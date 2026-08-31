import XCTest
@testable import NetlogsCore

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    var get: T { lock.lock(); defer { lock.unlock() }; return value }
}

/// Deterministic pinger: per-host canned outcome. `jitter` adds a random
/// per-call delay so ticks complete out of submission order.
private final class FakePinger: ICMPPinging, @unchecked Sendable {
    let outcomes: [String: PingOutcome]
    let jitter: Duration
    let opened = Locked(false)
    let closed = Locked(false)
    let sends = Locked<[String: Int]>([:])

    init(outcomes: [String: PingOutcome], jitter: Duration = .zero) {
        self.outcomes = outcomes
        self.jitter = jitter
    }

    func open() throws { opened.set(true) }
    func close() { closed.set(true) }
    func ping(host: String, sequence: UInt32) async -> PingOutcome {
        sends.mutate { $0[host, default: 0] += 1 }
        if jitter > .zero {
            let ns = UInt64.random(in: 0...UInt64(jitter.wholeNanoseconds))
            try? await Task.sleep(for: .nanoseconds(ns))
        }
        return outcomes[host] ?? .failure("no canned outcome for \(host)")
    }
}

final class MonitorEngineTests: XCTestCase {

    private func makeEngine(_ outcomes: [String: PingOutcome]) -> (MonitorEngine, FakePinger) {
        let fake = FakePinger(outcomes: outcomes)
        let engine = MonitorEngine(
            settings: MonitorSettings(
                routerHost: "192.168.1.1", internetHost: "1.1.1.1",
                pingInterval: .milliseconds(100), pingTimeout: .seconds(1)
            )
        ) { _, _ in fake }
        return (engine, fake)
    }

    func testEmitsOneOrderedSamplePerTick() async throws {
        let (engine, fake) = makeEngine([
            "192.168.1.1": .reply(rttMs: 2),
            "1.1.1.1": .reply(rttMs: 20),
        ])

        let collected = Locked<[PingSample]>([])
        let stream = try await engine.start(warmup: .zero)
        let collector = Task { for await s in stream { collected.mutate { $0.append(s) } } }
        try await Task.sleep(for: .milliseconds(950))
        await engine.stop()
        _ = await collector.value
        let samples = collected.get

        XCTAssertGreaterThanOrEqual(samples.count, 7, "expected ~9 samples, got \(samples.count)")
        XCTAssertLessThanOrEqual(samples.count, 11)
        XCTAssertEqual(samples.map(\.id), Array(0..<UInt32(samples.count)), "ids must be sequential")
        XCTAssertEqual(samples.first?.routerMs, 2)
        XCTAssertEqual(samples.first?.internetMs, 20)
        XCTAssertTrue(samples.allSatisfy { $0.phase == .idle })

        let gaps = zip(samples.dropFirst(), samples).map {
            $0.timestamp.timeIntervalSince($1.timestamp)
        }
        for g in gaps {
            XCTAssertEqual(g, 0.1, accuracy: 0.03, "sample spacing off: \(g)s")
        }
        XCTAssertTrue(fake.closed.get)
    }

    func testTimeoutOutcomeRecordsNilNotDropped() async throws {
        let (engine, _) = makeEngine([
            "192.168.1.1": .timeout,
            "1.1.1.1": .reply(rttMs: 15),
        ])

        let collected = Locked<[PingSample]>([])
        let stream = try await engine.start(warmup: .zero)
        let collector = Task { for await s in stream { collected.mutate { $0.append(s) } } }
        try await Task.sleep(for: .milliseconds(450))
        await engine.stop()
        _ = await collector.value
        let samples = collected.get

        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.routerMs == nil }, "router timeouts must be nil")
        XCTAssertTrue(samples.allSatisfy { $0.internetMs == 15 })
        XCTAssertEqual(samples.map(\.id), Array(0..<UInt32(samples.count)))
    }

    func testSamplesStayOrderedWhenPingsCompleteOutOfOrder() async throws {
        let fake = FakePinger(
            outcomes: ["192.168.1.1": .reply(rttMs: 1), "1.1.1.1": .reply(rttMs: 1)],
            jitter: .milliseconds(120) // >> the 20 ms interval, so ticks overlap heavily
        )
        let engine = MonitorEngine(
            settings: MonitorSettings(
                routerHost: "192.168.1.1", internetHost: "1.1.1.1",
                pingInterval: .milliseconds(20), pingTimeout: .seconds(1)
            )
        ) { _, _ in fake }

        let collected = Locked<[PingSample]>([])
        let stream = try await engine.start(warmup: .zero)
        let collector = Task { for await s in stream { collected.mutate { $0.append(s) } } }
        try await Task.sleep(for: .milliseconds(900))
        await engine.stop()
        _ = await collector.value
        let ids = collected.get.map(\.id)

        XCTAssertGreaterThan(ids.count, 10)
        XCTAssertEqual(ids, Array(0..<UInt32(ids.count)),
                       "samples must be emitted in id order despite scrambled ping completion")
    }

    func testRebuildsPingerAfterSustainedTotalFailure() async throws {
        // Every ping times out → after ~15 ticks the engine should open a fresh
        // pinger (interface-switch / sleep-wake recovery). The stream keeps
        // producing samples throughout.
        let opens = Locked(0)
        let engine = MonitorEngine(
            settings: MonitorSettings(
                routerHost: "192.168.1.1", internetHost: "1.1.1.1",
                pingInterval: .milliseconds(20), pingTimeout: .seconds(1)
            ),
            pingerFactory: { _, _ in
                let p = FakePinger(outcomes: ["192.168.1.1": .timeout, "1.1.1.1": .timeout])
                opens.mutate { $0 += 1 }
                return p
            }
        )

        let collected = Locked<[PingSample]>([])
        let stream = try await engine.start(warmup: .zero)
        let collector = Task { for await s in stream { collected.mutate { $0.append(s) } } }
        try await Task.sleep(for: .milliseconds(800))
        await engine.stop()
        _ = await collector.value

        let samples = collected.get
        XCTAssertGreaterThan(samples.count, 20)
        XCTAssertEqual(samples.map(\.id), Array(0..<UInt32(samples.count)), "cadence unbroken")
        XCTAssertTrue(samples.allSatisfy { $0.routerMs == nil && $0.internetMs == nil })
        XCTAssertGreaterThanOrEqual(opens.get, 2, "pinger rebuilt at least once")
    }

    func testStopEndsTheStream() async throws {
        let (engine, _) = makeEngine([
            "192.168.1.1": .reply(rttMs: 1),
            "1.1.1.1": .reply(rttMs: 1),
        ])
        let stream = try await engine.start(warmup: .zero)
        let done = Task { var n = 0; for await _ in stream { n += 1 }; return n }
        try await Task.sleep(for: .milliseconds(250))
        await engine.stop()
        let count = await done.value // must return, i.e. stream finished
        XCTAssertGreaterThan(count, 0)
    }
}
