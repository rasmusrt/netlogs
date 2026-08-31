import Foundation

/// Folds a stream of ``PingSample`` into a ``LiveSummary`` incrementally —
/// O(1) per sample, never recomputed from history (plan §8.1).
public struct LiveSummaryBuilder: Sendable {
    private var router = HostLatencyAccumulator()
    private var internet = HostLatencyAccumulator()
    private var total = 0
    private var routerTimeouts = 0
    private var internetTimeouts = 0
    private var failed = 0

    public private(set) var firstSampleAt: Date?
    public private(set) var lastSampleAt: Date?

    public init() {}

    public mutating func add(_ sample: PingSample) {
        total += 1
        if firstSampleAt == nil { firstSampleAt = sample.timestamp }
        lastSampleAt = sample.timestamp

        if let ms = sample.routerMs { router.record(rttMs: ms) }
        else { router.recordTimeout(); routerTimeouts += 1 }

        if let ms = sample.internetMs { internet.record(rttMs: ms) }
        else { internet.recordTimeout(); internetTimeouts += 1 }

        if sample.routerMs == nil || sample.internetMs == nil { failed += 1 }
    }

    public var summary: LiveSummary {
        LiveSummary(
            router: router.stat,
            internet: internet.stat,
            totalSamples: total,
            routerTimeouts: routerTimeouts,
            internetTimeouts: internetTimeouts,
            failureCount: failed
        )
    }

    /// Wall time spanned by the samples seen so far.
    public var elapsed: TimeInterval {
        guard let first = firstSampleAt, let last = lastSampleAt else { return 0 }
        return last.timeIntervalSince(first)
    }
}
