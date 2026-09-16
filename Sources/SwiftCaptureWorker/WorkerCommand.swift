import Foundation
import ArgumentParser

@main
struct SwiftCaptureWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Headless ScreenCaptureKit helper worker that emits separate live packet streams for video and audio."
    )

    @Flag(name: .long, help: "Print JSON describing available video and audio capture sources, then exit.")
    var listSources = false

    @Option(name: .long, help: "Which source categories to include when listing sources: video, audio, or all.")
    var sourceKind: SourceKind = .all

    @Option(name: .long, help: "Print JSON describing a running worker's configuration and IPC details by PID, then exit.")
    var infoPid: Int32?

    @Flag(name: .long, help: "List all discovered running worker processes as JSON, then exit.")
    var listWorkers = false

    @Option(name: .long, help: "1-based display index for display capture.")
    var screenIndex = 1

    @Option(name: .long, help: "Case-insensitive application name match for application/window capture.")
    var appName: String?

    @Option(name: .long, help: "Exact bundle identifier for application/window capture.")
    var appBundleID: String?

    @Option(name: .long, help: "Capture region for display capture in x:y:width:height form.")
    var area: String?

    @Option(name: .long, help: "Target frame rate. Valid values are 15, 30, and 60.")
    var fps = 60

    @Flag(name: .long, help: "Include the mouse cursor in the video stream.")
    var showCursor = false

    @Option(name: .long, help: "Automatically stop after the given duration in milliseconds.")
    var durationMs: Int?

    @Option(name: .long, help: "Target H.264 bitrate in bits per second.")
    var bitrate: Int?

    @Option(name: .long, help: "Maximum keyframe interval in frames. Defaults to fps * 2.")
    var keyframeInterval: Int?

    @Option(name: .long, help: "Output width in pixels. Must be specified with --output-height.")
    var outputWidth: Int?

    @Option(name: .long, help: "Output height in pixels. Must be specified with --output-width.")
    var outputHeight: Int?

    @Option(name: .long, help: "File descriptor for the video packet stream.")
    var videoFD: Int32 = 1

    @Option(name: .long, help: "File descriptor for the system/process audio packet stream.")
    var systemAudioFD: Int32?

    @Option(name: .long, help: "File descriptor for the input device audio packet stream.")
    var inputAudioFD: Int32?

    @Option(name: .long, help: "Optional file descriptor used for master control commands.")
    var controlFD: Int32?

    @Option(name: .long, help: "Unix domain socket path to connect to for multiplexed IPC output. Mutually exclusive with --video-fd / --system-audio-fd / --input-audio-fd.")
    var ipcSocket: String?

    @Option(name: .long, help: "TCP localhost port to connect to for multiplexed IPC output. Mutually exclusive with --ipc-socket.")
    var ipcPort: Int?

    @Flag(name: .long, help: "Skip video capture entirely. At least one audio capture flag must also be set.")
    var noVideo = false

    @Flag(name: .long, help: "Capture system/process audio from ScreenCaptureKit.")
    var captureSystemAudio = false

    @Flag(name: .long, help: "Capture microphone or other audio input device audio.")
    var captureInputAudio = false

    @Option(name: .long, help: "Exact unique ID of the audio input device to use with --capture-input-audio.")
    var inputDeviceID: String?

    @Option(name: .long, help: "Electron-compatible source ID to capture. Accepted formats: 'screen:DISPLAY_ID:0' (display) or 'window:WINDOW_ID:0' (window). Supersedes --screen-index and --app-bundle-id.")
    var sourceId: String?

    @Flag(name: .long, help: "Tap audio output of a specific process. Requires --audio-tap-pid or --audio-tap-app. macOS 14.2+.")
    var captureProcessAudio = false

    @Option(name: .long, help: "PID of the process to tap for audio. Used with --capture-process-audio.")
    var audioTapPid: Int32?

    @Option(name: .long, help: "Application name (or partial bundle ID) of the process to tap for audio. Used with --capture-process-audio.")
    var audioTapApp: String?

    @Option(name: .long, help: "File descriptor for the process audio tap packet stream.")
    var processAudioFD: Int32?

    @Flag(name: .long, help: "Capture webcam video as a separate H.264 stream (stream_id 4).")
    var captureWebcam = false

    @Option(name: .long, help: "Exact unique ID of the webcam device to use with --capture-webcam.")
    var webcamDeviceID: String?

    @Option(name: .long, help: "Target frame rate for webcam capture. Clamped to hardware-supported range.")
    var webcamFPS = 60

    @Option(name: .long, help: "Output width in pixels for webcam capture. Must be specified with --webcam-height.")
    var webcamWidth: Int?

    @Option(name: .long, help: "Output height in pixels for webcam capture. Must be specified with --webcam-width.")
    var webcamHeight: Int?

    @Option(name: .long, help: "File descriptor for the webcam video packet stream.")
    var webcamVideoFD: Int32?

    @Flag(name: .long, help: "Pre-mux audio+video into MPEG-TS in SwiftCapture instead of separate streams.")
    var premux = false

    @Option(name: .long, help: "For testing: dump muxed H.264 + AAC output to this file path instead of streaming. Useful with ffplay/ffprobe.")
    var dumpOutput: String?

    @Option(name: .long, help: "SRT URL for native SRT broadcast (srt://host:port?streamid=...&latency=...). Mutually exclusive with --dump-output.")
    var srtUrl: String?

    @Option(name: .long, help: "SRT latency in milliseconds. Default: 120")
    var srtLatencyMs: Int = 120

    @Option(name: .long, help: "SRT stream ID override (optional; otherwise parsed from srtUrl query params).")
    var srtStreamId: String?

    @Option(name: .long, help: "RTMP URL for native RTMP broadcast (rtmp://host:port/app/streamKey). Mutually exclusive with --srt-url and --dump-output.")
    var rtmpUrl: String?

    mutating func run() async throws {
        // Handle info/discovery commands first (they don't require full config validation)
        if listWorkers {
            let workers = WorkerRegistry.discoverWorkers()
            try writeJSON(workers)
            return
        }

        if let pid = infoPid {
            guard let entry = WorkerRegistry.queryWorker(pid: pid) else {
                throw WorkerError.notFound("No worker found with PID \(pid)")
            }
            try writeJSON(entry)
            return
        }

        let configuration = try makeConfiguration()

        if configuration.listSources {
            let response = try SourceDiscovery.query(kind: configuration.sourceKind)
            try writeJSON(response)
            return
        }

        guard #available(macOS 13.0, *) else {
            throw WorkerError.unsupported("This worker requires macOS 13 or newer.")
        }

        let session = try CaptureSession(configuration: configuration)
        try await session.run()
        Foundation.exit(0)
    }

    private func makeConfiguration() throws -> WorkerConfiguration {
        let captureArea = try area.map(CaptureArea.parse)
        let configuration = WorkerConfiguration(
            listSources: listSources,
            sourceKind: sourceKind,
            screenIndex: screenIndex,
            appName: appName,
            appBundleID: appBundleID,
            area: captureArea,
            fps: fps,
            showCursor: showCursor,
            durationMilliseconds: durationMs,
            bitrate: bitrate,
            keyFrameInterval: keyframeInterval,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            videoFD: videoFD,
            systemAudioFD: systemAudioFD,
            inputAudioFD: inputAudioFD,
            controlFD: controlFD,
            captureSystemAudio: captureSystemAudio,
            captureInputAudio: captureInputAudio,
            inputDeviceID: inputDeviceID,
            ipcSocket: ipcSocket,
            ipcPort: ipcPort,
            sourceId: sourceId,
            captureProcessAudio: captureProcessAudio,
            audioTapPID: audioTapPid,
            audioTapApp: audioTapApp,
            processAudioFD: processAudioFD,
            skipVideo: noVideo,
            captureWebcam: captureWebcam,
            webcamDeviceID: webcamDeviceID,
            webcamFPS: webcamFPS,
            webcamWidth: webcamWidth,
            webcamHeight: webcamHeight,
            webcamVideoFD: webcamVideoFD,
            premuxMPEGTS: premux,
            dumpOutputPath: dumpOutput,
            srtUrl: srtUrl,
            srtLatencyMs: srtLatencyMs,
            srtStreamId: srtStreamId,
            rtmpUrl: rtmpUrl
        )

        if !configuration.listSources {
            try configuration.validate()
        }

        return configuration
    }

    private func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
