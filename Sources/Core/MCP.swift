import Foundation

func runMCP() {
    let store: Store
    do { store = try Store() }
    catch {
        FileHandle.standardError.write(Data("无法打开历史库：\(error)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("agent-history mcp 已启动\n".utf8))
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
            let params = request["params"] as? [String: Any] ?? [:]
            result = callTool(store: store, name: params["name"] as? String ?? "",
                              arguments: params["arguments"] as? [String: Any] ?? [:])
        default:
            respond(id: id, result: nil, error: ["code": -32601, "message": "未知方法 \(method)"])
            continue
        }
        respond(id: id, result: result, error: nil)
    }
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
     "description": "在本地所有 Agent 客户端的历史中检索，返回命中的会话与片段",
     "inputSchema": ["type": "object", "properties": [
        "query": ["type": "string", "description": "关键词，支持中文片段"],
        "source": ["type": "string", "enum": ["codex", "claude", "workbuddy", "opencode", "kimi", "deepseek"]],
        "limit": ["type": "integer", "default": 20]],
        "required": ["query"]]],
    ["name": "get_thread_context",
     "description": "按会话 ID 取回可用于接续的上下文",
     "inputSchema": ["type": "object", "properties": [
        "thread_id": ["type": "string"],
        "max_chars": ["type": "integer", "default": 12000]],
        "required": ["thread_id"]]],
    ["name": "list_projects",
     "description": "列出本机历史里出现过的项目及其会话数",
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
        let limit = arguments["limit"] as? Int ?? 20
        let source = (arguments["source"] as? String).flatMap { SourceKind(rawValue: $0) }
        do {
            let hits = try store.search(query, sourceKind: source, limit: limit)
            let lines = hits.map { h in
                "[\(h.sourceKind.displayName)] \(h.threadTitle)\n\(h.text.replacingOccurrences(of: "\n", with: " ").prefix(200))\nthread_id=\(h.threadId)"
            }
            return textResult(lines.isEmpty ? "没有命中" : lines.joined(separator: "\n\n"))
        } catch { return textResult("检索失败：\(error)", isError: true) }

    case "get_thread_context":
        guard let threadId = arguments["thread_id"] as? String else { return textResult("缺少 thread_id", isError: true) }
        let maxChars = arguments["max_chars"] as? Int ?? 12000
        do {
            guard let thread = try store.thread(id: threadId) else { return textResult("找不到会话", isError: true) }
            var out = "# \(thread.title)\n项目：\(thread.projectPath)\n来源：\(thread.sourceKind.displayName)\n\n"
            for item in try store.items(threadId: threadId, limit: 5000) {
                let who = item.role == "user" ? "用户" : (item.role == "assistant" ? "助手" : item.itemType)
                out += "[\(who)] \(item.text)\n\n"
                if out.count >= maxChars { break }
            }
            return textResult(String(out.prefix(maxChars)))
        } catch { return textResult("读取失败：\(error)", isError: true) }

    case "list_projects":
        do {
            let projects = try store.projects()
            let lines = projects.map { "\($0.name)  \($0.threadCount) 个会话  \($0.path)" }
            return textResult(lines.joined(separator: "\n"))
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

private func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { result["isError"] = true }
    return result
}
