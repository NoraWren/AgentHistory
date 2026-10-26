import Foundation
import SQLite3

enum DBError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, String)
    case step(String, String)

    var description: String {
        switch self {
        case .open(let m): return "打开数据库失败：\(m)"
        case .prepare(let sql, let m): return "语句准备失败：\(m) [\(sql)]"
        case .step(let sql, let m): return "语句执行失败：\(m) [\(sql)]"
        }
    }
}

/// 判断一条数据库错误属于哪类故障，供界面翻译成人话。
/// sqlite 的提示语在不同语言与版本下不一致，所以以错误码为主、文本为辅。
extension DBError {
    var isLocked: Bool {
        let lower = description.lowercased()
        if lower.contains("locked") || lower.contains("busy") { return true }
        return false
    }

    var isUnreadable: Bool {
        if isLocked { return false }
        let lower = description.lowercased()
        // 缺表、缺列这类结构问题要原样报出来，别混成权限问题。
        if lower.contains("no such table") || lower.contains("no such column") { return false }
        return lower.contains("unable to open")
            || lower.contains("cannot open")
            || lower.contains("authorization denied")
            || lower.contains("not a database")
    }
}

final class Database {
    private var handle: OpaquePointer?
    let path: String

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX)
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let opened = h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if let h { sqlite3_close(h) }
            throw DBError.open(msg)
        }
        handle = opened
        sqlite3_busy_timeout(opened, 4000)
        try exec("PRAGMA foreign_keys=ON")
        if !readOnly {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "code \(rc)"
            sqlite3_free(err)
            throw DBError.step(sql, msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw DBError.prepare(sql, String(cString: sqlite3_errmsg(handle)))
        }
        return Statement(handle: stmt, sql: sql)
    }

    @discardableResult
    func run(_ sql: String, _ binds: [Any?] = []) throws -> Int64 {
        let stmt = try prepare(sql)
        try stmt.bind(binds)
        while try stmt.step() {}
        stmt.finalize()
        return sqlite3_last_insert_rowid(handle)
    }

    func query<T>(_ sql: String, _ binds: [Any?] = [], _ map: (Statement) throws -> T) throws -> [T] {
        let stmt = try prepare(sql)
        try stmt.bind(binds)
        var out: [T] = []
        while try stmt.step() { out.append(try map(stmt)) }
        stmt.finalize()
        return out
    }

    func scalarInt(_ sql: String, _ binds: [Any?] = []) throws -> Int64 {
        let rows = try query(sql, binds) { $0.int64(0) }
        return rows.first ?? 0
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") }
        catch { try? exec("ROLLBACK"); throw error }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
}

final class Statement {
    private var handle: OpaquePointer?
    private let sql: String

    init(handle: OpaquePointer, sql: String) {
        self.handle = handle
        self.sql = sql
    }

    deinit { finalize() }

    func finalize() {
        if let handle { sqlite3_finalize(handle) }
        handle = nil
    }

    func bind(_ params: [Any?]) throws {
        for (i, v) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch v {
            case nil: rc = sqlite3_bind_null(handle, idx)
            case let s as String: rc = sqlite3_bind_text(handle, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int: rc = sqlite3_bind_int64(handle, idx, Int64(n))
            case let n as Int64: rc = sqlite3_bind_int64(handle, idx, n)
            case let d as Double: rc = sqlite3_bind_double(handle, idx, d)
            case let b as Bool: rc = sqlite3_bind_int(handle, idx, b ? 1 : 0)
            default: rc = sqlite3_bind_text(handle, idx, String(describing: v!), -1, SQLITE_TRANSIENT)
            }
            if rc != SQLITE_OK { throw DBError.step(sql, "绑定参数 \(i) 失败") }
        }
    }

    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw DBError.step(sql, String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(handle, i) else { return "" }
        return String(cString: c)
    }

    func optText(_ i: Int32) -> String? {
        guard sqlite3_column_type(handle, i) != SQLITE_NULL else { return nil }
        return text(i)
    }

    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(handle, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(handle, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
