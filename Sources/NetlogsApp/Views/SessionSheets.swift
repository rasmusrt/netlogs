import SwiftUI
import NetlogsCore

enum PingHost: String, Hashable, CaseIterable, Identifiable {
    case router, internet
    var id: Self { self }
    var title: String { self == .router ? "Router" : "Internet" }
    /// The thresholds this host's figures are judged by — a gateway and an
    /// internet host do not deserve the same ramp. See `LatencyGrade.Ramp`.
    var ramp: LatencyGrade.Ramp { self == .router ? .gateway : .internet }
}

/// What a summary card, or the header's failure count, opens.
///
/// These were a trailing `.inspector` before. An inspector permanently narrows
/// the window it lives in, which is the wrong trade for detail you consult
/// occasionally — the log and the cards want that width back the moment you
/// are done reading. A sheet borrows the space and gives it straight back.
enum SessionSheet: String, CaseIterable, Identifiable, Hashable {
    case latency = "Latency"
    case throughput = "Speed tests"
    case network = "Network"
    case failures = "Failures"
    case traffic = "Traffic"
    case gateway = "Gateway"

    var id: Self { self }

    /// Height, per sheet, declared rather than negotiated.
    ///
    /// One size for all four was wrong in both directions: Latency's content
    /// ends well short of it and left a slab of empty sheet, while Speed and
    /// Network hold lists long enough that no fitted height would help — they
    /// scroll whatever we pick.
    ///
    /// Still fixed rather than content-driven, for two reasons. A sheet whose
    /// size is being negotiated re-lays out on every frame of the present
    /// animation, and the async detail load landing mid-animation resizes it
    /// again. And a fitted height would be defeated anyway by the `ScrollView`
    /// inside each sheet, which takes whatever height it is offered — the sheet
    /// would always come out at the maximum. One number per sheet keeps the
    /// animation moving a single rectangle while letting the short one be short.
    var preferredHeight: CGFloat {
        switch self {
        case .latency:    return 490
        case .throughput: return 560
        case .network:    return 560
        case .failures:   return 560
        case .traffic:    return 520
        case .gateway:    return 560
        }
    }

    var systemImage: String {
        switch self {
        case .latency:    return "chart.xyaxis.line"
        case .throughput: return "speedometer"
        case .network:    return "wifi"
        case .failures:   return "exclamationmark.triangle"
        case .traffic:    return "arrow.up.arrow.down"
        case .gateway:    return "antenna.radiowaves.left.and.right"
        }
    }
}

