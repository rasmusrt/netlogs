import XCTest
@testable import NetlogsCore

/// The anchor assertions are the contract.
///
/// A threshold may move — and if it does, the score should move with it. What
/// must not move is the *anchor*: that a threshold the app already judges by
/// lands on 70. Break that and the number starts disagreeing with the header
/// above it, which is the whole failure this design exists to prevent.
final class ScoringTests: XCTestCase {

    func testEveryThresholdTheAppJudgesByLandsOn70() {
        XCTAssertEqual(Scoring.loss(ratio: LossGrade.lossyRatio, failures: 100), 70)
        XCTAssertEqual(Scoring.latency(p50Ms: LatencyGrade.Ramp.internet.elevatedMs), 70)
        XCTAssertEqual(Scoring.jitter(ms: JitterGrade.elevatedMs), 70)
        XCTAssertEqual(Scoring.bufferbloat(ms: 100), 70) // BufferbloatGrade.poor
    }

    func testPerfectMeasurementsScore100() {
        XCTAssertEqual(Scoring.loss(ratio: 0, failures: 0), 100)
        XCTAssertEqual(Scoring.latency(p50Ms: 5), 100)
        XCTAssertEqual(Scoring.jitter(ms: 0), 100)
        XCTAssertEqual(Scoring.bufferbloat(ms: 0), 100)
    }

    func testEachComponentIsMonotone() {
        func nonIncreasing(_ values: [Int], _ what: String) {
            for (a, b) in zip(values, values.dropFirst()) {
                XCTAssertGreaterThanOrEqual(a, b, "\(what) went up as the measurement got worse")
            }
        }
        nonIncreasing(stride(from: 0.0, through: 0.5, by: 0.01)
            .map { Scoring.loss(ratio: $0, failures: 100) }, "loss")
        nonIncreasing(stride(from: 0.0, through: 1_200, by: 10)
            .map { Scoring.latency(p50Ms: $0) }, "latency")
        nonIncreasing(stride(from: 0.0, through: 500, by: 5)
            .map { Scoring.jitter(ms: $0) }, "jitter")
        nonIncreasing(stride(from: 0.0, through: 1_000, by: 10)
            .map { Scoring.bufferbloat(ms: $0) }, "bufferbloat")
    }

    func testScoresStayInRange() {
        for value in stride(from: -100.0, through: 5_000, by: 25) {
            for score in [Scoring.latency(p50Ms: value), Scoring.jitter(ms: value),
                          Scoring.bufferbloat(ms: value),
                          Scoring.loss(ratio: value / 1000, failures: 100)] {
                XCTAssertTrue((0...100).contains(score), "\(score) from \(value)")
            }
        }
    }

    /// A ratio over a small denominator is noise. `SessionVerdict` already
    /// refuses to report it, and the score has to refuse in the same place or
    /// a healthy header sits above a mediocre number.
    func testTrivialFailureCountsDoNotDentTheScore() {
        XCTAssertEqual(Scoring.loss(ratio: 2.0 / 60, failures: 2), 100)
        XCTAssertLessThan(Scoring.loss(ratio: 3.0 / 60, failures: 3), 100)
    }

    /// The grade a score reports is the grade the measurement would have got,
    /// which is what "the score cannot disagree with the header" means in
    /// practice.
    func testAScoreNamesTheSameGradeItsMeasurementWould() {
        for ms in [10.0, 74.0, 75.0, 120.0, 150.0, 250.0, 300.0, 800.0] {
            let score = Scoring.latency(p50Ms: ms)
            XCTAssertEqual(ScoreComponentKind.latency.label(forScore: score),
                           LatencyGrade(milliseconds: ms, on: .internet).label,
                           "\(ms) ms scored \(score)")
        }
        for ms in [0.0, 29.0, 30.0, 59.0, 60.0, 119.0, 120.0, 400.0] {
            let score = Scoring.jitter(ms: ms)
            XCTAssertEqual(ScoreComponentKind.jitter.label(forScore: score),
                           JitterGrade(milliseconds: ms).label,
                           "\(ms) ms scored \(score)")
        }
    }

    // MARK: - The overall

    private func component(_ kind: ScoreComponentKind, _ value: Int) -> ScoreComponent {
        ScoreComponent(kind: kind, value: value, measurement: 0)
    }

    func testTheOverallIsTheWorstComponentAndNamesIt() {
        let score = NetworkScore(components: [
            component(.loss, 100), component(.latency, 92),
            component(.jitter, 87), component(.bufferbloat, 42),
        ])
        XCTAssertEqual(score.value, 42)
        XCTAssertEqual(score.limiting?.kind, .bufferbloat)
        XCTAssertTrue(score.isComplete)
    }

    /// The reason every rendering must state its component count: the overall
    /// is a minimum, so an absent component silently *raises* it. A session
    /// with no speed tests must not look better than one that measured them.
    func testAnUnmeasuredComponentRaisesTheScoreAndIsReported() {
        let complete = NetworkScore(components: [
            component(.loss, 100), component(.latency, 92),
            component(.jitter, 87), component(.bufferbloat, 42),
        ])
        let noTests = NetworkScore(components: [
            component(.loss, 100), component(.latency, 92), component(.jitter, 87),
        ])
        XCTAssertGreaterThan(noTests.value, complete.value)
        XCTAssertFalse(noTests.isComplete)
        XCTAssertEqual(noTests.unmeasuredKinds, [.bufferbloat])
    }

    /// Something is always lowest. Saying a healthy connection is "limited by
    /// jitter (fine)" reads as a fault where there is none — found by running
    /// the score over real sessions, not by reading it.
    func testNothingIsCalledALimitUntilItLimits() {
        let healthy = NetworkScore(components: [
            component(.loss, 100), component(.latency, 92),
            component(.jitter, 78), component(.bufferbloat, 88),
        ])
        XCTAssertEqual(healthy.limiting?.kind, .jitter, "still the lowest")
        XCTAssertNil(healthy.constraint, "but nothing has crossed the problem line")

        let limited = NetworkScore(components: [
            component(.loss, 100), component(.latency, 92),
            component(.jitter, 78), component(.bufferbloat, 54),
        ])
        XCTAssertEqual(limited.constraint?.kind, .bufferbloat)
    }

    /// The problem line is the anchor every threshold is pinned to, so a
    /// component exactly at a threshold is not yet a constraint.
    func testTheProblemLineIsTheAnchor() {
        XCTAssertEqual(Scoring.problemScore, 70)
        let atThreshold = NetworkScore(components: [
            component(.loss, 100), component(.latency, 70),
            component(.jitter, 90), component(.bufferbloat, 90),
        ])
        XCTAssertNil(atThreshold.constraint)
    }

    func testWithheldReasonsReadAsSentences() {
        XCTAssertTrue(ScoreWithheld.tooFewSamples(12).reason.contains("30"))
        XCTAssertTrue(ScoreWithheld.poorCoverage(measured: 2_467, expected: 13_200)
            .reason.contains("19%"))
        XCTAssertTrue(ScoreWithheld.tooFewComponents(2).reason.contains("2 of 4"))
    }
}
