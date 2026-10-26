import Foundation
import AppKit

struct TransferSelection {
    let source: SourceKind
    let target: SourceKind
    var threadIDs: [String]
}

struct TransferResult {
    var mode: DeliveryMode
    var written: Int
    var skipped: Int
    var failed: Int
    var redacted: Int
    var detail: String
    var artifacts: [String]
}

enum TransferError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "" }
}

/// 记录一轮同步里改动过的目标路径，供取消或校验失败时恢复。
final class TransferJournal {
    private struct Entry {
        let target: String
        let backup: String?
        let existedBefore: Bool
    }

    private var entries: [Entry] = []
    private let lock = NSLock()

    func record(target: String, backup: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !entries.contains(where: { $0.target == target }) else { return }
        entries.append(Entry(target: target, backup: backup, existedBefore: backup != nil))
    }

    func reset() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// 倒序恢复：原有文件用备份覆盖，本轮新增的文件与目录直接删除。
    /// 返回无法恢复的路径与原因，空数组表示全部还原成功。
    func restore() -> [String] {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        let fm = FileManager.default
        var problems: [String] = []
        for entry in snapshot.reversed() {
            if let backup = entry.backup, fm.fileExists(atPath: backup) {
                do {
                    if fm.fileExists(atPath: entry.target) {
                        try fm.removeItem(atPath: entry.target)
                    }
                    try fm.copyItem(atPath: backup, toPath: entry.target)
                } catch {
                    problems.append("\(entry.target) 恢复失败：\(error)")
                }
            } else if !entry.existedBefore, fm.fileExists(atPath: entry.target) {
                do { try fm.removeItem(atPath: entry.target) }
                catch { problems.append("\(entry.target) 删除失败：\(error)") }
            }
        }
        return problems
    }
}

/// 一轮同步的取消信号与恢复日志。写入器在循环里查询取消，改文件前登记路径。
enum TransferScope {
    static let journal = TransferJournal()
    static var shouldCancel: () -> Bool = { false }

    static func checkCancel() throws {
        if shouldCancel() { throw TransferError.message("已取消") }
    }
}

enum TransferPlanner {
    static func mode(source: SourceKind, target: SourceKind) -> DeliveryMode {
        if source == target { return .mcpRead }
        if target == .deepseek { return .nativeImport }
        switch target {
        case .opencode, .workbuddy, .claude, .kimi: return .nativeImport
        case .codex, .deepseek: return .handoff
        }
    }

    static func plan(store: Store, source: SourceKind, target: SourceKind,
                     threadIDs explicit: [String] = []) throws -> TransferPlan {
        let mode = mode(source: source, target: target)
        let threads: [ThreadRow]
        if explicit.isEmpty {
            threads = try store.threads(sourceKind: source, limit: 100_000)
        } else {
            let all = try store.threads(sourceKind: source, limit: 1000)
            threads = all.filter { explicit.contains($0.id) }
        }

        var messages = 0
        var duplicates = 0
        var redacted = 0
        var bytes = 0
        for t in threads {
            let items = try store.items(threadId: t.id, limit: 100000)
            messages += items.count
            bytes += items.reduce(0) { $0 + $1.text.utf8.count }
            redacted += Redactor.mask(items.map(\.text).joined(separator: "\n")).hits
            let done: Bool
            if target == .deepseek && mode == .nativeImport {
                done = try alreadyTransferredNative(store: store, threadId: t.id)
            } else {
                done = try alreadyTransferred(store: store, threadId: t.id, target: target)
            }
            if done { duplicates += 1 }
        }

        let targetPath: String
        switch target {
        case .workbuddy: targetPath = WriteSupport.workbuddyProjects
        case .claude: targetPath = WriteSupport.claudeProjects
        case .opencode: targetPath = "opencode import"
        case .codex: targetPath = store.root + "/handoffs"
        case .kimi: targetPath = KimiSupport.home + "/sessions"
        case .deepseek: targetPath = DSHSupport.home + "/sessions"
        }

        var notes: [String] = []
        if mode == .handoff { notes.append("Codex 不接受外部伪造的历史，本次生成交接包并给出续接命令") }
        if target == .workbuddy { notes.append("写入前需要先退出 WorkBuddy") }
        if target == .claude { notes.append("Claude Code 的会话导入为实验性，写入后需验证是否可见") }
        if target == .kimi { notes.append("写入 Kimi Code 的会话目录，重启 Kimi Code 后侧边栏可见") }
        if target == .deepseek { notes.append("写入 DeepSeek Harness 的 v4 会话目录，重启后在侧边栏可见") }

        return TransferPlan(sourceKind: source, targetKind: target, mode: mode, threadIDs: threads.map(\.id),
                            messageCount: messages, duplicateCount: duplicates, redactedCount: redacted,
                            estimatedBytes: bytes, targetPath: targetPath, notes: notes)
    }

    static func alreadyTransferred(store: Store, threadId: String, target: SourceKind) throws -> Bool {
        try alreadyTransferred(store: store, threadId: threadId, targetRaw: target.rawValue)
    }

    static func alreadyTransferred(store: Store, threadId: String, targetRaw: String) throws -> Bool {
        let n = try store.db.scalarInt("""
        SELECT COUNT(*) FROM handoffs WHERE thread_id=? AND target=? AND status='transferred'
        """, [threadId, targetRaw])
        return n > 0
    }

    /// Native DeepSeek writes use their own target key so an older handoff package
    /// does not block the session from being imported into the sidebar.
    static func alreadyTransferredNative(store: Store, threadId: String) throws -> Bool {
        let n = try store.db.scalarInt("""
        SELECT COUNT(*) FROM handoffs WHERE thread_id=? AND target='deepseek-native' AND status='transferred'
        """, [threadId])
        return n > 0
    }
}

final class TransferRunner {
    let store: Store
    init(store: Store) { self.store = store }

    func execute(plan: TransferPlan, shouldCancel: @escaping () -> Bool = { false },
                 progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        let startedAt = Int64(Date().timeIntervalSince1970)
        TransferScope.journal.reset()
        // 上一轮留下的备份先按时间收一遍，别让备份目录跟着传输次数一起长。
        WriteSupport.pruneBackups(storeRoot: store.root)
        TransferScope.shouldCancel = shouldCancel
        // 取消信号只对本次同步有效，结束后复位，否则下一轮一开始就会被判定为已取消。
        defer { TransferScope.shouldCancel = { false } }
        do {
            let result = try run(plan: plan, shouldCancel: shouldCancel, progress: progress)
            if result.failed > 0 {
                let reason = result.detail.isEmpty
                    ? "\(result.failed) 条会话写入后校验未通过"
                    : "\(result.failed) 条会话写入后校验未通过：\(result.detail)"
                let problems = TransferScope.journal.restore()
                try? rollback(since: startedAt)
                throw TransferError.message(problems.isEmpty
                    ? "\(reason)；已按备份恢复到同步前状态"
                    : "\(reason)；已尝试恢复，以下路径需要手工处理：" + problems.joined(separator: "；"))
            }
            return result
        } catch {
            let problems = TransferScope.journal.restore()
            try? rollback(since: startedAt)
            if case TransferError.message(let reason) = error, !problems.isEmpty {
                throw TransferError.message("\(reason)；恢复不完整：" + problems.joined(separator: "；"))
            }
            throw error
        }
    }

