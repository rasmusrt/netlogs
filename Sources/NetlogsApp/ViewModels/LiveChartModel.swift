import Foundation
import Observation
import NetlogsCore

/// The hero RTT chart's backing store.
///
/// Its own `@Observable` object rather than a projection of `PingLog`, and that
/// is a mechanical requirement, not a stylistic one (plan §8.2). Observation
/// tracks at stored-property granularity, and `PingLog.rows` and `PingLog.count`
/// both read one stored `window` — so a chart that read either would be
/// invalidated by the very same append that invalidates the ping `Table`, and
/// both would re-render every second. `rows` also allocates a fresh 300-element
/// array on every read.
///
/// `series` is the only property the view reads. Everything else is accumulator
/// state, so writing it each second invalidates nothing.
///
/// Holds no session history: samples fold into a bounded set of buckets on
/// arrival, so memory is flat across a multi-hour run and nothing is ever
/// re-reduced over the full history (plan §8.1).
@MainActor
@Observable
final class LiveChartModel {

    enum Range: String, CaseIterable, Identifiable {
        case fiveMinutes = "5m"
        case session = "Session"

        var id: Self { self }
        var label: String { rawValue }
    }

    private(set) var series: PingChartSeries = .empty()
    private(set) var range: Range = .session

    // Whole-session path: bounded, amortised O(1) per sample.
    private var bucketer = PingChartBucketer(capacity: 200)
    private var load = RunEncoder<LoadPhase>()
    private var outage = RunEncoder<OutageScope>()

    // Rolling five-minute path. Deliberately *not* `controller.log`'s window —
    // sharing it to save 15 KB would reintroduce exactly the coupling above.
    private var recent = PingLogWindow(window: .seconds(300))

    private var lastPublish: Date = .distantPast

    /// Redraw ceiling.
    ///
    /// Swift Charts has no partial invalidation — every publish rebuilds every
    /// mark and re-resolves the scales. That is only single-digit milliseconds,
    /// so 1 Hz would be affordable on raw CPU; the reason to throttle is that a
    /// per-second array swap inside an animating transaction keeps CoreAnimation
    /// committing at *display* rate (120 Hz on ProMotion) for the whole session.
    /// The chart also disables implicit animation outright, which is the other
    /// half of that fix.
    ///
    /// Past about ten minutes it is perceptually pointless anyway: 200 buckets
    /// across ~800 pt is 4 pt per bucket, so one new sample moves the trace by a
    /// fraction of a point.
    private let minimumPublishInterval: TimeInterval = 2

    /// `@Observable` rewrites stored properties into computed ones, so `didSet`
    /// on `range` would not fire reliably. Explicit setter instead.
    func setRange(_ newRange: Range) {
        guard newRange != range else { return }
        range = newRange
        publish(at: Date(), force: true)
    }

    func append(_ sample: PingSample) {
        let sealedABucket = bucketer.append(sample)
        load.append(sample.phase == .idle ? nil : sample.phase, at: sample.timestamp)
        // Silence, not missed deadlines — see `PingChartBucketer.series`. The
        // live path and the saved path have to agree on this or a session looks
        // different after it is reloaded.
        outage.append(
            OutageScope(routerSilent: sample.routerNoReply,
                        internetSilent: sample.internetNoReply),
            at: sample.timestamp
        )
        recent.append(sample)

        // Publishing on a sealed bucket means the tail is never stale, and
        // needs no timer of its own.
        let due = sample.timestamp.timeIntervalSince(lastPublish) >= minimumPublishInterval
        if sealedABucket || due { publish(at: sample.timestamp) }
    }

    func reset() {
        bucketer.reset()
        load.reset()
        outage.reset()
        recent.reset()
        lastPublish = .distantPast
        series = .empty()
    }

    /// Called on stop, so a session that ended mid-download still renders that
    /// trailing band rather than dropping it.
    func finish() {
        load.closeOpen()
        outage.closeOpen()
        publish(at: Date(), force: true)
    }

    private func publish(at now: Date, force: Bool = false) {
        guard force || now.timeIntervalSince(lastPublish) > 0 else { return }
        lastPublish = now

        switch range {
        case .session:
            series = bucketer.series(load: load.runs(), outages: outage.runs(), now: now)

        case .fiveMinutes:
            // Zoomed in, so plot every sample — fidelity is the entire point of
            // zooming, and a one-second outage should break the line at
            // one-second resolution. Rebuilding over 300 samples is tens of
            // microseconds; keeping one code path is worth more than avoiding
            // it.
            let cutoff = now.addingTimeInterval(-300)
            series = PingChartSeries.build(
                samples: recent.samples,
                capacity: 400,
                now: now
            )
            series.load = load.runs().filter { $0.end >= cutoff }
            series.outages = outage.runs().filter { $0.end >= cutoff }
        }
    }
}
