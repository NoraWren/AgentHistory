import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "ui"

func makeStore() throws -> Store {
    try Store()
}

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
    let query = args.dropFirst().joined(separator: " ")
    guard !query.isEmpty else { print("用法：AgentHistory search <关键词>"); exit(2) }
    let store = try makeStore()
    let hits = try store.search(query)
    for hit in hits {
        print("[\(hit.sourceKind.displayName)] \(hit.threadTitle)")
        print("  \(hit.text.replacingOccurrences(of: "\n", with: " ").prefix(120))")
    }
    print("共 \(hits.count) 条")

case "mcp":
    runMCP()

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
    guard args.count >= 2 else { print("用法：AgentHistory items <thread_id> [after_ordinal]"); exit(2) }
    let store = try makeStore()
    let after = args.count > 2 ? Int(args[2]) ?? -1 : -1
    let rows = try store.items(threadId: args[1], afterOrdinal: after, limit: 200)
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
      AgentHistory search     检索历史
      AgentHistory mcp        以 stdio MCP 运行
    """)
}
