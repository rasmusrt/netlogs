import Foundation

/// The small, always-visible dashboard payload (plan §5 / §8.2). Numbers only —
/// updated every second, and cheap enough that a tick never touches the ping
/// table.
///
/// **Ping only, deliberately.** This comment used to promise that Phase 4/5
/// would add `latestDiagnostics` and `throughputAverages`. They never arrived,
/// and they should not. Throughput and diagnostics change on their own
/// schedules — minutes, and on-change — so folding them in would make one
/// stored property that every 1 Hz ping tick invalidates, which is the §8.2
/// problem; and no Mac view would read them, because the UI has separate
/// `ThroughputModel` and `DiagnosticsModel`.
///
/// Anything that needs all three composes them side by side, as `SessionExport`
/// and `DetailSummary` already do. The Phase 11 wire format is that
/// composition, not a wider `LiveSummary`.
public struct LiveSummary: Codable, Sendable, Equatable {
    public var router: PingStat
    public var internet: PingStat
    public var totalSamples: Int
    public var routerTimeouts: Int
    public var internetTimeouts: Int
    /// Samples where at least one host did not reply *inside the timeout*.
    ///
    /// Unchanged meaning, and deliberately still the total: a probe that missed
    /// its deadline failed, whether or not the reply turned up afterwards. The
    /// two splits below are what make it readable — this number on its own was
    /// the whole problem.
    public var failureCount: Int
    /// Of `failureCount`, the samples where at least one host sent nothing at
    /// all — no reply inside the timeout, none inside the grace window either.
    ///
    /// **This is the packet-loss number.** `failureCount` is not, and reporting
    /// it as though it were is how an overnight session came to claim 14 lost
    /// packets to 1.1.1.1 on a link that had not dropped one.
    public var noReplyCount: Int
    /// Of `failureCount`, the samples where a host answered late rather than
    /// not at all. `failureCount - noReplyCount` by construction, stored so the
    /// three can be read without subtracting.
    public var lateCount: Int
    /// Of `failureCount`, the samples taken while this app's own throughput
    /// test was saturating the link.
    ///
    /// Self-inflicted. The upload leg fills the uplink queue, the echo request
    /// queues behind it, and the probe misses its deadline — a real and useful
    /// bufferbloat measurement, and not a fault of the network being measured.
    /// Three of one overnight session's five failure clusters were this, each
    /// beginning eleven seconds into a scheduled test.
    public var failuresUnderLoad: Int
    public var routerLate: LateReplies
    public var internetLate: LateReplies
    /// Internet-host probes that got nothing back, on samples the app was not
    /// itself loading. The loss figure the verdict runs on, and the only one of
    /// these numbers that is safe to say "packet loss" out loud about.
    public var internetNoRepliesIdle: Int

    public init(
        router: PingStat = .init(),
        internet: PingStat = .init(),
        totalSamples: Int = 0,
        routerTimeouts: Int = 0,
        internetTimeouts: Int = 0,
        failureCount: Int = 0,
        noReplyCount: Int = 0,
        lateCount: Int = 0,
        failuresUnderLoad: Int = 0,
        routerLate: LateReplies = .init(),
        internetLate: LateReplies = .init(),
        internetNoRepliesIdle: Int? = nil
    ) {
        self.router = router
        self.internet = internet
        self.totalSamples = totalSamples
        self.routerTimeouts = routerTimeouts
        self.internetTimeouts = internetTimeouts
        self.failureCount = failureCount
        self.noReplyCount = noReplyCount
        self.lateCount = lateCount
        self.failuresUnderLoad = failuresUnderLoad
        self.routerLate = routerLate
        self.internetLate = internetLate
        // Unstated means "assume every timeout was a lost packet", matching
        // `init(from:)`. The conservative direction is the only safe default
        // here: a caller that has not been taught the difference should over-
        // report loss and be corrected, not under-report it and quietly grade
        // a broken link as healthy.
        self.internetNoRepliesIdle = internetNoRepliesIdle ?? internetTimeouts
    }

    /// Per-host probes that produced nothing at all. Derived: a host's timeouts
    /// are exactly its late replies plus its silences.
    public var routerNoReplies: Int { Swift.max(0, routerTimeouts - routerLate.count) }
    public var internetNoReplies: Int { Swift.max(0, internetTimeouts - internetLate.count) }

    /// Failures on an idle link — the ones that say something about the
    /// network rather than about the speed test.
    public var failuresIdle: Int { Swift.max(0, failureCount - failuresUnderLoad) }

    /// Lost packets as a fraction of samples, 0…1. Excludes late replies and
    /// excludes anything measured under the app's own load, because neither is
    /// a packet the network dropped.
    public var lossFraction: Double {
        totalSamples > 0 ? Double(noReplyCount) / Double(totalSamples) : 0
    }

    /// Decode leniently: `LiveSummary` is on the export wire format, and a blob
    /// written before the late-reply split has none of these keys. Missing
    /// reads as zero, which is exactly right — those sessions caught no late
    /// replies because nothing was listening for them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        router = try c.decodeIfPresent(PingStat.self, forKey: .router) ?? .init()
        internet = try c.decodeIfPresent(PingStat.self, forKey: .internet) ?? .init()
        totalSamples = try c.decodeIfPresent(Int.self, forKey: .totalSamples) ?? 0
        routerTimeouts = try c.decodeIfPresent(Int.self, forKey: .routerTimeouts) ?? 0
        internetTimeouts = try c.decodeIfPresent(Int.self, forKey: .internetTimeouts) ?? 0
        failureCount = try c.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        // Not zero. A session recorded before the split had no way to tell a
        // late reply from a lost packet, and every failure it stored was
        // *treated* as lost — so that is what it should keep meaning, rather
        // than silently becoming "0 lost, 0 late" and erasing the outages it
        // did record.
        noReplyCount = try c.decodeIfPresent(Int.self, forKey: .noReplyCount) ?? failureCount
        lateCount = try c.decodeIfPresent(Int.self, forKey: .lateCount) ?? 0
        failuresUnderLoad = try c.decodeIfPresent(Int.self, forKey: .failuresUnderLoad) ?? 0
        routerLate = try c.decodeIfPresent(LateReplies.self, forKey: .routerLate) ?? .init()
        internetLate = try c.decodeIfPresent(LateReplies.self, forKey: .internetLate) ?? .init()
        // Same reasoning as `noReplyCount`: an older blob measured no late
        // replies, so all of its internet timeouts were silences as far as it
        // could tell. Falling back to `internetTimeouts` keeps its verdict the
        // verdict it was shown with, rather than downgrading its outages to
        // zero on load.
        internetNoRepliesIdle =
            try c.decodeIfPresent(Int.self, forKey: .internetNoRepliesIdle) ?? internetTimeouts
    }
}
