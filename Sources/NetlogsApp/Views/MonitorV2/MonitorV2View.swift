import SwiftUI
import Charts
import NetlogsCore

/// The redesigned live screen, behind Settings › General › "Try the new
/// Monitor". It runs on the same `MonitorController` as the current screen, so
/// switching the flag never touches a running session.
///
/// Three things replace the wall of cards: a path strip that says where the
/// time goes right now, a calm per-second chart of the last five minutes, and
/// a short list of the moments that went wrong. The ping log is still there,
/// folded away.
///
/// Each part takes the narrow model it reads, so a ping tick redraws the chart
/// and the strip and nothing else (plan §8.2).
struct MonitorV2View<Header: View>: View {
    let controller: MonitorController
    /// A sheet covers this screen; the chart and the log stop following the
    /// live data behind it, for the reason `LiveSessionView` gives.
    var isCovered = false
    var onSelect: (SessionSheet) -> Void = { _ in }
    @ViewBuilder let header: Header

    @State private var showsLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                header
                LivePathStrip(log: controller.log, diagnostics: controller.diagnostics,
                              wan: controller.wan, onSelect: isCovered ? nil : onSelect)
                LivePingChart(log: controller.log, isCovered: isCovered)
                cards
                log
            }
            .cappedContentWidth()
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.m)
        }
        .fadingTopScrollEdge()
    }

    /// Rows of equal-height cards; a card left over on the last row takes
    /// the whole row instead of sitting at half width. See `CardGrid`.
    private var cards: some View {
        CardGrid(minColumnWidth: 260, spacing: Space.xs + 2) {
            ThroughputCard(averages: controller.throughput.averages,
                           isTesting: controller.throughput.isTesting,
                           phase: controller.throughput.phase,
                           onRun: { controller.runThroughputTestNow() })
                .tappable(.throughput, onSelect)
            if controller.wan.isActive {
                GatewayCard(radio: controller.wan.radio,
                            problem: controller.wan.latest?.failure?.description)
                    .tappable(.gateway, onSelect)
            } else {
                NetworkCard(snapshot: controller.diagnostics.latest)
                    .tappable(.network, onSelect)
            }
            HiccupsCard(failures: controller.failures, stats: controller.stats)
                .tappable(.failures, onSelect)
            if !controller.traffic.captures.isEmpty || controller.traffic.isCapturing {
                TrafficCard(captures: controller.traffic.captures,
                            isCapturing: controller.traffic.isCapturing)
                    .tappable(.traffic, onSelect)
            }
        }
        .environment(\.cardFillsHeight, true)
    }

    private var log: some View {
        DisclosureGroup(isExpanded: $showsLog) {
            if showsLog && !isCovered {
                SamplesTable(title: "Live ping log", rows: controller.log.rows,
                             footnote: "last 5 minutes")
                    .frame(height: 320)
                    .padding(.top, Space.s)
            }
        } label: {
            Text("Show the full ping log")
                .font(.callout)
        }
    }
}

// MARK: - Path strip

private extension VerticalAlignment {
    /// The line through the node icons' centres, which the hop bars sit on.
    enum HopBar: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let hopBar = VerticalAlignment(HopBar.self)
}

/// Mac, router, line and internet in a row, with what each hop costs right
/// now. The question it answers is the one people ask when a call stutters:
/// is it the Wi-Fi, the router or the line?
struct LivePathStrip: View {
    let log: PingLog
    let diagnostics: DiagnosticsModel
    let wan: WANTelemetryModel
    /// Each hop opens the sheet the old Monitor's matching card opened: the
    /// Wi-Fi hop the network sheet, the two latency hops the latency sheet on
    /// their host, the line the gateway sheet.
    var onSelect: ((SessionSheet) -> Void)?

    /// Ten seconds: long enough that one late ping does not flip a hop red,
    /// short enough to follow a change while you watch.
    private static let recent = 10

    private struct Hop {
        let value: String
        let caption: String
        let tint: Color?
    }

    var body: some View {
        let recent = Array(log.rows.filter { !$0.isWarmup }.prefix(Self.recent))
        let router = Self.median(recent.compactMap(\.routerRttMs))
        let internet = Self.median(recent.compactMap(\.internetRttMs))
        let lostBeyond = recent.contains { $0.internetNoReply && !$0.routerNoReply }
        let lostHome = recent.contains(where: \.routerNoReply)

        HStack(alignment: .hopBar, spacing: 0) {
            node("This Mac", "laptopcomputer")
            link(wifiHop)
                .tappable(.network, onSelect)
            node("Router", "wifi.router")
            link(routerHop(router, lost: lostHome))
                .tappable(.latency, onSelect, host: .router)
            if wan.isActive {
                node("Line", "antenna.radiowaves.left.and.right")
                    .tappable(.gateway, onSelect)
            }
            link(beyondHop(router: router, internet: internet, lost: lostBeyond))
                .tappable(.latency, onSelect, host: .internet)
            node("Internet", "globe")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity)
        .cardSurface()
    }

