import SwiftUI
import NetlogsCore

/// The evidence the findings cite: one row per session.
///
/// A `LazyVStack` at a fixed row height, not a SwiftUI `Table`. "The live table
/// was the whole bill" and "The hang" both record what a `Table` costs once
/// rows accumulate, and a sortable comparison table is exactly where that
/// mistake would come back.
///
/// Loss is split three ways — internet, router, both — because the split *is*
/// the diagnosis. A single loss column would hide the one distinction this app
/// exists to draw.
struct SessionComparisonTable: View {
    let sessions: [SessionAnalysis]
    var focused: Set<UUID> = []
    var onSelect: ((UUID) -> Void)?

    private static let rowHeight: CGFloat = 26

    /// One place for the column widths, so a header cannot drift off the values
    /// under it — and one place to total them, which is what the horizontal
    /// scroll needs to know.
    private enum Column {
        static let started: CGFloat = 116
        static let ran: CGFloat = 62
        static let covered: CGFloat = 62
        static let samples: CGFloat = 66
        static let p50: CGFloat = 52
        static let p95: CGFloat = 52
        static let lost: CGFloat = 48
        static let missed: CGFloat = 120
        static let shape: CGFloat = 72
        static let score: CGFloat = 130

        static let all: [CGFloat] = [started, ran, covered, samples, p50, p95,
                                     lost, missed, shape, score]
        static var total: CGFloat {
            all.reduce(0, +) + Space.s * CGFloat(all.count - 1)
        }
    }

