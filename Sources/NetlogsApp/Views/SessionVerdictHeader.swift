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
                failuresVital(failureCount == 1 ? "failure" : "failures")
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

    /// Clickable when there is something to show, plain text otherwise — a
    /// button that opens an empty sheet is worse than no button.
    @ViewBuilder
    private func failuresVital(_ label: String) -> some View {
        let tint: Color? = failureCount > 0 ? Palette.bad : nil
        if let onShowFailures, failureCount > 0 {
            Button(action: onShowFailures) {
                HStack(spacing: Space.xs) {
                    Text(failureCount.formatted()).monospacedDigit().foregroundStyle(tint ?? .primary)
                    Text(label)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help("Show every failed ping with its timestamp")
        } else {
            vital(failureCount.formatted(), label, tint: tint)
        }
    }

    private func vital(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        HStack(spacing: Space.xs) {
            Text(value).monospacedDigit().foregroundStyle(tint ?? .primary)
            if !label.isEmpty { Text(label) }
        }
    }
}
