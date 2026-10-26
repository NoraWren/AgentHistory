import Foundation

/// 记忆类内容的类别：交接包、主题汇编、结论。
/// 三者共用一张表和一套索引，因为它们被召回的方式完全一样：按关键词命中、按时间倒序、带出处。
enum MemoryKind: String, CaseIterable {
    case handoff
    case digest
    case fact

    var displayName: String {
        switch self {
        case .handoff: return "交接包"
        case .digest: return "汇编"
        case .fact: return "结论"
        }
    }

    /// 结论的三种类别，别的值一概不收。
    static let factCategories = ["决策", "偏好", "事实"]

    static func isFactCategory(_ raw: String) -> Bool {
        factCategories.contains(raw)
    }
}

enum MemoryError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}

struct MemoryDoc: Identifiable {
    let id: String
    let kind: MemoryKind
    let title: String
    let path: String
    let threadId: String
    let itemOrdinal: Int
    let category: String
    let body: String
    let meta: String
    let todo: String
    let status: String
    let supersededBy: String
    let createdAt: Int64
    let updatedAt: Int64
    let generatedAt: Int64

    var isActive: Bool { status == "active" }
    /// 结论被取代或作废之后，正文照旧保留，只是默认不再出现在检索里。
    var statusLabel: String {
        switch status {
        case "superseded": return supersededBy.isEmpty ? "已取代" : "已被取代"
        case "void": return "已作废"
        default: return ""
        }
    }
}

struct MemoryHit {
    let doc: MemoryDoc
    let score: Double
    let matchKind: String
}

/// 结论入库前的指纹：正文去掉所有空白后算 FNV-1a。
/// 用哈希而不是正文比对，是为了让「多一个句号」「多一个换行」的复述算作同一条。
enum MemoryFingerprint {
    static func normalize(_ text: String) -> String {
        // 空白全去掉；末尾的句号逗号也去掉，否则同一句话换个标点就成了两条。
        // 只削末尾，句中的小数点、序号里的点都留着，「3.5」不会和「35」撞上。
        let joined = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined()
        let trailing: Set<Character> = ["。", "．", ".", "，", ",", "、", "！", "!", "？", "?", "；", ";", "：", ":"]
        var end = joined.endIndex
        while end > joined.startIndex {
            let prev = joined.index(before: end)
            guard trailing.contains(joined[prev]) else { break }
            end = prev
        }
        return String(joined[joined.startIndex..<end])
    }

    static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalize(text).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension Store {
    // MARK: - 写入

    /// 文件类记忆（交接包、汇编）按「类别加路径」幂等登记。
    /// 同一份文件重复登记只更新正文；正文没变时直接跳过，补录才敢反复跑。
    @discardableResult
    func upsertMemoryFile(kind: MemoryKind, path: String, title: String, body: String,
                          threadId: String = "", meta: String = "", todo: String = "",
                          generatedAt: Int64 = 0) throws -> (id: String, inserted: Bool) {
        guard !path.isEmpty else { throw MemoryError.message("文件类记忆必须有路径") }
        let hash = MemoryFingerprint.of(body)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if let existing = try db.query(
            "SELECT id, content_hash FROM memory_docs WHERE kind=? AND path=?",
            [kind.rawValue, path], { (id: $0.text(0), hash: $0.text(1)) }).first {
            if existing.hash == hash { return (existing.id, false) }
            try db.run("""
            UPDATE memory_docs SET title=?, body=?, content_hash=?, thread_id=?, meta=?, todo=?,
                generated_at=?, updated_at=? WHERE id=?
            """, [title, body, hash, threadId, meta, todo,
                  generatedAt > 0 ? generatedAt : now, now, existing.id])
            try reindexMemory(id: existing.id, body: body)
            return (existing.id, false)
        }
        let id = UUID().uuidString
        try db.run("""
        INSERT INTO memory_docs(id,kind,title,path,thread_id,item_ordinal,category,body,meta,todo,
                                content_hash,status,superseded_by,created_at,updated_at,generated_at)
        VALUES(?,?,?,?,?,-1,'',?,?,?,?,'active','',?,?,?)
        """, [id, kind.rawValue, title, path, threadId, body, meta, todo, hash, now, now,
              generatedAt > 0 ? generatedAt : now])
        try reindexMemory(id: id, body: body)
        return (id, true)
    }

    /// 索引重建：contentless FTS 必须手写 rowid 才和主表对得上。
    private func reindexMemory(id: String, body: String) throws {
        let rowids = try db.query("SELECT rowid FROM memory_docs WHERE id=?", [id]) { $0.int64(0) }
        guard let rowid = rowids.first else { return }
        try db.run("DELETE FROM memory_docs_fts WHERE rowid=?", [rowid])
        let seg = TextTools.segmentJoined(body)
        guard !seg.isEmpty else { return }
        try db.run("INSERT INTO memory_docs_fts(rowid,seg) VALUES(?,?)", [rowid, seg])
    }

    /// 写一条结论。正文去掉空白后为空、超过四千年字、类别不在三值之内，都当场拒绝。
    /// 同一会话里同一正文已经记过时不新增，返回已有标识并说明是重复。
    @discardableResult
    func rememberFact(body: String, category: String, threadId: String = "",
                      itemOrdinal: Int = -1, supersedes: String = "") throws -> (id: String, duplicate: Bool) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MemoryError.message("结论正文不能为空") }
        guard trimmed.count <= 4000 else {
            throw MemoryError.message("结论正文最多 4000 字，收到 \(trimmed.count) 字")
        }
        guard MemoryKind.isFactCategory(category) else {
            let allowed = MemoryKind.factCategories.joined(separator: " / ")
            throw MemoryError.message("category 只认这些值：\(allowed)")
        }
        let hash = MemoryFingerprint.of(trimmed)
        if let existing = try db.query(
            "SELECT id FROM memory_docs WHERE kind='fact' AND thread_id=? AND content_hash=?",
            [threadId, hash], { $0.text(0) }).first {
            return (existing, true)
        }
        if !supersedes.isEmpty {
            let found = try db.query("SELECT 1 FROM memory_docs WHERE id=? AND kind='fact'",
                                     [supersedes]) { $0.int(0) }
            guard !found.isEmpty else {
                throw MemoryError.message("要取代的结论 \(supersedes) 不存在，没有写入任何内容")
            }
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let id = UUID().uuidString
        let title = String(trimmed.prefix(40))
        try db.transaction {
            try db.run("""
            INSERT INTO memory_docs(id,kind,title,path,thread_id,item_ordinal,category,body,meta,todo,
                                    content_hash,status,superseded_by,created_at,updated_at,generated_at)
            VALUES(?,'fact',?,'',?,?,?,?,'','',?,'active','',?,?,?)
            """, [id, title, threadId, itemOrdinal, category, trimmed, hash, now, now, now])
            if !supersedes.isEmpty {
                try db.run("UPDATE memory_docs SET status='superseded', superseded_by=?, updated_at=? WHERE id=?",
                           [id, now, supersedes])
            }
        }
        try reindexMemory(id: id, body: trimmed)
        return (id, false)
    }

