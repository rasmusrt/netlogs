import Foundation

/// One host's latency, reduced in SQLite rather than by folding samples.
///
/// The Analysis screen ranges over many sessions at once, where
/// `LiveSummaryBuilder` is the wrong instrument: it is O(1) per sample, but it
/// needs a `PingSample` to exist, and one overnight session is 38,000 of them.
/// These are the same figures computed by `GROUP BY`, so nothing is constructed
/// per sample — see `SessionStore.pingAggregates(for:)`.
public struct HostAggregate: Sendable, Equatable {
    public var replies: Int
    public var min: Double?
    public var max: Double?
    public var sum: Double
    /// Σ|Δ| between *consecutive replies*, and how many such pairs there were.
    /// A timeout ends a pair, exactly as `RunningStats.markGap()` does.
    public var jitterSum: Double
    public var jitterPairs: Int
    /// Replies that missed the deadline and were caught in the grace window.
    public var late: LateReplies

    public init(
        replies: Int = 0, min: Double? = nil, max: Double? = nil, sum: Double = 0,
        jitterSum: Double = 0, jitterPairs: Int = 0, late: LateReplies = .init()
    ) {
        self.replies = replies
        self.min = min
        self.max = max
        self.sum = sum
        self.jitterSum = jitterSum
        self.jitterPairs = jitterPairs
        self.late = late
    }

    public var mean: Double { replies > 0 ? sum / Double(replies) : 0 }

    /// Slowest round trip observed, late replies included. `max` alone cannot
    /// exceed the ping timeout, so on a session with late replies it is a
    /// ceiling imposed by a setting rather than a measurement.
    public var worstMs: Double? {
        switch (max, late.max) {
        case let (m?, l?): return Swift.max(m, l)
        case let (m?, nil): return m
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    /// `nil` until two replies have arrived with no timeout between them — the
    /// same distinction `RunningStats.measuredJitter` draws, and for the same
    /// reason: "no pair yet" and "the replies agreed" are different facts.
    public var measuredJitter: Double? {
        jitterPairs > 0 ? jitterSum / Double(jitterPairs) : nil
    }
}

/// One session's ping stream, reduced in SQL.
///
/// Everything `LiveSummary` carries except the percentiles, which need the
/// histogram query — `PingStat.p50`/`p95`/`p99` are rebuilt from
/// `LatencyHistogram` rather than from a `GROUP BY`.
public struct PingAggregate: Sendable, Equatable {
    public var totalSamples: Int
    public var firstSampleAt: Date?
    public var lastSampleAt: Date?
    public var routerTimeouts: Int
    public var internetTimeouts: Int
    /// Samples where *either* host missed its deadline, matching `LiveSummary`.
    public var failureCount: Int
    /// Of `failureCount`, samples where a host sent nothing at all. The
    /// packet-loss figure — see ``LiveSummary/noReplyCount``.
    public var noReplyCount: Int
    /// Of `failureCount`, samples where a host answered after the deadline.
    public var lateCount: Int
    /// Of `failureCount`, samples taken while this app's own throughput test
    /// was loading the link — see ``LiveSummary/failuresUnderLoad``.
    public var failuresUnderLoad: Int
    /// Samples taken under the app's own load, failed or not. The denominator
    /// `failuresUnderLoad` needs to mean anything.
    public var samplesUnderLoad: Int
    /// Internet-host probes that got nothing back, on samples the app was not
    /// itself loading. The mirror of ``LiveSummary/internetNoRepliesIdle``, and
    /// the figure the Analysis screen scores loss on.
    public var internetNoRepliesIdle: Int
    public var router: HostAggregate
    public var internet: HostAggregate

    public init(
        totalSamples: Int = 0,
        firstSampleAt: Date? = nil, lastSampleAt: Date? = nil,
        routerTimeouts: Int = 0, internetTimeouts: Int = 0, failureCount: Int = 0,
        noReplyCount: Int = 0, lateCount: Int = 0,
        failuresUnderLoad: Int = 0, samplesUnderLoad: Int = 0,
        internetNoRepliesIdle: Int? = nil,
        router: HostAggregate = .init(), internet: HostAggregate = .init()
    ) {
        self.totalSamples = totalSamples
        self.firstSampleAt = firstSampleAt
        self.lastSampleAt = lastSampleAt
        self.routerTimeouts = routerTimeouts
        self.internetTimeouts = internetTimeouts
        self.failureCount = failureCount
        self.noReplyCount = noReplyCount
        self.lateCount = lateCount
        self.failuresUnderLoad = failuresUnderLoad
        self.samplesUnderLoad = samplesUnderLoad
        // Same conservative default as `LiveSummary`: unstated means every
        // timeout was a lost packet.
        self.internetNoRepliesIdle = internetNoRepliesIdle ?? internetTimeouts
        self.router = router
        self.internet = internet
    }

    /// Failures on an idle link, and the samples they are a share of.
    public var failuresIdle: Int { Swift.max(0, failureCount - failuresUnderLoad) }
    public var samplesIdle: Int { Swift.max(0, totalSamples - samplesUnderLoad) }

    /// Lost packets as a fraction of samples, 0…1: late replies excluded,
    /// self-inflicted load excluded. The number to quote at an ISP.
    public var lossFraction: Double {
        totalSamples > 0 ? Double(noReplyCount) / Double(totalSamples) : 0
    }

    /// Ticks where neither host answered — the link itself dropped rather than
    /// one side of it.
    ///
    /// Derived, not stored: `failureCount` counts a tick once if *either* was
    /// silent, so the overlap falls out of inclusion–exclusion. Checked against
    /// the real database, where one session gives 180 + 18 − 182 = 16.
    public var bothTimeouts: Int {
        Swift.max(0, routerTimeouts + internetTimeouts - failureCount)
    }

    /// Wall time between the first and last stored sample — what was actually
    /// measured, as against what the session claims.
    public var measuredSpan: TimeInterval {
        guard let first = firstSampleAt, let last = lastSampleAt else { return 0 }
        return last.timeIntervalSince(first)
    }
}