/// The trailing inspector, replacing all four modal detail sheets.
///
/// `DetailSheets.swift` had four sheets in four different layout idioms — a
/// `List`, a real `Table`, a `List` of `LabeledContent`, and a fake table
/// hand-built from `HStack`s — behind an invisible tap target on a stat card.
/// An inspector is the native macOS home for exactly this: reference detail
/// alongside the thing it describes, rather than covering it up.
///
/// Content is loaded by the caller, lazily, so opening the inspector on a saved
/// session doesn't turn a sheet's on-demand read into an eager one on every
/// sidebar click.
struct SessionSheetView: View {
    let sheet: SessionSheet
    let detail: SessionDetail?
    let liveDiagnostics: DiagnosticsSnapshot?
    /// The running session's stored snapshots, reduced.
    ///
    /// Without this the Network sheet had no history at all while a session
    /// ran: the loader only reads for `.latency`, so `detail` was whatever an
    /// earlier Latency open had left behind — history appeared or didn't
    /// depending on which sheet you happened to open first, and was stale when
    /// it did.
    var liveTrace: DiagnosticsTrace?
    /// The live screen already holds every failure in memory, so the failures
    /// sheet opens instantly there instead of waiting on a history read.
    var liveFailures: [PingSample]?
    var liveFailureTotal: Int?
    /// Same arrangement as failures: the live screen already holds every
    /// capture in memory, so the sheet reads them from there rather than
    /// re-querying a session that is still being written.
    var liveTraffic: [TrafficCapture]?
    var liveCapturing: Bool = false
    /// Results the running session already holds in memory.
    ///
    /// Diagnostics and failures were already served this way; throughput was
    /// not, so the live Speed sheet re-read the whole session from SQLite to
    /// show rows the controller was holding. Worse than redundant: a test that
    /// finished seconds ago could be missing from that read, and the sheet said
    /// "No tests yet" while the card behind it showed the result.
    var liveThroughput: [ThroughputResult]?
    var liveAverages: ThroughputAverages?
    var isLoading = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if isLoading && detail == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content
                }
            }
        }
        // 600, not 660: the window's own minimum is 620, so the old width made
        // the sheet wider than the window it is attached to — which no native
        // app does, and which clipped the title to "atency" at that size.
        // Height is per sheet; see `SessionSheet.preferredHeight`.
        .frame(width: 600, height: sheet.preferredHeight)
    }

    /// Title leading, close trailing.
    ///
    /// This was a `NavigationStack` with a bottom-right "Done". A navigation
    /// bar inside a sheet left the title floating oddly in a wide, otherwise
    /// empty strip, and pushed dismissal to the far corner. A plain header row
    /// with a close control is what the rest of the system does now, and it
    /// puts dismissal where the eye already is.
    private var header: some View {
        HStack(spacing: Space.m) {
            Text(sheet.rawValue)
                .font(.headline)
            Spacer(minLength: Space.m)
            CloseButton { dismiss() }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s + 2)
    }


    @ViewBuilder
    private var content: some View {
        switch sheet {
        case .latency:
            LatencyDetail(detail: detail)
        case .throughput:
            ThroughputDetail(
                results: liveThroughput ?? detail?.summary.throughput ?? [],
                averages: liveAverages ?? detail?.throughputAverages ?? ThroughputAverages()
            )
        case .network:
            NetworkDetail(
                latest: liveDiagnostics ?? detail?.summary.diagnostics.last,
                trace: liveTrace ?? detail?.diagnosticsTrace ?? DiagnosticsTrace()
            )
        case .traffic:
            TrafficDetail(
                captures: liveTraffic ?? detail?.traffic ?? [],
                isCapturing: liveCapturing
            )
        case .gateway:
            GatewayDetail(trace: detail?.wanTrace ?? WANTrace())
        case .failures:
            FailuresDetail(
                failures: liveFailures ?? detail?.failures.reversed() ?? [],
                total: liveFailureTotal ?? detail?.failures.count ?? 0,
                sampleCount: detail?.sampleCount
            )
        }
    }
}

/// Every failed sample, with the timestamp and which host went quiet.
private struct FailuresDetail: View {
    let failures: [PingSample]
    let total: Int
    let sampleCount: Int?

    var body: some View {
        if failures.isEmpty {
            ContentUnavailableView(
                "Nothing missed a deadline",
                systemImage: "checkmark.seal",
                description: Text(sampleCount.map { "Both hosts replied to all \($0.formatted()) pings." }
                                  ?? "Both hosts have replied to every ping.")
            )
        } else {
            VStack(spacing: 0) {
                Table(failures) {
                    TableColumn("Time") { sample in
                        Text(sample.timestamp, format: .dateTime.month().day()
                            .hour().minute().second())
                            .font(.tabular)
                    }
                    .width(160)

                    TableColumn("Router") { sample in
                        HostOutcome(ms: sample.routerMs, lateMs: sample.routerLateMs,
                                    ramp: .gateway)
                    }
                    .width(130)

                    TableColumn("Internet") { sample in
                        HostOutcome(ms: sample.internetMs, lateMs: sample.internetLateMs,
                                    ramp: .internet)
                    }
                    .width(130)

                    TableColumn("Load") { sample in
                        if sample.phase != .idle {
                            Chip(text: sample.phase.rawValue)
                                .foregroundStyle(Palette.Chart.load(sample.phase))
                        }
                    }
                }

                Divider()
                HStack {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
            }
        }
    }

    /// Splits the total into the three things it is actually made of.
    ///
    /// The old footnote said "14 failed pings · 0.0% of the session", which is
    /// true and reads as packet loss. On the session that prompted this, none
    /// of the 14 were lost: every one came back late, and three of the five
    /// clusters were the app's own upload test filling the uplink queue. The
    /// percentage stays — but it is now a percentage of something named.
    private var footnote: String {
        // Counted over the rows on screen when they are all here; the totals
        // the header holds are the authority when they are not.
        let shown = failures
        let lost = shown.filter { $0.routerNoReply || $0.internetNoReply }.count
        let late = shown.count - lost
        let underLoad = shown.filter(\.isUnderLoad).count

        var parts = ["\(total.formatted()) missed deadline\(total == 1 ? "" : "s")"]
        if failures.count == total {
            parts.append(lost == 0 ? "none lost" : "\(lost) lost")
            if late > 0 { parts.append("\(late) replied late") }
            if underLoad > 0 { parts.append("\(underLoad) during a speed test") }
        }
        if let sampleCount, sampleCount > 0 {
            parts.append(Fmt.percent(Double(total) / Double(sampleCount)) + " of the session")
        }
        if failures.count < total {
            parts.append("showing the most recent \(failures.count.formatted())")
        }
        return parts.joined(separator: " · ")
    }
}

/// Which host answered and which did not — the distinction the sheet exists for.
///
/// Three outcomes, not two. A host that answered late gets its real round-trip
/// time shown with a "late" marker rather than the flat "no reply" it used to
/// get, because those are the rows a user takes to their ISP and "no reply" is
/// the wrong thing to take: it says a packet was dropped when what happened is
/// that a queue was full for two and a half seconds.
private struct HostOutcome: View {
    let ms: Double?
    let lateMs: Double?
    let ramp: LatencyGrade.Ramp

