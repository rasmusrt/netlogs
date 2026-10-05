import XCTest
@testable import NetlogsCore

/// The ramps, and the anchors they are derived from.
///
/// These assertions are the contract: a threshold may move, but the *shape* —
/// one external number and stated multiples of it — must not quietly become
/// three unrelated constants again, which is how the ramp this replaced ended
/// up with red at 500 ms.
final class GradeTests: XCTestCase {

    // MARK: - Latency

    /// ITU-T G.114: 150 ms one-way is the limit for acceptable interactive
    /// voice, so 300 ms round trip is where `.severe` begins. The other two
    /// steps are that number halved, twice.
    func testLatencyRampIsDerivedFromOneAnchor() {
        let internetRamp = LatencyGrade.Ramp.internet
        XCTAssertEqual(internetRamp.severeMs, 300)
        XCTAssertEqual(internetRamp.highMs, internetRamp.severeMs / 2)
        XCTAssertEqual(internetRamp.elevatedMs, internetRamp.severeMs / 4)
    }

    /// The gateway gets a fifth of the same 300 ms budget — one hop of the many
    /// a round trip has to fit into — and then the same halving.
    func testGatewayRampIsAFifthOfTheSameAnchor() {
        let gateway = LatencyGrade.Ramp.gateway
        XCTAssertEqual(gateway.severeMs, LatencyGrade.Ramp.internet.severeMs / 5)
        XCTAssertEqual(gateway.highMs, gateway.severeMs / 2)
        XCTAssertEqual(gateway.elevatedMs, gateway.severeMs / 4)
    }

    func testLatencyBoundaries() {
        XCTAssertEqual(LatencyGrade(milliseconds: 0, on: .internet), .fine)
        XCTAssertEqual(LatencyGrade(milliseconds: 74.9, on: .internet), .fine)
        XCTAssertEqual(LatencyGrade(milliseconds: 75, on: .internet), .elevated)
        XCTAssertEqual(LatencyGrade(milliseconds: 149.9, on: .internet), .elevated)
        XCTAssertEqual(LatencyGrade(milliseconds: 150, on: .internet), .high)
        XCTAssertEqual(LatencyGrade(milliseconds: 299.9, on: .internet), .high)
        XCTAssertEqual(LatencyGrade(milliseconds: 300, on: .internet), .severe)
        XCTAssertEqual(LatencyGrade(milliseconds: 5_000, on: .internet), .severe)
    }

    func testGatewayBoundaries() {
        XCTAssertEqual(LatencyGrade(milliseconds: 0, on: .gateway), .fine)
        XCTAssertEqual(LatencyGrade(milliseconds: 14.9, on: .gateway), .fine)
        XCTAssertEqual(LatencyGrade(milliseconds: 15, on: .gateway), .elevated)
        XCTAssertEqual(LatencyGrade(milliseconds: 29.9, on: .gateway), .elevated)
        XCTAssertEqual(LatencyGrade(milliseconds: 30, on: .gateway), .high)
        XCTAssertEqual(LatencyGrade(milliseconds: 59.9, on: .gateway), .high)
        XCTAssertEqual(LatencyGrade(milliseconds: 60, on: .gateway), .severe)
    }

    /// The case the shared ramp got wrong. This database's gateway has a median
    /// of 6.7 ms; 70 ms is ten times that and plainly broken, and the one ramp
    /// called it "fine" — the same word it gave a 6 ms reply.
    func testATenfoldGatewayReplyIsNotFine() {
        XCTAssertEqual(LatencyGrade(milliseconds: 70, on: .gateway), .severe)
        XCTAssertEqual(LatencyGrade(milliseconds: 70, on: .internet), .fine)
    }

    /// A call at 400 ms round trip is unusable. The ramp it replaced still
    /// called that merely "high", one step short of its worst.
    func testAnUnusableCallGradesSevere() {
        XCTAssertEqual(LatencyGrade(milliseconds: 400, on: .internet), .severe)
    }

    func testLatencyGradesAreOrderedAndDistinct() {
        XCTAssertLessThan(LatencyGrade.fine, LatencyGrade.elevated)
        XCTAssertLessThan(LatencyGrade.elevated, LatencyGrade.high)
        XCTAssertLessThan(LatencyGrade.high, LatencyGrade.severe)
        XCTAssertEqual(Set(LatencyGrade.allCases.map(\.label)).count,
                       LatencyGrade.allCases.count,
                       "the BufferbloatCard bug: two tiers sharing one word")
    }

    // MARK: - Jitter

    /// The verdict calls a session unstable at 30 ms. The tint must start
    /// there, not at the latency ramp's first step — that disagreement put an
    /// amber headline above a plain number.
    func testJitterIsAnchoredOnTheVerdictThreshold() {
        XCTAssertEqual(JitterGrade.elevatedMs, SessionVerdict.jitterThresholdMs)
        XCTAssertEqual(JitterGrade.highMs, SessionVerdict.jitterThresholdMs * 2)
        XCTAssertEqual(JitterGrade.severeMs, SessionVerdict.jitterThresholdMs * 4)

        XCTAssertEqual(JitterGrade(milliseconds: 29.9), .fine)
        XCTAssertEqual(JitterGrade(milliseconds: 30), .elevated)
        XCTAssertEqual(JitterGrade(milliseconds: 50), .elevated,
                       "the case that used to render untinted under an amber verdict")
        XCTAssertEqual(JitterGrade(milliseconds: 120), .severe)
    }

    // MARK: - Loss

    func testLossUsesTheVerdictsOwnThresholds() {
        XCTAssertEqual(LossGrade.lossyRatio, SessionVerdict.lossyLossRatio)
        XCTAssertEqual(LossGrade.severeRatio, SessionVerdict.offlineLossRatio)

        XCTAssertEqual(LossGrade(ratio: 0), .none)
        XCTAssertEqual(LossGrade(ratio: 0.019), .none)
        XCTAssertEqual(LossGrade(ratio: 0.02), .lossy)
        XCTAssertEqual(LossGrade(ratio: 0.25), .severe)
        XCTAssertEqual(LossGrade(ratio: 1), .severe)
    }
}
