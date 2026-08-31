import XCTest
@testable import NetlogsCore

final class DiagnosticsTraceTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func snapshot(
        _ offset: TimeInterval,
        rssi: Int? = -43,
        channel: Int? = 44,
        band: String? = "5 GHz",
        gateway: String? = "192.168.1.1",
        kind: DiagnosticsSnapshot.Kind = .wifi
    ) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            timestamp: start.addingTimeInterval(offset),
            interfaceName: "en0", kind: kind,
            rssi: rssi, noise: -92, snr: rssi.map { $0 + 92 }, txRateMbps: 866,
            channel: channel, band: band, phyMode: "802.11ax", security: "WPA3 Personal",
            ipAddress: "192.168.1.17", subnetMask: "255.255.255.0",
            gateway: gateway, dnsServers: ["1.1.1.1"], mtu: 1500
        )
    }

    // MARK: - Changes

    /// The 669-row case: heartbeats with a drifting radio and nothing else.
    func testHeartbeatsWithDriftingSignalAreNotChanges() {
        let snapshots = (0..<20).map { snapshot(Double($0) * 60, rssi: -43 - $0 % 4) }
        let trace = DiagnosticsTrace.build(snapshots)

        XCTAssertTrue(trace.changes.isEmpty)
        XCTAssertEqual(trace.points.count, 20)
        XCTAssertEqual(trace.readingCount, 20)
        XCTAssertEqual(trace.snapshotCount, 20)
        XCTAssertTrue(trace.points.allSatisfy { $0.segment == 0 })
    }

    func testChannelChangeIsDescribedAndBreaksTheLine() {
        let trace = DiagnosticsTrace.build([
            snapshot(0), snapshot(60),
            snapshot(120, channel: 36), snapshot(180, channel: 36),
        ])

        XCTAssertEqual(trace.changes.count, 1)
        let change = try! XCTUnwrap(trace.changes.first)
        XCTAssertEqual(change.time, start.addingTimeInterval(120))
        XCTAssertEqual(change.summary, "Channel 44 → 36")
        XCTAssertTrue(change.affectsRadio)
        XCTAssertEqual(trace.points.map(\.segment), [0, 0, 1, 1])
    }

    /// A new gateway is worth listing and explains nothing about the signal, so
    /// it must not put a mark on the trace or break the line.
    func testNonRadioChangeIsListedButNotMarked() {
        let trace = DiagnosticsTrace.build([
            snapshot(0), snapshot(60, gateway: "10.0.0.1"),
        ])

        XCTAssertEqual(trace.changes.count, 1)
        XCTAssertEqual(trace.changes.first?.summary, "Gateway 192.168.1.1 → 10.0.0.1")
        XCTAssertFalse(trace.changes.first?.affectsRadio ?? true)
        XCTAssertTrue(trace.radioChanges.isEmpty)
        XCTAssertEqual(trace.points.map(\.segment), [0, 0])
    }

    /// The invariant the field list exists for: anything `stableSignature`
    /// counts as a change has words to describe it. A change that renders as an
    /// empty row is worse than no row.
    func testEverySignatureChangeHasSomethingToSay() {
        let base = snapshot(0)
        var mutations: [(String, DiagnosticsSnapshot)] = []
        var s = base; s.interfaceName = "en1"; mutations.append(("interface", s))
        s = base; s.kind = .ethernet; mutations.append(("kind", s))
        s = base; s.channel = 36; mutations.append(("channel", s))
        s = base; s.band = "2.4 GHz"; mutations.append(("band", s))
        s = base; s.phyMode = "802.11ac"; mutations.append(("phyMode", s))
        s = base; s.security = "WPA2 Personal"; mutations.append(("security", s))
        s = base; s.ssid = "Home"; mutations.append(("ssid", s))
        s = base; s.bssid = "aa:bb:cc:dd:ee:ff"; mutations.append(("bssid", s))
        s = base; s.linkSpeedMbps = 1000; mutations.append(("linkSpeed", s))
        s = base; s.duplex = "full"; mutations.append(("duplex", s))
        s = base; s.ipAddress = "192.168.1.18"; mutations.append(("ip", s))
        s = base; s.subnetMask = "255.255.0.0"; mutations.append(("subnet", s))
        s = base; s.gateway = "10.0.0.1"; mutations.append(("gateway", s))
        s = base; s.dnsServers = ["9.9.9.9"]; mutations.append(("dns", s))
        s = base; s.mtu = 1400; mutations.append(("mtu", s))

        for (name, mutated) in mutations {
            var second = mutated
            second.timestamp = start.addingTimeInterval(60)
            XCTAssertNotEqual(second.stableSignature, base.stableSignature, name)

            let trace = DiagnosticsTrace.build([base, second])
            XCTAssertEqual(trace.changes.count, 1, name)
            XCTAssertFalse(trace.changes.first?.fields.isEmpty ?? true, name)
            XCTAssertFalse(trace.changes.first?.summary.isEmpty ?? true, name)
        }
    }

    // MARK: - Points

    /// A hole — a sleep, or a session picked up later — is not drawn through.
    func testLongGapBreaksTheLine() {
        let trace = DiagnosticsTrace.build([
            snapshot(0), snapshot(60), snapshot(60 + 600), snapshot(60 + 660),
        ])
        XCTAssertEqual(trace.points.map(\.segment), [0, 0, 1, 1])
    }

    func testSnapshotsWithoutSignalAreNotPlotted() {
        let trace = DiagnosticsTrace.build([
            snapshot(0, rssi: nil, kind: .ethernet),
            snapshot(60, rssi: nil, kind: .ethernet),
        ])
        XCTAssertTrue(trace.points.isEmpty)
        XCTAssertFalse(trace.hasTrace)
        XCTAssertEqual(trace.snapshotCount, 2)
        XCTAssertEqual(trace.readingCount, 0)
    }

    /// Decimation keeps the dip. Averaging a bucket is exactly what would hide
    /// the thirty seconds the sheet exists to show.
    func testDecimationCapsPointsAndKeepsTheWorstReading() {
        var snapshots = (0..<1_000).map { snapshot(Double($0) * 60) }
        snapshots[500] = snapshot(500 * 60, rssi: -88)
        let trace = DiagnosticsTrace.build(snapshots, maxPoints: 100)

        XCTAssertTrue(trace.isDecimated)
        XCTAssertEqual(trace.points.count, 100)
        XCTAssertEqual(trace.points.map(\.rssi).min(), -88)
        // The figures describe every stored reading, not the drawn subset.
        XCTAssertEqual(trace.readingCount, 1_000)
        XCTAssertEqual(trace.stats.min, -88)
    }

    func testShortSeriesIsNotDecimated() {
        let trace = DiagnosticsTrace.build((0..<50).map { snapshot(Double($0) * 60) })
        XCTAssertFalse(trace.isDecimated)
        XCTAssertEqual(trace.points.count, 50)
    }

    // MARK: - Scales

    /// The common case is a signal that never moves. Fitting the axis to a
    /// 2 dB wobble would draw a cliff.
    func testFlatSignalGetsAMinimumSpan() {
        let trace = DiagnosticsTrace.build((0..<10).map { snapshot(Double($0) * 60, rssi: -43) })
        let domain = trace.yDomain

        XCTAssertGreaterThanOrEqual(domain.upperBound - domain.lowerBound,
                                    DiagnosticsTrace.minimumSpan)
        XCTAssertTrue(domain.contains(-43))
    }

    func testDomainStaysInsidePlausibledBm() {
        let trace = DiagnosticsTrace.build([
            snapshot(0, rssi: -120), snapshot(60, rssi: -5),
        ])
        XCTAssertGreaterThanOrEqual(trace.yDomain.lowerBound, -100)
        XCTAssertLessThanOrEqual(trace.yDomain.upperBound, -10)
        XCTAssertLessThan(trace.yDomain.lowerBound, trace.yDomain.upperBound)
    }

    func testEmptyHistory() {
        let trace = DiagnosticsTrace.build([])
        XCTAssertTrue(trace.points.isEmpty)
        XCTAssertTrue(trace.changes.isEmpty)
        XCTAssertEqual(trace.snapshotCount, 0)
        XCTAssertFalse(trace.hasTrace)
        XCTAssertFalse(trace.yDomain.isEmpty)
    }

    /// Charts clips a label centred on a tick at the plot edge — the closing
    /// timestamp came out as "1" before the domain was padded.
    func testXDomainLeavesRoomForTheClosingLabel() {
        let trace = DiagnosticsTrace.build((0..<10).map { snapshot(Double($0) * 60) })
        let first = try! XCTUnwrap(trace.points.first?.time)
        let last = try! XCTUnwrap(trace.points.last?.time)

        XCTAssertLessThan(trace.xDomain.lowerBound, first)
        XCTAssertGreaterThan(trace.xDomain.upperBound, last)
    }

    /// Charts' own tick values snap to round times and can land a second from
    /// the domain edge, where the label is elided. These are round *and* clear
    /// of both ends.
    func testTicksAreRoundAndClearOfBothEnds() {
        // 76 minutes, the length of a real session.
        let trace = DiagnosticsTrace.build((0..<77).map { snapshot(Double($0) * 60) })
        let ticks = trace.xTicks()
        XCTAssertGreaterThanOrEqual(ticks.count, 3)

        let calendar = Calendar.current
        for tick in ticks {
            XCTAssertEqual(calendar.component(.second, from: tick), 0)
            // Quarter hours at this span.
            XCTAssertEqual(calendar.component(.minute, from: tick) % 15, 0)
        }

        let first = try! XCTUnwrap(trace.points.first?.time)
        let last = try! XCTUnwrap(trace.points.last?.time)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ticks.first).timeIntervalSince(first),
                                    trace.span * 0.08)
        XCTAssertGreaterThanOrEqual(last.timeIntervalSince(try XCTUnwrap(ticks.last)),
                                    trace.span * 0.08)
        for tick in ticks { XCTAssertTrue(trace.xDomain.contains(tick)) }
    }

    /// Three readings a minute apart: quarter hours would leave the axis blank,
    /// so the interval has to come down to something sub-minute.
    func testShortSpanGetsFinerTicks() {
        let trace = DiagnosticsTrace.build((0..<3).map { snapshot(Double($0) * 60) })
        let ticks = trace.xTicks()

        XCTAssertFalse(ticks.isEmpty)
        for tick in ticks { XCTAssertTrue(trace.xDomain.contains(tick)) }
        XCTAssertLessThan(
            try XCTUnwrap(ticks.last).timeIntervalSince(try XCTUnwrap(ticks.first)),
            trace.span
        )
    }

    func testTicksAreEmptyWithoutASpan() {
        XCTAssertTrue(DiagnosticsTrace.build([snapshot(0)]).xTicks().isEmpty)
        XCTAssertTrue(DiagnosticsTrace.build([]).xTicks().isEmpty)
    }

    // MARK: - Hover

    func testNearestPicksTheClosestReadingOnEitherSide() {
        let trace = DiagnosticsTrace.build((0..<5).map { snapshot(Double($0) * 60) })

        XCTAssertEqual(trace.nearest(to: start.addingTimeInterval(-999))?.id, 0)
        XCTAssertEqual(trace.nearest(to: start.addingTimeInterval(29))?.id, 0)
        XCTAssertEqual(trace.nearest(to: start.addingTimeInterval(31))?.id, 1)
        XCTAssertEqual(trace.nearest(to: start.addingTimeInterval(120))?.id, 2)
        XCTAssertEqual(trace.nearest(to: start.addingTimeInterval(9_999))?.id, 4)
    }

    func testNearestOnAnEmptyTrace() {
        XCTAssertNil(DiagnosticsTrace.build([]).nearest(to: start))
    }

    func testSinglePointHasAWidenedXDomain() {
        let trace = DiagnosticsTrace.build([snapshot(0)])
        XCTAssertFalse(trace.hasTrace)
        XCTAssertLessThan(trace.xDomain.lowerBound, trace.xDomain.upperBound)
    }
}