    init(ms: Double?, lateMs: Double? = nil, ramp: LatencyGrade.Ramp) {
        self.ms = ms
        self.lateMs = lateMs
        self.ramp = ramp
    }

    var body: some View {
        if let ms {
            Text(Fmt.msLabel(ms))
                .font(.tabularSmall)
                .foregroundStyle(Palette.pill(ms, on: ramp))
        } else if let lateMs {
            HStack(spacing: Space.xs) {
                Text(Fmt.msLabel(lateMs))
                    .font(.tabularSmall)
                    .foregroundStyle(Palette.pill(lateMs, on: ramp))
                Text("late")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .help("Replied after the timeout. The packet arrived; it missed the deadline.")
        } else {
            Text("no reply")
                .font(.tabularSmall.weight(.semibold))
                .foregroundStyle(Palette.critical)
        }
    }
}

// MARK: - Latency

private struct LatencyDetail: View {
    let detail: SessionDetail?
    @State private var host: PingHost = .internet

    var body: some View {
        if let detail {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    Picker("Host", selection: $host) {
                        ForEach(PingHost.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // Plain labels, with the percentile names kept in the
                    // tooltips: "p95" is precise and means nothing to most
                    // people, while "1 in 20 slower" says the same thing and
                    // can be read without being taught. Hover still gives the
                    // technical name, so the jargon stays discoverable.
                    DetailSection("Distribution") {
                        let stat = host == .router ? detail.stats.router : detail.stats.internet
                        percentileRow("Typical (50th percentile)", stat.p50, help: Explain.p50)
                        percentileRow("1 in 20 slower (95th percentile)", stat.p95, help: Explain.p95)
                        percentileRow("1 in 100 slower (99th percentile)", stat.p99, help: Explain.p99)
                        percentileRow("Jitter", stat.jitter, help: Explain.jitter)
                    }
                    .padding(Space.m)
                    .cardSurface()

                    // Side by side: they are the two ends of one distribution,
                    // and reading them stacked meant scrolling between halves
                    // of a comparison.
                    HStack(alignment: .top, spacing: Space.m) {
                        DetailSection("10 fastest") {
                            samples(host == .router
                                    ? detail.summary.routerLowest
                                    : detail.summary.internetLowest)
                        }
                        .padding(Space.m)
                        .cardSurface()

                        DetailSection("10 slowest") {
                            samples(host == .router
                                    ? detail.summary.routerHighest
                                    : detail.summary.internetHighest)
                        }
                        .padding(Space.m)
                        .cardSurface()
                    }
                }
                .padding(Space.l)
            }
        } else {
            ContentUnavailableView("No session", systemImage: "chart.xyaxis.line")
        }
    }

