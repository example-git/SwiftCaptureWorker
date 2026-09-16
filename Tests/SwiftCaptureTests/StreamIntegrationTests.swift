/// StreamIntegrationTests.swift
///
/// Black-box integration tests for SwiftCaptureWorker.
///
/// Two test suites:
///   1. FileOutputTests  – capture video+audio for a few seconds, mux to an
///      MP4 with ffmpeg, then verify stream properties with ffprobe.
///   2. LiveStreamTests  – connect to a live SCAP stream, verify CONFIG packet
///      fields are well-formed, and assert per-stream PTS monotonicity.
///
/// Requirements:
///   • The release binary must exist at the path returned by workerBinaryPath().
///   • ffmpeg and ffprobe must be available (Homebrew: `brew install ffmpeg`).
///   • Screen Recording permission must be granted to the test runner process.
///
/// Run:
///   swift test --filter StreamIntegrationTests

import XCTest
import Foundation
import Darwin

// ---------------------------------------------------------------------------
// MARK: – SCAP wire format constants
// ---------------------------------------------------------------------------

let scapMagic      = Data([0x53, 0x43, 0x41, 0x50]) // "SCAP"
let scapHeaderSize = 24

enum ScapType: UInt8 {
    case configuration = 1
    case sample        = 2
    case endOfStream   = 3
    case error         = 4
}

enum ScapStream: UInt8 {
    case video        = 0
    case systemAudio  = 1
    case inputAudio   = 2
    case processAudio = 3
}

struct ScapPacket {
    let type:     ScapType
    let flags:    UInt16
    let ptsNs:    UInt64
    let streamID: UInt8
    let payload:  Data
}

// ---------------------------------------------------------------------------
// MARK: – Helpers
// ---------------------------------------------------------------------------

