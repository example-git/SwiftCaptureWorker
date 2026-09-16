import Foundation
import Darwin

/// Shared low-level IPC connection used by all PacketStreamWriters in IPC mode.
///
/// Owns a single socket file descriptor and an NSLock so that multiple
/// PacketStreamWriters (video, system audio, input audio) can safely
/// multiplex onto the same connection.
final class IPCTransport: @unchecked Sendable {

    // MARK: - Endpoint (immutable, used for reconnection)
    private enum Endpoint {
        case unixSocket(String)
        case tcp(Int)
    }
    private let endpoint: Endpoint

    private var fd: Int32
    private let lock = NSLock()

    /// Called when a broken-pipe triggers a successful reconnect.
    /// The capture session should re-send stream configuration packets on this callback.
    var onReconnected: (() -> Void)?

    // MARK: - Init

    /// Connect to a Unix domain socket at `path`.
    init(unixSocketPath path: String) throws {
        self.endpoint = .unixSocket(path)
        self.fd = try Self.connectUnix(path: path)
    }

    /// Connect to `127.0.0.1:<port>` over TCP.
    init(tcpPort port: Int) throws {
        self.endpoint = .tcp(port)
        self.fd = try Self.connectTCP(port: port)
    }

    deinit {
        Darwin.close(fd)
    }

    // MARK: - Write

    /// Write all bytes of `data` to the socket, holding the shared lock.
    /// On EPIPE / ECONNRESET, blocks writes and spawns a background reconnect loop.
    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeUnderLock(data)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        Darwin.close(fd)
        fd = -1
    }

    // MARK: - Private helpers

    private func writeUnderLock(_ data: Data) throws {
        var writeError: Int32 = 0
        var offset = 0
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            while offset < buf.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buf.count - offset)
                if n > 0 {
                    offset += n
                } else {
                    writeError = (n < 0) ? errno : ECONNRESET
                    return
                }
            }
        }

        if writeError != 0 {
            let isBrokenPipe = writeError == EPIPE || writeError == ECONNRESET || writeError == EBADF
            if isBrokenPipe {
                // Close the dead socket and attempt reconnection on a background thread.
                Darwin.close(fd)
                fd = -1
                lock.unlock()
                reconnectInBackground()
                lock.lock()
            }
            throw WorkerError.ioFailed("IPC write failed (errno \(writeError)).")
        }
    }

    /// Retries the connection with exponential backoff (100 ms → 1.6 s, up to 10 attempts).
    /// Writes are dropped while disconnected; once reconnected, fires `onReconnected`
    /// so the caller can re-send stream configuration packets.
    private func reconnectInBackground() {
        let endpoint = self.endpoint
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var delay: UInt32 = 100_000  // 100 ms in microseconds
            for attempt in 1...10 {
                usleep(delay)
                delay = min(delay * 2, 1_600_000)  // cap at 1.6 s
                do {
                    let newFD: Int32
                    switch endpoint {
                    case .unixSocket(let path): newFD = try Self.connectUnix(path: path)
                    case .tcp(let port):        newFD = try Self.connectTCP(port: port)
                    }
                    self.lock.lock()
                    self.fd = newFD
                    let cb = self.onReconnected
                    self.lock.unlock()
                    fputs("[IPCTransport] Reconnected on attempt \(attempt)\n", stderr)
                    cb?()
                    return
                } catch {
                    fputs("[IPCTransport] Reconnect attempt \(attempt) failed: \(error)\n", stderr)
                }
            }
            fputs("[IPCTransport] Giving up after 10 reconnect attempts\n", stderr)
        }
    }

    // MARK: - Static connect helpers

    private static func connectUnix(path: String) throws -> Int32 {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw WorkerError.ioFailed("Failed to create Unix domain socket (errno \(errno)).")
        }
        var nosigpipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe,
                   socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len    = UInt8(MemoryLayout<sockaddr_un>.size)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard path.utf8.count <= maxLen else {
            Darwin.close(socketFD)
            throw WorkerError.ioFailed("Unix socket path too long (max \(maxLen) bytes): \(path)")
        }
        var sunPath = addr.sun_path
        withUnsafeMutablePointer(to: &sunPath) { ptr in
            ptr.withMemoryRebound(to: CChar.self,
                                  capacity: MemoryLayout.size(ofValue: addr.sun_path)) { dst in
                path.withCString { src in _ = strncpy(dst, src, maxLen) }
            }
        }
        addr.sun_path = sunPath
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(socketFD)
            throw WorkerError.ioFailed(
                "Failed to connect to Unix socket '\(path)' (errno \(errno)).")
        }
        return socketFD
    }

    private static func connectTCP(port: Int) throws -> Int32 {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw WorkerError.ioFailed("Failed to create TCP socket (errno \(errno)).")
        }
        var nosigpipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe,
                   socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            Darwin.close(socketFD)
            throw WorkerError.ioFailed(
                "Failed to connect to TCP 127.0.0.1:\(port) (errno \(errno)).")
        }
        return socketFD
    }
}
