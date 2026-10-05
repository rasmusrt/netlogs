import XCTest
import SQLite3
@testable import NetlogsCore

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [T] = []
    func append(_ v: T) { lock.lock(); value.append(v); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return value }
}

/// RTT as a function of sequence number, so a test can make "loaded" pings slow.
private final class RampPinger: ICMPPinging, @unchecked Sendable {
    let rtt: @Sendable (UInt32) -> Double
    init(rtt: @escaping @Sendable (UInt32) -> Double) { self.rtt = rtt }
    func open() throws {}
    func close() {}
    func ping(host: String, sequence: UInt32) async -> PingOutcome { .reply(rttMs: rtt(sequence)) }
}

private struct FakeThroughput: ThroughputProvider {
    func measureDownload(duration: Duration, discardingFirst warmup: Duration) async -> ThroughputMeasurement {
        try? await Task.sleep(for: duration)
        return ThroughputMeasurement(bytes: 300_000_000, seconds: 9)   // ≈ 266 Mbps
    }
    func measureUpload(duration: Duration, discardingFirst warmup: Duration) async -> ThroughputMeasurement {
        try? await Task.sleep(for: duration)
        return ThroughputMeasurement(bytes: 70_000_000, seconds: 9)    // ≈ 62 Mbps
    }
    func fetchMeta() async -> ThroughputMeta? { ThroughputMeta(isp: "FakeISP", colo: "TST") }
}

final class ThroughputTests: XCTestCase {

    // MARK: - Model

    func testBufferbloatMath() throws {
        let r = ThroughputResult(
            downloadMbps: 250, uploadMbps: 60, bytesDownloaded: 1, bytesUploaded: 1,
            idleLatencyMs: 20, downloadLatencyMs: 41, uploadLatencyMs: 500
        )
        XCTAssertEqual(try XCTUnwrap(r.bufferbloatMs), 480, accuracy: 1e-9, "max(41,500) − 20")

        let clean = ThroughputResult(
            downloadMbps: 100, uploadMbps: 100, bytesDownloaded: 1, bytesUploaded: 1,
            idleLatencyMs: 30, downloadLatencyMs: 25, uploadLatencyMs: 28
        )
        XCTAssertEqual(clean.bufferbloatMs, 0, "never negative")
    }

