import Foundation
import Observation
import NetlogsCore

/// Owns a live monitoring session: drives `MonitorEngine`, fans each
/// `PingSample` out to the stat/log view-models and the `SessionStore`, and
/// exposes coarse run state to the toolbar.
@MainActor
@Observable
final class MonitorController {

    enum RunState: Equatable {
        case idle
        case starting
        case running
        case error(String)
    }

    let stats = LiveStats()
    let log = PingLog()
    let chart = LiveChartModel()
    let failures = FailureLog()
    let diagnostics = DiagnosticsModel()
    let throughput = ThroughputModel()
    let traffic = TrafficLog()
    let wan = WANTelemetryModel()

    private(set) var state: RunState = .idle
    private(set) var session: SessionState?

    let store: SessionStore
    /// Fired on the main actor once `stopped_at` has actually been written.
    ///
    /// Stopping finishes the engine asynchronously, so a caller that reloaded
    /// the session list straight after `stop()` read the row *before* it was
    /// updated — every cleanly stopped session then showed up flagged as
    /// "not cleanly stopped". Callers reload from here instead.
    var onSessionStopped: (@MainActor () -> Void)?
    private let makeEngine: @MainActor (MonitorSettings) -> MonitorEngine
    private var engine: MonitorEngine?
    private var diagMonitor: DiagnosticsMonitor?
    private var pump: Task<Void, Never>?
    private var diagPump: Task<Void, Never>?
    private var wanMonitor: WANTelemetryMonitor?
    private var wanPump: Task<Void, Never>?
    private var throughputPump: Task<Void, Never>?
    private var manualTest: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    /// The in-flight `nettop` run, if any. One at a time: the trigger already
    /// guarantees that, and holding the handle is what lets `stop()` cancel a
    /// capture that would otherwise outlive its session by five seconds and
    /// write a row against a session the user has finished with.
    private var capture: Task<Void, Never>?
    private var captureTrigger = TrafficCaptureTrigger()
    private let sampleTraffic: any TrafficSampling
    /// Keeps the Mac awake for the duration of a session (plan §6.4).
    private var activity: (any NSObjectProtocol)?

    var isRunning: Bool { state == .running || state == .starting }

    init(
        store: SessionStore,
        engineFactory: @escaping @MainActor (MonitorSettings) -> MonitorEngine = { MonitorEngine(settings: $0) },
        trafficSampler: any TrafficSampling = NetTopRunner()
    ) {
        self.store = store
        self.makeEngine = engineFactory
        self.sampleTraffic = trafficSampler
    }

    /// The hosts the running session is actually probing.
    ///
    /// **Not** `AppSettings.monitor`. With auto-detect on, `start` resolves the
    /// gateway into a copy and the stored setting keeps whatever was last typed
    /// into the (disabled) Router field — so a view labelled from settings names
    /// an address the app may never have pinged. That is a bad bug in an app
    /// whose entire output is "this host behaved like this": it was reporting a
    /// healthy 4.6 ms minimum against `10.0.0.1` while measuring `192.168.0.1`.
    ///
    /// `nil` only in the moment between `start()` and the session row existing.
    var probedHosts: (router: String, internet: String)? {
        session.map { ($0.settings.routerHost, $0.settings.internetHost) }
    }

    func toggle(settings: MonitorSettings) {
        isRunning ? stop() : start(settings: settings)
    }

