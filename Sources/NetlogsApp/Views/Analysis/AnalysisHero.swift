import SwiftUI
import NetlogsCore

/// The answer, before any evidence: how this connection scores, in a word and
/// a sentence, and which part of the path the trouble is on.
///
/// The score is the target's median with its count beside it — never one
/// number for the range, which the plan refuses. Router health stays beside
/// the score, in the path, never inside it.
struct AnalysisHero: View {
    let group: TargetGroup?
    let findings: [Finding]
    /// Called with the sessions to light up while a part of the path is
    /// hovered, and with an empty set when the pointer leaves.
    var onHighlight: (Set<UUID>) -> Void = { _ in }

    var body: some View {
        // Always stacked. Beside the verdict the path got a third of the
        // row, and its three parts wrapped their labels into columns too
        // narrow to read; under it, each part has room for its sentence.
        VStack(spacing: Space.l) {
            verdict
            path
        }
    }

    // MARK: - Verdict

    private var issues: [Finding] { findings.filter(AnalysisFigures.isIssue) }

    private var verdict: some View {
        HStack(alignment: .center, spacing: Space.l + 4) {
            ring
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.s) {
                    if let score = group?.medianScore {
                        Text(AnalysisFigures.scoreWord(score))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AnalysisFigures.scoreTint(score))
                            .padding(.horizontal, Space.s)
                            .padding(.vertical, 2)
                            .background(Palette.fill(AnalysisFigures.scoreTint(score)),
                                        in: Capsule())
                    }
                    Text(scoreScope)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(headline)
                    .font(.verdictHeadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.l + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    private var ring: some View {
        let score = group?.medianScore
        let tint = score.map(AnalysisFigures.scoreTint) ?? .secondary
        return ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: CGFloat(score ?? 0) / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map(String.init) ?? "—")
                    .font(.title.weight(.bold).monospacedDigit())
                Text("of 100")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .accessibilityHidden(true)
    }

    /// "median of 9 scored sessions" — the count the median is of.
    private var scoreScope: String {
        guard let group else { return "" }
        let scored = group.scores.count
        guard scored > 0 else { return "not enough measured to score" }
        return "median of \(scored) scored session\(scored == 1 ? "" : "s")"
    }

    private var headline: String {
        guard let score = group?.medianScore else { return "Not enough measured yet" }
        let word = AnalysisFigures.scoreWord(score)
        switch issues.count {
        case 0:  return "\(word) overall, nothing to fix"
        case 1:  return "\(word) overall, with one thing to look at"
        default: return "\(word) overall, with \(issues.count) things to look at"
        }
    }

    /// The headlines of what fired, in the rules' own words, so the sentence
    /// can never claim something no rule found.
    private var sentence: String {
        if issues.isEmpty {
            if let healthy = findings.first(where: { $0.rule == .healthy }) {
                return healthy.evidence.sentence
            }
            return "Nothing worth reporting across these sessions."
        }
        let wifiFine = !issues.contains { $0.side == .localLink }
        let lead = wifiFine ? "Your Wi-Fi looks fine. " : ""
        let named = issues.prefix(2).map(\.headline).joined(separator: ", and ")
        return lead + named + "."
    }

    // MARK: - Path

    private var path: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Where the trouble is")
                .font(.headline)
            HStack(spacing: Space.xs) {
                node("laptopcomputer", ring: nil)
                link(.localLink)
                node("wifi.router", ring: tint(for: .router))
                link(.internetPath)
                node("globe", ring: nil)
            }
            .padding(.horizontal, Space.xs)
            HStack(alignment: .top, spacing: Space.s) {
                ForEach([Finding.Side.localLink, .router, .internetPath], id: \.self) { side in
                    sideSummary(side)
                }
            }
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
    }

    private func node(_ symbol: String, ring: Color?) -> some View {
        Image(systemName: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 32)
            .background(.quinary, in: Circle())
            .overlay(Circle().strokeBorder(ring ?? Color.secondary.opacity(0.4),
                                           lineWidth: ring == nil ? 1.5 : 3))
            .accessibilityHidden(true)
    }

    private func link(_ side: Finding.Side) -> some View {
        Capsule()
            .fill(tint(for: side))
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func sideSummary(_ side: Finding.Side) -> some View {
        let mine = issues.filter { $0.side == side }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.xs) {
                Circle().fill(tint(for: side)).frame(width: 7, height: 7)
                Text(AnalysisFigures.sideLabel(side))
                    .font(.caption.weight(.semibold))
            }
            Text(mine.first?.headline ?? "No problems found")
                .font(.caption)
                .foregroundStyle(mine.isEmpty ? AnyShapeStyle(.secondary)
                                              : AnyShapeStyle(tint(for: side)))
                .fixedSize(horizontal: false, vertical: true)
            if mine.count > 1 {
                Text("and \(mine.count - 1) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Space.xs + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { inside in
            onHighlight(inside ? Set(mine.flatMap(\.sessionIDs)) : [])
        }
        .accessibilityElement(children: .combine)
    }

    /// The worst issue on that side decides its colour; none is good.
    private func tint(for side: Finding.Side) -> Color {
        let worst = issues.filter { $0.side == side }.map(\.severity).max()
        switch worst {
        case nil:       return Palette.good
        case .info?:    return Palette.good
        case .notice?:  return Palette.warn
        case .warning?: return Palette.bad
        case .critical?: return Palette.critical
        }
    }
}
