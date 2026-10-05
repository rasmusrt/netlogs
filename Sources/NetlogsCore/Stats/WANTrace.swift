import Foundation

/// The Gateway sheet's three series on one time axis: internet RTT, WAN
/// throughput, and the 5G radio's SINR (Phase 14, `docs/wan-telemetry-plan.md`).
///
/// It exists to answer one question the app could not: was that latency
/// episode the radio, or something uploading? Both look the same from a ping.
/// With the three series lined up, a queue that forms while upload sits at the
/// line's ceiling and SINR holds steady reads differently from one that forms
/// while SINR falls.
///
/// **Each series is drawn at the resolution it was measured at, and no finer.**
/// RTT is bucketed from 1 Hz samples. Throughput is a rate between two counter
/// readings about 5 s apart, so it is a step over that interval, not a point.
/// SINR is reported by the CPE about every 12 s, so it is a step held until the
/// next report — never a line between two reports, which would assert eleven
/// seconds of measurements nobody took (the Phase 9 defect).
///
/// Pure: samples and snapshots in, marks out. Built the same way for a live
/// session and a saved one, so both draw the same picture.
public struct WANTrace: Sendable, Equatable {

    public struct RTTPoint: Sendable, Equatable, Identifiable {
        public let id: Int
        public let time: Date
        /// Median of the bucket's replies, late ones included — a late reply is
        /// the most informative RTT an episode produces.
        public let median: Double
        public let max: Double
        public let segment: Int
    }

    /// A rate over the interval between two counter readings.
    public struct RatePoint: Sendable, Equatable, Identifiable {
        public let id: Int
        public let start: Date
        public let end: Date
        public let upMbps: Double
        public let downMbps: Double
        public let segment: Int
    }

    /// One CPE report, held until the next.
    public struct RadioPoint: Sendable, Equatable, Identifiable {
        public let id: Int
        public let time: Date
        public let sinr: Double
        public let segment: Int
    }

    /// A band or cell change: a step in the radio, and far easier to line up
    /// with a latency step than a noisy dB value is.
    public struct RadioChange: Sendable, Equatable, Identifiable {
        public let id: Int
        public let time: Date
        public let summary: String
    }

    /// A stretch with no gateway data, and why.
    public struct Gap: Sendable, Equatable, Identifiable {
        public let id: Int
        public let start: Date
        public let end: Date
        public let reason: String
    }

    /// The three values at one moment, for the shared hover readout.
    public struct Readout: Sendable, Equatable {
        public let time: Date
        public let rttMs: Double?
        public let upMbps: Double?
        public let downMbps: Double?
        public let sinr: Double?
    }

