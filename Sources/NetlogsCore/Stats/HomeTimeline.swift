import Foundation

/// The home network over a fixed window, in equal buckets, for the Router
/// screen: Wi-Fi signal, how fast the router answers, the gateway's view of the
/// line, and what happened along the way.
///
/// Every lane shares one time axis on purpose. The question this screen answers
/// is "was it the Wi-Fi, the router or the line?", and the only way to answer
/// it at a glance is to read all three at the same moment.
///
/// A bucket nothing recorded is `measured == false` with every figure `nil` —
/// never zero. The Mac sleeps, and a lane that drew zero across the night would
/// be the one-sample-outage lie at a day's scale.
public struct HomeTimeline: Sendable, Equatable {

    public struct Bucket: Sendable, Equatable, Identifiable {
        public let id: Int
        public let start: Date
        public let end: Date
        /// Whether any session was recording during the bucket.
        public let measured: Bool
        /// Median RSSI, dBm. `nil` on Ethernet or with no reading.
        public let rssi: Double?
        /// Median round trip to the router, ms.
        public let routerMs: Double?
        /// Share of router pings with no reply.
        public let routerLoss: Double?
        /// Median 5G/LTE SINR from the gateway, dB.
        public let sinr: Double?
        /// Mean WAN rates from the gateway's counters, Mbit/s.
        public let downMbps: Double?
        public let upMbps: Double?

        public var mid: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    }

