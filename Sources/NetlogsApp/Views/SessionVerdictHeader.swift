import SwiftUI
import NetlogsCore

/// The line that answers the question the app exists to answer.
///
/// Deliberately plain-language: "Connection healthy", "Dropping packets". The
/// counters underneath are context, not findings, so they stay small — the old
/// header gave "elapsed" the same weight as "failures", which made how long it
/// had been running look as important as whether anything was wrong.
///
/// Takes plain values rather than a view model, so the live screen and the
/// saved screen render it from the same code without either being able to
/// invalidate the other's observations (plan §8.2).
struct SessionVerdictHeader: View {
    let verdict: SessionVerdict
    let reason: String
    let elapsed: TimeInterval
    let sampleCount: Int
    let failureCount: Int
    /// Of `failureCount`, the ones where nothing came back at all. This is what
    /// the header counts, because "lost" has to mean lost — see
    /// ``LiveSummary/noReplyCount``. Defaults to `failureCount` so a caller
    /// that has not been updated keeps the old, conservative behaviour rather
    /// than silently reporting zero loss.
    var lostCount: Int?
    /// Of `failureCount`, the ones a host answered late.
    var lateCount: Int = 0
    /// Of `failureCount`, the ones measured while the app's own speed test was
    /// loading the link.
    var underLoadCount: Int = 0
    var status: StatusChip?
    /// Set to make the failure count a button. The failures sheet is the only
    /// place that lists them, so this is its entry point.
    var onShowFailures: (() -> Void)?

    struct StatusChip {
        let text: String
        let color: Color
        var help: String?
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Image(systemName: verdict.systemImage)
                .font(.title3)
                .foregroundStyle(Palette.verdict(verdict))
                .accessibilityHidden(true)

            // The verdict is the one thing that must survive a narrow window,
            // so it takes layout priority. Without it the HStack shared width
            // evenly, the headline had nowhere to go, and "Measuring…" came out
            // hyphenated across three lines.
            VStack(alignment: .leading, spacing: 1) {
                Text(verdict.headline)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(2)

            Spacer(minLength: Space.s)

            vitals
                .layoutPriority(1)

            if let status {
                StatusBadge(text: status.text, color: status.color, size: .small)
                    .fixedSize()
                    .layoutPriority(3)
                    .helpIfPresent(status.help)
            }
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(verdict.headline). \(reason)"))
    }

    /// Sheds detail before the verdict does — the headline is what has to
    /// survive at quarter width.
    ///
    /// `fixedSize` goes on each candidate, not on the `ViewThatFits`. Putting
    /// it outside proposes an unbounded width to the candidates, so the widest
    /// one always "fit" and the whole mechanism did nothing — the vitals took
    /// their full width and truncated the headline to "Me…" instead.
    private var vitals: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) {
                vital(Fmt.clock(elapsed), "elapsed")
                dot
                vital(sampleCount.formatted(), "samples")
                dot
                failuresVital(lost == 1 ? "lost" : "lost")
            }
            .fixedSize()

            HStack(spacing: Space.s) {
                vital(Fmt.clock(elapsed), "elapsed")
                dot
                failuresVital("lost")
            }
            .fixedSize()

            failuresVital("lost").fixedSize()

            EmptyView()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var dot: some View { Text("·").foregroundStyle(.quaternary) }

    /// Packets that never came back. Falls back to every failure when the
    /// caller has not supplied the split.
    private var lost: Int { lostCount ?? failureCount }

    /// Spells out what the headline number leaves out. Both of these read as
    /// loss in the old header, and neither is: a late reply is a slow link, and
    /// a failure under load is one this app caused by saturating the uplink to
    /// measure it.
    private var breakdown: String {
        var parts = ["Show every failed ping with its timestamp"]
        if lateCount > 0 {
            parts.append("\(lateCount) more replied after the timeout — slow, not lost")
        }
        if underLoadCount > 0 {
            parts.append("\(underLoadCount) happened during a speed test")
        }
        return parts.joined(separator: ". ")
    }

    /// Clickable when there is something to show, plain text otherwise — a
    /// button that opens an empty sheet is worse than no button.
    @ViewBuilder
    private func failuresVital(_ label: String) -> some View {
        // Tinted on real loss only. A session whose every "failure" was a late
        // reply is a slow session, not a broken one, and painting the count red
        // is the same overstatement in colour that the word "lost" was in text.
        let tint: Color? = lost > 0 ? Palette.bad : nil
        if let onShowFailures, failureCount > 0 {
            Button(action: onShowFailures) {
                HStack(spacing: Space.xs) {
                    Text(lost.formatted()).monospacedDigit().foregroundStyle(tint ?? .primary)
                    Text(label)
                    if lateCount > 0 {
                        Text("+\(lateCount) slow")
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(breakdown)
        } else {
            vital(lost.formatted(), label, tint: tint)
        }
    }

    private func vital(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        HStack(spacing: Space.xs) {
            Text(value).monospacedDigit().foregroundStyle(tint ?? .primary)
            if !label.isEmpty { Text(label) }
        }
    }
}
