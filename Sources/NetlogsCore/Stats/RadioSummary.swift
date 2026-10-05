import Foundation

/// What the stored Wi-Fi snapshots say about a session's radio.
///
/// Reduced from `DiagnosticsSnapshot` through its own `Codable` conformance, so
/// the Analysis screen and the Network sheet cannot read the same row
/// differently.
///
/// **Thinner than the loss half of this app, and the rules must respect that.**
/// Snapshots are written on change plus a 60 s heartbeat, so a five-second fade
/// is invisible and any correlation is at minute resolution at best. "Which
/// side of the router" is strong for loss — per second, per host — and weak for
/// signal.
public struct RadioSummary: Sendable, Equatable {
    public let readings: Int
    public let rssiMin: Int?
    public let rssiMedian: Int?
    /// Share of readings at or below ``weakRSSI``.
    public let weakFraction: Double
    public let channels: Set<Int>
    public let bands: Set<String>
    public let isWiFi: Bool

    /// −70 dBm: where 5 GHz starts shedding rate, and the same threshold
    /// `NetworkCard.rssiTint` calls bad.
    public static let weakRSSI = -70

    public init(
        readings: Int, rssiMin: Int?, rssiMedian: Int?, weakFraction: Double,
        channels: Set<Int>, bands: Set<String>, isWiFi: Bool
    ) {
        self.readings = readings
        self.rssiMin = rssiMin
        self.rssiMedian = rssiMedian
        self.weakFraction = weakFraction
        self.channels = channels
        self.bands = bands
        self.isWiFi = isWiFi
    }

    public static let empty = RadioSummary(
        readings: 0, rssiMin: nil, rssiMedian: nil, weakFraction: 0,
        channels: [], bands: [], isWiFi: false
    )

    /// True when the radio never got near trouble — the guard that stops a
    /// router which merely rate-limits pings from being reported as failing
    /// Wi-Fi.
    public var wasStrongThroughout: Bool {
        guard let min = rssiMin else { return false }
        return min > Self.weakRSSI + 3
    }

    public var changedChannel: Bool { channels.count > 1 }
    public var changedBand: Bool { bands.count > 1 }

    public static func build(_ snapshots: [DiagnosticsSnapshot]) -> RadioSummary {
        guard !snapshots.isEmpty else { return .empty }
        let rssi = snapshots.compactMap(\.rssi).sorted()
        let weak = rssi.filter { $0 <= weakRSSI }.count
        return RadioSummary(
            readings: snapshots.count,
            rssiMin: rssi.first,
            rssiMedian: rssi.isEmpty ? nil : rssi[rssi.count / 2],
            weakFraction: rssi.isEmpty ? 0 : Double(weak) / Double(rssi.count),
            channels: Set(snapshots.compactMap(\.channel)),
            bands: Set(snapshots.compactMap(\.band)),
            isWiFi: snapshots.contains { $0.kind == .wifi }
        )
    }

    /// A phrase naming the radio, for a finding's evidence — "5 GHz channel
    /// 100", or channels plural when it moved. Never an access point: macOS 26
    /// does not give unprivileged apps the SSID or BSSID (PHASE4-NOTES).
    public var description: String? {
        guard isWiFi else { return nil }
        let band = bands.count == 1 ? bands.first : nil
        let channel: String? = channels.isEmpty ? nil
            : (channels.count == 1
               ? "channel \(channels.first!)"
               : "channels \(channels.sorted().map(String.init).joined(separator: ", "))")
        return [band, channel].compactMap { $0 }.joined(separator: " ")
    }
}
