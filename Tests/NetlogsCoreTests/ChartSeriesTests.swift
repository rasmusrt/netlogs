import XCTest
@testable import NetlogsCore

/// Covers the Phase 9 chart model: run-length encoding of load/outage
/// intervals, the streaming bucketer, and the two defects it was written to
/// fix (silent interpolation across outages, and a warm-up spike setting the
/// y-axis).
final class ChartSeriesTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// One sample per second from `epoch`.
    private func sample(
        _ id: UInt32,
        router: Double? = 5,
        internet: Double? = 20,
        phase: LoadPhase = .idle
    ) -> PingSample {
        PingSample(
            id: id,
            timestamp: epoch.addingTimeInterval(Double(id)),
            routerMs: router,
            internetMs: internet,
            phase: phase
        )
    }

    // MARK: - RunEncoder

    func testRunEncoderGroupsContiguousEqualValues() {
        var encoder = RunEncoder<LoadPhase>()
        // idle ×3, downloading ×4, idle ×2, uploading ×3
        for id in 0..<3 { encoder.append(nil, at: epoch.addingTimeInterval(Double(id))) }
        for id in 3..<7 { encoder.append(.downloading, at: epoch.addingTimeInterval(Double(id))) }
        for id in 7..<9 { encoder.append(nil, at: epoch.addingTimeInterval(Double(id))) }
        for id in 9..<12 { encoder.append(.uploading, at: epoch.addingTimeInterval(Double(id))) }
        encoder.closeOpen()

        let runs = encoder.runs()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].value, .downloading)
        XCTAssertEqual(runs[0].sampleCount, 4)
        XCTAssertEqual(runs[0].start, epoch.addingTimeInterval(3))
        XCTAssertEqual(runs[0].end, epoch.addingTimeInterval(6))
        XCTAssertEqual(runs[1].value, .uploading)
        XCTAssertEqual(runs[1].sampleCount, 3)
        XCTAssertEqual(runs[1].start, epoch.addingTimeInterval(9))
    }

    /// A session stopped mid-download must still render that band.
    func testRunEncoderIncludesTheStillOpenRun() {
        var encoder = RunEncoder<LoadPhase>()
        for id in 0..<3 { encoder.append(.downloading, at: epoch.addingTimeInterval(Double(id))) }

        XCTAssertEqual(encoder.runs().count, 1, "the open run must be visible before it is closed")
        XCTAssertEqual(encoder.runs()[0].sampleCount, 3)

        encoder.closeOpen()
        XCTAssertEqual(encoder.runs().count, 1, "closing must not duplicate the run")
        XCTAssertEqual(encoder.runs()[0].sampleCount, 3)
    }

    func testAdjacentDifferentValuesSplitWithoutAGap() {
        var encoder = RunEncoder<LoadPhase>()
        encoder.append(.downloading, at: epoch)
        encoder.append(.uploading, at: epoch.addingTimeInterval(1))
        encoder.closeOpen()

        let runs = encoder.runs()
        XCTAssertEqual(runs.map(\.value), [.downloading, .uploading])
        XCTAssertEqual(runs[0].end, epoch)
        XCTAssertEqual(runs[1].start, epoch.addingTimeInterval(1))
    }

    func testOutageScopeDistinguishesWhichHostIsSilent() {
        XCTAssertNil(OutageScope(routerSilent: false, internetSilent: false))
        XCTAssertEqual(OutageScope(routerSilent: true, internetSilent: false), .router)
        XCTAssertEqual(OutageScope(routerSilent: false, internetSilent: true), .internet)
        XCTAssertEqual(OutageScope(routerSilent: true, internetSilent: true), .both)
    }

    // MARK: - Bucketer

    func testStaysWithinCapacityAndKeepsWidthAPowerOfTwo() {
        var bucketer = PingChartBucketer(capacity: 16)
        for id in 0..<1000 {
            bucketer.append(sample(UInt32(id)))
            let points = bucketer.series(load: [], outages: [], now: epoch).internet
            XCTAssertLessThanOrEqual(points.count, 16, "exceeded capacity at \(id) samples")
        }
        XCTAssertEqual(bucketer.bucketWidth & (bucketer.bucketWidth - 1), 0,
                       "width \(bucketer.bucketWidth) is not a power of two")
        XCTAssertEqual(bucketer.sampleCount, 1000)
    }

    /// Compaction must not lose or distort anything: the extremes across all
    /// buckets still equal the extremes of the raw input.
    /// Compaction must be a faithful reduction: after many doublings, each
    /// merged bucket still reports exactly what reducing its own sample range
    /// directly would report.
    func testMergedBucketsMatchADirectReductionOfTheirRange() {
        // Deterministic sawtooth with two planted spikes.
        let values: [Double] = (0..<512).map { id in
            let base = Double((id * 37) % 91) + 5
            let spike: Double
            if id == 123 { spike = 900 } else if id == 400 { spike = 450 } else { spike = 0 }
            return base + spike
        }
        var bucketer = PingChartBucketer(capacity: 8)
        for (id, ms) in values.enumerated() {
            bucketer.append(sample(UInt32(id), router: nil, internet: ms))
        }

        // 512 samples into a capacity-8 bucketer settles on width 128.
        XCTAssertEqual(bucketer.bucketWidth, 128)
        let series = bucketer.series(load: [], outages: [], now: epoch)
        XCTAssertEqual(series.internet.count, 4)

        // Compare each bucket against a direct reduction of its own range,
        // undoing the ceiling clamp the plot applies.
        let ceiling = series.yDomain.upperBound
        for (index, point) in series.internet.enumerated() {
            let range = values[(index * 128) ..< ((index + 1) * 128)]
            XCTAssertEqual(point.lo, min(range.min()!, ceiling), accuracy: 0.0001)
            XCTAssertEqual(point.hi, min(range.max()!, ceiling), accuracy: 0.0001)
            let mean = range.reduce(0, +) / Double(range.count)
            XCTAssertEqual(point.avg, min(mean, ceiling), accuracy: 0.0001,
                           "bucket \(index) mean drifted — averages were averaged")
        }
    }

    /// Below capacity there is no compaction, so every sample is its own
    /// bucket and the reduction is the identity.
    func testBelowCapacityEachSampleIsItsOwnBucket() {
        var bucketer = PingChartBucketer(capacity: 200)
        for id in 0..<50 { bucketer.append(sample(UInt32(id), router: 5, internet: Double(id) + 1)) }

        let series = bucketer.series(load: [], outages: [], now: epoch)
        XCTAssertEqual(series.internet.count, 50)
        XCTAssertEqual(bucketer.bucketWidth, 1)
        for (index, point) in series.internet.enumerated() {
            XCTAssertEqual(point.lo, point.avg, accuracy: 0.0001)
            XCTAssertEqual(point.avg, point.hi, accuracy: 0.0001)
            XCTAssertEqual(point.avg, Double(index) + 1, accuracy: 0.0001)
        }
    }

    // MARK: - Defect 1: outages must break the line

    func testASilentBucketBreaksTheLineInsteadOfInterpolating() {
        var bucketer = PingChartBucketer(capacity: 200)
        // 10 good, 5 total timeouts, 10 good.
        for id in 0..<10 { bucketer.append(sample(UInt32(id), internet: 20)) }
        for id in 10..<15 { bucketer.append(sample(UInt32(id), router: nil, internet: nil)) }
        for id in 15..<25 { bucketer.append(sample(UInt32(id), internet: 20)) }

        let series = bucketer.series(load: [], outages: [], now: epoch)

        XCTAssertEqual(series.internet.count, 20, "silent buckets emit no point")
        let segments = Set(series.internet.map(\.segment))
        XCTAssertEqual(segments.count, 2, "the outage must split the trace into two segments")

        let before = series.internet.prefix(10)
        let after = series.internet.suffix(10)
        XCTAssertEqual(Set(before.map(\.segment)).count, 1)
        XCTAssertEqual(Set(after.map(\.segment)).count, 1)
        XCTAssertNotEqual(before.last!.segment, after.first!.segment,
                          "points either side of an outage must not be joined")
    }

    func testOutageRunsRecordScopeAndSpan() {
        var samples: [PingSample] = []
        for id in 0..<5 { samples.append(sample(UInt32(id))) }
        // Router-only outage for 3s, then both for 2s, then recovery.
        for id in 5..<8 { samples.append(sample(UInt32(id), router: nil, internet: 20)) }
        for id in 8..<10 { samples.append(sample(UInt32(id), router: nil, internet: nil)) }
        for id in 10..<15 { samples.append(sample(UInt32(id))) }

        let series = PingChartSeries.build(samples: samples)
        XCTAssertEqual(series.outages.map(\.value), [.router, .both])
        XCTAssertEqual(series.outages[0].start, epoch.addingTimeInterval(5))
        XCTAssertEqual(series.outages[0].end, epoch.addingTimeInterval(7))
        XCTAssertEqual(series.outages[1].start, epoch.addingTimeInterval(8))
        XCTAssertEqual(series.outages[1].end, epoch.addingTimeInterval(9))
    }

    // MARK: - Defect 2: the warm-up spike must not set the y-axis

    /// The warm-up artefact does its damage at the *start* of a session, which
    /// is exactly when someone is watching the chart. Over a long run the p95
    /// ceiling absorbs two outliers on its own; over the first twenty samples
    /// it cannot, and the trace sits pinned to the floor of a 725 ms axis.
    func testWarmupSamplesAreExcludedFromTheYAxisEarlyInASession() {
        var samples: [PingSample] = []
        // The documented ICMP socket warm-up: sample 0 comes back ~580 ms.
        samples.append(sample(0, router: 580, internet: 580))
        samples.append(sample(1, router: 300, internet: 300))
        for id in 2..<20 { samples.append(sample(UInt32(id), router: 4, internet: 18)) }

        let withWarmup = PingChartSeries.build(samples: samples, warmupSamplesToSkip: 0)
        let without = PingChartSeries.build(samples: samples, warmupSamplesToSkip: 2)

        XCTAssertGreaterThan(withWarmup.yDomain.upperBound, 500,
                             "sanity: the artefact does inflate the axis when kept")
        XCTAssertEqual(without.yDomain.upperBound, PingChartBucketer.minimumCeilingMs,
                       "excluding warm-up must let the real trace fill the plot")
        XCTAssertEqual(without.internet.count, 18)
    }

    /// Documents the other half of the defence: once there is enough data, the
    /// percentile ceiling is robust to a couple of outliers by itself.
    func testCeilingAbsorbsTwoOutliersOnceTheSessionIsLong() {
        var samples: [PingSample] = []
        samples.append(sample(0, router: 580, internet: 580))
        samples.append(sample(1, router: 300, internet: 300))
        for id in 2..<200 { samples.append(sample(UInt32(id), router: 4, internet: 18)) }

        let series = PingChartSeries.build(samples: samples, warmupSamplesToSkip: 0)
        XCTAssertEqual(series.yDomain.upperBound, PingChartBucketer.minimumCeilingMs)
        XCTAssertGreaterThan(series.clippedCount, 0, "and the outliers are reported")
    }

    func testYCeilingResistsASingleSpikeButFlagsIt() {
        var samples: [PingSample] = []
        for id in 0..<199 { samples.append(sample(UInt32(id), router: 4, internet: 20)) }
        samples.append(sample(199, router: 4, internet: 5000))

        let series = PingChartSeries.build(samples: samples)
        XCTAssertLessThan(series.yDomain.upperBound, 200,
                          "one 5 s spike must not flatten 199 healthy samples")
        XCTAssertGreaterThan(series.clippedCount, 0,
                             "a clamped peak has to be reported, not silently flattened")
    }

    func testYCeilingHasAFloorSoAHealthyLanIsNotMagnified() {
        var samples: [PingSample] = []
        for id in 0..<60 { samples.append(sample(UInt32(id), router: 1.2, internet: 1.4)) }

        let series = PingChartSeries.build(samples: samples)
        XCTAssertEqual(series.yDomain.upperBound, PingChartBucketer.minimumCeilingMs)
    }

    // MARK: - Series assembly

    func testBuildProducesLoadBandsFromPhases() {
        var samples: [PingSample] = []
        for id in 0..<10 { samples.append(sample(UInt32(id))) }
        for id in 10..<20 { samples.append(sample(UInt32(id), phase: .downloading)) }
        for id in 20..<25 { samples.append(sample(UInt32(id))) }
        for id in 25..<35 { samples.append(sample(UInt32(id), phase: .uploading)) }
        for id in 35..<45 { samples.append(sample(UInt32(id))) }

        let series = PingChartSeries.build(samples: samples)
        XCTAssertEqual(series.load.map(\.value), [.downloading, .uploading])
        XCTAssertEqual(series.load[0].sampleCount, 10)
        XCTAssertEqual(series.load[1].start, epoch.addingTimeInterval(25))
    }

    func testEmptyInputProducesAUsableDomain() {
        let series = PingChartSeries.build(samples: [], now: epoch)
        XCTAssertTrue(series.isEmpty)
        XCTAssertLessThan(series.xDomain.lowerBound, series.xDomain.upperBound)
        XCTAssertLessThan(series.yDomain.lowerBound, series.yDomain.upperBound)
    }

    func testHostsAreBucketedIndependently() {
        var samples: [PingSample] = []
        // Router replies throughout; internet drops out in the middle.
        for id in 0..<10 { samples.append(sample(UInt32(id), router: 3, internet: 25)) }
        for id in 10..<15 { samples.append(sample(UInt32(id), router: 3, internet: nil)) }
        for id in 15..<25 { samples.append(sample(UInt32(id), router: 3, internet: 25)) }

        let series = PingChartSeries.build(samples: samples)
        XCTAssertEqual(series.router.count, 25, "the router trace is unbroken")
        XCTAssertEqual(Set(series.router.map(\.segment)).count, 1)
        XCTAssertEqual(series.internet.count, 20)
        XCTAssertEqual(Set(series.internet.map(\.segment)).count, 2)
        XCTAssertEqual(series.outages.map(\.value), [.internet])
    }
}
