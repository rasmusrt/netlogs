import SwiftUI

/// The spacing rhythm.
///
/// Before Phase 9 the app used sixteen distinct spacing values
/// (0,1,2,3,4,5,6,8,10,12,14,16,18,20,24,28) with no relationship between them.
/// Everything now lands on this five-step scale.
enum Space {
    /// Between a label and the value it labels.
    static let xs: CGFloat = 4
    /// Between related items inside a group.
    static let s: CGFloat = 8
    /// Between groups inside a card.
    static let m: CGFloat = 12
    /// Card padding, and the gap between cards.
    static let l: CGFloat = 16
    /// Between major regions of a screen.
    static let xl: CGFloat = 24
}

enum Radius {
    static let card: CGFloat = 10
    static let control: CGFloat = 6
}

/// The type roles.
///
/// There were previously four different sizes for the same kind of content —
/// `.title` on the bufferbloat card, `.title2` in the session header, `.title2`
/// again in the saved-session view, `.title3` on every other metric — with no
/// rule for choosing between them. There are now two: `metricValue` for numbers
/// inside a card, and `metricValueLarge` for the one or two numbers that lead a
/// screen.
extension Font {
    /// Numbers inside a card.
    static let metricValue = Font.title3.weight(.semibold).monospacedDigit()
    /// Numbers that lead a screen.
    static let metricValueLarge = Font.title2.weight(.semibold).monospacedDigit()
    /// The caption above a number, and its unit.
    static let metricLabel = Font.caption2
    /// A card's own title.
    static let cardTitle = Font.caption.weight(.medium)
    /// The verdict line.
    static let verdictHeadline = Font.title2.weight(.semibold)
    /// Table cells and anything else that must align in a column.
    static let tabular = Font.callout.monospacedDigit()
    static let tabularSmall = Font.caption.monospacedDigit()
}
