import Foundation

/// Rolled-up latency numbers for one host (plan §5, `LiveSummary`).
public struct PingStat: Codable, Sendable, Equatable {
    public var min: Double
    public var avg: Double
    public var max: Double
    public var jitter: Double
    public var p50: Double
    public var p95: Double
    public var p99: Double
    /// Successful replies this stat was built from.
    public var samples: Int

    public init(
        min: Double = 0, avg: Double = 0, max: Double = 0, jitter: Double = 0,
        p50: Double = 0, p95: Double = 0, p99: Double = 0, samples: Int = 0
    ) {
        self.min = min
        self.avg = avg
        self.max = max
        self.jitter = jitter
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.samples = samples
    }
}

/// Incremental latency stats for one host: feeds each reply's RTT into a
/// ``RunningStats`` and a ``LatencyHistogram`` and hands back a ``PingStat``.
/// Timeouts call ``recordTimeout()`` so jitter doesn't jump across the gap.
public struct HostLatencyAccumulator: Sendable {
    private var running = RunningStats()
    private var histogram = LatencyHistogram()

    public init() {}

    public mutating func record(rttMs: Double) {
        running.add(rttMs)
        histogram.add(rttMs)
    }

    public mutating func recordTimeout() {
        running.markGap()
    }

    public var stat: PingStat {
        PingStat(
            min: running.minOrZero,
            avg: running.mean,
            max: running.maxOrZero,
            jitter: running.jitter,
            p50: histogram.p50,
            p95: histogram.p95,
            p99: histogram.p99,
            samples: running.count
        )
    }
}
