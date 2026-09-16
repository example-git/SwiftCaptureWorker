import Foundation
import CoreMedia

/// Single source of truth for "now" and the authoritative origin that every
/// registered stream is expressed relative to.
///
/// The `hostOrigin` is set on the FIRST sample of ANY registered stream — after
/// that it is immutable for the life of the clock (unless `reanchor` is invoked
/// by an explicit clock-glitch recovery path). This guarantees that the relative
/// offset between two streams is preserved rather than rebased to zero per stream.
final class MasterClock: @unchecked Sendable {
    let hostClock: CMClock
    private var hostOriginValue: CMTime = .invalid
    private let lock = NSLock()

    init(hostClock: CMClock = CMClockGetHostTimeClock()) {
        self.hostClock = hostClock
    }

    /// Current host-clock time.
    func now() -> CMTime {
        return CMClockGetTime(hostClock)
    }

    /// Install `hostTime` as the origin iff no origin has been set yet. Idempotent.
    /// Returns the effective origin (either the one we just set, or the
    /// previously-set one).
    @discardableResult
    func setOriginIfNeeded(hostTime: CMTime) -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        if !hostOriginValue.isValid {
            hostOriginValue = hostTime
        }
        return hostOriginValue
    }

    /// Current origin, or `.invalid` if the first sample has not yet arrived.
    var hostOrigin: CMTime {
        lock.lock()
        defer { lock.unlock() }
        return hostOriginValue
    }

    /// Host-domain time elapsed since origin, or `.invalid` if origin not yet set.
    func elapsedSinceOrigin(hostTime: CMTime) -> CMTime {
        lock.lock()
        let origin = hostOriginValue
        lock.unlock()
        guard origin.isValid, hostTime.isValid else { return .invalid }
        return CMTimeSubtract(hostTime, origin)
    }

    /// Replace the current origin with a fresh one. Only used by clock-glitch
    /// recovery (see SyncCoordinator edge case #6).
    func reanchor(newHostTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        hostOriginValue = newHostTime
    }
}
