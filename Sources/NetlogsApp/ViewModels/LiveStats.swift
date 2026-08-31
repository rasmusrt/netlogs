import Foundation
import Observation
import NetlogsCore

/// The always-visible dashboard state (plan §8.2). Separate `@Observable` object
/// from ``PingLog`` so a per-second stat update never invalidates the table.
@MainActor
@Observable
final class LiveStats {
    private var builder = LiveSummaryBuilder()

    /// Wall-clock elapsed, ticked by ``MonitorController``'s clock so it advances
    /// even if samples stall.
    var elapsed: TimeInterval = 0

    /// Stored, not computed.
    ///
    /// These were three computed properties, each calling `builder.summary`,
    /// which rebuilds a whole `LiveSummary` — two `PingStat`s, and six
    /// percentile scans over the latency histograms. The live screen reads them
    /// six times per body pass (`isIdle`, the verdict header's three, the
    /// cards, the verdict), so a single pass rebuilt the same value six times.
    /// Building it once per sample instead makes every read a stored load.
    private(set) var summary = LiveSummary()

    /// Flips false→true exactly once, so views can ask "has anything arrived?"
    /// without depending on a counter that changes every second. `isIdle` used
    /// `sampleCount == 0`, which put a per-tick dependency at the root of the
    /// live screen's body and re-evaluated the entire screen — cards, log table
    /// and all — once a second (plan §8.2).
    private(set) var hasSamples = false

    var sampleCount: Int { summary.totalSamples }
    var failureCount: Int { summary.failureCount }

    func add(_ sample: PingSample) {
        builder.add(sample)
        summary = builder.summary
        if !hasSamples { hasSamples = true }
    }

    func reset() {
        builder = LiveSummaryBuilder()
        summary = LiveSummary()
        hasSamples = false
        elapsed = 0
    }
}
