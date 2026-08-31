import SwiftUI
import Charts
import NetlogsCore

/// Wi-Fi signal over the session, with a mark where the connection changed and
/// the exact reading on hover.
///
/// This replaces a list of 669 rows reading `-43 dBm · ch 44`. The list held a
/// time series and rendered it as text, so the one thing worth knowing — that
/// the signal fell off at 03:10, when the radio moved to channel 36 — was the
/// one thing it could not show.
///
/// Small on purpose: it sits under the numbers it is the history of, inside a
/// sheet that is 560 pt tall and has an Interface block to fit as well. The
/// marks are split into properties rather than written inline because the whole
/// chart in one expression stopped type-checking in reasonable time.
struct RSSITrace: View {
    let trace: DiagnosticsTrace
    var height: CGFloat = 104

    /// The reading under the pointer, or nil. Written only when it *changes* —
    /// `onContinuousHover` fires far faster than the trace has points, and
    /// every write rebuilds the chart.
    @State private var hovered: DiagnosticsTrace.Point?

    /// Explicit style keys. `series:` makes Charts synthesise a style scale
    /// that silently beats a plain `.foregroundStyle(Color)` and draws
    /// everything default grey — the same trap `PingChart` documents.
    private static let lineKey = "Signal"
    private static let fillKey = "Signal fill"

    var body: some View {
        Chart {
            changeMarks
            weakRule
            areaMarks
            lineMarks
            hoverMarks
        }
        .chartForegroundStyleScale([
            Self.lineKey: Palette.Chart.internet,
            Self.fillKey: Palette.Chart.internet.opacity(Palette.Chart.envelopeOpacity),
        ])
        .chartLegend(.hidden)
        // Pinned, both axes — see `DiagnosticsTrace.yDomain` for why fitting
        // this one to its data would be actively misleading.
        .chartXScale(domain: trace.xDomain)
        .chartYScale(domain: trace.yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                AxisValueLabel {
                    if let dBm = value.as(Double.self) {
                        Text(Fmt.msCoarse(dBm)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xTicks) { _ in
                AxisGridLine().foregroundStyle(.separator.opacity(0.35))
                AxisValueLabel(format: xLabelFormat)
                    .font(.caption2)
            }
        }
        .chartYAxisLabel("dBm", position: .leading)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { update($0, proxy: proxy, frame: frame) }
                }
            }
        }
        // The redraw fix the live chart needed: without it a data swap inside
        // an animating transaction keeps CoreAnimation committing at display
        // rate between ticks.
        .transaction { $0.animation = nil }
        .frame(height: height)
        .accessibilityLabel("Wi-Fi signal over time")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: - Marks

    @ChartContentBuilder
    private var changeMarks: some ChartContent {
        ForEach(trace.radioChanges) { change in
            RuleMark(x: .value("Change", change.time))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    @ChartContentBuilder
    private var weakRule: some ChartContent {
        if trace.yDomain.contains(DiagnosticsTrace.weakRSSI) {
            RuleMark(y: .value("Weak", DiagnosticsTrace.weakRSSI))
                .foregroundStyle(Palette.bad.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                // Trailing, not leading: a session that opens on a weak signal
                // draws its first points exactly where a leading label sits.
                .annotation(position: .top, alignment: .trailing, spacing: 1) {
                    Text("weak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    @ChartContentBuilder
    private var areaMarks: some ChartContent {
        ForEach(trace.points) { point in
            AreaMark(
                x: .value("Time", point.time),
                yStart: .value("Floor", trace.yDomain.lowerBound),
                yEnd: .value("RSSI", point.rssi),
                series: .value("Series", "fill-\(point.segment)")
            )
            .foregroundStyle(by: .value("Signal", Self.fillKey))
        }
    }

    @ChartContentBuilder
    private var lineMarks: some ChartContent {
        ForEach(trace.points) { point in
            LineMark(
                x: .value("Time", point.time),
                y: .value("RSSI", point.rssi),
                series: .value("Series", "line-\(point.segment)")
            )
            .foregroundStyle(by: .value("Signal", Self.lineKey))
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private var hoverMarks: some ChartContent {
        if let hovered {
            RuleMark(x: .value("Hovered", hovered.time))
                .foregroundStyle(.secondary.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1))
            dot(hovered)
        }
    }

    /// Split out because the whole chart in one expression stopped
    /// type-checking, and kept split because the diagnostics here are
    /// misleading: a wrong member name inside `overflowResolution` reports as
    /// "`some Chart3DContent` has no member `annotation`", pointing at the
    /// mark rather than at the argument.
    private func dot(_ point: DiagnosticsTrace.Point) -> some ChartContent {
        PointMark(
            x: .value("Time", point.time),
            y: .value("RSSI", point.rssi)
        )
        .symbolSize(30)
        .foregroundStyle(by: .value("Signal", Self.lineKey))
        // `overflowResolution` is what keeps the readout inside the chart near
        // either end instead of half-drawn past its edge.
        .annotation(
            position: .top,
            spacing: 4,
            overflowResolution: AnnotationOverflowResolution(x: .fit(to: .chart), y: .disabled)
        ) {
            readout(point)
        }
    }

    // MARK: - Axis

    private var xTicks: [Date] { trace.xTicks() }

    /// Seconds only when a tick actually falls on one. A short session gets
    /// ticks every 30 s, where `22:27` printed twice is worse than useless; an
    /// hour-long one gets them on the quarter hour, where seconds are noise.
    private var showsSeconds: Bool {
        xTicks.contains { Calendar.current.component(.second, from: $0) != 0 }
    }

    private var xLabelFormat: Date.FormatStyle {
        showsSeconds ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
    }

    // MARK: - Hover

    /// The exact reading, which is the whole reason to hover: four ticks can
    /// only orient, and a trace decimated to 600 points is read off the line
    /// approximately at best.
    ///
    /// Opaque, not `floatingGlass`. Glass was the obvious choice — it is what
    /// the chart's range picker uses — and it was unreadable: a two-word
    /// number over a material that refracts the trace and the grid behind it,
    /// which is the legibility regression `LiquidGlass.swift` warns about, in
    /// the one place where reading the number is the entire point.
    private func readout(_ point: DiagnosticsTrace.Point) -> some View {
        Text("\(Fmt.msCoarse(point.rssi)) dBm · "
             + point.time.formatted(.dateTime.hour().minute().second()))
            .font(.caption2)
            .monospacedDigit()
            .padding(.horizontal, Space.s)
            .padding(.vertical, 3)
            .background(.background, in: Capsule())
            .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
            .fixedSize()
    }

    private func update(_ phase: HoverPhase, proxy: ChartProxy, frame: CGRect) {
        switch phase {
        case .active(let location):
            guard frame.contains(location),
                  let time: Date = proxy.value(atX: location.x - frame.minX),
                  let point = trace.nearest(to: time)
            else { clear(); return }
            if hovered?.id != point.id { hovered = point }
        case .ended:
            clear()
        }
    }

    private func clear() {
        if hovered != nil { hovered = nil }
    }

    private var accessibilitySummary: String {
        var parts = ["\(trace.readingCount) readings",
                     "low \(Fmt.msCoarse(trace.stats.min)) dBm",
                     "high \(Fmt.msCoarse(trace.stats.max)) dBm"]
        let changes = trace.radioChanges.count
        if changes > 0 { parts.append("\(changes) radio change\(changes == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
