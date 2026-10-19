import SwiftUI
import NetlogsCore

/// The answer, then the figures, then the evidence.
///
/// Top to bottom: how this connection scores and where the trouble is; the
/// four figures behind the score, which double as the chart's picker; every
/// session as a bar you can hover and open; what the rules found next to when
/// in the week it happens; and the table the findings cite.
///
/// One target at a time. The range can mix internet hosts and gateways, and a
/// figure pooled across them describes no connection that exists, so with
/// mixed targets a picker in the toolbar switches between them.
struct AnalysisView: View {
    let store: SessionStore
    @Bindable var settings: AppSettings
    var onSelectSession: ((UUID) -> Void)?
    /// The figure to open on instead of latency. Used by `--snapshots`.
    var initialMetric: AnalysisMetric?

    @State private var model = AnalysisModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                if let result = model.result, !result.isEmpty {
                    content(result)
                } else if model.isLoading {
                    LoadingView(label: "Loading analysis", placement: .inline)
                } else {
                    empty
                }
            }
            .cappedContentWidth()
            .padding(Space.l)
        }
        // Content fades out under the toolbar rather than being cut by a hard
        // edge. See `fadingTopScrollEdge`.
        .fadingTopScrollEdge()
        .navigationTitle("Analysis")
        .toolbar {
            if let result = model.result, result.range.byTarget.count > 1 {
                ToolbarItem(placement: .navigation) {
                    targetPicker(result)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Range", selection: $settings.analysisRange) {
                    ForEach(AnalysisRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .onAppear {
            if let initialMetric { model.metric = initialMetric }
        }
        .task(id: settings.analysisRange) {
            await model.load(store: store, range: settings.analysisRange)
        }
    }

    @ViewBuilder
    private func content(_ result: AnalysisResult) -> some View {
        let sessions = model.sessions(in: result)
        let findings = model.findings(in: result)

        scope(result, sessions: sessions)

        AnalysisHero(group: model.group(in: result), findings: findings) { ids in
            model.highlighted = ids
        }

        MetricTiles(sessions: sessions, selection: $model.metric)

        SessionBarsChart(
            sessions: sessions,
            interval: result.range.interval,
            metric: model.metric,
            highlighted: model.highlighted,
            hourly: result.range.hourlyBuckets,
            hourlyStats: result.range.hourlyPingStats,
            onSelect: { onSelectSession?($0) }
        )

        // Beside the heatmap only when there is something to read. With
        // nothing to act on the list is one line, and stretched to the
        // heatmap's height it read as an empty box; stacked, it stays short.
        if findings.contains(where: AnalysisFigures.isIssue) {
            SplitRow(minLeading: 340, minTrailing: 420) {
                findingList(findings)
                WeekHourHeatmap(grid: model.weekGrid(in: result))
            }
        } else {
            findingList(findings)
            WeekHourHeatmap(grid: model.weekGrid(in: result))
        }

        evidence(sessions)
    }

    private func findingList(_ findings: [Finding]) -> some View {
        FindingList(
            findings: findings,
            focusedSessions: model.focusedSessions,
            onHighlight: { model.highlighted = $0 },
            onFocus: { model.focus($0) }
        )
    }

    // MARK: - Scope

    /// Every figure below is qualified by this line — the house rule about a
    /// figure saying what it describes, applied to a whole screen.
    private func scope(_ result: AnalysisResult, sessions: [SessionAnalysis]) -> some View {
        let withheld = sessions.filter { $0.score.score == nil }.count
        let span = sessions.reduce(0) { $0 + $1.aggregate.measuredSpan }
        var parts = ["\(sessions.count) session\(sessions.count == 1 ? "" : "s")",
                     Fmt.duration(span) + " measured"]
        if withheld > 0 { parts.append("\(withheld) not scored") }
        if let key = model.group(in: result)?.key {
            parts.append("\(key.internetHost) via \(key.routerHost)")
        }
        return Text(parts.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private func targetPicker(_ result: AnalysisResult) -> some View {
        Picker("Target", selection: Binding(
            get: { model.group(in: result)?.key },
            set: { model.selectedTarget = $0; model.highlighted = [] }
        )) {
            ForEach(result.range.byTarget) { group in
                Text("\(group.key.internetHost) via \(group.key.routerHost)")
                    .tag(Optional(group.key))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Figures are never pooled across internet hosts or gateways.")
    }

    // MARK: - Evidence

    private func evidence(_ sessions: [SessionAnalysis]) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("All sessions")
                .font(.headline)
            Text("The evidence the findings cite. Click a row to open it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SessionComparisonTable(
                sessions: sessions,
                focused: model.focusedSessions,
                onSelect: { onSelectSession?($0) }
            )
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var empty: some View {
        EmptyState("Nothing recorded in this range", systemImage: "chart.bar.xaxis",
                   message: "Record a session on the Monitor screen, or widen the range.")
    }
}
