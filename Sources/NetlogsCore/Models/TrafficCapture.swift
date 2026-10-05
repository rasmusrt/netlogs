import Foundation

/// What this Mac was sending and receiving at the moment latency diverged.
///
/// The gap this closes: every latency episode in the database has two candidate
/// explanations that look identical from a ping — the path degraded, or
/// something started uploading — and the second one is knowable, locally, for
/// free, at the moment it happens. Reconstructing it hours later from memory is
/// what the two unexplained episodes of 8 September cost.
///
/// **This Mac only.** `nettop` sees this machine's processes. If the culprit is
/// a NAS, a phone or an Apple TV, nothing here will name it and the capture will
/// look innocently quiet — which is itself a finding, but only if the UI says
/// so rather than letting an empty list read as "nothing was uploading".
public struct TrafficCapture: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { timestamp }

    /// When the capture was *triggered*, not when it finished. `nettop` takes
    /// about five seconds to enumerate, so the two differ by more than the
    /// episode being investigated sometimes lasts.
    public let timestamp: Date
    /// The sample that set it off, so the row can say what it was reacting to.
    public let routerMs: Double?
    public let internetMs: Double?
    /// Seconds between the two `nettop` samples the rates were derived from.
    public let intervalSeconds: Double
    /// Busiest processes by bytes sent, descending. Capped — see `topCount`.
    public let processes: [ProcessTraffic]

    public init(
        timestamp: Date, routerMs: Double?, internetMs: Double?,
        intervalSeconds: Double, processes: [ProcessTraffic]
    ) {
        self.timestamp = timestamp
        self.routerMs = routerMs
        self.internetMs = internetMs
        self.intervalSeconds = intervalSeconds
        self.processes = processes
    }

    /// How many processes a capture keeps.
    ///
    /// The tail is every idle daemon on the machine at zero bytes, and storing
    /// it would make a capture ten times its useful size for a list nobody
    /// scrolls to the bottom of.
    public static let topCount = 12

    /// Total upload rate across the kept processes, bytes/second.
    ///
    /// A floor, not a total: it excludes whatever fell outside `topCount`. That
    /// only matters if the tail is large, and a tail of daemons at a few bytes
    /// each is not.
    public var uploadBytesPerSecond: Double {
        processes.reduce(0) { $0 + $1.bytesOutPerSecond }
    }

    public var downloadBytesPerSecond: Double {
        processes.reduce(0) { $0 + $1.bytesInPerSecond }
    }

    /// The single busiest uploader, or `nil` when nothing on this Mac was
    /// sending. `nil` is the interesting answer: it means look elsewhere on the
    /// network.
    public var topUploader: ProcessTraffic? {
        processes.first { $0.bytesOutPerSecond > 0 }
    }
}

/// One process's traffic rate, differenced between two `nettop` samples.
public struct ProcessTraffic: Codable, Sendable, Equatable, Hashable {
    /// As `nettop` reports it, **including its truncation**: a long name comes
    /// back clipped to the column width ("com.apple.WebKi"). Left alone rather
    /// than repaired by looking the pid up, because the pid may be gone by the
    /// time anyone reads this and a name invented later would not be the name
    /// that was measured.
    public let name: String
    public let pid: Int32
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double

    public init(name: String, pid: Int32,
                bytesInPerSecond: Double, bytesOutPerSecond: Double) {
        self.name = name
        self.pid = pid
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}
