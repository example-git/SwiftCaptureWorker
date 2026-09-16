import Foundation
import libsrt

/// SRT socket sink for MPEG-TS packets. Wraps libsrt C API and provides
/// buffered sending with lifecycle events emitted via SCAP control channel.
final class SRTSink: MPEGTSSink, @unchecked Sendable {
    private let url: URL
    private let latencyMs: Int
    private let streamIdOverride: String?

    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var senderThread: Thread?
    private var running = false
    private let lock = NSLock()

    // Bounded ring buffer for TS chunks (each 1316 bytes = 7 TS packets)
    private var chunkQueue: [Data] = []
    private let maxQueuedChunks = 300  // ~395 KB buffer (increased from 100 to handle burst)
    private var droppedChunks = 0
    private var lastDropWarningTime: Date?

    /// Called when the SRT connection is lost mid-stream. Fired from the sender
    /// thread. CaptureSession uses this to trigger requestStop().
    var onConnectionLost: ((String) -> Void)?

    // Stats for periodic SRT health logging
    private var statsBytesSent: Int64 = 0
    private var statsPacketsSent: Int64 = 0
    private var lastStatTime: Date?

    // Debug tee: if SRTSINK_DUMP_PATH env var is set, also write all TS data to that file.
    private var debugDumpHandle: FileHandle?

    /// Initialize with SRT URL (srt://host:port?streamid=...&latency=...&passphrase=...&pbkeylen=...)
    /// Hard-fails on invalid URL per Gate D.
    init(url: String, latencyMs: Int = 120, streamIdOverride: String? = nil) throws {
        guard let parsed = URL(string: url), parsed.scheme == "srt" else {
            throw WorkerError.invalidArgument("Invalid SRT URL: \(url). Must start with srt://")
        }
        guard let host = parsed.host, !host.isEmpty, parsed.port != nil else {
            throw WorkerError.invalidArgument("Invalid SRT URL: \(url). Missing host or port.")
        }

        self.url = parsed
        self.latencyMs = latencyMs
        self.streamIdOverride = streamIdOverride

        // Debug tee: open dump file if env var is set
        if let dumpPath = ProcessInfo.processInfo.environment["SRTSINK_DUMP_PATH"] {
            FileManager.default.createFile(atPath: dumpPath, contents: nil)
            self.debugDumpHandle = FileHandle(forWritingAtPath: dumpPath)
            FileHandle.standardError.write(Data("[SRTSink] Debug dump enabled: \(dumpPath)\n".utf8))
        }

        // Start libsrt if not already started (idempotent)
        if srt_startup() != 0 {
            throw WorkerError.ioFailed("srt_startup failed: \(String(cString: srt_getlasterror_str()))")
        }

        try connect()
    }

    deinit {
        stop()
    }

    // MARK: - MPEGTSSink Protocol

    func writeTSChunk(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }

        guard running else {
            throw WorkerError.ioFailed("SRT sink not running")
        }

        // Enqueue chunk; drop oldest if buffer full
        if chunkQueue.count >= maxQueuedChunks {
            chunkQueue.removeFirst()
            droppedChunks += 1

            // Emit warning every 5 seconds
            let now = Date()
            if lastDropWarningTime == nil || now.timeIntervalSince(lastDropWarningTime!) >= 5.0 {
                FileHandle.standardError.write(Data(
                    "[SRTSink] Warning: dropped \(droppedChunks) chunks in last 5s (network congestion)\n".utf8
                ))
                lastDropWarningTime = now

                // Escalate to transport-failed if >80 drops / 5s (mirrors GStreamer)
                if droppedChunks >= 80 {
                    FileHandle.standardError.write(Data(
                        "[SRTSink] ERROR: SRT uplink unstable (\(droppedChunks) drops / 5s). Connection failed.\n".utf8
                    ))
                    throw WorkerError.ioFailed("SRT transport failed (excessive packet loss)")
                }

                droppedChunks = 0
            }
        }

