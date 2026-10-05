import SwiftUI
import NetlogsCore

/// One row per target: the median score, what limits it, and the four
/// components behind it.
///
/// Never one number for the range. The database mixes internet hosts and
/// gateways, and a figure averaging those describes no connection that exists —
/// so a group is a target, and its median always carries the count it is the
/// median of.
struct ScoreStrip: View {
    let group: TargetGroup

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(group.key.internetHost)
                    .font(.headline)
                Text("via \(group.key.routerHost)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.m)
                Text(scopeLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // `.lastTextBaseline`, not `.first`: a MetricView stacks its label
            // above its value, so aligning on the first baseline put this
            // sentence beside the word "typical" instead of beside the number
            // it describes.
            HStack(alignment: .lastTextBaseline, spacing: Space.l) {
                MetricView("typical", group.medianScore.map(String.init), prominent: true)
                    .fixedSize()
                Text(limitLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if !componentMedians.isEmpty {
                // Fixed-width slots, not `gap` alone. The four labels are
                // different lengths, so spacing them evenly left the values
                // reading as a jumble rather than as a row of columns — the
                // same rule the repeated-row note in the design system draws.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(componentMedians, id: \.kind) { entry in
                        MetricView(entry.kind.rawValue, "\(entry.value)")
                            .frame(width: 96, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardFill, in: RoundedRectangle(cornerRadius: Radius.card,
                                                           style: .continuous))
    }

    private var scopeLine: String {
        let days = group.distinctDays()
        let count = group.sessions.count
        return "\(count) session\(count == 1 ? "" : "s") · "
            + "\(days) day\(days == 1 ? "" : "s") · "
            + Fmt.duration(group.measuredSpan) + " measured"
    }

    /// "limited by bufferbloat in 7 of 9" — the actionable headline, and the
    /// bridge from a number to a finding. Says nothing when nothing limits:
    /// something is always the lowest component, and naming it regardless
    /// reads as a fault where there is none.
    private var limitLine: String {
        let scored = group.scores.count
        guard scored > 0 else { return "not enough measured to score" }
        let tally = group.constraintTally
        guard let worst = tally.first else {
            return "nothing limiting in \(scored) scored session\(scored == 1 ? "" : "s")"
        }
        return "limited by \(worst.kind.rawValue) in \(worst.count) of \(scored)"
    }

    /// The median of each component across the group's scored sessions, so the
    /// four numbers under the headline describe the same set it does.
    private var componentMedians: [(kind: ScoreComponentKind, value: Int)] {
        ScoreComponentKind.allCases.compactMap { kind in
            let values = group.scores
                .compactMap { $0.components.first { $0.kind == kind }?.value }
                .sorted()
            guard !values.isEmpty else { return nil }
            return (kind: kind, value: values[values.count / 2])
        }
    }
}
