import SwiftUI
import NetlogsCore

/// The summary cards.
///
/// Full-width stacked rows rather than a column of equal cards. Three reasons,
/// all learned from looking at the thing on a real screen:
///
/// - A row reflows. Columns don't: at quarter-screen width a three-column strip
///   either wraps ragged or squeezes numbers until they truncate.
/// - It matches how the numbers are actually read — one subject per line, left
///   to right — instead of asking the eye to compare across columns.
/// - It leaves the vertical rhythm free for the log, which is what people
///   actually watch.
///
/// Labels are small uppercase and values are large; colour is used sparingly
/// and only where it means something (min good, max bad, signal quality).
struct SummaryCards: View {
    let latency: LiveSummary
    let routerHost: String
    let internetHost: String
    let throughput: ThroughputAverages
    let diagnostics: DiagnosticsSnapshot?
    /// What this Mac was sending during the session's latency episodes. Empty
    /// on a healthy session, which is most of them — see `trafficCard`.
    var traffic: [TrafficCapture] = []
    var isCapturingTraffic = false
    /// The gateway card appears only for a session that read the gateway, so a
    /// Mac without a UniFi gateway never sees an empty one.
    var showsGateway = false
    var gatewayRadio: CellularRadio?
    /// Why the latest gateway poll failed, if it did.
    var gatewayProblem: String?
    var isTesting = false
    var testingPhase: LoadPhase = .idle
    var onRunTest: (() -> Void)?
    var onSelect: ((SessionSheet) -> Void)?


    var body: some View {
        VStack(spacing: Space.xs + 2) {
            // Side by side, because the comparison between the two *is* the
            // diagnostic act — "the LAN is fine, the ISP isn't". Stacked when
            // there isn't room for both.
            //
            // `ViewThatFits` rather than measuring the width ourselves. I tried
            // the measured version for performance — ViewThatFits has to build
            // every candidate to measure it — and it was simply wrong: inside a
            // `ScrollView` the content is free to be wider than the viewport,
            // so the layout measured its own intrinsic width, concluded it had
            // room, and stayed side by side at every window size. That made the
            // detail column's minimum width exceed the window, and
            // `NavigationSplitView` paid for it by clipping the sidebar — which
            // is what "the sidebar breaks when you resize" actually was.
            //
            // ViewThatFits *proposes* the real available width to each
            // candidate instead of asking the content how big it would like to
            // be, which is the distinction that matters here.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xs + 2) {
                    routerCard.frame(minWidth: 250)
                    internetCard.frame(minWidth: 250)
                }
                VStack(spacing: Space.xs + 2) {
                    routerCard
                    internetCard
                }
            }

            ThroughputCard(averages: throughput,
                           isTesting: isTesting, phase: testingPhase, onRun: onRunTest)
                .tappable(.throughput, onSelect)

            // The local link and the WAN beside each other when the gateway is
            // being read — the same "which side of the router" comparison as
            // the latency pair above, one level down. Same `ViewThatFits`, for
            // the same reason.
            if showsGateway {
                ViewThatFits(in: .horizontal) {
                    // Equal heights: the two cards hold different rows, and a
                    // pair of mismatched boxes reads as a layout bug.
                    HStack(spacing: Space.xs + 2) {
                        networkCard.frame(minWidth: 250)
                        gatewayCard.frame(minWidth: 250)
                    }
                    .environment(\.cardFillsHeight, true)
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: Space.xs + 2) {
                        networkCard
                        gatewayCard
                    }
                }
            } else {
                networkCard
            }

            trafficCard
        }
    }

    /// Present only when there is something to say.
    ///
    /// Unlike the other four this card is *conditional*, and deliberately so. A
    /// healthy session never triggers a capture, so a permanent card would sit
    /// empty through every good night — teaching the eye to skip the one place
    /// that will eventually hold the answer. It is the same argument as the
    /// sidebar's status dot: absence is the signal.
    @ViewBuilder
    private var trafficCard: some View {
        if !traffic.isEmpty || isCapturingTraffic {
            TrafficCard(captures: traffic, isCapturing: isCapturingTraffic)
                .tappable(.traffic, onSelect)
        }
    }

    private var networkCard: some View {
        NetworkCard(snapshot: diagnostics)
            .tappable(.network, onSelect)
    }

    private var gatewayCard: some View {
        GatewayCard(radio: gatewayRadio, problem: gatewayProblem)
            .tappable(.gateway, onSelect)
    }

    private var routerCard: some View {
        LatencyCard(title: "Router", host: routerHost,
                    stat: latency.router, late: latency.routerLate,
                    systemImage: "wifi.router", help: Explain.routerCard,
                    ramp: .gateway)
            .tappable(.latency, onSelect)
    }

    private var internetCard: some View {
        LatencyCard(title: "Internet", host: internetHost,
                    stat: latency.internet, late: latency.internetLate,
                    systemImage: "globe", help: Explain.internetCard,
                    ramp: .internet)
            .tappable(.latency, onSelect)
    }
}

