import Foundation

/// One poll of the gateway: the cellular radio as the CPE last reported it, and
/// the WAN interface's cumulative counters (Phase 14; `docs/wan-telemetry-plan.md`).
///
/// **An allowlist, not the response.** The controller's device record for the
/// 5G CPE carries its IMEI, the SIM's ICCID and the eSIM's EID beside the radio
/// figures. None of that is a measurement of the connection, and the record is
/// never stored as received: only the fields declared here survive parsing.
///
/// Every field is optional. Firmware adds and drops fields, a gateway without a
/// cellular CPE has no radio, and "not reported" must stay distinguishable from
/// zero — the lesson of schema 3 and 5.
public struct WANSnapshot: Codable, Sendable, Equatable {
    /// When the poll was made.
    public let timestamp: Date
    public let radio: CellularRadio?
    public let counters: WANCounters?
    /// Why this poll has nothing to report. `nil` on success.
    ///
    /// Stored like a reading, not raised as an error: an unreachable gateway
    /// does not interrupt a session, and "the link to the gateway was down from
    /// 02:10" is itself something the session should be able to say.
    public let failure: WANTelemetryFailure?

    public init(timestamp: Date, radio: CellularRadio? = nil, counters: WANCounters? = nil,
                failure: WANTelemetryFailure? = nil) {
        self.timestamp = timestamp
        self.radio = radio
        self.counters = counters
        self.failure = failure
    }

    public static func failed(_ failure: WANTelemetryFailure, at timestamp: Date) -> WANSnapshot {
        WANSnapshot(timestamp: timestamp, failure: failure)
    }
}

/// The cellular radio, as the CPE last pushed it to the controller.
///
/// Measured by the Phase 14.0 spike: the U5G Max refreshes this about every
/// 12 s however often the controller is asked, so a series of these is steps at
/// that resolution and must be drawn that way.
public struct CellularRadio: Codable, Sendable, Equatable {
    /// When the CPE reported it — the controller's `last_seen` for the CPE, not
    /// the poll time. A poll learns of a value up to one refresh after it was
    /// measured, and correlating against the poll time would smear every step
    /// by that much.
    public let reportedAt: Date?
    /// Radio access technology, as reported: "5G", "LTE".
    public let technology: String?
    /// 5G standalone. `false` is NSA, where LTE carries the control plane.
    public let standalone: Bool?
    /// Primary band, e.g. "n78".
    public let band: String?
    public let cellID: Int?
    public let physicalCellID: Int?

    /// Signal-to-interference-plus-noise, dB. The figure that moves, and the one
    /// capacity follows.
    public let nrSINR: Double?
    public let nrRSRP: Double?
    public let nrRSRQ: Double?
    public let lteSINR: Double?
    public let lteRSRP: Double?
    public let lteRSRQ: Double?

    public init(
        reportedAt: Date? = nil, technology: String? = nil, standalone: Bool? = nil,
        band: String? = nil, cellID: Int? = nil, physicalCellID: Int? = nil,
        nrSINR: Double? = nil, nrRSRP: Double? = nil, nrRSRQ: Double? = nil,
        lteSINR: Double? = nil, lteRSRP: Double? = nil, lteRSRQ: Double? = nil
    ) {
        self.reportedAt = reportedAt
        self.technology = technology
        self.standalone = standalone
        self.band = band
        self.cellID = cellID
        self.physicalCellID = physicalCellID
        self.nrSINR = nrSINR
        self.nrRSRP = nrRSRP
        self.nrRSRQ = nrRSRQ
        self.lteSINR = lteSINR
        self.lteRSRP = lteRSRP
        self.lteRSRQ = lteRSRQ
    }
}

/// Cumulative counters on the gateway's active WAN interface.
///
/// Cumulative, not a rate. A rate is the difference of two snapshots, and
/// computing it at write time would bake the poll interval into the stored
/// figure. Store what was read.
public struct WANCounters: Codable, Sendable, Equatable {
    /// The gateway's name for the interface, e.g. "wan1".
    public let interface: String?
    public let rxBytes: Int64?
    public let txBytes: Int64?
    public let rxPackets: Int64?
    public let txPackets: Int64?

    public init(interface: String? = nil, rxBytes: Int64? = nil, txBytes: Int64? = nil,
                rxPackets: Int64? = nil, txPackets: Int64? = nil) {
        self.interface = interface
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.txPackets = txPackets
    }
}

/// Why a poll produced nothing. Each case says what the user would do about it,
/// which is why they are cases and not a string.
public enum WANTelemetryFailure: Codable, Sendable, Equatable {
    /// No API key in the Keychain.
    case noKey
    /// The gateway presented a certificate nobody has trusted yet. The key was
    /// **not** sent: the handshake is abandoned before any request goes out.
    case untrustedCertificate(sha256: String)
    /// The gateway presented a different certificate from the trusted one. Also
    /// abandoned before sending the key — this is what an impostor looks like,
    /// and also what a gateway looks like after a factory reset.
    case certificateChanged(sha256: String)
    /// The key was refused.
    case unauthorized
    case unreachable(String)
    /// It answered, but not with anything this parser recognises.
    case unexpectedResponse(String)

    public var description: String {
        switch self {
        case .noKey:                    return "No API key saved"
        case .untrustedCertificate:     return "Gateway certificate not trusted yet"
        case .certificateChanged:       return "Gateway certificate changed"
        case .unauthorized:             return "API key refused"
        case .unreachable(let reason):  return "Gateway unreachable: \(reason)"
        case .unexpectedResponse(let reason): return "Unexpected response: \(reason)"
        }
    }
}
