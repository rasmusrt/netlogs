import Foundation
import NetlogsCore

setvbuf(stdout, nil, _IONBF, 0) // unbuffered so output survives a crash

// Throwaway Phase 1 harness (build order, Phase 1).
//
//   netlogs-ping [routerHost] [internetHost] [seconds]
//
// Defaults: 192.168.1.1  1.1.1.1  60
//
// Verifies: unprivileged ICMP works, the timer does not drift, and missing
// replies record as timeouts rather than vanishing.

let args = CommandLine.arguments
let routerHost   = args.count > 1 ? args[1] : "192.168.1.1"
let internetHost = args.count > 2 ? args[2] : "1.1.1.1"
let seconds      = args.count > 3 ? (Double(args[3]) ?? 60) : 60

let driftThresholdMs = 50.0

/// Minimal lock box so the `@Sendable` tick observer can accumulate.
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&value); lock.unlock() }
    var current: T { lock.lock(); defer { lock.unlock() }; return value }
}

struct HostAgg {
    var replies = 0
    var timeouts = 0
    var failures = 0
    var min = Double.greatestFiniteMagnitude
    var max = 0.0
    var sum = 0.0

    mutating func record(_ ms: Double?) {
        guard let ms else { timeouts += 1; return }
        replies += 1
        min = Swift.min(min, ms)
        max = Swift.max(max, ms)
        sum += ms
    }
    var avg: Double { replies > 0 ? sum / Double(replies) : 0 }
    func line(label: String) -> String {
        let m = replies > 0
            ? String(format: "min %6.2f  avg %6.2f  max %7.2f ms", min, avg, max)
            : "no replies"
        return String(format: "%-22@  %3d replies / %2d timeouts / %d failures   %@",
                      label as NSString, replies, timeouts, failures, m)
    }
}

let maxLatenessMs = Atomic(0.0)
let tickCount = Atomic(0)

print("netlogs-ping — Phase 1 ICMP engine check")
print("  router   : \(routerHost)")
print("  internet : \(internetHost)")
print("  duration : \(Int(seconds))s at 1 Hz\n")

let settings = MonitorSettings(
    routerHost: routerHost,
    internetHost: internetHost,
    pingInterval: .seconds(1),
    pingTimeout: .seconds(2)
)
let engine = MonitorEngine(settings: settings)

let start = Date()
var samples = 0
var firstTimestamp: Date?
var firstID: UInt32 = 0
var maxSampleDriftMs = 0.0
var router = HostAgg()
var internet = HostAgg()
var socketError: String?

do {
    let stream = try await engine.start(onTick: { tick in
        tickCount.mutate { $0 = tick.count }
        maxLatenessMs.mutate { $0 = Swift.max($0, tick.lateness * 1000) }
    })

    for (h, desc) in await engine.resolvedAddresses() {
        print("  resolved \(h) → \(desc)")
    }
    print("")

    let stopper = Task {
        try? await Task.sleep(for: .seconds(seconds))
        await engine.stop()
    }

    for await s in stream {
        samples += 1
        router.record(s.routerMs)
        internet.record(s.internetMs)

        if firstTimestamp == nil { firstTimestamp = s.timestamp; firstID = s.id }
        // Drift of the scheduled timestamp vs a perfect 1 Hz grid anchored on
        // the first sample (the warm-up delay makes "since launch" meaningless).
        let slot = Int64(s.id) - Int64(firstID)
        let expected = firstTimestamp!.addingTimeInterval(Double(slot))
        let sampleDriftMs = s.timestamp.timeIntervalSince(expected) * 1000
        maxSampleDriftMs = Swift.max(maxSampleDriftMs, abs(sampleDriftMs))

        func cell(_ ms: Double?) -> String {
            ms.map { String(format: "%7.2f ms", $0) } ?? "  —  timeout"
        }
        print(String(
            format: "[%4d] sched +%5.1fs  drift %+6.1f ms   router %@   internet %@   phase=%@",
            s.id, s.timestamp.timeIntervalSince(start), sampleDriftMs,
            cell(s.routerMs) as NSString, cell(s.internetMs) as NSString, s.phase.rawValue as NSString
        ))
    }
    stopper.cancel()
} catch let e as ICMPPingerError {
    socketError = e.description
    if case .socketCreationFailed = e { /* highlighted below */ }
} catch {
    socketError = "\(error)"
}

// MARK: - Summary

print("\n──────────────── summary ────────────────")
if let socketError {
    print("RESULT: FAIL — engine did not start")
    print("  \(socketError)")
    print("\n  If this is errno 1 (EPERM) or 13 (EACCES): unprivileged ICMP is")
    print("  blocked in this context. Re-check under the sandboxed app target with")
    print("  com.apple.security.network.client before falling back to NWConnection.")
    exit(1)
}

let ticks = tickCount.current
let expectedSamples = Int(seconds.rounded())
let lateMs = maxLatenessMs.current
let driftOK = lateMs <= driftThresholdMs
// Engine correctness: exactly one sample per tick.
let perTickOK = abs(samples - ticks) <= 1
// Rate correctness: ~one tick per second over the window.
let rateOK = abs(ticks - expectedSamples) <= 2
let anyReplies = router.replies + internet.replies > 0

print(String(format: "samples received      : %d  (expected ~%d)  %@",
             samples, expectedSamples, (perTickOK && rateOK) ? "OK" : "MISMATCH"))
print(String(format: "timer ticks fired     : %d  (one sample each: %@)",
             ticks, perTickOK ? "yes" : "NO"))
print(String(format: "timer max lateness    : %.1f ms  (%@, threshold %.0f ms)",
             lateMs, driftOK ? "PASS" : "FAIL", driftThresholdMs))
print(String(format: "sample grid max drift : %.1f ms", maxSampleDriftMs))
print(router.line(label: "router   \(routerHost)"))
print(internet.line(label: "internet \(internetHost)"))
print("ICMP sockets          : opened OK (unprivileged SOCK_DGRAM, v4/v6 as needed)")

let verdict = perTickOK && rateOK && driftOK && anyReplies
print("\nRESULT: \(verdict ? "PASS" : "FAIL")")
if !anyReplies {
    print("  Zero replies — sends succeeded but nothing came back. On macOS the")
    print("  usual cause is a missing com.apple.security.network.client entitlement")
    print("  on the (unsigned) binary: run via Scripts/run-phase1.sh, which ad-hoc")
    print("  signs it. Only after that, if still zero, consider the NWConnection fallback.")
}
exit(verdict ? 0 : 1)
