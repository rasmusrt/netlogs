import Foundation

/// Drift-free repeating timer (plan §8.4).
///
/// `Timer` and hand-rolled `asyncAfter` re-scheduling both accumulate error
/// over an hours-long session because each fire schedules the next relative to
/// *now*. `DispatchSourceTimer` with a `repeating:` interval anchors every fire
/// to the original deadline (`start + n × interval`), so lateness stays bounded
/// by scheduler jitter and never grows.
public final class ScheduledTimer: @unchecked Sendable {

    /// One firing of the timer.
    public struct Tick: Sendable {
        /// 1-based, monotonic since `start()` — never resets, so it's a safe
        /// sample id even across a sleep/wake re-anchor.
        public let count: Int
        /// The wall-clock instant this tick represents, on a 1 Hz grid anchored
        /// at start (re-anchored to now if the Mac slept — see below). Use this
        /// as the sample timestamp.
        public let scheduledAt: Date
        /// The wall-clock instant the handler actually ran.
        public let firedAt: Date
        /// `firedAt − scheduledAt`. Bounded and roughly constant when the timer
        /// is behaving; a value that grows with `count` means drift.
        public var lateness: TimeInterval { firedAt.timeIntervalSince(scheduledAt) }
    }

    private let interval: Duration
    private let queue: DispatchQueue
    private let onTick: @Sendable (Tick) -> Void

    // All mutable state is touched only on `queue`.
    private var source: DispatchSourceTimer?
    private var count = 0
    /// The grid is `anchor + (count − anchorCount) × interval`. On a detected
    /// gap (the Mac slept: `DispatchTime` freezes, wall clock jumps) the anchor
    /// is moved to now so timestamps track reality instead of continuing from
    /// before the sleep.
    private var anchor: Date = .distantPast
    private var anchorCount = 0

    public init(
        interval: Duration,
        queue: DispatchQueue,
        onTick: @escaping @Sendable (Tick) -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.onTick = onTick
    }

    public func start() {
        queue.async { [self] in
            guard source == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            let now = Date()
            anchor = now
            anchorCount = 0
            count = 0
            let ns = interval.wholeNanoseconds
            t.schedule(
                deadline: .now() + .nanoseconds(ns),
                repeating: .nanoseconds(ns),
                leeway: .milliseconds(2)
            )
            t.setEventHandler { [self] in
                count += 1
                let firedAt = Date()
                var scheduled = anchor.addingTimeInterval(Double(count - anchorCount) * interval.timeInterval)

                // Gap → the machine slept (or a severe stall). Re-anchor so the
                // timestamp is ~now, not hours behind.
                if firedAt.timeIntervalSince(scheduled) > interval.timeInterval * 1.5 {
                    anchor = firedAt
                    anchorCount = count
                    scheduled = firedAt
                }
                onTick(Tick(count: count, scheduledAt: scheduled, firedAt: firedAt))
            }
            source = t
            t.resume()
        }
    }

    public func stop() {
        queue.sync { [self] in
            source?.cancel()
            source = nil
        }
    }

    deinit {
        source?.cancel()
    }
}
