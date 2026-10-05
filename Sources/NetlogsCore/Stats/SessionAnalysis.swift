import Foundation

/// One session, reduced to everything the Analysis screen judges by.
///
/// Assembled from the SQL aggregate, the SQL histogram and the stored
/// throughput results — never from `[PingSample]`, which is 38,000 structs for
/// one overnight session.
public struct SessionAnalysis: Sendable, Equatable, Identifiable {
    public let session: SessionState
    public let aggregate: PingAggregate
    public let latency: LatencyHistogram
    public let throughput: [ThroughputResult]
    public let radio: RadioSummary

    public var id: UUID { session.id }

    public init(
        session: SessionState,
        aggregate: PingAggregate,
        latency: LatencyHistogram = LatencyHistogram(),
        throughput: [ThroughputResult] = [],
        radio: RadioSummary = .empty
    ) {
        self.session = session
        self.aggregate = aggregate
        self.latency = latency
        self.throughput = throughput
        self.radio = radio
    }

    // MARK: - What was measured, against what was claimed

    /// Samples the session would have recorded if it never stopped measuring.
    ///
    /// The claim comes from `SessionState.duration`, whose fallback is the last
    /// sample rather than *now* — six of twenty sessions in a real database were
    /// never stopped cleanly, and measuring those against the clock would
    /// withhold every one of them.
    public var expectedSamples: Int {
        let interval = session.settings.pingInterval.timeInterval
        guard interval > 0 else { return aggregate.totalSamples }
        let claimed = Swift.max(session.duration, aggregate.measuredSpan)
        return Swift.max(1, Int((claimed / interval).rounded()))
    }

    /// Stored samples over expected. Below 1 the Mac stopped measuring — a
    /// closed lid, a forced sleep — and the session describes a
    /// differently-shaped day than the one it claims.
    public var coverage: Double {
        Swift.min(1, Double(aggregate.totalSamples) / Double(expectedSamples))
    }

    // MARK: - The figures the rules read

    /// Lost internet packets over samples.
    ///
    /// `internetNoRepliesIdle`, not `internetTimeouts` — the same correction
    /// `SessionVerdict` makes, and it has to be made here too or the Analysis
    /// screen and the session header grade the same night differently. Replies
    /// that arrived after the deadline are not loss, and timeouts caused by the
    /// app's own throughput test are loss the app caused.
    public var internetLossRatio: Double {
        aggregate.totalSamples > 0
            ? Double(aggregate.internetNoRepliesIdle) / Double(aggregate.totalSamples) : 0
    }

    public var routerLossRatio: Double {
        aggregate.totalSamples > 0
            ? Double(aggregate.routerTimeouts - aggregate.router.late.count)
                / Double(aggregate.totalSamples)
            : 0
    }

    /// Ticks where *only* the router was silent — the internet answered. This
    /// is the LAN-versus-upstream distinction, in one number.
    public var routerOnlyTimeouts: Int {
        Swift.max(0, aggregate.routerTimeouts - aggregate.bothTimeouts)
    }

    public var internetOnlyTimeouts: Int {
        Swift.max(0, aggregate.internetTimeouts - aggregate.bothTimeouts)
    }

    /// Median rather than mean. `ThroughputAverages` stays a mean and is right
    /// for the card; a rule that fires advice must not swing on one outlier.
    public var medianBufferbloatMs: Double? {
        let measured = throughput.compactMap(\.bufferbloatMs).sorted()
        guard !measured.isEmpty else { return nil }
        let middle = measured.count / 2
        return measured.count.isMultiple(of: 2)
            ? (measured[middle - 1] + measured[middle]) / 2
            : measured[middle]
    }

    // MARK: - Score

