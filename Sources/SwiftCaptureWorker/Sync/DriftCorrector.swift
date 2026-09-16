import Foundation
import CoreMedia

/// Stateless helpers that enforce per-stream monotonicity and flag
/// discontinuities.  All state lives on the caller's `StreamTimeline`.
enum DriftCorrector {
    /// Enforces strictly increasing PTS. If the proposed value has already been
    /// emitted (or is in the past), bump by one 90 kHz tick. Also flags large
    /// gaps as discontinuities (for diagnostics only — the caller is expected
    /// to pass the value through).
    static func sanitizePTS(
        proposedTicks: Int64,
        timeline: StreamTimeline
    ) -> Int64 {
        let last = timeline.lastEmittedPTSTicks
        if last < 0 {
            return proposedTicks
        }

        if proposedTicks <= last {
            return last + 1
        }

        // Detect huge gaps (> 4x nominal spacing). Increment counter; do not
        // clamp. A real pause is legitimate.
        if timeline.nominalRateHz > 0 {
            let expectedSpacingTicks = Int64((90_000.0 / timeline.nominalRateHz).rounded())
            let gap = proposedTicks - last
            if expectedSpacingTicks > 0 && gap > expectedSpacingTicks * 4 {
                timeline.discontinuityCount += 1
            }
        }
        return proposedTicks
    }

    /// Enforces dts <= pts and dts strictly increasing. If dts violates the
    /// ordering against the most recent dts, bump it by one tick. Clamps
    /// dts <= pts if the caller passed a later dts (should not happen with
    /// AllowFrameReordering = false).
    static func sanitizeDTS(
        proposedDTSTicks: Int64,
        ptsTicks: Int64,
        timeline: StreamTimeline
    ) -> Int64 {
        var dts = min(proposedDTSTicks, ptsTicks)
        if timeline.lastEmittedDTSTicks >= 0 && dts <= timeline.lastEmittedDTSTicks {
            dts = timeline.lastEmittedDTSTicks + 1
            if dts > ptsTicks {
                dts = ptsTicks
            }
        }
        return dts
    }
}