    /// 作废一条结论。已经作废或已被取代的不再改动，返回 false。
    @discardableResult
    func voidFact(id: String) throws -> MemoryDoc? {
        let rows = try db.query("""
        SELECT id,kind,title,path,thread_id,item_ordinal,category,body,meta,todo,status,superseded_by,
               created_at,updated_at,generated_at FROM memory_docs WHERE id=?
        """, [id], mapMemory).first
        guard let doc = rows else { throw MemoryError.message("找不到结论 \(id)") }
        guard doc.kind == .fact else { throw MemoryError.message("\(id) 不是结论，不能作废") }
        guard doc.status == "active" else { return nil }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try db.run("UPDATE memory_docs SET status='void', updated_at=? WHERE id=?", [now, id])
        // 作废之后默认就不再出现在检索里，索引也要跟着撤掉，不然「已在库里但搜不到」两头对不上。
        let rowids = try db.query("SELECT rowid FROM memory_docs WHERE id=?", [id]) { $0.int64(0) }
        for rid in rowids { try db.run("DELETE FROM memory_docs_fts WHERE rowid=?", [rid]) }
        return doc
    }

    // MARK: - 读取

    private func mapMemory(_ st: Statement) -> MemoryDoc {
        MemoryDoc(id: st.text(0), kind: MemoryKind(rawValue: st.text(1)) ?? .fact,
                  title: st.text(2), path: st.text(3), threadId: st.text(4),
                  itemOrdinal: st.int(5), category: st.text(6), body: st.text(7),
                  meta: st.text(8), todo: st.text(9), status: st.text(10), supersededBy: st.text(11),
                  createdAt: st.int64(12), updatedAt: st.int64(13), generatedAt: st.int64(14))
    }

    private static let memoryColumns = """
    id,kind,title,path,thread_id,item_ordinal,category,body,meta,todo,status,superseded_by,
    created_at,updated_at,generated_at
    """

    func memoryDoc(id: String) throws -> MemoryDoc? {
        try db.query("SELECT \(Self.memoryColumns) FROM memory_docs WHERE id=?", [id], mapMemory).first
    }

    /// 按会话取回它的记忆：交接包与结论。汇编不按会话归属，所以不出现在这里。
    func memoryForThread(_ threadId: String, includeInactive: Bool = false) throws -> [MemoryDoc] {
        let statusClause = includeInactive ? "" : " AND status='active'"
        return try db.query("""
        SELECT \(Self.memoryColumns) FROM memory_docs
        WHERE thread_id=? AND kind IN ('handoff','fact')\(statusClause)
        ORDER BY created_at DESC
        """, [threadId], mapMemory)
    }

