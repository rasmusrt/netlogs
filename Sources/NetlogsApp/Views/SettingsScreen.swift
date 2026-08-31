import SwiftUI
import NetlogsCore

/// The Settings window (plan §11). Saves on change — no Save button.
struct SettingsScreen: View {
    @Bindable var settings: AppSettings
    var store: SessionStore?

    @State private var dbBytes = 0

    /// The address the router probe will actually use. With auto-detect on, a
    /// duplicate is easiest to create without noticing — the field is disabled
    /// and shows a stale value, so only the detected gateway matters.
    private var effectiveRouterHost: String {
        settings.monitor.routerHostAutomatic
            ? (detectedGateway ?? settings.monitor.routerHost)
            : settings.monitor.routerHost
    }

    /// The address both probes would go to, when that is one address.
    ///
    /// Compared as trimmed, case-insensitive text rather than resolved: a
    /// lookup per keystroke to catch what is in practice a typo is the wrong
    /// trade. Two different names for one host still slip through, and still
    /// produce the fault the warning describes.
    private var duplicateHost: String? {
        let router = effectiveRouterHost.trimmingCharacters(in: .whitespaces)
        let internet = settings.monitor.internetHost.trimmingCharacters(in: .whitespaces)
        guard !router.isEmpty, router.lowercased() == internet.lowercased() else { return nil }
        return router
    }
    /// A label, not a live readout — but re-read every time Settings appears.
    ///
    /// The seed value below is evaluated when SwiftUI first *constructs* the
    /// view, which is at launch, not when the window opens. Seen in practice:
    /// an instance that came up while the network state was briefly unreadable
    /// showed "No gateway detected" for its whole life, while
    /// `SCDynamicStoreCopyValue` returned the gateway perfectly well the entire
    /// time. The refresh also picks up a gateway that changed because the
    /// machine moved networks.
    ///
    /// It matters beyond the label: `effectiveRouterHost` falls back to the
    /// typed host whenever this is `nil`, so a stuck `nil` silently changes
    /// what the duplicate-host warning compares.
    @State private var detectedGateway: String? = MacDiagnostics.defaultGateway()

    var body: some View {
        Form {
            Section("Hosts") {
                Toggle("Detect router automatically",
                       isOn: $settings.monitor.routerHostAutomatic)
                TextField("Router", text: $settings.monitor.routerHost)
                    .disabled(settings.monitor.routerHostAutomatic)
                    .foregroundStyle(settings.monitor.routerHostAutomatic
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if settings.monitor.routerHostAutomatic {
                    Text(detectedGateway.map { "Currently \($0)" }
                         ?? "No gateway detected — the address above will be used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Internet host", text: $settings.monitor.internetHost)

                // A warning, not a rejection. The configuration is legal and
                // the app still runs; it just cannot produce a meaningful
                // reading, and the way it fails — phantom packet loss — looks
                // like a network fault rather than a settings mistake. Saying
                // so here is the cheapest place to say it.
                if let duplicateHost {
                    Label {
                        Text("Both probes would ping \(duplicateHost). They are sent "
                             + "with the same sequence number, so one overwrites the "
                             + "other and about half of every tick is logged as a "
                             + "timeout — from a host that replied.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.bad)
                }
            }

            Section("Ping") {
                Picker("Interval", selection: pingInterval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
            }

            Section("Throughput") {
                Toggle("Run periodic tests", isOn: $settings.monitor.throughputEnabled)
                Picker("Run every", selection: $settings.monitor.throughputInterval) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .disabled(!settings.monitor.throughputEnabled)
                Text("Each test transfers ~200 MB against Cloudflare's speed endpoints.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Picker("Poll interval", selection: diagInterval) {
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Storage") {
                Picker("Keep stopped sessions", selection: $settings.retentionDays) {
                    Text("Forever").tag(0)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                LabeledContent("Database size",
                               value: ByteCountFormatter.string(fromByteCount: Int64(dbBytes), countStyle: .file))
            }
        }
        .formStyle(.grouped)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
        .task { dbBytes = store?.databaseByteCount() ?? 0 }
        .onAppear { detectedGateway = MacDiagnostics.defaultGateway() }
    }

    // MARK: - Bindings that translate Duration / side effects

    private var pingInterval: Binding<Double> {
        Binding(get: { settings.monitor.pingInterval.timeInterval },
                set: { settings.monitor.pingInterval = .seconds($0) })
    }

    private var diagInterval: Binding<Double> {
        Binding(get: { settings.monitor.diagnosticsInterval.timeInterval },
                set: { settings.monitor.diagnosticsInterval = .seconds($0) })
    }
}
