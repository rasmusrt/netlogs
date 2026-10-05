import Foundation
import Observation
import NetlogsCore

/// Holds the Analysis screen's loaded range.
///
/// Its own `@Observable` object rather than state on the view, for the reason
/// `LiveSheetLoader` documents: a `@State` write re-renders the view that owns
/// it, so setting `isLoading` and then `result` would invalidate the whole
/// screen twice for data only part of it reads.
@MainActor
@Observable
final class AnalysisModel {
    private(set) var result: AnalysisResult?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Which sessions the diagnosis band has filtered the table down to, or
    /// empty for all of them. A finding cites its evidence; this is how the
    /// citation is followed.
    var focusedSessions: Set<UUID> = []

    private var loadedRange: AnalysisRange?
    private var loadedAt: Date?

    /// A range load is not free, and the screen is re-entered often — the same
    /// freshness idea as `LiveSheetLoader`, at a longer horizon because a
    /// finished session does not change.
    private static let freshness: TimeInterval = 30

    func load(store: SessionStore, range: AnalysisRange, force: Bool = false) async {
        if !force, result != nil, loadedRange == range,
           let at = loadedAt, Date().timeIntervalSince(at) < Self.freshness { return }

        isLoading = result == nil || loadedRange != range
        defer { isLoading = false }
        do {
            result = try await AnalysisLoader.load(store: store, range: range)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loadedRange = range
        loadedAt = Date()
        focusedSessions = []
    }

    func focus(_ finding: Finding) {
        let ids = Set(finding.sessionIDs)
        focusedSessions = focusedSessions == ids ? [] : ids
    }
}
