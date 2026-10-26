import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "ui"

func makeStore() throws -> Store {
    try Store()
}

/// 状态里带的登记位置，JSON 输出用。
func registrationLocation(_ state: MCPClientState) -> String {
    switch state {
    case let .connected(_, _, location, _): return location
    case let .pluginInstalled(_, location): return location
    default: return ""
    }
}

func fmtBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// 所有子命令都在这里执行，顶层统一把错误翻译成一句中文再退出，
/// 避免路径没权限时抛 Swift fatal error 把调用方埋在一堆 domain code 里。
func runMain() throws {
switch command {
case "ui", "--ui":
    runUI()

case "sync":
    let store = try makeStore()
    let engine = SyncEngine(store: store)
    let summary = try engine.sync { fraction, phase in
        FileHandle.standardError.write(Data(("\r\(Int(fraction * 100))% \(phase)          ").utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))
    print("新增会话 \(summary.insertedThreads)，新增条目 \(summary.insertedItems)，耗时 \(String(format: "%.1f", summary.duration)) 秒")
    for (name, count) in summary.perSource.sorted(by: { $0.key < $1.key }) {
        print("  \(name)：\(count) 条")
    }
    for e in summary.errors { print("  错误：\(e)") }
    exit(summary.errors.isEmpty ? 0 : 1)

case "stats":
    let store = try makeStore()
    let s = try store.stats()
    let sources = try store.sources()
    print("会话 \(s.threadCount)  条目 \(s.itemCount)  项目 \(s.projectCount)  今日 \(s.todayItems)")
    print("库文件 \(store.dbSizeBytes()) 字节")
    for src in sources {
        print("  \(src.kind.displayName)：\(src.available ? "可用" : "不可用")  \(src.threadCount) 会话  \(src.lastError ?? "")")
    }

case "search":
    var options = SearchOptions()
    options.limit = 60
    var words: [String] = []
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--source":
            i += 1
            // 写错来源时早先直接跳过，检索照旧跑全库，看起来「筛了但没筛住」。
            if i < args.count, let kind = SourceKind(rawValue: args[i]) {
                options.sourceKind = kind
            } else if i < args.count {
                let allowed = SourceKind.allCases.map(\.rawValue).joined(separator: " / ")
                FileHandle.standardError.write(Data("--source \(args[i]) 不认识，只能用 \(allowed)\n".utf8))
                exit(2)
            } else {
                FileHandle.standardError.write(Data("--source 后面要跟一个来源\n".utf8))
                exit(2)
            }
        case "--project":
            i += 1
            if i < args.count { options.projectPath = args[i] }
        case "--days":
            i += 1
            if i < args.count, let d = Int(args[i]) {
                if d > 0 {
                    options.since = Int64((Date().timeIntervalSince1970 - Double(d) * 86400) * 1000)
                } else {
                    FileHandle.standardError.write(Data("--days \(d) 不是正数，没法按天筛，按不限时间算\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("--days 后面要跟一个整数\n".utf8))
            }
        case "--limit":
            i += 1
            // 检索层会把 0 和负数夹到 1，这里提前说一声，别让人以为写了 0 就真返回 0 条。
            if i < args.count, let n = Int(args[i]) {
                if n > 0 {
                    options.limit = n
                } else {
                    FileHandle.standardError.write(Data("--limit \(n) 不是正数，按 1 条算\n".utf8))
                    options.limit = 1
                }
            } else {
                FileHandle.standardError.write(Data("--limit 后面要跟一个整数\n".utf8))
            }
        case "--asked":
            options.onlyUser = true
        case "--all":
            options.mergeCopies = false
        case "--scope":
            i += 1
            // 写错范围不能悄悄退回只看会话：调用方以为查了记忆，得到的「没有命中」是假的。
            if i < args.count, let scope = SearchScope(rawValue: args[i]) {
                options.scope = scope
            } else if i < args.count {
                let allowed = SearchScope.allCases.map(\.rawValue).joined(separator: " / ")
                FileHandle.standardError.write(Data("--scope \(args[i]) 不认识，只能用 \(allowed)\n".utf8))
                exit(2)
            } else {
                FileHandle.standardError.write(Data("--scope 后面要跟 threads / memory / all\n".utf8))
                exit(2)
            }
        default:
            words.append(args[i])
        }
        i += 1
    }
    let query = words.joined(separator: " ")
    guard !query.isEmpty else {
        print("用法：AgentHistory search <关键词> [--source codex] [--project 路径] [--days 7] [--asked] [--all] [--scope threads|memory|all] [--limit 60]")
        exit(2)
    }
    let store = try makeStore()
    let hits = try store.search(query, options: options)
    for hit in hits {
        var marks: [String] = [hit.matchKind]
        if hit.groupHits > 1 { marks.append("命中 \(hit.groupHits) 处") }
        if hit.copyCount > 0 { marks.append("另有 \(hit.copyCount) 处副本") }
        if hit.isMemory {
            print("[\(hit.kindLabel)] \(hit.threadTitle)  （\(marks.joined(separator: "·"))）")
            print("  memory_id=\(hit.memoryId ?? "")")
        } else {
            print("[\(hit.sourceKind.displayName)] \(hit.threadTitle)  （\(marks.joined(separator: "·"))）")
            print("  thread_id=\(hit.threadId)（命中在 \(hit.targetThreadId)）")
        }
        print("  \(hit.text.replacingOccurrences(of: "\n", with: " ").prefix(120))")
    }
    print("共 \(hits.count) 条")

case "memory-backfill":
    // 早于索引功能产生的交接包与汇编只能靠这一遍补进检索。
    let store = try makeStore()
    let report = try store.backfillMemory()
    print("补录完成：新增 \(report.added) 份，跳过 \(report.skipped) 份，清掉 \(report.removed) 份失效索引")
    let total = try store.db.scalarInt("SELECT COUNT(*) FROM memory_docs WHERE kind IN ('handoff','digest')")
    print("索引里现在有 \(total) 份文件类记忆")

case "rebuild-lineage":
    let store = try makeStore()
    let report = try LineageBuilder.rebuild(store: store)
    print(report.summary)
    print("条目 \(report.itemsBefore) → \(report.itemsAfter)，检索索引 \(report.docsBefore) → \(report.docsAfter)")
    for (reason, count) in report.skippedReasons.sorted(by: { $0.value > $1.value }) {
        print("  跳过：\(reason) \(count) 条")
    }
    exit(report.itemsBefore == report.itemsAfter && report.docsBefore == report.docsAfter ? 0 : 1)

case "lineage":
    guard args.count >= 2 else { print("用法：AgentHistory lineage <会话ID>"); exit(2) }
    let store = try makeStore()
    guard let info = try store.lineage(threadId: args[1]) else {
        print("这个会话没有副本"); exit(0)
    }
    for m in info.members {
        let tag = m.isRepresentative ? "原创" : "副本"
        print("\(tag)  [\(m.sourceKind.displayName)] \(m.title)")
        print("   \(m.id)  \(m.relationLabel)  \(m.direction)  \(m.itemCount) 条")
        if !m.targetRef.isEmpty { print("   目标内标识：\(m.targetRef)") }
    }

case "export":
    var ids: [String] = []
    var dir = Store.defaultRoot + "/exports"
    var i = 1
    while i < args.count {
        if args[i] == "--out" {
            i += 1
            if i < args.count { dir = args[i] }
        } else {
            ids.append(args[i])
        }
        i += 1
    }
    let store = try makeStore()
    if ids.isEmpty {
        print("用法：AgentHistory export <会话ID>... [--out 目录]"); exit(2)
    }
    let report = Exporter.export(store: store, threadIds: ids, directory: dir)
    print(report.summary)
    for f in report.files { print("  \(f)") }
    for f in report.failures { print("  失败：\(f.title) — \(f.reason)") }
    exit(report.failed == 0 ? 0 : 1)

case "mcp":
    runMCP()

case "mcp-status":
    // 默认只列一行一句话；--json 给脚本用。
    var asJSON = false
    var timeout = MCPHandshake.defaultTimeout
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--json": asJSON = true
        case "--timeout":
            i += 1
            if i < args.count, let t = Int(args[i]), t > 0 { timeout = t }
        default: break
        }
        i += 1
    }
    let reports = MCPOnboarding.inspectAll(timeout: timeout)
    if asJSON {
        let rows: [[String: Any]] = reports.map { report in
            [
                "client": report.target.kind.rawValue,
                "name": report.displayName,
                "style": report.styleLabel,
                "state": report.state.label,
                "ok": report.state.isUsable,
                "failure": report.state.isFailure,
                "fixable": report.state.isFixable,
                "reason": report.reason,
                "tools": report.state.toolCount,
                "path": report.configPath,
                "location": registrationLocation(report.state),
            ]
        }
        let payload: [String: Any] = [
            "checked_at": ISO8601DateFormatter().string(from: Date()),
            "binary": MCPTargetRegistry.currentBinary(),
            "all_ok": reports.allSatisfy { !$0.state.isFailure },
            "clients": rows,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
    } else {
        for report in reports {
            let mark: String
            switch report.state {
            case .connected: mark = "通过"
            case .pluginInstalled: mark = "插件"
            case .notInstalled: mark = "未装"
            case .notConfigured: mark = "未接"
            case .pluginMissing: mark = "未装"
            case .connectFailed, .broken: mark = "失败"
            }
            print("\(mark)  \(report.displayName)（\(report.styleLabel)）")
            print("      \(report.state.label)：\(report.reason)")
            if report.target.style == .config || report.target.style == .command {
                print("      登记：\(report.configPath)")
            }
        }
        let failures = reports.filter { $0.state.isFailure }
        let usable = reports.filter { $0.state.isUsable }.count
        print("共 \(reports.count) 个客户端，\(usable) 个可用" + (failures.isEmpty ? "" : "，\(failures.count) 个需要处理"))
        if !failures.isEmpty {
            print("修复失效路径：AgentHistory mcp-repair")
        }
    }
    exit(reports.contains(where: { $0.state.isFailure }) ? 1 : 0)

case "mcp-connect", "mcp-disconnect":
    let action: MCPOnboarder.Action = command == "mcp-connect" ? .connect : .disconnect
    guard args.count >= 2 else {
        print("用法：AgentHistory \(command) <客户端> [--dry-run]")
        print("客户端：\(MCPTargetRegistry.allNames)")
        exit(2)
    }
    guard let target = MCPTargetRegistry.parse(args[1]) else {
        print("不认识 \(args[1])，可用：\(MCPTargetRegistry.allNames)")
        exit(2)
    }
    let dryRun = args.contains("--dry-run")
    do {
        if dryRun {
            let preview = try MCPOnboarder.preview(target, action: action)
            print(preview.summary)
            print("目标：\(preview.paths.joined(separator: "、"))")
            if let line = preview.commandLine {
                print("命令：\(line)")
            } else {
                print("--- 改动前 ---")
                print(preview.before)
                print("--- 改动后 ---")
                print(preview.after)
            }
            exit(0)
        }
        let result = try MCPOnboarder.perform(target, action: action)
        print(result.message)
        if let backup = result.backupPath, !backup.isEmpty {
            print("原文件已备份：\(backup)")
        }
        if target.style == .command {
            print("命令式接入由 \(target.displayName) 自己维护配置，重开一次客户端生效")
        } else if result.ok {
            print("重启 \(target.displayName) 后新开的会话即可调用 search_threads")
        }
        exit(result.ok ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data(("失败：" + MCPOnboarder.describe(error) + "\n").utf8))
        exit(1)
    }

case "mcp-repair":
    // 应用被挪过位置、或者升了级却还指着旧包，登记里写的都不是当前这份程序。
    // 这里一次改完，再握手确认。
    let dryRun = args.contains("--dry-run")
    let reports = MCPOnboarding.inspectAll()
    let items = MCPOnboarder.repairable(reports: reports)
    guard !items.isEmpty else {
        print("登记都对得上当前程序（" + MCPTargetRegistry.currentBinary() + "），不需要修")
        for report in reports where report.state.isFailure {
            print("  仍有问题：\(report.displayName) —— \(report.reason)")
        }
        exit(0)
    }
    print("有 \(items.count) 个登记要改回当前程序：")
    for item in items {
        let exists = FileManager.default.fileExists(atPath: item.oldBinary)
        print("  \(item.target.displayName)：\(item.oldBinary)" + (exists ? "（旧版本）" : "（文件已不在）"))
    }
    if dryRun {
        print("这只是预演，没有改动任何文件。去掉 --dry-run 才会写入。")
        exit(0)
    }
    let results = MCPOnboarder.repair(items: items)
    for result in results {
        print(result.message)
        if let backup = result.backupPath, !backup.isEmpty { print("  备份：\(backup)") }
    }
    exit(results.allSatisfy(\.ok) ? 0 : 1)

case "mcp-snippet":
    let names = args.count > 1 ? [args[1]] : []
    if names.isEmpty {
        for target in MCPTargetRegistry.all() {
            print("# \(target.displayName)（\(target.style.label)）")
            print(MCPOnboarder.snippet(target))
            print("")
        }
    } else {
        guard let target = MCPTargetRegistry.parse(names[0]) else {
            print("不认识 \(names[0])，可用：\(MCPTargetRegistry.allNames)")
            exit(2)
        }
        print(MCPOnboarder.snippet(target))
    }

case "models":
    // 换一台机器先看这个：装了什么、该填什么命令，不用猜。
    let hits = LLMDetector.detect(force: true)
    if hits.isEmpty {
        print("没探测到模型命令行。可以装 Claude Code 或 Codex，也可以用 --api 直接接接口。")
        print("接口需要：地址（到 /v1）、模型名，密钥可留空读环境变量。")
    } else {
        print("本机探测到 \(hits.count) 个：")
        for hit in hits {
            print("  \(hit.preset.label)")
            print("    路径：\(hit.path)")
            print("    命令：\(hit.preset.command)")
            print("    说明：\(hit.preset.note)")
        }
    }
    for name in LLMAPI.keyVariables {
        let has = !(ProcessInfo.processInfo.environment[name] ?? "").isEmpty
        print("环境变量 \(name)：\(has ? "已设置" : "没设置")")
    }
    // 界面上填过的接口配置，命令行这边也要看得见，省得靠记忆猜上次填了什么。
    let saved = LLMSettings.load()
    let savedBase = saved.base
    let savedModel = saved.model
    let savedKey = saved.apiKey
    if savedBase.isEmpty, savedModel.isEmpty {
        print("已存的接口配置：还没填过")
    } else {
        print("已存的接口配置：\(savedBase.isEmpty ? "（地址空）" : savedBase) · \(savedModel.isEmpty ? "（模型名空）" : savedModel) · 密钥\(savedKey.isEmpty ? "没存" : "已存")")
    }

case "digest-clean":
    // 清掉汇编调用模型时被同步进来的假会话；只认工作目录，不动真实对话。
    let store = try makeStore()
    let removed = try store.purgeDigestScratch()
    print(removed == 0 ? "库里没有汇编临时会话" : "库里清掉 \(removed) 个汇编临时会话")
    // claude 不给会话持久化也会建空的项目目录，顺带扫一遍。
    let swept = ScratchCleaner.clean()
    for root in swept.roots { print("扫了 \(root)：\(swept.summary)") }
    print(DigestWorkspace.purge(storeRoot: store.root).summary)
    let cached = DigestCache.purge(storeRoot: store.root)
    if cached.count > 0 {
        print("清掉 \(cached.count) 份提炼缓存，腾出 "
              + ByteCountFormatter.string(fromByteCount: cached.bytes, countStyle: .file))
    } else {
        print("没有提炼缓存")
    }

case "backups":
    // 传输前的备份只增不减，本机到过 774 MB。default 是看用量，prune 按时间留最近几份。
    let store = try makeStore()
    let action = args.count > 1 ? args[1] : "show"
    switch action {
    case "prune":
        let keep = args.count > 2 ? (Int(args[2]) ?? 5) : 5
        guard keep >= 1 else {
            print("要保留至少 1 份，收到 \(keep)")
            exit(2)
        }
        let before = WriteSupport.backupUsage(storeRoot: store.root)
        let result = WriteSupport.pruneBackups(storeRoot: store.root, keep: keep)
        let after = WriteSupport.backupUsage(storeRoot: store.root)
        if result.removed == 0 {
            print("没有可清的：自动备份 \(before.prunable) 份，没超过保留的 \(keep) 份")
            if before.manual > 0 {
                print("另有 \(before.manual) 份手工断点没动；整个目录 \(before.count) 份、\(fmtBytes(before.bytes))")
            }
        } else {
            print("清掉 \(result.removed) 份备份，腾出 \(fmtBytes(result.bytes))")
            print("现在 \(after.count) 份、\(fmtBytes(after.bytes))")
            if after.manual > 0 {
                print("其中 \(after.manual) 份是手工断点，没动")
            }
        }
    case "show", "":
        let usage = WriteSupport.backupUsage(storeRoot: store.root)
        print("\(usage.count) 份备份，共 \(fmtBytes(usage.bytes))")
        print("目录：\(store.root)/backups")
        if usage.manual > 0 {
            print("其中 \(usage.manual) 份是手工断点（名字不是时间戳），prune 不会动，要删得自己删")
        }
        print("自动备份现有 \(usage.prunable) 份；只留最近 5 份：AgentHistory backups prune 5")
    default:
        print("用法：AgentHistory backups [show|prune 份数]")
        exit(2)
    }

case "digest":
    var options = DigestOptions()
    var i = 1
    var printOnly = false
    while i < args.count {
        switch args[i] {
        case "--days":
            i += 1
            // 0 和负数当默认值处理，但要说一声：否则参数没生效，输出看起来跟没传一样。
            if i < args.count, let d = Int(args[i]) {
                if d > 0 {
                    options.since = Int64((Date().timeIntervalSince1970 - Double(d) * 86400) * 1000)
                } else {
                    FileHandle.standardError.write(Data("--days \(d) 不是正数，按默认 7 天算\n".utf8))
                }
            } else {
                FileHandle.standardError.write(Data("--days 后面要跟一个整数\n".utf8))
            }
        case "--source":
            i += 1
            if i < args.count, let kind = SourceKind(rawValue: args[i]) {
                options.sourceKind = kind
            } else if i < args.count {
                let allowed = SourceKind.allCases.map(\.rawValue).joined(separator: " / ")
                FileHandle.standardError.write(Data("--source \(args[i]) 不认识，只能用 \(allowed)\n".utf8))
                exit(2)
            } else {
                FileHandle.standardError.write(Data("--source 后面要跟一个来源\n".utf8))
                exit(2)
            }
        case "--project":
            i += 1
            if i < args.count { options.projectPath = args[i] }
        case "--command":
            i += 1
            if i < args.count { options.command = args[i] }
        case "--timeout":
            i += 1
            if i < args.count, let t = Double(args[i]) { options.timeout = t }
        case "--parallel":
            i += 1
            if i < args.count, let n = Int(args[i]), n > 0 {
                options.parallel = n
            } else {
                FileHandle.standardError.write(Data("--parallel 要是正整数，按默认 \(options.parallel) 路算\n".utf8))
            }
        case "--title":
            i += 1
            if i < args.count { options.title = args[i] }
        case "--out":
            i += 1
            if i < args.count { options.outputDirectory = args[i] }
        case "--no-llm":
            options.useLLM = false
        case "--no-cache":
            options.useCache = false
        case "--api":
            // 不装任何 CLI 时用接口：--api https://api.openai.com/v1 gpt-4o-mini [密钥]
            let rest = args.dropFirst(i + 1)
            guard rest.count >= 2 else {
                print("用法：--api <地址> <模型名> [密钥]"); exit(2)
            }
            let base = rest[rest.startIndex]
            let name = rest[rest.startIndex + 1]
            var key = ""
            if rest.count >= 3, !rest[rest.startIndex + 2].hasPrefix("--") {
                key = rest[rest.startIndex + 2]
                i += 1
            }
            options.api = LLMAPI(baseURL: base, model: name, apiKey: key)
            options.command = ""
            i += 2
        case "--print":
            // 只把正文打到标准输出，便于管道接别的工具。
            printOnly = true
        default:
            break
        }
        i += 1
    }
    let store = try makeStore()
    let result = DigestRunner.run(store: store, options: options) { phase in
        FileHandle.standardError.write(Data(("\r\(phase)          ").utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))
    guard !result.isEmpty else {
        print(result.note.isEmpty ? "没有可汇编的对话" : result.note)
        exit(1)
    }
    if printOnly {
        print(result.markdown)
    } else {
        print(result.markdown)
        print("---")
        print(result.note)
        if !result.path.isEmpty { print("已保存：\(result.path)") }
    }

case "plan":
    guard args.count >= 3, let src = SourceKind(rawValue: args[1]), let dst = SourceKind(rawValue: args[2]) else {
        print("用法：AgentHistory plan <来源> <目标>  来源/目标：codex claude workbuddy opencode kimi deepseek"); exit(2)
    }
    let store = try makeStore()
    let plan = try TransferPlanner.plan(store: store, source: src, target: dst)
    print("方式：\(plan.mode.rawValue)")
    print("会话：\(plan.threadIDs.count)  消息：\(plan.messageCount)  重复：\(plan.duplicateCount)  遮蔽：\(plan.redactedCount)")
    print("目标：\(plan.targetPath)")
    for n in plan.notes { print("提示：\(n)") }

case "transfer":
    guard args.count >= 3, let src = SourceKind(rawValue: args[1]), let dst = SourceKind(rawValue: args[2]) else {
        print("用法：AgentHistory transfer <来源> <目标> [线程ID]"); exit(2)
    }
    let store = try makeStore()
    let explicit = args.count > 3 ? [args[3]] : []
    let plan = try TransferPlanner.plan(store: store, source: src, target: dst, threadIDs: explicit)
    print("\(plan.mode.rawValue)：\(plan.threadIDs.count) 条会话，\(plan.messageCount) 条消息，重复 \(plan.duplicateCount)")
    let result = try TransferRunner(store: store).execute(plan: plan) { fraction, phase in
        FileHandle.standardError.write(Data(("\r\(Int(fraction * 100))% \(phase)          ").utf8))
    }
    FileHandle.standardError.write(Data("\n".utf8))
    print(result.detail)
    print("成功 \(result.written)  跳过 \(result.skipped)  失败 \(result.failed)")
    for a in result.artifacts.prefix(3) { print("  \(a)") }

case "verify":
    let store = try makeStore()
    var failures = 0
    for src in try store.sources() where src.available {
        let threads = try store.db.scalarInt("SELECT COUNT(*) FROM threads WHERE source_id=?", [src.id])
        let items = try store.db.scalarInt("""
            SELECT COUNT(*) FROM items i JOIN threads t ON t.id=i.thread_id WHERE t.source_id=?
            """, [src.id])
        let ok = threads > 0 && items > 0
        if !ok { failures += 1 }
        print("\(ok ? "通过" : "失败")  \(src.kind.displayName)：\(threads) 个会话，\(items) 条记录")
    }
    print(failures == 0 ? "适配器契约检查通过" : "有 \(failures) 个来源未通过")
    exit(failures == 0 ? 0 : 1)

case "repair-workbuddy":
    let store = try makeStore()
    let n = try WorkBuddyRegistry.backfill(store: store)
    print("已把 \(n) 条已写入的会话登记到 WorkBuddy 的会话表")
    print("启动 WorkBuddy 后按项目查看；若仍未出现，先退出再重启一次")

case "items":
    guard args.count >= 2 else { print("用法：AgentHistory items <thread_id> [after_ordinal|@ordinal]"); exit(2) }
    let store = try makeStore()
    let rows: [ItemRow]
    if args.count > 2, args[2].hasPrefix("@"), let at = Int(args[2].dropFirst()) {
        if let position = try store.itemPosition(threadId: args[1], ordinal: at, itemId: nil) {
            rows = try store.itemsPage(threadId: args[1], offset: position)
        } else {
            rows = []
        }
    } else {
        let after = args.count > 2 ? Int(args[2]) ?? -1 : -1
        rows = try store.items(threadId: args[1], afterOrdinal: after, limit: 200)
    }
    for r in rows.prefix(5) {
        print("\(r.ordinal) [\(r.itemType)] \(r.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
    }
    print("本页 \(rows.count) 条；最后序号 \(rows.last?.ordinal ?? -1)")

case "selftest":
    print("请运行 .build/agent-history-tests")

default:
    print("""
    Agent 记忆
      AgentHistory            打开界面
      AgentHistory sync       同步全部可用来源
      AgentHistory stats      查看统计
      AgentHistory search     检索历史（支持 --source/--project/--days/--asked/--all）
                              --scope threads|memory|all 连交接包、汇编与结论一起查
      AgentHistory memory-backfill  把已有的交接包与汇编补进检索索引
      AgentHistory rebuild-lineage  重建副本血缘
      AgentHistory lineage    查看某会话的副本
      AgentHistory export     导出会话为 Markdown
      AgentHistory mcp        以 stdio MCP 运行
      AgentHistory mcp-status 看六个客户端谁接上了（--json 给脚本用）
      AgentHistory mcp-connect <客户端>    一键接入（--dry-run 先看改动）
      AgentHistory mcp-disconnect <客户端> 移除本服务的登记
      AgentHistory mcp-repair 把失效的路径一次改回当前程序
      AgentHistory mcp-snippet [客户端]    生成手工粘贴用的配置片段
      AgentHistory digest     按天汇编一段时间的对话（默认接 claude -p 提炼）
                              --days 7 --source codex --project 路径 --no-llm
                              --command "claude -p --no-session-persistence" --timeout 600 --parallel 5
                              --api https://api.openai.com/v1 gpt-4o-mini [密钥]
                              --out 目录 --title 标题 --print
      AgentHistory models     看本机探测到哪些模型命令行，以及各自该用什么参数
      AgentHistory digest-clean  清掉汇编调用模型时留下的临时会话和空的项目目录
      AgentHistory backups    看传输前备份占了多少（prune [份数] 只留最近几份）
    """)
}
}

do {
    try runMain()
} catch {
    FileHandle.standardError.write(Data(("错误：" + ClaudeWriter.describe(error) + "\n").utf8))
    exit(1)
}

