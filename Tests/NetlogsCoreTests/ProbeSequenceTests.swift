import XCTest
@testable import NetlogsCore

/// The rule that stops the two probes colliding when both hosts are one
/// address. See `ProbeHost` and PHASE9-NOTES, "The ICMP socket's third key".
final class ProbeSequenceTests: XCTestCase {

    /// The defect this exists to prevent: same peer, same sequence, same
    /// payload, so `ping()` evicted the first probe and called it a timeout.
    func testTheTwoProbesNeverShareASequence() {
        for id in UInt32(0)...70_000 where id % 7 == 0 {
            XCTAssertNotEqual(
                ProbeHost.router.wireSequence(for: id),
                ProbeHost.internet.wireSequence(for: id),
                "tick \(id)"
            )
        }
    }

    /// Not just different on the same tick — the spaces never overlap at all,
    /// so a router probe cannot collide with an internet probe from a
    /// neighbouring tick either.
    func testSpacesAreDisjointAcrossEveryTick() {
        var router: Set<UInt32> = [], internet: Set<UInt32> = []
        for id in UInt32(0)..<40_000 {
            router.insert(ProbeHost.router.wireSequence(for: id))
            internet.insert(ProbeHost.internet.wireSequence(for: id))
        }
        XCTAssertTrue(router.isDisjoint(with: internet))
        XCTAssertEqual(router.map { $0 <= 0x7FFF }.allSatisfy { $0 }, true)
        XCTAssertEqual(internet.map { $0 >= 0x8000 }.allSatisfy { $0 }, true)
    }

    /// 1.1.1.1 does not answer sequence 0. The internet probe must never send
    /// one, at any tick, including after wrap-around.
    func testInternetProbeNeverSendsSequenceZero() {
        for id in UInt32(0)..<70_000 {
            XCTAssertNotEqual(ProbeHost.internet.wireSequence(for: id), 0)
        }
    }

    /// Everything fits the 16 bits the wire actually carries, so truncation in
    /// `ICMPPinger.ping` changes nothing.
    func testSequencesFitTheWire() {
        for id in UInt32(0)..<70_000 {
            for host in ProbeHost.allCases {
                let wire = host.wireSequence(for: id)
                XCTAssertLessThanOrEqual(wire, UInt32(UInt16.max))
                XCTAssertEqual(UInt32(UInt16(truncatingIfNeeded: wire)), wire)
            }
        }
    }

    /// `tick(fromWire:)` recovers the tick from either probe's sequence, which
    /// is what lets a test fake key on the tick without knowing the encoding.
    func testTickRoundTrips() {
        for id in UInt32(0)..<32_768 where id % 13 == 0 {
            for host in ProbeHost.allCases {
                XCTAssertEqual(ProbeHost.tick(fromWire: host.wireSequence(for: id)), id)
            }
        }
    }

    /// 32,768 ticks — 9.1 hours at 1 Hz — before a sequence is reused, which
    /// is the number the warm-up comment depends on.
    func testWrapAroundPeriod() {
        for host in ProbeHost.allCases {
            XCTAssertEqual(host.wireSequence(for: 0), host.wireSequence(for: 32_768))
            XCTAssertNotEqual(host.wireSequence(for: 0), host.wireSequence(for: 32_767))
        }
    }
}
