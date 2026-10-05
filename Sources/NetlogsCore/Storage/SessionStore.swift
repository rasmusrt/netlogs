import Foundation
import SQLite3

public enum SessionStoreError: Error, CustomStringConvertible {
    case open(path: String, message: String)
    case sqlite(code: Int32, message: String)

    public var description: String {
        switch self {
        case .open(let path, let msg): return "could not open \(path): \(msg)"
        case .sqlite(let code, let msg): return "sqlite error \(code): \(msg)"
        }
    }
}

/// Persists a session and its ping samples to SQLite (plan §9), with **batched
/// writes** — samples buffer in memory and flush every ~10 s in one
/// transaction (plan §8.5). The session row is written on start and updated on
/// stop, so a crash leaves a readable row with `stopped_at` NULL.
///
/// Raw `SQLite3` C API, no external dependency (plan §4). A dedicated serial
/// queue is the single synchronisation domain — the sqlite handle is only
/// touched there (same pattern as `ICMPPinger`).
public final class SessionStore: @unchecked Sendable {

    private let path: String
    private let queue = DispatchQueue(label: "netlogs.store")

    private var db: OpaquePointer?
    private var insertSample: OpaquePointer?

    private var buffer: [(sessionID: UUID, sample: PingSample)] = []
    private var flushTimer: ScheduledTimer?
    private let flushQueue = DispatchQueue(label: "netlogs.store.flush")

