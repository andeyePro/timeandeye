import Foundation
import SQLite3
import andeyeTTCore

/// SQLite-backed JournalStore using the system sqlite3 C API directly —
/// no third-party dependency. Rows store the Codable models as JSON columns
/// beside the queryable fields, so schema churn stays cheap pre-1.0.
public final class SQLiteJournalStore: JournalStore {
    public enum StoreError: Error {
        case open(String)
        case exec(String)
        case encode
    }

    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Sync switch: non-nil = every session mutation is stamped (HLC + dirty)
    /// and deletes become tombstones. nil = pre-sync behaviour, byte-for-byte.
    public var clock: HLCClock?
    /// Rows that must NEVER sync (the live crash-checkpoint row): mutations
    /// aren't stamped, deletes stay hard deletes, revisions() skips them.
    public var syncExcludedIDs: Set<UUID> = []
    // Serialises ALL access to the one sqlite3 connection. Without this, an
    // async OP push (SyncEngine isn't @MainActor, so it resumes off-main after
    // its network await) and the main-actor journal reads hit the connection
    // concurrently → SIGSEGV (which the crash trap turned into a "quit" on stop).
    private let lock = NSRecursiveLock()
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public init(path: String) throws {
        if sqlite3_open(path, &db) != SQLITE_OK {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            start REAL NOT NULL,
            certainty REAL NOT NULL,
            pushed INTEGER NOT NULL,
            is_op INTEGER NOT NULL,
            json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS review_segments (
            id TEXT PRIMARY KEY,
            start REAL NOT NULL,
            assigned INTEGER NOT NULL,
            json TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS spans (
            start REAL NOT NULL,
            end REAL NOT NULL,
            json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS spans_start ON spans(start);
        CREATE INDEX IF NOT EXISTS sessions_start ON sessions(start);
        """)
        // `end` is a queryable column so sessions(from:to:) can bound BOTH sides
        // in SQL instead of decoding every row before `to` and filtering in
        // Swift. ADD COLUMN has no IF NOT EXISTS, so tolerate the duplicate on
        // an already-migrated db, then backfill any rows written before it.
        try? exec("ALTER TABLE sessions ADD COLUMN end REAL NOT NULL DEFAULT 0")
        // Sync revision metadata (see 2026-07-02-sync-design.md): the row IS
        // the replica's raw revision. hlc_device = '' marks a row written
        // before sync was enabled (stampAll migrates). Deleted rows stay as
        // tombstones so the delete travels; every read filters deleted = 0.
        try? exec("ALTER TABLE sessions ADD COLUMN hlc_millis INTEGER NOT NULL DEFAULT 0")
        try? exec("ALTER TABLE sessions ADD COLUMN hlc_counter INTEGER NOT NULL DEFAULT 0")
        try? exec("ALTER TABLE sessions ADD COLUMN hlc_device TEXT NOT NULL DEFAULT ''")
        try? exec("ALTER TABLE sessions ADD COLUMN origin INTEGER NOT NULL DEFAULT 0")
        try? exec("ALTER TABLE sessions ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0")
        try? exec("ALTER TABLE sessions ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0")
        try exec("CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value BLOB)")
        // Standalone comment-to-task storage (keyed by TaskRef.storageKey).
        try exec("""
        CREATE TABLE IF NOT EXISTS task_comments (
            task_key TEXT NOT NULL,
            created REAL NOT NULL,
            text TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS task_comments_key ON task_comments(task_key, created)
        """)
        // Per-(session, backend) posting ledger — replaces the single
        // pushed/opTimeEntryID slot as the source of truth for what was
        // posted where. The composite primary key IS the idempotency key.
        // The legacy `pushed` column stays as the primary-pm mirror (see
        // JournalStore.markPushed) so existing summary/PATCH surfaces and the
        // frozen wire shape are untouched.
        try exec("""
        CREATE TABLE IF NOT EXISTS posting_ledger (
            session_id TEXT NOT NULL,
            backend_id TEXT NOT NULL,
            state TEXT NOT NULL,
            entry_id TEXT,
            last_error TEXT,
            attempts INTEGER NOT NULL DEFAULT 0,
            updated REAL NOT NULL,
            PRIMARY KEY (session_id, backend_id)
        );
        CREATE INDEX IF NOT EXISTS posting_ledger_backend ON posting_ledger(backend_id, state)
        """)
        // Posted-snapshot columns (D1/D4): what was actually billed, so the
        // divergence detector can compare against the current resolved
        // session. Additive; NULL on pre-existing rows.
        try? exec("ALTER TABLE posting_ledger ADD COLUMN posted_start REAL")
        try? exec("ALTER TABLE posting_ledger ADD COLUMN posted_duration REAL")
        try? exec("ALTER TABLE posting_ledger ADD COLUMN session_stamp TEXT")
        try backfillSessionEnds()
        // Span detail is for recent-history inspection, not an archive:
        // keep 30 days so the table cannot grow without bound.
        try exec("DELETE FROM spans WHERE start < \(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970)")
        try purgeTombstones()
    }

    deinit {
        sqlite3_close(db)
    }

    private func exec(_ sql: String) throws {
        try locked {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw StoreError.exec(message)
            }
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in },
                       row: (OpaquePointer?) throws -> Void) throws {
        try locked {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                try row(stmt)
            }
        }
    }

    private func jsonColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        guard let text = sqlite3_column_text(stmt, index) else { return Data() }
        return Data(String(cString: text).utf8)
    }

    // SQLITE_TRANSIENT so SQLite copies Swift string buffers before they die.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Sessions

    public func save(_ session: Session) throws {
        // One critical section: meta read + row write must not interleave.
        try locked {
            let existing = try revisionRow(id: session.id)
            let meta: RowMeta
            if let clock, !syncExcludedIDs.contains(session.id) {
                // Local mutation while sync is on: re-stamp, mark dirty. A
                // save always yields a LIVE row (saving over a tombstone is
                // the user re-instating). Origin is preserved — the caller
                // escalates it via saveLocal when a mutation is deliberate.
                meta = RowMeta(hlc: clock.tick(),
                               origin: existing?.origin ?? .auto,
                               deleted: false, dirty: true)
                saveClockState()
            } else {
                // Sync off / excluded row: preserve whatever meta the row has
                // (INSERT OR REPLACE would otherwise wipe it to defaults).
                meta = existing.map { RowMeta(hlc: $0.hlc, origin: $0.origin,
                                              deleted: false, dirty: $0.dirty) }
                    ?? RowMeta.unstamped
            }
            try write(session, meta: meta)
        }
    }

    /// Row-level revision metadata as stored beside the session JSON.
    struct RowMeta {
        var hlc: HLC
        var origin: SliceOrigin
        var deleted: Bool
        var dirty: Bool
        /// Pre-sync rows: hlc_device '' marks "not yet stamped".
        static let unstamped = RowMeta(hlc: HLC(physicalMillis: 0, counter: 0, deviceID: ""),
                                       origin: .auto, deleted: false, dirty: false)
    }

    private func write(_ session: Session, meta: RowMeta) throws {
        try locked {
            guard let json = try? encoder.encode(session),
                  let jsonString = String(data: json, encoding: .utf8) else {
                throw StoreError.encode
            }
            // is_op: 1 = remote/pushable task (.op OR .remote), 0 = .local.
            // Column name is historic; renaming would force a table rewrite
            // for zero behaviour gain.
            let isOP = session.task.isRemote ? 1 : 0
            var stmt: OpaquePointer?
            let sql = """
            INSERT OR REPLACE INTO sessions
                (id, start, end, certainty, pushed, is_op, json,
                 hlc_millis, hlc_counter, hlc_device, origin, deleted, dirty)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, session.id.uuidString, -1, Self.transient)
            sqlite3_bind_double(stmt, 2, session.start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, session.end.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, session.certainty)
            sqlite3_bind_int(stmt, 5, session.pushedToOP ? 1 : 0)
            sqlite3_bind_int(stmt, 6, Int32(isOP))
            sqlite3_bind_text(stmt, 7, jsonString, -1, Self.transient)
            sqlite3_bind_int64(stmt, 8, meta.hlc.physicalMillis)
            sqlite3_bind_int(stmt, 9, meta.hlc.counter)
            sqlite3_bind_text(stmt, 10, meta.hlc.deviceID, -1, Self.transient)
            sqlite3_bind_int(stmt, 11, Int32(meta.origin.rawValue))
            sqlite3_bind_int(stmt, 12, meta.deleted ? 1 : 0)
            sqlite3_bind_int(stmt, 13, meta.dirty ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// The raw row (live OR tombstone) with its revision meta; nil if absent.
    private func revisionRow(id: UUID) throws -> (session: Session, hlc: HLC,
                                                  origin: SliceOrigin, deleted: Bool,
                                                  dirty: Bool)? {
        var out: [(Session, HLC, SliceOrigin, Bool, Bool)] = []
        try query("""
            SELECT json, hlc_millis, hlc_counter, hlc_device, origin, deleted, dirty
            FROM sessions WHERE id = ?
            """,
                  bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.transient) }) { stmt in
            let session = try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0))
            let device = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            out.append((session,
                        HLC(physicalMillis: sqlite3_column_int64(stmt, 1),
                            counter: sqlite3_column_int(stmt, 2), deviceID: device),
                        SliceOrigin(rawValue: Int(sqlite3_column_int(stmt, 4))) ?? .auto,
                        sqlite3_column_int(stmt, 5) != 0,
                        sqlite3_column_int(stmt, 6) != 0))
        }
        return out.first
    }

    public func allSessions() throws -> [Session] {
        var out: [Session] = []
        try query("SELECT json FROM sessions WHERE deleted = 0 ORDER BY start") { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    public func session(id: UUID) throws -> Session? {
        var out: [Session] = []
        try query("SELECT json FROM sessions WHERE id = ? AND deleted = 0",
                  bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.transient) }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out.first
    }

    public func sessionCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM sessions WHERE deleted = 0") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    public func pushedCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM sessions WHERE pushed = 1 AND deleted = 0") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    public func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session] {
        var out: [Session] = []
        try query("SELECT json FROM sessions WHERE pushed = 0 AND is_op = 1 AND deleted = 0 AND certainty >= ? ORDER BY start",
                  bind: { sqlite3_bind_double($0, 1, threshold) }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    public func markPushed(_ id: UUID, opTimeEntryID: RemoteEntryID?) throws {
        // One critical section for the whole read-modify-write: the lock is
        // recursive, so the inner query/save re-acquisitions are free. Without
        // this, a main-actor update() can interleave between our read and our
        // save (sync runs off-main after its network await) and get overwritten.
        try locked {
            var sessions: [Session] = []
            try query("SELECT json FROM sessions WHERE id = ?",
                      bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.transient) }) { stmt in
                sessions.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
            }
            guard var session = sessions.first else { return }
            session.pushedToOP = true
            session.opTimeEntryID = opTimeEntryID
            try save(session)
        }
    }

