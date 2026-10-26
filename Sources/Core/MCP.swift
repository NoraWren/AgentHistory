import Foundation

/// MCP 常驻在客户端的进程里，库里的数据得跟着变，否则 agent 检索到的是上次手动同步的旧快照。
/// 策略：服务启动时补一次增量，之后每次工具调用前看水位，过期就再补。
/// 增量同步实测 1.2 秒，代价可以接受；`AGENT_HISTORY_MCP_SYNC=0` 可以关掉自动补。
private let mcpStaleAfter: TimeInterval = 300

private func mcpSyncEnabled() -> Bool {
    ProcessInfo.processInfo.environment["AGENT_HISTORY_MCP_SYNC"] != "0"
}

/// 补同步的判定单独抽出来，好让它能被测到：哪些来源该补，只看它自己的水位。
enum MCPSyncPolicy {
    /// 一个来源同步失败后先晾十分钟，别每次工具调用都去撞同一个打不开的目录。
    static let retryBackoff: TimeInterval = 600

    static func staleKinds(_ sources: [SourceInfo], now: TimeInterval,
                           threshold: TimeInterval = mcpStaleAfter) -> [SourceKind] {
        sources.filter { $0.available }
            .filter { isStale($0, now: now, threshold: threshold) }
            .map(\.kind)
    }

    static func isStale(_ source: SourceInfo, now: TimeInterval,
                        threshold: TimeInterval = mcpStaleAfter) -> Bool {
        now - TimeInterval(source.lastSyncAt) >= threshold
    }

    /// 距离上次同步过去多久，菜单栏和工具提示里用得上；从没同步过返回 nil。
    static func age(_ source: SourceInfo, now: TimeInterval) -> TimeInterval? {
        guard source.lastSyncAt > 0 else { return nil }
        return max(0, now - TimeInterval(source.lastSyncAt))
    }
}

/// 某来源上次补同步失败的时间。记在库里而不是进程内，几个 MCP 进程共享同一份冷却。
private func lastFailureAt(store: Store, kind: SourceKind) -> TimeInterval? {
    let rows = try? store.db.query("SELECT value FROM meta WHERE key=?",
                                   ["mcp_fail_\(kind.rawValue)"]) { $0.text(0) }
    guard let raw = rows?.first, let seconds = Double(raw) else { return nil }
    return seconds
}

private func recentlyFailed(store: Store, kind: SourceKind, now: TimeInterval) -> Bool {
    guard let failedAt = lastFailureAt(store: store, kind: kind) else { return false }
    return now - failedAt < MCPSyncPolicy.retryBackoff
}

/// 同步摘要里只有「来源显示名：原因」，按名字倒查来源后再落库。
private func recordFailure(store: Store, message: String) {
    guard let kind = SourceKind.allCases.first(where: { message.hasPrefix($0.displayName + "：") })
    else { return }
    _ = try? store.db.run("INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)",
                          ["mcp_fail_\(kind.rawValue)", String(Int(Date().timeIntervalSince1970))])
}

/// 按来源水位判断是否要补数据。用库里的水位而不是进程内时间戳，
/// 这样同一台机器上多个 MCP 进程不会各扫一遍。
@discardableResult
private func syncIfStale(store: Store, force: Bool = false) -> Bool {
    guard mcpSyncEnabled() else { return false }
    guard let sources = try? store.sources() else { return false }
    let available = sources.filter { $0.available }
    guard !available.isEmpty else { return false }
    let now = Date().timeIntervalSince1970
    // 每个来源各看各的水位：Claude 刚同步过，不代表 Codex 的增量也新鲜。
    // 早先取所有来源里最新的一次同步，只要有一个刚同步过，其余再旧也不会补。
    var kinds = force ? available.map(\.kind) : MCPSyncPolicy.staleKinds(available, now: now)
    kinds = kinds.filter { !recentlyFailed(store: store, kind: $0, now: now) }
    guard !kinds.isEmpty else { return false }
    do {
        // 同步引擎自己会抢跨进程锁：同一台机器上常有多个客户端各起一个 MCP，
        // 别人正在写就直接跳过，不用在这里再判一次。
        let summary = try SyncEngine(store: store).sync(kinds: kinds) { _, _ in }
        guard !summary.skipped else { return false }
        for line in summary.errors { recordFailure(store: store, message: line) }
        FileHandle.standardError.write(Data("agent-history mcp 已补同步\n".utf8))
        return true
    } catch {
        FileHandle.standardError.write(Data("agent-history mcp 同步失败：\(error)\n".utf8))
        return false
    }
}