    private func rollback(since: Int64) throws {
        let rows = try store.db.query("""
        SELECT id,payload FROM handoffs WHERE created_at>=? AND status='transferred'
        """, [since]) { ($0.text(0), $0.text(1)) }
        for (id, path) in rows where !path.isEmpty {
            if FileManager.default.fileExists(atPath: path) {
                let trash = store.root + "/backups/rolled-back-" + (path as NSString).lastPathComponent
                try? FileManager.default.moveItem(atPath: path, toPath: trash)
            }
            _ = try? store.db.run("DELETE FROM handoffs WHERE id=?", [id])
        }
    }

    private func run(plan: TransferPlan, shouldCancel: @escaping () -> Bool,
                     progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        progress(0.05, "读取")
        var payloads: [(String, String, [ItemRow])] = []
        for (i, id) in plan.threadIDs.enumerated() {
            if shouldCancel() { throw TransferError.message("已取消") }
            guard let thread = try store.thread(id: id) else { continue }
            let items = try store.items(threadId: id, limit: 100000)
            payloads.append((thread.id, thread.title, items))
            progress(0.05 + 0.20 * Double(i + 1) / Double(max(plan.threadIDs.count, 1)), "读取")
        }
        progress(0.25, "归一化")
        progress(0.45, "遮蔽")

        switch plan.mode {
        case .nativeImport:
            switch plan.targetKind {
            case .workbuddy:
                return try WorkBuddyWriter(store: store).write(plan: plan, payloads: payloads, progress: progress)
            case .opencode:
                return try OpenCodeWriter(store: store).write(plan: plan, payloads: payloads, progress: progress)
            case .claude:
                return try ClaudeWriter(store: store).write(plan: plan, payloads: payloads, progress: progress)
            case .codex:
                return try HandoffWriter(store: store).write(plan: plan, payloads: payloads, progress: progress)
            case .kimi:
                return try KimiWriter(store: store).write(plan: plan, payloads: payloads, progress: progress)
            case .deepseek:
                return try DSHWriter(store: store).write(plan: plan, payloads: payloads, progress: progress)
            }
        case .handoff, .mcpRead:
            if plan.mode == .mcpRead {
                let message = try MCPInstaller.install(store: store, target: plan.targetKind)
                progress(1.0, "完成")
                return TransferResult(mode: .mcpRead, written: 0, skipped: 0, failed: 0,
                                      redacted: 0, detail: message, artifacts: [])
            }
            return try HandoffWriter(store: store).write(plan: plan, payloads: payloads, progress: progress)
        }
    }
}

enum MCPInstaller {
    static var binaryPath: String {
        NSHomeDirectory() + "/Applications/AgentHistory.app/Contents/MacOS/AgentHistory"
    }

    static func install(store: Store, target: SourceKind) throws -> String {
        switch target {
        case .workbuddy:
            let path = NSHomeDirectory() + "/.workbuddy/connectors/default/mcp.json"
            guard FileManager.default.fileExists(atPath: path) else {
                return "WorkBuddy 配置不存在，跳过注册"
            }
            _ = try WriteSupport.backup(path: path, store: store)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var root = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["agent-history"] = ["type": "stdio", "command": binaryPath,
                                        "args": ["mcp"], "timeout": 60000, "disabled": false]
            root["mcpServers"] = servers
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: path))
            return "已在 WorkBuddy 注册 MCP 直读，重启 WorkBuddy 后新开会话即可检索"

        case .codex:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.npm-global/bin/codex")
            p.arguments = ["mcp", "add", "agent-history", "--", binaryPath, "mcp"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            return p.terminationStatus == 0
                ? "已在 Codex 注册 MCP 直读，新开会话即可调用 search_threads"
                : "注册 Codex MCP 失败，可手动执行 codex mcp add"

        case .claude, .opencode, .deepseek:
            return "该客户端暂不支持自动注册 MCP，请在其配置里指向 \(binaryPath) mcp"

        case .kimi:
            let dir = NSHomeDirectory() + "/.kimi-code"
            let path = dir + "/mcp.json"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            _ = try WriteSupport.backup(path: path, store: store)
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                root = parsed
            }
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers["agent-history"] = ["command": binaryPath, "args": ["mcp"]]
            root["mcpServers"] = servers
            let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: path))
            return "已在 Kimi Code 注册 MCP 直读（~/.kimi-code/mcp.json），重启后新会话即可检索"
        }
    }
}

enum WriteSupport {
    static var workbuddyProjects: String {
        ProcessInfo.processInfo.environment["AGENT_HISTORY_WORKBUDDY_PROJECTS"]
            ?? NSHomeDirectory() + "/.workbuddy/projects"
    }

    static var claudeProjects: String {
        ProcessInfo.processInfo.environment["AGENT_HISTORY_CLAUDE_PROJECTS"]
            ?? NSHomeDirectory() + "/.claude/projects"
    }

