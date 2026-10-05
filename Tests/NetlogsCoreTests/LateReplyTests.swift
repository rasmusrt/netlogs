import XCTest
@testable import NetlogsCore

/// The distinction between "the packet was lost" and "the packet was late".
///
/// Written against a real session: eleven hours at 1 Hz, 39,061 samples, 14
/// reported failures, and a maximum recorded internet RTT of 1942.1 ms against
/// a 2000 ms timeout. The distribution was clipped exactly at the deadline —
/// every failure was a reply the pinger stopped listening for, and three of the
/// five clusters began eleven seconds into the app's own scheduled upload test.
/// The user took "14 lost packets" to their ISP. Nothing had been lost.
final class LateReplyTests: XCTestCase {

    private func sample(
        id: UInt32 = 0,
        router: Double? = 5, internet: Double? = 20,
        routerLate: Double? = nil, internetLate: Double? = nil,
        phase: LoadPhase = .idle
    ) -> PingSample {
        PingSample(id: id, timestamp: Date(timeIntervalSince1970: 1000 + Double(id)),
                   routerMs: router, internetMs: internet,
                   routerLateMs: routerLate, internetLateMs: internetLate, phase: phase)
    }

    // MARK: - The sample's own vocabulary

    func testLateReplyIsATimeoutButNotALoss() {
        let late = sample(internet: nil, internetLate: 2410)

        XCTAssertTrue(late.internetTimedOut, "it missed its deadline, and that has not changed")
        XCTAssertTrue(late.internetWasLate)
        XCTAssertFalse(late.internetNoReply, "the packet arrived — 410 ms late, but it arrived")
        XCTAssertEqual(late.internetRttMs, 2410, "and the chart has a number to draw")
    }

    func testSilenceIsALoss() {
        let lost = sample(internet: nil)
        XCTAssertTrue(lost.internetTimedOut)
        XCTAssertTrue(lost.internetNoReply)
        XCTAssertNil(lost.internetRttMs)
    }

    // MARK: - Counting

    func testBuilderSplitsLostFromLateFromSelfInflicted() {
        var b = LiveSummaryBuilder()
        for i in 0..<10 { b.add(sample(id: UInt32(i))) }             // 10 clean
        b.add(sample(id: 10, internet: nil))                          // 1 lost
        b.add(sample(id: 11, internet: nil, internetLate: 2100))      // 1 late
        b.add(sample(id: 12, internet: nil, internetLate: 2400,
                     phase: .uploading))                              // 1 late, our own load
        b.add(sample(id: 13, internet: nil, phase: .uploading))       // 1 lost, our own load
        let s = b.summary

        XCTAssertEqual(s.totalSamples, 14)
        XCTAssertEqual(s.failureCount, 4, "four probes missed their deadline")
        XCTAssertEqual(s.lateCount, 2)
        XCTAssertEqual(s.noReplyCount, 2)
        XCTAssertEqual(s.failuresUnderLoad, 2)
        XCTAssertEqual(s.failuresIdle, 2)
        XCTAssertEqual(s.internetNoRepliesIdle, 1,
                       "the only silence on a link we were not loading ourselves")
    }

    func testLateRepliesStayOutOfTheTimelyLatencyStat() {
        var b = LiveSummaryBuilder()
        for i in 0..<5 { b.add(sample(id: UInt32(i), internet: 20)) }
        b.add(sample(id: 5, internet: nil, internetLate: 2400))
        let s = b.summary

        XCTAssertEqual(s.internet.samples, 5, "a late reply is not a timely one")
        XCTAssertEqual(s.internet.max, 20, accuracy: 1e-9,
                       "PingStat.max cannot exceed the timeout — that is the whole problem")
        XCTAssertEqual(s.internetLate.count, 1)
        XCTAssertEqual(s.internetLate.max, 2400)
        XCTAssertEqual(s.internetLate.worst(timelyMax: s.internet.max), 2400,
                       "and this is the figure that finally reaches past it")
    }

    func testJitterDoesNotDifferenceAcrossALateReply() {
        var withLate = LiveSummaryBuilder()
        withLate.add(sample(internet: 20))
        withLate.add(sample(id: 1, internet: nil, internetLate: 2400))
        withLate.add(sample(id: 2, internet: 20))

        var withLoss = LiveSummaryBuilder()
        withLoss.add(sample(internet: 20))
        withLoss.add(sample(id: 1, internet: nil))
        withLoss.add(sample(id: 2, internet: 20))

        XCTAssertEqual(withLate.summary.internet.jitter, withLoss.summary.internet.jitter,
                       "a gap is a gap: the late RTT must not become a jitter pair")
    }

