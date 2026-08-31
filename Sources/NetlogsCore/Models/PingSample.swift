import Foundation

/// One tick of the ping loop: a round-trip time to the router and to the
/// internet host, taken at the same scheduled instant.
///
/// `nil` for `routerMs` / `internetMs` means that host did not reply before the
/// timeout. A missing reply is recorded, never dropped (plan §6.1).
public struct PingSample: Codable, Identifiable, Sendable, Hashable {
    /// Monotonic sample index for the session. Widens the 16-bit ICMP sequence
    /// number so it does not wrap over a multi-hour run.
    public let id: UInt32
    /// The instant the tick was *scheduled* for, not when processing finished —
    /// so samples stay exactly `pingInterval` apart regardless of RTT.
    public let timestamp: Date
    public let routerMs: Double?
    public let internetMs: Double?
    public let phase: LoadPhase

    public init(
        id: UInt32,
        timestamp: Date,
        routerMs: Double?,
        internetMs: Double?,
        phase: LoadPhase
    ) {
        self.id = id
        self.timestamp = timestamp
        self.routerMs = routerMs
        self.internetMs = internetMs
        self.phase = phase
    }

    public var routerTimedOut: Bool { routerMs == nil }
    public var internetTimedOut: Bool { internetMs == nil }

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