    /// 列某类记忆，按时间倒序，不限关键词。recall 不带关键词时走这里。
    func listMemory(kind: MemoryKind? = nil, threadId: String? = nil,
                    includeInactive: Bool = false, limit: Int = 40) throws -> [MemoryDoc] {
        var filter = ""
        var binds: [Any?] = []
        if let kind { filter += " AND kind=?"; binds.append(kind.rawValue) }
        if let threadId, !threadId.isEmpty { filter += " AND thread_id=?"; binds.append(threadId) }
        if !includeInactive { filter += " AND status='active'" }
        binds.append(max(1, min(limit, 200)))
        return try db.query("""
        SELECT \(Self.memoryColumns) FROM memory_docs WHERE 1=1\(filter)
        ORDER BY created_at DESC LIMIT ?
        """, binds, mapMemory)
    }

    /// 记忆通道检索：短语优先，不足时放宽到单字并列。
    func searchMemory(_ query: String, kind: MemoryKind? = nil, threadId: String? = nil,
                      includeInactive: Bool = false, limit: Int = 40) throws -> [MemoryHit] {
        let cleaned = TextTools.sanitize(query)
        guard !cleaned.isEmpty else { return [] }
        let cap = min(max(limit, 1), 200)
        var hits: [MemoryHit] = []
        var seen = Set<String>()
        for (expr, label) in [(TextTools.makePhraseQuery(cleaned), "短语"),
                              (TextTools.makeLooseQuery(cleaned), "宽松")] {
            guard !expr.isEmpty, hits.count < cap else { continue }
            if label == "宽松", expr == TextTools.makePhraseQuery(cleaned) { continue }
            for row in try runMemory(expr, kind: kind, threadId: threadId,
                                     includeInactive: includeInactive, limit: cap) {
                guard !seen.contains(row.doc.id) else { continue }
                seen.insert(row.doc.id)
                hits.append(MemoryHit(doc: row.doc, score: row.score, matchKind: label))
                if hits.count >= cap { break }
            }
        }
        return Array(hits.prefix(cap))
    }

    private func runMemory(_ match: String, kind: MemoryKind?, threadId: String?,
                           includeInactive: Bool, limit: Int) throws -> [MemoryHit] {
        var filter = ""
        var binds: [Any?] = [match]
        if let kind { filter += " AND m.kind=?"; binds.append(kind.rawValue) }
        if let threadId, !threadId.isEmpty { filter += " AND m.thread_id=?"; binds.append(threadId) }
        if !includeInactive { filter += " AND m.status='active'" }
        binds.append(max(1, limit))
        return try db.query("""
        SELECT m.\(Self.memoryColumns), bm25(memory_docs_fts) AS score
        FROM memory_docs_fts JOIN memory_docs m ON m.rowid=memory_docs_fts.rowid
        WHERE memory_docs_fts MATCH ?\(filter)
        ORDER BY score ASC, m.created_at DESC LIMIT ?
        """, binds) { st in
            MemoryHit(doc: self.mapMemory(st), score: st.double(15), matchKind: "短语")
        }
    }

    /// 交接包清单：只读 agent 写的交接包，同步留下的传输记录不计入。
    /// 早前写入的行没有状态标记，按交接包一并读出，免得老数据凭空消失。
    func handoffDocs(threadId: String? = nil, limit: Int = 40) throws -> [MemoryDoc] {
        var filter = ""
        var binds: [Any?] = []
        if let threadId, !threadId.isEmpty { filter += " AND thread_id=?"; binds.append(threadId) }
        binds.append(max(1, min(limit, 200)))
        return try db.query("""
        SELECT \(Self.memoryColumns) FROM memory_docs
        WHERE kind='handoff' AND status='active'\(filter)
        ORDER BY created_at DESC LIMIT ?
        """, binds, mapMemory)
    }

    /// 结论清单：界面按类别筛，默认只列还能用的那些。
    /// 已作废与已被取代的仍然留在库里，勾上「看作废」才读得出来。
    func facts(category: String? = nil, includeInactive: Bool = false,
               limit: Int = 300) throws -> [MemoryDoc] {
        var filter = ""
        var binds: [Any?] = []
        if let category, !category.isEmpty { filter += " AND category=?"; binds.append(category) }
        if !includeInactive { filter += " AND status='active'" }
        binds.append(max(1, min(limit, 500)))
        return try db.query("""
        SELECT \(Self.memoryColumns) FROM memory_docs WHERE kind='fact'\(filter)
        ORDER BY created_at DESC LIMIT ?
        """, binds, mapMemory)
    }

