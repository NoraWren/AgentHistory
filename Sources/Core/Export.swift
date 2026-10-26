import Foundation

struct ExportRecord {
    let thread: ThreadRow
    let items: [ItemRow]
}

struct ExportReport {
    var written = 0
    var skipped = 0
    var failed = 0
    var directory: String = ""
    var files: [String] = []
    var failures: [(title: String, reason: String)] = []

    var summary: String {
        var parts = ["成功 \(written)", "跳过 \(skipped)", "失败 \(failed)"]
        if written > 0 { parts.append("目录 \(directory)") }
        return parts.joined(separator: "，")
    }
}

enum ExportFormatter {
    /// 工具输出在导出里折叠成引用块，超过这个长度就截断。
    static let toolLimit = 1_200
    static let toolLines = 24

    static func isToolOutput(_ type: String) -> Bool {
        switch type {
        case "commandExecution", "toolResult", "fileChange", "mcpToolCall":
            return true
        default:
            return false
        }
    }

    static func roleLabel(_ item: ItemRow) -> String {
        switch item.itemType {
        case "userMessage": return "用户"
        case "agentMessage": return "助手"
        case "reasoning": return "思考"
        case "plan": return "计划"
        case "commandExecution": return "命令"
        case "toolResult": return "输出"
        case "fileChange": return "改动"
        case "mcpToolCall": return "工具调用"
        default: return item.itemType.isEmpty ? "记录" : item.itemType
        }
    }

    /// 单条记录到 Markdown 片段，复制与导出共用。
    static func renderItem(_ item: ItemRow) -> String {
        let label = roleLabel(item)
        let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isToolOutput(item.itemType) {
            return renderTool(body: body, label: label)
        }
        if body.isEmpty { return "" }
        if item.itemType == "userMessage" {
            return "**用户**\n\n" + body + "\n"
        }
        if item.itemType == "agentMessage" {
            return "**助手**\n\n" + body + "\n"
        }
        return "> **\(label)**\n\n" + body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n") + "\n"
    }

    private static func renderTool(body: String, label: String) -> String {
        guard !body.isEmpty else { return "" }
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var trimmed = false
        if lines.count > toolLines {
            lines = Array(lines.prefix(toolLines))
            trimmed = true
        }
        var joined = lines.joined(separator: "\n")
        if joined.count > toolLimit {
            joined = String(joined.prefix(toolLimit))
            trimmed = true
        }
        if trimmed { joined += "\n…（已截断）" }
        let quoted = joined.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n")
        return "> **\(label)**\n>\n" + quoted + "\n"
    }

    static func timeRange(_ items: [ItemRow]) -> String {
        let stamps = items.map(\.createdAt).filter { $0 > 0 }.sorted()
        guard let first = stamps.first, let last = stamps.last else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let a = f.string(from: Date(timeIntervalSince1970: Double(first) / 1000))
        let b = f.string(from: Date(timeIntervalSince1970: Double(last) / 1000))
        return a == b ? a : "\(a) 至 \(b)"
    }

    static func redactedCount(_ items: [ItemRow]) -> Int {
        items.reduce(0) { $0 + occurrences(of: "[已遮蔽", in: $1.text) }
    }

    private static func occurrences(of needle: String, in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        var cursor = text.startIndex
        while let range = text.range(of: needle, range: cursor..<text.endIndex) {
            count += 1
            cursor = range.upperBound
        }
        return count
    }

