import Foundation

/// The replies from one host that arrived after the deadline but before the
/// pinger gave up (``PingOutcome/lateReply(rttMs:)``).
///
/// Kept apart from ``PingStat`` rather than folded into it, deliberately.
/// `PingStat` answers "how fast was this host when it answered in time", and a
/// late reply is not that — mixing them in would move a session's average and
/// percentiles by an amount that depends on the timeout, which is a setting.
///
/// What this adds is the one thing the old data could not say. A session that
/// reported 14 failures had a maximum RTT of 1942 ms against a 2000 ms timeout:
/// the distribution was clipped at the deadline, so the numbers describing the
/// worst moments of the session were the numbers from just *before* the worst
/// moments. ``worst`` is the first figure that reaches past it.
public struct LateReplies: Codable, Sendable, Equatable {
    /// How many replies missed the deadline and were caught anyway.
    public var count: Int
    /// Fastest and slowest of them, in ms. Both are by definition above the
    /// ping timeout. `nil` when `count == 0`.
    public var min: Double?
    public var max: Double?
    public var sum: Double

    public init(count: Int = 0, min: Double? = nil, max: Double? = nil, sum: Double = 0) {
        self.count = count
        self.min = min
        self.max = max
        self.sum = sum
    }

    public var mean: Double? { count > 0 ? sum / Double(count) : nil }

    public mutating func record(rttMs: Double) {
        count += 1
        sum += rttMs
        min = min.map { Swift.min($0, rttMs) } ?? rttMs
        max = max.map { Swift.max($0, rttMs) } ?? rttMs
    }

    /// The slowest round trip actually observed for this host, timely or late.
    ///
    /// Pass the host's `PingStat.max`. This is the figure to quote when asking
    /// "how bad did it get" — `PingStat.max` alone cannot exceed the timeout,
    /// so on any session with late replies it understates the peak by
    /// construction.
    public func worst(timelyMax: Double) -> Double {
        Swift.max(timelyMax, max ?? 0)
    }
}
