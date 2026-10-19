import SwiftUI
import NetlogsCore

/// "A new version is out", at the foot of the sidebar.
///
/// The sidebar rather than a banner over the detail: it is news about the
/// app, not about the network, and it should not push a session's verdict
/// down the screen. It stays until it is acted on or put off with "Later".
struct UpdateNotice: View {
    let updater: Updater

    var body: some View {
        if let release = updater.pendingRelease {
            card(release)
        } else if updater.state == .installing {
            card(nil)
        }
    }

    private func card(_ release: AppRelease?) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label {
                Text(release.map { "Netlogs \($0.version) is available" } ?? "Installing update…")
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
            if let release {
                HStack(spacing: Space.s) {
                    Button(updater.cannotInstallReason == nil ? "Install" : "Download") {
                        updater.install(release)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Later") { updater.dismiss() }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(Space.s)
        .accessibilityElement(children: .contain)
    }
}

/// Settings → General → Updates.
struct UpdateSettingsSection: View {
    @Bindable var updater: Updater

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: updater.current.description)
            if !updater.isDevBuild {
                Toggle("Check for updates automatically", isOn: $updater.automatic)
            }
            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if updater.state == .checking || updater.state == .installing {
                    ProgressView().controlSize(.small)
                } else if case .available(let release) = updater.state {
                    Button(updater.cannotInstallReason == nil ? "Install and Relaunch" : "Download") {
                        updater.install(release)
                    }
                } else {
                    Button("Check Now") { updater.checkFromMenu() }
                }
            }
        }
    }

    private var status: String {
        switch updater.state {
        case .checking: return "Checking…"
        case .installing: return "Installing…"
        case .available(let release): return "Netlogs \(release.version) is available."
        case .upToDate: return "Netlogs is up to date."
        case .failed(let message): return message
        case .idle:
            guard let date = updater.lastChecked else { return "Not checked yet." }
            return "Last checked \(date.formatted(.relative(presentation: .named)))."
        }
    }
}
