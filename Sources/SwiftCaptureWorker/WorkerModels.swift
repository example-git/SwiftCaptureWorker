import Foundation
import CoreGraphics
import CoreMedia
import ArgumentParser

enum WorkerError: LocalizedError {
    case invalidArgument(String)
    case unsupported(String)
    case notFound(String)
    case captureFailed(String)
    case encodingFailed(String)
    case ioFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArgument(let message),
             .unsupported(let message),
             .notFound(let message),
             .captureFailed(let message),
             .encodingFailed(let message),
             .ioFailed(let message):
            return message
        }
    }
}

struct CaptureArea: Equatable {
    let rect: CGRect

    static func parse(_ value: String) throws -> CaptureArea {
        let parts = value.split(separator: ":")
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3]),
              width > 0,
              height > 0 else {
            throw WorkerError.invalidArgument(
                "Invalid --area value '\(value)'. Expected x:y:width:height with positive width/height."
            )
        }

        return CaptureArea(rect: CGRect(x: x, y: y, width: width, height: height))
    }
}

struct WorkerConfiguration {
    let listSources: Bool
    let sourceKind: SourceKind
    let screenIndex: Int
    let appName: String?
    let appBundleID: String?
    let area: CaptureArea?
    let fps: Int
    let showCursor: Bool
    let durationMilliseconds: Int?
    let bitrate: Int?
    let keyFrameInterval: Int?
    let outputWidth: Int?
    let outputHeight: Int?
    let videoFD: Int32
    let systemAudioFD: Int32?
    let inputAudioFD: Int32?
    let controlFD: Int32?
    let captureSystemAudio: Bool
    let captureInputAudio: Bool
    let inputDeviceID: String?
    let ipcSocket: String?
    let ipcPort: Int?
    let sourceId: String?
    let captureProcessAudio: Bool
    let audioTapPID: Int32?
    let audioTapApp: String?
    let processAudioFD: Int32?
    let skipVideo: Bool
    let captureWebcam: Bool
    let webcamDeviceID: String?
    let webcamFPS: Int
    let webcamWidth: Int?
    let webcamHeight: Int?
    let webcamVideoFD: Int32?
    let premuxMPEGTS: Bool
    let dumpOutputPath: String?

    // SRT native uplink
    let srtUrl: String?
    let srtLatencyMs: Int
    let srtStreamId: String?

    // RTMP native uplink
    let rtmpUrl: String?

    /// True when output goes through a shared IPC transport rather than per-stream FDs.
    var isIPCMode: Bool { ipcSocket != nil || ipcPort != nil }

    /// True when an SCStream must be started (screen video or SCStream-based system audio).
    /// Webcam video does NOT use SCStream — it uses AVCaptureSession.
    var needsSCStream: Bool { (!skipVideo && !captureWebcam) || captureSystemAudio }

    /// True when at least one video source (screen or webcam) is active.
    var hasAnyVideo: Bool { !skipVideo || captureWebcam }