        chunkQueue.append(data)

        // Tee to debug dump file (if enabled)
        if let dh = debugDumpHandle {
            try? dh.write(contentsOf: data)
        }
    }

    func close() throws {
        debugDumpHandle?.closeFile()
        stop()
    }

    // MARK: - Private: Connection

    private func connect() throws {
        let sockfd = srt_create_socket()
        guard sockfd != SRT_INVALID_SOCK else {
            throw WorkerError.ioFailed("srt_create_socket failed: \(String(cString: srt_getlasterror_str()))")
        }

        // Parse query params and map to socket options
        var streamId: String? = streamIdOverride
        var passphrase: String?
        var pbkeylen: Int32 = 0

        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems {
                switch item.name.lowercased() {
                case "streamid":
                    if streamId == nil, let value = item.value { streamId = value }
                case "passphrase":
                    passphrase = item.value
                case "pbkeylen":
                    if let value = item.value, let num = Int32(value) { pbkeylen = num }
                default:
                    // Unknown params are ignored (not a hard-fail per plan update)
                    break
                }
            }
        }

        // Set socket options
        var latency = Int32(latencyMs)
        srt_setsockopt(sockfd, 0, SRTO_LATENCY, &latency, Int32(MemoryLayout<Int32>.size))

        var payloadSize = Int32(1316)
        srt_setsockopt(sockfd, 0, SRTO_PAYLOADSIZE, &payloadSize, Int32(MemoryLayout<Int32>.size))

        // Remove bandwidth ceiling so keyframe bursts are never TLPKTDROP'd.
        // GStreamer's srtsink also sets SRTO_MAXBW=-1 (unlimited).
        var maxbw = Int64(-1)
        srt_setsockopt(sockfd, 0, SRTO_MAXBW, &maxbw, Int32(MemoryLayout<Int64>.size))

        // Disable sender-side TLPKTDROP completely. With SNDDROPDELAY=-1, SRT
        // never drops a packet from the send buffer regardless of latency budget.
        // This ensures the server always receives every TS packet we produce.
        var snddropdelay = Int32(-1)
        srt_setsockopt(sockfd, 0, SRTO_SNDDROPDELAY, &snddropdelay, Int32(MemoryLayout<Int32>.size))

        if let sid = streamId {
            _ = sid.withCString { ptr in
                srt_setsockopt(sockfd, 0, SRTO_STREAMID, UnsafeMutableRawPointer(mutating: ptr), Int32(sid.utf8.count))
            }
        }

        if let pass = passphrase {
            _ = pass.withCString { ptr in
                srt_setsockopt(sockfd, 0, SRTO_PASSPHRASE, UnsafeMutableRawPointer(mutating: ptr), Int32(pass.utf8.count))
            }
            if pbkeylen > 0 {
                var keylen = pbkeylen
                srt_setsockopt(sockfd, 0, SRTO_PBKEYLEN, &keylen, Int32(MemoryLayout<Int32>.size))
            }
        }

        // Resolve host:port
        guard let host = url.host, let port = url.port else {
            srt_close(sockfd)
            throw WorkerError.invalidArgument("SRT URL missing host or port")
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM

        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "\(port)", &hints, &res)
        guard status == 0, let addr = res else {
            srt_close(sockfd)
            throw WorkerError.ioFailed("getaddrinfo failed for \(host):\(port)")
        }
        defer { freeaddrinfo(res) }

        // Connect in caller mode
        let connectResult = srt_connect(sockfd, addr.pointee.ai_addr, Int32(addr.pointee.ai_addrlen))
        if connectResult == SRT_ERROR {
            let err = String(cString: srt_getlasterror_str())
            srt_close(sockfd)
            throw WorkerError.ioFailed("srt_connect failed: \(err)")
        }

        socket = sockfd
        running = true

        // Start sender thread
        let thread = Thread { [weak self] in
            self?.senderLoop()
        }
        thread.start()
        senderThread = thread

        let streamIdDisplay = streamId != nil ? "[REDACTED]" : "none"
        FileHandle.standardError.write(Data(
            "[SRTSink] Connected to \(host):\(port) (latency=\(latencyMs)ms, streamid=\(streamIdDisplay))\n".utf8
        ))
    }

    private func stop() {
        lock.lock()
        running = false
        lock.unlock()

        // Wait for sender thread to exit
        senderThread?.cancel()

        if socket != SRT_INVALID_SOCK {
            srt_close(socket)
            socket = SRT_INVALID_SOCK
        }

        // Note: srt_cleanup() is global and should only be called at process exit
    }

    // MARK: - Private: Sender Thread

    private func senderLoop() {
        var consecutiveErrors = 0
        while true {
            lock.lock()
            guard running else {
                lock.unlock()
                break
            }

            guard !chunkQueue.isEmpty else {
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.001)  // 1ms
                continue
            }

            let chunk = chunkQueue.removeFirst()
            let currentSocket = socket  // Capture under lock to avoid race with stop()

            // Emit periodic SRT stats (every 5 seconds)
            let now = Date()
            let shouldLogStats = lastStatTime == nil || now.timeIntervalSince(lastStatTime!) >= 5.0
            if shouldLogStats { lastStatTime = now }
            lock.unlock()

            if shouldLogStats {
                logSRTStats(socket: currentSocket)
            }

            // Send chunk via srt_sendmsg2
            var sendFailed = false
            var sendError = ""
            chunk.withUnsafeBytes { ptr in
                guard let baseAddress = ptr.baseAddress else { return }
                let sent = srt_sendmsg2(currentSocket, baseAddress.assumingMemoryBound(to: Int8.self), Int32(chunk.count), nil)
                if sent == SRT_ERROR {
                    var errCode: Int32 = 0
                    _ = srt_getlasterror(&errCode)
                    sendError = "code=\(srt_getlasterror(nil)) sysErrno=\(errCode) msg=\(String(cString: srt_getlasterror_str()))"
                    sendFailed = true
                } else {
                    consecutiveErrors = 0
                    lock.lock()
                    statsBytesSent += Int64(chunk.count)
                    statsPacketsSent += 1
                    lock.unlock()
                }
            }

            if sendFailed {
                consecutiveErrors += 1
                FileHandle.standardError.write(Data(
                    "[SRTSink] srt_sendmsg2 failed (\(consecutiveErrors)): \(sendError)\n".utf8
                ))

                // Stop immediately — socket is broken. Do NOT retry on a dead socket.
                lock.lock()
                let wasRunning = running
                running = false
                lock.unlock()

                if wasRunning {
                    FileHandle.standardError.write(Data(
                        "[SRTSink] Connection lost — stopping sender thread\n".utf8
                    ))
                    onConnectionLost?("SRT connection lost: \(sendError)")
                }
                break
            }
        }
        FileHandle.standardError.write(Data("[SRTSink] Sender thread exiting\n".utf8))
    }

    private func logSRTStats(socket: SRTSOCKET) {
        guard socket != SRT_INVALID_SOCK else { return }
        var stats = CBytePerfMon()
        // srt_bstats(sock, perf, clear): clear=1 resets interval counters
        guard srt_bstats(socket, &stats, 1) == 0 else { return }

        let sent = stats.pktSent
        let retrans = stats.pktRetrans
        let lost = stats.pktSndLoss
        let kbpsSend = stats.mbpsSendRate * 1000  // convert Mbps → kbps
        let rttMs = stats.msRTT
        let bufMs = stats.msSndBuf

        let statMsg = "[SRTSink] Stats: sent=\(sent) retrans=\(retrans) loss=\(lost) " +
            "rate=\(String(format: "%.1f", kbpsSend))kbps rtt=\(String(format: "%.1f", rttMs))ms " +
            "buf=\(String(format: "%.1f", bufMs))ms\n"
        FileHandle.standardError.write(Data(statMsg.utf8))
    }
}
