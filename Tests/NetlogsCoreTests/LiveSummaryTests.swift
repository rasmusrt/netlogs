import XCTest
@testable import NetlogsCore

final class LiveSummaryTests: XCTestCase {

    private func sample(_ id: UInt32, router: Double?, internet: Double?) -> PingSample {
        PingSample(id: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                   routerMs: router, internetMs: internet, phase: .idle)
    }

    func testCountsAndStats() {
        var b = LiveSummaryBuilder()
        b.add(sample(0, router: 10, internet: 20))
        b.add(sample(1, router: 12, internet: nil))   // internet timeout
        b.add(sample(2, router: nil, internet: 22))   // router timeout
        b.add(sample(3, router: 14, internet: 24))

        let s = b.summary
        XCTAssertEqual(s.totalSamples, 4)
        XCTAssertEqual(s.routerTimeouts, 1)
        XCTAssertEqual(s.internetTimeouts, 1)
        XCTAssertEqual(s.failureCount, 2, "two samples had at least one timeout")
        XCTAssertEqual(s.router.samples, 3)
        XCTAssertEqual(s.router.min, 10); XCTAssertEqual(s.router.max, 14)
        XCTAssertEqual(s.internet.samples, 3)
        XCTAssertEqual(s.internet.avg, 22, accuracy: 1e-9)
        XCTAssertEqual(b.elapsed, 3, accuracy: 1e-9)
    }

    func testEmptyBuilder() {
        let s = LiveSummaryBuilder().summary
        XCTAssertEqual(s.totalSamples, 0)
        XCTAssertEqual(s.router.avg, 0)
        XCTAssertEqual(s.failureCount, 0)
    }

    func testLiveSummaryRoundTrips() throws {
        var b = LiveSummaryBuilder()
        for i in 0..<10 { b.add(sample(UInt32(i), router: Double(i + 1), internet: Double(i + 5))) }
        let s = b.summary
        let back = try JSONDecoder().decode(LiveSummary.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    // MARK: - PingLogWindow

    func testWindowTrimsToTimeSpan() {
        var w = PingLogWindow(window: .seconds(300))
        for i in 0..<600 { w.append(sample(UInt32(i), router: 5, internet: 5)) } // 1 s apart

        // Newest is t0+599; window keeps [t0+300 ... t0+599] inclusive → 300 rows.
        XCTAssertEqual(w.count, 300)
        XCTAssertEqual(w.samples.first?.id, 300)
        XCTAssertEqual(w.samples.last?.id, 599)
        XCTAssertEqual(Array(w.newestFirst.prefix(1)).first?.id, 599)
    }

    func testWindowHardCap() {
        var w = PingLogWindow(window: .seconds(100_000), hardCap: 50)
        for i in 0..<200 { w.append(sample(UInt32(i), router: 1, internet: 1)) }
        XCTAssertEqual(w.count, 50)
        XCTAssertEqual(w.samples.first?.id, 150)
    }

    func testWindowReset() {
        var w = PingLogWindow()
        for i in 0..<10 { w.append(sample(UInt32(i), router: 1, internet: 1)) }
        w.reset()
        XCTAssertEqual(w.count, 0)
    }
}
