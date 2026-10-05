import Foundation

/// One thing the app has noticed, with the evidence for it and something to do
/// about it.
///
/// Advice without its evidence is horoscope text, and this app has spent nine
/// phases earning the opposite — so a finding cannot be constructed without the
/// measurement it rests on and the threshold that measurement crossed. The
/// action is optional because "nothing at home to change" is a real answer and
/// often the most useful one.
public struct Finding: Sendable, Equatable, Identifiable {
    /// Declaration order is presentation order among findings of equal
    /// severity, so the most actionable come first.
    public enum Rule: String, Sendable, Equatable, CaseIterable {
        case linkDropped
        case routerLossWeakSignal
        case routerLossStrongSignal
        case upstreamLoss
        case bufferbloat
        case jitterWeakSignal
        case timeOfDayLatency
        case badSessions
        case insufficientCoverage
        case healthy
    }

    public enum Severity: Int, Sendable, Equatable, Comparable, CaseIterable {
        case info, notice, warning, critical
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Which side of the router. The distinction the whole app exists to draw,
    /// and the first thing a reader wants from a finding.
    public enum Side: String, Sendable, Equatable {
        case localLink, router, internetPath, indeterminate
    }

    public struct Evidence: Sendable, Equatable {
        /// What was measured, in its own units.
        public let measurement: String
        /// The threshold it crossed, named and valued.
        public let threshold: String
        /// What the measurement covers: sessions, span, sample count. Without
        /// this a reader cannot tell one bad night from a standing problem.
        public let scope: String

        public init(measurement: String, threshold: String, scope: String) {
            self.measurement = measurement
            self.threshold = threshold
            self.scope = scope
        }

        public var sentence: String { "\(measurement) \(threshold) — \(scope)." }
    }

    public let rule: Rule
    public let severity: Severity
    public let side: Side
    public let headline: String
    public let evidence: Evidence
    public let action: String?
    /// The sessions that produced it, so the table can filter to exactly these.
    public let sessionIDs: [UUID]

    public var id: String { "\(rule.rawValue)-\(sessionIDs.map(\.uuidString).joined())" }

    public init(
        rule: Rule, severity: Severity, side: Side, headline: String,
        evidence: Evidence, action: String?, sessionIDs: [UUID]
    ) {
        self.rule = rule
        self.severity = severity
        self.side = side
        self.headline = headline
        self.evidence = evidence
        self.action = action
        self.sessionIDs = sessionIDs
    }
}

/// A rule is pure and sees the whole range, so it can require evidence across
/// sessions and days before it says anything.
public protocol FindingRule: Sendable {
    static var rule: Finding.Rule { get }
    func evaluate(_ analysis: RangeAnalysis) -> [Finding]
}

public enum Diagnosis {
    public static let rules: [any FindingRule] = [
        LinkDroppedRule(),
        RouterLossRule(),
        UpstreamLossRule(),
        BufferbloatRule(),
        JitterWeakSignalRule(),
        TimeOfDayRule(),
        BadSessionsRule(),
        InsufficientCoverageRule(),
        HealthyRule(),
    ]

    /// Most severe first, then in rule order, so the band's top card is always
    /// the one worth reading first.
    public static func findings(for analysis: RangeAnalysis) -> [Finding] {
        let order = Finding.Rule.allCases
        return rules
            .flatMap { $0.evaluate(analysis) }
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return (order.firstIndex(of: $0.rule) ?? 0) < (order.firstIndex(of: $1.rule) ?? 0)
            }
    }
}

// MARK: - Rules

/// Loss on the internet host while the router answers everything.
///
/// The finding a user cannot get anywhere else, and the one whose action is to
/// do nothing: if the first hop is clean, no amount of moving the laptop or
/// rebooting the router will help. Saying that out loud is the point.
public struct UpstreamLossRule: FindingRule {
    public static let rule = Finding.Rule.upstreamLoss

