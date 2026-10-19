import SwiftUI
import NetlogsCore

/// What the rules found, most important first: a headline you can act on,
/// with the evidence and the advice one click away.
///
/// The order inside an opened row is still the screen's argument from
/// the old finding cards: the claim, why it is believed, then what to do. What changed
/// is that the evidence no longer has to be read to get the claim.
struct FindingList: View {
    let findings: [Finding]
    var focusedSessions: Set<UUID> = []
    /// Lights a finding's sessions up in the chart while it is hovered.
    var onHighlight: (Set<UUID>) -> Void = { _ in }
    /// Filters the table to a finding's sessions, or back.
    var onFocus: (Finding) -> Void = { _ in }

    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("What we found")
                .font(.headline)
            if findings.isEmpty {
                empty
            } else {
                Text("Most important first. Hover one to see its sessions in the chart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(findings) { finding in
                    row(finding)
                }
            }
        }
        .padding(Space.l + 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
        .onAppear {
            if expanded == nil { expanded = findings.first(where: AnalysisFigures.isIssue)?.id }
        }
    }

    /// The card sits beside the heatmap and takes its height, so a single
    /// line at the top left a tall empty box. Centred in the space instead,
    /// it reads as a state rather than as something that failed to load.
    private var empty: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("Nothing to report yet")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Findings appear once there is enough measured to back them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
    }

    private func row(_ finding: Finding) -> some View {
        let isOpen = expanded == finding.id
        return VStack(alignment: .leading, spacing: Space.s) {
            Button {
                expanded = isOpen ? nil : finding.id
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Circle()
                        .fill(AnalysisFigures.tint(finding))
                        .frame(width: 9, height: 9)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.s) {
                            Text(finding.headline)
                                .font(.callout.weight(.semibold))
                            if finding.side != .indeterminate {
                                Chip(text: AnalysisFigures.sideLabel(finding.side))
                                    .fixedSize()
                            }
                        }
                        if !isOpen, let action = finding.action {
                            Text(action)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: Space.s)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(isOpen ? "Hides the details" : "Shows why and what to do"))

            if isOpen {
                VStack(alignment: .leading, spacing: Space.s) {
                    detail("Why we think so", finding.evidence.sentence)
                    if let action = finding.action {
                        detail("What you can do", action)
                    }
                    if !finding.sessionIDs.isEmpty {
                        let isFocused = focusedSessions == Set(finding.sessionIDs)
                        Button(isFocused
                               ? "Show all sessions in the table"
                               : finding.sessionIDs.count == 1
                                   ? "Show this session in the table"
                                   : "Show these \(finding.sessionIDs.count) sessions in the table") {
                            onFocus(finding)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .padding(.leading, 17)
            }
        }
        .padding(Space.m)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Radius.control + 2,
                                                    style: .continuous))
        .onHover { inside in
            onHighlight(inside ? Set(finding.sessionIDs) : [])
        }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
