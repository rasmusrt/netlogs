import Foundation

/// One plotted point.
///
/// Deliberately **non-optional**: Swift Charts has no `Optional: Plottable`
/// conformance, so the vectorized `LinePlot` / `AreaPlot` API (macOS 15+)
/// requires concrete `Double`s. Gaps are carried by `segment`, not by `nil` — a
/// bucket in which a host never replied emits no point at all, and the next
/// point carries a bumped `segment` so the line *breaks* instead of
/// interpolating across the outage.
///
/// That break is the whole reason this type exists. The previous
/// `PingChartPoint` stored `hadFailure` that no view ever read, so a
/// thirty-second outage rendered as a smooth line at normal latency — the chart
/// asserted the connection was healthy precisely when it was down.
public struct RTTPoint: Sendable, Equatable, Identifiable {
    public let id: Int
    public let time: Date
    public let lo: Double
    public let avg: Double
    public let hi: Double
    /// Contiguity group. Points with different segments are never joined.
    public let segment: Int

    public init(id: Int, time: Date, lo: Double, avg: Double, hi: Double, segment: Int) {
        self.id = id
        self.time = time
        self.lo = lo
        self.avg = avg
        self.hi = hi
        self.segment = segment
    }
}

/// Everything one chart needs, whether it came from a live session or a stored
/// one. `PingChartBucketer` and the saved-session loader both produce this, so
/// the live and saved charts are the same view over the same shape — there is
/// no "mode" branch anywhere in the chart.
public struct PingChartSeries: Sendable, Equatable {
    public var router: [RTTPoint]
    public var internet: [RTTPoint]
    public var load: [LoadRun]
    public var outages: [OutageRun]
    /// Pinned explicitly so axis layout doesn't re-derive on every publish.
    public var xDomain: ClosedRange<Date>
    public var yDomain: ClosedRange<Double>
    /// How many buckets had a maximum above `yDomain.upperBound` and were
    /// clamped to it. Surfaced as "N above scale" so a clamped peak is never
    /// silently read as a plateau.
    public var clippedCount: Int

    public init(
        router: [RTTPoint],
        internet: [RTTPoint],
        load: [LoadRun],
        outages: [OutageRun],
        xDomain: ClosedRange<Date>,
        yDomain: ClosedRange<Double>,
        clippedCount: Int
    ) {
        self.router = router
        self.internet = internet
        self.load = load
        self.outages = outages
        self.xDomain = xDomain
        self.yDomain = yDomain
        self.clippedCount = clippedCount
    }

    public var isEmpty: Bool { router.isEmpty && internet.isEmpty }

    public static func empty(now: Date = Date()) -> PingChartSeries {
        PingChartSeries(
            router: [], internet: [], load: [], outages: [],
            xDomain: now ... now.addingTimeInterval(60),
            yDomain: 0 ... PingChartBucketer.minimumCeilingMs,
            clippedCount: 0
        )
    }
}

/// Folds a 1 Hz sample stream into at most `capacity` buckets covering the
/// whole session, at amortised O(1) per sample (plan §8.1).
///
/// When the sealed-bucket count reaches `capacity`, adjacent buckets are merged
/// pairwise and `bucketWidth` doubles. Merging is exact for min / max / sum /
/// count — a merged bucket reduces its sample range to exactly what reducing
/// that range directly would give — so no fidelity is lost relative to holding
/// the full history and re-reducing it. An eight-hour session does seven
/// compactions in total.
///
/// The *boundaries* are not the same as a one-shot downsample over the finished
/// array: this bucketer only ever doubles, so it settles on a power-of-two
/// width and between `capacity / 2` and `capacity` buckets, where a one-shot
/// pass picks `ceil(n / capacity)` and always emits `capacity`. Both are
/// faithful reductions; only the streaming one is O(1) per sample. They agree
/// exactly while `n <= capacity`, before any compaction has happened.
public struct PingChartBucketer: Sendable {