    /// Two sessions on two different days. A single bad evening is weather, not
    /// climate, and advice that fires on it will be wrong more often than right.
    public static let minimumSessions = 2
    public static let minimumDays = 2
    /// Below this the ratio is noise over too small a denominator.
    public static let minimumSamples = 1_800
    /// The router must be *clean*, not merely better — otherwise a session
    /// where everything struggled reads as an upstream problem.
    public static let routerCleanRatio = 0.005

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        analysis.byTarget.compactMap { group in
            let qualifying = group.sessions.filter {
                Double($0.internetOnlyTimeouts) / Double(max($0.aggregate.totalSamples, 1))
                    >= LossGrade.lossyRatio
                    && $0.routerLossRatio < Self.routerCleanRatio
            }
            guard qualifying.count >= Self.minimumSessions,
                  TargetGroup(key: group.key, sessions: qualifying).distinctDays() >= Self.minimumDays,
                  qualifying.reduce(0, { $0 + $1.aggregate.totalSamples }) >= Self.minimumSamples
            else { return nil }

            let samples = qualifying.reduce(0) { $0 + $1.aggregate.totalSamples }
            let lost = qualifying.reduce(0) { $0 + $1.internetOnlyTimeouts }
            let days = TargetGroup(key: group.key, sessions: qualifying).distinctDays()

            return Finding(
                rule: Self.rule,
                severity: .warning,
                side: .internetPath,
                headline: "Packet loss upstream of your router",
                evidence: Finding.Evidence(
                    measurement: String(
                        format: "%.1f%% of pings to %@ were lost while %@ answered %.1f%% of them",
                        Double(lost) / Double(samples) * 100, group.key.internetHost,
                        group.key.routerHost,
                        100 - qualifying.reduce(0.0) { $0 + $1.routerLossRatio }
                            / Double(qualifying.count) * 100
                    ),
                    threshold: String(format: "(loss is worth reporting from %.0f%%)",
                                      LossGrade.lossyRatio * 100),
                    scope: "\(qualifying.count) sessions across \(days) days, "
                        + "\(samples.formatted()) samples"
                ),
                action: "Nothing at home to change — this is beyond your router. "
                    + "The dates and times are in the table below if you raise it with your ISP.",
                sessionIDs: qualifying.map(\.id)
            )
        }
    }
}

/// Latency rising under load — the reason a fast connection feels slow on
/// calls, and the most commonly fixable thing this app can find.
public struct BufferbloatRule: FindingRule {
    public static let rule = Finding.Rule.bufferbloat

    public static let minimumTests = 3
    /// Two thirds of the tests must individually cross the line, so one bad run
    /// in a good set cannot carry the median.
    public static let majority = 2.0 / 3.0
    /// Tests clustered in ten minutes describe one moment, not a connection.
    public static let minimumSpan: TimeInterval = 2 * 3600
    /// A test that could not load the line says nothing about what load does.
    public static let minimumMbps = 5.0

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        analysis.byTarget.compactMap { group in
            let tests = group.sessions
                .flatMap(\.throughput)
                .filter { $0.bufferbloatMs != nil
                    && ($0.downloadMbps >= Self.minimumMbps || $0.uploadMbps >= Self.minimumMbps) }
            guard tests.count >= Self.minimumTests else { return nil }

            let values = tests.compactMap(\.bufferbloatMs).sorted()
            let median = values.count.isMultiple(of: 2)
                ? (values[values.count / 2 - 1] + values[values.count / 2]) / 2
                : values[values.count / 2]
            let grade = BufferbloatGrade(milliseconds: median)
            guard grade >= .poor else { return nil }

            let over = values.filter { BufferbloatGrade(milliseconds: $0) >= .poor }.count
            guard Double(over) / Double(values.count) >= Self.majority else { return nil }

            let times = tests.map(\.timestamp).sorted()
            guard let first = times.first, let last = times.last,
                  last.timeIntervalSince(first) >= Self.minimumSpan else { return nil }

            let down = tests.reduce(0) { $0 + $1.downloadMbps } / Double(tests.count)
            let up = tests.reduce(0) { $0 + $1.uploadMbps } / Double(tests.count)

            return Finding(
                rule: Self.rule,
                severity: grade >= .severe ? .critical : .warning,
                side: .router,
                headline: "Latency climbs under load",
                evidence: Finding.Evidence(
                    measurement: String(
                        format: "latency rose %.0f ms under load in %d of %d tests behind %@",
                        median, over, values.count, group.key.routerHost
                    ),
                    threshold: "(poor starts at 100 ms, severe at 300 ms)",
                    scope: String(format: "%d sessions, averaging %.0f Mbps down / %.0f Mbps up",
                                  group.sessions.count, down, up)
                ),
                action: String(
                    format: "Look for SQM or Smart Queue Management (fq_codel, CAKE) in your "
                        + "router's settings and shape it to roughly %.0f Mbps down and %.0f up. "
                        + "Re-measure afterwards — this figure should fall below 30 ms.",
                    down * 0.9, up * 0.9
                ),
                sessionIDs: group.sessions.map(\.id)
            )
        }
    }
}

