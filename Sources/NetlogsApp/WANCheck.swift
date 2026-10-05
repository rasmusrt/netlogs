import Foundation
import NetlogsCore

/// `NetlogsApp --wancheck [host] [sha256]` — poll the gateway the way a session
/// would and print what comes back.
///
/// Without a fingerprint it only learns the certificate: the handshake is
/// abandoned and the key is neither read nor sent. With one, it reads the key
/// from the Keychain (which may ask first) and polls five times, 2 s apart.
enum WANCheck {
    static func runBlocking(host: String?, pinned: String?) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let host = host ?? MacDiagnostics.defaultGateway() ?? "192.168.1.1"
        let key = pinned == nil ? nil : GatewayKeychain.read()
        print("gateway : \(host)")
        print("key     : \(pinned == nil ? "not read (no certificate trusted)" : key == nil ? "none in Keychain" : "from Keychain")")

        let gateway = UniFiGateway(host: host, apiKey: key, pinnedSHA256: pinned)
        let done = DispatchSemaphore(value: 0)
        Task {
            for i in 1...(pinned == nil ? 1 : 5) {
                let start = Date()
                let s = await gateway.poll()
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                print("── poll \(i) (\(ms) ms) ─────────────────────")
                if let failure = s.failure {
                    print("failure : \(failure.description)")
                    if case .untrustedCertificate(let sha) = failure { print("sha256  : \(sha)") }
                    if case .certificateChanged(let sha) = failure { print("sha256  : \(sha)") }
                }
                if let r = s.radio {
                    print("radio   : \(r.technology ?? "—") \(r.band ?? "—")  SA \(r.standalone.map(String.init) ?? "—")  cell \(r.cellID.map(String.init) ?? "—")")
                    print("nr      : SINR \(fmt(r.nrSINR))  RSRP \(fmt(r.nrRSRP))  RSRQ \(fmt(r.nrRSRQ))")
                    print("lte     : SINR \(fmt(r.lteSINR))  RSRP \(fmt(r.lteRSRP))  RSRQ \(fmt(r.lteRSRQ))")
                    print("reported: \(r.reportedAt.map { "\(Int(Date().timeIntervalSince($0))) s ago" } ?? "—")")
                }
                if let c = s.counters {
                    print("\(c.interface ?? "wan")    : rx \(c.rxBytes.map(String.init) ?? "—")  tx \(c.txBytes.map(String.init) ?? "—")")
                }
                if i < 5, pinned != nil { try? await Task.sleep(for: .seconds(2)) }
            }
            gateway.close()
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "—" }
}
