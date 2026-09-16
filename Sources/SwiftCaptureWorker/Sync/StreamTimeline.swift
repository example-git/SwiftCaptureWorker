import Foundation
import CoreMedia

/// Identifies a logical stream lane participating in sync.
enum StreamID: Hashable, CustomStringConvertible {
    case screenVideo
    case webcamVideo
    case screenSystemAudio
    case micAudio
    case processAudio

    var description: String {
        switch self {
        case .screenVideo:       return "screenVideo"
        case .webcamVideo:       return "webcamVideo"
        case .screenSystemAudio: return "screenSystemAudio"
        case .micAudio:          return "micAudio"
        case .processAudio:      return "processAudio"
        }
    }
}

enum StreamKind {
    case video
    case audio
}

/// Opaque handle used by the coordinator's callers to refer to a registered
/// stream without exposing internal storage.
struct StreamHandle: Hashable {
    let id: StreamID
}

/// Small rolling-window estimator for input PTS deltas. Used only for
/// diagnostics / sanity checks; the encoder remains the source of truth for
/// output cadence.
struct CadenceEstimator {
    private var samples: [Double] = []
    private let capacity: Int

    init(capacity: Int = 30) {
        self.capacity = capacity
    }

    mutating func record(deltaSeconds: Double) {
        guard deltaSeconds.isFinite, deltaSeconds > 0 else { return }
        samples.append(deltaSeconds)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    var medianSeconds: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    var isStable: Bool { samples.count >= capacity }
}

/// Per-stream bookkeeping — one instance per registered stream.
final class StreamTimeline {
    let id: StreamID
    let kind: StreamKind
    let sourceClock: CMClock
    let nominalRateHz: Double

    var observedCadence = CadenceEstimator()
    /// 90 kHz tick value of the most recently emitted PTS. `-1` until first emit.
    var lastEmittedPTSTicks: Int64 = -1
    /// 90 kHz tick value of the most recently emitted DTS. `-1` until first emit.
    var lastEmittedDTSTicks: Int64 = -1
    /// Output timescale — always 90 kHz for MPEG-TS.
    let outputTimescale: CMTimeScale = 90_000
    var framesEmitted: Int64 = 0
    var discontinuityCount: Int = 0

    /// Last raw input PTS we saw. Used for cadence-delta estimation.
    var lastRawInputPTS: CMTime = .invalid

    init(id: StreamID, kind: StreamKind, sourceClock: CMClock, nominalRateHz: Double) {
        self.id = id
        self.kind = kind
        self.sourceClock = sourceClock
        self.nominalRateHz = nominalRateHz
    }
}
