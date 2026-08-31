import Foundation
import NetlogsCore

/// `NetlogsApp --uicheck [seconds]`
///
/// Drives the real view-model pipeline — `MonitorController`, `LiveStats`,
/// `PingLog`, `DiagnosticsModel`, `ThroughputModel`, `SessionStore` — without
/// SwiftUI rendering, on a pumped main runloop. With `seconds >= 25` it also
/// fires a short throughput test. The rendered UI's smoothness is a separate
/// manual check (`Scripts/run-app.sh`).
enum UICheck {

    static func runBlocking() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let seconds = CommandLine.arguments.drop { $0 != "--uicheck" }
            .dropFirst().first.flatMap(Double.init) ?? 15

        guard let controller = MainActor.assumeIsolated({ start() }) else { exit(2) }

        if seconds >= 25 {
            RunLoop.main.run(until: Date().addingTimeInterval(6))
            MainActor.assumeIsolated {
                print("UICheck — firing a short throughput test…")
                controller.runThroughputTestNow(
                    directionDuration: .seconds(4), settle: .seconds(1), warmup: .seconds(1)
                )
            }
            RunLoop.main.run(until: Date().addingTimeInterval(seconds - 6))
        } else {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        exit(MainActor.assumeIsolated { finish(controller, ranThroughput: seconds >= 25) })
    }

