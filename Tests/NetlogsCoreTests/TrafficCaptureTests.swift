import XCTest
@testable import NetlogsCore

/// The `nettop` parser and the capture trigger.
///
/// Both are pure, which is the point: the runner spawns a five-second
/// subprocess that looks at the whole machine, and none of the logic worth
/// testing is in it. Same split as `ICMPPinger.echoReplySequence`.
final class NetTopParseTests: XCTestCase {

    /// Two samples, cumulative, exactly as `nettop -P -l 2 -s 1 -x` emits them:
    /// a header line per sample, `name.pid` then the two counters. Values taken
    /// from a real run on this machine.
    private let output = """
                                                     bytes_in       bytes_out
    syslogd.363                                             0            1564
    mDNSResponder.433                                64355906         2000000
    nsurlsessiond.627                                   20952          112769
    Claude Helper.6021                                1720454          680388
                                                     bytes_in       bytes_out
    syslogd.363                                             0            1564
    mDNSResponder.433                                64359034         2000000
    nsurlsessiond.627                                   20952         5112769
    Claude Helper.6021                                1721454          680388
    newprocess.9999                                      5000            5000
    """

    func testDifferencesTwoCumulativeSamples() {
        let rows = NetTop.parse(output, interval: 1)

        // nsurlsessiond sent 5 MB in the window and everything else barely
        // moved, so it leads. syslogd sent nothing and is dropped entirely.
        XCTAssertEqual(rows.first?.name, "nsurlsessiond")
        XCTAssertEqual(rows.first?.bytesOutPerSecond ?? 0, 5_000_000, accuracy: 1e-6)
        XCTAssertFalse(rows.contains { $0.name == "syslogd" },
                       "a process that moved nothing is not traffic")
    }

    func testCountersAreRatesNotTotals() {
        let rows = NetTop.parse(output, interval: 2)
        let sessiond = rows.first { $0.name == "nsurlsessiond" }
        XCTAssertEqual(sessiond?.bytesOutPerSecond ?? 0, 2_500_000, accuracy: 1e-6,
                       "the same delta over twice the window is half the rate")
    }

    func testAProcessThatStartedMidWindowIsSkipped() {
        let rows = NetTop.parse(output, interval: 1)
        XCTAssertFalse(rows.contains { $0.name == "newprocess" },
                       "its cumulative total is not a rate over this window — "
                       + "counting it would report bytes-since-launch as bytes-per-second")
    }

    func testProcessNamesMayContainSpaces() {
        let rows = NetTop.parse(output, interval: 1)
        let helper = rows.first { $0.name == "Claude Helper" }
        XCTAssertNotNil(helper, "the pid is after the last dot, not the first space")
        XCTAssertEqual(helper?.pid, 6021)
        XCTAssertEqual(helper?.bytesInPerSecond ?? 0, 1000, accuracy: 1e-6)
    }

    func testOneSampleYieldsNothing() {
        let single = output.split(separator: "\n")[0..<5].joined(separator: "\n")
        XCTAssertTrue(NetTop.parse(single, interval: 1).isEmpty,
                      "one cumulative reading cannot be a rate")
        XCTAssertFalse(NetTop.hasTwoSamples(single))
        XCTAssertTrue(NetTop.hasTwoSamples(output))
    }

    func testGarbageAndZeroIntervalAreSurvivable() {
        XCTAssertTrue(NetTop.parse("", interval: 1).isEmpty)
        XCTAssertTrue(NetTop.parse("not nettop output at all", interval: 1).isEmpty)
        XCTAssertTrue(NetTop.parse(output, interval: 0).isEmpty)
    }

    func testResultIsCappedAndSortedBySending() {
        var lines = ["  bytes_in bytes_out"]
        for i in 0..<40 { lines.append("proc\(i).\(1000 + i) 0 0") }
        lines.append("  bytes_in bytes_out")
        for i in 0..<40 { lines.append("proc\(i).\(1000 + i) 0 \(i * 100)") }

        let rows = NetTop.parse(lines.joined(separator: "\n"), interval: 1)
        XCTAssertEqual(rows.count, TrafficCapture.topCount)
        XCTAssertEqual(rows.first?.name, "proc39", "busiest uploader first")
        XCTAssertEqual(rows, rows.sorted { $0.bytesOutPerSecond > $1.bytesOutPerSecond })
    }
}

final class TrafficCaptureTriggerTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1000)

    private func sample(_ id: UInt32, router: Double?, internet: Double?,
                        late: Double? = nil) -> PingSample {
        PingSample(id: id, timestamp: start.addingTimeInterval(Double(id)),
                   routerMs: router, internetMs: internet,
                   routerLateMs: nil, internetLateMs: late, phase: .idle)
    }

    /// The shape of every episode in session `B4DA0F59`: a ramp, not a spike.
    private func ramp(from id: UInt32) -> [PingSample] {
        [700, 871, 1124, 1832, nil, 1521, 32].enumerated().map { offset, ms in
            sample(id + UInt32(offset), router: 4, internet: ms)
        }
    }

    func testFiresOnceForAWholeEpisode() {
        var trigger = TrafficCaptureTrigger()
        let fired = ramp(from: 0).filter { trigger.shouldCapture($0, now: $0.timestamp) }
        XCTAssertEqual(fired.count, 1,
                       "an episode is one event; the ramp held the condition for six samples")
        XCTAssertEqual(fired.first?.internetMs, 700, "and it fires as the ramp begins")
    }

    func testAHealthyRouterIsRequired() {
        var trigger = TrafficCaptureTrigger()
        // Both legs quiet: a link problem, and no process list explains it.
        let both = sample(0, router: nil, internet: nil)
        XCTAssertFalse(trigger.shouldCapture(both, now: both.timestamp))
        // A slow router is a LAN problem, which is also not this.
        let slowLan = sample(1, router: 40, internet: 900)
        XCTAssertFalse(trigger.shouldCapture(slowLan, now: slowLan.timestamp))
    }

    func testATimeoutCounts() {
        var trigger = TrafficCaptureTrigger()
        let lost = sample(0, router: 4, internet: nil)
        XCTAssertTrue(trigger.shouldCapture(lost, now: lost.timestamp),
                      "no reply at all is at least as strong a signal as a slow one")
    }

    func testALateReplyIsJudgedOnItsRealRtt() {
        var trigger = TrafficCaptureTrigger()
        // Missed the 2 s deadline but came back at 2.4 s — diverged, obviously.
        let late = sample(0, router: 4, internet: nil, late: 2400)
        XCTAssertTrue(trigger.shouldCapture(late, now: late.timestamp))
    }

    func testCooldownFloorsTheRate() {
        var trigger = TrafficCaptureTrigger(cooldown: 600)
        var fired = 0
        // Two hours of alternating episodes, one a minute.
        for minute in 0..<120 {
            let at = start.addingTimeInterval(Double(minute) * 60)
            let bad = PingSample(id: UInt32(minute), timestamp: at, routerMs: 4,
                                 internetMs: 900, routerLateMs: nil,
                                 internetLateMs: nil, phase: .idle)
            if trigger.shouldCapture(bad, now: at) { fired += 1 }
            // Five good samples between, enough to end the episode.
            for quiet in 1...5 {
                let ok = PingSample(id: UInt32(minute) * 10 + UInt32(quiet),
                                    timestamp: at.addingTimeInterval(Double(quiet)),
                                    routerMs: 4, internetMs: 20, routerLateMs: nil,
                                    internetLateMs: nil, phase: .idle)
                _ = trigger.shouldCapture(ok, now: ok.timestamp)
            }
        }
        XCTAssertLessThanOrEqual(fired, 13, "a bad two hours costs a dozen captures, not 120")
        XCTAssertGreaterThan(fired, 5, "…but it does keep sampling across the two hours")
    }

    func testASecondEpisodeAfterTheCooldownFires() {
        var trigger = TrafficCaptureTrigger(cooldown: 60)
        let first = sample(0, router: 4, internet: 900)
        XCTAssertTrue(trigger.shouldCapture(first, now: first.timestamp))

        for i in 1...5 {
            let ok = sample(UInt32(i), router: 4, internet: 20)
            _ = trigger.shouldCapture(ok, now: ok.timestamp)
        }
        let later = start.addingTimeInterval(120)
        let second = PingSample(id: 100, timestamp: later, routerMs: 4, internetMs: 900,
                                routerLateMs: nil, internetLateMs: nil, phase: .idle)
        XCTAssertTrue(trigger.shouldCapture(second, now: later))
    }

    func testABriefDipDoesNotSplitOneEpisodeInTwo() {
        var trigger = TrafficCaptureTrigger(cooldown: 600)
        var fired = 0
        // Ramp, one good sample, ramp again — one episode, not two.
        for (i, ms) in [900.0, 1200, 20, 1400, 1100].enumerated() {
            let s = sample(UInt32(i), router: 4, internet: ms)
            if trigger.shouldCapture(s, now: s.timestamp) { fired += 1 }
        }
        XCTAssertEqual(fired, 1)
    }
}