func runMCP() {
    let store: Store
    do { store = try Store() }
    catch {
        FileHandle.standardError.write(Data("无法打开历史库：\(error)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("agent-history mcp 已启动\n".utf8))
    syncIfStale(store: store)
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        let method = request["method"] as? String ?? ""
        let id = request["id"]
        if id == nil { continue }  // 通知不需要回复
        let result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": "2024-11-05",
                      "capabilities": ["tools": [:] ],
                      "serverInfo": ["name": "agent-history", "version": "0.1.0"]]
        case "tools/list":
            result = ["tools": toolDefinitions]
        case "tools/call":
            // 真正取数据前顺手补齐，别让 agent 读到过期的索引。
            syncIfStale(store: store)
            let params = request["params"] as? [String: Any] ?? [:]
            result = callTool(store: store, name: params["name"] as? String ?? "",
                              arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            respond(id: id, result: nil, error: ["code": -32601, "message": "未知方法 \(method)"])
            continue
        }
        respond(id: id, result: result, error: nil)
    }
    // stdin 关了说明客户端已经走人，跟着退出，不然会攒一堆僵尸各占一份库连接。
    FileHandle.standardError.write(Data("agent-history mcp 客户端已断开，退出\n".utf8))
    exit(0)
}

private func respond(id: Any?, result: [String: Any]?, error: [String: Any]?) {
    var payload: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull()]
    if let result { payload["result"] = result }
    if let error { payload["error"] = error }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
    fflush(stdout)
}

private let toolDefinitions: [[String: Any]] = [
    ["name": "search_threads",
     "description": "按内容族聚合检索会话：同一族的多份副本只返回代表会话，带族内命中数、副本数与命中类型",
     "inputSchema": ["type": "object", "properties": [
        "query": ["type": "string", "description": "关键词，支持中文片段"],
        "source": ["type": "string", "enum": ["codex", "claude", "workbuddy", "opencode", "kimi", "deepseek"], "description": "按来源筛选"],
        "project": ["type": "string", "description": "按项目路径筛选"],
        "days": ["type": "integer", "description": "只看最近 N 天"],
        "only_user": ["type": "boolean", "description": "只看用户提问"],
        "merge_copies": ["type": "boolean", "default": true, "description": "是否合并族内副本"],
        "limit": ["type": "integer", "default": 20]],
        "required": ["query"]]],
    ["name": "get_thread_context",
     "description": "按会话 ID 取回可用于接续的上下文。默认取结尾（接续时最需要的是最后几轮），scope=head 取开头，scope=all 从头顺下来",
     "inputSchema": ["type": "object", "properties": [
        "thread_id": ["type": "string"],
        "max_chars": ["type": "integer", "default": 12000],
        "scope": ["type": "string", "enum": ["tail", "head", "all"], "default": "tail"]],
        "required": ["thread_id"]]],
    ["name": "list_projects",
     "description": "列出本机历史里出现过的项目及其会话数。项目多时先用 query 过滤，再按 offset 翻页",
     "inputSchema": ["type": "object", "properties": [
        "query": ["type": "string", "description": "按项目名或路径筛选"],
        "limit": ["type": "integer", "default": 50],
        "offset": ["type": "integer", "default": 0]]]],
    ["name": "list_sources",
     "description": "列出各来源是否可用、上次同步过去多久、有多少会话，用来判断检索结果是否新鲜",
     "inputSchema": ["type": "object", "properties": [:]]],
    ["name": "stats",
     "description": "库的规模：会话数、条目数、项目数、今天新增、库文件大小。查之前先看一眼，好决定要不要加时间范围、limit 给多少",
     "inputSchema": ["type": "object", "properties": [:]]],
    ["name": "append_handoff",
     "description": "写入一份交接包，供另一个客户端接手",
     "inputSchema": ["type": "object", "properties": [
        "thread_id": ["type": "string"],
        "title": ["type": "string"],
        "summary": ["type": "string"],
        "todos": ["type": "string"],
        "target": ["type": "string"]],
        "required": ["title", "summary"]]],
]

