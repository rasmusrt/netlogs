import SwiftUI
import Charts
import NetlogsCore

/// One bar per session, placed where and as long as it ran, for whichever
/// figure the tiles picked. Hover reads one session out; a click opens it.
///
/// Latency, loss and jitter are drawn per hour of measuring instead. A session
/// summed up as one number drew an eight-hour recording as a flat block,
/// hiding exactly the evening it got slow. Latency hours come from the same
/// per-hour histograms as the Time of day heatmap, loss and jitter from
/// `SessionStore.hourlyPingStats`. Lag under load stays per session: it only
/// exists where a speed test ran.
///
/// Replaces the p50→p95 band that floated off the axis. A bar that starts at
/// zero reads at a glance — solid is the typical figure, the lighter cap is how
/// high it peaked — and the hover readout says the same thing in words.
///
/// **Nothing is drawn between sessions.** Sessions do not tile time, and the
/// gaps are the honest part of this chart.
struct SessionBarsChart: View {
    /// Newest first.
    let sessions: [SessionAnalysis]
    let interval: DateInterval
    let metric: AnalysisMetric
    /// Sessions to keep at full strength while a finding is hovered; empty
    /// means all of them.
    var highlighted: Set<UUID> = []
    /// Per-hour histograms, for latency.
    var hourly: [HourlyBucket] = []
    /// Per-hour loss and jitter.
    var hourlyStats: [HourlyPingStats] = []
    var onSelect: ((UUID) -> Void)?

    @State private var hovered: String?

    private struct Bar: Identifiable {
        /// The session's id, or day and hour for an hourly bar.
        let id: String
        /// The session a click opens: for an hour, the one with the most
        /// samples in it.
        let session: UUID
        /// Every session in the bar, for highlighting from a finding.
        let sessions: Set<UUID>
        let start: Date
        let end: Date
        let lower: Double
        let upper: Double
        let isWithheld: Bool
        /// Set on an hourly bar.
        var hour: Date?
    }

    private var isHourly: Bool {
        switch metric {
        case .latency:        return !hourly.isEmpty
        case .loss, .jitter:  return !hourlyStats.isEmpty
        case .bufferbloat:    return false
        }
    }

