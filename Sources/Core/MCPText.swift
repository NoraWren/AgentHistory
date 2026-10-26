import Foundation

/// MCP 结果里的文本拼装。单独一个文件，是因为 MCP.swift 已经四百多行，
/// 再加几段字符串拼接会把工具定义和执行分支冲散。

/// 会话条目的结果行。形状与改动前一致，既有客户端按 thread_id= 取会话的做法不能变。
func threadLine(_ h: SearchHit) -> String {
    let family = h.copyCount > 0 ? "，另有\(h.copyCount)处副本" : ""
    let snippet = h.text.replacingOccurrences(of: "\n", with: " ").prefix(200)
    return "[\(h.sourceKind.displayName)] \(h.threadTitle)（\(h.matchKind)命中，族内\(h.groupHits)处\(family)）\n\(snippet)\nthread_id=\(h.threadId)"
}

/// 记忆类命中没有来源客户端与族的概念，行里给出类别、标题与记忆标识，
/// 结尾写 memory_id，方便调用方接着用 get_handoff 或 recall 取全文。
func memoryLine(_ h: SearchHit) -> String? {
    guard let kind = h.memoryKind else { return nil }
    let snippet = h.text.replacingOccurrences(of: "\n", with: " ").prefix(200)
    var line = "[\(kind.displayName)] \(h.threadTitle)（\(h.matchKind)命中）\n\(snippet)\nmemory_id=\(h.memoryId ?? "")"
    if !h.threadId.isEmpty { line += "  thread_id=\(h.threadId)" }
    return line
}

/// recall 结果里的一条。正文截 240 字：够判断记的是什么，又不至于一次十条把上下文塞满。
func docBlock(_ d: MemoryDoc) -> String {
    var head = "[\(d.kind.displayName)] \(d.title)"
    if !d.category.isEmpty { head += "（\(d.category)）" }
    if !d.statusLabel.isEmpty { head += "（\(d.statusLabel)）" }
    head += "  \(stamp(d.createdAt))"
    var tail = "\nmemory_id=\(d.id)"
    if !d.threadId.isEmpty { tail += "  thread_id=\(d.threadId)" }
    if d.itemOrdinal >= 0 { tail += "  item_ordinal=\(d.itemOrdinal)" }
    // 无出处的结论照样返回，但必须说清楚，别让人以为它是从某段对话里抽出来的。
    if d.threadId.isEmpty, d.kind == .fact { tail += "  无出处" }
    let body = d.body.replacingOccurrences(of: "\n", with: " ").prefix(240)
    return head + "\n" + body + tail
}

/// 记忆条目上的时间戳，精确到分钟足够判断新旧。
func stamp(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

