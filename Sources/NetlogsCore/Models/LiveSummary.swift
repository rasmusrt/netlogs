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
    /// Samples where at least one host did not reply.
    public var failureCount: Int

    public init(
        router: PingStat = .init(),
        internet: PingStat = .init(),
        totalSamples: Int = 0,
        routerTimeouts: Int = 0,
        internetTimeouts: Int = 0,
        failureCount: Int = 0
    ) {
        self.router = router
        self.internet = internet
        self.totalSamples = totalSamples
        self.routerTimeouts = routerTimeouts
        self.internetTimeouts = internetTimeouts
        self.failureCount = failureCount
    }
}
