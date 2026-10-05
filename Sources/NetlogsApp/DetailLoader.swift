import Foundation
import NetlogsCore

/// The full picture for one stored session — built off the main actor from the
/// SQLite history, only when something needs it (plan §8.2).
///
/// Everything here is computed once, on load. `SavedSessionView` previously
/// called `load` *and* `export`, reading and reducing every sample of the
/// session twice; one call now covers the screen.
///
/// A `final class`, not a struct, purely for how SwiftUI compares it. As a
/// struct it was compared field by field — including `samples`, which is every
/// ping of the session, 38k of them for an overnight run. That comparison ran
/// whenever a parent re-rendered, which for the live screen is once a second,
/// *and* on every frame of a sheet's present/dismiss animation. Reference
/// identity makes it O(1). It is immutable and built once, so sharing it is
/// safe.
final class SessionDetail: Sendable {
    let session: SessionState
    let summary: DetailSummary
    let stats: LiveSummary
    let verdict: SessionVerdict
    /// CHART DISABLED — nil while `DetailMode.selectable` excludes `.chart`.
    /// Built over every sample of the session, and nothing reads it while the
    /// chart is off, so it was a full pass plus its allocations on every sheet
    /// open. Restore it by re-enabling `.chart` in `DetailMode.selectable`.
    let chart: PingChartSeries?
    let throughputAverages: ThroughputAverages
    let samples: [PingSample]
    /// Newest-first and capped, ready for the table. Computed once here rather
    /// than in a view body, which would re-derive it on every layout pass.
    let tableRows: [PingSample]
    /// Same reasoning, for the Network sheet's signal trace.
    let diagnosticsTrace: DiagnosticsTrace
    /// What this Mac was sending during the session's latency episodes.
    /// Rare — one per episode at most — so this is the whole list, not a window.
    let traffic: [TrafficCapture]
    /// The Gateway sheet's three series, built once here for the same reason
    /// as `diagnosticsTrace`.
    let wanTrace: WANTrace
    /// The last radio the gateway reported, for the Gateway card.
    let lastRadio: CellularRadio?

    init(
        session: SessionState,
        summary: DetailSummary,
        stats: LiveSummary,
        verdict: SessionVerdict,
        chart: PingChartSeries?,
        throughputAverages: ThroughputAverages,
        samples: [PingSample],
        traffic: [TrafficCapture] = [],
        wan: [WANSnapshot] = []
    ) {
        self.traffic = traffic
        self.session = session
        self.summary = summary
        self.stats = stats
        self.verdict = verdict
        self.chart = chart
        self.throughputAverages = throughputAverages
        self.samples = samples
        self.tableRows = Array(samples.suffix(samplesTableRenderCap).reversed())
        self.diagnosticsTrace = DiagnosticsTrace.build(summary.diagnostics)
        self.wanTrace = WANTrace.build(snapshots: wan, samples: samples)
        self.lastRadio = wan.last { $0.radio != nil }?.radio
    }

    var sampleCount: Int { samples.count }
    var failures: [PingSample] { summary.failures }
    var latestThroughput: ThroughputResult? { summary.throughput.last }
}

enum DetailLoader {
    static func load(store: SessionStore, sessionID: UUID) async throws -> SessionDetail {
        try await Task.detached(priority: .userInitiated) {
            try? store.flush() // pick up the last unflushed batch of a live session

            guard let session = try store.loadSession(sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let samples = try store.samples(for: sessionID)
            let throughput = try store.throughputResults(for: sessionID)
            let diagnostics = try store.diagnostics(for: sessionID)
            let traffic = try store.trafficCaptures(for: sessionID)
            let wan = try store.wanSnapshots(for: sessionID)

            // Everything that judges the session skips the ICMP warm-up
            // samples, exactly as the live path does — otherwise a saved
            // session's header reads "0 failures" beside a Failures tab holding
            // a warm-up timeout, and "10 slowest" always leads with the
            // warm-up spike. `samples` keeps everything, for export and for
            // the capped table window.
            let analysed = samples.filter { $0.id >= PingSample.warmupSampleCount }

            var builder = LiveSummaryBuilder()
            for sample in analysed { builder.add(sample) }
            let stats = builder.summary
            let averages = ThroughputAverages(results: throughput)

            return SessionDetail(
                session: session,
                summary: DetailSummary.build(
                    samples: analysed, throughput: throughput, diagnostics: diagnostics
                ),
                stats: stats,
                verdict: SessionVerdict.evaluate(summary: stats, throughput: averages),
                // Same warm-up exclusion the live chart applies, so a stored
                // session isn't drawn on an axis set by a socket artefact.
                chart: DetailMode.selectable.contains(.chart)
                    ? PingChartSeries.build(
                        samples: samples,
                        warmupSamplesToSkip: PingSample.warmupSampleCount
                      )
                    : nil,
                throughputAverages: averages,
                samples: samples,
                traffic: traffic,
                wan: wan
            )
        }.value
    }

    static func export(store: SessionStore, sessionID: UUID) async throws -> SessionExport {
        try await Task.detached(priority: .userInitiated) {
            try? store.flush()
            guard let session = try store.loadSession(sessionID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return SessionExport(
                session: session,
                samples: try store.samples(for: sessionID),
                throughput: try store.throughputResults(for: sessionID),
                diagnostics: try store.diagnostics(for: sessionID),
                traffic: try store.trafficCaptures(for: sessionID)
            )
        }.value
    }
}
