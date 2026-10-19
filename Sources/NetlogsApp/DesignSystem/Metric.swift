import SwiftUI

/// A labelled number with an optional unit — the one component for it.
///
/// This first replaced three near-identical private `metric()` helpers that
/// were hand-copied into `ThroughputCard`, `DiagnosticsCard`, and
/// `PingStatCard`. A second one, `StatValue`, then grew up beside it in the
/// summary cards with its own label treatment and its own accessibility
/// wiring, and only that one could carry a tooltip. They are now one view at
/// three sizes. `StatValue` stays as the card-size spelling, so the card call
/// sites still read the way they did.
///
/// Missing data is `nil` (or `Fmt`'s "—"): the dash is drawn, and VoiceOver
/// says "no data" rather than reading out the punctuation.
struct MetricView: View {
    let label: String
    let value: String?
    var unit: String?
    var tint: Color?
    /// Explains the measurement on hover, and to VoiceOver as a hint. See
    /// `StatValue` for why the labels themselves stay technical.
    var help: String?
    var style: Style

    enum Style {
        /// A figure in a sheet section or on the Analysis screen.
        case standard
        /// The one or two numbers that lead a screen.
        case prominent
        /// Inside a summary card: uppercase label, tighter, never wraps.
        case compact
    }

    init(
        _ label: String,
        _ value: String?,
        unit: String? = nil,
        tint: Color? = nil,
        help: String? = nil,
        style: Style = .standard
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.tint = tint
        self.help = help
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .compact ? 1 : Space.xs) {
            labelText
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—")
                    .font(valueFont)
                    .foregroundStyle(tint ?? .primary)
                if let unit {
                    Text(unit)
                        .font(style == .compact ? .caption2 : .metricLabel)
                        .foregroundStyle(style == .compact
                                         ? AnyShapeStyle(.tertiary)
                                         : AnyShapeStyle(.secondary))
                }
            }
        }
        // A card's values are laid out side by side and must never wrap or
        // truncate: a clipped "12" reads as a different number.
        .fixedSize(horizontal: style == .compact, vertical: style == .compact)
        .helpIfPresent(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(spokenValue))
        .accessibilityHint(Text(help ?? ""))
    }

    @ViewBuilder
    private var labelText: some View {
        switch style {
        case .compact:
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
        case .standard, .prominent:
            Text(label)
                .font(.metricLabel)
                .foregroundStyle(.secondary)
        }
    }

    private var valueFont: Font {
        switch style {
        // 14pt rather than title3's 15. A point sounds like nothing, but it
        // comes off four values in each card and pulls the pair's combined
        // minimum under a common window width, which is what decides whether
        // they sit together.
        case .compact:   return .system(size: 14, weight: .medium).monospacedDigit()
        case .standard:  return .metricValue
        case .prominent: return .metricValueLarge
        }
    }

    /// "12.3 ms", or "no data" for a missing figure — never "em dash".
    private var spokenValue: String {
        guard let value, value != "—" else { return "no data" }
        guard let unit else { return value }
        return "\(value) \(unit)"
    }
}

extension MetricView {
    /// Milliseconds, or an em dash when there is nothing to show yet.
    init(_ label: String, ms: Double?, tint: Color? = nil, help: String? = nil,
         style: Style = .standard) {
        self.init(
            label,
            ms.map { Fmt.ms($0) },
            unit: ms == nil ? nil : "ms",
            tint: tint,
            help: help,
            style: style
        )
    }
}

/// A labelled number inside a summary card. The label is small and quiet; the
/// number is the thing.
///
/// `help` is what lets the labels stay technical. RSSI, SNR and bufferbloat are
/// the real names for these measurements, and someone diagnosing a connection
/// will want to search for them or quote them to an ISP — renaming them to
/// "signal" and "noise margin" made the app friendlier and less useful at the
/// same time. The term stays; hovering explains it.
///
/// The card-size spelling of ``MetricView``; it draws nothing of its own.
struct StatValue: View {
    let label: String
    let value: String
    var unit: String?
    var tint: Color?
    var help: String?

    var body: some View {
        MetricView(label, value, unit: unit, tint: tint, help: help, style: .compact)
    }
}
