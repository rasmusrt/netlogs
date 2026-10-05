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
    case routerLossy
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
        case .routerLossy:      return "Router dropping packets"
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
        case .routerLossy:      return "wifi.exclamationmark"
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
        // Warn, not bad. The internet is reachable and the numbers describing
        // it are sound; what is broken is the first hop, which the user can
        // usually do something about.
        case .routerLossy:      return 1
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

        // `internetTimeouts`, not `failureCount`. The latter counts a sample
        // where *either* host was silent (LiveSummary), so a gateway that drops
        // ICMP scored as connection loss: "Connection down, 600 of 600 pings
        // lost" beside an Internet card showing 600 replies at 13 ms. That
        // inverts the router-versus-internet distinction the whole app exists
        // to draw. `ThroughputCard` had the same bug and was fixed; this is the
        // same fix, one layer down.
        // `internetNoRepliesIdle`, not `internetTimeouts`. Two exclusions, and
        // both of them changed a real verdict on real data:
        //
        // - A reply that arrives at 2.4 s against a 2 s timeout is not a lost
        //   packet. An eleven-hour session graded itself on 14 "lost" pings
        //   whose maximum recorded RTT was 1942 ms — the distribution was
        //   clipped at the deadline and every one of the 14 was still in
        //   flight. Counting those as loss is counting the timeout setting.
        // - A ping that missed its deadline because this app was saturating the
        //   uplink measures this app, not the link. Three of that session's
        //   five failure clusters started eleven seconds into a scheduled
        //   upload test. Grading the network on them is grading our own load
        //   generator.
        //
        // What is left is the number to take to an ISP: the internet host was
        // asked, on an unloaded link, and said nothing for five seconds.
        let internetLoss = Double(summary.internetNoRepliesIdle) / Double(summary.totalSamples)

        // Never once reached the internet host: down, regardless of the ratio.
        if summary.internet.samples == 0 { return .offline }

        if summary.internetNoRepliesIdle >= minimumFailuresToReport {
            if internetLoss >= offlineLossRatio { return .offline }
            if internetLoss >= lossyLossRatio { return .lossy }
        }

        // `grade` is nil when no test measured both an idle baseline and a
        // loaded window. An unmeasured baseline used to read as 0 ms, which
        // made the whole load latency look like bufferbloat and could put a
        // session in `.bloated` on the strength of nothing.
        if let throughput, throughput.count > 0,
           let grade = throughput.grade, grade >= .poor {
            return .bloated
        }

        if summary.internet.jitter > jitterThresholdMs { return .jittery }

        // Checked last, and it has to be checked: with loss now measured on the
        // internet host alone, a router dropping every packet would otherwise
        // fall through to "Connection healthy, no loss" — a quieter lie than
        // the one above it, told beside a Failures tab full of timeouts.
        let routerNoReplies = summary.routerNoReplies
        let routerLoss = Double(routerNoReplies) / Double(summary.totalSamples)
        if routerNoReplies >= minimumFailuresToReport,
           routerLoss >= lossyLossRatio {
            return .routerLossy
        }

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
            // Three distinct facts, and the old text collapsed them into one
            // word. "Dropped" now means dropped; a reply that came back over
            // the deadline is named as slow, and a timeout we caused ourselves
            // with a speed test is named as ours. Saying "12 dropped" for a
            // session that lost nothing is the small lie that sent a user to
            // argue with an ISP about a link that was working.
            let lost = summary.noReplyCount
            let late = summary.lateCount
            let tail: String
            if lost == 0, late == 0 {
                tail = "no loss"
            } else if lost == 0 {
                tail = "no loss, \(late) slow repl\(late == 1 ? "y" : "ies")"
            } else {
                tail = "\(lost) dropped of \(summary.totalSamples.formatted())"
            }
            let selfInflicted = summary.failuresUnderLoad
            let note = selfInflicted > 0
                ? " (\(selfInflicted) during speed tests)" : ""
            return String(format: "%.0f ms average", summary.internet.avg) + ", " + tail + note
        case .jittery:
            return String(format: "%.0f ms jitter between replies", summary.internet.jitter)
        case .bloated:
            let ms = throughput?.bufferbloatMs ?? 0
            return String(format: "latency rises %.0f ms under load", ms)
        case .routerLossy:
            return "\(summary.routerNoReplies) of \(summary.totalSamples) pings to the "
                + "router lost, internet unaffected"
        case .lossy:
            let lost = summary.internetNoRepliesIdle
            let pct = Double(lost) / Double(max(summary.totalSamples, 1)) * 100
            return String(format: "%.1f%% of pings lost (%d of %d)",
                          pct, lost, summary.totalSamples)
        case .offline:
            return summary.internet.samples == 0
                ? "no reply from the internet host"
                : "\(summary.internetNoRepliesIdle) of \(summary.totalSamples) pings lost"
        }
    }
}
