import Foundation

/// Fixed-bucket latency histogram for cheap percentiles (plan §8.1).
///
/// 1 ms buckets covering 0–999 ms, plus one overflow bucket for ≥ 1000 ms.
/// Fixed memory (1001 `Int`s), O(1) insert, nearest-rank percentiles in one
/// pass over the buckets.
public struct LatencyHistogram: Sendable, Equatable {
    public static let bucketCount = 1001 // 0…999 ms + overflow
    public static let overflowIndex = 1000

    private var buckets: [Int]
    public private(set) var count = 0

    public init() {
        buckets = Array(repeating: 0, count: Self.bucketCount)
    }

    public mutating func add(_ milliseconds: Double) {
        let index: Int
        if milliseconds >= 1000 {
            index = Self.overflowIndex
        } else if milliseconds <= 0 {
            index = 0
        } else {
            index = Int(milliseconds) // floor; e.g. 12.9 ms → bucket 12
        }
        buckets[index] += 1
        count += 1
    }

    /// Bulk insert of a bucket that was counted elsewhere — the shape a
    /// `GROUP BY CAST(ms AS INTEGER)` returns.
    ///
    /// This is what lets the Analysis screen build percentiles in SQLite
    /// without constructing a `PingSample`, while still going through the same
    /// nearest-rank rule the live path uses. Two implementations of a
    /// percentile would be two chances to disagree.
    public mutating func add(_ milliseconds: Double, count occurrences: Int) {
        guard occurrences > 0 else { return }
        let index: Int
        if milliseconds >= 1000 {
            index = Self.overflowIndex
        } else if milliseconds <= 0 {
            index = 0
        } else {
            index = Int(milliseconds)
        }
        buckets[index] += occurrences
        count += occurrences
    }

    /// One histogram covering every input — for a range's percentiles, which
    /// are over all of its sessions rather than an average of theirs.
    public static func merging(_ histograms: [LatencyHistogram]) -> LatencyHistogram {
        var out = LatencyHistogram()
        for histogram in histograms {
            for index in 0..<Self.bucketCount where histogram.buckets[index] > 0 {
                out.buckets[index] += histogram.buckets[index]
                out.count += histogram.buckets[index]
            }
        }
        return out
    }

    /// Nearest-rank percentile in milliseconds. `p` is 0…100.
    /// The overflow bucket reports as 1000. Returns 0 when empty.
    public func percentile(_ p: Double) -> Double {
        guard count > 0 else { return 0 }
        let clamped = Swift.min(Swift.max(p, 0), 100)
        // rank = ⌈p/100 · n⌉, at least 1
        let rank = Swift.max(1, Int((clamped / 100 * Double(count)).rounded(.up)))
        var cumulative = 0
        for index in 0..<Self.bucketCount {
            cumulative += buckets[index]
            if cumulative >= rank {
                return Double(index)
            }
        }
        return Double(Self.overflowIndex)
    }

    public var p50: Double { percentile(50) }
    public var p95: Double { percentile(95) }
    public var p99: Double { percentile(99) }
}
