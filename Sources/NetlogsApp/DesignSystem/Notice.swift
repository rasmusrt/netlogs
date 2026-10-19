import SwiftUI

/// A message about the state of things — a settings mistake, a failed check,
/// a session that stopped.
///
/// The same warning was built by hand three times: an orange
/// `exclamationmark.triangle.fill` `Label` in caption type under the host
/// fields in Settings, the same again in the gateway section, and a tinted,
/// outlined box for the session banner. None of them said "warning" to
/// VoiceOver — the triangle was the only thing that did, and it is silent.
///
/// Two styles:
/// - `.inline` sits in a form row or under the field it is about. No box; the
///   text itself carries the colour.
/// - `.banner` spans the content width above everything else, for a state that
///   affects the whole screen. It announces itself when it appears.
struct Notice<Actions: View>: View {
    let severity: Severity
    var title: String?
    let message: String
    var style: Style = .inline
    @ViewBuilder var actions: Actions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Severity {
        case info
        case warning
        case critical

        var color: Color {
            switch self {
            case .info:     return .secondary
            case .warning:  return Palette.bad
            case .critical: return Palette.critical
            }
        }

        var systemImage: String {
            switch self {
            case .info:              return "info.circle.fill"
            case .warning, .critical: return "exclamationmark.triangle.fill"
            }
        }

        /// What the icon says, for VoiceOver.
        var spoken: String {
            switch self {
            case .info:     return "Note"
            case .warning:  return "Warning"
            case .critical: return "Error"
            }
        }
    }

    enum Style {
        case inline
        case banner
    }

    init(
        _ severity: Severity,
        title: String? = nil,
        message: String,
        style: Style = .inline,
        @ViewBuilder actions: () -> Actions
    ) {
        self.severity = severity
        self.title = title
        self.message = message
        self.style = style
        self.actions = actions()
    }

    var body: some View {
        switch style {
        case .inline: inline
        case .banner: banner
        }
    }

    private var inline: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { Text(title).fontWeight(.medium) }
                    Text(message)
                        // Never truncated: in a form row the end of the
                        // sentence is usually the part that says what to do.
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                icon
            }
            .font(.caption)
            .foregroundStyle(severity.color)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(spokenText))
            actions
        }
    }

    private var banner: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            icon.foregroundStyle(severity.color)
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(.callout.weight(.medium)) }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(spokenText))
            Spacer(minLength: Space.m)
            actions
                .controlSize(.small)
        }
        .padding(Space.m)
        .background(Palette.fill(severity.color),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(severity.color.opacity(0.3), lineWidth: 1)
        }
        // Slides in from the top normally; only fades with Reduce Motion on.
        .transition(reduceMotion
                    ? AnyTransition.opacity
                    : AnyTransition.move(edge: .top).combined(with: .opacity))
        .onAppear {
            // A banner replaces content the user may have been reading, often
            // while their attention is elsewhere. Say it out loud once.
            AccessibilityNotification.Announcement(spokenText).post()
        }
    }

    private var icon: some View {
        Image(systemName: severity.systemImage)
            .accessibilityHidden(true)
    }

    /// "Warning: Both probes would ping…" — the severity in words, because
    /// the icon and the colour are the only other places it lives.
    private var spokenText: String {
        [severity.spoken, title, message]
            .compactMap { $0 }
            .joined(separator: ": ")
    }
}

extension Notice where Actions == EmptyView {
    init(_ severity: Severity, title: String? = nil, message: String,
         style: Style = .inline) {
        self.init(severity, title: title, message: message, style: style) {
            EmptyView()
        }
    }
}

/// Full-bleed banner for a session-level error.
struct ErrorBanner: View {
    let message: String
    var onRetry: () -> Void

    var body: some View {
        Notice(.critical, title: "Monitoring stopped", message: message, style: .banner) {
            Button("Retry", action: onRetry)
        }
    }
}
