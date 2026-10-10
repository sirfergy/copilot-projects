import Foundation

/// A clock that starts at `start` and advances with monotonic elapsed time.
///
/// Trackers publish snapshots at any moment, so a time taken before a snapshot
/// file is read can precede that snapshot's own timestamp and make it look
/// future-dated, and therefore stale. Judging each read with this clock keeps
/// an injected `start` deterministic while never placing a read earlier than it
/// happened.
func advancingClock(from start: Date) -> () -> Date {
    let started = ContinuousClock.now
    return {
        let (seconds, attoseconds) = started.duration(to: .now).components
        return start.addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18)
    }
}
