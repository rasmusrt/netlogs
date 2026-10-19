import Foundation
import Observation
import NetlogsCore

/// Everything the Router screen shows, built once off the main actor.
///
/// A `final class` for the reason `AnalysisResult` is one: SwiftUI compares a
/// view's stored values on every hover, and reference identity is O(1).
final class RouterResult: Sendable {
    let timeline: HomeTimeline
    /// The newest reading of each kind in the window, for the cards and the
    /// details list. `nil` when nothing in the window had one.
    let latestWiFi: DiagnosticsSnapshot?
    let latestRadio: CellularRadio?
    let routerHost: String?
    /// Median round trip to the router over every reply in the window.
    let routerMedianMs: Double?
    let routerLoss: Double?
    /// Median lag under load across the window's speed tests.
    let bufferbloatMs: Double?
    let speedTests: Int

    init(timeline: HomeTimeline, latestWiFi: DiagnosticsSnapshot?, latestRadio: CellularRadio?,
         routerHost: String?, routerMedianMs: Double?, routerLoss: Double?,
         bufferbloatMs: Double?, speedTests: Int) {
        self.timeline = timeline
        self.latestWiFi = latestWiFi
        self.latestRadio = latestRadio
        self.routerHost = routerHost
        self.routerMedianMs = routerMedianMs
        self.routerLoss = routerLoss
        self.bufferbloatMs = bufferbloatMs
        self.speedTests = speedTests
    }
}

@MainActor
@Observable
final class RouterModel {
    private(set) var result: RouterResult?
    private(set) var isLoading = false
    private(set) var error: String?
    private var loadedAt: Date?

    /// The window the screen covers. Twenty-four hours is what fits 96 readable
    /// columns at fifteen minutes each.
    static let window: TimeInterval = 24 * 3600
    private static let freshness: TimeInterval = 30

    func load(store: SessionStore, force: Bool = false) async {
        if !force, result != nil, let at = loadedAt,
           Date().timeIntervalSince(at) < Self.freshness { return }
        isLoading = result == nil
        defer { isLoading = false }
        do {
            result = try await RouterLoader.load(store: store, window: Self.window)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loadedAt = Date()
    }
}

enum RouterLoader {
    /// Detached and flushed first, like `AnalysisLoader`, so a running
    /// session's last batch is included.
    static func load(store: SessionStore, window: TimeInterval,
                     now: Date = Date()) async throws -> RouterResult {
        try await Task.detached(priority: .userInitiated) {
            try? store.flush()
            let interval = DateInterval(start: now.addingTimeInterval(-window), end: now)
            let sessions = try store.sessionsOverlapping(interval.start ... interval.end)
            let ids = sessions.map(\.id)

            var samples: [PingSample] = []
            var radio: [WANTrace.RadioPoint] = []
            var rates: [WANTrace.RatePoint] = []
            var changes: [WANTrace.RadioChange] = []
            var latestRadio: (Date, CellularRadio)?
            var recorded: [DateInterval] = []

            for session in sessions {
                let mine = (try? store.samples(for: session.id, from: interval.start,
                                               to: interval.end)) ?? []
                samples.append(contentsOf: mine)
                if let first = mine.first?.timestamp, let last = mine.last?.timestamp,
                   last > first {
                    recorded.append(DateInterval(start: first, end: last))
                }

                let snapshots = ((try? store.wanSnapshots(for: session.id)) ?? [])
                    .filter { interval.contains($0.timestamp) }
                guard !snapshots.isEmpty else { continue }
                let trace = WANTrace.build(snapshots: snapshots, samples: [])
                radio.append(contentsOf: trace.radio)
                rates.append(contentsOf: trace.rates)
                changes.append(contentsOf: trace.radioChanges)
                if let newest = snapshots.last(where: { $0.radio != nil }),
                   let value = newest.radio,
                   latestRadio == nil || newest.timestamp > latestRadio!.0 {
                    latestRadio = (newest.timestamp, value)
                }
            }

            var wan = WANTrace()
            wan.radio = radio
            wan.rates = rates
            wan.radioChanges = changes

            let diagnostics = ((try? store.diagnostics(for: ids)) ?? [:])
                .values.flatMap { $0 }
                .filter { interval.contains($0.timestamp) }
                .sorted { $0.timestamp < $1.timestamp }

            let timeline = HomeTimeline.build(interval: interval, recorded: recorded,
                                              diagnostics: diagnostics, samples: samples,
                                              wan: wan)

            let replies = samples.filter { !$0.isWarmup }.compactMap(\.routerRttMs).sorted()
            let counted = samples.filter { !$0.isWarmup }
            let lost = counted.filter(\.routerNoReply).count
            let tests = ((try? store.throughputResults(for: ids)) ?? [:])
                .values.flatMap { $0 }
                .filter { interval.contains($0.timestamp) }
            let bloat = tests.compactMap(\.bufferbloatMs).sorted()

            return RouterResult(
                timeline: timeline,
                latestWiFi: diagnostics.last(where: { $0.kind == .wifi }) ?? diagnostics.last,
                latestRadio: latestRadio?.1,
                routerHost: sessions.max(by: { $0.startedAt < $1.startedAt })?.settings.routerHost,
                routerMedianMs: replies.isEmpty ? nil : replies[replies.count / 2],
                routerLoss: counted.isEmpty ? nil : Double(lost) / Double(counted.count),
                bufferbloatMs: bloat.isEmpty ? nil : bloat[bloat.count / 2],
                speedTests: tests.count
            )
        }.value
    }
}
