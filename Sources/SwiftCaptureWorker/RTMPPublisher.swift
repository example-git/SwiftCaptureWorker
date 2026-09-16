import Foundation
import CoreMedia

/// Minimal RTMP publisher (publish-only). Accepts raw Annex-B H.264 and ADTS AAC,
/// converts to FLV video/audio messages, and streams to an rtmp:// URL.
/// No external dependencies — pure Swift over POSIX TCP.
final class RTMPPublisher: @unchecked Sendable {

    // MARK: - Public interface

    /// Called on the sender queue when the connection is lost. CaptureSession uses this
    /// to call requestStop().
    var onConnectionLost: ((String) -> Void)?

    /// Called on a background thread after a successful reconnect.
    var onReconnected: (() -> Void)?

    var isReconnecting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reconnecting
    }

    // MARK: - Init / deinit

    /// Parse and connect immediately. Throws on invalid URL or connection failure.
    init(url: String) throws {
        guard let parsed = URL(string: url), parsed.scheme == "rtmp" else {
            throw WorkerError.invalidArgument("Invalid RTMP URL: \(url). Must start with rtmp://")
        }
        guard let host = parsed.host, !host.isEmpty else {
            throw WorkerError.invalidArgument("Invalid RTMP URL: missing host")
        }
        let port = parsed.port ?? 1935
        // Path: /appName/streamKey  — app is everything except last component, streamKey is last.
        let pathComponents = parsed.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 1 else {
            throw WorkerError.invalidArgument("Invalid RTMP URL: path must be /app/streamKey or /streamKey")
        }
        let streamKey = pathComponents.last!
        let appName = pathComponents.dropLast().joined(separator: "/").nonEmpty ?? "live"
        let tcUrl = "\(parsed.scheme ?? "rtmp")://\(host):\(port)/\(appName)"

        self.host = host
        self.port = port
        self.appName = appName
        self.streamKey = streamKey
        self.tcUrl = tcUrl

        FileHandle.standardError.write(Data(
            "[RTMPPublisher] Connecting to \(host):\(port) app=\(appName) stream=[REDACTED]\n".utf8
        ))

        try connectAndHandshake()

        FileHandle.standardError.write(Data(
            "[RTMPPublisher] Connected\n".utf8
        ))

        // Start sender thread for async buffered sending
        startSenderThread()
        // Start receiver thread to drain incoming server control messages
        startReceiverThread()
    }

    deinit {
        close()
    }

    // MARK: - Media write API

    /// Write an Annex-B H.264 sample. Keyframe payload must include SPS+PPS+IDR.
    func writeVideoSample(_ annexB: Data, pts: CMTime, dts: CMTime, isKeyFrame: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isConnected || reconnecting else { throw WorkerError.ioFailed("RTMP not connected") }

        let ptMs = toRTMPTimestamp(pts)
        let dtMs = toRTMPTimestamp(dts.isValid ? dts : pts)
        let cts  = Int32(ptMs) - Int32(dtMs)  // composition time offset (usually 0)

        if isKeyFrame {
            // Parse SPS/PPS from the keyframe Annex-B stream and send sequence header if changed.
            let nalus = parseAnnexBNALUs(annexB)
            let spsNALUs = nalus.filter { ($0.first ?? 0) & 0x1F == 7 }
            let ppsNALUs = nalus.filter { ($0.first ?? 0) & 0x1F == 8 }
            if let sps = spsNALUs.first, let pps = ppsNALUs.first {
                let newHash = (sps + pps).hashValue
                if newHash != lastParameterSetHash {
                    lastParameterSetHash = newHash
                    let seqHeader = buildAVCSequenceHeader(sps: sps, pps: pps)
                    let msg = buildFLVVideoMessage(
                        isKeyFrame: true, isSequenceHeader: true, cts: 0,
                        payload: seqHeader, timestamp: dtMs
                    )
                    enqueueMessage(type: 0x09, chunkStreamID: 4, timestamp: dtMs,
                                   messageStreamID: publishStreamID, payload: msg, isKeyFrame: true)
                }
            }
        }

        // Strip parameter sets from Annex-B to get only frame NALUs, then convert to AVCC.
        let frameNALUs: [Data]
        if isKeyFrame {
            // Drop SPS (type 7) and PPS (type 8); keep IDR (type 5) and others.
            frameNALUs = parseAnnexBNALUs(annexB).filter {
                let t = ($0.first ?? 0) & 0x1F
                return t != 7 && t != 8
            }
        } else {
            frameNALUs = parseAnnexBNALUs(annexB)
        }

        guard !frameNALUs.isEmpty else { return }

        let avcc = nalUsToAVCC(frameNALUs)
        let msg = buildFLVVideoMessage(
            isKeyFrame: isKeyFrame, isSequenceHeader: false, cts: cts,
            payload: avcc, timestamp: dtMs
        )
        enqueueMessage(type: 0x09, chunkStreamID: 4, timestamp: dtMs,
                       messageStreamID: publishStreamID, payload: msg, isKeyFrame: isKeyFrame)
    }

    /// Write an ADTS-framed AAC sample.
    func writeAudioSample(_ adts: Data, pts: CMTime) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isConnected || reconnecting else { throw WorkerError.ioFailed("RTMP not connected") }

        let ts = toRTMPTimestamp(pts)

        if !audioHeaderSent {
            // Extract AudioSpecificConfig from ADTS header and send AAC sequence header.
            if let asc = audioSpecificConfigFromADTS(adts) {
                var seqHeader = Data([0xAF, 0x00])  // AAC, sequence header
                seqHeader.append(asc)
                enqueueMessage(type: 0x08, chunkStreamID: 5, timestamp: 0,
                               messageStreamID: publishStreamID, payload: seqHeader, isKeyFrame: false)
                audioHeaderSent = true
            }
        }

        // Strip 7-byte ADTS header (0xFFF1... no-CRC), send raw AAC.
        guard adts.count > 7 else { return }
        let raw = adts.dropFirst(7)
        var msg = Data([0xAF, 0x01])  // AAC, raw data
        msg.append(raw)
        enqueueMessage(type: 0x08, chunkStreamID: 5, timestamp: ts,
                       messageStreamID: publishStreamID, payload: msg, isKeyFrame: false)
    }

    func close() {
        lock.lock()
        reconnecting = false
        isShuttingDown = true
        senderRunning = false
        receiverRunning = false
        let hadConnection = isConnected || sendFD != nil || recvFD != nil
        isConnected = false
        if let fd = sendFD { Darwin.close(fd) }
        if sendFD != recvFD, let fd = recvFD { Darwin.close(fd) }
        sendFD = nil
        recvFD = nil
        lock.unlock()

        // Wait for threads to exit
        senderThread?.cancel()
        receiverThread?.cancel()

        if hadConnection {
            FileHandle.standardError.write(Data("[RTMPPublisher] Closed\n".utf8))
        }
    }

    // MARK: - Buffered sending

    /// Enqueue a message for async sending. Called under lock from writeVideoSample/writeAudioSample.
    private func enqueueMessage(type: UInt8, chunkStreamID: UInt8, timestamp: UInt32,
                                messageStreamID: UInt32, payload: Data, isKeyFrame: Bool) {
        // Drop oldest non-keyframe if buffer is full
        if messageQueue.count >= maxQueuedMessages {
            // Try to find a non-keyframe to drop
            if let idx = messageQueue.firstIndex(where: { !$0.isKeyFrame }) {
                messageQueue.remove(at: idx)
            } else {
                // All keyframes, drop oldest
                messageQueue.removeFirst()
            }
            droppedFrames += 1

            // Emit warning every 5 seconds
            let now = Date()
            if lastDropWarningTime == nil || now.timeIntervalSince(lastDropWarningTime!) >= 5.0 {
                FileHandle.standardError.write(Data(
                    "[RTMPPublisher] Warning: dropped \(droppedFrames) frames in last 5s (network congestion)\n".utf8
                ))
                lastDropWarningTime = now
                droppedFrames = 0
            }
        }

        messageQueue.append(QueuedMessage(
            type: type,
            chunkStreamID: chunkStreamID,
            timestamp: timestamp,
            messageStreamID: messageStreamID,
            payload: payload,
            isKeyFrame: isKeyFrame
        ))
    }

    private func startSenderThread() {
        lock.lock()
        senderRunning = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.senderLoop()
        }
        thread.start()
        senderThread = thread
    }

    private func senderLoop() {
        while true {
            lock.lock()
            guard senderRunning else {
                lock.unlock()
                break
            }

            guard !messageQueue.isEmpty else {
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.001)  // 1ms
                continue
            }

            let msg = messageQueue.removeFirst()

            // Send the message (still holding lock to protect chunkSendState)
            do {
                try sendMessageDirect(
                    type: msg.type,
                    chunkStreamID: msg.chunkStreamID,
                    timestamp: msg.timestamp,
                    messageStreamID: msg.messageStreamID,
                    payload: msg.payload
                )
                lock.unlock()
            } catch {
                lock.unlock()
                // Connection lost, trigger reconnect
                FileHandle.standardError.write(Data(
                    "[RTMPPublisher] Send failed: \(error.localizedDescription)\n".utf8
                ))
                reconnectInBackground()
                break
            }
        }
    }

    private func startReceiverThread() {
        lock.lock()
        receiverRunning = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.receiverLoop()
        }
        thread.start()
        receiverThread = thread
    }

    private func receiverLoop() {
        // Continuously drain incoming server messages (window acks, pings, bandwidth updates)
        // to prevent TCP receive buffer from filling up and causing flow control throttling.
        while true {
            lock.lock()
            guard receiverRunning else {
                lock.unlock()
                break
            }
            lock.unlock()

            do {
                // readNextMessage() polls with 50ms timeout, returns nil if nothing ready
                if let msg = try readNextMessage() {
                    lock.lock()
                    handleControlMessage(msg)
                    lock.unlock()
                } else {
                    // No message ready, brief sleep to avoid tight loop
                    Thread.sleep(forTimeInterval: 0.01)  // 10ms
                }
            } catch {
                // Connection lost or recv error
                FileHandle.standardError.write(Data(
                    "[RTMPPublisher] Receiver failed: \(error.localizedDescription)\n".utf8
                ))
                break
            }
        }
        FileHandle.standardError.write(Data("[RTMPPublisher] Receiver thread exiting\n".utf8))
    }

    /// Reconnect with exponential backoff (100 ms → 3.2 s, up to 10 attempts).
    /// Resets all media state so SPS/PPS sequence headers and audio headers are re-sent.
    /// Calls `onReconnected` on success, `onConnectionLost` if all attempts fail.
    func reconnectInBackground() {
        lock.lock()
        guard !isShuttingDown, !reconnecting else {
            lock.unlock()
            return
        }
        reconnecting = true
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var delay: UInt32 = 100_000  // 100 ms
            for attempt in 1...10 {
                usleep(delay)
                delay = min(delay * 2, 3_200_000)  // cap 3.2 s

                self.lock.lock()
                if self.isShuttingDown {
                    self.reconnecting = false
                    self.lock.unlock()
                    return
                }
                // Reset media state before reconnecting so sequence headers re-fire
                self.startPTS             = -1
                self.lastParameterSetHash  = 0
                self.audioHeaderSent      = false
                self.chunkSendState       = [:]
                self.chunkRecvState       = [:]
                self.recvBuffer           = Data()
                self.chunkSize            = 128
                self.serverChunkSize      = 128
                self.nextInvokeID         = 1
                // Clear pending messages - they're stale after reconnect
                self.messageQueue.removeAll()
                self.lock.unlock()

                do {
                    try self.connectAndHandshake()
                    self.lock.lock()
                    let shuttingDown = self.isShuttingDown
                    if shuttingDown {
                        self.reconnecting = false
                        self.lock.unlock()
                        self.close()
                        return
                    }
                    self.reconnecting = false
                    // Restart sender and receiver threads if they died
                    let needsSender = !self.senderRunning
                    let needsReceiver = !self.receiverRunning
                    self.lock.unlock()
                    if needsSender {
                        self.startSenderThread()
                    }
                    if needsReceiver {
                        self.startReceiverThread()
                    }
                    FileHandle.standardError.write(Data("[RTMPPublisher] Reconnected on attempt \(attempt)\n".utf8))
                    self.onReconnected?()
                    return
                } catch {
                    self.lock.lock()
                    let shuttingDown = self.isShuttingDown
                    self.lock.unlock()
                    FileHandle.standardError.write(Data("[RTMPPublisher] Reconnect attempt \(attempt) failed: \(error)\n".utf8))
                    if shuttingDown {
                        self.lock.lock()
                        self.reconnecting = false
                        self.lock.unlock()
                        return
                    }
                }
            }

            self.lock.lock()
            self.reconnecting = false
            let shuttingDown = self.isShuttingDown
            self.lock.unlock()
            if shuttingDown {
                return
            }
            let msg = "RTMP reconnect failed after 10 attempts"
            FileHandle.standardError.write(Data("[RTMPPublisher] \(msg)\n".utf8))
            self.onConnectionLost?(msg)
        }
    }

    // MARK: - Private state

    private let host: String
    private let port: Int
    private let appName: String
    private let streamKey: String
    private let tcUrl: String

    /// Serialises all mutable state access. Held across entire send/recv operations
    /// so reconnect and media-write paths never race.
    private let lock = NSLock()

    private var sendFD: Int32?
    private var recvFD: Int32?
    private var isConnected = false
    private var reconnecting = false
    private var isShuttingDown = false

    private var chunkSize: Int = 128
    private var publishStreamID: UInt32 = 1
    private var nextInvokeID: Double = 1

    // Chunk send state: last sent header per csid (for delta encoding)
    private struct ChunkSendState {
        var timestamp: UInt32 = 0
        var messageLength: Int = 0
        var messageTypeID: UInt8 = 0
        var messageStreamID: UInt32 = 0
    }
    private var chunkSendState: [UInt8: ChunkSendState] = [:]

    // Media state
    private var startPTS: Int64 = -1      // 90 kHz ticks of first sample
    private var lastParameterSetHash: Int = 0
    private var audioHeaderSent = false

    // Sender queue for async buffered sending
    private struct QueuedMessage {
        let type: UInt8
        let chunkStreamID: UInt8
        let timestamp: UInt32
        let messageStreamID: UInt32
        let payload: Data
        let isKeyFrame: Bool  // for drop priority
    }
    private var messageQueue: [QueuedMessage] = []
    // Sized for 60fps feeds: 60 video msgs/s + ~47 AAC audio msgs/s (48 kHz / 1024 samples)
    // ≈ 107 msgs/s → 320 ≈ 3 seconds of buffering before drops kick in.
    private let maxQueuedMessages = 320
    private var droppedFrames = 0
    private var lastDropWarningTime: Date?
    private var senderThread: Thread?
    private var senderRunning = false

    // Receiver thread for draining incoming server messages
    private var receiverThread: Thread?
    private var receiverRunning = false

    // Receive buffer
    private var recvBuffer = Data()
    private var serverChunkSize: Int = 128
    // Chunk recv state per csid
    private struct ChunkRecvState {
        var timestamp: UInt32 = 0
        var messageLength: Int = 0
        var messageTypeID: UInt8 = 0
        var messageStreamID: UInt32 = 0
        var bytesReceived: Int = 0
        var payload: Data = Data()
    }
    private var chunkRecvState: [UInt8: ChunkRecvState] = [:]

    // MARK: - Connection & handshake

    private func connectAndHandshake() throws {
        // Resolve host
        var hints = addrinfo()
        hints.ai_family   = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &res) == 0, let addr = res else {
            throw WorkerError.ioFailed("getaddrinfo failed for \(host):\(port)")
        }
        defer { freeaddrinfo(res) }

        let fd = socket(addr.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw WorkerError.ioFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        guard Darwin.connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 else {
            Darwin.close(fd)
            throw WorkerError.ioFailed("connect() failed: \(String(cString: strerror(errno)))")
        }
        sendFD = fd
        recvFD = fd
        isConnected = true

        // C0 + C1
        var c0c1 = Data(count: 1537)
        c0c1[0] = 0x03  // version
        // C1: timestamp (4 bytes, we use 0), zeros (4 bytes), random (1528 bytes)
        var rng = SystemRandomNumberGenerator()
        for i in 9..<1537 { c0c1[i] = UInt8.random(in: 0...255, using: &rng) }
        try tcpSend(c0c1)

        // Receive S0 + S1 + S2
        let s0s1s2 = try tcpRecv(count: 1 + 1536 + 1536)
        guard s0s1s2[0] == 0x03 else {
            throw WorkerError.ioFailed("RTMP handshake: unexpected server version \(s0s1s2[0])")
        }
        // C2 = S1 (bytes 1..1536)
        let c2 = s0s1s2.subdata(in: 1..<1537)
        try tcpSend(c2)

        // Now do the RTMP connect/publish sequence
        try rtmpConnect()
        try rtmpCreateStream()
        try rtmpPublish()

        FileHandle.standardError.write(Data("[RTMPPublisher] Publish session started\n".utf8))
    }

    // MARK: - AMF Command sequence

    private func rtmpConnect() throws {
        let invokeID = nextInvokeID; nextInvokeID += 1
        var amf = Data()
        amf.append(amfString("connect"))
        amf.append(amfNumber(invokeID))
        amf.append(amfObject([
            "app":      amfString(appName),
            "type":     amfString("nonprivate"),
            "flashVer": amfString("FMLE/3.0 (compatible; FMSc/1.0)"),
            "tcUrl":    amfString(tcUrl)
        ]))
        try sendMessage(type: 0x14, chunkStreamID: 3, timestamp: 0, messageStreamID: 0, payload: amf)

        // Wait for _result or _error
        try waitForResult(invokeID: invokeID, label: "connect")
    }

    private func rtmpCreateStream() throws {
        let invokeID = nextInvokeID; nextInvokeID += 1
        var amf = Data()
        amf.append(amfString("createStream"))
        amf.append(amfNumber(invokeID))
        amf.append(0x05)  // null
        try sendMessage(type: 0x14, chunkStreamID: 3, timestamp: 0, messageStreamID: 0, payload: amf)

        // Wait for _result containing stream ID
        let streamID = try waitForCreateStreamResult(invokeID: invokeID)
        publishStreamID = streamID
    }

    private func rtmpPublish() throws {
        let invokeID = nextInvokeID; nextInvokeID += 1
        var amf = Data()
        amf.append(amfString("publish"))
        amf.append(amfNumber(invokeID))
        amf.append(0x05)  // null
        amf.append(amfString(streamKey))
        amf.append(amfString("live"))
        try sendMessage(type: 0x14, chunkStreamID: 3, timestamp: 0,
                        messageStreamID: publishStreamID, payload: amf)
        // Some servers send onStatus; drain briefly but don't require it
        try drainIncoming(timeoutMs: 1000)
    }

    // MARK: - Message send

    /// Send a message directly (no lock, no enqueue). Called from handshake code or sender thread.
    private func sendMessageDirect(type: UInt8, chunkStreamID: UInt8, timestamp: UInt32,
                                   messageStreamID: UInt32, payload: Data) throws {
        let state = chunkSendState[chunkStreamID] ?? ChunkSendState()
        let isFirst = chunkSendState[chunkStreamID] == nil
        chunkSendState[chunkStreamID] = ChunkSendState(
            timestamp: timestamp,
            messageLength: payload.count,
            messageTypeID: type,
            messageStreamID: messageStreamID
        )

        var offset = 0
        while offset < payload.count || (payload.isEmpty && offset == 0) {
            let chunkPayloadSize = min(chunkSize, payload.count - offset)
            let isFirstChunk = offset == 0

            // Pre-allocate header capacity: basic(1) + timestamp(3-7) + len(3) + type(1) + streamID(4) + extTS(4) + chunk
            // = max ~20 bytes header + chunkPayloadSize. Avoids repeated realloc() on each append().
            var header = Data(capacity: 20 + chunkPayloadSize)
            // Basic header: fmt + csid (1 byte, csid 2..63)
            let fmt: UInt8 = isFirstChunk ? (isFirst ? 0 : 0) : 3
            header.append((fmt << 6) | (chunkStreamID & 0x3F))

            if isFirstChunk {
                // fmt=0: full header
                let ts = min(timestamp, 0xFFFFFF)
                header.append(UInt8((ts >> 16) & 0xFF))
                header.append(UInt8((ts >> 8)  & 0xFF))
                header.append(UInt8(ts & 0xFF))
                let len = payload.count
                header.append(UInt8((len >> 16) & 0xFF))
                header.append(UInt8((len >> 8)  & 0xFF))
                header.append(UInt8(len & 0xFF))
                header.append(type)
                // Stream ID: little-endian
                header.append(UInt8(messageStreamID & 0xFF))
                header.append(UInt8((messageStreamID >> 8) & 0xFF))
                header.append(UInt8((messageStreamID >> 16) & 0xFF))
                header.append(UInt8((messageStreamID >> 24) & 0xFF))
                if timestamp >= 0xFFFFFF {
                    header.append(UInt8((timestamp >> 24) & 0xFF))
                    header.append(UInt8((timestamp >> 16) & 0xFF))
                    header.append(UInt8((timestamp >> 8)  & 0xFF))
                    header.append(UInt8(timestamp & 0xFF))
                }
            }
            // fmt=3: no header bytes beyond basic header (continuation chunk)

            header.append(payload.subdata(in: offset..<offset + chunkPayloadSize))
            try tcpSend(header)

            offset += chunkPayloadSize
            if payload.isEmpty { break }

            _ = state  // suppress unused-var warning
        }
    }

    /// Wrapper for handshake/control messages. Acquires lock and sends immediately.
    private func sendMessage(type: UInt8, chunkStreamID: UInt8, timestamp: UInt32,
                             messageStreamID: UInt32, payload: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try sendMessageDirect(type: type, chunkStreamID: chunkStreamID,
                              timestamp: timestamp, messageStreamID: messageStreamID,
                              payload: payload)
    }

    // MARK: - TCP I/O

    private func tcpSend(_ data: Data) throws {
        guard let fd = sendFD else { throw WorkerError.ioFailed("Not connected") }
        var sent = 0
        try data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n <= 0 {
                    isConnected = false
                    if let fd = sendFD { Darwin.close(fd) }
                    if sendFD != recvFD, let fd = recvFD { Darwin.close(fd) }
                    sendFD = nil
                    recvFD = nil
                    let msg = "TCP send failed: \(String(cString: strerror(errno)))"
                    onConnectionLost?(msg)
                    throw WorkerError.ioFailed(msg)
                }
                sent += n
            }
        }
    }

    private func tcpRecv(count: Int) throws -> Data {
        guard let fd = recvFD else { throw WorkerError.ioFailed("Not connected") }
        var result = Data(count: count)
        var received = 0
        try result.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while received < count {
                let n = Darwin.recv(fd, base.advanced(by: received), count - received, 0)
                if n <= 0 {
                    isConnected = false
                    if let fd = sendFD { Darwin.close(fd) }
                    if sendFD != recvFD, let fd = recvFD { Darwin.close(fd) }
                    sendFD = nil
                    recvFD = nil
                    let msg = n == 0 ? "RTMP server closed connection" :
                        "TCP recv failed: \(String(cString: strerror(errno)))"
                    onConnectionLost?(msg)
                    throw WorkerError.ioFailed(msg)
                }
                received += n
            }
        }
        return result
    }

    // MARK: - Incoming message parsing

    private func waitForResult(invokeID: Double, label: String) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let msg = try readNextMessage() {
                if msg.type == 0x14 || msg.type == 0x11 {
                    // AMF0/AMF3 command - check if _result or _error
                    let (name, id) = amfCommandNameAndID(msg.payload)
                    if id == invokeID {
                        if name == "_error" {
                            throw WorkerError.ioFailed("RTMP \(label) error from server")
                        }
                        return  // _result — success
                    }
                }
                handleControlMessage(msg)
            }
        }
        throw WorkerError.ioFailed("RTMP \(label): timed out waiting for _result")
    }

    private func waitForCreateStreamResult(invokeID: Double) throws -> UInt32 {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let msg = try readNextMessage() {
                if msg.type == 0x14 || msg.type == 0x11 {
                    let (name, id) = amfCommandNameAndID(msg.payload)
                    if id == invokeID && name == "_result" {
                        // Stream ID is the 4th AMF value (number after null)
                        return parseStreamIDFromResult(msg.payload)
                    }
                }
                handleControlMessage(msg)
            }
        }
        throw WorkerError.ioFailed("RTMP createStream: timed out")
    }

    private func drainIncoming(timeoutMs: Int) throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            guard let fd = recvFD else { break }
            var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&fds, 1, 50)
            if r <= 0 { break }
            if (fds.revents & Int16(POLLIN)) != 0 {
                if let msg = try readNextMessage() {
                    handleControlMessage(msg)
                }
            }
        }
    }

    private struct RTMPMessage {
        let type: UInt8
        let streamID: UInt32
        let timestamp: UInt32
        let payload: Data
    }

    private func readNextMessage() throws -> RTMPMessage? {
        guard let fd = recvFD else { return nil }
        // Non-blocking check
        var fds = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&fds, 1, 50)
        guard r > 0, (fds.revents & Int16(POLLIN)) != 0 else { return nil }

        // Read at least 1 byte for basic header
        let headerByte = try tcpRecv(count: 1)[0]
        let fmt = (headerByte >> 6) & 0x03
        var csid = Int(headerByte & 0x3F)
        if csid == 0 {
            csid = Int(try tcpRecv(count: 1)[0]) + 64
        } else if csid == 1 {
            let b = try tcpRecv(count: 2)
            csid = Int(b[0]) | (Int(b[1]) << 8) + 64
        }

        var state = chunkRecvState[UInt8(csid)] ?? ChunkRecvState()

        if fmt == 0 {
            let h = try tcpRecv(count: 11)
            state.timestamp    = UInt32(h[0]) << 16 | UInt32(h[1]) << 8 | UInt32(h[2])
            state.messageLength = Int(h[3]) << 16 | Int(h[4]) << 8 | Int(h[5])
            state.messageTypeID = h[6]
            state.messageStreamID = UInt32(h[7]) | UInt32(h[8]) << 8 | UInt32(h[9]) << 16 | UInt32(h[10]) << 24
            if state.timestamp == 0xFFFFFF {
                let ext = try tcpRecv(count: 4)
                state.timestamp = UInt32(ext[0]) << 24 | UInt32(ext[1]) << 16 | UInt32(ext[2]) << 8 | UInt32(ext[3])
            }
            state.bytesReceived = 0
            state.payload = Data()
        } else if fmt == 1 {
            let h = try tcpRecv(count: 7)
            let ts = UInt32(h[0]) << 16 | UInt32(h[1]) << 8 | UInt32(h[2])
            state.messageLength = Int(h[3]) << 16 | Int(h[4]) << 8 | Int(h[5])
            state.messageTypeID = h[6]
            state.timestamp += ts
            if ts == 0xFFFFFF {
                let ext = try tcpRecv(count: 4)
                state.timestamp = UInt32(ext[0]) << 24 | UInt32(ext[1]) << 16 | UInt32(ext[2]) << 8 | UInt32(ext[3])
            }
            state.bytesReceived = 0
            state.payload = Data()
        } else if fmt == 2 {
            let h = try tcpRecv(count: 3)
            let ts = UInt32(h[0]) << 16 | UInt32(h[1]) << 8 | UInt32(h[2])
            state.timestamp += ts
            if ts == 0xFFFFFF {
                let ext = try tcpRecv(count: 4)
                state.timestamp = UInt32(ext[0]) << 24 | UInt32(ext[1]) << 16 | UInt32(ext[2]) << 8 | UInt32(ext[3])
            }
        }
        // fmt==3: continuation, no header

        let remaining = state.messageLength - state.bytesReceived
        let chunkBytes = min(serverChunkSize, remaining)
        let chunk = try tcpRecv(count: chunkBytes)
        state.payload.append(chunk)
        state.bytesReceived += chunkBytes
        chunkRecvState[UInt8(csid)] = state

        if state.bytesReceived >= state.messageLength {
            let msg = RTMPMessage(type: state.messageTypeID, streamID: state.messageStreamID,
                                  timestamp: state.timestamp, payload: state.payload)
            chunkRecvState[UInt8(csid)]?.bytesReceived = 0
            chunkRecvState[UInt8(csid)]?.payload = Data()
            return msg
        }
        return nil
    }

    private func handleControlMessage(_ msg: RTMPMessage) {
        switch msg.type {
        case 0x01:  // Set Chunk Size
            if msg.payload.count >= 4 {
                serverChunkSize = Int(msg.payload[0]) << 24 | Int(msg.payload[1]) << 16 |
                                  Int(msg.payload[2]) << 8  | Int(msg.payload[3])
                serverChunkSize = max(1, serverChunkSize & 0x7FFFFFFF)
            }
        case 0x04:  // User Control — ignore
            break
        case 0x05:  // Window Acknowledgement Size — send ack if needed
            break
        case 0x06:  // Set Peer Bandwidth — ignore
            break
        case 0x03:  // Acknowledgement — ignore
            break
        default:
            break
        }
    }

    // MARK: - AMF0 helpers

    private func amfString(_ s: String) -> Data {
        var d = Data([0x02])
        let bytes = Data(s.utf8)
        d.append(UInt8((bytes.count >> 8) & 0xFF))
        d.append(UInt8(bytes.count & 0xFF))
        d.append(bytes)
        return d
    }

    private func amfNumber(_ n: Double) -> Data {
        var d = Data([0x00])
        var v = n.bitPattern.bigEndian
        d.append(Data(bytes: &v, count: 8))
        return d
    }

    private func amfObject(_ pairs: [String: Data]) -> Data {
        var d = Data([0x03])
        for (key, value) in pairs {
            let kb = Data(key.utf8)
            d.append(UInt8((kb.count >> 8) & 0xFF))
            d.append(UInt8(kb.count & 0xFF))
            d.append(kb)
            d.append(value)
        }
        d.append(contentsOf: [0x00, 0x00, 0x09])  // object end marker
        return d
    }

    private func amfCommandNameAndID(_ payload: Data) -> (name: String, id: Double) {
        var offset = 0
        guard payload.count > 3, payload[offset] == 0x02 else { return ("", 0) }
        offset += 1
        let len = Int(payload[offset]) << 8 | Int(payload[offset+1])
        offset += 2
        guard offset + len <= payload.count else { return ("", 0) }
        let name = String(data: payload.subdata(in: offset..<offset+len), encoding: .utf8) ?? ""
        offset += len
        guard offset + 9 <= payload.count, payload[offset] == 0x00 else { return (name, 0) }
        offset += 1
        var bits: UInt64 = 0
        for i in 0..<8 { bits = (bits << 8) | UInt64(payload[offset + i]) }
        let id = Double(bitPattern: bits)
        return (name, id)
    }

    private func parseStreamIDFromResult(_ payload: Data) -> UInt32 {
        // _result, invokeID, null, streamID(number)
        // Skip "connect" string + number + null/object + null → find last number
        var offset = 0
        var lastNumber: Double = 1
        while offset < payload.count {
            let type = payload[offset]; offset += 1
            switch type {
            case 0x00:  // number
                guard offset + 8 <= payload.count else { return UInt32(lastNumber) }
                var bits: UInt64 = 0
                for i in 0..<8 { bits = (bits << 8) | UInt64(payload[offset + i]) }
                lastNumber = Double(bitPattern: bits)
                offset += 8
            case 0x02:  // string
                guard offset + 2 <= payload.count else { return UInt32(lastNumber) }
                let len = Int(payload[offset]) << 8 | Int(payload[offset+1])
                offset += 2 + len
            case 0x05:  // null
                break
            case 0x03:  // object — scan to end marker
                while offset + 2 < payload.count {
                    if payload[offset] == 0 && payload[offset+1] == 0 && payload[offset+2] == 0x09 {
                        offset += 3; break
                    }
                    let klen = Int(payload[offset]) << 8 | Int(payload[offset+1])
                    offset += 2 + klen
                    // skip value (best-effort, just advance 1 to avoid loop)
                    offset += 1
                }
            default:
                offset += 1
            }
        }
        return UInt32(lastNumber)
    }

    // MARK: - FLV message builders

    private func buildFLVVideoMessage(isKeyFrame: Bool, isSequenceHeader: Bool,
                                     cts: Int32, payload: Data, timestamp: UInt32) -> Data {
        var msg = Data()
        // Frame type + codec: 0x17 = keyframe+AVC, 0x27 = inter+AVC
        msg.append(isKeyFrame ? 0x17 : 0x27)
        // AVC packet type: 0=sequence header, 1=NALU
        msg.append(isSequenceHeader ? 0x00 : 0x01)
        // Composition time offset (signed 24-bit, big-endian, ms)
        let ctsU = UInt32(bitPattern: cts)
        msg.append(UInt8((ctsU >> 16) & 0xFF))
        msg.append(UInt8((ctsU >> 8)  & 0xFF))
        msg.append(UInt8(ctsU & 0xFF))
        msg.append(payload)
        return msg
    }

    private func buildAVCSequenceHeader(sps: Data, pps: Data) -> Data {
        var r = Data()
        r.append(0x01)              // configurationVersion
        r.append(sps.count >= 4 ? sps[1] : 0x42)  // AVCProfileIndication
        r.append(sps.count >= 4 ? sps[2] : 0xC0)  // profile_compatibility
        r.append(sps.count >= 4 ? sps[3] : 0x28)  // AVCLevelIndication
        r.append(0xFF)              // lengthSizeMinusOne = 3 (4-byte lengths)
        r.append(0xE1)              // numSequenceParameterSets = 1
        r.append(UInt8((sps.count >> 8) & 0xFF))
        r.append(UInt8(sps.count & 0xFF))
        r.append(sps)
        r.append(0x01)              // numPictureParameterSets = 1
        r.append(UInt8((pps.count >> 8) & 0xFF))
        r.append(UInt8(pps.count & 0xFF))
        r.append(pps)
        return r
    }

    // MARK: - H.264 Annex-B parsing

    /// Parse Annex-B stream into individual NAL unit Data objects (no start code).
    private func parseAnnexBNALUs(_ data: Data) -> [Data] {
        var nalus: [Data] = []
        var i = data.startIndex
        var nalStart: Data.Index? = nil

        func flush(to end: Data.Index) {
            if let start = nalStart, start < end {
                nalus.append(Data(data[start..<end]))
            }
        }

        while i < data.endIndex {
            // Look for 00 00 01 or 00 00 00 01
            if data[i] == 0x00,
               i + 2 < data.endIndex, data[data.index(i, offsetBy: 1)] == 0x00,
               data[data.index(i, offsetBy: 2)] == 0x01 {
                flush(to: i)
                i = data.index(i, offsetBy: 3)
                nalStart = i
            } else if data[i] == 0x00,
                      i + 3 < data.endIndex,
                      data[data.index(i, offsetBy: 1)] == 0x00,
                      data[data.index(i, offsetBy: 2)] == 0x00,
                      data[data.index(i, offsetBy: 3)] == 0x01 {
                flush(to: i)
                i = data.index(i, offsetBy: 4)
                nalStart = i
            } else {
                i = data.index(after: i)
            }
        }
        flush(to: data.endIndex)
        return nalus.filter { !$0.isEmpty }
    }

    /// Convert NAL units to AVCC (4-byte big-endian length prefix per NALU).
    private func nalUsToAVCC(_ nalus: [Data]) -> Data {
        var result = Data()
        for nalu in nalus {
            let len = nalu.count
            result.append(UInt8((len >> 24) & 0xFF))
            result.append(UInt8((len >> 16) & 0xFF))
            result.append(UInt8((len >> 8)  & 0xFF))
            result.append(UInt8(len & 0xFF))
            result.append(nalu)
        }
        return result
    }

    // MARK: - AAC helpers

    /// Extract AudioSpecificConfig from ADTS header for AAC-LC.
    /// Returns 2-byte ASC for the sample rate/channel config in the ADTS header.
    private func audioSpecificConfigFromADTS(_ adts: Data) -> Data? {
        guard adts.count >= 7 else { return nil }
        // ADTS byte 2: profile(2) | samplingFreqIdx(4) | channelConfig(1 of 3)
        // ADTS byte 3: channelConfig(2 of 3) | ...
        let b2 = adts[2]
        let b3 = adts[3]
        let profile         = (b2 >> 6) + 1           // MPEG-4 objectType = profile + 1
        let samplingFreqIdx = (b2 >> 2) & 0x0F
        let channelConfig   = ((b2 & 0x01) << 2) | ((b3 >> 6) & 0x03)
        // AudioSpecificConfig: objectType(5) | samplingFreqIdx(4) | channelConfig(4) | frameLengthFlag(1) | dependsOnCoreCoder(1) | extensionFlag(1)
        let word = (UInt16(profile) << 11) | (UInt16(samplingFreqIdx) << 7) | (UInt16(channelConfig) << 3)
        return Data([UInt8(word >> 8), UInt8(word & 0xFF)])
    }

    // MARK: - Timestamp

    private func toRTMPTimestamp(_ pts: CMTime) -> UInt32 {
        let ticks = CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value
        if startPTS < 0 { startPTS = ticks }
        let relative = max(0, ticks - startPTS)
        // 90kHz → ms: divide by 90
        return UInt32(relative / 90) & 0xFFFFFFFF
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
