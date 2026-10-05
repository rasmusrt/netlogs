import Foundation

/// One completed throughput test (plan §5 / §7).
///
/// The latency figures are **not** separate probes — they are derived from the
/// 1 Hz ping stream, which keeps running through the test with each sample
/// tagged by ``LoadPhase``. `bufferbloatMs` is the headline number.
public struct ThroughputResult: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date

    public let downloadMbps: Double
    public let uploadMbps: Double
    public let bytesDownloaded: Int
    public let bytesUploaded: Int

    /// Internet-host RTT, idle window just before the test.
    ///
    /// `nil` means *not measured* — an idle window where no ping got a reply.
    /// It used to be stored as `0`, which made the subtraction below report the
    /// entire load latency as bufferbloat: 210 ms and a "poor" grade invented
    /// out of a window that measured nothing. Same mistake as schema 2's
    /// `NOT NULL DEFAULT 0`, in the field the Speed card leads with.
    public let idleLatencyMs: Double?
    /// Internet-host RTT while `.downloading`, or `nil` if that window caught
    /// no replies.
    public let downloadLatencyMs: Double?
    /// Internet-host RTT while `.uploading`, or `nil` if that window caught no
    /// replies.
    public let uploadLatencyMs: Double?
    /// `max(downloadLatencyMs, uploadLatencyMs) − idleLatencyMs`, floored at 0.
    ///
    /// `nil` unless both halves of that subtraction were measured. A number
    /// derived from an unmeasured baseline is not a smaller number; it is not
    /// a measurement at all.
    public let bufferbloatMs: Double?
    /// Internet-host jitter over the same idle window as `idleLatencyMs`, on the
    /// same definition as `RunningStats.measuredJitter` — the mean absolute
    /// difference between consecutive replies.
    ///
    /// `nil` means *not measured*, which is not the same as measured at zero.
    /// Two things produce it: a result recorded before schema 3, and an idle
    /// window that never got two consecutive replies. Both used to be stored as
    /// a confident `0.0`.
    public let idleJitterMs: Double?
    /// Share of pings in the whole test window that got no internet reply, 0…1,
    /// or `nil` if no ping landed in the window at all.
    ///
    /// ICMP loss measured *while* the test ran, not loss of the test's own
    /// bytes — HTTP over TCP cannot see that. It is the same instrument as the
    /// latency figures above, over the same window.
    public let packetLoss: Double?

    /// Spread of internet-host RTT within each phase — the same `RunningStats`
    /// the means above come from, no extra probing.
    ///
    /// All optional and all `nil` before schema 5, on the same rule as
    /// ``idleJitterMs``: a figure that was never measured is not a zero. They
    /// are also `nil` for a phase whose window caught no replies, or fewer than
    /// two consecutive ones in the case of jitter.
    ///
    /// **Read them knowing the sample count.** A direction runs ten seconds at
    /// one ping a second, so a high or a low here is drawn from roughly ten
    /// samples. That is enough to show a load spike — which is the point, and
    /// what bufferbloat is — but it is not the dense probing a dedicated speed
    /// test does, and the extremes will be softer than one.
    public let idleLowMs: Double?
    public let idleHighMs: Double?
    public let downloadJitterMs: Double?
    public let downloadLowMs: Double?
    public let downloadHighMs: Double?
    public let uploadJitterMs: Double?
    public let uploadLowMs: Double?
    public let uploadHighMs: Double?

    public let isp: String?
    public let serverLocation: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        downloadMbps: Double,
        uploadMbps: Double,
        bytesDownloaded: Int,
        bytesUploaded: Int,
        idleLatencyMs: Double?,
        downloadLatencyMs: Double?,
        uploadLatencyMs: Double?,
        idleJitterMs: Double? = nil,
        packetLoss: Double? = nil,
        idleLowMs: Double? = nil,
        idleHighMs: Double? = nil,
        downloadJitterMs: Double? = nil,
        downloadLowMs: Double? = nil,
        downloadHighMs: Double? = nil,
        uploadJitterMs: Double? = nil,
        uploadLowMs: Double? = nil,
        uploadHighMs: Double? = nil,
        isp: String? = nil,
        serverLocation: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.bytesDownloaded = bytesDownloaded
        self.bytesUploaded = bytesUploaded
        self.idleLatencyMs = idleLatencyMs
        self.downloadLatencyMs = downloadLatencyMs
        self.uploadLatencyMs = uploadLatencyMs
        // Derived only from what was measured: the heavier direction needs at
        // least one load window, and the subtraction needs the baseline.
        let loaded = [downloadLatencyMs, uploadLatencyMs].compactMap { $0 }.max()
        self.bufferbloatMs = (loaded == nil || idleLatencyMs == nil)
            ? nil : max(0, loaded! - idleLatencyMs!)
        self.idleJitterMs = idleJitterMs
        self.packetLoss = packetLoss
        self.idleLowMs = idleLowMs
        self.idleHighMs = idleHighMs
        self.downloadJitterMs = downloadJitterMs
        self.downloadLowMs = downloadLowMs
        self.downloadHighMs = downloadHighMs
        self.uploadJitterMs = uploadJitterMs
        self.uploadLowMs = uploadLowMs
        self.uploadHighMs = uploadHighMs
        self.isp = isp
        self.serverLocation = serverLocation
    }

    public var totalBytes: Int { bytesDownloaded + bytesUploaded }

    /// Whether the download direction loaded the connection harder. The same
    /// choice ``bufferbloatMs`` is derived from.
    /// Which direction loaded the connection harder. A direction that measured
    /// nothing cannot be the heavier one; if neither measured, the choice is
    /// arbitrary and both readings below are `nil` anyway.
    private var downloadWasHeavier: Bool {
        switch (downloadLatencyMs, uploadLatencyMs) {
        case let (dl?, ul?): return dl >= ul
        case (_?, nil):      return true
        case (nil, _?):      return false
        case (nil, nil):     return true
        }
    }

    /// Round-trip time while the connection was loaded — the worse of the two
    /// directions.
    ///
    /// This and ``loadedJitterMs`` come from the *same* direction on purpose.
    /// Taking the worst latency from one and the worst jitter from the other
    /// would describe a moment that never happened.
    public var loadedLatencyMs: Double? {
        downloadWasHeavier ? downloadLatencyMs : uploadLatencyMs
    }

    /// Jitter during ``loadedLatencyMs``' direction. `nil` before schema 4.
    public var loadedJitterMs: Double? {
        downloadWasHeavier ? downloadJitterMs : uploadJitterMs
    }
}

