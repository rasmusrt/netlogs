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
    /// Capture what this Mac is sending when latency diverges
    /// (``TrafficCaptureTrigger``). Defaults on: it is local, it is this
    /// machine only, and it is the one thing that answers "what was uploading"
    /// at the moment it matters rather than hours later. It records process
    /// names, so it is a switch rather than an assumption.
    public var trafficCaptureEnabled: Bool
    /// Poll the gateway's controller for the WAN radio and counters (Phase 14).
    /// Off by default: it needs an API key the user has to create, and it reads
    /// a second device.
    public var wanTelemetryEnabled: Bool
    /// The controller to ask. `nil` means the session's router host, which is
    /// the gateway in every setup this was built for.
    public var wanGatewayHost: String?
    /// SHA-256 of the one certificate the gateway is trusted to present. Not a
    /// secret — it identifies the gateway, it does not unlock it — so it lives
    /// here and not in the Keychain with the key.
    public var wanCertificateSHA256: String?

    public init(
        routerHostAutomatic: Bool = true,
        routerHost: String = "192.168.1.1",
        internetHost: String = "1.1.1.1",
        pingInterval: Duration = .seconds(1),
        pingTimeout: Duration = .seconds(2),
        throughputEnabled: Bool = true,
        throughputInterval: Int = 15,
        diagnosticsInterval: Duration = .seconds(5),
        trafficCaptureEnabled: Bool = true,
        wanTelemetryEnabled: Bool = false,
        wanGatewayHost: String? = nil,
        wanCertificateSHA256: String? = nil
    ) {
        self.routerHostAutomatic = routerHostAutomatic
        self.routerHost = routerHost
        self.internetHost = internetHost
        self.pingInterval = pingInterval
        self.pingTimeout = pingTimeout
        self.throughputEnabled = throughputEnabled
        self.throughputInterval = throughputInterval
        self.diagnosticsInterval = diagnosticsInterval
        self.trafficCaptureEnabled = trafficCaptureEnabled
        self.wanTelemetryEnabled = wanTelemetryEnabled
        self.wanGatewayHost = wanGatewayHost
        self.wanCertificateSHA256 = wanCertificateSHA256
    }

    /// The host the gateway poll goes to.
    public var effectiveWANGatewayHost: String {
        let typed = wanGatewayHost?.trimmingCharacters(in: .whitespaces) ?? ""
        return typed.isEmpty ? routerHost : typed
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
        trafficCaptureEnabled = try c.decodeIfPresent(Bool.self, forKey: .trafficCaptureEnabled) ?? d.trafficCaptureEnabled
        wanTelemetryEnabled = try c.decodeIfPresent(Bool.self, forKey: .wanTelemetryEnabled) ?? d.wanTelemetryEnabled
        wanGatewayHost = try c.decodeIfPresent(String.self, forKey: .wanGatewayHost) ?? d.wanGatewayHost
        wanCertificateSHA256 = try c.decodeIfPresent(String.self, forKey: .wanCertificateSHA256) ?? d.wanCertificateSHA256
    }
}
