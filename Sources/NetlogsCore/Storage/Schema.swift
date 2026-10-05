import Foundation

/// SQLite schema for a Netlogs database (plan §9).
///
/// Raw SQLite via the system `SQLite3` module — no external dependency, which
/// keeps `NetlogsCore` importable by the future iOS viewer unchanged (plan §4).
enum Schema {
    /// Bump when `statements` changes; `SessionStore` applies migrations by
    /// `PRAGMA user_version`.
    static let version = 10

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
        // Schema 3's lesson, applied to the four columns it left behind.
        //
        // The three phase latencies were written as `idle ?? 0` and the
        // bufferbloat derived from them, so an idle window that caught no
        // replies stored a confident 0 ms baseline — and `max(load) - 0`
        // reported the entire load latency as bufferbloat: 210 ms and a "poor"
        // grade, invented from a window that measured nothing. It is schema 2's
        // `NOT NULL DEFAULT 0` again, in the figure the Speed card leads with.
        //
        // Same table rebuild as v3, for the same reason: SQLite has no
        // `DROP NOT NULL`. Nothing references `throughput_results`, so the drop
        // and rename are safe with foreign keys on, and the index has to be
        // recreated because `statements` runs before migrations do.
        //
        // The backfill discriminator is exact rather than heuristic this time:
        // a measured round-trip time is never 0.0 ms — the packet has to reach
        // the host and come back — so `idle_latency_ms = 0` means "never
        // measured" with certainty, unlike v3's jitter-and-loss pair, which had
        // to reason about coincidence. The load latencies were written with the
        // same `?? 0` fallback and get the same treatment. Bufferbloat is
        // nulled wherever its baseline was, because a subtraction is only as
        // real as both of its terms.
        5: [
            """
            CREATE TABLE throughput_results_v5 (
                id            TEXT PRIMARY KEY,
                session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                timestamp     REAL NOT NULL,
                download_mbps REAL NOT NULL,
                upload_mbps   REAL NOT NULL,
                bytes_down    INTEGER NOT NULL,
                bytes_up      INTEGER NOT NULL,
                idle_latency_ms     REAL,
                download_latency_ms REAL,
                upload_latency_ms   REAL,
                bufferbloat_ms      REAL,
                idle_jitter_ms      REAL,
                packet_loss         REAL,
                isp             TEXT,
                server_location TEXT,
                idle_low_ms         REAL,
                idle_high_ms        REAL,
                download_jitter_ms  REAL,
                download_low_ms     REAL,
                download_high_ms    REAL,
                upload_jitter_ms    REAL,
                upload_low_ms       REAL,
                upload_high_ms      REAL
            );
            """,
            """
            INSERT INTO throughput_results_v5
            SELECT id, session_id, timestamp, download_mbps, upload_mbps,
                   bytes_down, bytes_up,
                   NULLIF(idle_latency_ms, 0),
                   NULLIF(download_latency_ms, 0),
                   NULLIF(upload_latency_ms, 0),
                   CASE WHEN idle_latency_ms = 0 THEN NULL ELSE bufferbloat_ms END,
                   idle_jitter_ms, packet_loss, isp, server_location,
                   idle_low_ms, idle_high_ms,
                   download_jitter_ms, download_low_ms, download_high_ms,
                   upload_jitter_ms, upload_low_ms, upload_high_ms
            FROM throughput_results;
            """,
            "DROP TABLE throughput_results;",
            "ALTER TABLE throughput_results_v5 RENAME TO throughput_results;",
            "CREATE INDEX IF NOT EXISTS idx_throughput_session_time ON throughput_results(session_id, timestamp);",
        ],
        // The denormalized session summary the sidebar needs (`SessionSummary`).
        //
        // Plain `ADD COLUMN`s, and every one of them nullable — "not summarised
        // yet" has to be storable, because a session that was force-quit never
        // reached `stopSession` and no backfill can invent a stop for it.
        // `internet_samples IS NULL` is the marker, and `SessionStore` fills
        // the gaps in one pass rather than leaving rows permanently blank.
        //
        // Named for the leg they describe. Schema 2 and 4 both had to be undone
        // because a column could not say "not measured"; this time the question
        // a column answers is in its name from the start.
        6: [
            "ALTER TABLE sessions ADD COLUMN internet_samples INTEGER;",
            "ALTER TABLE sessions ADD COLUMN internet_failures INTEGER;",
            "ALTER TABLE sessions ADD COLUMN internet_min_ms REAL;",
            "ALTER TABLE sessions ADD COLUMN internet_avg_ms REAL;",
            "ALTER TABLE sessions ADD COLUMN internet_max_ms REAL;",
            "ALTER TABLE sessions ADD COLUMN internet_p95_ms REAL;",
            "ALTER TABLE sessions ADD COLUMN internet_spark BLOB;",
        ],
        // Late replies (see `PingOutcome.lateReply`). Nullable from birth, and
        // for once the nullability needs no argument: NULL means "no late reply
        // for this host on this tick", which is the overwhelmingly common case
        // and the only thing an existing row can honestly say. Every sample
        // written before this migration has NULL in both columns, which reads
        // correctly as "we were not listening past the deadline then" — the
        // failures in those sessions stay failures and simply have no RTT.
        //
        // No backfill is possible and none should be attempted. The numbers
        // were never recorded; the socket dropped those packets unmatched.
        7: [
            "ALTER TABLE ping_samples ADD COLUMN router_late_ms REAL;",
            "ALTER TABLE ping_samples ADD COLUMN internet_late_ms REAL;",
        ],
        // The lost/late/self-inflicted split, carried onto the session row.
        //
        // Schema 6 stored `internet_failures`, meaning internet *timeouts*, and
        // every reader treated it as packet loss — the sidebar, and
        // `SessionSummary.lossRatio`. Schema 7 established that those are three
        // different facts; this is what stops the one-figure summary from being
        // the last place in the app that cannot tell them apart. Without it a
        // status dot in the sidebar would be coloured by the very number
        // schema 7 disproved.
        //
        // Nullable, and `internet_lost IS NULL` is the backfill marker — the
        // same discipline as schema 6's `internet_samples`, and necessary for
        // the same reason: zero lost packets is a real and common answer, so
        // the marker cannot be a value.
        //
        // The backfill genuinely recomputes rather than copying
        // `internet_failures` across. For sessions recorded before schema 7 the
        // two agree, because nothing was listening past the deadline and every
        // timeout really is stored as a silence; for anything recorded since
        // they do not, and the recomputation is the only thing that gets those
        // right.
        8: [
            "ALTER TABLE sessions ADD COLUMN internet_lost INTEGER;",
            "ALTER TABLE sessions ADD COLUMN internet_late INTEGER;",
            "ALTER TABLE sessions ADD COLUMN failures_under_load INTEGER;",
        ],
        // Traffic captures (`TrafficCapture`). A new table, so nothing to
        // migrate — `statements` creates it — and this entry exists only to
        // carry the version bump and this note.
        //
        // JSON in one column, like `diagnostics_snapshots`, and for the same
        // reason: the shape of a capture is a list of whatever processes were
        // busy, which is not a fixed set of columns and never will be.
        9: [],
        // Gateway telemetry (`WANSnapshot`, Phase 14). A new table again, so
        // the entry only carries the bump. JSON for the reason the plan gives:
        // the fields come from a vendor API that moves between firmware
        // versions, and a JSON column absorbs that where typed columns would
        // need a migration each time. Kept out of `ping_samples` on purpose —
        // the radio changes every ~12 s, and 39,000 copies of it per night
        // would be the cost of saving one join.
        10: [],
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
            diagnostics_interval_ns INTEGER NOT NULL,
            internet_samples    INTEGER,
            internet_failures   INTEGER,
            internet_min_ms     REAL,
            internet_avg_ms     REAL,
            internet_max_ms     REAL,
            internet_p95_ms     REAL,
            internet_spark      BLOB,
            internet_lost       INTEGER,
            internet_late       INTEGER,
            failures_under_load INTEGER
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS ping_samples (
            session_id   TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            seq          INTEGER NOT NULL,
            timestamp    REAL NOT NULL,
            router_ms    REAL,
            internet_ms  REAL,
            router_late_ms   REAL,
            internet_late_ms REAL,
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
            idle_latency_ms     REAL,
            download_latency_ms REAL,
            upload_latency_ms   REAL,
            bufferbloat_ms      REAL,
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
        CREATE TABLE IF NOT EXISTS traffic_captures (
            session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            timestamp   REAL NOT NULL,
            json        TEXT NOT NULL,
            PRIMARY KEY (session_id, timestamp)
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS wan_snapshots (
            session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
            timestamp   REAL NOT NULL,
            json        TEXT NOT NULL,
            PRIMARY KEY (session_id, timestamp)
        );
        """,
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
