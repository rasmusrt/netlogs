import XCTest
@testable import NetlogsCore

final class DetailAndExportTests: XCTestCase {

    private func sample(_ id: UInt32, r: Double?, i: Double?, phase: LoadPhase = .idle) -> PingSample {
        PingSample(id: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                   routerMs: r, internetMs: i, phase: phase)
    }

    // MARK: - DetailSummary

    func testTopNAndFailuresMatchBruteForce() {
        var rng = SystemRandomNumberGenerator()
        var samples: [PingSample] = []
        for id in 0..<5_000 {
            let drop = Int.random(in: 0..<50, using: &rng) == 0
            samples.append(sample(UInt32(id),
                                  r: drop ? nil : Double.random(in: 2...60, using: &rng),
                                  i: Double.random(in: 10...120, using: &rng)))
        }

        let d = DetailSummary.build(samples: samples, topN: 10)

        let routerAsc = samples.compactMap { s in s.routerMs.map { ($0, s.id) } }.sorted { $0.0 < $1.0 }
        XCTAssertEqual(d.routerLowest.map(\.id), routerAsc.prefix(10).map { $0.1 })
        XCTAssertEqual(d.routerHighest.map(\.id), routerAsc.suffix(10).reversed().map { $0.1 })
        XCTAssertEqual(d.failures.count, samples.filter { $0.routerMs == nil }.count)
        XCTAssertTrue(d.failures.allSatisfy { $0.routerMs == nil || $0.internetMs == nil })
    }

    func testDetailSummaryEmpty() {
        let d = DetailSummary.build(samples: [])
        XCTAssertTrue(d.routerLowest.isEmpty && d.failures.isEmpty)
    }

    // MARK: - Chart series
    //
    // `PingChartDownsampler` was replaced by `PingChartBucketer`; the bucketer's
    // own behaviour is covered in ChartSeriesTests. What remains here is the
    // property these tests were really protecting — that a long session is
    // reduced to a bounded, ordered, in-span set of points.

    func testLongSessionIsCappedAndKeepsItsSpan() {
        let samples = (0..<3_700).map {
            sample(UInt32($0), r: Double($0 % 40) + 2, i: Double($0 % 90) + 10)
        }
        let series = PingChartSeries.build(samples: samples)

        XCTAssertLessThanOrEqual(series.internet.count, 200)
        XCTAssertGreaterThan(series.internet.count, 100)

        let span = samples.first!.timestamp.timeIntervalSince1970
            ... samples.last!.timestamp.timeIntervalSince1970
        XCTAssertTrue(span.contains(series.internet.first!.time.timeIntervalSince1970))
        XCTAssertTrue(span.contains(series.internet.last!.time.timeIntervalSince1970))

        for point in series.internet + series.router {
            XCTAssertLessThanOrEqual(point.lo, point.avg)
            XCTAssertLessThanOrEqual(point.avg, point.hi)
        }
    }

    func testSmallInputPassesThrough() {
        let samples = (0..<12).map { sample(UInt32($0), r: 5, i: 5) }
        let series = PingChartSeries.build(samples: samples)
        XCTAssertEqual(series.internet.count, 12)
        XCTAssertEqual(series.router.count, 12)
    }

    func testLoadAndFailureAreCarriedAsRunsNotPointFlags() {
        var samples = (0..<40).map { sample(UInt32($0), r: 5, i: 5, phase: .downloading) }
        samples[20] = sample(20, r: nil, i: nil, phase: .downloading)
        let series = PingChartSeries.build(samples: samples)

        XCTAssertEqual(series.load.map(\.value), [.downloading])
        XCTAssertEqual(series.load[0].sampleCount, 40)
        XCTAssertEqual(series.outages.map(\.value), [.both])
        XCTAssertEqual(series.outages[0].sampleCount, 1)
    }

    // MARK: - Export

