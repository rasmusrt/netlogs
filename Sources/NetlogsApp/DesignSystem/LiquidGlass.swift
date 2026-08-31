import SwiftUI

/// Every `#available(macOS 26, *)` in the app lives in this file.
///
/// The app compiles against the macOS 26 SDK, so standard AppKit and SwiftUI
/// chrome — window, sidebar, toolbar, sheets, controls — already adopts the
/// Tahoe appearance automatically on Tahoe, with no code. What does *not* come
/// for free is anything hand-rolled, which is why the redesign replaces custom
/// backgrounds with semantic ones rather than reaching for glass.
///
/// Where glass is used at all, it follows the HIG: Liquid Glass is the material
/// of the *control* layer, not the content layer. It belongs on things that
/// float above content and refract it, it must not be stacked, and it must not
/// be spread across large content areas. For Netlogs there is a sharper reason
/// than taste — the numbers *are* the product, and a monospaced latency readout
/// over a background that refracts whatever happens to be scrolled beneath it
/// is a legibility regression that changes from moment to moment. Stat cards
/// stay opaque. Glass is used for exactly one thing: the chart's floating range
/// picker.
extension View {

    /// For a control floating *over* content. Never for a card.
    @ViewBuilder
    func floatingGlass(in shape: some Shape = Capsule()) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator, lineWidth: 0.5))
        }
    }

    /// Content fades out under the toolbar instead of being cut by a rule.
    ///
    /// `.soft`, not `.hard`. Hard draws a defined edge — effectively a stroke —
    /// and was chosen back when a chart ran to the top of the scroll view and
    /// needed a clean cut. With the chart gone, the fade is both what the rest
    /// of the system does (Finder's list slides up under its toolbar) and one
    /// less line on a screen that had too many.
    @ViewBuilder
    func fadingTopScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// The standard card surface: an opaque fill and a container shape, no
    /// outline.
    ///
    /// Four outlined cards stacked above an outlined table is a lot of
    /// hairlines for a screen that is already mostly rules and numbers, and it
    /// is what made this look dated beside the prototype. The fill carries the
    /// separation on its own: `Palette.cardFill` is a *relative* fill, so a card
    /// is always one step from whatever is behind it — see the note there.
    ///
    /// The shape stays a plain `RoundedRectangle` rather than a
    /// `ConcentricRectangle`. Concentricity means tracking the container a
    /// shape is inset within, and a card floating mid-content has nothing
    /// meaningful to be concentric *to* — it would resolve against the window
    /// and drift with the window's own radius. `ConcentricRectangle` is also
    /// `Shape` but not `InsettableShape`, which rules out `containerShape`,
    /// and that is the part that pays off: it lets anything nested inside the
    /// card curve in sympathy with it.
    func cardSurface(radius: CGFloat = Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Palette.cardFill, in: shape)
            .containerShape(shape)
    }

    /// Attaches a tooltip only when there is one.
    ///
    /// `.help("")` still installs a tooltip — an empty one — which suppresses
    /// whatever an ancestor would otherwise have shown. Passing an optional
    /// straight into `.help` therefore silently turned neighbouring tooltips
    /// off.
    @ViewBuilder
    func helpIfPresent(_ text: String?) -> some View {
        if let text, !text.isEmpty { help(text) } else { self }
    }

}
