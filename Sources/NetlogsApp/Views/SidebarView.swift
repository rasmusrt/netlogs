import SwiftUI
import NetlogsCore

struct SidebarView: View {
    /// A `Set`, so several logs can be selected and deleted at once.
    @Binding var selection: Set<SidebarItem>
    let sessions: [SessionState]
    /// The session currently being recorded, if any. It is filtered out of
    /// `sessions` by the caller — a recording session is Monitor, not a log —
    /// so this is only used to badge the Monitor row.
    let runningSessionID: UUID?
    var onDelete: ([SessionState]) -> Void = { _ in }

    var body: some View {
        List(selection: $selection) {
            // The live badge lives here rather than on the session header, so
            // that a running session stays visible while you are reading a
            // different log — the header is only on screen when Monitor is
            // selected, which is exactly when you least need telling.
            HStack(spacing: Space.s) {
                Label("Monitor", systemImage: "waveform.path.ecg")
                if runningSessionID != nil {
                    Spacer(minLength: Space.xs)
                    StatusBadge(text: "Live", color: Palette.good, size: .small)
                        .fixedSize()
                }
            }
            .tag(SidebarItem.monitor)

            Section("Logs") {
                if sessions.isEmpty {
                    Text("No saved sessions")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(sessions) { session in
                    row(session)
                        .tag(SidebarItem.session(session.id))
                        .contextMenu {
                            let targets = deleteTargets(rightClicked: session)
                            Button(
                                targets.count == 1
                                    ? "Delete Session"
                                    : "Delete \(targets.count) Sessions",
                                role: .destructive
                            ) { onDelete(targets) }
                        }
                }
            }
        }
        // Explicit, though the split view usually infers it. Sidebar style is
        // what gives rows the inset rounded selection and the accent tint when
        // the list has focus; without it a plain list selection reads as a flat
        // grey block that looks disabled.
        .listStyle(.sidebar)
        .navigationTitle("Netlogs")
        // Resizable, because a Mac sidebar is: Finder, Mail and Xcode all let
        // you drag one within a range and remember where you left it. A single
        // fixed value pins the divider outright — you can still collapse the
        // column, but not resize it, which is the one sidebar behaviour every
        // other app has.
        //
        // The range was removed once because selecting a different log made the
        // sidebar jump. That was not the range's fault: `detail` in RootView
        // returns three structurally different views (live, saved,
        // multi-selection), each reporting its own intrinsic minimum, so the
        // split re-resolved on every selection change. That is now pinned at
        // the detail column instead, which is where it belongs.
        //
        // `max` is not optional. Without it the sidebar absorbs width every
        // time the window grows and never gives it back — drag a window edge
        // around for a few seconds and it settles past 340pt — and AppKit
        // persists the split position, so the bad width survives a relaunch.
        //
        // `min` is 200, not lower: below that the one-line row (a date beside
        // its longest duration, "Aug 28 at 23:55 … 19m 12s") starts to
        // truncate, and a row that clips at both ends is worse than a column
        // that stops narrowing.
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        .onDeleteCommand {
            let targets = selectedSessions
            if !targets.isEmpty { onDelete(targets) }
        }
    }

    private var selectedSessions: [SessionState] {
        sessions.filter { selection.contains(.session($0.id)) }
    }

    /// Right-clicking inside a multi-selection acts on the whole selection;
    /// right-clicking outside it acts on just that row, which is what Finder
    /// does and what avoids deleting things you had forgotten were selected.
    private func deleteTargets(rightClicked session: SessionState) -> [SessionState] {
        let selected = selectedSessions
        return selected.contains(where: { $0.id == session.id }) ? selected : [session]
    }

    /// Date leading, duration trailing — so the column of durations scans on
    /// its own and the long overnight run is easy to find. The column width is
    /// now fixed (see `navigationSplitViewColumnWidth` above), so this single
    /// one-line layout always has the room it needs; the earlier two-line
    /// fallback existed only for a sidebar that could be squeezed narrow.
    ///
    /// A sparkline per row was considered and cut: it would mean reading and
    /// downsampling every session's samples on every sidebar render — fifty
    /// sessions at an hour each is 180,000 rows — or a schema migration to
    /// denormalize a summary onto the session row. See PUBLISHING.md.
    private func row(_ session: SessionState) -> some View {
        HStack(spacing: Space.s) {
            date(session)
            Spacer(minLength: Space.xs)
            duration(session)
        }
        .padding(.vertical, 1)
    }

    /// Only a live dot. There used to be an amber warning on any session whose
    /// `stopped_at` was never written — but stopped, quit, or force-quit, the
    /// samples are on disk and the results are the same, so it flagged a
    /// distinction with no consequence for the reader. The one place it *did*
    /// have a consequence was retention, and that is fixed in
    /// `SessionStore.prune` rather than papered over with a badge.
    @ViewBuilder
    private func date(_ session: SessionState) -> some View {
        Text(session.startedAt, format: .dateTime.month().day().hour().minute())
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    private func duration(_ session: SessionState) -> some View {
        Text(Fmt.duration(session.duration))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
    }
}