// MARK: - Container

/// One full-width card: icon, uppercase title, optional subtitle, a chevron
/// when it leads somewhere, and a row of values underneath.
struct SummaryCard<Content: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    var accessory: AnyView?
    var showsChevron = true
    /// Explains what the card measures. Attached to the title row, which is the
    /// part you hover when you are asking "what is this card?".
    var help: String?
    @ViewBuilder var content: Content
    @Environment(\.cardFillsHeight) private var fillsHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                    .helpIfPresent(help)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.s)
                accessory
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.quaternary)
                }
            }
            content
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s + 2)
        .frame(maxWidth: .infinity,
               maxHeight: fillsHeight ? .infinity : nil,
               alignment: .topLeading)
        .cardSurface()
    }
}

/// Set on a row of cards that should share one height. The surface is drawn
/// inside the card, so stretching the card from outside would stretch an
/// invisible frame and leave the backgrounds at their own heights.
private struct CardFillsHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cardFillsHeight: Bool {
        get { self[CardFillsHeightKey.self] }
        set { self[CardFillsHeightKey.self] = newValue }
    }
}

/// A labelled number. The label is small and quiet; the number is the thing.
///
/// `help` is what lets the labels stay technical. RSSI, SNR and bufferbloat are
/// the real names for these measurements, and someone diagnosing a connection
/// will want to search for them or quote them to an ISP — renaming them to
/// "signal" and "noise margin" made the app friendlier and less useful at the
/// same time. The term stays; hovering explains it.
struct StatValue: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color?
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    // 14pt rather than title3's 15. A point sounds like
                    // nothing, but it comes off four values in each card and
                    // pulls the pair's combined minimum under a common window
                    // width, which is what decides whether they sit together.
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint ?? .primary)
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .fixedSize()
        .helpIfPresent(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(value) \(unit ?? "")"))
        .accessibilityHint(Text(help ?? ""))
    }
}

/// The tooltip copy, in one place so the wording stays consistent between the
/// summary cards and the inspector.
enum Explain {
    // Plain concatenated strings rather than a `"""` block with trailing
    // backslashes: the continuation form kept the continuation line's leading
    // spaces, so the rendered tooltip read "busy,    caused by".
    static let rssi =
        "RSSI — received signal strength, in dBm. Closer to zero is better: "
        + "−60 is strong, −70 usable, −80 and below starts dropping packets."

    static let snr =
        "SNR — how far the signal rises above background radio noise, in dB. "
        + "Above 25 is comfortable; below 15 the radio starts retransmitting."

    static let txRate =
        "The rate negotiated with the access point, in Mbps. This is the "
        + "ceiling for the Wi-Fi link itself, not your internet speed."

    static let bufferbloat =
        "Bufferbloat — how far latency climbs while the connection is busy, "
        + "caused by oversized queues holding packets instead of dropping "
        + "them. Under 30 ms is excellent; over 300 ms makes calls and games "
        + "feel broken even on a fast line."

