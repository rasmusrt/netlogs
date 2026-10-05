import XCTest
@testable import NetlogsCore

/// Every rule gets one case where it fires and several where it must not.
///
/// The non-firing cases are the important ones. A rule that fires on a single
/// bad evening will be wrong more often than it is right, and advice that is
/// wrong costs more trust than advice that is missing.
final class FindingRulesTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func radio(rssi: [Int], channels: Set<Int> = [100],
                       bands: Set<String> = ["5 GHz"]) -> RadioSummary {
        let sorted = rssi.sorted()
        return RadioSummary(
            readings: rssi.count, rssiMin: sorted.first,
            rssiMedian: sorted.isEmpty ? nil : sorted[sorted.count / 2],
            weakFraction: rssi.isEmpty ? 0
                : Double(rssi.filter { $0 <= RadioSummary.weakRSSI }.count) / Double(rssi.count),
            channels: channels, bands: bands, isWiFi: true
        )
    }

    private func session(
        day: Int, internetHost: String = "1.1.1.1", routerHost: String = "192.168.0.1",
        samples: Int = 3_600, routerTimeouts: Int = 0, internetTimeouts: Int = 0,
        bothTimeouts: Int = 0, throughput: [ThroughputResult] = [],
        jitterSum: Double = 5_000, radio: RadioSummary = .empty,
        coverage: Double = 1
    ) -> SessionAnalysis {
        let settings = MonitorSettings(routerHost: routerHost, internetHost: internetHost)
        let started = epoch.addingTimeInterval(Double(day) * 86_400)
        let claimed = coverage > 0 ? Double(samples) / coverage : Double(samples)
        let state = SessionState(startedAt: started,
                                 stoppedAt: started.addingTimeInterval(claimed),
                                 settings: settings)
        // failureCount counts a tick once if either was silent, so the overlap
        // is the ticks where both were.
        let failures = routerTimeouts + internetTimeouts - bothTimeouts
        let aggregate = PingAggregate(
            totalSamples: samples,
            firstSampleAt: started, lastSampleAt: started.addingTimeInterval(Double(samples)),
            routerTimeouts: routerTimeouts, internetTimeouts: internetTimeouts,
            failureCount: failures,
            router: HostAggregate(replies: samples - routerTimeouts, min: 2, max: 20,
                                  sum: Double(samples - routerTimeouts) * 8,
                                  jitterSum: 100, jitterPairs: 1_000),
            internet: HostAggregate(replies: samples - internetTimeouts, min: 20, max: 90,
                                    sum: Double(samples - internetTimeouts) * 35,
                                    jitterSum: jitterSum, jitterPairs: 1_000)
        )
        var histogram = LatencyHistogram()
        histogram.add(35, count: samples - internetTimeouts)
        return SessionAnalysis(session: state, aggregate: aggregate,
                               latency: histogram, throughput: throughput, radio: radio)
    }

    private func test(_ bufferbloat: Double?, at offset: TimeInterval,
                      down: Double = 500, up: Double = 60) -> ThroughputResult {
        ThroughputResult(
            timestamp: epoch.addingTimeInterval(offset),
            downloadMbps: down, uploadMbps: up, bytesDownloaded: 1, bytesUploaded: 1,
            idleLatencyMs: bufferbloat == nil ? nil : 20,
            downloadLatencyMs: bufferbloat.map { 20 + $0 },
            uploadLatencyMs: bufferbloat.map { 20 + $0 }
        )
    }

    private func range(_ sessions: [SessionAnalysis]) -> RangeAnalysis {
        RangeAnalysis(interval: DateInterval(start: epoch.addingTimeInterval(-86_400),
                                             end: epoch.addingTimeInterval(30 * 86_400)),
                      sessions: sessions)
    }

    // MARK: - Upstream loss

    func testUpstreamLossFiresWhenTheRouterIsCleanAcrossDays() {
        let findings = UpstreamLossRule().evaluate(range([
            session(day: 0, internetTimeouts: 200),
            session(day: 1, internetTimeouts: 180),
        ]))
        let finding = findings.first
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(finding?.side, .internetPath)
        XCTAssertEqual(finding?.severity, .warning)
        XCTAssertTrue(finding?.action?.contains("Nothing at home") ?? false,
                      "the null result is the useful part")
        XCTAssertTrue(finding?.evidence.scope.contains("2 days") ?? false)
    }

    func testUpstreamLossDoesNotFireOnOneBadNight() {
        XCTAssertTrue(UpstreamLossRule().evaluate(range([
            session(day: 0, internetTimeouts: 400),
        ])).isEmpty)
    }

    func testUpstreamLossDoesNotFireTwiceOnOneDay() {
        XCTAssertTrue(UpstreamLossRule().evaluate(range([
            session(day: 0, internetTimeouts: 200),
            session(day: 0, internetTimeouts: 200),
        ])).isEmpty, "two sessions, one day — still weather")
    }

    /// If the router is losing packets too, the problem is not upstream, and
    /// telling someone there is nothing to fix at home would be wrong.
    func testUpstreamLossDoesNotFireWhenTheRouterIsAlsoLosing() {
        XCTAssertTrue(UpstreamLossRule().evaluate(range([
            session(day: 0, routerTimeouts: 300, internetTimeouts: 300, bothTimeouts: 250),
            session(day: 1, routerTimeouts: 300, internetTimeouts: 300, bothTimeouts: 250),
        ])).isEmpty)
    }

    /// Two targets in range must never be pooled — each is evaluated alone.
    func testUpstreamLossEvaluatesEachTargetSeparately() {
        let findings = UpstreamLossRule().evaluate(range([
            session(day: 0, internetHost: "1.1.1.1", internetTimeouts: 200),
            session(day: 1, internetHost: "1.1.1.1", internetTimeouts: 200),
            session(day: 0, internetHost: "8.8.8.8"),
            session(day: 1, internetHost: "8.8.8.8"),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].evidence.measurement.contains("1.1.1.1"))
    }

    // MARK: - Bufferbloat

    func testBufferbloatFiresOnASustainedPattern() {
        let tests = (0..<9).map { test(238, at: Double($0) * 3_600) }
        let findings = BufferbloatRule().evaluate(range([
            session(day: 0, throughput: tests),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.side, .router)
        XCTAssertTrue(findings.first?.action?.contains("SQM") ?? false)
        XCTAssertTrue(findings.first?.action?.contains("Re-measure") ?? false,
                      "an action the user can check")
        XCTAssertTrue(findings.first?.evidence.measurement.contains("9 of 9") ?? false)
    }

    func testBufferbloatDoesNotFireOnTooFewTests() {
        XCTAssertTrue(BufferbloatRule().evaluate(range([
            session(day: 0, throughput: [test(400, at: 0), test(400, at: 7_200)]),
        ])).isEmpty)
    }

    /// Nine tests in ten minutes describe one moment, not a connection.
    func testBufferbloatDoesNotFireOnTestsClusteredInTime() {
        let tests = (0..<9).map { test(238, at: Double($0) * 60) }
        XCTAssertTrue(BufferbloatRule().evaluate(range([
            session(day: 0, throughput: tests),
        ])).isEmpty)
    }

    /// One terrible run among good ones must not carry the finding.
    func testBufferbloatDoesNotFireWithoutAMajorityOverTheLine() {
        var tests = (0..<8).map { test(20, at: Double($0) * 3_600) }
        tests.append(test(900, at: 9 * 3_600))
        XCTAssertTrue(BufferbloatRule().evaluate(range([
            session(day: 0, throughput: tests),
        ])).isEmpty)
    }

    /// A test that could not load the line says nothing about what load does.
    func testBufferbloatIgnoresTestsThatNeverLoadedTheLine() {
        let tests = (0..<9).map { test(238, at: Double($0) * 3_600, down: 1, up: 0.5) }
        XCTAssertTrue(BufferbloatRule().evaluate(range([
            session(day: 0, throughput: tests),
        ])).isEmpty)
    }

    /// Unmeasured is not zero: results with no idle baseline carry no
    /// bufferbloat and must not be counted as good ones.
    func testBufferbloatIgnoresUnmeasuredResults() {
        let tests = (0..<9).map { test(nil, at: Double($0) * 3_600) }
        XCTAssertTrue(BufferbloatRule().evaluate(range([
            session(day: 0, throughput: tests),
        ])).isEmpty)
    }

    // MARK: - Ordering

    func testFindingsComeBackMostSevereFirst() {
        let tests = (0..<9).map { test(500, at: Double($0) * 3_600) }
        let findings = Diagnosis.findings(for: range([
            session(day: 0, internetTimeouts: 200, throughput: tests),
            session(day: 1, internetTimeouts: 200),
        ]))
        XCTAssertGreaterThanOrEqual(findings.count, 2)
        XCTAssertEqual(findings.first?.severity, .critical, "severe bufferbloat outranks loss")
    }

    // MARK: - Router loss, split by what the radio was doing

    /// The most important guard in the catalogue. One real session has 164
    /// router-only losses at −29 to −40 dBm; telling that user their Wi-Fi is
    /// failing would be wrong.
    func testRouterLossWithAStrongSignalIsNotAWiFiFault() {
        let findings = RouterLossRule().evaluate(range([
            session(day: 0, samples: 1_147, routerTimeouts: 164,
                    radio: radio(rssi: [-29, -35, -40])),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].rule, Finding.Rule.routerLossStrongSignal)
        XCTAssertEqual(findings[0].side, Finding.Side.router)
        XCTAssertEqual(findings[0].severity, Finding.Severity.info)
        XCTAssertTrue(findings[0].action?.contains("Nothing to fix") ?? false)
    }

    func testRouterLossWithAWeakSignalIsAWiFiFault() {
        let findings = RouterLossRule().evaluate(range([
            session(day: 0, routerTimeouts: 200,
                    radio: radio(rssi: [-72, -75, -68, -71])),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].rule, Finding.Rule.routerLossWeakSignal)
        XCTAssertEqual(findings[0].side, Finding.Side.localLink)
        XCTAssertTrue(findings[0].action?.contains("Move closer") ?? false)
    }

    /// Without radio readings the rule cannot tell the two apart, so it says
    /// nothing rather than guessing.
    func testRouterLossSaysNothingWithoutRadioReadings() {
        XCTAssertTrue(RouterLossRule().evaluate(range([
            session(day: 0, routerTimeouts: 200),
        ])).isEmpty)
    }

    func testRouterLossDoesNotFireWhenTheInternetIsAlsoLosing() {
        XCTAssertTrue(RouterLossRule().evaluate(range([
            session(day: 0, routerTimeouts: 200, internetTimeouts: 200,
                    radio: radio(rssi: [-72, -75])),
        ])).isEmpty)
    }

    // MARK: - Link dropped

    func testLinkDroppedFiresWhenNeitherHostAnswered() {
        let findings = LinkDroppedRule().evaluate(range([
            session(day: 0, samples: 2_873, routerTimeouts: 96,
                    internetTimeouts: 96, bothTimeouts: 96),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].side, Finding.Side.localLink)
    }

    func testLinkDroppedNamesAChannelChangeWhenThereWasOne() {
        let findings = LinkDroppedRule().evaluate(range([
            session(day: 0, samples: 2_873, routerTimeouts: 96,
                    internetTimeouts: 96, bothTimeouts: 96,
                    radio: radio(rssi: [-50], channels: [36, 100])),
        ]))
        XCTAssertTrue(findings[0].action?.contains("Pin the access point") ?? false)
    }

    func testLinkDroppedIgnoresLossOnOneSideOnly() {
        XCTAssertTrue(LinkDroppedRule().evaluate(range([
            session(day: 0, routerTimeouts: 200),
        ])).isEmpty)
    }

    // MARK: - Bad sessions

    /// The 9 Sep case: one session scored near zero on bufferbloat, too few
    /// tests for the bufferbloat rule, and nothing on screen said so.
    func testBadSessionsNamesOneSessionNoPatternExplains() {
        let bad = session(day: 1, throughput: [test(491, at: 86_400)])
        let findings = BadSessionsRule().evaluate(range([
            session(day: 0), bad, session(day: 2), session(day: 3),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].sessionIDs, [bad.id])
        XCTAssertEqual(findings[0].side, .router, "bufferbloat is the router's side")
        XCTAssertEqual(findings[0].severity, .notice)
        XCTAssertEqual(findings[0].headline, "One session went badly")
        XCTAssertTrue(findings[0].evidence.measurement.contains("bufferbloat"))
        XCTAssertTrue(findings[0].evidence.scope.contains("1 of 4"))
        XCTAssertTrue(findings[0].action?.contains("Too few to call a pattern") ?? false)
    }

    func testBadSessionsStaysQuietWhenEverySessionScoredWell() {
        XCTAssertTrue(BadSessionsRule().evaluate(range([
            session(day: 0), session(day: 1),
        ])).isEmpty)
    }

    /// When the bufferbloat rule already cites the session, saying it again
    /// with less to say would bury the finding that has a cause.
    func testBadSessionsDefersToTheRuleThatExplainsIt() {
        let tests = (0..<9).map { test(238, at: Double($0) * 3_600) }
        let findings = Diagnosis.findings(for: range([
            session(day: 0, throughput: tests), session(day: 1),
        ]))
        XCTAssertTrue(findings.contains { $0.rule == Finding.Rule.bufferbloat })
        XCTAssertFalse(findings.contains { $0.rule == Finding.Rule.badSessions })
    }

    /// Explained is per component: a session a loss rule cites is still
    /// reported for a bufferbloat score the loss rule says nothing about.
    func testBadSessionsOnlyDefersForTheSameComponent() {
        let bad = session(day: 0, routerTimeouts: 200, bothTimeouts: 0,
                          throughput: [test(491, at: 0)],
                          radio: radio(rssi: Array(repeating: -35, count: 60)))
        let findings = Diagnosis.findings(for: range([bad, session(day: 1)]))
        XCTAssertTrue(findings.contains { $0.rule == Finding.Rule.routerLossStrongSignal })
        XCTAssertTrue(findings.contains {
            $0.rule == Finding.Rule.badSessions && $0.sessionIDs == [bad.id]
        })
    }

    func testBadSessionsIgnoresSessionsThatStoppedMeasuring() {
        XCTAssertTrue(BadSessionsRule().evaluate(range([
            session(day: 0, samples: 600, throughput: [test(491, at: 0)], coverage: 0.2),
            session(day: 1),
        ])).isEmpty, "a withheld score is not a bad score")
    }

    func testBadSessionsStopsCallingItAFewWhenItIsMostOfTheRange() {
        let findings = BadSessionsRule().evaluate(range([
            session(day: 0, throughput: [test(491, at: 0)]),
            session(day: 1, throughput: [test(491, at: 86_400)]),
            session(day: 2),
        ]))
        XCTAssertEqual(findings.first?.headline, "2 sessions went badly")
        XCTAssertFalse(findings.first?.action?.contains("Too few") ?? true)
    }

    // MARK: - Coverage and health

    func testCoverageFiresOnASessionThatStoppedMeasuring() {
        let findings = InsufficientCoverageRule().evaluate(range([
            session(day: 0, samples: 2_467, coverage: 0.187),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].evidence.measurement.contains("19%"))
    }

    func testCoverageStaysQuietWhenEverySessionMeasuredItsClaim() {
        XCTAssertTrue(InsufficientCoverageRule().evaluate(range([
            session(day: 0), session(day: 1),
        ])).isEmpty)
    }

    /// An empty findings list is ambiguous between "nothing wrong" and
    /// "nothing computed". This rule is what makes the difference sayable.
    func testHealthyFiresWhenEverythingElseStaysQuiet() {
        let findings = HealthyRule().evaluate(range([
            session(day: 0), session(day: 1),
        ]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertNil(findings[0].action, "nothing to do is the point")
        XCTAssertTrue(findings[0].evidence.threshold.contains("70"))
    }

    /// It reports the absence of the others, so it must never appear beside
    /// one of them.
    func testHealthyStaysQuietWhenSomethingElseFired() {
        let tests = (0..<9).map { test(238, at: Double($0) * 3_600) }
        let findings = Diagnosis.findings(for: range([
            session(day: 0, throughput: tests), session(day: 1),
        ]))
        XCTAssertFalse(findings.contains { $0.rule == Finding.Rule.healthy })
        XCTAssertTrue(findings.contains { $0.rule == Finding.Rule.bufferbloat })
    }

    /// One bad session is enough to stop the range being called healthy —
    /// otherwise a 0 in the table sits under "Nothing wrong".
    func testHealthyStaysQuietBesideABadSession() {
        let findings = Diagnosis.findings(for: range([
            session(day: 0), session(day: 1, throughput: [test(491, at: 86_400)]),
            session(day: 2),
        ]))
        XCTAssertFalse(findings.contains { $0.rule == Finding.Rule.healthy })
        XCTAssertTrue(findings.contains { $0.rule == Finding.Rule.badSessions })
    }

    func testHealthyNeedsMoreThanOneShortSession() {
        XCTAssertTrue(HealthyRule().evaluate(range([
            session(day: 0, samples: 120),
        ])).isEmpty)
    }
}