    private var wifiHop: Hop {
        guard let snapshot = diagnostics.latest else {
            return Hop(value: "—", caption: "No reading yet", tint: nil)
        }
        guard snapshot.kind == .wifi, let rssi = snapshot.rssi else {
            return Hop(value: snapshot.kind == .ethernet ? "Cable" : "—",
                       caption: snapshot.kind == .ethernet ? "Ethernet" : "No signal reading",
                       tint: snapshot.kind == .ethernet ? Palette.good : nil)
        }
        let (word, tint): (String, Color) =
            rssi > -60 ? ("strong", Palette.good)
            : rssi > RadioSummary.weakRSSI ? ("OK", Palette.warn)
            : ("weak", Palette.bad)
        return Hop(value: "\(rssi) dBm", caption: "Wi-Fi signal · \(word)", tint: tint)
    }

    private func routerHop(_ ms: Double?, lost: Bool) -> Hop {
        guard let ms else {
            return Hop(value: "—", caption: lost ? "Router not answering" : "Waiting",
                       tint: lost ? Palette.bad : nil)
        }
        if lost { return Hop(value: Fmt.msLabel(ms), caption: "to the router · pings lost",
                             tint: Palette.bad) }
        let slow = ms > HomeTimeline.slowRouterMs
        return Hop(value: Fmt.msLabel(ms),
                   caption: slow ? "to the router · busy" : "to the router · fast",
                   tint: slow ? Palette.warn : Palette.good)
    }

    private func beyondHop(router: Double?, internet: Double?, lost: Bool) -> Hop {
        guard let internet else {
            return Hop(value: "—", caption: lost ? "Internet not answering" : "Waiting",
                       tint: lost ? Palette.bad : nil)
        }
        let beyond = max(internet - (router ?? 0), 0)
        if lost { return Hop(value: "\(Fmt.msCoarse(beyond)) ms",
                             caption: "beyond · pings lost", tint: Palette.bad) }
        let tint = beyond < 50 ? Palette.good : beyond < 120 ? Palette.warn : Palette.bad
        return Hop(value: "\(Fmt.msCoarse(beyond)) ms", caption: "beyond the router",
                   tint: tint)
    }

