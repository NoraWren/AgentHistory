import Foundation

struct LineageReport {
    var threadCount = 0
    var familyCount = 0
    var collapsedCopies = 0
    var confirmedLinks = 0
    var inferredLinks = 0
    var unmatchedHandoffs = 0
    var skippedReasons: [String: Int] = [:]
    var itemsBefore: Int64 = 0
    var itemsAfter: Int64 = 0
    var docsBefore: Int64 = 0
    var docsAfter: Int64 = 0
    var duration: Double = 0

    var summary: String {
        var parts = ["会话 \(threadCount)", "内容族 \(familyCount)", "折叠副本 \(collapsedCopies)"]
        parts.append("同步记录 \(confirmedLinks) 条")
        parts.append("按内容推断 \(inferredLinks) 条")
        if unmatchedHandoffs > 0 { parts.append("未匹配转出记录 \(unmatchedHandoffs) 条") }
        return parts.joined(separator: "，") + String(format: "，耗时 %.2f 秒", duration)
    }
}

/// 从 handoffs 的反推结果。
private struct CopyEvidence {
    let originalId: String
    let copyId: String
    let direction: String
    let targetRef: String
}

enum LineageBuilder {
    private struct Node {
        let id: String
        let source: SourceKind
        let nativeId: String
        let title: String
        let cwd: String
        let createdAt: Int64
        let itemCount: Int
        let chars: Int

        var signature: String { "\(title)\u{1}\(cwd)\u{1}\(itemCount)\u{1}\(chars)" }
    }

    /// 目标端的原生会话来源与路径形态。返回 nil 表示这条转出记录不是原生会话。
    private static func targetRule(_ target: String) -> (source: SourceKind, stripExtension: Bool)? {
        switch target {
        case "kimi": return (.kimi, false)
        case "workbuddy": return (.workbuddy, true)
        case "deepseek-native": return (.deepseek, false)
        case "claude": return (.claude, true)
        default: return nil   // codex / deepseek 的转出物是交接包 .md，不构成副本关系
        }
    }

