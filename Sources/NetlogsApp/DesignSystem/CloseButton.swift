import SwiftUI

/// A round close control, matching the one the system puts on its own sheets.
struct CloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(hovering ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary),
                            in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        // Escape already dismisses a sheet; this makes Return work too, so the
        // sheet closes on whichever key the hand reaches for first.
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Close")
        .help("Close")
    }
}
