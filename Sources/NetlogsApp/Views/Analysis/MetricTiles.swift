import SwiftUI
import Charts
import NetlogsCore

/// The four figures a session is scored on, one tile each. Clicking a tile
/// switches the session chart to that figure, so the tiles double as its
/// picker and there is one control instead of two.
struct MetricTiles: View {
    /// Newest first, as `RangeAnalysis` keeps them.
    let sessions: [SessionAnalysis]
    @Binding var selection: AnalysisMetric

    var body: some View {
        // Four in a row, or two by two; never three and one. Decided on the
        // width offered, so a long hint no longer forces two by two on a
        // window with room for four.
        CardGrid(minColumnWidth: 200, spacing: Space.s, evenRows: true) {
            ForEach(AnalysisMetric.allCases) { tile($0) }
        }
    }

    private func tile(_ metric: AnalysisMetric) -> some View {
        let value = AnalysisFigures.median(metric, of: sessions)
        let grade = value.map { AnalysisFigures.grade(metric, $0) }
        let formatted = value.map { AnalysisFigures.format(metric, $0) }
        let isSelected = selection == metric
        // Oldest first, so the line reads left to right like the chart.
        let series = sessions.reversed().compactMap { AnalysisFigures.value(metric, of: $0) }

        return Button {
            selection = metric
        } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack {
                    Text(metric.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Space.xs)
                    if let grade {
                        Text(grade.word)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(grade.tint ?? Palette.good)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Palette.fill(grade.tint ?? Palette.good), in: Capsule())
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(formatted?.value ?? "—")
                        .font(.metricValueLarge)
                    if let unit = formatted?.unit {
                        Text(unit)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                sparkline(series, metric: metric, isSelected: isSelected)
                Text(hint(metric, measured: series.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                  lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text("Shows this figure in the chart"))
    }

    @ViewBuilder
    private func sparkline(_ values: [Double], metric: AnalysisMetric,
                           isSelected: Bool) -> some View {
        if values.count >= 2 {
            Chart(Array(values.enumerated()), id: \.offset) { point in
                LineMark(x: .value("Session", point.offset), y: .value("Value", point.element))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .foregroundStyle(isSelected ? Palette.Chart.internet : Color.secondary)
            }
            // From zero, so a change from 0.01 % to 0.02 % loss is a flat
            // line rather than a hill that fills the tile.
            .chartYScale(domain: 0 ... max(values.max() ?? 0, Self.floor(metric)) * 1.15)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: 26)
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 26)
        }
    }

    /// The smallest top a sparkline gets, so noise around a healthy value
    /// stays near the floor.
    private static func floor(_ metric: AnalysisMetric) -> Double {
        switch metric {
        case .latency:     return 50
        case .loss:        return 0.02
        case .jitter:      return 10
        case .bufferbloat: return 60
        }
    }

    private func hint(_ metric: AnalysisMetric, measured: Int) -> String {
        switch metric {
        case .latency:
            return "How fast the internet answers. Typical, across \(measured) sessions."
        case .loss:
            return "Share of pings to the internet that never came back."
        case .jitter:
            return "How much latency wobbles. Matters for calls."
        case .bufferbloat:
            return measured == 0
                ? "No speed tests in this period."
                : "Extra latency while a speed test filled the line, across \(measured) sessions."
        }
    }
}