    static func backup(path: String, store: Store) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = store.root + "/backups/\(stamp)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = dir + "/" + (path as NSString).lastPathComponent
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(atPath: dest)
        }
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return dest
    }

    static func backupSQLite(path: String, store: Store) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dir = store.root + "/backups/\(stamp)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = dir + "/" + (path as NSString).lastPathComponent
        let src = try Database(path: "file:\(path)?mode=ro", readOnly: true)
        let escaped = dest.replacingOccurrences(of: "'", with: "''")
        try src.exec("VACUUM INTO '\(escaped)'")
        return dest
    }

    /// 写入前登记：文件已存在就留一份备份，不存在则记为新增，回滚时整个删掉。
    static func track(_ path: String, store: Store) throws {
        let backup = try backup(path: path, store: store)
        TransferScope.journal.record(target: path, backup: backup)
    }

    static func trackSQLite(_ path: String, store: Store) throws {
        let backup = try backupSQLite(path: path, store: store)
        TransferScope.journal.record(target: path, backup: backup)
    }

    /// 备份目录只增不减会一路涨上去：每写一次目标客户端的库就先 VACUUM 一份副本，
    /// 本机攒到 774 MB，比口袋库本身还大。这里按修改时间只留最近若干份。
    /// 只认纯数字的目录名（那是按时间戳建的），手写的断点目录不动。
    @discardableResult
    static func pruneBackups(storeRoot: String, keep: Int = 5) -> (removed: Int, bytes: Int64) {
        let dir = storeRoot + "/backups"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return (0, 0) }
        let entries: [(path: String, at: Date, size: Int64)] = names.compactMap { name in
            guard !name.isEmpty, name.allSatisfy(\.isNumber) else { return nil }
            let path = dir + "/" + name
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeDirectory,
                  let at = attrs[.modificationDate] as? Date else { return nil }
            return (path, at, directorySize(path))
        }
        guard entries.count > keep else { return (0, 0) }
        var removed = 0
        var bytes: Int64 = 0
        for entry in entries.sorted(by: { $0.at > $1.at }).dropFirst(keep) {
            if (try? FileManager.default.removeItem(atPath: entry.path)) != nil {
                removed += 1
                bytes += entry.size
            }
        }
        return (removed, bytes)
    }

    /// 分开数：能自动清的时间戳目录、和手写的断点目录（prune 永远不碰后者）。
    static func backupUsage(storeRoot: String) -> (count: Int, bytes: Int64, prunable: Int, manual: Int) {
        let dir = storeRoot + "/backups"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return (0, 0, 0, 0) }
        var count = 0
        var bytes: Int64 = 0
        var prunable = 0
        var manual = 0
        for name in names {
            let path = dir + "/" + name
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeDirectory else { continue }
            count += 1
            if name.allSatisfy(\.isNumber) { prunable += 1 } else { manual += 1 }
            bytes += directorySize(path)
        }
        return (count, bytes, prunable, manual)
    }

    private static func directorySize(_ path: String) -> Int64 {
        guard let e = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let name as String in e {
            let full = path + "/" + name
            total += (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int64 ?? 0
        }
        return total
    }

    static func slug(_ path: String) -> String {
        var s = path.hasPrefix("/") ? String(path.dropFirst()) : path
        s = s.replacingOccurrences(of: "/", with: "-")
        return s.isEmpty ? "root" : s
    }

    /// Claude Code 的项目目录名：按真实路径（解析软链）取名，非 ASCII 字符逐个换成短横线。
    /// 不这么算，写到 `~/.claude/projects` 里的会话在 `claude --resume` 里查不到。
    static func claudeProjectDir(_ path: String) -> String {
        let real = (path as NSString).resolvingSymlinksInPath
        var s = real.hasPrefix("/") ? String(real.dropFirst()) : real
        var out = ""
        for ch in s {
            if ch == "/" { out.append("-") }
            else if ch.isASCII { out.append(ch) }
            else { out.append("-") }
        }
        s = out
        return "-" + (s.isEmpty ? "root" : s)
    }

    static func record(store: Store, plan: TransferPlan, threadId: String, status: String, detail: String,
                       target: String? = nil) throws {
        try store.db.run("""
        INSERT INTO handoffs(id,thread_id,target,created_at,title,summary,decisions,todos,files,status,payload)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)
        """, [UUID().uuidString, threadId, target ?? plan.targetKind.rawValue,
              Int64(Date().timeIntervalSince1970), "", "", "", "", "", status, detail])
    }
}

// MARK: - WorkBuddy

struct WorkBuddyWriter {
    let store: Store

