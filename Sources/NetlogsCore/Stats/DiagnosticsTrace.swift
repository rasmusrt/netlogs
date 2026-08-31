import Foundation

/// The Network sheet's history, reduced to the two things it actually carries.
///
/// `diagnostics_snapshots` stores a snapshot on change **plus** a 60 s
/// heartbeat, so a long session is almost all heartbeat: 669 rows of
/// `-43 dBm · ch 44`, every one looking identical. Rendered as a list, the only
/// things in there worth seeing — a signal drop, a channel change, a band
/// switch — are invisible.
///
/// So: a time series of RSSI, and the few moments where the *connection itself*
/// changed. `DiagnosticsSnapshot.stableSignature` already draws that second
/// line, and it is the same rule `DiagnosticsChangeDetector` stores on, so the
/// list of changes here cannot disagree with the reason a row was written.
///
/// Pure and deterministic: snapshots in, marks out. Built from stored snapshots
/// on both paths — the live model keeps the ones it wrote, a saved session
/// reads them back — so the same session draws the same trace either way.
public struct DiagnosticsTrace: Sendable, Equatable {

    /// One drawn reading. `segment` breaks the line rather than drawing through
    /// a discontinuity — the same trick `PingChartSeries` uses across an outage.
    public struct Point: Sendable, Equatable, Identifiable {
        public let id: Int
        public let time: Date
        public let rssi: Double
        public let segment: Int
    }

    public struct FieldChange: Sendable, Equatable {
        public let label: String
        public let before: String
        public let after: String

        public var summary: String { "\(label) \(before) → \(after)" }
    }

    /// One moment where the connection stopped being the same connection.
    public struct Change: Sendable, Equatable, Identifiable {
        public let id: Int
        public let time: Date
        public let fields: [FieldChange]

        /// Whether this change can move the signal, and so is worth a mark on
        /// the trace. A new gateway or MTU is worth listing but explains
        /// nothing about RSSI; a channel, band or access-point change does.
        public var affectsRadio: Bool {
            fields.contains { DiagnosticsTrace.radioLabels.contains($0.label) }
        }

        public var summary: String {
            fields.map(\.summary).joined(separator: " · ")
        }
    }

    public var points: [Point] = []
    public var changes: [Change] = []
    /// Over **every** stored reading, not the drawn ones — the figures under
    /// the chart describe the session, not the decimation.
    public var stats = RunningStats()
    /// True when more readings were stored than drawn; see ``decimate``.
    public var isDecimated = false
    /// Stored snapshots the trace was built from — including the ones carrying
    /// no RSSI, which is every one of them on Ethernet.
    public var snapshotCount = 0

    public init() {}

    public var readingCount: Int { stats.count }
    /// Two points is the least that can be a line rather than a dot.
    public var hasTrace: Bool { points.count >= 2 }
    public var radioChanges: [Change] { changes.filter(\.affectsRadio) }

    /// Below this, a Wi-Fi link is in trouble — the same threshold
    /// `NetworkCard.rssiTint` calls `bad`. Drawn as a reference line so a drop
    /// is read against something rather than against the axis.
    public static let weakRSSI: Double = -70

    // MARK: - Scales

    /// Pinned, never inferred — an inferred domain re-lays out every axis label
    /// on each publish (`PingChart`), and here it would also lie: the common
    /// case is a signal that never moves, and fitting the axis to a 2 dB wobble
    /// magnifies it into a cliff. `minimumSpan` is what stops that.
    public var yDomain: ClosedRange<Double> {
        guard stats.count > 0 else { return -90 ... -30 }
        let low = Swift.max(stats.min, -100)
        let high = Swift.min(stats.max, -10)
        let mid = (low + high) / 2
        let span = Swift.max(high - low + 6, Self.minimumSpan)
        let lo = ((mid - span / 2) / 5).rounded(.down) * 5
        let hi = ((mid + span / 2) / 5).rounded(.up) * 5
        let flooredLo = Swift.max(lo, -100)
        return flooredLo ... Swift.max(Swift.min(hi, -10), flooredLo + 5)
    }

