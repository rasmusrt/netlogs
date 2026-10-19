import SwiftUI

/// What a view that loads its content is currently able to show.
///
/// The saved-session screen kept this as an optional plus a `failedToLoad`
/// flag, the sheets as an optional plus `isLoading`, and Analysis as a result
/// plus a model flag — three spellings of the same three states, each with its
/// own spinner. Putting them in one enum means a screen cannot be "loading"
/// and "failed" at once, and cannot forget to handle one of them.
enum LoadState<Value> {
    case loading
    case loaded(Value)
    /// Nothing to show, for a reason worth saying: empty, deleted, failed.
    case unavailable(EmptyState)
}

/// Draws a ``LoadState``: the spinner, the content, or the empty state.
///
/// ```swift
/// LoadStateView(state) { detail in
///     SessionScaffold(…)
/// }
/// ```
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    var placement: LoadingView.Placement = .fill
    @ViewBuilder let content: (Value) -> Content

    init(_ state: LoadState<Value>,
         placement: LoadingView.Placement = .fill,
         @ViewBuilder content: @escaping (Value) -> Content) {
        self.state = state
        self.placement = placement
        self.content = content
    }

    var body: some View {
        switch state {
        case .loading:
            LoadingView(placement: placement)
        case .loaded(let value):
            content(value)
        case .unavailable(let empty):
            empty
        }
    }
}

/// The one spinner.
///
/// Small, centred, and late: it waits a quarter of a second before appearing,
/// because almost every load in this app finishes sooner than that, and a
/// spinner that flashes for a frame reads as a glitch rather than as progress.
struct LoadingView: View {
    var label = "Loading"
    var placement: Placement = .fill
    /// How long to wait before showing anything.
    var delay: Duration = .milliseconds(250)

    @State private var visible = false

    enum Placement {
        /// Takes the whole space it is given — a screen or a sheet body.
        case fill
        /// Sits at the top of a scrolling column.
        case inline
    }

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(visible ? 1 : 0)
            .accessibilityLabel(Text(label))
            .accessibilityHidden(!visible)
            .modifier(PlacementFrame(placement: placement))
            .task {
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
                visible = true
            }
    }

    private struct PlacementFrame: ViewModifier {
        let placement: Placement

        func body(content: Content) -> some View {
            switch placement {
            case .fill:
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .inline:
                content
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, Space.xl)
            }
        }
    }
}

/// An empty, missing or failed state: a symbol, a short title, and one
/// sentence saying why or what to do next.
///
/// A value as well as a view, so a ``LoadState`` can carry one. The copy rule
/// is the system's: the title says what is missing ("No tests yet"), the
/// message says how to get it ("Tests run on the interval set in Settings").
struct EmptyState: View {
    let title: String
    let systemImage: String
    var message: String?

    init(_ title: String, systemImage: String, message: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
    }
}

/// The one empty-state treatment used inside a card or inspector section.
///
/// The small sibling of ``EmptyState``: one quiet line, for a card or a
/// section too small to hold a symbol and a title.
struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
