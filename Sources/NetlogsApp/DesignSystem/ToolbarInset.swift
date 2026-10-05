import AppKit
import SwiftUI

/// How tall the window chrome is that content scrolls underneath.
///
/// SwiftUI will not tell us. A `GeometryReader` reports `safeAreaInsets.top ==
/// 0` everywhere in a `NavigationSplitView` detail on macOS 26 — at the detail
/// root, inside the `ScrollView`, and inside a `mask` — because the toolbar
/// overlay is not a SwiftUI safe area at all. AppKit sets it on the backing
/// scroll view as a content inset, derived from the window, and SwiftUI never
/// surfaces the number.
///
/// So take it from the window, which is where it comes from:
/// `contentLayoutRect` is the part of the content view that no chrome covers,
/// and the gap above it is the inset. Reading it live rather than hard-coding
/// 52 means full screen, a hidden toolbar and any future change of toolbar
/// style stay correct for free.
struct ToolbarInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> NSView { Reader(inset: $inset) }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? Reader)?.inset = $inset
    }

    /// A zero-size view that exists only to have a `window`.
    final class Reader: NSView {
        var inset: Binding<CGFloat>

        init(inset: Binding<CGFloat>) {
            self.inset = inset
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            center.removeObserver(self)
            guard let window else { return }
            // The inset changes with the window's chrome, not its content:
            // resizing, entering and leaving full screen, and the toolbar
            // being shown or hidden from the View menu.
            for name in [NSWindow.didResizeNotification,
                         NSWindow.didEnterFullScreenNotification,
                         NSWindow.didExitFullScreenNotification] {
                center.addObserver(self, selector: #selector(measure),
                                   name: name, object: window)
            }
            measure()
        }

        /// Deferred by one runloop turn: at `viewDidMoveToWindow` the window
        /// has not laid its chrome out yet and reports a full-height
        /// `contentLayoutRect`, which would read as no inset at all.
        @objc private func measure() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, let content = window.contentView
                else { return }
                let top = content.bounds.height - window.contentLayoutRect.height
                if abs(top - inset.wrappedValue) > 0.5 { inset.wrappedValue = top }
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