    private func percentileRow(_ label: String, _ ms: Double, help: String) -> some View {
        DetailRow(label: label,
                     value: Fmt.msLabel(ms),
                     tint: Palette.latency(ms, on: host.ramp),
                     help: help)
    }

    /// Banded on alternating rows so the eye can carry a time across to its
    /// value. Striped by position, which is safe here in a way it was not in
    /// the live log: these are ten finished rows, not a sliding window, so no
    /// row ever changes index.
    @ViewBuilder
    private func samples(_ list: [PingSample]) -> some View {
        if list.isEmpty {
            EmptyNote("—")
        } else {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { index, sample in
                    let ms = host == .router ? sample.routerMs : sample.internetMs
                    DetailRow(
                        // Same field-based format as the live ping log. The
                        // `.standard` style used here before is also
                        // locale-aware, but it resolves to the region's full
                        // time pattern — which on a Danish region is
                        // "7.14.53", reading like a decimal beside a column of
                        // milliseconds while the log two panes away said
                        // "07:14:53". One app, one format.
                        label: sample.timestamp
                            .formatted(.dateTime.hour().minute().second()),
                        value: Fmt.msLabel(ms),
                        tint: ms.flatMap { Palette.latency($0, on: host.ramp) }
                    )
                    .padding(.horizontal, Space.xs)
                    .padding(.vertical, 3)
                    .background {
                        if index.isMultiple(of: 2) {
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(Palette.rowStripe)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Throughput

private struct ThroughputDetail: View {
    let results: [ThroughputResult]
    let averages: ThroughputAverages

    var body: some View {
        if results.isEmpty {
            ContentUnavailableView(
                "No tests yet",
                systemImage: "speedometer",
                description: Text("Throughput tests run on the interval set in Settings.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    // Always shown, and the same six figures the Speed card
                    // carries — the card is the summary of this sheet, so they
                    // should not be a different set of numbers.
                    DetailSection("Average of \(averages.count) test\(averages.count == 1 ? "" : "s")") {
                        DetailRow(label: "Download",
                                     value: "\(Fmt.mbps(averages.downloadMbps)) Mbps")
                        DetailRow(label: "Upload",
                                     value: "\(Fmt.mbps(averages.uploadMbps)) Mbps")
                        DetailRow(label: "Bufferbloat",
                                     value: averages.bufferbloatMs
                                         .map { "+\(Fmt.msCoarse($0)) ms" } ?? "—",
                                     tint: averages.bufferbloatMs.map(Palette.bufferbloat),
                                     help: Explain.bufferbloat)
                        DetailRow(label: "Packet loss",
                                     value: Fmt.percent(averages.packetLoss),
                                     help: Explain.packetLoss)
                        DetailRow(label: "Ping under load",
                                     value: Fmt.msLabel(averages.loadedLatencyMs),
                                     tint: averages.loadedLatencyMs.flatMap { Palette.latency($0, on: .internet) },
                                     help: Explain.testAverage)
                        DetailRow(label: "Jitter under load",
                                     value: Fmt.msLabel(averages.loadedJitterMs),
                                     tint: averages.loadedJitterMs.flatMap { Palette.jitter($0) },
                                     help: Explain.testJitter)
                    }
                    .padding(Space.m)
                    .cardSurface()
                    ForEach(results.reversed()) { result in
                        testCard(result)
                    }
                }
                .padding(Space.l)
            }
        }
    }

    private func testCard(_ result: ThroughputResult) -> some View {
        let grade = result.bufferbloatMs.map { BufferbloatGrade(milliseconds: $0) }
        return VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text(result.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // No badge at all when bufferbloat was never measured — an
                // "excellent" grade derived from an unmeasured baseline is the
                // exact claim schema 5 exists to stop making.
                if let grade {
                    StatusBadge(text: grade.label, color: Palette.grade(grade),
                                showsDot: false, size: .small)
                }
            }
            // The headline six, in the same order as the Speed card on the
            // Monitor screen — so the summary and one test read the same way.
            //
            // Six do not fit one row at this sheet width, so they fall to two
            // rather than truncating. `fixedSize` goes on each candidate, not
            // on the `ViewThatFits`: a candidate holding a `Spacer` is greedy
            // and always "fits", which makes the whole mechanism a no-op — the
            // same trap documented on `ThroughputCard`.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                    headlineMetrics(result, grade)
                }
                .fixedSize()

                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                        speedMetrics(result, grade)
                    }
                    .fixedSize()
                    HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                        pingMetrics(result)
                    }
                    .fixedSize()
                }
            }

            // The same story the idle → down → up arrows told, read down the
            // latency column, with the spread beside it. An average says the
            // connection slowed under load; the high says how far it went,
            // which is what a call actually suffers.
            // No rule under the headings: a `Divider` is greedy horizontally,
            // and inside a `GridRow` it stretched the table to the full card
            // width, scattering four numbers across 550 pt. The headings are
            // tertiary and the rows are tabular — that separates them already.
            Grid(alignment: .trailing, horizontalSpacing: Space.m, verticalSpacing: 3) {
                GridRow {
                    Color.clear.frame(width: 0, height: 0).gridColumnAlignment(.leading)
                    Text("latency")
                    Text("jitter")
                    Text("low")
                    Text("high")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                phaseRow("idle", result.idleLatencyMs,
                         result.idleJitterMs, result.idleLowMs, result.idleHighMs)
                phaseRow("download", result.downloadLatencyMs,
                         result.downloadJitterMs, result.downloadLowMs, result.downloadHighMs)
                phaseRow("upload", result.uploadLatencyMs,
                         result.uploadJitterMs, result.uploadLowMs, result.uploadHighMs)
            }
            .padding(.top, Space.xs)

            // Loss moved up to the headline row, so it is not repeated here.
            Text("\(Fmt.bytes(result.totalBytes))"
                 + (result.serverLocation.map { " · \($0)" } ?? ""))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, Space.xs)
        }
        .padding(Space.m)
        .cardSurface()
    }

