import Foundation
import Observation
import NetlogsCore

/// Holds the Analysis screen's loaded range.
///
/// Its own `@Observable` object rather than state on the view, for the reason
/// `LiveSheetLoader` documents: a `@State` write re-renders the view that owns
/// it, so setting `isLoading` and then `result` would invalidate the whole
/// screen twice for data only part of it reads.
@MainActor
@Observable
final class AnalysisModel {
    private(set) var result: AnalysisResult?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Which sessions the diagnosis band has filtered the table down to, or
    /// empty for all of them. A finding cites its evidence; this is how the
    /// citation is followed.
    var focusedSessions: Set<UUID> = []

    /// Which target the screen describes. Never one figure for the whole range
    /// (the plan's first refusal), so with mixed targets the screen shows one
    /// at a time and a picker switches. `nil` means the busiest one.
    var selectedTarget: TargetKey?

    /// The figure the session chart draws, picked by the metric tiles.
    var metric: AnalysisMetric = .latency

    /// Sessions to light up in the chart while a finding or a part of the path
    /// is hovered. Hover-only, so it is never persisted and never filters.
    var highlighted: Set<UUID> = []

    private var loadedRange: AnalysisRange?
    private var loadedAt: Date?

    /// A range load is not free, and the screen is re-entered often — the same
    /// freshness idea as `LiveSheetLoader`, at a longer horizon because a
    /// finished session does not change.
    private static let freshness: TimeInterval = 30

    func load(store: SessionStore, range: AnalysisRange, force: Bool = false) async {
        if !force, result != nil, loadedRange == range,
           let at = loadedAt, Date().timeIntervalSince(at) < Self.freshness { return }

        isLoading = result == nil || loadedRange != range
        defer { isLoading = false }
        do {
            result = try await AnalysisLoader.load(store: store, range: range)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loadedRange = range
        loadedAt = Date()
        focusedSessions = []
        highlighted = []
        if let target = selectedTarget,
           !(result?.range.byTarget.contains { $0.key == target } ?? false) {
            selectedTarget = nil
        }
    }

    /// The group the screen describes: the picked one, else the busiest.
    func group(in result: AnalysisResult) -> TargetGroup? {
        let groups = result.range.byTarget
        if let target = selectedTarget, let match = groups.first(where: { $0.key == target }) {
            return match
        }
        return groups.first
    }

    /// Every session in range for that target, withheld ones included, so the
    /// chart and the table can show them faded rather than pretend they did
    /// not happen. Newest first, the order `RangeAnalysis` keeps.
    func sessions(in result: AnalysisResult) -> [SessionAnalysis] {
        guard let key = group(in: result)?.key else { return result.range.sessions }
        return result.range.sessions.filter {
            $0.session.settings.internetHost == key.internetHost
                && $0.session.settings.routerHost == key.routerHost
        }
    }

    /// Built once per result and target: merging a histogram per cell is not
    /// free, and the screen re-renders on every hover.
    @ObservationIgnored private var gridCache: (result: ObjectIdentifier, target: TargetKey?,
                                                grid: WeekHourGrid)?

    func weekGrid(in result: AnalysisResult) -> WeekHourGrid {
        let target = group(in: result)?.key
        if let cache = gridCache, cache.result == ObjectIdentifier(result), cache.target == target {
            return cache.grid
        }
        let ids = Set(sessions(in: result).filter { $0.coverage >= Scoring.coverageFloor }.map(\.id))
        let grid = WeekHourGrid.build(result.range.hourlyBuckets, sessionIDs: ids)
        gridCache = (ObjectIdentifier(result), target, grid)
        return grid
    }

    /// Findings that concern the shown target: those citing any of its
    /// sessions, plus those that cite none (such as `healthy`).
    func findings(in result: AnalysisResult) -> [Finding] {
        let ids = Set(sessions(in: result).map(\.id))
        return result.findings.filter {
            $0.sessionIDs.isEmpty || !ids.isDisjoint(with: $0.sessionIDs)
        }
    }

    func focus(_ finding: Finding) {
        let ids = Set(finding.sessionIDs)
        focusedSessions = focusedSessions == ids ? [] : ids
    }
}

/// The four figures a session is scored on, in the order the tiles show them.
enum AnalysisMetric: String, CaseIterable, Identifiable {
    case latency, loss, jitter, bufferbloat
    var id: Self { self }

    var title: String {
        switch self {
        case .latency:     return "Latency"
        case .loss:        return "Packet loss"
        case .jitter:      return "Jitter"
        case .bufferbloat: return "Lag under load"
        }
    }
}
