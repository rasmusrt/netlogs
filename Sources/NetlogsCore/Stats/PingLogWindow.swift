import Foundation

/// The bounded display window for the live ping log (plan §8.3).
///
/// Time-based: keeps only samples within `window` of the newest one (~300 rows
/// at 1 Hz over 5 minutes), with a `hardCap` as a belt-and-braces bound. Full
/// history stays in SQLite; this is only what the table renders.
public struct PingLogWindow: Sendable {
    public let window: Duration
    public let hardCap: Int

    private var buffer: [PingSample] = []

    public init(window: Duration = .seconds(300), hardCap: Int = 1000) {
        precondition(hardCap > 0)
        self.window = window
        self.hardCap = hardCap
    }

    public mutating func append(_ sample: PingSample) {
        buffer.append(sample)

        // Keep samples strictly newer than (newest − window); at 1 Hz over
        // 5 minutes that settles at exactly 300 rows.
        let cutoff = sample.timestamp.addingTimeInterval(-window.timeInterval)
        var drop = 0
        while drop < buffer.count, buffer[drop].timestamp <= cutoff { drop += 1 }
        if drop > 0 { buffer.removeFirst(drop) }

        if buffer.count > hardCap {
            buffer.removeFirst(buffer.count - hardCap)
        }
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// Oldest first.
    public var samples: [PingSample] { buffer }
    /// Newest first — the natural order for a live log table.
    public var newestFirst: ReversedCollection<[PingSample]> { buffer.reversed() }
    public var count: Int { buffer.count }
    public var newest: PingSample? { buffer.last }
}
