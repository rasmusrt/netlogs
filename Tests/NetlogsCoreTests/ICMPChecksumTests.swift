import XCTest
@testable import NetlogsCore

final class ICMPChecksumTests: XCTestCase {

    func testKnownVector() {
        // type=8 code=0 id=0 seq=0, no payload.
        XCTAssertEqual(icmpChecksum([8, 0, 0, 0, 0, 0, 0, 0]), 0xF7FF)
    }

    func testOddLengthIsHandled() {
        // Must not trap on a trailing byte.
        _ = icmpChecksum([8, 0, 0, 0, 0, 0, 0, 0, 0xAB])
    }

    func testInsertedChecksumMakesWholePacketSumToAllOnes() {
        var pkt = [UInt8](repeating: 0, count: 64)
        pkt[0] = 8
        pkt[6] = 0x12; pkt[7] = 0x34
        for i in 8..<64 { pkt[i] = UInt8(0x40 + (i & 0x3F)) }

        let ck = icmpChecksum(pkt)
        pkt[2] = UInt8(ck >> 8)
        pkt[3] = UInt8(ck & 0xFF)

        // The 16-bit ones-complement sum over a packet that already carries its
        // checksum folds to 0xFFFF — the defining property a receiver checks.
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < pkt.count { sum &+= (UInt32(pkt[i]) << 8) | UInt32(pkt[i + 1]); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
        XCTAssertEqual(sum & 0xFFFF, 0xFFFF)
    }
}
