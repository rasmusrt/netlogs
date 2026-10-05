import XCTest
@testable import NetlogsCore

/// The verdict is the one piece of judgement the UI renders, and both the live
/// header and the saved-session header call it. Testing it here is what makes
/// them provably identical.
final class SessionVerdictTests: XCTestCase {

    /// `failures` are internet timeouts, which is the common case; a
    /// router-only outage is built with `routerFailures` instead. The two were
    /// conflated here before — this helper hardcoded `routerTimeouts: 0`, which
    /// is precisely why nothing caught the verdict scoring router silence as
    /// connection loss.
    private func summary(
        samples: Int,
        failures: Int = 0,
        routerFailures: Int = 0,
        internetSamples: Int? = nil,
        jitter: Double = 2,
        avg: Double = 20
    ) -> LiveSummary {
        LiveSummary(
            router: PingStat(min: 1, avg: 3, max: 8, jitter: 1, p50: 3, p95: 5, p99: 7,
                             samples: samples - routerFailures),
            internet: PingStat(min: avg / 2, avg: avg, max: avg * 3, jitter: jitter,
                               p50: avg, p95: avg * 2, p99: avg * 3,
                               samples: internetSamples ?? (samples - failures)),
            totalSamples: samples,
            routerTimeouts: routerFailures,
            internetTimeouts: failures,
            // Samples where *either* host was silent. Overlap is not modelled;
            // tests set one side or the other.
            failureCount: failures + routerFailures
        )
    }

    private func averages(bufferbloatMs: Double, count: Int = 3) -> ThroughputAverages {
        ThroughputAverages(
            count: count,
            downloadMbps: 500, uploadMbps: 50,
            bufferbloatMs: bufferbloatMs
        )
    }