    var body: some View {
        // Horizontal scroll, rather than a wider detail column. Eight columns
        // need about 730 pt and the window's minimum is 620, so at a narrow
        // width the Score column was simply clipped off the right edge. Raising
        // the detail column's own minimum is what `RootView` records as having
        // made the sidebar jump.
        //
        // No vertical scroll of its own: the screen already scrolls, and
        // nesting one inside the other makes both feel broken.
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: Space.s) {
                header
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, analysis in
                        row(analysis, striped: index.isMultiple(of: 2))
                    }
                }
            }
            .frame(width: Column.total, alignment: .leading)
        }
    }

    private var shown: [SessionAnalysis] {
        focused.isEmpty ? sessions : sessions.filter { focused.contains($0.id) }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            cell("Started", width: Column.started, alignment: .leading)
            cell("Ran", width: Column.ran)
            cell("Covered", width: Column.covered)
            cell("Samples", width: Column.samples)
            cell("p50", width: Column.p50)
            cell("p95", width: Column.p95)
            cell("Lost", width: Column.lost)
            // "Missed", not "Loss". These three are *timeouts* — a probe that
            // did not answer in time — and after schema 7 that is no longer the
            // same thing as a dropped packet. The Lost column beside it is the
            // one that means what the old header claimed.
            cell("Missed int/rtr/both", width: Column.missed)
            cell("Shape", width: Column.shape)
            cell("Score", width: Column.score, alignment: .leading)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func row(_ analysis: SessionAnalysis, striped: Bool) -> some View {
        HStack(spacing: Space.s) {
            cell(analysis.session.startedAt
                    .formatted(.dateTime.month().day().hour().minute()),
                 width: Column.started, alignment: .leading)
            cell(Fmt.duration(analysis.aggregate.measuredSpan), width: Column.ran)
            cell(coverage(analysis), width: Column.covered, tint: coverageTint(analysis))
            cell(analysis.aggregate.totalSamples.formatted(), width: Column.samples)
            cell(Fmt.msCoarse(analysis.latency.p50), width: Column.p50,
                 tint: Palette.latency(analysis.latency.p50, on: .internet))
            cell(Fmt.msCoarse(analysis.latency.p95), width: Column.p95,
                 tint: Palette.latency(analysis.latency.p95, on: .internet))
            cell(analysis.aggregate.internetNoRepliesIdle.formatted(), width: Column.lost,
                 tint: Palette.loss(analysis.internetLossRatio))
            cell(lossSplit(analysis), width: Column.missed)
            shapeCell(analysis)
            scoreCell(analysis)
        }
        .frame(height: Self.rowHeight)
        .background(striped ? Palette.rowStripe : AnyShapeStyle(.clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect?(analysis.id) }
    }

    /// The sparkline, moved here from the sidebar row.
    ///
    /// This is where it was always going to end up. A list answers "which of
    /// these should I open", which a dot does better; a comparison table
    /// answers "how did these differ", which is exactly what a shape is for —
    /// and this screen has the width to draw one at a size worth reading.
    ///
    /// Blank where the summary has not been written yet, rather than a zero
    /// line: an unsummarised session is unknown, not flat.
    @ViewBuilder
    private func shapeCell(_ analysis: SessionAnalysis) -> some View {
        if let spark = analysis.session.summary?.spark {
            SparklineView(spark: spark,
                          tint: analysis.session.summary.flatMap {
                              Palette.latency($0.p95Ms, on: .internet)
                          })
                .frame(width: Column.shape)
        } else {
            Color.clear.frame(width: Column.shape, height: 1)
        }
    }

    /// Three counts in one column, in the order the diagnosis reads them.
    private func lossSplit(_ analysis: SessionAnalysis) -> String {
        "\(analysis.internetOnlyTimeouts) / \(analysis.routerOnlyTimeouts) / "
            + "\(analysis.aggregate.bothTimeouts)"
    }

    private func coverage(_ analysis: SessionAnalysis) -> String {
        Fmt.percent(analysis.coverage)
    }

    /// A session that measured 19% of what it claims is not a short session —
    /// it is a session with a hole in it, and ranking it beside the others
    /// without saying so would be the omission the coverage column exists for.
    private func coverageTint(_ analysis: SessionAnalysis) -> Color? {
        analysis.coverage < Scoring.coverageFloor ? Palette.bad : nil
    }

    @ViewBuilder
    private func scoreCell(_ analysis: SessionAnalysis) -> some View {
        switch analysis.score {
        case .scored(let score):
            HStack(spacing: Space.xs) {
                Text("\(score.value)")
                    .font(.tabularSmall)
                    .foregroundStyle(Palette.score(score) ?? .primary)
                Text(score.constraint.map { $0.kind.rawValue } ?? "—")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !score.isComplete {
                    Text("(\(score.components.count)/4)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Column.score, alignment: .leading)
        case .withheld:
            Text("withheld")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: Column.score, alignment: .leading)
        }
    }

    private func cell(_ text: String, width: CGFloat,
                      alignment: Alignment = .trailing, tint: Color? = nil) -> some View {
        Text(text)
            .font(.tabularSmall)
            .foregroundStyle(tint ?? .primary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
    }
}

/// A session's latency at thumbnail size./// A session's latency at thumbnail size.
///
/// Scaled to its *own* range, not to a shared one. A common scale would make
/// every line but the worst session's a flat streak along the bottom, and the
/// question this answers is "did this session change while it ran", which is a
/// question about one session's shape.
///
/// Untinted unless the session's p95 earns a tint on its own ramp — the same
/// rule the tables follow, so a coloured line in the list means the same thing
/// a coloured figure does inside it.
private struct SparklineView: View {
    let spark: Sparkline
    var tint: Color?

    private static let height: CGFloat = 11

    var body: some View {
        Canvas { context, size in
            guard let range = spark.range else { return }
            // A flat session has no range to divide by. Draw it down the
            // middle rather than at the floor, which would read as "fast".
            let span = range.upperBound - range.lowerBound
            let step = spark.values.count > 1
                ? size.width / CGFloat(spark.values.count - 1) : 0

            func point(_ index: Int, _ value: Double) -> CGPoint {
                let t = span > 0 ? (value - range.lowerBound) / span : 0.5
                return CGPoint(x: CGFloat(index) * step,
                               y: size.height - CGFloat(t) * size.height)
            }

            // One subpath per unbroken run: a bucket with no replies is a gap
            // in the line, and joining across it would draw a measurement that
            // was never taken.
            var path = Path()
            var pen: CGPoint?
            for (index, value) in spark.values.enumerated() {
                guard let value else { pen = nil; continue }
                let next = point(index, value)
                if pen == nil { path.move(to: next) } else { path.addLine(to: next) }
                pen = next
            }
            context.stroke(path, with: .color(tint ?? .secondary),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .opacity(tint == nil ? 0.55 : 0.9)
        .accessibilityHidden(true)
    }
}
