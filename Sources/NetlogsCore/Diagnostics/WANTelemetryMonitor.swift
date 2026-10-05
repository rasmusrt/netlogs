import Foundation

/// One poll of the gateway, and whether it is worth storing.
public struct WANTelemetryEvent: Sendable {
    public let snapshot: WANSnapshot
    public let shouldStore: Bool
}

/// Decides whether a gateway poll is worth a row.
///
/// Polling every 2 s and storing every poll would write the same radio figures
/// six times over, since the CPE only refreshes them every ~12 s. So a poll is
/// stored when something in it moved: a new CPE report, the counters, or the
/// failure state. The counters move about every 5 s, which sets the real rate
/// at about one row per 5 s. The heartbeat bounds the gap when nothing moves
/// at all — a stalled controller reads the same as a quiet one otherwise.
public struct WANChangeDetector: Sendable {
    public let heartbeat: Duration
    private var last: WANSnapshot?
    private var lastStoredAt: Date?

    public init(heartbeat: Duration = .seconds(60)) {
        self.heartbeat = heartbeat
    }

    public mutating func shouldStore(_ snapshot: WANSnapshot, now: Date) -> Bool {
        let changed = last.map {
            $0.radio != snapshot.radio || $0.counters != snapshot.counters
                || $0.failure != snapshot.failure
        } ?? true
        let heartbeatDue = lastStoredAt.map {
            now.timeIntervalSince($0) >= heartbeat.timeInterval
        } ?? true
        guard changed || heartbeatDue else { return false }
        last = snapshot
        lastStoredAt = now
        return true
    }
}

/// Polls a ``WANTelemetryProvider`` on its own timer.
///
/// Mirrors ``DiagnosticsMonitor``, with one difference that matters: a poll is
/// a network request and can take seconds. A poll still in flight when the
/// timer fires is **not** joined by a second one — the tick is skipped. The
/// ping loop never learns this monitor exists, so a hung gateway costs gateway
/// readings and nothing else.
public final class WANTelemetryMonitor: @unchecked Sendable {
    private let provider: any WANTelemetryProvider
    private let interval: Duration

    private let queue = DispatchQueue(label: "netlogs.wan")
    private let timerQueue = DispatchQueue(label: "netlogs.wan.timer")

    private var timer: ScheduledTimer?
    private var detector: WANChangeDetector
    private var continuation: AsyncStream<WANTelemetryEvent>.Continuation?
    private var inFlight: Task<Void, Never>?

    public init(provider: any WANTelemetryProvider, interval: Duration = .seconds(2),
                heartbeat: Duration = .seconds(60)) {
        self.provider = provider
        self.interval = interval
        self.detector = WANChangeDetector(heartbeat: heartbeat)
    }

    public func start() -> AsyncStream<WANTelemetryEvent> {
        let (stream, cont) = AsyncStream<WANTelemetryEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        queue.sync {
            continuation = cont
            poll()
        }
        let t = ScheduledTimer(interval: interval, queue: timerQueue) { [weak self] _ in
            self?.queue.async { [weak self] in self?.poll() }
        }
        timer = t
        t.start()
        return stream
    }

    public func stop() {
        timer?.stop()
        timer = nil
        queue.sync {
            inFlight?.cancel()
            inFlight = nil
            continuation?.finish()
            continuation = nil
        }
        provider.close()
    }

    private func poll() { // always on `queue`
        guard inFlight == nil, continuation != nil else { return }
        inFlight = Task { [weak self, provider] in
            let snapshot = await provider.poll()
            self?.queue.async { [weak self] in self?.deliver(snapshot) }
        }
    }

    private func deliver(_ snapshot: WANSnapshot) { // always on `queue`
        inFlight = nil
        guard let continuation else { return }
        let store = detector.shouldStore(snapshot, now: snapshot.timestamp)
        continuation.yield(WANTelemetryEvent(snapshot: snapshot, shouldStore: store))
    }
}
