import SwiftUI
import NetlogsCore

/// The figures the Analysis screen reads off a session, and the plain words it
/// grades them with.
///
/// One place, so the tiles, the chart and the readout cannot each pick a
/// slightly different number for "this session's latency". Every value is
/// optional: a session that never ran a speed test has no lag-under-load
/// figure, and drawing it as zero would be the schema-2 lie again.
enum AnalysisFigures {

    // MARK: - Per session

    /// The value a session contributes to a metric's tile and its chart bar.
    static func value(_ metric: AnalysisMetric, of analysis: SessionAnalysis) -> Double? {
        switch metric {
        case .latency:
            return analysis.latency.count > 0 ? analysis.latency.p50 : nil
        case .loss:
            return analysis.aggregate.totalSamples > 0 ? analysis.internetLossRatio : nil
        case .jitter:
            return analysis.aggregate.internet.jitterPairs >= 30
                ? analysis.aggregate.internet.measuredJitter : nil
        case .bufferbloat:
            return analysis.medianBufferbloatMs
        }
    }

    /// The two stacked parts of a session's bar. `lower` is drawn solid,
    /// `upper` lighter on top of it.
    ///
    /// Latency: typical (p50), then up to the peaks (p95). Loss: lost on the
    /// way to the router, then lost beyond it — the split the app exists for.
    static func bar(_ metric: AnalysisMetric, of analysis: SessionAnalysis)
        -> (lower: Double, upper: Double)? {
        switch metric {
        case .latency:
            guard analysis.latency.count > 0 else { return nil }
            return (analysis.latency.p50, analysis.latency.p95)
        case .loss:
            let total = Double(analysis.aggregate.totalSamples)
            guard total > 0 else { return nil }
            let home = max(analysis.routerLossRatio, 0)
            let upstream = Double(analysis.internetOnlyTimeouts) / total
            return (home, home + upstream)
        case .jitter, .bufferbloat:
            guard let value = value(metric, of: analysis) else { return nil }
            return (value, value)
        }
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// The tile's figure: the median across the sessions that measured it.
    static func median(_ metric: AnalysisMetric, of sessions: [SessionAnalysis]) -> Double? {
        median(sessions.compactMap { value(metric, of: $0) })
    }

    // MARK: - Formatting

    static func format(_ metric: AnalysisMetric, _ value: Double) -> (value: String, unit: String) {
        switch metric {
        case .latency:     return (Fmt.msCoarse(value), "ms")
        case .loss:        return (Fmt.percent(value).replacingOccurrences(of: "%", with: ""), "%")
        case .jitter:      return (Fmt.ms(value), "ms")
        case .bufferbloat: return ("+" + Fmt.msCoarse(value), "ms")
        }
    }

    static func axisLabel(_ metric: AnalysisMetric, _ value: Double) -> String {
        metric == .loss ? Fmt.percent(value) : Fmt.msCoarse(value) + " ms"
    }

    // MARK: - Grades in words

    /// A plain word and a colour for a figure, from the same Core grades the
    /// rest of the app tints with. `nil` colour means "fine — no colour".
    static func grade(_ metric: AnalysisMetric, _ value: Double) -> (word: String, tint: Color?) {
        switch metric {
        case .latency:
            let grade = LatencyGrade(milliseconds: value, on: .internet)
            return (word(grade.rawValue), Palette.grade(grade))
        case .jitter:
            let grade = JitterGrade(milliseconds: value)
            return (word(grade.rawValue), Palette.jitter(value))
        case .loss:
            switch LossGrade(ratio: value) {
            case .none:   return ("Good", nil)
            case .lossy:  return ("Lossy", Palette.loss(value))
            case .severe: return ("Bad", Palette.loss(value))
            }
        case .bufferbloat:
            let grade = BufferbloatGrade(milliseconds: value)
            let words = ["Good", "Fair", "Poor", "Bad"]
            let index: Int
            switch grade {
            case .excellent: index = 0
            case .moderate:  index = 1
            case .poor:      index = 2
            case .severe:    index = 3
            }
            return (words[index], index == 0 ? nil : Palette.grade(grade))
        }
    }

    private static func word(_ step: Int) -> String {
        ["Good", "Fair", "Poor", "Bad"][min(max(step, 0), 3)]
    }

    /// The overall score in a word. 70 is `Scoring.problemScore`: below it a
    /// component is a problem, so it is also where "Good" stops.
    static func scoreWord(_ score: Int) -> String {
        switch score {
        case 85...:                   return "Excellent"
        case Scoring.problemScore...: return "Good"
        case 50...:                   return "Fair"
        default:                      return "Poor"
        }
    }

    static func scoreTint(_ score: Int) -> Color {
        switch score {
        case Scoring.problemScore...: return Palette.good
        case 50...:                   return Palette.warn
        default:                      return Palette.bad
        }
    }

    // MARK: - Findings

    /// The colour a finding's severity is drawn in. `healthy` is info, and
    /// reads as good rather than as nothing.
    static func tint(_ finding: Finding) -> Color {
        if finding.rule == .healthy { return Palette.good }
        switch finding.severity {
        case .info:     return .secondary
        case .notice:   return Palette.warn
        case .warning:  return Palette.bad
        case .critical: return Palette.critical
        }
    }

    /// A finding is something to look at unless it is the all-clear or a
    /// note about coverage.
    static func isIssue(_ finding: Finding) -> Bool {
        finding.rule != .healthy && finding.severity >= .notice
    }

    static func sideLabel(_ side: Finding.Side) -> String {
        switch side {
        case .localLink:     return "Your Wi-Fi"
        case .router:        return "Your router"
        case .internetPath:  return "Your provider"
        case .indeterminate: return "Unclear"
        }
    }

    static func sessionTime(_ analysis: SessionAnalysis) -> String {
        let start = analysis.aggregate.firstSampleAt ?? analysis.session.startedAt
        let end = analysis.aggregate.lastSampleAt ?? start
        let day = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let from = start.formatted(date: .omitted, time: .shortened)
        let to = end.formatted(date: .omitted, time: .shortened)
        return "\(day), \(from)–\(to)"
    }
}