    static func render(thread: ThreadRow, items: [ItemRow]) -> String {
        var out = "# \(thread.title.isEmpty ? "（无标题会话）" : thread.title)\n\n"
        var meta: [String] = ["来源：\(thread.sourceKind.displayName)"]
        if !thread.projectPath.isEmpty { meta.append("项目：\(thread.projectPath)") }
        let range = timeRange(items)
        if !range.isEmpty { meta.append("时间：\(range)") }
        meta.append("记录：\(items.count) 条")
        let masked = redactedCount(items)
        meta.append(masked > 0 ? "遮蔽：\(masked) 处（库内已脱敏，不可还原）" : "遮蔽：无")
        out += "> " + meta.joined(separator: " · ") + "\n\n---\n\n"

        var blocks: [String] = []
        for item in items {
            let block = renderItem(item)
            if !block.isEmpty { blocks.append(block) }
        }
        out += blocks.joined(separator: "\n")
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    /// 文件名：标题 + 短标识，去掉路径分隔符等不合法字符。
    static func fileName(title: String, id: String, taken: inout Set<String>) -> String {
        var base = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        base = base.components(separatedBy: illegal).joined(separator: " ")
        base = base.replacingOccurrences(of: "\u{1}", with: " ")
        if base.isEmpty { base = "会话" }
        if base.count > 60 { base = String(base.prefix(60)) }
        let suffix = String(id.replacingOccurrences(of: "-", with: "").prefix(6))
        var candidate = base + "-" + suffix + ".md"
        var n = 2
        while taken.contains(candidate) {
            candidate = base + "-" + suffix + "-" + String(n) + ".md"
            n += 1
        }
        taken.insert(candidate)
        return candidate
    }
}

enum Exporter {
    /// 单会话导出。目录不存在时创建，同名不覆盖。
    static func writeThread(store: Store, threadId: String, directory: String,
                            taken: inout Set<String>) throws -> (file: String, title: String) {
        guard let thread = try store.thread(id: threadId) else {
            throw HistoryError.message("找不到会话 \(threadId)")
        }
        let items = try store.items(threadId: threadId, limit: 1_000_000)
        let content = ExportFormatter.render(thread: thread, items: items)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let name = ExportFormatter.fileName(title: thread.title, id: thread.id, taken: &taken)
        let path = directory + "/" + name
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return (path, thread.title.isEmpty ? "（无标题）" : thread.title)
    }

    /// 批量导出：每条一个文件，外加 index.md 清单。
    static func export(store: Store, threadIds: [String], directory: String) -> ExportReport {
        var report = ExportReport()
        report.directory = directory
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            report.failed = threadIds.count
            report.failures.append(("目标目录", "\(error)"))
            return report
        }
        var taken = Set<String>()
        var manifest: [(file: String, title: String, source: String, masked: Int, items: Int)] = []
        var seen = Set<String>()

        for id in threadIds {
            guard seen.insert(id).inserted else { report.skipped += 1; continue }
            do {
                guard let thread = try store.thread(id: id) else {
                    report.skipped += 1
                    report.failures.append((id, "会话不存在"))
                    continue
                }
                let items = try store.items(threadId: id, limit: 1_000_000)
                let content = ExportFormatter.render(thread: thread, items: items)
                let name = ExportFormatter.fileName(title: thread.title, id: thread.id, taken: &taken)
                let path = directory + "/" + name
                try content.write(toFile: path, atomically: true, encoding: .utf8)
                report.written += 1
                report.files.append(path)
                manifest.append((name, thread.title.isEmpty ? "（无标题）" : thread.title,
                                 thread.sourceKind.displayName, ExportFormatter.redactedCount(items),
                                 items.count))
            } catch {
                report.failed += 1
                report.failures.append((id, "\(error)"))
            }
        }

        if !manifest.isEmpty {
            var index = "# 导出清单\n\n共 \(report.written) 个会话。\n\n"
            index += "| 文件 | 标题 | 来源 | 记录 | 遮蔽 |\n| --- | --- | --- | --- | --- |\n"
            for m in manifest {
                index += "| [\(m.file)](\(m.file)) | \(m.title.replacingOccurrences(of: "|", with: "、")) | \(m.source) | \(m.items) | \(m.masked) |\n"
            }
            try? index.write(toFile: directory + "/index.md", atomically: true, encoding: .utf8)
        }
        return report
    }
}