    /// `.withheld` rather than a guess, on the same discipline as
    /// `SessionVerdict.insufficientData`.
    public var score: ScoreResult {
        guard aggregate.totalSamples >= SessionVerdict.minimumSamples else {
            return .withheld(.tooFewSamples(aggregate.totalSamples))
        }
        guard coverage >= Scoring.coverageFloor else {
            return .withheld(.poorCoverage(measured: aggregate.totalSamples,
                                           expected: expectedSamples))
        }

        var components: [ScoreComponent] = [
            ScoreComponent(kind: .loss,
                           value: Scoring.loss(ratio: internetLossRatio,
                                               failures: aggregate.internetNoRepliesIdle),
                           measurement: internetLossRatio)
        ]
        if latency.count > 0 {
            components.append(ScoreComponent(kind: .latency,
                                             value: Scoring.latency(p50Ms: latency.p50),
                                             measurement: latency.p50))
        }
        // Jitter needs pairs, not samples: "no pair yet" and "the replies
        // agreed" are different facts, and only the second is a measurement.
        if let jitter = aggregate.internet.measuredJitter, aggregate.internet.jitterPairs >= 30 {
            components.append(ScoreComponent(kind: .jitter,
                                             value: Scoring.jitter(ms: jitter),
                                             measurement: jitter))
        }
        if let bloat = medianBufferbloatMs {
            components.append(ScoreComponent(kind: .bufferbloat,
                                             value: Scoring.bufferbloat(ms: bloat),
                                             measurement: bloat))
        }

        guard components.count >= Scoring.minimumComponents else {
            return .withheld(.tooFewComponents(components.count))
        }
        return .scored(NetworkScore(components: components))
    }
}

/// A range of sessions, grouped so nothing can be pooled by accident.
///
/// There is no accessor returning "the range's latency" or "the range's score".
/// The database mixes `1.1.1.1` and `8.8.8.8` across three gateways, and a
/// figure averaging those describes no connection that exists — so the only way
/// to read figures is through a group, and a group is a target.
public struct RangeAnalysis: Sendable, Equatable {
    public let interval: DateInterval
    public let sessions: [SessionAnalysis]
    /// Day-and-hour latency buckets for the whole range, folded per target by
    /// ``TargetGroup/hourProfile``. Empty when nothing asked for them.
    public let hourlyBuckets: [HourlyBucket]
    /// The same, for the router — so a time-of-day claim can check whether the
    /// first hop was slow in those hours too, which would make it a local
    /// problem rather than an upstream one.
    public let routerHourlyBuckets: [HourlyBucket]

    public init(interval: DateInterval, sessions: [SessionAnalysis],
                hourlyBuckets: [HourlyBucket] = [],
                routerHourlyBuckets: [HourlyBucket] = []) {
        self.interval = interval
        self.sessions = sessions.sorted { $0.session.startedAt > $1.session.startedAt }
        self.hourlyBuckets = hourlyBuckets
        self.routerHourlyBuckets = routerHourlyBuckets
    }

    /// Sessions worth judging: enough samples, and enough of the claim actually
    /// measured. Everything except the coverage rule itself reads this.
    public var qualifying: [SessionAnalysis] {
        sessions.filter {
            $0.aggregate.totalSamples >= SessionVerdict.minimumSamples
                && $0.coverage >= Scoring.coverageFloor
        }
    }

    public var underCovered: [SessionAnalysis] {
        sessions.filter {
            $0.aggregate.totalSamples >= SessionVerdict.minimumSamples
                && $0.coverage < Scoring.coverageFloor
        }
    }

    /// Qualifying sessions grouped by internet host, then by gateway — the two
    /// axes along which a figure changes what it describes.
    public var byTarget: [TargetGroup] {
        let groups = Dictionary(grouping: qualifying) {
            TargetKey(internetHost: $0.session.settings.internetHost,
                      routerHost: $0.session.settings.routerHost)
        }
        return groups
            .map { TargetGroup(key: $0.key, sessions: $0.value,
                               hourlyBuckets: hourlyBuckets,
                               routerHourlyBuckets: routerHourlyBuckets) }
            .sorted { $0.sessions.count > $1.sessions.count }
    }

    /// More than one target in range means every figure below has to say which
    /// one it describes.
    public var hasMixedTargets: Bool { byTarget.count > 1 }

