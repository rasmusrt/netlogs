import Foundation

/// One poll of the diagnostics provider.
public struct DiagnosticsEvent: Sendable {
    public let snapshot: DiagnosticsSnapshot
    /// `true` when this snapshot should be persisted (changed vs the last
    /// stored one, or a 60 s heartbeat). Radio metrics still update running
    /// stats every poll regardless (plan §6.2).
    public let shouldStore: Bool
}

/// Polls a ``DiagnosticsProvider`` on a fixed interval and emits
/// ``DiagnosticsEvent``s. Separate from `MonitorEngine` — a 5 s diagnostics
/// tick and the 1 Hz ping loop are independent concerns.
public final class DiagnosticsMonitor: @unchecked Sendable {
    private let provider: any DiagnosticsProvider
    private let interval: Duration

    /// Sync domain for poll / detector / continuation.
    private let queue = DispatchQueue(label: "netlogs.diagnostics")
    /// Distinct queue for the timer — `ScheduledTimer.stop()` does a `sync`, so
    /// it must not share `queue` (that would be a nested same-queue sync).
    private let timerQueue = DispatchQueue(label: "netlogs.diagnostics.timer")

    private var timer: ScheduledTimer?
    private var detector: DiagnosticsChangeDetector
    private var continuation: AsyncStream<DiagnosticsEvent>.Continuation?

    public init(
        provider: any DiagnosticsProvider,
        interval: Duration = .seconds(5),
        heartbeat: Duration = .seconds(60)
    ) {
        self.provider = provider
        self.interval = interval
        self.detector = DiagnosticsChangeDetector(heartbeat: heartbeat)
    }

    public func start() -> AsyncStream<DiagnosticsEvent> {
        let (stream, cont) = AsyncStream<DiagnosticsEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        queue.sync {
            continuation = cont
            poll() // first reading immediately, don't wait a full interval
        }
        let t = ScheduledTimer(interval: interval, queue: timerQueue) { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in self?.poll() }
        }
        timer = t
        t.start()
        return stream
    }

    public func stop() {
        timer?.stop()
        timer = nil
        queue.sync {
            continuation?.finish()
            continuation = nil
        }
    }

    /// Take a reading now, outside the schedule (e.g. after enabling SSID).
    public func pollNow() {
        queue.async { [weak self] in self?.poll() }
    }

    private func poll() { // always on `queue`
        let snapshot = provider.snapshot()
        let shouldStore = detector.shouldStore(snapshot, now: Date())
        continuation?.yield(DiagnosticsEvent(snapshot: snapshot, shouldStore: shouldStore))
    }
}
