import Foundation
import Observation
import NetlogsCore

/// Live diagnostics for the compact stat card and the Network sheet. Its own
/// `@Observable` object so a 5 s diagnostics poll doesn't re-render the ping
/// table or the ping stats.
@MainActor
@Observable
final class DiagnosticsModel {
    private(set) var latest: DiagnosticsSnapshot?
    private(set) var pollCount = 0

    /// The snapshots this session has **stored** — the live source for the
    /// Network sheet's trace.
    ///
    /// Only the stored ones, deliberately. That set is exactly what a saved
    /// session reads back from `diagnostics_snapshots`, so the trace looks the
    /// same whether the session is running or reopened later. Appending every
    /// poll instead would draw a denser line live than the same session can
    /// ever draw again — the drift the Speed sheet already had once.
    ///
    /// Cheap to keep, and cheap to observe: a stored snapshot arrives about
    /// once a minute, and `@Observable` tracks per property, so appending here
    /// invalidates the sheet that reads it rather than the card that reads
    /// `latest`.
    private(set) var history: [DiagnosticsSnapshot] = []

    /// Rebuilt when a snapshot is stored — about once a minute — rather than
    /// in the sheet's body, which would re-reduce every snapshot on each of the
    /// 5 s polls that move `latest` (`SessionDetail.tableRows`, same reason).
    private(set) var trace = DiagnosticsTrace()

    /// Bounds a pathological session — a flapping connection stores one
    /// snapshot per poll rather than one a minute. At 5 s that is under three
    /// hours, and `DiagnosticsTrace` decimates long before this matters to the
    /// drawing.
    static let historyCap = 2_000

    func apply(_ snapshot: DiagnosticsSnapshot, stored: Bool) {
        latest = snapshot
        pollCount += 1
        guard stored else { return }
        history.append(snapshot)
        if history.count > Self.historyCap { history.removeFirst(history.count - Self.historyCap) }
        trace = DiagnosticsTrace.build(history)
    }

    func reset() {
        latest = nil
        pollCount = 0
        history = []
        trace = DiagnosticsTrace()
    }
}