/// Both hosts silent on the same tick: the link itself dropped, not one side of
/// it. Distinct from either loss rule, and the only one that can say so.
public struct LinkDroppedRule: FindingRule {
    public static let rule = Finding.Rule.linkDropped

    public static let ratio = 0.01
    public static let minimumTicks = 20

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        analysis.byTarget.compactMap { group in
            let affected = group.sessions.filter {
                $0.aggregate.bothTimeouts >= Self.minimumTicks
                    && Double($0.aggregate.bothTimeouts)
                        / Double(max($0.aggregate.totalSamples, 1)) >= Self.ratio
            }
            guard !affected.isEmpty else { return nil }

            let dropped = affected.reduce(0) { $0 + $1.aggregate.bothTimeouts }
            let samples = affected.reduce(0) { $0 + $1.aggregate.totalSamples }
            let moved = affected.contains { $0.radio.changedChannel || $0.radio.changedBand }

            return Finding(
                rule: Self.rule,
                severity: .warning,
                side: .localLink,
                headline: "The link itself dropped",
                evidence: Finding.Evidence(
                    measurement: String(
                        format: "%.1f%% of ticks got no reply from either %@ or %@ (%d of %d)",
                        Double(dropped) / Double(samples) * 100,
                        group.key.routerHost, group.key.internetHost, dropped, samples
                    ),
                    threshold: String(format: "(worth reporting from %.0f%%)", Self.ratio * 100),
                    scope: "\(affected.count) session\(affected.count == 1 ? "" : "s")"
                        + (moved ? ", radio changed channel or band during them" : "")
                ),
                action: moved
                    ? "The radio moved between channels while this happened. Pin the access "
                        + "point to one channel and re-measure."
                    : "Both sides went quiet at once, so this is the connection to the "
                        + "network rather than either host. Check for interference, or for "
                        + "an adapter that sleeps.",
                sessionIDs: affected.map(\.id)
            )
        }
    }
}

/// Router loss with a clean internet path — split in two by what the radio was
/// doing, because the same numbers mean opposite things.
///
/// The split is the most important guard in the catalogue. One real session has
/// **164 router-only losses in 1,147 samples at −29 to −40 dBm**: telling that
/// user their Wi-Fi is failing would be wrong, and many routers simply
/// deprioritise ICMP addressed to themselves.
public struct RouterLossRule: FindingRule {
    public static let rule = Finding.Rule.routerLossWeakSignal

    public static let minimumTicks = 20
    /// The internet must be *clean*, not merely better.
    public static let internetCleanRatio = 0.005

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        analysis.byTarget.compactMap { group in
            let affected = group.sessions.filter {
                $0.routerOnlyTimeouts >= Self.minimumTicks
                    && Double($0.routerOnlyTimeouts)
                        / Double(max($0.aggregate.totalSamples, 1)) >= LossGrade.lossyRatio
                    && $0.internetLossRatio < Self.internetCleanRatio
            }
            guard !affected.isEmpty else { return nil }

            let lost = affected.reduce(0) { $0 + $1.routerOnlyTimeouts }
            let samples = affected.reduce(0) { $0 + $1.aggregate.totalSamples }
            let percent = Double(lost) / Double(samples) * 100
            let radios = affected.map(\.radio)
            let strong = radios.allSatisfy { $0.wasStrongThroughout }
            let weak = radios.contains { $0.weakFraction >= 0.10 }
            let onWiFi = radios.contains(where: \.isWiFi)

            let measurement = String(
                format: "%.1f%% of pings to %@ went unanswered while %@ replied to "
                    + "%.1f%% of them",
                percent, group.key.routerHost, group.key.internetHost,
                100 - affected.reduce(0.0) { $0 + $1.internetLossRatio }
                    / Double(affected.count) * 100
            )
            let scope = "\(affected.count) session\(affected.count == 1 ? "" : "s"), "
                + "\(samples.formatted()) samples"

            // Strong signal throughout: not a Wi-Fi fault, and saying so is the
            // useful answer.
            if onWiFi, strong, !weak {
                let radio = radios.compactMap(\.description).first
                return Finding(
                    rule: .routerLossStrongSignal,
                    severity: .info,
                    side: .router,
                    headline: "Your router ignores some pings",
                    evidence: Finding.Evidence(
                        measurement: measurement
                            + (radios.compactMap(\.rssiMin).max()
                                .map { ", with the signal never below \($0) dBm" } ?? ""),
                        threshold: "(loss is worth reporting from 2%)",
                        scope: scope + (radio.map { ", on \($0)" } ?? "")
                    ),
                    action: "Nothing to fix. Many routers rate-limit pings addressed to "
                        + "themselves, and the internet path was unaffected throughout. If "
                        + "you want the first hop measured reliably, point Router host at a "
                        + "device that answers consistently.",
                    sessionIDs: affected.map(\.id)
                )
            }

            // Weak signal alongside the loss: a local problem worth acting on.
            guard onWiFi, weak else { return nil }
            let radio = radios.compactMap(\.description).first
            return Finding(
                rule: .routerLossWeakSignal,
                severity: .warning,
                side: .localLink,
                headline: "Losing packets to your own router",
                evidence: Finding.Evidence(
                    measurement: measurement,
                    threshold: String(format: "(signal was at or below %d dBm for %.0f%% of it)",
                                      RadioSummary.weakRSSI,
                                      (radios.map(\.weakFraction).max() ?? 0) * 100),
                    scope: scope + (radio.map { ", on \($0)" } ?? "")
                ),
                action: "This is between the Mac and the access point, not on the internet "
                    + "side. Move closer, or move the access point — 5 GHz loses rate "
                    + "quickly past \(RadioSummary.weakRSSI) dBm.",
                sessionIDs: affected.map(\.id)
            )
        }
    }
}

