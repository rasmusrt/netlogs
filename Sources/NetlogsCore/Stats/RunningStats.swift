import Foundation

/// O(1)-per-sample min / max / mean / jitter (plan §8.1).
///
/// Jitter is the running mean of the absolute difference between *consecutive*
/// samples. A gap (a timeout between two replies) is not a jitter spike —
/// call ``markGap()`` so the next value isn't differenced against a stale one.
public struct RunningStats: Sendable, Equatable {
    public private(set) var count = 0
    public private(set) var min = Double.infinity
    public private(set) var max = -Double.infinity

    private var sum = 0.0
    private var previous: Double?
    private var jitterSum = 0.0
    private var jitterCount = 0

    public init() {}

    public mutating func add(_ value: Double) {
        count += 1
        sum += value
        if value < min { min = value }
        if value > max { max = value }
        if let previous {
            jitterSum += abs(value - previous)
            jitterCount += 1
        }
        previous = value
    }

    /// Record that the stream skipped a sample (e.g. a timeout), so the next
    /// ``add(_:)`` does not count the jump across the gap as jitter.
    public mutating func markGap() {
        previous = nil
    }

    public var mean: Double { count > 0 ? sum / Double(count) : 0 }

    /// `nil` until two replies have arrived without a gap between them.
    ///
    /// Jitter needs a *pair* to exist at all, so "no pair yet" and "the two
    /// replies were identical" are different facts. ``jitter`` flattens them to
    /// 0, which is right for a card that already guards on a sample count;
    /// anything that stores or averages the number wants this one.
    public var measuredJitter: Double? {
        jitterCount > 0 ? jitterSum / Double(jitterCount) : nil
    }

    public var jitter: Double { measuredJitter ?? 0 }

    /// `min`/`max` normalised to 0 when nothing has been added.
    public var minOrZero: Double { count > 0 ? min : 0 }
    public var maxOrZero: Double { count > 0 ? max : 0 }
}
