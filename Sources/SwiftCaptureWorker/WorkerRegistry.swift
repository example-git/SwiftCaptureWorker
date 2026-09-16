import Foundation

/// Registry entry written by each worker process for discovery by UI sessions.
struct WorkerRegistryEntry: Codable {
    let pid: Int32
    let ipcType: IPCType
    let startTime: Date
    let configuration: WorkerConfigurationSnapshot

    enum IPCType: Codable {
        case unixSocket(String)
        case tcp(Int)

        enum CodingKeys: String, CodingKey {
            case type
            case path
            case port
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "unix":
                let path = try container.decode(String.self, forKey: .path)
                self = .unixSocket(path)
            case "tcp":
                let port = try container.decode(Int.self, forKey: .port)
                self = .tcp(port)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown IPC type: \(type)"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .unixSocket(let path):
                try container.encode("unix", forKey: .type)
                try container.encode(path, forKey: .path)
            case .tcp(let port):
                try container.encode("tcp", forKey: .type)
                try container.encode(port, forKey: .port)
            }
        }
    }
}

/// Snapshot of worker configuration for registry/info purposes.
struct WorkerConfigurationSnapshot: Codable {
    // Video source
    let screenIndex: Int?
    let appName: String?
    let appBundleID: String?
    let sourceId: String?
    let area: String?
    let showCursor: Bool
    let skipVideo: Bool

    // Video encoding
    let fps: Int?
    let bitrate: Int?
    let keyFrameInterval: Int?
    let outputWidth: Int?
    let outputHeight: Int?

    // Audio capture
    let captureSystemAudio: Bool
    let captureInputAudio: Bool
    let inputDeviceID: String?
    let captureProcessAudio: Bool
    let audioTapPID: Int32?
    let audioTapApp: String?

    // Webcam
    let captureWebcam: Bool
    let webcamDeviceID: String?
    let webcamFPS: Int?
    let webcamWidth: Int?
    let webcamHeight: Int?

    // Output
    let premuxMPEGTS: Bool
    let dumpOutputPath: String?
    let srtUrl: String?
    let srtLatencyMs: Int?
    let srtStreamId: String?
    let rtmpUrl: String?

    init(from config: WorkerConfiguration) {
        self.screenIndex = config.skipVideo ? nil : config.screenIndex
        self.appName = config.appName
        self.appBundleID = config.appBundleID
        self.sourceId = config.sourceId
        self.area = config.area.map { "\($0.rect.origin.x):\($0.rect.origin.y):\($0.rect.width):\($0.rect.height)" }
        self.showCursor = config.showCursor
        self.skipVideo = config.skipVideo

        self.fps = config.skipVideo ? nil : config.fps
        self.bitrate = config.bitrate
        self.keyFrameInterval = config.keyFrameInterval
        self.outputWidth = config.outputWidth
        self.outputHeight = config.outputHeight

        self.captureSystemAudio = config.captureSystemAudio
        self.captureInputAudio = config.captureInputAudio
        self.inputDeviceID = config.inputDeviceID
        self.captureProcessAudio = config.captureProcessAudio
        self.audioTapPID = config.audioTapPID
        self.audioTapApp = config.audioTapApp

        self.captureWebcam = config.captureWebcam
        self.webcamDeviceID = config.webcamDeviceID
        self.webcamFPS = config.captureWebcam ? config.webcamFPS : nil
        self.webcamWidth = config.webcamWidth
        self.webcamHeight = config.webcamHeight

        self.premuxMPEGTS = config.premuxMPEGTS
        self.dumpOutputPath = config.dumpOutputPath
        self.srtUrl = config.srtUrl != nil ? "[REDACTED]" : nil
        self.srtLatencyMs = config.srtUrl != nil ? config.srtLatencyMs : nil
        self.srtStreamId = config.srtStreamId != nil ? "[REDACTED]" : nil
        self.rtmpUrl = config.rtmpUrl != nil ? "[REDACTED]" : nil
    }
}

/// Manages worker process registry for cross-session discovery.
enum WorkerRegistry {
    private static let registryDir = "/tmp"

    /// Register this worker process. Call on startup after IPC is bound.
    static func register(pid: Int32, ipcType: WorkerRegistryEntry.IPCType, config: WorkerConfiguration) throws {
        let entry = WorkerRegistryEntry(
            pid: pid,
            ipcType: ipcType,
            startTime: Date(),
            configuration: WorkerConfigurationSnapshot(from: config)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let path = registryPath(for: pid)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Unregister this worker process. Call on clean shutdown.
    static func unregister(pid: Int32) {
        let path = registryPath(for: pid)
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Discover all currently registered worker processes.
    /// Filters out stale entries (PIDs that are no longer running).
    static func discoverWorkers() -> [WorkerRegistryEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: registryDir) else {
            return []
        }

        let registryFiles = files.filter { $0.hasPrefix("swiftcapture-registry-") && $0.hasSuffix(".json") }
        var entries: [WorkerRegistryEntry] = []

        for file in registryFiles {
            let path = "\(registryDir)/\(file)"
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                continue
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let entry = try? decoder.decode(WorkerRegistryEntry.self, from: data) else {
                // Corrupt or incompatible registry file, skip it
                continue
            }

            // Check if the PID is still running
            if isProcessRunning(pid: entry.pid) {
                entries.append(entry)
            } else {
                // Stale entry, clean it up
                try? fm.removeItem(atPath: path)
            }
        }

        return entries
    }

    /// Query a specific worker's registry entry by PID.
    static func queryWorker(pid: Int32) -> WorkerRegistryEntry? {
        let path = registryPath(for: pid)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WorkerRegistryEntry.self, from: data)
    }

    private static func registryPath(for pid: Int32) -> String {
        return "\(registryDir)/swiftcapture-registry-\(pid).json"
    }

    private static func isProcessRunning(pid: Int32) -> Bool {
        // Send signal 0 to check if the process exists without affecting it
        return kill(pid, 0) == 0
    }
}