    /// The defect schema 5 undoes: an idle window that caught no replies was
    /// stored as 0 ms, and `max(load) − 0` reported the whole load latency as
    /// bufferbloat — 210 ms and a "poor" grade out of a window that measured
    /// nothing.
    func testUnmeasuredIdleWindowFabricatesNothing() {
        let r = ThroughputResult(
            downloadMbps: 250, uploadMbps: 60, bytesDownloaded: 1, bytesUploaded: 1,
            idleLatencyMs: nil, downloadLatencyMs: 210, uploadLatencyMs: 180
        )
        XCTAssertNil(r.bufferbloatMs, "no baseline, no subtraction")
        XCTAssertNil(r.idleLatencyMs)
        XCTAssertEqual(try XCTUnwrap(r.loadedLatencyMs), 210, accuracy: 1e-9,
                       "the load figures were measured and still stand")

        let averages = ThroughputAverages(results: [r])
        XCTAssertNil(averages.bufferbloatMs)
        XCTAssertNil(averages.grade, "nothing to grade")
        XCTAssertNil(averages.latencyMs)
        XCTAssertEqual(averages.count, 1, "the test still happened")

        // And the verdict cannot call a session bloated on the strength of it.
        let summary = LiveSummary(
            internet: PingStat(min: 10, avg: 20, max: 30, jitter: 2,
                               p50: 20, p95: 25, p99: 28, samples: 600),
            totalSamples: 600
        )
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary, throughput: averages), .good)
    }

    /// A direction that measured nothing cannot be the heavier one.
    func testHeavierDirectionIgnoresUnmeasuredWindows() throws {
        let r = ThroughputResult(
            downloadMbps: 100, uploadMbps: 10, bytesDownloaded: 1, bytesUploaded: 1,
            idleLatencyMs: 20, downloadLatencyMs: nil, uploadLatencyMs: 90
        )
        XCTAssertEqual(try XCTUnwrap(r.loadedLatencyMs), 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.bufferbloatMs), 70, accuracy: 1e-9)
    }

    func testMeasurementMbps() {
        XCTAssertEqual(ThroughputMeasurement(bytes: 125_000_000, seconds: 10).mbps, 100, accuracy: 1e-6)
        XCTAssertEqual(ThroughputMeasurement(bytes: 0, seconds: 0).mbps, 0)
    }

    func testResultRoundTrips() throws {
        let r = ThroughputResult(
            downloadMbps: 248.3, uploadMbps: 58.7, bytesDownloaded: 283_000_000, bytesUploaded: 66_000_000,
            idleLatencyMs: 18, downloadLatencyMs: 39, uploadLatencyMs: 210,
            isp: "TDC Holding A/S", serverLocation: "CPH"
        )
        let back = try JSONDecoder().decode(ThroughputResult.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }

    /// Every figure is an average at any count — the `latest*` parallel set and
    /// the `count >= 3` switch are gone (plan §13 Q2, reversed deliberately).
    func testAveragesAtEveryCount() {
        func result(_ down: Double, loadedBy up: Double) -> ThroughputResult {
            ThroughputResult(downloadMbps: down, uploadMbps: 10,
                             bytesDownloaded: 1, bytesUploaded: 1,
                             idleLatencyMs: 20, downloadLatencyMs: up, uploadLatencyMs: 30,
                             downloadJitterMs: 8)
        }
        let one = ThroughputAverages(results: [result(100, loadedBy: 90)])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.downloadMbps, 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(one.loadedLatencyMs), 90, accuracy: 1e-9,
                       "the heavier direction, same one bufferbloat comes from")

        let two = ThroughputAverages(results: [result(100, loadedBy: 90), result(200, loadedBy: 110)])
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.downloadMbps, 150, accuracy: 1e-9, "averaged, not the latest")
        XCTAssertEqual(try XCTUnwrap(two.loadedLatencyMs), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(two.loadedJitterMs), 8, accuracy: 1e-9)
    }

    func testLoadedFiguresComeFromOneDirection() throws {
        // Upload is the heavier direction here, and its jitter is nil — the
        // pair must not fall back to the download's, which would describe a
        // moment that never happened.
        let r = ThroughputResult(downloadMbps: 100, uploadMbps: 10,
                                 bytesDownloaded: 1, bytesUploaded: 1,
                                 idleLatencyMs: 20, downloadLatencyMs: 40, uploadLatencyMs: 400,
                                 downloadJitterMs: 5, uploadJitterMs: nil)
        XCTAssertEqual(try XCTUnwrap(r.loadedLatencyMs), 400, accuracy: 1e-9)
        XCTAssertNil(r.loadedJitterMs)
    }

    // MARK: - Engine: load tagging + latency derivation

    func testThroughputTestTagsSamplesAndDerivesBufferbloat() async throws {
        // Samples 0–5 are "idle" (~15 ms); from sample 6 on they're "loaded"
        // (~220 ms). Keyed on the tick rather than the raw wire sequence: the
        // top bit names the probe (`ProbeHost`), so the internet host's
        // sequences all start at 0x8000 and a naive `seq <= 6` read every one
        // of them as loaded. The id is the tick plus one — the engine never
        // sends wire sequence 0, because 1.1.1.1 does not answer it.
        let pinger = RampPinger(rtt: { seq in ProbeHost.tick(fromWire: seq) <= 6 ? 15 : 220 })
        let engine = MonitorEngine(
            settings: MonitorSettings(
                routerHost: "r", internetHost: "i",
                pingInterval: .milliseconds(50), pingTimeout: .seconds(1),
                throughputEnabled: false // triggered manually below
            ),
            pingerFactory: { _, _ in pinger },
            throughputProvider: FakeThroughput()
        )

        let samples = Box<PingSample>()
        let results = Box<ThroughputResult>()

        let resultStream = await engine.throughputResults()
        let sampleStream = try await engine.start(warmup: .zero)
        let sc = Task { for await s in sampleStream { samples.append(s) } }
        let rc = Task { for await r in resultStream { results.append(r) } }

        try await Task.sleep(for: .milliseconds(350)) // ~7 idle pings
        await engine.runThroughputTestNow(
            directionDuration: .milliseconds(500),
            settle: .milliseconds(150),
            warmup: .milliseconds(80)
        )
        try await Task.sleep(for: .milliseconds(100))
        await engine.stop()
        _ = await sc.value
        _ = await rc.value

        let phases = Set(samples.all.map(\.phase))
        XCTAssertTrue(phases.contains(.downloading), "some samples tagged .downloading")
        XCTAssertTrue(phases.contains(.uploading), "some samples tagged .uploading")

        let result = try XCTUnwrap(results.all.first)
        XCTAssertEqual(result.downloadMbps, 266.6, accuracy: 5)
        XCTAssertEqual(result.uploadMbps, 62.2, accuracy: 5)
        XCTAssertEqual(result.isp, "FakeISP")
        XCTAssertEqual(result.serverLocation, "TST")
        XCTAssertLessThan(try XCTUnwrap(result.idleLatencyMs), 60,
                          "idle window caught the ~15 ms pings")
        XCTAssertGreaterThan(try XCTUnwrap(result.downloadLatencyMs), 150,
                             "load window caught the ~220 ms pings")
        XCTAssertGreaterThan(try XCTUnwrap(result.bufferbloatMs), 80,
                             "load latency well above idle")
    }

    // MARK: - Storage

    func testPersistsThroughputRow() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID()).sqlite")
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        let session = try store.startSession(MonitorSettings())
        let r = ThroughputResult(
            downloadMbps: 248.3, uploadMbps: 58.7, bytesDownloaded: 283_000_000, bytesUploaded: 66_000_000,
            idleLatencyMs: 18, downloadLatencyMs: 39, uploadLatencyMs: 210,
            isp: "TDC Holding A/S", serverLocation: "CPH"
        )
        try store.appendThroughput(r, to: session.id)

        XCTAssertEqual(try store.throughputCount(for: session.id), 1)
        let back = try XCTUnwrap(try store.throughputResults(for: session.id).first)
        XCTAssertEqual(back.downloadMbps, 248.3, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(back.bufferbloatMs), 192, accuracy: 1e-6) // recomputed in init
        XCTAssertEqual(back.serverLocation, "CPH")
    }

    // MARK: - Schema 3: unmeasured is not zero

    func testUnmeasuredJitterAndLossPersistAsNull() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID()).sqlite")
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        let session = try store.startSession(MonitorSettings())
        // A test whose idle window never got two consecutive replies. The
        // figures are unknown, and a `0` would read as a flawless connection.
        try store.appendThroughput(
            ThroughputResult(downloadMbps: 100, uploadMbps: 10,
                             bytesDownloaded: 1, bytesUploaded: 1,
                             idleLatencyMs: 18, downloadLatencyMs: 39, uploadLatencyMs: 40),
            to: session.id)
        // And one that genuinely measured zero loss, which must survive as 0.
        try store.appendThroughput(
            ThroughputResult(downloadMbps: 100, uploadMbps: 10,
                             bytesDownloaded: 1, bytesUploaded: 1,
                             idleLatencyMs: 18, downloadLatencyMs: 39, uploadLatencyMs: 40,
                             idleJitterMs: 2.5, packetLoss: 0),
            to: session.id)

        let back = try store.throughputResults(for: session.id)
        XCTAssertEqual(back.count, 2)
        XCTAssertNil(back[0].idleJitterMs)
        XCTAssertNil(back[0].packetLoss)
        XCTAssertEqual(back[1].idleJitterMs, 2.5)
        XCTAssertEqual(back[1].packetLoss, 0, "a measured zero is not a missing value")
    }

    func testMigrationFromSchema2NullsTheDefaultedRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = UUID()
        let defaulted = UUID(), measured = UUID()
        // Schema 2 wrote 0 for both columns on every pre-existing row, so this
        // is the exact ambiguity the migration has to resolve.
        try makeSchema2Database(at: url, session: session, rows: [
            (defaulted, 0, 0),
            (measured, 3.5, 0),
        ])

        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close() }
        let back = try store.throughputResults(for: session)

        XCTAssertEqual(back.count, 2, "the rebuild kept every row")
        let old = try XCTUnwrap(back.first { $0.id == defaulted })
        XCTAssertNil(old.idleJitterMs, "a defaulted row is unmeasured, not zero")
        XCTAssertNil(old.packetLoss)
        let new = try XCTUnwrap(back.first { $0.id == measured })
        XCTAssertEqual(new.idleJitterMs, 3.5)
        XCTAssertEqual(new.packetLoss, 0, "real jitter means the 0 loss was measured")
        XCTAssertEqual(new.downloadMbps, 200, accuracy: 1e-6, "the copy carried the other columns")
    }

    func testPerPhaseSpreadRoundTripsAndIsNilWhenAbsent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tp-\(UUID()).sqlite")
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close(); try? FileManager.default.removeItem(at: url) }
        let session = try store.startSession(MonitorSettings())

        try store.appendThroughput(
            ThroughputResult(downloadMbps: 269, uploadMbps: 31,
                             bytesDownloaded: 1, bytesUploaded: 1,
                             idleLatencyMs: 27.8, downloadLatencyMs: 170, uploadLatencyMs: 38.7,
                             idleJitterMs: 19.6, packetLoss: 0,
                             idleLowMs: 13.9, idleHighMs: 53.1,
                             downloadJitterMs: 190.2, downloadLowMs: 41.8, downloadHighMs: 366.7,
                             uploadJitterMs: 18.4, uploadLowMs: 20.9, uploadHighMs: 99.2),
            to: session.id)
        // A result with no spread at all — what every row written before
        // schema 4 looks like when it is read back.
        try store.appendThroughput(
            ThroughputResult(downloadMbps: 100, uploadMbps: 10,
                             bytesDownloaded: 1, bytesUploaded: 1,
                             idleLatencyMs: 20, downloadLatencyMs: 30, uploadLatencyMs: 31),
            to: session.id)

        let back = try store.throughputResults(for: session.id)
        XCTAssertEqual(back.count, 2)

        XCTAssertEqual(try XCTUnwrap(back[0].downloadHighMs), 366.7, accuracy: 1e-6,
                       "the load spike is the number the card exists to show")
        XCTAssertEqual(try XCTUnwrap(back[0].downloadJitterMs), 190.2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(back[0].idleLowMs), 13.9, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(back[0].uploadHighMs), 99.2, accuracy: 1e-6)

        XCTAssertNil(back[1].downloadHighMs, "never measured, so not a zero")
        XCTAssertNil(back[1].idleLowMs)
        XCTAssertNil(back[1].uploadJitterMs)
        XCTAssertEqual(try XCTUnwrap(back[1].downloadLatencyMs), 30, accuracy: 1e-6,
                       "a measured figure is untouched")
    }

    func testAveragesIgnoreUnmeasuredResults() {
        func result(jitter: Double?, loss: Double?) -> ThroughputResult {
            ThroughputResult(downloadMbps: 100, uploadMbps: 10,
                             bytesDownloaded: 1, bytesUploaded: 1,
                             idleLatencyMs: 20, downloadLatencyMs: 30, uploadLatencyMs: 30,
                             idleJitterMs: jitter, packetLoss: loss)
        }

        let mixed = ThroughputAverages(results: [
            result(jitter: nil, loss: nil),
            result(jitter: 2, loss: 0),
            result(jitter: 4, loss: 0.5),
        ])
        XCTAssertEqual(mixed.count, 3)
        XCTAssertEqual(try XCTUnwrap(mixed.jitterMs), 3, accuracy: 1e-9,
                       "mean of the two that measured, not of three with a zero")
        XCTAssertEqual(try XCTUnwrap(mixed.packetLoss), 0.25, accuracy: 1e-9)

        let none = ThroughputAverages(results: [result(jitter: nil, loss: nil)])
        XCTAssertNil(none.jitterMs)
        XCTAssertNil(none.packetLoss)
        XCTAssertEqual(try XCTUnwrap(none.latencyMs), 20, accuracy: 1e-9,
                       "a measured figure is untouched")
    }

    // MARK: -

    /// Writes a database in the shape schema 2 shipped: the columns present but
    /// `NOT NULL DEFAULT 0`, and `user_version = 2`. Built by hand rather than
    /// by an older `Schema`, because the point is to convert what is actually on
    /// disk in the wild.
    private func makeSchema2Database(at url: URL, session: UUID,
                                     rows: [(id: UUID, jitter: Double, loss: Double)]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func exec(_ sql: String) {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            XCTAssertEqual(rc, SQLITE_OK, err.map { String(cString: $0) } ?? "")
            sqlite3_free(err)
        }
        exec("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, started_at REAL NOT NULL, stopped_at REAL,
                router_host TEXT NOT NULL, internet_host TEXT NOT NULL,
                ping_interval_ns INTEGER NOT NULL, ping_timeout_ns INTEGER NOT NULL,
                throughput_enabled INTEGER NOT NULL, throughput_interval INTEGER NOT NULL,
                diagnostics_interval_ns INTEGER NOT NULL);
            """)
        exec("""
            CREATE TABLE throughput_results (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                timestamp REAL NOT NULL, download_mbps REAL NOT NULL, upload_mbps REAL NOT NULL,
                bytes_down INTEGER NOT NULL, bytes_up INTEGER NOT NULL,
                idle_latency_ms REAL NOT NULL, download_latency_ms REAL NOT NULL,
                upload_latency_ms REAL NOT NULL, bufferbloat_ms REAL NOT NULL,
                idle_jitter_ms REAL NOT NULL DEFAULT 0,
                packet_loss REAL NOT NULL DEFAULT 0,
                isp TEXT, server_location TEXT);
            """)
        exec("CREATE INDEX idx_throughput_session_time ON throughput_results(session_id, timestamp);")
        exec("""
            INSERT INTO sessions VALUES
            ('\(session.uuidString)', 1000, 2000, '10.0.0.1', '1.1.1.1', 1000000000, 1000000000, 1, 1800, 60000000000);
            """)
        for (i, row) in rows.enumerated() {
            exec("""
                INSERT INTO throughput_results VALUES
                ('\(row.id.uuidString)', '\(session.uuidString)', \(1000 + i),
                 200, 50, 1, 1, 20, 30, 40, 20, \(row.jitter), \(row.loss), NULL, NULL);
                """)
        }
        exec("PRAGMA user_version = 2;")
    }
}