    static let testAverage =
        "Round trip to the internet host while the test was loading the "
        + "connection — the heavier of the two directions. The idle figure is "
        + "not shown here: it is the connection as it always is, which the "
        + "Internet card already reports over the whole session."

    static let testJitter =
        "Variation in round-trip time under that same load: the mean "
        + "difference between one reply and the next. This is usually where a "
        + "connection falls apart — jitter can rise tenfold under load while "
        + "the average barely moves, and it is jitter that breaks calls."

    static let packetLoss =
        "The share of pings that got no reply while this speed test ran. "
        + "Above about 2% is audible in calls and visible in video."

    static let jitter =
        "Jitter — the average change in round-trip time from one ping to the "
        + "next. For calls, steady latency matters more than low latency."

    static let p50 =
        "The median (p50). Half of all replies were faster than this, half "
        + "slower — the typical ping, and steadier than an average, which one "
        + "bad spike can drag upwards."

    static let p95 =
        "The 95th percentile (p95). One reply in twenty was slower than this. "
        + "At one ping a second that is about three times a minute — the bad "
        + "moments you actually notice, rather than the single worst sample."

    static let p99 =
        "The 99th percentile (p99). One reply in a hundred was slower than "
        + "this. The gap between it and the typical figure is how ugly the "
        + "rare moments get."

    static let minimum =
        "The fastest reply in the session — roughly the best this path can do "
        + "when nothing is in the way."

    static let average =
        "Mean round-trip time across every reply. Compare the router's average "
        + "with the internet's: the gap between them is what your connection "
        + "adds beyond your own network."

    static let maximum =
        "The single slowest reply. One bad sample, not a trend — the p95 in the "
        + "Latency sheet is the better measure of the bad moments."

    /// Shown instead of `maximum` when the peak is a reply that came back after
    /// the ping timeout.
    ///
    /// Without this the figure is a ceiling, not a measurement: a reply that
    /// misses the deadline used to be discarded, so "max" could never exceed
    /// the timeout no matter how bad the link got. A session that peaked at
    /// 2.4 s reported a 1.9 s maximum and called the rest packet loss.
    static let trafficCard =
        "Taken automatically when the internet goes slow while the router stays "
        + "fast — the moment worth knowing what this Mac was sending. It sees "
        + "this Mac only: if the uploader is a NAS, a phone or a TV, this card "
        + "will correctly show nothing, and that is itself the answer."

    static let maximumLate =
        "The slowest reply of the session — and it came back after the ping "
        + "timeout, so it counts as a missed deadline as well. A number above "
        + "the timeout means the reply arrived; it was just late."

    static let routerCard =
        "Your own router, the first hop out of this Mac. It measures your local "
        + "network only. If this is slow, the problem is inside your home."

    static let internetCard =
        "A host out on the internet, past your router. Read it against the "
        + "router card: both slow points at your own network, this one slow "
        + "alone points at your connection or your ISP."

    static let download = "Measured by pulling data from Cloudflare's speed endpoint."
    static let upload = "Measured by pushing data to Cloudflare's speed endpoint."
}


// MARK: - Cards

struct LatencyCard: View {
    let title: String
    let host: String
    let stat: PingStat
    /// Replies that came back after the deadline. `PingStat.max` is clipped at
    /// the ping timeout by construction, so on a session with any of these it
    /// is not the slowest reply — it is the slowest reply *that fitted*.
    var late: LateReplies = .init()
    let systemImage: String
    let help: String
    /// The two cards sit one above the other and are read against each other,
    /// which only works if each is judged on its own leg's thresholds.
    let ramp: LatencyGrade.Ramp

    /// The slowest reply actually observed, late ones included.
    private var peak: Double { late.worst(timelyMax: stat.max) }
    /// …and whether the figure on screen is one of those, which changes what
    /// the number means enough to be worth saying in the label.
    private var peakIsLate: Bool { (late.max ?? 0) > stat.max }

