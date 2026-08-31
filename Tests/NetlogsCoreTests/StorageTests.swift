import XCTest
@testable import NetlogsCore

final class StorageTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netlogs-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func dbURL(_ name: String = "t.sqlite") -> URL { dir.appendingPathComponent(name) }

    private func sample(_ id: UInt32, router: Double? = 3, internet: Double? = 20, phase: LoadPhase = .idle) -> PingSample {
        PingSample(id: id, timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                   routerMs: router, internetMs: internet, phase: phase)
    }

    // MARK: -

    func testSessionStateRoundTrip() throws {
        let s = SessionState(startedAt: Date(timeIntervalSince1970: 1), stoppedAt: nil,
                             settings: MonitorSettings())
        let back = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertTrue(back.isRunning)
    }

    func testWriteReadRoundTrip() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }

        let session = try store.startSession(MonitorSettings(routerHost: "10.0.0.1", internetHost: "9.9.9.9"))
        store.append((0..<100).map { sample($0) }, to: session.id)
        try store.flush()

        XCTAssertEqual(try store.sampleCount(for: session.id), 100)

        let loaded = try XCTUnwrap(try store.loadSession(session.id))
        XCTAssertEqual(loaded.settings.routerHost, "10.0.0.1")
        XCTAssertEqual(loaded.settings.internetHost, "9.9.9.9")
        XCTAssertTrue(loaded.isRunning)

        let rows = try store.samples(for: session.id)
        XCTAssertEqual(rows.count, 100)
        XCTAssertEqual(rows.map(\.id), Array(0..<100))
        XCTAssertEqual(rows[0].routerMs, 3)
    }

    func testNothingOnDiskUntilFlush() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }
        let session = try store.startSession(MonitorSettings())
        store.append((0..<50).map { sample($0) }, to: session.id)

        XCTAssertEqual(store.pendingCount, 50)
        XCTAssertEqual(try store.sampleCount(for: session.id), 0, "not written before flush")

        try store.flush()
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(try store.sampleCount(for: session.id), 50)
    }

    func testTimeoutSamplesPersistAsNull() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { store.close() }
        let session = try store.startSession(MonitorSettings())
        store.append([
            sample(0, router: nil, internet: 15),
            sample(1, router: 4, internet: nil),
        ], to: session.id)
        try store.flush()

        let rows = try store.samples(for: session.id)
        XCTAssertNil(rows[0].routerMs); XCTAssertEqual(rows[0].internetMs, 15)
        XCTAssertEqual(rows[1].routerMs, 4); XCTAssertNil(rows[1].internetMs)
    }

    func testForceQuitMidSessionLeavesReadablePartialSession() throws {
        let url = dbURL()

        var store1: SessionStore? = try SessionStore(url: url, flushInterval: .zero)
        let session = try store1!.startSession(MonitorSettings())
        let sessionID = session.id
        store1!.append((0..<200).map { sample($0) }, to: sessionID)
        try store1!.flush()                                         // 200 durable
        store1!.append((200..<250).map { sample($0) }, to: sessionID) // 50 buffered, never flushed
        store1 = nil // drop the connection with no stopSession()/close() — buffer is lost

        let reopened = try SessionStore(url: url, flushInterval: .zero)
        defer { reopened.close() }

        let recovered = try XCTUnwrap(try reopened.loadSession(sessionID))
        XCTAssertTrue(recovered.isRunning, "a crashed session stays open (stopped_at NULL)")
        XCTAssertEqual(try reopened.sampleCount(for: sessionID), 200, "flushed rows survived, buffered ones didn't")

        let rows = try reopened.samples(for: sessionID)
        XCTAssertEqual(rows.map(\.id), Array(0..<200))
    }

    func testCleanStopFlushesRemainderAndMarksStopped() throws {
        let url = dbURL()
        let store = try SessionStore(url: url, flushInterval: .zero)
        let session = try store.startSession(MonitorSettings())
        store.append((0..<175).map { sample($0) }, to: session.id)
        let stoppedAt = Date(timeIntervalSince1970: 1_700_009_999)
        try store.stopSession(session.id, at: stoppedAt)
        store.close()

        let reopened = try SessionStore(url: url, flushInterval: .zero)
        defer { reopened.close() }
        let loaded = try XCTUnwrap(try reopened.loadSession(session.id))
        XCTAssertFalse(loaded.isRunning)
        XCTAssertEqual(loaded.stoppedAt?.timeIntervalSince1970 ?? 0, stoppedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try reopened.sampleCount(for: session.id), 175, "stopSession flushed the tail")
    }

    func testAllSessionsNewestFirstAndReopenIsIdempotent() throws {
        let url = dbURL()
        var ids: [UUID] = []
        do {
            let store = try SessionStore(url: url, flushInterval: .zero)
            for i in 0..<3 {
                let s = try store.startSession(MonitorSettings(), startedAt: Date(timeIntervalSince1970: Double(1000 + i * 100)))
                ids.append(s.id)
            }
            store.close()
        }
        let reopened = try SessionStore(url: url, flushInterval: .zero) // migration must be a no-op
        defer { reopened.close() }
        XCTAssertEqual(try reopened.allSessions().map(\.id), ids.reversed())
    }

    /// Engine → store end to end: every emitted sample is persisted, in order.
    func testEngineSessionPersistsEverySample() async throws {
        final class Fake: ICMPPinging, @unchecked Sendable {
            func open() throws {}
            func close() {}
            func ping(host: String, sequence: UInt32) async -> PingOutcome { .reply(rttMs: 5) }
        }

        let store = try SessionStore(url: dbURL(), flushInterval: .milliseconds(100))
        let settings = MonitorSettings(pingInterval: .milliseconds(20), pingTimeout: .seconds(1))
        let engine = MonitorEngine(settings: settings) { _, _ in Fake() }
        let session = try store.startSession(settings)

        let stream = try await engine.start(warmup: .zero)
        let consumer = Task {
            for await s in stream { store.append(s, to: session.id) }
        }
        try await Task.sleep(for: .milliseconds(1200))
        await engine.stop()
        await consumer.value // stream drained

        try store.stopSession(session.id)
        store.close()

        let reopened = try SessionStore(url: dbURL(), flushInterval: .zero)
        defer { reopened.close() }
        let rows = try reopened.samples(for: session.id)
        XCTAssertGreaterThan(rows.count, 40, "≈60 samples expected, got \(rows.count)")
        XCTAssertEqual(rows.map(\.id), Array(0..<UInt32(rows.count)), "persisted in order, no gaps")
        XCTAssertTrue(rows.allSatisfy { $0.routerMs == 5 && $0.internetMs == 5 })
        XCTAssertFalse(try XCTUnwrap(reopened.loadSession(session.id)).isRunning)
    }

    func testAutoFlushTimerPersistsWithoutExplicitFlush() throws {
        let store = try SessionStore(url: dbURL(), flushInterval: .milliseconds(150))
        defer { store.close() }
        let session = try store.startSession(MonitorSettings())
        store.append((0..<30).map { sample($0) }, to: session.id)

        let deadline = Date().addingTimeInterval(2)
        while try store.sampleCount(for: session.id) < 30, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertEqual(try store.sampleCount(for: session.id), 30, "the 150 ms flush timer wrote the batch")
    }
}