    /// 界面顶上的分类计数。负数不做，空库如实给零。
    func memoryCounts() throws -> (handoffs: Int, digests: Int, facts: Int) {
        func count(_ sql: String) -> Int { (try? Int(db.scalarInt(sql))) ?? 0 }
        return (count("SELECT COUNT(*) FROM memory_docs WHERE kind='handoff' AND status='active'"),
                count("SELECT COUNT(*) FROM memory_docs WHERE kind='digest' AND status='active'"),
                count("SELECT COUNT(*) FROM memory_docs WHERE kind='fact' AND status='active'"))
    }

    /// 库里的传输记录条数，列出交接包时用来说明「另有若干条未计入」。
    func transferRecordCount() throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM handoffs WHERE status='transferred'"))
    }

    // MARK: - 补录

    /// 把磁盘上已经存在的交接包与汇编登记进索引。
    /// 老产物早于索引功能产生，只能靠这一遍补；跑完写标记，之后由使用者手动触发。
    @discardableResult
    func backfillMemory() throws -> (added: Int, skipped: Int, removed: Int) {
        var added = 0, skipped = 0, removed = 0
        var seen = Set<String>()
        let fm = FileManager.default

        let handoffsDir = root + "/handoffs"
        let digestDir = root + "/digests"
        var targets: [(MemoryKind, String)] = []
        for name in (try? fm.contentsOfDirectory(atPath: handoffsDir)) ?? [] where name.hasSuffix(".md") {
            targets.append((.handoff, handoffsDir + "/" + name))
        }
        // digests 下面还有 cache 与 work 两个工作目录，只收顶层的产物。
        for name in (try? fm.contentsOfDirectory(atPath: digestDir)) ?? [] where name.hasSuffix(".md") {
            targets.append((.digest, digestDir + "/" + name))
        }

        for (kind, path) in targets {
            seen.insert(kind.rawValue + "|" + path)
            guard let body = try? String(contentsOfFile: path, encoding: .utf8), !body.isEmpty else {
                skipped += 1
                continue
            }
            let attrs = try? fm.attributesOfItem(atPath: path)
            let mtime = Int64(((attrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970 * 1000)
            let name = (path as NSString).lastPathComponent
            let title = name.replacingOccurrences(of: ".md", with: "")
            let threadId = try memoryThreadId(forFile: path, kind: kind, name: name)
            let meta = kind == .digest ? "覆盖范围见标题" : ""
            let result = try upsertMemoryFile(kind: kind, path: path, title: title, body: body,
                                              threadId: threadId, meta: meta, generatedAt: mtime)
            if result.inserted { added += 1 } else { skipped += 1 }
        }

        // 磁盘上已经删掉的文档，索引里也要跟着撤，否则检索会一直返回一个打不开的命。
        let stored = try db.query("SELECT id, kind, path FROM memory_docs WHERE path<>''") {
            (id: $0.text(0), key: $0.text(1) + "|" + $0.text(2))
        }
        for row in stored where !seen.contains(row.key) {
            try db.run("DELETE FROM memory_docs_fts WHERE rowid=(SELECT rowid FROM memory_docs WHERE id=?)", [row.id])
            try db.run("DELETE FROM memory_docs WHERE id=?", [row.id])
            removed += 1
        }
        if added > 0 || removed > 0 {
            try db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('memory_backfill_v1',?)",
                       [String(Int(Date().timeIntervalSince1970))])
        }
        return (added, skipped, removed)
    }

    /// 交接包文件名带会话前缀时回查会话；回查不到就留空，不编造来源。
    private func memoryThreadId(forFile path: String, kind: MemoryKind, name: String) throws -> String {
        guard kind == .handoff else { return "" }
        let stem = name.replacingOccurrences(of: ".md", with: "")
        // append_handoff 写的是完整 UUID；界面导出的写的是会话 ID 前八位加目标名。
        if let hit = try db.query("SELECT thread_id FROM handoffs WHERE id=? AND thread_id<>''",
                                  [stem], { $0.text(0) }).first {
            return hit
        }
        guard stem.count >= 8 else { return "" }
        let prefix = String(stem.prefix(8))
        let ids = try db.query("SELECT id FROM threads WHERE substr(id,1,8)=?", [prefix]) { $0.text(0) }
        return ids.count == 1 ? ids[0] : ""
    }

    /// 首次启动补录一遍，之后靠标记位跳过。目录不存在或已经补过都是正常情况。
    func backfillMemoryIfNeeded() {
        let done = try? db.query("SELECT value FROM meta WHERE key='memory_backfill_v1'") { $0.text(0) }.first
        guard done == nil else { return }
        _ = try? backfillMemory()
        _ = try? db.run("INSERT OR REPLACE INTO meta(key,value) VALUES('memory_backfill_v1',?)",
                        [String(Int(Date().timeIntervalSince1970))])
    }
}

