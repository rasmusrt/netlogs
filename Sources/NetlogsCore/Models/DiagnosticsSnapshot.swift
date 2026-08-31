import Foundation

/// A point-in-time view of the active network interface (plan §5 / §6.2).
///
/// Wi-Fi radio fields come from CoreWLAN; IP/subnet/MTU from `getifaddrs`;
/// gateway / primary interface / DNS from SystemConfiguration. Anything that
/// can't be read is `nil`. `ssid`/`bssid` are always `nil` on macOS 26 —
/// unprivileged apps can't read them (PHASE4-NOTES); the fields stay for the
/// wire format and a possible future `wifi-info`-entitled build.
public struct DiagnosticsSnapshot: Codable, Sendable, Equatable {

    public enum Kind: String, Codable, Sendable {
        case wifi, ethernet, other
    }

    public var timestamp: Date
    public var interfaceName: String
    public var kind: Kind

    // Wi-Fi radio (dBm for rssi/noise; snr is rssi − noise)
    public var rssi: Int?
    public var noise: Int?
    public var snr: Int?
    public var txRateMbps: Double?
    public var channel: Int?
    public var band: String?
    public var phyMode: String?
    public var security: String?
    public var ssid: String?
    public var bssid: String?

    // Ethernet (IOKit — deferred in Phase 4, see PHASE4-NOTES)
    public var linkSpeedMbps: Int?
    public var duplex: String?

    // Common
    public var ipAddress: String?
    public var subnetMask: String?
    public var gateway: String?
    public var dnsServers: [String]
    public var mtu: Int?

    public init(
        timestamp: Date = Date(),
        interfaceName: String,
        kind: Kind,
        rssi: Int? = nil,
        noise: Int? = nil,
        snr: Int? = nil,
        txRateMbps: Double? = nil,
        channel: Int? = nil,
        band: String? = nil,
        phyMode: String? = nil,
        security: String? = nil,
        ssid: String? = nil,
        bssid: String? = nil,
        linkSpeedMbps: Int? = nil,
        duplex: String? = nil,
        ipAddress: String? = nil,
        subnetMask: String? = nil,
        gateway: String? = nil,
        dnsServers: [String] = [],
        mtu: Int? = nil
    ) {
        self.timestamp = timestamp
        self.interfaceName = interfaceName
        self.kind = kind
        self.rssi = rssi
        self.noise = noise
        self.snr = snr
        self.txRateMbps = txRateMbps
        self.channel = channel
        self.band = band
        self.phyMode = phyMode
        self.security = security
        self.ssid = ssid
        self.bssid = bssid
        self.linkSpeedMbps = linkSpeedMbps
        self.duplex = duplex
        self.ipAddress = ipAddress
        self.subnetMask = subnetMask
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.mtu = mtu
    }

    /// The fields that make two snapshots "the same connection". Excludes
    /// `timestamp` and the continuously-varying radio metrics (`rssi`, `noise`,
    /// `snr`, `txRateMbps`) — those drive running stats, not new stored rows
    /// (plan §6.2).
    public var stableSignature: String {
        [
            interfaceName, kind.rawValue,
            channel.map(String.init) ?? "-",
            band ?? "-", phyMode ?? "-", security ?? "-",
            ssid ?? "-", bssid ?? "-",
            linkSpeedMbps.map(String.init) ?? "-", duplex ?? "-",
            ipAddress ?? "-", subnetMask ?? "-", gateway ?? "-",
            dnsServers.sorted().joined(separator: ","),
            mtu.map(String.init) ?? "-",
        ].joined(separator: "|")
    }
}
