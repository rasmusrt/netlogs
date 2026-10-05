import Foundation
import Observation
import NetlogsCore

/// Live gateway telemetry for the connection badge. Its own `@Observable`
/// object, like `DiagnosticsModel`, so a 2 s gateway poll re-renders the badge
/// and nothing else.
@MainActor
@Observable
final class WANTelemetryModel {
    /// `false` when the session was started with telemetry off, so the badge
    /// can stay out of the way rather than report a failure nobody asked about.
    private(set) var isActive = false
    private(set) var latest: WANSnapshot?
    /// The last radio actually reported. Kept across a failed poll, which
    /// says nothing about the radio, so the badge does not flicker to empty.
    private(set) var radio: CellularRadio?
    private(set) var storedCount = 0

    func begin() {
        reset()
        isActive = true
    }

    func apply(_ snapshot: WANSnapshot, stored: Bool) {
        latest = snapshot
        if let radio = snapshot.radio { self.radio = radio }
        if stored { storedCount += 1 }
    }

    func reset() {
        isActive = false
        latest = nil
        radio = nil
        storedCount = 0
    }
}
