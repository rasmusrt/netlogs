import XCTest
@testable import NetlogsCore

/// Scripted provider for deterministic tests.
private struct FakeDiagnostics: DiagnosticsProvider {
    let snapshots: [DiagnosticsSnapshot]
    let counter: Counter
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var i = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = i; i += 1; return v }
    }
    func snapshot() -> DiagnosticsSnapshot {
        let all = snapshots
        return all[min(counter.next(), all.count - 1)]
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticsEvent] = []
    func append(_ e: DiagnosticsEvent) -> Int { lock.lock(); defer { lock.unlock() }; events.append(e); return events.count }
    var all: [DiagnosticsEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

final class DiagnosticsTests: XCTestCase {

    private func wifi(rssi: Int, channel: Int = 44, ssid: String? = nil, ip: String = "192.168.1.17") -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            interfaceName: "en0", kind: .wifi,
            rssi: rssi, noise: -92, snr: rssi + 92, txRateMbps: 866,
            channel: channel, band: "5 GHz", phyMode: "802.11ax", security: "WPA3 Personal",
            ssid: ssid, ipAddress: ip, subnetMask: "255.255.255.0",
            gateway: "192.168.1.1", dnsServers: ["1.1.1.1", "8.8.8.8"], mtu: 1500
        )
    }

    // MARK: - Change detector

    func testStoresOnStableChangeNotOnRadioDrift() {
        var d = DiagnosticsChangeDetector(heartbeat: .seconds(60))
        let t0 = Date(timeIntervalSince1970: 0)

        XCTAssertTrue(d.shouldStore(wifi(rssi: -50), now: t0), "first snapshot always stores")
        XCTAssertFalse(d.shouldStore(wifi(rssi: -55), now: t0.addingTimeInterval(5)), "rssi drift alone")
        XCTAssertFalse(d.shouldStore(wifi(rssi: -60), now: t0.addingTimeInterval(10)))
        XCTAssertTrue(d.shouldStore(wifi(rssi: -60, channel: 149), now: t0.addingTimeInterval(15)), "channel changed")
        XCTAssertFalse(d.shouldStore(wifi(rssi: -48, channel: 149), now: t0.addingTimeInterval(20)))
    }

    func testHeartbeatStoresEvenWhenUnchanged() {
        var d = DiagnosticsChangeDetector(heartbeat: .seconds(60))
        let t0 = Date(timeIntervalSince1970: 1000)
        _ = d.shouldStore(wifi(rssi: -50), now: t0)
        XCTAssertFalse(d.shouldStore(wifi(rssi: -50), now: t0.addingTimeInterval(55)))
        XCTAssertTrue(d.shouldStore(wifi(rssi: -50), now: t0.addingTimeInterval(60)), "60 s heartbeat")
        XCTAssertFalse(d.shouldStore(wifi(rssi: -50), now: t0.addingTimeInterval(90)))
        XCTAssertTrue(d.shouldStore(wifi(rssi: -50), now: t0.addingTimeInterval(120)))
    }

    func testAnHourOfStablePollsStoresFarFewerThan1800() {
        var d = DiagnosticsChangeDetector(heartbeat: .seconds(60))
        var stored = 0
        let start = Date(timeIntervalSince1970: 0)
        // 5 s polls for an hour = 720 polls, network stable the whole time.
        for i in 0..<720 {
            if d.shouldStore(wifi(rssi: -50 + Int(i % 7)), now: start.addingTimeInterval(Double(i) * 5)) {
                stored += 1
            }
        }
        XCTAssertLessThan(stored, 70, "≈ one heartbeat per minute, got \(stored)")
        XCTAssertGreaterThan(stored, 55)
    }

    // MARK: - Monitor

    func testMonitorEmitsAndFlagsFirstAndChanges() async {
        let snaps = [
            wifi(rssi: -50),                 // poll 0 → store (first)
            wifi(rssi: -52),                 // poll 1 → no
            wifi(rssi: -80, ssid: "Cafe"),   // poll 2 → store (ssid changed)
            wifi(rssi: -81, ssid: "Cafe"),   // poll 3 → no
        ]
        let monitor = DiagnosticsMonitor(
            provider: FakeDiagnostics(snapshots: snaps, counter: .init()),
            interval: .milliseconds(50),
            heartbeat: .seconds(999)
        )
        let box = EventBox()
        let stream = monitor.start()
        let collector = Task { for await e in stream { if box.append(e) >= 4 { break } } }
        _ = await collector.value
        monitor.stop()
        let events = box.all

        XCTAssertGreaterThanOrEqual(events.count, 4)
        XCTAssertTrue(events[0].shouldStore)
        XCTAssertFalse(events[1].shouldStore)
        XCTAssertTrue(events[2].shouldStore)
        XCTAssertFalse(events[3].shouldStore)
        XCTAssertEqual(events[2].snapshot.ssid, "Cafe")
    }

    // MARK: - Model + storage

    func testSnapshotRoundTripAndSignature() throws {
        let a = wifi(rssi: -50)
        let b = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(a, b)

        // rssi/noise/snr/txRate excluded from the signature; channel included.
        XCTAssertEqual(wifi(rssi: -50).stableSignature, wifi(rssi: -70).stableSignature)
        XCTAssertNotEqual(wifi(rssi: -50, channel: 1).stableSignature, wifi(rssi: -50, channel: 149).stableSignature)
    }

    func testPersistsAndReadsBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID()).sqlite")
        let store = try SessionStore(url: url, flushInterval: .zero)
        defer { store.close(); try? FileManager.default.removeItem(at: url) }

        let session = try store.startSession(MonitorSettings())
        try store.appendDiagnostics(wifi(rssi: -50), to: session.id)
        try store.appendDiagnostics(wifi(rssi: -70, channel: 149), to: session.id)

        XCTAssertEqual(try store.diagnosticsCount(for: session.id), 2)
        let rows = try store.diagnostics(for: session.id)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].channel, 149)
        XCTAssertEqual(rows[0].dnsServers, ["1.1.1.1", "8.8.8.8"])
    }
}