    func write(plan: TransferPlan, payloads: [(String, String, [ItemRow])],
               progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.workbuddy.mac").isEmpty {
            throw TransferError.message("请先退出 WorkBuddy，再执行同步")
        }
        var written = 0, skipped = 0
        var artifacts: [String] = []
        for (i, entry) in payloads.enumerated() {
            let (threadId, title, items) = entry
            try TransferScope.checkCancel()
            if try TransferPlanner.alreadyTransferred(store: store, threadId: threadId, target: .workbuddy) {
                skipped += 1
                continue
            }
            guard let thread = try store.thread(id: threadId) else { continue }
            let cwd = thread.projectPath
            let dir = WriteSupport.workbuddyProjects + "/" + WriteSupport.slug(cwd)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let sid = UUID().uuidString.lowercased()
            let file = dir + "/" + sid + ".jsonl"
            let metaFile = dir + "/" + sid + ".meta.json"
            try WriteSupport.track(file, store: store)
            try WriteSupport.track(metaFile, store: store)
            var lines: [String] = []
            lines.append(try jsonLine(["type": "ai-title", "id": UUID().uuidString.lowercased(),
                                       "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                                       "aiTitle": title, "sessionId": sid, "cwd": cwd]))
            for item in items {
                let ts = item.createdAt == 0 ? Int64(Date().timeIntervalSince1970 * 1000) : item.createdAt
                switch item.itemType {
                case "userMessage":
                    lines.append(try jsonLine(["id": item.id, "timestamp": ts, "type": "message",
                                               "role": "user", "content": [["type": "input_text", "text": item.text]],
                                               "sessionId": sid, "cwd": cwd]))
                case "agentMessage":
                    lines.append(try jsonLine(["id": item.id, "timestamp": ts, "type": "message",
                                               "role": "assistant", "content": [["type": "output_text", "text": item.text]],
                                               "sessionId": sid, "cwd": cwd]))
                case "reasoning":
                    lines.append(try jsonLine(["id": item.id, "timestamp": ts, "type": "reasoning",
                                               "rawContent": [["type": "reasoning_text", "text": item.text]],
                                               "content": [], "sessionId": sid, "cwd": cwd]))
                default:
                    continue
                }
            }
            try lines.joined(separator: "\n").appending("\n").write(toFile: file, atomically: true, encoding: .utf8)
            let meta = ["codebuddy.ai/hostKind": "unopted", "acpConnectionId": UUID().uuidString.lowercased()]
            try jsonLine(meta).write(toFile: metaFile, atomically: true, encoding: .utf8)
            try WriteSupport.track(WorkBuddyRegistry.dbPath, store: store)
            try WorkBuddyRegistry.register(file: file, store: store)
            try WriteSupport.record(store: store, plan: plan, threadId: threadId, status: "transferred", detail: file)
            artifacts.append(file)
            written += 1
            progress(0.60 + 0.30 * Double(i + 1) / Double(max(payloads.count, 1)), "写入 WorkBuddy")
        }
        progress(0.90, "校验")
        let missing = artifacts.filter { !FileManager.default.fileExists(atPath: $0) }
        progress(1.0, "完成")
        return TransferResult(mode: plan.mode, written: written, skipped: skipped + plan.duplicateCount,
                              failed: missing.count, redacted: plan.redactedCount,
                              detail: "写入 \(written) 条会话；启动 WorkBuddy 后可在项目里看到",
                              artifacts: artifacts)
    }

    private func jsonLine(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

enum WorkBuddyRegistry {
    static var dbPath: String { NSHomeDirectory() + "/.workbuddy/workbuddy.db" }

    static func register(file: String, store: Store) throws {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        let sid = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        var title = "从其他客户端同步的会话"
        var cwd = ""
        var minTs = Int64.max
        var maxTs: Int64 = 0
        if let handle = FileHandle(forReadingAtPath: file) {
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 4_000_000), let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    guard let d = line.data(using: .utf8),
                          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
                    if let t = o["aiTitle"] as? String, !t.isEmpty { title = t }
                    if let c = o["cwd"] as? String, !c.isEmpty { cwd = c }
                    if let ts = (o["timestamp"] as? NSNumber)?.int64Value, ts > 0 {
                        minTs = min(minTs, ts); maxTs = max(maxTs, ts)
                    }
                }
            }
        }
        guard !cwd.isEmpty else { return }
        let db = try Database(path: dbPath)
        let userID = try db.query("SELECT user_id FROM sessions LIMIT 1") { $0.text(0) }.first
            ?? (try? String(contentsOfFile: NSHomeDirectory() + "/.workbuddy/device-id", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userID.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let created = minTs == .max ? now : minTs
        let updated = maxTs == 0 ? now : maxTs
        try db.run("""
        INSERT OR REPLACE INTO sessions(id,cwd,user_id,title,status,created_at,updated_at,last_activity_at,
            is_playground,transport,mode,model,permission_mode,unread,plugin_context_json,
            last_user_prompt_expert_selection)
        VALUES(?,?,?,?,?,?,?,?,1,'local','craft','deepseek-v4.1-flash','bypassPermissions',0,?,?)
        """, [sid, cwd, userID, title, "completed", created, updated, updated,
              "{\"version\":1,\"selectedPluginIds\":[],\"microSceneIds\":[],\"projectResources\":{\"connectorSkillIds\":[],\"mcpServerNames\":[],\"projectSkillNames\":[]},\"pluginSettings\":{\"enabledPlugins\":{},\"extraKnownMarketplaces\":{}}}",
              "{\"version\":1,\"selection\":null}"])
    }

    static func backfill(store: Store) throws -> Int {
        guard FileManager.default.fileExists(atPath: dbPath) else { return 0 }
        _ = try WriteSupport.backup(path: dbPath, store: store)
        let rows = try store.db.query("""
        SELECT payload FROM handoffs WHERE target='workbuddy' AND status='transferred'
        """) { $0.text(0) }
        var count = 0
        for file in rows where !file.isEmpty && FileManager.default.fileExists(atPath: file) {
            try register(file: file, store: store)
            count += 1
        }
        return count
    }
}

// MARK: - Kimi Code

enum KimiSupport {
    static var home: String {
        ProcessInfo.processInfo.environment["AGENT_HISTORY_KIMI_HOME"]
            ?? NSHomeDirectory() + "/.kimi-code"
    }

    static func iso(_ ms: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func latestWorkspace(home base: String? = nil) -> (id: String, root: String)? {
        let path = (base ?? home) + "/workspaces.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let map = root["workspaces"] as? [String: Any] else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var best: (stamp: Double, id: String, root: String)?
        for (id, value) in map {
            guard let ws = value as? [String: Any], let path = ws["root"] as? String else { continue }
            let stamp = parser.date(from: ws["last_opened_at"] as? String ?? "")?.timeIntervalSince1970 ?? 0
            if best == nil || stamp > best!.stamp {
                best = (stamp, id, path)
            }
        }
        guard let best else { return nil }
        return (best.id, best.root)
    }
}

struct KimiWriter {
    let store: Store
    var home: String = KimiSupport.home

    func write(plan: TransferPlan, payloads: [(String, String, [ItemRow])],
               progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        guard let workspace = KimiSupport.latestWorkspace(home: home) else {
            throw TransferError.message("Kimi Code 还没有工作区：先在 Kimi Code 里打开一个文件夹，再执行同步")
        }
        var written = 0, skipped = 0
        var artifacts: [String] = []
        for (i, entry) in payloads.enumerated() {
            let (threadId, title, items) = entry
            if try TransferPlanner.alreadyTransferred(store: store, threadId: threadId, target: .kimi) {
                skipped += 1
                continue
            }
            guard let thread = try store.thread(id: threadId) else { continue }
            let messages = items.filter {
                ($0.itemType == "userMessage" || $0.itemType == "agentMessage") && !$0.text.isEmpty
            }
            guard !messages.isEmpty else { skipped += 1; continue }

            let sessionId = "session_" + UUID().uuidString.lowercased()
            let dir = home + "/sessions/" + workspace.id + "/" + sessionId
            try FileManager.default.createDirectory(atPath: dir + "/agents/main", withIntermediateDirectories: true)

            let startedAt = messages.first?.createdAt ?? Int64(Date().timeIntervalSince1970 * 1000)
            let endedAt = messages.last?.createdAt ?? startedAt
            let cwd = thread.projectPath.hasPrefix("/") && thread.projectPath != "/(未知)"
                ? thread.projectPath : workspace.root
            let firstUser = messages.first(where: { $0.role == "user" })?.text ?? ""

            let state: [String: Any] = [
                "id": sessionId, "version": 2, "cwd": cwd, "archived": thread.archived,
                "agents": ["main": ["homedir": dir + "/agents/main", "type": "main"]],
                "custom": [String: Any](), "title": String(title.prefix(120)), "titleKind": "custom",
                "createdAt": startedAt, "updatedAt": endedAt,
                "lastPrompt": String(firstUser.prefix(200)),
                "lastTurnReason": "completed", "isCustomTitle": true
            ]
            try Self.jsonData(state).write(to: URL(fileURLWithPath: dir + "/state.json"))

            var records: [[String: Any]] = [
                ["type": "metadata", "protocol_version": "1.5", "created_at": startedAt],
                ["type": "runtime.set_binding", "workspaceId": workspace.id, "runtimeId": "local",
                 "agentId": "main", "time": startedAt]
            ]
            var turn = 0
            var promptId = ""
            for (index, item) in messages.enumerated() {
                let ts = item.createdAt == 0 ? startedAt + Int64(index * 1000) : item.createdAt
                let messageId = "msg_" + String(UUID().uuidString
                    .replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
                let role = item.role == "user" ? "user" : "assistant"
                if role == "user" {
                    promptId = messageId
                    records.append(["type": "turn.prompt", "agentId": "main",
                                    "input": [["type": "text", "text": item.text]],
                                    "origin": ["kind": "user"], "time": ts, "promptId": promptId])
                    records.append(["type": "agent.turn.started", "turnId": turn,
                                    "queueItemId": promptId, "time": ts, "kind": "event"])
                }
                records.append(["type": "context.append_message", "agentId": "main", "time": ts,
                                "message": ["role": role,
                                            "content": [["type": "text", "text": item.text]],
                                            "id": messageId, "toolCalls": []]])
                if role == "user" {
                    records.append(["type": "agent.message.appended", "time": ts + 1, "kind": "event",
                                    "message": ["message": ["role": "user",
                                                            "content": [["type": "text", "text": item.text]]],
                                                "meta": ["source": "input", "promptId": promptId,
                                                         "origin": ["kind": "user"], "tracked": true,
                                                         "createdAt": KimiSupport.iso(ts),
                                                         "userMessageId": promptId]]])
                } else {
                    records.append(["type": "agent.message.appended", "time": ts + 1, "kind": "event",
                                    "message": ["message": ["role": "assistant",
                                                            "content": [["type": "text", "text": item.text]],
                                                            "toolCalls": []],
                                                "meta": ["model": ["provider": "agent-loop", "model": "agent-loop"],
                                                         "source": "llm",
                                                         "usage": ["inputOther": 0, "output": 0,
                                                                   "inputCacheRead": 0, "inputCacheCreation": 0],
                                                         "finish": ["finishReason": "completed",
                                                                    "rawFinishReason": "stop"],
                                                         "messageId": UUID().uuidString
                                                            .replacingOccurrences(of: "-", with: "").lowercased()]]])
                    records.append(["type": "agent.turn.ended", "turnId": turn, "outcome": "done",
                                    "time": ts + 2, "kind": "event"])
                    records.append(["type": "turn.ended", "agentId": "main", "turnId": turn,
                                    "reason": "completed", "durationMs": 1, "time": ts + 3])
                    if !promptId.isEmpty {
                        records.append(["type": "prompt.completed", "agentId": "main", "promptId": promptId,
                                        "finishedAt": KimiSupport.iso(ts + 4), "reason": "completed",
                                        "time": ts + 4])
                    }
                    turn += 1
                }
            }

            var lines: [String] = []
            for record in records {
                lines.append(String(decoding: try Self.jsonData(record), as: UTF8.self))
            }
            try (lines.joined(separator: "\n") + "\n")
                .write(toFile: dir + "/agents/main/wire.jsonl", atomically: true, encoding: .utf8)

            try WriteSupport.record(store: store, plan: plan, threadId: threadId, status: "transferred", detail: dir)
            written += 1
            artifacts.append(dir)
            progress(0.60 + 0.30 * Double(i + 1) / Double(max(payloads.count, 1)), "写入 Kimi Code")
        }
        progress(0.90, "校验")
        let missing = artifacts.filter { !FileManager.default.fileExists(atPath: $0 + "/state.json") }
        progress(1.0, "完成")
        return TransferResult(mode: plan.mode, written: written, skipped: skipped + plan.duplicateCount,
                              failed: missing.count, redacted: plan.redactedCount,
                              detail: "写入 \(written) 个会话到 Kimi Code；重启 Kimi Code 后可在侧边栏看到",
                              artifacts: artifacts)
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

// MARK: - DeepSeek Harness

enum DSHSupport {
    static var home: String {
        if let env = ProcessInfo.processInfo.environment["AGENT_HISTORY_DSH_HOME"] { return env }
        let dsh = NSHomeDirectory() + "/.dsh"
        if FileManager.default.fileExists(atPath: dsh + "/storages") { return dsh }
        return NSHomeDirectory() + "/Library/Application Support/dsh-desktop/harness"
    }

    /// Project directory name: "-" + path with "/" replaced by "-" + "-", non-ASCII escaped as ~UTF16.
    static func projectDir(_ path: String) -> String {
        var out = "-"
        for scalar in path.unicodeScalars {
            if scalar == "/" {
                out.append("-")
            } else if scalar.isASCII {
                out.append(Character(scalar))
            } else {
                for unit in String(Character(scalar)).utf16 {
                    out += String(format: "~%04X", unit)
                }
            }
        }
        return out + "--"
    }

    static func workspacePath(_ home: String) -> String { home + "/storages/workspace.json" }
}

struct DSHWriter {
    let store: Store
    var home: String = DSHSupport.home

    private struct Turn {
        let user: String
        let assistant: String
        let at: Int64
    }

    func write(plan: TransferPlan, payloads: [(String, String, [ItemRow])],
               progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        guard let zstd = DeepSeekAdapter.zstdPath() else {
            throw TransferError.message("未找到 zstd，无法写入 DeepSeek Harness 会话")
        }
        let wsPath = DSHSupport.workspacePath(home)
        guard let wsData = try? Data(contentsOf: URL(fileURLWithPath: wsPath)),
              var root = (try? JSONSerialization.jsonObject(with: wsData)) as? [String: Any],
              var tables = root["tables"] as? [String: Any],
              var workspaces = tables["workspaces"] as? [String: Any],
              !workspaces.isEmpty else {
            throw TransferError.message("DeepSeek Harness 还没有工作区：先在 DSH 里打开一个文件夹")
        }

        func workspaceId(for cwd: String) -> String? {
            var best: (Int, String)?
            for (id, value) in workspaces {
                guard let ws = value as? [String: Any], let p = ws["path"] as? String else { continue }
                if cwd == p || cwd.hasPrefix(p + "/") {
                    if best == nil || p.count > best!.0 { best = (p.count, id) }
                }
            }
            if let best { return best.1 }
            return workspaces.keys.sorted().first
        }

        var written = 0, skipped = 0
        var failed = 0
        var artifacts: [String] = []
        for (i, entry) in payloads.enumerated() {
            let (threadId, title, items) = entry
            if try TransferPlanner.alreadyTransferredNative(store: store, threadId: threadId) {
                skipped += 1
                continue
            }
            guard let thread = try store.thread(id: threadId) else { continue }
            var turns: [Turn] = []
            var pending: (String, Int64)?
            for item in items {
                guard item.itemType == "userMessage" || item.itemType == "agentMessage" else { continue }
                if item.role == "user" {
                    pending = (item.text, item.createdAt)
                } else if item.role == "assistant", let user = pending {
                    turns.append(Turn(user: user.0, assistant: item.text, at: item.createdAt))
                    pending = nil
                }
            }
            guard !turns.isEmpty, let wsId = workspaceId(for: thread.projectPath),
                  let ws = workspaces[wsId] as? [String: Any],
                  let cwd = ws["path"] as? String else {
                skipped += 1
                continue
            }

            let sid = "session-" + UUID().uuidString.lowercased()
            let dir = home + "/sessions/" + DSHSupport.projectDir(cwd) + "/" + sid
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            var records: [[String: Any]] = [[
                "type": "session", "version": 4, "id": sid,
                "createdAt": turns.first?.at ?? Int64(Date().timeIntervalSince1970 * 1000),
                "cwd": cwd, "isSeeded": false, "delegationDepth": 0, "agentPreset": "standard"
            ]]
            var seq = 0
            var firstUserSeq = 0
            var lastTime = turns.first?.at ?? Int64(Date().timeIntervalSince1970 * 1000)
            for (ti, turn) in turns.enumerated() {
                let n = ti + 1
                let t = turn.at == 0 ? lastTime + 1000 : turn.at
                lastTime = t
                func add(_ type: String, _ data: [String: Any], surface: Bool = false) {
                    var record: [String: Any] = ["type": type, "seq": seq, "time": t, "data": data]
                    if surface { record["surfaceOp"] = "append" }
                    records.append(record)
                    seq += 1
                }
                add("turn/start", ["turn": n])
                if n == 1 { firstUserSeq = seq }
                add("user/message", [
                    "content": [["type": "text", "text": turn.user]],
                    "source": ["kind": "user"], "role": "user", "id": UUID().uuidString.lowercased()
                ], surface: true)
                add("step/start", ["turn": n, "step": 1])
                add("assistant/message", [
                    "turn": n, "step": 1,
                    "message": [
                        "role": "assistant",
                        "content": [["type": "text", "text": turn.assistant]],
                        "source": [
                            "kind": "model", "provider": "deepseek-account", "model": "deepseek-flash",
                            "replayState": [
                                "response": ["kind": "deepseek-messages", "version": 1, "model": "deepseek-flash"],
                                "blocks": [["type": "text"]]
                            ]
                        ],
                        "id": UUID().uuidString.lowercased()
                    ],
                    "stream": []
                ], surface: true)
                add("step/end", ["turn": n, "step": 1])
                add("turn/end", ["turn": n, "reason": ["kind": "completed"]])
            }
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            records.append([
                "type": "session/title", "seq": seq, "time": lastTime + 1,
                "data": ["title": cleanTitle.isEmpty ? "导入会话" : cleanTitle,
                         "messageSeqs": [firstUserSeq], "source": ["kind": "fallback"]]
            ])

            var lines: [String] = []
            for record in records {
                lines.append(String(decoding: try Self.jsonData(record), as: UTF8.self))
            }
            let headerFrame = try Self.compress(zstd, lines[0] + "\n")
            let bodyFrame = try Self.compress(zstd, lines.dropFirst().joined(separator: "\n") + "\n")
            try (headerFrame + bodyFrame).write(to: URL(fileURLWithPath: dir + "/session.v4.jsonl.zstd"))

            var ids = (ws["sessionIds"] as? [String]) ?? []
            if !ids.contains(sid) { ids.insert(sid, at: 0) }
            var updated = ws
            updated["sessionIds"] = ids
            updated["updatedAt"] = KimiSupport.iso(Int64(Date().timeIntervalSince1970 * 1000))
            workspaces[wsId] = updated

            try WriteSupport.record(store: store, plan: plan, threadId: threadId, status: "transferred",
                                    detail: dir, target: "deepseek-native")
            written += 1
            artifacts.append(dir)
            progress(0.60 + 0.30 * Double(i + 1) / Double(max(payloads.count, 1)), "写入 DeepSeek Harness")
        }

        if written > 0 {
            tables["workspaces"] = workspaces
            root["tables"] = tables
            _ = try WriteSupport.backup(path: wsPath, store: store)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: wsPath))
        }
        progress(0.90, "校验")
        let missing = artifacts.filter { !FileManager.default.fileExists(atPath: $0 + "/session.v4.jsonl.zstd") }
        failed += missing.count
        progress(1.0, "完成")
        return TransferResult(mode: plan.mode, written: written, skipped: skipped + plan.duplicateCount,
                              failed: failed, redacted: plan.redactedCount,
                              detail: "写入 \(written) 个会话到 DeepSeek Harness；重启 DSH 后侧边栏可见",
                              artifacts: artifacts)
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    private static func compress(_ zstd: String, _ text: String) throws -> Data {
        let tmp = NSTemporaryDirectory() + "dsh-" + UUID().uuidString + ".jsonl"
        try text.data(using: .utf8)?.write(to: URL(fileURLWithPath: tmp))
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-q", "-c", tmp]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TransferError.message("zstd 压缩失败")
        }
        return data
    }
}

// MARK: - OpenCode

struct OpenCodeWriter {
    let store: Store

    func write(plan: TransferPlan, payloads: [(String, String, [ItemRow])],
               progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.local/share")
        let openCodeDB = dataHome + "/opencode/opencode.db"
        if FileManager.default.fileExists(atPath: openCodeDB) {
            _ = try WriteSupport.backupSQLite(path: openCodeDB, store: store)
        }
        var written = 0, skipped = 0, failed = 0
        var artifacts: [String] = []
        let tempDir = store.root + "/outbox"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        for (i, entry) in payloads.enumerated() {
            let (threadId, title, items) = entry
            if try TransferPlanner.alreadyTransferred(store: store, threadId: threadId, target: .opencode) {
                skipped += 1; continue
            }
            guard let thread = try store.thread(id: threadId) else { continue }
            let sid = "ses_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var messages: [[String: Any]] = []
            var lastUserMessageID: String?
            for item in items {
                let mid = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
                let pid = "prt_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)
                let role = item.role == "user" ? "user" : "assistant"
                let created = item.createdAt == 0 ? now : item.createdAt
                var info: [String: Any] = ["id": String(mid), "sessionID": String(sid), "role": role,
                                           "time": ["created": created, "completed": created],
                                           "agent": "build"]
                if role == "user" {
                    info["model"] = ["providerID": "opencode", "modelID": "big-pickle"]
                    lastUserMessageID = String(mid)
                } else {
                    info["parentID"] = lastUserMessageID ?? String(mid)
                    info["modelID"] = "big-pickle"
                    info["providerID"] = "opencode"
                    info["mode"] = "build"
                    info["path"] = ["cwd": thread.projectPath, "root": "/"]
                    info["cost"] = 0
                    info["tokens"] = ["input": 0, "output": 0, "reasoning": 0,
                                      "cache": ["read": 0, "write": 0]]
                }
                let part: [String: Any] = ["type": "text", "id": pid, "sessionID": String(sid),
                                           "messageID": mid, "text": item.text,
                                           "time": ["start": created, "end": created]]
                messages.append(["info": info, "parts": [part]])
            }
            let doc: [String: Any] = [
                "info": ["id": String(sid), "slug": "from-\(thread.sourceKind.rawValue)", "projectID": "global",
                         "directory": thread.projectPath, "title": title, "version": "1.1.53",
                         "summary": ["additions": 0, "deletions": 0, "files": 0], "cost": 0,
                         "tokens": ["input": 0, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0]],
                         "time": ["created": now, "updated": now]],
                "messages": messages]
            let file = tempDir + "/\(sid).json"
            let data = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: file))
            if let out = try? runOpenCodeImport(file: file), out.contains("Imported") {
                try WriteSupport.record(store: store, plan: plan, threadId: threadId, status: "transferred", detail: file)
                written += 1
                artifacts.append(file)
            } else {
                failed += 1
            }
            progress(0.60 + 0.30 * Double(i + 1) / Double(max(payloads.count, 1)), "写入 OpenCode")
        }
        progress(0.90, "校验")
        progress(1.0, "完成")
        return TransferResult(mode: plan.mode, written: written, skipped: skipped + plan.duplicateCount,
                              failed: failed, redacted: plan.redactedCount,
                              detail: "导入 \(written) 条会话到 OpenCode", artifacts: artifacts)
    }

    private func runOpenCodeImport(file: String) throws -> String {
        let candidates = [NSHomeDirectory() + "/.npm-global/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TransferError.message("未找到 opencode 命令")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["import", file]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Claude Code

struct ClaudeWriter {
    let store: Store
    /// 测试或迁移时指定别的项目目录，默认为 ~/.claude/projects。
    var projectsDir: String? = nil

    func write(plan: TransferPlan, payloads: [(String, String, [ItemRow])],
               progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        let base = projectsDir ?? WriteSupport.claudeProjects
        var written = 0, skipped = 0
        var artifacts: [String] = []
        for (i, entry) in payloads.enumerated() {
            let (threadId, title, items) = entry
            try TransferScope.checkCancel()
            if try TransferPlanner.alreadyTransferred(store: store, threadId: threadId, target: .claude) {
                skipped += 1; continue
            }
            guard let thread = try store.thread(id: threadId) else { continue }
            let dir = base + "/" + WriteSupport.claudeProjectDir(thread.projectPath)
            do {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                throw TransferError.message("无法创建 Claude 项目目录 \(dir)：\(Self.describe(error))")
            }
            let sid = UUID().uuidString.lowercased()
            let now = ISO8601DateFormatter().string(from: Date())
            var prevUuid: String?
            var lines: [[String: Any]] = [
                ["type": "last-prompt", "sessionId": sid],
                ["type": "mode", "mode": "normal", "sessionId": sid],
                ["type": "permission-mode", "permissionMode": "default", "sessionId": sid],
            ]
            for item in items where item.itemType == "userMessage" || item.itemType == "agentMessage" {
                let uuid = UUID().uuidString.lowercased()
                var obj: [String: Any] = ["type": item.role == "user" ? "user" : "assistant",
                                          "uuid": uuid, "sessionId": sid, "cwd": thread.projectPath,
                                          "version": "2.1.251", "timestamp": now, "isSidechain": false,
                                          "userType": "external"]
                if let p = prevUuid { obj["parentUuid"] = p }
                let content: Any = item.role == "user" ? item.text : [["type": "text", "text": item.text]]
                obj["message"] = ["role": item.role == "user" ? "user" : "assistant", "content": content]
                lines.append(obj)
                prevUuid = uuid
            }
            lines.append(["type": "ai-title", "aiTitle": title, "sessionId": sid])
            let file = dir + "/" + sid + ".jsonl"
            let body = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
                .joined(separator: "\n") + "\n"
            try WriteSupport.track(file, store: store)
            do {
                try body.write(toFile: file, atomically: true, encoding: .utf8)
            } catch {
                throw TransferError.message("无法写入会话文件 \(file)：\(Self.describe(error))")
            }
            try WriteSupport.record(store: store, plan: plan, threadId: threadId, status: "transferred", detail: file)
            written += 1; artifacts.append(file)
            progress(0.60 + 0.30 * Double(i + 1) / Double(max(payloads.count, 1)), "写入 Claude Code")
        }
        progress(0.90, "校验")

        if let reason = Self.verify(artifacts: artifacts) {
            progress(0.95, "降级为交接包")
            // 降级前把这一轮写进去的会话文件和同步记录撤干净，否则下次同步会以为已经导过。
            for file in artifacts {
                try? FileManager.default.removeItem(atPath: file)
            }
            for (threadId, _, _) in payloads {
                _ = try? store.db.run("DELETE FROM handoffs WHERE thread_id=? AND target='claude' AND status='transferred'",
                                      [threadId])
            }
            let handoff = try HandoffWriter(store: store, recordTarget: "claude-handoff")
                .write(plan: plan, payloads: payloads, progress: progress)
            progress(1.0, "完成")
            return TransferResult(mode: handoff.mode, written: handoff.written,
                                  skipped: handoff.skipped, failed: 0, redacted: plan.redactedCount,
                                  detail: "Claude Code 未识别写入的会话（\(reason)），已撤销原写入并改为生成 \(handoff.written) 个交接包",
                                  artifacts: handoff.artifacts)
        }

        progress(1.0, "完成")
        return TransferResult(mode: plan.mode, written: written, skipped: skipped + plan.duplicateCount,
                              failed: 0, redacted: plan.redactedCount,
                              detail: "写入 \(written) 个会话，已用隔离配置目录确认可被 claude --resume 识别", artifacts: artifacts)
    }

    /// 两步校验：先按 Claude 的定位规则检查文件与目录名，再在隔离配置目录里问一次 `claude --resume`。
    /// 返回 nil 表示通过，否则返回失败原因。
    static func verify(artifacts: [String]) -> String? {
        guard !artifacts.isEmpty else { return nil }
        for file in artifacts {
            let sid = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            guard let data = FileManager.default.contents(atPath: file),
                  let text = String(data: data, encoding: .utf8) else {
                return "会话文件 \(sid) 无法读取"
            }
            var sawUser = false
            var sawSession = false
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                    return "会话文件 \(sid) 不是合法的 JSONL"
                }
                if obj["sessionId"] as? String == sid { sawSession = true }
                if obj["type"] as? String == "user" { sawUser = true }
            }
            guard sawSession else { return "会话文件 \(sid) 里缺少匹配的 sessionId" }
            guard sawUser else { return "会话文件 \(sid) 里没有任何用户消息" }
            // 目录名必须与 Claude 按 cwd 算出来的名字一致，否则 --resume 按项目找不到这个会话。
            guard let cwd = cwd(of: file) else { return "会话文件 \(sid) 里没有 cwd，Claude 无法把它归到项目" }
            let expected = WriteSupport.claudeProjectDir(cwd)
            let actual = ((file as NSString).deletingLastPathComponent as NSString).lastPathComponent
            guard expected == actual else {
                return "会话 \(sid.prefix(8)) 的目录名 \(actual) 与 cwd \(cwd) 应有的 \(expected) 不符"
            }
        }
        if ProcessInfo.processInfo.environment["AGENT_HISTORY_CLAUDE_PROBE"] == "0" { return nil }
        return probe(artifacts: artifacts)
    }

    /// 在临时配置目录里跑一次 `claude --resume`，不联网、不碰用户的 ~/.claude。
    private static func probe(artifacts: [String]) -> String? {
        let bin = ["/Users/\(NSUserName())/.npm-global/bin/claude",
                   "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bin else { return nil }
        let fm = FileManager.default
        let sandbox = NSTemporaryDirectory() + "claude-probe-" + UUID().uuidString
        defer { try? fm.removeItem(atPath: sandbox) }

        for file in artifacts.prefix(2) {
            let sid = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
            let parent = (file as NSString).deletingLastPathComponent
            let mirror = sandbox + "/projects/" + (parent as NSString).lastPathComponent
            try? fm.createDirectory(atPath: mirror, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: file, toPath: mirror + "/" + (file as NSString).lastPathComponent)

            let cwd = Self.cwd(of: file) ?? NSHomeDirectory()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--resume", sid, "--print", ""]
            p.currentDirectoryURL = URL(fileURLWithPath: fm.fileExists(atPath: cwd) ? cwd : NSHomeDirectory())
            var env = ProcessInfo.processInfo.environment
            env["CLAUDE_CONFIG_DIR"] = sandbox
            env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:9"
            env["DISABLE_TELEMETRY"] = "1"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return "无法启动 claude 命令：\(error)" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let out = String(decoding: data, as: UTF8.self)
            if out.contains("No conversation found") {
                return "claude --resume 找不到会话 \(sid.prefix(8))"
            }
        }
        return nil
    }

    /// 取这个文件里第一条带 cwd 的记录，判断归属项目用。
    private static func cwd(of file: String) -> String? {
        guard let data = FileManager.default.contents(atPath: file),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let cwd = obj["cwd"] as? String, !cwd.isEmpty else { continue }
            return cwd
        }
        return nil
    }

    /// 把 Cocoa 权限错误翻成一句能看懂的话，避免命令行只抛一大串 domain code。
    static func describe(_ error: Error) -> String {
        // TransferError 自带人话，别让 NSError 把它吞成 "error 0"。
        if let t = error as? TransferError { return t.description }
        if let h = error as? HistoryError { return h.description }
        if let d = error as? DBError { return d.description }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError, 513, 257:
                let path = (ns.userInfo[NSFilePathErrorKey] as? String) ?? (ns.userInfo[NSURLErrorKey] as? URL)?.path ?? ""
                return path.isEmpty ? "没有权限，检查目录属主与可写位" : "没有权限写入 \(path)，检查目录属主与可写位"
            case NSFileWriteOutOfSpaceError:
                return "磁盘空间不足"
            default: break
            }
        }
        return ns.localizedDescription
    }
}

// MARK: - 交接包

struct HandoffWriter {
    let store: Store
    /// 降级写入时用独立的目标名登记，避免占掉原目标的同步记录。
    var recordTarget: String? = nil

