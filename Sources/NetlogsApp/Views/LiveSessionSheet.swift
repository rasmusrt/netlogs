import SwiftUI
import Observation
import NetlogsCore

/// Holds the loaded history for whichever sheet is open.
///
/// An `@Observable` object rather than `@State` on the live screen, because
/// `@State` writes re-render the view that owns them: setting `isLoading` and
/// then `detail` invalidated the entire live screen — cards, log table and all —
/// twice per sheet open, for data only the sheet reads (plan §8.2).
@MainActor
@Observable
final class LiveSheetLoader {
    private(set) var detail: SessionDetail?
    private(set) var isLoading = false

    private var loadedSession: UUID?
    private var loadedAt: Date?

    /// How long a load stays good enough to reuse. Reopening a sheet seconds
    /// after closing it re-read and re-reduced the whole session for data that
    /// had advanced by a row or two.
    private static let freshness: TimeInterval = 5

    /// Only the latency sheet needs stored history; every other sheet is served
    /// from memory, so opening one during a running session never touches the
    /// full table.
    ///
    /// Speed used to be loaded here too. It does not need to be — the
    /// controller holds every result of the running session — and reading it
    /// from disk meant a full session read and reduce to show rows that were
    /// already in memory, with the newest one possibly not flushed yet.
    func load(sheet: SessionSheet, store: SessionStore, sessionID: UUID) async {
        guard sheet == .latency else { return }
        if detail != nil, loadedSession == sessionID,
           let at = loadedAt, Date().timeIntervalSince(at) < Self.freshness { return }

        isLoading = detail == nil
        defer { isLoading = false }
        detail = try? await DetailLoader.load(store: store, sessionID: sessionID)
        loadedSession = sessionID
        loadedAt = Date()
    }
}

/// The live screen's sheet, and the only thing that observes the values it
/// shows.
///
/// Its whole reason to exist is that boundary. Reading `controller.diagnostics`,
/// `controller.failures` and the loaded detail inside the presenting view's
/// `.sheet` closure made those reads dependencies of the *live screen's* body,
/// so a sheet was rebuilt on every 1 Hz tick and on every write from its own
/// load. Here they belong to this view alone.
struct LiveSessionSheet: View {
    let sheet: SessionSheet
    let controller: MonitorController
    let loader: LiveSheetLoader

    var body: some View {
        SessionSheetView(
            sheet: sheet,
            detail: loader.detail,
            liveDiagnostics: controller.diagnostics.latest,
            liveTrace: controller.diagnostics.trace,
            liveFailures: controller.failures.newestFirst,
            liveFailureTotal: controller.failures.total,
            liveThroughput: controller.throughput.results,
            liveAverages: controller.throughput.averages,
            isLoading: loader.isLoading
        )
        .task(id: controller.session?.id) {
            guard let id = controller.session?.id else { return }
            await loader.load(sheet: sheet, store: controller.store, sessionID: id)
        }
    }
}