    // MARK: - Posting ledger

    /// Decode one ledger row from a `SELECT session_id, backend_id, state,
    /// entry_id, last_error, attempts, updated` statement. An unknown future
    /// state string reads as `.posted` — the never-double-post direction.
    private func postingRow(_ stmt: OpaquePointer?) -> PostingRecord? {
        guard let idText = sqlite3_column_text(stmt, 0),
              let sessionID = UUID(uuidString: String(cString: idText)),
              let backendText = sqlite3_column_text(stmt, 1) else { return nil }
        let stateRaw = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        return PostingRecord(
            sessionID: sessionID,
            backendID: String(cString: backendText),
            state: PostingState(rawValue: stateRaw) ?? .posted,
            entryID: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
            lastError: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            attempts: Int(sqlite3_column_int(stmt, 5)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
            postedStart: sqlite3_column_type(stmt, 7) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
            postedDuration: sqlite3_column_type(stmt, 8) == SQLITE_NULL
                ? nil : sqlite3_column_double(stmt, 8),
            sessionStamp: sqlite3_column_text(stmt, 9).map { String(cString: $0) })
    }

    private static let postingColumns =
        "session_id, backend_id, state, entry_id, last_error, attempts, updated, posted_start, posted_duration, session_stamp"

    public func postingRecords(session: UUID) throws -> [PostingRecord] {
        var out: [PostingRecord] = []
        try query("SELECT \(Self.postingColumns) FROM posting_ledger WHERE session_id = ? ORDER BY backend_id",
                  bind: { sqlite3_bind_text($0, 1, session.uuidString, -1, Self.transient) }) { stmt in
            if let record = self.postingRow(stmt) { out.append(record) }
        }
        return out
    }

    public func postingRecords(state: PostingState, backendID: String) throws -> [PostingRecord] {
        var out: [PostingRecord] = []
        try query("SELECT \(Self.postingColumns) FROM posting_ledger WHERE state = ? AND backend_id = ? ORDER BY session_id",
                  bind: {
                      sqlite3_bind_text($0, 1, state.rawValue, -1, Self.transient)
                      sqlite3_bind_text($0, 2, backendID, -1, Self.transient)
                  }) { stmt in
            if let record = self.postingRow(stmt) { out.append(record) }
        }
        return out
    }

    public func postingRecord(session: UUID, backendID: String) throws -> PostingRecord? {
        var out: [PostingRecord] = []
        try query("SELECT \(Self.postingColumns) FROM posting_ledger WHERE session_id = ? AND backend_id = ?",
                  bind: {
                      sqlite3_bind_text($0, 1, session.uuidString, -1, Self.transient)
                      sqlite3_bind_text($0, 2, backendID, -1, Self.transient)
                  }) { stmt in
            if let record = self.postingRow(stmt) { out.append(record) }
        }
        return out.first
    }

    public func setPostingRecord(_ record: PostingRecord) throws {
        try locked {
            var stmt: OpaquePointer?
            let sql = """
            INSERT OR REPLACE INTO posting_ledger
                (session_id, backend_id, state, entry_id, last_error, attempts, updated,
                 posted_start, posted_duration, session_stamp)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, record.sessionID.uuidString, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, record.backendID, -1, Self.transient)
            sqlite3_bind_text(stmt, 3, record.state.rawValue, -1, Self.transient)
            if let entryID = record.entryID {
                sqlite3_bind_text(stmt, 4, entryID, -1, Self.transient)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let lastError = record.lastError {
                sqlite3_bind_text(stmt, 5, lastError, -1, Self.transient)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_int(stmt, 6, Int32(record.attempts))
            sqlite3_bind_double(stmt, 7, record.updatedAt.timeIntervalSince1970)
            if let postedStart = record.postedStart {
                sqlite3_bind_double(stmt, 8, postedStart.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            if let postedDuration = record.postedDuration {
                sqlite3_bind_double(stmt, 9, postedDuration)
            } else {
                sqlite3_bind_null(stmt, 9)
            }
            if let sessionStamp = record.sessionStamp {
                sqlite3_bind_text(stmt, 10, sessionStamp, -1, Self.transient)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func clearPostingRecord(session: UUID, backendID: String) throws {
        try locked {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "DELETE FROM posting_ledger WHERE session_id = ? AND backend_id = ?",
                -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, session.uuidString, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, backendID, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func sessions(needingPostTo backendID: String,
                         atOrAbove threshold: Double) throws -> [Session] {
        // FAIL-CLOSED eligibility: the ONLY retryable stored state is
        // 'failed' — any other row (posted/skipped/stuck/inflight AND any
        // state a NEWER build writes) blocks re-posting, matching the row
        // decoder's unknown→posted direction. A whitelist here once let a
        // future state fall through to a duplicate post (Fable reviewer A2).
        // A row for ANOTHER backend never hides the session from this one —
        // the per-backend key is what lets one session be posted to OP and
        // pending to a finance backend at the same time. The legacy `pushed`
        // column is deliberately ignored here (migrated rows carry ledger
        // rows instead).
        var out: [Session] = []
        try query("""
            SELECT json FROM sessions s
            WHERE s.is_op = 1 AND s.deleted = 0 AND s.certainty >= ?
              AND NOT EXISTS (SELECT 1 FROM posting_ledger l
                              WHERE l.session_id = s.id AND l.backend_id = ?
                                AND l.state != 'failed')
            ORDER BY s.start
            """,
                  bind: {
                      sqlite3_bind_double($0, 1, threshold)
                      sqlite3_bind_text($0, 2, backendID, -1, Self.transient)
                  }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    public func migrateSingleSlotPostings(to backendID: String,
                                          excluding: Set<UUID>) throws -> Int {
        try locked {
            // Tombstoned rows are included: a resurrected (synced-back) slice
            // must still know it was posted, or the next pass double-posts.
            let notIn = excluding.isEmpty ? "" : " AND s.id NOT IN ("
                + excluding.map { "'\($0.uuidString)'" }.joined(separator: ",") + ")"
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO posting_ledger
                (session_id, backend_id, state, entry_id, last_error, attempts, updated)
            SELECT s.id, ?, 'posted', json_extract(s.json, '$.opTimeEntryID'), NULL, 0, ?
            FROM sessions s
            WHERE s.pushed = 1 AND s.is_op = 1\(notIn)
              AND NOT EXISTS (SELECT 1 FROM posting_ledger l
                              WHERE l.session_id = s.id AND l.backend_id = ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, backendID, -1, Self.transient)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, backendID, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            return Int(sqlite3_changes(db))
        }
    }

    public func latestEndByTask(excluding: Set<UUID>) throws -> [TaskRef: Date] {
        // GROUP BY the JSON task key in SQL so durable recency never decodes
        // the whole table (it used to, once a minute, growing with history).
        var out: [TaskRef: Date] = [:]
        let notIn = excluding.isEmpty ? "" : " AND id NOT IN ("
            + excluding.map { "'\($0.uuidString)'" }.joined(separator: ",") + ")"
        try query("SELECT json_extract(json, '$.task'), MAX(end) FROM sessions WHERE deleted = 0\(notIn) GROUP BY 1") { stmt in
            guard let text = sqlite3_column_text(stmt, 0) else { return }
            if let ref = try? self.decoder.decode(TaskRef.self,
                                                  from: Data(String(cString: text).utf8)) {
                out[ref] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
        }
        return out
    }

    public func sessions(from: Date, to: Date) throws -> [Session] {
        var out: [Session] = []
        // Bounds BOTH sides in SQL (was: start < to, then a Swift end > from
        // filter that still decoded every row before `to`).
        try query("SELECT json FROM sessions WHERE start < ? AND end > ? AND deleted = 0 ORDER BY start",
                  bind: {
                      sqlite3_bind_double($0, 1, to.timeIntervalSince1970)
                      sqlite3_bind_double($0, 2, from.timeIntervalSince1970)
                  }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    // MARK: - Resolved view (D1 — sync-aware overrides)

    /// STAMPED revisions intersecting [from, to], tombstones included (the
    /// resolver needs them to pass through, and resolution is time-local so
    /// a window load is exact — a claimant that trims in-window time must
    /// itself intersect the window).
    private func revisions(from: Date, to: Date) throws -> [SessionRevision] {
        var out: [SessionRevision] = []
        try query("""
            SELECT json, hlc_millis, hlc_counter, hlc_device, origin, deleted
            FROM sessions WHERE hlc_device != '' AND start < ? AND end > ?
            """,
                  bind: {
                      sqlite3_bind_double($0, 1, to.timeIntervalSince1970)
                      sqlite3_bind_double($0, 2, from.timeIntervalSince1970)
                  }) { stmt in
            let session = try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0))
            let device = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            out.append(SessionRevision(
                session: session,
                hlc: HLC(physicalMillis: sqlite3_column_int64(stmt, 1),
                         counter: sqlite3_column_int(stmt, 2), deviceID: device),
                origin: SliceOrigin(rawValue: Int(sqlite3_column_int(stmt, 4))) ?? .auto,
                deleted: sqlite3_column_int(stmt, 5) != 0))
        }
        return out.filter { !syncExcludedIDs.contains($0.id) }
    }

    /// Sync ON: the overlap-resolved derived view over the window's stamped
    /// revisions, plus any UNSTAMPED in-window rows verbatim (excluded rows
    /// like the live checkpoint are unstamped; they must keep appearing to
    /// the callers that filter them). Sync OFF: identical to the raw window.
    /// NOTE: fragment IDS are window-dependent (a claimant outside [from,to)
    /// isn't loaded, so a boundary-crossing parent may split differently in
    /// a different window) — in-window SECONDS are exact; never key anything
    /// on fragment ids from a windowed query (the ledger folds to parents).
    public func resolvedSessions(from: Date, to: Date) throws -> [Session] {
        guard clock != nil else { return try sessions(from: from, to: to) }
        let resolved = SessionMerge.resolveOverlaps(try revisions(from: from, to: to))
            .filter { !$0.deleted }
            .map(\.session)
        let stampedIDs = Set(resolved.map(\.id))
        let unstamped = try sessions(from: from, to: to).filter { raw in
            !stampedIDs.contains(raw.id)
                && ((try? revisionRow(id: raw.id))?.hlc.deviceID.isEmpty ?? true)
        }
        return (resolved + unstamped)
            .filter { $0.start < to && $0.end > from }
            .sorted { $0.start != $1.start ? $0.start < $1.start
                                           : $0.id.uuidString < $1.id.uuidString }
    }

    /// The record's current revision stamp; nil while unstamped (sync off /
    /// excluded rows) so the verify sweep stays inert exactly as before sync.
    public func sessionStamp(_ id: UUID) throws -> String? {
        guard let row = try revisionRow(id: id), !row.hlc.deviceID.isEmpty else { return nil }
        return row.hlc.description
    }

    /// Sync ON: this session's surviving (start, seconds) after overlap
    /// resolution — nil when fully covered. Sync OFF: the stored span.
    public func resolvedContribution(sessionID: UUID) throws -> (start: Date, seconds: TimeInterval)? {
        guard let s = try session(id: sessionID) else { return nil }
        guard clock != nil,
              let row = try revisionRow(id: sessionID), !row.hlc.deviceID.isEmpty else {
            return (s.start, s.end.timeIntervalSince(s.start))
        }
        let contributions = SessionMerge.resolvedContributions(
            try revisions(from: s.start, to: s.end))
        return contributions[sessionID]
    }

    /// Populate `end` for rows written before that column existed (end == 0 is
    /// impossible for a real post-1970 date, so it reliably marks unmigrated
    /// rows). One-time, on the first launch after the column is added.
    private func backfillSessionEnds() throws {
        var stale: [Session] = []
        try query("SELECT json FROM sessions WHERE end = 0") { stmt in
            stale.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        for session in stale { try save(session) }   // save() now writes `end`
    }

    public func update(_ session: Session) throws {
        try save(session)   // INSERT OR REPLACE keyed by id
    }

    public func deleteSession(_ id: UUID) throws {
        try locked {
            // Sync on: the delete must travel, so the row becomes a tombstone
            // (stamped + dirty). Sync off / excluded rows: hard delete as ever.
            if let clock, !syncExcludedIDs.contains(id) {
                guard let row = try revisionRow(id: id), !row.deleted else { return }
                try write(row.session, meta: RowMeta(hlc: clock.tick(), origin: row.origin,
                                                     deleted: true, dirty: true))
                saveClockState()
                return
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func escalateOrigin(_ id: UUID, to origin: SliceOrigin) throws {
        try locked {
            guard let row = try revisionRow(id: id), row.origin < origin else { return }
            // Origin drives cross-device overlap authority, so a change must
            // sync: re-stamp + dirty like any other mutation (clock present),
            // else just record it for a later sync enablement.
            let hlc = (clock != nil && !syncExcludedIDs.contains(id))
                ? clock!.tick() : row.hlc
            try write(row.session, meta: RowMeta(hlc: hlc, origin: origin,
                                                 deleted: row.deleted,
                                                 dirty: row.dirty || clock != nil))
            saveClockState()
        }
    }

    public func save(_ span: FocusSpan) throws {
        try locked {
            guard let json = try? encoder.encode(span),
                  let jsonString = String(data: json, encoding: .utf8) else {
                throw StoreError.encode
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO spans (start, end, json) VALUES (?,?,?)",
                                     -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, span.start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, span.end.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, jsonString, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func spans(from: Date, to: Date) throws -> [FocusSpan] {
        var out: [FocusSpan] = []
        try query("SELECT json FROM spans WHERE end > ? AND start < ? ORDER BY start",
                  bind: {
                      sqlite3_bind_double($0, 1, from.timeIntervalSince1970)
                      sqlite3_bind_double($0, 2, to.timeIntervalSince1970)
                  }) { stmt in
            out.append(try self.decoder.decode(FocusSpan.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    // MARK: - Review segments

    public func save(_ segment: ReviewSegment) throws {
        try locked {
            guard let json = try? encoder.encode(segment),
                  let jsonString = String(data: json, encoding: .utf8) else {
                throw StoreError.encode
            }
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO review_segments (id, start, assigned, json) VALUES (?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, segment.id.uuidString, -1, Self.transient)
            sqlite3_bind_double(stmt, 2, segment.start.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, segment.assigned == nil ? 0 : 1)
            sqlite3_bind_text(stmt, 4, jsonString, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func pendingReview() throws -> [ReviewSegment] {
        var out: [ReviewSegment] = []
        try query("SELECT json FROM review_segments WHERE assigned = 0 ORDER BY start") { stmt in
            out.append(try self.decoder.decode(ReviewSegment.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    public func assign(_ segmentIDs: [UUID], to target: Target?) throws {
        // Single critical section across the batch (see markPushed).
        try locked {
            for id in segmentIDs {
                var segments: [ReviewSegment] = []
                try query("SELECT json FROM review_segments WHERE id = ?",
                          bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.transient) }) { stmt in
                    segments.append(try self.decoder.decode(ReviewSegment.self,
                                                            from: self.jsonColumn(stmt, 0)))
                }
                guard var segment = segments.first else { continue }
                segment.assigned = target
                try save(segment)
            }
        }
    }
}

// MARK: - RevisionStore (the replica side of sync)

extension SQLiteJournalStore: RevisionStore {
    public func allRevisions() throws -> [SessionRevision] {
        var out: [SessionRevision] = []
        try query("""
            SELECT json, hlc_millis, hlc_counter, hlc_device, origin, deleted
            FROM sessions WHERE hlc_device != ''
            """) { stmt in
            let session = try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0))
            let device = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            out.append(SessionRevision(
                session: session,
                hlc: HLC(physicalMillis: sqlite3_column_int64(stmt, 1),
                         counter: sqlite3_column_int(stmt, 2), deviceID: device),
                origin: SliceOrigin(rawValue: Int(sqlite3_column_int(stmt, 4))) ?? .auto,
                deleted: sqlite3_column_int(stmt, 5) != 0))
        }
        return out.filter { !syncExcludedIDs.contains($0.id) }
            .sorted {
                $0.session.start != $1.session.start
                    ? $0.session.start < $1.session.start
                    : $0.id.uuidString < $1.id.uuidString
            }
    }

    public func revision(id: UUID) throws -> SessionRevision? {
        guard !syncExcludedIDs.contains(id),
              let row = try revisionRow(id: id), !row.hlc.deviceID.isEmpty else { return nil }
        return SessionRevision(session: row.session, hlc: row.hlc,
                               origin: row.origin, deleted: row.deleted)
    }

    public func dirtyRevisionIDs() throws -> [UUID] {
        var out: [UUID] = []
        try query("SELECT id FROM sessions WHERE dirty = 1 AND hlc_device != ''") { stmt in
            if let text = sqlite3_column_text(stmt, 0),
               let id = UUID(uuidString: String(cString: text)) { out.append(id) }
        }
        return out.filter { !syncExcludedIDs.contains($0) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    public func saveLocal(_ revision: SessionRevision) throws {
        try write(revision.session, meta: RowMeta(hlc: revision.hlc, origin: revision.origin,
                                                  deleted: revision.deleted, dirty: true))
    }

    public func applyRemote(_ revision: SessionRevision) throws {
        try write(revision.session, meta: RowMeta(hlc: revision.hlc, origin: revision.origin,
                                                  deleted: revision.deleted, dirty: false))
    }

    public func clearDirty(_ cleared: [SessionRevision]) throws {
        try locked {
            for rev in cleared {
                var stmt: OpaquePointer?
                let sql = """
                UPDATE sessions SET dirty = 0
                WHERE id = ? AND hlc_millis = ? AND hlc_counter = ? AND hlc_device = ?
                """
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, rev.id.uuidString, -1, Self.transient)
                sqlite3_bind_int64(stmt, 2, rev.hlc.physicalMillis)
                sqlite3_bind_int(stmt, 3, rev.hlc.counter)
                sqlite3_bind_text(stmt, 4, rev.hlc.deviceID, -1, Self.transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
                }
            }
        }
    }

    public var syncToken: SyncToken? {
        get {
            var out: Data?
            try? query("SELECT value FROM sync_state WHERE key = 'token'") { stmt in
                if let bytes = sqlite3_column_blob(stmt, 0) {
                    out = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
                }
            }
            return out.map(SyncToken.init(raw:))
        }
        set {
            locked {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(
                    db, "INSERT OR REPLACE INTO sync_state (key, value) VALUES ('token', ?)",
                    -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                let raw = newValue?.raw ?? Data()
                _ = raw.withUnsafeBytes {
                    sqlite3_bind_blob(stmt, 1, $0.baseAddress, Int32(raw.count), Self.transient)
                }
                _ = sqlite3_step(stmt)
            }
        }
    }

    // MARK: - Task comments (standalone comment-to-task)

    public func saveTaskComment(_ ref: TaskRef, text: String, at date: Date) throws {
        try locked {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "INSERT INTO task_comments (task_key, created, text) VALUES (?,?,?)",
                -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, ref.storageKey, -1, Self.transient)
            sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, text, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func taskComments(for ref: TaskRef) throws -> [(date: Date, text: String)] {
        var out: [(Date, String)] = []
        try query("SELECT created, text FROM task_comments WHERE task_key = ? ORDER BY created",
                  bind: { sqlite3_bind_text($0, 1, ref.storageKey, -1, Self.transient) }) { stmt in
            let text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            out.append((Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)), text))
        }
        return out
    }

    // MARK: sync_state helpers (device id, clock persistence)

    private func syncStateData(_ key: String) -> Data? {
        var out: Data?
        try? query("SELECT value FROM sync_state WHERE key = ?",
                   bind: { sqlite3_bind_text($0, 1, key, -1, Self.transient) }) { stmt in
            if let bytes = sqlite3_column_blob(stmt, 0) {
                out = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
            }
        }
        return out
    }

    private func setSyncStateData(_ key: String, _ value: Data) {
        locked {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "INSERT OR REPLACE INTO sync_state (key, value) VALUES (?, ?)",
                -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
            _ = value.withUnsafeBytes {
                sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(value.count), Self.transient)
            }
            _ = sqlite3_step(stmt)
        }
    }

    public func syncStateString(_ key: String) -> String? {
        syncStateData(key).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func setSyncStateString(_ key: String, _ value: String) {
        setSyncStateData(key, Data(value.utf8))
    }

    /// The HLC clock state as of the last stamped mutation — restored on
    /// launch so stamps stay monotonic even across a wall-clock regression.
    public func loadClockState() -> HLC? {
        syncStateData("clock").flatMap { try? decoder.decode(HLC.self, from: $0) }
    }

    func saveClockState() {
        guard let clock, let data = try? encoder.encode(clock.last) else { return }
        setSyncStateData("clock", data)
    }

    /// Checks-only raw accessor: freezes the is_op column contract
    /// (1 = remote/pushable, 0 = local) independent of query behaviour.
    public func rawIsOPColumn(id: UUID) throws -> Int {
        var out = -1
        try query("SELECT is_op FROM sessions WHERE id = ?",
                  bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.transient) }) { stmt in
            out = Int(sqlite3_column_int(stmt, 0))
        }
        return out
    }

    /// Tombstone GC (sync design: retain ≥ 90 days). Only tombstones the
    /// server has already seen (dirty = 0) are purged — an unpushed delete
    /// must survive locally or it never travels. LOCAL-only: the CK-side
    /// record remains (incremental pulls never re-send untouched records, so
    /// it won't resurrect); server-side GC is a later explicit pass.
    public func purgeTombstones(olderThanDays days: Int = 90, now: Date = Date()) throws {
        let cutoffMillis = Int64((now.timeIntervalSince1970 - Double(days) * 86_400) * 1000)
        try exec("""
        DELETE FROM sessions
        WHERE deleted = 1 AND dirty = 0 AND hlc_millis > 0 AND hlc_millis < \(cutoffMillis)
        """)
    }

    /// One-shot sync-enablement migration: stamp every pre-sync row (in start
    /// order, so HLCs read sensibly) and mark it dirty for the first upload.
    /// Idempotent — already-stamped rows are untouched.
    public func stampAllUnstamped(clock: HLCClock) throws {
        try locked {
            var stale: [UUID] = []
            try query("SELECT id FROM sessions WHERE hlc_device = '' ORDER BY start") { stmt in
                if let text = sqlite3_column_text(stmt, 0),
                   let id = UUID(uuidString: String(cString: text)) { stale.append(id) }
            }
            for id in stale where !syncExcludedIDs.contains(id) {
                guard let row = try revisionRow(id: id) else { continue }
                try write(row.session, meta: RowMeta(hlc: clock.tick(), origin: .auto,
                                                     deleted: row.deleted, dirty: true))
            }
            saveClockState()
        }
    }
}
