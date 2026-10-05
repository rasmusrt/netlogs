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

    /// Content fades out under the toolbar instead of being cut by a hard
    /// edge.
    ///
    /// This is hand-rolled because the platform effect cannot be reached from
    /// here. macOS 26 draws the edge under a toolbar with an `NSScrollPocket`,
    /// and there are two of them in this window: one owned by the scroll view,
    /// which SwiftUI's `scrollEdgeEffectStyle(.soft, for: .top)` does control,
    /// and one owned by `NSTitlebarBackgroundView`, which sits on top of it,
    /// renders `NSHardPocketView`, and ignores every SwiftUI modifier —
    /// applied to the `ScrollView`, to the detail, or to the whole scene. The
    /// AppKit control for it, `preferredScrollEdgeEffectStyle`, only exists on
    /// titlebar and split-item *accessory* controllers, and a SwiftUI
    /// `NavigationSplitView` vends neither.
    ///
    /// That hard pocket is also the "1pt rule under the toolbar" that
    /// `NetlogsScene` hides the toolbar background to be rid of — it was never
    /// a titlebar separator, which is why `titlebarSeparatorStyle = .none` did
    /// nothing. Hiding the background removes the pocket, and with it the only
    /// thing that was covering scrolled content: figures ran straight into the
    /// window title at full strength. So the fade has to come from us.
    ///
    /// The band is transparent for its first two fifths and eases in after
    /// that, rather than ramping linearly from the very top: a linear fade
    /// still leaves content at half strength where the title sits, which is
    /// exactly the collision this is here to fix.
    ///
    /// For a scroll view flush with the top of the window, and nothing else:
    /// the band's height is the window's own chrome inset, so a scroll view
    /// sitting lower down would be given a fade where no toolbar covers it.
    func fadingTopScrollEdge() -> some View {
        modifier(FadingTopScrollEdge())
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

/// See `fadingTopScrollEdge()`.
private struct FadingTopScrollEdge: ViewModifier {
    /// Zero until the window has laid its chrome out, and zero forever if the
    /// reader ever fails — which masks nothing rather than masking wrongly.
    @State private var inset: CGFloat = 0

    private static let band = Gradient(stops: [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 0.42),
        .init(color: .black.opacity(0.12), location: 0.60),
        .init(color: .black.opacity(0.45), location: 0.78),
        .init(color: .black.opacity(0.85), location: 0.93),
        .init(color: .black, location: 1),
    ])

    func body(content: Content) -> some View {
        content
            // `ignoresSafeArea` is the whole trick. The `ScrollView`'s own
            // frame starts *below* the toolbar even though it draws above it,
            // so a mask laid out in that frame both cuts everything under the
            // toolbar away and puts the fade 52pt too low — visible as content
            // dissolving where it should be solid. Ignoring the safe area
            // gives the mask the drawn region rather than the laid-out one.
            .mask(alignment: .top) {
                VStack(spacing: 0) {
                    LinearGradient(gradient: Self.band,
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: inset)
                    Color.black
                }
                .ignoresSafeArea(edges: .top)
            }
            // Outside the mask, so the reader is not masked by its own
            // measurement.
            .background(ToolbarInsetReader(inset: $inset).frame(width: 0, height: 0))
    }
}
