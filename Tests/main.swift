import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String) {
    if cond { print("  ok  \(name)") }
    else { print("  FAIL \(name)"); failures += 1 }
}

print("中文切词")
let tokens = TextTools.segment("我的止损线是3000元，跨境电商试水")
check(tokens.contains("止") && tokens.contains("损") && tokens.contains("线"), "汉字拆成单字")
check(tokens.contains("3000"), "数字保留整词")
check(TextTools.makeMatchQuery("止损线") == "\"止\" \"损\" \"线\"", "中文查询生成短语")
check(TextTools.makeMatchQuery("thread_history 3000").contains("AND"), "中英混合查询用 AND 连接")

print("脱敏")
let secret = "key=sk-abcdefghijklmnopqrstuvwxyz012345 普通文本保留"
let masked = Redactor.mask(secret)
check(masked.hits == 1, "命中一条密钥")
check(!masked.text.contains("abcdefghijklmnopqrstuvwxyz012345"), "密钥中段被遮蔽")
check(masked.text.contains("普通文本保留"), "普通文本不被改写")
let plain = Redactor.mask("这只是普通的一句话，没有密钥")
check(plain.hits == 0 && plain.text == "这只是普通的一句话，没有密钥", "无密钥文本原样返回")

print("数据库与检索")
let tmp = NSTemporaryDirectory() + "agent-history-test-\(UUID().uuidString)"
do {
    let store = try Store(root: tmp)
    try store.registerSource(.codex, available: true)
    let threadId = try store.upsertThread(ThreadInput(
        sourceId: "codex", nativeId: "t1", projectPath: "/tmp/demo",
        title: "止损线讨论", createdAt: 1_700_000_000_000, updatedAt: 1_700_000_100_000,
        model: "gpt", threadSource: "user", archived: false, preview: "讨论止损"))
    try store.upsertItems(threadId: threadId, items: [
        ItemInput(nativeId: "i1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_050_000, text: "我的止损线是3000元，跨境电商试水", rawJSON: "{}"),
        ItemInput(nativeId: "i2", ordinal: 2, itemType: "agentMessage", role: "assistant",
                  createdAt: 1_700_000_060_000, text: "收到，先记下这个止损线", rawJSON: "{}"),
    ])
    let hits = try store.search("止损线")
    check(hits.count == 2, "三字中文检索命中两条")
    let two = try store.search("止损")
    check(two.count == 2, "两字中文检索命中")
    let latin = try store.search("3000")
    check(latin.count == 1, "数字检索命中")
    let none = try store.search("不存在词")
    check(none.isEmpty, "无关查询不命中")
    let items = try store.items(threadId: threadId)
    check(items.count == 2 && items[0].ordinal == 1, "条目按序号返回")
    let again = try store.upsertItems(threadId: threadId, items: [
        ItemInput(nativeId: "i1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_050_000, text: "我的止损线是3000元，跨境电商试水", rawJSON: "{}")
    ])
    check(again.inserted == 0, "重复写入不新增条目")
    check(try store.search("止损线").count == 2, "重复写入不产生重复检索结果")
} catch {
    print("  FAIL 数据库用例：\(error)")
    failures += 1
}

print("Kimi Code 适配器")
do {
    let root = NSTemporaryDirectory() + "agent-history-kimi-\(UUID().uuidString)"
    let kimiHome = root + "/.kimi-code"
    let sessionDir = kimiHome + "/sessions/ws-alpha/sess-001"
    let agentsDir = sessionDir + "/agents/main"
    try FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
    let state = """
    {"version":2,"id":"sess-001","workspaceId":"ws-alpha","cwd":"/tmp/kimi-project","title":"Kimi 记忆共享","createdAt":1700000000000,"updatedAt":1700000500000,"archived":false}
    """
    try state.write(toFile: sessionDir + "/state.json", atomically: true, encoding: .utf8)
    let wirePath = agentsDir + "/wire.jsonl"
    let line1 = """
    {"type":"metadata","protocol_version":"1.5","created_at":1700000000000}
    """
    let line2 = """
    {"type":"context.append_message","agentId":"main","time":1700000001000,"message":{"id":"m1","role":"user","content":[{"type":"text","text":"我的止损线是3000元"}]}}
    """
    let line3 = """
    {"type":"context.append_message","agentId":"main","time":1700000002000,"message":{"id":"m2","role":"assistant","content":[{"type":"text","text":"记下了这个止损线"}]}}
    """
    try ([line1, line2, line3].joined(separator: "\n") + "\n").write(toFile: wirePath, atomically: true, encoding: .utf8)

    let store2 = try Store(root: root + "/store")
    let adapter = KimiAdapter(home: kimiHome)
    check(adapter.isAvailable, "发现 Kimi Code 会话目录")
    let first = try adapter.sync(into: store2) { _ in }
    check(first == 2, "首次同步写入两条消息")
    let hits = try store2.search("止损线")
    check(hits.count == 2 && hits.allSatisfy { $0.sourceKind == .kimi }, "Kimi 内容进入统一检索")
    let rows = try store2.threads(sourceKind: .kimi)
    check(rows.count == 1 && rows[0].title == "Kimi 记忆共享", "会话标题来自 state.json")
    check(rows.first?.projectPath == "/tmp/kimi-project", "项目路径来自 state.json")

    let again = try adapter.sync(into: store2) { _ in }
    check(again == 0, "重复同步不新增")

    let line4 = """
    {"type":"context.append_message","agentId":"main","time":1700000003000,"message":{"id":"m3","role":"user","content":[{"type":"text","text":"再记一条"}]}}
    """
    if let handle = FileHandle(forWritingAtPath: wirePath) {
        handle.seekToEndOfFile()
        handle.write(Data((line4 + "\n").utf8))
        try handle.close()
    }
    let third = try adapter.sync(into: store2) { _ in }
    check(third == 1, "追加消息只同步新增部分")
} catch {
    print("  FAIL Kimi 用例：\(error)")
    failures += 1
}

print("Kimi Code 原生写入")
do {
    let root = NSTemporaryDirectory() + "agent-history-kimi-write-\(UUID().uuidString)"
    let kimiHome = root + "/.kimi-code"
    try FileManager.default.createDirectory(atPath: kimiHome, withIntermediateDirectories: true)
    let workspaces = """
    {"version":1,"workspaces":{"wd_demo_0123456789ab":{"root":"/tmp/kimi-demo","name":"Demo","created_at":"2026-10-24T00:00:00.000Z","last_opened_at":"2026-10-24T00:00:00.000Z"}},"deleted_workspace_ids":[]}
    """
    try workspaces.write(toFile: kimiHome + "/workspaces.json", atomically: true, encoding: .utf8)

    let store3 = try Store(root: root + "/store")
    let tid = try store3.upsertThread(ThreadInput(
        sourceId: "codex", nativeId: "kimi-write", projectPath: "/tmp/kimi-demo-project",
        title: "交接给 Kimi", createdAt: 1_700_000_000_000, updatedAt: 1_700_000_100_000,
        model: "gpt", threadSource: "user", archived: false, preview: "你好"))
    _ = try store3.upsertItems(threadId: tid, items: [
        ItemInput(nativeId: "k1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_050_000, text: "你好，继续昨天的活", rawJSON: ""),
        ItemInput(nativeId: "k2", ordinal: 2, itemType: "agentMessage", role: "assistant",
                  createdAt: 1_700_000_060_000, text: "收到，接着说", rawJSON: "")
    ])
    guard let thread = try store3.thread(id: tid) else { throw HistoryError.message("缺少会话") }
    let plan = TransferPlan(sourceKind: .codex, targetKind: .kimi, mode: .nativeImport,
                            threadIDs: [tid], messageCount: 2, duplicateCount: 0, redactedCount: 0,
                            estimatedBytes: 20, targetPath: kimiHome + "/sessions", notes: [])
    let items = try store3.items(threadId: tid)
    let result = try KimiWriter(store: store3, home: kimiHome)
        .write(plan: plan, payloads: [(thread.id, thread.title, items)]) { _, _ in }
    check(result.written == 1 && result.failed == 0, "写入一个 Kimi 会话")

    let sessionRoot = kimiHome + "/sessions/wd_demo_0123456789ab"
    let dirs = (try? FileManager.default.contentsOfDirectory(atPath: sessionRoot)) ?? []
    check(dirs.count == 1, "生成会话目录")
    if let dir = dirs.first {
        let wire = (try? String(contentsOfFile: sessionRoot + "/" + dir + "/agents/main/wire.jsonl",
                                encoding: .utf8)) ?? ""
        check(wire.contains("agent.message.appended"), "wire 含界面事件")
        check(wire.contains("turn.prompt") && wire.contains("context.append_message"), "wire 含上下文记录")
        let stateData = try Data(contentsOf: URL(fileURLWithPath: sessionRoot + "/" + dir + "/state.json"))
        let state = (try? JSONSerialization.jsonObject(with: stateData)) as? [String: Any]
        check(state?["cwd"] as? String == "/tmp/kimi-demo-project", "state 记录项目路径")
        check(state?["title"] as? String == "交接给 Kimi", "state 记录标题")
    }
    let again = try KimiWriter(store: store3, home: kimiHome)
        .write(plan: plan, payloads: [(thread.id, thread.title, items)]) { _, _ in }
    check(again.skipped == 1 && again.written == 0, "重复同步跳过")
} catch {
    print("  FAIL Kimi 写入用例：\(error)")
    failures += 1
}

print("DeepSeek Harness 适配器")
do {
    let root = NSTemporaryDirectory() + "agent-history-dsh-\(UUID().uuidString)"
    let sessionDir = root + "/sessions/--Users-test-Desktop--/session-abc-123"
    try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
    let plain = sessionDir + "/session.jsonl"
    let lines = [
        #"{"type":"session","version":0,"id":"session-abc-123","createdAt":1789649125342,"cwd":"/tmp/dsh-project"}"#,
        #"{"type":"session/title","seq":1,"time":1789649125442,"data":{"title":"DSH 记忆"}}"#,
        #"{"type":"user/message","seq":2,"time":1789649125450,"data":{"content":[{"type":"text","text":"你好，DSH"}],"source":{"kind":"user"},"role":"user","id":"u1"}}"#,
        #"{"type":"user/message","seq":3,"time":1789649125460,"data":{"content":[{"type":"text","text":"runtime context"}],"source":{"kind":"plugin","plugin":"x"},"role":"user","id":"u2"}}"#,
        #"{"type":"assistant/message","seq":4,"time":1789649125470,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"收到 DSH 的消息"},{"type":"reasoning","text":"先确认上下文"}]}}}"#
    ]
    try (lines.joined(separator: "\n") + "\n").write(toFile: plain, atomically: true, encoding: .utf8)

    let store4 = try Store(root: root + "/store")
    let adapter = DeepSeekAdapter(home: root)
    check(adapter.isAvailable, "发现 DeepSeek 会话")
    let first = try adapter.sync(into: store4) { _ in }
    check(first == 3, "只收真实用户消息、助手回复和推理")
    let rows = try store4.threads(sourceKind: .deepseek)
    check(rows.count == 1 && rows[0].title == "DSH 记忆", "标题来自 session/title")
    check(rows.first?.projectPath == "/tmp/dsh-project", "项目路径来自 session 头")
    check(try store4.search("DSH").count >= 2, "内容进入统一检索")
    check(try adapter.sync(into: store4) { _ in } == 0, "重复同步不新增")

    if let zstd = DeepSeekAdapter.zstdPath() {
        let packed = sessionDir + "/session.jsonl.zstd"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-q", "-f", "-o", packed, plain]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            try FileManager.default.removeItem(atPath: plain)
            check(try adapter.sync(into: store4) { _ in } == 0, "压缩会话可读且不重复")
        }
    }
} catch {
    print("  FAIL DeepSeek 用例：\(error)")
    failures += 1
}

print("DeepSeek Harness 原生写入")
do {
    let root = NSTemporaryDirectory() + "agent-history-dsh-write-\(UUID().uuidString)"
    let dshHome = root + "/dsh"
    try FileManager.default.createDirectory(atPath: dshHome + "/storages", withIntermediateDirectories: true)
    let workspaces = """
    {"unit":{"name":"workspace","version":2},"global":{"initialized":true,"workspaceIds":["ws-test"],"archivedSessionIds":[]},"tables":{"workspaces":{"ws-test":{"path":"/tmp/dsh-demo","title":"dsh-demo","sessionIds":[],"createdAt":"2026-10-24T00:00:00.000Z","updatedAt":"2026-10-24T00:00:00.000Z"}}}}
    """
    try workspaces.write(toFile: dshHome + "/storages/workspace.json", atomically: true, encoding: .utf8)

    check(DSHSupport.projectDir("/Users/kongqi/PycharmProjects/易得广场") == "--Users-kongqi-PycharmProjects-~6613~5F97~5E7F~573A--", "项目目录编码")

    let store5 = try Store(root: root + "/store")
    let tid = try store5.upsertThread(ThreadInput(
        sourceId: "claude", nativeId: "dsh-write", projectPath: "/tmp/dsh-demo",
        title: "交给 DSH", createdAt: 1_700_000_000_000, updatedAt: 1_700_000_100_000,
        model: "claude", threadSource: "user", archived: false, preview: "你好"))
    _ = try store5.upsertItems(threadId: tid, items: [
        ItemInput(nativeId: "d1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_050_000, text: "你好，继续昨天的活", rawJSON: ""),
        ItemInput(nativeId: "d2", ordinal: 2, itemType: "agentMessage", role: "assistant",
                  createdAt: 1_700_000_060_000, text: "收到，接着说", rawJSON: ""),
        ItemInput(nativeId: "d3", ordinal: 3, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_070_000, text: "第二条", rawJSON: ""),
        ItemInput(nativeId: "d4", ordinal: 4, itemType: "agentMessage", role: "assistant",
                  createdAt: 1_700_000_080_000, text: "好", rawJSON: "")
    ])
    guard let thread = try store5.thread(id: tid) else { throw HistoryError.message("缺少会话") }
    let plan = TransferPlan(sourceKind: .claude, targetKind: .deepseek, mode: .nativeImport,
                            threadIDs: [tid], messageCount: 4, duplicateCount: 0, redactedCount: 0,
                            estimatedBytes: 40, targetPath: dshHome + "/sessions", notes: [])
    let items = try store5.items(threadId: tid)
    let result = try DSHWriter(store: store5, home: dshHome)
        .write(plan: plan, payloads: [(thread.id, thread.title, items)]) { _, _ in }
    check(result.written == 1 && result.failed == 0, "写入一个 DSH 会话")

    let project = dshHome + "/sessions/" + DSHSupport.projectDir("/tmp/dsh-demo")
    let dirs = (try? FileManager.default.contentsOfDirectory(atPath: project)) ?? []
    check(dirs.count == 1, "生成 v4 会话目录")
    if let sid = dirs.first {
        let file = project + "/" + sid + "/session.v4.jsonl.zstd"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: DeepSeekAdapter.zstdPath() ?? "/opt/homebrew/bin/zstd")
        process.arguments = ["-dc", file]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        check(lines.count >= 12, "会话记录数量")
        let objs = lines.compactMap { l in (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any] }
        check((objs.first?["version"] as? Int) == 4, "会话头为 v4")
        let seqs = objs.compactMap { ($0["seq"] as? NSNumber)?.intValue }
        check(seqs == Array(0..<seqs.count), "事件序号连续")
        check((objs.last?["type"] as? String) == "session/title", "标题在末尾")
        check((objs.last?["data"] as? [String: Any])?["source"] != nil, "标题带来源")
        let assistantHasUsage = objs.contains { o in
            o["type"] as? String == "assistant/message" &&
            (o["data"] as? [String: Any])?["usage"] != nil
        }
        check(!assistantHasUsage, "助手消息不带 usage")

        let wsData = try Data(contentsOf: URL(fileURLWithPath: dshHome + "/storages/workspace.json"))
        let wsRoot = (try? JSONSerialization.jsonObject(with: wsData)) as? [String: Any]
        let tables = wsRoot?["tables"] as? [String: Any]
        let ws = (tables?["workspaces"] as? [String: Any])?["ws-test"] as? [String: Any]
        check((ws?["sessionIds"] as? [String])?.contains(sid) == true, "会话登记到工作区")
    }
    let again = try DSHWriter(store: store5, home: dshHome)
        .write(plan: plan, payloads: [(thread.id, thread.title, items)]) { _, _ in }
    check(again.skipped == 1 && again.written == 0, "重复同步跳过")
} catch {
    print("  FAIL DSH 写入用例：\(error)")
    failures += 1
}

print(failures == 0 ? "全部通过" : "失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
