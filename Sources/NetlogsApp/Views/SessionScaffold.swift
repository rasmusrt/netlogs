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

    /// The log's title row plus a few rows: below this the summary scrolls
    /// rather than the log disappearing.
    private static var logMinHeight: CGFloat { 140 }

    var body: some View {
        switch mode {
        case .summary:
            // The summary takes its natural height and the log takes the
            // rest, down to the window's bottom edge — until the window is too
            // short for both. Then the summary scrolls instead of growing.
            //
            // This was a plain `VStack` with `.layoutPriority(1)` on the
            // summary, which cannot give height back: a saved session with all
            // five cards needs more than a 530 pt window has, so the detail
            // column's *minimum* height exceeded the window. `NavigationSplitView`
            // then overflowed and was centred in the window, which moved both
            // columns about 22 pt up under the toolbar — the sidebar's first
            // row under the traffic lights and the verdict header against the
            // navigation title. Shorter sessions fit, which is why it only
            // showed on some logs.
            //
            // A `ScrollView` will not adopt its content's height on its own —
            // not with a `maxHeight`, `ViewThatFits`, `.fixedSize` or a
            // measuring `.background`, all tried before — so the height is
            // decided by `SummaryOverLog`, which measures the stack through an
            // unconstrained proposal and hands the scroll view an exact size.
            SummaryOverLog(logMinHeight: Self.logMinHeight) {
                ScrollView { summaryStack }
                    .scrollBounceBehavior(.basedOnSize)
                    .fadingTopScrollEdge()

                VStack(spacing: 0) {
                    SectionSeparator()
                    log
                }
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

/// The summary over the log: the summary gets its natural height, capped so
/// that the log keeps at least `logMinHeight`; the log gets the rest.
///
/// Always reports exactly the size it is offered, so the detail column's
/// minimum height never depends on how many cards a session has.
private struct SummaryOverLog: Layout {
    let logMinHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let natural = subviews[0]
            .sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        let summary = max(0, min(natural, bounds.height - logMinHeight))
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: summary))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + summary),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width,
                                                     height: bounds.height - summary))
    }
}
