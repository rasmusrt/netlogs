import Foundation

/// One session's samples in one hour of one calendar day.
public struct HourKey: Sendable, Equatable, Hashable {
    public let sessionID: UUID
    /// `yyyy-MM-dd` in the machine's current zone — see the caveat on
    /// `SessionStore.hourlyBuckets`.
    public let day: String
    public let hour: Int

    public init(sessionID: UUID, day: String, hour: Int) {
        self.sessionID = sessionID
        self.day = day
        self.hour = hour
    }
}

public struct HourlyBucket: Sendable, Equatable {
    public let key: HourKey
    public let histogram: LatencyHistogram

    public init(key: HourKey, histogram: LatencyHistogram) {
        self.key = key
        self.histogram = histogram
    }
}

/// What one hour of the day looked like across a range.
public struct HourProfile: Sendable, Equatable, Identifiable {
    public let hour: Int
    public let histogram: LatencyHistogram
    /// Distinct calendar days contributing. The evidence bar: an hour seen once
    /// is an evening, not a pattern.
    public let days: Int

    public var id: Int { hour }
    public var samples: Int { histogram.count }
    public var median: Double? { histogram.count > 0 ? histogram.p50 : nil }

    public init(hour: Int, histogram: LatencyHistogram, days: Int) {
        self.hour = hour
        self.histogram = histogram
        self.days = days
    }
}

/// All 24 hours, folded from the day-and-hour buckets.
///
/// Every hour is present, including the ones with nothing in them — an hour you
/// never measured must be drawn as an empty slot rather than as zero, which is
/// the same rule the rest of the app applies to unmeasured figures.
public struct HourOfDayProfile: Sendable, Equatable {
    public let hours: [HourProfile]
    /// Median across every hour, the line each hour is compared against.
    public let overallMedian: Double?

    /// An hour needs this many distinct days before it can be claimed as a
    /// pattern, and this many samples on each of them.
    public static let minimumDays = 3
    public static let minimumSamplesPerDay = 900

    public init(hours: [HourProfile], overallMedian: Double?) {
        self.hours = hours
        self.overallMedian = overallMedian
    }

    public var measuredHours: [HourProfile] { hours.filter { $0.samples > 0 } }

    /// Hours with enough evidence to be compared at all.
    public var qualifying: [HourProfile] {
        hours.filter {
            $0.days >= Self.minimumDays
                && $0.samples >= Self.minimumDays * Self.minimumSamplesPerDay
        }
    }

    public static func build(_ buckets: [HourlyBucket], sessionIDs: Set<UUID>) -> HourOfDayProfile {
        let mine = buckets.filter { sessionIDs.contains($0.key.sessionID) }
        var byHour: [Int: [HourlyBucket]] = [:]
        for bucket in mine { byHour[bucket.key.hour, default: []].append(bucket) }

        let hours = (0..<24).map { hour -> HourProfile in
            let group = byHour[hour] ?? []
            return HourProfile(
                hour: hour,
                histogram: LatencyHistogram.merging(group.map(\.histogram)),
                days: Set(group.map(\.key.day)).count
            )
        }
        let all = LatencyHistogram.merging(hours.map(\.histogram))
        return HourOfDayProfile(hours: hours,
                                overallMedian: all.count > 0 ? all.p50 : nil)
    }
}
