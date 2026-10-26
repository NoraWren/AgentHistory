import Foundation

/// 检索聚合：命中先按内容族归并，每族只出一条，带族内命中数。
extension Store {
    /// 兼容旧调用点的简写。
    func search(_ query: String, sourceKind: SourceKind? = nil, limit: Int = 60) throws -> [SearchHit] {
        var options = SearchOptions()
        options.sourceKind = sourceKind
        options.limit = limit
        return try search(query, options: options)
    }

    private struct Row {
        let itemId: String
        let threadId: String
        let representativeId: String
        let title: String
        let sourceKind: SourceKind
        let itemType: String
        let createdAt: Int64
        let text: String
        let ordinal: Int
        let familyHits: Int
        let copyCount: Int
        let updatedAt: Int64
        let score: Double

        func toHit(_ matchKind: String) -> SearchHit {
            SearchHit(id: itemId, threadId: representativeId, threadTitle: title,
                      sourceKind: sourceKind, itemType: itemType, createdAt: createdAt,
                      text: text, ordinal: ordinal, hitThreadId: threadId,
                      copyCount: copyCount, groupHits: familyHits, matchKind: matchKind)
        }
    }

    func search(_ query: String, options: SearchOptions) throws -> [SearchHit] {
        // 调用方（MCP 客户端尤其）传个 0 或负数进来，下面 prefix 会直接崩掉整个进程。
        // 在这里统一夹一遍，所有入口都受保护。
        var options = options
        options.limit = min(max(options.limit, 1), 200)
        let cleaned = TextTools.sanitize(query)
        guard !cleaned.isEmpty else { return [] }
        var hits: [SearchHit] = []
        switch options.scope {
        case .threads:
            hits = try threadHits(cleaned, options: options)
        case .memory:
            hits = try memoryHits(cleaned, options: options, limit: options.limit)
        case .all:
            hits = try mergedHits(cleaned, options: options)
        }
        return Array(hits.prefix(options.limit))
    }