    @ViewBuilder
    private func headlineMetrics(_ result: ThroughputResult, _ grade: BufferbloatGrade?) -> some View {
        speedMetrics(result, grade)
        pingMetrics(result)
    }

    /// Bufferbloat belongs here as a figure, not only as the grade word in the
    /// badge: with all three phase latencies in the table below, the number
    /// derived from them was the one thing the card stopped saying out loud.
    @ViewBuilder
    private func speedMetrics(_ result: ThroughputResult, _ grade: BufferbloatGrade?) -> some View {
        MetricView("down", Fmt.mbps(result.downloadMbps), unit: "Mbps")
        MetricView("up", Fmt.mbps(result.uploadMbps), unit: "Mbps")
        MetricView("bufferbloat",
                   result.bufferbloatMs.map { "+\(Fmt.msCoarse($0))" },
                   unit: "ms", tint: grade.map(Palette.grade))
    }

    /// Loss over the whole test window, then ping and jitter **under load**.
    ///
    /// Not the idle figures. Idle is the connection as it always is, and the
    /// session's own Internet card already says that over a far longer window
    /// than a ten-second lead-in — putting it here restated something the app
    /// says better elsewhere. What only a test can show is what load does to
    /// it, which for this connection is a jitter of 19.6 ms at rest and 190.2
    /// while downloading.
    ///
    /// Both come from the *same* direction — whichever loaded the connection
    /// harder, which is also the one `bufferbloatMs` is derived from — so the
    /// pair describes one moment rather than two unrelated worst cases.
    @ViewBuilder
    private func pingMetrics(_ result: ThroughputResult) -> some View {
        let latency = result.loadedLatencyMs
        let jitter = result.loadedJitterMs
        MetricView("pkt loss", Fmt.percent(result.packetLoss),
                   tint: result.packetLoss.map { $0 >= SessionVerdict.lossyLossRatio
                                                 ? Palette.bad : nil } ?? nil)
        MetricView("ping under load", Fmt.ms(latency), unit: "ms",
                   tint: latency.flatMap { Palette.latency($0, on: .internet) })
        MetricView("jitter under load", Fmt.ms(jitter), unit: "ms",
                   tint: jitter.flatMap { Palette.jitter($0) })
    }

