import Foundation

/// Everything about one session, in one shape (plan §10). CSV / JSON / text
/// reports are all rendered from this.
public struct SessionExport: Codable, Sendable {
    public var session: SessionState
    public var summary: LiveSummary
    public var samples: [PingSample]
    public var throughput: [ThroughputResult]
    public var diagnostics: [DiagnosticsSnapshot]
    /// What this Mac was sending during the session's latency episodes.
    ///
    /// Included because a report whose whole purpose is to be handed to someone
    /// else should carry the answer to their first question — "was it you?" —
    /// rather than making them ask. It names processes on this machine only;
    /// see `PRIVACY.md`.
    public var traffic: [TrafficCapture]

    public init(
        session: SessionState,
        samples: [PingSample],
        throughput: [ThroughputResult] = [],
        diagnostics: [DiagnosticsSnapshot] = [],
        traffic: [TrafficCapture] = []
    ) {
        self.session = session
        self.samples = samples
        self.throughput = throughput
        self.diagnostics = diagnostics
        self.traffic = traffic

        // The warm-up exclusion, for the fourth time in this codebase and the
        // first time in this file — which is why a session the app called clean
        // exported with one failure and a 580 ms router maximum. `samples`
        // still carries everything: the row dumps are raw data, and it is only
        // the *judgement* — the summary and the failure list — that has to
        // match what the screens judged.
        var builder = LiveSummaryBuilder()
        for sample in Self.analysed(samples) { builder.add(sample) }
        self.summary = builder.summary
    }

    /// Carries an existing summary through rather than rebuilding it. Private
    /// because there is exactly one honest use: a filtered *view* of a session,
    /// which must still describe the session it came from.
    private init(
        session: SessionState,
        summary: LiveSummary,
        samples: [PingSample],
        throughput: [ThroughputResult],
        diagnostics: [DiagnosticsSnapshot],
        traffic: [TrafficCapture] = []
    ) {
        self.session = session
        self.summary = summary
        self.samples = samples
        self.throughput = throughput
        self.diagnostics = diagnostics
        self.traffic = traffic
    }

    private static func analysed(_ samples: [PingSample]) -> [PingSample] {
        samples.filter { $0.id >= PingSample.warmupSampleCount }
    }

    /// The failures the app would show, warm-up excluded — one definition, used
    /// by both the failures-only export and the text report, so they cannot
    /// disagree with each other or with the Failures sheet.
    public var failures: [PingSample] {
        Self.analysed(samples).filter { $0.routerMs == nil || $0.internetMs == nil }
    }

    /// Drops non-failure samples and **keeps the session's own summary**.
    ///
    /// It used to rebuild the summary from the failures alone, so a healthy
    /// 600-sample session with one drop exported a summary block claiming
    /// 1 sample, 1 failure and zero internet replies — 100% packet loss, in a
    /// file whose whole purpose is to be read by someone who was not there.
    public func filteredToFailures() -> SessionExport {
        SessionExport(
            session: session,
            summary: summary,
            samples: failures,
            throughput: throughput,
            diagnostics: diagnostics,
            // Kept, for the same reason the summary is: a failures-only export
            // is the one most likely to be sent to someone else, and "what was
            // this Mac sending at the time" is the first thing they will ask.
            traffic: traffic
        )
    }
}

public enum ExportFormat: String, CaseIterable, Sendable {
    case csv, json, text

    public var fileExtension: String { self == .text ? "txt" : rawValue }
}

public enum SessionExporter {

    public static func data(
        _ export: SessionExport, as format: ExportFormat, failuresOnly: Bool = false
    ) throws -> Data {
        switch format {
        case .json: return try json(failuresOnly ? export.filteredToFailures() : export)
        case .csv:  return Data(csv(failuresOnly ? export.filteredToFailures() : export).utf8)
        case .text: return Data(text(export, failuresOnly: failuresOnly).utf8)
        }
    }

