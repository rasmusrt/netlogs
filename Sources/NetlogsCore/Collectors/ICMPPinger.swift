import Darwin
import Foundation

/// Errors from ``ICMPPinger/open()``.
public enum ICMPPingerError: Error, CustomStringConvertible {
    case resolutionFailed(host: String, message: String)
    /// The kernel refused the socket. `code` is `errno`. Under the App Sandbox
    /// this is what a missing `com.apple.security.network.client` entitlement
    /// looks like; `EPERM`/`EACCES` here is the Phase 1 "stop and resolve" signal.
    case socketCreationFailed(code: Int32, message: String)

    public var description: String {
        switch self {
        case .resolutionFailed(let host, let msg):
            return "could not resolve \(host): \(msg)"
        case .socketCreationFailed(let code, let msg):
            return "ICMP socket() failed (errno \(code): \(msg))"
        }
    }
}

/// Sends ICMP echo requests to a **set of hosts over shared unprivileged
/// datagram sockets** (one for IPv4, one for IPv6) and matches replies by
/// (peer address, sequence, echoed payload).
///
/// `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` / `IPPROTO_ICMPV6` work on Darwin
/// without root, inside the sandbox, with `com.apple.security.network.client`.
/// macOS delivers a copy of every echo reply to every ICMP datagram socket of
/// the matching protocol and does no per-socket demux, so there is one socket
/// per family and replies are sorted out in userspace by the `recvfrom` peer
/// address. See `PHASE1-FINDINGS.md`.
///
/// That sorting cannot lean on the ICMP identifier — the kernel owns it on
/// `SOCK_DGRAM` — so the echoed payload is the third part of the key. See
/// ``echoReplySequence(_:count:family:)``.
public final class ICMPPinger: ICMPPinging, @unchecked Sendable {

    enum Family: Sendable { case v4, v6 }

    private let hosts: [String]
    private let timeout: Duration
    /// Serial queue that is the single synchronization domain for all mutable
    /// state below — send, receive, and timeout all run here.
    private let queue: DispatchQueue

    private var fdV4: Int32 = -1
    private var fdV6: Int32 = -1
    private var srcV4: DispatchSourceRead?
    private var srcV6: DispatchSourceRead?
    private var isOpen = false

    /// host string → resolved destination.
    private var destinations: [String: Destination] = [:]

    private struct Destination {
        var storage: sockaddr_storage
        let len: socklen_t
        let family: Family
        /// Raw address bytes — 4 (v4) or 16 (v6). The demux key; matches the
        /// `recvfrom` peer address of a reply.
        let addrKey: [UInt8]
    }

    /// In-flight requests keyed by (peer address, 16-bit wire sequence).
    private var pending: [Key: Pending] = [:]

    private struct Key: Hashable {
        let addrKey: [UInt8]
        let sequence: UInt16
    }

    private struct Pending {
        let sentAt: DispatchTime
        let continuation: CheckedContinuation<PingOutcome, Never>
        let deadline: DispatchSourceTimer
    }

    static let payloadLength = 56 // classic ping data size → 64-byte packet

    /// The data section every request carries, and that every reply to one of
    /// our requests echoes back verbatim (RFC 792: "the data received in the
    /// echo message must be returned in the echo reply message").
    ///
    /// Defined once because it is now read at both ends — written into a
    /// request and checked on a reply — and a drift between the two would
    /// silently reject every reply.
    static let payload: [UInt8] = (0..<payloadLength).map { UInt8(0x40 &+ ($0 & 0x3F)) }

    public init(hosts: [String], timeout: Duration) {
        self.hosts = hosts
        self.timeout = timeout
        self.queue = DispatchQueue(label: "netlogs.icmp")
    }

    // MARK: - ICMPPinging

    public func open() throws {
        try queue.sync { try openLocked() }
    }

    public func close() {
        queue.sync { closeLocked() }
    }

