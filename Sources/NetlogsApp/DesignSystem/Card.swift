import SwiftUI

/// One full-width card: icon, uppercase title, optional subtitle, a chevron
/// when it leads somewhere, and a row of values underneath.
///
/// Opening a card is not this view's job — see `tappable` in `SummaryCards`,
/// which adds the hover ring, the button trait and the VoiceOver action.
struct SummaryCard<Content: View>: View {
    let title: String
    let systemImage: String
    var subtitle: String?
    var accessory: AnyView?
    var showsChevron = true
    /// Explains what the card measures. Attached to the title row, which is the
    /// part you hover when you are asking "what is this card?".
    var help: String?
    @ViewBuilder var content: Content
    @Environment(\.cardFillsHeight) private var fillsHeight

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.s) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                    .helpIfPresent(help)
                    // Spoken as typed, not letter by letter as an acronym
                    // the way VoiceOver can read a short uppercase word.
                    .accessibilityLabel(Text(title))
                    // So the rotor's Headings list walks card by card.
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Truncated in the middle to fit; the tooltip and
                        // VoiceOver still get the whole host name.
                        .help(subtitle)
                }
                Spacer(minLength: Space.s)
                accessory
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.quaternary)
                        .accessibilityHidden(true)
                }
            }
            content
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s + 2)
        .frame(maxWidth: .infinity,
               maxHeight: fillsHeight ? .infinity : nil,
               alignment: .topLeading)
        .cardSurface()
    }
}

/// Set on a row of cards that should share one height. The surface is drawn
/// inside the card, so stretching the card from outside would stretch an
/// invisible frame and leave the backgrounds at their own heights.
private struct CardFillsHeightKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cardFillsHeight: Bool {
        get { self[CardFillsHeightKey.self] }
        set { self[CardFillsHeightKey.self] = newValue }
    }
}
