import SwiftUI
import Charts
import NetlogsCore

/// Median latency by hour of day, for one target.
///
/// An hour that was never measured is drawn as an **empty slot with a
/// hairline**, never as a zero-height bar — a bar at zero would read as a fast
/// hour, which is the same lie as storing an unmeasured figure as 0.
///
/// Hours below the evidence bar are drawn faintly rather than omitted: they are
/// measurements, just not enough of them to claim a pattern from.
struct HourOfDayChart: View {
    let profile: HourOfDayProfile
    let host: String
    var height: CGFloat = 130

    private static let strongKey = "enough days"
    private static let thinKey = "too few days"
    private static let noneKey = "not measured"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Chart {
                // Every hour is a bar on a *categorical* x scale. A continuous
                // scale cannot give Charts a band to size a bar against, and
                // the bars silently rendered at no width — leaving only the
                // marks for unmeasured hours on screen, which said the exact
                // opposite of the truth.
                ForEach(profile.hours) { hour in
                    BarMark(
                        x: .value("Hour", label(hour.hour)),
                        y: .value("Median", hour.median ?? unmeasuredHeight),
                        width: .ratio(0.72)
                    )
                    .foregroundStyle(by: .value("Evidence", key(hour)))
                }
                if let baseline = profile.overallMedian {
                    RuleMark(y: .value("Typical", baseline))
                        .foregroundStyle(.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 1) {
                            Text("typical")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartForegroundStyleScale([
                Self.strongKey: Palette.Chart.internet,
                Self.thinKey: Palette.Chart.internet.opacity(0.35),
                // A stub on the baseline, not a zero-height bar: an hour never
                // measured must not read as a fast hour.
                Self.noneKey: Color.secondary.opacity(0.25),
            ])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18, 23].map(label)) { value in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.35))
                    AxisValueLabel {
                        if let hour = value.as(String.self) {
                            Text(hour).font(.caption2)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.separator.opacity(0.5))
                    AxisValueLabel {
                        if let ms = value.as(Double.self) {
                            Text(Fmt.msCoarse(ms)).font(.caption2).monospacedDigit()
                        }
                    }
                }
            }
            .chartYAxisLabel("ms", position: .leading)
            .transaction { $0.animation = nil }
            .frame(height: height)

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func label(_ hour: Int) -> String { String(format: "%02d", hour) }

    /// Just enough to be visible on the baseline.
    private var unmeasuredHeight: Double {
        (profile.measuredHours.compactMap(\.median).max() ?? 10) * 0.02
    }

    private func key(_ hour: HourProfile) -> String {
        guard hour.samples > 0 else { return Self.noneKey }
        return hour.days >= HourOfDayProfile.minimumDays ? Self.strongKey : Self.thinKey
    }

    /// Says why nothing is being claimed, which is itself informative — an
    /// unexplained flat panel invites the eye to invent a trend.
    private var caption: String {
        let qualifying = profile.qualifying.count
        let measured = profile.measuredHours.count
        if qualifying == 0 {
            let best = profile.measuredHours.map(\.days).max() ?? 0
            return "\(host): no hour has enough days behind it to claim a pattern "
                + "(needs \(HourOfDayProfile.minimumDays); the best has \(best)). "
                + "Faint bars are hours measured on fewer days."
        }
        return "\(host): \(measured) hours measured, \(qualifying) with at least "
            + "\(HourOfDayProfile.minimumDays) days behind them. Faint bars have fewer."
    }
}