/// Jitter above the verdict's own threshold, correlated with a weak signal.
public struct JitterWeakSignalRule: FindingRule {
    public static let rule = Finding.Rule.jitterWeakSignal

    public static let minimumSessions = 1
    public static let minimumPairs = 600

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        analysis.byTarget.compactMap { group in
            let affected = group.sessions.filter {
                guard let jitter = $0.aggregate.internet.measuredJitter else { return false }
                return jitter > SessionVerdict.jitterThresholdMs
                    && $0.aggregate.internet.jitterPairs >= Self.minimumPairs
                    && $0.radio.isWiFi
                    && $0.radio.weakFraction >= 0.10
            }
            guard affected.count >= Self.minimumSessions else { return nil }

            let jitter = affected.compactMap { $0.aggregate.internet.measuredJitter }
            let mean = jitter.reduce(0, +) / Double(jitter.count)
            let radio = affected.map(\.radio).compactMap(\.description).first

            return Finding(
                rule: Self.rule,
                severity: .notice,
                side: .localLink,
                headline: "Unstable latency while the signal was weak",
                evidence: Finding.Evidence(
                    measurement: String(format: "jitter averaged %.0f ms between consecutive "
                                        + "replies", mean),
                    threshold: String(format: "(unstable from %.0f ms)",
                                      SessionVerdict.jitterThresholdMs),
                    scope: "\(affected.count) session\(affected.count == 1 ? "" : "s")"
                        + (radio.map { ", on \($0)" } ?? "")
                ),
                action: "Move the Mac or the access point. Signal that low makes the radio "
                    + "change rate, and rate changes show up as jitter.",
                sessionIDs: affected.map(\.id)
            )
        }
    }
}

/// Sessions that scored below the line when no pattern rule accounts for them.
///
/// Every other rule demands evidence across tests, sessions or days before it
/// says anything, and is right to. But that leaves a hole: two sessions on
/// 9 Sep scored 0 and 6 on severe bufferbloat, one of three tests could not
/// make a majority, and the screen said only that some sessions had stopped
/// measuring. A score of 0 in the table with nothing above it explaining it is
/// the screen disagreeing with itself.
///
/// This rule does not diagnose. It points at the sessions and says the range
/// is not enough to call it a pattern, which is what the other rules' guards
/// already concluded.
public struct BadSessionsRule: FindingRule {
    public static let rule = Finding.Rule.badSessions

    /// The rules whose findings explain a low component. A session one of them
    /// already cites for the same component is not reported again.
    static let explanations: [(rule: any FindingRule, kinds: Set<ScoreComponentKind>)] = [
        (LinkDroppedRule(), [.loss]),
        (RouterLossRule(), [.loss]),
        (UpstreamLossRule(), [.loss]),
        (BufferbloatRule(), [.bufferbloat]),
        (JitterWeakSignalRule(), [.jitter]),
        (TimeOfDayRule(), [.latency]),
    ]

