import Foundation
import Observation
import NetlogsCore

/// Throughput + bufferbloat state for the dashboard. Its own `@Observable`
/// object; a test completing (every N minutes) never re-renders the ping table.
@MainActor
@Observable
final class ThroughputModel {
    private(set) var results: [ThroughputResult] = []
    /// The engine's current load phase, for a "testing…" indicator.
    private(set) var phase: LoadPhase = .idle

    var latest: ThroughputResult? { results.last }
    var isTesting: Bool { phase != .idle }

    func apply(_ result: ThroughputResult) {
        results.append(result)
    }

    /// Guarded, because the controller's clock calls this once a second with
    /// whatever the engine reports — which is `.idle` for all but the ~25 s of
    /// a test. An unconditional write is an Observation change notification
    /// every tick, and `phase` / `isTesting` are read by the summary cards, so
    /// the cards were being asked to re-render for a value that had not moved.
    func setPhase(_ phase: LoadPhase) {
        guard phase != self.phase else { return }
        self.phase = phase
    }

    func reset() {
        results.removeAll()
        phase = .idle
    }

    /// Rolled up by `NetlogsCore`, so the live dashboard and a loaded saved
    /// session compute this identically.
    var averages: ThroughputAverages { ThroughputAverages(results: results) }
}
