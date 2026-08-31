import Foundation

/// The heavy, on-demand payload behind the detail sheets (plan §5 / §8.2).
/// Built only when a sheet opens, from the full session history in SQLite —
/// never kept live.
public struct DetailSummary: Sendable {
    public var routerLowest: [PingSample]
    public var routerHighest: [PingSample]
    public var internetLowest: [PingSample]
    public var internetHighest: [PingSample]
    public var failures: [PingSample]
    public var throughput: [ThroughputResult]
    public var diagnostics: [DiagnosticsSnapshot]

    public init(
        routerLowest: [PingSample] = [], routerHighest: [PingSample] = [],
        internetLowest: [PingSample] = [], internetHighest: [PingSample] = [],
        failures: [PingSample] = [],
        throughput: [ThroughputResult] = [],
        diagnostics: [DiagnosticsSnapshot] = []
    ) {
        self.routerLowest = routerLowest
        self.routerHighest = routerHighest
        self.internetLowest = internetLowest
        self.internetHighest = internetHighest
        self.failures = failures
        self.throughput = throughput
        self.diagnostics = diagnostics
    }

    /// One streaming pass over `samples` — bounded top-N inserts, no full sorts
    /// (plan §8.1). O(n) in the sample count; fine for a multi-hour session.
    public static func build(
        samples: [PingSample],
        throughput: [ThroughputResult] = [],
        diagnostics: [DiagnosticsSnapshot] = [],
        topN: Int = 10
    ) -> DetailSummary {
        var routerLow = TopNTracker<PingSample>(capacity: topN, keep: .smallest) { $0.routerMs ?? .infinity }
        var routerHigh = TopNTracker<PingSample>(capacity: topN, keep: .largest) { $0.routerMs ?? -.infinity }
        var internetLow = TopNTracker<PingSample>(capacity: topN, keep: .smallest) { $0.internetMs ?? .infinity }
        var internetHigh = TopNTracker<PingSample>(capacity: topN, keep: .largest) { $0.internetMs ?? -.infinity }
        var failures: [PingSample] = []

        for sample in samples {
            if sample.routerMs != nil { routerLow.offer(sample); routerHigh.offer(sample) }
            if sample.internetMs != nil { internetLow.offer(sample); internetHigh.offer(sample) }
            if sample.routerMs == nil || sample.internetMs == nil { failures.append(sample) }
        }

        return DetailSummary(
            routerLowest: routerLow.elements,
            routerHighest: routerHigh.elements,
            internetLowest: internetLow.elements,
            internetHighest: internetHigh.elements,
            failures: failures,
            throughput: throughput,
            diagnostics: diagnostics
        )
    }
}
