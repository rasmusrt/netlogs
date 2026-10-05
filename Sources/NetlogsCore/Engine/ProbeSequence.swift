import Foundation

/// Which of the two probes a request belongs to, and the wire sequence it gets.
///
/// The engine pings two hosts on every tick, and `ICMPPinger` matches replies on
/// `(peer address, sequence, echoed payload)`. When the two hosts are the *same*
/// address — a typo, or a router that is also the configured internet host —
/// all three parts collide: same peer, same sequence, and the payload is a
/// fixed pattern shared by every request we send. `ping()` resolves the clash by
/// timing the earlier probe out, so a host answering everything was reported as
/// 5 replies and 9 timeouts (PHASE9-NOTES, "The ICMP socket's third key").
///
/// Nothing in the reply can distinguish the two probes, because on `SOCK_DGRAM`
/// the kernel owns the ICMP identifier and RFC 792 echoes our own payload back
/// unchanged. So the requests have to be made distinguishable *before* they are
/// sent: the top bit of the sequence names the probe, and each host walks its
/// own 15-bit space.
public enum ProbeHost: String, Sendable, CaseIterable {
    case router
    case internet

    /// The half of the 16-bit sequence space this probe uses:
    /// router `0x0000…0x7FFF`, internet `0x8000…0xFFFF`.
    var spaceBit: UInt32 { self == .router ? 0x0000 : 0x8000 }

    /// The wire sequence for tick `id`.
    ///
    /// Wrap-around is 32,768 ticks — 9.1 hours at 1 Hz, against a ping timeout
    /// measured in seconds, so a reused sequence is always long resolved. Two
    /// consequences worth knowing rather than rediscovering:
    ///
    /// - The internet probe never sends sequence 0. It cannot: its space starts
    ///   at `0x8000`. That matters because 1.1.1.1 does not answer sequence 0 —
    ///   measured — which is the reason the caller offsets the tick id by one.
    /// - The router probe *does* reach 0, once, at 9.1 hours. The local gateway
    ///   answers 0 quite happily, also measured.
    public func wireSequence(for id: UInt32) -> UInt32 {
        (id & 0x7FFF) | spaceBit
    }

    /// The tick a wire sequence came from, with the probe bit stripped.
    ///
    /// The inverse of ``wireSequence(for:)`` modulo the 15-bit wrap. Exists so
    /// nothing has to re-derive the encoding by hand — a test fake keyed on the
    /// sequence did exactly that, and silently started reading every internet
    /// ping as a loaded one the moment the probe bit appeared.
    public static func tick(fromWire wire: UInt32) -> UInt32 {
        wire & 0x7FFF
    }
}
