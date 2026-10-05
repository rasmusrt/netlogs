import Foundation

/// One tick of the ping loop: a round-trip time to the router and to the
/// internet host, taken at the same scheduled instant.
///
/// `nil` for `routerMs` / `internetMs` means that host did not reply before the
/// timeout. A missing reply is recorded, never dropped (plan §6.1).
///
/// **Timed out is not the same as lost.** `routerLateMs` / `internetLateMs`
/// carry the round-trip time of a reply that arrived *after* the deadline but
/// inside the pinger's grace window. When one of those is set, the host was
/// reachable and slow; when both it and the timely column are `nil`, nothing
/// came back at all. The pair exists because a 2 s timeout truncates the
/// latency distribution exactly where the interesting data is: an overnight
/// session recorded a 1942 ms maximum and 14 "failures", and every one of the
/// 14 was a reply that would have landed a few hundred milliseconds later.
///
/// The timely columns keep their old meaning on purpose, so every existing
/// loss count still counts a late reply as a failed probe. What is new is that
/// the number is no longer thrown away.
public struct PingSample: Codable, Identifiable, Sendable, Hashable {
    /// Monotonic sample index for the session. Widens the 16-bit ICMP sequence
    /// number so it does not wrap over a multi-hour run.
    public let id: UInt32
    /// The instant the tick was *scheduled* for, not when processing finished —
    /// so samples stay exactly `pingInterval` apart regardless of RTT.
    public let timestamp: Date
    public let routerMs: Double?
    public let internetMs: Double?
    /// RTT of a router reply that missed the deadline, `nil` otherwise. Never
    /// set at the same time as `routerMs` — a probe is timely or it is late.
    public let routerLateMs: Double?
    /// RTT of an internet reply that missed the deadline, `nil` otherwise.
    public let internetLateMs: Double?
    public let phase: LoadPhase

    public init(
        id: UInt32,
        timestamp: Date,
        routerMs: Double?,
        internetMs: Double?,
        routerLateMs: Double? = nil,
        internetLateMs: Double? = nil,
        phase: LoadPhase
    ) {
        self.id = id
        self.timestamp = timestamp
        self.routerMs = routerMs
        self.internetMs = internetMs
        self.routerLateMs = routerLateMs
        self.internetLateMs = internetLateMs
        self.phase = phase
    }

    /// The host did not reply inside the timeout. Unchanged meaning: a late
    /// reply is still a timed-out probe, and still counts as a failure.
    public var routerTimedOut: Bool { routerMs == nil }
    public var internetTimedOut: Bool { internetMs == nil }

    /// The host answered, but only after the deadline had passed.
    public var routerWasLate: Bool { routerLateMs != nil }
    public var internetWasLate: Bool { internetLateMs != nil }

    /// Nothing came back at all — not inside the timeout, not inside the grace
    /// window. This, and not ``routerTimedOut``, is the one that means "lost".
    public var routerNoReply: Bool { routerMs == nil && routerLateMs == nil }
    public var internetNoReply: Bool { internetMs == nil && internetLateMs == nil }

    /// Best known round-trip time, timely or late — what a latency chart should
    /// plot, so a spike over the timeout draws as a spike rather than a hole.
    public var routerRttMs: Double? { routerMs ?? routerLateMs }
    public var internetRttMs: Double? { internetMs ?? internetLateMs }

    /// The tick was taken while the app's own throughput test was saturating
    /// the link. Latency and loss under load are real measurements, but they
    /// are measurements of a link this app is loading; folding them into a
    /// session's headline loss figure reports self-inflicted queueing as a
    /// network fault. Three of one overnight session's five failure clusters
    /// began eleven seconds into a scheduled upload test.
    public var isUnderLoad: Bool { phase != .idle }

    /// Samples with an `id` below this carry the ICMP socket warm-up spike —
    /// roughly 580 ms on the first tick (PHASE1-FINDINGS §3). They are kept in
    /// the log and on disk, but excluded from anything that would let an
    /// artefact set a scale: the session statistics, and the chart's y-axis.
    ///
    /// Lives on the model rather than on a view model so the live path and the
    /// stored-session path can't disagree about it — which they did before
    /// Phase 9, leaving saved charts scaled to the spike.
    public static let warmupSampleCount: UInt32 = 2
}
