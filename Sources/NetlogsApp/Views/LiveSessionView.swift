import SwiftUI
import NetlogsCore

/// The live Monitor screen.
///
/// Owns lifecycle — start/stop, autostart, the error banner — and hands each
/// region of `SessionScaffold` an already-narrow value, so the cards, the
/// chart, and the log table each register their own Observation dependency
/// (plan §8.2).
struct LiveSessionView: View {
    let controller: MonitorController
    var settings: MonitorSettings = .uiDefault
    var onSessionEnd: () -> Void = {}

    @Binding var mode: DetailMode
    @State private var sheet: SessionSheet?
    @State private var loader = LiveSheetLoader()


    private var isIdle: Bool {
        controller.state == .idle && !controller.stats.hasSamples
    }

    var body: some View {
        Group {
            if isIdle { idleState } else { session }
        }
        .navigationTitle("Monitor")
        .toolbar { toolbarContent }
        // Three stable references, and nothing that changes per tick. Reading
        // the live values here instead put them in *this* view's body, so every
        // parent re-render — and every `@State` write from the load — rebuilt
        // the sheet. Measured: on screen in under 65 ms, then 8-10 body
        // evaluations over the next 1.4-1.8 s. That settling is what read as a
        // slow sheet.
        .sheet(item: $sheet) { which in
            LiveSessionSheet(sheet: which, controller: controller, loader: loader)
        }
        .onAppear {
            // Once per launch, which is what the flag means. `onAppear` fires
            // every time this view is shown — including every click on Monitor
            // in the sidebar — and the flag stays in `CommandLine.arguments`
            // for the life of the process, so without the latch `--autostart`
            // silently became "start a session whenever you navigate back to
            // Monitor and nothing is running".
            if !Self.didAutostart,
               CommandLine.arguments.contains("--autostart"),
               case .idle = controller.state {
                Self.didAutostart = true
                controller.start(settings: settings)
            }
        }
    }

    /// Latch for `--autostart`. Static, not `@State`: the view is recreated on
    /// every navigation back to Monitor, which is exactly the case being
    /// guarded against.
    @MainActor private static var didAutostart = false

    /// A single empty state, replacing two that used to overlap.
    private var idleState: some View {
        ContentUnavailableView {
            Label("Not monitoring", systemImage: "waveform.path.ecg")
        } description: {
            Text("Start a session to watch your connection in real time.")
        } actions: {
            Button("Start monitoring") { controller.start(settings: settings) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var session: some View {
        SessionScaffold(mode: mode) {
            VStack(spacing: Space.s) {
                SessionVerdictHeader(
                    verdict: verdict,
                    reason: SessionVerdict.reason(for: verdict,
                                                  summary: controller.stats.summary,
                                                  throughput: controller.throughput.averages),
                    elapsed: controller.stats.elapsed,
                    sampleCount: controller.stats.sampleCount,
                    failureCount: controller.stats.failureCount,
                    lostCount: controller.stats.summary.noReplyCount,
                    lateCount: controller.stats.summary.lateCount,
                    underLoadCount: controller.stats.summary.failuresUnderLoad,
                    status: statusChip,
                    onShowFailures: { sheet = .failures }
                )
                if case .error(let message) = controller.state {
                    ErrorBanner(message: message) { controller.start(settings: settings) }
                }
            }
        } content: {
            SummaryCards(
                latency: controller.stats.summary,
                // The session's resolved hosts, not the settings — see
                // `MonitorController.probedHosts`.
                routerHost: controller.probedHosts?.router ?? settings.routerHost,
                internetHost: controller.probedHosts?.internet ?? settings.internetHost,
                throughput: controller.throughput.averages,
                diagnostics: controller.diagnostics.latest,
                traffic: controller.traffic.captures,
                isCapturingTraffic: controller.traffic.isCapturing,
                showsGateway: controller.wan.isActive,
                gatewayRadio: controller.wan.radio,
                gatewayProblem: controller.wan.latest?.failure?.description,
                isTesting: controller.throughput.isTesting,
                testingPhase: controller.throughput.phase,
                onRunTest: { controller.runThroughputTestNow() },
                onSelect: { sheet = $0 }
            )
            // CHART DISABLED — the other half of the switch:
            // ChartPanel(
            //     series: controller.chart.series,
            //     routerHost: controller.probedHosts?.router ?? settings.routerHost,
            //     internetHost: controller.probedHosts?.internet ?? settings.internetHost,
            //     range: controller.chart.range,
            //     onRange: { controller.chart.setRange($0) }
            // )
        } log: {
            // A presented sheet covers the log completely, and SwiftUI keeps
            // updating the view behind it — so a 300-row `Table` was being
            // rebuilt once a second for pixels nobody can see, on the same main
            // thread the sheet needs to animate and respond.
            //
            // Measured: main-thread stalls of 100–655 ms, every burst of them
            // during sheet activity, growing with the row count until the log's
            // 5-minute window fills at 300 rows and they plateau.
            if sheet == nil {
                SamplesTable(
                    title: "Live ping log",
                    rows: controller.log.rows,
                    footnote: "last 5 minutes"
                )
            } else {
                Color.clear
            }
        }
        .animation(.default, value: controller.state)
    }

    private var verdict: SessionVerdict {
        SessionVerdict.evaluate(summary: controller.stats.summary,
                                throughput: controller.throughput.averages)
    }

    private var statusChip: SessionVerdictHeader.StatusChip? {
        switch controller.state {
        case .idle:     return .init(text: "Idle", color: .secondary)
        case .starting: return .init(text: "Starting…", color: Palette.warn)
        // No chip while running: the sidebar's Monitor row carries the live
        // badge now, and it stays visible while you read a different log.
        // `starting` and `error` keep theirs — they are transient states you
        // only care about on this screen.
        case .running:  return nil
        case .error(let message):
            return .init(text: "Error", color: Palette.critical, help: message)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // CHART DISABLED — restore with DetailMode.selectable.
        // ToolbarItem(placement: .principal) {
        //     ModePicker(mode: $mode)
        // }

        // Export first, run control last, so the primary action sits in the
        // corner. No `ToolbarSpacer` between them: the saved-session toolbar
        // has none, and the extra gap made the two screens look like they had
        // different toolbars.
        ToolbarItem {
            ExportButton(store: controller.store, sessionID: controller.session?.id)
        }
        ToolbarItem {
            Button {
                // Stopping reloads via `onSessionStopped`, once the row is
                // actually written; starting needs an immediate reload so the
                // new session appears in the sidebar.
                let wasRunning = controller.isRunning
                controller.toggle(settings: settings)
                if !wasRunning { onSessionEnd() }
            } label: {
                Label(controller.isRunning ? "Stop" : "Start",
                      systemImage: controller.isRunning ? "stop.fill" : "play.fill")
                    // Morphs one glyph into the other rather than swapping
                    // them. Needs an animation on the same value to drive it.
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            // Green to begin, red to end — the one control in the app whose
            // two states do opposite things, so it should not look identical
            // in both.
            .buttonStyle(.borderedProminent)
            .tint(controller.isRunning ? Palette.critical : Palette.good)
            .animation(.smooth(duration: 0.25), value: controller.isRunning)
            .keyboardShortcut(controller.isRunning ? "." : "r", modifiers: .command)
        }
    }


}

/// Summary / Chart switch. Icon-only so it survives a narrow toolbar.
struct ModePicker: View {
    @Binding var mode: DetailMode

    var body: some View {
        Picker("View", selection: $mode) {
            ForEach(DetailMode.allCases) { mode in
                Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .help("Switch between the summary and the latency chart (⌘1 / ⌘2)")
    }
}
