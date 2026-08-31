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

    func setPhase(_ phase: LoadPhase) {
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