    @MainActor
    private static func start() -> MonitorController? {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("netlogs-uicheck-\(UUID().uuidString).sqlite")
            let controller = MonitorController(store: try SessionStore(url: url))
            print("UICheck — starting a live session…")
            controller.start(settings: MonitorSettings(throughputEnabled: false)) // manual test only
            return controller
        } catch {
            print("UICheck FAIL — \(error)")
            return nil
        }
    }

    @MainActor
    private static func finish(_ controller: MonitorController, ranThroughput: Bool) -> Int32 {
        let stats = controller.stats
        let log = controller.log
        print("state          : \(controller.state)")
        print("stat samples   : \(stats.sampleCount)")
        print("log rows       : \(log.rows.count)")
        print("elapsed        : \(String(format: "%.0f s", stats.elapsed))")

        var persisted = 0, diagRows = 0, tpRows = 0
        if let session = controller.session {
            try? controller.store.stopSession(session.id) // flush
            persisted = (try? controller.store.sampleCount(for: session.id)) ?? 0
            diagRows = (try? controller.store.diagnosticsCount(for: session.id)) ?? 0
            tpRows = (try? controller.store.throughputCount(for: session.id)) ?? 0
        }
        print("persisted rows : \(persisted)")
        print("diag polls/rows: \(controller.diagnostics.pollCount) polled / "
              + "\(controller.diagnostics.history.count) kept / \(diagRows) stored")

        // The live chart model, driven by the same stream (Phase 9).
        let series = controller.chart.series
        let verdict = SessionVerdict.evaluate(summary: stats.summary,
                                              throughput: controller.throughput.averages)
        print("chart points   : \(series.internet.count) internet / \(series.router.count) router")
        print("chart domain   : 0…\(String(format: "%.0f", series.yDomain.upperBound)) ms"
              + "  clipped=\(series.clippedCount)")
        print("failures       : \(controller.failures.total) (log \(controller.failures.rows.count))")
        print("verdict        : \(verdict.rawValue) — "
              + SessionVerdict.reason(for: verdict, summary: stats.summary,
                                      throughput: controller.throughput.averages))

        var ok = stats.sampleCount > 3
            && log.rows.count >= stats.sampleCount
            && log.rows.count <= stats.sampleCount + 4
            && persisted >= log.rows.count - 1
            && controller.diagnostics.pollCount >= 2
            && diagRows >= 1
            && controller.state == .running
            // The chart published, stayed inside its bucket budget, and the
            // warm-up spike did not set the axis.
            && !series.isEmpty
            && series.internet.count <= 200
            && series.yDomain.upperBound >= PingChartBucketer.minimumCeilingMs
            && controller.failures.total == stats.failureCount

        if ranThroughput {
            let r = controller.throughput.latest
            print("throughput     : ↓\(r.map { String(format: "%.0f", $0.downloadMbps) } ?? "—")"
                  + " ↑\(r.map { String(format: "%.0f", $0.uploadMbps) } ?? "—") Mbps"
                  + "  bufferbloat +\(r.map { String(format: "%.0f", $0.bufferbloatMs) } ?? "—") ms"
                  + "  (\(r?.isp ?? "—") / \(r?.serverLocation ?? "—"))  rows=\(tpRows)")
            // Nullable since schema 3, so a live test has to come back with
            // both actually measured — a `nil` reaching the card as "—" here
            // would mean the engine stopped measuring, not that the history
            // predates the column.
            print("test jitter/loss: \(Fmt.msLabel(r?.idleJitterMs)) / \(Fmt.percent(r?.packetLoss))")
            // Schema 4: the spread has to arrive for the load phases too, not
            // just idle — those are the ones that used to be a bare mean.
            print("test spread     : idle \(Fmt.ms(r?.idleLowMs))–\(Fmt.ms(r?.idleHighMs))"
                  + "  down \(Fmt.ms(r?.downloadLowMs))–\(Fmt.ms(r?.downloadHighMs))"
                  + " (jitter \(Fmt.ms(r?.downloadJitterMs)))"
                  + "  up \(Fmt.ms(r?.uploadLowMs))–\(Fmt.ms(r?.uploadHighMs))")
            let loaded = Set(log.rows.map(\.phase))
            print("phases tagged  : \(loaded.map(\.rawValue).sorted())")
            // The load bands the chart draws come from the run encoder, not
            // from per-point phases — check they were actually produced.
            let bands = controller.chart.series.load
            print("load bands     : \(bands.map { "\($0.value.rawValue)×\($0.sampleCount)" })")
            ok = ok
                && r != nil
                && (r?.downloadMbps ?? 0) > 1
                && r?.idleJitterMs != nil
                && r?.packetLoss != nil
                && r?.idleLowMs != nil
                && r?.downloadLowMs != nil
                && r?.downloadHighMs != nil
                && r?.uploadLowMs != nil
                && tpRows == 1
                && loaded.contains(.downloading)
                && loaded.contains(.uploading)
                && bands.contains { $0.value == .downloading }
                && bands.contains { $0.value == .uploading }
        }

        // Detail + export from the same real session.
        if let session = controller.session,
           let stored = try? controller.store.samples(for: session.id) {
            // Mirrors DetailLoader: analysis skips the ICMP warm-up samples,
            // the export keeps everything.
            let samples = stored.filter { $0.id >= PingSample.warmupSampleCount }
            let d = DetailSummary.build(samples: samples,
                                       throughput: (try? controller.store.throughputResults(for: session.id)) ?? [],
                                       diagnostics: (try? controller.store.diagnostics(for: session.id)) ?? [])
            let chart = PingChartSeries.build(
                samples: samples,
                warmupSamplesToSkip: PingSample.warmupSampleCount
            )
            let export = SessionExport(session: session, samples: stored,
                                       throughput: (try? controller.store.throughputResults(for: session.id)) ?? [],
                                       diagnostics: (try? controller.store.diagnostics(for: session.id)) ?? [])
            let csv = SessionExporter.csv(export)
            let json = (try? SessionExporter.json(export))?.count ?? 0
            let txt = SessionExporter.text(export)
            print("detail         : router top-\(d.routerLowest.count)/\(d.routerHighest.count), "
                  + "failures \(d.failures.count), chart points \(chart.internet.count)")
            print("export sizes   : csv \(csv.count) B · json \(json) B · txt \(txt.count) B")
            ok = ok
                && !chart.isEmpty && chart.internet.count <= 200
                && csv.hasPrefix("seq,timestamp")
                && json > 0
                && txt.contains("NETLOGS SESSION REPORT")
        }

        print("\nRESULT: \(ok ? "PASS" : "FAIL")")
        return ok ? 0 : 1
    }
}
