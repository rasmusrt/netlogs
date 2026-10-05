import SwiftUI
import Charts
import NetlogsCore

/// One bar per session: when it ran, and the band its latency sat in.
///
/// The bar's width is the session's real extent, so an overnight run is wide
/// and a coffee-break check is narrow, and **nothing is drawn between them** —
/// sessions do not tile time, and a line across the gaps would assert
/// measurements never made.
struct SessionSpreadChart: View {
    let spread: SessionSpread
    var height: CGFloat = 150
    var onSelect: ((UUID) -> Void)?

    @State private var hovered: SpreadMark?

    private static let bandKey = "band"
    private static let peakKey = "peak"
    private static let coveredKey = "covered"
    private static let underCoveredKey = "under-covered"

    var body: some View {
        Chart {
            bands
            peaks
            coverage
        }
        .chartForegroundStyleScale([
            Self.bandKey: Palette.Chart.internet.opacity(Palette.Chart.envelopeOpacity + 0.15),
            Self.peakKey: Palette.Chart.internet,
            Self.coveredKey: Palette.Chart.internet.opacity(0.5),
            Self.underCoveredKey: Palette.bad.opacity(0.6),
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: spread.xDomain)
        .chartYScale(domain: spread.yDomain)
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
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine().foregroundStyle(.separator.opacity(0.35))
                AxisValueLabel(format: .dateTime.month().day())
                    .font(.caption2)
            }
        }
        .chartYAxisLabel("ms", position: .leading)
        .transaction { $0.animation = nil }
        .frame(height: height)
        .overlay(alignment: .topLeading) { readout }
        .accessibilityLabel("Latency by session")
        .accessibilityValue("\(spread.marks.count) sessions")
    }

    /// p50 to p95. A min–max band would be a full-height smear set by one
    /// outlier — one real session has a 1,062 ms maximum against a 42 ms mean.
    @ChartContentBuilder
    private var bands: some ChartContent {
        ForEach(spread.marks) { mark in
            RectangleMark(
                xStart: .value("From", mark.start),
                xEnd: .value("To", mark.drawnEnd),
                yStart: .value("p50", mark.low),
                yEnd: .value("p95", mark.high)
            )
            .foregroundStyle(by: .value("Part", Self.bandKey))
            .opacity(mark.isWithheld ? 0.35 : 1)
        }
    }

    /// A hairline at p99, so the tail is visible without letting it set the
    /// band's height.
    @ChartContentBuilder
    private var peaks: some ChartContent {
        ForEach(spread.marks) { mark in
            RectangleMark(
                xStart: .value("From", mark.start),
                xEnd: .value("To", mark.drawnEnd),
                yStart: .value("p99", mark.peak),
                yEnd: .value("p99", mark.peak + spread.yDomain.upperBound * 0.006)
            )
            .foregroundStyle(by: .value("Part", Self.peakKey))
            .opacity(mark.isWithheld ? 0.35 : 0.8)
        }
    }

    /// Coverage, inside the chart rather than as a rail beneath it.
    ///
    /// It began as an `HStack` of equal segments under the plot, which drew a
    /// continuous bar across a time axis and so implied the week had been
    /// measured end to end — the precise claim the gaps above it exist to
    /// deny. Sharing the x scale is the only way it can be honest.
    @ChartContentBuilder
    private var coverage: some ChartContent {
        ForEach(spread.marks) { mark in
            RectangleMark(
                xStart: .value("From", mark.start),
                xEnd: .value("To", mark.drawnEnd),
                yStart: .value("Base", 0),
                yEnd: .value("Coverage", spread.yDomain.upperBound * 0.03)
            )
            .foregroundStyle(by: .value("Part", mark.coverage < Scoring.coverageFloor
                                        ? Self.underCoveredKey : Self.coveredKey))
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let hovered {
            Text(summary(hovered))
                .font(.caption2)
                .monospacedDigit()
                .padding(.horizontal, Space.s)
                .padding(.vertical, 3)
                .background(.background, in: Capsule())
                .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
                .padding(Space.s)
        }
    }

    private func summary(_ mark: SpreadMark) -> String {
        let when = mark.start.formatted(.dateTime.month().day().hour().minute())
        let band = "\(Fmt.msCoarse(mark.low))–\(Fmt.msCoarse(mark.high)) ms"
        return mark.isWithheld
            ? "\(when) · \(band) · withheld"
            : "\(when) · \(band) · p99 \(Fmt.msCoarse(mark.peak))"
    }
}
