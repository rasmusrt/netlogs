import Foundation
import Observation
import NetlogsCore

/// Every sample in which a host failed to reply, for the whole session.
///
/// This exists because the log table's Failures filter would otherwise be a
/// trap. The live table is a five-minute window, so filtering *it* would show
/// "failures in the last five minutes" — a session with a forty-second outage
/// forty minutes ago would render empty, which reads as "no failures" and is
/// worse than useless. The filter therefore switches data *source*, not just
/// predicate.
///
/// Its own `@Observable` object, so appending a failure never invalidates the
/// chart or the stat cards (plan §8.2). Failures are rare, so in practice this
/// is written a handful of times an hour.
@MainActor
@Observable
final class FailureLog {

    /// Bounded so a genuinely broken connection can't grow this without limit.
    /// At 1 Hz a fully offline session would otherwise accumulate 3,600 rows an
    /// hour; the oldest are dropped and the count keeps counting.
    static let capacity = 500

    private(set) var rows: [PingSample] = []
    /// Total failures seen, including any dropped past `capacity`.
    private(set) var total = 0

    var isTruncated: Bool { total > rows.count }

    /// Newest first, matching the live log's row order.
    ///
    /// Stored rather than computed for the same reason as `PingLog.rows`: a
    /// computed reverse allocates on every read, and SwiftUI reads on every
    /// layout pass. Failures are rare, so this is rebuilt almost never.
    private(set) var newestFirst: [PingSample] = []

    func append(_ sample: PingSample) {
        guard sample.routerTimedOut || sample.internetTimedOut else { return }
        total += 1
        rows.append(sample)
        if rows.count > Self.capacity {
            rows.removeFirst(rows.count - Self.capacity)
        }
        newestFirst = rows.reversed()
    }

    func reset() {
        rows.removeAll()
        newestFirst = []
        total = 0
    }
}