    // MARK: - The verdict

    private func session(
        lost: Int = 0, late: Int = 0,
        lateUnderLoad: Int = 0, lostUnderLoad: Int = 0,
        samples: Int = 1000
    ) -> LiveSummary {
        var b = LiveSummaryBuilder()
        var id: UInt32 = 0
        func add(_ s: PingSample) { b.add(s); id += 1 }
        for _ in 0..<lost { add(sample(id: id, internet: nil)) }
        for _ in 0..<late { add(sample(id: id, internet: nil, internetLate: 2400)) }
        for _ in 0..<lateUnderLoad {
            add(sample(id: id, internet: nil, internetLate: 2400, phase: .uploading))
        }
        for _ in 0..<lostUnderLoad {
            add(sample(id: id, internet: nil, phase: .uploading))
        }
        while Int(id) < samples { add(sample(id: id, internet: 20)) }
        return b.summary
    }

    func testTheRealSessionNoLongerReadsAsPacketLoss() {
        // 39,061 samples, 14 missed deadlines, every one of them a reply on a
        // latency ramp that crossed the deadline — neighbouring samples read
        // 1.5–1.9 s — and three of them eleven seconds into a scheduled upload
        // test. The router answered all 39,061 in 3–8 ms throughout.
        let s = session(late: 11, lateUnderLoad: 3, samples: 39_061)

        XCTAssertEqual(s.failureCount, 14, "the probes did miss their deadlines")
        XCTAssertEqual(s.noReplyCount, 0, "and not one packet was lost")
        XCTAssertEqual(s.lateCount, 14)
        XCTAssertEqual(s.failuresUnderLoad, 3, "three of them we caused ourselves")
        XCTAssertEqual(s.internetNoRepliesIdle, 0)
        XCTAssertEqual(s.lossFraction, 0)
        XCTAssertEqual(SessionVerdict.evaluate(summary: s), .good)

        let reason = SessionVerdict.reason(for: .good, summary: s)
        XCTAssertTrue(reason.contains("no loss"), reason)
        XCTAssertTrue(reason.contains("14 slow replies"), reason)
        XCTAssertTrue(reason.contains("3 during speed tests"), reason)
    }

    func testSelfInflictedTimeoutsDoNotGradeTheNetwork() {
        // 6% of samples silent — comfortably "lossy" — but all of it during our
        // own speed test. Grading the network on it grades our load generator.
        let s = session(lostUnderLoad: 60, samples: 1000)
        XCTAssertEqual(s.failureCount, 60)
        XCTAssertEqual(s.noReplyCount, 60, "they really did send nothing")
        XCTAssertEqual(s.internetNoRepliesIdle, 0, "…while we were filling the uplink")
        XCTAssertEqual(SessionVerdict.evaluate(summary: s), .good)
    }

    func testRealLossStillGradesAsLossy() {
        let s = session(lost: 60, samples: 1000)
        XCTAssertEqual(SessionVerdict.evaluate(summary: s), .lossy)
        XCTAssertTrue(SessionVerdict.reason(for: .lossy, summary: s).contains("60 of 1000"))
    }

    func testAnUnsplitSummaryStillReportsItsLoss() {
        // Every construction site that predates the split — the decode path for
        // an old export, and every test written before this file.
        let old = LiveSummary(
            internet: PingStat(avg: 20, samples: 940),
            totalSamples: 1000, internetTimeouts: 60, failureCount: 60
        )
        XCTAssertEqual(old.internetNoRepliesIdle, 60,
                       "unstated means lost, never means fine")
        XCTAssertEqual(SessionVerdict.evaluate(summary: old), .lossy)
    }

    // MARK: - Engine and storage

    func testEngineCarriesTheLateRttOntoTheSample() async throws {
        let fake = FakeLatePinger()
        let engine = MonitorEngine(
            settings: MonitorSettings(routerHost: "r", internetHost: "i",
                                      pingInterval: .milliseconds(50), pingTimeout: .seconds(1)),
            pingerFactory: { _, _ in fake },
            throughputProvider: nil
        )
        let stream = try await engine.start(warmup: .zero)
        var seen: [PingSample] = []
        for await s in stream {
            seen.append(s)
            if seen.count == 3 { await engine.stop() }
        }
        let first = try XCTUnwrap(seen.first)
        XCTAssertNil(first.internetMs, "a late reply is still a miss in the timely column")
        XCTAssertEqual(first.internetLateMs, 2400)
        XCTAssertEqual(first.routerMs, 5)
    }

