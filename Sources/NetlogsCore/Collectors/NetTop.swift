import Foundation

/// Runs `nettop` and turns two cumulative samples into per-process rates.
///
/// ## Why two samples
///
/// `nettop` reports bytes **since each process started**, not since the last
/// call. One sample says which daemon has moved the most data since boot, which
/// is never the question. Two samples a second apart, differenced, say what is
/// moving data *now* — which is the entire question.
///
/// ## Why it cannot be synchronous with anything
///
/// Measured on this machine: `nettop` takes ~5 s to produce its **first**
/// sample, whatever flags it is given — `-l 1` and `-l 2 -s 1` both cost 5.05 s,
/// so the cost is enumeration at startup and the extra sample is nearly free.
/// That is longer than several of the latency episodes this exists to explain.
/// It runs detached, off the ping path, and its result is stored against the
/// moment it was *triggered* rather than the moment it landed.
public enum NetTop {

    /// Parses `nettop -P -l 2 -s <interval> -x -J bytes_in,bytes_out` output.
    ///
    /// Pure and static so the parsing is testable without spawning anything —
    /// the same reason `ICMPPinger.echoReplySequence` is.
    ///
    /// The format is two blocks, each introduced by a header line containing the
    /// column names, with rows of `name.pid  bytes_in  bytes_out`. Values are
    /// cumulative, so this differences block two against block one and divides
    /// by the elapsed interval.
    ///
    /// Whether `output` holds the two sample blocks `parse` needs. Used to tell
    /// a truncated run from a machine that simply was not sending.
    public static func hasTwoSamples(_ output: String) -> Bool {
        output.split(separator: "\n").filter {
            $0.contains("bytes_in") || $0.contains("bytes_out")
        }.count >= 2
    }

    /// A process present in only the second block is skipped rather than
    /// counted from zero: it started during the window, so its cumulative total
    /// is not a rate over that window and treating it as one would report a
    /// process that sent 2 KB since launch as sending 2 KB/s.
    public static func parse(_ output: String, interval: Double) -> [ProcessTraffic] {
        guard interval > 0 else { return [] }

        var blocks: [[String: (inBytes: Double, outBytes: Double, pid: Int32)]] = []
        var current: [String: (inBytes: Double, outBytes: Double, pid: Int32)] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !fields.isEmpty else { continue }

            // The header repeats once per sample and is what separates them.
            if fields.contains("bytes_in") || fields.contains("bytes_out") {
                if !current.isEmpty { blocks.append(current); current = [:] }
                continue
            }
            guard fields.count >= 3,
                  let inBytes = Double(fields[fields.count - 2]),
                  let outBytes = Double(fields[fields.count - 1])
            else { continue }

            // "Claude Helper.6021" — the name may contain spaces, so the pid is
            // whatever follows the *last* dot of everything before the numbers.
            let label = fields[0..<(fields.count - 2)].joined(separator: " ")
            guard let dot = label.lastIndex(of: "."),
                  let pid = Int32(label[label.index(after: dot)...])
            else { continue }
            let name = String(label[label.startIndex..<dot])
            // Keyed by name.pid, not by name: two helpers of the same app are
            // two rows in nettop and differencing them together would attribute
            // one's traffic to the other.
            current["\(name).\(pid)"] = (inBytes, outBytes, pid)
        }
        if !current.isEmpty { blocks.append(current) }
        guard blocks.count >= 2 else { return [] }

        let first = blocks[blocks.count - 2], last = blocks[blocks.count - 1]
        var out: [ProcessTraffic] = []
        for (key, new) in last {
            guard let old = first[key] else { continue } // started mid-window
            // Counters do not go backwards; if they appear to, the pid was
            // reused and the two readings are different processes.
            let deltaIn = new.inBytes - old.inBytes
            let deltaOut = new.outBytes - old.outBytes
            guard deltaIn >= 0, deltaOut >= 0, deltaIn + deltaOut > 0 else { continue }
            let name = String(key[key.startIndex..<(key.lastIndex(of: ".") ?? key.endIndex)])
            out.append(ProcessTraffic(name: name, pid: new.pid,
                                      bytesInPerSecond: deltaIn / interval,
                                      bytesOutPerSecond: deltaOut / interval))
        }
        // Busiest uploader first — the question is always "what is sending".
        out.sort {
            $0.bytesOutPerSecond == $1.bytesOutPerSecond
                ? $0.bytesInPerSecond > $1.bytesInPerSecond
                : $0.bytesOutPerSecond > $1.bytesOutPerSecond
        }
        return Array(out.prefix(TrafficCapture.topCount))
    }
}

/// A source of per-process traffic rates. `NetTopRunner` is the real one; tests
/// inject fakes, on the same pattern as `DiagnosticsProvider`.
public protocol TrafficSampling: Sendable {
    /// Two samples `interval` apart, differenced.
    ///
    /// `nil` means the sample could not be taken — no `nettop`, no permission,
    /// output that did not parse. An **empty array** means it was taken and
    /// nothing on this Mac was moving bytes.
    ///
    /// Those are emphatically not the same fact, and this app has been bitten
    /// three times by a type that could not tell them apart (schema 2, 4 and
    /// 7). "Nothing was sending" is the single most useful thing a capture can
    /// say — it is what points at another device on the network — and
    /// collapsing it into the failure case would throw away the finding.
    ///
    /// Never throws. A capture that failed must not interrupt a session.
    func sample(interval: Double) async -> [ProcessTraffic]?
}

/// Spawns `/usr/bin/nettop`.
///
/// The app is deliberately **not sandboxed** (`Support/Netlogs.entitlements`:
/// the App Sandbox blocks ICMP reception on macOS 26 with no entitlement to
/// unblock it), so spawning a subprocess needs no temporary exception. If the
/// app is ever sandboxed for an App Store build, this is one of the things that
/// stops working.
public struct NetTopRunner: TrafficSampling {
    public init() {}

    public func sample(interval: Double = 1) async -> [ProcessTraffic]? {
        let seconds = max(1, Int(interval.rounded()))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-l", "2", "-s", "\(seconds)", "-x",
                             "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil // no nettop, or no permission — not "nothing was sending"
        }
        // Read before waiting. A pipe that fills while nobody is draining it
        // blocks the child, and `nettop -x` on a busy machine writes several
        // hundred lines per sample.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Two blocks are required to difference anything. Fewer means the run
        // was cut short, which is a failure, not a quiet machine.
        guard NetTop.hasTwoSamples(text) else { return nil }
        return NetTop.parse(text, interval: Double(seconds))
    }
}