    func testWithholdsJudgementUntilThereIsEnoughData() {
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 0)), .insufficientData)
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 29)), .insufficientData)
        XCTAssertNotEqual(SessionVerdict.evaluate(summary: summary(samples: 30)), .insufficientData)
    }

    /// The case that made every session open by shouting: a single dropped
    /// ping early on is 10% loss by ratio, which is not a finding.
    func testASingleEarlyDropIsNotReportedAsLoss() {
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: summary(samples: 40, failures: 1)),
            .good
        )
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: summary(samples: 40, failures: 2)),
            .good
        )
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: summary(samples: 40, failures: 3)),
            .lossy,
            "three real drops in forty samples is worth reporting"
        )
    }

    func testHealthySessionReadsGood() {
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 600)), .good)
    }

    func testNoInternetReplyAtAllIsOffline() {
        let s = summary(samples: 60, failures: 60, internetSamples: 0)
        XCTAssertEqual(SessionVerdict.evaluate(summary: s), .offline)
    }

    func testHeavyLossIsOfflineAndModerateLossIsLossy() {
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 100, failures: 30)), .offline)
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 100, failures: 5)), .lossy)
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 100, failures: 1)), .good)
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 600, failures: 12)), .lossy)
    }

    func testBufferbloatOutranksJitterButNotLoss() {
        let clean = summary(samples: 600)
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: clean, throughput: averages(bufferbloatMs: 400)),
            .bloated
        )
        // Loss is the more serious symptom and must win.
        let lossy = summary(samples: 600, failures: 30)
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: lossy, throughput: averages(bufferbloatMs: 400)),
            .lossy
        )
    }

    func testModerateBufferbloatIsNotCalledOut() {
        let clean = summary(samples: 600)
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: clean, throughput: averages(bufferbloatMs: 60)),
            .good,
            "only poor/severe bufferbloat is worth interrupting the user for"
        )
    }

    func testJitterIsReportedWhenNothingWorseIsWrong() {
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 600, jitter: 45)), .jittery)
        XCTAssertEqual(SessionVerdict.evaluate(summary: summary(samples: 600, jitter: 5)), .good)
    }

    func testAThroughputResultWithNoTestsIsIgnored() {
        let clean = summary(samples: 600)
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: clean,
                                    throughput: averages(bufferbloatMs: 900, count: 0)),
            .good
        )
    }

    // MARK: - Bufferbloat grade

    func testGradeThresholdsAndOrdering() {
        XCTAssertEqual(BufferbloatGrade(milliseconds: 0), .excellent)
        XCTAssertEqual(BufferbloatGrade(milliseconds: 29.9), .excellent)
        XCTAssertEqual(BufferbloatGrade(milliseconds: 30), .moderate)
        XCTAssertEqual(BufferbloatGrade(milliseconds: 99.9), .moderate)
        XCTAssertEqual(BufferbloatGrade(milliseconds: 100), .poor)
        XCTAssertEqual(BufferbloatGrade(milliseconds: 299.9), .poor)
        XCTAssertEqual(BufferbloatGrade(milliseconds: 300), .severe)
        XCTAssertEqual(BufferbloatGrade(milliseconds: 5000), .severe)

        XCTAssertTrue(BufferbloatGrade.excellent < .moderate)
        XCTAssertTrue(BufferbloatGrade.poor < .severe)
    }

    /// The old card had three colour thresholds and four labels, so "severe"
    /// and "poor" were painted the same. One type now owns both.
    func testEveryGradeHasADistinctLabel() {
        let labels = BufferbloatGrade.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, BufferbloatGrade.allCases.count)
    }

    func testEveryVerdictHasAHeadlineAndReason() {
        let s = summary(samples: 600, failures: 20, jitter: 40)
        for verdict in SessionVerdict.allCases {
            XCTAssertFalse(verdict.headline.isEmpty)
            XCTAssertFalse(verdict.systemImage.isEmpty)
            XCTAssertFalse(
                SessionVerdict.reason(for: verdict, summary: s,
                                      throughput: averages(bufferbloatMs: 200)).isEmpty
            )
        }
    }

    // MARK: - Router loss is not connection loss

    /// The defect: a gateway that drops ICMP while the internet answers
    /// everything used to read "Connection down — 600 of 600 pings lost",
    /// beside an Internet card showing 600 replies.
    func testRouterOnlyLossIsNotOffline() {
        let s = summary(samples: 600, failures: 0, routerFailures: 600)
        let verdict = SessionVerdict.evaluate(summary: s)

        XCTAssertEqual(verdict, .routerLossy)
        XCTAssertNotEqual(verdict, .offline)
        XCTAssertEqual(verdict.severity, 1, "the internet works; this is a warning")

        let reason = SessionVerdict.reason(for: verdict, summary: s)
        XCTAssertTrue(reason.contains("router"), reason)
        XCTAssertTrue(reason.contains("internet unaffected"), reason)
    }

    /// Partial router loss, still not the internet's problem.
    func testPartialRouterLossReportsTheRouter() {
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: summary(samples: 600, routerFailures: 60)),
            .routerLossy
        )
    }

    /// And the other half of the fix: with loss measured on the internet alone,
    /// router silence must not fall through to "healthy" either.
    func testRouterLossIsNeverReportedAsHealthy() {
        for lost in [30, 100, 599, 600] {
            XCTAssertNotEqual(
                SessionVerdict.evaluate(summary: summary(samples: 600, routerFailures: lost)),
                .good,
                "\(lost) router timeouts"
            )
        }
    }

    /// Below the reporting threshold the router is not worth mentioning, the
    /// same rule internet loss already followed.
    func testTrivialRouterLossStaysHealthy() {
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: summary(samples: 600, routerFailures: 2)),
            .good
        )
    }

    /// Internet loss still outranks router loss: if both are dropping, the one
    /// the user actually feels is the one named.
    func testInternetLossOutranksRouterLoss() {
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: summary(samples: 600, failures: 300,
                                                     routerFailures: 300)),
            .offline
        )
        XCTAssertEqual(
            SessionVerdict.evaluate(summary: summary(samples: 600, failures: 30,
                                                     routerFailures: 300)),
            .lossy
        )
    }

    /// The loss figures quoted in the reason describe the internet host, not
    /// the union of both.
    func testLossReasonCountsInternetTimeoutsOnly() {
        let s = summary(samples: 1000, failures: 50, routerFailures: 400)
        let reason = SessionVerdict.reason(for: .lossy, summary: s)
        XCTAssertTrue(reason.contains("50 of 1000"), reason)
        XCTAssertFalse(reason.contains("450"), reason)
    }
}