    /// Padded past the first and last reading on purpose. Charts centres an
    /// axis label on its tick and clips at the plot edge, so a domain ending
    /// exactly on the last reading printed the closing label as "1" — half a
    /// timestamp. The pad keeps the trace off the frame; the room for the
    /// label comes from placing the ticks (``xTicks``) rather than letting
    /// Charts snap them to round times, which can land one two seconds from
    /// the domain edge however wide the pad is.
    public var xDomain: ClosedRange<Date> {
        guard let first = points.first?.time, let last = points.last?.time else {
            let now = Date()
            return now.addingTimeInterval(-60) ... now
        }
        guard last > first else {
            return first.addingTimeInterval(-30) ... first.addingTimeInterval(30)
        }
        let pad = Swift.max(last.timeIntervalSince(first) * 0.03, 10)
        return first.addingTimeInterval(-pad) ... last.addingTimeInterval(pad)
    }

    /// dBm. Twenty is wide enough that a real drop still reads as a drop.
    public static let minimumSpan: Double = 20

    /// Wall-clock time covered by the drawn points.
    public var span: TimeInterval {
        guard let first = points.first?.time, let last = points.last?.time else { return 0 }
        return last.timeIntervalSince(first)
    }

    /// Round tick times inside the data range, with a margin at each end.
    ///
    /// Two constraints, and Charts' automatic values satisfy only the first.
    /// Ticks should be round — 14:45, not 14:39 — because an axis of arbitrary
    /// times orients nobody. And no tick may sit near the domain edge, where
    /// Charts elides its label (`15:…`, or a bare `1`). Automatic values snap
    /// to round times wherever they fall, edge included; midpoint spacing
    /// guaranteed the room and gave up the round numbers. Choosing the interval
    /// and then dropping what lands in the margin keeps both.
    ///
    /// Exact readings are the hover readout's job, so this axis only has to
    /// orient — three or four ticks is plenty.
    public func xTicks(
        targetCount: Int = 4,
        edgeMargin: Double = 0.08,
        calendar: Calendar = .current
    ) -> [Date] {
        guard targetCount > 0, let first = points.first?.time,
              let last = points.last?.time, span > 0 else { return [] }

        let ideal = span / Double(targetCount)
        let interval = Self.tickIntervals
            .min { abs($0 - ideal) < abs($1 - ideal) } ?? ideal
        let lower = first.addingTimeInterval(span * edgeMargin)
        let upper = last.addingTimeInterval(-span * edgeMargin)
        guard upper > lower else { return [] }

        // Round *to the wall clock*, not to the session's start: 15:00 is a
        // round time, 15:00 plus however long the session had been running is
        // not.
        let origin = calendar.startOfDay(for: first)
        var ticks: [Date] = []
        var step = (lower.timeIntervalSince(origin) / interval).rounded(.up)
        while ticks.count < 64 {
            let tick = origin.addingTimeInterval(step * interval)
            if tick > upper { break }
            ticks.append(tick)
            step += 1
        }
        // A span short enough to hold no round tick at all still deserves one
        // time on the axis.
        return ticks.isEmpty ? [first.addingTimeInterval(span / 2)] : ticks
    }

    /// Seconds, minutes, quarters, hours, quarter-days. Anything coarser is a
    /// day, by which point a session has other problems.
    static let tickIntervals: [TimeInterval] = [
        5, 10, 15, 30, 60, 120, 300, 600, 900, 1800,
        3600, 7200, 10800, 21600, 43200, 86400,
    ]

