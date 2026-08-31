import Foundation

/// SQLite schema for a Netlogs database (plan §9).
///
/// Raw SQLite via the system `SQLite3` module — no external dependency, which
/// keeps `NetlogsCore` importable by the future iOS viewer unchanged (plan §4).
enum Schema {
    /// Bump when `statements` changes; `SessionStore` applies migrations by
    /// `PRAGMA user_version`.
    static let version = 4

    /// Applied in order to a database created before that version. `statements`
    /// only creates missing tables, so a new column on an existing one has to
    /// arrive as an explicit `ALTER`.
    static let migrations: [Int: [String]] = [
        2: [
            "ALTER TABLE throughput_results ADD COLUMN idle_jitter_ms REAL NOT NULL DEFAULT 0;",
            "ALTER TABLE throughput_results ADD COLUMN packet_loss REAL NOT NULL DEFAULT 0;",
        ],
        // Schema 2 was the mistake this undoes. `NOT NULL DEFAULT 0` gave every
        // result recorded before it a jitter and a loss of exactly 0.0, which
        // is indistinguishable from a test that measured a clean connection —
        // the app's whole job is telling those two apart. The columns become
        // nullable so "never measured" can be stored as such and drawn as "—".
        //
        // SQLite has no `DROP NOT NULL`, so this is the documented table
        // rebuild. No table references `throughput_results`, so the drop and
        // rename are safe with `foreign_keys` on; the index goes with the old
        // table and has to be recreated here, because `statements` has already
        // run by the time migrations do.
        //
        // Backfilling is the one judgement call. There is no marker saying
        // which rows were defaulted, so the discriminator is `idle_jitter_ms =
        // 0`: jitter is a mean of absolute differences between consecutive
        // replies, so a measured window lands on exactly 0.0 only if every
        // reply agreed to the last bit of a Double, and a window with too few
        // replies to have a difference at all now stores NULL rather than 0.
        // `packet_loss = 0` is required as well because loss genuinely is zero
        // most of the time, and it is only meaningful as a pair with jitter.
        // A false positive costs one "—" in place of a real zero; a false
        // negative would keep asserting a measurement that never happened.
        3: [
            """
            CREATE TABLE throughput_results_v3 (
                id            TEXT PRIMARY KEY,
                session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                timestamp     REAL NOT NULL,
                download_mbps REAL NOT NULL,
                upload_mbps   REAL NOT NULL,
                bytes_down    INTEGER NOT NULL,
                bytes_up      INTEGER NOT NULL,
                idle_latency_ms     REAL NOT NULL,
                download_latency_ms REAL NOT NULL,
                upload_latency_ms   REAL NOT NULL,
                bufferbloat_ms      REAL NOT NULL,
                idle_jitter_ms      REAL,
                packet_loss         REAL,
                isp             TEXT,
                server_location TEXT
            );
            """,
            """
            INSERT INTO throughput_results_v3
            SELECT id, session_id, timestamp, download_mbps, upload_mbps,
                   bytes_down, bytes_up, idle_latency_ms, download_latency_ms,
                   upload_latency_ms, bufferbloat_ms,
                   CASE WHEN idle_jitter_ms = 0 AND packet_loss = 0
                        THEN NULL ELSE idle_jitter_ms END,
                   CASE WHEN idle_jitter_ms = 0 AND packet_loss = 0
                        THEN NULL ELSE packet_loss END,
                   isp, server_location
            FROM throughput_results;
            """,
            "DROP TABLE throughput_results;",
            "ALTER TABLE throughput_results_v3 RENAME TO throughput_results;",
            "CREATE INDEX IF NOT EXISTS idx_throughput_session_time ON throughput_results(session_id, timestamp);",
        ],
        // Per-phase spread. Plain `ADD COLUMN`s, not the rebuild v3 needed:
        // these are nullable from birth, and nullable is exactly what they
        // should be, so there is no `NOT NULL DEFAULT 0` to undo later.
        4: [
            "ALTER TABLE throughput_results ADD COLUMN idle_low_ms REAL;",
            "ALTER TABLE throughput_results ADD COLUMN idle_high_ms REAL;",
            "ALTER TABLE throughput_results ADD COLUMN download_jitter_ms REAL;",
            "ALTER TABLE throughput_results ADD COLUMN download_low_ms REAL;",
            "ALTER TABLE throughput_results ADD COLUMN download_high_ms REAL;",
            "ALTER TABLE throughput_results ADD COLUMN upload_jitter_ms REAL;",
            "ALTER TABLE throughput_results ADD COLUMN upload_low_ms REAL;",
            "ALTER TABLE throughput_results ADD COLUMN upload_high_ms REAL;",
        ],
    ]

    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id                  TEXT PRIMARY KEY,
            started_at          REAL NOT NULL,
            stopped_at          REAL,
            router_host         TEXT NOT NULL,
            internet_host       TEXT NOT NULL,
            ping_interval_ns    INTEGER NOT NULL,
            ping_timeout_ns     INTEGER NOT NULL,
            throughput_enabled  INTEGER NOT NULL,
            throughput_interval INTEGER NOT NULL,
            diagnostics_interval_ns INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS ping_samples (
            session_id   TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            seq          INTEGER NOT NULL,
            timestamp    REAL NOT NULL,
            router_ms    REAL,
            internet_ms  REAL,
            phase        TEXT NOT NULL,
            PRIMARY KEY (session_id, seq)
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_ping_samples_session_time ON ping_samples(session_id, timestamp);",
        """
        CREATE TABLE IF NOT EXISTS throughput_results (
            id            TEXT PRIMARY KEY,
            session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            timestamp     REAL NOT NULL,
            download_mbps REAL NOT NULL,
            upload_mbps   REAL NOT NULL,
            bytes_down    INTEGER NOT NULL,
            bytes_up      INTEGER NOT NULL,
            idle_latency_ms     REAL NOT NULL,
            download_latency_ms REAL NOT NULL,
            upload_latency_ms   REAL NOT NULL,
            bufferbloat_ms      REAL NOT NULL,
            idle_jitter_ms      REAL,
            packet_loss         REAL,
            idle_low_ms         REAL,
            idle_high_ms        REAL,
            download_jitter_ms  REAL,
            download_low_ms     REAL,
            download_high_ms    REAL,
            upload_jitter_ms    REAL,
            upload_low_ms       REAL,
            upload_high_ms      REAL,
            isp             TEXT,
            server_location TEXT
        );
        """,
        "CREATE INDEX IF NOT EXISTS idx_throughput_session_time ON throughput_results(session_id, timestamp);",
        """
        CREATE TABLE IF NOT EXISTS diagnostics_snapshots (
            session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            timestamp   REAL NOT NULL,
            json        TEXT NOT NULL,
            PRIMARY KEY (session_id, timestamp)
        );
        """,
    ]
}
