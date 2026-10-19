import XCTest
@testable import NetlogsCore

final class WeekHourGridTests: XCTestCase {

    private let session = UUID()
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        return calendar
    }

    private func bucket(day: String, hour: Int, ms: Double, count: Int,
                        id: UUID? = nil) -> HourlyBucket {
        var histogram = LatencyHistogram()
        histogram.add(ms, count: count)
        return HourlyBucket(key: HourKey(sessionID: id ?? session, day: day, hour: hour),
                            histogram: histogram)
    }

    func testAlwaysSevenByTwentyFourMondayFirst() {
        let grid = WeekHourGrid.build([], sessionIDs: [session], calendar: calendar)
        XCTAssertEqual(grid.cells.count, 168)
        XCTAssertTrue(grid.isEmpty)
        XCTAssertNil(grid.range)
        XCTAssertEqual(grid.cell(weekday: 0, hour: 0).weekday, 0)
        XCTAssertEqual(grid.cell(weekday: 6, hour: 23).hour, 23)
    }

    func testPlacesADayOnItsWeekday() {
        // 19 Oct 2026 is a Monday, 18 Oct a Sunday.
        let grid = WeekHourGrid.build(
            [bucket(day: "2026-10-19", hour: 8, ms: 20, count: 3_600),
             bucket(day: "2026-10-18", hour: 21, ms: 45, count: 3_600)],
            sessionIDs: [session], calendar: calendar
        )
        XCTAssertEqual(grid.cell(weekday: 0, hour: 8).median ?? 0, 20, accuracy: 1)
        XCTAssertEqual(grid.cell(weekday: 6, hour: 21).median ?? 0, 45, accuracy: 1)
        XCTAssertNil(grid.cell(weekday: 1, hour: 8).median, "unmeasured is nil, never 0")
        XCTAssertEqual(grid.measured.count, 2)
    }

    func testMergesTheSameWeekdayAcrossWeeksAndCountsDays() {
        let grid = WeekHourGrid.build(
            [bucket(day: "2026-10-12", hour: 20, ms: 30, count: 1_000),
             bucket(day: "2026-10-19", hour: 20, ms: 30, count: 1_000)],
            sessionIDs: [session], calendar: calendar
        )
        let cell = grid.cell(weekday: 0, hour: 20)
        XCTAssertEqual(cell.days, 2)
        XCTAssertEqual(cell.samples, 2_000)
        XCTAssertFalse(cell.isThin)
    }

    func testIgnoresOtherSessionsAndFlagsThinCells() {
        let other = UUID()
        let grid = WeekHourGrid.build(
            [bucket(day: "2026-10-19", hour: 9, ms: 25, count: 120),
             bucket(day: "2026-10-19", hour: 10, ms: 90, count: 3_600, id: other)],
            sessionIDs: [session], calendar: calendar
        )
        XCTAssertTrue(grid.cell(weekday: 0, hour: 9).isThin)
        XCTAssertNil(grid.cell(weekday: 0, hour: 10).median)
    }
}
