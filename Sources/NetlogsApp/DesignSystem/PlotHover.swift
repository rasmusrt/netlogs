import SwiftUI
import Charts

extension View {
    /// Reports the time under the pointer while it is over a chart's plot
    /// area, and `nil` when it leaves. `onTap` runs on a click in the plot.
    ///
    /// The same construction as the Analysis session chart, whose hover has
    /// always worked: a clear `Rectangle` with a rectangular `contentShape`
    /// inside `chartOverlay`, carrying both `onContinuousHover` and
    /// `onTapGesture`. The version this replaced turned the chart's hit
    /// testing off and hovered an overlay outside it, and on the Router lanes
    /// and the live Monitor chart that overlay never received an event.
    func plotHover(domain: ClosedRange<Date>, onTap: (() -> Void)? = nil,
                   onChange: @escaping (Date?) -> Void) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard frame.width > 0,
                                      point.x >= frame.minX, point.x <= frame.maxX,
                                      point.y >= frame.minY, point.y <= frame.maxY else {
                                    onChange(nil)
                                    return
                                }
                                let date = proxy.value(atX: point.x - frame.minX, as: Date.self)
                                onChange(date.map { min(max($0, domain.lowerBound), domain.upperBound) })
                            case .ended:
                                onChange(nil)
                            }
                        }
                        .onTapGesture { onTap?() }
                }
            }
        }
    }
}
