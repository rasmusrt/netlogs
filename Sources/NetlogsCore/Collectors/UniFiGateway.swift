import CryptoKit
import Foundation
import Security

/// A source of gateway telemetry. `UniFiGateway` is the real one; tests inject
/// fakes, as they do for ``DiagnosticsProvider``.
public protocol WANTelemetryProvider: Sendable {
    /// One poll. Never throws: every failure comes back as a snapshot carrying
    /// ``WANTelemetryFailure``, because none of them should interrupt a session.
    func poll() async -> WANSnapshot
    /// Release the connection. Safe to call more than once.
    func close()
}

/// Reads the WAN from a UniFi gateway's local controller API.
///
/// Uses `/proxy/network/api/s/<site>/stat/device` with an `X-API-KEY` header.
/// The newer `/proxy/network/integration/v1` API accepts the same key but does
/// not carry the cellular radio (Phase 14.0, `PHASE14-NOTES.md`).
///
/// **Trust is a pinned certificate, never an ATS exception.** The gateway's
/// certificate is self-signed, so the system cannot vouch for it. The user
/// trusts its SHA-256 once, in Settings, and every connection after that must
/// present exactly that certificate. Until one is trusted, and whenever the
/// certificate differs, the TLS handshake is abandoned — so the key is never
/// sent to a host that has not been recognised. It is also not attached to a
/// request at all while no certificate is pinned.
public final class UniFiGateway: WANTelemetryProvider, @unchecked Sendable {
    public let host: String
    public let site: String
    private let apiKey: String?
    private let pinnedSHA256: String?
    private let delegate: PinningDelegate
    private let session: URLSession

    public init(host: String, apiKey: String?, pinnedSHA256: String?,
                site: String = "default", timeout: TimeInterval = 5) {
        self.host = host
        self.site = site
        self.apiKey = apiKey
        self.pinnedSHA256 = pinnedSHA256.map(Self.normalise)
        self.delegate = PinningDelegate(pinned: self.pinnedSHA256)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func close() { session.invalidateAndCancel() }

    public func poll() async -> WANSnapshot {
        let now = Date()
        // Checked before any network: with a certificate pinned and no key,
        // there is nothing a request could return.
        if pinnedSHA256 != nil, apiKey == nil { return .failed(.noKey, at: now) }

        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        guard let url = URL(string: "https://\(authority)/proxy/network/api/s/\(site)/stat/device")
        else { return .failed(.unreachable("not a valid host"), at: now) }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Only once a certificate is pinned. The delegate would abandon the
        // handshake anyway, but a key that is never placed on an unpinned
        // request cannot leak through a mistake in the delegate.
        if pinnedSHA256 != nil, let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        }

        delegate.reset()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let observed = delegate.rejected {
                return .failed(pinnedSHA256 == nil
                               ? .untrustedCertificate(sha256: observed)
                               : .certificateChanged(sha256: observed), at: now)
            }
            return .failed(.unreachable(Self.describe(error)), at: now)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 401, 403: return .failed(.unauthorized, at: now)
            default: return .failed(.unexpectedResponse("HTTP \(http.statusCode)"), at: now)
            }
        }

        do {
            let (radio, counters) = try UniFiDeviceParser.parse(data)
            return WANSnapshot(timestamp: now, radio: radio, counters: counters)
        } catch {
            return .failed(.unexpectedResponse(String(describing: error)), at: now)
        }
    }

    /// Lowercase hex without separators, so a fingerprint pasted with colons
    /// or in upper case still matches.
    public static func normalise(_ sha256: String) -> String {
        sha256.lowercased().filter(\.isHexDigit)
    }

    /// `ab12cd…` as `AB:12:CD:…`, the way certificate viewers show it, so the
    /// user can compare it against the gateway's own settings page.
    public static func display(_ sha256: String) -> String {
        let hex = Array(normalise(sha256).uppercased())
        return stride(from: 0, to: hex.count, by: 2)
            .map { String(hex[$0..<min($0 + 2, hex.count)]) }
            .joined(separator: ":")
    }

    private static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .timedOut: return "timed out"
        case .cannotConnectToHost, .cannotFindHost: return "no answer"
        case .notConnectedToInternet, .networkConnectionLost: return "no network"
        default: return urlError.localizedDescription
        }
    }
}

