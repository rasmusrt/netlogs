import Foundation
import NetlogsCore
import os

/// `NetlogsApp --selftest [router] [internet] [seconds]`
///
/// Runs `MonitorEngine` headless from *inside the real app binary* (bundle
/// identity, code signature, hardened runtime once it's set up) and reports
/// whether ICMP actually works there. This is the repeatable check that the
/// packaged app hasn't regressed the Phase 1 result — the plain CLI is not a
/// substitute because it has a different signature/identity.
enum SelfTest {

    static func runBlocking() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        let sem = DispatchSemaphore(value: 0)
        let code = OSAllocatedUnfairLock<Int32>(initialState: 1)
        Task {
            let result = await run()
            code.withLock { $0 = result }
            sem.signal()
        }
        sem.wait()
        exit(code.withLock { $0 })
    }

    static func run() async -> Int32 {
        let log = Logger(subsystem: "app.netlogs.Netlogs", category: "selftest")

        let args = CommandLine.arguments.drop { $0 != "--selftest" }.dropFirst()
        // The detected gateway, not a guess. A hard-coded 192.168.1.1 reports
        // "ICMP usable: NO" on any network numbered differently, which is a
        // false alarm about the one thing this check exists to prove.
        let router = args.first ?? MacDiagnostics.defaultGateway() ?? "192.168.1.1"
        let internet = args.dropFirst().first ?? "1.1.1.1"
        let seconds = args.dropFirst(2).first.flatMap(Double.init) ?? 20

        let home = ProcessInfo.processInfo.environment["HOME"] ?? "?"
        let sandboxed = home.contains("/Containers/")
        print("NetlogsApp --selftest")
        print("  bundle id : \(Bundle.main.bundleIdentifier ?? "nil")")
        print("  sandboxed : \(sandboxed ? "YES (\(home))" : "no")")
        print("  targets   : \(router), \(internet)   duration: \(Int(seconds))s\n")

        let engine = MonitorEngine(settings: MonitorSettings(
            routerHost: router, internetHost: internet,
            pingInterval: .seconds(1), pingTimeout: .seconds(2)
        ))

        var samples = 0
        var routerReplies = 0, internetReplies = 0
        do {
            let stream = try await engine.start()
            for (h, d) in await engine.resolvedAddresses() { print("  resolved \(h) → \(d)") }
            print("")

            let stopper = Task { try? await Task.sleep(for: .seconds(seconds)); await engine.stop() }
            for await s in stream {
                samples += 1
                if s.routerMs != nil { routerReplies += 1 }
                if s.internetMs != nil { internetReplies += 1 }
                print(String(format: "[%3d] router %@   internet %@",
                             s.id,
                             s.routerMs.map { String(format: "%6.2f ms", $0) } ?? "  timeout",
                             s.internetMs.map { String(format: "%6.2f ms", $0) } ?? "  timeout"))
            }
            stopper.cancel()
        } catch let e as ICMPPingerError {
            print("\nFAIL — engine did not start: \(e)")
            log.error("selftest engine start failed: \(e.description, privacy: .public)")
            return 2
        } catch {
            print("\nFAIL — \(error)")
            return 2
        }

        let anyReplies = routerReplies + internetReplies > 0
        print("\n──── selftest summary ────")
        print("samples       : \(samples)")
        print("router replies : \(routerReplies)")
        print("internet replies: \(internetReplies)")
        print("ICMP usable   : \(anyReplies ? "YES" : "NO")")

        if anyReplies {
            log.notice("selftest PASS — ICMP usable (\(routerReplies + internetReplies, privacy: .public) replies)")
            print("\nRESULT: PASS")
            return 0
        } else {
            log.error("selftest FAIL — no ICMP replies; sandboxed=\(sandboxed, privacy: .public)")
            print("\nRESULT: FAIL — sends succeeded but no replies.")
            print(sandboxed
                  ? "  This binary is App-Sandboxed; ICMP reception is blocked there (PHASE0-FINDINGS.md)."
                  : "  Check reachability, and that the binary is signed with com.apple.security.network.client.")
            return 1
        }
    }
}