    public struct Event: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case notRecording, weakWiFi, slowRouter, channelChange, radioChange
        }
        public let id: Int
        public let kind: Kind
        public let start: Date
        public let end: Date
        /// The figure the event is about: the weakest RSSI, the slowest router
        /// reply, the new channel. `nil` where the event has none.
        public let value: Double?
        /// Words from the source, such as the gateway's "band n78 → n41".
        public let note: String?
    }

    public let interval: DateInterval
    public let buckets: [Bucket]
    /// Newest first.
    public let events: [Event]

    public static let bucketCount = 96
    /// Where the signal starts costing rate — the same line `RadioSummary` uses.
    public static let weakRSSI = Double(RadioSummary.weakRSSI)
    /// A router that takes longer than this to answer a ping from the same room
    /// is busy, not merely far away.
    public static let slowRouterMs = 20.0
    /// Gaps shorter than this are a Mac waking up, not worth an event.
    public static let minimumGapBuckets = 2

    public init(interval: DateInterval, buckets: [Bucket], events: [Event]) {
        self.interval = interval
        self.buckets = buckets
        self.events = events
    }

    public var hasWiFi: Bool { buckets.contains { $0.rssi != nil } }
    public var hasGateway: Bool { buckets.contains { $0.sinr != nil || $0.downMbps != nil } }
    public var hasMeasurements: Bool { buckets.contains { $0.measured } }

    // MARK: - Build

    public static func build(
        interval: DateInterval,
        recorded: [DateInterval],
        diagnostics: [DiagnosticsSnapshot],
        samples: [PingSample],
        wan: WANTrace,
        bucketCount: Int = HomeTimeline.bucketCount
    ) -> HomeTimeline {
        let width = interval.duration / Double(bucketCount)
        guard width > 0 else { return HomeTimeline(interval: interval, buckets: [], events: []) }

        func index(_ date: Date) -> Int? {
            let i = Int(date.timeIntervalSince(interval.start) / width)
            return (0..<bucketCount).contains(i) ? i : nil
        }

        var rssi = [[Double]](repeating: [], count: bucketCount)
        for snapshot in diagnostics {
            guard let value = snapshot.rssi, let i = index(snapshot.timestamp) else { continue }
            rssi[i].append(Double(value))
        }

        var router = [[Double]](repeating: [], count: bucketCount)
        var routerPings = [Int](repeating: 0, count: bucketCount)
        var routerLost = [Int](repeating: 0, count: bucketCount)
        for sample in samples where !sample.isWarmup {
            guard let i = index(sample.timestamp) else { continue }
            routerPings[i] += 1
            if let ms = sample.routerRttMs { router[i].append(ms) }
            if sample.routerNoReply { routerLost[i] += 1 }
        }

        var sinr = [[Double]](repeating: [], count: bucketCount)
        for point in wan.radio {
            guard let i = index(point.time) else { continue }
            sinr[i].append(point.sinr)
        }

        // Rates are intervals; weight each by how long it lasted so a short
        // burst does not count as much as a whole minute.
        var down = [Double](repeating: 0, count: bucketCount)
        var up = [Double](repeating: 0, count: bucketCount)
        var rateSeconds = [Double](repeating: 0, count: bucketCount)
        for rate in wan.rates {
            let mid = rate.start.addingTimeInterval(rate.end.timeIntervalSince(rate.start) / 2)
            guard let i = index(mid) else { continue }
            let seconds = max(rate.end.timeIntervalSince(rate.start), 1)
            down[i] += rate.downMbps * seconds
            up[i] += rate.upMbps * seconds
            rateSeconds[i] += seconds
        }

        let buckets = (0..<bucketCount).map { i -> Bucket in
            let start = interval.start.addingTimeInterval(Double(i) * width)
            let end = start.addingTimeInterval(width)
            let measured = recorded.contains { $0.start < end && $0.end > start }
            return Bucket(
                id: i, start: start, end: end, measured: measured,
                rssi: measured ? median(rssi[i]) : nil,
                routerMs: measured ? median(router[i]) : nil,
                routerLoss: measured && routerPings[i] > 0
                    ? Double(routerLost[i]) / Double(routerPings[i]) : nil,
                sinr: measured ? median(sinr[i]) : nil,
                downMbps: measured && rateSeconds[i] > 0 ? down[i] / rateSeconds[i] : nil,
                upMbps: measured && rateSeconds[i] > 0 ? up[i] / rateSeconds[i] : nil
            )
        }

        var events: [Event] = []
        func add(_ kind: Event.Kind, _ start: Date, _ end: Date, _ value: Double?, _ note: String? = nil) {
            events.append(Event(id: events.count, kind: kind, start: start, end: end,
                                value: value, note: note))
        }

        for run in runs(buckets, where: { !$0.measured }) where run.count >= minimumGapBuckets {
            add(.notRecording, run.first!.start, run.last!.end, nil)
        }
        for run in runs(buckets, where: { ($0.rssi ?? 0) <= weakRSSI && $0.rssi != nil }) {
            add(.weakWiFi, run.first!.start, run.last!.end, run.compactMap(\.rssi).min())
        }
        for run in runs(buckets, where: { ($0.routerMs ?? 0) > slowRouterMs }) {
            add(.slowRouter, run.first!.start, run.last!.end, run.compactMap(\.routerMs).max())
        }

        var lastChannel: Int?
        for snapshot in diagnostics.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let channel = snapshot.channel else { continue }
            if let lastChannel, lastChannel != channel, interval.contains(snapshot.timestamp) {
                add(.channelChange, snapshot.timestamp, snapshot.timestamp, Double(channel),
                    snapshot.band)
            }
            lastChannel = channel
        }
        for change in wan.radioChanges where interval.contains(change.time) {
            add(.radioChange, change.time, change.time, nil, change.summary)
        }

        let ordered = events
            .sorted { $0.start > $1.start }
            .enumerated()
            .map { Event(id: $0.offset, kind: $0.element.kind, start: $0.element.start,
                         end: $0.element.end, value: $0.element.value, note: $0.element.note) }
        return HomeTimeline(interval: interval, buckets: buckets, events: ordered)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Consecutive buckets matching a predicate.
    private static func runs(_ buckets: [Bucket], where match: (Bucket) -> Bool) -> [[Bucket]] {
        var out: [[Bucket]] = []
        var current: [Bucket] = []
        for bucket in buckets {
            if match(bucket) {
                current.append(bucket)
            } else if !current.isEmpty {
                out.append(current)
                current = []
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
