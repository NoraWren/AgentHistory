import Foundation

final class Store {
    let db: Database
    let root: String

    static var defaultRoot: String {
        if let override = ProcessInfo.processInfo.environment["AGENT_HISTORY_HOME"] { return override }
        return NSHomeDirectory() + "/.agent-history"
    }

    init(root: String = Store.defaultRoot) throws {
        self.root = root
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/handoffs", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/backups", withIntermediateDirectories: true)
        self.db = try Database(path: root + "/history.db")
        try migrate()
    }

    func migrate() throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS sources(
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, root TEXT NOT NULL,
            available INTEGER NOT NULL DEFAULT 0, adapter_version INTEGER NOT NULL DEFAULT 1,
            last_sync_at INTEGER NOT NULL DEFAULT 0, last_error TEXT);
        CREATE TABLE IF NOT EXISTS projects(
            id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
            last_active_at INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS threads(
            id TEXT PRIMARY KEY, source_id TEXT NOT NULL, native_id TEXT NOT NULL,
            project_id TEXT, title TEXT NOT NULL DEFAULT '', cwd TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0,
            model TEXT NOT NULL DEFAULT '', thread_source TEXT NOT NULL DEFAULT '',
            archived INTEGER NOT NULL DEFAULT 0, item_count INTEGER NOT NULL DEFAULT 0,
            preview TEXT NOT NULL DEFAULT '',
            UNIQUE(source_id, native_id));
        CREATE TABLE IF NOT EXISTS turns(
            id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, native_turn_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT '',
            started_at INTEGER NOT NULL DEFAULT 0, completed_at INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS items(
            id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, turn_id TEXT,
            native_item_id TEXT NOT NULL, ordinal INTEGER NOT NULL DEFAULT 0,
            item_type TEXT NOT NULL DEFAULT '', role TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT '',
            raw_json TEXT NOT NULL DEFAULT '', truncated INTEGER NOT NULL DEFAULT 0,
            UNIQUE(thread_id, native_item_id));
        CREATE TABLE IF NOT EXISTS sync_state(
            source_id TEXT NOT NULL, thread_id TEXT NOT NULL, watermark TEXT NOT NULL DEFAULT '',
            updated_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(source_id, thread_id));
        CREATE TABLE IF NOT EXISTS handoffs(
            id TEXT PRIMARY KEY, thread_id TEXT NOT NULL DEFAULT '', target TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0, title TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '', decisions TEXT NOT NULL DEFAULT '',
            todos TEXT NOT NULL DEFAULT '', files TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'draft', payload TEXT NOT NULL DEFAULT '');
        CREATE VIRTUAL TABLE IF NOT EXISTS search_docs USING fts5(seg, content='', contentless_delete=1);
        CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_threads_source ON threads(source_id, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_thread ON items(thread_id, ordinal);
        CREATE INDEX IF NOT EXISTS idx_handoffs_thread ON handoffs(thread_id);
        """)
        try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','1')")
    }

    // MARK: - 来源

    func registerSource(_ kind: SourceKind, available: Bool, error: String? = nil) throws {
        try db.run("""
        INSERT INTO sources(id,kind,name,root,available,adapter_version,last_sync_at,last_error)
        VALUES(?,?,?,?,?,1,COALESCE((SELECT last_sync_at FROM sources WHERE id=?),0),?)
        ON CONFLICT(id) DO UPDATE SET available=excluded.available, root=excluded.root,
            name=excluded.name, last_error=excluded.last_error
        """, [kind.rawValue, kind.rawValue, kind.displayName, kind.rootPath, available ? 1 : 0, kind.rawValue, error])
    }

    func sources() throws -> [SourceInfo] {
        try db.query("""
        SELECT s.id,s.kind,s.available,s.last_sync_at,s.last_error,
               (SELECT COUNT(*) FROM threads t WHERE t.source_id=s.id)
        FROM sources s ORDER BY s.kind
        """) { st in
            SourceInfo(id: st.text(0), kind: SourceKind(rawValue: st.text(1)) ?? .codex,
                       available: st.int(2) == 1, lastSyncAt: st.int64(3),
                       lastError: st.optText(4), threadCount: st.int(5))
        }
    }

    func markSynced(_ kind: SourceKind) throws {
        try db.run("UPDATE sources SET last_sync_at=?, last_error=NULL WHERE id=?",
                   [Int64(Date().timeIntervalSince1970), kind.rawValue])
    }

    func markSourceError(_ kind: SourceKind, _ message: String) throws {
        try db.run("UPDATE sources SET last_error=? WHERE id=?", [message, kind.rawValue])
    }

    // MARK: - 项目与会话

    func ensureProject(path: String, lastActiveAt: Int64) throws -> String {
        let trimmed = path.isEmpty ? "/" : path
        let rows = try db.query("SELECT id FROM projects WHERE path=?", [trimmed]) { $0.text(0) }
        if let id = rows.first {
            try db.run("UPDATE projects SET last_active_at=MAX(last_active_at,?) WHERE id=?", [lastActiveAt, id])
            return id
        }
        let id = UUID().uuidString
        let name = (trimmed as NSString).lastPathComponent.isEmpty ? trimmed : (trimmed as NSString).lastPathComponent
        try db.run("INSERT INTO projects(id,path,name,last_active_at) VALUES(?,?,?,?)",
                   [id, trimmed, name, lastActiveAt])
        return id
    }

    @discardableResult
    func upsertThread(_ input: ThreadInput) throws -> String {
        let projectId = try ensureProject(path: input.projectPath, lastActiveAt: input.updatedAt)
        let existing = try db.query("SELECT id FROM threads WHERE source_id=? AND native_id=?",
                                    [input.sourceId, input.nativeId]) { $0.text(0) }
        if let id = existing.first {
            try db.run("""
            UPDATE threads SET title=?, cwd=?, updated_at=MAX(updated_at,?), model=?, thread_source=?,
                archived=?, preview=?, project_id=?
            WHERE id=?
            """, [input.title, input.projectPath, input.updatedAt, input.model, input.threadSource,
                  input.archived ? 1 : 0, input.preview, projectId, id])
            return id
        }
        let id = UUID().uuidString
        try db.run("""
        INSERT INTO threads(id,source_id,native_id,project_id,title,cwd,created_at,updated_at,
                            model,thread_source,archived,item_count,preview)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,0,?)
        """, [id, input.sourceId, input.nativeId, projectId, input.title, input.projectPath,
              input.createdAt, input.updatedAt, input.model, input.threadSource,
              input.archived ? 1 : 0, input.preview])
        return id
    }

    func upsertItems(threadId: String, items: [ItemInput], turnNativeId: String? = nil) throws -> (inserted: Int, redacted: Int) {
        var inserted = 0
        var redacted = 0
        var turnId: String? = nil
        if let turnNativeId, !turnNativeId.isEmpty {
            let rows = try db.query("SELECT id FROM turns WHERE thread_id=? AND native_turn_id=?",
                                    [threadId, turnNativeId]) { $0.text(0) }
            if let id = rows.first { turnId = id }
            else {
                let id = UUID().uuidString
                try db.run("INSERT INTO turns(id,thread_id,native_turn_id,ordinal,status) VALUES(?,?,?,?,?)",
                           [id, threadId, turnNativeId, 0, "completed"])
                turnId = id
            }
        }
        try db.transaction {
            for item in items {
                let masked = Redactor.mask(item.text)
                redacted += masked.hits
                let id = UUID().uuidString
                // 原始 JSON 会随条目线性膨胀（实测 410MB），正文已经保留，原件可按 native_id 回源读取。
                let rawToStore = ""
                try db.run("""
                INSERT INTO items(id,thread_id,turn_id,native_item_id,ordinal,item_type,role,created_at,text,raw_json,truncated)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(thread_id,native_item_id) DO NOTHING
                """, [id, threadId, turnId, item.nativeId, item.ordinal, item.itemType, item.role,
                      item.createdAt, masked.text, rawToStore, item.truncated ? 1 : 0])
                let rowid: Int64
                if db.changes > 0 {
                    rowid = db.lastInsertRowID
                    inserted += 1
                } else {
                    let rows = try db.query("SELECT rowid FROM items WHERE thread_id=? AND native_item_id=?",
                                            [threadId, item.nativeId]) { $0.int64(0) }
                    guard let rid = rows.first else { continue }
                    rowid = rid
                    try db.run("""
                    UPDATE items SET ordinal=?, item_type=?, role=?, created_at=?, text=?, raw_json=?, truncated=?
                    WHERE rowid=?
                    """, [item.ordinal, item.itemType, item.role, item.createdAt, masked.text, rawToStore,
                          item.truncated ? 1 : 0, rid])
                    try db.run("DELETE FROM search_docs WHERE rowid=?", [rid])
                }
                let seg = TextTools.segmentJoined(masked.text)
                if !seg.isEmpty {
                    try db.run("INSERT INTO search_docs(rowid,seg) VALUES(?,?)", [rowid, seg])
                }
            }
            let count = try db.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id=?", [threadId])
            try db.run("UPDATE threads SET item_count=? WHERE id=?", [count, threadId])
        }
        return (inserted, redacted)
    }

    func watermark(sourceId: String, threadId: String) throws -> String? {
        try db.query("SELECT watermark FROM sync_state WHERE source_id=? AND thread_id=?",
                     [sourceId, threadId]) { $0.text(0) }.first
    }

    func setWatermark(sourceId: String, threadId: String, watermark: String) throws {
        try db.run("""
        INSERT INTO sync_state(source_id,thread_id,watermark,updated_at) VALUES(?,?,?,?)
        ON CONFLICT(source_id,thread_id) DO UPDATE SET watermark=excluded.watermark, updated_at=excluded.updated_at
        """, [sourceId, threadId, watermark, Int64(Date().timeIntervalSince1970)])
    }

    // MARK: - 查询

    func projects() throws -> [ProjectRow] {
        try db.query("""
        SELECT p.id,p.path,p.name,p.last_active_at,(SELECT COUNT(*) FROM threads t WHERE t.project_id=p.id)
        FROM projects p ORDER BY p.last_active_at DESC
        """) { st in
            ProjectRow(id: st.text(0), path: st.text(1), name: st.text(2),
                       lastActiveAt: st.int64(3), threadCount: st.int(4))
        }
    }

    func threads(sourceKind: SourceKind? = nil, projectPath: String? = nil,
                 query: String? = nil, limit: Int = 300) throws -> [ThreadRow] {
        var sql = """
        SELECT t.id,t.source_id,t.native_id,t.cwd,t.title,t.updated_at,t.item_count,t.thread_source,t.archived
        FROM threads t WHERE 1=1
        """
        var binds: [Any?] = []
        if let kind = sourceKind { sql += " AND t.source_id=?"; binds.append(kind.rawValue) }
        if let path = projectPath { sql += " AND t.cwd=?"; binds.append(path) }
        if let q = query, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " AND (t.title LIKE ? OR t.preview LIKE ?)"
            binds.append("%\(q)%"); binds.append("%\(q)%")
        }
        sql += " ORDER BY t.updated_at DESC LIMIT ?"
        binds.append(limit)
        return try db.query(sql, binds) { st in
            ThreadRow(id: st.text(0), sourceId: st.text(1),
                      sourceKind: SourceKind(rawValue: st.text(1)) ?? .codex,
                      nativeId: st.text(2), projectPath: st.text(3), title: st.text(4),
                      updatedAt: st.int64(5), itemCount: st.int(6),
                      threadSource: st.text(7), archived: st.int(8) == 1)
        }
    }

    func thread(id: String) throws -> ThreadRow? {
        try db.query("""
        SELECT t.id,t.source_id,t.native_id,t.cwd,t.title,t.updated_at,t.item_count,t.thread_source,t.archived
        FROM threads t WHERE t.id=?
        """, [id]) { st in
            ThreadRow(id: st.text(0), sourceId: st.text(1),
                      sourceKind: SourceKind(rawValue: st.text(1)) ?? .codex,
                      nativeId: st.text(2), projectPath: st.text(3), title: st.text(4),
                      updatedAt: st.int64(5), itemCount: st.int(6),
                      threadSource: st.text(7), archived: st.int(8) == 1)
        }.first
    }

    func items(threadId: String, afterOrdinal: Int = -1, limit: Int = 200) throws -> [ItemRow] {
        try db.query("""
        SELECT id,thread_id,ordinal,item_type,role,created_at,text,truncated
        FROM items WHERE thread_id=? AND ordinal>? ORDER BY ordinal LIMIT ?
        """, [threadId, afterOrdinal, limit]) { st in
            ItemRow(id: st.text(0), threadId: st.text(1), ordinal: st.int(2),
                    itemType: st.text(3), role: st.text(4), createdAt: st.int64(5),
                    text: st.text(6), truncated: st.int(7) == 1)
        }
    }

    func search(_ query: String, sourceKind: SourceKind? = nil, limit: Int = 60) throws -> [SearchHit] {
        let match = TextTools.makeMatchQuery(query)
        guard !match.isEmpty else { return [] }
        var sql = """
        SELECT i.id,i.thread_id,t.title,t.source_id,i.item_type,i.created_at,i.text,i.ordinal
        FROM search_docs JOIN items i ON i.rowid=search_docs.rowid
        JOIN threads t ON t.id=i.thread_id
        WHERE search_docs MATCH ?
        """
        var binds: [Any?] = [match]
        if let kind = sourceKind { sql += " AND t.source_id=?"; binds.append(kind.rawValue) }
        sql += " ORDER BY rank LIMIT ?"
        binds.append(limit)
        return try db.query(sql, binds) { st in
            SearchHit(id: st.text(0), threadId: st.text(1), threadTitle: st.text(2),
                      sourceKind: SourceKind(rawValue: st.text(3)) ?? .codex,
                      itemType: st.text(4), createdAt: st.int64(5), text: st.text(6), ordinal: st.int(7))
        }
    }

    struct Stats {
        var threadCount = 0
        var itemCount = 0
        var todayItems = 0
        var projectCount = 0
        var sourceCount = 0
    }

    func stats() throws -> Stats {
        var s = Stats()
        s.threadCount = Int(try db.scalarInt("SELECT COUNT(*) FROM threads"))
        s.itemCount = Int(try db.scalarInt("SELECT COUNT(*) FROM items"))
        s.projectCount = Int(try db.scalarInt("SELECT COUNT(*) FROM projects"))
        s.sourceCount = Int(try db.scalarInt("SELECT COUNT(*) FROM sources WHERE available=1"))
        let startOfDay = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000)
        s.todayItems = Int(try db.scalarInt("SELECT COUNT(*) FROM items WHERE created_at>=?", [startOfDay]))
        return s
    }

    func dailyActivity(days: Int = 30) throws -> [(day: String, count: Int)] {
        try db.query("""
        SELECT date(created_at/1000,'unixepoch','localtime') d, COUNT(*)
        FROM items WHERE created_at >= ? GROUP BY d ORDER BY d
        """, [Int64((Date().timeIntervalSince1970 - Double(days * 86400)) * 1000)]) { st in
            (st.text(0), st.int(1))
        }
    }

    func dbSizeBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: root + "/history.db")
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