    func start(settings: MonitorSettings) {
        guard case .idle = stateOrError else { return }
        var settings = settings
        // Resolved once, here, and then fixed for the whole session. The
        // session row records the host it used, so a target that changed
        // mid-run would leave a log whose router column silently means two
        // different machines. A detection failure falls back to whatever is in
        // settings rather than stopping the session.
        if settings.routerHostAutomatic, let gateway = MacDiagnostics.defaultGateway() {
            settings.routerHost = gateway
        }
        state = .starting
        stats.reset()
        log.reset()
        chart.reset()
        failures.reset()
        diagnostics.reset()
        throughput.reset()
        traffic.reset()
        wan.reset()
        captureTrigger = TrafficCaptureTrigger()
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Netlogs monitoring session"
        )
        pump = Task { [weak self] in await self?.run(settings: settings) }
    }

    func stop() {
        guard isRunning else { return }
        endActivity()
        // Seal the trailing load/outage run so a session stopped mid-download
        // still renders that band.
        chart.finish()
        // Stop clicked inside the first three seconds catches `run()` parked in
        // the engine's socket warm-up. Without this cancel it woke up after the
        // teardown and rebuilt the session this call had just dismantled.
        pump?.cancel(); pump = nil
        clock?.cancel(); clock = nil
        diagMonitor?.stop(); diagMonitor = nil
        diagPump?.cancel(); diagPump = nil
        stopWAN()
        throughputPump?.cancel(); throughputPump = nil
        manualTest?.cancel(); manualTest = nil
        capture?.cancel(); capture = nil
        traffic.captureFailed()
        let engine = engine
        let session = session
        Task { [store, weak self] in
            await engine?.stop()               // finishes the stream → run() returns
            if let session { try? store.stopSession(session.id) }
            self?.onSessionStopped?()
        }
        state = .idle
        self.engine = nil
        self.session = nil
    }

    /// Manual "Run now" — kicks a throughput test immediately. Durations are
    /// overridable for the headless check.
    func runThroughputTestNow(
        directionDuration: Duration = .seconds(10),
        settle: Duration = .seconds(2),
        warmup: Duration = .seconds(1)
    ) {
        guard state == .running, manualTest == nil, let engine else { return }
        manualTest = Task { [weak self] in
            await engine.runThroughputTestNow(
                directionDuration: directionDuration, settle: settle, warmup: warmup
            )
            self?.manualTest = nil
        }
    }

    // MARK: -

    private var stateOrError: RunState {
        if case .error = state { return .idle } // allow restart after an error
        return state
    }

    private func run(settings: MonitorSettings) async {
        do {
            let session = try store.startSession(settings)
            self.session = session
            startClock(from: session.startedAt)

            let engine = makeEngine(settings)
            self.engine = engine

            let throughputStream = await engine.throughputResults()
            throughputPump = Task { [weak self] in
                for await result in throughputStream {
                    guard let self else { break }
                    self.throughput.apply(result)
                    try? self.store.appendThroughput(result, to: session.id)
                }
            }

            let stream = try await engine.start()
            // Cancellation alone does not surface here: the engine's warm-up
            // sleeps with `try?` and then hands back an already-finished
            // stream, so a `stop()` that happened during those three seconds
            // used to be invisible to this code. It resumed, set `.running`
            // over the `.idle` stop had just written, and started a second
            // DiagnosticsMonitor the completed `stop()` had no handle on — the
            // toolbar showed a session that wasn't running, `start()` refused
            // to run again because it guards on state, and the orphaned
            // monitor kept polling CoreWLAN every 5 s until Stop was clicked a
            // second time. Stopping the engine covers the opposite ordering,
            // where `stop()` released its reference before this call got the
            // actor and opened a socket nobody would ever close.
            guard !Task.isCancelled, state == .starting else {
                await engine.stop()
                return
            }
            state = .running

            startDiagnostics(settings: settings, sessionID: session.id)
            if settings.wanTelemetryEnabled {
                startWAN(settings: settings, sessionID: session.id)
            }

            for await sample in stream {
                // The first samples can carry the ICMP socket warm-up spike
                // (~1 s); keep them in the log and on disk, but don't let them
                // skew the session stats or set the chart's y-axis
                // (PHASE1-FINDINGS §3).
                if sample.id >= PingSample.warmupSampleCount {
                    stats.add(sample)
                    chart.append(sample)
                    // Same exclusion: a warm-up timeout is a socket artefact,
                    // not a dropped packet. Counting it here while the stats
                    // skip it would show "0 failures" in the header next to a
                    // non-empty Failures tab.
                    failures.append(sample)
                }
                log.append(sample)
                store.append(sample, to: session.id)

                if settings.trafficCaptureEnabled,
                   sample.id >= PingSample.warmupSampleCount {
                    considerCapture(sample, sessionID: session.id)
                }
            }
        } catch {
            // Same race on the failure path: a socket that fails to open after
            // the user has already stopped would otherwise replace their
            // `.idle` with a red error banner, and nil out the engine and
            // session of whatever run started in the meantime.
            guard !Task.isCancelled else { return }
            endActivity()
            clock?.cancel(); clock = nil
            diagMonitor?.stop(); diagMonitor = nil
            diagPump?.cancel(); diagPump = nil
            stopWAN()
            throughputPump?.cancel(); throughputPump = nil
            state = .error(Self.describe(error))
            if let session { try? store.stopSession(session.id) }
            self.engine = nil
            self.session = nil
        }
        pump = nil
    }

    /// Fire a `nettop` capture if this sample says a latency episode has begun.
    ///
    /// **Never awaited from the sample loop.** `nettop` takes about five
    /// seconds; awaiting it here would stall the loop that drains the engine's
    /// stream, which back-pressures the engine and puts a five-second hole in
    /// the ping log the capture is supposed to explain. It is detached, and its
    /// timestamp is the sample's, not the moment it finishes.
    private func considerCapture(_ sample: PingSample, sessionID: UUID) {
        guard capture == nil,
              captureTrigger.shouldCapture(sample, now: sample.timestamp) else { return }
        traffic.beginCapture()
        capture = Task { [weak self, sampleTraffic, store] in
            let processes = await sampleTraffic.sample(interval: 1)
            guard let self, !Task.isCancelled else { return }
            // `nil` is "could not sample"; `[]` is "sampled, nothing was
            // sending" — and the second one is stored, because a quiet Mac
            // during a latency episode is the finding that points at another
            // device on the network.
            guard let processes else {
                self.traffic.captureFailed()
                self.capture = nil
                return
            }
            let capture = TrafficCapture(
                timestamp: sample.timestamp,
                routerMs: sample.routerRttMs, internetMs: sample.internetRttMs,
                intervalSeconds: 1, processes: processes
            )
            self.traffic.append(capture)
            try? store.appendTrafficCapture(capture, to: sessionID)
            self.capture = nil
        }
    }

    private func endActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func startDiagnostics(settings: MonitorSettings, sessionID: UUID) {
        let monitor = DiagnosticsMonitor(
            provider: MacDiagnostics(),
            interval: settings.diagnosticsInterval
        )
        diagMonitor = monitor
        let events = monitor.start()
        diagPump = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                self.diagnostics.apply(event.snapshot, stored: event.shouldStore)
                if event.shouldStore {
                    try? self.store.appendDiagnostics(event.snapshot, to: sessionID)
                }
            }
        }
    }

    /// Poll the gateway beside the session, on its own monitor. The ping loop
    /// never learns about it; a hung gateway costs gateway readings only.
    ///
    /// The key is read here, once per session, off the main actor — the
    /// Keychain may ask the user first. No key is not an error: the monitor
    /// runs and records `.noKey`, so the session says why it has no WAN data.
    private func startWAN(settings: MonitorSettings, sessionID: UUID) {
        wan.begin()
        wanPump = Task { [weak self, store] in
            let key = await Task.detached { GatewayKeychain.read() }.value
            guard let self, !Task.isCancelled else { return }
            let monitor = WANTelemetryMonitor(provider: UniFiGateway(
                host: settings.effectiveWANGatewayHost,
                apiKey: key,
                pinnedSHA256: settings.wanCertificateSHA256
            ))
            self.wanMonitor = monitor
            for await event in monitor.start() {
                self.wan.apply(event.snapshot, stored: event.shouldStore)
                if event.shouldStore {
                    try? store.appendWANSnapshot(event.snapshot, to: sessionID)
                }
            }
        }
    }

    private func stopWAN() {
        wanMonitor?.stop(); wanMonitor = nil
        wanPump?.cancel(); wanPump = nil
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? ICMPPingerError { return e.description }
        if let e = error as? SessionStoreError { return e.description }
        return error.localizedDescription
    }

    private func startClock(from start: Date) {
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.stats.elapsed = Date().timeIntervalSince(start)
                if let engine = self.engine {
                    self.throughput.setPhase(await engine.currentPhase)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