/// Accepts exactly one certificate, identified by the SHA-256 of its DER.
private final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let pinned: String?
    private let lock = NSLock()
    private var _rejected: String?

    /// The fingerprint of the last certificate refused. Read after a failed
    /// request to say which certificate it was.
    var rejected: String? { lock.withLock { _rejected } }

    init(pinned: String?) { self.pinned = pinned }

    func reset() { lock.withLock { _rejected = nil } }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let der = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        if let pinned, fingerprint == pinned {
            lock.withLock { _rejected = nil }
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            lock.withLock { _rejected = fingerprint }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Turns a `stat/device` response into the allowlisted fields and nothing else.
///
/// Pure, so the whole of it is testable against fixtures without a gateway.
public enum UniFiDeviceParser {
    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case notADeviceList
        case noGateway

        public var description: String {
            switch self {
            case .notADeviceList: return "not a device list"
            case .noGateway:      return "no gateway in the device list"
            }
        }
    }

    /// Gateway device types that carry `wanN` interfaces.
    static let gatewayTypes: Set<String> = ["udm", "ugw", "uxg"]

    public static func parse(_ data: Data) throws -> (CellularRadio?, WANCounters?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = root["data"] as? [[String: Any]]
        else { throw ParseError.notADeviceList }

        guard let gateway = devices.first(where: {
            gatewayTypes.contains($0["type"] as? String ?? "") || $0["wan1"] is [String: Any]
        }) else { throw ParseError.noGateway }

        guard let (name, wan) = uplink(of: gateway) else { return (nil, nil) }
        let counters = WANCounters(
            interface: name,
            rxBytes: int64(wan["rx_bytes"]), txBytes: int64(wan["tx_bytes"]),
            rxPackets: int64(wan["rx_packets"]), txPackets: int64(wan["tx_packets"])
        )

        // Only the CPE the active uplink names. A cellular backup on a second
        // WAN reports a radio that is carrying none of the traffic being
        // measured, and correlating latency against it would be worse than
        // having no radio at all.
        guard let cpeMAC = (wan["mbb_device_mac"] as? String)?.lowercased(),
              let cpe = devices.first(where: {
                  $0["type"] as? String == "umbb" && ($0["mac"] as? String)?.lowercased() == cpeMAC
              }),
              let radio = (cpe["mbb"] as? [String: Any])?["radio"] as? [String: Any]
        else { return (nil, counters) }

        return (CellularRadio(
            reportedAt: double(cpe["last_seen"]).map { Date(timeIntervalSince1970: $0) },
            technology: radio["rat"] as? String,
            standalone: radio["5g_sa_mode"] as? Bool,
            band: radio["band"] as? String,
            cellID: int64(radio["cell_id"]).map(Int.init),
            physicalCellID: int64(radio["pci"]).map(Int.init),
            nrSINR: double(radio["snr_nr"]),
            nrRSRP: double(radio["rsrp_nr"]),
            nrRSRQ: double(radio["rsrq_nr"]),
            lteSINR: double(radio["snr"]),
            lteRSRP: double(radio["rsrp"]),
            lteRSRQ: double(radio["rsrq"])
        ), counters)
    }

    /// The WAN interface carrying traffic: the one marked `is_uplink`, else the
    /// first that is up.
    static func uplink(of gateway: [String: Any]) -> (String, [String: Any])? {
        let wans = gateway.keys
            .filter { $0.hasPrefix("wan") && Int($0.dropFirst(3)) != nil }
            .sorted { Int($0.dropFirst(3))! < Int($1.dropFirst(3))! }
            .compactMap { name in (gateway[name] as? [String: Any]).map { (name, $0) } }
        return wans.first { $0.1["is_uplink"] as? Bool == true }
            ?? wans.first { $0.1["up"] as? Bool == true }
    }

    /// JSON numbers arrive as `NSNumber`; a `Bool` is one too, and must not
    /// read as 0 or 1.
    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.int64Value
    }
}
