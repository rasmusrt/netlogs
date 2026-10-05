import Foundation

/// What is limiting a connection, expressed as a number without inventing a
/// judgement the app does not already make.
///
/// Every component is a piecewise-linear reparameterisation of thresholds that
/// already exist in Core, with each threshold pinned to a fixed anchor:
///
/// **70 is where the app's own logic starts calling something a problem** —
/// `LossGrade.lossyRatio`, `LatencyGrade.Ramp.internet.elevatedMs`,
/// `JitterGrade.elevatedMs`,
/// and `BufferbloatGrade.poor`. The mapping is monotone and invertible within
/// each segment, so the grade is recoverable from the number. The score cannot
/// disagree with the verdict header, because it *is* the verdict's thresholds
/// in different units.
///
/// There is deliberately no score-band vocabulary — no "excellent/good/fair".
/// A second set of words over the same thresholds is how `BufferbloatCard.tint`
/// drifted from its own grade and painted "severe" as "poor".
public enum ScoreComponentKind: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case loss, latency, jitter, bufferbloat

    /// The word for this component's own grade at a given score, so a caller
    /// never has to invent one.
    public func label(forScore score: Int) -> String {
        switch self {
        case .loss:        return LossGrade(ratio: Scoring.lossRatio(forScore: score)).label
        case .latency:     return LatencyGrade(milliseconds: Scoring.latencyMs(forScore: score),
                                               on: .internet).label
        case .jitter:      return JitterGrade(milliseconds: Scoring.jitterMs(forScore: score)).label
        case .bufferbloat: return BufferbloatGrade(milliseconds: Scoring.bufferbloatMs(forScore: score)).label
        }
    }
}

public struct ScoreComponent: Sendable, Equatable, Identifiable, Codable {
    public let kind: ScoreComponentKind
    /// 0…100.
    public let value: Int
    /// The measurement it came from, in that component's own units — kept so a
    /// card can show the figure beside the score rather than the score alone.
    public let measurement: Double

    public var id: ScoreComponentKind { kind }

    public init(kind: ScoreComponentKind, value: Int, measurement: Double) {
        self.kind = kind
        self.value = value
        self.measurement = measurement
    }

    public var label: String { kind.label(forScore: value) }
}

public struct NetworkScore: Sendable, Equatable, Codable {
    /// Only the components that were actually measured.
    public let components: [ScoreComponent]

    public init(components: [ScoreComponent]) {
        self.components = components
    }

    /// The worst component, not an average.
    ///
    /// An average hides the one thing worth fixing: a connection losing 5% of
    /// its packets while everything else is perfect would score in the
    /// mid-eighties and read as fine.
    public var value: Int { components.map(\.value).min() ?? 0 }

    /// The lowest component. Something is always lowest, so this alone is not
    /// a claim that anything is wrong — see ``constraint``.
    public var limiting: ScoreComponent? {
        components.min { $0.value < $1.value }
    }

    /// The component holding the score down, when something actually is.
    ///
    /// `nil` while every component sits above the line the app's own logic
    /// calls a problem. Found by running the score over real sessions: a clean
    /// connection rendered as "limited by jitter (fine)", which reads as a
    /// fault where there is none. A limit is only a limit once it limits.
    public var constraint: ScoreComponent? {
        guard let limiting, limiting.value < Scoring.problemScore else { return nil }
        return limiting
    }

    public var measuredKinds: Set<ScoreComponentKind> { Set(components.map(\.kind)) }
    public var unmeasuredKinds: [ScoreComponentKind] {
        ScoreComponentKind.allCases.filter { !measuredKinds.contains($0) }
    }

    /// Why every rendering of this number must say how many components it had.
    ///
    /// The overall is a *minimum*, so a component that was never measured
    /// silently **raises** the score. A session with no speed tests cannot be
    /// limited by bufferbloat, and would otherwise look better than an
    /// identical session that measured it.
    public var isComplete: Bool { components.count == ScoreComponentKind.allCases.count }
}

public enum ScoreWithheld: Sendable, Equatable, Codable {
    /// Below `SessionVerdict.minimumSamples`; the same discipline as
    /// `.insufficientData`.
    case tooFewSamples(Int)
    /// The Mac stopped measuring for part of what the session claims.
    case poorCoverage(measured: Int, expected: Int)
    /// Fewer than `Scoring.minimumComponents` were measurable.
    case tooFewComponents(Int)

    public var reason: String {
        switch self {
        case .tooFewSamples(let n):
            return "\(n) of \(SessionVerdict.minimumSamples) samples"
        case .poorCoverage(let measured, let expected):
            let pct = expected > 0 ? Double(measured) / Double(expected) * 100 : 0
            return String(format: "measured %.0f%% of what this session claims", pct)
        case .tooFewComponents(let n):
            return "only \(n) of 4 measurements available"
        }
    }
}