    var body: some View {
        SummaryCard(title: title, systemImage: systemImage, subtitle: host,
                    help: help) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                // Min green *when it deserves it*, max red — the two ends of
                // the range are what the eye lands on, so the average stays
                // neutral. Min was hardcoded to green, which made a session
                // whose best ping was 900 ms show a green floor beside a red
                // ceiling: the one figure that cannot lie about a connection
                // being fine, lying about it.
                StatValue(label: "min", value: number(stat.min), unit: "ms",
                          tint: stat.samples == 0 ? nil : Palette.pill(stat.min, on: ramp),
                          help: Explain.minimum)
                StatValue(label: "avg", value: number(stat.avg), unit: "ms",
                          help: Explain.average)
                StatValue(label: peakIsLate ? "max (late)" : "max",
                          value: number(peak), unit: "ms",
                          tint: stat.samples == 0 ? nil : Palette.latency(peak, on: ramp) ?? .primary,
                          help: peakIsLate ? Explain.maximumLate : Explain.maximum)
                StatValue(label: "jitter", value: number(stat.jitter), unit: "ms",
                          help: Explain.jitter)
                Spacer(minLength: 0)
            }
        }
    }

    private func number(_ ms: Double) -> String {
        stat.samples == 0 ? "—" : Fmt.ms(ms)
    }
}

struct ThroughputCard: View {
    let averages: ThroughputAverages
    var isTesting = false
    var phase: LoadPhase = .idle
    var onRun: (() -> Void)?

    private var hasData: Bool { averages.count > 0 }

    /// Every figure is an average across the session's tests, at any count.
    /// The card is read as a summary of the session, and a card that silently
    /// switched between an average and one test's numbers was harder to trust
    /// than a thin average that says how thin it is — the subtitle carries the
    /// count, and the sheet lists every run for anyone who wants a specific one.
    private var shown: (down: Double, up: Double, bloat: Double?,
                        ping: Double?, jitter: Double?, loss: Double?) {
        (averages.downloadMbps, averages.uploadMbps, averages.bufferbloatMs,
         averages.loadedLatencyMs, averages.loadedJitterMs, averages.packetLoss)
    }

    /// Loss measured while the test ran, not across the whole session. The
    /// session-wide figure meant this card could report 100% loss beside 383
    /// Mbps of download, because a dead router host counted every sample as a
    /// failure.
    private func lossIsWorthReporting(_ fraction: Double?) -> Bool {
        guard let fraction else { return false }
        return fraction >= SessionVerdict.lossyLossRatio
    }

