import SwiftUI

/// The one heading treatment for a group of content: small, quiet, secondary.
///
/// The Analysis screen and every sheet each typed this out — `.cardTitle` in
/// `.secondary` — and neither told VoiceOver it was a heading, so the rotor's
/// Headings list was empty on the two screens with the most sections.
struct SectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.cardTitle)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One section treatment shared by every sheet, so they read as one surface
/// rather than four unrelated screens.
struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeading(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label on the left, a selectable figure on the right.
struct DetailRow: View {
    let label: String
    let value: String
    var tint: Color?
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.s)
            Text(value)
                .font(.tabularSmall)
                .foregroundStyle(tint ?? .primary)
                .textSelection(.enabled)
                // Long values (DNS lists, interface names) wrap rather than
                // pushing the label off the sheet.
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .helpIfPresent(help)
        // Read as one line, "MTU, 1500", not as two unrelated texts.
        .accessibilityElement(children: .combine)
    }
}

/// The rule between the summary and the log.
///
/// A plain `Divider()` uses the full-strength separator colour, which reads as
/// a hard line in dark mode where it sits against a near-black background —
/// far more prominent than the same divider looks in light. This is the same
/// colour at a weight that matches in both appearances.
struct SectionSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .opacity(0.5)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
