import SwiftUI
import Charts
import NetlogsCore

/// The hero RTT trace, shared unchanged by the live and saved screens — both
/// hand it a `PingChartSeries`, so there is no mode branch anywhere in here.
///
/// Marks are declared back to front, because Swift Charts z-orders by
/// declaration order:
///
/// 1. Load bands — where a throughput test was running.
/// 2. Outage bands — where a host stopped replying.
/// 3. The min–max envelope and the average line, per host.
///
/// The bands replace what used to be coloured dots on individual points. A
/// throughput test is an *interval*, and drawing it as a property of points was
/// a category error that also made the app's whole thesis — latency climbing
/// under load — nearly invisible.
struct PingChart: View {
    let series: PingChartSeries
    var showsRouter = true
    var height: CGFloat = 240

    /// Series keys do two jobs: they break the line across an outage, and they
    /// name which host a mark belongs to.
    private static let internetKey = "Internet"
    private static let routerKey = "Router"

    var body: some View {
        Chart {
            ForEach(series.load) { run in
                RectangleMark(
                    xStart: .value("Load start", run.start),
                    xEnd: .value("Load end", run.end)
                )
                .foregroundStyle(
                    Palette.Chart.load(run.value).opacity(Palette.Chart.bandOpacity)
                )
            }

            ForEach(series.outages) { run in
                RectangleMark(
                    xStart: .value("Outage start", run.start),
                    xEnd: .value("Outage end", run.end)
                )
                // Kept light on purpose. At full saturation a two-minute
                // outage became a solid block that read as the subject of the
                // chart rather than as an annotation on it.
                .foregroundStyle(
                    Palette.Chart.outage(run.value).opacity(Palette.fillOpacity)
                )
            }

            ForEach(series.internet) { point in
                AreaMark(
                    x: .value("Time", point.time),
                    yStart: .value("Min", point.lo),
                    yEnd: .value("Max", point.hi),
                    series: .value("Series", "envelope-\(point.segment)")
                )
                .foregroundStyle(
                    Palette.Chart.internet.opacity(Palette.Chart.envelopeOpacity)
                )
            }

            if showsRouter {
                ForEach(series.router) { point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("RTT", point.avg),
                        series: .value("Series", "router-\(point.segment)")
                    )
                    .foregroundStyle(by: .value("Host", Self.routerKey))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }

            ForEach(series.internet) { point in
                LineMark(
                    x: .value("Time", point.time),
                    y: .value("RTT", point.avg),
                    series: .value("Series", "internet-\(point.segment)")
                )
                .foregroundStyle(by: .value("Host", Self.internetKey))
                .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            }
        }
        // `series:` is what breaks the line across an outage, but it also makes
        // Charts synthesise a style scale keyed on the series value — which
        // silently beat a plain `.foregroundStyle(Color)` and drew every trace
        // in the default light grey. Styling *by* an explicit host key and
        // pinning the scale here is what actually holds the colours.
        .chartForegroundStyleScale([
            Self.internetKey: Palette.Chart.internet,
            Self.routerKey: Palette.Chart.router,
        ])
        .chartLegend(.hidden)
        // Pinned rather than inferred: an inferred domain jitters on every
        // publish, which re-lays out and re-formats every axis label — often
        // more expensive than the marks themselves.
        .chartXScale(domain: series.xDomain)
        .chartYScale(domain: series.yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                AxisValueLabel {
                    if let ms = value.as(Double.self) {
                        Text(Fmt.msCoarse(ms)).font(.caption2).monospacedDigit()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.separator.opacity(0.35))
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.caption2)
            }
        }
        .chartYAxisLabel("ms", position: .leading)
        // The other half of the redraw fix: without this, a data swap inside an
        // animating transaction keeps CoreAnimation committing at display rate
        // between ticks, for the entire session.
        .transaction { $0.animation = nil }
        .frame(minHeight: height)
        .overlay(alignment: .topLeading) { clippedNotice }
        .accessibilityLabel("Round-trip time over time")
        .accessibilityValue(accessibilitySummary)
    }

    /// A clamped peak has to say so. Without this the trace simply rides the
    /// top of the plot and reads as a plateau.
    @ViewBuilder
    private var clippedNotice: some View {
        if series.clippedCount > 0 {
            Text("\(series.clippedCount) above scale")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.s)
                .padding(.vertical, 3)
                .floatingGlass(in: Capsule())
                .padding(Space.s)
        }
    }

    private var accessibilitySummary: String {
        guard !series.isEmpty else { return "no samples yet" }
        let outages = series.outages.count
        let tests = series.load.count
        var parts: [String] = ["\(series.internet.count) points"]
        if outages > 0 { parts.append("\(outages) outage\(outages == 1 ? "" : "s")") }
        if tests > 0 { parts.append("\(tests) load period\(tests == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

/// The chart plus its legend and range control — what screens actually embed.
struct ChartPanel: View {
    let series: PingChartSeries
    let routerHost: String
    let internetHost: String
    var range: LiveChartModel.Range?
    var onRange: ((LiveChartModel.Range) -> Void)?
    var height: CGFloat = 240

    /// Mirrors `range` so the `Picker` can bind to something writable.
    ///
    /// A `Binding(get:set:)` wrapping `onRange` would be the obvious way, but
    /// `Binding.set` is `@Sendable` and the callback captures the `@MainActor`
    /// controller — annotating around that crashed the 6.3.3 compiler outright.
    /// Local state plus two `onChange`s is duller and works.
    @State private var pickerRange: LiveChartModel.Range = .session

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                legend
                Spacer(minLength: Space.m)
                if range != nil, let onRange {
                    rangePicker(onRange)
                }
            }
            PingChart(series: series, height: height)
        }
        .onAppear { if let range { pickerRange = range } }
        .onChange(of: range) { _, new in if let new { pickerRange = new } }
    }

    private var legend: some View {
        HStack(spacing: Space.m) {
            swatch(Palette.Chart.internet, internetHost, weight: .semibold)
            swatch(Palette.Chart.router, routerHost, weight: .regular)
            if !series.load.isEmpty {
                swatch(Palette.Chart.downloadBand, "download", filled: true)
                swatch(Palette.Chart.uploadBand, "upload", filled: true)
            }
            if !series.outages.isEmpty {
                swatch(Palette.bad, "outage", filled: true)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func swatch(
        _ color: Color,
        _ label: String,
        weight: Font.Weight = .regular,
        filled: Bool = false
    ) -> some View {
        HStack(spacing: Space.xs + 1) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(filled ? color.opacity(0.35) : color)
                .frame(width: filled ? 10 : 12, height: filled ? 10 : 2.5)
            Text(label).fontWeight(weight)
        }
    }

    private func rangePicker(
        _ onRange: @escaping (LiveChartModel.Range) -> Void
    ) -> some View {
        Picker("Range", selection: $pickerRange) {
            ForEach(LiveChartModel.Range.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .onChange(of: pickerRange) { _, new in onRange(new) }
    }
}
