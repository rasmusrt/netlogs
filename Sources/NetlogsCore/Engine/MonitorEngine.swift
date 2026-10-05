import Foundation

/// The single session actor (plan §2).
///
/// One process, one timer, one ICMP socket. Each tick pings both hosts in
/// parallel and emits one ``PingSample`` on an `AsyncStream`. The
/// two-timers-drifting-out-of-phase class of bug from the prototype cannot occur
/// here because there is only one timer.
public actor MonitorEngine {

    /// Builds the pinger for a set of hosts. Overridable so tests run offline.
    public typealias PingerFactory =
        @Sendable (_ hosts: [String], _ timeout: Duration) -> any ICMPPinging

    private let settings: MonitorSettings
    private let makePinger: PingerFactory
    private let throughput: (any ThroughputProvider)?
    private let timerQueue = DispatchQueue(label: "netlogs.engine.timer")
    private let throughputTimerQueue = DispatchQueue(label: "netlogs.engine.throughput")

    private var pinger: (any ICMPPinging)?
    private var timer: ScheduledTimer?
    private var continuation: AsyncStream<PingSample>.Continuation?

    // Ticks run concurrently (so one slow/lost ping doesn't stall the 1 Hz
    // cadence) but samples must leave in order. Each tick's id comes from the
    // timer count synchronously; completed samples wait in `holdback` until
    // every earlier id has been emitted.
    private var emitNext: UInt32 = 0
    private var holdback: [UInt32: PingSample] = [:]

    // If both hosts time out for this many ticks in a row the socket is
    // probably stale (interface switch, sleep/wake) — rebuild the pinger.
    private var consecutiveTotalFailures = 0
    private static let failureRecoveryThreshold = 15

    // Throughput (plan §7). The 1 Hz ping loop keeps running through a test and
    // every sample is tagged with `currentPhase`; latency-under-load is derived
    // from those tagged samples, not separate probes.
    private var recentSamples: [PingSample] = [] // rolling ~90 s for latency derivation
    private var throughputTimer: ScheduledTimer?
    private var throughputFirstRun: Task<Void, Never>?
    private var throughputContinuation: AsyncStream<ThroughputResult>.Continuation?
    private var throughputInProgress = false
    private var cachedMeta: ThroughputMeta?

    /// Current throughput-test phase; every ``PingSample`` is tagged with it.
    public private(set) var currentPhase: LoadPhase = .idle

    public init(
        settings: MonitorSettings,
        pingerFactory: PingerFactory? = nil,
        throughputProvider: (any ThroughputProvider)? = HTTPThroughput()
    ) {
        self.settings = settings
        self.makePinger = pingerFactory ?? { hosts, timeout in
            ICMPPinger(hosts: hosts, timeout: timeout)
        }
        self.throughput = throughputProvider
    }

    /// Open the socket and start the tick loop.
    ///
    /// - Parameters:
    ///   - warmup: the unprivileged ICMP datagram socket does not deliver
    ///     replies for the first few seconds (PHASE1-FINDINGS §3). A priming
    ///     round is sent immediately and the scheduled loop starts after this
    ///     delay. Pass `.zero` in tests.
    ///   - onTick: optional observer called synchronously on the timer queue for
    ///     every firing, before the ping work is dispatched. Used by the Phase 1
    ///     CLI to measure timer drift; harmless to ignore.
    /// - Returns: a stream of samples, one per tick, in order. Finishes on `stop()`.
    public func start(
        warmup: Duration = .seconds(3),
        onTick: (@Sendable (ScheduledTimer.Tick) -> Void)? = nil
    ) async throws -> AsyncStream<PingSample> {
        precondition(timer == nil, "MonitorEngine.start() called twice")

        let hosts = [settings.routerHost, settings.internetHost]
        let p = makePinger(hosts, settings.pingTimeout)
        try p.open()
        pinger = p
        emitNext = 0
        holdback.removeAll()

        let (stream, cont) = AsyncStream<PingSample>.makeStream(bufferingPolicy: .bufferingNewest(600))
        continuation = cont

        // Prime the socket through the warm-up window, then start ticking.
        if warmup > .zero {
            let hostsToPrime = hosts
            // A sequence the sample loop will never reach, not 0.
            //
            // Sample ids start at 0 too, so the prime and the first real sample
            // used the same wire sequence. `ping` treats a repeated sequence as
            // a stale request: it evicted the prime's pending entry and resumed
            // it as `.timeout`, leaving two identical echo requests in flight
            // for one reply. A home router answers both and the sample
            // survives; 1.1.1.1 de-duplicates them, so the first internet
            // sample timed out on every single session. That is what
            // `PingSample.warmupSampleCount` has been hiding.
            Task {
                for h in hostsToPrime {
                    _ = await p.ping(host: h, sequence: Self.primeSequence)
                }
            }
            try? await Task.sleep(for: warmup)
        }
        guard continuation != nil else { return stream } // stopped during warm-up

        let t = ScheduledTimer(interval: settings.pingInterval, queue: timerQueue) { [weak self] tick in
            onTick?(tick)
            guard let self else { return }
            // id assigned here, synchronously and in order, from the tick count.
            let id = UInt32(truncatingIfNeeded: tick.count - 1)
            Task { await self.tick(id: id, scheduledAt: tick.scheduledAt) }
        }
        timer = t
        t.start()

        if settings.throughputEnabled, throughput != nil {
            startThroughputSchedule()
        }

        cont.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
        return stream
    }

    public func stop() {
        timer?.stop()
        timer = nil
        throughputTimer?.stop()
        throughputTimer = nil
        throughputFirstRun?.cancel()
        throughputFirstRun = nil
        pinger?.close()
        pinger = nil
        continuation?.finish()
        continuation = nil
        throughputContinuation?.finish()
        throughputContinuation = nil
        holdback.removeAll()
        recentSamples.removeAll()
        consecutiveTotalFailures = 0
        currentPhase = .idle
    }

    // MARK: - Throughput (plan §7)

    /// A stream of completed throughput tests. Call before or after `start()`.
    public func throughputResults() -> AsyncStream<ThroughputResult> {
        let (stream, cont) = AsyncStream<ThroughputResult>.makeStream(bufferingPolicy: .bufferingNewest(32))
        throughputContinuation = cont
        return stream
    }

    /// Run a throughput test immediately (manual "Run now"). Durations are
    /// overridable for tests; the scheduled path uses the defaults.
    public func runThroughputTestNow(
        directionDuration: Duration = .seconds(10),
        settle: Duration = .seconds(2),
        warmup: Duration = .seconds(1)
    ) async {
        await runThroughputTest(directionDuration: directionDuration, settle: settle, warmup: warmup)
    }

    private func startThroughputSchedule() {
        // First run ~3 s after start; the repeating timer takes over after that.
        throughputFirstRun = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.runThroughputTest()
        }
        let interval = Duration.seconds(max(1, settings.throughputInterval) * 60)
        let t = ScheduledTimer(interval: interval, queue: throughputTimerQueue) { [weak self] _ in
            Task { await self?.runThroughputTest() }
        }
        throughputTimer = t
        t.start()
    }

    /// Wire sequence used only for the warm-up ping.
    ///
    /// `UInt16.max`, which is the top of the *internet* probe's space now that
    /// `ProbeHost` splits the range, so the sample loop reaches it after 9.1
    /// hours rather than 18. Still harmless: the prime resolves within its
    /// timeout, seconds into the session, and `pending` is keyed by sequence
    /// only for as long as a probe is in flight.
    private static let primeSequence: UInt32 = 0xFFFF

    private func runThroughputTest(
        directionDuration: Duration = .seconds(10),
        settle: Duration = .seconds(2),
        warmup: Duration = .seconds(1)
    ) async {
        guard let throughput, !throughputInProgress, throughputContinuation != nil else { return }
        throughputInProgress = true
        defer {
            throughputInProgress = false
            currentPhase = .idle
        }

        // The idle baseline is taken *before* the meta fetch, and the meta
        // fetch is tagged as load.
        //
        // Both halves were wrong, and the second one produced a 591 ms spike on
        // both hosts six seconds into a session — tagged `idle`, and therefore
        // the session's maximum on both latency cards, on a link whose real
        // worst reading was 31 ms. `fetchMeta()` is an HTTPS round trip to
        // Cloudflare; on Wi-Fi it delays the ping loop exactly as the transfer
        // does. It is our traffic, so it is our phase.
        //
        // And the baseline that follows it must not include it. Reading the
        // window *after* the fetch meant the ten seconds it averaged over were
        // the ten seconds the fetch had just disturbed — an idle baseline
        // measured during activity, feeding the one subtraction the Speed card
        // leads with.
        let now = Date()
        let idleFrom = now.addingTimeInterval(-(directionDuration.timeInterval + 2))
        let idleStats = latencyStats(phase: .idle, from: idleFrom, to: now)
        let idle = idleStats.mean

        if cachedMeta == nil {
            currentPhase = .downloading
            cachedMeta = await throughput.fetchMeta()
            currentPhase = .idle
        }

        currentPhase = .downloading
        let dlStart = Date()
        let download = await throughput.measureDownload(duration: directionDuration, discardingFirst: warmup)
        let dlEnd = Date()
        currentPhase = .idle

        try? await Task.sleep(for: settle) // let the queue drain between directions

        currentPhase = .uploading
        let ulStart = Date()
        let upload = await throughput.measureUpload(duration: directionDuration, discardingFirst: warmup)
        let ulEnd = Date()
        currentPhase = .idle

        guard throughputContinuation != nil else { return } // stopped mid-test

        // Full spread for the load phases too. These used a `latencyMean`
        // helper that built an array only to average it; `latencyStats` was
        // already computing everything it did, and more.
        let dlStats = latencyStats(phase: .downloading, from: dlStart, to: dlEnd)
        let ulStats = latencyStats(phase: .uploading, from: ulStart, to: ulEnd)
        let dlLatency = dlStats.mean
        let ulLatency = ulStats.mean

        throughputContinuation?.yield(
            ThroughputResult(
                downloadMbps: download.mbps,
                uploadMbps: upload.mbps,
                bytesDownloaded: download.bytes,
                bytesUploaded: upload.bytes,
                idleLatencyMs: idle ?? 0,
                downloadLatencyMs: dlLatency ?? idle ?? 0,
                uploadLatencyMs: ulLatency ?? idle ?? 0,
                idleJitterMs: idleStats.jitter,
                packetLoss: lossFraction(from: idleFrom, to: ulEnd),
                idleLowMs: idleStats.low,
                idleHighMs: idleStats.high,
                downloadJitterMs: dlStats.jitter,
                downloadLowMs: dlStats.low,
                downloadHighMs: dlStats.high,
                uploadJitterMs: ulStats.jitter,
                uploadLowMs: ulStats.low,
                uploadHighMs: ulStats.high,
                isp: cachedMeta?.isp,
                serverLocation: cachedMeta?.colo
            )
        )
    }

    /// Mean and jitter of internet-host RTT over samples tagged `phase` in a
    /// window, on `RunningStats`' definitions so the speed card and the latency
    /// cards cannot drift apart on what "jitter" means. A timeout marks a gap
    /// rather than differencing against a stale value.
    /// Internet-host RTT over the samples tagged `phase` in a window.
    ///
    /// Every member is optional: a window that caught no replies measured
    /// nothing, and recording that as zero is the bug schema 3 exists to undo
    /// (see ``ThroughputResult/idleJitterMs``).
    struct PhaseLatency {
        var mean: Double?
        var low: Double?
        var high: Double?
        var jitter: Double?
    }

    /// The whole spread, not just the mean. `RunningStats` was already
    /// computing min and max here and the result threw them away — which is
    /// why the Speed card could show a load average with nothing to say how
    /// far the spike went.
    private func latencyStats(phase: LoadPhase, from: Date, to: Date) -> PhaseLatency {
        var stats = RunningStats()
        // The warm-up exclusion belongs here too. The first scheduled test
        // fires about three seconds after pings begin, so without it the idle
        // baseline of every session's first test is one or two samples that
        // include the ~580 ms socket warm-up spike and the first internet
        // timeout — a baseline wrong in both directions, feeding the one
        // subtraction the Speed card leads with.
        for sample in recentSamples
        where sample.id >= PingSample.warmupSampleCount
            && sample.phase == phase && sample.timestamp >= from && sample.timestamp <= to {
            if let ms = sample.internetMs { stats.add(ms) } else { stats.markGap() }
        }
        guard stats.count > 0 else { return PhaseLatency(jitter: stats.measuredJitter) }
        return PhaseLatency(mean: stats.mean, low: stats.min, high: stats.max,
                            jitter: stats.measuredJitter)
    }

    /// Share of samples in the window with no internet reply, 0…1, or `nil` if
    /// the window held no samples. Every phase, so this covers the whole test
    /// rather than only its idle lead-in.
    private func lossFraction(from: Date, to: Date) -> Double? {
        var total = 0, lost = 0
        for sample in recentSamples where sample.timestamp >= from && sample.timestamp <= to {
            total += 1
            if sample.internetMs == nil { lost += 1 }
        }
        return total > 0 ? Double(lost) / Double(total) : nil
    }


    /// Phase 5 hook — set the load phase samples are tagged with.
    public func setPhase(_ phase: LoadPhase) {
        currentPhase = phase
    }

    /// What each host resolved to, once `start()` has opened the pinger.
    public func resolvedAddresses() -> [(host: String, description: String)] {
        guard let pinger else { return [] }
        return [settings.routerHost, settings.internetHost].compactMap { host in
            pinger.resolvedDescription(of: host).map { (host, $0) }
        }
    }

    // MARK: - Tick

    private func tick(id: UInt32, scheduledAt: Date) async {
        guard continuation != nil else { return }

        let router: Double?
        let internet: Double?
        let routerLate: Double?
        let internetLate: Double?
        if let pinger {
            // One sequence space per host, so the two probes cannot collide
            // when both hosts are the same address — see `ProbeHost`. The
            // `id + 1` offset predates that and still earns its keep: 1.1.1.1
            // does not answer an echo request with sequence 0 (measured: 0 got
            // no reply on any run, 65535 and 1 upwards always did), so without
            // it the first internet sample of every session timed out, which
            // is what `PingSample.warmupSampleCount` was quietly hiding.
            async let r = pinger.ping(host: settings.routerHost,
                                      sequence: ProbeHost.router.wireSequence(for: id &+ 1))
            async let i = pinger.ping(host: settings.internetHost,
                                      sequence: ProbeHost.internet.wireSequence(for: id &+ 1))
            let (ro, io) = await (r, i)
            router = ro.rttMs
            internet = io.rttMs
            // A reply that missed the deadline resolves as `.lateReply`, so
            // `rttMs` is nil above and the probe still reads as a timeout
            // everywhere loss is counted. The RTT rides alongside instead of
            // being discarded — see `PingOutcome`.
            routerLate = ro.lateRttMs
            internetLate = io.lateRttMs
        } else {
            router = nil
            internet = nil // no socket — still emit a sample so the stream keeps cadence
            routerLate = nil
            internetLate = nil
        }

        // The engine may have been stopped while these pings were in flight.
        guard continuation != nil else { return }

        let sample = PingSample(
            id: id, timestamp: scheduledAt,
            routerMs: router, internetMs: internet,
            routerLateMs: routerLate, internetLateMs: internetLate,
            phase: currentPhase
        )
        holdback[id] = sample

        recentSamples.append(sample)
        if recentSamples.count > 90 { recentSamples.removeFirst(recentSamples.count - 90) }

        flushInOrder()

        // `noReply`, not `== nil`: the socket-rebuild heuristic is looking for
        // a dead socket, and a host answering at 2.4 s is emphatically not one.
        // Keying on the timely columns alone would have torn down and rebuilt a
        // working socket in the middle of a bufferbloat episode.
        if sample.routerNoReply, sample.internetNoReply {
            consecutiveTotalFailures += 1
            if consecutiveTotalFailures >= Self.failureRecoveryThreshold {
                consecutiveTotalFailures = 0
                rebuildPinger()
            }
        } else {
            consecutiveTotalFailures = 0
        }
    }

    /// Tear down and reopen the ICMP socket. On failure `pinger` is left nil and
    /// the next window of failures triggers another attempt.
    private func rebuildPinger() {
        pinger?.close()
        let fresh = makePinger([settings.routerHost, settings.internetHost], settings.pingTimeout)
        do {
            try fresh.open()
            pinger = fresh
        } catch {
            pinger = nil
        }
    }

    /// Emit every buffered sample whose turn has come, oldest first.
    private func flushInOrder() {
        guard let continuation else { return }
        while let sample = holdback.removeValue(forKey: emitNext) {
            continuation.yield(sample)
            emitNext &+= 1
        }
    }
}
