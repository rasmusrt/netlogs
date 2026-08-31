import Foundation

/// Decides whether a freshly-polled ``DiagnosticsSnapshot`` is worth storing:
/// **on change** (a stable field differs from the last stored snapshot) **or**
/// every `heartbeat` seconds (plan §6.2). Continuously-varying radio metrics do
/// not count as a change.
///
/// Pure and deterministic — the poller feeds it a snapshot and `now`.
public struct DiagnosticsChangeDetector: Sendable {
    public let heartbeat: Duration

    private var lastStoredSignature: String?
    private var lastStoredAt: Date?

    public init(heartbeat: Duration = .seconds(60)) {
        self.heartbeat = heartbeat
    }

    /// Returns `true` and records this snapshot as the new baseline, or `false`.
    public mutating func shouldStore(_ snapshot: DiagnosticsSnapshot, now: Date) -> Bool {
        let changed = snapshot.stableSignature != lastStoredSignature
        let heartbeatDue = lastStoredAt.map {
            now.timeIntervalSince($0) >= heartbeat.timeInterval
        } ?? true

        guard changed || heartbeatDue else { return false }
        lastStoredSignature = snapshot.stableSignature
        lastStoredAt = now
        return true
    }
}
