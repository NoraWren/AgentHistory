import Foundation

protocol HistoryAdapter {
    var kind: SourceKind { get }
    var isAvailable: Bool { get }
    var unavailableReason: String? { get }
    func sync(into store: Store, progress: (SyncPhase) -> Void) throws -> Int
}

enum AdapterFactory {
    static func all() -> [HistoryAdapter] {
        [CodexAdapter(), ClaudeAdapter(), WorkBuddyAdapter(), OpenCodeAdapter(), KimiAdapter(), DeepSeekAdapter()]
    }
}

private func jsonObject(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func jsonString(_ value: Any?) -> String {
    guard let value else { return "" }
    if let s = value as? String { return s }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value),
       let s = String(data: data, encoding: .utf8) {
        return s
    }
    return String(describing: value)
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func parseISO(_ s: String) -> Int64 {
    if let d = isoFormatter.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return Int64(d.timeIntervalSince1970 * 1000) }
    return 0
}

private func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n)) + "…"
}

private func firstLine(_ s: String, _ n: Int = 80) -> String {
    let line = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    return clip(line.trimmingCharacters(in: .whitespacesAndNewlines), n)
}

// MARK: - Codex

final class CodexAdapter: HistoryAdapter {
    let kind: SourceKind = .codex
    /// 允许用 AGENT_HISTORY_CODEX_HOME 指向别的 Codex 目录，方便验收和排查。
    private let home = ProcessInfo.processInfo.environment["AGENT_HISTORY_CODEX_HOME"]
        ?? NSHomeDirectory() + "/.codex"
    private var statePath: String?
    private var historyPath: String?

    init() {
        statePath = Self.latestFile(prefix: "state_", suffix: ".sqlite", in: home)
        historyPath = Self.latestFile(prefix: "thread_history_", suffix: ".sqlite", in: home)
    }