    func write(plan: TransferPlan, payloads: [(String, String, [ItemRow])],
               progress: @escaping (Double, String) -> Void) throws -> TransferResult {
        var written = 0, skipped = 0
        var artifacts: [String] = []
        let targetKey = recordTarget ?? plan.targetKind.rawValue
        for (i, entry) in payloads.enumerated() {
            let (threadId, title, items) = entry
            try TransferScope.checkCancel()
            if try TransferPlanner.alreadyTransferred(store: store, threadId: threadId, targetRaw: targetKey) {
                skipped += 1; continue
            }
            guard let thread = try store.thread(id: threadId) else { continue }
            var md = "# 交接包：\(title)\n\n"
            md += "- 来源：\(thread.sourceKind.displayName)\n- 项目：\(thread.projectPath)\n"
            md += "- 更新时间：\(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(thread.updatedAt) / 1000)))\n\n"
            md += "## 对话摘要\n\n"
            for item in items where item.itemType == "userMessage" || item.itemType == "agentMessage" {
                let who = item.role == "user" ? "用户" : "助手"
                md += "**\(who)**：\(item.text)\n\n"
            }
            md += "## 待办\n\n- [ ] 在目标客户端继续上述工作\n"
            let name = threadId.prefix(8) + "-" + targetKey + ".md"
            let file = store.root + "/handoffs/" + name
            try WriteSupport.track(file, store: store)
            try md.write(toFile: file, atomically: true, encoding: .utf8)
            try WriteSupport.record(store: store, plan: plan, threadId: threadId, status: "transferred",
                                    detail: file, target: targetKey)
            // 界面导出的交接包同样要能被检索到，否则「导出了但搜不到」还是同一个坑。
            _ = try? store.upsertMemoryFile(kind: .handoff, path: file, title: title, body: md,
                                            threadId: threadId, meta: "目标 \(targetKey)",
                                            todo: "在目标客户端继续上述工作")
            written += 1; artifacts.append(file)
            progress(0.60 + 0.30 * Double(i + 1) / Double(max(payloads.count, 1)), "生成交接包")
        }
        progress(0.90, "校验"); progress(1.0, "完成")
        let first = artifacts.first ?? ""
        let command = first.isEmpty ? "" : "\n继续执行：codex exec \"读取 \(first) 并接着做\""
        return TransferResult(mode: plan.mode, written: written, skipped: skipped + plan.duplicateCount,
                              failed: 0, redacted: plan.redactedCount,
                              detail: "生成 \(written) 个交接包；用 codex exec 读取后继续" + command,
                              artifacts: artifacts)
    }
}
