import Foundation

/// User-configurable knobs for a monitoring session (plan §5).
///
/// Only the fields Phase 1 actually reads are exercised yet; the rest are
/// carried now so the type does not churn when later phases land.
public struct MonitorSettings: Codable, Sendable, Hashable {
    public var routerHost: String
    /// Resolve `routerHost` from the default gateway when a session starts.
    /// The internet host stays manual — pinging a chosen address is the point
    /// of it — but the router is whatever this machine is actually behind, and
    /// a stale hand-typed address just reports a connection that is down.
    public var routerHostAutomatic: Bool
    public var internetHost: String
    public var pingInterval: Duration
    public var pingTimeout: Duration
    /// Defaults to `true`, matching `uiDefault`.
    ///
    /// These must agree. `init(from:)` falls back to a bare `MonitorSettings()`
    /// for any key a stored blob is missing, so while the bare default was
    /// `false` and the UI default `true`, settings written before this key
    /// existed came back with speed tests silently switched off.
    public var throughputEnabled: Bool
    /// Minutes between throughput tests: 5 | 10 | 15 | 30 | 60.
    public var throughputInterval: Int
    public var diagnosticsInterval: Duration

    public init(
        routerHostAutomatic: Bool = true,
        routerHost: String = "192.168.1.1",
        internetHost: String = "1.1.1.1",
        pingInterval: Duration = .seconds(1),
        pingTimeout: Duration = .seconds(2),
        throughputEnabled: Bool = true,
        throughputInterval: Int = 15,
        diagnosticsInterval: Duration = .seconds(5)
    ) {
        self.routerHostAutomatic = routerHostAutomatic
        self.routerHost = routerHost
        self.internetHost = internetHost
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.throughputEnabled = throughputEnabled
        self.throughputInterval = throughputInterval
        self.diagnosticsInterval = diagnosticsInterval
    }

    /// Lenient decode so a persisted settings blob from an older build (missing
    /// a key, or carrying one that's since been removed) still loads.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings()
        routerHost = try c.decodeIfPresent(String.self, forKey: .routerHost) ?? d.routerHost
        routerHostAutomatic = try c.decodeIfPresent(Bool.self, forKey: .routerHostAutomatic) ?? d.routerHostAutomatic
        internetHost = try c.decodeIfPresent(String.self, forKey: .internetHost) ?? d.internetHost
        pingInterval = try c.decodeIfPresent(Duration.self, forKey: .pingInterval) ?? d.pingInterval
        pingTimeout = try c.decodeIfPresent(Duration.self, forKey: .pingTimeout) ?? d.pingTimeout
        throughputEnabled = try c.decodeIfPresent(Bool.self, forKey: .throughputEnabled) ?? d.throughputEnabled
        throughputInterval = try c.decodeIfPresent(Int.self, forKey: .throughputInterval) ?? d.throughputInterval
        diagnosticsInterval = try c.decodeIfPresent(Duration.self, forKey: .diagnosticsInterval) ?? d.diagnosticsInterval
    }
}