/// The throughput test must not measure itself as the network.
///
/// Phase 13 established that timeouts caused by our own load are ours. The same
/// argument applies to every packet the test sends, including the ones before
/// the transfer starts.
final class ThroughputPhaseTaggingTests: XCTestCase {

    /// A provider whose `fetchMeta` takes real time, like the HTTPS round trip
    /// it stands for.
    private final class SlowMetaProvider: ThroughputProvider, @unchecked Sendable {
        /// When the meta fetch actually ran. The assertion needs the real
        /// window, not an inference from which samples happen to be tagged —
        /// the first version of this test asserted "no idle sample between the
        /// first and last loaded one", which the bug slips straight past
        /// because the meta fetch happens *before* any sample is tagged.
        let window = Locked<(start: Date, end: Date)?>(nil)

        func fetchMeta() async -> ThroughputMeta? {
            let start = Date()
            try? await Task.sleep(for: .milliseconds(400))
            window.mutate { $0 = (start, Date()) }
            return ThroughputMeta(isp: "TDC", colo: "CPH")
        }
        func measureDownload(duration: Duration, discardingFirst: Duration) async -> ThroughputMeasurement {
            try? await Task.sleep(for: .milliseconds(100))
            return ThroughputMeasurement(bytes: 1_000_000, seconds: 0.1)
        }
        func measureUpload(duration: Duration, discardingFirst: Duration) async -> ThroughputMeasurement {
            try? await Task.sleep(for: .milliseconds(100))
            return ThroughputMeasurement(bytes: 100_000, seconds: 0.1)
        }
    }

    private final class SteadyPinger: ICMPPinging, @unchecked Sendable {
        func open() throws {}
        func close() {}
        func ping(host: String, sequence: UInt32) async -> PingOutcome { .reply(rttMs: 20) }
    }

    func testMetaFetchIsTaggedAsLoadNotIdle() async throws {
        let provider = SlowMetaProvider()
        let engine = MonitorEngine(
            settings: MonitorSettings(routerHost: "r", internetHost: "i",
                                      pingInterval: .milliseconds(50),
                                      pingTimeout: .seconds(1),
                                      throughputEnabled: false),
            pingerFactory: { _, _ in SteadyPinger() },
            throughputProvider: provider
        )
        let results = await engine.throughputResults()
        let stream = try await engine.start(warmup: .zero)

        let collected = Locked<[PingSample]>([])
        let collector = Task { for await s in stream { collected.mutate { $0.append(s) } } }

        // The meta fetch is 400 ms of network activity. Every sample taken
        // during it must carry a load phase, or its latency lands in the idle
        // baseline and in the session's "max" — which is how a 591 ms spike
        // came to be the headline maximum of a 31 ms session.
        await engine.runThroughputTestNow(directionDuration: .milliseconds(100),
                                          settle: .milliseconds(10),
                                          warmup: .zero)
        _ = await results.first { _ in true }
        await engine.stop()
        collector.cancel()

        let samples = collected.get
        XCTAssertGreaterThan(samples.count, 5, "the ping loop kept running through the test")

        let window = try XCTUnwrap(provider.window.get, "fetchMeta never ran")
        let during = samples.filter {
            $0.timestamp >= window.start && $0.timestamp <= window.end
        }
        XCTAssertGreaterThanOrEqual(during.count, 3,
                                    "a 400 ms fetch at 50 ms per tick should cover several samples")
        let mistagged = during.filter { !$0.isUnderLoad }
        XCTAssertTrue(mistagged.isEmpty,
                      "\(mistagged.count) of \(during.count) samples taken during the "
                      + "meta fetch are tagged idle — their latency lands in the idle "
                      + "baseline and in the session maximum")
    }
}

/// Shared with `MonitorEngineTests`; redeclared here so this file stands alone.
fileprivate final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    var get: T { lock.lock(); defer { lock.unlock() }; return value }
}