    private func makeExport(sampleCount: Int) -> SessionExport {
        let samples: [PingSample] = (0..<sampleCount).map { id in
            let router: Double? = (id % 30 == 0) ? nil : (5 + Double(id % 10))
            let internet = 20 + Double(id % 15)
            let phase: LoadPhase = (id % 100 < 10) ? .downloading : .idle
            return sample(UInt32(id), r: router, i: internet, phase: phase)
        }
        let session = SessionState(startedAt: samples.first!.timestamp,
                                   stoppedAt: samples.last!.timestamp,
                                   settings: MonitorSettings())
        let tp = [ThroughputResult(downloadMbps: 248, uploadMbps: 59,
                                   bytesDownloaded: 100_000_000, bytesUploaded: 60_000_000,
                                   idleLatencyMs: 20, downloadLatencyMs: 40, uploadLatencyMs: 130,
                                   isp: "TDC Holding A/S", serverLocation: "CPH")]
        let diag = [DiagnosticsSnapshot(interfaceName: "en0", kind: .wifi, rssi: -60, noise: -90, snr: 30,
                                        txRateMbps: 400, channel: 44, band: "5 GHz", phyMode: "802.11ax",
                                        security: "WPA3 Personal", ipAddress: "192.168.1.17",
                                        subnetMask: "255.255.255.0", gateway: "192.168.1.1",
                                        dnsServers: ["1.1.1.1"], mtu: 1500)]
        return SessionExport(session: session, samples: samples, throughput: tp, diagnostics: diag)
    }

