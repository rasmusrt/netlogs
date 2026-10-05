import XCTest
@testable import NetlogsCore

/// The gateway parser, the change detector and the monitor.
///
/// The fixture is shaped like the UCG-Fiber's `stat/device` response from the
/// Phase 14.0 spike, cut down to the fields that matter and with made-up
/// identifiers in place of the real ones.
final class WANTelemetryTests: XCTestCase {

    private static let imei = "350000000000001"
    private static let iccid = "89450000000000000001"

    private func deviceList(uplinkCPE: String? = "90:41:b2:00:00:01",
                            cpeMAC: String = "90:41:b2:00:00:01",
                            wan2Uplink: Bool = false) -> Data {
        let mbbMAC = uplinkCPE.map { "\"mbb_device_mac\": \"\($0)\"," } ?? ""
        return Data("""
        {"meta": {"rc": "ok"}, "data": [
          {"type": "udm", "model": "UDMA6A8",
           "wan1": {\(mbbMAC) "is_uplink": \(!wan2Uplink), "up": true,
                    "rx_bytes": 509927478268, "tx_bytes": 40153043042,
                    "rx_packets": 420814929, "tx_packets": 87484891},
           "wan2": {"is_uplink": \(wan2Uplink), "up": \(wan2Uplink),
                    "rx_bytes": 7, "tx_bytes": 8}},
          {"type": "usw", "mac": "aa:aa:aa:aa:aa:aa"},
          {"type": "umbb", "mac": "\(cpeMAC)", "last_seen": 1790609073,
           "mbb": {"imei": "\(Self.imei)",
                   "sim": [{"iccid": "\(Self.iccid)", "rxbytes": 1}],
                   "radio": {"rat": "5G", "5g_sa_mode": false, "band": "n78",
                             "cell_id": 8451162, "pci": 862,
                             "snr_nr": 25.4, "rsrp_nr": -90, "rsrq_nr": -11,
                             "snr": 20.4, "rsrp": -81, "rsrq": -11}}}
        ]}
        """.utf8)
    }

    // MARK: - Parser

    func testReadsTheRadioAndTheUplinkCounters() throws {
        let (radio, counters) = try UniFiDeviceParser.parse(deviceList())
        XCTAssertEqual(radio?.technology, "5G")
        XCTAssertEqual(radio?.standalone, false)
        XCTAssertEqual(radio?.band, "n78")
        XCTAssertEqual(radio?.cellID, 8451162)
        XCTAssertEqual(radio?.nrSINR, 25.4)
        XCTAssertEqual(radio?.lteRSRP, -81)
        XCTAssertEqual(radio?.reportedAt, Date(timeIntervalSince1970: 1790609073),
                       "the CPE's own report time, not the poll's")
        XCTAssertEqual(counters?.interface, "wan1")
        XCTAssertEqual(counters?.rxBytes, 509927478268, "no precision lost on a 39-bit counter")
        XCTAssertEqual(counters?.txPackets, 87484891)
    }

    /// The device record carries the IMEI and ICCID beside the radio. The
    /// snapshot is an allowlist, so neither can reach the database.
    func testStoresNoIdentifiers() throws {
        let (radio, counters) = try UniFiDeviceParser.parse(deviceList())
        let json = String(decoding: try JSONEncoder().encode(
            WANSnapshot(timestamp: Date(), radio: radio, counters: counters)), as: UTF8.self)
        XCTAssertFalse(json.contains(Self.imei))
        XCTAssertFalse(json.contains(Self.iccid))
        XCTAssertFalse(json.contains("90:41:b2"), "nor the CPE's MAC")
    }

    /// A cellular backup on the idle WAN is measuring nothing the pings cross.
    func testIgnoresACPEThatIsNotOnTheActiveUplink() throws {
        let (radio, counters) = try UniFiDeviceParser.parse(deviceList(wan2Uplink: true))
        XCTAssertNil(radio)
        XCTAssertEqual(counters?.interface, "wan2")
        XCTAssertEqual(counters?.rxBytes, 7)
    }