    var body: some View {
        let bars = self.bars
        VStack(alignment: .leading, spacing: Space.s) {
            header
            legend
            Chart {
                barMarks(bars)
                referenceMark
            }
            .chartXScale(domain: interval.start ... max(interval.end, bars.map(\.end).max() ?? interval.end))
            .chartPlotStyle { $0.clipped() }
            .chartYScale(domain: 0 ... yMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(AnalysisFigures.axisLabel(metric, v))
                                .font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.3))
                    // A label this close to the right edge is cut off by it
                    // and shows as "…", so it is left off.
                    if let date = value.as(Date.self),
                       interval.end.timeIntervalSince(date) > interval.duration * 0.04 {
                        AxisValueLabel(format: xLabelFormat).font(.caption2)
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
                                case .active(let point):
                                    let id = bar(at: point.x - frame.minX, proxy: proxy, bars: bars)?.id
                                    if id != hovered { hovered = id }
                                case .ended:
                                    if hovered != nil { hovered = nil }
                                }
                            }
                            .onTapGesture {
                                if let bar = bars.first(where: { $0.id == hovered }) {
                                    onSelect?(bar.session)
                                }
                            }
                    }
                }
            }
            // The same redraw fix every chart here carries: no animation on
            // a data swap, or CoreAnimation keeps committing between hovers.
            .transaction { $0.animation = nil }
            .frame(height: 220)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text("\(bars.count) \(isHourly ? "hours" : "sessions")"))

            Text(isHourly
                 ? "Each bar is one hour of measuring. Hours with nothing recorded stay empty; "
                   + "the chart never fills them in."
                 : "Each bar is one recording. Gaps are times nothing was recorded; "
                   + "the chart never fills them in.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - Marks

    // Split out of `body`: the whole chart in one expression is what stopped
    // `RSSITrace` type-checking in reasonable time.
    @ChartContentBuilder
    private func barMarks(_ bars: [Bar]) -> some ChartContent {
        ForEach(bars) { bar in
            RectangleMark(
                xStart: .value("From", bar.start),
                xEnd: .value("To", bar.end),
                yStart: .value("Base", 0),
                yEnd: .value("Lower", max(bar.lower, yMax * 0.012))
            )
            .foregroundStyle(lowerColor(bar))
            .opacity(opacity(bar))
            if bar.upper > bar.lower {
                RectangleMark(
                    xStart: .value("From", bar.start),
                    xEnd: .value("To", bar.end),
                    yStart: .value("Lower", bar.lower),
                    yEnd: .value("Upper", bar.upper)
                )
                .foregroundStyle(upperColor(bar))
                .opacity(opacity(bar))
            }
        }
    }

    @ChartContentBuilder
    private var referenceMark: some ChartContent {
        if let reference {
            RuleMark(y: .value("Reference", reference.value))
                .foregroundStyle(Color.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                // Leading, not trailing: the newest sessions sit at the right
                // edge and the label was drawn over them. The backing keeps it
                // readable where a bar still reaches the line.
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text(reference.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
        }
    }

    // MARK: - Header and readout

    private var title: String {
        isHourly ? "\(metric.title), hour by hour" : "\(metric.title), session by session"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: Space.s)
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(hovered == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let guide {
                Text(guide)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One line on how to read the chart.
    private var guide: String? {
        switch metric {
        case .bufferbloat:
            return "Only measured during speed tests, so one bar per recording."
        case _ where !isHourly:
            return nil
        case .latency:
            return "Low, even bars are good. Tall peaks are hours where the connection stuttered."
        case .loss:
            return "Flat is good. A bar is an hour where pings went missing."
        case .jitter:
            return "Low, even bars are good. Tall bars are hours where the delay wobbled, which makes calls choppy."
        }
    }

    private var readout: String {
        guard let hovered, let bar = bars.first(where: { $0.id == hovered }),
              let analysis = sessions.first(where: { $0.id == bar.session }) else {
            return "Hover a bar to read it, click to open it"
        }
        if let hour = bar.hour {
            let day = hour.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let time = hour.formatted(.dateTime.hour().minute())
            let figures: String
            switch metric {
            case .loss:
                figures = "lost at home \(Fmt.percent(bar.lower))"
                    + " · beyond the router \(Fmt.percent(bar.upper - bar.lower))"
            case .jitter:
                figures = "jitter \(Fmt.ms(bar.lower)) ms"
            default:
                figures = "typical \(Fmt.msCoarse(bar.lower)) ms · worst 5 % \(Fmt.msCoarse(bar.upper)) ms"
            }
            return "\(day), \(time) · \(figures) · \(AnalysisFigures.sessionTime(analysis))"
        }
        var parts = [AnalysisFigures.sessionTime(analysis)]
        if analysis.latency.count > 0 {
            parts.append("typical \(Fmt.msCoarse(analysis.latency.p50)) ms")
            parts.append("peaks \(Fmt.msCoarse(analysis.latency.p95)) ms")
        }
        parts.append("lost \(Fmt.percent(analysis.internetLossRatio))")
        if let bloat = analysis.medianBufferbloatMs {
            parts.append("under load +\(Fmt.msCoarse(bloat)) ms")
        }
        if let score = analysis.score.score?.value {
            parts.append("score \(score)")
        } else {
            parts.append("not scored")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var legend: some View {
        HStack(spacing: Space.l) {
            switch metric {
            case .latency:
                swatch(Palette.Chart.internet, "Typical ping")
                swatch(Palette.Chart.internet.opacity(0.3), "Worst 5 %")
            case .loss:
                swatch(Palette.warn, "Lost at home (Wi-Fi and router)")
                swatch(Palette.Chart.internet, "Lost beyond the router")
            case .jitter:
                swatch(Palette.Chart.internet, "Jitter")
            case .bufferbloat:
                swatch(Palette.Chart.internet, "Lag under load")
                swatch(Color.secondary.opacity(0.3), "No speed test")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: Space.xs) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    // MARK: - Data

    private var bars: [Bar] {
        isHourly ? hourBars : sessionBars
    }

    /// One bar per day and hour, every shown session's samples in that hour
    /// merged. Hours without samples have no row, so they stay empty.
    private var hourBars: [Bar] {
        let shown = Set(sessions.map(\.id))
        let withheld = Set(sessions.filter { $0.score.score == nil }.map(\.id))

        /// One hour's figures: (lower, upper, samples per session).
        typealias Hour = (lower: Double, upper: Double, weights: [UUID: Int])
        var hours: [HourSlot: Hour] = [:]
        switch metric {
        case .latency:
            let groups = Dictionary(grouping: hourly.filter { shown.contains($0.key.sessionID) },
                                    by: { HourSlot($0.key) })
            for (slot, buckets) in groups {
                let histogram = LatencyHistogram.merging(buckets.map(\.histogram))
                guard histogram.count > 0 else { continue }
                hours[slot] = (histogram.p50, histogram.p95, weights(buckets.map {
                    ($0.key.sessionID, $0.histogram.count) }))
            }
        case .loss, .jitter:
            let groups = Dictionary(grouping: hourlyStats.filter { shown.contains($0.key.sessionID) },
                                    by: { HourSlot($0.key) })
            for (slot, rows) in groups {
                let samples = rows.map(\.samples).reduce(0, +)
                guard samples > 0 else { continue }
                let weight = weights(rows.map { ($0.key.sessionID, $0.samples) })
                if metric == .loss {
                    let home = Double(rows.map(\.routerLost).reduce(0, +)) / Double(samples)
                    let beyond = Double(rows.map(\.internetOnlyLost).reduce(0, +)) / Double(samples)
                    hours[slot] = (home, home + beyond, weight)
                } else {
                    let pairs = rows.map(\.jitterPairs).reduce(0, +)
                    // Too few pairs to call it a figure: a handful of pings
                    // at the edge of a session.
                    guard pairs >= 10 else { continue }
                    let jitter = rows.map(\.jitterSum).reduce(0, +) / Double(pairs)
                    hours[slot] = (jitter, jitter, weight)
                }
            }
        case .bufferbloat:
            return []
        }

        let calendar = Calendar.current
        let parser = DateFormatter()
        parser.calendar = calendar
        parser.timeZone = .current
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        // Thin enough to keep neighbouring hours apart, never so thin that a
        // bar on a thirty-day axis disappears.
        let inset = min(240, interval.duration / 2400)

        return hours.compactMap { slot, hour -> Bar? in
            guard let day = parser.date(from: slot.day),
                  let start = calendar.date(byAdding: .hour, value: slot.hour, to: day),
                  let main = hour.weights.max(by: { $0.value < $1.value })?.key
            else { return nil }
            let ids = Set(hour.weights.keys)
            return Bar(id: "\(slot.day) \(slot.hour)", session: main, sessions: ids,
                       start: start.addingTimeInterval(inset),
                       end: start.addingTimeInterval(3600 - inset),
                       lower: hour.lower, upper: hour.upper,
                       isWithheld: ids.isSubset(of: withheld), hour: start)
        }
        .sorted { $0.start < $1.start }
    }

    private struct HourSlot: Hashable {
        let day: String
        let hour: Int
        init(_ key: HourKey) { day = key.day; hour = key.hour }
    }

    private func weights(_ pairs: [(UUID, Int)]) -> [UUID: Int] {
        Dictionary(pairs, uniquingKeysWith: +)
    }

    private var sessionBars: [Bar] {
        // A fifteen-minute session on a thirty-day axis would otherwise be a
        // zero-width rectangle that draws nothing.
        let minimumWidth = interval.duration / 240
        return sessions.compactMap { analysis in
            guard let start = analysis.aggregate.firstSampleAt,
                  let end = analysis.aggregate.lastSampleAt else { return nil }
            let drawnEnd = max(end, start.addingTimeInterval(minimumWidth))
            if let parts = AnalysisFigures.bar(metric, of: analysis) {
                return Bar(id: analysis.id.uuidString, session: analysis.id, sessions: [analysis.id],
                           start: start, end: drawnEnd,
                           lower: parts.lower, upper: parts.upper,
                           isWithheld: analysis.score.score == nil)
            }
            // Not measured for this figure: a stub on the baseline, never a
            // zero-height bar that reads as "perfect".
            return Bar(id: analysis.id.uuidString, session: analysis.id, sessions: [analysis.id],
                       start: start, end: drawnEnd,
                       lower: -1, upper: -1, isWithheld: true)
        }
    }

    private var reference: (value: Double, label: String)? {
        switch metric {
        case .latency:
            guard let typical = AnalysisFigures.median(.latency, of: sessions) else { return nil }
            return (typical, "typical \(Fmt.msCoarse(typical)) ms")
        case .jitter:
            guard let typical = AnalysisFigures.median(.jitter, of: sessions) else { return nil }
            return (typical, "typical \(Fmt.ms(typical)) ms")
        case .bufferbloat:
            return (30, "noticeable above 30 ms")
        case .loss:
            return nil
        }
    }

    private var yMax: Double {
        let tops = isHourly ? hourBars.map(\.upper)
            : sessions.compactMap { AnalysisFigures.bar(metric, of: $0)?.upper }
        let top = max(tops.max() ?? 0, (reference?.value ?? 0) * 1.25)
        switch metric {
        case .loss:
            return niceCeiling(max(top * 1.1, 0.01))
        case .latency:
            // Fitted to the data, but never so tight that a calm 15 ms line
            // fills the chart and looks like trouble.
            return niceCeiling(max(top * 1.1, 25))
        default:
            return niceCeiling(max(top * 1.1, 10))
        }
    }

    private func niceCeiling(_ value: Double) -> Double {
        let magnitude = pow(10, floor(log10(value)))
        let fraction = value / magnitude
        let step: Double = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 2.5 ? 2.5
            : fraction <= 5 ? 5 : 10
        return step * magnitude
    }

    private var xLabelFormat: Date.FormatStyle {
        interval.duration > 36 * 3600
            ? .dateTime.weekday(.abbreviated).day()
            : .dateTime.hour().minute()
    }

    private func bar(at x: CGFloat, proxy: ChartProxy, bars: [Bar]) -> Bar? {
        guard let date: Date = proxy.value(atX: x) else { return nil }
        if let inside = bars.first(where: { $0.start <= date && date <= $0.end }) {
            return inside
        }
        // Thin bars are hard to land on: take the nearest within a few points.
        let tolerance = interval.duration / 120
        return bars
            .map { (bar: $0, distance: min(abs($0.start.timeIntervalSince(date)),
                                            abs($0.end.timeIntervalSince(date)))) }
            .filter { $0.distance <= tolerance }
            .min { $0.distance < $1.distance }?
            .bar
    }

    // MARK: - Style

    private func opacity(_ bar: Bar) -> Double {
        if !highlighted.isEmpty && highlighted.isDisjoint(with: bar.sessions) { return 0.18 }
        if bar.isWithheld && bar.lower >= 0 { return 0.45 }
        return 1
    }

    private func lowerColor(_ bar: Bar) -> Color {
        if bar.lower < 0 { return Color.secondary.opacity(0.3) }
        // An hour with nothing lost: a quiet stub on the baseline, not a
        // warning-coloured one.
        if metric == .loss && bar.upper <= 0 { return Color.secondary.opacity(0.3) }
        let isHovered = hovered == bar.id
        switch metric {
        case .loss:
            return isHovered ? Palette.warn.opacity(0.75) : Palette.warn
        default:
            return isHovered ? Palette.Chart.internet.opacity(0.7) : Palette.Chart.internet
        }
    }

    private func upperColor(_ bar: Bar) -> Color {
        let isHovered = hovered == bar.id
        switch metric {
        case .loss:
            return isHovered ? Palette.Chart.internet.opacity(0.7) : Palette.Chart.internet
        default:
            return Palette.Chart.internet.opacity(isHovered ? 0.5 : 0.3)
        }
    }
}
