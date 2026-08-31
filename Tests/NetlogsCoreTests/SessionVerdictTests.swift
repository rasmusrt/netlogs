import XCTest
@testable import NetlogsCore

/// The verdict is the one piece of judgement the UI renders, and both the live
/// header and the saved-session header call it. Testing it here is what makes
/// them provably identical.
final class SessionVerdictTests: XCTestCase {

    private func summary(
        samples: Int,
        failures: Int = 0,
        internetSamples: Int? = nil,
        jitter: Double = 2,
        avg: Double = 20
    ) -> LiveSummary {
        LiveSummary(
            router: PingStat(min: 1, avg: 3, max: 8, jitter: 1, p50: 3, p95: 5, p99: 7,
                             samples: samples - failures),
            internet: PingStat(min: avg / 2, avg: avg, max: avg * 3, jitter: jitter,
                               p50: avg, p95: avg * 2, p99: avg * 3,
                               samples: internetSamples ?? (samples - failures)),
            totalSamples: samples,
            routerTimeouts: 0,
            internetTimeouts: failures,
            failureCount: failures
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
}