    public var totalSamples: Int { sessions.reduce(0) { $0 + $1.aggregate.totalSamples } }
    public var measuredSpan: TimeInterval {
        sessions.reduce(0) { $0 + $1.aggregate.measuredSpan }
    }
}

public struct TargetKey: Sendable, Equatable, Hashable {
    public let internetHost: String
    public let routerHost: String

    public init(internetHost: String, routerHost: String) {
        self.internetHost = internetHost
        self.routerHost = routerHost
    }
}

public struct TargetGroup: Sendable, Equatable, Identifiable {
    public let key: TargetKey
    public let sessions: [SessionAnalysis]
    let hourlyBuckets: [HourlyBucket]
    let routerHourlyBuckets: [HourlyBucket]

    public var id: TargetKey { key }

    public init(key: TargetKey, sessions: [SessionAnalysis],
                hourlyBuckets: [HourlyBucket] = [],
                routerHourlyBuckets: [HourlyBucket] = []) {
        self.key = key
        self.sessions = sessions
        self.hourlyBuckets = hourlyBuckets
        self.routerHourlyBuckets = routerHourlyBuckets
    }

    /// This target's hours only — never pooled with another host's.
    public var hourProfile: HourOfDayProfile {
        HourOfDayProfile.build(hourlyBuckets, sessionIDs: Set(sessions.map(\.id)))
    }

    /// The same hours measured against the router, for the check that keeps a
    /// congestion claim honest.
    public var routerHourProfile: HourOfDayProfile {
        HourOfDayProfile.build(routerHourlyBuckets, sessionIDs: Set(sessions.map(\.id)))
    }

    public var scores: [NetworkScore] { sessions.compactMap { $0.score.score } }

    /// The median score with its count — never a blend, and never presented
    /// without saying how many sessions it is the median of.
    public var medianScore: Int? {
        let values = scores.map(\.value).sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    /// Which component limited how many sessions — the actionable headline, and
    /// the bridge from the score to the findings.
    ///
    /// Counts `constraint`, not `limiting`: a session where nothing crossed the
    /// problem line contributes to no tally, because "jitter limited 4 of 9"
    /// would otherwise be said about four healthy sessions.
    public var constraintTally: [(kind: ScoreComponentKind, count: Int)] {
        let kinds = scores.compactMap { $0.constraint?.kind }
        return Dictionary(grouping: kinds, by: { $0 })
            .map { (kind: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    public var totalSamples: Int { sessions.reduce(0) { $0 + $1.aggregate.totalSamples } }
    public var measuredSpan: TimeInterval {
        sessions.reduce(0) { $0 + $1.aggregate.measuredSpan }
    }

    /// Distinct calendar days the sessions touch — the evidence bar several
    /// rules require before they will say anything.
    public func distinctDays(_ calendar: Calendar = .current) -> Int {
        Set(sessions.map { calendar.startOfDay(for: $0.session.startedAt) }).count
    }
}

/// How far back the Analysis screen looks.
///
/// Four presets rather than a free date picker. Retention defaults to 30 days,
/// so these cover the whole database, and a custom range is a second control to
/// design for a case that does not exist yet.
///
/// There is deliberately no "all time": the reduction is linear in samples
/// scanned, and a month of continuous 1 Hz recording is roughly 2.6M of them.
/// Capping the range is the cheap half of that problem; a stored per-session
/// summary is the expensive half, and is not worth building until a real
/// database is slow.
public enum AnalysisRange: String, Sendable, Equatable, Codable, CaseIterable, Identifiable {
    case day, week, fortnight, month

    public var id: Self { self }

    public var days: Int {
        switch self {
        case .day:       return 1
        case .week:      return 7
        case .fortnight: return 14
        case .month:     return 30
        }
    }

    public var label: String {
        switch self {
        case .day:       return "24 hours"
        case .week:      return "7 days"
        case .fortnight: return "14 days"
        case .month:     return "30 days"
        }
    }

    public func interval(endingAt end: Date = Date()) -> DateInterval {
        DateInterval(start: end.addingTimeInterval(-Double(days) * 86_400), end: end)
    }
}
