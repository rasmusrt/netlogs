import SwiftUI
import NetlogsCore

enum SidebarItem: Hashable {
    case monitor
    case analysis
    case session(UUID)
}

struct RootView: View {
    let store: SessionStore
    @Bindable var settings: AppSettings

    @State private var selection: Set<SidebarItem> = [.monitor]
    @State private var savedSessions: [SessionState] = []
    @State private var controller: MonitorController
    /// Empty when no confirmation is pending; one or many when it is.
    @State private var pendingDelete: [SessionState] = []

    init(store: SessionStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        _controller = State(initialValue: MonitorController(store: store))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $selection,
                // A recording session is Monitor, which carries the live
                // badge; it joins Logs when it stops. It used to appear in
                // both, but only sometimes — the list is reloaded on stop and
                // at launch, never on start — so the same session showed up
                // twice or not at all depending on what else had happened.
                sessions: savedSessions.filter { $0.id != controller.session?.id },
                runningSessionID: controller.session?.id,
                onDelete: { pendingDelete = $0 }
            )
        } detail: {
            detail
                // One minimum for every branch. `detail` returns three
                // structurally different views, and each was reporting its own
                // intrinsic minimum width, so changing the selection
                // re-resolved the split and the sidebar visibly jumped. Pinned
                // here, the sidebar's width is the user's to set and nothing
                // else moves it.
                //
                // 340 sits just above what the samples table needs (its column
                // minimums sum to ~320) and below the window's own 560pt
                // minimum less the sidebar, so it constrains the split without
                // forcing the window any wider.
                .frame(minWidth: 340, maxWidth: .infinity)
        }
        .task {
            // Reload only once the stop has actually been committed, so a
            // session that was stopped properly never shows as interrupted.
            controller.onSessionStopped = { reload() }
            pruneIfNeeded()
            reload()
            await backfillSummaries()
        }
        // `alert`, not `confirmationDialog`. Both look much the same on macOS,
        // but an alert is the canonical destructive confirmation here and it
        // honours button key equivalents reliably.
        //
        // Return confirms and Escape cancels. Note this deliberately departs
        // from the macOS convention of never making a destructive action the
        // default button — deleting a log is cheap to redo by recording
        // another, and confirming without reaching for the mouse is worth more
        // than the guard rail.
        .alert(
            pendingDelete.count == 1
                ? "Delete this session?"
                : "Delete \(pendingDelete.count) sessions?",
            isPresented: Binding(get: { !pendingDelete.isEmpty },
                                 set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) { deletePending() }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { pendingDelete = [] }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        guard let first = pendingDelete.first else { return "" }
        if pendingDelete.count == 1 {
            return "\(first.startedAt.formatted(date: .abbreviated, time: .shortened))"
                + " · \(Fmt.duration(first.duration)). This can't be undone."
        }
        let total = pendingDelete.reduce(0) { $0 + $1.duration }
        return "\(Fmt.duration(total)) of recording across "
            + "\(pendingDelete.count) sessions. This can't be undone."
    }

    private var selectedSessions: [SessionState] {
        savedSessions.filter { selection.contains(.session($0.id)) }
    }

    @ViewBuilder
    private var detail: some View {
        let sessions = selectedSessions
        if selection.contains(.analysis) {
            AnalysisView(store: store, settings: settings) { id in
                selection = [.session(id)]
            }
        } else if sessions.count > 1 {
            multiSelection(sessions)
        } else if let session = sessions.first {
            // A session row is written at start, so the running session appears
            // in Logs while it records. Selecting it must show the live screen,
            // not a read-only snapshot of a session that is still growing.
            if session.id == controller.session?.id {
                live
            } else {
                SavedSessionView(
                    store: store,
                    session: session,
                    onDelete: { pendingDelete = [session] },
                    mode: $settings.detailMode
                )
            }
        } else {
            live
        }
    }

    private func multiSelection(_ sessions: [SessionState]) -> some View {
        let total = sessions.reduce(0) { $0 + $1.duration }
        return ContentUnavailableView {
            Label("\(sessions.count) sessions selected", systemImage: "checklist")
        } description: {
            Text("\(Fmt.duration(total)) of recording in total.")
        } actions: {
            Button("Delete \(sessions.count) Sessions", role: .destructive) {
                pendingDelete = sessions
            }
        }
    }

    private var live: some View {
        LiveSessionView(
            controller: controller,
            settings: settings.monitor,
            onSessionEnd: reload,
            mode: $settings.detailMode
        )
    }

    private func reload() {
        savedSessions = (try? store.allSessions()) ?? []
    }

    /// Fold any session that has no schema-6 summary — one recorded before the
    /// migration, or force-quit before it reached `stopSession`.
    ///
    /// Off the main actor and after the first `reload`, so the sidebar is on
    /// screen while it runs: over this database's 225,000 samples the whole
    /// pass takes 262 ms, which is once, but it is not nothing. Reload again
    /// only if it actually wrote something.
    private func backfillSummaries() async {
        let store = store
        let running = controller.session?.id
        let wrote = await Task.detached(priority: .utility) {
            (try? store.backfillSummaries(excluding: running)) ?? 0
        }.value
        if wrote > 0 { reload() }
    }

    private func pruneIfNeeded() {
        guard settings.retentionDays > 0 else { return }
        let cutoff = Date(timeIntervalSinceNow: -Double(settings.retentionDays) * 86_400)
        if (try? store.prune(stoppedBefore: cutoff)) ?? 0 > 0 {
            try? store.vacuum()
        }
    }

    private func deletePending() {
        let ids = pendingDelete.map(\.id)
        pendingDelete = []
        for id in ids { try? store.deleteSession(id) }
        selection.subtract(ids.map(SidebarItem.session))
        if selection.isEmpty { selection = [.monitor] }
        reload()
    }
}