    private static func latestFile(prefix: String, suffix: String, in dir: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let candidates = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }.compactMap { name -> (Int, String)? in
            let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard let n = Int(middle) else { return nil }
            return (n, dir + "/" + name)
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    var isAvailable: Bool { statePath != nil && historyPath != nil }
    var unavailableReason: String? {
        isAvailable ? nil : "未找到 state_*.sqlite 或 thread_history_*.sqlite"
    }

    private struct ThreadMeta {
        let id: String
        let title: String
        let cwd: String
        let createdAt: Int64
        let updatedAt: Int64
        let model: String
        let threadSource: String
        let archived: Bool
    }

    func sync(into store: Store, progress: (SyncPhase) -> Void) throws -> Int {
        guard let statePath, let historyPath else { throw HistoryError.message("Codex 数据目录不完整") }
        let state = try Database(path: "file:\(statePath)?mode=ro", readOnly: true)
        let history = try Database(path: "file:\(historyPath)?mode=ro", readOnly: true)

        let metas = try state.query("""
        SELECT id,COALESCE(NULLIF(title,''),first_user_message),cwd,created_at,updated_at,
               COALESCE(model,''),COALESCE(thread_source,source),archived
        FROM threads ORDER BY updated_at ASC
        """) { st -> ThreadMeta in
            ThreadMeta(id: st.text(0), title: st.text(1), cwd: st.text(2),
                       createdAt: st.int64(3), updatedAt: st.int64(4), model: st.text(5),
                       threadSource: st.text(6), archived: st.int(7) == 1)
        }

        var totalNew = 0
        for (index, meta) in metas.enumerated() {
            let watermark = try store.watermark(sourceId: kind.rawValue, threadId: meta.id)
            let after = Int64(watermark ?? "0") ?? 0
            let rows = try history.query("""
            SELECT item_id,rollout_ordinal,item_type,created_at_ms,item_json,updated_at_ordinal,turn_id
            FROM thread_items WHERE thread_id=? AND updated_at_ordinal>?
            ORDER BY rollout_ordinal
            """, [meta.id, after]) { st in
                (st.text(0), st.int(1), st.text(2), st.int64(3), st.text(4), st.int64(5), st.text(6))
            }
            if rows.isEmpty {
                if index % 50 == 0 {
                    progress(SyncPhase(name: "读取 Codex", completed: index, total: metas.count))
                }
                continue
            }

            var inputs: [ItemInput] = []
            var maxOrdinal = after
            var preview = ""
            for (nativeId, ordinal, type, created, raw, updatedOrdinal, nativeTurn) in rows {
                maxOrdinal = max(maxOrdinal, updatedOrdinal, Int64(ordinal))
                guard let text = Self.extractText(type: type, raw: raw) else { continue }
                if preview.isEmpty && (type == "userMessage" || type == "agentMessage") {
                    preview = firstLine(text, 160)
                }
                inputs.append(ItemInput(nativeId: nativeId, ordinal: ordinal, itemType: type,
                                        role: Self.role(for: type), createdAt: created,
                                        text: text, rawJSON: clip(raw, 4000), truncated: raw.count > 4000,
                                        turnId: nativeTurn.isEmpty ? nil : nativeTurn))
            }
            let threadId = try store.upsertThread(ThreadInput(
                sourceId: kind.rawValue, nativeId: meta.id, projectPath: meta.cwd,
                title: firstLine(meta.title, 120), createdAt: meta.createdAt * 1000, updatedAt: meta.updatedAt * 1000,
                model: meta.model, threadSource: meta.threadSource, archived: meta.archived,
                preview: preview))
            if !inputs.isEmpty {
                let result = try store.upsertItems(threadId: threadId, items: inputs)
                totalNew += result.inserted
            }
            try store.setWatermark(sourceId: kind.rawValue, threadId: meta.id, watermark: String(maxOrdinal))
            if index % 20 == 0 || index == metas.count - 1 {
                progress(SyncPhase(name: "读取 Codex", completed: index + 1, total: metas.count))
            }
        }
        return totalNew
    }

    static func role(for type: String) -> String {
        switch type {
        case "userMessage": return "user"
        case "agentMessage": return "assistant"
        case "reasoning": return "reasoning"
        case "commandExecution": return "tool"
        case "plan": return "plan"
        default: return "system"
        }
    }

    static func extractText(type: String, raw: String) -> String? {
        guard let obj = jsonObject(raw) else { return clip(raw, 1000) }
        switch type {
        case "userMessage":
            let parts = (obj["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        case "agentMessage":
            return obj["text"] as? String
        case "reasoning":
            let summary = (obj["summary"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let joined = summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        case "plan":
            if let text = obj["text"] as? String { return text }
            return clip(raw, 800)
        case "commandExecution":
            let command = obj["command"] as? String ?? ""
            let output = (obj["aggregatedOutput"] as? String) ?? (obj["output"] as? String) ?? ""
            let body = output.isEmpty ? command : command + "\n" + clip(output, 1200)
            return body.isEmpty ? nil : body
        case "mcpToolCall":
            let tool = obj["tool"] as? String ?? obj["server"] as? String ?? "工具调用"
            let args = jsonString(obj["arguments"])
            return tool + " " + clip(args, 400)
        case "fileChange":
            let files = (obj["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return files.isEmpty ? nil : "修改文件：" + files.joined(separator: ", ")
        default:
            return nil
        }
    }
}

// MARK: - Claude Code

final class ClaudeAdapter: HistoryAdapter {
    let kind: SourceKind = .claude
    private let root = WriteSupport.claudeProjects

    var isAvailable: Bool { FileManager.default.fileExists(atPath: root) }
    var unavailableReason: String? { isAvailable ? nil : "未找到 \(root)" }

    func sync(into store: Store, progress: (SyncPhase) -> Void) throws -> Int {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var files: [String] = []
        for d in dirs {
            let dir = root + "/" + d
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for n in names where n.hasSuffix(".jsonl") {
                files.append(dir + "/" + n)
            }
        }
        var totalNew = 0
        for (index, file) in files.enumerated() {
            defer { progress(SyncPhase(name: "读取 Claude Code", completed: index + 1, total: files.count)) }
            let sessionId = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            let watermark = Int64(try store.watermark(sourceId: kind.rawValue, threadId: sessionId) ?? "0") ?? 0
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            let start = size < watermark ? 0 : watermark
            guard let handle = FileHandle(forReadingAtPath: file) else { continue }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            guard let data = try handle.readToEnd(), !data.isEmpty else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var inputs: [ItemInput] = []
            var cwd = ""
            var title = ""
            var ordinal = 0
            var minTs = Int64.max
            var maxTs: Int64 = 0

            for line in text.split(separator: "\n") {
                guard let obj = jsonObject(String(line)) else { continue }
                let type = obj["type"] as? String ?? ""
                let ts = parseISO(obj["timestamp"] as? String ?? "")
                if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty { title = t }
                ordinal += 1
                if ts > 0 { minTs = min(minTs, ts); maxTs = max(maxTs, ts) }
                let nativeId = obj["uuid"] as? String ?? "\(sessionId)-\(start)-\(ordinal)"
                // Claude 给每条记录都打了 promptId，同一轮提问及其回复共享一个值。
                let nativeTurn = (obj["promptId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if type == "user" {
                    let msg = obj["message"] as? [String: Any] ?? [:]
                    let content = Self.flatten(msg["content"])
                    if !content.isEmpty {
                        if title.isEmpty { title = firstLine(content, 100) }
                        inputs.append(ItemInput(nativeId: nativeId, ordinal: ordinal, itemType: "userMessage",
                                                role: "user", createdAt: ts, text: content,
                                                rawJSON: clip(String(line), 3000), turnId: nativeTurn))
                    }
                } else if type == "assistant" {
                    let msg = obj["message"] as? [String: Any] ?? [:]
                    for (bi, block) in (msg["content"] as? [[String: Any]] ?? []).enumerated() {
                        let bt = block["type"] as? String ?? ""
                        guard let t = block["text"] as? String ?? block["thinking"] as? String, !t.isEmpty else { continue }
                        inputs.append(ItemInput(nativeId: "\(nativeId)-b\(bi)", ordinal: ordinal * 100 + bi,
                                                itemType: bt == "thinking" ? "reasoning" : "agentMessage",
                                                role: bt == "thinking" ? "reasoning" : "assistant",
                                                createdAt: ts, text: t, rawJSON: clip(String(line), 3000),
                                                turnId: nativeTurn))
                    }
                }
            }
            guard !inputs.isEmpty || !cwd.isEmpty else { continue }
            // 汇编时的工作目录会被 claude 记成会话，这些是工具中间产物，不当成我的对话收进来。
            if LLMRunner.isScratchPath(cwd) { continue }
            let threadId = try store.upsertThread(ThreadInput(
                sourceId: kind.rawValue, nativeId: sessionId, projectPath: cwd.isEmpty ? "/(未知)" : cwd,
                title: title.isEmpty ? "Claude 会话 \(sessionId.prefix(8))" : title,
                createdAt: minTs == .max ? 0 : minTs, updatedAt: maxTs,
                model: "", threadSource: "user", archived: false,
                preview: inputs.first(where: { $0.role == "user" }).map { firstLine($0.text, 160) } ?? ""))
            if !inputs.isEmpty {
                totalNew += try store.upsertItems(threadId: threadId, items: inputs).inserted
            }
            try store.setWatermark(sourceId: kind.rawValue, threadId: sessionId, watermark: String(size))
        }
        return totalNew
    }

    static func flatten(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { block -> String? in
                if let t = block["text"] as? String { return t }
                if let t = block["thinking"] as? String { return t }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }
}

// MARK: - WorkBuddy

final class WorkBuddyAdapter: HistoryAdapter {
    let kind: SourceKind = .workbuddy
    private let root = WriteSupport.workbuddyProjects
    /// 会话表在 projects 的同级目录，跟着 projects 的位置走，方便整体指到别的目录。
    private var dbPath: String {
        (root as NSString).deletingLastPathComponent + "/workbuddy.db"
    }

    var isAvailable: Bool { FileManager.default.fileExists(atPath: root) }
    var unavailableReason: String? { isAvailable ? nil : "未找到 \(root)" }

    func sync(into store: Store, progress: (SyncPhase) -> Void) throws -> Int {
        var titles: [String: String] = [:]
        if FileManager.default.fileExists(atPath: dbPath),
           let db = try? Database(path: "file:\(dbPath)?mode=ro", readOnly: true) {
            let rows = (try? db.query("SELECT id,COALESCE(NULLIF(custom_title,''),title) FROM sessions") { st in
                (st.text(0), st.text(1))
            }) ?? []
            for (id, t) in rows where !t.isEmpty { titles[id] = t }
        }

        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        var files: [String] = []
        for d in dirs {
            let dir = root + "/" + d
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for n in names where n.hasSuffix(".jsonl") { files.append(dir + "/" + n) }
        }

        var totalNew = 0
        for (index, file) in files.enumerated() {
            defer { progress(SyncPhase(name: "读取 WorkBuddy", completed: index + 1, total: files.count)) }
            let sessionId = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            let watermark = Int64(try store.watermark(sourceId: kind.rawValue, threadId: sessionId) ?? "0") ?? 0
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            let start = size < watermark ? 0 : watermark
            guard let handle = FileHandle(forReadingAtPath: file) else { continue }
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            guard let data = try handle.readToEnd(), !data.isEmpty else { continue }
            let text = String(decoding: data, as: UTF8.self)
            var inputs: [ItemInput] = []
            var cwd = ""
            var title = titles[sessionId] ?? ""
            var ordinal = 0
            var minTs = Int64.max
            var maxTs: Int64 = 0

            for line in text.split(separator: "\n") {
                guard let obj = jsonObject(String(line)) else { continue }
                let type = obj["type"] as? String ?? ""
                let ts = (obj["timestamp"] as? NSNumber)?.int64Value ?? 0
                if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                if type == "ai-title", let t = obj["aiTitle"] as? String, !t.isEmpty { title = t }
                ordinal += 1
                if ts > 0 { minTs = min(minTs, ts); maxTs = max(maxTs, ts) }
                let nativeId = obj["id"] as? String ?? "\(sessionId)-\(start)-\(ordinal)"
                switch type {
                case "message":
                    let role = obj["role"] as? String ?? "user"
                    let content = ClaudeAdapter.flatten(obj["content"])
                    guard !content.isEmpty else { continue }
                    inputs.append(ItemInput(nativeId: nativeId, ordinal: ordinal,
                                            itemType: role == "user" ? "userMessage" : "agentMessage",
                                            role: role, createdAt: ts, text: content,
                                            rawJSON: clip(String(line), 3000),
                                            turnId: role == "user" ? nativeId : nil))
                case "reasoning":
                    let content = (obj["rawContent"] as? [[String: Any]] ?? [])
                        .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    guard !content.isEmpty else { continue }
                    inputs.append(ItemInput(nativeId: nativeId, ordinal: ordinal, itemType: "reasoning",
                                            role: "reasoning", createdAt: ts, text: content, rawJSON: clip(String(line), 3000)))
                case "function_call":
                    let name = obj["name"] as? String ?? "工具"
                    let args = jsonString(obj["arguments"])
                    inputs.append(ItemInput(nativeId: nativeId, ordinal: ordinal, itemType: "commandExecution",
                                            role: "tool", createdAt: ts, text: name + " " + clip(args, 600),
                                            rawJSON: clip(String(line), 3000)))
                case "function_call_result":
                    let output = (obj["output"] as? [String: Any])?["text"] as? String ?? ""
                    guard !output.isEmpty else { continue }
                    inputs.append(ItemInput(nativeId: nativeId, ordinal: ordinal, itemType: "toolResult",
                                            role: "tool", createdAt: ts, text: clip(output, 1500),
                                            rawJSON: clip(String(line), 3000), truncated: output.count > 1500))
                default:
                    continue
                }
            }
            guard !inputs.isEmpty || !cwd.isEmpty else { continue }
            let threadId = try store.upsertThread(ThreadInput(
                sourceId: kind.rawValue, nativeId: sessionId, projectPath: cwd.isEmpty ? "/(未知)" : cwd,
                title: title.isEmpty ? "WorkBuddy 会话 \(sessionId.prefix(8))" : title,
                createdAt: minTs == .max ? 0 : minTs, updatedAt: maxTs,
                model: "", threadSource: "user", archived: false,
                preview: inputs.first(where: { $0.role == "user" }).map { firstLine($0.text, 160) } ?? ""))
            if !inputs.isEmpty {
                totalNew += try store.upsertItems(threadId: threadId, items: inputs).inserted
            }
            try store.setWatermark(sourceId: kind.rawValue, threadId: sessionId, watermark: String(size))
        }
        return totalNew
    }
}

// MARK: - OpenCode

final class OpenCodeAdapter: HistoryAdapter {
    let kind: SourceKind = .opencode
    /// 跟 OpenCode 自己的规则一致，认 XDG_DATA_HOME，方便把数据指到别的目录。
    private let dbPath = {
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            ?? NSHomeDirectory() + "/.local/share"
        return dataHome + "/opencode/opencode.db"
    }()

    var isAvailable: Bool { FileManager.default.fileExists(atPath: dbPath) }
    var unavailableReason: String? { isAvailable ? nil : "未找到 \(dbPath)" }

    func sync(into store: Store, progress: (SyncPhase) -> Void) throws -> Int {
        guard isAvailable else { return 0 }
        let db = try Database(path: "file:\(dbPath)?mode=ro", readOnly: true)
        let sessions = try db.query("""
        SELECT id,title,directory,COALESCE(time_created,0),COALESCE(time_updated,0)
        FROM session ORDER BY time_updated ASC
        """) { st in (st.text(0), st.text(1), st.text(2), st.int64(3), st.int64(4)) }

        var totalNew = 0
        for (index, session) in sessions.enumerated() {
            defer { progress(SyncPhase(name: "读取 OpenCode", completed: index + 1, total: sessions.count)) }
            let (sid, title, directory, created, updated) = session
            let lastUpdated = Int64(try store.watermark(sourceId: kind.rawValue, threadId: sid) ?? "0") ?? 0
            if updated <= lastUpdated && lastUpdated > 0 { continue }

            let messages = try db.query("""
            SELECT m.id, m.data, COALESCE(json_extract(m.data,'$.time.created'),0)
            FROM message m WHERE m.session_id=? ORDER BY m.time_created ASC
            """, [sid]) { st in (st.text(0), st.text(1), st.int64(2)) }
            var inputs: [ItemInput] = []
            var ordinal = 0
            for (mid, data, createdMs) in messages {
                let msg = jsonObject(data) ?? [:]
                let role = msg["role"] as? String ?? "user"
                let parts = try db.query("SELECT id,data FROM part WHERE message_id=? ORDER BY time_created ASC", [mid]) { st in
                    (st.text(0), st.text(1))
                }
                for (pid, pdata) in parts {
                    guard let p = jsonObject(pdata) else { continue }
                    let type = p["type"] as? String ?? ""
                    guard type == "text", let t = p["text"] as? String, !t.isEmpty else { continue }
                    ordinal += 1
                    inputs.append(ItemInput(nativeId: pid, ordinal: ordinal,
                                            itemType: role == "user" ? "userMessage" : "agentMessage",
                                            role: role, createdAt: createdMs, text: t,
                                            rawJSON: clip(pdata, 3000),
                                            turnId: role == "user" ? mid : nil))
                }
            }
            let threadId = try store.upsertThread(ThreadInput(
                sourceId: kind.rawValue, nativeId: sid, projectPath: directory.isEmpty ? "/(未知)" : directory,
                title: title.isEmpty ? "OpenCode 会话 \(sid.suffix(6))" : title,
                createdAt: created, updatedAt: updated, model: "", threadSource: "user", archived: false,
                preview: inputs.first(where: { $0.role == "user" }).map { firstLine($0.text, 160) } ?? ""))
            if !inputs.isEmpty { totalNew += try store.upsertItems(threadId: threadId, items: inputs).inserted }
            try store.setWatermark(sourceId: kind.rawValue, threadId: sid, watermark: String(updated))
        }
        return totalNew
    }
}

// MARK: - Kimi Code

final class KimiAdapter: HistoryAdapter {
    let kind: SourceKind = .kimi
    private let home: String
    private let sessionsRoot: String
    private var workspaces: [String: String] = [:]

    init(home: String? = nil) {
        let base = home
            ?? ProcessInfo.processInfo.environment["AGENT_HISTORY_KIMI_HOME"]
            ?? NSHomeDirectory() + "/.kimi-code"
        self.home = base
        self.sessionsRoot = base + "/sessions"
    }

    private var sessionDirectories: [String] {
        let fm = FileManager.default
        guard let wsNames = try? fm.contentsOfDirectory(atPath: sessionsRoot) else { return [] }
        var result: [String] = []
        for ws in wsNames.sorted() where !ws.hasPrefix(".") {
            let wsDir = sessionsRoot + "/" + ws
            guard let names = try? fm.contentsOfDirectory(atPath: wsDir) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let dir = wsDir + "/" + name
                if Self.statePath(in: dir) != nil { result.append(dir) }
            }
        }
        return result
    }

    static func statePath(in dir: String) -> String? {
        let direct = dir + "/state.json"
        if FileManager.default.fileExists(atPath: direct) { return direct }
        let nested = dir + "/session-meta/state.json"
        if FileManager.default.fileExists(atPath: nested) { return nested }
        return nil
    }

    var isAvailable: Bool { !sessionDirectories.isEmpty }
    var unavailableReason: String? {
        isAvailable ? nil : "未找到 Kimi Code 会话（\(sessionsRoot) 为空或不存在）"
    }

    private func loadWorkspaces() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/workspaces.json")),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let map = root["workspaces"] as? [String: Any] else { return }
        for (id, value) in map {
            guard let ws = value as? [String: Any], let path = ws["root"] as? String,
                  !path.isEmpty else { continue }
            workspaces[id] = path
        }
    }

    func sync(into store: Store, progress: (SyncPhase) -> Void) throws -> Int {
        loadWorkspaces()
        let dirs = sessionDirectories
        var totalNew = 0
        for (index, dir) in dirs.enumerated() {
            defer { progress(SyncPhase(name: "读取 Kimi Code", completed: index + 1, total: dirs.count)) }
            guard let statePath = Self.statePath(in: dir),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
                  let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }

            let sessionId = (state["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (dir as NSString).lastPathComponent
            let workspaceId = state["workspaceId"] as? String ?? ""
            let cwd = (state["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? workspaces[workspaceId] ?? ""
            let createdAt = (state["createdAt"] as? NSNumber)?.int64Value ?? 0
            let updatedAt = (state["updatedAt"] as? NSNumber)?.int64Value ?? createdAt
            let archived = (state["archived"] as? Bool) ?? false
            var title = (state["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                title = (state["lastPrompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var inputs: [ItemInput] = []
            let wire = dir + "/agents/main/wire.jsonl"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: wire),
               let size = (attrs[.size] as? NSNumber)?.int64Value {
                let stored = Int64(try store.watermark(sourceId: kind.rawValue, threadId: sessionId) ?? "0") ?? 0
                let start = size < stored ? 0 : stored
                var nextOffset = start
                var ordinal = Int(try store.db.scalarInt("""
                    SELECT COALESCE(MAX(i.ordinal),0) FROM items i
                    JOIN threads t ON t.id=i.thread_id
                    WHERE t.source_id=? AND t.native_id=?
                    """, [kind.rawValue, sessionId]))
                var lastTs = updatedAt

                if start < size, let handle = FileHandle(forReadingAtPath: wire) {
                    defer { try? handle.close() }
                    try handle.seek(toOffset: UInt64(start))
                    if let chunk = try handle.readToEnd(), !chunk.isEmpty {
                        var body = chunk
                        if chunk.last != 0x0A {
                            var cut = chunk.count
                            while cut > 0 && chunk[cut - 1] != 0x0A { cut -= 1 }
                            body = Data(chunk[0..<cut])
                            nextOffset = start + Int64(cut)
                        } else {
                            nextOffset = start + Int64(chunk.count)
                        }
                        var byteCursor = start
                        for line in body.split(separator: 0x0A) {
                            let lineOffset = byteCursor
                            byteCursor += Int64(line.count + 1)
                            let raw = String(decoding: line, as: UTF8.self)
                            guard !line.isEmpty, let obj = jsonObject(raw),
                                  obj["type"] as? String == "context.append_message",
                                  let message = obj["message"] as? [String: Any] else { continue }
                            let ts = (obj["time"] as? NSNumber)?.int64Value ?? 0
                            if ts > 0 { lastTs = ts }
                            let role = message["role"] as? String ?? ""
                            let nativeId = (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                                ?? "\(sessionId)-\(lineOffset)"
                            // Kimi 的 wire 没有轮次字段：一条用户消息开一轮，其后所有回复算这一轮。
                            let turnKey = role == "user" ? nativeId : nil
                            for item in Self.items(message: message, role: role, nativeId: nativeId,
                                                   createdAt: ts > 0 ? ts : lastTs, ordinal: &ordinal,
                                                   turnKey: turnKey) {
                                if title.isEmpty, item.role == "user" { title = firstLine(item.text, 120) }
                                inputs.append(item)
                            }
                        }
                    }
                }
                try store.setWatermark(sourceId: kind.rawValue, threadId: sessionId, watermark: String(nextOffset))
            }

            let preview = inputs.first(where: { $0.role == "user" }).map { firstLine($0.text, 160) }
                ?? (state["lastPrompt"] as? String ?? "")
            let threadId = try store.upsertThread(ThreadInput(
                sourceId: kind.rawValue, nativeId: sessionId,
                projectPath: cwd.isEmpty ? "/(未知)" : cwd,
                title: title.isEmpty ? "Kimi Code 会话 \(sessionId.prefix(8))" : firstLine(title, 120),
                createdAt: createdAt, updatedAt: updatedAt,
                model: "", threadSource: "user", archived: archived, preview: preview))
            if !inputs.isEmpty {
                totalNew += try store.upsertItems(threadId: threadId, items: inputs).inserted
            }
        }
        return totalNew
    }

    static func items(message: [String: Any], role: String, nativeId: String,
                      createdAt: Int64, ordinal: inout Int, turnKey: String? = nil) -> [ItemInput] {
        var out: [ItemInput] = []
        let textRole = role == "user" ? "user" : (role == "assistant" ? "assistant" : role)
        let textType = role == "user" ? "userMessage" : (role == "assistant" ? "agentMessage" : "systemMessage")

        func add(_ id: String, _ type: String, _ role: String, _ text: String,
                 truncated: Bool = false) {
            guard !text.isEmpty else { return }
            ordinal += 1
            out.append(ItemInput(nativeId: id, ordinal: ordinal, itemType: type, role: role,
                                 createdAt: createdAt, text: text, rawJSON: "", truncated: truncated,
                                 turnId: turnKey))
        }

        if let plain = message["content"] as? String {
            add(nativeId, textType, textRole, plain.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for (pi, part) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
            let type = part["type"] as? String ?? ""
            switch type {
            case "text":
                add("\(nativeId)-p\(pi)", textType, textRole,
                    (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            case "thinking", "reasoning":
                let thought = (part["thinking"] as? String) ?? (part["text"] as? String) ?? ""
                add("\(nativeId)-t\(pi)", "reasoning", "reasoning",
                    thought.trimmingCharacters(in: .whitespacesAndNewlines))
            case "tool_use", "server_tool_use", "mcp_tool_use":
                let name = part["name"] as? String ?? "工具调用"
                let args = clip(jsonString(part["input"] ?? part["arguments"]), 600)
                add("\(nativeId)-c\(pi)", "commandExecution", "tool", name + " " + args)
            case "tool_result":
                let content = contentText(part["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                add("\(nativeId)-r\(pi)", "toolResult", "tool", clip(content, 1500),
                    truncated: content.count > 1500)
            default:
                continue
            }
        }
        for (ci, call) in (message["toolCalls"] as? [[String: Any]] ?? []).enumerated() {
            let name = call["name"] as? String ?? "工具调用"
            let args = clip(jsonString(call["arguments"] ?? call["input"]), 600)
            add("\(nativeId)-tc\(ci)", "commandExecution", "tool", name + " " + args)
        }
        return out
    }

    private static func contentText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}

// MARK: - DeepSeek Harness

final class DeepSeekAdapter: HistoryAdapter {
    let kind: SourceKind = .deepseek
    private let roots: [String]

    init(home: String? = nil) {
        if let home {
            roots = [home]
        } else if let env = ProcessInfo.processInfo.environment["AGENT_HISTORY_DSH_HOME"] {
            roots = [env]
        } else {
            let base = NSHomeDirectory()
            let candidates = [
                base + "/Library/Application Support/dsh-desktop/harness",
                base + "/Library/Application Support/@deepseek-ai/dsh-desktop/harness",
                base + "/.dsh"
            ]
            roots = candidates.filter { FileManager.default.fileExists(atPath: $0) }
        }
    }

    static func zstdPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["AGENT_HISTORY_ZSTD"],
           FileManager.default.isExecutableFile(atPath: custom) { return custom }
        for path in ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let path = String(dir) + "/zstd"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private var sessionFiles: [String] {
        var result: [String] = []
        for root in roots {
            let sessions = root + "/sessions"
            guard let projects = try? FileManager.default.contentsOfDirectory(atPath: sessions) else { continue }
            for project in projects.sorted() where !project.hasPrefix(".") {
                let projectDir = sessions + "/" + project
                guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectDir) else { continue }
                for dir in dirs.sorted() where !dir.hasPrefix(".") {
                    for name in ["session.v4.jsonl.zstd", "session.jsonl.zstd", "session.jsonl"] {
                        let file = projectDir + "/" + dir + "/" + name
                        if FileManager.default.fileExists(atPath: file) {
                            result.append(file)
                            break
                        }
                    }
                }
            }
        }
        return result.sorted()
    }

    var isAvailable: Bool { !sessionFiles.isEmpty }
    var unavailableReason: String? {
        let files = sessionFiles
        if files.isEmpty {
            let where_ = roots.isEmpty ? "未找到 DeepSeek Harness 数据目录" : roots.joined(separator: "、")
            return "未找到 DeepSeek Harness 会话（\(where_) 下的 sessions 为空或不存在）"
        }
        if files.contains(where: { $0.hasSuffix(".zstd") }), Self.zstdPath() == nil {
            return "未找到 zstd 解压工具，无法读取会话"
        }
        return nil
    }

    private func readText(_ file: String) throws -> String {
        guard file.hasSuffix(".zstd") else {
            return try String(contentsOfFile: file, encoding: .utf8)
        }
        guard let zstd = Self.zstdPath() else {
            throw HistoryError.message("未找到 zstd 解压工具，无法读取 DeepSeek Harness 会话")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", file]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HistoryError.message("zstd 解压失败：\((file as NSString).lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func sync(into store: Store, progress: (SyncPhase) -> Void) throws -> Int {
        let files = sessionFiles
        var totalNew = 0
        for (index, file) in files.enumerated() {
            defer { progress(SyncPhase(name: "读取 DeepSeek Harness", completed: index + 1, total: files.count)) }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: file),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { continue }
            let folder = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            let stored = Int64(try store.watermark(sourceId: kind.rawValue, threadId: folder) ?? "0") ?? 0
            if stored > 0 && size == stored { continue }

            let text = try readText(file)
            var sessionId = folder
            var cwd = ""
            var title = ""
            var createdAt: Int64 = 0
            var updatedAt: Int64 = 0
            var items: [ItemInput] = []

            for line in text.split(separator: "\n") {
                guard !line.isEmpty, let obj = jsonObject(String(line)) else { continue }
                let type = obj["type"] as? String ?? ""
                let seq = (obj["seq"] as? NSNumber)?.int64Value ?? 0
                let time = (obj["time"] as? NSNumber)?.int64Value ?? 0
                if time > updatedAt { updatedAt = time }
                switch type {
                case "session":
                    if let id = obj["id"] as? String, !id.isEmpty { sessionId = id }
                    if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
                    createdAt = (obj["createdAt"] as? NSNumber)?.int64Value ?? 0
                case "session/title":
                    if let data = obj["data"] as? [String: Any],
                       let t = data["title"] as? String, !t.isEmpty { title = t }
                case "user/message":
                    guard let data = obj["data"] as? [String: Any], Self.isUserInput(data) else { continue }
                    let content = Self.contentText(data["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !content.isEmpty else { continue }
                    let nativeId = (data["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "\(sessionId)-\(seq)"
                    items.append(ItemInput(nativeId: nativeId, ordinal: Int(seq) * 100,
                                           itemType: "userMessage", role: "user",
                                           createdAt: time, text: content, rawJSON: "",
                                           turnId: Self.turnKey(sessionId, data) ?? nativeId))
                case "assistant/message":
                    guard let data = obj["data"] as? [String: Any],
                          let message = data["message"] as? [String: Any],
                          let parts = message["content"] as? [[String: Any]] else { continue }
                    let turnKey = Self.turnKey(sessionId, data)
                    for (pi, part) in parts.enumerated() {
                        let partType = part["type"] as? String ?? ""
                        let nativeId = "\(sessionId)-\(seq)-p\(pi)"
                        if partType == "text" {
                            let body = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !body.isEmpty else { continue }
                            items.append(ItemInput(nativeId: nativeId, ordinal: Int(seq) * 100 + pi,
                                                   itemType: "agentMessage", role: "assistant",
                                                   createdAt: time, text: body, rawJSON: "", turnId: turnKey))
                        } else if partType == "reasoning" || partType == "think" {
                            let body = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !body.isEmpty else { continue }
                            items.append(ItemInput(nativeId: nativeId, ordinal: Int(seq) * 100 + pi,
                                                   itemType: "reasoning", role: "reasoning",
                                                   createdAt: time, text: body, rawJSON: "", turnId: turnKey))
                        } else if partType == "tool-call" {
                            let name = part["name"] as? String ?? "工具调用"
                            let args = clip(jsonString(part["arguments"]), 600)
                            items.append(ItemInput(nativeId: nativeId, ordinal: Int(seq) * 100 + pi,
                                                   itemType: "commandExecution", role: "tool",
                                                   createdAt: time, text: name + " " + args, rawJSON: "",
                                                   turnId: turnKey))
                        }
                    }
                case "tool/result":
                    guard let data = obj["data"] as? [String: Any],
                          let message = data["message"] as? [String: Any],
                          let blocks = message["content"] as? [[String: Any]] else { continue }
                    let body = blocks.compactMap { Self.contentText($0["content"]) }
                        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !body.isEmpty else { continue }
                    items.append(ItemInput(nativeId: "\(sessionId)-\(seq)-r", ordinal: Int(seq) * 100,
                                           itemType: "toolResult", role: "tool",
                                           createdAt: time, text: clip(body, 1500), rawJSON: "",
                                           truncated: body.count > 1500,
                                           turnId: Self.turnKey(sessionId, data)))
                default:
                    continue
                }
            }

            if createdAt == 0 { createdAt = items.first?.createdAt ?? 0 }
            if updatedAt == 0 { updatedAt = items.last?.createdAt ?? createdAt }
            let preview = items.first(where: { $0.role == "user" }).map { firstLine($0.text, 160) } ?? ""
            if title.isEmpty { title = preview }
            let threadId = try store.upsertThread(ThreadInput(
                sourceId: kind.rawValue, nativeId: sessionId,
                projectPath: cwd.isEmpty ? "/(未知)" : cwd,
                title: title.isEmpty ? "DeepSeek 会话 \(sessionId.prefix(12))" : firstLine(title, 120),
                createdAt: createdAt, updatedAt: updatedAt,
                model: "", threadSource: "user", archived: false, preview: preview))
            if !items.isEmpty {
                totalNew += try store.upsertItems(threadId: threadId, items: items).inserted
            }
            try store.setWatermark(sourceId: kind.rawValue, threadId: folder, watermark: String(size))
            if sessionId != folder {
                try store.setWatermark(sourceId: kind.rawValue, threadId: sessionId, watermark: String(size))
            }
        }
        return totalNew
    }

    static func isUserInput(_ data: [String: Any]) -> Bool {
        guard let source = data["source"] as? [String: Any] else { return true }
        let kind = source["kind"] as? String ?? ""
        return kind == "user" || kind == "cli" || kind == "acp"
    }

    /// DeepSeek 的回复里带原生轮次号（`data.turn`），用户消息有时没有，
    /// 所以把轮次号拼上会话 ID 当标识；拿不到时返回 nil，接在会话最后一轮后面。
    static func turnKey(_ sessionId: String, _ data: [String: Any]) -> String? {
        if let turn = data["turn"] as? NSNumber { return "\(sessionId)-t\(turn.intValue)" }
        if let turn = data["turn"] as? Int { return "\(sessionId)-t\(turn)" }
        return nil
    }

    static func contentText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let blocks = value as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