    /// `~/Library/Application Support/Netlogs/netlogs.sqlite`, creating the dir.
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Netlogs", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("netlogs.sqlite")
    }

    public init(url: URL, flushInterval: Duration = .seconds(10)) throws {
        self.path = url.path

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(handle)
            throw SessionStoreError.open(path: path, message: msg)
        }
        self.db = handle

        sqlite3_busy_timeout(handle, 3000) // wait out a transient lock instead of failing
        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = NORMAL;")
        try exec("PRAGMA foreign_keys = ON;")
        try migrate()
        self.insertSample = try prepare("""
            INSERT OR REPLACE INTO ping_samples
                (session_id, seq, timestamp, router_ms, internet_ms,
                 router_late_ms, internet_late_ms, phase)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """)

        if flushInterval > .zero {
            let timer = ScheduledTimer(interval: flushInterval, queue: flushQueue) { [weak self] _ in
                self?.enqueueFlush()
            }
            flushTimer = timer
            timer.start()
        }
    }

    private func enqueueFlush() {
        queue.async { [weak self] in try? self?.flushLocked() }
    }

    deinit {
        sqlite3_finalize(insertSample)
        sqlite3_close_v2(db)
    }

    // MARK: - Session lifecycle

    public func startSession(_ settings: MonitorSettings, id: UUID = UUID(), startedAt: Date = Date()) throws -> SessionState {
        try queue.sync {
            let stmt = try prepare("""
                INSERT INTO sessions
                    (id, started_at, stopped_at, router_host, internet_host,
                     ping_interval_ns, ping_timeout_ns, throughput_enabled,
                     throughput_interval, diagnostics_interval_ns)
                VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            bind(stmt, 2, startedAt.timeIntervalSince1970)
            bind(stmt, 3, settings.routerHost)
            bind(stmt, 4, settings.internetHost)
            bind(stmt, 5, Int64(settings.pingInterval.wholeNanoseconds))
            bind(stmt, 6, Int64(settings.pingTimeout.wholeNanoseconds))
            bind(stmt, 7, Int64(settings.throughputEnabled ? 1 : 0))
            bind(stmt, 8, Int64(settings.throughputInterval))
            bind(stmt, 9, Int64(settings.diagnosticsInterval.wholeNanoseconds))
            try step(stmt)
            return SessionState(id: id, startedAt: startedAt, stoppedAt: nil, settings: settings)
        }
    }

    /// Flush remaining samples, mark the session stopped, and fold it down to
    /// the summary its sidebar row is drawn from (``SessionSummary``).
    ///
    /// The fold happens here rather than on read because this is the one moment
    /// the session is both complete and already in hand — after the flush there
    /// is nothing left to arrive, and the alternative is a scan per row per
    /// render. A session that never reaches this method is caught by
    /// ``backfillSummaries(excluding:)`` instead.
    public func stopSession(_ id: UUID, at stoppedAt: Date = Date()) throws {
        try queue.sync {
            try flushLocked()
            let stmt = try prepare("UPDATE sessions SET stopped_at = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, stoppedAt.timeIntervalSince1970)
            bind(stmt, 2, id.uuidString)
            try step(stmt)
            // Deliberately not fatal. A session that stopped is stopped even if
            // summarising it fails; the backfill will try again next launch.
            try? writeSummaryLocked(computeSummaryLocked(id), for: id)
        }
    }

    // MARK: - Samples

    /// Buffer a sample. Not on disk until the next ``flush()`` (or the timer).
    public func append(_ sample: PingSample, to sessionID: UUID) {
        queue.async { self.buffer.append((sessionID, sample)) }
    }

    public func append(_ samples: [PingSample], to sessionID: UUID) {
        queue.async { for s in samples { self.buffer.append((sessionID, s)) } }
    }

    /// Write every buffered sample in one transaction.
    public func flush() throws {
        try queue.sync { try flushLocked() }
    }

    public var pendingCount: Int {
        queue.sync { buffer.count }
    }

    // MARK: - Diagnostics

    /// Store one diagnostics snapshot (JSON blob). Called only when the change
    /// detector says so, so this writes straight through — no batching needed.
    public func appendDiagnostics(_ snapshot: DiagnosticsSnapshot, to sessionID: UUID) throws {
        try queue.sync {
            let json = try JSONEncoder().encode(snapshot)
            let stmt = try prepare("""
                INSERT OR REPLACE INTO diagnostics_snapshots (session_id, timestamp, json)
                VALUES (?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, sessionID.uuidString)
            bind(stmt, 2, snapshot.timestamp.timeIntervalSince1970)
            bind(stmt, 3, String(decoding: json, as: UTF8.self))
            try step(stmt)
        }
    }

    // MARK: - Traffic captures

    /// Store one traffic capture (JSON blob), on the same straight-through
    /// pattern as diagnostics: they are rare by construction — one per latency
    /// episode, floored at one per ten minutes — so there is nothing to batch.
    public func appendTrafficCapture(_ capture: TrafficCapture, to sessionID: UUID) throws {
        try queue.sync {
            let json = try JSONEncoder().encode(capture)
            let stmt = try prepare("""
                INSERT OR REPLACE INTO traffic_captures (session_id, timestamp, json)
                VALUES (?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, sessionID.uuidString)
            bind(stmt, 2, capture.timestamp.timeIntervalSince1970)
            bind(stmt, 3, String(decoding: json, as: UTF8.self))
            try step(stmt)
        }
    }

    /// Stored traffic captures for a session, oldest first.
    public func trafficCaptures(for id: UUID) throws -> [TrafficCapture] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT json FROM traffic_captures WHERE session_id = ? ORDER BY timestamp;
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            let decoder = JSONDecoder()
            var out: [TrafficCapture] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cString = sqlite3_column_text(stmt, 0) else { continue }
                let data = Data(String(cString: cString).utf8)
                if let capture = try? decoder.decode(TrafficCapture.self, from: data) {
                    out.append(capture)
                }
            }
            return out
        }
    }

    // MARK: - Gateway telemetry

    /// Store one gateway poll. Straight through, like diagnostics: the change
    /// detector holds this to about one row per 5 s.
    public func appendWANSnapshot(_ snapshot: WANSnapshot, to sessionID: UUID) throws {
        try queue.sync {
            let json = try JSONEncoder().encode(snapshot)
            let stmt = try prepare("""
                INSERT OR REPLACE INTO wan_snapshots (session_id, timestamp, json)
                VALUES (?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, sessionID.uuidString)
            bind(stmt, 2, snapshot.timestamp.timeIntervalSince1970)
            bind(stmt, 3, String(decoding: json, as: UTF8.self))
            try step(stmt)
        }
    }

    /// Stored gateway polls for a session, oldest first.
    public func wanSnapshots(for id: UUID) throws -> [WANSnapshot] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT json FROM wan_snapshots WHERE session_id = ? ORDER BY timestamp;
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            let decoder = JSONDecoder()
            var out: [WANSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cString = sqlite3_column_text(stmt, 0) else { continue }
                let data = Data(String(cString: cString).utf8)
                if let snapshot = try? decoder.decode(WANSnapshot.self, from: data) {
                    out.append(snapshot)
                }
            }
            return out
        }
    }

    // MARK: - Throughput

    public func appendThroughput(_ result: ThroughputResult, to sessionID: UUID) throws {
        try queue.sync {
            let stmt = try prepare("""
                INSERT OR REPLACE INTO throughput_results
                    (id, session_id, timestamp, download_mbps, upload_mbps,
                     bytes_down, bytes_up, idle_latency_ms, download_latency_ms,
                     upload_latency_ms, bufferbloat_ms, idle_jitter_ms,
                     packet_loss, idle_low_ms, idle_high_ms,
                     download_jitter_ms, download_low_ms, download_high_ms,
                     upload_jitter_ms, upload_low_ms, upload_high_ms,
                     isp, server_location)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, result.id.uuidString)
            bind(stmt, 2, sessionID.uuidString)
            bind(stmt, 3, result.timestamp.timeIntervalSince1970)
            bind(stmt, 4, result.downloadMbps)
            bind(stmt, 5, result.uploadMbps)
            bind(stmt, 6, Int64(result.bytesDownloaded))
            bind(stmt, 7, Int64(result.bytesUploaded))
            // NULL, not 0 — schema 3 exists so an unmeasured figure stops
            // reading back as a measured zero, and schema 5 extends that to
            // the four latency columns for the same reason.
            bindOptional(stmt, 8, result.idleLatencyMs)
            bindOptional(stmt, 9, result.downloadLatencyMs)
            bindOptional(stmt, 10, result.uploadLatencyMs)
            bindOptional(stmt, 11, result.bufferbloatMs)
            bindOptional(stmt, 12, result.idleJitterMs)
            bindOptional(stmt, 13, result.packetLoss)
            bindOptional(stmt, 14, result.idleLowMs)
            bindOptional(stmt, 15, result.idleHighMs)
            bindOptional(stmt, 16, result.downloadJitterMs)
            bindOptional(stmt, 17, result.downloadLowMs)
            bindOptional(stmt, 18, result.downloadHighMs)
            bindOptional(stmt, 19, result.uploadJitterMs)
            bindOptional(stmt, 20, result.uploadLowMs)
            bindOptional(stmt, 21, result.uploadHighMs)
            if let isp = result.isp { bind(stmt, 22, isp) } else { sqlite3_bind_null(stmt, 22) }
            if let loc = result.serverLocation { bind(stmt, 23, loc) } else { sqlite3_bind_null(stmt, 23) }
            try step(stmt)
        }
    }

    public func throughputCount(for id: UUID) throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM throughput_results WHERE session_id = ?;")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Throughput results for a session, oldest first.
    public func throughputResults(for id: UUID) throws -> [ThroughputResult] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id, timestamp, download_mbps, upload_mbps, bytes_down, bytes_up,
                       idle_latency_ms, download_latency_ms, upload_latency_ms,
                       idle_jitter_ms, packet_loss,
                       idle_low_ms, idle_high_ms,
                       download_jitter_ms, download_low_ms, download_high_ms,
                       upload_jitter_ms, upload_low_ms, upload_high_ms,
                       isp, server_location
                FROM throughput_results WHERE session_id = ? ORDER BY timestamp;
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            var out: [ThroughputResult] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ThroughputResult(
                    id: UUID(uuidString: text(stmt, 0)) ?? UUID(),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    downloadMbps: sqlite3_column_double(stmt, 2),
                    uploadMbps: sqlite3_column_double(stmt, 3),
                    bytesDownloaded: Int(sqlite3_column_int64(stmt, 4)),
                    bytesUploaded: Int(sqlite3_column_int64(stmt, 5)),
                    // optionalDouble, not column_double: SQLite reads a NULL
                    // REAL back as 0.0, which would undo schema 5 on the way
                    // out of the database.
                    idleLatencyMs: optionalDouble(stmt, 6),
                    downloadLatencyMs: optionalDouble(stmt, 7),
                    uploadLatencyMs: optionalDouble(stmt, 8),
                    idleJitterMs: optionalDouble(stmt, 9),
                    packetLoss: optionalDouble(stmt, 10),
                    idleLowMs: optionalDouble(stmt, 11),
                    idleHighMs: optionalDouble(stmt, 12),
                    downloadJitterMs: optionalDouble(stmt, 13),
                    downloadLowMs: optionalDouble(stmt, 14),
                    downloadHighMs: optionalDouble(stmt, 15),
                    uploadJitterMs: optionalDouble(stmt, 16),
                    uploadLowMs: optionalDouble(stmt, 17),
                    uploadHighMs: optionalDouble(stmt, 18),
                    isp: sqlite3_column_type(stmt, 19) == SQLITE_NULL ? nil : text(stmt, 19),
                    serverLocation: sqlite3_column_type(stmt, 20) == SQLITE_NULL ? nil : text(stmt, 20)
                ))
            }
            return out
        }
    }

    public func diagnosticsCount(for id: UUID) throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM diagnostics_snapshots WHERE session_id = ?;")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Stored diagnostics snapshots for a session, oldest first.
    public func diagnostics(for id: UUID) throws -> [DiagnosticsSnapshot] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT json FROM diagnostics_snapshots WHERE session_id = ? ORDER BY timestamp;
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            let decoder = JSONDecoder()
            var out: [DiagnosticsSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cString = sqlite3_column_text(stmt, 0) else { continue }
                let data = Data(String(cString: cString).utf8)
                if let snap = try? decoder.decode(DiagnosticsSnapshot.self, from: data) {
                    out.append(snap)
                }
            }
            return out
        }
    }

    // MARK: - Delete / prune / size (plan §7 / §13 Q3)

    /// Delete a session and everything under it (FK `ON DELETE CASCADE`).
    public func deleteSession(_ id: UUID) throws {
        try queue.sync {
            let stmt = try prepare("DELETE FROM sessions WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            try step(stmt)
        }
    }

    /// Drop sessions that stopped before `cutoff` (a still-running session is
    /// never pruned). Returns how many were removed.
    @discardableResult
    /// Deletes sessions that ended before `cutoff`.
    ///
    /// "Ended" is the last thing that actually happened in the session, not
    /// `stopped_at`. A force-quit leaves `stopped_at` NULL forever, and the
    /// original `stopped_at IS NOT NULL` filter meant those rows could never be
    /// pruned at all — they accumulated for the life of the database. They were
    /// only visible because the sidebar flagged them; hiding that flag without
    /// fixing this would have buried a leak.
    ///
    /// A session still recording is inherently safe: its newest sample is
    /// "now", so it can never fall before a cutoff in the past.
    public func prune(stoppedBefore cutoff: Date) throws -> Int {
        try queue.sync {
            let stmt = try prepare("""
                DELETE FROM sessions
                WHERE COALESCE(
                        stopped_at,
                        (SELECT MAX(timestamp) FROM ping_samples p
                         WHERE p.session_id = sessions.id),
                        started_at
                      ) < ?;
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, cutoff.timeIntervalSince1970)
            try step(stmt)
            return Int(sqlite3_changes(db))
        }
    }

    /// Reclaim disk space after large deletes.
    ///
    /// In WAL mode `VACUUM` alone does not reclaim anything yet: it writes the
    /// rebuilt database into the WAL, so the database plus its WAL is briefly
    /// *larger* than before, until some later checkpoint copies it back. The
    /// truncating checkpoint does that now and empties the WAL, so the space
    /// is actually free when this returns, and the size Settings shows is the
    /// size after cleanup.
    public func vacuum() throws {
        try queue.sync {
            try exec("VACUUM;")
            try exec("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    /// Size on disk of the database plus its WAL/SHM sidecars.
    public func databaseByteCount() -> Int {
        let fm = FileManager.default
        return [path, path + "-wal", path + "-shm"].reduce(0) { total, p in
            let size = (try? fm.attributesOfItem(atPath: p))?[.size] as? Int
            return total + (size ?? 0)
        }
    }

    /// Flush + stop the timer + close the handle. Safe to call once.
    public func close() {
        queue.sync {
            try? flushLocked()
            flushTimer?.stop()
            flushTimer = nil
            sqlite3_finalize(insertSample); insertSample = nil
            sqlite3_close_v2(db); db = nil
        }
    }

    // MARK: - Reads

    public func loadSession(_ id: UUID) throws -> SessionState? {
        try queue.sync { try loadSessionLocked(id) }
    }

    /// All sessions, newest first.
    public func allSessions() throws -> [SessionState] {
        try queue.sync {
            let stmt = try prepare("SELECT id FROM sessions ORDER BY started_at DESC;")
            defer { sqlite3_finalize(stmt) }
            var ids: [UUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let u = UUID(uuidString: text(stmt, 0)) { ids.append(u) }
            }
            return try ids.compactMap { try loadSessionLocked($0) }
        }
    }

    /// Sessions whose recorded extent overlaps `range` — the Analysis screen's
    /// selection (`docs/analysis-screen-plan.md`).
    ///
    /// A session's end is `stopped_at` when it has one, and otherwise its last
    /// stored sample: six of twenty sessions in a real database were never
    /// stopped cleanly, and measuring those against *now* would sweep in every
    /// crashed session ever recorded. That fallback mirrors
    /// `SessionState.duration`, so the screen and the row agree about when a
    /// session ended.
    ///
    /// Sessions are selected by overlap and reported *whole*. Clipping an
    /// overnight run at a range boundary would produce a figure describing half
    /// a night while labelled with the session.
    public func sessionsOverlapping(_ range: ClosedRange<Date>) throws -> [SessionState] {
        try queue.sync {
            let stmt = try prepare("""
                SELECT s.id FROM sessions s
                WHERE s.started_at <= ?
                  AND COALESCE(
                        s.stopped_at,
                        (SELECT MAX(p.timestamp) FROM ping_samples p WHERE p.session_id = s.id),
                        s.started_at
                      ) >= ?
                ORDER BY s.started_at DESC;
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, range.upperBound.timeIntervalSince1970)
            bind(stmt, 2, range.lowerBound.timeIntervalSince1970)

            var ids: [UUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let u = UUID(uuidString: text(stmt, 0)) { ids.append(u) }
            }
            return try ids.compactMap { try loadSessionLocked($0) }
        }
    }

    /// Reduces each session's ping stream in SQLite — the same figures
    /// `LiveSummaryBuilder` folds, without constructing a `PingSample`.
    ///
    /// `LAG`, not a self-join on `seq - 1`. The join is measurably faster
    /// (210 ms against 510 ms over 167k samples, because `(session_id, seq)` is
    /// the primary key), and it is *wrong here*: it pairs on consecutive
    /// sequence **numbers**, while the Swift path folds rows in the order it
    /// reads them and therefore pairs across a hole in the sequence. Sessions
    /// with holes are exactly the ones this screen must not disagree about — a
    /// sleeping Mac is the common cause of both. Optimise this only against the
    /// equality test, on data that has a gap in it.
    ///
    /// The window runs *after* the warm-up filter, so the first analysed sample
    /// has no predecessor — matching a builder started at that sample. Without
    /// that ordering the ~580 ms ICMP warm-up spike leaks into jitter.
    public func pingAggregates(
        for ids: [UUID], skippingWarmup: Bool = true
    ) throws -> [UUID: PingAggregate] {
        guard !ids.isEmpty else { return [:] }
        return try queue.sync {
            let slots = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let stmt = try prepare("""
                WITH windowed AS (
                    SELECT session_id, timestamp, router_ms, internet_ms,
                           router_late_ms, internet_late_ms,
                           phase <> 'idle' AS under_load,
                           -- "silent" is the strict one: nothing inside the
                           -- timeout and nothing inside the grace window
                           -- either. It is what `failed` used to be taken to
                           -- mean, and the difference between the two is the
                           -- difference between a lost packet and a slow one.
                           (router_ms IS NULL AND router_late_ms IS NULL)
                             OR (internet_ms IS NULL AND internet_late_ms IS NULL) AS silent,
                           router_ms IS NULL OR internet_ms IS NULL AS failed,
                           LAG(router_ms)   OVER w AS prev_router,
                           LAG(internet_ms) OVER w AS prev_internet
                    FROM ping_samples
                    WHERE session_id IN (\(slots)) AND seq >= ?
                    WINDOW w AS (PARTITION BY session_id ORDER BY seq)
                )
                SELECT session_id,
                       COUNT(*), MIN(timestamp), MAX(timestamp),
                       SUM(router_ms IS NULL), SUM(internet_ms IS NULL),
                       SUM(failed),
                       COUNT(router_ms), MIN(router_ms), MAX(router_ms),
                       COALESCE(SUM(router_ms), 0),
                       COALESCE(SUM(CASE WHEN router_ms IS NOT NULL AND prev_router IS NOT NULL
                                         THEN ABS(router_ms - prev_router) END), 0),
                       SUM(CASE WHEN router_ms IS NOT NULL AND prev_router IS NOT NULL
                                THEN 1 ELSE 0 END),
                       COUNT(internet_ms), MIN(internet_ms), MAX(internet_ms),
                       COALESCE(SUM(internet_ms), 0),
                       COALESCE(SUM(CASE WHEN internet_ms IS NOT NULL AND prev_internet IS NOT NULL
                                         THEN ABS(internet_ms - prev_internet) END), 0),
                       SUM(CASE WHEN internet_ms IS NOT NULL AND prev_internet IS NOT NULL
                                THEN 1 ELSE 0 END),
                       SUM(silent),
                       SUM(failed AND NOT silent),
                       SUM(failed AND under_load),
                       SUM(under_load),
                       COUNT(router_late_ms), MIN(router_late_ms), MAX(router_late_ms),
                       COALESCE(SUM(router_late_ms), 0),
                       COUNT(internet_late_ms), MIN(internet_late_ms), MAX(internet_late_ms),
                       COALESCE(SUM(internet_late_ms), 0),
                       SUM(internet_ms IS NULL AND internet_late_ms IS NULL AND NOT under_load)
                FROM windowed GROUP BY session_id;
                """)
            defer { sqlite3_finalize(stmt) }
            for (offset, id) in ids.enumerated() {
                bind(stmt, Int32(offset + 1), id.uuidString)
            }
            bind(stmt, Int32(ids.count + 1),
                 Int64(skippingWarmup ? PingSample.warmupSampleCount : 0))

            var out: [UUID: PingAggregate] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(stmt, 0)) else { continue }
                func date(_ index: Int32) -> Date? {
                    sqlite3_column_type(stmt, index) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
                }
                func optional(_ index: Int32) -> Double? {
                    sqlite3_column_type(stmt, index) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, index)
                }
                func count(_ index: Int32) -> Int { Int(sqlite3_column_int64(stmt, index)) }

                out[id] = PingAggregate(
                    totalSamples: count(1),
                    firstSampleAt: date(2), lastSampleAt: date(3),
                    routerTimeouts: count(4), internetTimeouts: count(5),
                    failureCount: count(6),
                    noReplyCount: count(19), lateCount: count(20),
                    failuresUnderLoad: count(21), samplesUnderLoad: count(22),
                    internetNoRepliesIdle: count(31),
                    router: HostAggregate(
                        replies: count(7), min: optional(8), max: optional(9),
                        sum: sqlite3_column_double(stmt, 10),
                        jitterSum: sqlite3_column_double(stmt, 11), jitterPairs: count(12),
                        late: LateReplies(count: count(23), min: optional(24), max: optional(25),
                                          sum: sqlite3_column_double(stmt, 26))
                    ),
                    internet: HostAggregate(
                        replies: count(13), min: optional(14), max: optional(15),
                        sum: sqlite3_column_double(stmt, 16),
                        jitterSum: sqlite3_column_double(stmt, 17), jitterPairs: count(18),
                        late: LateReplies(count: count(27), min: optional(28), max: optional(29),
                                          sum: sqlite3_column_double(stmt, 30))
                    )
                )
            }
            return out
        }
    }

    /// 1 ms latency buckets per session, straight from SQL.
    ///
    /// The same buckets `LatencyHistogram` builds sample by sample, so
    /// percentiles computed from these are identical to the live path's — which
    /// is what lets the Analysis screen and a saved session agree by
    /// construction rather than by inspection.
    public func latencyHistograms(
        for ids: [UUID], host: PingHostColumn = .internet, skippingWarmup: Bool = true
    ) throws -> [UUID: LatencyHistogram] {
        guard !ids.isEmpty else { return [:] }
        return try queue.sync {
            let slots = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT session_id, CAST(\(host.column) AS INTEGER) AS bucket, COUNT(*)
                FROM ping_samples
                WHERE session_id IN (\(slots)) AND seq >= ? AND \(host.column) IS NOT NULL
                GROUP BY session_id, bucket;
                """)
            defer { sqlite3_finalize(stmt) }
            for (offset, id) in ids.enumerated() {
                bind(stmt, Int32(offset + 1), id.uuidString)
            }
            bind(stmt, Int32(ids.count + 1),
                 Int64(skippingWarmup ? PingSample.warmupSampleCount : 0))

            var out: [UUID: LatencyHistogram] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(stmt, 0)) else { continue }
                out[id, default: LatencyHistogram()].add(
                    sqlite3_column_double(stmt, 1),
                    count: Int(sqlite3_column_int64(stmt, 2))
                )
            }
            return out
        }
    }

    /// Latency buckets per session, per calendar day, per hour of day.
    ///
    /// Grouped by day *and* hour rather than by hour alone, so the day count a
    /// time-of-day claim needs falls out of the same query — "slow at 20:00"
    /// means nothing until it has happened on several different days.
    ///
    /// `phase = 'idle'` is not optional. Only 1,340 of 190,277 samples in a
    /// real database are non-idle, but they average 66 ms against 40 — so
    /// without it a nightly speed test manufactures an evening congestion
    /// pattern out of the app's own measurements.
    ///
    /// `localtime` applies the machine's *current* zone to historical rows, so
    /// a range spanning a DST change or travel mislabels hours. Bucketing by
    /// day-and-hour keeps the fold in Swift, where `Calendar` can fix that if
    /// it ever matters.
    public func hourlyBuckets(
        for ids: [UUID], host: PingHostColumn = .internet, skippingWarmup: Bool = true
    ) throws -> [HourlyBucket] {
        guard !ids.isEmpty else { return [] }
        return try queue.sync {
            let slots = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let stmt = try prepare("""
                SELECT session_id,
                       strftime('%Y-%m-%d', timestamp, 'unixepoch', 'localtime') AS day,
                       CAST(strftime('%H', timestamp, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                       CAST(\(host.column) AS INTEGER) AS bucket,
                       COUNT(*)
                FROM ping_samples
                WHERE session_id IN (\(slots)) AND seq >= ?
                  AND \(host.column) IS NOT NULL AND phase = 'idle'
                GROUP BY session_id, day, hour, bucket;
                """)
            defer { sqlite3_finalize(stmt) }
            for (offset, id) in ids.enumerated() {
                bind(stmt, Int32(offset + 1), id.uuidString)
            }
            bind(stmt, Int32(ids.count + 1),
                 Int64(skippingWarmup ? PingSample.warmupSampleCount : 0))

            var merged: [HourKey: LatencyHistogram] = [:]
            var owners: [HourKey: UUID] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = UUID(uuidString: text(stmt, 0)) else { continue }
                let key = HourKey(sessionID: id, day: text(stmt, 1),
                                  hour: Int(sqlite3_column_int64(stmt, 2)))
                merged[key, default: LatencyHistogram()].add(
                    sqlite3_column_double(stmt, 3),
                    count: Int(sqlite3_column_int64(stmt, 4))
                )
                owners[key] = id
            }
            return merged.map { HourlyBucket(key: $0.key, histogram: $0.value) }
        }
    }

    public func sampleCount(for id: UUID) throws -> Int {
        try queue.sync {
            let stmt = try prepare("SELECT COUNT(*) FROM ping_samples WHERE session_id = ?;")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Samples for a session ordered by sequence, optionally within a time range.
    public func samples(for id: UUID, from: Date? = nil, to: Date? = nil) throws -> [PingSample] {
        try queue.sync {
            var sql = """
                SELECT seq, timestamp, router_ms, internet_ms,
                       router_late_ms, internet_late_ms, phase
                FROM ping_samples WHERE session_id = ?
                """
            if from != nil { sql += " AND timestamp >= ?" }
            if to != nil { sql += " AND timestamp <= ?" }
            sql += " ORDER BY seq;"

            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            var col: Int32 = 1
            bind(stmt, col, id.uuidString); col += 1
            if let from { bind(stmt, col, from.timeIntervalSince1970); col += 1 }
            if let to { bind(stmt, col, to.timeIntervalSince1970); col += 1 }

            var out: [PingSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func optional(_ index: Int32) -> Double? {
                    sqlite3_column_type(stmt, index) == SQLITE_NULL
                        ? nil : sqlite3_column_double(stmt, index)
                }
                out.append(PingSample(
                    id: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 0)),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    routerMs: optional(2),
                    internetMs: optional(3),
                    routerLateMs: optional(4),
                    internetLateMs: optional(5),
                    phase: LoadPhase(rawValue: text(stmt, 6)) ?? .idle
                ))
            }
            return out
        }
    }

    // MARK: - Locked internals (must run on `queue`)

    private func flushLocked() throws {
        guard !buffer.isEmpty, let insertSample else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)

        try exec("BEGIN IMMEDIATE;")
        do {
            for (sessionID, s) in batch {
                sqlite3_reset(insertSample)
                sqlite3_clear_bindings(insertSample)
                bind(insertSample, 1, sessionID.uuidString)
                bind(insertSample, 2, Int64(s.id))
                bind(insertSample, 3, s.timestamp.timeIntervalSince1970)
                bindOptional(insertSample, 4, s.routerMs)
                bindOptional(insertSample, 5, s.internetMs)
                bindOptional(insertSample, 6, s.routerLateMs)
                bindOptional(insertSample, 7, s.internetLateMs)
                bind(insertSample, 8, s.phase.rawValue)
                try step(insertSample)
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            buffer.insert(contentsOf: batch, at: 0) // don't lose the batch
            throw error
        }
    }

    private func loadSessionLocked(_ id: UUID) throws -> SessionState? {
        let stmt = try prepare("""
            SELECT started_at, stopped_at, router_host, internet_host,
                   ping_interval_ns, ping_timeout_ns, throughput_enabled,
                   throughput_interval, diagnostics_interval_ns,
                   internet_samples, internet_failures, internet_min_ms,
                   internet_avg_ms, internet_max_ms, internet_p95_ms,
                   internet_spark,
                   internet_lost, internet_late, failures_under_load
            FROM sessions WHERE id = ?;
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        let stopped = sqlite3_column_type(stmt, 1) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let settings = MonitorSettings(
            routerHost: text(stmt, 2),
            internetHost: text(stmt, 3),
            pingInterval: .nanoseconds(sqlite3_column_int64(stmt, 4)),
            pingTimeout: .nanoseconds(sqlite3_column_int64(stmt, 5)),
            throughputEnabled: sqlite3_column_int64(stmt, 6) != 0,
            throughputInterval: Int(sqlite3_column_int64(stmt, 7)),
            diagnosticsInterval: .nanoseconds(sqlite3_column_int64(stmt, 8))
        )
        return SessionState(
            id: id, startedAt: started, stoppedAt: stopped, settings: settings,
            lastSampleAt: lastSampleAtLocked(id),
            summary: summary(from: stmt, firstColumn: 9)
        )
    }

    /// `nil` when this row has never been summarised — the sample count is the
    /// marker, because a session with no replies at all still has one (zero)
    /// and must not be re-folded on every launch.
    private func summary(from stmt: OpaquePointer, firstColumn: Int32) -> SessionSummary? {
        guard sqlite3_column_type(stmt, firstColumn) != SQLITE_NULL else { return nil }
        let blob = sqlite3_column_blob(stmt, firstColumn + 6)
        let bytes = Int(sqlite3_column_bytes(stmt, firstColumn + 6))
        let spark = blob.flatMap { pointer -> Sparkline? in
            guard bytes > 0 else { return nil }
            return Sparkline(data: Data(bytes: pointer, count: bytes))
        }
        // Columns 7…9 are schema 8. A row summarised before it has them NULL
        // until `backfillSummaries` reaches it; `lost: nil` then falls back to
        // the timeout count, which over-reports rather than reporting none.
        func optionalCount(_ index: Int32) -> Int? {
            sqlite3_column_type(stmt, index) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(stmt, index))
        }
        return SessionSummary(
            samples: Int(sqlite3_column_int64(stmt, firstColumn)),
            failures: Int(sqlite3_column_int64(stmt, firstColumn + 1)),
            lost: optionalCount(firstColumn + 7),
            late: optionalCount(firstColumn + 8) ?? 0,
            underLoad: optionalCount(firstColumn + 9) ?? 0,
            minMs: sqlite3_column_double(stmt, firstColumn + 2),
            avgMs: sqlite3_column_double(stmt, firstColumn + 3),
            maxMs: sqlite3_column_double(stmt, firstColumn + 4),
            p95Ms: sqlite3_column_double(stmt, firstColumn + 5),
            spark: spark
        )
    }

    /// Newest stored sample for a session, so `SessionState.duration` can be
    /// truthful about one that was never cleanly stopped.
    private func lastSampleAtLocked(_ id: UUID) -> Date? {
        guard let stmt = try? prepare(
            "SELECT MAX(timestamp) FROM ping_samples WHERE session_id = ?;"
        ) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, id.uuidString)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    // MARK: - The session summary

    /// Summarise every session that has no summary, newest first.
    ///
    /// Called at launch. A session only lacks one for two reasons: it predates
    /// schema 6, or it was force-quit and never reached ``stopSession``. Both
    /// are finished sessions whose samples will not change, so folding them
    /// once is right and doing it again is waste — which is why the sample
    /// count, not the blob, is the marker: a session where nothing ever replied
    /// summarises to zeros and a `nil` sparkline, and must still count as done.
    ///
    /// `excluding` is the running session, whose row exists from the moment it
    /// starts. Summarising it would store a figure for a session that is still
    /// growing, and `stopSession` will write the real one in a moment.
    ///
    /// Returns how many it wrote, so a caller can skip reloading when the
    /// answer is none.
    @discardableResult
    public func backfillSummaries(excluding running: UUID? = nil) throws -> Int {
        try queue.sync {
            let stmt = try prepare("""
                SELECT id FROM sessions
                WHERE internet_samples IS NULL OR internet_lost IS NULL
                ORDER BY started_at DESC;
                """)
            defer { sqlite3_finalize(stmt) }
            var ids: [UUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let id = UUID(uuidString: text(stmt, 0)), id != running {
                    ids.append(id)
                }
            }
            guard !ids.isEmpty else { return 0 }

            // One transaction: fifty small updates otherwise means fifty
            // fsyncs, which is most of the cost of the whole pass.
            try exec("BEGIN;")
            do {
                for id in ids {
                    try writeSummaryLocked(computeSummaryLocked(id), for: id)
                }
                try exec("COMMIT;")
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
            return ids.count
        }
    }

    /// Recompute one session's summary from its samples and store it.
    /// Exposed for the tests and for anything that edits samples after a stop.
    public func refreshSummary(for id: UUID) throws -> SessionSummary {
        try queue.sync {
            let summary = try computeSummaryLocked(id)
            try writeSummaryLocked(summary, for: id)
            return summary
        }
    }

    /// Three grouped scans over one session, and no `PingSample` built.
    ///
    /// The percentile comes from the same integer-millisecond histogram
    /// `latencyHistograms` uses, so the sidebar's p95 and the Analysis screen's
    /// cannot disagree by a rounding rule.
    private func computeSummaryLocked(_ id: UUID) throws -> SessionSummary {
        let warmup = Int64(PingSample.warmupSampleCount)

        let stats = try prepare("""
            SELECT COUNT(internet_ms), SUM(internet_ms IS NULL),
                   MIN(internet_ms), AVG(internet_ms), MAX(internet_ms),
                   MIN(timestamp), MAX(timestamp),
                   SUM(internet_ms IS NULL AND internet_late_ms IS NULL),
                   SUM(internet_ms IS NULL AND internet_late_ms IS NOT NULL),
                   SUM(internet_ms IS NULL AND phase <> 'idle')
            FROM ping_samples WHERE session_id = ? AND seq >= ?;
            """)
        defer { sqlite3_finalize(stats) }
        bind(stats, 1, id.uuidString)
        bind(stats, 2, warmup)
        guard sqlite3_step(stats) == SQLITE_ROW else {
            return SessionSummary(samples: 0, failures: 0, lost: 0,
                                  minMs: 0, avgMs: 0, maxMs: 0, p95Ms: 0, spark: nil)
        }
        let samples = Int(sqlite3_column_int64(stats, 0))
        let failures = Int(sqlite3_column_int64(stats, 1))
        let first = optionalDouble(stats, 5)
        let last = optionalDouble(stats, 6)

        var histogram = LatencyHistogram()
        let buckets = try prepare("""
            SELECT CAST(internet_ms AS INTEGER), COUNT(*)
            FROM ping_samples
            WHERE session_id = ? AND seq >= ? AND internet_ms IS NOT NULL
            GROUP BY 1;
            """)
        defer { sqlite3_finalize(buckets) }
        bind(buckets, 1, id.uuidString)
        bind(buckets, 2, warmup)
        while sqlite3_step(buckets) == SQLITE_ROW {
            histogram.add(Double(sqlite3_column_int64(buckets, 0)),
                          count: Int(sqlite3_column_int64(buckets, 1)))
        }

        return SessionSummary(
            samples: samples,
            failures: failures,
            lost: Int(sqlite3_column_int64(stats, 7)),
            late: Int(sqlite3_column_int64(stats, 8)),
            underLoad: Int(sqlite3_column_int64(stats, 9)),
            minMs: optionalDouble(stats, 2) ?? 0,
            avgMs: optionalDouble(stats, 3) ?? 0,
            maxMs: optionalDouble(stats, 4) ?? 0,
            p95Ms: histogram.p95,
            spark: try sparklineLocked(id, from: first, to: last, warmup: warmup)
        )
    }

    /// Buckets by *time*, not by sample index, so a session that stopped
    /// measuring for an hour draws a gap rather than closing it up.
    private func sparklineLocked(
        _ id: UUID, from first: Double?, to last: Double?, warmup: Int64
    ) throws -> Sparkline? {
        guard let first, let last, last > first else { return nil }
        let width = (last - first) / Double(Sparkline.bucketCount)
        guard width > 0 else { return nil }

        let stmt = try prepare("""
            SELECT MIN(CAST((timestamp - ?) / ? AS INTEGER), ?), AVG(internet_ms)
            FROM ping_samples
            WHERE session_id = ? AND seq >= ? AND internet_ms IS NOT NULL
            GROUP BY 1;
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, first)
        bind(stmt, 2, width)
        // The last sample lands exactly on `bucketCount`; clamp it into the
        // final bucket rather than growing the array by one.
        bind(stmt, 3, Int64(Sparkline.bucketCount - 1))
        bind(stmt, 4, id.uuidString)
        bind(stmt, 5, warmup)

        var means: [Int: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            means[Int(sqlite3_column_int64(stmt, 0))] = sqlite3_column_double(stmt, 1)
        }
        return Sparkline(bucketedMeans: means)
    }

    private func writeSummaryLocked(_ summary: SessionSummary, for id: UUID) throws {
        let stmt = try prepare("""
            UPDATE sessions SET internet_samples = ?, internet_failures = ?,
                                internet_min_ms = ?, internet_avg_ms = ?,
                                internet_max_ms = ?, internet_p95_ms = ?,
                                internet_spark = ?,
                                internet_lost = ?, internet_late = ?,
                                failures_under_load = ?
            WHERE id = ?;
            """)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(summary.samples))
        bind(stmt, 2, Int64(summary.failures))
        bind(stmt, 3, summary.minMs)
        bind(stmt, 4, summary.avgMs)
        bind(stmt, 5, summary.maxMs)
        bind(stmt, 6, summary.p95Ms)
        if let data = summary.spark?.data {
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(stmt, 7, $0.baseAddress, Int32(data.count), Self.transient)
            }
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        bind(stmt, 8, Int64(summary.lost))
        bind(stmt, 9, Int64(summary.late))
        bind(stmt, 10, Int64(summary.underLoad))
        bind(stmt, 11, id.uuidString)
        try step(stmt)
    }

    /// Puts a summarised row back into its pre-schema-8 shape: the schema-6
    /// columns intact, the split NULL. Exists so the backfill can be tested
    /// against the state every existing database is actually in on first launch
    /// — which is the only state that matters and the one a fresh test database
    /// can never reach on its own.
    func clearSummarySplitForTesting(_ id: UUID) throws {
        try queue.sync {
            let stmt = try prepare("""
                UPDATE sessions SET internet_lost = NULL, internet_late = NULL,
                                    failures_under_load = NULL
                WHERE id = ?;
                """)
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, id.uuidString)
            try step(stmt)
        }
    }

    // MARK: - SQLite plumbing (must run on `queue` / during init)

    private func migrate() throws {
        let from = userVersion()
        guard from < Schema.version else { return }
        // A fresh database gets the current tables from `statements` and needs
        // no `ALTER`s; an existing one gets only the steps it has not seen. `from`
        // is 0 for both cases, so ask SQLite which it is rather than guessing.
        let existing = tableExists("throughput_results")
        try exec("BEGIN;")
        do {
            for statement in Schema.statements { try exec(statement) }
            if existing, from < Schema.version {
                for v in (max(from, 1) + 1)...Schema.version {
                    for statement in Schema.migrations[v] ?? [] {
                        // `statements` ran first and creates any table that is
                        // *missing* at its current shape — new columns and all.
                        // A migration that then ADDs one of those columns is
                        // adding it twice, and SQLite fails the whole
                        // transaction on it. That is not hypothetical: a
                        // database carrying an old `throughput_results` but no
                        // `ping_samples` at all is exactly what the schema-2
                        // migration test builds, and schema 7 broke it.
                        //
                        // Skipping a redundant ADD is right rather than merely
                        // convenient: the column exists, with the type the
                        // migration wanted, and every ADD COLUMN in this file
                        // is nullable with no default, so there is no backfill
                        // being skipped along with it.
                        if redundantAddColumn(statement) { continue }
                        try exec(statement)
                    }
                }
            }
            try exec("PRAGMA user_version = \(Schema.version);")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// True when `statement` is `ALTER TABLE t ADD COLUMN c …` and `t` already
    /// has a column `c`.
    ///
    /// Only recognises that one shape, deliberately. Anything it does not parse
    /// comes back `false` and is executed, so a migration this cannot read
    /// still runs — and fails loudly — rather than being silently dropped.
    private func redundantAddColumn(_ statement: String) -> Bool {
        let words = statement
            .replacingOccurrences(of: ";", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard words.count >= 6,
              words[0].caseInsensitiveCompare("ALTER") == .orderedSame,
              words[1].caseInsensitiveCompare("TABLE") == .orderedSame,
              words[3].caseInsensitiveCompare("ADD") == .orderedSame,
              words[4].caseInsensitiveCompare("COLUMN") == .orderedSame
        else { return false }
        return columnExists(table: words[2], column: words[5])
    }

    private func columnExists(table: String, column: String) -> Bool {
        // `table` comes from `Schema.migrations`, which is a compile-time
        // constant in this module — never from a caller.
        guard let stmt = try? prepare("PRAGMA table_info(\(table));") else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if text(stmt, 1).caseInsensitiveCompare(column) == .orderedSame { return true }
        }
        return false
    }

    private func tableExists(_ name: String) -> Bool {
        guard let stmt = try? prepare(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(name)';"
        ) else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func userVersion() -> Int {
        guard let stmt = try? prepare("PRAGMA user_version;") else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? lastMessage()
            sqlite3_free(err)
            throw SessionStoreError.sqlite(code: sqlite3_errcode(db), message: message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SessionStoreError.sqlite(code: sqlite3_errcode(db), message: lastMessage())
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SessionStoreError.sqlite(code: rc, message: lastMessage())
        }
    }

    private func lastMessage() -> String { String(cString: sqlite3_errmsg(db)) }

    // Binding helpers. SQLITE_TRANSIENT so sqlite copies the bytes.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, Self.transient)
    }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }
    private func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }
    private func bindOptional(_ stmt: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) }
        else { sqlite3_bind_null(stmt, index) }
    }
    /// `nil` for a NULL column. Ten of these in one row is enough to want a
    /// name for it.
    private func optionalDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }
    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