public enum ScoreResult: Sendable, Equatable, Codable {
    case scored(NetworkScore)
    case withheld(ScoreWithheld)

    public var score: NetworkScore? {
        if case .scored(let s) = self { return s }
        return nil
    }
}

/// The mappings. Pure, and tested against their anchors.
public enum Scoring {
    /// Below this share of the claimed duration, the session describes a
    /// differently-shaped day than the one it claims and is not scored.
    public static let coverageFloor = 0.80
    /// Fewer than this many measured components and the minimum means too
    /// little to publish.
    public static let minimumComponents = 3
    /// The score every threshold the app judges by is pinned to. Below it, a
    /// component is describing a problem rather than a characteristic.
    public static let problemScore = 100 - 30

    // MARK: - Components

    /// Internet-host loss only. Router silence is not connection loss — the bug
    /// `SessionVerdict` carried until it was fixed.
    ///
    /// Below `SessionVerdict.minimumFailuresToReport` this returns 100, the
    /// same guard `evaluate` applies: without it a 60-sample window with two
    /// timeouts scores 68 while the header says "Connection healthy".
    public static func loss(ratio: Double, failures: Int) -> Int {
        guard failures >= SessionVerdict.minimumFailuresToReport else { return 100 }
        return score(ratio, through: lossKnots)
    }

    public static func latency(p50Ms: Double) -> Int { score(p50Ms, through: latencyKnots) }
    public static func jitter(ms: Double) -> Int { score(ms, through: jitterKnots) }
    public static func bufferbloat(ms: Double) -> Int { score(ms, through: bufferbloatKnots) }

    // MARK: - The knots
    //
    // Each list pins this component's existing thresholds to fixed scores, and
    // the ends are stated multiples rather than further judgements.

    static var lossKnots: [(Double, Double)] {
        [(0, 100), (LossGrade.lossyRatio, 70), (LossGrade.severeRatio, 0)]
    }
    /// The internet ramp, because every component of the score is measured
    /// against the internet host — the loss ratio, the histogram the p50 comes
    /// from, and the jitter. Scoring the gateway would need its own components,
    /// not just its own knots.
    static var latencyKnots: [(Double, Double)] {
        let ramp = LatencyGrade.Ramp.internet
        return [(20, 100), (ramp.elevatedMs, 70), (ramp.highMs, 40),
                (ramp.severeMs, 10), (ramp.severeMs * 2, 0)]
    }
    static var jitterKnots: [(Double, Double)] {
        [(0, 100), (JitterGrade.elevatedMs, 70), (JitterGrade.highMs, 40),
         (JitterGrade.severeMs, 10), (JitterGrade.severeMs * 2, 0)]
    }
    static var bufferbloatKnots: [(Double, Double)] {
        [(0, 100), (30, 90), (100, 70), (300, 30), (600, 0)]
    }

    // MARK: - Inverses, for naming a grade from a score

    static func lossRatio(forScore score: Int) -> Double { invert(score, lossKnots) }
    static func latencyMs(forScore score: Int) -> Double { invert(score, latencyKnots) }
    static func jitterMs(forScore score: Int) -> Double { invert(score, jitterKnots) }
    static func bufferbloatMs(forScore score: Int) -> Double { invert(score, bufferbloatKnots) }

    // MARK: - Interpolation

    /// Linear between knots, flat outside them, rounded once at the end.
    static func score(_ measurement: Double, through knots: [(Double, Double)]) -> Int {
        guard let first = knots.first, let last = knots.last else { return 0 }
        if measurement <= first.0 { return Int(first.1.rounded()) }
        if measurement >= last.0 { return Int(last.1.rounded()) }
        for (low, high) in zip(knots, knots.dropFirst()) where measurement <= high.0 {
            let span = high.0 - low.0
            guard span > 0 else { return Int(high.1.rounded()) }
            let t = (measurement - low.0) / span
            return Int((low.1 + (high.1 - low.1) * t).rounded())
        }
        return Int(last.1.rounded())
    }

    /// The measurement a score corresponds to. Only used to name a grade, so it
    /// need not be exact at a knot's own value — but it is, because the
    /// mapping is monotone and invertible within each segment.
    static func invert(_ score: Int, _ knots: [(Double, Double)]) -> Double {
        let target = Double(score)
        guard let first = knots.first, let last = knots.last else { return 0 }
        if target >= first.1 { return first.0 }
        if target <= last.1 { return last.0 }
        for (low, high) in zip(knots, knots.dropFirst()) where target >= high.1 {
            let span = high.1 - low.1
            guard span != 0 else { return high.0 }
            let t = (target - low.1) / span
            return low.0 + (high.0 - low.0) * t
        }
        return last.0
    }
}
