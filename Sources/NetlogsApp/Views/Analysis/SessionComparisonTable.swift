import SwiftUI
import NetlogsCore

/// The evidence the findings cite: one row per session.
///
/// A `LazyVStack` at a fixed row height, not a SwiftUI `Table`. "The live table
/// was the whole bill" and "The hang" both record what a `Table` costs once
/// rows accumulate, and a sortable comparison table is exactly where that
/// mistake would come back.
///
/// Missed pings are split three ways — internet, router, both — because the
/// split *is* the diagnosis. It sits on a quiet second line under the row,
/// only where there is something to say, rather than as a column of 0 / 0 / 0.
struct SessionComparisonTable: View {
    let sessions: [SessionAnalysis]
    var focused: Set<UUID> = []
    var onSelect: ((UUID) -> Void)?

    @State private var width: CGFloat = 0
    @State private var hovered: UUID?

    /// One place for the column widths, so a header cannot drift off the values
    /// under it — and one place to total them, which is what the horizontal
    /// scroll needs to know.
    private enum Column {
        static let started: CGFloat = 120
        static let ran: CGFloat = 64
        static let typical: CGFloat = 64
        static let worst: CGFloat = 72
        static let lost: CGFloat = 44
        static let shape: CGFloat = 80
        static let score: CGFloat = 76

        static let all: [CGFloat] = [started, ran, typical, worst, lost, shape, score]
        /// Narrow windows keep what the diagnosis reads — when, how slow,
        /// what was lost, the score — and drop what only qualifies it.
        static let compact: [CGFloat] = [started, typical, worst, lost, score]

        static func total(_ columns: [CGFloat]) -> CGFloat {
            columns.reduce(0, +) + Space.m * CGFloat(columns.count - 1) + Space.s * 2
        }
    }

    var body: some View {
        // Full table when it fits, the compact one when it does not, and a
        // horizontal scroll only as the last resort. Every column grows from
        // its minimum, so a wide card shares its spare width out evenly.
        //
        // No vertical scroll of its own: the screen already scrolls, and
        // nesting one inside the other makes both feel broken.
        Group {
            if width >= Column.total(Column.all) {
                table(compact: false)
            } else if width >= Column.total(Column.compact) {
                table(compact: true)
            } else {
                ScrollView(.horizontal) {
                    table(compact: true)
                        .frame(width: Column.total(Column.compact))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func table(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            header(compact: compact)
            // Thin rules between rows and a soft highlight under the pointer,
            // like the cards elsewhere — not zebra stripes, which made the
            // table the loudest thing on a calm screen.
            LazyVStack(spacing: 0) {
                ForEach(shown, id: \.id) { analysis in
                    Divider().opacity(0.5)
                    row(analysis, compact: compact)
                }
            }
        }
    }

    private var shown: [SessionAnalysis] {
        focused.isEmpty ? sessions : sessions.filter { focused.contains($0.id) }
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: Space.m) {
            heading("Started", width: Column.started, alignment: .leading)
            if !compact {
                heading("Ran", width: Column.ran)
            }
            heading("Typical", width: Column.typical)
            heading("Worst 5 %", width: Column.worst)
            heading("Lost", width: Column.lost)
            if !compact {
                heading("Shape", width: Column.shape, alignment: .center)
            }
            heading("Score", width: Column.score, alignment: .leading)
        }
        .padding(.horizontal, Space.s)
    }

    private func row(_ analysis: SessionAnalysis, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.m) {
                cell(analysis.session.startedAt
                        .formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                     width: Column.started, alignment: .leading)
                if !compact {
                    cell(Fmt.duration(analysis.aggregate.measuredSpan), width: Column.ran,
                         secondary: true)
                }
                cell("\(Fmt.msCoarse(analysis.latency.p50)) ms", width: Column.typical,
                     tint: Palette.latency(analysis.latency.p50, on: .internet))
                cell("\(Fmt.msCoarse(analysis.latency.p95)) ms", width: Column.worst,
                     tint: Palette.latency(analysis.latency.p95, on: .internet))
                cell(analysis.aggregate.internetNoRepliesIdle.formatted(), width: Column.lost,
                     tint: Palette.loss(analysis.internetLossRatio))
                if !compact {
                    shapeCell(analysis)
                }
                scoreCell(analysis)
            }
            if let note = note(analysis) {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.s)
        .background(hovered == analysis.id ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hovered = analysis.id } else if hovered == analysis.id { hovered = nil }
        }
        .onTapGesture { onSelect?(analysis.id) }
    }

    /// What a row needs said that has no column of its own: where pings went
    /// unanswered, and a session that measured too little of its time.
    ///
    /// "Missed", not "lost": these are *timeouts* — a probe that did not answer
    /// in time — and the split is the diagnosis: internet, router, or both.
    private func note(_ analysis: SessionAnalysis) -> String? {
        var parts: [String] = []
        let missed = [(analysis.internetOnlyTimeouts, "internet"),
                      (analysis.routerOnlyTimeouts, "router"),
                      (analysis.aggregate.bothTimeouts, "both")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }
        if !missed.isEmpty { parts.append("Missed: " + missed.joined(separator: " · ")) }
        // A session that measured 19 % of what it claims is not a short
        // session; it is one with a hole in it.
        if analysis.coverage < Scoring.coverageFloor {
            parts.append("Measured \(Fmt.percent(analysis.coverage)) of the time")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "   ")
    }

    /// The sparkline: did this session change while it ran. Blank where the
    /// summary has not been written yet — unknown, not flat.
    @ViewBuilder
    private func shapeCell(_ analysis: SessionAnalysis) -> some View {
        if let spark = analysis.session.summary?.spark {
            SparklineView(spark: spark,
                          tint: analysis.session.summary.flatMap {
                              Palette.latency($0.p95Ms, on: .internet)
                          })
                .frame(minWidth: Column.shape, maxWidth: .infinity)
        } else {
            Color.clear.frame(minWidth: Column.shape, maxWidth: .infinity, maxHeight: 1)
        }
    }

    @ViewBuilder
    private func scoreCell(_ analysis: SessionAnalysis) -> some View {
        Group {
            switch analysis.score {
            case .scored(let score):
                let tint = AnalysisFigures.scoreTint(score.value)
                Text("\(score.value)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, 1)
                    .background(Palette.fill(tint), in: Capsule())
            case .withheld:
                Text("Too short")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: Column.score, maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ text: String, width: CGFloat,
                         alignment: Alignment = .trailing) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(minWidth: width, maxWidth: .infinity, alignment: alignment)
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment = .trailing,
                      tint: Color? = nil, secondary: Bool = false) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(tint.map { AnyShapeStyle($0.opacity(0.9)) }
                             ?? (secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
            .lineLimit(1)
            .frame(minWidth: width, maxWidth: .infinity, alignment: alignment)
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