    public var rtt: [RTTPoint] = []
    public var rates: [RatePoint] = []
    public var radio: [RadioPoint] = []
    public var radioChanges: [RadioChange] = []
    public var gaps: [Gap] = []
    public var xDomain: ClosedRange<Date> = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 1)
    public var bucketSeconds: TimeInterval = 1
    /// Gateway polls the trace was built from, failures included.
    public var snapshotCount = 0

    public init() {}

    /// Whether there is anything from the gateway to draw. RTT alone is the
    /// Latency sheet's job.
    public var hasGatewayData: Bool { !rates.isEmpty || !radio.isEmpty }

    /// Drawn points per series, at most. RTT is bucketed to fit.
    public static let targetBuckets = 600
    static let bucketSizes: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
    /// A counter pair further apart than this is not one interval of traffic
    /// but a gap in the readings, and averaging across it would draw a flat
    /// rate over minutes nobody measured.
    public static let maxRateInterval: TimeInterval = 30
    /// Missing this many seconds of CPE reports breaks the SINR line. About
    /// five refresh intervals.
    public static let maxRadioInterval: TimeInterval = 60

    // MARK: - Build

    public static func build(
        snapshots: [WANSnapshot],
        samples: [PingSample],
        warmupSamplesToSkip: UInt32 = PingSample.warmupSampleCount
    ) -> WANTrace {
        var trace = WANTrace()
        let snapshots = snapshots.sorted { $0.timestamp < $1.timestamp }
        let samples = samples.filter { $0.id >= warmupSamplesToSkip }
        trace.snapshotCount = snapshots.count

        let times = [samples.first?.timestamp, samples.last?.timestamp,
                     snapshots.first?.timestamp, snapshots.last?.timestamp].compactMap { $0 }
        guard let start = times.min(), let end = times.max(), end > start else { return trace }
        trace.xDomain = start...end

        let span = end.timeIntervalSince(start)
        trace.bucketSeconds = bucketSizes.first { span / $0 <= Double(targetBuckets) }
            ?? bucketSizes.last!

        trace.rtt = buildRTT(samples, start: start, bucket: trace.bucketSeconds)
        trace.rates = buildRates(snapshots)
        (trace.radio, trace.radioChanges) = buildRadio(snapshots)
        trace.gaps = buildGaps(snapshots, end: end)
        return trace
    }

    static func buildRTT(_ samples: [PingSample], start: Date, bucket: TimeInterval) -> [RTTPoint] {
        var buckets: [Int: [Double]] = [:]
        for sample in samples {
            guard let rtt = sample.internetRttMs else { continue }
            let index = Int(sample.timestamp.timeIntervalSince(start) / bucket)
            buckets[index, default: []].append(rtt)
        }
        var points: [RTTPoint] = []
        var segment = 0
        var previous: Int?
        for index in buckets.keys.sorted() {
            let values = buckets[index]!.sorted()
            if let previous, index > previous + 1 { segment += 1 }
            previous = index
            points.append(RTTPoint(
                id: points.count,
                time: start.addingTimeInterval((Double(index) + 0.5) * bucket),
                median: values[values.count / 2],
                max: values.last!,
                segment: segment
            ))
        }
        return points
    }

    static func buildRates(_ snapshots: [WANSnapshot]) -> [RatePoint] {
        // Only readings where the counters moved. A row stored because the
        // radio changed repeats the last counters; pairing against it would
        // draw a zero and then a doubled rate.
        var readings: [(time: Date, counters: WANCounters)] = []
        for snapshot in snapshots {
            guard let c = snapshot.counters, c.rxBytes != nil, c.txBytes != nil else { continue }
            if let last = readings.last?.counters,
               last.rxBytes == c.rxBytes, last.txBytes == c.txBytes { continue }
            readings.append((snapshot.timestamp, c))
        }

        var points: [RatePoint] = []
        var segment = 0
        for (a, b) in zip(readings, readings.dropFirst()) {
            let dt = b.time.timeIntervalSince(a.time)
            guard dt > 0, dt <= maxRateInterval, a.counters.interface == b.counters.interface,
                  let rx0 = a.counters.rxBytes, let rx1 = b.counters.rxBytes,
                  let tx0 = a.counters.txBytes, let tx1 = b.counters.txBytes,
                  rx1 >= rx0, tx1 >= tx0   // a reset or a counter wrap, not traffic
            else {
                if !points.isEmpty { segment += 1 }
                continue
            }
            points.append(RatePoint(
                id: points.count, start: a.time, end: b.time,
                upMbps: Double(tx1 - tx0) * 8 / dt / 1_000_000,
                downMbps: Double(rx1 - rx0) * 8 / dt / 1_000_000,
                segment: segment
            ))
        }
        return points
    }

    static func buildRadio(_ snapshots: [WANSnapshot]) -> ([RadioPoint], [RadioChange]) {
        var points: [RadioPoint] = []
        var changes: [RadioChange] = []
        var segment = 0
        var lastReport: Date?
        var last: CellularRadio?

        for snapshot in snapshots {
            guard let radio = snapshot.radio else { continue }
            // Timestamped by the CPE's report, not the poll: six polls of one
            // report are one point.
            let time = radio.reportedAt ?? snapshot.timestamp
            if let lastReport, time <= lastReport { continue }

            if let lastReport, time.timeIntervalSince(lastReport) > maxRadioInterval { segment += 1 }
            if let last {
                var parts: [String] = []
                if last.band != radio.band, let from = last.band, let to = radio.band {
                    parts.append("band \(from) → \(to)")
                }
                if last.cellID != radio.cellID, last.cellID != nil, radio.cellID != nil {
                    parts.append("new cell")
                }
                if !parts.isEmpty {
                    changes.append(RadioChange(id: changes.count, time: time,
                                               summary: parts.joined(separator: ", ")))
                }
            }
            if let sinr = radio.nrSINR ?? radio.lteSINR {
                points.append(RadioPoint(id: points.count, time: time, sinr: sinr, segment: segment))
            }
            lastReport = time
            last = radio
        }
        return (points, changes)
    }

    static func buildGaps(_ snapshots: [WANSnapshot], end: Date) -> [Gap] {
        var gaps: [Gap] = []
        var open: (start: Date, reason: String)?
        for snapshot in snapshots {
            if let failure = snapshot.failure {
                if open == nil { open = (snapshot.timestamp, failure.description) }
            } else if let o = open {
                gaps.append(Gap(id: gaps.count, start: o.start, end: snapshot.timestamp, reason: o.reason))
                open = nil
            }
        }
        if let o = open { gaps.append(Gap(id: gaps.count, start: o.start, end: end, reason: o.reason)) }
        return gaps
    }

    // MARK: - Reading

    /// The three values at `time`, each from the series' own resolution: the
    /// RTT bucket containing it, the rate interval containing it, and the last
    /// SINR report at or before it.
    public func readout(at time: Date) -> Readout {
        let halfBucket = bucketSeconds / 2
        let rttPoint = rtt.first { abs($0.time.timeIntervalSince(time)) <= halfBucket }
        let rate = rates.first { $0.start <= time && time <= $0.end }
        let report = radio.last { $0.time <= time }
        let heldTooLong = report.map { time.timeIntervalSince($0.time) > Self.maxRadioInterval } ?? true
        return Readout(time: time, rttMs: rttPoint?.median, upMbps: rate?.upMbps,
                       downMbps: rate?.downMbps, sinr: heldTooLong ? nil : report?.sinr)
    }

    public var span: TimeInterval { xDomain.upperBound.timeIntervalSince(xDomain.lowerBound) }

    /// Wall-clock ticks across the domain, as ``DiagnosticsTrace/xTicks`` does.
    public func xTicks(targetCount: Int = 4, calendar: Calendar = .current) -> [Date] {
        guard span > 0 else { return [] }
        let ideal = span / Double(targetCount)
        let interval = DiagnosticsTrace.tickIntervals
            .min { abs($0 - ideal) < abs($1 - ideal) } ?? ideal
        let lower = xDomain.lowerBound.addingTimeInterval(span * 0.08)
        let upper = xDomain.upperBound.addingTimeInterval(-span * 0.08)
        guard upper > lower else { return [xDomain.lowerBound.addingTimeInterval(span / 2)] }
        let origin = calendar.startOfDay(for: xDomain.lowerBound)
        var ticks: [Date] = []
        var step = (lower.timeIntervalSince(origin) / interval).rounded(.up)
        while ticks.count < 64 {
            let tick = origin.addingTimeInterval(step * interval)
            if tick > upper { break }
            ticks.append(tick)
            step += 1
        }
        return ticks.isEmpty ? [xDomain.lowerBound.addingTimeInterval(span / 2)] : ticks
    }
}
