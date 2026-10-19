import Foundation

/// Median latency per weekday and hour, for the Analysis screen's heatmap.
///
/// Built from the same `HourlyBucket`s as `HourOfDayProfile`, so the two
/// cannot disagree about a single hour. The difference is that this keeps the
/// weekday apart, which is what lets "Sunday evenings" show up as a block
/// instead of being averaged into every other evening.
///
/// **A cell is a measurement, not a pattern.** Over a week most cells come from
/// one day, so nothing here claims a trend — the cell carries its day count and
/// sample count, and a view must draw a thinly measured cell as such. An hour
/// never measured is `nil`, never zero, for the reason the old hour-of-day chart gave: a bar at zero reads as a fast hour.
public struct WeekHourGrid: Sendable, Equatable {
    public struct Cell: Sendable, Equatable, Identifiable {
        /// 0 = Monday … 6 = Sunday, the order the grid is drawn in.
        public let weekday: Int
        public let hour: Int
        public let median: Double?
        public let samples: Int
        public let days: Int

        public var id: Int { weekday * 24 + hour }

        /// Fewer samples than one well-measured hour on one day. Drawn faintly.
        public var isThin: Bool { samples < HourOfDayProfile.minimumSamplesPerDay }
    }

    /// Always 7 × 24, Monday first.
    public let cells: [Cell]

    public init(cells: [Cell]) {
        self.cells = cells
    }

    public var measured: [Cell] { cells.filter { $0.median != nil } }
    public var isEmpty: Bool { measured.isEmpty }

    /// The lowest and highest measured median, for a colour scale.
    public var range: ClosedRange<Double>? {
        let values = measured.compactMap(\.median)
        guard let low = values.min(), let high = values.max() else { return nil }
        return low ... Swift.max(high, low + 1)
    }

    public func cell(weekday: Int, hour: Int) -> Cell {
        cells[weekday * 24 + hour]
    }

    public static let weekdaySymbols = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// `HourKey.day` is `yyyy-MM-dd` in the machine's zone, so it is parsed in
    /// that zone too — parsing it as UTC would move late evenings to the next
    /// weekday for anyone east of Greenwich.
    public static func build(
        _ buckets: [HourlyBucket], sessionIDs: Set<UUID>,
        calendar: Calendar = .current
    ) -> WeekHourGrid {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        var weekdayOfDay: [String: Int] = [:]
        var grouped: [Int: [HourlyBucket]] = [:]
        for bucket in buckets where sessionIDs.contains(bucket.key.sessionID) {
            let day = bucket.key.day
            let weekday: Int
            if let known = weekdayOfDay[day] {
                weekday = known
            } else {
                guard let date = formatter.date(from: day) else { continue }
                // Calendar weekday is 1 = Sunday … 7 = Saturday.
                weekday = (calendar.component(.weekday, from: date) + 5) % 7
                weekdayOfDay[day] = weekday
            }
            guard (0..<24).contains(bucket.key.hour) else { continue }
            grouped[weekday * 24 + bucket.key.hour, default: []].append(bucket)
        }

        let cells = (0..<7).flatMap { weekday in
            (0..<24).map { hour -> Cell in
                let group = grouped[weekday * 24 + hour] ?? []
                let merged = LatencyHistogram.merging(group.map(\.histogram))
                return Cell(
                    weekday: weekday, hour: hour,
                    median: merged.count > 0 ? merged.p50 : nil,
                    samples: merged.count,
                    days: Set(group.map(\.key.day)).count
                )
            }
        }
        return WeekHourGrid(cells: cells)
    }
}
