import Foundation

/// One mark per session: when it ran, and the latency band it spent its time in.
///
/// `low`/`high` are p50→p95, not min→max. One 1,062 ms outlier against a 42 ms
/// average would make every bar a full-height smear set by a single sample —
/// the same "axis set by an artefact" problem the warm-up exclusion exists for.
/// The tail worth seeing is p95; the outliers live in the session's own screen.
public struct SpreadMark: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let start: Date
    /// The last sample. Kept exact — `drawnEnd` is what a chart should use.
    public let end: Date
    public let low: Double
    public let high: Double
    public let peak: Double
    public let coverage: Double
    public let isWithheld: Bool
    /// The component holding this session's score down, or `nil` when nothing
    /// does — what the mark is tinted by.
    public let constraint: ScoreComponentKind?

    /// At least `minimumWidth` wide, so a fifteen-minute session on a seven-day
    /// axis is not a zero-width rectangle that draws nothing. The same lesson
    /// as the one-sample outage band: `end` stays the measurement, and only the
    /// drawing is widened.
    public let drawnEnd: Date

    public init(
        id: UUID, start: Date, end: Date, low: Double, high: Double, peak: Double,
        coverage: Double, isWithheld: Bool, constraint: ScoreComponentKind?,
        minimumWidth: TimeInterval
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.low = low
        self.high = high
        self.peak = peak
        self.coverage = coverage
        self.isWithheld = isWithheld
        self.constraint = constraint
        self.drawnEnd = Swift.max(end, start.addingTimeInterval(minimumWidth))
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// The marks plus the scales they are drawn on.
///
/// There is deliberately **no line between marks**. Sessions do not tile time —
/// in a real database 46 h of measurement sits inside 11 days — so a line
/// across the gaps would assert measurements that were never made, which is the
/// defect Phase 9 opened by fixing.
public struct SessionSpread: Sendable, Equatable {
    public let marks: [SpreadMark]
    public let interval: DateInterval

    public init(marks: [SpreadMark], interval: DateInterval) {
        self.marks = marks
        self.interval = interval
    }

    public var isEmpty: Bool { marks.isEmpty }

    /// Covers the range *and* every mark, so a session that started before the
    /// range is drawn whole rather than clipped at the boundary.
    public var xDomain: ClosedRange<Date> {
        guard let first = marks.map(\.start).min(),
              let last = marks.map(\.drawnEnd).max() else {
            return interval.start ... interval.end
        }
        let low = Swift.min(first, interval.start)
        let high = Swift.max(last, interval.end)
        return low < high ? low ... high : low ... low.addingTimeInterval(60)
    }

    /// From zero, and never fitted tightly.
    ///
    /// A range where every session sat at 30 ms would otherwise be drawn to a
    /// 6 ms spread, magnifying nothing into a cliff — the problem
    /// `DiagnosticsTrace.yDomain` solves the same way. Latency also has a
    /// meaningful floor at 0, unlike RSSI, so the domain starts there rather
    /// than centring on the data.
    public var yDomain: ClosedRange<Double> {
        let top = marks.map(\.high).max() ?? 0
        let ceiling = Swift.max(top * 1.15, Self.minimumCeilingMs)
        return 0 ... (ceiling / 25).rounded(.up) * 25
    }

    public static let minimumCeilingMs: Double = 100

    public static func build(
        _ sessions: [SessionAnalysis], interval: DateInterval, minimumWidth: TimeInterval
    ) -> SessionSpread {
        let marks = sessions.compactMap { analysis -> SpreadMark? in
            guard let start = analysis.aggregate.firstSampleAt,
                  let end = analysis.aggregate.lastSampleAt,
                  analysis.latency.count > 0 else { return nil }
            let withheld = analysis.score.score == nil
            return SpreadMark(
                id: analysis.id, start: start, end: end,
                low: analysis.latency.p50, high: analysis.latency.p95,
                peak: analysis.latency.p99,
                coverage: analysis.coverage, isWithheld: withheld,
                constraint: analysis.score.score?.constraint?.kind,
                minimumWidth: minimumWidth
            )
        }
        return SessionSpread(marks: marks, interval: interval)
    }
}
