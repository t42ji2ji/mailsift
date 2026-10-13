import Foundation
import SQLite3

/// Read-only access to a SQLite file that another process (Mail, accountsd) holds open in WAL mode.
final class ReadOnlySQLite {
    private var db: OpaquePointer?

    /// Throws `.fullDiskAccessRequired` when the file exists but cannot be opened (TCC denies reads).
    init(path: String) throws {
        var comps = URLComponents()
        comps.scheme = "file"
        comps.path = path
        comps.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        let uri = comps.string ?? "file:\(path)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(uri, &db, flags, nil)
        if rc != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(db)
            db = nil
            if rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH || rc == SQLITE_PERM {
                throw MailSourceError.fullDiskAccessRequired
            }
            throw MailSourceError.other("Cannot open \(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 3000)
    }

    deinit { sqlite3_close(db) }

    /// Runs `sql` with integer/text bindings and calls `row` for each result row.
    func query(_ sql: String, _ args: [Any] = [], row: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            // A database that opened but whose pages can't be read is the TCC case too.
            if rc == SQLITE_CANTOPEN || rc == SQLITE_AUTH || rc == SQLITE_PERM { throw MailSourceError.fullDiskAccessRequired }
            throw MailSourceError.other("SQLite prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW { try row(Row(stmt: stmt)) }
            else if step == SQLITE_DONE { break }
            else {
                if step == SQLITE_CANTOPEN || step == SQLITE_AUTH || step == SQLITE_PERM { throw MailSourceError.fullDiskAccessRequired }
                throw MailSourceError.other("SQLite step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    struct Row {
        let stmt: OpaquePointer?
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func text(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    }
}
