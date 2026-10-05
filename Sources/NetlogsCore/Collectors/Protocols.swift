import Foundation

/// Outcome of a single echo request.
///
/// `.timeout` and `.lateReply` are both failed probes — neither answered inside
/// the deadline — but they are *not* the same fact about the network, and the
/// app spent a long time unable to tell them apart. A session ending with 14
/// "no reply"s recorded a maximum RTT of 1942 ms against a 2000 ms timeout:
/// every one of those failures was a reply still in flight, arriving a few
/// hundred milliseconds late, and being dropped on the floor because nothing
/// was listening for it any more. The distribution was truncated exactly at the
/// deadline, which made a queueing problem look like packet loss — and packet
/// loss is what the user then went and argued about with their ISP.
///
/// So the pinger keeps listening past the deadline for a grace window and
/// reports what it hears. `.lateReply` still counts as a failure everywhere
/// loss is counted; what it adds is the *number*.
public enum PingOutcome: Sendable, Equatable {
    case reply(rttMs: Double)
    /// A reply that arrived after the timeout but within the grace window.
    /// Carries the true round-trip time, which is by definition > the timeout.
    case lateReply(rttMs: Double)
    case timeout
    case failure(String)

    /// Round-trip time of a *timely* reply, `nil` otherwise.
    ///
    /// Deliberately `nil` for `.lateReply`: this is what feeds
    /// `PingSample.routerMs`/`internetMs`, and a probe that missed its deadline
    /// must keep reading as a miss in every existing consumer. The late number
    /// travels alongside in ``lateRttMs``.
    public var rttMs: Double? {
        if case .reply(let ms) = self { return ms }
        return nil
    }

    /// Round-trip time of a reply that missed the deadline, `nil` otherwise.
    public var lateRttMs: Double? {
        if case .lateReply(let ms) = self { return ms }
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
