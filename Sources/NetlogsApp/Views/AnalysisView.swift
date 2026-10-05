import SwiftUI
import NetlogsCore

/// Answer, then summary, then evidence.
///
/// The diagnosis leads because that is what a user came for: what is wrong,
/// which side of the router it is on, and what to do. The scores summarise, and
/// the table underneath is the evidence the findings cite — reachable, but not
/// the thing you have to read first.
struct AnalysisView: View {
    let store: SessionStore
    @Bindable var settings: AppSettings
    var onSelectSession: ((UUID) -> Void)?

    @State private var model = AnalysisModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                if let result = model.result, !result.isEmpty {
                    scope(result)
                    diagnosis(result)
                    scores(result)
                    spread(result)
                    hours(result)
                    evidence(result)
                } else if model.isLoading {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Space.xl)
                } else {
                    empty
                }
            }
            .padding(Space.l)
        }
        // What every other screen does, and this one was missing: content
        // fades out under the toolbar rather than sliding under it and being
        // cut by a hard edge, which put scrolled figures right behind the
        // title. See `fadingTopScrollEdge`.
        .fadingTopScrollEdge()
        .navigationTitle("Analysis")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Range", selection: $settings.analysisRange) {
                    ForEach(AnalysisRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .task(id: settings.analysisRange) {
            await model.load(store: store, range: settings.analysisRange)
        }
    }

    /// Every figure below is qualified by this line — the house rule about a
    /// figure saying what it describes, applied to a whole screen.
    private func scope(_ result: AnalysisResult) -> some View {
        let range = result.range
        return VStack(alignment: .leading, spacing: Space.xs) {
            Text(scopeSentence(range))
                .font(.callout)
                .foregroundStyle(.secondary)
            if range.hasMixedTargets {
                Text("Figures are grouped by internet host and gateway, and never "
                     + "pooled across them.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func scopeSentence(_ range: RangeAnalysis) -> String {
        let count = range.sessions.count
        var parts = ["\(count) session\(count == 1 ? "" : "s")",
                     Fmt.duration(range.measuredSpan) + " measured",
                     "\(range.totalSamples.formatted()) samples"]
        if range.byTarget.count > 1 { parts.append("\(range.byTarget.count) targets") }
        if !range.underCovered.isEmpty {
            parts.append("\(range.underCovered.count) withheld for coverage")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func diagnosis(_ result: AnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeading("What we found")
            if result.findings.isEmpty {
                // An empty list is ambiguous between "nothing wrong" and
                // "nothing computed". Saying which is the whole point.
                Text(result.range.qualifying.isEmpty
                     ? "Not enough measured to say anything yet."
                     : "Nothing worth reporting across these sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(result.findings.prefix(3)) { finding in
                FindingCard(
                    finding: finding,
                    isFocused: model.focusedSessions == Set(finding.sessionIDs),
                    onFocus: { model.focus(finding) }
                )
            }
            if result.findings.count > 3 {
                Text("\(result.findings.count - 3) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func scores(_ result: AnalysisResult) -> some View {
        if !result.range.byTarget.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeading("How each connection scores")
                ForEach(result.range.byTarget) { group in
                    ScoreStrip(group: group)
                }
            }
        }
    }

    @ViewBuilder
    private func spread(_ result: AnalysisResult) -> some View {
        let spread = SessionSpread.build(
            result.range.sessions,
            interval: result.range.interval,
            // A fifteen-minute session on a seven-day axis is otherwise a
            // zero-width rectangle that draws nothing — the one-sample outage
            // lesson, at range scale.
            minimumWidth: result.range.interval.duration / 240
        )
        if !spread.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeading("When they ran, and how they behaved")
                SessionSpreadChart(spread: spread) { onSelectSession?($0) }
                Text("Each bar is one session: the band it spent its time in "
                     + "(p50 to p95), with a mark at p99 and a coverage strip "
                     + "along the bottom. Nothing is drawn between sessions, "
                     + "because nothing was measured there.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func hours(_ result: AnalysisResult) -> some View {
        let groups = result.range.byTarget.filter { !$0.hourProfile.measuredHours.isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeading("What time of day looks like")
                ForEach(groups) { group in
                    HourOfDayChart(profile: group.hourProfile,
                                   host: group.key.internetHost)
                }
            }
        }
    }

    private func evidence(_ result: AnalysisResult) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeading("Every session in range")
            SessionComparisonTable(
                sessions: result.range.sessions,
                focused: model.focusedSessions,
                onSelect: { onSelectSession?($0) }
            )
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing recorded in this range", systemImage: "chart.bar.xaxis")
        } description: {
            Text("Record a session on the Monitor screen, or widen the range.")
        }
    }
}

/// The one heading treatment this screen uses.
struct SectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.cardTitle)
            .foregroundStyle(.secondary)
    }
}