    /// One phase. Everything but the mean is optional — results recorded before
    /// schema 4 have no spread at all, and a phase whose window caught nothing
    /// has none either, so both render "—" rather than a fabricated 0.
    private func phaseRow(_ label: String, _ latency: Double?,
                          _ jitter: Double?, _ low: Double?, _ high: Double?) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(Fmt.ms(latency))
                .foregroundStyle(latency.flatMap { Palette.latency($0, on: .internet) } ?? .primary)
            Text(Fmt.ms(jitter)).foregroundStyle(.secondary)
            Text(Fmt.ms(low)).foregroundStyle(.secondary)
            Text(Fmt.ms(high))
                .foregroundStyle(high.flatMap { Palette.latency($0, on: .internet) }
                                 .map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        }
        .font(.tabularSmall)
    }

}

// MARK: - Diagnostics

private struct NetworkDetail: View {
    let latest: DiagnosticsSnapshot?
    let trace: DiagnosticsTrace

    var body: some View {
        if let latest {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if latest.kind == .wifi {
                        DetailSection("Signal") {
                            HStack(alignment: .firstTextBaseline, spacing: Space.l) {
                                MetricView("RSSI", latest.rssi.map(String.init), unit: "dBm")
                                MetricView("SNR", latest.snr.map(String.init), unit: "dB")
                                MetricView("Tx", Fmt.mbps(latest.txRateMbps), unit: "Mbps")
                            }
                            if !chips(latest).isEmpty {
                                HStack(spacing: Space.s) {
                                    ForEach(chips(latest), id: \.self) { Chip(text: $0) }
                                }
                                .padding(.top, Space.xs)
                            }
                            signalHistory
                        }
                    }

                    changes

                    DetailSection("Interface") {
                        DetailRow(
                            label: "Device",
                            value: "\(latest.interfaceName) · \(latest.kind.rawValue)",
                            help: "The BSD device name macOS uses for this "
                                + "interface. en0 is normally the built-in "
                                + "Wi-Fi; Ethernet and adapters get higher numbers."
                        )
                        // ssid/bssid and the Ethernet link fields are
                        // permanently nil (PHASE4-NOTES), so they are not
                        // rendered as empty rows.
                        optionalRow("IP", latest.ipAddress)
                        optionalRow("Subnet", latest.subnetMask)
                        optionalRow("Gateway", latest.gateway)
                        if !latest.dnsServers.isEmpty {
                            DetailRow(label: "DNS",
                                         value: latest.dnsServers.joined(separator: ", "))
                        }
                        optionalRow("MTU", latest.mtu.map(String.init))
                    }
                }
                .padding(Space.l)
            }
        } else {
            ContentUnavailableView(
                "No diagnostics",
                systemImage: "wifi.slash",
                description: Text("Network details appear once a session is running.")
            )
        }
    }

    /// The trace, directly under the numbers it is the history of.
    @ViewBuilder
    private var signalHistory: some View {
        if trace.hasTrace {
            VStack(alignment: .leading, spacing: Space.xs) {
                RSSITrace(trace: trace)
                Text(traceCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Space.s)
        } else if trace.snapshotCount > 0 {
            // One reading is a dot, not a trace. Say which, rather than
            // drawing a chart of a single point.
            Text("\(trace.readingCount) reading so far — the trace appears once "
                 + "there are two.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, Space.s)
        }
    }

    /// Low / average / high come from every stored reading, not the drawn
    /// ones — a decimated trace keeps the worst reading per bucket, so quoting
    /// figures off the line would read low.
    private var traceCaption: String {
        var parts = [
            "low \(Fmt.msCoarse(trace.stats.min))",
            "avg \(Fmt.ms(trace.stats.mean))",
            "high \(Fmt.msCoarse(trace.stats.max)) dBm",
            "\(trace.readingCount) readings",
        ]
        if trace.isDecimated {
            parts.append("\(trace.points.count) drawn, worst per bucket")
        }
        return parts.joined(separator: " · ")
    }

    /// What the 669 rows were actually hiding: the three or four moments where
    /// this stopped being the same connection.
    @ViewBuilder
    private var changes: some View {
        if trace.snapshotCount > 0 {
            DetailSection(trace.changes.isEmpty
                          ? "Changes" : "Changes (\(trace.changes.count))") {
                if trace.changes.isEmpty {
                    Text("None — one connection for the whole session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(trace.changes.reversed()) { change in
                        DetailRow(
                            label: change.time
                                .formatted(.dateTime.hour().minute().second()),
                            value: change.summary
                        )
                    }
                }
            }
        }
    }

    private func chips(_ snapshot: DiagnosticsSnapshot) -> [String] {
        [snapshot.band,
         snapshot.phyMode,
         snapshot.channel.map { "ch \($0)" },
         snapshot.security].compactMap { $0 }
    }

    @ViewBuilder
    private func optionalRow(_ label: String, _ value: String?) -> some View {
        if let value { DetailRow(label: label, value: value) }
    }
}

// MARK: - Shared bits

/// One section treatment shared by every sheet, so they read as one surface
/// rather than four unrelated screens.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title)
                .font(.cardTitle)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var tint: Color?
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.s)
            Text(value)
                .font(.tabularSmall)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
        }
        .helpIfPresent(help)
    }
}


