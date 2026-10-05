import SwiftUI
import NetlogsCore

/// A stored session, rendered by the same components as the live one.
struct SavedSessionView: View {
    let store: SessionStore
    let session: SessionState
    var onDelete: () -> Void = {}

    @Binding var mode: DetailMode
    @State private var sheet: SessionSheet?
    @State private var detail: SessionDetail?
    @State private var failedToLoad = false

    var body: some View {
        Group {
            if let detail {
                loaded(detail)
            } else if failedToLoad {
                ContentUnavailableView(
                    "Couldn't load this session",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The session may have been deleted.")
                )
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(session.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationSubtitle(Fmt.duration(session.duration))
        .toolbar { toolbarContent }
        .sheet(item: $sheet) { which in
            SessionSheetView(sheet: which, detail: detail, liveDiagnostics: nil)
        }
        .task(id: session.id) { await load() }
    }

    private func loaded(_ detail: SessionDetail) -> some View {
        SessionScaffold(mode: mode) {
            SessionVerdictHeader(
                verdict: detail.verdict,
                reason: SessionVerdict.reason(for: detail.verdict,
                                              summary: detail.stats,
                                              throughput: detail.throughputAverages),
                elapsed: session.duration,
                sampleCount: detail.sampleCount,
                failureCount: detail.stats.failureCount,
                lostCount: detail.stats.noReplyCount,
                lateCount: detail.stats.lateCount,
                underLoadCount: detail.stats.failuresUnderLoad,
                onShowFailures: { sheet = .failures }
            )
        } content: {
            SummaryCards(
                latency: detail.stats,
                routerHost: session.settings.routerHost,
                internetHost: session.settings.internetHost,
                throughput: detail.throughputAverages,
                diagnostics: detail.summary.diagnostics.last,
                traffic: detail.traffic,
                showsGateway: detail.wanTrace.snapshotCount > 0,
                gatewayRadio: detail.lastRadio,
                onSelect: { sheet = $0 }
            )
            // CHART DISABLED:
            // ChartPanel(series: detail.chart,
            //            routerHost: session.settings.routerHost,
            //            internetHost: session.settings.internetHost)
        } log: {
            SamplesTable(
                title: "Ping log",
                rows: detail.tableRows,
                totalCount: detail.sampleCount,
                footnote: "\(detail.sampleCount.formatted()) samples"
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // CHART DISABLED — restore with DetailMode.selectable.
        // ToolbarItem(placement: .principal) {
        //     ModePicker(mode: $mode)
        // }
        // Delete then export, so the export control sits in the corner and
        // the destructive one is not the easiest thing to hit.
        ToolbarItem {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        ToolbarItem { ExportButton(store: store, sessionID: session.id) }
    }

    private func load() async {
        failedToLoad = false
        do {
            detail = try await DetailLoader.load(store: store, sessionID: session.id)
        } catch {
            detail = nil
            failedToLoad = true
        }
    }
}
