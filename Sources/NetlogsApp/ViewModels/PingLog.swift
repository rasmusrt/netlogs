import Foundation
import Observation
import NetlogsCore

/// The live ping-log table's backing store (plan §8.2 / §8.3): a time-based
/// 5-minute window, newest first. Full history is in SQLite — this is only what
/// the `Table` renders.
@MainActor
@Observable
final class PingLog {
    private var window = PingLogWindow(window: .seconds(300))

    /// Newest first — the row order the table shows.
    ///
    /// Stored, not computed. It used to be `Array(window.newestFirst)`, which
    /// allocated and copied a fresh 300-element array on *every read* — and
    /// SwiftUI reads it once per layout pass, which during a sidebar
    /// show/hide animation means at display rate. That was the sidebar's
    /// stutter: ~16 KB copied 120 times a second, and a `Table` whose data
    /// identity changed on every frame, forcing a reload mid-animation.
    /// Rebuilding it once per sample instead makes it 1 allocation a second.
    private(set) var rows: [PingSample] = []

    var count: Int { rows.count }

    func append(_ sample: PingSample) {
        window.append(sample)
        rows = Array(window.newestFirst)
    }

    func reset() {
        window.reset()
        rows = []
    }
}
