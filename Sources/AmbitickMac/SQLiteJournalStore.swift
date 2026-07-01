import Foundation
import SQLite3
import AmbitickCore

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
        try backfillSessionEnds()
        // Span detail is for recent-history inspection, not an archive:
        // keep 30 days so the table cannot grow without bound.
        try exec("DELETE FROM spans WHERE start < \(Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970)")
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
        try locked {
            guard let json = try? encoder.encode(session),
                  let jsonString = String(data: json, encoding: .utf8) else {
                throw StoreError.encode
            }
            var isOP = 0
            if case .op = session.task { isOP = 1 }
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO sessions (id, start, end, certainty, pushed, is_op, json) VALUES (?,?,?,?,?,?,?)"
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
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func allSessions() throws -> [Session] {
        var out: [Session] = []
        try query("SELECT json FROM sessions ORDER BY start") { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    public func session(id: UUID) throws -> Session? {
        var out: [Session] = []
        try query("SELECT json FROM sessions WHERE id = ?",
                  bind: { sqlite3_bind_text($0, 1, id.uuidString, -1, Self.transient) }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out.first
    }

    public func sessionCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM sessions") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    public func pushedCount() throws -> Int {
        var count = 0
        try query("SELECT COUNT(*) FROM sessions WHERE pushed = 1") { stmt in
            count = Int(sqlite3_column_int64(stmt, 0))
        }
        return count
    }

    public func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session] {
        var out: [Session] = []
        try query("SELECT json FROM sessions WHERE pushed = 0 AND is_op = 1 AND certainty >= ? ORDER BY start",
                  bind: { sqlite3_bind_double($0, 1, threshold) }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    public func markPushed(_ id: UUID, opTimeEntryID: Int?) throws {
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

    public func latestEndByTask(excluding: Set<UUID>) throws -> [TaskRef: Date] {
        // GROUP BY the JSON task key in SQL so durable recency never decodes
        // the whole table (it used to, once a minute, growing with history).
        var out: [TaskRef: Date] = [:]
        let notIn = excluding.isEmpty ? "" : " WHERE id NOT IN ("
            + excluding.map { "'\($0.uuidString)'" }.joined(separator: ",") + ")"
        try query("SELECT json_extract(json, '$.task'), MAX(end) FROM sessions\(notIn) GROUP BY 1") { stmt in
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
        try query("SELECT json FROM sessions WHERE start < ? AND end > ? ORDER BY start",
                  bind: {
                      sqlite3_bind_double($0, 1, to.timeIntervalSince1970)
                      sqlite3_bind_double($0, 2, from.timeIntervalSince1970)
                  }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
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
