import XCTest
@testable import NetlogsCore

/// The load-bearing test of the Analysis screen: the reduction done in SQLite
/// must equal the one `LiveSummaryBuilder` does in Swift, over the same samples.
///
/// Nothing built on top of the range queries is worth anything if these two
/// disagree — and every figure the screen shows, scores or advises on comes
/// through them.
final class RangeAggregateTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("netlogs-range-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func store(_ name: String = "range.sqlite") throws -> SessionStore {
        try SessionStore(url: dir.appendingPathComponent(name), flushInterval: .zero)
    }

    /// A stream with everything that makes the two implementations diverge if
    /// either is careless: a warm-up spike, timeouts on each host separately,
    /// a tick where both were silent, and a hole in the sequence.
    private func awkwardStream() -> [PingSample] {
        var out: [PingSample] = []
        func add(_ id: UInt32, _ router: Double?, _ internet: Double?) {
            out.append(PingSample(id: id,
                                  timestamp: epoch.addingTimeInterval(Double(id)),
                                  routerMs: router, internetMs: internet, phase: .idle))
        }
        add(0, 580, nil)      // the warm-up pair: a spike, and the internet timeout
        add(1, 40, 300)       // that PingSample.warmupSampleCount exists to hide
        add(2, 3.0, 20.0)
        add(3, 4.5, 24.0)
        add(4, nil, 26.0)     // router silent
        add(5, 3.5, nil)      // internet silent
        add(6, nil, nil)      // both silent
        add(7, 5.0, 30.0)
        add(8, 3.2, 21.0)
        // A hole: seq 9…19 never existed, as when the Mac slept.
        add(20, 6.0, 40.0)
        add(21, 3.8, 22.0)
        return out
    }

    private func expected(_ samples: [PingSample]) -> LiveSummary {
        var builder = LiveSummaryBuilder()
        for sample in samples where sample.id >= PingSample.warmupSampleCount {
            builder.add(sample)
        }
        return builder.summary
    }

    func testSQLReductionEqualsTheSwiftOne() throws {
        let store = try store()
        let session = try store.startSession(MonitorSettings(), startedAt: epoch)
        let samples = awkwardStream()
        for sample in samples { store.append(sample, to: session.id) }
        try store.flush()

        let aggregate = try XCTUnwrap(
            try store.pingAggregates(for: [session.id])[session.id]
        )
        let swift = expected(samples)

        XCTAssertEqual(aggregate.totalSamples, swift.totalSamples)
        XCTAssertEqual(aggregate.routerTimeouts, swift.routerTimeouts)
        XCTAssertEqual(aggregate.internetTimeouts, swift.internetTimeouts)
        XCTAssertEqual(aggregate.failureCount, swift.failureCount)

        // Counts and extremes are exact; the means and jitters are sums in a
        // different order, so they get a relative tolerance rather than an
        // equality that would flake on the last bit of a Double.
        XCTAssertEqual(aggregate.router.replies, swift.router.samples)
        XCTAssertEqual(try XCTUnwrap(aggregate.router.min), swift.router.min)
        XCTAssertEqual(try XCTUnwrap(aggregate.router.max), swift.router.max)
        XCTAssertEqual(aggregate.router.mean, swift.router.avg, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(aggregate.router.measuredJitter),
                       swift.router.jitter, accuracy: 1e-9)

        XCTAssertEqual(aggregate.internet.replies, swift.internet.samples)
        XCTAssertEqual(try XCTUnwrap(aggregate.internet.min), swift.internet.min)
        XCTAssertEqual(try XCTUnwrap(aggregate.internet.max), swift.internet.max)
        XCTAssertEqual(aggregate.internet.mean, swift.internet.avg, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(aggregate.internet.measuredJitter),
                       swift.internet.jitter, accuracy: 1e-9)
    }

    /// The trap the `LAG` comment in `pingAggregates` is about. The Swift path
    /// folds rows in read order, so it pairs 8 with 20 across the hole; a
    /// self-join on `seq - 1` would not, and the two would silently disagree on
    /// exactly the sessions where a Mac slept.
    func testJitterPairsAcrossAHoleInTheSequence() throws {
        let store = try store("hole.sqlite")
        let session = try store.startSession(MonitorSettings(), startedAt: epoch)
        for sample in awkwardStream() { store.append(sample, to: session.id) }
        try store.flush()

        let aggregate = try XCTUnwrap(
            try store.pingAggregates(for: [session.id])[session.id]
        )
        // Router replies after the warm-up: 2,3,5,7,8,20,21. Consecutive-reply
        // pairs: (2,3), (7,8), (8,20), (20,21) — the third spans the hole.
        XCTAssertEqual(aggregate.router.jitterPairs, 4)
    }

    /// The warm-up window is excluded *before* the window function runs, so the
    /// first analysed sample has no predecessor. Otherwise the 580 ms spike
    /// pairs with the sample after it and dominates a short session's jitter.
    func testWarmUpIsExcludedBeforeJitterIsPaired() throws {
        let store = try store("warmup.sqlite")
        let session = try store.startSession(MonitorSettings(), startedAt: epoch)
        for sample in awkwardStream() { store.append(sample, to: session.id) }
        try store.flush()

        let skipping = try XCTUnwrap(try store.pingAggregates(for: [session.id])[session.id])
        let keeping = try XCTUnwrap(
            try store.pingAggregates(for: [session.id], skippingWarmup: false)[session.id]
        )

        XCTAssertEqual(skipping.totalSamples, keeping.totalSamples - 2)
        XCTAssertEqual(try XCTUnwrap(skipping.router.max), 6.0, "no 580 ms spike")
        XCTAssertEqual(try XCTUnwrap(keeping.router.max), 580.0)
        XCTAssertLessThan(try XCTUnwrap(skipping.router.measuredJitter),
                          try XCTUnwrap(keeping.router.measuredJitter))
    }

    /// `failureCount` counts a tick once if either host was silent, so the
    /// overlap — the ticks where the link itself dropped — falls out of
    /// inclusion–exclusion rather than needing its own column.
    func testBothTimeoutsIsDerivedNotStored() throws {
        let store = try store("both.sqlite")
        let session = try store.startSession(MonitorSettings(), startedAt: epoch)
        for sample in awkwardStream() { store.append(sample, to: session.id) }
        try store.flush()

        let aggregate = try XCTUnwrap(try store.pingAggregates(for: [session.id])[session.id])
        XCTAssertEqual(aggregate.bothTimeouts, 1, "seq 6, where neither answered")
    }

    // MARK: - Selection

    func testSelectsSessionsByOverlapAndReportsThemWhole() throws {
        let store = try store("overlap.sqlite")
        let inside = try store.startSession(MonitorSettings(),
                                            startedAt: epoch.addingTimeInterval(3600))
        let straddling = try store.startSession(MonitorSettings(),
                                                startedAt: epoch.addingTimeInterval(-3600))
        let before = try store.startSession(MonitorSettings(),
                                            startedAt: epoch.addingTimeInterval(-86_400))
        try store.stopSession(inside.id, at: epoch.addingTimeInterval(7200))
        try store.stopSession(straddling.id, at: epoch.addingTimeInterval(600))
        try store.stopSession(before.id, at: epoch.addingTimeInterval(-82_800))

        let found = try store.sessionsOverlapping(epoch ... epoch.addingTimeInterval(7200))
        let ids = Set(found.map(\.id))
        XCTAssertTrue(ids.contains(inside.id))
        XCTAssertTrue(ids.contains(straddling.id), "a session may start before the range")
        XCTAssertFalse(ids.contains(before.id))
    }

    /// A session that was never stopped ends at its last sample, not at *now* —
    /// six of twenty sessions in a real database have no `stopped_at`, and
    /// measuring those against the clock would sweep in every crashed session
    /// ever recorded.
    func testUnstoppedSessionEndsAtItsLastSample() throws {
        let store = try store("unstopped.sqlite")
        let old = try store.startSession(MonitorSettings(),
                                         startedAt: epoch.addingTimeInterval(-86_400))
        store.append(PingSample(id: 0, timestamp: epoch.addingTimeInterval(-86_000),
                                routerMs: 3, internetMs: 20, phase: .idle), to: old.id)
        try store.flush()

        let found = try store.sessionsOverlapping(epoch ... epoch.addingTimeInterval(3600))
        XCTAssertFalse(found.map(\.id).contains(old.id))
    }

    func testEmptyInputDoesNotQuery() throws {
        let store = try store("empty.sqlite")
        XCTAssertTrue(try store.pingAggregates(for: []).isEmpty)
    }
}
