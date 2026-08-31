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

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    private var finished: [Run] = []
    private var open: Run?
    private var nextID = 0
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
        guard let value else {
            closeOpen()
            return
        }
        if var current = open, current.value == value {
            current.end = time
            current.sampleCount += 1
            open = current
        } else {
            closeOpen()
            open = Run(id: nextID, value: value, start: time, end: time, sampleCount: 1)
            nextID += 1
        }
    }

    /// Seals the run in progress. Call on session stop so the trailing run is
    /// rendered rather than dropped.
    public mutating func closeOpen() {
        guard let open else { return }
        finished.append(open)
        self.open = nil
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
    }
}

public typealias LoadRun = RunEncoder<LoadPhase>.Run
public typealias OutageRun = RunEncoder<OutageScope>.Run
