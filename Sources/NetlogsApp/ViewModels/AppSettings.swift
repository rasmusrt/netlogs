import SwiftUI
import Observation
import NetlogsCore

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App-wide settings, persisted to `UserDefaults` on every change — no Save
/// button (plan §11). `monitor` is the session config; `theme` and
/// `retentionDays` are app policy.
@MainActor
@Observable
final class AppSettings {
    var monitor: MonitorSettings { didSet { persist() } }
    var theme: AppTheme { didSet { persist() } }
    /// 0 = keep forever.
    var retentionDays: Int { didSet { persist() } }
    /// Summary or chart. Lives here rather than in view state so the View menu
    /// can drive it, and so the choice survives a relaunch.
    var detailMode: DetailMode { didSet { persist() } }
    /// How far back the Analysis screen looks. Optional in `Stored` so an
    /// existing preferences blob still decodes, the same precedent
    /// `detailMode` set.
    var analysisRange: AnalysisRange { didSet { persist() } }
    /// Shows the redesigned Monitor screen instead of the current one. Off by
    /// default; optional in `Stored` for the same reason as `analysisRange`.
    var monitorV2Beta: Bool { didSet { persist() } }

    private static let key = "netlogs.settings.v1"

    private struct Stored: Codable {
        var monitor: MonitorSettings
        var theme: AppTheme
        var retentionDays: Int
        var detailMode: DetailMode?
        var analysisRange: AnalysisRange?
        var monitorV2Beta: Bool?
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Stored.self, from: data) {
            monitor = saved.monitor
            theme = saved.theme
            retentionDays = saved.retentionDays
            detailMode = saved.detailMode ?? .summary
            analysisRange = saved.analysisRange ?? .week
            monitorV2Beta = saved.monitorV2Beta ?? false
        } else {
            monitor = .uiDefault
            theme = .system
            retentionDays = 30
            detailMode = .summary
            analysisRange = .week
            monitorV2Beta = false
        }
    }

    private func persist() {
        let stored = Stored(monitor: monitor, theme: theme,
                            retentionDays: retentionDays, detailMode: detailMode,
                            analysisRange: analysisRange, monitorV2Beta: monitorV2Beta)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
