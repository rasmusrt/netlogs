import Foundation
import Observation
import NetlogsCore

/// The session's traffic captures, newest first.
///
/// Its own `@Observable` object for the same reason `FailureLog` is: a capture
/// lands at most once every ten minutes and must not invalidate the chart or
/// the stat cards when it does (plan §8.2).
@MainActor
@Observable
final class TrafficLog {
    private(set) var captures: [TrafficCapture] = []
    /// A capture is running now. The sheet says so rather than looking empty
    /// for the five seconds `nettop` takes — an empty list already means
    /// something specific here ("nothing on this Mac was sending"), so it must
    /// not also mean "still working".
    private(set) var isCapturing = false

    var isEmpty: Bool { captures.isEmpty }

    func beginCapture() { isCapturing = true }

    func append(_ capture: TrafficCapture) {
        captures.insert(capture, at: 0)
        isCapturing = false
    }

    func captureFailed() { isCapturing = false }

    func reset() {
        captures = []
        isCapturing = false
    }
}
