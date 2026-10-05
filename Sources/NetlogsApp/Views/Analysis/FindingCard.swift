import SwiftUI
import NetlogsCore

/// One thing the app noticed, with the evidence under it and the action under
/// that.
///
/// The order is deliberate and is the screen's whole argument: the claim, then
/// why it is believed, then what to do. A finding that led with its advice
/// would be asking to be trusted rather than showing why it should be.
struct FindingCard: View {
    let finding: Finding
    var isFocused = false
    var onFocus: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(finding.headline)
                    .font(.headline)
                Spacer(minLength: Space.s)
                StatusBadge(text: sideLabel, color: tint, showsDot: false, size: .small)
                    .fixedSize()
            }

            Text(finding.evidence.sentence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let action = finding.action {
                Text(action)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onFocus, !finding.sessionIDs.isEmpty {
                Button(isFocused
                       ? "Show all sessions"
                       : finding.sessionIDs.count == 1
                           ? "Show the session"
                           : "Show the \(finding.sessionIDs.count) sessions",
                       action: onFocus)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.fill(tint), in: RoundedRectangle(cornerRadius: Radius.card,
                                                             style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(tint.opacity(isFocused ? 0.6 : 0.18), lineWidth: 1)
        }
    }

    private var tint: Color {
        switch finding.severity {
        case .info:     return Palette.good
        case .notice:   return Palette.warn
        case .warning:  return Palette.bad
        case .critical: return Palette.critical
        }
    }

    private var icon: String {
        switch finding.side {
        case .localLink:    return "wifi.exclamationmark"
        case .router:       return "wifi.router"
        case .internetPath: return "globe"
        case .indeterminate: return "questionmark.circle"
        }
    }

    /// Which side of the router, said in words rather than left to the icon.
    /// It is the first thing a reader wants and the thing no other tool can
    /// tell them.
    private var sideLabel: String {
        switch finding.side {
        case .localLink:     return "your Wi-Fi"
        case .router:        return "your router"
        case .internetPath:  return "upstream"
        case .indeterminate: return "unclear"
        }
    }
}