    func testIgnoresACPETheUplinkDoesNotName() throws {
        let (radio, counters) = try UniFiDeviceParser.parse(deviceList(uplinkCPE: nil))
        XCTAssertNil(radio, "without the uplink naming it, a CPE is not known to be the path")
        XCTAssertNotNil(counters)
    }

    func testMatchesTheCPEWhateverTheCaseOfItsMAC() throws {
        let (radio, _) = try UniFiDeviceParser.parse(
            deviceList(uplinkCPE: "90:41:B2:00:00:01", cpeMAC: "90:41:b2:00:00:01"))
        XCTAssertNotNil(radio)
    }

    func testRejectsSomethingThatIsNotADeviceList() {
        XCTAssertThrowsError(try UniFiDeviceParser.parse(Data("{\"error\": 1}".utf8))) {
            XCTAssertEqual($0 as? UniFiDeviceParser.ParseError, .notADeviceList)
        }
        XCTAssertThrowsError(try UniFiDeviceParser.parse(
            Data("{\"data\": [{\"type\": \"usw\"}]}".utf8))) {
            XCTAssertEqual($0 as? UniFiDeviceParser.ParseError, .noGateway)
        }
    }

    /// `true` is an `NSNumber` too, and must not come back as a 1.
    func testABooleanIsNotANumber() {
        XCTAssertNil(UniFiDeviceParser.double(true as NSNumber))
        XCTAssertNil(UniFiDeviceParser.int64(false as NSNumber))
        XCTAssertEqual(UniFiDeviceParser.double(25.4 as NSNumber), 25.4)
    }

    // MARK: - Fingerprints

    func testFingerprintsCompareHoweverTheyWereTyped() {
        let raw = "ab12cd"
        XCTAssertEqual(UniFiGateway.normalise("AB:12:CD"), raw)
        XCTAssertEqual(UniFiGateway.normalise(" ab 12 cd "), raw)
        XCTAssertEqual(UniFiGateway.display(raw), "AB:12:CD")
    }

    /// With a certificate trusted and no key there is nothing to ask for, so
    /// it must not go to the network at all. The host does not exist.
    func testAPinnedGatewayWithoutAKeyNeverConnects() async {
        let gateway = UniFiGateway(host: "gateway.invalid", apiKey: nil, pinnedSHA256: "ab")
        defer { gateway.close() }
        let snapshot = await gateway.poll()
        XCTAssertEqual(snapshot.failure, .noKey)
    }

    // MARK: - Change detector

    private func snapshot(at t: TimeInterval, sinr: Double = 25, reported: TimeInterval = 0,
                          rx: Int64 = 100, failure: WANTelemetryFailure? = nil) -> WANSnapshot {
        let at = Date(timeIntervalSince1970: t)
        if let failure { return .failed(failure, at: at) }
        return WANSnapshot(
            timestamp: at,
            radio: CellularRadio(reportedAt: Date(timeIntervalSince1970: reported), nrSINR: sinr),
            counters: WANCounters(interface: "wan1", rxBytes: rx, txBytes: rx))
    }

    /// Polled every 2 s, the CPE refreshes every ~12 s: six identical polls
    /// are one row.
    func testStoresOnlyWhatMoved() {
        var detector = WANChangeDetector()
        XCTAssertTrue(detector.shouldStore(snapshot(at: 0), now: Date(timeIntervalSince1970: 0)))
        for t in stride(from: 2.0, through: 10, by: 2) {
            XCTAssertFalse(detector.shouldStore(snapshot(at: t), now: Date(timeIntervalSince1970: t)))
        }
        XCTAssertTrue(detector.shouldStore(snapshot(at: 12, sinr: 24, reported: 12),
                                           now: Date(timeIntervalSince1970: 12)))
        XCTAssertTrue(detector.shouldStore(snapshot(at: 14, sinr: 24, reported: 12, rx: 200),
                                           now: Date(timeIntervalSince1970: 14)),
                      "the counters moving is a change")
    }

