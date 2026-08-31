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

            NetworkCard(snapshot: diagnostics)
                .tappable(.network, onSelect)
        }
    }

    private var routerCard: some View {
        LatencyCard(title: "Router", host: routerHost,
                    stat: latency.router,
                    systemImage: "wifi.router", help: Explain.routerCard)
            .tappable(.latency, onSelect)
    }

    private var internetCard: some View {
        LatencyCard(title: "Internet", host: internetHost,
                    stat: latency.internet,
                    systemImage: "globe", help: Explain.internetCard)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
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
    let systemImage: String
    let help: String

    var body: some View {
        SummaryCard(title: title, systemImage: systemImage, subtitle: host,
                    help: help) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                // Min green, max red — the simplest honest mapping, and the one
                // the prototype used. Average stays neutral so the two ends of
                // the range are what the eye lands on.
                StatValue(label: "min", value: number(stat.min), unit: "ms",
                          tint: stat.samples == 0 ? nil : Palette.good,
                          help: Explain.minimum)
                StatValue(label: "avg", value: number(stat.avg), unit: "ms",
                          help: Explain.average)
                StatValue(label: "max", value: number(stat.max), unit: "ms",
                          tint: stat.samples == 0 ? nil : Palette.latency(stat.max) ?? .primary,
                          help: Explain.maximum)
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
    private var shown: (down: Double, up: Double, bloat: Double,
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
                let grade = BufferbloatGrade(milliseconds: values.bloat)
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
    private func speedStats(_ values: (down: Double, up: Double, bloat: Double,
                                       ping: Double?, jitter: Double?, loss: Double?),
                            _ grade: BufferbloatGrade) -> some View {
        StatValue(label: "download", value: Fmt.mbps(values.down),
                  unit: "Mbps", tint: Palette.good,
                  help: Explain.download)
        StatValue(label: "upload", value: Fmt.mbps(values.up),
                  unit: "Mbps", tint: Palette.Chart.internet,
                  help: Explain.upload)
        StatValue(label: "bufferbloat",
                  value: "+\(Fmt.msCoarse(values.bloat))", unit: "ms",
                  tint: Palette.grade(grade),
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
    private func pingStats(_ values: (down: Double, up: Double, bloat: Double,
                                      ping: Double?, jitter: Double?, loss: Double?)) -> some View {
        // "avg ping", not "ping under load": every figure on this card is an
        // average now, and the long labels pushed the row to two lines at any
        // window width. Which load they describe is in the tooltip.
        StatValue(label: "avg ping", value: Fmt.ms(values.ping),
                  unit: "ms", tint: values.ping.flatMap { Palette.latency($0) },
                  help: Explain.testAverage)
        StatValue(label: "avg jitter", value: Fmt.ms(values.jitter),
                  unit: "ms", tint: values.jitter.flatMap { Palette.latency($0) },
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
