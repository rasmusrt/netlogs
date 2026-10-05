import Foundation

/// What a session looked like, folded onto its own row (schema 6).
///
/// Every figure here is derivable from `ping_samples`, and that is exactly the
/// problem this solves: deriving them costs a scan per session, and the sidebar
/// wants all of them at once. Fifty sessions at an hour each is 180,000 rows to
/// read and downsample on every render, which is why Phase 9 cut the sidebar
/// sparkline rather than pay it. Stored once at `stopSession`, it is four
/// doubles, two integers and 98 bytes.
///
/// **The internet host, not the router.** Every other one-figure summary in the
/// app is the internet leg — `SessionAnalysis.latency`, the score's components,
/// the verdict's jitter — because that is the number a session is judged by.
/// Naming the columns for the leg they describe leaves room to add the router's
/// later without either being ambiguous in the meantime.
public struct SessionSummary: Codable, Sendable, Equatable {
    /// Replies folded in, past the warm-up. Zero is a real answer — a session
    /// where the host never replied — and distinct from having no summary.
    public let samples: Int
    /// Ticks where the internet host did not reply *inside the timeout*.
    /// Unchanged since schema 6, and still the total — `lost + late`.
    public let failures: Int
    /// Of `failures`, the ticks where nothing came back at all. The packet-loss
    /// figure; see `LiveSummary.noReplyCount`.
    public let lost: Int
    /// Of `failures`, the ticks where the reply arrived after the deadline.
    public let late: Int
    /// Of `failures`, the ticks measured while this app's own throughput test
    /// was saturating the link.
    public let underLoad: Int
    public let minMs: Double
    public let avgMs: Double
    public let maxMs: Double
    public let p95Ms: Double
    /// `nil` when the session was too short to bucket.
    public let spark: Sparkline?

    public init(
        samples: Int, failures: Int,
        lost: Int? = nil, late: Int = 0, underLoad: Int = 0,
        minMs: Double, avgMs: Double, maxMs: Double, p95Ms: Double,
        spark: Sparkline?
    ) {
        self.samples = samples
        self.failures = failures
        // Unstated means every timeout was a lost packet — the same
        // conservative default as `LiveSummary`, so a row written before
        // schema 8 over-reports loss rather than reporting none.
        self.lost = lost ?? failures
        self.late = late
        self.underLoad = underLoad
        self.minMs = minMs
        self.avgMs = avgMs
        self.maxMs = maxMs
        self.p95Ms = p95Ms
        self.spark = spark
    }

    /// Ticks the summary covers — replies plus missed deadlines.
    public var ticks: Int { samples + failures }

    /// Lost packets over ticks. `lost`, not `failures`: a reply that arrived
    /// over the deadline was not lost, and the whole of schema 7 and 8 exists
    /// because this ratio was being quoted as packet loss when it was not.
    public var lossRatio: Double {
        ticks > 0 ? Double(lost) / Double(ticks) : 0
    }

    /// How a session reads at a glance — what the sidebar's status dot shows.
    ///
    /// Three states, and `.clean` draws nothing. A column of green dots is
    /// noise; absence is a stronger "nothing to see here" than a colour, and it
    /// means a dot in the list always means *look at this one*.
    public enum Status: String, Sendable, Codable, CaseIterable {
        /// Packets were lost. The only state that earns red.
        case lost
        /// Nothing lost, but the session was not clean: replies over the
        /// deadline, or a p95 bad enough to notice.
        case degraded
        case clean
    }

    /// Thresholds are `SessionVerdict`'s, deliberately: the dot and the header
    /// a click away have to agree, and they can only do that by sharing the
    /// numbers rather than each picking their own.
    public func status(p95WarnMs: Double = 150) -> Status {
        if lossRatio >= SessionVerdict.lossyLossRatio, lost >= SessionVerdict.minimumFailuresToReport {
            return .lost
        }
        // `lost` below the reporting threshold still is not clean. Claiming a
        // spotless session beside a non-empty failures list is the small lie
        // `SessionVerdict.reason` already refuses to tell.
        if lost > 0 || late > 0 || p95Ms >= p95WarnMs { return .degraded }
        return .clean
    }

