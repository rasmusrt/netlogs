import SwiftUI

/// The widest a screen's content grows. Past it, cards stretched across a big
/// window read as empty bands, so the content stays this wide and centred.
enum ContentWidth {
    static let max: CGFloat = 1100
}

extension View {
    /// Caps a screen's content at `ContentWidth.max` and centres it.
    func cappedContentWidth() -> some View {
        frame(maxWidth: ContentWidth.max, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Cards in rows of equal width and equal height.
///
/// As many columns as fit at `minColumnWidth`, never more than there are
/// cards. A short last row shares the full width between its cards rather
/// than leaving one at half width beside a hole, and every card in a row is
/// offered the row's height, so cards that fill their frame
/// (`cardFillsHeight`, or `maxHeight: .infinity`) line up top and bottom.
///
/// `LazyVGrid` and `ViewThatFits` both did neither: the grid kept each card at
/// its own height, and `ViewThatFits` judged by ideal widths, so a card with a
/// long row of chips made a row that fitted easily fall back to a stack.
struct CardGrid: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat = Space.s
    var maxColumns = 4
    /// Only column counts that divide the cards into full rows — four tiles
    /// as four or two by two, never three and one.
    var evenRows = false

    private func rows(count: Int, width: CGFloat) -> [Range<Int>] {
        guard count > 0 else { return [] }
        let fit = Int((width + spacing) / (minColumnWidth + spacing))
        var columns = Swift.max(1, Swift.min(fit, maxColumns, count))
        while evenRows, columns > 1, count % columns != 0 { columns -= 1 }
        return stride(from: 0, to: count, by: columns).map { $0 ..< Swift.min($0 + columns, count) }
    }

    private func columnWidth(_ row: Range<Int>, in width: CGFloat) -> CGFloat {
        (width - spacing * CGFloat(row.count - 1)) / CGFloat(row.count)
    }

    private func height(_ row: Range<Int>, width: CGFloat, subviews: Subviews) -> CGFloat {
        let column = columnWidth(row, in: width)
        return row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
            .max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (minColumnWidth + spacing) * CGFloat(subviews.count) - spacing
        let heights = rows(count: subviews.count, width: width)
            .map { height($0, width: width, subviews: subviews) }
        return CGSize(width: width,
                      height: heights.reduce(0, +) + spacing * CGFloat(Swift.max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        var y = bounds.minY
        for row in rows(count: subviews.count, width: bounds.width) {
            let column = columnWidth(row, in: bounds.width)
            let rowHeight = height(row, width: bounds.width, subviews: subviews)
            var x = bounds.minX
            for index in row {
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: column, height: rowHeight))
                x += column + spacing
            }
            y += rowHeight + spacing
        }
    }
}

/// Two cards side by side with one height, or stacked when the window is too
/// narrow for both at their minimum widths. The trailing card can be given a
/// fixed width; otherwise both share the row equally.
///
/// Decided on the width actually offered, not on ideal sizes — see `CardGrid`.
struct SplitRow: Layout {
    var minLeading: CGFloat
    var minTrailing: CGFloat
    /// When set, the trailing card is this wide and the leading one takes the rest.
    var trailingWidth: CGFloat?
    var spacing: CGFloat = Space.l

    private func widths(_ width: CGFloat) -> (CGFloat, CGFloat)? {
        let trailing = trailingWidth ?? (width - spacing) / 2
        let leading = width - spacing - trailing
        guard leading >= minLeading, trailing >= minTrailing else { return nil }
        return (leading, trailing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minLeading + spacing + (trailingWidth ?? minTrailing)
        guard subviews.count == 2 else {
            return CGSize(width: width, height: subviews.first?.sizeThatFits(.init(width: width, height: nil)).height ?? 0)
        }
        if let (leading, trailing) = widths(width) {
            let height = Swift.max(subviews[0].sizeThatFits(.init(width: leading, height: nil)).height,
                                   subviews[1].sizeThatFits(.init(width: trailing, height: nil)).height)
            return CGSize(width: width, height: height)
        }
        let heights = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: .init(width: bounds.width, height: nil))
            return
        }
        if let (leading, trailing) = widths(bounds.width) {
            let height = bounds.height
            subviews[0].place(at: bounds.origin, proposal: .init(width: leading, height: height))
            subviews[1].place(at: CGPoint(x: bounds.minX + leading + spacing, y: bounds.minY),
                              proposal: .init(width: trailing, height: height))
            return
        }
        let first = subviews[0].sizeThatFits(.init(width: bounds.width, height: nil)).height
        subviews[0].place(at: bounds.origin, proposal: .init(width: bounds.width, height: first))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + first + spacing),
                          proposal: .init(width: bounds.width, height: nil))
    }
}
