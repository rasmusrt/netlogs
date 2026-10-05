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
    private var noReply = 0
    private var late = 0
    private var failedUnderLoad = 0
    private var routerLate = LateReplies()
    private var internetLate = LateReplies()
    private var internetSilentIdle = 0

    public private(set) var firstSampleAt: Date?
    public private(set) var lastSampleAt: Date?

    public init() {}

    public mutating func add(_ sample: PingSample) {
        total += 1
        if firstSampleAt == nil { firstSampleAt = sample.timestamp }
        lastSampleAt = sample.timestamp

        // A late reply is still a gap for the *timely* stat — it did not
        // arrive in time, so `markGap` is correct and jitter must not difference
        // across it. Its RTT is recorded separately, in `LateReplies`.
        if let ms = sample.routerMs { router.record(rttMs: ms) }
        else { router.recordTimeout(); routerTimeouts += 1 }
        if let ms = sample.routerLateMs { routerLate.record(rttMs: ms) }

        if let ms = sample.internetMs { internet.record(rttMs: ms) }
        else { internet.recordTimeout(); internetTimeouts += 1 }
        if let ms = sample.internetLateMs { internetLate.record(rttMs: ms) }
        if sample.internetNoReply, !sample.isUnderLoad { internetSilentIdle += 1 }

        if sample.routerTimedOut || sample.internetTimedOut {
            failed += 1
            if sample.isUnderLoad { failedUnderLoad += 1 }
            // A sample can be both — one host silent, the other merely late —
            // and it belongs in `noReply`. "At least one host sent nothing" is
            // the stricter fact and the one that means a packet was lost.
            if sample.routerNoReply || sample.internetNoReply { noReply += 1 } else { late += 1 }
        }
    }

    public var summary: LiveSummary {
        LiveSummary(
            router: router.stat,
            internet: internet.stat,
            totalSamples: total,
            routerTimeouts: routerTimeouts,
            internetTimeouts: internetTimeouts,
            failureCount: failed,
            noReplyCount: noReply,
            lateCount: late,
            failuresUnderLoad: failedUnderLoad,
            routerLate: routerLate,
            internetLate: internetLate,
            internetNoRepliesIdle: internetSilentIdle
        )
    }

    /// Wall time spanned by the samples seen so far.
    public var elapsed: TimeInterval {
        guard let first = firstSampleAt, let last = lastSampleAt else { return 0 }
        return last.timeIntervalSince(first)
    }
}
