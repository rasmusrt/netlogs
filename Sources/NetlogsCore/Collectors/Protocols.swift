import Foundation

/// Outcome of a single echo request.
public enum PingOutcome: Sendable, Equatable {
    case reply(rttMs: Double)
    case timeout
    case failure(String)

    /// Round-trip time in milliseconds, or `nil` for a timeout/failure.
    public var rttMs: Double? {
        if case .reply(let ms) = self { return ms }
        return nil
    }
}

/// A source of round-trip times to a fixed set of hosts.
///
/// One implementation (`ICMPPinger`) owns a **single** ICMP datagram socket for
/// all hosts — macOS delivers every echo reply to every ICMP datagram socket in
/// the process, so multiple sockets cannot be demuxed by the kernel (see
/// `PHASE1-FINDINGS.md` §2). Tests inject fakes.
public protocol ICMPPinging: Sendable {
    /// Resolve the hosts and acquire the socket. Throws if that fails
    /// (e.g. the sandbox denies the socket, or a host does not resolve).
    func open() throws
    /// Send one echo request to `host` with `sequence` and await the matching
    /// reply or a timeout. `host` must be one of the hosts this was created
    /// with. Never throws; failures come back as `.failure`.
    func ping(host: String, sequence: UInt32) async -> PingOutcome
    /// Release the socket. Safe to call more than once.
    func close()
    /// Human-readable note of what `host` resolved to, e.g. "1.1.1.1 (IPv4)".
    /// Optional; the default returns `nil`.
    func resolvedDescription(of host: String) -> String?
}

extension ICMPPinging {
    public func resolvedDescription(of host: String) -> String? { nil }
}

/// A source of point-in-time network-interface snapshots (plan §6.2).
/// `MacDiagnostics` is the real implementation; tests inject fakes.
public protocol DiagnosticsProvider: Sendable {
    /// Best-effort snapshot of the active interface. Never throws — fields it
    /// can't read come back `nil`.
    func snapshot() -> DiagnosticsSnapshot
}

/// One direction of a throughput measurement.
public struct ThroughputMeasurement: Sendable, Equatable {
    /// Bytes transferred in the steady-state window (first ~1 s discarded).
    public let bytes: Int
    /// Length of that steady-state window in seconds.
    public let seconds: Double

    public init(bytes: Int, seconds: Double) {
        self.bytes = bytes
        self.seconds = seconds
    }

    public var mbps: Double {
        seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0
    }
}

public struct ThroughputMeta: Sendable, Equatable {
    public let isp: String?
    public let colo: String?
    public init(isp: String?, colo: String?) {
        self.isp = isp
        self.colo = colo
    }
}

/// Runs the actual bytes-over-the-wire throughput test (plan §6.3). Behind a
/// protocol so the endpoint can be swapped; `HTTPThroughput` (Cloudflare) is
/// the default. Time-boxed, not byte-boxed.
public protocol ThroughputProvider: Sendable {
    func measureDownload(duration: Duration, discardingFirst warmup: Duration) async -> ThroughputMeasurement
    func measureUpload(duration: Duration, discardingFirst warmup: Duration) async -> ThroughputMeasurement
    func fetchMeta() async -> ThroughputMeta?
}
