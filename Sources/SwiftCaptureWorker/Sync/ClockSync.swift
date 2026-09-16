import Foundation
import CoreMedia

/// Translates a CMTime expressed on an arbitrary `CMClock` into the shared host
/// clock domain, with long-term drift tracking. One `ClockTranslator` per
/// source clock.
///
/// Design:
/// - `CMSyncConvertTime(src, src_clock, host_clock)` gives us the best
///   translation Core Media can provide at each call.
/// - `CMSyncGetRelativeRate` can tell us whether two clocks are running at the
///   same rate. We re-measure periodically (every ~2s) and if the rate has
///   materially shifted we compute a `residualOffsetTicks` that absorbs the
///   discontinuity so the emitted PTS is continuous.
final class ClockTranslator {
    let sourceClock: CMClock
    let hostClock: CMClock

    /// The most recently observed source→host relative rate (1.0 for identical).
    private(set) var relativeRate: Double = 1.0
    /// Accumulated affine correction applied on top of `CMSyncConvertTime`.
    /// Expressed in 90 kHz ticks.
    private(set) var residualOffsetTicks: Int64 = 0
    /// Host-clock time of the last `CMSyncGetRelativeRate` refresh.
    private var lastRemeasuredAt: CMTime = .invalid
    /// Marked true if Core Media refuses to translate; falls back to identity.
    private(set) var untrusted: Bool = false

    /// True when sourceClock and hostClock are the same object — no translation
    /// needed, and `toHost` is a pure pass-through.
    let isIdentity: Bool

    init(sourceClock: CMClock, hostClock: CMClock) {
        self.sourceClock = sourceClock
        self.hostClock = hostClock
        self.isIdentity = (sourceClock === hostClock)
    }

    /// Translate `sourcePTS` (on `sourceClock`) into the host clock domain.
    func toHost(_ sourcePTS: CMTime) -> CMTime {
        guard sourcePTS.isValid else { return .invalid }
        if isIdentity || untrusted {
            return sourcePTS
        }
        let raw = CMSyncConvertTime(sourcePTS, from: sourceClock, to: hostClock)
        guard raw.isValid else { return sourcePTS } // defensive
        if residualOffsetTicks == 0 {
            return raw
        }
        let residual = CMTime(value: residualOffsetTicks, timescale: 90_000)
        return CMTimeAdd(raw, residual)
    }

    /// Re-measure the relative rate if `now - lastRemeasuredAt >= interval`.
    /// Returns true if a measurement was actually performed.
    @discardableResult
    func remeasureIfDue(now: CMTime, interval: CMTime = CMTime(value: 2, timescale: 1)) -> Bool {
        guard !isIdentity, !untrusted else { return false }
        if lastRemeasuredAt.isValid {
            let elapsed = CMTimeSubtract(now, lastRemeasuredAt)
            if CMTimeCompare(elapsed, interval) < 0 {
                return false
            }
        }

        // CMSyncGetRelativeRate returns the rate of `ofClock` relative to
        // `relativeToClock`. We want source's rate relative to host: how fast
        // does the source clock run compared to host? Returns 0.0 if either
        // clock is invalid or the two cannot be correlated.
        let rate = CMSyncGetRelativeRate(sourceClock, relativeTo: hostClock)
        guard rate != 0 else {
            // Core Media refused to correlate — mark untrusted and fall back
            // to identity translation.
            untrusted = true
            return false
        }

        // Compute residual so the translated value at `now` is continuous across
        // the rate change. We use a simple approach: sample the current
        // sourceClock time, translate under both the OLD and NEW effective
        // cached views, and accumulate the delta into residualOffsetTicks.
        let sourceNow = CMSyncConvertTime(now, from: hostClock, to: sourceClock)
        let translatedNow = CMSyncConvertTime(sourceNow, from: sourceClock, to: hostClock)
        // Without our residual, translatedNow ≈ now. The affine correction we
        // want is whatever keeps successive translations continuous given the
        // PRIOR residualOffsetTicks. If the new translation moved by delta vs
        // the prior cached translation, we subtract that delta from the
        // residual so the output stays put.
        let deltaTicks = CMTimeConvertScale(
            CMTimeSubtract(translatedNow, now),
            timescale: 90_000,
            method: .roundHalfAwayFromZero
        ).value
        residualOffsetTicks -= deltaTicks
        relativeRate = Double(rate)
        lastRemeasuredAt = now
        return true
    }
}

/// Holds one `ClockTranslator` per unique source clock and provides the facade
/// the coordinator uses.
final class ClockSync {
    let hostClock: CMClock
    private var translators: [ObjectIdentifier: ClockTranslator] = [:]
    private let lock = NSLock()

    init(hostClock: CMClock) {
        self.hostClock = hostClock
    }

    /// Get (or lazily create) the translator for `source`.
    func translator(for source: CMClock) -> ClockTranslator {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(source)
        if let existing = translators[key] {
            return existing
        }
        let made = ClockTranslator(sourceClock: source, hostClock: hostClock)
        translators[key] = made
        return made
    }

    /// Translate a source-clock PTS into the host clock domain.
    func toHost(_ sourcePTS: CMTime, from source: CMClock) -> CMTime {
        return translator(for: source).toHost(sourcePTS)
    }

    /// Re-measure drift for every non-identity translator.
    func remeasureAll(now: CMTime) {
        lock.lock()
        let all = Array(translators.values)
        lock.unlock()
        for t in all {
            t.remeasureIfDue(now: now)
        }
    }
}