    /// 记忆通道：交接包、汇编、结论各查各的表，命中后直接给出去。
    /// 不做族聚合——这些文档没有副本概念，算进族里会把「另有 N 处副本」这个数算歪。
    private func memoryHits(_ cleaned: String, options: SearchOptions, limit: Int) throws -> [SearchHit] {
        guard limit > 0 else { return [] }
        var hits: [SearchHit] = []
        for m in try searchMemory(cleaned, limit: limit) {
            // 记忆没有来源与项目归属，按时间筛仍然有意义，别的筛选一律不适用。
            if let since = options.since, m.doc.createdAt < since { continue }
            if let until = options.until, m.doc.createdAt >= until { continue }
            hits.append(SearchHit(id: m.doc.id, threadId: m.doc.threadId,
                                  threadTitle: m.doc.title, sourceKind: .codex,
                                  itemType: m.doc.kind.rawValue, createdAt: m.doc.createdAt,
                                  text: m.doc.body, ordinal: m.doc.itemOrdinal,
                                  matchKind: m.matchKind, memoryKind: m.doc.kind,
                                  memoryId: m.doc.id, memoryPath: m.doc.path))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// 范围设成全部：两条通道都给名额，谁没占满就把剩下的让给对方。
    /// 早先是会话查满上限就不再补记忆，结果「全部」实际等于「只看会话」，
    /// 一个常见词能凑够六十条会话，记忆永远排在门外。
    private func mergedHits(_ cleaned: String, options: SearchOptions) throws -> [SearchHit] {
        // 记忆总量很少（本机二十几份文档），先给一半名额就够它露头，
        // 另一半留给会话，不至于搜一个词就全是汇编。
        let memoryCap = max(1, options.limit / 2)
        let memory = try memoryHits(cleaned, options: options, limit: memoryCap)
        let threadBudget = max(0, options.limit - memory.count)
        var threadOptions = options
        threadOptions.limit = threadBudget
        let threads = threadBudget > 0 ? try threadHits(cleaned, options: threadOptions) : []

        // 会话不够填的时候，把空出来的名额还给记忆。
        var memoryHits = memory
        let spare = options.limit - threads.count - memory.count
        if spare > 0, memory.count >= memoryCap {
            memoryHits = try self.memoryHits(cleaned, options: options, limit: memoryCap + spare)
        }
        // 记忆排前面：库里二十几份文档对二十二万条记录，命中本身就说明这条更该先看。
        return memoryHits + threads
    }

    /// 会话条目通道：短语优先，不足时放宽。
    private func threadHits(_ cleaned: String, options: SearchOptions) throws -> [SearchHit] {
        let phrase = TextTools.makePhraseQuery(cleaned)
        let loose = TextTools.makeLooseQuery(cleaned)

        var hits: [SearchHit] = []
        var seen = Set<String>()
        // 短语优先：连续汉字在索引里是相邻单字，用真正的短语表达式才能要求相邻。
        if !phrase.isEmpty, let rows = try run(phrase, options: options) {
            for row in rows where !seen.contains(row.representativeId) {
                seen.insert(row.representativeId)
                hits.append(row.toHit("短语"))
            }
        }
        if hits.count < options.limit, loose != phrase, let rows = try run(loose, options: options) {
            for row in rows where !seen.contains(row.representativeId) {
                seen.insert(row.representativeId)
                hits.append(row.toHit("宽松"))
                if hits.count >= options.limit { break }
            }
        }
        return Array(hits.prefix(options.limit))
    }

    /// 单条命中行在会话里的位置，用于直接跳转。
    func itemPosition(threadId: String, ordinal: Int, itemId: String?) throws -> Int? {
        if let itemId, !itemId.isEmpty {
            let exists = try db.query("SELECT ordinal FROM items WHERE id=? AND thread_id=?",
                                      [itemId, threadId]) { $0.int(0) }
            if let o = exists.first {
                return Int(try db.scalarInt("""
                    SELECT COUNT(*) FROM items WHERE thread_id=? AND ordinal<?
                    """, [threadId, o]))
            }
        }
        let exists = try db.query("SELECT 1 FROM items WHERE thread_id=? AND ordinal=? LIMIT 1",
                                  [threadId, ordinal]) { $0.int(0) }
        guard !exists.isEmpty else { return nil }
        return Int(try db.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id=? AND ordinal<?",
                                    [threadId, ordinal]))
    }

    /// 按偏移直接取一页，跳转不再靠反复翻页。
    func itemsPage(threadId: String, offset: Int, limit: Int = 200) throws -> [ItemRow] {
        try db.query("""
        SELECT i.id,i.thread_id,i.ordinal,i.item_type,i.role,i.created_at,i.text,i.truncated,
               COALESCE(t.ordinal,0)
        FROM items i LEFT JOIN turns t ON t.id=i.turn_id
        WHERE i.thread_id=? ORDER BY i.ordinal LIMIT ? OFFSET ?
        """, [threadId, max(1, limit), max(0, offset)]) { st in
            ItemRow(id: st.text(0), threadId: st.text(1), ordinal: st.int(2),
                    itemType: st.text(3), role: st.text(4), createdAt: st.int64(5),
                    text: st.text(6), truncated: st.int(7) == 1, turnOrdinal: st.int(8))
        }
    }

    /// 取会话最后 limit 条，按时间正序返回。
    /// items(threadId:limit:) 是从头取的，长会话想拿结尾只能靠这条，
    /// 不然「给结尾」给回来的是最早的 5000 条。
    func itemsTail(threadId: String, limit: Int = 500) throws -> [ItemRow] {
        let rows = try db.query("""
        SELECT i.id,i.thread_id,i.ordinal,i.item_type,i.role,i.created_at,i.text,i.truncated,
               COALESCE(t.ordinal,0)
        FROM items i LEFT JOIN turns t ON t.id=i.turn_id
        WHERE i.thread_id=? ORDER BY i.ordinal DESC LIMIT ?
        """, [threadId, max(1, limit)]) { st in
            ItemRow(id: st.text(0), threadId: st.text(1), ordinal: st.int(2),
                    itemType: st.text(3), role: st.text(4), createdAt: st.int64(5),
                    text: st.text(6), truncated: st.int(7) == 1, turnOrdinal: st.int(8))
        }
        return rows.reversed()
    }

    /// 会话数：全部 vs 合并后。
    func threadTotals() throws -> (all: Int, merged: Int) {
        let all = Int(try db.scalarInt("SELECT COUNT(*) FROM threads"))
        let merged = Int(try db.scalarInt("""
        SELECT COUNT(*) FROM threads t
        WHERE NOT EXISTS (SELECT 1 FROM thread_links l WHERE l.thread_id=t.id AND l.role='copy')
        """))
        return (all, merged)
    }

    // MARK: - 查询

    /// 返回 nil 表示 SQL 侧聚合失败，调用方走内存分组。
    private func run(_ match: String, options: SearchOptions) throws -> [Row]? {
        var filter = ""
        var binds: [Any?] = [match]
        if let kind = options.sourceKind { filter += " AND t.source_id=?"; binds.append(kind.rawValue) }
        if let path = options.projectPath { filter += " AND t.cwd=?"; binds.append(path) }
        if let since = options.since { filter += " AND i.created_at>=?"; binds.append(since) }
        if let until = options.until { filter += " AND i.created_at<?"; binds.append(until) }
        if options.onlyUser { filter += " AND i.item_type='userMessage'" }

        let select = """
        SELECT i.id,i.thread_id,i.ordinal,i.item_type,i.created_at,i.text,
               t.title,t.source_id,t.updated_at, bm25(search_docs) AS score,
               COALESCE(l.family_id, 'solo:'||t.id) AS fam,
               COALESCE(f.representative_thread_id, i.thread_id) AS rep,
               COALESCE(f.member_count, 1) AS members
        FROM search_docs
        JOIN items i ON i.rowid=search_docs.rowid
        JOIN threads t ON t.id=i.thread_id
        LEFT JOIN thread_links l ON l.thread_id=t.id
        LEFT JOIN thread_families f ON f.id=l.family_id
        WHERE search_docs MATCH ?\(filter)
        """

        func mapRow(_ st: Statement) -> Row {
            Row(itemId: st.text(0), threadId: st.text(1),
                representativeId: st.text(11), title: st.text(6),
                sourceKind: SourceKind(rawValue: st.text(7)) ?? .codex,
                itemType: st.text(3), createdAt: st.int64(4), text: st.text(5),
                ordinal: st.int(2), familyHits: 1,
                copyCount: max(0, st.int(12) - 1), updatedAt: st.int64(8), score: st.double(9))
        }

        guard options.mergeCopies else {
            var plainBinds = binds
            plainBinds.append(options.limit)
            return try db.query(select + " ORDER BY score ASC, t.updated_at DESC LIMIT ?",
                                plainBinds, mapRow)
        }

        let sql = """
        WITH base AS (\(select)),
        ranked AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY fam ORDER BY score ASC, updated_at DESC) AS rn,
                   COUNT(*) OVER (PARTITION BY fam) AS fam_hits
            FROM base)
        SELECT id,thread_id,ordinal,item_type,created_at,text,title,source_id,updated_at,score,
               rep,fam_hits,members
        FROM ranked WHERE rn=1
        ORDER BY score ASC, updated_at DESC
        LIMIT ?
        """
        var rankedBinds = binds
        rankedBinds.append(options.limit)
        do {
            return try db.query(sql, rankedBinds) { st in
                Row(itemId: st.text(0), threadId: st.text(1),
                    representativeId: st.text(10), title: st.text(6),
                    sourceKind: SourceKind(rawValue: st.text(7)) ?? .codex,
                    itemType: st.text(3), createdAt: st.int64(4), text: st.text(5),
                    ordinal: st.int(2), familyHits: st.int(11),
                    copyCount: max(0, st.int(12) - 1), updatedAt: st.int64(8), score: st.double(9))
            }
        } catch {
            return try memoryGrouped(select, binds: binds, limit: options.limit, mapRow: mapRow)
        }
    }

    /// 窗口函数不可用时：多取原始行，在内存里按族取最优。
    private func memoryGrouped(_ select: String, binds: [Any?], limit: Int,
                               mapRow: (Statement) -> Row) throws -> [Row] {
        var rawBinds = binds
        rawBinds.append(max(limit * 40, 800))
        let rows = try db.query(select + " ORDER BY score ASC, t.updated_at DESC LIMIT ?",
                                rawBinds, mapRow)
        var best: [String: Row] = [:]
        var counts: [String: Int] = [:]
        for r in rows {
            counts[r.representativeId, default: 0] += 1
            if let current = best[r.representativeId] {
                if r.score < current.score { best[r.representativeId] = r }
            } else {
                best[r.representativeId] = r
            }
        }
        return best.values
            .map { r in
                Row(itemId: r.itemId, threadId: r.threadId, representativeId: r.representativeId,
                    title: r.title, sourceKind: r.sourceKind, itemType: r.itemType,
                    createdAt: r.createdAt, text: r.text, ordinal: r.ordinal,
                    familyHits: counts[r.representativeId] ?? 1, copyCount: r.copyCount,
                    updatedAt: r.updatedAt, score: r.score)
            }
            .sorted { ($0.score, -Double($0.updatedAt)) < ($1.score, -Double($1.updatedAt)) }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
