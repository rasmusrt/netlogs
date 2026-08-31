import Foundation

extension Duration {
    /// Seconds as a floating-point `TimeInterval`.
    public var timeInterval: TimeInterval {
        let (s, atto) = components
        return Double(s) + Double(atto) / 1e18
    }

    /// Whole nanoseconds, clamped to `Int` range.
    var wholeNanoseconds: Int {
        let (s, atto) = components
        let ns = s.multipliedReportingOverflow(by: 1_000_000_000)
        guard !ns.overflow else { return .max }
        let total = ns.partialValue.addingReportingOverflow(atto / 1_000_000_000)
        guard !total.overflow else { return .max }
        return Int(clamping: total.partialValue)
    }
}
