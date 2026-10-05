import Foundation
import NetlogsCore

/// The Analysis screen's payload, built once off the main actor.
///
/// A `final class` for the same reason `SessionDetail` is one: SwiftUI compares
/// a view's stored values on every re-render, and comparing a struct holding
/// every session in a range means walking it. Reference identity is O(1), and
/// this is immutable and built once, so sharing it is safe.
final class AnalysisResult: Sendable {
    let range: RangeAnalysis
    let findings: [Finding]
    /// How long the queries took. Printed by `--rangecheck` and worth keeping
    /// here too: the decision to defer a denormalised summary table rests on
    /// this number staying small, so it should be observable rather than
    /// assumed.
    let queryMilliseconds: Double

    init(range: RangeAnalysis, findings: [Finding], queryMilliseconds: Double) {
        self.range = range
        self.findings = findings
        self.queryMilliseconds = queryMilliseconds
    }

    var isEmpty: Bool { range.sessions.isEmpty }
}

enum AnalysisLoader {
    /// Mirrors `DetailLoader.load`: detached, flushes first so a running
    /// session's last batch is included, and never touches a `PingSample`.
    static func load(
        store: SessionStore, range: AnalysisRange, now: Date = Date()
    ) async throws -> AnalysisResult {
        try await Task.detached(priority: .userInitiated) {
            try? store.flush()

            let began = DispatchTime.now()
            let interval = range.interval(endingAt: now)
            let sessions = try store.sessionsOverlapping(interval.start ... interval.end)
            let ids = sessions.map(\.id)
            let aggregates = try store.pingAggregates(for: ids)
            let histograms = try store.latencyHistograms(for: ids)

            var throughput: [UUID: [ThroughputResult]] = [:]
            var radio: [UUID: RadioSummary] = [:]
            for id in ids {
                throughput[id] = (try? store.throughputResults(for: id)) ?? []
                // Decoded through the model's own Codable conformance rather
                // than picked apart with json_extract, so this screen and the
                // Network sheet cannot read one row differently. About 3,000
                // rows for a whole database.
                radio[id] = RadioSummary.build((try? store.diagnostics(for: id)) ?? [])
            }

            let analyses = sessions.compactMap { session -> SessionAnalysis? in
                guard let aggregate = aggregates[session.id] else { return nil }
                return SessionAnalysis(
                    session: session,
                    aggregate: aggregate,
                    latency: histograms[session.id] ?? LatencyHistogram(),
                    throughput: throughput[session.id] ?? [],
                    radio: radio[session.id] ?? .empty
                )
            }

            let hourly = (try? store.hourlyBuckets(for: ids)) ?? []
            let routerHourly = (try? store.hourlyBuckets(for: ids, host: .router)) ?? []
            let analysis = RangeAnalysis(interval: interval, sessions: analyses,
                                         hourlyBuckets: hourly,
                                         routerHourlyBuckets: routerHourly)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds
                                 - began.uptimeNanoseconds) / 1_000_000
            return AnalysisResult(range: analysis,
                                  findings: Diagnosis.findings(for: analysis),
                                  queryMilliseconds: elapsed)
        }.value
    }
}
