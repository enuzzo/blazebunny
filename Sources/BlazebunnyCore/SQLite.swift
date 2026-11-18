import Foundation
import SQLite3

/// Minimal SQLite wrapper. Not thread-safe; `LibraryIndex` serialises access.
final class SQLiteDB {
    struct Error: Swift.Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private(set) var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]

    /// `readOnly` opens a second connection for queries only: in WAL mode it reads while another
    /// connection writes, so the UI never waits for the scanner.
    init(path: String, readOnly: Bool = false) throws {
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw Error(message: msg)
        }
        // Wait for a competing connection (an old scan still finishing after a library
        // switch) instead of failing at once with "database is locked".
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        for s in cache.values { sqlite3_finalize(s) }
        sqlite3_close(handle)
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw Error(message: msg + " in: " + sql.prefix(120))
        }
    }

    /// Runs `sql` with `args`, calling `row` for each result row.
    func query(_ sql: String, _ args: [Any?] = [], row: ((Row) throws -> Void)? = nil) throws {
        let stmt = try prepare(sql)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as Bool: sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Data:
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            default: throw Error(message: "unsupported bind type \(type(of: a))")
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Error(message: String(cString: sqlite3_errmsg(handle))) }
            try row?(Row(stmt: stmt))
        }
    }

    func run(_ sql: String, _ args: [Any?] = []) throws { try query(sql, args) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try exec("COMMIT")
            return r
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { return s }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw Error(message: String(cString: sqlite3_errmsg(handle)) + " in: " + sql.prefix(120))
        }
        cache[sql] = s
        return s
    }

    struct Row {
        let stmt: OpaquePointer
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func intOrNil(_ i: Int32) -> Int? { isNull(i) ? nil : Int(sqlite3_column_int64(stmt, i)) }
        func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
        func data(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
        func string(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
