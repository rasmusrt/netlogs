import XCTest
@testable import NetlogsCore

/// Schema 6: the summary the sidebar draws a row from without touching
/// `ping_samples`.
final class SessionSummaryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netlogs-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func dbURL(_ name: String = "t.sqlite") -> URL { dir.appendingPathComponent(name) }

    private func sample(_ id: UInt32, internet: Double?) -> PingSample {
        PingSample(id: id,
                   timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                   routerMs: 3, internetMs: internet, phase: .idle)
    }

    // MARK: - The blob

    func testSparklineRoundTripsThroughItsBlob() throws {
        let line = Sparkline(values: [12.3, nil, 400.0, 0.4])
        let back = try XCTUnwrap(Sparkline(data: line.data))
        XCTAssertEqual(back.values.count, 4)
        XCTAssertEqual(back.values[0], 12.3)
        XCTAssertNil(back.values[1])
        XCTAssertEqual(back.values[2], 400.0)
        XCTAssertEqual(back.values[3], 0.4)
    }

    /// A dropped sparkline costs one blank row; a misparsed one draws a lie.
    func testSparklineRejectsBlobsItDidNotWrite() {
        XCTAssertNil(Sparkline(data: Data()))
        XCTAssertNil(Sparkline(data: Data([9, 1, 0, 0])))          // wrong version
        XCTAssertNil(Sparkline(data: Data([1, 4, 0, 0])))          // truncated
        XCTAssertNil(Sparkline(data: Data([1, 1, 0, 0, 0, 0])))    // too long
    }

    func testSparklineClampsRatherThanWrapping() throws {
        let line = Sparkline(values: [1_000_000, -5])
        let back = try XCTUnwrap(Sparkline(data: line.data))
        XCTAssertEqual(back.values[0], Double(Sparkline.noData - 1) / 10)
        XCTAssertNil(back.values[1])
    }

    // MARK: - The fold

    func testStoppingASessionSummarisesIt() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let session = try store.startSession(MonitorSettings())
        // Two warm-up samples, then 10, 20, …, 100 and two silences.
        store.append([sample(0, internet: 5_000), sample(1, internet: 5_000)], to: session.id)
        store.append((0..<10).map { sample(UInt32($0) + 2, internet: Double($0 + 1) * 10) },
                     to: session.id)
        store.append([sample(12, internet: nil), sample(13, internet: nil)], to: session.id)
        try store.stopSession(session.id)

        let summary = try XCTUnwrap(try store.loadSession(session.id)?.summary)
        XCTAssertEqual(summary.samples, 10)
        XCTAssertEqual(summary.failures, 2)
        XCTAssertEqual(summary.minMs, 10, accuracy: 0.001)
        XCTAssertEqual(summary.maxMs, 100, accuracy: 0.001)
        XCTAssertEqual(summary.avgMs, 55, accuracy: 0.001)
        XCTAssertEqual(summary.ticks, 12)
        XCTAssertEqual(summary.lossRatio, 2.0 / 12, accuracy: 0.001)
        XCTAssertNotNil(summary.spark)
    }

    /// The warm-up spike is excluded here for the same reason it is excluded
    /// from the session statistics and the chart's y-axis.
    func testTheWarmupSpikeDoesNotSetTheSummary() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let session = try store.startSession(MonitorSettings())
        store.append([sample(0, internet: 580), sample(1, internet: 400)], to: session.id)
        store.append((2..<20).map { sample($0, internet: 20) }, to: session.id)
        try store.stopSession(session.id)

        let summary = try XCTUnwrap(try store.loadSession(session.id)?.summary)
        XCTAssertEqual(summary.maxMs, 20, accuracy: 0.001)
        XCTAssertEqual(summary.samples, 18)
    }

    /// The p95 comes from the same integer-millisecond histogram the Analysis
    /// screen uses, so the two cannot disagree by a rounding rule.
    func testThePercentileMatchesTheHistogramTheAnalysisScreenUses() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let session = try store.startSession(MonitorSettings())
        store.append((0..<102).map { sample($0, internet: Double($0 % 100) + 1) },
                     to: session.id)
        try store.stopSession(session.id)

        let summary = try XCTUnwrap(try store.loadSession(session.id)?.summary)
        let histogram = try XCTUnwrap(try store.latencyHistograms(for: [session.id])[session.id])
        XCTAssertEqual(summary.p95Ms, histogram.p95, accuracy: 0.001)
    }

    /// A session that never replied summarises to zeros — which is an answer,
    /// and has to be distinguishable from never having been summarised, or the
    /// backfill folds it again on every launch.
    func testASessionThatNeverRepliedIsStillSummarised() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let session = try store.startSession(MonitorSettings())
        store.append((0..<20).map { sample($0, internet: nil) }, to: session.id)
        try store.stopSession(session.id)

        let summary = try XCTUnwrap(try store.loadSession(session.id)?.summary)
        XCTAssertEqual(summary.samples, 0)
        XCTAssertEqual(summary.failures, 18)
        XCTAssertNil(summary.spark)
        XCTAssertEqual(try store.backfillSummaries(), 0, "already summarised")
    }

    // MARK: - Backfill

    func testBackfillSummarisesASessionThatWasNeverStopped() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let crashed = try store.startSession(MonitorSettings())
        store.append((0..<30).map { sample($0, internet: 40) }, to: crashed.id)
        try store.flush()

        XCTAssertNil(try store.loadSession(crashed.id)?.summary)
        XCTAssertEqual(try store.backfillSummaries(), 1)

        let summary = try XCTUnwrap(try store.loadSession(crashed.id)?.summary)
        XCTAssertEqual(summary.samples, 28)
        XCTAssertEqual(summary.avgMs, 40, accuracy: 0.001)
        XCTAssertEqual(try store.backfillSummaries(), 0, "a second pass has nothing to do")
    }

    /// The running session's row exists from the moment it starts. Summarising
    /// it would store a figure for something still growing.
    func testBackfillSkipsTheRunningSession() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let running = try store.startSession(MonitorSettings())
        store.append((0..<30).map { sample($0, internet: 40) }, to: running.id)
        try store.flush()

        XCTAssertEqual(try store.backfillSummaries(excluding: running.id), 0)
        XCTAssertNil(try store.loadSession(running.id)?.summary)
    }

    // MARK: - The sparkline itself

    func testTheSparklineTracksWhenTheLatencyActuallyRose() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        // 480 samples one second apart: 10 ms for the first half, 100 for the
        // second. At 48 buckets that is ten samples a bucket.
        let session = try store.startSession(MonitorSettings())
        store.append((0..<480).map { sample($0, internet: $0 < 240 ? 10 : 100) },
                     to: session.id)
        try store.stopSession(session.id)

        let spark = try XCTUnwrap(try store.loadSession(session.id)?.summary?.spark)
        XCTAssertEqual(spark.values.count, Sparkline.bucketCount)
        XCTAssertEqual(try XCTUnwrap(spark.values[2]), 10, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(spark.values[45]), 100, accuracy: 0.5)
        XCTAssertEqual(spark.range?.lowerBound ?? 0, 10, accuracy: 0.5)
        XCTAssertEqual(spark.range?.upperBound ?? 0, 100, accuracy: 0.5)
    }

    /// Bucketed by wall clock, not by sample index: a session that stopped
    /// measuring for a stretch draws a gap rather than closing it up.
    func testAGapInMeasurementIsAGapInTheLine() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let session = try store.startSession(MonitorSettings())
        store.append((0..<20).map { sample($0, internet: 20) }, to: session.id)
        // Nothing for an hour, then twenty more.
        store.append((0..<20).map {
            PingSample(id: 3_600 + $0,
                       timestamp: Date(timeIntervalSince1970: 1_700_003_600 + Double($0)),
                       routerMs: 3, internetMs: 20, phase: .idle)
        }, to: session.id)
        try store.stopSession(session.id)

        let spark = try XCTUnwrap(try store.loadSession(session.id)?.summary?.spark)
        XCTAssertNotNil(spark.values.first.flatMap { $0 })
        XCTAssertNotNil(spark.values.last.flatMap { $0 })
        XCTAssertTrue(spark.values.dropFirst().dropLast().contains { $0 == nil },
                      "the hour with no samples should be empty buckets")
    }
}