    /// How many sessions the evidence names before it stops listing.
    public static let listed = 2

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        var explained: [UUID: Set<ScoreComponentKind>] = [:]
        for (rule, kinds) in Self.explanations {
            for finding in rule.evaluate(analysis) {
                for id in finding.sessionIDs { explained[id, default: []].formUnion(kinds) }
            }
        }

        return analysis.byTarget.compactMap { group in
            let scored = group.sessions.filter { $0.score.score != nil }
            let bad = scored
                .compactMap { session -> (SessionAnalysis, NetworkScore, ScoreComponent)? in
                    guard let score = session.score.score, let constraint = score.constraint,
                          !(explained[session.id]?.contains(constraint.kind) ?? false)
                    else { return nil }
                    return (session, score, constraint)
                }
                .sorted { $0.1.value < $1.1.value }
            guard !bad.isEmpty else { return nil }

            let named = bad.prefix(Self.listed).map { session, score, constraint in
                session.session.startedAt.formatted(
                    .dateTime.day().month(.abbreviated).hour().minute()
                ) + " scored \(score.value), limited by \(constraint.kind.rawValue) "
                    + "(\(constraint.label))"
            }
            let rest = bad.count - named.count
            // A third of the range is where "a bad evening" stops being an
            // honest description, even if no rule recognises the shape.
            let isFew = bad.count * 3 <= scored.count
            let onlyBloat = bad.allSatisfy { $0.2.kind == .bufferbloat }

            return Finding(
                rule: Self.rule,
                severity: .notice,
                side: onlyBloat ? .router : .indeterminate,
                headline: bad.count == 1 ? "One session went badly"
                    : "\(bad.count) sessions went badly",
                evidence: Finding.Evidence(
                    measurement: named.joined(separator: "; ")
                        + (rest > 0 ? "; and \(rest) more" : ""),
                    threshold: "(a problem below \(Scoring.problemScore))",
                    scope: "\(bad.count) of \(scored.count) scored sessions to "
                        + group.key.internetHost
                ),
                action: isFew
                    ? "Too few to call a pattern, so there is no advice yet. Open "
                        + (bad.count == 1 ? "it" : "them")
                        + " to see what happened then; if it keeps happening, a finding "
                        + "with a cause will take over from this one."
                    : "Enough of the range to matter, but not a shape any rule here "
                        + "recognises. Open them and look for what they share — time of "
                        + "day, a speed test, a place.",
                sessionIDs: bad.map(\.0.id)
            )
        }
    }
}

/// The Mac stopped measuring part of what a session claims.
public struct InsufficientCoverageRule: FindingRule {
    public static let rule = Finding.Rule.insufficientCoverage

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        let affected = analysis.underCovered
        guard !affected.isEmpty else { return [] }

        let worst = affected.min { $0.coverage < $1.coverage }
        return [Finding(
            rule: Self.rule,
            severity: .notice,
            side: .indeterminate,
            headline: "Some sessions stopped measuring",
            evidence: Finding.Evidence(
                // Formatted here rather than through `Fmt`, which lives in the
                // app target — Core stays free of it, as it stays free of
                // SwiftUI.
                measurement: worst.map { session in
                    let hours = Int(session.session.duration) / 3600
                    let minutes = (Int(session.session.duration) % 3600) / 60
                    let claimed = hours > 0 ? "\(hours) h \(minutes) m" : "\(minutes) m"
                    return String(format: "one log claims %@ and measured %.0f%% of it",
                                  claimed, session.coverage * 100)
                } ?? "coverage fell below the floor",
                threshold: String(format: "(a session is scored from %.0f%% coverage)",
                                  Scoring.coverageFloor * 100),
                scope: "\(affected.count) session\(affected.count == 1 ? "" : "s") in range"
            ),
            action: "Their scores and rates are withheld rather than guessed. Netlogs holds "
                + "off idle sleep while recording, but a closed lid or a forced sleep still "
                + "stops it.",
            sessionIDs: affected.map(\.id)
        )]
    }
}

/// Nothing wrong — said out loud, because an empty findings list is ambiguous
/// between "nothing wrong" and "nothing computed", which is the same defect
/// family as schema 2's `NOT NULL DEFAULT 0`.
public struct HealthyRule: FindingRule {
    public static let rule = Finding.Rule.healthy