    func testLateColumnsRoundTripAndAggregate() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("late-\(UUID()).sqlite")
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close(); try? FileManager.default.removeItem(at: url) }
        let session = try store.startSession(MonitorSettings())

        // Two warm-up samples the aggregate skips, then the interesting ones.
        var samples = [sample(id: 0), sample(id: 1)]
        samples.append(sample(id: 2, internet: nil, internetLate: 2400))
        samples.append(sample(id: 3, internet: nil))
        samples.append(sample(id: 4, internet: nil, internetLate: 2100, phase: .uploading))
        samples.append(sample(id: 5, internet: 20, phase: .uploading))
        store.append(samples, to: session.id)
        try store.flush()

        let back = try store.samples(for: session.id)
        XCTAssertEqual(back.count, 6)
        XCTAssertEqual(back[2].internetLateMs, 2400)
        XCTAssertNil(back[3].internetLateMs)

        let agg = try XCTUnwrap(store.pingAggregates(for: [session.id])[session.id])
        XCTAssertEqual(agg.totalSamples, 4, "warm-up excluded")
        XCTAssertEqual(agg.failureCount, 3)
        XCTAssertEqual(agg.lateCount, 2)
        XCTAssertEqual(agg.noReplyCount, 1)
        XCTAssertEqual(agg.failuresUnderLoad, 1)
        XCTAssertEqual(agg.samplesUnderLoad, 2)
        XCTAssertEqual(agg.internet.late.count, 2)
        XCTAssertEqual(agg.internet.late.max, 2400)
        XCTAssertEqual(agg.internet.worstMs, 2400,
                       "the slowest round trip actually observed, not the timeout")
    }

    /// The SQL and the Swift fold have to agree about the split too, not just
    /// about the totals — `RangeCheck` exists because they once did not.
    func testSqlAndSwiftAgreeOnTheSplit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("late-agree-\(UUID()).sqlite")
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close(); try? FileManager.default.removeItem(at: url) }
        let session = try store.startSession(MonitorSettings())

        var samples: [PingSample] = []
        for i in 0..<200 {
            let id = UInt32(i)
            switch i % 17 {
            case 3:  samples.append(sample(id: id, internet: nil, internetLate: 2000 + Double(i)))
            case 7:  samples.append(sample(id: id, internet: nil))
            case 11: samples.append(sample(id: id, internet: nil, phase: .downloading))
            case 13: samples.append(sample(id: id, router: nil, internet: 20))
            default: samples.append(sample(id: id))
            }
        }
        store.append(samples, to: session.id)
        try store.flush()

        var b = LiveSummaryBuilder()
        for s in samples where s.id >= PingSample.warmupSampleCount { b.add(s) }
        let swiftSide = b.summary
        let sql = try XCTUnwrap(store.pingAggregates(for: [session.id])[session.id])

        XCTAssertEqual(sql.totalSamples, swiftSide.totalSamples)
        XCTAssertEqual(sql.failureCount, swiftSide.failureCount)
        XCTAssertEqual(sql.lateCount, swiftSide.lateCount)
        XCTAssertEqual(sql.noReplyCount, swiftSide.noReplyCount)
        XCTAssertEqual(sql.failuresUnderLoad, swiftSide.failuresUnderLoad)
        XCTAssertEqual(sql.internetNoRepliesIdle, swiftSide.internetNoRepliesIdle,
                       "the number both the verdict and the Analysis score run on")
        XCTAssertEqual(sql.internet.late.count, swiftSide.internetLate.count)
        XCTAssertEqual(sql.internet.late.max, swiftSide.internetLate.max)
    }
}

/// Router answers on time, internet answers 400 ms past a 2 s deadline.
private final class FakeLatePinger: ICMPPinging, @unchecked Sendable {
    func open() throws {}
    func close() {}
    func ping(host: String, sequence: UInt32) async -> PingOutcome {
        host == "r" ? .reply(rttMs: 5) : .lateReply(rttMs: 2400)
    }
}

/// Schema 8: the lost/late/self-inflicted split, carried onto the session row.
///
/// The one-figure summary was the last place in the app that could not tell a
/// dropped packet from a slow one — and it is the figure the sidebar's status
/// dot is coloured by, so getting it wrong here paints a red dot on a session
/// that lost nothing.
final class SessionSummarySplitTests: XCTestCase {

    private func store() throws -> (SessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sum-\(UUID()).sqlite")
        return (try SessionStore(url: url, flushInterval: .zero), url)
    }

