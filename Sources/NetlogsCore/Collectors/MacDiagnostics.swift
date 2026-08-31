import Foundation

#if canImport(CoreWLAN)
import CoreWLAN
import SystemConfiguration
import Darwin

/// Native diagnostics collector (plan §6.2). No shell:
///   • CoreWLAN            — RSSI, noise, tx rate, channel, band, PHY, security, SSID/BSSID
///   • SystemConfiguration — primary interface, gateway, DNS servers
///   • getifaddrs          — IPv4 address, subnet mask, MTU
///
/// Ethernet link speed / duplex (IOKit) is deferred — see `PHASE4-NOTES.md`.
public struct MacDiagnostics: DiagnosticsProvider {

    public init() {}

    /// The default IPv4 gateway, or nil when there is no usable route.
    ///
    /// Separate from `snapshot()` on purpose: resolving which address to ping
    /// should not also spin up CoreWLAN and read the whole radio state.
    public static func defaultGateway() -> String? {
        let store = SCDynamicStoreCreate(nil, "Netlogs.gateway" as CFString, nil, nil)
        return primaryIPv4(store).router
    }

    public func snapshot() -> DiagnosticsSnapshot {
        let store = SCDynamicStoreCreate(nil, "Netlogs.diagnostics" as CFString, nil, nil)
        let (primaryInterface, gateway) = Self.primaryIPv4(store)
        let dns = Self.dnsServers(store)

        let wifi = CWWiFiClient.shared().interface()
        let interfaceName = primaryInterface ?? wifi?.interfaceName ?? "en0"

        var snap = DiagnosticsSnapshot(
            interfaceName: interfaceName,
            kind: .other,
            gateway: gateway,
            dnsServers: dns
        )

        let info = Self.interfaceInfo(for: interfaceName)
        snap.ipAddress = info.ip
        snap.subnetMask = info.mask
        snap.mtu = info.mtu

        if let wifi, wifi.interfaceName == interfaceName, wifi.powerOn() {
            snap.kind = .wifi
            fillWiFi(&snap, from: wifi)
        } else if primaryInterface != nil {
            snap.kind = .ethernet
        }

        return snap
    }

    // MARK: - CoreWLAN

    private func fillWiFi(_ snap: inout DiagnosticsSnapshot, from wifi: CWInterface) {
        let rssi = wifi.rssiValue()
        let noise = wifi.noiseMeasurement()
        snap.rssi = rssi == 0 ? nil : rssi
        snap.noise = noise == 0 ? nil : noise
        if let r = snap.rssi, let n = snap.noise { snap.snr = r - n }

        let tx = wifi.transmitRate()
        snap.txRateMbps = tx > 0 ? tx : nil

        if let channel = wifi.wlanChannel() {
            snap.channel = channel.channelNumber
            snap.band = Self.bandString(channel.channelBand)
        }
        snap.phyMode = Self.phyString(wifi.activePHYMode())
        snap.security = Self.securityString(wifi.security())
        // ssid / bssid: not read — macOS 26 redacts them for unprivileged apps
        // (needs com.apple.developer.networking.wifi-info). See PHASE4-NOTES.
    }

    static func bandString(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return nil
        }
    }

    static func phyString(_ mode: CWPHYMode) -> String? {
        switch mode {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n"
        case .mode11ac: return "802.11ac"
        case .mode11ax: return "802.11ax"
        default: return nil
        }
    }

    static func securityString(_ security: CWSecurity) -> String? {
        switch security {
        case .none: return "None"
        case .WEP, .dynamicWEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA Personal"
        case .wpa2Personal: return "WPA2 Personal"
        case .wpa3Personal: return "WPA3 Personal"
        case .personal: return "Personal"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .wpa3Enterprise, .enterprise:
            return "Enterprise"
        default: return nil
        }
    }

    // MARK: - SystemConfiguration

    static func primaryIPv4(_ store: SCDynamicStore?) -> (interface: String?, router: String?) {
        guard let store,
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return (nil, nil) }
        return (dict["PrimaryInterface"] as? String, dict["Router"] as? String)
    }

    static func dnsServers(_ store: SCDynamicStore?) -> [String] {
        guard let store,
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String]
        else { return [] }
        return servers
    }

    // MARK: - getifaddrs

    static func interfaceInfo(for interface: String) -> (ip: String?, mask: String?, mtu: Int?) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return (nil, nil, nil) }
        defer { freeifaddrs(head) }

        var ip: String?
        var mask: String?
        var mtu: Int?

        var node: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = node {
            defer { node = cur.pointee.ifa_next }
            guard String(cString: cur.pointee.ifa_name) == interface else { continue }

            let family = cur.pointee.ifa_addr?.pointee.sa_family
            if family == UInt8(AF_INET), ip == nil {
                ip = cur.pointee.ifa_addr.flatMap(numericHost)
                mask = cur.pointee.ifa_netmask.flatMap(numericHost)
            } else if family == UInt8(AF_LINK), let data = cur.pointee.ifa_data {
                mtu = Int(data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
            }
        }
        return (ip, mask, mtu)
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = getnameinfo(
            sa, socklen_t(sa.pointee.sa_len),
            &buffer, socklen_t(buffer.count),
            nil, 0, NI_NUMERICHOST
        ) == 0
        guard ok else { return nil }
        return buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
    }
}

#else

/// Non-macOS stand-in so `NetlogsCore` still compiles for the Phase 9 iOS
/// viewer (which supplies no collectors).
public struct MacDiagnostics: DiagnosticsProvider {
    public init() {}
    public func snapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(interfaceName: "unknown", kind: .other)
    }
}

#endif
