import XCTest
@testable import NetlogsCore

final class SessionSpreadTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func analysis(dayOffset: Double, minutes: Double, p50: Double, p95: Double,
                          coverage: Double = 1) -> SessionAnalysis {
        let started = epoch.addingTimeInterval(dayOffset * 86_400)
        let samples = Int(minutes * 60)
        let claimed = coverage > 0 ? Double(samples) / coverage : Double(samples)
        let state = SessionState(startedAt: started,
                                 stoppedAt: started.addingTimeInterval(claimed),
                                 settings: MonitorSettings())
        let aggregate = PingAggregate(
            totalSamples: samples,
            firstSampleAt: started,
            lastSampleAt: started.addingTimeInterval(Double(samples)),
            router: HostAggregate(replies: samples, min: 2, max: 20, sum: Double(samples) * 8,
                                  jitterSum: 100, jitterPairs: 500),
            internet: HostAggregate(replies: samples, min: p50, max: p95,
                                    sum: Double(samples) * p50,
                                    jitterSum: 2_000, jitterPairs: 500)
        )
        var histogram = LatencyHistogram()
        histogram.add(p50, count: samples * 9 / 10)
        histogram.add(p95, count: samples / 10)
        return SessionAnalysis(session: state, aggregate: aggregate, latency: histogram)
    }

    private func interval() -> DateInterval {
        DateInterval(start: epoch, end: epoch.addingTimeInterval(7 * 86_400))
    }

    /// A fifteen-minute session on a seven-day axis is a zero-width rectangle
    /// that draws nothing — the one-sample outage lesson, at range scale. The
    /// measurement stays exact; only the drawing is widened.
    func testAShortSessionStillHasSomethingToDraw() {
        let spread = SessionSpread.build(
            [analysis(dayOffset: 1, minutes: 15, p50: 30, p95: 45)],
            interval: interval(), minimumWidth: 3_600
        )
        let mark = spread.marks[0]
        XCTAssertEqual(mark.duration, 900, accuracy: 1)
        XCTAssertEqual(mark.drawnEnd.timeIntervalSince(mark.start), 3_600, accuracy: 1)
    }

    func testALongSessionIsDrawnAtItsRealWidth() {
        let spread = SessionSpread.build(
            [analysis(dayOffset: 1, minutes: 600, p50: 30, p95: 45)],
            interval: interval(), minimumWidth: 3_600
        )
        let mark = spread.marks[0]
        XCTAssertEqual(mark.drawnEnd, mark.end, "no offset, only a floor")
    }

    /// A range where every session sat at 30 ms must not be drawn to a 6 ms
    /// spread — the same magnification `DiagnosticsTrace.yDomain` refuses.
    func testAFlatRangeGetsAFloorRatherThanAMagnifiedAxis() {
        let spread = SessionSpread.build(
            (0..<5).map { analysis(dayOffset: Double($0), minutes: 60, p50: 30, p95: 34) },
            interval: interval(), minimumWidth: 600
        )
        XCTAssertEqual(spread.yDomain.lowerBound, 0, "latency has a real floor")
        XCTAssertGreaterThanOrEqual(spread.yDomain.upperBound,
                                    SessionSpread.minimumCeilingMs)
    }

    func testTheAxisCoversTheWorstBandInRange() {
        let spread = SessionSpread.build(
            [analysis(dayOffset: 0, minutes: 60, p50: 30, p95: 45),
             analysis(dayOffset: 2, minutes: 60, p50: 120, p95: 480)],
            interval: interval(), minimumWidth: 600
        )
        XCTAssertGreaterThan(spread.yDomain.upperBound, 480)
    }

    /// A session that started before the range is reported whole, so the axis
    /// has to reach back for it rather than clipping the bar.
    func testTheAxisReachesASessionThatStartedBeforeTheRange() {
        let spread = SessionSpread.build(
            [analysis(dayOffset: -0.5, minutes: 600, p50: 30, p95: 45)],
            interval: interval(), minimumWidth: 600
        )
        XCTAssertLessThan(spread.xDomain.lowerBound, interval().start)
    }

    func testASessionWithNoRepliesIsNotDrawn() {
        let started = epoch
        let state = SessionState(startedAt: started, stoppedAt: started.addingTimeInterval(600),
                                 settings: MonitorSettings())
        let aggregate = PingAggregate(totalSamples: 600, firstSampleAt: started,
                                      lastSampleAt: started.addingTimeInterval(600),
                                      internetTimeouts: 600, failureCount: 600)
        let spread = SessionSpread.build(
            [SessionAnalysis(session: state, aggregate: aggregate)],
            interval: interval(), minimumWidth: 600
        )
        XCTAssertTrue(spread.isEmpty, "nothing measured, nothing to draw")
    }

    func testEmptyRangeStillHasUsableScales() {
        let spread = SessionSpread.build([], interval: interval(), minimumWidth: 600)
        XCTAssertTrue(spread.isEmpty)
        XCTAssertLessThan(spread.xDomain.lowerBound, spread.xDomain.upperBound)
        XCTAssertLessThan(spread.yDomain.lowerBound, spread.yDomain.upperBound)
    }
}
