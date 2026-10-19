import SwiftUI
import NetlogsCore

/// Typical latency per weekday and hour: darker is slower, striped is never
/// measured.
///
/// Replaces the hour-of-day bars. Those averaged every weekday into one
/// evening, so "Sunday nights are bad" could not show; this keeps the weekday
/// and lets a block of slow hours be seen as a block. A cell is a measurement,
/// not a pattern — thin cells are drawn faintly and the readout says how many
/// days a cell comes from.
struct WeekHourHeatmap: View {
    let grid: WeekHourGrid

    @State private var hovered: Int?

    private static let low = Color.orange.opacity(0.12)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Time of day")
                .font(.headline)
            Text("Typical latency per weekday and hour. Darker is slower; striped means not measured.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { weekday in
                    HStack(spacing: 2) {
                        Text(WeekHourGrid.weekdaySymbols[weekday])
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            cell(grid.cell(weekday: weekday, hour: hour))
                        }
                    }
                }
                HStack(spacing: 2) {
                    Color.clear.frame(width: 28, height: 1)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour.isMultiple(of: 6) ? String(format: "%02d", hour) : "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, Space.xs)
            .onHover { inside in if !inside { hovered = nil } }

            legend
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(hovered == nil ? .secondary : .primary)
                .frame(minHeight: 16, alignment: .leading)
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Latency by weekday and hour"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private func cell(_ cell: WeekHourGrid.Cell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return ZStack {
            if let median = cell.median {
                shape.fill(color(for: median).opacity(cell.isThin ? 0.45 : 1))
            } else {
                shape.fill(.quinary)
                Hatch().stroke(.quaternary, lineWidth: 1).clipShape(shape)
            }
            if hovered == cell.id {
                shape.strokeBorder(.primary, lineWidth: 1.5)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .onHover { inside in
            if inside { hovered = cell.id }
        }
    }

    private var legend: some View {
        HStack(spacing: Space.l) {
            HStack(spacing: Space.xs) {
                Text("Faster")
                LinearGradient(colors: [color(for: grid.range?.lowerBound ?? 0),
                                        color(for: grid.range?.upperBound ?? 1)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 80, height: 8)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("Slower")
            }
            HStack(spacing: Space.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2).fill(.quinary)
                    Hatch().stroke(.quaternary, lineWidth: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .frame(width: 14, height: 8)
                Text("Not measured")
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var readout: String {
        guard let id = hovered else { return "Hover a square to read it." }
        let cell = grid.cells[id]
        let when = "\(WeekHourGrid.weekdaySymbols[cell.weekday]) "
            + String(format: "%02d:00–%02d:00", cell.hour, (cell.hour + 1) % 24)
        guard let median = cell.median else { return "\(when) · not measured" }
        let days = "\(cell.days) day\(cell.days == 1 ? "" : "s")"
        return "\(when) · typical \(Fmt.msCoarse(median)) ms · from \(days)"
            + (cell.isThin ? ", only briefly" : "")
    }

    /// A single-hue ramp from pale to deep orange across the measured range,
    /// so the darkest cell is always the slowest hour actually seen.
    private func color(for median: Double) -> Color {
        guard let range = grid.range else { return Color.orange.opacity(0.3) }
        let t = (median - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Color.orange.opacity(0.15 + 0.85 * min(max(t, 0), 1))
    }

    private var accessibilitySummary: String {
        let measured = grid.measured
        guard let slowest = measured.max(by: { ($0.median ?? 0) < ($1.median ?? 0) }),
              let median = slowest.median else { return "Nothing measured" }
        return "\(measured.count) hours measured. Slowest: "
            + "\(WeekHourGrid.weekdaySymbols[slowest.weekday]) at \(slowest.hour):00, "
            + "\(Fmt.msCoarse(median)) milliseconds."
    }
}

/// Diagonal stripes for "not measured", so an empty hour can never be read as
/// a fast one.
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 5
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return path
    }
}