    public func ping(host: String, sequence: UInt32) async -> PingOutcome {
        let wire = UInt16(truncatingIfNeeded: sequence)
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isOpen else {
                    continuation.resume(returning: .failure("pinger not open"))
                    return
                }
                guard let dest = destinations[host] else {
                    continuation.resume(returning: .failure("unknown host \(host)"))
                    return
                }
                let fd = (dest.family == .v4) ? fdV4 : fdV6
                guard fd >= 0 else {
                    continuation.resume(returning: .failure("no \(dest.family) socket"))
                    return
                }

                let key = Key(addrKey: dest.addrKey, sequence: wire)
                if let existing = pending.removeValue(forKey: key) {
                    existing.deadline.cancel()
                    existing.continuation.resume(returning: .timeout)
                }

                let packet = makeEchoRequest(family: dest.family, sequence: wire)
                var storage = dest.storage
                let sentAt = DispatchTime.now()
                let n: Int = packet.withUnsafeBytes { raw in
                    withUnsafePointer(to: &storage) { sp in
                        sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, raw.baseAddress, raw.count, 0, sa, dest.len)
                        }
                    }
                }
                if n < 0 {
                    continuation.resume(returning: .failure("sendto: \(Self.errnoString())"))
                    return
                }

                let deadline = DispatchSource.makeTimerSource(queue: queue)
                deadline.schedule(deadline: .now() + .nanoseconds(timeout.wholeNanoseconds))
                deadline.setEventHandler { [self] in
                    guard let p = pending.removeValue(forKey: key) else { return }
                    p.deadline.cancel()
                    p.continuation.resume(returning: .timeout)
                }
                pending[key] = Pending(sentAt: sentAt, continuation: continuation, deadline: deadline)
                deadline.resume()
            }
        }
    }

    /// "1.1.1.1 (IPv4)" style description of what a host resolved to, or `nil`
    /// if it isn't one of this pinger's hosts / it isn't open yet.
    public func resolvedDescription(of host: String) -> String? {
        queue.sync {
            guard let d = destinations[host] else { return nil }
            return "\(Self.ipString(d.addrKey, d.family)) (\(d.family == .v4 ? "IPv4" : "IPv6"))"
        }
    }

    // MARK: - Socket lifecycle (queue-isolated)

    private func openLocked() throws {
        guard !isOpen else { return }

        for host in hosts {
            destinations[host] = try resolve(host)
        }
        let needV4 = destinations.values.contains { $0.family == .v4 }
        let needV6 = destinations.values.contains { $0.family == .v6 }

        if needV4 {
            fdV4 = try makeSocket(.v4)
            srcV4 = makeReadSource(fd: fdV4, family: .v4)
        }
        if needV6 {
            do {
                fdV6 = try makeSocket(.v6)
            } catch {
                closeLocked()
                throw error
            }
            srcV6 = makeReadSource(fd: fdV6, family: .v6)
        }

        isOpen = true
        srcV4?.resume()
        srcV6?.resume()
    }

    private func closeLocked() {
        isOpen = false
        srcV4?.cancel(); srcV4 = nil
        srcV6?.cancel(); srcV6 = nil
        if fdV4 >= 0 { Darwin.close(fdV4); fdV4 = -1 }
        if fdV6 >= 0 { Darwin.close(fdV6); fdV6 = -1 }
        for (_, p) in pending {
            p.deadline.cancel()
            p.continuation.resume(returning: .failure("pinger closed"))
        }
        pending.removeAll()
    }

    private func makeSocket(_ family: Family) throws -> Int32 {
        let (domain, proto): (Int32, Int32) =
            (family == .v4) ? (AF_INET, IPPROTO_ICMP) : (AF_INET6, IPPROTO_ICMPV6)
        let s = socket(domain, SOCK_DGRAM, proto)
        guard s >= 0 else {
            throw ICMPPingerError.socketCreationFailed(code: errno, message: Self.errnoString())
        }
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        if family == .v6 {
            var on: Int32 = 1
            setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return s
    }

    private func makeReadSource(fd: Int32, family: Family) -> DispatchSourceRead {
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [self] in drain(family: family) }
        return rs
    }

    private func resolve(_ host: String) throws -> Destination {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICHOST // fast path: literal IPs

        var result: UnsafeMutablePointer<addrinfo>?
        var err = getaddrinfo(host, nil, &hints, &result)
        if err != 0 {
            hints.ai_flags = 0
            err = getaddrinfo(host, nil, &hints, &result)
        }
        guard err == 0, let info = result else {
            throw ICMPPingerError.resolutionFailed(host: host, message: String(cString: gai_strerror(err)))
        }
        defer { freeaddrinfo(result) }

        let family: Family = (info.pointee.ai_family == AF_INET6) ? .v6 : .v4
        var storage = sockaddr_storage()
        let len = info.pointee.ai_addrlen
        withUnsafeMutablePointer(to: &storage) { dst in
            dst.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { dstBytes in
                info.pointee.ai_addr.withMemoryRebound(to: UInt8.self, capacity: Int(len)) { srcBytes in
                    dstBytes.update(from: srcBytes, count: Int(len))
                }
            }
        }
        return Destination(storage: storage, len: len, family: family, addrKey: Self.addrKey(storage))
    }

    // MARK: - Receive path (queue-isolated)

    private func drain(family: Family) {
        let fd = (family == .v4) ? fdV4 : fdV6
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var peer = sockaddr_storage()
            var peerLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &peer) { pp in
                pp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    buffer.withUnsafeMutableBytes { buf in
                        recvfrom(fd, buf.baseAddress, buf.count, 0, sa, &peerLen)
                    }
                }
            }
            if n <= 0 { break } // EWOULDBLOCK / EAGAIN when drained
            handlePacket(buffer, count: n, family: family, peer: peer)
        }
    }

    private func handlePacket(_ buffer: [UInt8], count: Int, family: Family, peer: sockaddr_storage) {
        guard let sequence = Self.echoReplySequence(buffer, count: count, family: family) else { return }
        let key = Key(addrKey: Self.addrKey(peer), sequence: sequence)
        guard let p = pending.removeValue(forKey: key) else { return }
        p.deadline.cancel()

        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- p.sentAt.uptimeNanoseconds
        p.continuation.resume(returning: .reply(rttMs: Double(elapsedNs) / 1_000_000))
    }

    /// The wire sequence of `buffer[0..<count]` if it is an echo reply to one
    /// of *our* requests, `nil` otherwise.
    ///
    /// The payload check is not belt-and-braces. `SOCK_DGRAM` gives the kernel
    /// the ICMP identifier, so the header leaves only (peer address, sequence)
    /// to demux by — and macOS hands every ICMP datagram socket a copy of every
    /// reply, not just the ones answering that socket. Instrumenting the socket
    /// showed replies arriving from hosts this app never pinged, carrying
    /// another process's sequence numbers. Two of those numbers landing on a
    /// host we are pinging is enough to record someone else's round trip as
    /// ours; requiring the 56-byte pattern back as well makes that collision
    /// require a packet that is, byte for byte, an answer to a request we sent.
    ///
    /// Static and pure so the demux rules are testable: the receive path itself
    /// needs `com.apple.security.network.client`, which `swift test` binaries
    /// do not have (PHASE1-FINDINGS §1).
    static func echoReplySequence(_ buffer: [UInt8], count: Int, family: Family) -> UInt16? {
        // v4 SOCK_DGRAM ICMP receives carry the IPv4 header; v6 does not.
        let offset: Int
        if family == .v4 {
            guard count > 0, (buffer[0] >> 4) == 4 else { return nil }
            offset = Int(buffer[0] & 0x0F) * 4
        } else {
            offset = 0
        }
        guard count >= offset + 8 + payloadLength else { return nil }

        let type = buffer[offset]
        let expected: UInt8 = (family == .v4) ? 0 : 129 // echo reply
        guard type == expected else { return nil }

        let start = offset + 8
        for i in 0..<payloadLength where buffer[start + i] != payload[i] { return nil }

        return (UInt16(buffer[offset + 6]) << 8) | UInt16(buffer[offset + 7])
    }

    // MARK: - Address helpers

    /// Raw address bytes from a `sockaddr_storage`: `sin_addr` (4) or `sin6_addr` (16).
    /// Darwin layout: `sa_len` at byte 0, `sa_family` at byte 1.
    private static func addrKey(_ storage: sockaddr_storage) -> [UInt8] {
        var s = storage
        return withUnsafeBytes(of: &s) { raw in
            let family = raw.load(fromByteOffset: 1, as: UInt8.self)
            if family == UInt8(AF_INET6) {
                return Array(raw[8..<24])   // sockaddr_in6.sin6_addr
            }
            return Array(raw[4..<8])        // sockaddr_in.sin_addr
        }
    }

    private static func ipString(_ addrKey: [UInt8], _ family: Family) -> String {
        let af = (family == .v4) ? AF_INET : AF_INET6
        var out = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return addrKey.withUnsafeBytes { raw -> String in
            out.withUnsafeMutableBufferPointer { dst -> String in
                guard inet_ntop(af, raw.baseAddress, dst.baseAddress, socklen_t(dst.count)) != nil,
                      let base = dst.baseAddress else { return "" }
                return String(cString: base)
            }
        }
    }

    // MARK: - Packet construction

    func makeEchoRequest(family: Family, sequence: UInt16) -> [UInt8] {
        var pkt = [UInt8](repeating: 0, count: 8 + Self.payloadLength)
        pkt[0] = (family == .v4) ? 8 : 128 // echo request
        pkt[1] = 0                         // code
        pkt[2] = 0; pkt[3] = 0             // checksum (v4 filled below; kernel fills v6)
        pkt[4] = 0; pkt[5] = 0             // identifier — kernel owns this on SOCK_DGRAM
        pkt[6] = UInt8(sequence >> 8)
        pkt[7] = UInt8(sequence & 0xFF)
        pkt.replaceSubrange(8..., with: Self.payload)
        if family == .v4 {
            let ck = icmpChecksum(pkt)
            pkt[2] = UInt8(ck >> 8)
            pkt[3] = UInt8(ck & 0xFF)
        }
        return pkt
    }

    private static func errnoString() -> String {
        String(cString: strerror(errno))
    }
}

/// Standard 16-bit one's-complement checksum over `bytes`.
func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < bytes.count {
        sum &+= (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
        i += 2
    }
    if i < bytes.count {
        sum &+= UInt32(bytes[i]) << 8
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) &+ (sum >> 16)
    }
    return UInt16(~sum & 0xFFFF)
}
