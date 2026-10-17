import Foundation
import SQLite3

public enum StoreError: Error, CustomStringConvertible {
    case sqlite(String)
    case notFound

    public var description: String {
        switch self {
        case .sqlite(let message): return "SQLite error: \(message)"
        case .notFound: return "Item not found"
        }
    }
}

enum SQLValue {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite wrapper. Not thread-safe by itself; callers serialize access.
final class SQLiteDB {
    let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(rc))"
            if let db { sqlite3_close_v2(db) }
            throw StoreError.sqlite(message)
        }
        handle = db
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw StoreError.sqlite(message)
        }
    }

    func prepare(_ sql: String, _ values: [SQLValue] = []) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sqlite("\(errorMessage) — \(sql)")
        }
        let statement = Statement(stmt, db: self)
        try statement.bind(values)
        return statement
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ values: [SQLValue] = []) throws {
        let stmt = try prepare(sql, values)
        _ = try stmt.step()
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}

final class Statement {
    let stmt: OpaquePointer
    unowned let db: SQLiteDB

    init(_ stmt: OpaquePointer, db: SQLiteDB) {
        self.stmt = stmt
        self.db = db
    }

    deinit {
        sqlite3_finalize(stmt)
    }

    func bind(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let idx = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .int(let v):
                rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v):
                rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let s):
                let bytes = Array(s.utf8)
                if bytes.isEmpty {
                    rc = sqlite3_bind_text(stmt, idx, "", 0, SQLITE_TRANSIENT)
                } else {
                    rc = bytes.withUnsafeBufferPointer { buf in
                        buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { ptr in
                            sqlite3_bind_text64(stmt, idx, ptr, sqlite3_uint64(buf.count), SQLITE_TRANSIENT, UInt8(SQLITE_UTF8))
                        }
                    }
                }
            case .blob(let data):
                if data.isEmpty {
                    rc = sqlite3_bind_zeroblob(stmt, idx, 0)
                } else {
                    rc = data.withUnsafeBytes { buf in
                        sqlite3_bind_blob64(stmt, idx, buf.baseAddress, sqlite3_uint64(buf.count), SQLITE_TRANSIENT)
                    }
                }
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw StoreError.sqlite(db.errorMessage) }
        }
    }

    /// Returns true when a row is available.
    func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.sqlite(db.errorMessage)
        }
    }

    func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(stmt, col)) }
    func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
    func isNull(_ col: Int32) -> Bool { sqlite3_column_type(stmt, col) == SQLITE_NULL }

    func text(_ col: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, col) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, col))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }

    func blob(_ col: Int32) -> Data? {
        if isNull(col) { return nil }
        let count = Int(sqlite3_column_bytes(stmt, col))
        guard count > 0, let ptr = sqlite3_column_blob(stmt, col) else { return Data() }
        return Data(bytes: ptr, count: count)
    }
}
