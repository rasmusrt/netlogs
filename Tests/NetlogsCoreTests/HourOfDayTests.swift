import XCTest
@testable import NetlogsCore

/// The most false-positive-prone rule in the catalogue, so most of these
/// assert that it stays quiet.
final class HourOfDayTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = UUID()

    private func bucket(day: Int, hour: Int, ms: Double, count: Int,
                        id: UUID? = nil) -> HourlyBucket {
        var histogram = LatencyHistogram()
        histogram.add(ms, count: count)
        return HourlyBucket(
            key: HourKey(sessionID: id ?? session, day: "2026-09-\(String(format: "%02d", day))",
                         hour: hour),
            histogram: histogram
        )
    }

    /// Quiet hours at 40 ms every day, one hour at 90 ms on three days.
    private func congestedBuckets(days: Int = 3, peakMs: Double = 90) -> [HourlyBucket] {
        var out: [HourlyBucket] = []
        for day in 1...5 {
            for hour in 0..<24 where hour != 20 {
                out.append(bucket(day: day, hour: hour, ms: 40, count: 3_600))
            }
        }
        for day in 1...days {
            out.append(bucket(day: day, hour: 20, ms: peakMs, count: 3_600))
        }
        return out
    }

    private func analysis(_ buckets: [HourlyBucket],
                          router: [HourlyBucket] = []) -> RangeAnalysis {
        let state = SessionState(id: session, startedAt: epoch,
                                 stoppedAt: epoch.addingTimeInterval(5 * 86_400),
                                 settings: MonitorSettings())
        let aggregate = PingAggregate(
            totalSamples: 400_000,
            firstSampleAt: epoch, lastSampleAt: epoch.addingTimeInterval(5 * 86_400),
            internet: HostAggregate(replies: 400_000, min: 20, max: 90,
                                    sum: 400_000 * 40, jitterSum: 100, jitterPairs: 1_000)
        )
        var histogram = LatencyHistogram()
        histogram.add(40, count: 400_000)
        return RangeAnalysis(
            interval: DateInterval(start: epoch, end: epoch.addingTimeInterval(6 * 86_400)),
            sessions: [SessionAnalysis(session: state, aggregate: aggregate, latency: histogram)],
            hourlyBuckets: buckets, routerHourlyBuckets: router
        )
    }

    // MARK: - The fold

    func testEveryHourIsPresentEvenWhenNeverMeasured() {
        let profile = HourOfDayProfile.build(
            [bucket(day: 1, hour: 3, ms: 40, count: 100)], sessionIDs: [session]
        )
        XCTAssertEqual(profile.hours.count, 24)
        XCTAssertEqual(profile.hours[7].samples, 0, "an hour never measured is not zero latency")
        XCTAssertNil(profile.hours[7].median)
    }

    func testDaysAreCountedDistinctly() {
        let profile = HourOfDayProfile.build([
            bucket(day: 1, hour: 20, ms: 40, count: 100),
            bucket(day: 1, hour: 20, ms: 50, count: 100),
            bucket(day: 2, hour: 20, ms: 40, count: 100),
        ], sessionIDs: [session])
        XCTAssertEqual(profile.hours[20].days, 2, "two calendar days, three buckets")
    }

    func testAnotherTargetsHoursAreNotPooledIn() {
        let other = UUID()
        let profile = HourOfDayProfile.build([
            bucket(day: 1, hour: 20, ms: 40, count: 100),
            bucket(day: 1, hour: 20, ms: 900, count: 100, id: other),
        ], sessionIDs: [session])
        XCTAssertEqual(profile.hours[20].median, 40)
    }

    // MARK: - The rule

    func testFiresOnASustainedEveningPattern() {
        let findings = TimeOfDayRule().evaluate(analysis(congestedBuckets()))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].side, Finding.Side.internetPath)
        XCTAssertTrue(findings[0].evidence.measurement.contains("20:00"))
        XCTAssertTrue(findings[0].evidence.scope.contains("3 days"))
    }

    func testDoesNotFireOnTwoDays() {
        XCTAssertTrue(TimeOfDayRule().evaluate(analysis(congestedBuckets(days: 2))).isEmpty)
    }

    /// 1.24× is what the real database's worst hour looks like. It must not be
    /// reported as a pattern.
    func testDoesNotFireBelowTheRatio() {
        XCTAssertTrue(TimeOfDayRule().evaluate(analysis(congestedBuckets(peakMs: 50))).isEmpty)
    }

    /// A ratio over a small baseline is noise: 15 ms against 10 ms is 1.5×, and
    /// nobody can feel it.
    func testDoesNotFireWithoutAnAbsoluteMargin() {
        var buckets: [HourlyBucket] = []
        for day in 1...5 {
            for hour in 0..<24 where hour != 20 {
                buckets.append(bucket(day: day, hour: hour, ms: 10, count: 3_600))
            }
        }
        for day in 1...3 { buckets.append(bucket(day: day, hour: 20, ms: 16, count: 3_600)) }
        XCTAssertTrue(TimeOfDayRule().evaluate(analysis(buckets)).isEmpty)
    }

    /// If the router is slow in the same hours, the problem is inside the
    /// house and calling it congestion points at the wrong side of it.
    func testDoesNotFireWhenTheRouterIsSlowInTheSameHours() {
        var router: [HourlyBucket] = []
        for day in 1...5 {
            for hour in 0..<24 where hour != 20 {
                router.append(bucket(day: day, hour: hour, ms: 4, count: 3_600))
            }
        }
        for day in 1...3 { router.append(bucket(day: day, hour: 20, ms: 40, count: 3_600)) }

        XCTAssertTrue(TimeOfDayRule().evaluate(
            analysis(congestedBuckets(), router: router)
        ).isEmpty)
    }

    func testFiresWhenOnlyTheInternetIsSlowInThoseHours() {
        var router: [HourlyBucket] = []
        for day in 1...5 {
            for hour in 0..<24 { router.append(bucket(day: day, hour: hour, ms: 4, count: 3_600)) }
        }
        XCTAssertEqual(TimeOfDayRule().evaluate(
            analysis(congestedBuckets(), router: router)
        ).count, 1)
    }

    func testDoesNotFireOnASparseHour() {
        var buckets = congestedBuckets(days: 3)
        buckets.removeAll { $0.key.hour == 20 }
        for day in 1...3 { buckets.append(bucket(day: day, hour: 20, ms: 200, count: 50)) }
        XCTAssertTrue(TimeOfDayRule().evaluate(analysis(buckets)).isEmpty,
                      "150 samples across three days is not an hour")
    }
}