    /// The reading nearest a point in time — what the hover readout shows.
    ///
    /// Binary search rather than a scan: hover fires continuously, and this
    /// runs per event over as many as 600 points.
    public func nearest(to time: Date) -> Point? {
        guard !points.isEmpty else { return nil }
        var low = 0, high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].time < time { low = mid + 1 } else { high = mid }
        }
        let candidate = points[low]
        guard low > 0 else { return candidate }
        let previous = points[low - 1]
        return abs(previous.time.timeIntervalSince(time))
            <= abs(candidate.time.timeIntervalSince(time)) ? previous : candidate
    }

    // MARK: - Build

    /// - Parameters:
    ///   - snapshots: stored snapshots, oldest first — the order both
    ///     `SessionStore.diagnostics(for:)` and the live model produce.
    ///   - maxPoints: drawn-point cap. Snapshots land at most one a minute in
    ///     the quiet case, but a flapping connection stores one per *poll*, so
    ///     the count is not bounded by the heartbeat.
    ///   - gapBreak: a hole longer than this (a sleep, a stopped session)
    ///     breaks the line instead of being drawn through.
    public static func build(
        _ snapshots: [DiagnosticsSnapshot],
        maxPoints: Int = 600,
        gapBreak: TimeInterval = 300
    ) -> DiagnosticsTrace {
        var trace = DiagnosticsTrace()
        guard !snapshots.isEmpty else { return trace }
        trace.snapshotCount = snapshots.count

        for index in snapshots.indices.dropFirst() {
            let previous = snapshots[index - 1], current = snapshots[index]
            guard current.stableSignature != previous.stableSignature else { continue }
            let fields = zip(labelled(previous), labelled(current))
                .compactMap { before, after -> FieldChange? in
                    guard before.value != after.value else { return nil }
                    return FieldChange(label: after.label,
                                       before: before.value ?? "—",
                                       after: after.value ?? "—")
                }
            // `labelled` covers every field `stableSignature` hashes, so a
            // changed signature always has something to say. The guard is for
            // the day one list grows and the other doesn't — an unexplained
            // row is worse than a missing one.
            guard !fields.isEmpty else { continue }
            trace.changes.append(
                Change(id: trace.changes.count, time: current.timestamp, fields: fields)
            )
        }

        let readings: [(time: Date, rssi: Double)] = snapshots.compactMap { snapshot in
            snapshot.rssi.map { (snapshot.timestamp, Double($0)) }
        }
        for reading in readings { trace.stats.add(reading.rssi) }

        // Breaks are found in the full series and applied to the drawn one, so
        // decimation can't invent a gap by widening the spacing.
        var breaks = trace.radioChanges.map(\.time)
        for index in readings.indices.dropFirst()
        where readings[index].time.timeIntervalSince(readings[index - 1].time) > gapBreak {
            breaks.append(readings[index].time)
        }
        breaks.sort()

        let drawn = decimate(readings, to: maxPoints)
        trace.isDecimated = drawn.count < readings.count

        var segment = 0, nextBreak = 0
        for reading in drawn {
            while nextBreak < breaks.count, breaks[nextBreak] <= reading.time {
                nextBreak += 1
                segment += 1
            }
            trace.points.append(
                Point(id: trace.points.count, time: reading.time,
                      rssi: reading.rssi, segment: segment)
            )
        }
        return trace
    }

    /// Keeps the **worst** reading in each bucket, not the first or the mean.
    ///
    /// The question this chart answers is "when did the signal fall off", and
    /// an average over a bucket is exactly what hides a thirty-second dip. A
    /// decimated trace therefore reads slightly low by construction, which is
    /// the safe direction and is why the figures under it come from the full
    /// series instead.
    static func decimate(
        _ readings: [(time: Date, rssi: Double)], to maxPoints: Int
    ) -> [(time: Date, rssi: Double)] {
        guard maxPoints > 0, readings.count > maxPoints else { return readings }
        var out: [(time: Date, rssi: Double)] = []
        out.reserveCapacity(maxPoints)
        for bucket in 0..<maxPoints {
            let lower = bucket * readings.count / maxPoints
            let upper = (bucket + 1) * readings.count / maxPoints
            guard lower < upper else { continue }
            var worst = readings[lower]
            for index in (lower + 1)..<upper where readings[index].rssi < worst.rssi {
                worst = readings[index]
            }
            out.append(worst)
        }
        return out
    }

    // MARK: - Fields

    /// The fields `stableSignature` is built from, in the words the sheet uses.
    ///
    /// `ssid`/`bssid` are here even though they are permanently nil on macOS 26
    /// (PHASE4-NOTES) and the Interface block doesn't render them: the
    /// signature hashes them, so leaving them out would let a change appear
    /// with no description.
    static func labelled(_ s: DiagnosticsSnapshot) -> [(label: String, value: String?)] {
        [
            (label: "Interface", value: s.interfaceName),
            (label: "Type", value: s.kind.rawValue),
            (label: "Channel", value: s.channel.map(String.init)),
            (label: "Band", value: s.band),
            (label: "Protocol", value: s.phyMode),
            (label: "Security", value: s.security),
            (label: "Network", value: s.ssid),
            (label: "AP", value: s.bssid),
            (label: "Link", value: s.linkSpeedMbps.map { "\($0) Mbps" }),
            (label: "Duplex", value: s.duplex),
            (label: "IP", value: s.ipAddress),
            (label: "Subnet", value: s.subnetMask),
            (label: "Gateway", value: s.gateway),
            (label: "DNS", value: s.dnsServers.isEmpty
                ? nil : s.dnsServers.sorted().joined(separator: ", ")),
            (label: "MTU", value: s.mtu.map(String.init)),
        ]
    }

    static let radioLabels: Set<String> = ["Interface", "Type", "Channel", "Band",
                                           "Protocol", "Network", "AP"]
}
