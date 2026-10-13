import Foundation
import SQLite3

enum SQLiteError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
}

enum SQLValue {
    case int(Int64), double(Double), text(String), blob(Data), null
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not thread-safe by itself; `IndexStore` serializes access with a lock per connection.
final class SQLiteConnection {
    let handle: OpaquePointer

    init(url: URL, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close(db)
            throw SQLiteError.failed(message)
        }
        handle = db
        // The app and the CLI may use the same file from different processes.
        sqlite3_busy_timeout(db, 10_000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        return Statement(handle: statement, connection: self)
    }

    /// Runs `sql` once with `args`, calling `row` for each result row.
    func query(_ sql: String, _ args: [SQLValue] = [], row: (Statement) throws -> Void = { _ in }) throws {
        let statement = try prepare(sql)
        try statement.bind(args)
        while try statement.step() { try row(statement) }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func error() -> SQLiteError { .failed(String(cString: sqlite3_errmsg(handle))) }
}

final class Statement {
    let handle: OpaquePointer
    let connection: SQLiteConnection

    init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ args: [SQLValue]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 =
                switch value {
                case .int(let v): sqlite3_bind_int64(handle, index, v)
                case .double(let v): sqlite3_bind_double(handle, index, v)
                case .text(let v): sqlite3_bind_text(handle, index, v, -1, transient)
                case .blob(let v): v.withUnsafeBytes { sqlite3_bind_blob(handle, index, $0.baseAddress, Int32($0.count), transient) }
                case .null: sqlite3_bind_null(handle, index)
                }
            guard status == SQLITE_OK else { throw connection.error() }
        }
    }

    /// True while a row is available.
    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw connection.error()
        }
    }

    func run(_ args: [SQLValue]) throws {
        try bind(args)
        while try step() {}
    }

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func text(_ column: Int32) -> String {
        sqlite3_column_text(handle, column).map { String(cString: $0) } ?? ""
    }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func blob(_ column: Int32) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: sqlite3_column_blob(handle, column), count: Int(sqlite3_column_bytes(handle, column)))
    }
}