    /// Floor for the y-axis ceiling. Keeps a healthy LAN from being drawn on a
    /// 0–3 ms axis where ordinary jitter looks like a catastrophe.
    public static let minimumCeilingMs: Double = 50

    struct HostFold: Sendable, Equatable {
        var count = 0
        var sum = 0.0
        var lo = Double.infinity
        var hi = -Double.infinity

        mutating func add(_ ms: Double) {
            count += 1
            sum += ms
            if ms < lo { lo = ms }
            if ms > hi { hi = ms }
        }

        mutating func merge(_ other: HostFold) {
            guard other.count > 0 else { return }
            count += other.count
            sum += other.sum
            lo = Swift.min(lo, other.lo)
            hi = Swift.max(hi, other.hi)
        }

        /// Kept as sum+count rather than a stored average: once bucket widths
        /// differ (which they do at the tail after a compaction), averaging
        /// averages is wrong.
        var avg: Double { count > 0 ? sum / Double(count) : 0 }
    }

    struct Bucket: Sendable {
        var samples = 0
        var firstTime: Date
        var lastTime: Date
        var router = HostFold()
        var internet = HostFold()

        mutating func add(_ sample: PingSample) {
            samples += 1
            lastTime = sample.timestamp
            if let ms = sample.routerMs { router.add(ms) }
            if let ms = sample.internetMs { internet.add(ms) }
        }

        mutating func merge(_ other: Bucket) {
            samples += other.samples
            lastTime = other.lastTime
            router.merge(other.router)
            internet.merge(other.internet)
        }

        var midpoint: Date {
            firstTime.addingTimeInterval(lastTime.timeIntervalSince(firstTime) / 2)
        }
    }

    public let capacity: Int
    private var sealed: [Bucket] = []
    private var open: Bucket?
    public private(set) var bucketWidth = 1
    public private(set) var sampleCount = 0
    public private(set) var firstTime: Date?
    public private(set) var lastTime: Date?

    public init(capacity: Int = 200) {
        precondition(capacity >= 2 && capacity.isMultiple(of: 2),
                     "capacity must be even and at least 2 so pairwise compaction is exact")
        self.capacity = capacity
        sealed.reserveCapacity(capacity)
    }

    /// Returns `true` when this sample sealed a bucket — the natural cue to
    /// republish, which is why the live chart needs no timer of its own.
    @discardableResult
    public mutating func append(_ sample: PingSample) -> Bool {
        sampleCount += 1
        if firstTime == nil { firstTime = sample.timestamp }
        lastTime = sample.timestamp

        if open == nil {
            open = Bucket(firstTime: sample.timestamp, lastTime: sample.timestamp)
        }
        open?.add(sample)

        guard let current = open, current.samples >= bucketWidth else { return false }
        sealed.append(current)
        open = nil
        if sealed.count >= capacity { compact() }
        return true
    }

    /// O(capacity), once per doubling — so amortised O(1) per sample.
    private mutating func compact() {
        var merged: [Bucket] = []
        merged.reserveCapacity(capacity / 2)
        var i = 0
        while i < sealed.count {
            var bucket = sealed[i]
            if i + 1 < sealed.count { bucket.merge(sealed[i + 1]) }
            merged.append(bucket)
            i += 2
        }
        sealed = merged
        bucketWidth *= 2
    }

    public mutating func reset() {
        sealed.removeAll(keepingCapacity: true)
        open = nil
        bucketWidth = 1
        sampleCount = 0
        firstTime = nil
        lastTime = nil
    }

    private var allBuckets: [Bucket] {
        guard let open else { return sealed }
        return sealed + [open]
    }

