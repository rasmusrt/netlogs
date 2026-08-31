import XCTest
@testable import NetlogsCore

final class RetentionTests: XCTestCase {

    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ret-\(UUID()).sqlite")
    }
    override func tearDownWithError() throws {
        for p in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? FileManager.default.removeItem(atPath: p)
        }
    }

    private func seed(
        _ store: SessionStore,
        stoppedAt: Date?,
        samples: Int,
        sampleTime: Date = Date()
    ) throws -> UUID {
        let s = try store.startSession(
            MonitorSettings(),
            startedAt: stoppedAt?.addingTimeInterval(-60) ?? sampleTime.addingTimeInterval(-60)
        )
        store.append((0..<samples).map {
            PingSample(id: UInt32($0), timestamp: sampleTime, routerMs: 5, internetMs: 5, phase: .idle)
        }, to: s.id)
        try store.flush()
        if let stoppedAt { try store.stopSession(s.id, at: stoppedAt) }
        return s.id
    }

    func testDeleteCascades() throws {
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close() }
        let id = try seed(store, stoppedAt: Date(), samples: 200)
        XCTAssertEqual(try store.sampleCount(for: id), 200)

        try store.deleteSession(id)
        XCTAssertNil(try store.loadSession(id))
        XCTAssertEqual(try store.sampleCount(for: id), 0, "ping_samples cascade-deleted")
        XCTAssertTrue(try store.allSessions().isEmpty)
    }

    func testPruneKeepsRunningAndRecentSessions() throws {
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close() }

        let old = try seed(store, stoppedAt: Date(timeIntervalSinceNow: -40 * 86_400), samples: 50)
        let recent = try seed(store, stoppedAt: Date(timeIntervalSinceNow: -2 * 86_400), samples: 50)
        let running = try seed(store, stoppedAt: nil, samples: 50)

        let removed = try store.prune(stoppedBefore: Date(timeIntervalSinceNow: -30 * 86_400))
        XCTAssertEqual(removed, 1)
        XCTAssertNil(try store.loadSession(old))
        XCTAssertNotNil(try store.loadSession(recent))
        XCTAssertNotNil(try store.loadSession(running), "a running session is never pruned")
    }

    /// A force-quit leaves `stopped_at` NULL forever. The old
    /// `stopped_at IS NOT NULL` filter meant those rows could never be pruned
    /// at all, so they accumulated for the life of the database — visible only
    /// because the sidebar flagged them, which it no longer does.
    func testPrunesAStaleSessionThatWasNeverStopped() throws {
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close() }

        let abandoned = try seed(store, stoppedAt: nil, samples: 50,
                                 sampleTime: Date(timeIntervalSinceNow: -40 * 86_400))
        let recording = try seed(store, stoppedAt: nil, samples: 50)

        let removed = try store.prune(stoppedBefore: Date(timeIntervalSinceNow: -30 * 86_400))
        XCTAssertEqual(removed, 1)
        XCTAssertNil(try store.loadSession(abandoned))
        XCTAssertNotNil(try store.loadSession(recording),
                        "a session whose newest sample is now can never be older than the cutoff")
    }

    /// A session that recorded nothing at all still has to age out.
    func testPrunesAnEmptySessionByItsStartTime() throws {
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close() }

        let empty = try store.startSession(
            MonitorSettings(), startedAt: Date(timeIntervalSinceNow: -40 * 86_400)
        )
        XCTAssertEqual(try store.prune(stoppedBefore: Date(timeIntervalSinceNow: -30 * 86_400)), 1)
        XCTAssertNil(try store.loadSession(empty.id))
    }

    func testDatabaseByteCountGrowsThenShrinksAfterVacuum() throws {
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close() }
        _ = try seed(store, stoppedAt: Date(), samples: 20_000)
        let big = store.databaseByteCount()
        XCTAssertGreaterThan(big, 100_000)

        _ = try store.prune(stoppedBefore: Date(timeIntervalSinceNow: 86_400)) // everything
        try store.vacuum()
        XCTAssertLessThan(store.databaseByteCount(), big)
    }

    func testLenientDecodeOfPartialSettingsBlob() throws {
        // Take a real encoded blob, drop a key, add a since-removed one — it
        // should still decode, filling defaults for the missing key.
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(MonitorSettings(routerHost: "10.0.0.1", throughputInterval: 30))
        ) as! [String: Any]
        json.removeValue(forKey: "internetHost")
        json["ssidOptIn"] = true // no longer a field

        let decoded = try JSONDecoder().decode(
            MonitorSettings.self, from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(decoded.routerHost, "10.0.0.1")
        XCTAssertEqual(decoded.throughputInterval, 30)
        XCTAssertEqual(decoded.internetHost, "1.1.1.1", "missing key → default")
    }
}