    private func node(_ label: String, _ symbol: String) -> some View {
        VStack(spacing: Space.xs) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quinary, in: Circle())
                .alignmentGuide(.hopBar) { $0[VerticalAlignment.center] }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func link(_ hop: Hop) -> some View {
        VStack(spacing: Space.xs) {
            Text(hop.value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            Capsule()
                .fill(hop.tint ?? Color.secondary.opacity(0.25))
                .frame(height: 4)
                .alignmentGuide(.hopBar) { $0[VerticalAlignment.center] }
            Text(hop.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Space.s)
        // Room for the hover outline `tappable` draws around a hop.
        .padding(.vertical, Space.xs)
        .frame(minWidth: 60, maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

// MARK: - Live chart

/// Every ping of the last five minutes, one column per second. Blue is the
/// trip to the internet, grey the part of it spent reaching the router.
///
/// Hovering freezes the chart on the moment under the pointer: a chart that
/// scrolls away while you read it is the reason the old one was switched off.
struct LivePingChart: View {
    let log: PingLog
    var isCovered = false

    @State private var frozen: [PingSample]?
    @State private var hovered: UInt32?

    private static let window: TimeInterval = 300

    var body: some View {
        // `??` only reads `log.rows` when nothing is frozen, so a paused chart
        // stops observing the log and is not redrawn every second.
        let rows = frozen ?? log.rows
        let samples = rows.filter { !$0.isWarmup }
        let newest = samples.first?.timestamp ?? Date()
        let domain = newest.addingTimeInterval(-Self.window) ... newest
        let yMax = Self.yMax(samples)
        let hoveredSample = hovered.flatMap { id in samples.first { $0.id == id } }

        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Every ping, last 5 minutes")
                    .font(.headline)
                Spacer(minLength: Space.s)
                readout(hoveredSample, samples: samples)
            }
            Text("One column per second. Hover to read a single ping; the chart pauses while you look.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if samples.isEmpty {
                EmptyNote("Waiting for the first pings.")
                    .frame(height: 180)
            } else {
                chart(samples, domain: domain, yMax: yMax, marked: hoveredSample)
                    .frame(height: 180)
            }
            legend
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        .onChange(of: isCovered) { _, covered in
            if covered { frozen = frozen ?? log.rows } else if hovered == nil { frozen = nil }
        }
    }

    private func chart(_ samples: [PingSample], domain: ClosedRange<Date>, yMax: Double,
                       marked: PingSample?) -> some View {
        Chart {
            columns(samples, yMax: yMax)
            if let marked {
                RuleMark(x: .value("Time", marked.timestamp))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0 ... yMax)
        .chartXAxis {
            AxisMarks(values: .stride(by: .minute)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) { Text("\(Int(ms)) ms") }
                }
            }
        }
        .plotHover(domain: domain) { date in
            guard let date else {
                hovered = nil
                if !isCovered { frozen = nil }
                return
            }
            if frozen == nil { frozen = log.rows }
            hovered = samples.min {
                abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date))
            }?.id
        }
        .transaction { $0.animation = nil }
    }

    @ChartContentBuilder
    private func columns(_ samples: [PingSample], yMax: Double) -> some ChartContent {
        ForEach(samples, id: \.id) { sample in
            if sample.internetNoReply {
                BarMark(x: .value("Time", sample.timestamp, unit: .second),
                        yStart: .value("ms", 0), yEnd: .value("ms", yMax))
                    .foregroundStyle(Palette.bad.opacity(0.18))
            } else if let internet = sample.internetRttMs {
                BarMark(x: .value("Time", sample.timestamp, unit: .second),
                        yStart: .value("ms", 0), yEnd: .value("ms", min(internet, yMax)))
                    .foregroundStyle(sample.internetWasLate ? Palette.warn : Palette.Chart.internet)
            }
            if let router = sample.routerRttMs {
                BarMark(x: .value("Time", sample.timestamp, unit: .second),
                        yStart: .value("ms", 0), yEnd: .value("ms", min(router, yMax)))
                    .foregroundStyle(Color.gray.opacity(0.85))
            }
        }
    }

    @ViewBuilder
    private func readout(_ sample: PingSample?, samples: [PingSample]) -> some View {
        if let sample {
            let time = sample.timestamp.formatted(date: .omitted, time: .standard)
            let body = sample.internetNoReply
                ? "no reply from the internet"
                : "internet \(Fmt.msCoarse(sample.internetRttMs)) ms · router \(Fmt.msLabel(sample.routerRttMs))"
                  + (sample.internetWasLate ? " · late" : "")
            Text("\(time) · \(body) · paused")
                .font(.caption.weight(.semibold).monospacedDigit())
        } else {
            let recent = samples.prefix(10)
            let internet = LivePathStrip.median(recent.compactMap(\.internetRttMs))
            let router = LivePathStrip.median(recent.compactMap(\.routerRttMs))
            Text("Now: internet \(Fmt.msCoarse(internet)) ms · router \(Fmt.msLabel(router))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var legend: some View {
        HStack(spacing: Space.l) {
            swatch(Palette.Chart.internet, "To the internet")
            swatch(Color.gray.opacity(0.85), "To your router")
            swatch(Palette.bad.opacity(0.5), "Lost ping")
            swatch(Palette.warn, "Answered late")
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

    /// A calm scale: at least 100 ms, otherwise the 95th percentile rounded up
    /// to the next 50. One spike is drawn to the top edge rather than squashing
    /// every other column flat.
    private static func yMax(_ samples: [PingSample]) -> Double {
        let values = samples.compactMap(\.internetRttMs).sorted()
        guard !values.isEmpty else { return 100 }
        let p95 = values[min(values.count - 1, Int(Double(values.count) * 0.95))]
        return max(100, (p95 * 1.2 / 50).rounded(.up) * 50)
    }
}

// MARK: - Hiccups

/// The moments that went wrong, newest first, in words: which side of the
/// router it happened on, and whether a speed test was running.
struct HiccupsCard: View {
    let failures: FailureLog
    let stats: LiveStats

    var body: some View {
        let rows = Array(failures.newestFirst.prefix(3))
        SummaryCard(title: "Hiccups", systemImage: "exclamationmark.bubble",
                    subtitle: "\(failures.total) of \(stats.sampleCount.formatted()) pings") {
            if rows.isEmpty {
                Text("None so far.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(rows, id: \.id) { sample in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(sample.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Circle()
                                .fill(Self.isLost(sample) ? Palette.bad : Palette.warn)
                                .frame(width: 7, height: 7)
                            Text(Self.sentence(sample))
                                .font(.callout)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private static func isLost(_ sample: PingSample) -> Bool {
        sample.routerNoReply || sample.internetNoReply
    }

    static func sentence(_ sample: PingSample) -> String {
        let load = sample.isUnderLoad ? " A speed test was running." : ""
        if sample.routerNoReply {
            return "Lost ping at your router." + load
        }
        if sample.internetNoReply {
            return "Lost ping, past the router. Your home network was fine." + load
        }
        if sample.routerWasLate, let ms = sample.routerLateMs {
            return "Late reply from the router, \(Fmt.msCoarse(ms)) ms." + load
        }
        if let ms = sample.internetLateMs {
            return "Late reply, \(Fmt.msCoarse(ms)) ms." + load
        }
        return "Slow reply." + load
    }
}
