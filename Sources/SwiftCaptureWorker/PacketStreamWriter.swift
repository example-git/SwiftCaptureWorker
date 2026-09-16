import Foundation

final class PacketStreamWriter {
    // MARK: - Storage (one of the two is set, never both)
    private let lock   = NSLock()
    private let handle: FileHandle?
    private let ipc:    IPCTransport?
    private let streamID: UInt8

    // MARK: - Init (file descriptor mode)
    init(fileDescriptor: Int32) {
        self.handle   = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: false)
        self.ipc      = nil
        self.streamID = 0
    }

    // MARK: - Init (IPC multiplex mode)
    init(ipcTransport: IPCTransport, streamID: UInt8) {
        self.handle   = nil
        self.ipc      = ipcTransport
        self.streamID = streamID
    }

    // MARK: - Public write API

    func writeConfiguration<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        try writePacket(type: .configuration, flags: 0, ptsNanoseconds: 0, payload: payload)
    }

    func writeSample(_ payload: Data, ptsNanoseconds: UInt64, flags: UInt16 = 0) throws {
        try writePacket(type: .sample, flags: flags, ptsNanoseconds: ptsNanoseconds, payload: payload)
    }

    func writeError(_ message: String) {
        guard let payload = message.data(using: .utf8) else { return }
        try? writePacket(type: .error, flags: 0, ptsNanoseconds: 0, payload: payload)
    }

    func writeEndOfStream() {
        try? writePacket(type: .endOfStream, flags: 0, ptsNanoseconds: 0, payload: Data())
    }

    func close() {
        handle?.closeFile()
        // IPCTransport is reference-counted; caller closes it when all writers are done.
    }

    // MARK: - Private

    private func writePacket(type: PacketType, flags: UInt16, ptsNanoseconds: UInt64, payload: Data) throws {
        guard payload.count <= Int(UInt32.max) else {
            throw WorkerError.ioFailed("Packet payload exceeds the maximum supported size.")
        }

        var header = Data(capacity: 24)
        header.append(contentsOf: [0x53, 0x43, 0x41, 0x50])          // "SCAP"
        header.append(0x01)                                            // version
        header.append(type.rawValue)                                   // type
        header.append(contentsOf: flags.bigEndianBytes)                // flags
        header.append(contentsOf: ptsNanoseconds.bigEndianBytes)       // pts
        header.append(contentsOf: UInt32(payload.count).bigEndianBytes)// length
        header.append(streamID)                                        // stream_id (was reserved[0])
        header.append(contentsOf: [0, 0, 0])                          // reserved[1-3]

        if let ipc {
            // IPC mode: shared transport, already has its own lock.
            var packet = header
            if !payload.isEmpty { packet.append(payload) }
            try ipc.write(packet)
        } else if let handle {
            // FD mode: per-writer lock.
            lock.lock()
            defer { lock.unlock() }
            do {
                try handle.write(contentsOf: header)
                if !payload.isEmpty {
                    try handle.write(contentsOf: payload)
                }
            } catch {
                throw WorkerError.ioFailed("Failed to write packet stream data: \(error.localizedDescription)")
            }
        }
    }
}

private extension FixedWidthInteger {
    var bigEndianBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian) { Array($0) }
    }
}