    func testAFailureAndARecoveryAreBothStored() {
        var detector = WANChangeDetector()
        _ = detector.shouldStore(snapshot(at: 0), now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(detector.shouldStore(snapshot(at: 2, failure: .unreachable("timed out")),
                                           now: Date(timeIntervalSince1970: 2)))
        XCTAssertFalse(detector.shouldStore(snapshot(at: 4, failure: .unreachable("timed out")),
                                            now: Date(timeIntervalSince1970: 4)),
                       "a failure that persists is one row, not one per poll")
        XCTAssertTrue(detector.shouldStore(snapshot(at: 6), now: Date(timeIntervalSince1970: 6)))
    }

    func testAHeartbeatWhenNothingMoves() {
        var detector = WANChangeDetector(heartbeat: .seconds(60))
        _ = detector.shouldStore(snapshot(at: 0), now: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(detector.shouldStore(snapshot(at: 58), now: Date(timeIntervalSince1970: 58)))
        XCTAssertTrue(detector.shouldStore(snapshot(at: 60), now: Date(timeIntervalSince1970: 60)))
    }

    // MARK: - Monitor

    /// A gateway that takes longer to answer than the poll interval must not
    /// accumulate requests: the tick is skipped, not queued.
    func testASlowGatewayIsNeverAskedTwiceAtOnce() async throws {
        let provider = SlowProvider(delay: .milliseconds(250))
        let monitor = WANTelemetryMonitor(provider: provider, interval: .milliseconds(50))
        let events = monitor.start()
        var received = 0
        for await _ in events {
            received += 1
            if received == 3 { break }
        }
        monitor.stop()
        XCTAssertEqual(provider.maxConcurrent, 1)
        XCTAssertTrue(provider.closed)
    }

    // MARK: - Storage and settings

    func testPersistsAndReadsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wan-\(UUID()).sqlite")
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        let session = try store.startSession(MonitorSettings())
        try store.appendWANSnapshot(snapshot(at: 1), to: session.id)
        try store.appendWANSnapshot(snapshot(at: 2, failure: .certificateChanged(sha256: "ff")),
                                    to: session.id)
        let rows = try store.wanSnapshots(for: session.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].radio?.nrSINR, 25)
        XCTAssertEqual(rows[1].failure, .certificateChanged(sha256: "ff"))
    }

    /// Settings saved before Phase 14 have none of the gateway keys.
    func testOldSettingsDecodeWithTelemetryOff() throws {
        let old = Data(#"{"routerHost": "192.168.0.1", "internetHost": "1.1.1.1"}"#.utf8)
        let settings = try JSONDecoder().decode(MonitorSettings.self, from: old)
        XCTAssertFalse(settings.wanTelemetryEnabled)
        XCTAssertNil(settings.wanCertificateSHA256)
        XCTAssertEqual(settings.effectiveWANGatewayHost, "192.168.0.1",
                       "no host of its own means the router")
    }

    func testATypedGatewayHostOverridesTheRouter() {
        var settings = MonitorSettings(routerHost: "192.168.0.1")
        settings.wanGatewayHost = " 10.0.0.1 "
        XCTAssertEqual(settings.effectiveWANGatewayHost, "10.0.0.1")
        settings.wanGatewayHost = "  "
        XCTAssertEqual(settings.effectiveWANGatewayHost, "192.168.0.1")
    }
}

private final class SlowProvider: WANTelemetryProvider, @unchecked Sendable {
    private let delay: Duration
    private let lock = NSLock()
    private var current = 0
    private var _max = 0
    private var _closed = false

    init(delay: Duration) { self.delay = delay }

    var maxConcurrent: Int { lock.withLock { _max } }
    var closed: Bool { lock.withLock { _closed } }

    func poll() async -> WANSnapshot {
        lock.withLock { current += 1; _max = max(_max, current) }
        try? await Task.sleep(for: delay)
        lock.withLock { current -= 1 }
        return WANSnapshot(timestamp: Date(), counters: WANCounters(rxBytes: Int64.random(in: 0...1_000)))
    }

    func close() { lock.withLock { _closed = true } }
}