private func callTool(store: Store, name: String, arguments: [String: Any]) -> [String: Any] {
    switch name {
    case "search_threads":
        let query = arguments["query"] as? String ?? ""
        // 空查询会一路走到 FTS 再安静返回「没有命中」，看起来像库里什么也没有。
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return textResult("query 不能为空", isError: true)
        }
        // 参数写错要当场说，不能悄悄退回默认值：客户端写 source=codex-cli、
        // days=0，结果照样有，但筛没筛、筛了几天全对不上，比直接报错更难查。
        var notes: [String] = []
        if let raw = arguments["source"] as? String, !raw.isEmpty,
           SourceKind(rawValue: raw) == nil {
            let allowed = SourceKind.allCases.map(\.rawValue).joined(separator: " / ")
            return textResult("source 只认这些值：\(allowed)", isError: true)
        }
        if let raw = arguments["limit"], !(raw is NSNull) {
            guard let n = raw as? Int else {
                return textResult("limit 要写成整数", isError: true)
            }
            if n < 1 || n > 200 {
                notes.append("limit \(n) 超出 1..200，按 \(min(max(n, 1), 200)) 算")
            }
        }
        // 客户端传 0、负数、或者一个很大的数都很常见。这里夹住，别让一次错参数
        // 要么直接把进程崩掉（负数进 prefix），要么把几十万字塞进对方的上下文。
        let limit = min(max(arguments["limit"] as? Int ?? 20, 1), 200)
        let source = (arguments["source"] as? String).flatMap { SourceKind(rawValue: $0) }
        var options = SearchOptions()
        options.sourceKind = source
        options.projectPath = arguments["project"] as? String
        options.limit = limit
        options.onlyUser = arguments["only_user"] as? Bool ?? false
        options.mergeCopies = arguments["merge_copies"] as? Bool ?? true
        if let raw = arguments["days"], !(raw is NSNull) {
            guard let days = raw as? Int else {
                return textResult("days 要写成整数", isError: true)
            }
            // 早先 days 是 0 或负数时直接跳过这里，等于没加条件，却让人以为筛过了。
            guard days > 0 else {
                return textResult("days 要是正整数，收到 \(days)；不想按时间筛就别传这个参数", isError: true)
            }
            // 库里的 created_at 是毫秒，早先这里按秒算，减出来的值永远小于任何时间戳，
            // 「只看最近 N 天」等于没加条件。统一换算成毫秒。
            options.since = Int64((Date().timeIntervalSince1970 - Double(days) * 86400) * 1000)
        }
        do {
            let hits = try store.search(query, options: options)
            // 条数夹在 200 以内还不够：一条摘要三百来字，200 条能到六万多字，
            // 对方的上下文一次就被检索结果塞满。这里按总字数封顶，超出的只报个数。
            let outputBudget = 16_000
            var lines: [String] = []
            var used = 0
            for h in hits {
                let line = "[\(h.sourceKind.displayName)] \(h.threadTitle)（\(h.matchKind)命中，族内\(h.groupHits)处\(h.copyCount > 0 ? "，另有\(h.copyCount)处副本" : "")）\n\(h.text.replacingOccurrences(of: "\n", with: " ").prefix(200))\nthread_id=\(h.threadId)"
                if used + line.count > outputBudget, !lines.isEmpty { break }
                lines.append(line)
                used += line.count
            }
            guard !lines.isEmpty else { return textResult("没有命中") }
            var header = "\(hits.count) 个会话命中"
            if lines.count < hits.count {
                header += "，只列了前 \(lines.count) 条（字数上限），要更多请加 limit 或缩小范围"
            }
            if !notes.isEmpty { header += "\n" + notes.joined(separator: "；") }
            return textResult(header + "\n\n" + lines.joined(separator: "\n\n"))
        } catch { return textResult("检索失败：\(error)", isError: true) }

    case "get_thread_context":
        guard let threadId = arguments["thread_id"] as? String else { return textResult("缺少 thread_id", isError: true) }
        // 上限压到八万字：整条大会话有二十五万字单条记录，真按传进来的数给，
        // 对方模型的上下文一次就被这条塞满。下限兜住 500，别给个空壳回去。
        let maxChars = min(max(arguments["max_chars"] as? Int ?? 12000, 500), 80_000)
        let scope = (arguments["scope"] as? String ?? "tail").lowercased()
        do {
            guard let thread = try store.thread(id: threadId) else { return textResult("找不到会话", isError: true) }
            let header = "# \(thread.title)\n项目：\(thread.projectPath)\n来源：\(thread.sourceKind.displayName)\n\n"
            // 接续要的是最后几轮，早先不管 scope 都从头截，长会话给回来的全是开头。
            let budget = max(500, maxChars - header.count)
            var body = ""
            switch scope {
            case "head", "all":
                let items = try store.items(threadId: threadId, limit: 5000)
                for item in items {
                    body += contextLine(item)
                    if body.count >= budget { break }
                }
                if body.count > budget {
                    body = String(body.prefix(budget)) + "\n…（后面还有 \(items.count) 条，超出字数上限）\n"
                }
            default:
                // 从库里倒着取，长会话也能真的拿到结尾，不再被 5000 条上限卡在开头。
                let items = try store.itemsTail(threadId: threadId, limit: 3000)
                // 从最后一条往前攒，攒满为止，再翻回时间顺序。
                // 工具输出单独限一个额度：会话结尾常常连着十几条命令回显，
                // 不设限的话预算全被它们吃掉，接续最需要的最后一问一答反而没进来。
                let toolBudget = Int(Double(budget) * 0.35)
                var picked: [String] = []
                var used = 0
                var toolUsed = 0
                for item in items.reversed() {
                    var line = contextLine(item)
                    if isToolItem(item) {
                        let toolRoom = toolBudget - toolUsed
                        // 工具输出超额度就截到还能放下的长度，别整条丢掉——
                        // 丢掉的话结尾连着几条命令回显时，一条都进不来。
                        if toolRoom < 120 { continue }
                        if line.count > toolRoom {
                            line = String(line.prefix(toolRoom - 20)) + "…（工具输出已截断）\n\n"
                        }
                        toolUsed += line.count
                    }
                    if used + line.count > budget {
                        // 最后一条如果是几万字的正文，直接 break 会让整个上下文只剩一个省略号。
                        // 留一段截断的正文，比给一串空行有用。
                        if picked.isEmpty {
                            let room = budget - used
                            if room > 200 {
                                line = String(line.prefix(room - 20)) + "…（超出字数上限，已截断）\n\n"
                                picked.append(line)
                                used += line.count
                            }
                        }
                        break
                    }
                    picked.append(line)
                    used += line.count
                }
                // 全是超长工具输出这种极端情况，至少给回最后一条的开头。
                if picked.isEmpty, let last = items.last, budget > 300 {
                    let head = String(contextLine(last).prefix(budget - 60))
                    picked.append(head + "…（只留了最后一条的开头）\n\n")
                }
                if picked.count < items.count {
                    body = "…（前面还有 \(items.count - picked.count) 条，只给了结尾）\n"
                }
                body += picked.reversed().joined()
            }
            return textResult(header + body)
        } catch { return textResult("读取失败：\(error)", isError: true) }

    case "list_sources":
        do {
            let now = Date().timeIntervalSince1970
            let sources = try store.sources()
            guard !sources.isEmpty else { return textResult("还没有配置任何来源") }
            let lines = sources.map { src -> String in
                var parts = [src.kind.displayName, src.available ? "可用" : "不可用",
                             "\(src.threadCount) 个会话"]
                if let age = MCPSyncPolicy.age(src, now: now) {
                    parts.append("上次同步 \(ageLabel(age))前")
                    if MCPSyncPolicy.isStale(src, now: now) { parts.append("已过期") }
                } else {
                    parts.append("还没同步过")
                }
                if let err = src.lastError, !err.isEmpty { parts.append("错误：\(err)") }
                return parts.joined(separator: " · ")
            }
            return textResult(lines.joined(separator: "\n"))
        } catch { return textResult("读取失败：\(error)", isError: true) }

    case "stats":
        do {
            let s = try store.stats()
            let mb = Double(store.dbSizeBytes()) / 1024.0 / 1024.0
            let lines = [
                "会话 \(s.threadCount) · 条目 \(s.itemCount) · 项目 \(s.projectCount)",
                "今天新增 \(s.todayItems) 条 · 库文件 \(String(format: "%.0f", mb)) MB",
            ]
            return textResult(lines.joined(separator: "\n"))
        } catch { return textResult("读取失败：\(error)", isError: true) }

    case "list_projects":
        do {
            let all = try store.projects()
            return listProjectsResult(all: all, arguments: arguments)
        } catch { return textResult("读取失败：\(error)", isError: true) }

    case "append_handoff":
        let threadId = arguments["thread_id"] as? String ?? ""
        let title = arguments["title"] as? String ?? "交接"
        let summary = arguments["summary"] as? String ?? ""
        let todos = arguments["todos"] as? String ?? ""
        let target = arguments["target"] as? String ?? ""
        let id = UUID().uuidString
        do {
            try store.db.run("""
            INSERT INTO handoffs(id,thread_id,target,created_at,title,summary,decisions,todos,files,status,payload)
            VALUES(?,?,?,?,?,?,?,?,?, 'draft', '')
            """, [id, threadId, target, Int64(Date().timeIntervalSince1970), title, summary, "", todos, ""])
            var md = "# \(title)\n\n\(summary)\n\n## 待办\n\n\(todos)\n"
            if !threadId.isEmpty, let t = try store.thread(id: threadId) {
                md += "\n## 来源\n\n\(t.sourceKind.displayName) · \(t.projectPath)\n"
            }
            let file = store.root + "/handoffs/\(id).md"
            try md.write(toFile: file, atomically: true, encoding: .utf8)
            return textResult("已写入交接包 \(id)\n\(file)")
        } catch { return textResult("写入失败：\(error)", isError: true) }

    default:
        return textResult("未知工具 \(name)", isError: true)
    }
}