/// A round close control, matching the one the system puts on its own sheets.
struct CloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(hovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        // Escape already dismisses a sheet; this makes Return work too, so the
        // sheet closes on whichever key the hand reaches for first.
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Close")
        .help("Close")
    }
}

// MARK: - Traffic

/// What this Mac was sending when latency diverged.
///
/// One section per capture, busiest uploader first. The empty states carry most
/// of the meaning here and are worth reading closely — see below.
private struct TrafficDetail: View {
    let captures: [TrafficCapture]
    let isCapturing: Bool

    var body: some View {
        if captures.isEmpty {
            ContentUnavailableView(
                isCapturing ? "Capturing…" : "Nothing to show",
                systemImage: isCapturing ? "arrow.triangle.2.circlepath" : "checkmark.seal",
                description: Text(isCapturing
                    ? "Reading what this Mac is sending. Takes about five seconds."
                    : "Latency has not diverged far enough to trigger a capture. "
                      + "These are taken when the internet is slow while the router is fine.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if isCapturing {
                        Label("Capturing…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(captures) { capture in
                        section(capture)
                    }
                    footnote
                }
                .padding(Space.m)
            }
        }
    }

    @ViewBuilder
    private func section(_ capture: TrafficCapture) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(capture.timestamp, format: .dateTime.hour().minute().second())
                    .font(.headline.monospacedDigit())
                Text(trigger(capture))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(Fmt.rate(capture.uploadBytesPerSecond) + " up")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if capture.processes.isEmpty {
                // The most useful thing this sheet can say, and the one a
                // blank list would swallow. Nothing on this Mac was sending
                // while the connection was struggling, so whatever filled the
                // uplink is on another device.
                Label(
                    "Nothing on this Mac was sending. Look at another device on the network.",
                    systemImage: "questionmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ForEach(capture.processes, id: \.self) { process in
                    HStack(spacing: Space.s) {
                        Text(process.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Space.s)
                        Text(Fmt.rate(process.bytesOutPerSecond))
                            .font(.tabularSmall)
                            .foregroundStyle(process.bytesOutPerSecond > 0 ? Palette.bad : .secondary)
                            .frame(width: 90, alignment: .trailing)
                        Text(Fmt.rate(process.bytesInPerSecond))
                            .font(.tabularSmall)
                            .foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .trailing)
                    }
                }
                HStack(spacing: Space.s) {
                    Spacer(minLength: 0)
                    Text("sent").frame(width: 90, alignment: .trailing)
                    Text("received").frame(width: 90, alignment: .trailing)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(Space.s)
        .background(Palette.rowStripe, in: RoundedRectangle(cornerRadius: Radius.control))
    }

    private func trigger(_ capture: TrafficCapture) -> String {
        let internet = capture.internetMs.map { Fmt.msLabel($0) } ?? "no reply"
        let router = capture.routerMs.map { Fmt.msLabel($0) } ?? "no reply"
        return "internet \(internet) · router \(router)"
    }

    private var footnote: some View {
        Text("Rates are measured over one second, on this Mac only. "
             + "Other devices on the network do not appear here.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}