    private func sample(_ id: UInt32, internet: Double?, late: Double? = nil,
                        phase: LoadPhase = .idle) -> PingSample {
        PingSample(id: id, timestamp: Date(timeIntervalSince1970: 1000 + Double(id)),
                   routerMs: 5, internetMs: internet, routerLateMs: nil,
                   internetLateMs: late, phase: phase)
    }

    func testSummaryStoresTheSplitAndReadsItBack() throws {
        let (store, url) = try store()
        defer { store.close(); try? FileManager.default.removeItem(at: url) }
        let session = try store.startSession(MonitorSettings())

        var samples = [sample(0, internet: 20), sample(1, internet: 20)] // warm-up
        for i in 2..<50 { samples.append(sample(UInt32(i), internet: 20)) }
        samples.append(sample(50, internet: nil))                          // lost
        samples.append(sample(51, internet: nil, late: 2400))              // late
        samples.append(sample(52, internet: nil, phase: .uploading))       // ours
        store.append(samples, to: session.id)
        try store.flush()
        try store.stopSession(session.id)

        let back = try XCTUnwrap(try store.loadSession(session.id)?.summary)
        XCTAssertEqual(back.failures, 3, "three probes missed their deadline")
        XCTAssertEqual(back.lost, 2, "…and only two of them sent nothing")
        XCTAssertEqual(back.late, 1)
        XCTAssertEqual(back.underLoad, 1)
        XCTAssertEqual(back.lossRatio, 2.0 / Double(back.ticks), accuracy: 1e-9,
                       "the ratio is over lost, not over timeouts")
    }

    func testStatusIsCleanDegradedLost() {
        func summary(lost: Int, late: Int, samples: Int = 1000, p95: Double = 30)
            -> SessionSummary {
            SessionSummary(samples: samples, failures: lost + late,
                           lost: lost, late: late, underLoad: 0,
                           minMs: 10, avgMs: 20, maxMs: 40, p95Ms: p95, spark: nil)
        }
        XCTAssertEqual(summary(lost: 0, late: 0).status(), SessionSummary.Status.clean)
        // The session that started all this: fourteen missed deadlines, none of
        // them lost. Worth a dot, not a red one.
        XCTAssertEqual(summary(lost: 0, late: 14).status(), SessionSummary.Status.degraded)
        XCTAssertEqual(summary(lost: 1, late: 0).status(), SessionSummary.Status.degraded,
                       "below the reporting threshold is not the same as clean")
        XCTAssertEqual(summary(lost: 60, late: 0).status(), SessionSummary.Status.lost)
        XCTAssertEqual(summary(lost: 0, late: 0, p95: 400).status(), SessionSummary.Status.degraded)
    }

    func testAnUnsplitSummaryCountsEveryTimeoutAsLost() {
        // A row written before schema 8, read before the backfill reaches it.
        let old = SessionSummary(samples: 940, failures: 60,
                                 minMs: 10, avgMs: 20, maxMs: 40, p95Ms: 30, spark: nil)
        XCTAssertEqual(old.lost, 60, "unstated means lost, never means fine")
        XCTAssertEqual(old.status(), SessionSummary.Status.lost)
    }

    func testBackfillRewritesRowsSummarisedBeforeTheSplit() throws {
        let (store, url) = try store()
        defer { store.close(); try? FileManager.default.removeItem(at: url) }
        let session = try store.startSession(MonitorSettings())
        var samples = [sample(0, internet: 20), sample(1, internet: 20)]
        for i in 2..<50 { samples.append(sample(UInt32(i), internet: 20)) }
        samples.append(sample(50, internet: nil, late: 2400))
        store.append(samples, to: session.id)
        try store.flush()
        try store.stopSession(session.id)

        // Put the row back into its schema-6 state: summarised, but with no
        // split — exactly what an existing database looks like on first launch.
        try store.clearSummarySplitForTesting(session.id)
        let stale = try XCTUnwrap(try store.loadSession(session.id)?.summary)
        XCTAssertEqual(stale.lost, 1, "the conservative fallback, before backfill")

        XCTAssertEqual(try store.backfillSummaries(), 1)
        let fixed = try XCTUnwrap(try store.loadSession(session.id)?.summary)
        XCTAssertEqual(fixed.lost, 0, "recomputed from the samples, which have the late RTT")
        XCTAssertEqual(fixed.late, 1)
        XCTAssertEqual(fixed.status(), SessionSummary.Status.degraded)
    }
}
