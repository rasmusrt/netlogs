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
                (session_id, seq, timestamp, router_ms, internet_ms, phase)
            VALUES (?, ?, ?, ?, ?, ?);
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

    /// Flush remaining samples and mark the session stopped.
    public func stopSession(_ id: UUID, at stoppedAt: Date = Date()) throws {
        try queue.sync {
            try flushLocked()
            let stmt = try prepare("UPDATE sessions SET stopped_at = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, stoppedAt.timeIntervalSince1970)
            bind(stmt, 2, id.uuidString)
            try step(stmt)
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
            bind(stmt, 8, result.idleLatencyMs)
            bind(stmt, 9, result.downloadLatencyMs)
            bind(stmt, 10, result.uploadLatencyMs)
            bind(stmt, 11, result.bufferbloatMs)
            // NULL, not 0 — schema 3 exists so an unmeasured figure stops
            // reading back as a measured zero.
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
                    idleLatencyMs: sqlite3_column_double(stmt, 6),
                    downloadLatencyMs: sqlite3_column_double(stmt, 7),
                    uploadLatencyMs: sqlite3_column_double(stmt, 8),
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
    public func vacuum() throws {
        try queue.sync { try exec("VACUUM;") }
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
            var sql = "SELECT seq, timestamp, router_ms, internet_ms, phase FROM ping_samples WHERE session_id = ?"
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
                out.append(PingSample(
                    id: UInt32(truncatingIfNeeded: sqlite3_column_int64(stmt, 0)),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    routerMs: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2),
                    internetMs: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3),
                    phase: LoadPhase(rawValue: text(stmt, 4)) ?? .idle
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
                bind(insertSample, 6, s.phase.rawValue)
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
                   throughput_interval, diagnostics_interval_ns
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
            lastSampleAt: lastSampleAtLocked(id)
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
                    for statement in Schema.migrations[v] ?? [] { try exec(statement) }
                }
            }
            try exec("PRAGMA user_version = \(Schema.version);")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
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