    public static let minimumSessions = 2
    public static let minimumSpan: TimeInterval = 2 * 3600

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        // Only when everything else stayed quiet: this rule reports the absence
        // of the others, so it must not run beside them.
        let others = Diagnosis.rules
            .filter { type(of: $0).rule != Self.rule }
            .flatMap { $0.evaluate(analysis) }
        guard others.isEmpty else { return [] }

        let scored = analysis.qualifying.filter { $0.score.score != nil }
        guard scored.count >= Self.minimumSessions,
              scored.reduce(0, { $0 + $1.aggregate.measuredSpan }) >= Self.minimumSpan,
              scored.allSatisfy({ ($0.score.score?.value ?? 0) >= Scoring.problemScore })
        else { return [] }

        let samples = scored.reduce(0) { $0 + $1.aggregate.totalSamples }
        let loss = scored.reduce(0.0) { $0 + $1.internetLossRatio } / Double(scored.count)
        let latencies = scored.map(\.latency.p50).sorted()

        return [Finding(
            rule: Self.rule,
            severity: .info,
            side: .indeterminate,
            headline: "Nothing wrong across these sessions",
            evidence: Finding.Evidence(
                measurement: String(
                    format: "loss stayed at %.2f%%, latency around %.0f ms typical",
                    loss * 100, latencies[latencies.count / 2]
                ),
                threshold: "(every scored session came out at \(Scoring.problemScore) or above)",
                scope: "\(scored.count) sessions, \(samples.formatted()) samples"
            ),
            action: nil,
            sessionIDs: scored.map(\.id)
        )]
    }
}

/// Latency that is reliably worse at particular hours — congestion, and the one
/// finding that only a range can produce.
///
/// The most false-positive-prone rule in the catalogue, so it carries the most
/// guards. It needs the hour to be worse by a *ratio and* an absolute margin,
/// on several different days, with the router unaffected in the same hours —
/// and it only ever sees idle samples, because the app's own nightly speed test
/// would otherwise manufacture the very pattern it claims to find.
public struct TimeOfDayRule: FindingRule {
    public static let rule = Finding.Rule.timeOfDayLatency

    public static let ratio = 1.5
    public static let absoluteMs = 20.0

    public init() {}

    public func evaluate(_ analysis: RangeAnalysis) -> [Finding] {
        analysis.byTarget.compactMap { group in
            let profile = group.hourProfile
            guard let baseline = profile.overallMedian, baseline > 0 else { return nil }

            let worst = profile.qualifying
                .compactMap { hour -> (HourProfile, Double)? in
                    guard let median = hour.median else { return nil }
                    return (hour, median)
                }
                .filter { $0.1 >= baseline * Self.ratio && $0.1 - baseline >= Self.absoluteMs }
                .max { $0.1 < $1.1 }
            guard let (hour, median) = worst else { return nil }

            // If the router was slow in the same hours, the problem is inside
            // the house and this rule would be pointing at the wrong side of
            // it. Only skipped when the router has no readings to compare.
            let routerProfile = group.routerHourProfile
            if let routerBaseline = routerProfile.overallMedian, routerBaseline > 0,
               let routerHour = routerProfile.hours.first(where: { $0.hour == hour.hour })?.median,
               routerHour >= routerBaseline * Self.ratio {
                return nil
            }

            return Finding(
                rule: Self.rule,
                severity: .notice,
                side: .internetPath,
                headline: "Slower at particular hours",
                evidence: Finding.Evidence(
                    measurement: String(
                        format: "between %02d:00 and %02d:00, latency to %@ ran at %.0f ms "
                            + "against %.0f ms for the rest of the range (%.1f×)",
                        hour.hour, (hour.hour + 1) % 24, group.key.internetHost,
                        median, baseline, median / baseline
                    ),
                    threshold: String(format: "(reported from %.1f× and %.0f ms)",
                                      Self.ratio, Self.absoluteMs),
                    scope: "\(hour.days) days, \(hour.samples.formatted()) samples in that hour"
                ),
                action: "This looks like congestion beyond your router. Move large transfers "
                    + "outside those hours; if it persists, the times above are what an ISP "
                    + "ticket needs.",
                sessionIDs: group.sessions.map(\.id)
            )
        }
    }
}
