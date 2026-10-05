import Foundation
import NetlogsCore

/// `NetlogsApp --rangecheck [days]` — run the Analysis reduction over the real
/// database and print what it found.
///
/// The plan's first de-risking step, in executable form. Fixtures prove the
/// rules behave; only this proves they behave *on data nobody designed for
/// them*. It also times the queries, so the decision to defer a denormalised
/// summary table is observed rather than assumed.
///
/// Read-only, and it never writes to the database.
enum RangeCheck {
    static func runBlocking(days: Int) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        do {
            let store = try SessionStore(url: try SessionStore.defaultURL())
            let end = Date()
            let start = end.addingTimeInterval(-Double(days) * 86_400)

            let began = DispatchTime.now()
            let sessions = try store.sessionsOverlapping(start ... end)
            let ids = sessions.map(\.id)
            let aggregates = try store.pingAggregates(for: ids)
            let histograms = try store.latencyHistograms(for: ids)
            var throughput: [UUID: [ThroughputResult]] = [:]
            for id in ids { throughput[id] = (try? store.throughputResults(for: id)) ?? [] }
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds
                                   - began.uptimeNanoseconds) / 1_000_000

            let analyses = sessions.compactMap { session -> SessionAnalysis? in
                guard let aggregate = aggregates[session.id] else { return nil }
                return SessionAnalysis(session: session, aggregate: aggregate,
                                       latency: histograms[session.id] ?? LatencyHistogram(),
                                       throughput: throughput[session.id] ?? [])
            }
            let range = RangeAnalysis(
                interval: DateInterval(start: start, end: end), sessions: analyses
            )

            print("range          : last \(days) days")
            print("sessions       : \(range.sessions.count) "
                  + "(\(range.qualifying.count) qualifying, "
                  + "\(range.underCovered.count) under-covered)")
            print("samples        : \(range.totalSamples.formatted())")
            print(String(format: "queries        : %.0f ms", elapsedMs))
            print("targets        : \(range.byTarget.count)"
                  + (range.hasMixedTargets ? "  ← figures must not be pooled" : ""))

            for group in range.byTarget {
                print("\n── \(group.key.internetHost) via \(group.key.routerHost) "
                      + "─────────────────")
                let days = group.distinctDays()
                print("  sessions     : \(group.sessions.count) over "
                      + "\(days) day\(days == 1 ? "" : "s"), "
                      + Fmt.duration(group.measuredSpan) + " measured")
                if let median = group.medianScore {
                    let tally = group.constraintTally
                        .map { "\($0.kind.rawValue) \($0.count)" }.joined(separator: ", ")
                    print("  median score : \(median)"
                          + (tally.isEmpty ? "   nothing limiting" : "   limited by: \(tally)"))
                }
                for analysis in group.sessions.prefix(8) {
                    let when = analysis.session.startedAt
                        .formatted(.dateTime.month().day().hour().minute())
                    switch analysis.score {
                    case .scored(let score):
                        let limiting = score.constraint
                            .map { "limited by \($0.kind.rawValue) (\($0.label))" }
                            ?? "nothing limiting"
                        print(String(format: "  %-16@ %3d  %-34@ %d of 4 measured",
                                     when as NSString, score.value,
                                     limiting as NSString, score.components.count))
                    case .withheld(let reason):
                        print("  \(when)  withheld — \(reason.reason)")
                    }
                }
            }

            let findings = Diagnosis.findings(for: range)
            print("\n── findings (\(findings.count)) ─────────────────────────────")
            if findings.isEmpty {
                print("  none fired. With two rules shipped that is a plausible answer,")
                print("  not a broken one — see the plan's non-firing conditions.")
            }
            for finding in findings {
                print("  [\(finding.severity)] \(finding.headline)   (\(finding.side))")
                print("    \(finding.evidence.sentence)")
                if let action = finding.action { print("    → \(action)") }
            }

            // The check that matters: a rollup must not disagree with the
            // session screen about the same session.
            var mismatches = 0
            for analysis in range.qualifying.prefix(5) {
                let samples = try store.samples(for: analysis.id)
                    .filter { $0.id >= PingSample.warmupSampleCount }
                var builder = LiveSummaryBuilder()
                for sample in samples { builder.add(sample) }
                let swift = builder.summary
                let sql = analysis.aggregate
                if sql.totalSamples != swift.totalSamples
                    || sql.internetTimeouts != swift.internetTimeouts
                    || abs(sql.internet.mean - swift.internet.avg) > 1e-6 {
                    mismatches += 1
                    print("  MISMATCH on \(analysis.id): "
                          + "SQL \(sql.totalSamples)/\(sql.internetTimeouts) "
                          + "vs Swift \(swift.totalSamples)/\(swift.internetTimeouts)")
                }
            }
            print("\nagreement      : \(mismatches == 0 ? "SQL matches the Swift fold" : "\(mismatches) MISMATCHES")")
            exit(mismatches == 0 ? 0 : 1)
        } catch {
            print("rangecheck failed: \(error)")
            exit(1)
        }
    }
}
