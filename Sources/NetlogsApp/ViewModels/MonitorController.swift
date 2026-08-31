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
    private var throughputPump: Task<Void, Never>?
    private var manualTest: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    /// Keeps the Mac awake for the duration of a session (plan §6.4).
    private var activity: (any NSObjectProtocol)?

    var isRunning: Bool { state == .running || state == .starting }

    init(
        store: SessionStore,
        engineFactory: @escaping @MainActor (MonitorSettings) -> MonitorEngine = { MonitorEngine(settings: $0) }
    ) {
        self.store = store
        self.makeEngine = engineFactory
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
        clock?.cancel(); clock = nil
        diagMonitor?.stop(); diagMonitor = nil
        diagPump?.cancel(); diagPump = nil
        throughputPump?.cancel(); throughputPump = nil
        manualTest?.cancel(); manualTest = nil
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
            state = .running

            startDiagnostics(settings: settings, sessionID: session.id)

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
            }
        } catch {
            endActivity()
            clock?.cancel(); clock = nil
            diagMonitor?.stop(); diagMonitor = nil
            diagPump?.cancel(); diagPump = nil
            throughputPump?.cancel(); throughputPump = nil
            state = .error(Self.describe(error))
            if let session { try? store.stopSession(session.id) }
            self.engine = nil
            self.session = nil
        }
        pump = nil
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
