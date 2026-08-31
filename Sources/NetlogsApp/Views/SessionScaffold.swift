import SwiftUI

/// What the upper region of a session screen is showing.
///
/// The chart moved behind this toggle after the first build put it on the main
/// screen as the hero. It was the most interesting thing on screen and the
/// hardest to read: spikes and shaded bands answer "what happened at 3am",
/// which is a question you ask deliberately, not one you want dominating the
/// window while you glance at whether the connection is fine.
enum DetailMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case summary = "Summary"
    case chart = "Chart"

    var id: Self { self }

    /// CHART DISABLED — the chart is noisy and not earning its place yet, so
    /// the UI only offers Summary for now. Everything behind it is intact:
    /// `LiveChartModel` still runs, `PingChart`/`ChartPanel` still compile, and
    /// the Core bucketer and run encoders are still tested. To bring it back,
    /// return `allCases` here and un-comment the two blocks marked
    /// CHART DISABLED in LiveSessionView and NetlogsScene.
    static var selectable: [DetailMode] { [.summary] }

    var systemImage: String {
        switch self {
        case .summary: return "square.grid.2x2"
        case .chart:   return "chart.xyaxis.line"
        }
    }
}

/// The shared session layout: header, a switchable upper region, and the log.
///
/// Generic over three `View`s rather than taking a `mode: .live | .saved` enum,
/// and deliberately not a protocol or an existential. That choice is
/// load-bearing: the live screen's data lives in several separate
/// `@Observable` objects specifically so a stat tick doesn't invalidate the
/// ping table and vice versa (plan §8.2). Funnelling them through one
/// `SessionSource` protocol — or one normalized snapshot struct that both modes
/// produce — would collapse Observation's per-object granularity and re-create
/// the exact problem §8.2 exists to prevent, while looking like a tidy-up.
struct SessionScaffold<Header: View, Body_: View, Log: View>: View {
    let mode: DetailMode
    @ViewBuilder let header: Header
    @ViewBuilder let content: Body_
    @ViewBuilder let log: Log

    /// Header + cards, sized to their own content. Shared by the summary and
    /// chart branches.
    private var summaryStack: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header
            content
        }
        .padding(.horizontal, Space.m)
        .padding(.bottom, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        switch mode {
        case .summary:
            // No scroll view, no measuring. `summaryStack` is a plain stack of
            // fixed-height cards, so it reports its own natural height; the
            // log is a greedy `Table` and takes everything left over, down to
            // the window's bottom edge.
            //
            // Every version that put the summary in a `ScrollView` failed,
            // because on this SwiftUI a `ScrollView` will not adopt its
            // content's height — not with a `maxHeight` (it fell back to the
            // cap and left a slab of slack), not with `ViewThatFits` + a
            // layout priority (it took the whole column and centred the cards
            // in it), not with `.fixedSize(vertical:)` (same centring), and
            // not with an off-screen `.background` measurement feeding
            // `.frame(height:)` (the measurement is derived from the layout it
            // feeds, so the loop settled differently per session and the log
            // stopped short for every log but the shortest).
            //
            // `.layoutPriority(1)` makes the stack hand the summary its full
            // natural height first; the log gets the rest. No `maxHeight` on
            // the summary — it reads as "fill up to this" and left a tall band
            // of empty space under the cards on a tall window.
            VStack(spacing: 0) {
                summaryStack
                    .layoutPriority(1)

                SectionSeparator()
                log
            }

        case .chart:
            // The chart genuinely benefits from being dragged taller, so this
            // is the one mode that keeps a split.
            VSplitView {
                ScrollView { summaryStack }
                .fadingTopScrollEdge()
                .frame(minHeight: 220, idealHeight: 380)

                log
                    .frame(minHeight: 110, idealHeight: 200)
            }
        }
    }
}

/// The rule between the summary and the log.
///
/// A plain `Divider()` uses the full-strength separator colour, which reads as
/// a hard line in dark mode where it sits against a near-black background —
/// far more prominent than the same divider looks in light. This is the same
/// colour at a weight that matches in both appearances.
struct SectionSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .opacity(0.5)
            .frame(height: 1)
    }
}

/// Full-bleed banner for a session-level error.
struct ErrorBanner: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.critical)
            VStack(alignment: .leading, spacing: 2) {
                Text("Monitoring stopped").font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Space.m)
            Button("Retry", action: onRetry)
                .controlSize(.small)
        }
        .padding(Space.m)
        .background(Palette.fill(Palette.critical),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Palette.critical.opacity(0.3), lineWidth: 1)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