/// 项目列表按字数封顶。本机 281 个项目、两万六千字，一次全塞回去比一次检索还占上下文。
/// 单独拎出来是为了能直接测：翻页、过滤、越界都不经过 MCP 的 stdio。
func listProjectsResult(all: [ProjectRow], arguments: [String: Any]) -> [String: Any] {
    // 本机 281 个项目、两万六千字，一次全塞回去比一次检索还占上下文。
    // 按字数封顶，再给 query 和 offset 让人自己翻。
    let filter = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let matched = filter.isEmpty ? all : all.filter {
        $0.name.localizedCaseInsensitiveContains(filter)
            || $0.path.localizedCaseInsensitiveContains(filter)
    }
    if let raw = arguments["limit"], !(raw is NSNull), !(raw is Int) {
        return textResult("limit 要写成整数", isError: true)
    }
    if let raw = arguments["offset"], !(raw is NSNull), !(raw is Int) {
        return textResult("offset 要写成整数", isError: true)
    }
    var notes: [String] = []
    let asked = arguments["limit"] as? Int ?? 50
    if asked < 1 || asked > 500 {
        notes.append("limit \(asked) 超出 1..500，按 \(min(max(asked, 1), 500)) 算")
    }
    let limit = min(max(asked, 1), 500)
    let offset = max(0, arguments["offset"] as? Int ?? 0)
    guard offset < matched.count else {
        return textResult("offset \(offset) 越界，一共 \(matched.count) 个项目", isError: true)
    }
    let outputBudget = 16_000
    var lines: [String] = []
    var used = 0
    for p in matched.dropFirst(offset).prefix(limit) {
        let line = "\(p.name)  \(p.threadCount) 个会话  \(p.path)"
        if used + line.count > outputBudget, !lines.isEmpty { break }
        lines.append(line)
        used += line.count + 1
    }
    guard !lines.isEmpty else { return textResult("没有匹配的项目") }
    var header = filter.isEmpty
        ? "\(matched.count) 个项目"
        : "\(matched.count) 个项目匹配 \(filter)"
    if all.count != matched.count { header += "（库里共 \(all.count) 个）" }
    let shown = offset + lines.count
    if shown < matched.count {
        header += "，只列了第 \(offset + 1) 到 \(shown) 个，接着看用 offset=\(shown)"
    }
    if !notes.isEmpty { header += "\n" + notes.joined(separator: "；") }
    return textResult(header + "\n\n" + lines.joined(separator: "\n"))
}

/// 会话正文里的一行。工具输出常常几千字，整段塞进上下文会把预算吃光，
/// 这里只留一行开头，接续时看得到「跑过什么」就够了。
private func isToolItem(_ item: ItemRow) -> Bool {
    switch item.itemType {
    case "commandExecution", "toolResult", "mcpToolCall", "fileChange", "reasoning":
        return true
    default:
        return item.role != "user" && item.role != "assistant"
    }
}

private func contextLine(_ item: ItemRow) -> String {
    let who = item.role == "user" ? "用户"
        : (item.role == "assistant" ? "助手" : (item.itemType.isEmpty ? item.role : item.itemType))
    var text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if isToolItem(item) {
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 200 { text = String(text.prefix(200)) + "…" }
    }
    return "[\(who)] \(text)\n\n"
}

/// 「3 分钟」「2 小时」「5 天」，给 list_sources 用。
private func ageLabel(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "\(Int(seconds)) 秒" }
    if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
    if seconds < 86400 { return "\(Int(seconds / 3600)) 小时" }
    return "\(Int(seconds / 86400)) 天"
}

private func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { result["isError"] = true }
    return result
}
