import XCTest
@testable import NetlogsCore

/// The Gateway sheet's series. Mostly about what must *not* be drawn: a rate
/// across a gap, a SINR line between reports, a zero from a repeated reading.
final class WANTraceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func sample(_ s: Int, _ ms: Double?, late: Double? = nil) -> PingSample {
        PingSample(id: UInt32(s + 10), timestamp: at(Double(s)), routerMs: 4,
                   internetMs: ms, internetLateMs: late, phase: .idle)
    }

    private func counters(_ s: TimeInterval, tx: Int64, rx: Int64 = 0,
                          radio: CellularRadio? = nil) -> WANSnapshot {
        WANSnapshot(timestamp: at(s), radio: radio,
                    counters: WANCounters(interface: "wan1", rxBytes: rx, txBytes: tx))
    }

    private func radio(_ s: TimeInterval, reported: TimeInterval, sinr: Double,
                       band: String = "n78", cell: Int = 1) -> WANSnapshot {
        WANSnapshot(timestamp: at(s),
                    radio: CellularRadio(reportedAt: at(reported), band: band, cellID: cell,
                                         nrSINR: sinr))
    }

    // MARK: - Rates

    func testARateIsTheCounterDifferenceOverItsInterval() {
        // 5 s apart, 3,125,000 bytes up: 5 Mbps.
        let trace = WANTrace.build(snapshots: [counters(0, tx: 0), counters(5, tx: 3_125_000)],
                                   samples: [])
        XCTAssertEqual(trace.rates.count, 1)
        XCTAssertEqual(trace.rates[0].upMbps, 5, accuracy: 1e-9)
        XCTAssertEqual(trace.rates[0].start, at(0))
        XCTAssertEqual(trace.rates[0].end, at(5), "a step over the interval, not a point")
    }

    /// A row stored for a radio change repeats the last counters. Pairing
    /// against it would draw 0 Mbps and then twice the real rate.
    func testARepeatedReadingIsNotAZero() {
        let trace = WANTrace.build(snapshots: [
            counters(0, tx: 0),
            counters(2, tx: 0, radio: CellularRadio(nrSINR: 20)),
            counters(5, tx: 3_125_000),
        ], samples: [])
        XCTAssertEqual(trace.rates.count, 1)
        XCTAssertEqual(trace.rates[0].upMbps, 5, accuracy: 1e-9)
    }

    func testNoRateAcrossAGapInTheReadings() {
        let trace = WANTrace.build(snapshots: [
            counters(0, tx: 0), counters(5, tx: 1_000),
            counters(300, tx: 2_000), counters(305, tx: 3_000),
        ], samples: [])
        XCTAssertEqual(trace.rates.count, 2, "the five minutes between are not averaged over")
        XCTAssertNotEqual(trace.rates[0].segment, trace.rates[1].segment)
    }

    func testACounterResetIsNotNegativeTraffic() {
        let trace = WANTrace.build(snapshots: [
            counters(0, tx: 9_000_000), counters(5, tx: 100), counters(10, tx: 200),
        ], samples: [])
        XCTAssertEqual(trace.rates.count, 1)
        XCTAssertGreaterThanOrEqual(trace.rates[0].upMbps, 0)
    }

    // MARK: - Radio

    /// Six polls of one CPE report are one point, at the report's time.
    func testRadioIsOnePointPerReport() {
        let trace = WANTrace.build(snapshots: [
            radio(0, reported: -1, sinr: 25), radio(2, reported: -1, sinr: 25),
            radio(4, reported: -1, sinr: 25), radio(12, reported: 11, sinr: 18),
        ], samples: [])
        XCTAssertEqual(trace.radio.map(\.sinr), [25, 18])
        XCTAssertEqual(trace.radio[1].time, at(11), "the CPE's time, not the poll's")
    }

    func testABandChangeIsMarked() {
        let trace = WANTrace.build(snapshots: [
            radio(0, reported: 0, sinr: 25), radio(12, reported: 12, sinr: 8, band: "n1", cell: 2),
        ], samples: [])
        XCTAssertEqual(trace.radioChanges.count, 1)
        XCTAssertEqual(trace.radioChanges[0].summary, "band n78 → n1, new cell")
    }

    func testTheSINRLineBreaksWhenReportsStop() {
        let trace = WANTrace.build(snapshots: [
            radio(0, reported: 0, sinr: 25), radio(200, reported: 200, sinr: 24),
        ], samples: [])
        XCTAssertNotEqual(trace.radio[0].segment, trace.radio[1].segment)
        XCTAssertNil(trace.readout(at: at(150)).sinr,
                     "a report is not held for minutes past its refresh interval")
    }

    // MARK: - RTT, gaps and readout

    /// A late reply is the RTT an episode is made of. Dropping it would draw
    /// the episode as a gap.
    func testLateRepliesAreDrawn() {
        let trace = WANTrace.build(snapshots: [], samples: [
            sample(0, 30), sample(1, nil, late: 2_400), sample(2, 32),
        ])
        XCTAssertEqual(trace.rtt.map(\.max).max(), 2_400)
    }

    func testRTTIsBucketedToFit() {
        let samples = (0..<3_600).map { sample($0, 30) }
        let trace = WANTrace.build(snapshots: [], samples: samples)
        XCTAssertEqual(trace.bucketSeconds, 10)
        XCTAssertLessThanOrEqual(trace.rtt.count, WANTrace.targetBuckets)
    }

    func testAFailurePeriodIsAGapWithItsReason() {
        let trace = WANTrace.build(snapshots: [
            counters(0, tx: 0),
            .failed(.unreachable("timed out"), at: at(10)),
            .failed(.unreachable("timed out"), at: at(20)),
            counters(30, tx: 10),
        ], samples: [])
        XCTAssertEqual(trace.gaps.count, 1)
        XCTAssertEqual(trace.gaps[0].start, at(10))
        XCTAssertEqual(trace.gaps[0].end, at(30))
        XCTAssertEqual(trace.gaps[0].reason, "Gateway unreachable: timed out")
    }

    func testTheReadoutLinesUpAllThree() {
        let trace = WANTrace.build(snapshots: [
            WANSnapshot(timestamp: at(0),
                        radio: CellularRadio(reportedAt: at(0), nrSINR: 22),
                        counters: WANCounters(interface: "wan1", rxBytes: 0, txBytes: 0)),
            counters(5, tx: 3_125_000),
        ], samples: (0..<10).map { sample($0, 40) })
        let readout = trace.readout(at: at(3))
        XCTAssertEqual(readout.rttMs, 40)
        XCTAssertEqual(readout.upMbps ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(readout.sinr, 22)
        XCTAssertTrue(trace.hasGatewayData)
    }

    func testNothingFromTheGatewayIsNotGatewayData() {
        let trace = WANTrace.build(snapshots: [], samples: (0..<10).map { sample($0, 40) })
        XCTAssertFalse(trace.hasGatewayData)
    }
}
