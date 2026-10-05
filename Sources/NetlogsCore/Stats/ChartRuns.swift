import Foundation

/// Which hosts were silent across a run of samples.
///
/// Router-only versus internet-only is the distinction the whole app exists to
/// draw — "the LAN is fine, the ISP isn't" — so the chart tints them
/// differently rather than lumping them into one "failure" colour.
public enum OutageScope: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case router
    case internet
    case both

    /// `nil` when both hosts replied, which closes any open outage run.
    public init?(routerSilent: Bool, internetSilent: Bool) {
        switch (routerSilent, internetSilent) {
        case (true, true):   self = .both
        case (true, false):  self = .router
        case (false, true):  self = .internet
        case (false, false): return nil
        }
    }

    public var label: String {
        switch self {
        case .router:   return "Router unreachable"
        case .internet: return "Internet unreachable"
        case .both:     return "No connectivity"
        }
    }
}

/// Run-length encodes a per-sample value into contiguous wall-clock intervals.
///
/// This is how the chart derives its load bands and outage bands. Deriving them
/// from chart buckets instead would be both lossier and more work: a bucket's
/// "dominant value" smears a boundary by up to `bucketWidth / 2`, which is
/// nine seconds at hour-scale on a twenty-five-second throughput test. Runs are
/// exact, O(1) per sample (plan §8.1), and map straight onto
/// `RectangleMark(xStart:xEnd:)`.
public struct RunEncoder<Value: Equatable & Sendable>: Sendable {

    public struct Run: Sendable, Equatable, Identifiable {
        public let id: Int
        public let value: Value
        public var start: Date
        public var end: Date
        public var sampleCount: Int
        /// How much wall clock a single sample stands for, taken from the
        /// cadence of the stream that produced this run. Read only by
        /// `drawnEnd`; it never moves `start` or `end`.
        public var sampleInterval: TimeInterval

        /// Exactly what was measured: first sample to last. A one-sample run
        /// really did span zero seconds between its endpoints, and this keeps
        /// saying so. Nothing that *reports* a number reads `drawnEnd`.
        public var duration: TimeInterval { end.timeIntervalSince(start) }

        /// The end to draw to, which is not always the end that was measured.
        ///
        /// A run built from one sample has `start == end`, so the
        /// `RectangleMark(xStart:xEnd:)` it feeds is zero-width and Swift
        /// Charts draws nothing for it at all — one dropped ping disappeared
        /// from the chart completely, which is precisely the case the outage
        /// band exists to report (`PingChartBucketer.points` deliberately does
        /// *not* break the trace for it). Widening to one sample interval is
        /// not an exaggeration: a sample at `t` is the only evidence available
        /// for the whole tick it opened, so that interval is what it covers.
        ///
        /// A no-op for every multi-sample run: consecutive samples are at
        /// least one interval apart, so `end` already wins the `max`.
        public var drawnEnd: Date {
            max(end, start.addingTimeInterval(sampleInterval))
        }
    }

    /// Fallback cadence, used only before this encoder has seen two samples —
    /// the app's default ping interval.
    public static var assumedSampleInterval: TimeInterval { 1 }

    private var finished: [Run] = []
    private var open: Run?
    private var nextID = 0
    /// Cadence learned from the timestamps themselves, so Core needs no
    /// knowledge of the configured ping interval — that is a user setting, and
    /// threading it through would give the live path and the saved-session path
    /// two chances to disagree about it.
    ///
    /// The *smallest* positive gap seen, not the latest: a sleep/wake gap or a
    /// late tick only ever stretches the spacing, so taking the minimum stops
    /// one suspended Mac from stamping an hours-wide extent onto the next
    /// single-sample run.
    private var observedInterval: TimeInterval?
    private var previousTime: Date?

    private var sampleInterval: TimeInterval {
        observedInterval ?? Self.assumedSampleInterval
    }
    /// Belt-and-braces bound. A real session produces about four load runs per
    /// throughput test and very few outage runs, so this is never reached in
    /// practice — it exists so a pathological session can't grow unbounded.
    private let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = capacity
    }

    /// Extends the open run, or starts a new one. Passing `nil` closes the open
    /// run without starting another — that is how "back to normal" is spelled.
    public mutating func append(_ value: Value?, at time: Date) {
        learnCadence(from: time)
        guard let value else {
            closeOpen()
            return
        }
        if var current = open, current.value == value {
            current.end = time
            current.sampleCount += 1
            current.sampleInterval = sampleInterval
            open = current
        } else {
            closeOpen()
            open = Run(id: nextID, value: value, start: time, end: time,
                       sampleCount: 1, sampleInterval: sampleInterval)
            nextID += 1
        }
    }

    private mutating func learnCadence(from time: Date) {
        defer { previousTime = time }
        guard let previousTime else { return }
        let gap = time.timeIntervalSince(previousTime)
        guard gap > 0 else { return }
        observedInterval = min(observedInterval ?? gap, gap)
    }

    /// Seals the run in progress. Call on session stop so the trailing run is
    /// rendered rather than dropped.
    public mutating func closeOpen() {
        guard var run = open else { return }
        // Re-stamp the cadence on the way out. A run that opened on the very
        // first sample of a session was created before any gap had been seen,
        // so it would otherwise seal carrying the fallback interval rather than
        // the one this session actually ticks at.
        run.sampleInterval = sampleInterval
        finished.append(run)
        open = nil
        if finished.count > capacity {
            finished.removeFirst(finished.count - capacity)
        }
    }

    /// Closed runs plus the one still in progress — what the chart renders.
    public func runs() -> [Run] {
        guard let open else { return finished }
        return finished + [open]
    }

    public mutating func reset() {
        finished.removeAll(keepingCapacity: true)
        open = nil
        nextID = 0
        observedInterval = nil
        previousTime = nil
    }
}

public typealias LoadRun = RunEncoder<LoadPhase>.Run
public typealias OutageRun = RunEncoder<OutageScope>.Run
