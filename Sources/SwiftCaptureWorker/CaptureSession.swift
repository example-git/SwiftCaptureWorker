import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Dispatch
import Darwin

// MARK: - Leveled logger

private func log(_ level: String, _ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(ts)] [\(level)] \(message)\n".data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: data)
}
private func info(_ msg: String)  { log("INFO ", msg) }
private func warn(_ msg: String)  { log("WARN ", msg) }
private func error(_ msg: String) { log("ERROR", msg) }
private func debug(_ msg: String) { log("DEBUG", msg) }

// MARK: - CaptureSession

@available(macOS 13.0, *)
final class CaptureSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private final class WorkerStreamOutput: NSObject, SCStreamOutput {
        private weak var owner: CaptureSession?

        init(owner: CaptureSession) {
            self.owner = owner
            super.init()
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
            autoreleasepool {
                owner?.handleStreamOutput(sampleBuffer, outputType: outputType)
            }
        }
    }

    /// Delegate that receives webcam video frames from AVCaptureVideoDataOutput.
    private final class WebcamStreamOutput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        private weak var owner: CaptureSession?

        init(owner: CaptureSession) {
            self.owner = owner
            super.init()
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            autoreleasepool {
                owner?.handleWebcamFrame(sampleBuffer)
            }
        }
    }

    private let configuration: WorkerConfiguration
    private let videoWriter: PacketStreamWriter
    private let systemAudioWriter: PacketStreamWriter?
    private let inputAudioWriter: PacketStreamWriter?
    private let processAudioWriter: PacketStreamWriter?
    private let webcamVideoWriter: PacketStreamWriter?
    private let ipcTransport: IPCTransport?
    private var stopProcessTap: (() -> Void)?
    private let videoOutputQueue = DispatchQueue(label: "swiftcapture.worker.video", qos: .userInteractive)
    private let encoderInputQueue = DispatchQueue(label: "swiftcapture.worker.encoderinput", qos: .userInteractive)
    private let encoderFlushQueue = DispatchQueue(label: "swiftcapture.worker.encoderflush", qos: .utility)
    private let systemAudioOutputQueue = DispatchQueue(label: "swiftcapture.worker.systemaudio", qos: .userInteractive)
    private let inputAudioOutputQueue = DispatchQueue(label: "swiftcapture.worker.inputaudio", qos: .userInteractive)
    private let webcamOutputQueue = DispatchQueue(label: "swiftcapture.worker.webcam", qos: .userInteractive)
    private let webcamEncoderInputQueue = DispatchQueue(label: "swiftcapture.worker.webcamencoderinput", qos: .userInteractive)

    private lazy var systemAudioStream = systemAudioWriter.map { PCMStreamSource(writer: $0) }
    private lazy var inputAudioStream = inputAudioWriter.map { PCMStreamSource(writer: $0) }

    private var videoEncoder: H264Encoder?
    /// Keyed per logical stream lane (screenSystemAudio / micAudio). Each
    /// encoder owns its own converter, anchor and frame counter so concurrent
    /// audio sources never collide.
    private var audioEncoders: [StreamID: AACEncoder] = [:]
    private let audioEncoderInputQueue = DispatchQueue(label: "swiftcapture.worker.audioencodinput", qos: .userInteractive)
    private var shareableContent: SCShareableContent?
    private var contentFilter: SCContentFilter?
    private var streamConfiguration: SCStreamConfiguration?
    private var stream: SCStream?
    private var streamOutputDelegate: WorkerStreamOutput?
    private var inputCaptureSession: AVCaptureSession?
    private var webcamEncoder: H264Encoder?
    private var webcamCaptureSession: AVCaptureSession?
    private var webcamStreamDelegate: WebcamStreamOutput?
    private var firstWebcamFrameSeen = false
    private var webcamFramesReceived: Int = 0
    private var webcamFramesEncoded: Int = 0

    // Cached video configs for resending to late-joining IPC clients
    private var cachedVideoConfig: VideoStreamConfiguration?
    private var cachedWebcamVideoConfig: VideoStreamConfiguration?

    private var premuxWriter: PremuxWriter?
    private var mpegTSMuxer: MPEGTSMuxer?
    private var rtmpPublisher: RTMPPublisher?

    // MARK: - Sync coordination
    /// Coordinator that normalises every stream's PTS onto a shared host-clock
    /// timeline. Created lazily when any encoder path needs it. `nil` in pure
    /// pass-through modes that never go through the muxer.
    private var syncCoordinator: SyncCoordinator?
    /// Handles obtained from `syncCoordinator.registerStream`. Captured by the
    /// various encoder/muxer closures.
    private var screenVideoHandle: StreamHandle?
    private var webcamVideoHandle: StreamHandle?
    private var screenSystemAudioHandle: StreamHandle?
    private var micAudioHandle: StreamHandle?
    private var processAudioHandle: StreamHandle?
    /// Periodic timer that re-measures cross-clock drift every ~2s.
    private var driftMeasurementTask: Task<Void, Never>?

    private let stopLock = NSLock()
    private var stopRequested = false
    private var streamFailed = false
    private var framesReceived: Int = 0
    private var framesSubmitted: Int = 0
    private var framesEncoded: Int = 0
    private var firstVideoFrameSeen = false
    private var firstAudioPacketSeen = false
    private var deferredInputAudioUntilFirstWebcamFrameLogged = false
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var durationStopTask: Task<Void, Never>?
    private var startupTimeoutTask: Task<Void, Never>?

    init(configuration: WorkerConfiguration) throws {
        self.configuration = configuration

        // In premux / dump / SRT / RTMP mode: media goes to the native sink, not IPC/FD writers.
        // If an IPC port is also provided (Electron always passes --ipc-port), use it for SCAP
        // control packets only (video/webcam config, EOS, errors) so waitForReady resolves.
        // Audio writers stay nil — audio goes straight to the RTMP/SRT/dump sink.
        if configuration.premuxMPEGTS || configuration.dumpOutputPath != nil || configuration.srtUrl != nil || configuration.rtmpUrl != nil {
            if configuration.isIPCMode {
                let transport: IPCTransport
                if let port = configuration.ipcPort {
                    transport = try IPCTransport(tcpPort: port)
                } else if let path = configuration.ipcSocket {
                    transport = try IPCTransport(unixSocketPath: path)
                } else {
                    throw WorkerError.invalidArgument("IPC mode set but neither ipcSocket nor ipcPort configured.")
                }
                self.videoWriter = PacketStreamWriter(ipcTransport: transport, streamID: 0)
                self.webcamVideoWriter = configuration.captureWebcam
                    ? PacketStreamWriter(ipcTransport: transport, streamID: 4) : nil
                self.ipcTransport = transport
            } else {
                self.videoWriter = PacketStreamWriter(fileDescriptor: 1)
                self.webcamVideoWriter = nil
                self.ipcTransport = nil
            }
            self.systemAudioWriter = nil
            self.inputAudioWriter  = nil
            self.processAudioWriter = nil
        } else if configuration.isIPCMode {
            // IPC mode: all streams share one socket, multiplexed by stream_id.
            let transport: IPCTransport
            if let path = configuration.ipcSocket {
                transport = try IPCTransport(unixSocketPath: path)
            } else if let port = configuration.ipcPort {
                transport = try IPCTransport(tcpPort: port)
            } else {
                throw WorkerError.invalidArgument("IPC mode set but neither ipcSocket nor ipcPort configured.")
            }
            self.videoWriter      = PacketStreamWriter(ipcTransport: transport, streamID: 0)
            self.systemAudioWriter = configuration.captureSystemAudio
                ? PacketStreamWriter(ipcTransport: transport, streamID: 1) : nil
            self.inputAudioWriter  = configuration.captureInputAudio
                ? PacketStreamWriter(ipcTransport: transport, streamID: 2) : nil
            self.processAudioWriter = configuration.captureProcessAudio
                ? PacketStreamWriter(ipcTransport: transport, streamID: 3) : nil
            self.webcamVideoWriter = configuration.captureWebcam
                ? PacketStreamWriter(ipcTransport: transport, streamID: 4) : nil
            self.ipcTransport = transport
        } else {
            // FD mode: each stream has its own pipe file descriptor.
            self.videoWriter      = PacketStreamWriter(fileDescriptor: configuration.videoFD)
            self.systemAudioWriter = configuration.systemAudioFD.map(PacketStreamWriter.init(fileDescriptor:))
            self.inputAudioWriter  = configuration.inputAudioFD.map(PacketStreamWriter.init(fileDescriptor:))
            self.processAudioWriter = configuration.processAudioFD.map(PacketStreamWriter.init(fileDescriptor:))
            self.webcamVideoWriter = configuration.webcamVideoFD.map(PacketStreamWriter.init(fileDescriptor:))
            self.ipcTransport = nil
        }

        super.init()

        // Set up premux writer if --premux flag is set
        if configuration.premuxMPEGTS {
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let outputPath = "/tmp/swiftcapture-premux-\(timestamp).mp4"
            do {
                self.premuxWriter = try PremuxWriter(
                    outputPath: outputPath,
                    width: Int32(configuration.webcamWidth ?? 1920),
                    height: Int32(configuration.webcamHeight ?? 1080),
                    fps: configuration.webcamFPS
                )
                info("Premux mode enabled: outputting to \(outputPath)")
            } catch {
                warn("Failed to initialize premux writer: \(error.localizedDescription)")
            }
        }

        // Set up MPEG-TS muxer if --dump-output flag is set
        if let dumpPath = configuration.dumpOutputPath {
            do {
                self.mpegTSMuxer = try MPEGTSMuxer(outputPath: dumpPath)
                info("MPEG-TS dump mode enabled: outputting to \(dumpPath)")
            } catch {
                warn("Failed to initialize MPEG-TS muxer: \(error.localizedDescription)")
            }
        }

        // Set up MPEG-TS muxer with SRT sink if --srt-url is set
        if let srtUrl = configuration.srtUrl {
            do {
                let sink = try SRTSink(
                    url: srtUrl,
                    latencyMs: configuration.srtLatencyMs,
                    streamIdOverride: configuration.srtStreamId
                )
                sink.onConnectionLost = { [weak self] message in
                    guard let self else { return }
                    self.error("SRT uplink lost: \(message)")
                    self.reportError(message)
                    self.requestStop()
                }
                self.mpegTSMuxer = try MPEGTSMuxer(sink: sink)
                info("Native SRT mode enabled: broadcasting to \(Self.redactURL(srtUrl)) (latency=\(configuration.srtLatencyMs)ms)")
            } catch {
                throw WorkerError.ioFailed("Failed to initialize SRT uplink: \(error.localizedDescription)")
            }
        }

        // Set up RTMP publisher if --rtmp-url is set
        if let rtmpUrl = configuration.rtmpUrl {
            do {
                let publisher = try RTMPPublisher(url: rtmpUrl)
                publisher.onConnectionLost = { [weak self, weak publisher] message in
                    guard let self, let publisher else { return }
                    self.error("RTMP uplink lost: \(message) — reconnecting")
                    if !publisher.isReconnecting {
                        publisher.reconnectInBackground()
                    }
                }
                publisher.onReconnected = { [weak self] in
                    guard let self else { return }
                    self.info("RTMP uplink reconnected — resending stream configuration")
                    self.videoEncoder?.resetConfiguration()
                    self.webcamEncoder?.resetConfiguration()
                }
                self.rtmpPublisher = publisher
                info("Native RTMP mode enabled: broadcasting to \(Self.redactURL(rtmpUrl))")
            } catch {
                throw WorkerError.ioFailed("Failed to initialize RTMP uplink: \(error.localizedDescription)")
            }
        }

        // Always create the sync coordinator. It is cheap and gives encoders a
        // single authoritative host-clock origin + drift-tracked translation.
        // The first sample of ANY registered stream establishes hostOrigin, so
        // cross-stream offsets are preserved (not independently rebased).
        self.syncCoordinator = SyncCoordinator()

        // Wire reconnect callback: when the IPC transport reconnects after a broken pipe,
        // reset all encoder configuration flags so config packets are re-sent to the new
        // consumer. Capture continues uninterrupted — no requestStop().
        ipcTransport?.onReconnected = { [weak self] in
            guard let self else { return }
            self.info("IPC reconnected — resending stream configuration")
            self.videoEncoder?.resetConfiguration()
            self.webcamEncoder?.resetConfiguration()
        }

        let output = configuration.isIPCMode
            ? (configuration.ipcSocket.map { "socket:\($0)" } ?? configuration.ipcPort.map { "tcp:\($0)" } ?? "ipc")
            : "videoFD:\(configuration.videoFD)"
        let videoDesc = configuration.skipVideo ? "no-video" : "screen:\(configuration.screenIndex) fps:\(configuration.fps)"
        info("CaptureSession init — \(videoDesc) " +
             "duration:\(configuration.durationMilliseconds.map { "\($0)ms" } ?? "unlimited") " +
             "\(output) " +
             "systemAudio:\(configuration.captureSystemAudio) " +
             "inputAudio:\(configuration.captureInputAudio) " +
             "processAudio:\(configuration.captureProcessAudio) " +
             "webcam:\(configuration.captureWebcam)")
    }

    /// Returns a `hostDomainPTSFor`-shaped closure routed through the
    /// coordinator for the supplied handle. Captured by encoder constructors
    /// so the first sample they see establishes / aligns with `hostOrigin`.
    private func ptsNormalizer(for handle: StreamHandle) -> (@Sendable (CMTime) -> CMTime) {
        // Capture by value — neither `self` nor the coordinator is retained
        // beyond its registration. `SyncCoordinator` is `@unchecked Sendable`.
        guard let coordinator = syncCoordinator else {
            return { pts in pts }
        }
        return { rawPTS in coordinator.normalize(rawPTS: rawPTS, handle: handle) }
    }

    /// Start the 2-second periodic drift-measurement task. Idempotent.
    private func startDriftMeasurementTaskIfNeeded() {
        guard driftMeasurementTask == nil, let coordinator = syncCoordinator else { return }
        driftMeasurementTask = Task.detached { [weak self] in
            while let self, !Task.isCancelled, !self.shouldStop() {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                coordinator.tickDriftMeasurement()
            }
        }
    }

    func run() async throws {
        info("Validating configuration")
        try configuration.validate()

        info("Installing SIGINT handler")
        try setupSignalHandler()

        // Register this worker process for discovery by UI sessions
        let pid = ProcessInfo.processInfo.processIdentifier
        if let port = configuration.ipcPort {
            try WorkerRegistry.register(pid: pid, ipcType: .tcp(port), config: configuration)
            info("Registered worker (PID \(pid)) with IPC port \(port)")
        } else if let socketPath = configuration.ipcSocket {
            try WorkerRegistry.register(pid: pid, ipcType: .unixSocket(socketPath), config: configuration)
            info("Registered worker (PID \(pid)) with Unix socket \(socketPath)")
        }

        startDriftMeasurementTaskIfNeeded()

        if let controlFD = configuration.controlFD {
            info("Launching control command listener on fd \(controlFD)")
            Task.detached(priority: .userInitiated) { [weak self] in
                self?.listenForControlCommands(fileDescriptor: controlFD)
            }
        }

        if configuration.needsSCStream {
            info("Starting SCStream capture pipeline")
            do {
                try await startCapture()
            } catch {
                self.error("startCapture failed: \(error.localizedDescription)")
                reportError(error.localizedDescription)
                await shutdown()
                return
            }
        } else if configuration.captureWebcam && configuration.captureInputAudio {
            // Webcam + input audio: both inputs in a single AVCaptureSession for synchronized delivery
            info("Webcam+audio mode: starting both in single capture session")
            do {
                try await requestCameraPermission()
                try await requestMicrophonePermission()
                try await MainActor.run { try startWebcamWithAudioCapture() }
            } catch {
                self.error("Webcam+audio capture failed: \(error.localizedDescription)")
                reportError(error.localizedDescription)
                await shutdown()
                return
            }
        } else if configuration.captureInputAudio {
            // Audio-only (no SCStream): start AVCaptureSession directly.
            info("Audio-only mode: starting input audio capture (no SCStream)")
            do {
                try await requestMicrophonePermission()
                try await MainActor.run { try startInputAudioCapture() }
            } catch {
                self.error("Input audio capture failed: \(error.localizedDescription)")
                reportError(error.localizedDescription)
                await shutdown()
                return
            }
        }

        if configuration.captureProcessAudio {
            info("Starting process audio tap")
            do {
                try await startProcessAudioTap()
            } catch {
                self.error("Process audio tap failed: \(error.localizedDescription)")
                reportError(error.localizedDescription)
                await shutdown()
                return
            }
        }

        if configuration.captureWebcam && configuration.captureInputAudio && webcamCaptureSession == nil {
            // This shouldn't happen if startWebcamWithAudioCapture() ran above, but as safety fallback
            info("Fallback: starting webcam capture (audio should already be running)")
            do {
                try await requestCameraPermission()
                try await MainActor.run { try startWebcamCapture() }
            } catch {
                self.error("Webcam capture failed: \(error.localizedDescription)")
                reportError(error.localizedDescription)
                await shutdown()
                return
            }
        } else if configuration.captureWebcam && !configuration.captureInputAudio && webcamCaptureSession == nil {
            info("Starting webcam-only capture")
            do {
                try await requestCameraPermission()
                try await MainActor.run { try startWebcamCapture() }
            } catch {
                self.error("Webcam capture failed: \(error.localizedDescription)")
                reportError(error.localizedDescription)
                await shutdown()
                return
            }
        }

        if configuration.skipVideo && !configuration.captureWebcam {
            // No video stream — start duration timer immediately rather than waiting
            // for a first video frame that will never arrive.
            info("No-video mode: capture pipeline ready — starting duration timer now")
            startDurationTimerIfNeeded()
        } else {
            info("Capture pipeline running — scheduling startup timeout")
            scheduleStartupTimeoutIfNeeded()
        }

        info("Waiting for stop signal (Ctrl-C, duration expiry, or control command)")
        await waitForStop()

        info("Stop signal received — beginning shutdown")
        await shutdown()
        info("Session ended")
    }

    private func handleStreamOutput(_ sampleBuffer: CMSampleBuffer, outputType: SCStreamOutputType) {
        autoreleasepool {
            do {
                switch outputType {
            case .screen:
                guard !shouldStop() else { return }
                guard shouldProcessScreenSampleBuffer(sampleBuffer) else {
                    return
                }
                guard let imageBuffer = sampleBuffer.imageBuffer else {
                    throw WorkerError.captureFailed("Received a complete screen buffer without an image payload.")
                }
                markVideoCaptureStartedIfNeeded()
                // Use the sample buffer's own PTS (on the host clock), so video and
                // audio share the same timeline and callback-delivery jitter does
                // not skew A/V sync.
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                stopLock.withLock { framesReceived += 1 }
                // Hand the retained raw pixel buffer to the encoder queue asynchronously
                // so this SCStream callback returns immediately and VT backpressure
                // never stalls videoOutputQueue.
                encoderInputQueue.async { [weak self, imageBuffer] in
                    guard let self, !self.shouldStop() else { return }
                    let (forceKeyFrame, shouldFlush) = self.stopLock.withLock {
                        self.framesSubmitted += 1
                        let keyframe = self.framesSubmitted % max(self.configuration.fps, 1) == 0
                        // Flush VT pipeline every 300 frames (~5sec @ 60fps) to prevent internal buffer accumulation
                        let flush = self.framesSubmitted % 300 == 0
                        return (keyframe, flush)
                    }
                    do {
                        try autoreleasepool {
                            try self.videoEncoder?.encode(imageBuffer, pts: pts, forceKeyFrame: forceKeyFrame)
                            if shouldFlush {
                                // Flush asynchronously on background queue to avoid blocking frame submission
                                self.encoderFlushQueue.async { [weak self] in
                                    self?.videoEncoder?.flush()
                                }
                            }
                        }
                    } catch {
                        self.error("Encoder input failed: \(error.localizedDescription)")
                        self.reportError(error.localizedDescription)
                        self.requestStop()
                    }
                }

            case .audio:
                let isFirst = stopLock.withLock {
                    if firstAudioPacketSeen { return false }
                    firstAudioPacketSeen = true
                    return true
                }
                if isFirst { info("First system audio packet received") }

                // In MPEG-TS dump mode, encode through AAC.
                // Use the sample buffer's own PTS (which is stamped at the START of the
                // captured PCM window, on the host clock), NOT "now" — using the callback
                // arrival time would push audio later than video by the audio system's
                // capture-buffer latency (~250ms at start), causing A/V desync.
                if let audioEncoder = self.audioEncoders[.screenSystemAudio] {
                    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    systemAudioOutputQueue.async { [weak self] in
                        autoreleasepool {
                            guard let self, !self.shouldStop() else { return }
                            do {
                                try audioEncoder.encode(sampleBuffer, pts: pts)
                            } catch {
                                self.error("Audio encoder input failed: \(error.localizedDescription)")
                                self.reportError(error.localizedDescription)
                                self.requestStop()
                            }
                        }
                    }
                } else {
                    try systemAudioStream?.append(sampleBuffer)
                }

                default:
                    break
                }
            } catch {
                self.error("Stream output handler failed: \(error.localizedDescription)")
                reportError(error.localizedDescription)
                requestStop()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        autoreleasepool {
            if configuration.captureWebcam && !configuration.needsSCStream {
            let prerollGate = stopLock.withLock { () -> (drop: Bool, log: Bool) in
                guard !firstWebcamFrameSeen else { return (false, false) }
                let shouldLog = !deferredInputAudioUntilFirstWebcamFrameLogged
                if shouldLog {
                    deferredInputAudioUntilFirstWebcamFrameLogged = true
                }
                return (true, shouldLog)
            }
            if prerollGate.drop {
                if prerollGate.log {
                    info("Dropping input audio until first webcam frame to avoid startup A/V skew")
                }
                return
            }
        }

        // In premux mode, send audio directly to the muxer
        if let premux = premuxWriter {
            premux.appendAudio(sampleBuffer)
            return
        }

        // In MPEG-TS dump mode, encode through AAC.
        // Use the sample buffer's own PTS rather than the callback arrival time,
        // so the audio timeline starts when the PCM was captured, not when it
        // was delivered — the AV delivery latency would otherwise desync A/V.
        if let audioEncoder = audioEncoders[.micAudio] {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            audioEncoderInputQueue.async { [weak self] in
                autoreleasepool {
                    guard let self, !self.shouldStop() else { return }
                    do {
                        try audioEncoder.encode(sampleBuffer, pts: pts)
                    } catch {
                        self.error("Audio encoder input failed: \(error.localizedDescription)")
                        self.reportError(error.localizedDescription)
                        self.requestStop()
                    }
                }
            }
            return
        }

        // Normal mode: send through PCM stream
        do {
            try inputAudioStream?.append(sampleBuffer)
        } catch {
            self.error("Input audio output handler failed: \(error.localizedDescription)")
            reportError(error.localizedDescription)
            requestStop()
        }
        }
    }

    private func shouldProcessScreenSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard CMSampleBufferIsValid(sampleBuffer),
              let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return false
        }

        return status == .complete
    }

    @MainActor
    private func startCapture() async throws {
        info("Requesting SCShareableContent — this requires Screen Recording permission")
        let shareableContent: SCShareableContent
        do {
            shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            self.error("SCShareableContent failed: \(error.localizedDescription)")
            self.error("Likely cause: Screen Recording permission not granted to this terminal/binary in System Settings > Privacy & Security > Screen Recording")
            throw error
        }
        self.shareableContent = shareableContent
        info("SCShareableContent: \(shareableContent.displays.count) display(s), \(shareableContent.applications.count) app(s), \(shareableContent.windows.count) window(s)")

        // Select the capture target for the content filter. When skipVideo, we still need
        // a valid SCContentFilter for SCStream (system audio requires it), but we use a
        // minimal 2×2 stream that we never read video frames from.
        let targetDesc = configuration.skipVideo ? "primary display (audio-only)" :
            "screen \(configuration.screenIndex)\(configuration.appName.map { ", app: \($0)" } ?? "")"
        info("Selecting capture target (\(targetDesc))")
        let target = try selectTarget(from: shareableContent)
        info("Capture target: \(Int(target.outputSize.width))x\(Int(target.outputSize.height)) px")
        contentFilter = target.filter

        // Video encoder — skipped in no-video mode.
        let outputSize: CGSize
        if configuration.skipVideo {
            outputSize = CGSize(width: 2, height: 2)   // minimal; never used for video frames
        } else if let w = configuration.outputWidth, let h = configuration.outputHeight {
            outputSize = CGSize(width: w, height: h)
            info("Output resolution override: \(w)x\(h)")
        } else {
            outputSize = target.outputSize
        }

        if !configuration.skipVideo {
            // SCStream PTS live on the host clock (CMClockGetHostTimeClock).
            let screenHandle = syncCoordinator!.registerStream(
                id: .screenVideo,
                kind: .video,
                sourceClock: CMClockGetHostTimeClock(),
                nominalRateHz: Double(configuration.fps)
            )
            self.screenVideoHandle = screenHandle
            let screenPTSNormalizer = ptsNormalizer(for: screenHandle)

            info("Creating H.264 hardware encoder (\(Int(outputSize.width))x\(Int(outputSize.height)) @ \(configuration.fps) fps, keyframes every \(configuration.keyFrameInterval ?? configuration.fps * 2) frames, CABAC, high-quality VT settings, range: full (BGRA))")
            videoEncoder = try H264Encoder(
                width: Int32(outputSize.width),
                height: Int32(outputSize.height),
                fps: configuration.fps,
                bitRate: configuration.bitrate,
                keyFrameInterval: configuration.keyFrameInterval,
                pixelFormat: kCVPixelFormatType_32BGRA,
                hostDomainPTSFor: screenPTSNormalizer
            ) { [weak self] sample in
                guard let self else { return }

                if let encoderError = sample.error {
                    self.error("H.264 encoder error: \(encoderError)")
                    self.videoWriter.writeError(encoderError)
                    self.requestStop()
                    return
                }

                do {
                    if let config = sample.configuration {
                        info("Sending video config packet: \(config.gstreamerCaps)")
                        self.cachedVideoConfig = config
                        try self.videoWriter.writeConfiguration(config)
                    }
                    if let payload = sample.payload {
                        self.stopLock.withLock { self.framesEncoded += 1 }
                        // Resend config before keyframes for late-joining IPC clients
                        if sample.isKeyFrame, let config = self.cachedVideoConfig {
                            try self.videoWriter.writeConfiguration(config)
                        }
                        // Always write to IPC for UI preview/monitoring
                        try self.videoWriter.writeSample(
                            payload,
                            ptsNanoseconds: sample.pts.nanosecondsValue,
                            flags: sample.isKeyFrame ? PacketFlags.keyFrame : 0
                        )
                        if let muxer = self.mpegTSMuxer {
                            try muxer.writeVideoSample(payload, pts: sample.pts, dts: sample.dts, isKeyFrame: sample.isKeyFrame)
                        }
                        if let rtmp = self.rtmpPublisher {
                            do {
                                try rtmp.writeVideoSample(payload, pts: sample.pts, dts: sample.dts, isKeyFrame: sample.isKeyFrame)
                            } catch {
                                if rtmp.isReconnecting { return }
                                self.error("Video packet write failed: \(error.localizedDescription)")
                                self.videoWriter.writeError(error.localizedDescription)
                                self.requestStop()
                                return
                            }
                        }
                    }
                } catch {
                    self.error("Video packet write failed: \(error.localizedDescription)")
                    self.videoWriter.writeError(error.localizedDescription)
                    self.requestStop()
                }
            }
            info("H.264 encoder created")
        }

        info("Configuring SCStream: \(configuration.skipVideo ? "audio-only" : "\(Int(outputSize.width))x\(Int(outputSize.height)) \(configuration.fps)fps") systemAudio:\(configuration.captureSystemAudio)")
        let streamConfig = SCStreamConfiguration()
        streamConfig.width  = Int(outputSize.width)
        streamConfig.height = Int(outputSize.height)
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        info("Screen capture pixel format: 32BGRA (BGRA), colorSpace: displayP3, background: clear")
        if !configuration.skipVideo {
            streamConfig.sourceRect           = target.sourceRect
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: Int32(configuration.fps))
            streamConfig.showsCursor          = configuration.showCursor
            streamConfig.scalesToFit          = outputSize != target.outputSize
            streamConfig.colorSpaceName       = CGColorSpace.displayP3
            streamConfig.backgroundColor      = CGColor.clear
        } else {
            // Audio-only: one frame per second minimum; we never process screen output.
            streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }

        if #available(macOS 14.0, *) {
            streamConfig.queueDepth = configuration.skipVideo ? 2 : 8
            if !configuration.skipVideo {
                streamConfig.captureResolution = outputSize == target.outputSize ? .best : .nominal
            }
        }

        if configuration.captureSystemAudio {
            streamConfig.capturesAudio = true
        }
        self.streamConfiguration = streamConfig

        guard let contentFilter else {
            throw WorkerError.captureFailed("Content filter was unexpectedly nil before stream creation.")
        }

        info("Creating SCStream")
        let streamDelegate = WorkerStreamOutput(owner: self)
        self.streamOutputDelegate = streamDelegate

        let stream = SCStream(filter: contentFilter, configuration: streamConfig, delegate: nil)
        self.stream = stream

        // If in MPEG-TS or RTMP mode and capturing system audio, create AAC encoder
        if configuration.captureSystemAudio && (mpegTSMuxer != nil || rtmpPublisher != nil) && audioEncoders[.screenSystemAudio] == nil {
            // System audio on SCStream rides the host clock too.
            let sysHandle = syncCoordinator!.registerStream(
                id: .screenSystemAudio,
                kind: .audio,
                sourceClock: CMClockGetHostTimeClock(),
                nominalRateHz: 48000.0
            )
            self.screenSystemAudioHandle = sysHandle
            let sysPTSNormalizer = ptsNormalizer(for: sysHandle)

            info("Creating AAC encoder for MPEG-TS muxing (system audio)")
            audioEncoders[.screenSystemAudio] = try AACEncoder(
                sampleRate: 48000,
                channels: 2,
                hostDomainPTSFor: sysPTSNormalizer
            ) { [weak self] sample in
                guard let self else { return }
                let pts = sample.pts
                do {
                    if let muxer = self.mpegTSMuxer {
                        try muxer.writeAudioSample(sample.payload, pts: pts)
                    }
                    if let rtmp = self.rtmpPublisher {
                        do {
                            try rtmp.writeAudioSample(sample.payload, pts: pts)
                        } catch {
                            if rtmp.isReconnecting { return }
                            self.error("Audio write failed: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    self.error("Audio write failed: \(error.localizedDescription)")
                }
            }
        }

        // Only add screen output when capturing video.
        if !configuration.skipVideo {
            try stream.addStreamOutput(streamDelegate, type: .screen, sampleHandlerQueue: videoOutputQueue)
            info("Added screen output handler")
        }

        if configuration.captureSystemAudio {
            try stream.addStreamOutput(streamDelegate, type: .audio, sampleHandlerQueue: systemAudioOutputQueue)
            info("Added system audio output handler")
        }

        info("Calling SCStream.startCapture()")
        try await stream.startCapture()
        info("SCStream.startCapture() returned — waiting for first frame")

        // Start input audio AFTER video capture so both streams begin at
        // roughly the same wall-clock time, keeping A/V in sync.
        if configuration.captureInputAudio {
            info("Starting input audio capture")
            try await requestMicrophonePermission()
            try startInputAudioCapture()
        }
    }

    private func startInputAudioCapture() throws {
        // In muxer mode, inputAudioWriter is nil but we'll encode through AAC encoder instead
        if inputAudioWriter == nil && mpegTSMuxer == nil {
            throw WorkerError.invalidArgument("Input audio capture was requested without an output stream.")
        }
        _ = inputAudioWriter

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        let device: AVCaptureDevice
        if let deviceID = configuration.inputDeviceID {
            guard let matching = SourceDiscovery.inputDevices()
                .first(where: { $0.uniqueID == deviceID }),
                  let selectedDevice = AVCaptureDevice(uniqueID: matching.uniqueID) else {
                throw WorkerError.notFound("Audio input device '\(deviceID)' was not found.")
            }
            device = selectedDevice
            info("Using input audio device: \(device.localizedName) (\(deviceID))")
        } else if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            device = defaultDevice
            info("Using default input audio device: \(device.localizedName)")
        } else {
            throw WorkerError.notFound("No default audio input device is available.")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw WorkerError.captureFailed("Failed to attach audio input device to capture session.")
        }
        captureSession.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: inputAudioOutputQueue)
        guard captureSession.canAddOutput(output) else {
            throw WorkerError.captureFailed("Failed to attach audio data output to capture session.")
        }
        captureSession.addOutput(output)

        captureSession.commitConfiguration()

        // If in MPEG-TS dump mode, create AAC encoder for the mic. Register
        // against the AVCaptureSession's synchronization clock — the
        // coordinator's `ClockSync` then translates mic PTS into the host
        // domain so it stays in sync with screen video / system audio.
        if mpegTSMuxer != nil && audioEncoders[.micAudio] == nil {
            let micClock = captureSession.synchronizationClock ?? CMClockGetHostTimeClock()
            let micHandle = syncCoordinator!.registerStream(
                id: .micAudio,
                kind: .audio,
                sourceClock: micClock,
                nominalRateHz: 48000.0
            )
            self.micAudioHandle = micHandle
            let micPTSNormalizer = ptsNormalizer(for: micHandle)

            info("Creating AAC encoder for MPEG-TS muxing")
            audioEncoders[.micAudio] = try AACEncoder(
                sampleRate: 48000,
                channels: 2,
                hostDomainPTSFor: micPTSNormalizer
            ) { [weak self] sample in
                guard let self, let muxer = self.mpegTSMuxer else { return }
                // Use the CMTime directly — roundtripping through nanoseconds
                // introduces ±1-tick jitter on the 90 kHz grid.
                let pts = sample.pts
                do {
                    try muxer.writeAudioSample(sample.payload, pts: pts)
                } catch {
                    self.error("Audio muxer write failed: \(error.localizedDescription)")
                }
            }
        }

        captureSession.startRunning()
        inputCaptureSession = captureSession
        info("Input audio AVCaptureSession running")
    }

    // MARK: - Webcam Capture

    private func startWebcamCapture() throws {
        // In muxer or RTMP mode, webcamVideoWriter may be nil but output goes elsewhere
        if webcamVideoWriter == nil && mpegTSMuxer == nil && rtmpPublisher == nil {
            throw WorkerError.invalidArgument("Webcam capture was requested without an output stream.")
        }

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        let device: AVCaptureDevice
        if let deviceID = configuration.webcamDeviceID {
            guard let matching = SourceDiscovery.webcamDevices()
                .first(where: { $0.uniqueID == deviceID }),
                  let selectedDevice = AVCaptureDevice(uniqueID: matching.uniqueID) else {
                throw WorkerError.notFound("Webcam device '\(deviceID)' was not found.")
            }
            device = selectedDevice
            info("Using webcam device: \(device.localizedName) (\(deviceID))")
        } else if let defaultDevice = AVCaptureDevice.default(for: .video) {
            device = defaultDevice
            info("Using default webcam device: \(device.localizedName)")
        } else {
            throw WorkerError.notFound("No webcam device is available.")
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw WorkerError.captureFailed("Failed to attach webcam device to capture session.")
        }
        captureSession.addInput(input)

        // Configure the session preset or explicit format based on requested resolution.
        let webcamChoice: WebcamFormatChoice?
        if let w = configuration.webcamWidth, let h = configuration.webcamHeight {
            webcamChoice = selectWebcamFormat(device: device, width: w, height: h, fps: configuration.webcamFPS)
            if let choice = webcamChoice {
                let dims = CMVideoFormatDescriptionGetDimensions(choice.format.formatDescription)
                let actualFPS = 1.0 / CMTimeGetSeconds(choice.frameDuration)
                info("Webcam format: \(dims.width)x\(dims.height) @ \(String(format: "%.2f", actualFPS)) fps (requested \(configuration.webcamFPS))")
            } else {
                warn("No exact webcam format for \(w)x\(h) — using device default")
            }
        } else {
            webcamChoice = nil
            // Use a reasonable default preset — medium quality is 480p-ish, high is 720p.
            captureSession.sessionPreset = .high
        }

        let videoOutput = AVCaptureVideoDataOutput()
        let preferredPixelFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ]
        let availablePixelFormats = Set(videoOutput.availableVideoPixelFormatTypes)
        let pixelFormat = preferredPixelFormats.first { availablePixelFormats.contains($0) }
            ?? kCVPixelFormatType_32BGRA
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        info("Webcam video output pixel format: \(Self.describePixelFormat(pixelFormat))")
        videoOutput.alwaysDiscardsLateVideoFrames = false

        let delegate = WebcamStreamOutput(owner: self)
        videoOutput.setSampleBufferDelegate(delegate, queue: webcamOutputQueue)
        self.webcamStreamDelegate = delegate

        guard captureSession.canAddOutput(videoOutput) else {
            throw WorkerError.captureFailed("Failed to attach video data output to webcam capture session.")
        }
        captureSession.addOutput(videoOutput)

        captureSession.commitConfiguration()

        if let choice = webcamChoice {
            try device.lockForConfiguration()
            device.activeFormat = choice.format
            let bounds = supportedFrameDurations(for: choice.format, requestedFPS: configuration.webcamFPS)
            device.activeVideoMinFrameDuration = bounds.min
            device.activeVideoMaxFrameDuration = bounds.max
            device.unlockForConfiguration()
        } else {
            try device.lockForConfiguration()
            let bounds = supportedFrameDurations(for: device.activeFormat, requestedFPS: configuration.webcamFPS)
            device.activeVideoMinFrameDuration = bounds.min
            device.activeVideoMaxFrameDuration = bounds.max
            device.unlockForConfiguration()
        }

        // Determine the actual output dimensions for the H.264 encoder.
        let outputWidth: Int32
        let outputHeight: Int32
        if let w = configuration.webcamWidth, let h = configuration.webcamHeight {
            outputWidth = Int32(w)
            outputHeight = Int32(h)
        } else {
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            outputWidth = dims.width
            outputHeight = dims.height
        }

        // Pull the device's real frame duration so the encoder can quantize to
        // the actual (possibly fractional) cadence — e.g. 1001/60000 = 59.94.
        let deviceFrameDuration = device.activeVideoMinFrameDuration

        // Register webcam against the AVCaptureSession's synchronization clock;
        // ClockSync translates into host domain.
        let camClock = captureSession.synchronizationClock ?? CMClockGetHostTimeClock()
        let camHandle = syncCoordinator!.registerStream(
            id: .webcamVideo,
            kind: .video,
            sourceClock: camClock,
            nominalRateHz: 1.0 / CMTimeGetSeconds(deviceFrameDuration)
        )
        self.webcamVideoHandle = camHandle
        let camPTSNormalizer = ptsNormalizer(for: camHandle)

        info("Creating webcam H.264 hardware encoder (\(outputWidth)x\(outputHeight) @ \(configuration.webcamFPS) fps, real cadence \(String(format: "%.4f", 1.0 / CMTimeGetSeconds(deviceFrameDuration))) fps, range: \(pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? "full" : pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "video" : "BGRA"))")
        webcamEncoder = try H264Encoder(
            width: outputWidth,
            height: outputHeight,
            fps: configuration.webcamFPS,
            bitRate: nil,
            keyFrameInterval: configuration.webcamFPS,
            realFrameDuration: deviceFrameDuration,
            pixelFormat: pixelFormat,
            hostDomainPTSFor: camPTSNormalizer
        ) { [weak self] sample in
            guard let self else { return }

            if let encoderError = sample.error {
                self.error("Webcam H.264 encoder error: \(encoderError)")
                self.webcamVideoWriter?.writeError(encoderError)
                self.requestStop()
                return
            }

            do {
                if let config = sample.configuration {
                    self.info("Sending webcam video config packet: \(config.gstreamerCaps)")
                    self.cachedWebcamVideoConfig = config
                    try self.webcamVideoWriter?.writeConfiguration(config)
                }
                if let payload = sample.payload {
                    self.stopLock.withLock { self.webcamFramesEncoded += 1 }
                    // Resend config before keyframes for late-joining IPC clients
                    if sample.isKeyFrame, let config = self.cachedWebcamVideoConfig {
                        try self.webcamVideoWriter?.writeConfiguration(config)
                    }
                    // Always write to IPC for UI preview/monitoring
                    try self.webcamVideoWriter?.writeSample(
                        payload,
                        ptsNanoseconds: sample.pts.nanosecondsValue,
                        flags: sample.isKeyFrame ? PacketFlags.keyFrame : 0
                    )
                    if let muxer = self.mpegTSMuxer {
                        try muxer.writeVideoSample(payload, pts: sample.pts, dts: sample.dts, isKeyFrame: sample.isKeyFrame)
                    }
                    if let rtmp = self.rtmpPublisher {
                        do {
                            try rtmp.writeVideoSample(payload, pts: sample.pts, dts: sample.dts, isKeyFrame: sample.isKeyFrame)
                        } catch {
                            if rtmp.isReconnecting { return }
                            self.error("Video packet write failed: \(error.localizedDescription)")
                            self.webcamVideoWriter?.writeError(error.localizedDescription)
                            self.requestStop()
                            return
                        }
                    }
                }
            } catch {
                self.error("Webcam video packet write failed: \(error.localizedDescription)")
                self.webcamVideoWriter?.writeError(error.localizedDescription)
                self.requestStop()
            }
        }
        info("Webcam H.264 encoder created")

        captureSession.startRunning()
        if let choice = webcamChoice {
            try device.lockForConfiguration()
            device.activeFormat = choice.format
            let bounds = supportedFrameDurations(for: choice.format, requestedFPS: configuration.webcamFPS)
            device.activeVideoMinFrameDuration = bounds.min
            device.activeVideoMaxFrameDuration = bounds.max
            device.unlockForConfiguration()
        }
        info("Webcam AVCaptureSession running")
        webcamCaptureSession = captureSession
    }

    private func startWebcamWithAudioCapture() throws {
        // In premux or muxer mode, output streams aren't needed (will write to their respective writers)
        let isPremux = configuration.premuxMPEGTS
        let isMuxer = mpegTSMuxer != nil

        let isRTMP = rtmpPublisher != nil
        if !isPremux && !isMuxer && !isRTMP {
            guard webcamVideoWriter != nil else {
                throw WorkerError.invalidArgument("Webcam capture was requested without a video output stream.")
            }
            guard inputAudioWriter != nil else {
                throw WorkerError.invalidArgument("Input audio capture was requested without an audio output stream.")
            }
        }

        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()

        // ===== VIDEO INPUT (Webcam) =====
        let videoDevice: AVCaptureDevice
        if let deviceID = configuration.webcamDeviceID {
            guard let matching = SourceDiscovery.webcamDevices()
                .first(where: { $0.uniqueID == deviceID }),
                  let selectedDevice = AVCaptureDevice(uniqueID: matching.uniqueID) else {
                throw WorkerError.notFound("Webcam device '\(deviceID)' was not found.")
            }
            videoDevice = selectedDevice
            info("Using webcam device: \(videoDevice.localizedName) (\(deviceID))")
        } else if let defaultDevice = AVCaptureDevice.default(for: .video) {
            videoDevice = defaultDevice
            info("Using default webcam device: \(videoDevice.localizedName)")
        } else {
            throw WorkerError.notFound("No webcam device is available.")
        }

        let webcamChoice: WebcamFormatChoice?
        if let w = configuration.webcamWidth, let h = configuration.webcamHeight {
            webcamChoice = selectWebcamFormat(device: videoDevice, width: w, height: h, fps: configuration.webcamFPS)
        } else {
            webcamChoice = nil
        }

        let videoInput = try AVCaptureDeviceInput(device: videoDevice)
        guard captureSession.canAddInput(videoInput) else {
            throw WorkerError.captureFailed("Failed to attach webcam device to capture session.")
        }
        captureSession.addInput(videoInput)

        if let w = configuration.webcamWidth, let h = configuration.webcamHeight {
            if let choice = selectWebcamFormat(device: videoDevice, width: w, height: h, fps: configuration.webcamFPS) {
                let dims = CMVideoFormatDescriptionGetDimensions(choice.format.formatDescription)
                let actualFPS = 1.0 / CMTimeGetSeconds(choice.frameDuration)
                info("Webcam format: \(dims.width)x\(dims.height) @ \(String(format: "%.2f", actualFPS)) fps (requested \(configuration.webcamFPS))")
            } else {
                warn("No exact webcam format for \(w)x\(h) — using device default")
            }
        }

        // Video output
        let videoOutput = AVCaptureVideoDataOutput()
        let preferredPixelFormats: [OSType] = [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ]
        let availablePixelFormats = Set(videoOutput.availableVideoPixelFormatTypes)
        let pixelFormat = preferredPixelFormats.first { availablePixelFormats.contains($0) }
            ?? kCVPixelFormatType_32BGRA
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        info("Webcam video output pixel format: \(Self.describePixelFormat(pixelFormat))")
        videoOutput.alwaysDiscardsLateVideoFrames = false

        let webcamDelegate = WebcamStreamOutput(owner: self)
        videoOutput.setSampleBufferDelegate(webcamDelegate, queue: webcamOutputQueue)
        self.webcamStreamDelegate = webcamDelegate

        guard captureSession.canAddOutput(videoOutput) else {
            throw WorkerError.captureFailed("Failed to attach video data output to webcam capture session.")
        }
        captureSession.addOutput(videoOutput)

        // ===== AUDIO INPUT (Input Device) =====
        let audioDevice: AVCaptureDevice
        if let deviceID = configuration.inputDeviceID {
            guard let matching = SourceDiscovery.inputDevices()
                .first(where: { $0.uniqueID == deviceID }),
                  let selectedDevice = AVCaptureDevice(uniqueID: matching.uniqueID) else {
                throw WorkerError.notFound("Audio input device '\(deviceID)' was not found.")
            }
            audioDevice = selectedDevice
            info("Using input audio device: \(audioDevice.localizedName) (\(deviceID))")
        } else if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            audioDevice = defaultDevice
            info("Using default input audio device: \(audioDevice.localizedName)")
        } else {
            throw WorkerError.notFound("No default audio input device is available.")
        }

        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard captureSession.canAddInput(audioInput) else {
            throw WorkerError.captureFailed("Failed to attach audio input device to capture session.")
        }
        captureSession.addInput(audioInput)

        // Audio output
        let audioOutput = AVCaptureAudioDataOutput()
        // Don't set explicit audio settings — use device native format to avoid format conversion delays
        audioOutput.setSampleBufferDelegate(self, queue: inputAudioOutputQueue)
        guard captureSession.canAddOutput(audioOutput) else {
            throw WorkerError.captureFailed("Failed to attach audio data output to capture session.")
        }
        captureSession.addOutput(audioOutput)

        // ===== ENCODER SETUP (H.264 for video) =====
        captureSession.commitConfiguration()

        if let choice = webcamChoice {
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = choice.format
            let bounds = supportedFrameDurations(for: choice.format, requestedFPS: configuration.webcamFPS)
            videoDevice.activeVideoMinFrameDuration = bounds.min
            videoDevice.activeVideoMaxFrameDuration = bounds.max
            videoDevice.unlockForConfiguration()
        } else {
            try videoDevice.lockForConfiguration()
            let bounds = supportedFrameDurations(for: videoDevice.activeFormat, requestedFPS: configuration.webcamFPS)
            videoDevice.activeVideoMinFrameDuration = bounds.min
            videoDevice.activeVideoMaxFrameDuration = bounds.max
            videoDevice.unlockForConfiguration()
        }

        let outputWidth: Int32
        let outputHeight: Int32
        if let w = configuration.webcamWidth, let h = configuration.webcamHeight {
            outputWidth = Int32(w)
            outputHeight = Int32(h)
        } else {
            let dims = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
            outputWidth = dims.width
            outputHeight = dims.height
        }

        // Pull the device's real frame duration so the encoder can quantize to
        // the actual (possibly fractional) cadence — e.g. 1001/60000 = 59.94.
        let deviceFrameDuration = videoDevice.activeVideoMinFrameDuration

        // Webcam + mic share ONE AVCaptureSession and therefore ONE
        // synchronization clock — they are already inter-aligned by the OS.
        // Register both lanes against that single clock so the coordinator
        // translates them with a single `ClockTranslator` instance — yielding
        // sample-accurate A/V offsets with no extra correction.
        let sharedClock = captureSession.synchronizationClock ?? CMClockGetHostTimeClock()
        let camHandle = syncCoordinator!.registerStream(
            id: .webcamVideo,
            kind: .video,
            sourceClock: sharedClock,
            nominalRateHz: 1.0 / CMTimeGetSeconds(deviceFrameDuration)
        )
        self.webcamVideoHandle = camHandle
        let camPTSNormalizer = ptsNormalizer(for: camHandle)

        info("Creating webcam H.264 hardware encoder (\(outputWidth)x\(outputHeight) @ \(configuration.webcamFPS) fps, real cadence \(String(format: "%.4f", 1.0 / CMTimeGetSeconds(deviceFrameDuration))) fps, range: \(pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? "full" : pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "video" : "BGRA"))")
        webcamEncoder = try H264Encoder(
            width: outputWidth,
            height: outputHeight,
            fps: configuration.webcamFPS,
            bitRate: nil,
            keyFrameInterval: configuration.webcamFPS,
            realFrameDuration: deviceFrameDuration,
            pixelFormat: pixelFormat,
            hostDomainPTSFor: camPTSNormalizer
        ) { [weak self] sample in
            guard let self else { return }

            if let encoderError = sample.error {
                self.error("Webcam H.264 encoder error: \(encoderError)")
                self.webcamVideoWriter?.writeError(encoderError)
                self.requestStop()
                return
            }

            do {
                if let config = sample.configuration {
                    self.info("Sending webcam video config packet: \(config.gstreamerCaps)")
                    try self.webcamVideoWriter?.writeConfiguration(config)
                }
                if let payload = sample.payload {
                    self.stopLock.withLock { self.webcamFramesEncoded += 1 }

                    if let premux = self.premuxWriter {
                        premux.appendVideo(payload: payload, pts: sample.pts, isKeyFrame: sample.isKeyFrame)
                    } else if self.mpegTSMuxer == nil && self.rtmpPublisher == nil {
                        try self.webcamVideoWriter?.writeSample(
                            payload,
                            ptsNanoseconds: sample.pts.nanosecondsValue,
                            flags: sample.isKeyFrame ? PacketFlags.keyFrame : 0
                        )
                    }
                    if let muxer = self.mpegTSMuxer {
                        try muxer.writeVideoSample(payload, pts: sample.pts, dts: sample.dts, isKeyFrame: sample.isKeyFrame)
                    }
                    if let rtmp = self.rtmpPublisher {
                        do {
                            try rtmp.writeVideoSample(payload, pts: sample.pts, dts: sample.dts, isKeyFrame: sample.isKeyFrame)
                        } catch {
                            if rtmp.isReconnecting { return }
                            self.error("Video packet write failed: \(error.localizedDescription)")
                            self.webcamVideoWriter?.writeError(error.localizedDescription)
                            self.requestStop()
                            return
                        }
                    }
                }
            } catch {
                self.error("Webcam video packet write failed: \(error.localizedDescription)")
                self.webcamVideoWriter?.writeError(error.localizedDescription)
                self.requestStop()
            }
        }
        info("Webcam H.264 encoder created")

        // If in MPEG-TS or RTMP mode, create AAC encoder for audio
        if (mpegTSMuxer != nil || rtmpPublisher != nil) && audioEncoders[.micAudio] == nil {
            let micHandle = syncCoordinator!.registerStream(
                id: .micAudio,
                kind: .audio,
                sourceClock: sharedClock,
                nominalRateHz: 48000.0
            )
            self.micAudioHandle = micHandle
            let micPTSNormalizer = ptsNormalizer(for: micHandle)

            info("Creating AAC encoder for MPEG-TS muxing (input audio)")
            audioEncoders[.micAudio] = try AACEncoder(
                sampleRate: 48000,
                channels: 2,
                hostDomainPTSFor: micPTSNormalizer
            ) { [weak self] sample in
                guard let self else { return }
                let pts = sample.pts
                do {
                    if let muxer = self.mpegTSMuxer {
                        try muxer.writeAudioSample(sample.payload, pts: pts)
                    }
                    if let rtmp = self.rtmpPublisher {
                        do {
                            try rtmp.writeAudioSample(sample.payload, pts: pts)
                        } catch {
                            if rtmp.isReconnecting { return }
                            self.error("Audio write failed: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    self.error("Audio write failed: \(error.localizedDescription)")
                }
            }
        }

        // Start capture session with both inputs
        captureSession.startRunning()
        if let choice = webcamChoice {
            try videoDevice.lockForConfiguration()
            videoDevice.activeFormat = choice.format
            let bounds = supportedFrameDurations(for: choice.format, requestedFPS: configuration.webcamFPS)
            videoDevice.activeVideoMinFrameDuration = bounds.min
            videoDevice.activeVideoMaxFrameDuration = bounds.max
            videoDevice.unlockForConfiguration()
        }
        info("Webcam+audio AVCaptureSession running (both inputs synchronized)")
        webcamCaptureSession = captureSession
        inputCaptureSession = nil  // Input audio now part of webcam session, not separate
    }

    private func handleWebcamFrame(_ sampleBuffer: CMSampleBuffer) {
        autoreleasepool {
            guard !shouldStop() else { return }
            guard CMSampleBufferIsValid(sampleBuffer),
                  let imageBuffer = sampleBuffer.imageBuffer else {
                return
            }

        let isFirst = stopLock.withLock {
            if firstWebcamFrameSeen { return false }
            firstWebcamFrameSeen = true
            return true
        }
        if isFirst {
            info("First webcam frame received")
            // Webcam is the active video source regardless of whether SCStream also
            // runs for system audio. When skipVideo=true the SCStream screen-frame
            // handler never fires, so this is the only place to cancel the startup
            // timeout. Call unconditionally.
            markVideoCaptureStartedIfNeeded()
        }

        // Use the sample buffer's own PTS so the encoded timeline reflects the
        // camera's real frame rate (which may be fractional, e.g. 59.94/59.9997),
        // not an integer-fps approximation. Callback-arrival time would throw this
        // away and also add delivery jitter.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        webcamEncoderInputQueue.async { [weak self, imageBuffer] in
            guard let self, !self.shouldStop() else { return }
            let (forceKeyFrame, shouldFlush) = self.stopLock.withLock {
                self.webcamFramesReceived += 1
                let keyframe = self.webcamFramesReceived % max(self.configuration.webcamFPS, 1) == 0
                // Flush VT pipeline every 300 frames (~5sec @ 60fps) to prevent internal buffer accumulation
                let flush = self.webcamFramesReceived % 300 == 0
                return (keyframe, flush)
            }
            do {
                try autoreleasepool {
                    try self.webcamEncoder?.encode(imageBuffer, pts: pts, forceKeyFrame: forceKeyFrame)
                    if shouldFlush {
                        // Flush asynchronously on background queue to avoid blocking frame submission
                        self.encoderFlushQueue.async { [weak self] in
                            self?.webcamEncoder?.flush()
                        }
                    }
                }
            } catch {
                self.error("Webcam encoder input failed: \(error.localizedDescription)")
                self.reportError(error.localizedDescription)
                self.requestStop()
            }
        }
        }
    }

    private struct WebcamFormatChoice {
        let format: AVCaptureDevice.Format
        let range: AVFrameRateRange
        let frameDuration: CMTime
    }

    /// Select the best matching camera format and frame duration for the requested resolution and fps.
    private func selectWebcamFormat(device: AVCaptureDevice, width: Int, height: Int, fps: Int) -> WebcamFormatChoice? {
        let requestedFPS = Double(fps)
        var bestChoice: WebcamFormatChoice?
        var bestResolutionDelta = Int.max
        var bestFPSDistance = Double.infinity
        var bestRangeMax = 0.0

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let w = Int(dims.width)
            let h = Int(dims.height)
            guard w >= width && h >= height else { continue }

            let resolutionDelta = (w - width) + (h - height)
            for range in format.videoSupportedFrameRateRanges {
                let (duration, fpsDistance): (CMTime, Double)
                if requestedFPS >= range.minFrameRate && requestedFPS <= range.maxFrameRate {
                    duration = range.minFrameDuration
                    fpsDistance = 0
                } else {
                    let distToMin = abs(requestedFPS - range.minFrameRate)
                    let distToMax = abs(requestedFPS - range.maxFrameRate)
                    if distToMin <= distToMax {
                        duration = range.maxFrameDuration
                        fpsDistance = distToMin
                    } else {
                        duration = range.minFrameDuration
                        fpsDistance = distToMax
                    }
                }

                if resolutionDelta < bestResolutionDelta ||
                    (resolutionDelta == bestResolutionDelta && (
                        fpsDistance < bestFPSDistance ||
                        (fpsDistance == bestFPSDistance && range.maxFrameRate > bestRangeMax)
                    )) {
                    bestResolutionDelta = resolutionDelta
                    bestFPSDistance = fpsDistance
                    bestRangeMax = range.maxFrameRate
                    bestChoice = WebcamFormatChoice(format: format, range: range, frameDuration: duration)
                }
            }
        }
        return bestChoice
    }

    private func supportedFrameDurations(for format: AVCaptureDevice.Format, requestedFPS: Int) -> (min: CMTime, max: CMTime) {
        let requested = Double(requestedFPS)
        var upperRate = Double.infinity
        var lowerRate = -Double.infinity
        var upperDuration: CMTime?
        var lowerDuration: CMTime?
        var firstDuration: CMTime?

        for range in format.videoSupportedFrameRateRanges {
            if firstDuration == nil {
                firstDuration = range.minFrameDuration
            }
            let candidates: [(rate: Double, duration: CMTime)] = [
                (range.minFrameRate, range.maxFrameDuration),
                (range.maxFrameRate, range.minFrameDuration)
            ]
            for candidate in candidates {
                if candidate.rate >= requested, candidate.rate < upperRate {
                    upperRate = candidate.rate
                    upperDuration = candidate.duration
                }
                if candidate.rate <= requested, candidate.rate > lowerRate {
                    lowerRate = candidate.rate
                    lowerDuration = candidate.duration
                }
            }
        }

        let fallback = firstDuration ?? CMTime(value: 1, timescale: Int32(max(1, requestedFPS)))
        let minDuration = upperDuration ?? lowerDuration ?? fallback
        let maxDuration = lowerDuration ?? upperDuration ?? fallback
        return (min: minDuration, max: maxDuration)
    }

    /// Clamp a requested fps to the range supported by the given format.
    /// Returns the best matching CMTime frame duration for use with
    /// activeVideoMinFrameDuration / activeVideoMaxFrameDuration.
    /// Using CMTime instead of Int avoids rounding 29.97 → 30, which
    /// AVFoundation rejects for devices that only support NTSC rates.
    private func clampFrameRate(fps: Int, format: AVCaptureDevice.Format) -> CMTime {
        let requestedFPS = Double(fps)

        var bestRange: AVFrameRateRange?
        var closestDistance = Double.infinity
        for range in format.videoSupportedFrameRateRanges {
            if requestedFPS >= range.minFrameRate && requestedFPS <= range.maxFrameRate {
                return CMTime(seconds: 1.0 / requestedFPS, preferredTimescale: 600_000)
            }
            let distToMin = abs(requestedFPS - range.minFrameRate)
            let distToMax = abs(requestedFPS - range.maxFrameRate)
            let dist = min(distToMin, distToMax)
            if dist < closestDistance {
                closestDistance = dist
                bestRange = range
            }
        }
        if let bestRange {
            let distToMin = abs(requestedFPS - bestRange.minFrameRate)
            let distToMax = abs(requestedFPS - bestRange.maxFrameRate)
            let duration = distToMax <= distToMin ? bestRange.minFrameDuration : bestRange.maxFrameDuration
            let actualFPS = 1.0 / CMTimeGetSeconds(duration)
            if abs(actualFPS - requestedFPS) > 0.1 {
                info("Webcam fps clamped from \(fps) to \(String(format: "%.2f", actualFPS)) (format supports: \(format.videoSupportedFrameRateRanges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" }.joined(separator: ", ")))")
            }
            return duration
        }
        return CMTime(value: 1, timescale: Int32(max(1, fps)))
    }

    // MARK: - Permission Requests

    /// Request camera permission. Throws if denied/restricted.
    private func requestCameraPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            info("Camera permission: authorized")
        case .notDetermined:
            info("Camera permission: requesting from user")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                throw WorkerError.captureFailed(
                    "Camera permission denied. Grant Camera access in " +
                    "System Settings > Privacy & Security > Camera.")
            }
            info("Camera permission: granted by user")
        case .denied, .restricted:
            throw WorkerError.captureFailed(
                "Camera permission denied. Grant Camera access in " +
                "System Settings > Privacy & Security > Camera.")
        @unknown default:
            throw WorkerError.captureFailed("Camera permission status unknown.")
        }
    }

    private static func describePixelFormat(_ pixelFormat: OSType) -> String {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return "420f (full-range bi-planar YUV)"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return "420v (video-range bi-planar YUV)"
        case kCVPixelFormatType_32BGRA:
            return "32BGRA"
        default:
            let bytes = [
                UInt8((pixelFormat >> 24) & 0xFF),
                UInt8((pixelFormat >> 16) & 0xFF),
                UInt8((pixelFormat >> 8) & 0xFF),
                UInt8(pixelFormat & 0xFF)
            ]
            let fourCC = String(bytes.map { Character(UnicodeScalar($0)) })
            return "\(fourCC) (0x\(String(pixelFormat, radix: 16)))"
        }
    }

    /// Request microphone permission. Throws if denied/restricted.
    private func requestMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            info("Microphone permission: authorized")
        case .notDetermined:
            info("Microphone permission: requesting from user")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw WorkerError.captureFailed(
                    "Microphone permission denied. Grant Microphone access in " +
                    "System Settings > Privacy & Security > Microphone.")
            }
            info("Microphone permission: granted by user")
        case .denied, .restricted:
            throw WorkerError.captureFailed(
                "Microphone permission denied. Grant Microphone access in " +
                "System Settings > Privacy & Security > Microphone.")
        @unknown default:
            throw WorkerError.captureFailed("Microphone permission status unknown.")
        }
    }

    @MainActor
    private func startProcessAudioTap() throws {
        guard let writer = processAudioWriter else {
            throw WorkerError.invalidArgument("Process audio tap requested but writer is nil.")
        }

        if #available(macOS 14.2, *) {
            // Resolve target process(es) to CoreAudio AudioObjectIDs.
            // Electron / multi-process apps route audio through helper subprocesses,
            // so we tap ALL processes whose bundle ID starts with the main app's
            // bundle ID (e.g. "com.co.app" + "com.co.app.helper").
            let processObjectIDs: [AudioObjectID]
            if let pid = configuration.audioTapPID {
                guard let id = ProcessAudioTap.resolveProcessAudioObjectID(pid: pid) else {
                    throw WorkerError.notFound("No CoreAudio process object found for PID \(pid).")
                }
                processObjectIDs = [id]
                info("Process audio tap: PID \(pid) → AudioObjectID \(id)")
            } else if let appName = configuration.audioTapApp {
                let ids = ProcessAudioTap.resolveAllProcessAudioObjectIDs(appName: appName)
                guard !ids.isEmpty else {
                    throw WorkerError.notFound(
                        "No CoreAudio process objects found for app '\(appName)'. " +
                        "Is the app running and registered with CoreAudio?")
                }
                processObjectIDs = ids
                info("Process audio tap: '\(appName)' → \(ids.count) process(es): \(ids)")
            } else {
                throw WorkerError.invalidArgument("Process audio tap: no PID or app name provided.")
            }

            let tap = try ProcessAudioTap(processAudioObjectIDs: processObjectIDs, writer: writer)
            try tap.start()
            stopProcessTap = { tap.stop() }
            info("Process audio tap started (\(processObjectIDs.count) process(es) tapped)")
        } else {
            throw WorkerError.unsupported("Process audio tap requires macOS 14.2 or newer.")
        }
    }

    @MainActor
    private func selectTarget(from content: SCShareableContent) throws -> CaptureTarget {
        if let sourceId = configuration.sourceId {
            return try selectTargetBySourceId(sourceId, from: content)
        }

        // In no-video / audio-only mode, default to the primary display so SCStream has
        // a valid content filter for system audio capture. No video frames are ever used.
        if configuration.skipVideo {
            guard let primary = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                             ?? content.displays.first else {
                throw WorkerError.notFound("No displays found for system audio SCStream filter.")
            }
            let excludedApps = content.applications.filter { app in
                Bundle.main.bundleIdentifier.map { app.bundleIdentifier == $0 } ?? false
            }
            return CaptureTarget(
                filter: SCContentFilter(display: primary, excludingApplications: excludedApps, exceptingWindows: []),
                sourceRect: CGRect(origin: .zero, size: primary.frame.size),
                outputSize: CGSize(width: 2, height: 2))
        }

        let requestedAppBundleID = try configuration.appBundleID ?? matchAppBundleID(appName: configuration.appName, from: content)
        if let appBundleID = requestedAppBundleID {
            info("App capture mode: bundle ID \(appBundleID)")
            let appWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == appBundleID }
            guard let bestWindow = appWindows.max(by: { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }) else {
                throw WorkerError.notFound("No shareable windows were found for app '\(appBundleID)'.")
            }
            info("Selected window: '\(bestWindow.title ?? "(untitled)")' frame=\(bestWindow.frame)")

            let scaleFactor = scaleFactor(for: bestWindow.frame)
            let outputSize = CGSize(width: bestWindow.frame.width * scaleFactor, height: bestWindow.frame.height * scaleFactor)
            return CaptureTarget(
                filter: SCContentFilter(desktopIndependentWindow: bestWindow),
                sourceRect: .null,
                outputSize: outputSize
            )
        }

        info("Display capture mode: screen index \(configuration.screenIndex)")
        let displays = try SourceDiscovery.displays()
        guard let displaySource = displays.first(where: { $0.index == configuration.screenIndex }) else {
            throw WorkerError.notFound("Display \(configuration.screenIndex) was not found. Available: \(displays.map { "\($0.index):\($0.name)" }.joined(separator: ", "))")
        }
        info("Matched display: '\(displaySource.name)' displayID=\(displaySource.displayID) scale=\(displaySource.scaleFactor)x")

        guard let display = content.displays.first(where: { $0.displayID == displaySource.displayID }) else {
            throw WorkerError.notFound("Display \(configuration.screenIndex) not available in SCShareableContent.")
        }

        let scaleFactor = displaySource.scaleFactor
        let logicalFrame = CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                                   width: display.frame.width, height: display.frame.height)

        let sourceRect: CGRect
        let outputSize: CGSize
        if let area = configuration.area {
            let areaRect = area.rect
            let withinBounds = areaRect.minX >= 0 && areaRect.minY >= 0 &&
                areaRect.maxX <= logicalFrame.width && areaRect.maxY <= logicalFrame.height
            guard withinBounds else {
                throw WorkerError.invalidArgument(
                    "Capture area \(areaRect) exceeds display bounds \(logicalFrame).")
            }
            sourceRect = areaRect
            outputSize = CGSize(width: areaRect.width * scaleFactor, height: areaRect.height * scaleFactor)
            info("Custom area: \(areaRect) → output \(Int(outputSize.width))x\(Int(outputSize.height)) px")
        } else {
            sourceRect = CGRect(x: 0, y: 0, width: logicalFrame.width, height: logicalFrame.height)
            outputSize = CGSize(width: logicalFrame.width * scaleFactor, height: logicalFrame.height * scaleFactor)
            info("Full display: logical \(Int(logicalFrame.width))x\(Int(logicalFrame.height)) → output \(Int(outputSize.width))x\(Int(outputSize.height)) px")
        }

        let excludedApps = content.applications.filter { app in
            Bundle.main.bundleIdentifier.map { app.bundleIdentifier == $0 } ?? false
        }

        return CaptureTarget(
            filter: SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: []),
            sourceRect: sourceRect,
            outputSize: outputSize
        )
    }

    @MainActor
    private func selectTargetBySourceId(_ sourceId: String, from content: SCShareableContent) throws -> CaptureTarget {
        let parts = sourceId.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, let rawID = UInt32(parts[1]) else {
            throw WorkerError.invalidArgument(
                "Invalid --source-id '\(sourceId)'. Expected 'screen:DISPLAY_ID:0' or 'window:WINDOW_ID:0'.")
        }

        switch String(parts[0]) {
        case "screen":
            guard let display = content.displays.first(where: { $0.displayID == rawID }) else {
                throw WorkerError.notFound("Display with ID \(rawID) not found in SCShareableContent.")
            }
            info("Source ID '\(sourceId)' → display displayID=\(rawID) frame=\(display.frame)")

            let displayScaleFactor = (try? SourceDiscovery.displays()
                .first(where: { $0.displayID == rawID })?.scaleFactor) ?? 1.0
            let logicalFrame = display.frame
            let sourceRect = CGRect(origin: .zero, size: logicalFrame.size)
            let outputSize = CGSize(
                width:  logicalFrame.width  * displayScaleFactor,
                height: logicalFrame.height * displayScaleFactor)
            let excludedApps = content.applications.filter { app in
                Bundle.main.bundleIdentifier.map { app.bundleIdentifier == $0 } ?? false
            }
            return CaptureTarget(
                filter: SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: []),
                sourceRect: sourceRect,
                outputSize: outputSize)

        case "window":
            guard let window = content.windows.first(where: { $0.windowID == rawID }) else {
                throw WorkerError.notFound("Window with ID \(rawID) not found in SCShareableContent.")
            }
            info("Source ID '\(sourceId)' → window '\(window.title ?? "(untitled)")' frame=\(window.frame)")

            let sf = scaleFactor(for: window.frame)
            let outputSize = CGSize(width: window.frame.width * sf, height: window.frame.height * sf)
            return CaptureTarget(
                filter: SCContentFilter(desktopIndependentWindow: window),
                sourceRect: .null,
                outputSize: outputSize)

        default:
            throw WorkerError.invalidArgument(
                "Unknown source kind in --source-id '\(sourceId)'. Expected 'screen' or 'window'.")
        }
    }

    private func matchAppBundleID(appName: String?, from content: SCShareableContent) throws -> String? {
        guard let appName else { return nil }

        let matches = content.applications.filter {
            $0.applicationName.localizedCaseInsensitiveContains(appName) ||
            $0.bundleIdentifier.localizedCaseInsensitiveContains(appName)
        }

        guard let first = matches.first else {
            throw WorkerError.notFound("No app matched '\(appName)'. Running apps: \(content.applications.map { $0.applicationName }.joined(separator: ", "))")
        }

        if matches.count > 1 {
            let ids = matches.compactMap { $0.bundleIdentifier }
            throw WorkerError.invalidArgument(
                "Multiple apps matched '\(appName)': \(ids.joined(separator: ", ")). Use --app-bundle-id.")
        }

        return first.bundleIdentifier
    }

    @MainActor
    private func scaleFactor(for frame: CGRect) -> CGFloat {
        for screen in NSScreen.screens where screen.frame.intersects(frame) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 1.0
    }

    private func requestStop() {
        stopLock.lock()
        guard !stopRequested else { stopLock.unlock(); return }
        stopRequested = true
        let continuation = stopContinuation
        stopContinuation = nil
        stopLock.unlock()
        continuation?.resume()
    }

    private func shouldStop() -> Bool {
        stopLock.withLock { stopRequested }
    }

    private func hasStreamFailure() -> Bool {
        stopLock.withLock { streamFailed }
    }

    private func markVideoCaptureStartedIfNeeded() {
        stopLock.lock()
        guard !firstVideoFrameSeen else { stopLock.unlock(); return }
        firstVideoFrameSeen = true
        let startupTask = self.startupTimeoutTask
        self.startupTimeoutTask = nil
        stopLock.unlock()

        info("First video frame received — encoder delivering output")
        startupTask?.cancel()
        startDurationTimerIfNeeded()
    }

    /// Starts the optional fixed-duration stop timer.  Safe to call multiple times;
    /// only the first call takes effect (guarded by `durationStopTask`).
    private func startDurationTimerIfNeeded() {
        guard let durationMs = configuration.durationMilliseconds else { return }
        stopLock.lock()
        guard durationStopTask == nil else { stopLock.unlock(); return }
        stopLock.unlock()
        info("Duration timer started: \(durationMs)ms")
        durationStopTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            self?.info("Duration elapsed, requesting stop")
            self?.requestStop()
        }
    }

    private func scheduleStartupTimeoutIfNeeded() {
        stopLock.lock()
        guard !firstVideoFrameSeen, startupTimeoutTask == nil else { stopLock.unlock(); return }
        stopLock.unlock()

        info("Startup timeout armed: 5s")
        startupTimeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !self.hasSeenFirstVideoFrame(), !self.shouldStop() else { return }
            self.error("Startup timed out — no video frame received within 5s")
            self.reportError("Capture startup timed out before the first video frame was delivered.")
            self.requestStop()
        }
    }

    private func hasSeenFirstVideoFrame() -> Bool {
        stopLock.withLock { firstVideoFrameSeen }
    }

    private func waitForStop() async {
        if shouldStop() { return }
        await withCheckedContinuation { continuation in
            stopLock.lock()
            if stopRequested {
                stopLock.unlock()
                continuation.resume()
                return
            }
            stopContinuation = continuation
            stopLock.unlock()
        }
    }

    @MainActor
    private func shutdown() async {
        info("Shutdown: cancelling timers")
        durationStopTask?.cancel()
        durationStopTask = nil
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        driftMeasurementTask?.cancel()
        driftMeasurementTask = nil

        // Drain encoder input queue — wait for all queued encode() calls to complete.
        info("Shutdown: draining encoder input queue")
        encoderInputQueue.sync { }

        // Drain webcam encoder input queue.
        if webcamEncoder != nil {
            info("Shutdown: draining webcam encoder input queue")
            webcamEncoderInputQueue.sync { }
        }

        // Flush VT: CompleteFrames + Invalidate. Called from MainActor (not
        // encoderInputQueue) so VT callbacks can fire without queue deadlock.
        info("Shutdown: flushing encoder")
        videoEncoder?.finish()

        if webcamEncoder != nil {
            info("Shutdown: flushing webcam encoder")
            webcamEncoder?.finish()
        }

        // Drain audio encoder input queue if any AAC encoder is present
        if !audioEncoders.isEmpty {
            info("Shutdown: draining audio encoder input queue")
            audioEncoderInputQueue.sync { }
        }

        // Stop process audio tap (writes its own EOS + closes its writer).
        if let stopTap = stopProcessTap {
            info("Shutdown: stopping process audio tap")
            stopTap()
            stopProcessTap = nil
        }

        // Finalize MPEG-TS muxer
        if let muxer = mpegTSMuxer {
            info("Shutdown: finalizing MPEG-TS muxer")
            muxer.finish()
            mpegTSMuxer = nil
        }

        // Close RTMP publisher
        if let rtmp = rtmpPublisher {
            info("Shutdown: closing RTMP publisher")
            rtmp.close()
            rtmpPublisher = nil
        }

        // Finalize premux writer
        if let premux = premuxWriter {
            info("Shutdown: finalizing premux writer")
            await premux.finish()
            premuxWriter = nil
        }

        // All encoded frames have been delivered — now write EOS and close FDs.
        info("Shutdown: writing EOS packets")
        videoWriter.writeEndOfStream()
        systemAudioWriter?.writeEndOfStream()
        inputAudioWriter?.writeEndOfStream()
        webcamVideoWriter?.writeEndOfStream()
        videoWriter.close()
        systemAudioWriter?.close()
        inputAudioWriter?.close()
        webcamVideoWriter?.close()

        if let stream, !hasStreamFailure() {
            info("Shutdown: stopping SCStream (detached, not awaited)")
            Task.detached { try? await stream.stopCapture() }
        }
        if let captureSession = inputCaptureSession, captureSession.isRunning {
            info("Shutdown: stopping AVCaptureSession (input audio)")
            captureSession.stopRunning()
        }
        if let captureSession = webcamCaptureSession, captureSession.isRunning {
            info("Shutdown: stopping AVCaptureSession (webcam)")
            captureSession.stopRunning()
        }

        stream = nil
        streamOutputDelegate = nil
        streamConfiguration = nil
        contentFilter = nil
        shareableContent = nil
        webcamStreamDelegate = nil

        // Unregister this worker from the discovery registry
        let pid = ProcessInfo.processInfo.processIdentifier
        WorkerRegistry.unregister(pid: pid)
        info("Shutdown: complete")
    }

    private func setupSignalHandler() throws {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGINT,
            queue: DispatchQueue(label: "swiftcapture.worker.signal")
        )
        source.setEventHandler { [weak self] in
            self?.info("SIGINT received")
            self?.requestStop()
        }
        source.resume()
        self.signalSource = source
    }

    private func reportError(_ message: String) {
        error("Reporting error to stream consumers: \(message)")
        videoWriter.writeError(message)
        systemAudioWriter?.writeError(message)
        inputAudioWriter?.writeError(message)
        webcamVideoWriter?.writeError(message)
    }

    private func info(_ msg: String) { SwiftCaptureWorker_log("INFO ", msg) }
    private func warn(_ msg: String) { SwiftCaptureWorker_log("WARN ", msg) }
    private func error(_ msg: String) { SwiftCaptureWorker_log("ERROR", msg) }

    private func writeDiagnostic(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }

    private func listenForControlCommands(fileDescriptor: Int32) {
        info("Control listener active on fd \(fileDescriptor)")
        let originalFlags = fcntl(fileDescriptor, F_GETFL)
        if originalFlags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK) }
        defer { if originalFlags >= 0 { _ = fcntl(fileDescriptor, F_SETFL, originalFlags) } }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while !shouldStop() {
            let bytesRead = Darwin.read(fileDescriptor, &chunk, chunk.count)
            if bytesRead > 0 {
                buffer.append(chunk, count: bytesRead)
            } else if bytesRead == 0 {
                info("Control fd closed — stopping")
                requestStop(); return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(20_000); continue
            } else {
                warn("Control fd read error \(errno) — stopping")
                requestStop(); return
            }

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                guard let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }

                if text == "stop" {
                    info("Control command: stop"); requestStop(); return
                }
                if let data = text.data(using: .utf8),
                   let msg = try? JSONDecoder().decode(ControlMessage.self, from: data),
                   msg.command == "stop" {
                    info("Control command (JSON): stop"); requestStop(); return
                }
            }
        }
    }

    private static func redactURL(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "[REDACTED]" }
        let host = url.host ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        if url.scheme == "rtmp" {
            let app = url.pathComponents.filter { $0 != "/" }.dropLast().joined(separator: "/")
            let appPart = app.isEmpty ? "" : "\(app)/"
            return "rtmp://\(host)\(port)/\(appPart)[REDACTED]"
        } else if url.scheme == "srt" {
            return "srt://\(host)\(port)?[REDACTED]"
        }
        return urlString
    }

    private var signalSource: DispatchSourceSignal?
}

// Module-level log so init can call it before self methods are usable
private func SwiftCaptureWorker_log(_ level: String, _ message: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    guard let data = "[\(ts)] [\(level)] \(message)\n".data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: data)
}

private struct CaptureTarget {
    let filter: SCContentFilter
    let sourceRect: CGRect
    let outputSize: CGSize
}

private struct ControlMessage: Decodable {
    let command: String
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }; return body()
    }
}
