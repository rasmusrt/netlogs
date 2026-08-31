import SwiftUI

/// A labelled number with an optional unit.
///
/// This replaces three near-identical private `metric()` helpers that were
/// hand-copied into `ThroughputCard`, `DiagnosticsCard`, and `PingStatCard`,
/// and had already drifted apart in spacing and font.
struct MetricView: View {
    let label: String
    let value: String?
    var unit: String?
    var tint: Color?
    var prominent = false

    init(
        _ label: String,
        _ value: String?,
        unit: String? = nil,
        tint: Color? = nil,
        prominent: Bool = false
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.tint = tint
        self.prominent = prominent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label)
                .font(.metricLabel)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—")
                    .font(prominent ? .metricValueLarge : .metricValue)
                    .foregroundStyle(tint ?? .primary)
                if let unit {
                    Text(unit)
                        .font(.metricLabel)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value.map { "\($0) \(unit ?? "")" } ?? "no data"))
    }
}

extension MetricView {
    /// Milliseconds, or an em dash when there is nothing to show yet.
    init(_ label: String, ms: Double?, tint: Color? = nil, prominent: Bool = false) {
        self.init(
            label,
            ms.map { Fmt.ms($0) },
            unit: ms == nil ? nil : "ms",
            tint: tint,
            prominent: prominent
        )
    }
}
