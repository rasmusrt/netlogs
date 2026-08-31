import Foundation
import NetlogsCore

/// `NetlogsApp --diag` — print a few `MacDiagnostics` snapshots so the radio
/// numbers can be eyeballed against macOS's own Wi-Fi menu (Phase 4 "done
/// when"). SSID/BSSID are not read — macOS redacts them (PHASE4-NOTES).
enum DiagCheck {
    static func runBlocking() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let provider = MacDiagnostics()

        for i in 1...3 {
            let s = provider.snapshot()
            print("── snapshot \(i) ──────────────────────────")
            print("interface : \(s.interfaceName)  (\(s.kind.rawValue))")
            print("rssi/noise: \(fmt(s.rssi)) / \(fmt(s.noise)) dBm   snr: \(fmt(s.snr)) dB")
            print("tx rate   : \(s.txRateMbps.map { String(format: "%.0f Mbps", $0) } ?? "—")")
            print("channel   : \(fmt(s.channel))  band: \(s.band ?? "—")  phy: \(s.phyMode ?? "—")")
            print("security  : \(s.security ?? "—")")
            print("ip / mask : \(s.ipAddress ?? "—") / \(s.subnetMask ?? "—")   mtu: \(fmt(s.mtu))")
            print("gateway   : \(s.gateway ?? "—")")
            print("dns       : \(s.dnsServers.isEmpty ? "—" : s.dnsServers.joined(separator: ", "))")
            if i < 3 { Thread.sleep(forTimeInterval: 3) }
        }
        exit(0)
    }

    private static func fmt(_ value: Int?) -> String { value.map(String.init) ?? "—" }
}