/// Rolled-up throughput for the dashboard (plan §5 `LiveSummary`, §13 Q2).
public struct ThroughputAverages: Codable, Sendable, Equatable {
    public var count: Int
    public var downloadMbps: Double
    public var uploadMbps: Double
    /// `nil` when no test in the set measured both an idle baseline and a
    /// loaded window — the same rule as `jitterMs` below, applied to the figure
    /// the card leads with.
    public var bufferbloatMs: Double?
    /// Latency, jitter and loss measured during the tests themselves — not the
    /// session-wide ping stats, which describe a different host over a
    /// different span.
    public var latencyMs: Double?
    /// Averaged over the tests that *measured* it, and `nil` when none did —
    /// the same rule the ping cards use, where the mean is over replies rather
    /// than over samples. A set mixing measured and unmeasured tests averages
    /// what it has rather than counting the unmeasured ones as zero.
    public var jitterMs: Double?
    public var packetLoss: Double?
    /// Ping and jitter *while loaded*, averaged on the same rule.
    ///
    /// The idle figures above describe the connection as it always is, which
    /// the session's own Internet card says over a much longer window. These
    /// are what only a test can show.
    public var loadedLatencyMs: Double?
    public var loadedJitterMs: Double?

    public init(
        count: Int = 0,
        downloadMbps: Double = 0, uploadMbps: Double = 0, bufferbloatMs: Double? = nil,
        latencyMs: Double? = nil, jitterMs: Double? = nil, packetLoss: Double? = nil,
        loadedLatencyMs: Double? = nil, loadedJitterMs: Double? = nil
    ) {
        self.count = count
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.bufferbloatMs = bufferbloatMs
        self.latencyMs = latencyMs
        self.jitterMs = jitterMs
        self.packetLoss = packetLoss
        self.loadedLatencyMs = loadedLatencyMs
        self.loadedJitterMs = loadedJitterMs
    }

    /// Rolls up a session's tests.
    ///
    /// Lives here rather than in a view model so the live dashboard and a
    /// loaded saved session compute it identically. Tests arrive at most a few
    /// times an hour, so a pass over the array is not worth making incremental.
    ///
    /// **Always an average, at any `count`.** This used to carry a parallel set
    /// of `latest*` figures and switch to them below three tests, on plan §13
    /// Q2's reasoning that averaging fewer "describes neither". Reversed
    /// deliberately: the card is read as a summary of the session, and silently
    /// changing what it summarises — average here, single test there — is
    /// harder to trust than a thin average that says how thin it is. The label
    /// carries the count, and the sheet lists every run individually for
    /// anyone who wants a specific one.
    public init(results: [ThroughputResult]) {
        guard !results.isEmpty else {
            self.init()
            return
        }
        let n = Double(results.count)
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        self.init(
            count: results.count,
            downloadMbps: results.reduce(0) { $0 + $1.downloadMbps } / n,
            uploadMbps: results.reduce(0) { $0 + $1.uploadMbps } / n,
            // Every figure averages the tests that measured it, and reports
            // nothing when none did. Dividing a sum of measured values by the
            // count of *all* tests — which is what these three used to do —
            // quietly counts an unmeasured window as a zero.
            bufferbloatMs: mean(results.compactMap(\.bufferbloatMs)),
            latencyMs: mean(results.compactMap(\.idleLatencyMs)),
            jitterMs: mean(results.compactMap(\.idleJitterMs)),
            packetLoss: mean(results.compactMap(\.packetLoss)),
            loadedLatencyMs: mean(results.compactMap(\.loadedLatencyMs)),
            loadedJitterMs: mean(results.compactMap(\.loadedJitterMs))
        )
    }

    /// `nil` when bufferbloat was never measured, so a card can show "—"
    /// rather than grading a number that does not exist.
    public var grade: BufferbloatGrade? {
        bufferbloatMs.map { BufferbloatGrade(milliseconds: $0) }
    }
}