    func testCSVShape() throws {
        let e = makeExport(sampleCount: 100)
        let csv = SessionExporter.csv(e)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.first,
                       "seq,timestamp,router_ms,internet_ms,router_late_ms,internet_late_ms,phase")
        XCTAssertEqual(lines.count, 100 + 1 + 1) // header + rows + trailing newline
        XCTAssertTrue(lines[1].hasPrefix("0,"))
        // Every row leaves both late columns blank here — the fixture's
        // timeouts are true losses. A row with a blank `router_ms` and a number
        // in `router_late_ms` is the case this file exists to keep distinct.
        XCTAssertEqual(lines[1].split(separator: ",", omittingEmptySubsequences: false).count, 7)
        let timeoutRow = try XCTUnwrap(lines.first { $0.hasPrefix("30,") })
        XCTAssertTrue(timeoutRow.contains(",,"), "a lost row leaves router_ms blank")
    }

    func testJSONRoundTrips() throws {
        let e = makeExport(sampleCount: 50)
        let data = try SessionExporter.json(e)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(SessionExport.self, from: data)

        XCTAssertEqual(round.samples.count, e.samples.count)
        XCTAssertEqual(round.summary.totalSamples, e.summary.totalSamples)
        XCTAssertEqual(round.throughput.first?.isp, "TDC Holding A/S")
    }

    func testTextReportContainsKeySections() {
        let e = makeExport(sampleCount: 500)
        let txt = SessionExporter.text(e)
        XCTAssertTrue(txt.contains("NETLOGS SESSION REPORT"))
        XCTAssertTrue(txt.contains("PING SUMMARY"))
        XCTAssertTrue(txt.contains("THROUGHPUT"))
        XCTAssertTrue(txt.contains("bufferbloat"))
        XCTAssertTrue(txt.contains("DIAGNOSTICS"))
        XCTAssertTrue(txt.contains("TDC Holding A/S"))
        XCTAssertTrue(txt.contains("802.11ax"))
        XCTAssertTrue(txt.contains("Verdict      :"))
    }

    func testTextReportListsEachFailureWithTimestamp() {
        // makeExport drops the router reply on every 30th sample: ids 0, 30,
        // …, 270. Nine of them are reported, not ten — id 0 is inside the
        // warm-up window (`PingSample.warmupSampleCount`), which the screens do
        // not judge and neither does the report.
        let e = makeExport(sampleCount: 300)
        let txt = SessionExporter.text(e)
        XCTAssertTrue(txt.contains("MISSED DEADLINES (9)"))
        // "LOST", not "FAILED": the fixture drops the reply outright, with no
        // late arrival, so these really are lost packets and the report is
        // entitled to say so. A late reply prints its round-trip time instead.
        XCTAssertTrue(txt.contains("LOST"))
        // One row per failure, plus header + rule + section title lines.
        let failedRows = txt.split(separator: "\n").filter { $0.contains("LOST") }
        XCTAssertEqual(failedRows.count, 9)
    }

    func testFailuresOnlyTextIsTrimmedAndDiffersFromFull() {
        let e = makeExport(sampleCount: 300)
        let full = SessionExporter.text(e, failuresOnly: false)
        let only = SessionExporter.text(e, failuresOnly: true)
        XCTAssertNotEqual(full, only, "the two scopes used to render the same page")
        // Failures-only keeps the header and the failure log, nothing else.
        XCTAssertTrue(only.contains("MISSED DEADLINES (9)"))
        XCTAssertTrue(only.contains("LOST"))
        XCTAssertFalse(only.contains("PING SUMMARY"))
        XCTAssertFalse(only.contains("THROUGHPUT"))
        XCTAssertFalse(only.contains("DIAGNOSTICS"))
        // The full report still carries the same failure log.
        XCTAssertTrue(full.contains("MISSED DEADLINES (9)"))
    }

    func testFailuresOnlyFilenameIsDistinct() {
        let e = makeExport(sampleCount: 50)
        XCTAssertNotEqual(
            SessionExporter.filename(e, format: .text, failuresOnly: false),
            SessionExporter.filename(e, format: .text, failuresOnly: true)
        )
        XCTAssertTrue(
            SessionExporter.filename(e, format: .text, failuresOnly: true).contains("-failures")
        )
    }

    func testFailuresOnlyScope() {
        let full = makeExport(sampleCount: 300)
        let e = full.filteredToFailures()
        XCTAssertTrue(e.samples.allSatisfy { $0.routerMs == nil || $0.internetMs == nil })
        XCTAssertEqual(e.samples.count, 9) // ids 30,60,…,270; id 0 is warm-up
    }

    /// A filtered *view* of a session still has to describe the session. It
    /// used to rebuild the summary from the failures alone, so a healthy run
    /// with a handful of drops exported a block claiming 100% packet loss and
    /// zero internet replies.
    func testFailuresOnlySummaryStillDescribesTheWholeSession() {
        let full = makeExport(sampleCount: 300)
        let only = full.filteredToFailures()

        XCTAssertEqual(only.summary, full.summary)
        XCTAssertEqual(only.summary.totalSamples, 298) // 300 less the warm-up pair
        XCTAssertGreaterThan(only.summary.internet.samples, 0)
    }

    /// The warm-up exclusion, applied here as it is on every screen: a session
    /// the app calls clean must not export a failure and a spike.
    func testExportSummaryExcludesTheWarmUpSamples() {
        let e = makeExport(sampleCount: 300)
        XCTAssertEqual(e.summary.totalSamples, 298)
        XCTAssertEqual(e.samples.count, 300, "the raw rows keep everything")
        XCTAssertEqual(e.failures.count, 9)
        XCTAssertTrue(e.failures.allSatisfy { $0.id >= PingSample.warmupSampleCount })
    }

    func testLargeExportIsQuick() {
        // 3 h at 1 Hz ≈ 10,800 samples — building all three formats should be fast.
        let e = makeExport(sampleCount: 10_800)
        let start = DispatchTime.now()
        _ = SessionExporter.csv(e)
        _ = try? SessionExporter.json(e)
        _ = SessionExporter.text(e)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        XCTAssertLessThan(seconds, 1.0, "all three exports of a 3 h session in \(seconds) s")
    }
}