    var body: some View {
        SummaryCard(title: "Speed", systemImage: "speedometer",
                    subtitle: hasData ? label : nil,
                    accessory: runButton) {
            if hasData {
                let values = shown
                let grade = values.bloat.map { BufferbloatGrade(milliseconds: $0) }
                // Six stats do not fit the card at a narrow window, so they
                // fall to two rows rather than truncating. `fixedSize` goes on
                // each candidate, not on the `ViewThatFits`: a candidate
                // holding a `Spacer` is greedy and always "fits", which makes
                // the whole mechanism a no-op (the same trap documented in
                // `SessionVerdictHeader`).
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        speedStats(values, grade)
                        pingStats(values)
                    }
                    .fixedSize()

                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                            speedStats(values, grade)
                        }
                        .fixedSize()
                        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                            pingStats(values)
                        }
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(isTesting ? "\(phase.rawValue.capitalized)…" : "No speed test yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func speedStats(_ values: (down: Double, up: Double, bloat: Double?,
                                       ping: Double?, jitter: Double?, loss: Double?),
                            _ grade: BufferbloatGrade?) -> some View {
        StatValue(label: "download", value: Fmt.mbps(values.down),
                  unit: "Mbps", tint: Palette.good,
                  help: Explain.download)
        StatValue(label: "upload", value: Fmt.mbps(values.up),
                  unit: "Mbps", tint: Palette.Chart.internet,
                  help: Explain.upload)
        StatValue(label: "bufferbloat",
                  value: values.bloat.map { "+\(Fmt.msCoarse($0))" } ?? "—", unit: "ms",
                  tint: grade.map(Palette.grade),
                  help: Explain.bufferbloat)
        // Tinted on the same rule the verdict uses, so the card can't shout an
        // orange 2.8% (one drop in thirty-six) while the header says the
        // connection is healthy.
        StatValue(label: "pkt loss", value: Fmt.percent(values.loss),
                  tint: lossIsWorthReporting(values.loss) ? Palette.bad : nil,
                  help: Explain.packetLoss)
    }

    /// Latency and jitter measured *under load*, from the ping stream tagged by
    /// load phase — not the session-wide average, and no longer the test's idle
    /// lead-in either.
    ///
    /// These deliberately differ from the Internet card. That card pings a host
    /// you chose, over the whole session; this one describes the connection at
    /// the moment this test ran. Making them agree, as an earlier version did,
    /// only made this pair meaningless — and showing the *idle* figures here,
    /// as a later one did, made them agree by another route: idle is the
    /// connection as it always is, which is exactly what the Internet card
    /// already says, over hours instead of a ten-second lead-in.
    @ViewBuilder
    private func pingStats(_ values: (down: Double, up: Double, bloat: Double?,
                                      ping: Double?, jitter: Double?, loss: Double?)) -> some View {
        // "avg ping", not "ping under load": every figure on this card is an
        // average now, and the long labels pushed the row to two lines at any
        // window width. Which load they describe is in the tooltip.
        StatValue(label: "avg ping", value: Fmt.ms(values.ping),
                  unit: "ms", tint: values.ping.flatMap { Palette.latency($0, on: .internet) },
                  help: Explain.testAverage)
        StatValue(label: "avg jitter", value: Fmt.ms(values.jitter),
                  unit: "ms", tint: values.jitter.flatMap { Palette.jitter($0) },
                  help: Explain.testJitter)
    }

    private var label: String {
        "average of \(averages.count) test\(averages.count == 1 ? "" : "s")"
    }

    private var runButton: AnyView? {
        guard let onRun else { return nil }
        return AnyView(
            Button(isTesting ? "Testing…" : "Test now", action: onRun)
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(isTesting)
        )
    }
}

/// The WAN as the gateway reports it: the 5G radio's headline figures, and
/// the way into the Gateway sheet's chart.
struct GatewayCard: View {
    let radio: CellularRadio?
    let problem: String?