    public static func filename(
        _ export: SessionExport, format: ExportFormat, failuresOnly: Bool = false
    ) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let scope = failuresOnly ? "-failures" : ""
        return "netlogs-\(f.string(from: export.session.startedAt))\(scope).\(format.fileExtension)"
    }

    // MARK: - JSON

    public static func json(_ export: SessionExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    /// Bytes per second, human-sized. Duplicated from the app's `Fmt.rate`
    /// rather than shared: `NetlogsCore` cannot see `NetlogsApp`, and the
    /// export's formatting is part of the report's contract with whoever reads
    /// it, not part of the UI's.
    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        }
        if bytesPerSecond >= 1_000 {
            return String(format: "%.0f kB/s", bytesPerSecond / 1_000)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    // MARK: - CSV (the ping log — the bulk data)

    public static func csv(_ export: SessionExport) -> String {
        // `*_late_ms` are the round trips that missed the ping timeout. An
        // empty `router_ms` with an empty `router_late_ms` is a lost packet; an
        // empty `router_ms` with a number beside it is a slow one. Whoever
        // reads this file needs to be able to tell those apart, because the
        // whole file exists to be handed to someone who was not there.
        var out = "seq,timestamp,router_ms,internet_ms,router_late_ms,internet_late_ms,phase\n"
        out.reserveCapacity(export.samples.count * 64)
        let iso = ISO8601DateFormatter()
        func num(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
        for s in export.samples {
            out += "\(s.id),\(iso.string(from: s.timestamp)),"
                + "\(num(s.routerMs)),\(num(s.internetMs)),"
                + "\(num(s.routerLateMs)),\(num(s.internetLateMs)),\(s.phase.rawValue)\n"
        }
        return out
    }

    // MARK: - Text report

    /// Human-readable report. `failuresOnly` trims it to the session header and
    /// the failure log — the "Failures only" menu scope used to filter the
    /// samples out from under the summary builder, which left every scope
    /// producing a near-identical page.
    public static func text(_ export: SessionExport, failuresOnly: Bool = false) -> String {
        let s = export.session
        let sum = export.summary
        let width = 64

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "dd MMM yyyy 'at' HH:mm:ss"

        var out = ""
        func line(_ str: String = "") { out += str + "\n" }
        func rule() { line(String(repeating: "─", count: width)) }
        func thin() { line("  " + String(repeating: "-", count: width - 4)) }

        let averages = ThroughputAverages(results: export.throughput)
        let verdict = SessionVerdict.evaluate(summary: sum, throughput: averages)
        let failures = export.failures

        func failureLog() {
            rule(); line("MISSED DEADLINES (\(failures.count))"); rule()
            guard !failures.isEmpty else {
                line("  None — every ping got a reply from both hosts, in time.")
                line()
                return
            }
            line("  " + "Timestamp".padding(toLength: 29, withPad: " ", startingAt: 0)
                 + rjust("Router", 10) + "  " + rjust("Internet", 10) + "   Load")
            thin()
            let cap = 500
            // "LOST" and a late round trip are different rows now. The old
            // report printed "FAILED" for both, which is how a session that
            // lost nothing came to be sent to an ISP as fourteen lost packets.
            func cell(_ ms: Double?, _ lateMs: Double?) -> String {
                if let ms { return String(format: "%10.1f", ms) }
                if let lateMs { return String(format: "%8.1f↑", lateMs) }
                return rjust("LOST", 10)
            }
            for f in failures.prefix(cap) {
                line("  " + df.string(from: f.timestamp)
                        .padding(toLength: 29, withPad: " ", startingAt: 0)
                     + cell(f.routerMs, f.routerLateMs) + "  "
                     + cell(f.internetMs, f.internetLateMs)
                     + (f.isUnderLoad ? "   \(f.phase.rawValue)" : ""))
            }
            line()
            line(String(format: "  ↑ replied after the %.1f s timeout — the packet "
                        + "arrived, late. Not a lost packet.",
                        s.settings.pingTimeout.timeInterval))
            if failures.count > cap {
                line("  … and \(failures.count - cap) more — full list in the CSV export.")
            }
            line()
        }

        rule()
        line("NETLOGS SESSION REPORT")
        rule()
        line("Session      : \(s.id.uuidString)")
        line("Started      : \(df.string(from: s.startedAt))")
        line("Stopped      : \(s.stoppedAt.map { df.string(from: $0) } ?? "— (not cleanly stopped)")")
        line("Duration     : \(formatDuration(s.duration))")
        line("Router host  : \(s.settings.routerHost)")
        line("Internet host: \(s.settings.internetHost)")
        if let isp = export.throughput.last?.isp { line("ISP          : \(isp)") }
        line("Verdict      : \(verdict.headline) — "
             + SessionVerdict.reason(for: verdict, summary: sum, throughput: averages))
        line()

        if failuresOnly {
            failureLog()
            rule()
            return out
        }

        rule(); line("PING SUMMARY"); rule()
        // Three numbers where there was one. "N failed" is true and reads as
        // packet loss, and on the session this was written for none of the 14
        // failures was a lost packet: every one was a reply over the deadline,
        // and three were the app's own upload test filling the uplink.
        let per = sum.noReplyCount == 0
            ? ""
            : " (~1 in \(max(1, sum.totalSamples / sum.noReplyCount)))"
        var counts = ["\(sum.totalSamples) samples", "\(sum.noReplyCount) lost\(per)"]
        if sum.lateCount > 0 { counts.append("\(sum.lateCount) replied late") }
        if sum.failuresUnderLoad > 0 {
            counts.append("\(sum.failuresUnderLoad) during a speed test")
        }
        line("  " + counts.joined(separator: " · ")
             + " · \(formatDuration(s.duration))   — values in ms")
        line()
        line("  " + "Host".padding(toLength: 10, withPad: " ", startingAt: 0)
             + rjust("Min", 8) + rjust("Avg", 9) + rjust("Max", 9)
             + rjust("Jitter", 9) + rjust("Timeouts", 11))
        thin()
        line(statRow("Router", sum.router, timeouts: sum.routerTimeouts))
        line(statRow("Internet", sum.internet, timeouts: sum.internetTimeouts))
        // Max above is the slowest reply that fitted inside the timeout, which
        // on a session with late replies is a property of the setting rather
        // than of the link. Say what the link actually did.
        for (name, stat, late) in [("Router", sum.router, sum.routerLate),
                                   ("Internet", sum.internet, sum.internetLate)]
        where late.count > 0 {
            line(String(format: "  %@: %d repl%@ after the timeout, slowest %.0f ms",
                        name, late.count, late.count == 1 ? "y" : "ies",
                        late.worst(timelyMax: stat.max)))
        }
        line()
        line("  " + "Host".padding(toLength: 10, withPad: " ", startingAt: 0)
             + rjust("p50", 8) + rjust("p95", 9) + rjust("p99", 9))
        thin()
        line(pctRow("Router", sum.router))
        line(pctRow("Internet", sum.internet))
        line()

        failureLog()

        if !export.traffic.isEmpty {
            rule(); line("TRAFFIC AT SLOW MOMENTS (\(export.traffic.count))"); rule()
            line("  Captured on this Mac when the internet slowed while the router")
            line("  stayed fast. Other devices on the network do not appear here.")
            line()
            for capture in export.traffic {
                let internet = capture.internetMs.map { String(format: "%.0f ms", $0) } ?? "no reply"
                line("\(df.string(from: capture.timestamp))  — internet \(internet)")
                if capture.processes.isEmpty {
                    line("  Nothing on this Mac was sending.")
                } else {
                    for proc in capture.processes.prefix(6) {
                        line(String(format: "  %-28@ %10@ up  %10@ down",
                                    proc.name as NSString,
                                    Self.rate(proc.bytesOutPerSecond) as NSString,
                                    Self.rate(proc.bytesInPerSecond) as NSString))
                    }
                }
                line()
            }
        }

        if !export.throughput.isEmpty {
            rule(); line("THROUGHPUT  (\(export.throughput.count) test\(export.throughput.count == 1 ? "" : "s"))"); rule()
            for t in export.throughput {
                line("\(df.string(from: t.timestamp))")
                line(String(format: "  down %.1f Mbps   up %.1f Mbps   %.0f MB transferred",
                            t.downloadMbps, t.uploadMbps, Double(t.totalBytes) / 1_000_000))
                // "—" where a window caught no replies. A report is read by
                // someone who was not there, so it must not print a confident
                // 0 ms for a measurement that never happened.
                func ms(_ value: Double?) -> String {
                    value.map { String(format: "%.0f ms", $0) } ?? "—"
                }
                line("  latency  idle \(ms(t.idleLatencyMs)) → "
                     + "download \(ms(t.downloadLatencyMs)) → upload \(ms(t.uploadLatencyMs))")
                line("  bufferbloat "
                     + (t.bufferbloatMs.map { String(format: "+%.0f ms", $0) } ?? "—")
                     + (t.serverLocation.map { "   via \($0)" } ?? ""))
                line()
            }
        }

        if let d = export.diagnostics.last {
            rule(); line("DIAGNOSTICS  (latest of \(export.diagnostics.count) stored)"); rule()
            line("Interface : \(d.interfaceName) (\(d.kind.rawValue))")
            if let rssi = d.rssi { line("RSSI/SNR  : \(rssi) dBm / \(d.snr.map { "\($0)" } ?? "—") dB") }
            if let tx = d.txRateMbps { line(String(format: "Tx rate   : %.0f Mbps", tx)) }
            if let band = d.band { line("Radio     : \(band) \(d.phyMode ?? "") \(d.channel.map { "ch \($0)" } ?? "")") }
            if let sec = d.security { line("Security  : \(sec)") }
            line("IP        : \(d.ipAddress ?? "—") / \(d.subnetMask ?? "—")   MTU \(d.mtu.map { "\($0)" } ?? "—")")
            line("Gateway   : \(d.gateway ?? "—")")
            line("DNS       : \(d.dnsServers.isEmpty ? "—" : d.dnsServers.joined(separator: ", "))")
        }

        line(); rule()
        return out
    }

    private static func rjust(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }

    private static func statRow(_ host: String, _ p: PingStat, timeouts: Int) -> String {
        "  " + host.padding(toLength: 10, withPad: " ", startingAt: 0)
        + String(format: "%8.1f%9.1f%9.1f%9.1f", p.min, p.avg, p.max, p.jitter)
        + String(format: "%11d", timeouts)
    }

    private static func pctRow(_ host: String, _ p: PingStat) -> String {
        "  " + host.padding(toLength: 10, withPad: " ", startingAt: 0)
        + String(format: "%8.1f%9.1f%9.1f", p.p50, p.p95, p.p99)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return String(format: "%dh %02dm %02ds", s / 3600, (s % 3600) / 60, s % 60)
    }
}