    func validate() throws {
        if let bitRate = bitrate, bitRate <= 0 {
            throw WorkerError.invalidArgument("Invalid --bitrate value \(bitRate). The bitrate must be greater than zero.")
        }

        if ipcSocket != nil && ipcPort != nil {
            throw WorkerError.invalidArgument("Use either --ipc-socket or --ipc-port, not both.")
        }

        if srtUrl != nil && dumpOutputPath != nil {
            throw WorkerError.invalidArgument("Use either --srt-url or --dump-output, not both.")
        }
        if rtmpUrl != nil && dumpOutputPath != nil {
            throw WorkerError.invalidArgument("Use either --rtmp-url or --dump-output, not both.")
        }
        if rtmpUrl != nil && srtUrl != nil {
            throw WorkerError.invalidArgument("Use either --rtmp-url or --srt-url, not both.")
        }

        if isIPCMode {
            // In IPC mode all streams go over the socket; per-stream FDs are illegal.
            let hasAnyFD = videoFD != 1
                        || systemAudioFD    != nil
                        || inputAudioFD     != nil
                        || controlFD        != nil
                        || processAudioFD   != nil
                        || webcamVideoFD    != nil
            if hasAnyFD {
                throw WorkerError.invalidArgument(
                    "--ipc-socket / --ipc-port cannot be combined with " +
                    "--video-fd, --system-audio-fd, --input-audio-fd, " +
                    "--control-fd, --process-audio-fd, or --webcam-video-fd.")
            }
        }

        // When capturing webcam, treat screen capture as disabled
        let effectiveSkipVideo = skipVideo || captureWebcam

        if effectiveSkipVideo {
            let hasVideoOnlyFlags = bitrate != nil || outputWidth != nil || outputHeight != nil
                                 || area != nil || appName != nil || appBundleID != nil
            if hasVideoOnlyFlags && !captureWebcam {
                throw WorkerError.invalidArgument(
                    "--no-video cannot be combined with --bitrate, --output-width/height, " +
                    "--area, --app-name, or --app-bundle-id.")
            }
            let hasAnyCaptureStream = captureSystemAudio || captureInputAudio || captureProcessAudio || captureWebcam
            if !hasAnyCaptureStream {
                throw WorkerError.invalidArgument(
                    "--no-video requires at least one other capture flag: " +
                    "--capture-system-audio, --capture-input-audio, --capture-process-audio, or --capture-webcam.")
            }
        }

        guard effectiveSkipVideo || [15, 30, 60].contains(fps) else {
            throw WorkerError.invalidArgument("Invalid --fps value \(fps). Valid values are 15, 30, or 60.")
        }

        if let durationMilliseconds, durationMilliseconds < 100 {
            throw WorkerError.invalidArgument("Invalid --duration-ms value \(durationMilliseconds). Minimum is 100.")
        }

        if let w = outputWidth, w < 128 { throw WorkerError.invalidArgument("--output-width must be >= 128.") }
        if let h = outputHeight, h < 128 { throw WorkerError.invalidArgument("--output-height must be >= 128.") }
        if (outputWidth == nil) != (outputHeight == nil) {
            throw WorkerError.invalidArgument("Both --output-width and --output-height must be specified together.")
        }

        guard screenIndex >= 1 else {
            throw WorkerError.invalidArgument("Invalid --screen-index value \(screenIndex). Indices are 1-based.")
        }

        if appName != nil && appBundleID != nil {
            throw WorkerError.invalidArgument("Use either --app-name or --app-bundle-id, not both.")
        }

        if area != nil && (appName != nil || appBundleID != nil) {
            throw WorkerError.invalidArgument("The --area option is only supported for display capture, not app capture.")
        }

        if captureSystemAudio && systemAudioFD == nil && !isIPCMode && dumpOutputPath == nil && srtUrl == nil && rtmpUrl == nil {
            throw WorkerError.invalidArgument("System audio capture requires --system-audio-fd (or --ipc-socket / --ipc-port).")
        }

        if captureInputAudio && inputAudioFD == nil && !isIPCMode && !premuxMPEGTS && dumpOutputPath == nil && srtUrl == nil && rtmpUrl == nil {
            throw WorkerError.invalidArgument("Input audio capture requires --input-audio-fd (or --ipc-socket / --ipc-port).")
        }

        if !captureSystemAudio && systemAudioFD != nil {
            throw WorkerError.invalidArgument("--system-audio-fd was provided without --capture-system-audio.")
        }

        if !captureInputAudio && inputAudioFD != nil {
            throw WorkerError.invalidArgument("--input-audio-fd was provided without --capture-input-audio.")
        }

        if inputDeviceID != nil && !captureInputAudio {
            throw WorkerError.invalidArgument("--input-device-id requires --capture-input-audio.")
        }

        if captureProcessAudio {
            if audioTapPID == nil && audioTapApp == nil {
                throw WorkerError.invalidArgument("--capture-process-audio requires --audio-tap-pid or --audio-tap-app.")
            }
            if audioTapPID != nil && audioTapApp != nil {
                throw WorkerError.invalidArgument("Use either --audio-tap-pid or --audio-tap-app, not both.")
            }
            if processAudioFD == nil && !isIPCMode && dumpOutputPath == nil && srtUrl == nil && rtmpUrl == nil {
                throw WorkerError.invalidArgument("Process audio capture requires --process-audio-fd (or --ipc-socket / --ipc-port).")
            }
        }

        if !captureProcessAudio && processAudioFD != nil {
            throw WorkerError.invalidArgument("--process-audio-fd was provided without --capture-process-audio.")
        }

        if captureWebcam {
            guard webcamFPS > 0 else {
                throw WorkerError.invalidArgument("Invalid --webcam-fps value \(webcamFPS). Must be a positive integer.")
            }
            if let w = webcamWidth, w < 128 { throw WorkerError.invalidArgument("--webcam-width must be >= 128.") }
            if let h = webcamHeight, h < 128 { throw WorkerError.invalidArgument("--webcam-height must be >= 128.") }
            if (webcamWidth == nil) != (webcamHeight == nil) {
                throw WorkerError.invalidArgument("Both --webcam-width and --webcam-height must be specified together.")
            }
            if webcamVideoFD == nil && !isIPCMode && !premuxMPEGTS && dumpOutputPath == nil && srtUrl == nil && rtmpUrl == nil {
                throw WorkerError.invalidArgument("Webcam capture requires --webcam-video-fd (or --ipc-socket / --ipc-port).")
            }
        }

        if !captureWebcam && webcamVideoFD != nil {
            throw WorkerError.invalidArgument("--webcam-video-fd was provided without --capture-webcam.")
        }

        if !captureWebcam && webcamDeviceID != nil {
            throw WorkerError.invalidArgument("--webcam-device-id requires --capture-webcam.")
        }


        let activeFDs = [
            skipVideo ? nil : Int32?(videoFD),
            systemAudioFD,
            inputAudioFD,
            controlFD,
            processAudioFD,
            webcamVideoFD
        ].compactMap { $0 }

        let uniqueFDs = Set(activeFDs)
        guard uniqueFDs.count == activeFDs.count else {
            throw WorkerError.invalidArgument("Active stream/control file descriptors must all be distinct.")
        }
    }
}

