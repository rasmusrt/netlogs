import SwiftUI

/// The one pill.
///
/// There were two before, unrelated: the session-header badge (10/5 padding, a
/// tinted fill, a leading dot) and the diagnostics chip (6/2 padding, a
/// `.quaternary` fill, no dot). They are the same object at two sizes.
struct StatusBadge: View {
    let text: String
    var color: Color = .secondary
    var showsDot = true
    var size: Size = .regular
    var filled = true

    enum Size {
        case regular
        case small

        var font: Font {
            switch self {
            case .regular: return .callout.weight(.medium)
            case .small:   return .caption2
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: return Space.s + 2
            case .small:   return Space.s - 2
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .regular: return Space.xs + 1
            case .small:   return 2
            }
        }

        var dot: CGFloat {
            switch self {
            case .regular: return 8
            case .small:   return 6
            }
        }
    }

    var body: some View {
        HStack(spacing: Space.xs + 2) {
            if showsDot {
                Circle()
                    .fill(color)
                    .frame(width: size.dot, height: size.dot)
            }
            Text(text).font(size.font).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .background(fill, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var fill: AnyShapeStyle {
        guard filled else { return AnyShapeStyle(.clear) }
        return color == .secondary
            ? AnyShapeStyle(.quaternary)
            : AnyShapeStyle(Palette.fill(color))
    }
}

/// A neutral chip for reference facts — radio band, channel, security mode.
/// No dot, no status meaning.
struct Chip: View {
    let text: String

    var body: some View {
        StatusBadge(text: text, showsDot: false, size: .small)
    }
}
