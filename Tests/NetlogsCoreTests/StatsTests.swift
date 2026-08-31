import XCTest
@testable import NetlogsCore

final class StatsTests: XCTestCase {

    // Deterministic pseudo-random so failures reproduce.
    private struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private func sampleValues(_ n: Int, seed: UInt64 = 0x9E3779B9) -> [Double] {
        var rng = LCG(state: seed)
        return (0..<n).map { _ in
            // mix of a tight cluster and a heavy tail, some > 1000 ms
            let base = Double.random(in: 5...45, using: &rng)
            let spike = Double.random(in: 0...1, using: &rng) < 0.03
                ? Double.random(in: 200...1500, using: &rng) : 0
            return base + spike
        }
    }

    func testRunningStatsMatchesNaiveReference() {
        let values = sampleValues(100_000)

        var stats = RunningStats()
        for v in values { stats.add(v) }

        XCTAssertEqual(stats.count, values.count)
        XCTAssertEqual(stats.min, values.min()!, accuracy: 1e-9)
        XCTAssertEqual(stats.max, values.max()!, accuracy: 1e-9)
        XCTAssertEqual(stats.mean, values.reduce(0, +) / Double(values.count), accuracy: 1e-6)

        var naiveJitterSum = 0.0
        for i in 1..<values.count { naiveJitterSum += abs(values[i] - values[i - 1]) }
        XCTAssertEqual(stats.jitter, naiveJitterSum / Double(values.count - 1), accuracy: 1e-6)
    }

    func testRunningStatsGapResetsJitterAnchor() {
        var s = RunningStats()
        s.add(10)
        s.markGap()
        s.add(500) // must NOT count |500 - 10| as jitter
        s.add(505)
        XCTAssertEqual(s.jitter, 5, accuracy: 1e-9)
    }

    func testMeasuredJitterNeedsAPair() {
        var s = RunningStats()
        XCTAssertNil(s.measuredJitter, "nothing added")
        s.add(10)
        XCTAssertNil(s.measuredJitter, "one reply has nothing to differ from")
        s.markGap()
        s.add(500)
        XCTAssertNil(s.measuredJitter, "a gap between them is not a pair either")
        XCTAssertEqual(s.jitter, 0, "the non-optional form still flattens to 0")
        s.add(505)
        XCTAssertEqual(try XCTUnwrap(s.measuredJitter), 5, accuracy: 1e-9)
    }

    func testHistogramPercentilesMatchNearestRankReference() {
        let values = sampleValues(100_000, seed: 0xDEADBEEF)

        var hist = LatencyHistogram()
        for v in values { hist.add(v) }

        let sorted = values.sorted()
        func nearestRank(_ p: Double) -> Double {
            let rank = max(1, Int((p / 100 * Double(sorted.count)).rounded(.up)))
            return min(sorted[rank - 1], 1000) // histogram tops out at the overflow bucket
        }
        // Within one 1 ms bucket of the exact value.
        XCTAssertEqual(hist.p50, floor(nearestRank(50)), accuracy: 1)
        XCTAssertEqual(hist.p95, floor(nearestRank(95)), accuracy: 1)
        XCTAssertEqual(hist.p99, floor(nearestRank(99)), accuracy: 1)
    }

    func testHistogramEdgeCases() {
        var empty = LatencyHistogram()
        XCTAssertEqual(empty.p50, 0)
        empty.add(0); empty.add(999.9); empty.add(4000)
        XCTAssertEqual(empty.count, 3)
        XCTAssertEqual(empty.percentile(100), 1000, "overflow bucket reports as 1000")
        XCTAssertEqual(empty.percentile(0), 0)
    }

    func testTopNMatchesFullSort() {
        let values = sampleValues(100_000, seed: 42)

        var lowest = TopNTracker<Double>(capacity: 10, keep: .smallest) { $0 }
        var highest = TopNTracker<Double>(capacity: 10, keep: .largest) { $0 }
        for v in values { lowest.offer(v); highest.offer(v) }

        XCTAssertEqual(lowest.elements, Array(values.sorted().prefix(10)))
        XCTAssertEqual(highest.elements, Array(values.sorted().suffix(10).reversed()))
    }

    func testTopNKeepsFirstSeenOnTies() {
        var t = TopNTracker<[Int]>(capacity: 2, keep: .smallest) { Double($0[0]) }
        t.offer([5, 1]); t.offer([5, 2]); t.offer([5, 3]); t.offer([9, 9])
        XCTAssertEqual(t.elements.map { $0[1] }, [1, 2], "ties resolve to earlier arrivals")
    }

    func testStatsThroughputStaysFlat() {
        // Proxy for O(1): 100k adds must not be pathologically slow, and the
        // second half must not be dramatically slower than the first.
        let values = sampleValues(100_000, seed: 7)
        var acc = HostLatencyAccumulator()
        var low = TopNTracker<Double>(capacity: 10, keep: .smallest) { $0 }

        func time(_ range: Range<Int>) -> Double {
            let start = DispatchTime.now()
            for i in range { acc.record(rttMs: values[i]); low.offer(values[i]) }
            return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        }
        let firstHalf = time(0..<50_000)
        let secondHalf = time(50_000..<100_000)

        XCTAssertLessThan(firstHalf + secondHalf, 0.5, "100k stat updates should be well under 0.5 s")
        XCTAssertLessThan(secondHalf, firstHalf * 4 + 0.02, "runtime per sample must not grow with n")
        _ = acc.stat
    }
}
