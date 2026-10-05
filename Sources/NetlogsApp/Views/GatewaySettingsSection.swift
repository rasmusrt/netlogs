import SwiftUI
import NetlogsCore

/// Settings for reading the WAN from the gateway (Phase 14).
///
/// A guided flow rather than a list of controls, because the first version was
/// a list and its owner could not find the switch: it sat at the top while the
/// setup happened at the bottom. So the section shows one next step at a time:
/// save a key, connect, and then the switch.
///
/// **Trust on first use, like SSH.** The first version asked the user to
/// compare the certificate's SHA-256 with the one their browser shows, which is
/// buried four clicks deep and which nobody does. That check only defends
/// against an impostor on the LAN at the exact moment of first connection. The
/// defence that matters is the one after: once a certificate is remembered, a
/// different one is refused before the key is sent, and *that* is shown loudly
/// and needs an explicit decision. The fingerprint stays available under
/// Details for anyone who does want to compare it.
struct GatewaySettingsSection: View {
    @Bindable var settings: AppSettings
    /// The router a session would use: the detected gateway with auto-detect
    /// on. Not `monitor.routerHost`, which then holds a stale typed value.
    let routerHost: String

    @State private var hasKey = GatewayKeychain.hasKey
    @State private var keyDraft = ""
    @State private var working = false
    @State private var result: WANSnapshot?

    private var pinned: String? { settings.monitor.wanCertificateSHA256 }

    var body: some View {
        Section {
            if !hasKey {
                keyEntry
            } else if pinned == nil {
                connect
            } else {
                Toggle("Record 5G radio and WAN traffic during sessions",
                       isOn: $settings.monitor.wanTelemetryEnabled)
                HStack {
                    Button("Check connection") { check(trustingFirstUse: false) }
                        .disabled(working)
                    if working { ProgressView().controlSize(.small) }
                }
            }

            if let result { outcome(result) }

            DisclosureGroup("Details") { details }
        } header: {
            Text("Gateway telemetry")
        } footer: {
            Text("Reads the 5G radio and WAN counters from your UniFi gateway's local "
                 + "API. The key stays in the Keychain and is only sent to the gateway "
                 + "Netlogs first connected to. Nothing leaves your network.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Steps

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Paste the API key you created on the gateway.")
                .font(.callout)
            HStack {
                SecureField("", text: $keyDraft, prompt: Text("API key"))
                    .labelsHidden()
                Button("Save") {
                    GatewayKeychain.save(keyDraft)
                    keyDraft = ""
                    hasKey = GatewayKeychain.hasKey
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var connect: some View {
        HStack {
            Button("Connect to \(host)") { check(trustingFirstUse: true) }
                .buttonStyle(.borderedProminent)
                .disabled(working)
            if working { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private var details: some View {
        TextField("Gateway", text: gatewayHost, prompt: Text("Same as router (\(routerHost))"))
        if hasKey {
            LabeledContent("API key") {
                HStack {
                    Text("In Keychain").foregroundStyle(.secondary).fixedSize()
                    Button("Remove") {
                        GatewayKeychain.delete()
                        hasKey = GatewayKeychain.hasKey
                        settings.monitor.wanTelemetryEnabled = false
                        result = nil
                    }
                }
            }
        }
        if let pinned {
            LabeledContent("Certificate") {
                HStack {
                    Text("Remembered").foregroundStyle(.secondary).fixedSize()
                    Button("Forget") {
                        settings.monitor.wanCertificateSHA256 = nil
                        settings.monitor.wanTelemetryEnabled = false
                        result = nil
                    }
                }
            }
            Text("SHA-256 " + UniFiGateway.display(pinned))
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func outcome(_ snapshot: WANSnapshot) -> some View {
        switch snapshot.failure {
        case nil:
            Label(Self.describe(snapshot), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Palette.good)

        case .certificateChanged(let sha):
            VStack(alignment: .leading, spacing: Space.s) {
                Label("The gateway now presents a different certificate, so the key was "
                      + "not sent. That is expected after a reset or a new gateway. If "
                      + "neither happened, do not accept it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.bad)
                Text("New SHA-256 " + UniFiGateway.display(sha))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Accept the new certificate") {
                    settings.monitor.wanCertificateSHA256 = UniFiGateway.normalise(sha)
                    check(trustingFirstUse: false)
                }
            }

        case let failure?:
            Label(failure.description, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Palette.bad)
        }
    }

    // MARK: -

    private var host: String {
        let typed = settings.monitor.wanGatewayHost?.trimmingCharacters(in: .whitespaces) ?? ""
        return typed.isEmpty ? routerHost : typed
    }

    private var gatewayHost: Binding<String> {
        Binding(get: { settings.monitor.wanGatewayHost ?? "" },
                set: { settings.monitor.wanGatewayHost = $0.isEmpty ? nil : $0 })
    }

    /// Poll once. On first use, an unknown certificate is remembered and the
    /// poll repeated with the key; a working connection then turns recording
    /// on, because that is what setting it up was for.
    private func check(trustingFirstUse: Bool) {
        working = true
        let host = host
        Task {
            var pin = pinned
            if pin == nil {
                // Unpinned: learns the certificate, sends nothing.
                let probe = UniFiGateway(host: host, apiKey: nil, pinnedSHA256: nil)
                let first = await probe.poll()
                probe.close()
                guard trustingFirstUse, case .untrustedCertificate(let sha) = first.failure else {
                    result = first
                    working = false
                    return
                }
                pin = UniFiGateway.normalise(sha)
            }
            let key = await Task.detached { GatewayKeychain.read() }.value
            let gateway = UniFiGateway(host: host, apiKey: key, pinnedSHA256: pin)
            let snapshot = await gateway.poll()
            gateway.close()
            if trustingFirstUse, snapshot.failure == nil {
                settings.monitor.wanCertificateSHA256 = pin
                settings.monitor.wanTelemetryEnabled = true
            }
            result = snapshot
            working = false
        }
    }

    private static func describe(_ snapshot: WANSnapshot) -> String {
        var parts: [String] = ["Connected"]
        if let radio = snapshot.radio {
            parts.append([radio.technology, radio.band].compactMap { $0 }.joined(separator: " "))
            if let sinr = radio.nrSINR ?? radio.lteSINR {
                parts.append(String(format: "SINR %.1f dB", sinr))
            }
        } else {
            parts.append("no cellular radio on the active WAN")
        }
        if let interface = snapshot.counters?.interface { parts.append("via \(interface)") }
        return parts.joined(separator: " · ")
    }
}