    var body: some View {
        SummaryCard(title: "Gateway", systemImage: "antenna.radiowaves.left.and.right",
                    subtitle: problem,
                    accessory: radio.map { r in
                        AnyView(Chip(text: [r.technology, r.band].compactMap { $0 }
                                        .joined(separator: " · ")))
                    }) {
            if let radio {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    StatValue(label: "SINR", value: Self.db(radio.nrSINR ?? radio.lteSINR),
                              unit: "dB")
                    StatValue(label: "RSRP", value: Self.db(radio.nrRSRP ?? radio.lteRSRP),
                              unit: "dBm")
                    StatValue(label: "Cell", value: radio.cellID.map(String.init) ?? "—")
                    Spacer(minLength: 0)
                }
            } else {
                Text(problem == nil ? "Waiting for the gateway…" : "No radio readings")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func db(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }
}

struct NetworkCard: View {
    let snapshot: DiagnosticsSnapshot?

    var body: some View {
        SummaryCard(title: "Network", systemImage: icon,
                    subtitle: snapshot?.ipAddress,
                    accessory: kindChip) {
            if let snapshot, snapshot.kind == .wifi {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    StatValue(label: "RSSI", value: snapshot.rssi.map(String.init) ?? "—",
                              unit: "dBm", tint: snapshot.rssi.flatMap(Self.rssiTint),
                              help: Explain.rssi)
                    StatValue(label: "SNR", value: snapshot.snr.map(String.init) ?? "—",
                              unit: "dB", tint: snapshot.snr.flatMap(Self.snrTint),
                              help: Explain.snr)
                    StatValue(label: "TX rate", value: Fmt.mbps(snapshot.txRateMbps),
                              unit: "Mbps", help: Explain.txRate)
                    Spacer(minLength: 0)
                }
            } else if let snapshot {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    StatValue(label: "gateway", value: snapshot.gateway ?? "—")
                    StatValue(label: "MTU", value: snapshot.mtu.map(String.init) ?? "—")
                    Spacer(minLength: 0)
                }
            } else {
                Text("Waiting for the first reading…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var icon: String {
        switch snapshot?.kind {
        case .ethernet: return "cable.connector"
        case .wifi, .none: return "wifi"
        case .other: return "network"
        }
    }

    private var kindChip: AnyView? {
        guard let snapshot else { return nil }
        let name: String
        switch snapshot.kind {
        case .wifi: name = snapshot.band.map { "Wi-Fi · \($0)" } ?? "Wi-Fi"
        case .ethernet: name = "Ethernet"
        case .other: name = "Network"
        }
        return AnyView(Chip(text: name))
    }

    /// Wi-Fi signal, in the terms the Wi-Fi menu uses: −60 and better is a
    /// strong link, −70 is usable, −80 is trouble.
    static func rssiTint(_ dBm: Int) -> Color? {
        switch dBm {
        case (-60)...:  return Palette.good
        case (-70)...:  return Palette.warn
        case (-80)...:  return Palette.bad
        default:        return Palette.critical
        }
    }

    static func snrTint(_ dB: Int) -> Color? {
        switch dB {
        case 25...: return Palette.good
        case 15...: return Palette.warn
        default:    return Palette.bad
        }
    }
}

// MARK: - Affordance

private extension View {
    func tappable(_ sheet: SessionSheet, _ onSelect: ((SessionSheet) -> Void)?) -> some View {
        modifier(TappableCard(sheet: sheet, onSelect: onSelect))
    }
}

/// Hover feedback for a card that opens a sheet. Without it a row of identical
/// cards hides its destinations completely.
private struct TappableCard: ViewModifier {
    let sheet: SessionSheet
    let onSelect: ((SessionSheet) -> Void)?
    @State private var hovering = false

    func body(content: Content) -> some View {
        if let onSelect {
            content
                .contentShape(Rectangle())
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.tint.opacity(hovering ? 0.55 : 0), lineWidth: 1)
                }
                .onHover { hovering = $0 }
                .onTapGesture { onSelect(sheet) }
                // No `.pointerStyle` here. It installs a tracking area across
                // the whole card, which swallowed the `.help` tooltips on the
                // values inside it — the hover ring still appeared, so the card
                // looked alive while every explanation had gone silent.
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }
}

/// The one empty-state treatment used inside a card or inspector section.
struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What this Mac was sending when the connection last went bad.
///
/// The headline is the busiest uploader, because that is the answer the card
/// exists to give. When there wasn't one, the headline says so in words rather
/// than showing a dash — "nothing on this Mac" is a finding, not a blank.
struct TrafficCard: View {
    let captures: [TrafficCapture]
    var isCapturing = false

    var body: some View {
        SummaryCard(title: "Traffic", systemImage: "arrow.up.arrow.down",
                    subtitle: subtitle, help: Explain.trafficCard) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                if let latest = captures.first {
                    if let top = latest.topUploader {
                        StatValue(label: "top uploader", value: top.name, unit: "",
                                  help: Explain.trafficCard)
                        StatValue(label: "sending", value: Fmt.rate(top.bytesOutPerSecond),
                                  unit: "", tint: Palette.bad, help: Explain.trafficCard)
                    } else {
                        Text("Nothing on this Mac was sending — look at another device.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if isCapturing {
                    Text("Capturing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var subtitle: String {
        let n = captures.count
        if n == 0 { return "during a latency episode" }
        return "\(n) capture\(n == 1 ? "" : "s") during latency episodes"
    }
}