    /// One line for the dot's tooltip. Names what is actually wrong, including
    /// when the answer is "we did it to ourselves".
    public var statusSummary: String {
        var parts: [String] = []
        if lost > 0 { parts.append("\(lost) lost") }
        if late > 0 { parts.append("\(late) replied late") }
        if underLoad > 0 { parts.append("\(underLoad) during a speed test") }
        if parts.isEmpty {
            parts.append(samples > 0 ? "every ping answered in time" : "no replies recorded")
        }
        return parts.joined(separator: " · ")
            + String(format: " · p95 %.0f ms", p95Ms)
    }
}

/// A session's latency reduced to a fixed number of buckets, for drawing at
/// thumbnail size.
///
/// Fixed-width on purpose. A sparkline forty pixels wide cannot show more than
/// a few dozen points, so resolving finer would store detail no one can see and
/// make the blob's size depend on how long the session ran — the two properties
/// that would make this worth reading lazily rather than with the row.
public struct Sparkline: Codable, Sendable, Equatable {
    /// Chosen against the sidebar's fixed 200pt column: a 48pt line at 2× is 96
    /// device pixels, so 48 buckets is two pixels a bucket. Wider would be
    /// invisible detail.
    public static let bucketCount = 48

    /// Mean round-trip time per bucket, oldest first. `nil` is a bucket with no
    /// replies — a gap in the line, not a zero in it, which is the distinction
    /// schema 2 and 4 both got wrong in this database.
    public let values: [Double?]

    public init(values: [Double?]) { self.values = values }

    // MARK: - Wire format

    /// `[version, count, count × UInt16 little-endian tenths of a millisecond]`.
    ///
    /// Tenths rather than whole milliseconds because a gateway sparkline sits
    /// between 3 and 9 ms, where integers would quantise the whole line into
    /// three steps. `UInt16` still reaches 6.5 s, well past any ping timeout.
    static let version: UInt8 = 1
    /// A bucket with no replies. Also what an out-of-range value clamps to,
    /// which is safe: nothing that far out belongs on a thumbnail.
    static let noData: UInt16 = .max

    public var data: Data {
        var out = Data([Self.version, UInt8(min(values.count, 255))])
        for value in values.prefix(255) {
            let raw: UInt16
            if let value, value >= 0 {
                let tenths = (value * 10).rounded()
                raw = tenths < Double(Self.noData) ? UInt16(tenths) : Self.noData - 1
            } else {
                raw = Self.noData
            }
            out.append(UInt8(raw & 0xFF))
            out.append(UInt8(raw >> 8))
        }
        return out
    }

    /// `nil` for anything that is not a blob this type wrote — a truncated
    /// read, or a version from a future build. A dropped sparkline costs one
    /// blank row; a misparsed one draws a lie.
    public init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == Self.version else { return nil }
        let count = Int(bytes[1])
        guard bytes.count == 2 + count * 2 else { return nil }
        values = (0..<count).map { index in
            let low = UInt16(bytes[2 + index * 2])
            let high = UInt16(bytes[3 + index * 2])
            let raw = low | (high << 8)
            return raw == Self.noData ? nil : Double(raw) / 10
        }
    }

    /// The replies that fell in each bucket, meaned. `nil` when there is
    /// nothing to draw.
    public init?(bucketedMeans: [Int: Double], bucketCount: Int = Sparkline.bucketCount) {
        guard !bucketedMeans.isEmpty, bucketCount > 0 else { return nil }
        values = (0..<bucketCount).map { bucketedMeans[$0] }
    }

    /// `nil` when every bucket is empty — a line with no points.
    public var range: ClosedRange<Double>? {
        let present = values.compactMap { $0 }
        guard let low = present.min(), let high = present.max() else { return nil }
        return low...high
    }
}