    /// Emits points for one host, bumping `segment` across any bucket in which
    /// that host never replied.
    ///
    /// Note a bucket only breaks the line when it is *entirely* silent: at
    /// hour-scale one lost ping inside an eighteen-sample bucket is reported by
    /// the outage band, not by a hole in the trace. That is the right split —
    /// the band is exact about when, the line stays readable.
    private func points(
        _ fold: KeyPath<Bucket, HostFold>,
        ceiling: Double
    ) -> (points: [RTTPoint], clipped: Int) {
        var out: [RTTPoint] = []
        out.reserveCapacity(capacity)
        var segment = 0
        var clipped = 0
        for (index, bucket) in allBuckets.enumerated() {
            let host = bucket[keyPath: fold]
            guard host.count > 0 else {
                segment += 1
                continue
            }
            if host.hi > ceiling { clipped += 1 }
            out.append(RTTPoint(
                id: index,
                time: bucket.midpoint,
                lo: Swift.min(host.lo, ceiling),
                avg: Swift.min(host.avg, ceiling),
                hi: Swift.min(host.hi, ceiling),
                segment: segment
            ))
        }
        return (out, clipped)
    }

    /// 95th percentile of bucket maxima, headroomed and floored.
    ///
    /// An inferred domain lets one pathological spike — or the documented ICMP
    /// warm-up artefact — flatten the entire trace into the bottom few percent
    /// of the plot. Sorting at most 400 doubles twice a second is not a cost
    /// worth optimising away.
    private func yCeiling() -> Double {
        let maxima = allBuckets
            .flatMap { [$0.router, $0.internet] }
            .filter { $0.count > 0 }
            .map(\.hi)
            .sorted()
        guard !maxima.isEmpty else { return Self.minimumCeilingMs }
        let index = Swift.min(maxima.count - 1, Int(Double(maxima.count) * 0.95))
        return Swift.max(Self.minimumCeilingMs, (maxima[index] * 1.25).rounded(.up))
    }

    public func series(load: [LoadRun], outages: [OutageRun], now: Date) -> PingChartSeries {
        let ceiling = yCeiling()
        let router = points(\.router, ceiling: ceiling)
        let internet = points(\.internet, ceiling: ceiling)
        let start = firstTime ?? now
        let end = Swift.max(lastTime ?? now, now, start.addingTimeInterval(60))
        return PingChartSeries(
            router: router.points,
            internet: internet.points,
            load: load,
            outages: outages,
            xDomain: start ... end,
            yDomain: 0 ... ceiling,
            clippedCount: router.clipped + internet.clipped
        )
    }
}

extension PingChartSeries {
    /// Builds a series from a finished array of samples — the saved-session
    /// path. Runs the same bucketer and the same run encoders the live chart
    /// uses, so a stored session and a live one are rendered by identical code.
    ///
    /// `warmupSamplesToSkip` drops the leading samples that carry the ICMP
    /// socket warm-up spike (PHASE1-FINDINGS §3). The live stats already
    /// exclude them; excluding them here too keeps a ~580 ms artefact from
    /// setting the y-axis for the whole session.
    public static func build(
        samples: [PingSample],
        capacity: Int = 200,
        warmupSamplesToSkip: UInt32 = 0,
        now: Date = Date()
    ) -> PingChartSeries {
        var bucketer = PingChartBucketer(capacity: capacity)
        var load = RunEncoder<LoadPhase>()
        var outages = RunEncoder<OutageScope>()

        for sample in samples where sample.id >= warmupSamplesToSkip {
            bucketer.append(sample)
            load.append(sample.phase == .idle ? nil : sample.phase, at: sample.timestamp)
            outages.append(
                OutageScope(routerSilent: sample.routerMs == nil,
                            internetSilent: sample.internetMs == nil),
                at: sample.timestamp
            )
        }
        load.closeOpen()
        outages.closeOpen()

        guard bucketer.sampleCount > 0 else { return .empty(now: now) }
        return bucketer.series(
            load: load.runs(),
            outages: outages.runs(),
            now: bucketer.lastTime ?? now
        )
    }
}