enum SourceKind: String, ExpressibleByArgument, Codable {
    case video
    case audio
    case all
}

struct DisplaySource: Codable {
    let index: Int
    let displayID: UInt32
    let electronSourceId: String
    let name: String
    let isPrimary: Bool
    let frame: RectJSON
    let scaleFactor: Double
}

struct AppSource: Codable {
    let name: String
    let bundleIdentifier: String
    let processID: Int32
    let windows: [WindowSource]
}

struct WindowSource: Codable {
    let windowID: UInt32
    let electronSourceId: String
    let title: String
    let frame: RectJSON
    let isOnScreen: Bool
}

struct AudioInputSource: Codable {
    let name: String
    let uniqueID: String
    let modelID: String?
    let connected: Bool
}

struct ProcessAudioSource: Codable {
    let name: String
    let bundleIdentifier: String
    let processID: Int32?
    let processIDs: [Int32]
    let bundleIdentifiers: [String]
    let processObjectCount: Int
}

struct WebcamSource: Codable {
    let name: String
    let uniqueID: String
    let modelID: String?
    let connected: Bool
    let formats: [WebcamFormat]
}

struct WebcamFormat: Codable {
    let width: Int
    let height: Int
    let minFPS: Double
    let maxFPS: Double
}

struct SourceDiscoveryResponse: Codable {
    let video: VideoSources?
    let audio: AudioSources?
    let webcams: [WebcamSource]?
}

struct VideoSources: Codable {
    let displays: [DisplaySource]
    let applications: [AppSource]
}

struct AudioSources: Codable {
    let systemAudioSupported: Bool
    let inputDevices: [AudioInputSource]
    let processes: [ProcessAudioSource]
}

struct RectJSON: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

struct VideoStreamConfiguration: Codable {
    let codec: String
    let width: Int
    let height: Int
    let fps: Int
    let bitRate: Int
    let format: String
    let gstreamerCaps: String
    let hardwareAccelerated: Bool
    let parameterSets: [String]
}

struct AudioStreamConfiguration: Codable {
    let codec: String
    let sampleRate: Double
    let channels: UInt32
    let bitsPerChannel: UInt32
    let bytesPerFrame: UInt32
    let framesPerPacket: UInt32
    let formatFlags: UInt32
    let gstreamerCaps: String
    let isInterleaved: Bool
}

enum PacketType: UInt8 {
    case configuration = 1
    case sample = 2
    case endOfStream = 3
    case error = 4
}

enum PacketFlags {
    static let keyFrame: UInt16 = 1 << 0
}

extension CMTime {
    var nanosecondsValue: UInt64 {
        guard isValid else { return 0 }
        let seconds = CMTimeGetSeconds(self)
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return UInt64(seconds * 1_000_000_000)
    }
}
