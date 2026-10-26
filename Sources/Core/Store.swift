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
        CREATE TABLE IF NOT EXISTS thread_families(
            id TEXT PRIMARY KEY, representative_thread_id TEXT NOT NULL,
            member_count INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS thread_links(
            family_id TEXT NOT NULL, thread_id TEXT NOT NULL PRIMARY KEY,
            role TEXT NOT NULL DEFAULT 'copy', relation TEXT NOT NULL DEFAULT 'inferred',
            direction TEXT NOT NULL DEFAULT '', target_ref TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0);
        -- 记忆类内容单独占一张表：交接包、汇编、结论的召回方式完全一样，
        -- 塞进 items 里造伪会话会污染会话数、条目数、项目列表和血缘重建。
        CREATE TABLE IF NOT EXISTS memory_docs(
            id TEXT PRIMARY KEY, kind TEXT NOT NULL,
            title TEXT NOT NULL DEFAULT '', path TEXT NOT NULL DEFAULT '',
            thread_id TEXT NOT NULL DEFAULT '', item_ordinal INTEGER NOT NULL DEFAULT -1,
            category TEXT NOT NULL DEFAULT '', body TEXT NOT NULL DEFAULT '',
            meta TEXT NOT NULL DEFAULT '', todo TEXT NOT NULL DEFAULT '',
            content_hash TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'active',
            superseded_by TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0,
            generated_at INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS idx_threads_updated ON threads(updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_threads_source ON threads(source_id, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_thread ON items(thread_id, ordinal);
        -- 按轮取数（汇编、轮次摘要）走这两个索引，否则每轮都要把 items 全表扫一遍。
        CREATE INDEX IF NOT EXISTS idx_turns_thread ON turns(thread_id, ordinal);
        CREATE INDEX IF NOT EXISTS idx_turns_started ON turns(started_at);
        CREATE INDEX IF NOT EXISTS idx_items_turn ON items(turn_id, ordinal);
        CREATE INDEX IF NOT EXISTS idx_items_turn_type ON items(turn_id, item_type);
        CREATE INDEX IF NOT EXISTS idx_handoffs_thread ON handoffs(thread_id);
        CREATE INDEX IF NOT EXISTS idx_links_thread ON thread_links(thread_id);
        CREATE INDEX IF NOT EXISTS idx_links_family ON thread_links(family_id);
        CREATE INDEX IF NOT EXISTS idx_families_rep ON thread_families(representative_thread_id);
        CREATE INDEX IF NOT EXISTS idx_memory_kind ON memory_docs(kind, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_memory_thread ON memory_docs(thread_id, kind);
        -- 文件类按「类别加路径」唯一，补录才敢反复跑；结论按「会话加指纹」唯一，同一句话写两遍只留一条。
        CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_path ON memory_docs(kind, path) WHERE path<>'';
        CREATE UNIQUE INDEX IF NOT EXISTS idx_memory_fact ON memory_docs(thread_id, content_hash) WHERE kind='fact';
        CREATE VIRTUAL TABLE IF NOT EXISTS memory_docs_fts USING fts5(seg, content='', contentless_delete=1);
        """)
        try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('schema_version','2')")
        try backfillTurns()
        // 交接包与汇编早于索引功能产生，第一次启动补一遍，之后就靠手动触发。
        backfillMemoryIfNeeded()
    }

    /// 老库里条目没有轮次归属（`turns` 为空、`items.turn_id` 全空），
    /// 靠一次重建把它们按「一条用户消息带其后所有回复」切回轮次。
    /// 之后各来源同步会带原生轮次标识，这里只跑一次，结果记在 meta 里。
    private func backfillTurns() throws {
        let done = try db.query("SELECT value FROM meta WHERE key='turns_backfill'") { $0.text(0) }.first
        guard done != "1" else { return }
        let threads = try db.query("""
        SELECT DISTINCT i.thread_id FROM items i
        WHERE i.turn_id IS NULL AND NOT EXISTS(SELECT 1 FROM turns t WHERE t.thread_id=i.thread_id)
        """) { $0.text(0) }
        for threadId in threads {
            let rows = try db.query("""
            SELECT rowid,item_type,created_at FROM items WHERE thread_id=? ORDER BY ordinal
            """, [threadId]) { ($0.int64(0), $0.text(1), $0.int64(2)) }
            guard !rows.isEmpty else { continue }
            try db.transaction {
                var ordinal = 0
                var currentTurn: String? = nil
                for (rowid, type, created) in rows {
                    if currentTurn == nil || type == "userMessage" {
                        ordinal += 1
                        let id = UUID().uuidString
                        try db.run("""
                        INSERT INTO turns(id,thread_id,native_turn_id,ordinal,status,started_at,completed_at)
                        VALUES(?,?,?,?,'completed',?,?)
                        """, [id, threadId, "legacy-\(ordinal)", ordinal, created, created])
                        currentTurn = id
                    }
                    guard let turn = currentTurn else { continue }
                    try db.run("UPDATE items SET turn_id=? WHERE rowid=?", [turn, rowid])
                    try db.run("""
                    UPDATE turns SET started_at=MIN(started_at,CASE WHEN ?>0 THEN ? ELSE started_at END),
                        completed_at=MAX(completed_at,?) WHERE id=?
                    """, [created, created, created, turn])
                }
            }
        }
        try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('turns_backfill','1')")
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

    /// 写入条目，同时把条目归到轮次上。
    ///
    /// 轮次标识的优先级：条目自带的 `turnId` > 调用方给的 `turnNativeId` > 会话已有最后一轮。
    /// 来源没给轮次时（比如老数据、或增量里只有助手回复），接在最后一轮后面，
    /// 这样按轮折叠时不会出现一堆孤立的半轮。
    @discardableResult
    func upsertItems(threadId: String, items: [ItemInput], turnNativeId: String? = nil) throws -> (inserted: Int, redacted: Int) {
        var inserted = 0
        var redacted = 0
        var turnCache: [String: String] = [:]
        var lastNativeTurn: String? = try db.query(
            "SELECT native_turn_id FROM turns WHERE thread_id=? ORDER BY ordinal DESC LIMIT 1",
            [threadId]) { $0.text(0) }.first
        var nextTurnOrdinal = Int(try db.scalarInt(
            "SELECT COALESCE(MAX(ordinal),0) FROM turns WHERE thread_id=?", [threadId]))

        func turnId(for item: ItemInput) throws -> String? {
            let native = [item.turnId, turnNativeId].compactMap { $0 }.first { !$0.isEmpty }
                ?? lastNativeTurn
            guard let native, !native.isEmpty else { return nil }
            if let cached = turnCache[native] { return cached }
            let existing = try db.query("SELECT id FROM turns WHERE thread_id=? AND native_turn_id=?",
                                        [threadId, native]) { $0.text(0) }.first
            let id: String
            if let existing {
                id = existing
            } else {
                nextTurnOrdinal += 1
                id = UUID().uuidString
                try db.run("INSERT INTO turns(id,thread_id,native_turn_id,ordinal,status) VALUES(?,?,?,?,?)",
                           [id, threadId, native, nextTurnOrdinal, "completed"])
            }
            turnCache[native] = id
            lastNativeTurn = native
            return id
        }
        try db.transaction {
            for item in items {
                let itemTurnId = try turnId(for: item)
                let masked = Redactor.mask(item.text)
                redacted += masked.hits
                let id = UUID().uuidString
                // 原始 JSON 会随条目线性膨胀（实测 410MB），正文已经保留，原件可按 native_id 回源读取。
                let rawToStore = ""
                try db.run("""
                INSERT INTO items(id,thread_id,turn_id,native_item_id,ordinal,item_type,role,created_at,text,raw_json,truncated)
                VALUES(?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(thread_id,native_item_id) DO NOTHING
                """, [id, threadId, itemTurnId, item.nativeId, item.ordinal, item.itemType, item.role,
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
                    UPDATE items SET turn_id=COALESCE(?,turn_id), ordinal=?, item_type=?, role=?,
                        created_at=?, text=?, raw_json=?, truncated=?
                    WHERE rowid=?
                    """, [itemTurnId, item.ordinal, item.itemType, item.role, item.createdAt, masked.text, rawToStore,
                          item.truncated ? 1 : 0, rid])
                    try db.run("DELETE FROM search_docs WHERE rowid=?", [rid])
                }
                let seg = TextTools.segmentJoined(masked.text)
                if !seg.isEmpty {
                    try db.run("INSERT INTO search_docs(rowid,seg) VALUES(?,?)", [rowid, seg])
                }
            }
            // 轮次的起止时间按它下面条目的时间取，来源给了原生时间也不用，避免两套口径打架。
            for id in Set(turnCache.values) {
                try db.run("""
                UPDATE turns SET
                    started_at=(SELECT MIN(created_at) FROM items WHERE turn_id=turns.id AND created_at>0),
                    completed_at=(SELECT MAX(created_at) FROM items WHERE turn_id=turns.id)
                WHERE id=? AND EXISTS(SELECT 1 FROM items WHERE turn_id=turns.id)
                """, [id])
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
                 query: String? = nil, limit: Int = 300,
                 mergeCopies: Bool = false, before: Int64? = nil,
                 beforeId: String? = nil) throws -> [ThreadRow] {
        var sql = threadSelectBase
        var binds: [Any?] = []
        if let kind = sourceKind { sql += " AND t.source_id=?"; binds.append(kind.rawValue) }
        if let path = projectPath { sql += " AND t.cwd=?"; binds.append(path) }
        if let q = query, !q.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " AND (t.title LIKE ? OR t.preview LIKE ?)"
            binds.append("%\(q)%"); binds.append("%\(q)%")
        }
        if mergeCopies { sql += " AND COALESCE(l.role,'')<>'copy'" }
        // 按 updated_at 倒序翻页：给一个游标就只取更早的，比 offset 数页稳。
        // 同一毫秒可能有好几个会话（真实库里有 15 对），光比时间戳会把跨界的那几个漏掉或重复，
        // 所以再拿 id 当第二把尺子。
        if let before {
            if let beforeId, !beforeId.isEmpty {
                sql += " AND (t.updated_at<? OR (t.updated_at=? AND t.id<?))"
                binds.append(before); binds.append(before); binds.append(beforeId)
            } else {
                sql += " AND t.updated_at<?"
                binds.append(before)
            }
        }
        sql += " ORDER BY t.updated_at DESC, t.id DESC LIMIT ?"
        // 负数进 SQLite 的 LIMIT 意思是「不限」，调用方一个笔误就会把整库搬进内存。
        binds.append(max(1, min(limit, 5000)))
        return try db.query(sql, binds) { st in
            ThreadRow(id: st.text(0), sourceId: st.text(1),
                      sourceKind: SourceKind(rawValue: st.text(1)) ?? .codex,
                      nativeId: st.text(2), projectPath: st.text(3), title: st.text(4),
                      updatedAt: st.int64(5), itemCount: st.int(6),
                      threadSource: st.text(7), archived: st.int(8) == 1,
                      copyCount: max(0, st.int(11) - 1),
                      familyId: st.text(9).isEmpty ? nil : st.text(9),
                      lineageRole: st.text(10))
        }
    }

    /// 当前筛选条件下的会话总数。列表分页后要靠它说明「还有多少没显示」。
    func threadCount(sourceKind: SourceKind? = nil, projectPath: String? = nil,
                     mergeCopies: Bool = false) throws -> Int {
        var sql = """
        SELECT COUNT(*) FROM threads t
        LEFT JOIN thread_links l ON l.thread_id=t.id
        WHERE 1=1
        """
        var binds: [Any?] = []
        if let kind = sourceKind { sql += " AND t.source_id=?"; binds.append(kind.rawValue) }
        if let path = projectPath { sql += " AND t.cwd=?"; binds.append(path) }
        if mergeCopies { sql += " AND COALESCE(l.role,'')<>'copy'" }
        return Int(try db.scalarInt(sql, binds))
    }

    private var threadSelectBase: String {
        """
        SELECT t.id,t.source_id,t.native_id,t.cwd,t.title,t.updated_at,t.item_count,t.thread_source,t.archived,
               COALESCE(l.family_id,''),COALESCE(l.role,''),COALESCE(f.member_count,1)
        FROM threads t
        LEFT JOIN thread_links l ON l.thread_id=t.id
        LEFT JOIN thread_families f ON f.id=l.family_id
        WHERE 1=1
        """
    }

    func thread(id: String) throws -> ThreadRow? {
        try db.query(threadSelectBase + " AND t.id=?", [id]) { st in
            ThreadRow(id: st.text(0), sourceId: st.text(1),
                      sourceKind: SourceKind(rawValue: st.text(1)) ?? .codex,
                      nativeId: st.text(2), projectPath: st.text(3), title: st.text(4),
                      updatedAt: st.int64(5), itemCount: st.int(6),
                      threadSource: st.text(7), archived: st.int(8) == 1,
                      copyCount: max(0, st.int(11) - 1),
                      familyId: st.text(9).isEmpty ? nil : st.text(9),
                      lineageRole: st.text(10))
        }.first
    }

    func items(threadId: String, afterOrdinal: Int = -1, limit: Int = 200) throws -> [ItemRow] {
        try db.query("""
        SELECT i.id,i.thread_id,i.ordinal,i.item_type,i.role,i.created_at,i.text,i.truncated,
               COALESCE(t.ordinal,0)
        FROM items i LEFT JOIN turns t ON t.id=i.turn_id
        WHERE i.thread_id=? AND i.ordinal>? ORDER BY i.ordinal LIMIT ?
        """, [threadId, afterOrdinal, max(1, limit)]) { st in
            // 只挡负数：SQLite 里 LIMIT 为负等于不限。导出要一次拿完整会话，所以不设上限。
            ItemRow(id: st.text(0), threadId: st.text(1), ordinal: st.int(2),
                    itemType: st.text(3), role: st.text(4), createdAt: st.int64(5),
                    text: st.text(6), truncated: st.int(7) == 1, turnOrdinal: st.int(8))
        }
    }

    struct TurnRow: Identifiable {
        let id: String
        let ordinal: Int
        let startedAt: Int64
        let completedAt: Int64
        var itemCount: Int = 0
        /// 这一轮的第一个问题，列表里当轮次摘要用。
        var prompt: String = ""
    }

    func turns(threadId: String) throws -> [TurnRow] {
        try db.query("""
        SELECT t.id,t.ordinal,t.started_at,t.completed_at,
               (SELECT COUNT(*) FROM items i WHERE i.turn_id=t.id),
               COALESCE((SELECT i.text FROM items i WHERE i.turn_id=t.id AND i.role='user'
                         ORDER BY i.ordinal LIMIT 1),'')
        FROM turns t WHERE t.thread_id=? ORDER BY t.ordinal
        """, [threadId]) { st in
            TurnRow(id: st.text(0), ordinal: st.int(1), startedAt: st.int64(2),
                    completedAt: st.int64(3), itemCount: st.int(4), prompt: st.text(5))
        }
    }

    /// 某一轮第一条记录在会话里的序号，跳轮次时按它算偏移。
    func firstItemOrdinal(turnId: String) throws -> Int? {
        try db.query("SELECT MIN(ordinal) FROM items WHERE turn_id=?", [turnId]) { $0.int(0) }.first
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
