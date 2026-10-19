import SwiftUI
import Charts
import NetlogsCore

/// The home network over the last 24 hours: this Mac's Wi-Fi, the router, and
/// — when a gateway is connected — the line itself, on one shared timeline.
///
/// Everything here already existed, spread across the Network and Gateway
/// sheets of one session at a time. This screen's job is to put the three
/// side by side across sessions, so "was it the Wi-Fi, the router or the
/// line?" is one look instead of three sheets.
struct RouterView: View {
    let store: SessionStore

    @State private var model = RouterModel()
    @State private var hovered: Int?
    @State private var hoveredEvent: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if let result = model.result, result.timeline.hasMeasurements {
                    content(result)
                } else if model.isLoading {
                    LoadingView(label: "Loading", placement: .inline)
                } else {
                    EmptyState("Nothing recorded in the last 24 hours",
                               systemImage: "wifi.router",
                               message: "Record a session on the Monitor screen to see your home network here.")
                }
            }
            .cappedContentWidth()
            .padding(Space.l)
        }
        .fadingTopScrollEdge()
        .navigationTitle("Router")
        .navigationSubtitle("Last 24 hours")
        .task { await model.load(store: store) }
    }

    @ViewBuilder
    private func content(_ result: RouterResult) -> some View {
        // One row of equal cards when there is room; on a narrow window two
        // and a full-width third rather than a stack of three.
        CardGrid(minColumnWidth: 250, spacing: Space.s) {
            cards(result)
        }

        timeline(result.timeline)

        // Stacked, both full width. Side by side, the short list of events
        // was stretched to the height of the details and read as an empty box.
        events(result.timeline)
        details(result)
    }

    // MARK: - Cards

    @ViewBuilder
    private func cards(_ result: RouterResult) -> some View {
        wifiCard(result)
        routerCard(result)
        if result.latestRadio != nil || result.timeline.hasGateway {
            lineCard(result)
        }
    }

    private func wifiCard(_ result: RouterResult) -> some View {
        let wifi = result.latestWiFi
        let rssi = wifi?.rssi
        let grade: (String, Color?) = {
            guard let rssi else { return ("No reading", nil) }
            if rssi > -60 { return ("Strong", Palette.good) }
            if rssi > RadioSummary.weakRSSI { return ("OK", Palette.warn) }
            return ("Weak", Palette.bad)
        }()
        let weak = result.timeline.events.filter { $0.kind == .weakWiFi }.count
        let facts = [wifi?.band.map { band in wifi?.channel.map { "\(band) · channel \($0)" } ?? band },
                     wifi?.phyMode,
                     wifi?.txRateMbps.map { "Link \(Fmt.mbps($0)) Mbit/s" },
                     wifi?.snr.map { "Signal-to-noise \($0) dB" }].compactMap { $0 }
        return statusCard(
            title: wifi?.kind == .ethernet ? "Ethernet" : "Wi-Fi",
            symbol: "wifi",
            value: rssi.map(String.init) ?? "—", unit: rssi == nil ? "" : "dBm",
            grade: grade,
            sentence: wifi?.kind == .ethernet
                ? "This Mac is on a cable, so there is no radio to go wrong."
                : weak == 0
                    ? "This Mac had a good signal to the router all day."
                    : "Mostly fine, but the signal was weak \(weak) time\(weak == 1 ? "" : "s").",
            facts: facts,
            help: Explain.rssi
        )
    }

    private func routerCard(_ result: RouterResult) -> some View {
        let ms = result.routerMedianMs
        let bloat = result.bufferbloatMs
        let lagging = (bloat ?? 0) >= 30
        let slow = (ms ?? 0) > HomeTimeline.slowRouterMs
        let grade: (String, Color?) = slow ? ("Slow", Palette.bad)
            : lagging ? ("Lags under load", Palette.bufferbloat(bloat ?? 0))
            : ms == nil ? ("No reading", nil) : ("Fast", Palette.good)
        var facts: [String] = []
        if let loss = result.routerLoss { facts.append("\(Fmt.percent(loss)) lost") }
        if let bloat { facts.append("+\(Fmt.msCoarse(bloat)) ms under load") }
        if let host = result.routerHost { facts.append(host) }
        return statusCard(
            title: "Router",
            symbol: "wifi.router",
            value: ms.map { $0 < 10 ? Fmt.ms($0) : Fmt.msCoarse($0) } ?? "—", unit: ms == nil ? "" : "ms",
            grade: grade,
            sentence: lagging
                ? "Answers fast, but slows down when the line is busy."
                : slow ? "Slow to answer, even for pings from this Mac."
                : "Answers quickly. Its median reply over the day.",
            facts: facts,
            help: Explain.routerCard
        )
    }

    private func lineCard(_ result: RouterResult) -> some View {
        let radio = result.latestRadio
        let sinr = radio?.nrSINR ?? radio?.lteSINR
        let rsrp = radio?.nrRSRP ?? radio?.lteRSRP
        let grade: (String, Color?) = {
            guard let sinr else { return ("No reading", nil) }
            if sinr >= 13 { return ("Good", Palette.good) }
            if sinr >= 5 { return ("Fair", Palette.warn) }
            return ("Poor", Palette.bad)
        }()
        var tech = radio?.technology ?? "Cellular"
        if let standalone = radio?.standalone, tech == "5G" {
            tech += standalone ? " standalone" : " non-standalone"
        }
        let facts = [tech, radio?.band.map { "Band \($0)" },
                     rsrp.map { "RSRP \(Fmt.msCoarse($0)) dBm" }].compactMap { $0 }
        return statusCard(
            title: "Line",
            symbol: "antenna.radiowaves.left.and.right",
            value: sinr.map(Fmt.msCoarse) ?? "—", unit: sinr == nil ? "" : "dB signal quality",
            grade: grade,
            sentence: "As the gateway reports it. Signal quality (SINR) is what speed follows.",
            facts: facts,
            help: nil
        )
    }

    private func statusCard(title: String, symbol: String, value: String, unit: String,
                            grade: (String, Color?), sentence: String, facts: [String],
                            help: String?) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(Palette.Chart.internet)
                    .frame(width: 26, height: 26)
                    .background(Palette.fill(Palette.Chart.internet),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).font(.headline)
                Spacer(minLength: Space.xs)
                Text(grade.0)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(grade.1 ?? .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(grade.1.map { AnyShapeStyle(Palette.fill($0)) }
                                ?? AnyShapeStyle(.quaternary), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.metricValueLarge)
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
            .helpIfPresent(help)
            Text(sentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout {
                ForEach(facts, id: \.self) { Chip(text: $0) }
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    // MARK: - Timeline

    private struct Lane {
        let title: String
        let note: String
        let unit: String
        let value: (HomeTimeline.Bucket) -> Double?
        let domain: ClosedRange<Double>
        /// Bars draw from the domain's floor; a dBm lane has no zero.
        let isBad: (Double) -> Bool
        let reference: (value: Double, label: String)?
        let format: (Double) -> String
    }

    private func lanes(_ timeline: HomeTimeline) -> [Lane] {
        var lanes: [Lane] = []
        if timeline.hasWiFi {
            lanes.append(Lane(title: "Wi-Fi signal", note: "this Mac to the router", unit: "dBm",
                              value: \.rssi, domain: -90 ... -30,
                              isBad: { $0 <= HomeTimeline.weakRSSI },
                              reference: (HomeTimeline.weakRSSI, "weak below −70 dBm"),
                              format: { "\(Fmt.msCoarse($0)) dBm" }))
        }
        // Scaled to the day's own replies, so a router that answers in 2 to
        // 6 ms shows its variation instead of a flat line under a 20 ms
        // threshold. Never below 10 ms, so a quiet day is not magnified into
        // drama; the threshold line shows only once the scale reaches it.
        let routerTop = timeline.buckets.compactMap(\.routerMs).max() ?? 0
        let routerDomain = 0 ... max(10, (routerTop * 1.25 / 5).rounded(.up) * 5)
        let slowShown = routerDomain.upperBound >= HomeTimeline.slowRouterMs
        lanes.append(Lane(title: "Router",
                          note: slowShown ? "how fast it answers" : "how fast it answers · slow is above 20 ms",
                          unit: "ms",
                          value: \.routerMs, domain: routerDomain,
                          isBad: { $0 > HomeTimeline.slowRouterMs },
                          reference: slowShown ? (HomeTimeline.slowRouterMs, "slow above 20 ms") : nil,
                          format: { $0 < 10 ? "\(Fmt.ms($0)) ms" : "\(Fmt.msCoarse($0)) ms" }))
        if timeline.buckets.contains(where: { $0.sinr != nil }) {
            lanes.append(Lane(title: "Line signal quality", note: "SINR, from the gateway", unit: "dB",
                              value: \.sinr, domain: 0 ... 30,
                              isBad: { $0 < 5 },
                              reference: (5, "poor below 5 dB"),
                              format: { "\(Fmt.msCoarse($0)) dB" }))
        }
        if timeline.buckets.contains(where: { $0.downMbps != nil }) {
            let top = timeline.buckets.compactMap(\.downMbps).max() ?? 100
            lanes.append(Lane(title: "Internet traffic", note: "everything through the line, download",
                              unit: "Mbit/s", value: \.downMbps, domain: 0 ... max(top * 1.1, 10),
                              isBad: { _ in false }, reference: nil,
                              format: { "\(Fmt.mbps($0)) Mbit/s" }))
        }
        return lanes
    }

    private func timeline(_ timeline: HomeTimeline) -> some View {
        let lanes = self.lanes(timeline)
        let event = hoveredEvent.flatMap { id in timeline.events.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Everything on one timeline").font(.headline)
                Spacer(minLength: Space.s)
                Text(readoutTime(timeline))
                    .font(.caption.monospacedDigit().weight(hovered == nil ? .regular : .semibold))
                    .foregroundStyle(hovered == nil ? .secondary : .primary)
            }
            Text("Move along the timeline to read every lane at the same moment. "
                 + "That is how you tell a Wi-Fi problem from a problem with the line.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                laneView(lane, timeline: timeline, event: event,
                         showsAxis: lane.title == lanes.last?.title)
            }
            HStack(spacing: Space.l) {
                swatch(Palette.Chart.internet, "Normal")
                swatch(Palette.bad, "Outside the good range")
                swatch(Color.secondary.opacity(0.25), "Not recording")
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private func laneView(_ lane: Lane, timeline: HomeTimeline, event: HomeTimeline.Event?,
                          showsAxis: Bool) -> some View {
        let shown = hovered.map { timeline.buckets[$0] }
            ?? timeline.buckets.last(where: { lane.value($0) != nil })
        let value = shown.flatMap(lane.value)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(lane.title).font(.caption.weight(.semibold))
                Text(lane.note).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                Text(value.map(lane.format) ?? "not measured")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(value.map { lane.isBad($0) ? Palette.bad : Color.primary }
                                     ?? Color.secondary)
            }
            Chart {
                laneMarks(lane, timeline: timeline, event: event)
            }
            .chartXScale(domain: timeline.interval.start ... timeline.interval.end)
            .chartYScale(domain: lane.domain)
            .chartYAxis(.hidden)
            .chartXAxis {
                if showsAxis {
                    AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                        AxisGridLine().foregroundStyle(.separator.opacity(0.3))
                        // A label within an hour of the right edge is cut in
                        // half by it, so it is left off.
                        if let date = value.as(Date.self),
                           timeline.interval.end.timeIntervalSince(date) > 3600 {
                            AxisValueLabel(format: .dateTime.hour()).font(.caption2)
                        }
                    }
                } else {
                    AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                        AxisGridLine().foregroundStyle(.separator.opacity(0.3))
                    }
                }
            }
            .plotHover(domain: timeline.interval.start ... timeline.interval.end) { date in
                let index = date.flatMap { date in
                    timeline.buckets.firstIndex { $0.start <= date && date < $0.end }
                }
                if index != hovered { hovered = index }
            }
            .transaction { $0.animation = nil }
            .frame(height: showsAxis ? 76 : 58)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(lane.title))
        .accessibilityValue(Text(value.map(lane.format) ?? "not measured"))
    }

    @ChartContentBuilder
    private func laneMarks(_ lane: Lane, timeline: HomeTimeline,
                           event: HomeTimeline.Event?) -> some ChartContent {
        if let event {
            RectangleMark(xStart: .value("From", event.start),
                          xEnd: .value("To", max(event.end, event.start.addingTimeInterval(900))),
                          yStart: .value("Floor", lane.domain.lowerBound),
                          yEnd: .value("Ceiling", lane.domain.upperBound))
                .foregroundStyle(Palette.fill(Palette.warn))
        }
        ForEach(timeline.buckets) { bucket in
            if !bucket.measured {
                RectangleMark(xStart: .value("From", bucket.start), xEnd: .value("To", bucket.end),
                              yStart: .value("Floor", lane.domain.lowerBound),
                              yEnd: .value("Ceiling", lane.domain.upperBound))
                    .foregroundStyle(Color.secondary.opacity(0.12))
            } else if let value = lane.value(bucket) {
                RectangleMark(
                    xStart: .value("From", bucket.start.addingTimeInterval(60)),
                    xEnd: .value("To", bucket.end.addingTimeInterval(-60)),
                    yStart: .value("Floor", lane.domain.lowerBound),
                    yEnd: .value("Value", min(max(value, lane.domain.lowerBound
                        + (lane.domain.upperBound - lane.domain.lowerBound) * 0.03),
                                              lane.domain.upperBound))
                )
                .foregroundStyle(barColor(lane.isBad(value), hovered: hovered == bucket.id))
            }
        }
        if let reference = lane.reference {
            RuleMark(y: .value("Reference", reference.value))
                .foregroundStyle(Color.secondary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    Text(reference.label).font(.caption2).foregroundStyle(.secondary)
                }
        }
    }

    private func barColor(_ bad: Bool, hovered: Bool) -> Color {
        let base = bad ? Palette.bad : Palette.Chart.internet
        return hovered ? base : base.opacity(0.8)
    }

    private func readoutTime(_ timeline: HomeTimeline) -> String {
        guard let hovered else { return "Latest reading" }
        let bucket = timeline.buckets[hovered]
        let day = bucket.start.formatted(.dateTime.weekday(.abbreviated).day())
        return "\(day), \(bucket.start.formatted(date: .omitted, time: .shortened))"
            + "–\(bucket.end.formatted(date: .omitted, time: .shortened))"
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: Space.xs) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 9)
            Text(label)
        }
    }

    // MARK: - Events and details

    private func events(_ timeline: HomeTimeline) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("What happened").font(.headline)
            Text("Newest first. Hover one to find it on the timeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if timeline.events.isEmpty {
                EmptyNote("Nothing out of the ordinary in the last 24 hours.")
            }
            ForEach(timeline.events) { event in
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(Self.when(event.start))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Circle().fill(eventTint(event)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(eventTitle(event)).font(.callout.weight(.semibold))
                        Text(eventDetail(event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Space.s)
                .background(hoveredEvent == event.id ? AnyShapeStyle(Palette.fill(Palette.warn))
                                                     : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { hoveredEvent = event.id } else if hoveredEvent == event.id { hoveredEvent = nil }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    /// The window is 24 hours, so a time alone is ambiguous: 17.56 could be
    /// an hour ago or yesterday evening.
    private static func when(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return time }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func eventTitle(_ event: HomeTimeline.Event) -> String {
        switch event.kind {
        case .notRecording:  return "Not recording"
        case .weakWiFi:      return "Weak Wi-Fi"
        case .slowRouter:    return "Router slow to answer"
        case .channelChange: return "Wi-Fi changed channel"
        case .radioChange:   return "The line changed cell or band"
        }
    }

    private func eventDetail(_ event: HomeTimeline.Event) -> String {
        let span = "from \(Self.when(event.start).lowercased()) to \(Self.when(event.end).lowercased())"
        switch event.kind {
        case .notRecording:
            return "Nothing was measured \(span), so there is nothing to show for it."
        case .weakWiFi:
            return "Signal down to \(Fmt.msCoarse(event.value)) dBm \(span). "
                + "Usually distance or walls between this Mac and the router."
        case .slowRouter:
            return "Up to \(Fmt.msCoarse(event.value)) ms \(span). "
                + "Often the line was busy, which is lag under load."
        case .channelChange:
            let channel = event.value.map { "channel \(Int($0))" } ?? "a new channel"
            return "The router moved to \(channel)\(event.note.map { " (\($0))" } ?? "")."
        case .radioChange:
            return event.note.map { "The gateway reported \($0)." } ?? "The gateway reported a change."
        }
    }

    private func eventTint(_ event: HomeTimeline.Event) -> Color {
        switch event.kind {
        case .notRecording, .channelChange, .radioChange: return .secondary
        case .weakWiFi:   return Palette.warn
        case .slowRouter: return Palette.bad
        }
    }

    private func detailColumn(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                DetailRow(label: row.0, value: row.1)
                Divider().opacity(0.4)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func details(_ result: RouterResult) -> some View {
        let wifi = result.latestWiFi
        let radio = result.latestRadio
        var rows: [(String, String)] = []
        if let ip = wifi?.ipAddress { rows.append(("This Mac", "\(ip) on \(wifi?.interfaceName ?? "")")) }
        if let gateway = wifi?.gateway ?? result.routerHost { rows.append(("Router", gateway)) }
        if let dns = wifi?.dnsServers, !dns.isEmpty { rows.append(("DNS", dns.joined(separator: ", "))) }
        if let security = wifi?.security { rows.append(("Wi-Fi security", security)) }
        if let phy = wifi?.phyMode { rows.append(("Wi-Fi standard", phy)) }
        if let noise = wifi?.noise { rows.append(("Noise level", "\(noise) dBm")) }
        if let tech = radio?.technology { rows.append(("Line", tech + (radio?.band.map { ", band \($0)" } ?? ""))) }
        if let cell = radio?.cellID { rows.append(("Cell", "\(cell)" + (radio?.physicalCellID.map { ", PCI \($0)" } ?? ""))) }
        return VStack(alignment: .leading, spacing: Space.s) {
            Text("Network details").font(.headline)
            // Two columns when there is room, so a full-width card is not a
            // long list of label, gap, value.
            let half = (rows.count + 1) / 2
            SplitRow(minLeading: 260, minTrailing: 260, spacing: Space.xl) {
                detailColumn(Array(rows.prefix(half)))
                detailColumn(Array(rows.dropFirst(half)))
            }
            Text("macOS does not let apps read the Wi-Fi network name, so it is not shown.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }
}
