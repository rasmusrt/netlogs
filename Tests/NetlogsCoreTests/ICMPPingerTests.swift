import XCTest
@testable import NetlogsCore

/// Resolution / socket-setup only. Delivering replies needs code-signing with
/// `com.apple.security.network.client` (see PHASE1-FINDINGS §1), which
/// `swift test` binaries don't have — that path is covered by
/// `Scripts/run-phase1.sh`.
final class ICMPPingerTests: XCTestCase {

    func testResolvesV4AndV6LiteralsAndOpensBothSockets() throws {
        let pinger = ICMPPinger(
            hosts: ["1.1.1.1", "2606:4700:4700::1111"],
            timeout: .seconds(1)
        )
        try pinger.open() // getaddrinfo + socket() succeed unprivileged
        defer { pinger.close() }

        XCTAssertEqual(pinger.resolvedDescription(of: "1.1.1.1"), "1.1.1.1 (IPv4)")
        XCTAssertEqual(
            pinger.resolvedDescription(of: "2606:4700:4700::1111"),
            "2606:4700:4700::1111 (IPv6)"
        )
        XCTAssertNil(pinger.resolvedDescription(of: "8.8.8.8"), "not one of its hosts")
    }

    func testUnknownHostPingIsAFailureNotACrash() async throws {
        let pinger = ICMPPinger(hosts: ["1.1.1.1"], timeout: .milliseconds(200))
        try pinger.open()
        defer { pinger.close() }

        let outcome = await pinger.ping(host: "9.9.9.9", sequence: 1)
        guard case .failure = outcome else {
            return XCTFail("expected .failure for an unknown host, got \(outcome)")
        }
    }

    func testResolutionFailureThrows() {
        let pinger = ICMPPinger(hosts: [""], timeout: .seconds(1))
        XCTAssertThrowsError(try pinger.open()) { error in
            guard case ICMPPingerError.resolutionFailed = error else {
                return XCTFail("expected .resolutionFailed, got \(error)")
            }
        }
    }

    // MARK: - Reply demux
    //
    // The socket receives other processes' echo replies — macOS does no
    // per-socket demux — and the kernel owns the ICMP identifier on
    // `SOCK_DGRAM`, so (peer, sequence) alone would accept a stranger's round
    // trip as one of ours. These cover the payload being the third key.

    /// A reply as it arrives on an IPv4 datagram socket: 20-byte IP header,
    /// then the ICMP message.
    private func v4Reply(sequence: UInt16, payload: [UInt8] = ICMPPinger.payload,
                         type: UInt8 = 0, headerWords: UInt8 = 5) -> [UInt8] {
        var ip = [UInt8](repeating: 0, count: Int(headerWords) * 4)
        ip[0] = 0x40 | headerWords
        var icmp: [UInt8] = [type, 0, 0, 0, 0x1A, 0x2B,
                             UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        icmp += payload
        return ip + icmp
    }

    private func sequence(of packet: [UInt8], family: ICMPPinger.Family = .v4) -> UInt16? {
        ICMPPinger.echoReplySequence(packet, count: packet.count, family: family)
    }

    func testAcceptsOurOwnEchoReply() {
        let packet = v4Reply(sequence: 1234)
        XCTAssertEqual(sequence(of: packet), 1234)
    }

    func testRejectsAnotherProcessesReplyOnTheSameSequence() {
        // What `/sbin/ping` sends: a timeval, then an ascending byte pattern
        // from 8 — same length, same host, and a sequence that can collide.
        let foreign = (0..<ICMPPinger.payloadLength).map { UInt8(($0 &+ 8) & 0xFF) }
        XCTAssertNotEqual(foreign, ICMPPinger.payload, "the fixture has to actually differ")
        XCTAssertNil(sequence(of: v4Reply(sequence: 1234, payload: foreign)),
                     "same peer, same sequence, not our packet")
    }

    func testRejectsAReplyOneByteOff() {
        var payload = ICMPPinger.payload
        payload[ICMPPinger.payloadLength - 1] &+= 1
        XCTAssertNil(sequence(of: v4Reply(sequence: 7, payload: payload)),
                     "the whole payload is checked, not a prefix")
    }

    func testRejectsTruncatedAndNonReplyPackets() {
        XCTAssertNil(sequence(of: v4Reply(sequence: 7, payload: Array(ICMPPinger.payload.dropLast()))),
                     "a payload shorter than ours cannot be an echo of it")
        XCTAssertNil(sequence(of: v4Reply(sequence: 7, type: 8)), "echo request, not reply")
        XCTAssertNil(sequence(of: v4Reply(sequence: 7, type: 11)), "time exceeded")
        XCTAssertNil(sequence(of: [], family: .v4), "empty read")
    }

    func testReadsPastAnIPv4HeaderWithOptions() {
        // 24-byte header (6 words). Reading the ICMP message at a fixed offset
        // would land four bytes into it and see a different type and sequence.
        XCTAssertEqual(sequence(of: v4Reply(sequence: 4321, headerWords: 6)), 4321)
    }

    func testIPv6RepliesCarryNoIPHeader() {
        var packet: [UInt8] = [129, 0, 0, 0, 0, 0, 0x00, 0x09]
        packet += ICMPPinger.payload
        XCTAssertEqual(sequence(of: packet, family: .v6), 9)
        packet[0] = 128 // echo request
        XCTAssertNil(sequence(of: packet, family: .v6))
    }

    /// The request we send, turned into the reply it should provoke. Guards the
    /// two ends against drifting apart — a mismatch would reject every reply
    /// and read as total packet loss.
    func testTheRequestWeSendIsAcceptedBackAsAReply() {
        let pinger = ICMPPinger(hosts: ["1.1.1.1"], timeout: .seconds(1))
        var request = pinger.makeEchoRequest(family: .v4, sequence: 999)
        request[0] = 0 // echo request → echo reply
        let packet = [UInt8](repeating: 0, count: 20).enumerated().map { $0.offset == 0 ? 0x45 : $0.element }
            + request
        XCTAssertEqual(sequence(of: packet), 999)
    }
}