/// Returns the path of the release binary, preferring a freshly-built one.
func workerBinaryPath() throws -> String {
    // Accept an explicit override from the environment (useful in CI).
    if let env = ProcessInfo.processInfo.environment["SCAP_WORKER"],
       FileManager.default.fileExists(atPath: env) { return env }

    // #filePath resolves at compile time to the absolute source path:
    //   …/watch-client/SwiftCapture/Tests/SwiftCaptureTests/StreamIntegrationTests.swift
    // Two deletions → …/watch-client/SwiftCapture/Tests/
    // One more     → …/watch-client/SwiftCapture/   (package root, has .build/ inside)
    let pkgRoot  = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SwiftCaptureTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // SwiftCapture/  ← .build lives here
    let repoRoot = pkgRoot.deletingLastPathComponent() // watch-client/

    let candidates: [URL] = [
        pkgRoot.appendingPathComponent(".build/arm64-apple-macosx/release/SwiftCaptureWorker"),
        pkgRoot.appendingPathComponent(".build/release/SwiftCaptureWorker"),
        repoRoot.appendingPathComponent("resources/swiftcapture/mac/SwiftCaptureWorker"),
        // Packaged build: worker sits next to the test binary.
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("SwiftCaptureWorker"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        return url.path
    }
    throw XCTestError(.failureWhileWaiting,
        userInfo: [NSLocalizedDescriptionKey:
            "SwiftCaptureWorker binary not found. Build with `swift build -c release` first.\nChecked: \(candidates.map(\.path).joined(separator: "\n  "))"])
}

func toolPath(_ name: String) throws -> String {
    let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
    for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
    throw XCTestError(.failureWhileWaiting,
        userInfo: [NSLocalizedDescriptionKey: "\(name) not found. Install with: brew install ffmpeg"])
}

// ---------------------------------------------------------------------------
// MARK: – SCAP stream parser
// ---------------------------------------------------------------------------

/// Accumulates raw bytes from the IPC socket and vends complete ScapPackets.
final class ScapParser {
    private var buffer = Data()

    func push(_ chunk: Data) { buffer.append(chunk) }

    /// Returns and removes all complete packets from the internal buffer.
    func drain() -> [ScapPacket] {
        var packets: [ScapPacket] = []
        while buffer.count >= scapHeaderSize {
            // Work with a flat byte array so subscript indices are always 0-based.
            let hdr = Array(buffer.prefix(scapHeaderSize))
            guard hdr[0] == 0x53, hdr[1] == 0x43, hdr[2] == 0x41, hdr[3] == 0x50 else {
                buffer.removeFirst(); continue   // re-sync on magic
            }
            let typeRaw  = hdr[5]
            let flags    = UInt16(hdr[6]) << 8 | UInt16(hdr[7])
            let ptsNs    = UInt64(hdr[8])  << 56 | UInt64(hdr[9])  << 48 |
                           UInt64(hdr[10]) << 40 | UInt64(hdr[11]) << 32 |
                           UInt64(hdr[12]) << 24 | UInt64(hdr[13]) << 16 |
                           UInt64(hdr[14]) << 8  | UInt64(hdr[15])
            let length   = Int(UInt32(hdr[16]) << 24 | UInt32(hdr[17]) << 16 |
                               UInt32(hdr[18]) << 8  | UInt32(hdr[19]))
            let streamID = hdr[20]
            let total    = scapHeaderSize + length
            guard buffer.count >= total else { break }
            let payload  = Data(buffer.prefix(total).dropFirst(scapHeaderSize))
            buffer.removeFirst(total)
            guard let type = ScapType(rawValue: typeRaw) else { continue }
            packets.append(ScapPacket(type: type, flags: flags, ptsNs: ptsNs,
                                      streamID: streamID, payload: payload))
        }
        return packets
    }
}

// ---------------------------------------------------------------------------
// MARK: – Worker process wrapper
// ---------------------------------------------------------------------------

final class WorkerSession {
    let process:  Process
    let port:     Int
    private let serverFD: Int32
    private let parser   = ScapParser()
    private let ioQueue  = DispatchQueue(label: "scap.test.io")
    private let lock     = NSLock()

    private(set) var allPackets: [ScapPacket] = []
    var onPacket: ((ScapPacket) -> Void)?

    init(workerPath: String, extraArgs: [String] = []) throws {
        // --- Plain BSD TCP listen socket on a random port ---
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "socket() failed errno=\(errno)"])
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = 0          // let OS pick
        addr.sin_addr.s_addr = INADDR_ANY
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "bind() failed errno=\(errno)"])
        }
        guard Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "listen() failed errno=\(errno)"])
        }

        // Read back the assigned port.
        var boundAddr = sockaddr_in()
        var boundLen  = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = getsockname(fd, $0, &boundLen)
            }
        }
        self.port     = Int(UInt16(bigEndian: boundAddr.sin_port))
        self.serverFD = fd

        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: workerPath)
        proc.arguments      = ["--ipc-port", String(self.port)] + extraArgs
        proc.standardInput  = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError  = FileHandle.nullDevice
        self.process = proc
    }

    func start() throws {
        try process.run()
        // Accept the single worker connection on a background thread.
        ioQueue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        Darwin.close(serverFD)
    }

    /// Block until `condition()` is true or `timeout` seconds elapse.
    func wait(timeout: TimeInterval = 15, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    func snapshotPackets() -> [ScapPacket] {
        lock.lock(); defer { lock.unlock() }
        return allPackets
    }

    // MARK: – Private networking

    private func acceptLoop() {
        // Block until the worker connects, then read until EOF.
        let clientFD = Darwin.accept(serverFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { Darwin.close(clientFD) }

        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(clientFD, &buf, buf.count)
            if n <= 0 { break }
            let chunk = Data(buf[0..<n])
            parser.push(chunk)
            let newPackets = parser.drain()
            lock.lock()
            allPackets.append(contentsOf: newPackets)
            lock.unlock()
            for p in newPackets { onPacket?(p) }
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: – Process runner helper
// ---------------------------------------------------------------------------

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

func runProcess(_ executable: String, args: [String]) throws -> ProcessResult {
    let proc     = Process()
    let outPipe  = Pipe()
    let errPipe  = Pipe()
    proc.executableURL  = URL(fileURLWithPath: executable)
    proc.arguments      = args
    proc.standardOutput = outPipe
    proc.standardError  = errPipe
    try proc.run()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return ProcessResult(
        status: proc.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
    )
}

// ---------------------------------------------------------------------------
// MARK: – Test 1: File output + ffprobe validation
// ---------------------------------------------------------------------------

final class FileOutputTests: XCTestCase {

    /// Runs the worker for 4 s capturing video + system audio, muxes the raw
    /// SCAP streams into an MP4 via ffmpeg, then uses ffprobe to verify:
    ///   • One H.264 video stream (codec=h264, Annex-B)
    ///   • One AAC audio stream (transcoded from the raw PCM)
    ///   • Duration ≥ 2.5 s and ≤ 7.0 s
    ///   • Video framerate ≥ 25 fps
    ///   • Output dimensions match the requested 640×360
    ///   • Audio sample rate = 48000 Hz, channels ≥ 1
    func testVideoAndAudioMuxedToFile() throws {
        let worker  = try workerBinaryPath()
        let ffmpeg  = try toolPath("ffmpeg")
        let ffprobe = try toolPath("ffprobe")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scap_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let videoRaw  = tmp.appendingPathComponent("video.h264")
        let audioRaw  = tmp.appendingPathComponent("audio.f32le")
        let outputMp4 = tmp.appendingPathComponent("output.mp4")

        // --- Capture ---
        let session = try WorkerSession(
            workerPath: worker,
            extraArgs: [
                "--fps",                  "30",
                "--output-width",         "640",
                "--output-height",        "360",
                "--duration-ms",          "4000",
                "--capture-system-audio",
            ])

        // All mutable state touched by onPacket must be read back after the wait
        // via snapshotPackets() to avoid data races with the IO queue.
        try session.start()
        let cleanExit = session.wait(timeout: 12) {
            let pkts = session.snapshotPackets()
            let sawVideoEOS = pkts.contains { $0.type == .endOfStream && $0.streamID == ScapStream.video.rawValue }
            let sawAudioEOS = pkts.contains { $0.type == .endOfStream && $0.streamID == ScapStream.systemAudio.rawValue }
            return sawVideoEOS && sawAudioEOS
        }
        session.stop()

        // Build local variables from the thread-safe snapshot.
        let allPkts = session.snapshotPackets()
        var videoConfig: [String: Any]?
        var audioConfig: [String: Any]?
        var videoPayload = Data()
        var audioPayload = Data()
        for pkt in allPkts {
            switch (pkt.type, ScapStream(rawValue: pkt.streamID)) {
            case (.configuration, .some(.video)):
                videoConfig = try? JSONSerialization.jsonObject(with: pkt.payload) as? [String: Any]
            case (.configuration, .some(.systemAudio)):
                audioConfig = try? JSONSerialization.jsonObject(with: pkt.payload) as? [String: Any]
            case (.sample, .some(.video)):
                videoPayload.append(pkt.payload)
            case (.sample, .some(.systemAudio)):
                audioPayload.append(pkt.payload)
            default:
                break
            }
        }
        let sawVideoEOS = allPkts.contains { $0.type == .endOfStream && $0.streamID == ScapStream.video.rawValue }
        let sawAudioEOS = allPkts.contains { $0.type == .endOfStream && $0.streamID == ScapStream.systemAudio.rawValue }

        // --- Verify both streams delivered data ---
        XCTAssertTrue(cleanExit,
            "Worker did not send EOS for both streams within the timeout. " +
            "videoEOS=\(sawVideoEOS) audioEOS=\(sawAudioEOS)")

        guard let vcfg = videoConfig else { XCTFail("No video CONFIG packet received"); return }
        guard let acfg = audioConfig else { XCTFail("No audio CONFIG packet received"); return }

        XCTAssertEqual(vcfg["codec"]  as? String, "h264",   "Video codec must be h264")
        XCTAssertEqual(vcfg["format"] as? String, "annexb", "Video format must be annexb")
        XCTAssertFalse(videoPayload.isEmpty, "No video SAMPLE data received")
        XCTAssertEqual(acfg["codec"]        as? String, "lpcm", "Audio codec must be lpcm")
        XCTAssertEqual(acfg["isInterleaved"] as? Bool,  true,   "Audio must be interleaved")
        // Audio payload may be empty if no sound is playing during the test; note it but
        // don't fail here — the mux step handles the no-audio case gracefully.
        let hasAudio = !audioPayload.isEmpty
        if !hasAudio {
            print("⚠️  Warning: no audio SAMPLE data received — system audio may be silent")
        }

        let sampleRate: Double
        if let r = acfg["sampleRate"] as? Double   { sampleRate = r }
        else if let r = acfg["sampleRate"] as? Int { sampleRate = Double(r) }
        else                                       { sampleRate = 48000 }
        let actualRate = Int(sampleRate)
        let actualChannels: Int
        if let c = acfg["channels"] as? Int         { actualChannels = c }
        else if let c = acfg["channels"] as? Double { actualChannels = Int(c) }
        else                                        { actualChannels = 2 }

        // --- Write raw streams to disk ---
        try videoPayload.write(to: videoRaw)
        if hasAudio { try audioPayload.write(to: audioRaw) }

        // --- Mux with ffmpeg ---
        // Include audio only when we actually captured some samples.
        var muxArgs = [
            "-y",
            "-framerate", "\(vcfg["fps"] as? Int ?? 30)",
            "-f",         "h264",
            "-i",         videoRaw.path,
        ]
        if hasAudio {
            muxArgs += [
                "-f",    "f32le",
                "-ar",   "\(actualRate)",
                "-ac",   "\(actualChannels)",
                "-i",    audioRaw.path,
                "-c:v",  "copy",
                "-c:a",  "aac",
            ]
        } else {
            muxArgs += ["-c:v", "copy"]
        }
        muxArgs.append(outputMp4.path)

        let muxResult = try runProcess(ffmpeg, args: muxArgs)
        XCTAssertEqual(muxResult.status, 0,
            "ffmpeg mux failed (exit \(muxResult.status)):\n\(muxResult.stderr)")
        guard muxResult.status == 0 else { return }

        // --- ffprobe ---
        let probeResult = try runProcess(ffprobe, args: [
            "-v",            "quiet",
            "-print_format", "json",
            "-show_streams",
            "-show_format",
            outputMp4.path,
        ])
        XCTAssertEqual(probeResult.status, 0,
            "ffprobe failed (exit \(probeResult.status)):\n\(probeResult.stderr)")
        guard probeResult.status == 0 else { return }

        guard
            let probeData = probeResult.stdout.data(using: String.Encoding.utf8),
            let probe     = try? JSONSerialization.jsonObject(with: probeData) as? [String: Any],
            let streams   = probe["streams"] as? [[String: Any]]
        else {
            XCTFail("Could not parse ffprobe JSON:\n\(probeResult.stdout)"); return
        }

        let videoStreams = streams.filter { ($0["codec_type"] as? String) == "video" }
        let audioStreams = streams.filter { ($0["codec_type"] as? String) == "audio" }

        XCTAssertEqual(videoStreams.count, 1, "Expected exactly 1 video stream in output file")
        XCTAssertEqual(audioStreams.count, 1, "Expected exactly 1 audio stream in output file")

        if let vs = videoStreams.first {
            XCTAssertEqual(vs["codec_name"] as? String, "h264",
                "Output video codec must be h264")
            XCTAssertEqual(vs["width"]  as? Int, 640, "Output width must be 640")
            XCTAssertEqual(vs["height"] as? Int, 360, "Output height must be 360")

            if let rateStr = vs["r_frame_rate"] as? String {
                let parts = rateStr.split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 {
                    XCTAssertGreaterThanOrEqual(parts[0] / parts[1], 25.0,
                        "Video framerate must be ≥ 25 fps, got \(rateStr)")
                }
            }
        }

        if let as_ = audioStreams.first {
            let outRate = Int(as_["sample_rate"] as? String ?? "0") ?? 0
            XCTAssertEqual(outRate, 48000, "Output audio sample rate must be 48 000 Hz")
            let outCh = as_["channels"] as? Int ?? 0
            XCTAssertGreaterThanOrEqual(outCh, 1, "Output audio channels must be ≥ 1")
        }

        if let fmt    = probe["format"] as? [String: Any],
           let durStr = fmt["duration"] as? String,
           let dur    = Double(durStr) {
            XCTAssertGreaterThanOrEqual(dur, 2.5,
                "Output file duration \(String(format: "%.2f", dur))s shorter than expected (≥ 2.5 s)")
            XCTAssertLessThanOrEqual(dur, 7.0,
                "Output file duration \(String(format: "%.2f", dur))s longer than expected (≤ 7.0 s)")
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: – Test 2: Live stream format + timestamp validation
// ---------------------------------------------------------------------------

final class LiveStreamTests: XCTestCase {

    /// Connects to a live SCAP stream (video + system audio) and verifies:
    ///   • Video CONFIG has: codec="h264", format="annexb", fps, width, height,
    ///     bitRate, gstreamerCaps (byte-stream / alignment=au), parameterSets
    ///     (2 non-empty valid-base64 entries).
    ///   • Audio CONFIG has: codec="lpcm", isInterleaved=true, sampleRate>0,
    ///     channels 1–8, bitsPerChannel in {8,16,24,32}, bytesPerFrame correct,
    ///     gstreamerCaps (layout=interleaved, rate=, channels=) with rate matching
    ///     the sampleRate field.
    ///   • At least 60 video SAMPLEs and 60 audio SAMPLEs arrive.
    ///   • Per-stream PTS values are monotonically non-decreasing.
    ///   • The very first video SAMPLE has the key-frame flag (bit 0) set.
    ///   • No ERROR packets arrive.
    func testLiveStreamFormatAndTimestamps() throws {
        let worker     = try workerBinaryPath()
        let minSamples = 60   // ~2 s at 30 fps

        let session = try WorkerSession(
            workerPath: worker,
            extraArgs: [
                "--fps",                  "30",
                "--output-width",         "320",
                "--output-height",        "180",
                "--capture-system-audio",
            ])

        try session.start()
        let gotEnough = session.wait(timeout: 15) {
            let pkts = session.snapshotPackets()
            let videoSamples = pkts.filter { $0.type == .sample && $0.streamID == ScapStream.video.rawValue }.count
            let audioSamples = pkts.filter { $0.type == .sample && $0.streamID == ScapStream.systemAudio.rawValue }.count
            return videoSamples >= minSamples && audioSamples >= minSamples
        }
        session.stop()

        // Derive all assertions from the thread-safe snapshot.
        let allPkts = session.snapshotPackets()

        let videoSamples = allPkts.filter { $0.type == .sample && $0.streamID == ScapStream.video.rawValue }
        let audioSamples = allPkts.filter { $0.type == .sample && $0.streamID == ScapStream.systemAudio.rawValue }
        let errorMessages = allPkts.filter { $0.type == .error }
            .compactMap { String(data: $0.payload, encoding: .utf8) }

        var videoConfig: [String: Any]?
        var audioConfig: [String: Any]?
        for pkt in allPkts where pkt.type == .configuration {
            guard let json = try? JSONSerialization.jsonObject(with: pkt.payload) as? [String: Any] else { continue }
            if pkt.streamID == ScapStream.video.rawValue       { videoConfig = json }
            if pkt.streamID == ScapStream.systemAudio.rawValue { audioConfig = json }
        }

        // PTS monotonicity check
        var videoMonotone = true
        var lastVideoPTS: UInt64 = 0
        for pkt in videoSamples {
            if pkt.ptsNs < lastVideoPTS { videoMonotone = false }
            lastVideoPTS = pkt.ptsNs
        }
        var audioMonotone = true
        var lastAudioPTS: UInt64 = 0
        for pkt in audioSamples {
            if pkt.ptsNs < lastAudioPTS { audioMonotone = false }
            lastAudioPTS = pkt.ptsNs
        }
        let firstVideoIsKeyFrame = videoSamples.first.map { ($0.flags & 0x01) != 0 } ?? false

        // --- Error guard ---
        XCTAssertTrue(errorMessages.isEmpty,
            "Worker emitted ERROR packet(s): \(errorMessages.joined(separator: "; "))")

        // --- Sample volume ---
        XCTAssertTrue(gotEnough,
            "Did not receive \(minSamples) samples from both streams within timeout. " +
            "video=\(videoSamples.count) audio=\(audioSamples.count)")

        // --- Video CONFIG ---
        guard let vcfg = videoConfig else { XCTFail("No video CONFIG received"); return }

        XCTAssertEqual(vcfg["codec"]  as? String, "h264",   "video codec must be h264")
        XCTAssertEqual(vcfg["format"] as? String, "annexb", "video format must be annexb")
        XCTAssertNotNil(vcfg["fps"],     "video CONFIG must include fps")
        XCTAssertNotNil(vcfg["width"],   "video CONFIG must include width")
        XCTAssertNotNil(vcfg["height"],  "video CONFIG must include height")
        XCTAssertNotNil(vcfg["bitRate"], "video CONFIG must include bitRate")

        if let caps = vcfg["gstreamerCaps"] as? String {
            XCTAssertTrue(caps.hasPrefix("video/x-h264"),
                "video gstreamerCaps must start with video/x-h264, got: \(caps)")
            XCTAssertTrue(caps.contains("stream-format=byte-stream"),
                "video gstreamerCaps must contain stream-format=byte-stream")
            XCTAssertTrue(caps.contains("alignment=au"),
                "video gstreamerCaps must contain alignment=au")
        } else {
            XCTFail("video CONFIG must include gstreamerCaps string")
        }

        if let paramSets = vcfg["parameterSets"] as? [String] {
            XCTAssertEqual(paramSets.count, 2,
                "video CONFIG must have exactly 2 parameterSets (SPS + PPS)")
            for (i, ps) in paramSets.enumerated() {
                XCTAssertFalse(ps.isEmpty, "parameterSets[\(i)] must not be empty")
                XCTAssertNotNil(Data(base64Encoded: ps),
                    "parameterSets[\(i)] must be valid base64")
            }
        } else {
            XCTFail("video CONFIG must include parameterSets array")
        }

        // --- Audio CONFIG ---
        guard let acfg = audioConfig else { XCTFail("No audio CONFIG received"); return }

        XCTAssertEqual(acfg["codec"] as? String, "lpcm", "audio codec must be lpcm")
        XCTAssertEqual(acfg["isInterleaved"] as? Bool, true, "audio isInterleaved must be true")

        let sampleRate: Double
        if let r = acfg["sampleRate"] as? Double      { sampleRate = r }
        else if let r = acfg["sampleRate"] as? Int    { sampleRate = Double(r) }
        else                                          { sampleRate = 0 }
        XCTAssertGreaterThan(sampleRate, 0, "audio sampleRate must be > 0")

        let channels: Int
        if let c = acfg["channels"] as? Int         { channels = c }
        else if let c = acfg["channels"] as? Double { channels = Int(c) }
        else                                        { channels = 0 }
        XCTAssertGreaterThan(channels, 0,  "audio channels must be > 0")
        XCTAssertLessThanOrEqual(channels, 8, "audio channels unexpectedly large: \(channels)")

        let bitsPerChannel: Int
        if let b = acfg["bitsPerChannel"] as? Int         { bitsPerChannel = b }
        else if let b = acfg["bitsPerChannel"] as? Double { bitsPerChannel = Int(b) }
        else                                              { bitsPerChannel = 0 }
        XCTAssertTrue([8, 16, 24, 32].contains(bitsPerChannel),
            "audio bitsPerChannel must be 8/16/24/32, got \(bitsPerChannel)")

        let bytesPerFrame: Int
        if let b = acfg["bytesPerFrame"] as? Int         { bytesPerFrame = b }
        else if let b = acfg["bytesPerFrame"] as? Double { bytesPerFrame = Int(b) }
        else                                             { bytesPerFrame = 0 }
        let expectedBPF = (bitsPerChannel / 8) * channels
        XCTAssertEqual(bytesPerFrame, expectedBPF,
            "bytesPerFrame (\(bytesPerFrame)) must equal bitsPerChannel/8 × channels (\(expectedBPF))")

        if let caps = acfg["gstreamerCaps"] as? String {
            XCTAssertTrue(caps.hasPrefix("audio/x-raw"),
                "audio gstreamerCaps must start with audio/x-raw, got: \(caps)")
            XCTAssertTrue(caps.contains("layout=interleaved"),
                "audio gstreamerCaps must contain layout=interleaved")
            XCTAssertTrue(caps.contains("rate="),
                "audio gstreamerCaps must contain rate=")
            XCTAssertTrue(caps.contains("channels="),
                "audio gstreamerCaps must contain channels=")

            // The rate= token must match the sampleRate field.
            let tokens = caps.components(separatedBy: ",")
            if let rateToken = tokens.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("rate=") }),
               let rateStr   = rateToken.components(separatedBy: "=").last,
               let capsRate  = Double(rateStr.trimmingCharacters(in: .whitespaces)) {
                XCTAssertEqual(capsRate, sampleRate, accuracy: 1.0,
                    "gstreamerCaps rate=\(capsRate) does not match sampleRate=\(sampleRate)")
            }
        } else {
            XCTFail("audio CONFIG must include gstreamerCaps string")
        }

        // --- Timestamp monotonicity ---
        XCTAssertTrue(videoMonotone, "Video PTS regressed (non-monotone) during capture")
        XCTAssertTrue(audioMonotone, "Audio PTS regressed (non-monotone) during capture")

        // --- PTS sanity ---
        XCTAssertGreaterThan(lastVideoPTS, 0,
            "Last video PTS is zero — host-time conversion is broken")
        XCTAssertGreaterThan(lastAudioPTS, 0,
            "Last audio PTS is zero — host-time conversion is broken")

        // --- First frame must be a key frame ---
        XCTAssertTrue(firstVideoIsKeyFrame,
            "First video SAMPLE must have the key-frame flag (IDR)")
    }
}
