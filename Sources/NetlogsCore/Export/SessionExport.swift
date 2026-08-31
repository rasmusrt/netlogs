import Foundation

/// Everything about one session, in one shape (plan §10). CSV / JSON / text
/// reports are all rendered from this.
public struct SessionExport: Codable, Sendable {
    public var session: SessionState
    public var summary: LiveSummary
    public var samples: [PingSample]
    public var throughput: [ThroughputResult]
    public var diagnostics: [DiagnosticsSnapshot]

    public init(
        session: SessionState,
        samples: [PingSample],
        throughput: [ThroughputResult] = [],
        diagnostics: [DiagnosticsSnapshot] = []
    ) {
        self.session = session
        self.samples = samples
        self.throughput = throughput
        self.diagnostics = diagnostics

        var builder = LiveSummaryBuilder()
        for sample in samples { builder.add(sample) }
        self.summary = builder.summary
    }

    /// `failuresOnly` keeps the session/summary but drops non-failure samples.
    /// Used for the row-oriented CSV/JSON exports; the text report keeps the
    /// full sample set and filters internally so its summary block still
    /// describes the whole session.
    public func filteredToFailures() -> SessionExport {
        SessionExport(
            session: session,
            samples: samples.filter { $0.routerMs == nil || $0.internetMs == nil },
            throughput: throughput,
            diagnostics: diagnostics
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

    // MARK: - CSV (the ping log — the bulk data)

    public static func csv(_ export: SessionExport) -> String {
        var out = "seq,timestamp,router_ms,internet_ms,phase\n"
        out.reserveCapacity(export.samples.count * 48)
        let iso = ISO8601DateFormatter()
        for s in export.samples {
            let r = s.routerMs.map { String(format: "%.3f", $0) } ?? ""
            let i = s.internetMs.map { String(format: "%.3f", $0) } ?? ""
            out += "\(s.id),\(iso.string(from: s.timestamp)),\(r),\(i),\(s.phase.rawValue)\n"
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
        let failures = export.samples.filter { $0.routerMs == nil || $0.internetMs == nil }

        func failureLog() {
            rule(); line("PING FAILURES (\(failures.count))"); rule()
            guard !failures.isEmpty else {
                line("  None — every ping got a reply from both hosts.")
                line()
                return
            }
            line("  " + "Timestamp".padding(toLength: 29, withPad: " ", startingAt: 0)
                 + rjust("Router", 8) + "    " + rjust("Internet", 8))
            thin()
            let cap = 500
            for f in failures.prefix(cap) {
                let r = f.routerMs.map { String(format: "%8.1f", $0) } ?? rjust("FAILED", 8)
                let i = f.internetMs.map { String(format: "%8.1f", $0) } ?? rjust("FAILED", 8)
                line("  " + df.string(from: f.timestamp)
                        .padding(toLength: 29, withPad: " ", startingAt: 0)
                     + r + "    " + i)
            }
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
        let per = sum.failureCount == 0
            ? ""
            : " (~1 in \(max(1, sum.totalSamples / sum.failureCount)))"
        line("  \(sum.totalSamples) samples · \(sum.failureCount) failed\(per)"
             + " · \(formatDuration(s.duration))   — values in ms")
        line()
        line("  " + "Host".padding(toLength: 10, withPad: " ", startingAt: 0)
             + rjust("Min", 8) + rjust("Avg", 9) + rjust("Max", 9)
             + rjust("Jitter", 9) + rjust("Timeouts", 11))
        thin()
        line(statRow("Router", sum.router, timeouts: sum.routerTimeouts))
        line(statRow("Internet", sum.internet, timeouts: sum.internetTimeouts))
        line()
        line("  " + "Host".padding(toLength: 10, withPad: " ", startingAt: 0)
             + rjust("p50", 8) + rjust("p95", 9) + rjust("p99", 9))
        thin()
        line(pctRow("Router", sum.router))
        line(pctRow("Internet", sum.internet))
        line()

        failureLog()

        if !export.throughput.isEmpty {
            rule(); line("THROUGHPUT  (\(export.throughput.count) test\(export.throughput.count == 1 ? "" : "s"))"); rule()
            for t in export.throughput {
                line("\(df.string(from: t.timestamp))")
                line(String(format: "  down %.1f Mbps   up %.1f Mbps   %.0f MB transferred",
                            t.downloadMbps, t.uploadMbps, Double(t.totalBytes) / 1_000_000))
                line(String(format: "  latency  idle %.0f ms → download %.0f ms → upload %.0f ms",
                            t.idleLatencyMs, t.downloadLatencyMs, t.uploadLatencyMs))
                line(String(format: "  bufferbloat +%.0f ms%@", t.bufferbloatMs,
                            t.serverLocation.map { "   via \($0)" } ?? ""))
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
