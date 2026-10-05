import SwiftUI
import Charts
import NetlogsCore

/// The Gateway sheet: internet RTT, WAN upload and 5G SINR on one time axis,
/// with one hover line across all three (Phase 14's deliverable).
///
/// Three charts rather than one with three y-axes. The units have nothing in
/// common, and a shared plot area would have to rescale two of them into the
/// third's axis, which is how a chart starts implying correlations by choice of
/// scale. Stacked with a shared x domain, a moment lines up vertically and each
/// series keeps an axis that means something.
///
/// Upload only, not download. On this line upload is the narrow side (~30 of
/// ~665 Mbps) and the side whose capacity moves with the radio; drawn on one
/// axis with download it would be a flat line along the bottom. Download is in
/// the readout.
struct GatewayDetail: View {
    let trace: WANTrace

    @State private var hovered: Date?

    var body: some View {
        if !trace.hasGatewayData {
            ContentUnavailableView(
                "No gateway data",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text(trace.gaps.last?.reason
                                  ?? "Turn on Gateway telemetry in Settings → Diagnostics, "
                                     + "then start a session.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    readout
                    panel("Internet latency", unit: "ms") { rttChart }
                    panel("WAN upload", unit: "Mbps") { uploadChart }
                    panel("5G signal quality (SINR)", unit: "dB") { sinrChart }
                    footnote
                }
                .padding(Space.l)
            }
        }
    }

    // MARK: - Layout

    private func panel(_ title: String, unit: String,
                       @ViewBuilder chart: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold))
                Text(unit).font(.caption2).foregroundStyle(.tertiary)
            }
            chart()
                .frame(height: 96)
        }
    }

    /// The three values under the pointer, or the latest when nothing is
    /// hovered. One line for all three is the point of the sheet.
    private var readout: some View {
        let time = hovered ?? latestTime
        let r = trace.readout(at: time)
        return HStack(spacing: Space.m) {
            Text(time.formatted(.dateTime.hour().minute().second()))
                .foregroundStyle(.secondary)
            value("RTT", r.rttMs.map { Fmt.msCoarse($0) }, "ms")
            value("Up", r.upMbps.map { String(format: "%.1f", $0) }, "Mbps")
            value("Down", r.downMbps.map { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) }, "Mbps")
            value("SINR", r.sinr.map { String(format: "%.1f", $0) }, "dB")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func value(_ label: String, _ value: String?, _ unit: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value ?? "—").fontWeight(.medium)
            if value != nil { Text(unit).foregroundStyle(.tertiary) }
        }
    }

    private var footnote: some View {
        Text("SINR is drawn as steps: the 5G modem reports about every 12 seconds, so a "
             + "value holds until the next report. Upload is measured between gateway "
             + "counter readings about 5 seconds apart. Grey stretches had no gateway data. "
             + "Lines that move together coincide; that alone does not say which caused which.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var latestTime: Date {
        [trace.rtt.last?.time, trace.rates.last?.end, trace.radio.last?.time]
            .compactMap { $0 }.max() ?? trace.xDomain.upperBound
    }

    // MARK: - Charts

    private var rttChart: some View {
        Chart {
            gapMarks
            ForEach(trace.rtt) { p in
                AreaMark(x: .value("Time", p.time),
                         yStart: .value("Median", p.median), yEnd: .value("Max", p.max),
                         series: .value("Series", "env-\(p.segment)"))
                    .foregroundStyle(Palette.Chart.internet.opacity(Palette.Chart.envelopeOpacity))
            }
            ForEach(trace.rtt) { p in
                LineMark(x: .value("Time", p.time), y: .value("RTT", p.median),
                         series: .value("Series", "rtt-\(p.segment)"))
                    .foregroundStyle(Palette.Chart.internet)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            changeMarks
            hoverMark
        }
        .modifier(SharedAxis(trace: trace, hovered: $hovered))
    }

    private var uploadChart: some View {
        Chart {
            gapMarks
            // Each rate is a step over its own interval: two points, start and
            // end, at the same height.
            ForEach(trace.rates) { r in
                AreaMark(x: .value("Time", r.start), y: .value("Up", r.upMbps),
                         series: .value("Series", "up-\(r.segment)"))
                    .foregroundStyle(Palette.Chart.uploadBand.opacity(0.55))
                AreaMark(x: .value("Time", r.end), y: .value("Up", r.upMbps),
                         series: .value("Series", "up-\(r.segment)"))
                    .foregroundStyle(Palette.Chart.uploadBand.opacity(0.55))
            }
            changeMarks
            hoverMark
        }
        .modifier(SharedAxis(trace: trace, hovered: $hovered))
    }

    private var sinrChart: some View {
        Chart {
            gapMarks
            ForEach(trace.radio) { p in
                LineMark(x: .value("Time", p.time), y: .value("SINR", p.sinr),
                         series: .value("Series", "sinr-\(p.segment)"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Palette.good)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            changeMarks
            hoverMark
        }
        .modifier(SharedAxis(trace: trace, hovered: $hovered))
    }

    @ChartContentBuilder
    private var gapMarks: some ChartContent {
        ForEach(trace.gaps) { gap in
            RectangleMark(xStart: .value("From", gap.start), xEnd: .value("To", gap.end))
                .foregroundStyle(.secondary.opacity(0.12))
        }
    }

    @ChartContentBuilder
    private var changeMarks: some ChartContent {
        ForEach(trace.radioChanges) { change in
            RuleMark(x: .value("Change", change.time))
                .foregroundStyle(.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    @ChartContentBuilder
    private var hoverMark: some ChartContent {
        if let hovered {
            RuleMark(x: .value("Hovered", hovered))
                .foregroundStyle(.secondary.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
    }
}

/// The x scale, axis and hover every panel shares. The domain is pinned to the
/// whole trace, so the three panels line up to the second even when one series
/// starts later than the others.
private struct SharedAxis: ViewModifier {
    let trace: WANTrace
    /// Room for "1000" in caption2.
    static let yLabelWidth: CGFloat = 30
    @Binding var hovered: Date?

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: trace.xDomain)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: trace.xTicks()) { _ in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.35))
                    AxisValueLabel(format: .dateTime.hour().minute()).font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                    // A fixed width, or the plot areas are not the same width:
                    // "200" is wider than "40", so the RTT panel's plot started
                    // further right and the shared hover line visibly missed
                    // between panels — the one thing this sheet must not do.
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(v.formatted(.number.precision(.fractionLength(0))))
                                .font(.caption2)
                                .monospacedDigit()
                                .frame(width: Self.yLabelWidth, alignment: .trailing)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plot = proxy.plotFrame {
                        let frame = geometry[plot]
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard frame.contains(location),
                                          let time: Date = proxy.value(atX: location.x - frame.minX)
                                    else { hovered = nil; return }
                                    // Whole seconds: the pointer moves far
                                    // faster than anything here changes, and
                                    // every write redraws three charts.
                                    let second = Date(timeIntervalSince1970:
                                        time.timeIntervalSince1970.rounded())
                                    if hovered != second { hovered = second }
                                case .ended:
                                    hovered = nil
                                }
                            }
                    }
                }
            }
            .transaction { $0.animation = nil }
    }
}