    private static func lastComponent(_ path: String, stripExtension: Bool) -> String {
        let firstLine = path.split(separator: "\n").first.map(String.init) ?? path
        var name = (firstLine.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        if stripExtension, !name.isEmpty {
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty { name = (name as NSString).deletingPathExtension }
        }
        return name
    }

    static func rebuild(store: Store) throws -> LineageReport {
        let started = Date()
        var report = LineageReport()
        report.itemsBefore = try store.db.scalarInt("SELECT COUNT(*) FROM items")
        report.docsBefore = try store.db.scalarInt("SELECT COUNT(*) FROM search_docs")

        let nodes: [Node] = try store.db.query("""
        SELECT t.id, t.source_id, t.native_id, t.title, t.cwd, t.created_at,
               COALESCE(s.c,0), COALESCE(s.ch,0)
        FROM threads t
        LEFT JOIN (SELECT thread_id, COUNT(*) c, SUM(LENGTH(text)) ch FROM items GROUP BY thread_id) s
               ON s.thread_id = t.id
        """) { st in
            Node(id: st.text(0), source: SourceKind(rawValue: st.text(1)) ?? .codex,
                 nativeId: st.text(2), title: st.text(3), cwd: st.text(4),
                 createdAt: st.int64(5), itemCount: st.int(6), chars: st.int(7))
        }
        report.threadCount = nodes.count
        guard !nodes.isEmpty else {
            try clear(store)
            report.itemsAfter = report.itemsBefore
            report.docsAfter = report.docsBefore
            report.duration = Date().timeIntervalSince(started)
            return report
        }

        var indexById: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { indexById[n.id] = i }
        var nativeToIndex: [SourceKind: [String: Int]] = [:]
        for (i, n) in nodes.enumerated() { nativeToIndex[n.source, default: [:]][n.nativeId] = i }

        // 并查集：一条转出记录把「来源会话」和「目标会话」连在一起。
        var parent = Array(0..<nodes.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != c { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        var evidence: [CopyEvidence] = []
        let handoffs: [(threadId: String, target: String, payload: String)] = try store.db.query(
            "SELECT thread_id, target, payload FROM handoffs") { ($0.text(0), $0.text(1), $0.text(2)) }

        for h in handoffs {
            guard let rule = targetRule(h.target) else {
                report.unmatchedHandoffs += 1
                report.skippedReasons["交接包不是原生会话", default: 0] += 1
                continue
            }
            guard let originalIndex = indexById[h.threadId] else {
                report.unmatchedHandoffs += 1
                report.skippedReasons["来源会话未入库", default: 0] += 1
                continue
            }
            let candidates = nativeToIndex[rule.source] ?? [:]
            let wanted = lastComponent(h.payload, stripExtension: rule.stripExtension)
            var copyIndex = candidates[wanted]
            if copyIndex == nil, !wanted.isEmpty {
                copyIndex = candidates.first(where: { !$0.key.isEmpty && (wanted.hasSuffix($0.key) || $0.key.hasSuffix(wanted)) })?.value
            }
            guard let copyIndex, copyIndex != originalIndex else {
                report.unmatchedHandoffs += 1
                report.skippedReasons[rule.source.displayName + " 目标未入库", default: 0] += 1
                continue
            }
            union(originalIndex, copyIndex)
            evidence.append(CopyEvidence(
                originalId: nodes[originalIndex].id,
                copyId: nodes[copyIndex].id,
                direction: "\(nodes[originalIndex].source.displayName)→\(nodes[copyIndex].source.displayName)",
                targetRef: wanted))
        }
        report.confirmedLinks = evidence.count

        // 族：先收并查集得到的组，再对剩余会话按四项等值推断。
        var groups: [[Int]] = []
        var grouped: [Int: [Int]] = [:]
        for i in nodes.indices { grouped[find(i), default: []].append(i) }
        var assigned = Set<Int>()
        for (_, members) in grouped where members.count > 1 {
            groups.append(members)
            for m in members { assigned.insert(m) }
        }

        var bySignature: [String: [Int]] = [:]
        for i in nodes.indices where !assigned.contains(i) {
            bySignature[nodes[i].signature, default: []].append(i)
        }
        for (_, members) in bySignature where members.count > 1 {
            groups.append(members)
            report.inferredLinks += members.count
            for m in members { assigned.insert(m) }
        }

        // 代表会话：created_at 升序，同值按来源声明顺序；0 视为未知，排最后。
        func rank(_ i: Int) -> (Int64, Int, String) {
            let n = nodes[i]
            let order = SourceKind.allCases.firstIndex(of: n.source) ?? SourceKind.allCases.count
            return (n.createdAt == 0 ? Int64.max : n.createdAt, order, n.id)
        }

        let evidenceByCopy: [String: CopyEvidence] = Dictionary(
            evidence.map { ($0.copyId, $0) }, uniquingKeysWith: { first, _ in first })
        let confirmedOriginalIds = Set(evidence.map { $0.originalId })
        let inferredThreadIds = Set(groups.flatMap { $0 }.filter { idx in
            !evidenceByCopy.keys.contains(nodes[idx].id) && !confirmedOriginalIds.contains(nodes[idx].id)
        }.map { nodes[$0].id })

        try clear(store)
        try store.db.transaction {
            for members in groups {
                let ordered = members.sorted { rank($0) < rank($1) }
                guard let representative = ordered.first else { continue }
                let familyId = "fam:" + nodes[representative].id
                try store.db.run("""
                INSERT OR REPLACE INTO thread_families(id,representative_thread_id,member_count,created_at)
                VALUES(?,?,?,?)
                """, [familyId, nodes[representative].id, ordered.count, Int64(Date().timeIntervalSince1970)])
                for (position, index) in ordered.enumerated() {
                    let node = nodes[index]
                    let isRepresentative = position == 0
                    let relation: String
                    let direction: String
                    let targetRef: String
                    if let e = evidenceByCopy[node.id] {
                        relation = "confirmed"
                        direction = e.direction
                        targetRef = e.targetRef
                    } else if inferredThreadIds.contains(node.id) {
                        relation = "inferred"
                        direction = ""
                        targetRef = ""
                    } else if isRepresentative {
                        relation = "confirmed"
                        direction = ""
                        targetRef = ""
                    } else {
                        relation = "confirmed"
                        direction = "\(nodes[representative].source.displayName)→\(node.source.displayName)"
                        targetRef = node.nativeId
                    }
                    try store.db.run("""
                    INSERT OR REPLACE INTO thread_links(family_id,thread_id,role,relation,direction,target_ref,created_at)
                    VALUES(?,?,?,?,?,?,?)
                    """, [familyId, node.id, isRepresentative ? "original" : "copy",
                          relation, direction, targetRef, Int64(Date().timeIntervalSince1970)])
                }
            }
        }

        report.familyCount = groups.count
        report.collapsedCopies = groups.reduce(0) { $0 + max(0, $1.count - 1) }
        report.itemsAfter = try store.db.scalarInt("SELECT COUNT(*) FROM items")
        report.docsAfter = try store.db.scalarInt("SELECT COUNT(*) FROM search_docs")
        try store.db.run("""
        INSERT OR REPLACE INTO meta(key,value) VALUES('lineage_built_at',?)
        """, [String(Int64(Date().timeIntervalSince1970))])
        report.duration = Date().timeIntervalSince(started)
        return report
    }

    private static func clear(_ store: Store) throws {
        try store.db.exec("DELETE FROM thread_links; DELETE FROM thread_families;")
    }
}

extension Store {
    /// 会话所属内容族的全部成员，代表排在最前。未归族返回 nil。
    func lineage(threadId: String) throws -> LineageInfo? {
        let familyIds = try db.query("SELECT family_id FROM thread_links WHERE thread_id=?",
                                     [threadId]) { $0.text(0) }
        guard let familyId = familyIds.first else { return nil }
        let members: [LineageMember] = try db.query("""
        SELECT l.thread_id, t.title, t.source_id, t.native_id, l.role, l.relation,
               l.direction, l.target_ref, t.created_at, t.item_count
        FROM thread_links l JOIN threads t ON t.id=l.thread_id
        WHERE l.family_id=?
        ORDER BY (l.role='original') DESC, t.created_at ASC
        """, [familyId]) { st in
            LineageMember(id: st.text(0), title: st.text(1),
                          sourceKind: SourceKind(rawValue: st.text(2)) ?? .codex,
                          nativeId: st.text(3), role: st.text(4), relation: st.text(5),
                          direction: st.text(6), targetRef: st.text(7),
                          createdAt: st.int64(8), itemCount: st.int(9))
        }
        guard !members.isEmpty else { return nil }
        return LineageInfo(familyId: familyId, members: members)
    }

    /// 会话在内容族里的代表；未归族时返回自己。
    func representativeThreadId(of threadId: String) throws -> String {
        try db.query("""
        SELECT f.representative_thread_id FROM thread_links l
        JOIN thread_families f ON f.id=l.family_id WHERE l.thread_id=?
        """, [threadId]) { $0.text(0) }.first ?? threadId
    }
}
