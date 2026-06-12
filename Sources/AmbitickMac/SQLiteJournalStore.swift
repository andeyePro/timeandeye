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
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.exec(message)
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in },
                       row: (OpaquePointer?) throws -> Void) throws {
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

    private func jsonColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Data {
        guard let text = sqlite3_column_text(stmt, index) else { return Data() }
        return Data(String(cString: text).utf8)
    }

    // SQLITE_TRANSIENT so SQLite copies Swift string buffers before they die.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Sessions

    public func save(_ session: Session) throws {
        guard let json = try? encoder.encode(session),
              let jsonString = String(data: json, encoding: .utf8) else {
            throw StoreError.encode
        }
        var isOP = 0
        if case .op = session.task { isOP = 1 }
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO sessions (id, start, certainty, pushed, is_op, json) VALUES (?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, session.id.uuidString, -1, Self.transient)
        sqlite3_bind_double(stmt, 2, session.start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 3, session.certainty)
        sqlite3_bind_int(stmt, 4, session.pushedToOP ? 1 : 0)
        sqlite3_bind_int(stmt, 5, Int32(isOP))
        sqlite3_bind_text(stmt, 6, jsonString, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func allSessions() throws -> [Session] {
        var out: [Session] = []
        try query("SELECT json FROM sessions ORDER BY start") { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
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

    public func sessions(from: Date, to: Date) throws -> [Session] {
        var out: [Session] = []
        try query("SELECT json FROM sessions WHERE start < ? ORDER BY start",
                  bind: { sqlite3_bind_double($0, 1, to.timeIntervalSince1970) }) { stmt in
            out.append(try self.decoder.decode(Session.self, from: self.jsonColumn(stmt, 0)))
        }
        return out.filter { $0.end > from }
    }

    public func update(_ session: Session) throws {
        try save(session)   // INSERT OR REPLACE keyed by id
    }

    public func deleteSession(_ id: UUID) throws {
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

    public func save(_ span: FocusSpan) throws {
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

    public func pendingReview() throws -> [ReviewSegment] {
        var out: [ReviewSegment] = []
        try query("SELECT json FROM review_segments WHERE assigned = 0 ORDER BY start") { stmt in
            out.append(try self.decoder.decode(ReviewSegment.self, from: self.jsonColumn(stmt, 0)))
        }
        return out
    }

    public func assign(_ segmentIDs: [UUID], to target: Target) throws {
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
