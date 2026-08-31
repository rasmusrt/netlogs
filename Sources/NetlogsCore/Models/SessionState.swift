import Foundation

/// A monitoring session's identity and lifecycle (plan §5).
///
/// Written to storage when the session starts and updated on stop, so a crash
/// leaves a session row with `stoppedAt == nil` that is still readable.
public struct SessionState: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var startedAt: Date
    public var stoppedAt: Date?
    public var settings: MonitorSettings
    /// Timestamp of the newest stored sample, filled in by `SessionStore`.
    ///
    /// Exists so `duration` can be truthful about a session that was never
    /// cleanly stopped. Optional and defaulted so older encoded blobs decode.
    public var lastSampleAt: Date?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        stoppedAt: Date? = nil,
        settings: MonitorSettings,
        lastSampleAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.settings = settings
        self.lastSampleAt = lastSampleAt
    }

    public var isRunning: Bool { stoppedAt == nil }

    /// How long the session actually ran.
    ///
    /// A session row is written at start and updated at stop, so a force-quit
    /// leaves `stoppedAt` nil forever. Measuring that against *now* made a
    /// session that ran for eight seconds report "12h 0m" and climbing. Fall
    /// back to the last sample we actually recorded.
    public var duration: TimeInterval {
        let end = stoppedAt ?? lastSampleAt ?? startedAt
        return max(0, end.timeIntervalSince(startedAt))
    }
}
