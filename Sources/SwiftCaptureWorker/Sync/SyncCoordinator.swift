import Foundation
import CoreMedia

/// Single event shape reported to `SyncDiagnosticsSink`.
struct SyncDiagnosticsEvent {
    let streamID: StreamID
    let rawPTS: CMTime
    let normalizedPTS: CMTime
    let driftCorrectionTicks: Int64
    let ts: CMTime   // host-clock time of the event
}

protocol SyncDiagnosticsSink: AnyObject {
    func record(_ event: SyncDiagnosticsEvent)
}

/// The public entry point used by `CaptureSession`. Owns a `MasterClock`,
/// a `ClockSync`, and one `StreamTimeline` per registered stream.
///
/// All state-mutating paths take a single internal `NSLock`. Lock is held only
/// for pointer-level updates and O(1) CMTime arithmetic — not across any I/O.
final class SyncCoordinator: @unchecked Sendable {
    let masterClock: MasterClock
    private let clockSync: ClockSync
    private var timelines: [StreamID: StreamTimeline] = [:]
    private let lock = NSLock()

    weak var diagnostics: SyncDiagnosticsSink?

    init(masterClock: MasterClock = MasterClock()) {
        self.masterClock = masterClock
        self.clockSync = ClockSync(hostClock: masterClock.hostClock)
    }

    // MARK: - Registration

    /// Register a stream lane. Safe to call multiple times for the same id —
    /// the first registration wins (subsequent calls return the existing handle).
    @discardableResult
    func registerStream(
        id: StreamID,
        kind: StreamKind,
        sourceClock: CMClock,
        nominalRateHz: Double
    ) -> StreamHandle {
        lock.lock()
        defer { lock.unlock() }
        if timelines[id] == nil {
            timelines[id] = StreamTimeline(
                id: id,
                kind: kind,
                sourceClock: sourceClock,
                nominalRateHz: nominalRateHz
            )
        }
        return StreamHandle(id: id)
    }

    // MARK: - Normalization (the hot path)

    /// Translate a sample's raw PTS into a host-domain, master-origin-relative
    /// CMTime on the 90 kHz grid.
    ///
    /// The FIRST call on ANY registered stream establishes `hostOrigin`. This
    /// means the first stream starts at approx 0 and all others start at their
    /// true wall-clock offset relative to the first.
    func normalize(rawPTS: CMTime, handle: StreamHandle) -> CMTime {
        guard rawPTS.isValid else {
            return .invalid
        }

        lock.lock()
        guard let timeline = timelines[handle.id] else {
            lock.unlock()
            return .invalid
        }

        // Cadence-delta bookkeeping (diagnostics only).
        if timeline.lastRawInputPTS.isValid {
            let delta = CMTimeSubtract(rawPTS, timeline.lastRawInputPTS)
            let deltaSeconds = CMTimeGetSeconds(delta)
            timeline.observedCadence.record(deltaSeconds: deltaSeconds)
        }
        timeline.lastRawInputPTS = rawPTS

        // 1. Translate into host clock.
        let translator = clockSync.translator(for: timeline.sourceClock)
        let hostPTS = translator.toHost(rawPTS)

        // 2. Install origin if needed.
        let origin = masterClock.setOriginIfNeeded(hostTime: hostPTS)

        // 3. Express relative to master origin.
        let relative = CMTimeSubtract(hostPTS, origin)

        // 4. Quantize to 90 kHz grid.
        let relativeTicks = CMTimeConvertScale(
            relative,
            timescale: 90_000,
            method: .roundHalfAwayFromZero
        ).value

        // 5. Monotonic sanitization.
        let ticks = DriftCorrector.sanitizePTS(proposedTicks: relativeTicks, timeline: timeline)
        let driftCorrection = ticks - relativeTicks
        timeline.lastEmittedPTSTicks = ticks
        timeline.framesEmitted += 1

        let normalized = CMTime(value: ticks, timescale: 90_000)

        // Diagnostics OUTSIDE the critical section — capture what we need first.
        let diagEvent = SyncDiagnosticsEvent(
            streamID: timeline.id,
            rawPTS: rawPTS,
            normalizedPTS: normalized,
            driftCorrectionTicks: driftCorrection,
            ts: masterClock.now()
        )
        lock.unlock()
        diagnostics?.record(diagEvent)

        return normalized
    }

    /// Sanitize a DTS against the same stream's most recently emitted DTS and
    /// the provided PTS. Call AFTER `normalize(rawPTS:)` for the same sample.
    func sanitizeDTS(proposedDTSTicks: Int64, ptsTicks: Int64, handle: StreamHandle) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let timeline = timelines[handle.id] else {
            return ptsTicks
        }
        let dts = DriftCorrector.sanitizeDTS(
            proposedDTSTicks: proposedDTSTicks,
            ptsTicks: ptsTicks,
            timeline: timeline
        )
        timeline.lastEmittedDTSTicks = dts
        return dts
    }

    // MARK: - Drift measurement

    /// Called periodically (e.g. every 2s) to refresh cross-clock rate estimates.
    func tickDriftMeasurement() {
        clockSync.remeasureAll(now: masterClock.now())
    }

    // MARK: - Diagnostics & stats

    func timelineSnapshot(for id: StreamID) -> (framesEmitted: Int64, discontinuities: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let t = timelines[id] else { return nil }
        return (t.framesEmitted, t.discontinuityCount)
    }
}
