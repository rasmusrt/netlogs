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

            // Directly under Monitor and outside Logs: it is a screen about
            // the logs rather than one of them. This is what replaced the
            // sidebar-sparkline idea — comparison wants a screen, not a 200 pt
            // row.
            Label("Analysis", systemImage: "chart.bar.xaxis")
                .tag(SidebarItem.analysis)

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
        // Widened by 15pt when the status dot arrived. The old `min: 200` was
        // measured against "a date beside its longest duration, Aug 28 at 23:55
        // … 19m 12s" — and the dot plus its gap is 11pt the row did not have,
        // which showed up immediately as "Aug 30 at 22:33 · 12h…" truncating in
        // the one place a duration is worth reading. Adding a column and not
        // moving these numbers is how a row that used to fit stops fitting.
        .navigationSplitViewColumnWidth(min: 215, ideal: 245, max: 335)
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

    /// Date leading, duration trailing, status dot last — one line.
    ///
    /// The sparkline that used to sit under this is gone. It was good data in
    /// the wrong place: a 200 pt sidebar row is not a chart surface, it cost a
    /// second line on every row, and the question it answered ("did this
    /// session change while it ran") is not the question you ask a *list*. The
    /// question you ask a list is "which of these should I open", and a
    /// 48-bucket trace answers that much worse than a coloured dot does. It
    /// belongs on the Analysis screen's comparison table, which has the width
    /// for it and is already about comparing sessions.
    ///
    /// The dot goes after the duration, not after the date. Durations are flush
    /// right, so a trailing dot sits at a fixed x and the column scans in one
    /// vertical pass; a dot after the date would sit at a ragged x — dates vary
    /// in width — and you would have to read every row to find it, which is the
    /// entire value of a status lamp gone.
    ///
    /// Nothing is drawn for a clean session, so no row reserves space for a dot
    /// it does not have. See `SessionSummary.Status`.
    private func row(_ session: SessionState) -> some View {
        HStack(spacing: Space.xs) {
            date(session)
            Spacer(minLength: Space.xs)
            duration(session)
            StatusDot(summary: session.summary)
        }
        .padding(.vertical, 2)
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

    /// `fixedSize`, so this never truncates.
    ///
    /// It used to, and adding the status dot is what tipped it over: at the
    /// sidebar width this database is actually used at, eight rows came out as
    /// "12h…", "1h 34…", "10h 3…". A duration clipped to "12h…" has lost the
    /// only part worth reading, and it is six characters — there is no version
    /// of this row where truncating it is the right call.
    ///
    /// The date absorbs the pressure instead. It has slack the duration does
    /// not: "Aug 30 at 22:3…" still identifies a session, and in practice the
    /// column is wide enough that neither clips.
    private func duration(_ session: SessionState) -> some View {
        Text(Fmt.duration(session.duration))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }
}


/// A session's verdict at a glance: red for lost packets, orange for a session
/// that was not clean, nothing at all for one that was.
///
/// Absence is the third state on purpose. A green dot on every healthy row is
/// noise that trains the eye to skip the column, which costs exactly the rows
/// that do have a dot; leaving them blank means a dot in this list always means
/// "look at this one".
///
/// Grey when there is no summary yet — a session recorded before schema 6, or
/// one the backfill has not reached. That is "not known", which is neither good
/// news nor bad, and must not be drawn as either.
private struct StatusDot: View {
    let summary: SessionSummary?

    private static let size: CGFloat = 7

    var body: some View {
        Group {
            if let summary {
                switch summary.status() {
                case .lost:     dot(Palette.critical, summary.statusSummary)
                case .degraded: dot(Palette.bad, summary.statusSummary)
                case .clean:    spacer
                }
            } else {
                dot(.secondary.opacity(0.35), "Not summarised yet")
            }
        }
        .frame(width: Self.size)
    }

    /// Keeps the durations from shifting left on clean rows. The dot itself is
    /// absent; the column it lives in is not.
    private var spacer: some View { Color.clear.frame(width: Self.size, height: Self.size) }

    private func dot(_ color: Color, _ help: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: Self.size, height: Self.size)
            .help(help)
            .accessibilityLabel(Text(help))
    }
}
