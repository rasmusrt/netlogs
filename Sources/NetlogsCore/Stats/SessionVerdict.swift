import Foundation

/// How bad the latency penalty under load is.
///
/// One type owns both the threshold and the label so they cannot drift. They
/// previously could: `BufferbloatCard.tint` had three thresholds while its
/// `grade` had four, so anything above 300 ms was labelled "severe" but still
/// painted the same colour as "poor".
public enum BufferbloatGrade: Int, Sendable, Equatable, Hashable, Comparable, CaseIterable {
    case excellent
    case moderate
    case poor
    case severe

    public init(milliseconds: Double) {
        switch milliseconds {
        case ..<30:  self = .excellent
        case ..<100: self = .moderate
        case ..<300: self = .poor
        default:     self = .severe
        }
    }

    public var label: String {
        switch self {
        case .excellent: return "excellent"
        case .moderate:  return "moderate"
        case .poor:      return "poor"
        case .severe:    return "severe"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A one-line answer to "is this connection behaving?", replacing a header that
/// showed only raw counters.
///
/// A pure function in Core, with tests, so the live header and the saved-session
/// header are provably identical rather than two hand-written switches that
/// drift apart.
public enum SessionVerdict: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case insufficientData
    case good
    case jittery
    case bloated
    case lossy
    case offline

    /// Minimum samples before any judgement is offered. At 1 Hz this is thirty
    /// seconds. Ten was too eager: one lost ping in the first ten samples is
    /// 10% loss by ratio, so every session opened by announcing "Dropping
    /// packets" in orange before settling down.
    public static let minimumSamples = 30

    /// A ratio over a small denominator is noise, so loss also has to clear an
    /// absolute count before it is worth saying out loud.
    public static let minimumFailuresToReport = 3

    /// Loss at or above this fraction reads as a broken connection rather than
    /// an unreliable one.
    public static let offlineLossRatio = 0.25
    /// Loss at or above this fraction is worth calling out. One dropped ping in
    /// fifty is already visible in a video call.
    public static let lossyLossRatio = 0.02
    /// Mean absolute deviation between consecutive replies, in milliseconds.
    public static let jitterThresholdMs = 30.0

    public var headline: String {
        switch self {
        case .insufficientData: return "Measuring…"
        case .good:             return "Connection healthy"
        case .jittery:          return "Unstable latency"
        case .bloated:          return "Bufferbloat under load"
        case .lossy:            return "Dropping packets"
        case .offline:          return "Connection down"
        }
    }

    public var systemImage: String {
        switch self {
        case .insufficientData: return "clock"
        case .good:             return "checkmark.circle.fill"
        case .jittery:          return "waveform.path"
        case .bloated:          return "arrow.down.right.and.arrow.up.left"
        case .lossy:            return "exclamationmark.triangle.fill"
        case .offline:          return "bolt.horizontal.circle.fill"
        }
    }

    /// Ranked most severe first, so the caller can pick a colour without
    /// re-deriving a switch.
    public var severity: Int {
        switch self {
        case .insufficientData: return 0
        case .good:             return 0
        case .jittery:          return 1
        case .bloated:          return 2
        case .lossy:            return 2
        case .offline:          return 3
        }
    }

    /// Evaluates the session, most severe condition first.
    public static func evaluate(
        summary: LiveSummary,
        throughput: ThroughputAverages? = nil
    ) -> SessionVerdict {
        guard summary.totalSamples >= minimumSamples else { return .insufficientData }

        let lossRatio = Double(summary.failureCount) / Double(summary.totalSamples)

        // Never once reached the internet host: down, regardless of the ratio.
        if summary.internet.samples == 0 { return .offline }

        if summary.failureCount >= minimumFailuresToReport {
            if lossRatio >= offlineLossRatio { return .offline }
            if lossRatio >= lossyLossRatio { return .lossy }
        }

        if let throughput, throughput.count > 0,
           BufferbloatGrade(milliseconds: throughput.bufferbloatMs) >= .poor {
            return .bloated
        }

        if summary.internet.jitter > jitterThresholdMs { return .jittery }

        return .good
    }

    /// A short sentence naming the evidence behind the verdict.
    public static func reason(
        for verdict: SessionVerdict,
        summary: LiveSummary,
        throughput: ThroughputAverages? = nil
    ) -> String {
        switch verdict {
        case .insufficientData:
            return "\(summary.totalSamples) of \(minimumSamples) samples"
        case .good:
            // Below the reporting threshold is not the same as none, and
            // claiming "no loss" beside a non-empty Failures tab is the kind of
            // small lie that costs trust in everything else on screen.
            let dropped = summary.failureCount
            let tail = dropped == 0
                ? "no loss"
                : "\(dropped) dropped of \(summary.totalSamples.formatted())"
            return String(format: "%.0f ms average", summary.internet.avg) + ", " + tail
        case .jittery:
            return String(format: "%.0f ms jitter between replies", summary.internet.jitter)
        case .bloated:
            let ms = throughput?.bufferbloatMs ?? 0
            return String(format: "latency rises %.0f ms under load", ms)
        case .lossy:
            let pct = Double(summary.failureCount) / Double(max(summary.totalSamples, 1)) * 100
            return String(format: "%.1f%% of pings lost (%d of %d)",
                          pct, summary.failureCount, summary.totalSamples)
        case .offline:
            return summary.internet.samples == 0
                ? "no reply from the internet host"
                : "\(summary.failureCount) of \(summary.totalSamples) pings lost"
        }
    }
}
