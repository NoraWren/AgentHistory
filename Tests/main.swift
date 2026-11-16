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
    check(hits.count == 1 && hits[0].groupHits == 2, "三字中文聚合命中一个会话两处")
    let two = try store.search("止损")
    check(two.count == 1 && two[0].groupHits == 2, "两字中文聚合命中一个会话两处")
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
    let repeatHits = try store.search("止损线")
    check(repeatHits.count == 1 && repeatHits[0].groupHits == 2, "重复写入不产生重复检索结果")

    // 时间窗的两头都要管。早先只加了 since，until 传了也没人用。
    var window = SearchOptions()
    window.since = 1_700_000_070_000
    check(try store.search("止损线", options: window).isEmpty, "since 之后才发生的命中不算")
    var before = SearchOptions()
    before.until = 1_700_000_055_000
    check(try store.search("止损线", options: before).count == 1, "until 之前的内容照常命中")
    var tooLate = SearchOptions()
    tooLate.until = 1_700_000_010_000
    check(try store.search("止损线", options: tooLate).isEmpty, "until 之后的内容被挡掉")

    // 越界参数不能把进程带走。MCP 客户端传 limit=-5 时，原来直接在 prefix 上崩了。
    var negative = SearchOptions()
    negative.limit = -5
    check(try store.search("止损线", options: negative).count == 1, "负的 limit 当一次用，不再崩")
    var zero = SearchOptions()
    zero.limit = 0
    check(try store.search("止损线", options: zero).count == 1, "limit 为 0 也给一条")
    var huge = SearchOptions()
    huge.limit = 200_000
    check(try store.search("止损线", options: huge).count == 1, "巨大的 limit 被夹住")
    // SQLite 里 LIMIT 为负等于不限，条目和会话列表都不该被一次笔误搬空。
    check(try store.items(threadId: threadId, limit: -3).count == 1, "条目列表负 limit 不变成全取")
    check((try store.threads(limit: -3)).count >= 1, "会话列表负 limit 仍能返回")

    // list_projects 早先一次把全部项目拼成文本，本机 281 个项目、两万六千字，
    // 一次调用就顶大半上下文。现在按字数封顶、支持过滤和翻页，这里把边界钉住。
    let projects = (1...300).map { i in
        ProjectRow(id: "p\(i)", path: "/tmp/proj-\(i)", name: "proj-\(i)",
                   lastActiveAt: Int64(1_700_000_000_000 - i))
    }
    func body(_ args: [String: Any]) -> String {
        let result = listProjectsResult(all: projects, arguments: args)
        let content = result["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }
    let firstPage = body([:])
    check(firstPage.hasPrefix("300 个项目"), "默认列出总数")
    check(firstPage.contains("offset=50"), "默认一页五十个，给出下一页的写法")
    check(!firstPage.contains("proj-51 "), "第一页不含第五十一个")
    let secondPage = body(["offset": 50])
    check(secondPage.contains("proj-51 "), "翻页从第五十一个接着来")
    check(secondPage.contains("只列了第 51 到 100 个"), "表头写清这一页的范围")
    let filtered = body(["query": "proj-2"])
    // proj-2、proj-20..29、proj-200..299 共 111 个，第一页按活跃度只到 proj-23x。
    check(filtered.contains("111 个项目匹配 proj-2"), "按关键词过滤，总数对得上")
    check(filtered.contains("库里共 300 个"), "过滤后仍报库内总数")
    check(!filtered.contains("proj-1 "), "过滤掉不匹配的")
    check(body(["query": "proj-2", "offset": 100]).contains("proj-29"),
          "过滤结果也能翻到后面的页")
    let tooBig = body(["limit": 999])
    check(tooBig.contains("limit 999 超出 1..500"), "超上限的 limit 会说明")
    check(body(["offset": 9999]).contains("越界"), "越界 offset 直接报错")
    check(body(["limit": "五十"]).contains("limit 要写成整数"), "类型不对的 limit 直接报错")
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
    check(hits.count == 1 && hits[0].groupHits == 2 && hits.allSatisfy { $0.sourceKind == .kimi }, "Kimi 内容进入统一检索")
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
    check(try store4.search("DSH").first?.sourceKind == .deepseek, "内容进入统一检索")
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

    // DSH 侧边栏的标题读投射缓存，先埋一份模板，导入时照着它的形状写
    let cacheDir = dshHome + "/storages/session_projcache/sessions"
    try FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    let cacheTemplate = """
    {"version":7,"record":{"identity":{},"rows":{"title":{"ver":1,"seq":0,"val":""},"titleInput":{"ver":3,"seq":0,"val":{"first":{"seq":0,"text":""}}},"sessionListMetadata":{"ver":1,"seq":0,"val":{"blank":true,"lastPromptAt":null}},"workingDirectory":{"ver":1,"seq":0,"val":""},"timeContext":{"ver":3,"seq":0,"val":{"lastMessageTime":0}},"sessionStats":{"ver":1,"seq":0,"val":{"turns":0,"steps":0,"lastTurn":0,"openStep":null,"pendingCalls":{}}},"turnOutline":{"ver":2,"seq":0,"val":{"turns":[],"draft":""}},"turnBoundary":{"ver":2,"seq":0,"val":{"openTurnStartSeq":null,"lastStepStartSeq":0,"lastTurn":0}},"agentTeam":{"ver":7,"seq":0,"val":{"id":"","tasks":[],"nextTaskNumber":1}}}}}
    """
    try cacheTemplate.write(toFile: cacheDir + "/session-seed.json", atomically: true, encoding: .utf8)

    check(DSHSupport.workspaceHome("/Users/example/Documents/Codex/2026-10-24/10-30-1-3-1-users") == "/Users/example/Documents/Codex", "一次性任务目录归到 Codex 工作区")
    check(DSHSupport.workspaceHome("/Users/example/Documents/Codex") == "/Users/example/Documents/Codex", "Codex 根目录原样保留")
    check(DSHSupport.workspaceHome("/Users/example/Documents/Gitlab知识库") == "/Users/example/Documents/Gitlab知识库", "普通项目路径不动")
    check(DSHSupport.workspaceHome("/Users/example/Projects/my-app") == "/Users/example/Projects/my-app", "普通子目录不动")

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
        let cachePath = dshHome + "/storages/session_projcache/sessions/" + sid + ".json"
        let cacheRoot = (try? JSONSerialization.jsonObject(
            with: try Data(contentsOf: URL(fileURLWithPath: cachePath)))) as? [String: Any]
        let cacheRecord = cacheRoot?["record"] as? [String: Any]
        let cacheRows = cacheRecord?["rows"] as? [String: Any] ?? [:]
        check((cacheRows["title"] as? [String: Any])?["val"] as? String == "交给 DSH", "投射缓存里带标题")
        check(((cacheRows["title"] as? [String: Any])?["seq"] as? NSNumber)?.intValue == seqs.count - 1,
              "缓存序号跟会话末尾对齐")
        let meta = (cacheRows["sessionListMetadata"] as? [String: Any])?["val"] as? [String: Any]
        check(meta?["blank"] as? Bool == false, "缓存不标成空会话")
        let outline = ((cacheRows["turnOutline"] as? [String: Any])?["val"] as? [String: Any])?["turns"] as? [[String: Any]]
        check(outline?.count == 2, "缓存里两轮轮廓")
        check((cacheRows["workingDirectory"] as? [String: Any])?["val"] as? String == "/tmp/dsh-demo",
              "缓存带工作目录")
        check((cacheRecord?["identity"] as? [String: Any])?["cwd"] as? String == "/tmp/dsh-demo",
              "缓存身份带工作目录")

    }

    // 没有对应工作区的项目要新建一个，不能挂到别的项目名下
    let otherTid = try store5.upsertThread(ThreadInput(
        sourceId: "claude", nativeId: "dsh-write-other", projectPath: "/tmp/dsh-other",
        title: "另一个项目", createdAt: 1_700_000_200_000, updatedAt: 1_700_000_300_000,
        model: "claude", threadSource: "user", archived: false, preview: "开工"))
    _ = try store5.upsertItems(threadId: otherTid, items: [
        ItemInput(nativeId: "o1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_210_000, text: "另一个项目的第一条", rawJSON: ""),
        ItemInput(nativeId: "o2", ordinal: 2, itemType: "agentMessage", role: "assistant",
                  createdAt: 1_700_000_220_000, text: "收到", rawJSON: "")
    ])
    guard let otherThread = try store5.thread(id: otherTid) else { throw HistoryError.message("缺少会话") }
    let otherPlan = TransferPlan(sourceKind: .claude, targetKind: .deepseek, mode: .nativeImport,
                                 threadIDs: [otherTid], messageCount: 2, duplicateCount: 0, redactedCount: 0,
                                 estimatedBytes: 20, targetPath: dshHome + "/sessions", notes: [])
    let otherItems = try store5.items(threadId: otherTid)
    let otherResult = try DSHWriter(store: store5, home: dshHome)
        .write(plan: otherPlan, payloads: [(otherThread.id, otherThread.title, otherItems)]) { _, _ in }
    check(otherResult.written == 1, "另一个项目写入成功")
    let otherProject = dshHome + "/sessions/" + DSHSupport.projectDir("/tmp/dsh-other")
    let otherDirs = (try? FileManager.default.contentsOfDirectory(atPath: otherProject)) ?? []
    check(otherDirs.count == 1, "写入自己的项目目录")
    let wsData2 = try Data(contentsOf: URL(fileURLWithPath: dshHome + "/storages/workspace.json"))
    let wsRoot2 = (try? JSONSerialization.jsonObject(with: wsData2)) as? [String: Any]
    let all2 = ((wsRoot2?["tables"] as? [String: Any])?["workspaces"] as? [String: Any]) ?? [:]
    let created = all2.first { (($0.value as? [String: Any])?["path"] as? String) == "/tmp/dsh-other" }
    check(created != nil, "没有就按项目路径新建工作区")
    if let created {
        check((created.value as? [String: Any])?["title"] as? String == "dsh-other", "工作区名字取项目目录名")
        let ids = (created.value as? [String: Any])?["sessionIds"] as? [String]
        check(ids?.contains(otherDirs.first ?? "") == true, "新会话登记到新工作区")
        let listed = (wsRoot2?["global"] as? [String: Any])?["workspaceIds"] as? [String]
        check(listed?.contains(created.key) == true, "新工作区进侧边栏")
    }
    if let dirName = otherDirs.first {
        let z = Process()
        z.executableURL = URL(fileURLWithPath: DeepSeekAdapter.zstdPath() ?? "/opt/homebrew/bin/zstd")
        z.arguments = ["-dc", otherProject + "/" + dirName + "/session.v4.jsonl.zstd"]
        let p = Pipe()
        z.standardOutput = p
        z.standardError = FileHandle.nullDevice
        try z.run()
        let out = p.fileHandleForReading.readDataToEndOfFile()
        try? p.fileHandleForReading.close()
        z.waitUntilExit()
        let first = String(decoding: out, as: UTF8.self).split(separator: "\n").first ?? ""
        let header = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any]
        check(header?["cwd"] as? String == "/tmp/dsh-other", "会话头带自己的项目路径")
    }
    let again = try DSHWriter(store: store5, home: dshHome)
        .write(plan: plan, payloads: [(thread.id, thread.title, items)]) { _, _ in }
    check(again.skipped == 1 && again.written == 0, "重复同步跳过")
} catch {
    print("  FAIL DSH 写入用例：\(error)")
    failures += 1
}

print("取消回滚与校验失败恢复")
do {
    let root = NSTemporaryDirectory() + "agent-history-rollback-\(UUID().uuidString)"
    let store = try Store(root: root + "/store")
    func makeThread(_ name: String, project: String, userOnly: Bool = true) throws -> String {
        let id = try store.upsertThread(ThreadInput(
            sourceId: "claude", nativeId: name, projectPath: project,
            title: name, createdAt: 1_700_000_000_000, updatedAt: 1_700_000_100_000,
            model: "claude", threadSource: "user", archived: false, preview: name))
        var inputs: [ItemInput] = []
        if userOnly {
            inputs.append(ItemInput(nativeId: name + "-u", ordinal: 1, itemType: "userMessage", role: "user",
                                    createdAt: 1_700_000_050_000, text: "继续做 \(name)", rawJSON: ""))
        }
        inputs.append(ItemInput(nativeId: name + "-a", ordinal: 2, itemType: "agentMessage", role: "assistant",
                                createdAt: 1_700_000_060_000, text: "好的", rawJSON: ""))
        _ = try store.upsertItems(threadId: id, items: inputs)
        return id
    }
    let a = try makeThread("回滚甲", project: "/tmp")
    let b = try makeThread("回滚乙", project: "/tmp")
    let projects = root + "/claude-projects"
    // 写入器默认读环境变量，这里指到临时目录，避免碰到真实的 ~/.claude/projects。
    setenv("AGENT_HISTORY_CLAUDE_PROJECTS", projects, 1)
    defer { unsetenv("AGENT_HISTORY_CLAUDE_PROJECTS") }

    // 1. 取消：已写入的文件与同步记录都要撤销
    var plan = TransferPlan(sourceKind: .claude, targetKind: .claude, mode: .nativeImport,
                            threadIDs: [a, b], messageCount: 4, duplicateCount: 0, redactedCount: 0,
                            estimatedBytes: 40, targetPath: projects, notes: [])
    var calls = 0
    var cancelled = false
    do {
        _ = try TransferRunner(store: store).execute(plan: plan, shouldCancel: { calls += 1; return calls > 1 }) { _, _ in }
    } catch {
        cancelled = true
    }
    check(cancelled, "写入阶段取消会中断同步")
    let leftFiles = ((try? FileManager.default.subpathsOfDirectory(atPath: projects)) ?? [])
        .filter { $0.hasSuffix(".jsonl") }
    check(leftFiles.isEmpty, "取消后已写入的会话文件被撤销")
    let leftRows = try store.db.scalarInt("SELECT COUNT(*) FROM handoffs WHERE target='claude'")
    check(leftRows == 0, "取消后统一库不留同步记录")

    // 2. 校验失败（没有用户消息）：降级成交接包，且不把 claude 记成已同步
    let c = try makeThread("降级丙", project: "/tmp", userOnly: false)
    plan = TransferPlan(sourceKind: .claude, targetKind: .claude, mode: .nativeImport,
                        threadIDs: [c], messageCount: 1, duplicateCount: 0, redactedCount: 0,
                        estimatedBytes: 10, targetPath: projects, notes: [])
    let downgraded = try HandoffWriter(store: store, recordTarget: "claude-handoff")
        .write(plan: plan, payloads: [(c, "降级丙", try store.items(threadId: c))]) { _, _ in }
    check(downgraded.written == 1 && downgraded.artifacts.first?.hasSuffix(".md") == true, "降级生成交接包")
    check(try store.db.scalarInt("SELECT COUNT(*) FROM handoffs WHERE thread_id=? AND target='claude'", [c]) == 0,
          "降级不占用 claude 目标记录")
    check(try store.db.scalarInt("SELECT COUNT(*) FROM handoffs WHERE thread_id=? AND target='claude-handoff'", [c]) == 1,
          "降级记录单独记账")

    // 3. 备份还原：原有文件在回滚后恢复原内容，本轮新增的文件被删掉
    let journal = TransferJournal()
    let original = root + "/existing.txt"
    let fresh = root + "/fresh.txt"
    try "原始内容".write(toFile: original, atomically: true, encoding: .utf8)
    let backup = try WriteSupport.backup(path: original, store: store)
    journal.record(target: original, backup: backup)
    journal.record(target: fresh, backup: nil)
    try "被覆盖".write(toFile: original, atomically: true, encoding: .utf8)
    try "新增".write(toFile: fresh, atomically: true, encoding: .utf8)
    let problems = journal.restore()
    check(problems.isEmpty, "回滚没有报错")
    check(try String(contentsOfFile: original, encoding: .utf8) == "原始内容", "原有文件按备份还原")
    check(!FileManager.default.fileExists(atPath: fresh), "本轮新增的文件被删除")
} catch {
    print("  FAIL 回滚用例：\(error)")
    failures += 1
}

print("轮次切分")
do {
    let root = NSTemporaryDirectory() + "agent-history-turns-\(UUID().uuidString)"
    let store = try Store(root: root)
    try store.registerSource(.codex, available: true)
    let tid = try store.upsertThread(ThreadInput(
        sourceId: "codex", nativeId: "turn-thread", projectPath: "/tmp/turn",
        title: "两轮对话", createdAt: 1_700_000_000_000, updatedAt: 1_700_000_900_000,
        model: "gpt", threadSource: "user", archived: false, preview: "第一问"))
    // 原生轮次标识优先于「用户消息开新轮」的推断。
    try store.upsertItems(threadId: tid, items: [
        ItemInput(nativeId: "a1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_100_000, text: "第一问", rawJSON: "", turnId: "t1"),
        ItemInput(nativeId: "a2", ordinal: 2, itemType: "agentMessage", role: "assistant",
                  createdAt: 1_700_000_200_000, text: "第一答", rawJSON: "", turnId: "t1"),
        ItemInput(nativeId: "a3", ordinal: 3, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_300_000, text: "第二问", rawJSON: "", turnId: "t2"),
        ItemInput(nativeId: "a4", ordinal: 4, itemType: "agentMessage", role: "assistant",
                  createdAt: 1_700_000_400_000, text: "第二答", rawJSON: "", turnId: "t2"),
    ])
    let turns = try store.turns(threadId: tid)
    check(turns.count == 2, "两轮对话建了两个轮次")
    check(turns.first?.itemCount == 2 && turns.last?.itemCount == 2, "每轮各两条条目")
    check(turns.first?.prompt == "第一问" && turns.last?.prompt == "第二问", "轮次摘要取用户提问")
    check(turns.first?.startedAt == 1_700_000_100_000 && turns.first?.completedAt == 1_700_000_200_000,
          "轮次起止时间取条目时间")
    let loaded = try store.items(threadId: tid)
    check(loaded.map(\.turnOrdinal) == [1, 1, 2, 2], "条目带出所属轮次序号")
    let paged = try store.itemsPage(threadId: tid, offset: 2)
    check(paged.first?.turnOrdinal == 2, "分页取出的条目也带轮次")

    // 轮次跳转要能定位到这一轮的第一条，否则长会话只能一路翻。
    let secondTurnFirst = try store.firstItemOrdinal(turnId: turns[1].id)
    check(secondTurnFirst == 3, "取到第二轮第一条的序号")
    let secondTurnPage = try store.itemsPage(threadId: tid, offset: 2)
    check(secondTurnPage.first?.ordinal == 3, "按偏移直接落到第二轮开头")

    // 给 agent 的上下文默认取结尾，必须真的从库里倒着取，不能靠从头取再切。
    let tail = try store.itemsTail(threadId: tid, limit: 2)
    check(tail.map(\.ordinal) == [3, 4], "从尾部取到最后一问一答且按正序排")
    check(try store.itemsTail(threadId: tid, limit: 99).count == 4, "尾部条数超过总数时给全部")

    // 增量里没带轮次标识的条目（典型是只补了助手回复）接在最后一轮后面，不产生孤轮。
    try store.upsertItems(threadId: tid, items: [
        ItemInput(nativeId: "a5", ordinal: 5, itemType: "toolResult", role: "tool",
                  createdAt: 1_700_000_500_000, text: "跑完了", rawJSON: "")
    ])
    let after = try store.turns(threadId: tid)
    check(after.count == 2 && after.last?.itemCount == 3, "不带轮次的条目接到最后一轮")

    // 老库回填：把 turn_id 清空、删掉轮次表，重新打开应能按用户消息重建。
    try store.db.run("UPDATE items SET turn_id=NULL")
    try store.db.run("DELETE FROM turns")
    try store.db.run("DELETE FROM meta WHERE key='turns_backfill'")
    let reopened = try Store(root: root)
    let rebuilt = try reopened.turns(threadId: tid)
    check(rebuilt.count == 2, "老库按用户消息回填轮次")
    check(rebuilt.first?.prompt == "第一问", "回填后轮次摘要正确")
    let orphans = try reopened.db.scalarInt("SELECT COUNT(*) FROM items WHERE turn_id IS NULL")
    check(orphans == 0, "回填后没有孤立条目")
} catch {
    print("  FAIL 轮次用例：\(error)")
    failures += 1
}

print("主题汇编")
do {
    let root = NSTemporaryDirectory() + "agent-history-digest-\(UUID().uuidString)"
    let store = try Store(root: root)
    try store.registerSource(.codex, available: true)
    try store.registerSource(.claude, available: true)

    // 2026-10-20 10:00 与 2026-10-21 09:00 各一轮，方便按天分组断言。
    func stamp(_ day: Int, _ hour: Int) -> Int64 {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = day; c.hour = hour
        let date = Calendar(identifier: .gregorian).date(from: c) ?? Date()
        return Int64(date.timeIntervalSince1970 * 1000)
    }
    func addThread(native: String, source: String, path: String, title: String,
                   turns: [(ask: String, answer: String, at: Int64)]) throws -> String {
        let tid = try store.upsertThread(ThreadInput(
            sourceId: source, nativeId: native, projectPath: path, title: title,
            createdAt: turns.first?.at ?? 0, updatedAt: turns.last?.at ?? 0,
            model: "m", threadSource: "user", archived: false, preview: ""))
        var ordinal = 0
        for (index, turn) in turns.enumerated() {
            ordinal += 1
            try store.upsertItems(threadId: tid, items: [
                ItemInput(nativeId: "\(native)-q\(index)", ordinal: ordinal, itemType: "userMessage",
                          role: "user", createdAt: turn.at, text: turn.ask, rawJSON: "",
                          turnId: "\(native)-t\(index)"),
                ItemInput(nativeId: "\(native)-a\(index)", ordinal: ordinal + 1, itemType: "agentMessage",
                          role: "assistant", createdAt: turn.at + 60_000, text: turn.answer, rawJSON: "",
                          turnId: "\(native)-t\(index)"),
                ItemInput(nativeId: "\(native)-c\(index)", ordinal: ordinal + 2, itemType: "commandExecution",
                          role: "tool", createdAt: turn.at + 30_000, text: "ls", rawJSON: "",
                          turnId: "\(native)-t\(index)"),
            ])
            ordinal += 2
        }
        return tid
    }

    let codexA = try addThread(native: "da", source: "codex", path: "/tmp/alpha", title: "支付对账", turns: [
        (ask: "对账表为什么缺三笔", answer: "因为退款单没有回写", at: stamp(20, 10)),
        (ask: "那怎么补", answer: "先补退款的 payment_id", at: stamp(21, 9)),
    ])
    _ = try addThread(native: "db", source: "claude", path: "/tmp/beta", title: "文案打磨", turns: [
        (ask: "把标题改短", answer: "已改成八个字", at: stamp(21, 15)),
    ])

    var options = DigestOptions()
    options.since = stamp(19, 0)
    options.until = stamp(22, 0)
    options.useLLM = false
    let plan = try DigestPlanner.build(store: store, options: options)
    check(plan.turnCount == 3, "三天窗口内取到 3 轮")
    check(plan.threadCount == 2, "两个会话参与汇编")
    check(plan.dayCount == 2, "按天分成两节")
    check(plan.days.map { $0.key } == ["2026-10-20", "2026-10-21"], "天的顺序按时间从前到后")
    check(plan.days.last?.label.contains("10月21日") == true, "日期标题是中文月日")
    check(plan.days.last?.threads.count == 2, "同一天两个会话各成一组")
    check(plan.days.last?.threads.first?.turns.count == 1, "同一天同一会话的轮次并到一组")
    check(plan.turns.allSatisfy { $0.answer.isEmpty == false }, "每轮都带上了答复")
    check(plan.turns.first?.toolCount == 1, "工具输出只计数不搬正文")
    let material = plan.days.map { DigestPlanner.materialText($0.turns, dayLabel: $0.label) }
        .joined(separator: "\n")
    check(material.contains("对账表为什么缺三笔"), "材料里含用户提问")
    check(material.contains("因为退款单没有回写"), "材料里含答复")
    check(!material.contains("ls"), "工具输出正文不进材料")
    check(material.contains("### 支付对账"), "材料按会话分组")

    // 分段：不超上限时一天一段，超了同一天拆开，轮次不丢不重
    let whole = DigestPlanner.segments(plan, limit: 14_000)
    check(whole.count == plan.dayCount, "材料不长时一天出一段")
    check(whole.allSatisfy { $0.material.hasPrefix("# 对话材料") }, "每段材料带标题")
    // 上限取最小那一天材料的一半，保证至少有一天被拆开。
    let shortest = plan.days.map { DigestPlanner.materialText($0.turns, dayLabel: $0.label).count }.min() ?? 0
    let split = DigestPlanner.segments(plan, limit: max(1, shortest / 2))
    check(split.count > plan.dayCount, "材料超上限时同一天拆成多段")
    check(split.allSatisfy {
        DigestPlanner.materialText($0.turns, dayLabel: $0.dayLabel).count <= max(1, shortest / 2) || $0.turns.count == 1
    }, "每段都在上限内")
    check(Set(split.map { "\($0.dayKey)#\($0.part)" }).count == split.count, "每段编号唯一")
    check(split.allSatisfy { !$0.turns.isEmpty }, "没有空段")
    let kept = Set(split.flatMap { $0.turns.map { "\($0.threadId)#\($0.ordinal)" } })
    check(kept.count == plan.turnCount, "拆段不丢轮次也不重复")

    // 来源筛选
    options.sourceKind = .claude
    let claudeOnly = try DigestPlanner.build(store: store, options: options)
    check(claudeOnly.turnCount == 1 && claudeOnly.threadCount == 1, "按来源筛只剩 claude 的一轮")

    // 项目筛选
    options.sourceKind = nil
    options.projectPath = "/tmp/alpha"
    let alphaOnly = try DigestPlanner.build(store: store, options: options)
    check(alphaOnly.turnCount == 2 && alphaOnly.threadCount == 1, "按项目筛只剩 alpha 的两轮")
    options.projectPath = nil

    // 时间窗边界
    options.since = stamp(21, 0)
    let fromSecondDay = try DigestPlanner.build(store: store, options: options)
    check(fromSecondDay.turnCount == 2, "起始时间卡掉更早的轮次")
    options.since = stamp(19, 0)

    // 定时任务自己跟自己说话的轮次不进汇编
    _ = try addThread(native: "dc", source: "codex", path: "/tmp/alpha", title: "定时观察", turns: [
        (ask: "<heartbeat>检查一遍</heartbeat>", answer: "无变化", at: stamp(21, 20)),
        (ask: "Automation ID: abc\nAutomation memory: 上次无变化", answer: "已记录", at: stamp(21, 21)),
    ])
    let filtered = try DigestPlanner.build(store: store, options: options)
    check(filtered.turnCount == plan.turnCount, "心跳与自动化模板轮被挡在汇编外")
    check(filtered.skippedTurns == 2, "略过的轮数单独计数")

    // 副本会话不进汇编
    try store.db.run("INSERT INTO thread_families(id,representative_thread_id,member_count,created_at) VALUES('fam1',?,2,0)", [codexA])
    try store.db.run("""
        INSERT INTO thread_links(family_id,thread_id,role,relation,direction,target_ref,created_at)
        VALUES('fam1',?,'original','confirmed','','',0)
        """, [codexA])
    let copyId = try addThread(native: "copy", source: "claude", path: "/tmp/alpha", title: "支付对账", turns: [
        (ask: "对账表为什么缺三笔", answer: "因为退款单没有回写", at: stamp(20, 10)),
    ])
    try store.db.run("""
        INSERT INTO thread_links(family_id,thread_id,role,relation,direction,target_ref,created_at)
        VALUES('fam1',?,'copy','confirmed','','',0)
        """, [copyId])
    let noCopy = try DigestPlanner.build(store: store, options: options)
    check(noCopy.turnCount == filtered.turnCount, "副本会话不重复计入汇编")

    // 模型通路失败时退回按天摘要，并在说明里给出原因
    var llm = options
    llm.useLLM = true
    llm.command = "bash -c 'exit 3'"
    let failed = DigestRunner.run(store: store, options: llm)
    check(failed.usedLLM == false, "模型失败不标记成提炼过")
    check(failed.markdown.contains("# 主题汇编"), "降级后仍出标题")
    check(failed.markdown.contains("没有经过模型提炼"), "降级正文说明没走模型")
    check(failed.note.contains("改出按天摘要"), "说明里写明降级原因")
    check(!failed.path.isEmpty && FileManager.default.fileExists(atPath: failed.path), "降级也落盘")

    // 模型把提示词原样回显也要认出来
    var echo = options
    echo.useLLM = true
    echo.command = "cat"
    let echoed = DigestRunner.run(store: store, options: echo)
    check(echoed.usedLLM == false, "回显材料不算提炼成功")

    // 正常通路：命令把结果写到标准输出
    var good = options
    good.useLLM = true
    good.command = "bash -c 'echo \"# 主题汇编 · 10月20日至10月21日\"; echo; echo \"## 10月20日 周二\"; echo \"- 对账缺三笔是退款单没回写\"'"
    let ok = DigestRunner.run(store: store, options: good)
    check(ok.usedLLM == true, "命令正常返回就算提炼成功")
    check(ok.markdown.contains("退款单没回写"), "正文取命令的标准输出")
    check(ok.note.contains("模型提炼"), "说明标注模型提炼")
    check(ok.calls == plan.dayCount + 1, "两天各提炼一次，再多一次合并")

    // 超时：命令卡住要在限定时间附近被打断并降级
    var slow = options
    slow.useLLM = true
    slow.timeout = 5
    slow.command = "sleep 30"
    let started = Date()
    let timedOut = DigestRunner.run(store: store, options: slow)
    let cost = Date().timeIntervalSince(started)
    check(timedOut.usedLLM == false, "超时后不标记成提炼成功")
    check(cost < 25, "超时的命令被中断，没有一直等下去（\(String(format: "%.1f", cost)) 秒）")
    check(timedOut.note.contains("改出按天摘要"), "超时也降级出稿")
} catch {
    print("  FAIL 汇编用例：\(error)")
    failures += 1
}

print("没装模型命令行也能用")
do {
    // 换到没有 Claude Code 的机器上，默认命令不能还写死 claude。
    check(LLMRunner.binary(of: "claude -p --no-session-persistence") == "claude", "取命令里的可执行文件名")
    check(LLMRunner.binary(of: "  \"/opt/bin/mytool\" --flag") == "/opt/bin/mytool", "带引号的路径也能取出来")
    check(LLMRunner.binary(of: "") == "", "空命令没有可执行文件名")

    // 找不到命令时要说清本机有什么，不能只说「命令失败」。
    var missing = DigestOptions()
    missing.command = "definitely-not-a-real-model-cli --go"
    var hint = ""
    do { _ = try LLMRunner.preflight(missing) }
    catch { hint = "\(error)" }
    check(hint.contains("definitely-not-a-real-model-cli"), "提示里带上找不到的命令名")
    check(hint.contains("接口") || hint.contains("本机能用的有"), "提示里给出替代办法")

    // 两条通路都没配，直接说清楚原因，不抛给用户一个空白面板。
    var nothing = DigestOptions()
    nothing.command = ""
    var none = ""
    do { _ = try LLMRunner.preflight(nothing) }
    catch { none = "\(error)" }
    check(none.contains("没有可用的模型通路"), "没配通路时说明原因")

    // 接口配好了就不用管命令行存不存在。
    var viaAPI = DigestOptions()
    viaAPI.command = "definitely-not-a-real-model-cli"
    viaAPI.api = LLMAPI(baseURL: "https://example.invalid/v1", model: "m1")
    if case .api = try? LLMRunner.preflight(viaAPI) {} else { check(false, "接口优先，跳过命令行检查") }

    // 接口请求：形状、地址拼接、密钥来源都对，且完全不联网。
    var captured: URLRequest?
    LLMAPI.transport = { request in
        captured = request
        let body = """
        {"choices":[{"message":{"role":"assistant","content":"## 10月20日\\n- 退款单没回写"}}]}
        """
        return (200, Data(body.utf8))
    }
    setenv("AGENT_HISTORY_LLM_API_KEY", "sk-from-env", 1)
    var opts = DigestOptions()
    opts.api = LLMAPI(baseURL: "https://api.example.com/v1", model: "demo-model")
    let answer = try LLMRunner.ask(opts, prompt: "把这段压成要点", workDir: NSTemporaryDirectory() + "ah-api-\(UUID().uuidString)")
    check(answer.output.contains("退款单没回写"), "接口正文取 choices[0].message.content")
    check(captured?.url?.absoluteString == "https://api.example.com/v1/chat/completions", "地址拼到 chat/completions")
    check(captured?.httpMethod == "POST", "接口用 POST")
    check(captured?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-from-env", "没填密钥时读环境变量")
    let sent = captured.flatMap { $0.httpBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    check(sent?["model"] as? String == "demo-model", "请求里带模型名")
    let messages = sent?["messages"] as? [[String: Any]]
    check(messages?.first?["content"] as? String == "把这段压成要点", "提示词进 messages")

    // 直接给到 /chat/completions 的地址不再重复拼。
    var direct = DigestOptions()
    direct.api = LLMAPI(baseURL: "https://api.example.com/v1/chat/completions/", model: "m")
    captured = nil
    _ = try LLMRunner.ask(direct, prompt: "x", workDir: NSTemporaryDirectory() + "ah-api2-\(UUID().uuidString)")
    check(captured?.url?.absoluteString == "https://api.example.com/v1/chat/completions", "给全地址不重复拼")

    // 接口报错要把状态码和返回片段带出来，方便判断是密钥错还是模型名错。
    LLMAPI.transport = { _ in (401, Data("{\"error\":\"bad key\"}".utf8)) }
    var bad = DigestOptions()
    bad.api = LLMAPI(baseURL: "https://api.example.com/v1", model: "m")
    var apiError = ""
    do { _ = try LLMRunner.ask(bad, prompt: "x", workDir: NSTemporaryDirectory() + "ah-api3-\(UUID().uuidString)") }
    catch { apiError = "\(error)" }
    check(apiError.contains("401"), "错误里带状态码")
    check(apiError.lowercased().contains("bad key"), "错误里带服务端原话")

    // 地址或模型名缺一半就当没配，不要盖掉本来能跑的命令行。
    check(LLMAPI(baseURL: "https://api.example.com/v1", model: "").isEmpty, "缺模型名算没配")
    check(LLMAPI(baseURL: "", model: "m").isEmpty, "缺地址算没配")

    // 接口也失败时仍然退到按天摘要，说明里写清是哪条没成。
    let root = NSTemporaryDirectory() + "agent-history-api-\(UUID().uuidString)"
    let store = try Store(root: root)
    let id = try store.upsertThread(ThreadInput(
        sourceId: "codex", nativeId: "api-1", projectPath: "/tmp/api",
        title: "接口降级", createdAt: 0, updatedAt: 0,
        model: "", threadSource: "user", archived: false, preview: ""))
    try store.upsertItems(threadId: id, items: [
        ItemInput(nativeId: "a1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: Int64(Date().timeIntervalSince1970 * 1000), text: "对账缺三笔",
                  rawJSON: "", turnId: "api-t1"),
    ])
    LLMAPI.transport = { _ in (500, Data("boom".utf8)) }
    var degraded = DigestOptions()
    degraded.since = Int64((Date().timeIntervalSince1970 - 86400) * 1000)
    // 上界显式往后放：默认上界就是「此刻」，刚写进去的条目可能落在同一毫秒被半开区间挡掉。
    degraded.until = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
    degraded.api = LLMAPI(baseURL: "https://api.example.com/v1", model: "m")
    let failedAPI = DigestRunner.run(store: store, options: degraded)
    check(failedAPI.usedLLM == false, "接口失败不标记成提炼过")
    check(failedAPI.markdown.contains("按天"), "接口失败仍出按天摘要")
    check(failedAPI.note.contains("500") || failedAPI.note.contains("没走成模型"), "说明里写明接口失败")

    // 通路探测：缓存要能重置，推荐值在只有接口时给接口。
    LLMDetector.reset()
    let detected = LLMDetector.detect()
    check(detected.allSatisfy { FileManager.default.isExecutableFile(atPath: $0.path) }, "探测到的都是真可执行文件")
    let onlyAPI = LLMDetector.recommended(api: LLMAPI(baseURL: "https://api.example.com/v1", model: "m"))
    check(onlyAPI?.label.contains("接口") == true, "配了接口时推荐接口")

    // 自动探测出来的命令不落盘，换台机器才不会拿着一条不存在的命令去跑。
    check(LLMDetector.isPresetCommand("claude -p --no-session-persistence"), "预设命令认得出")
    check(LLMDetector.isPresetCommand("  codex exec --ephemeral --skip-git-repo-check -s read-only -\n"),
          "首尾空白不影响判断")
    check(!LLMDetector.isPresetCommand("my-own-model-cli --flag"), "自己写的命令不影响")
    check(!LLMDetector.isPresetCommand(""), "空命令不算预设")

    // 接口配置要存得住：关掉再打开不用重新填，密钥也不进 UserDefaults。
    let cfgHome = NSTemporaryDirectory() + "ah-cfg-\(UUID().uuidString)"
    setenv("AGENT_HISTORY_HOME", cfgHome, 1)
    LLMConfig.saveKey("sk-keep-me")
    check(LLMConfig.loadKey() == "sk-keep-me", "密钥存得下、读得回")
    let mode = (try? FileManager.default.attributesOfItem(atPath: LLMConfig.keyPath))?[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600, "密钥文件只有本人可读")
    LLMConfig.saveKey("  ")
    check(LLMConfig.loadKey().isEmpty, "清空密钥时文件一并删掉")
    check(!FileManager.default.fileExists(atPath: LLMConfig.keyPath), "清空后不留空壳")
    // 旧版本把密钥写在偏好里，启动时要搬走并从偏好删掉。
    UserDefaults.standard.set("sk-legacy", forKey: "digestAPIKey")
    LLMConfig.migrateFromDefaults()
    check(LLMConfig.loadKey() == "sk-legacy", "旧密钥搬到文件")
    check(UserDefaults.standard.string(forKey: "digestAPIKey") == nil, "偏好里不再留明文密钥")

    // 填一次就该记住：下次打开不用重新输。
    LLMSettings.saveBase("https://api.deepseek.com/v1")
    LLMSettings.saveModel("deepseek-chat")
    LLMSettings.saveKey("sk-round-trip")
    let reopened = LLMSettings.load()
    check(reopened.base == "https://api.deepseek.com/v1", "地址重开后还在")
    check(reopened.model == "deepseek-chat", "模型名重开后还在")
    check(reopened.apiKey == "sk-round-trip", "密钥重开后还在")
    check(reopened.api?.model == "deepseek-chat", "三项齐了就算配好接口")
    // 只填一半不算配好，别拿半个配置去发请求。
    LLMSettings.saveModel("")
    check(LLMSettings.load().api == nil, "缺模型名不算配好")
    // 清空要能真的清掉，不然换密钥时会把旧值带走。
    LLMSettings.saveKey("")
    check(LLMSettings.load().apiKey.isEmpty, "清空密钥后不再读回旧的")
    UserDefaults.standard.removeObject(forKey: "digestAPIBase")
    UserDefaults.standard.removeObject(forKey: "digestAPIModel")

    unsetenv("AGENT_HISTORY_HOME")

    LLMAPI.transport = nil
    unsetenv("AGENT_HISTORY_LLM_API_KEY")
} catch {
    print("  FAIL 模型通路用例：\(error)")
    failures += 1
}

print("汇编缓存不重复调模型")
do {
    // 同一段材料跑第二次不该再调模型：只要今天有新对话，前几天应当直接复用。
    let root = NSTemporaryDirectory() + "agent-history-cache-\(UUID().uuidString)"
    let store = try Store(root: root)
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let id = try store.upsertThread(ThreadInput(
        sourceId: "codex", nativeId: "cache-1", projectPath: "/tmp/cache",
        title: "缓存验证", createdAt: now, updatedAt: now,
        model: "", threadSource: "user", archived: false, preview: ""))
    try store.upsertItems(threadId: id, items: [
        ItemInput(nativeId: "c1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: now, text: "把退款单补上", rawJSON: "", turnId: "cache-t1"),
    ])
    let counter = root + "/calls.txt"
    var cachedOptions = DigestOptions()
    cachedOptions.since = now - 3600_000
    cachedOptions.until = now + 3600_000
    cachedOptions.useLLM = true
    cachedOptions.command = "bash -c 'echo x >> \(counter); echo \"# 主题汇编 · 今天\"; echo \"- 补退款单\"'"
    let firstRun = DigestRunner.run(store: store, options: cachedOptions)
    let firstLines = ((try? String(contentsOfFile: counter, encoding: .utf8)) ?? "")
        .split(separator: "\n").count
    check(firstRun.cachedCalls == 0, "第一次跑没有可复用的结果")
    check(firstLines == 2, "第一次跑调两次模型：一天一段加一次合并")

    let secondRun = DigestRunner.run(store: store, options: cachedOptions)
    let secondLines = ((try? String(contentsOfFile: counter, encoding: .utf8)) ?? "")
        .split(separator: "\n").count
    check(secondRun.cachedCalls == 1, "第二次跑复用那一天的结果")
    // 合并那一步也吃缓存：材料一个字没变，第二次应当一次模型都不调。
    check(secondRun.calls == 0, "第二次跑一次模型都没调")
    check(secondLines == 2, "第二次跑没有新的模型调用")
    check(secondRun.markdown.contains("补退款单"), "复用出来的内容照常进汇编")
    check(secondRun.note.contains("复用"), "说明里标出复用了多少段")

    // 关掉缓存就得老实重跑。
    var noCache = cachedOptions
    noCache.useCache = false
    let thirdRun = DigestRunner.run(store: store, options: noCache)
    let thirdLines = ((try? String(contentsOfFile: counter, encoding: .utf8)) ?? "")
        .split(separator: "\n").count
    check(thirdRun.cachedCalls == 0, "关掉缓存不算复用")
    check(thirdRun.calls == 2, "关掉缓存时各段和合并都重新调模型")
    check(thirdLines == 4, "关掉缓存时每段都重新调模型")

    // 换模型后缓存必须失效，不能拿另一个模型的结论充数。
    var otherModel = cachedOptions
    otherModel.command = "bash -c 'echo y >> \(counter); echo \"# 主题汇编 · 换模型\"'"
    let switched = DigestRunner.run(store: store, options: otherModel)
    check(switched.cachedCalls == 0, "换模型后不吃旧缓存")

    check(DigestCache.fingerprint("同样的材料") == DigestCache.fingerprint("同样的材料"), "指纹可重复")
    check(DigestCache.fingerprint("材料一") != DigestCache.fingerprint("材料二"), "不同材料指纹不同")

    // 缓存不能无限长：写满上限后只留最近的几份。
    let trimRoot = NSTemporaryDirectory() + "agent-history-trim-\(UUID().uuidString)"
    for i in 0..<8 {
        DigestCache.save(storeRoot: trimRoot, key: "k\(i)", text: "结果 \(i)")
    }
    let trimmed = DigestCache.trim(storeRoot: trimRoot, keep: 3)
    check(trimmed == 5, "超出上限的缓存被删掉")
    let left = ((try? FileManager.default.contentsOfDirectory(atPath: DigestCache.directory(storeRoot: trimRoot))) ?? [])
        .filter { $0.hasSuffix(".md") }
    check(left.count == 3, "只留最近的 3 份")
    check(DigestCache.trim(storeRoot: trimRoot, keep: 3) == 0, "没超上限时不动手")

    let purged = DigestCache.purge(storeRoot: root)
    check(purged.count > 0, "缓存能整片清掉")
    check((try? FileManager.default.contentsOfDirectory(atPath: DigestCache.directory(storeRoot: root)))?.isEmpty ?? true,
          "清完缓存目录是空的")
} catch {
    print("  FAIL 汇编缓存用例：\(error)")
    failures += 1
}

print("备份目录不会一直长")
do {
    let root = NSTemporaryDirectory() + "agent-history-backups-\(UUID().uuidString)"
    let dir = root + "/backups"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    // backup() 建的目录名是纯数字时间戳，会随每次传输多一份。
    for stamp in 1...8 {
        let path = dir + "/17000000\(stamp)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try String(repeating: "x", count: 100).write(toFile: path + "/history.db", atomically: true, encoding: .utf8)
        // 修改时间按序号递增，保证「留最近的」这件事可判定。
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(1_700_000_000 + stamp))],
            ofItemAtPath: path)
    }
    // 手工断点目录不在清理范围内，别被一起删掉。
    let manual = dir + "/pre-digest-clean"
    try FileManager.default.createDirectory(atPath: manual, withIntermediateDirectories: true)
    try "keep".write(toFile: manual + "/history.db", atomically: true, encoding: .utf8)

    let before = WriteSupport.backupUsage(storeRoot: root)
    check(before.count == 9, "先数清 8 份时间戳备份加 1 份手工断点")
    check(before.bytes > 800, "用量按文件实际大小算")
    check(before.prunable == 8, "自动备份单独数出来是 8 份")
    check(before.manual == 1, "手工断点单独数出来是 1 份")

    let pruned = WriteSupport.pruneBackups(storeRoot: root, keep: 3)
    check(pruned.removed == 5, "只留最近 3 份，其余 5 份被清")
    check(pruned.bytes > 0, "腾出的体积如实回报")
    let after = WriteSupport.backupUsage(storeRoot: root)
    check(after.count == 4, "剩 3 份时间戳备份加手工断点")
    check(after.prunable == 3 && after.manual == 1, "清理后自动备份 3 份、手工断点仍 1 份")
    check(FileManager.default.fileExists(atPath: manual + "/history.db"), "手工断点目录不动")
    check(FileManager.default.fileExists(atPath: dir + "/170000008/history.db"), "留的是最新的那份")
    check(!FileManager.default.fileExists(atPath: dir + "/170000001/history.db"), "最旧的被清掉")
    check(WriteSupport.pruneBackups(storeRoot: root, keep: 3).removed == 0, "没超过保留数时不动手")
    check(WriteSupport.pruneBackups(storeRoot: NSTemporaryDirectory() + "没有这个目录", keep: 3).removed == 0,
          "目录不存在也不报错")
} catch {
    print("  FAIL 备份清理用例：\(error)")
    failures += 1
}

print("会话列表能翻到底")
do {
    let root = NSTemporaryDirectory() + "agent-history-paging-\(UUID().uuidString)"
    let store = try Store(root: root)
    try store.registerSource(.codex, available: true)
    // 造 450 个会话。早先列表写死 500 条看着够，实际库里有 759 个，
    // 后 259 个永远不显示；这里验证游标翻页能一个不落地走完。
    // 第 250、251 个时间戳故意一样，正好卡在第一页（200 个）的边界上。
    // 真实库 827 个会话里有 9 对这样，页长取 161 或 322 时只按时间戳翻页就会漏 1 个。
    for i in 1...450 {
        let stamp = i == 250 ? Int64(251) : Int64(i)
        _ = try store.upsertThread(ThreadInput(
            sourceId: "codex", nativeId: "t\(i)", projectPath: "/tmp/demo",
            title: "会话 \(i)", createdAt: 1_700_000_000_000 + Int64(i),
            updatedAt: 1_700_000_000_000 + stamp, model: "gpt",
            threadSource: "user", archived: false, preview: ""))
    }
    check(try store.threadCount() == 450, "筛选条件对应的总数对得上")
    var seen: [String] = []
    var cursor: Int64? = nil
    var cursorId: String? = nil
    var rounds = 0
    while true {
        let page = try store.threads(limit: 200, before: cursor, beforeId: cursorId)
        if page.isEmpty { break }
        check(page.count <= 200, "每页不超过两百")
        seen.append(contentsOf: page.map(\.id))
        cursor = page.last?.updatedAt
        cursorId = page.last?.id
        rounds += 1
        if rounds > 10 { break }
    }
    check(rounds == 3, "450 个分三页走完")
    check(seen.count == 450, "一个都没漏")
    check(Set(seen).count == 450, "也没有重复")
    check(try store.threadCount(sourceKind: .claude) == 0, "按来源筛时总数为零")
} catch {
    print("  FAIL 会话翻页用例：\(error)")
    failures += 1
}

print("MCP 补同步只看各自水位")
do {
    let now = Date().timeIntervalSince1970
    func source(_ kind: SourceKind, _ age: TimeInterval?, available: Bool = true) -> SourceInfo {
        SourceInfo(id: kind.rawValue, kind: kind, available: available,
                   lastSyncAt: age.map { Int64(now - $0) } ?? 0, lastError: nil)
    }
    // 一个刚同步过、一个一小时没动：只补后者。早先取最大值判定，后者永远补不上。
    let mixed = [source(.claude, 10), source(.codex, 3600)]
    let stale = MCPSyncPolicy.staleKinds(mixed, now: now)
    check(stale == [.codex], "只补落后的那个来源")
    check(MCPSyncPolicy.staleKinds([source(.claude, 10), source(.kimi, 20)], now: now).isEmpty,
          "都新鲜时不补")
    check(MCPSyncPolicy.staleKinds([source(.claude, 10, available: false)], now: now).isEmpty,
          "不可用的来源不参与补同步")
    check(MCPSyncPolicy.staleKinds([source(.deepseek, nil)], now: now) == [.deepseek],
          "从没同步过的来源要补")
    check(MCPSyncPolicy.staleKinds([source(.codex, 299)], now: now).isEmpty, "五分钟内不算旧")
    check(MCPSyncPolicy.staleKinds([source(.codex, 300)], now: now) == [.codex], "到五分钟算旧")
    check(MCPSyncPolicy.age(source(.codex, 42), now: now).map { Int($0) } == 42, "算出上次同步过去多久")
    check(MCPSyncPolicy.age(source(.codex, nil), now: now) == nil, "没同步过不算时长")
}

print("汇编临时会话不混进库")
do {
    let root = NSTemporaryDirectory() + "agent-history-scratch-\(UUID().uuidString)"
    let storeRoot = root + "/store"
    let projects = root + "/claude-projects"
    try FileManager.default.createDirectory(atPath: projects + "/-tmp-work", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: projects + "/-tmp-real", withIntermediateDirectories: true)
    setenv("AGENT_HISTORY_CLAUDE_PROJECTS", projects, 1)

    // 汇编的工作目录，claude 会把它也记成会话。
    let scratchCwd = storeRoot + "/" + LLMRunner.workDirectoryName + "/2026-10-20-1"
    func line(_ uuid: String, _ type: String, _ text: String, _ cwd: String) -> String {
        """
        {"type":"\(type)","uuid":"\(uuid)","promptId":"p-\(uuid)","cwd":"\(cwd)","timestamp":"2026-10-20T02:00:00Z","message":{"role":"\(type == "user" ? "user" : "assistant")","content":[{"type":"text","text":"\(text)"}]}}
        """
    }
    try ([line("s1", "user", "你是我的工作助理。下面是某一天的对话记录", scratchCwd),
          line("s2", "assistant", "- 假要点", scratchCwd)].joined(separator: "\n") + "\n")
        .write(toFile: projects + "/-tmp-work/scratch.jsonl", atomically: true, encoding: .utf8)
    try ([line("r1", "user", "真实提问：对账缺三笔", "/tmp/real-project"),
          line("r2", "assistant", "因为退款单没回写", "/tmp/real-project")].joined(separator: "\n") + "\n")
        .write(toFile: projects + "/-tmp-real/real.jsonl", atomically: true, encoding: .utf8)

    let store = try Store(root: storeRoot)
    let adapter = ClaudeAdapter()
    check(adapter.isAvailable, "看到 Claude 会话目录")
    _ = try adapter.sync(into: store) { _ in }
    let rows = try store.threads(sourceKind: .claude)
    check(rows.count == 1, "汇编工作目录里的会话不进口袋库")
    check(rows.first?.title.contains("真实提问") == true, "真实对话照常收进来")
    let scratchHits = try store.search("工作助理")
    check(scratchHits.isEmpty, "提示词不进检索")

    // 老版本已经收进来的假会话，用 digest-clean 清掉。
    let polluted = try store.upsertThread(ThreadInput(
        sourceId: "claude", nativeId: "old-scratch", projectPath: scratchCwd,
        title: "你是我的工作助理", createdAt: 0, updatedAt: 0,
        model: "", threadSource: "user", archived: false, preview: ""))
    try store.upsertItems(threadId: polluted, items: [
        ItemInput(nativeId: "o1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_000_000, text: "你是我的工作助理", rawJSON: "")
    ])
    check(try store.search("工作助理").isEmpty == false, "清理前能检索到假会话")
    let removed = try store.purgeDigestScratch()
    check(removed == 1, "清理掉汇编留下的假会话")
    check(try store.search("工作助理").isEmpty, "清理后检索不到假会话")
    check(try store.threads(sourceKind: .claude).count == 1, "真实对话没被误删")
    check(try store.purgeDigestScratch() == 0, "再清一次没有可清的")

    // 换过库目录、用副本库跑过的，路径前缀不一样，也要认出来。
    check(LLMRunner.isScratchPath("/private/tmp/ah-digest/digests/work/2026-10-20-1"), "别处根目录下的工作目录也算临时")
    check(LLMRunner.isScratchPath("/Users/example/.agent-history/digests/work/merge"), "merge 目录算临时")
    check(!LLMRunner.isScratchPath("/Users/example/Projects/示例项目"), "真实项目目录不算临时")
    check(!LLMRunner.isScratchPath("/tmp/digests/workshop"), "名字相近但不是工作目录的不算")
    check(!LLMRunner.isScratchPath(""), "空路径不算临时")

    // claude 不给会话持久化时仍会建空的项目目录，digest-clean 要顺带扫掉。
    let hollow = projects + "/-tmp-hollow"
    try FileManager.default.createDirectory(atPath: hollow + "/memory", withIntermediateDirectories: true)
    let swept = ScratchCleaner.clean(projectsRoot: projects)
    check(!FileManager.default.fileExists(atPath: hollow), "空项目目录被清掉")
    check(FileManager.default.fileExists(atPath: projects + "/-tmp-real/real.jsonl"), "有会话的项目保留")
    check(swept.removedProjects >= 1, "清掉的个数如实回报")
    check(ScratchCleaner.clean(projectsRoot: projects).removedProjects == 0, "再扫一次没有可清的")

    // 汇编自己的工作目录里存着提示词副本，清理时整片收掉。
    let workRoot = storeRoot + "/" + LLMRunner.workDirectoryName
    try FileManager.default.createDirectory(atPath: workRoot + "/2026-10-20-1", withIntermediateDirectories: true)
    try "材料副本".write(toFile: workRoot + "/2026-10-20-1/prompt.md", atomically: true, encoding: .utf8)
    let purged = DigestWorkspace.purge(storeRoot: storeRoot)
    check(purged.removed == 1, "清掉汇编工作目录")
    check(purged.bytes > 0, "腾出的体积如实回报")
    check(DigestWorkspace.purge(storeRoot: storeRoot).removed == 0, "再清一次没有可清的")
    unsetenv("AGENT_HISTORY_CLAUDE_PROJECTS")
} catch {
    print("  FAIL 临时会话用例：\(error)")
    failures += 1
}

print("MCP 接入：注册表")
do {
    let home = "/tmp/ah-registry-" + UUID().uuidString
    let targets = MCPTargetRegistry.all(home: home)
    check(targets.count == 6, "六个客户端都在注册表里")
    check(Set(targets.map { $0.kind }).count == 6, "客户端类型不重复")
    check(Set(targets.map { $0.rootPath }).count == 6, "根目录不重复")
    check(Set(targets.map { $0.configPath }).count == 6, "登记文件不重复")
    check(targets.map { $0.kind.rawValue } == ["codex", "claude", "workbuddy", "opencode", "kimi", "deepseek"],
          "顺序固定，界面和命令行一致")
    check(targets.allSatisfy { $0.rootPath.hasPrefix(home) }, "路径都挂在家目录下")
    check(targets.allSatisfy { !$0.note.isEmpty }, "每项都写了备注")
    check(Set(targets.map { $0.style }) == [.config, .command, .plugin], "三种接入方式都有覆盖")
    check(MCPTargetRegistry.parse("claude", home: home)?.kind == .claude, "英文短名能认")
    check(MCPTargetRegistry.parse("Claude Code", home: home)?.kind == .claude, "显示名能认")
    check(MCPTargetRegistry.parse("claudecode", home: home)?.kind == .claude, "习惯叫法能认")
    check(MCPTargetRegistry.parse("dsh", home: home)?.kind == .deepseek, "插件客户端也能按叫法认")
    check(MCPTargetRegistry.parse("不存在的客户端", home: home) == nil, "认不出的返回空")
}

print("MCP 接入：装没装、接没接")
do {
    let home = NSTemporaryDirectory() + "agent-history-onboard-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    let missing = MCPOnboarding.inspect(MCPTargetRegistry.target(.kimi, home: home))
    if case let .notInstalled(path) = missing.state {
        check(path.hasPrefix(home), "根目录不存在时报未安装")
    } else {
        check(false, "根目录不存在时不该报 " + missing.state.label)
    }

    // 装了但从来没配过。
    try FileManager.default.createDirectory(atPath: home + "/.kimi-code", withIntermediateDirectories: true)
    let unconfigured = MCPOnboarding.inspect(MCPTargetRegistry.target(.kimi, home: home))
    if case .notConfigured = unconfigured.state {
        check(true, "根目录在、没有登记文件时报未接入")
    } else {
        check(false, "没有登记文件时不该报 " + unconfigured.state.label)
    }
    check(!unconfigured.state.isFailure, "未接入不算故障")

    // 文件里有别的东西但没有本服务。
    try #"{"mcpServers": {"other": {"command": "/bin/echo"}}}"#
        .write(toFile: home + "/.kimi-code/mcp.json", atomically: true, encoding: .utf8)
    let other = MCPOnboarding.inspect(MCPTargetRegistry.target(.kimi, home: home))
    if case .notConfigured = other.state { check(true, "登记文件里没有本服务时报未接入") }
    else { check(false, "只有别的登记时不该报 " + other.state.label) }

    // 文件坏了。
    try "{ 这不是 JSON".write(toFile: home + "/.kimi-code/mcp.json", atomically: true, encoding: .utf8)
    let broken = MCPOnboarding.inspect(MCPTargetRegistry.target(.kimi, home: home))
    if case .broken = broken.state { check(true, "解析不了时报配置有问题") }
    else { check(false, "坏文件不该报 " + broken.state.label) }
    check(broken.state.isFailure, "坏文件算故障")

    // 关键一条：登记在、路径失效，不能算已接入。
    try #"{"mcpServers": {"agent-history": {"command": "/tmp/没有这个程序", "args": ["mcp"]}}}"#
        .write(toFile: home + "/.kimi-code/mcp.json", atomically: true, encoding: .utf8)
    let stale = MCPOnboarding.inspect(MCPTargetRegistry.target(.kimi, home: home))
    if case let .connectFailed(_, binary, reason, fixable) = stale.state {
        check(binary == "/tmp/没有这个程序", "报告的是登记里那个路径")
        check(reason.contains("不在了"), "原因是文件不在了")
        check(fixable, "路径失效可以一键修")
    } else {
        check(false, "路径失效时不该报 " + stale.state.label)
    }
    check(!stale.state.isUsable, "路径失效不能说成可用")
    check(stale.state.isFailure, "路径失效算故障")

    // 插件式的状态要跟配置式分开。
    let pluginMissing = MCPOnboarding.inspect(MCPTargetRegistry.target(.deepseek, home: home))
    if case .notInstalled = pluginMissing.state { check(true, "插件客户端没装时报未安装") }
    else { check(false, "插件客户端不该报 " + pluginMissing.state.label) }
    try FileManager.default.createDirectory(atPath: home + "/.dsh/profiles/desktop", withIntermediateDirectories: true)
    try #"{"dsh": {"profile": {"bundles": []}}}"#
        .write(toFile: home + "/.dsh/profiles/desktop/package.json", atomically: true, encoding: .utf8)
    let pluginOff = MCPOnboarding.inspect(MCPTargetRegistry.target(.deepseek, home: home))
    if case .pluginMissing = pluginOff.state { check(true, "bundles 里没有时报插件未装") }
    else { check(false, "插件未装不该报 " + pluginOff.state.label) }
    // 清单里登记了但插件实体不在，不能算装好。
    try #"{"dsh": {"profile": {"bundles": ["@local/agent-history-mcp"]}}}"#
        .write(toFile: home + "/.dsh/profiles/desktop/package.json", atomically: true, encoding: .utf8)
    let pluginHalf = MCPOnboarding.inspect(MCPTargetRegistry.target(.deepseek, home: home))
    if case .broken = pluginHalf.state { check(true, "清单有登记但实体不在时报配置有问题") }
    else { check(false, "实体不在不该报 " + pluginHalf.state.label) }
    // 补上实体。
    try FileManager.default.createDirectory(atPath: home + "/.agent-history/dsh-plugin", withIntermediateDirectories: true)
    let pluginOn = MCPOnboarding.inspect(MCPTargetRegistry.target(.deepseek, home: home))
    if case let .pluginInstalled(_, location) = pluginOn.state {
        check(location.contains("bundles"), "插件已装时报出登记位置")
        check(pluginOn.state.isUsable, "装好插件就算可用")
    } else {
        check(false, "装了插件不该报 " + pluginOn.state.label)
    }
    try? FileManager.default.removeItem(atPath: home)
}

print("MCP 接入：握手失败分类")
do {
    let dir = NSTemporaryDirectory() + "agent-history-handshake-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    if case let .failed(failure) = MCPHandshake.probe(binary: dir + "/不存在", timeout: 2) {
        check(failure == .missingBinary(dir + "/不存在"), "路径不存在时归类为找不到文件")
        check(failure.isPathProblem, "找不到文件属于路径问题，可以一键修")
    } else {
        check(false, "不存在的路径不该握手成功")
    }

    // 有文件但没执行权限。
    let plain = dir + "/not-exec"
    try "hello".write(toFile: plain, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain)
    if case let .failed(failure) = MCPHandshake.probe(binary: plain, timeout: 2) {
        check(failure == .notExecutable(plain), "没有执行权限时单独归类")
        check(failure.isPathProblem, "权限问题也能一键修")
    } else {
        check(false, "不可执行的文件不该握手成功")
    }

    // 能执行但立刻退出、什么都不输出。
    let silent = dir + "/silent.sh"
    try "#!/bin/sh\nexit 0\n".write(toFile: silent, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent)
    if case let .failed(failure) = MCPHandshake.probe(binary: silent, timeout: 3) {
        check(!failure.isPathProblem, "进程正常退出但没给清单，不算路径问题")
        check(failure.reason.contains("工具清单") || failure.reason.contains("退出码"),
              "能执行的程序没给清单时报清单缺失")
    } else {
        check(false, "立刻退出的程序不该握手成功")
    }

    // 一直挂着不回话，要靠超时收尾，不能把检查卡死。
    let hang = dir + "/hang.sh"
    try "#!/bin/sh\nwhile true; do sleep 1; done\n".write(toFile: hang, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hang)
    let started = Date()
    if case let .failed(failure) = MCPHandshake.probe(binary: hang, timeout: 2) {
        check(failure.reason.contains("超时"), "挂住的进程报超时")
    } else {
        check(false, "挂住的进程不该握手成功")
    }
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 8, "超时后能及时收尾，实测 " + String(format: "%.1f", elapsed) + " 秒")
    try? FileManager.default.removeItem(atPath: dir)
}

print("MCP 接入：JSON 只动自己那一条")
do {
    // 校验器本身先验一遍：JSONSerialization 放行尾逗号，文本手术不能放。
    func rejects(_ text: String) -> Bool {
        JSONSpan.validate([UInt8](text.utf8)) != nil
    }
    check(!rejects(#"{"a": 1}"#), "普通对象通过校验")
    check(!rejects(#"{"a": [1, 2, {"b": null}], "c": true, "d": -1.5e3}"#), "嵌套结构通过校验")
    check(!rejects("{\n  \"中文\": \"值\",\n  \"空\": {}\n}"), "中文键和多行通过校验")
    check(rejects(#"{"a": 1,}"#), "尾逗号被拦下")
    check(rejects(#"{"a": [1, 2,]}"#), "数组尾逗号被拦下")
    check(rejects(#"{"a": 1"#), "缺闭合括号被拦下")
    check(rejects(#"{"a" 1}"#), "缺冒号被拦下")
    check(rejects(#"{} extra"#), "尾巴多内容被拦下")
    check(rejects(#"{"a": }"#), "缺值被拦下")

    let root = NSTemporaryDirectory() + "agent-history-write-" + UUID().uuidString
    let backups = root + "/backups"
    try FileManager.default.createDirectory(atPath: backups, withIntermediateDirectories: true)
    let file = root + "/mcp.json"
    // 仿 WorkBuddy 的样子：旁边还有几十条别的登记。
    let others = (1...40).map { #""other-\#($0)": {"command": "/usr/bin/x\#($0)", "args": [], "disabled": true}"# }
    let original = "{\n  \"mcpServers\": {\n    " + others.joined(separator: ",\n    ")
        + "\n  },\n  \"version\": 2\n}\n"
    try original.write(toFile: file, atomically: true, encoding: .utf8)

    let backup = try MCPJSONWriter.upsert(path: file, key: "mcpServers", binary: "/bin/agent-history",
                                          format: .jsonServers(key: "mcpServers", commandIsArray: false),
                                          backupRoot: backups)
    check(FileManager.default.fileExists(atPath: backup), "写入前留了备份")
    let added = try String(contentsOfFile: file, encoding: .utf8)
    let parsed = (try? JSONSerialization.jsonObject(with: Data(added.utf8))) as? [String: Any]
    check(parsed != nil, "写完之后仍然是合法 JSON")
    let servers = parsed?["mcpServers"] as? [String: Any]
    check(servers?["agent-history"] != nil, "本服务那条加进去了")
    check(servers?.count == 41, "其他 40 条一条不少")
    check(parsed?["version"] as? Int == 2, "旁边的键没被动过")
    var keptAll = true
    for i in 1...40 {
        let entry = servers?["other-\(i)"] as? [String: Any]
        if entry?["command"] as? String != "/usr/bin/x\(i)" { keptAll = false }
    }
    check(keptAll, "40 条别的登记逐条对上")
    // 逐字节对比：除了新插入的那一块，其余全文不变。
    let head = "{\n  \"mcpServers\": {\n    " + others.joined(separator: ",\n    ")
    check(added.hasPrefix(head), "前面几十条逐字节一致")
    check(added.hasSuffix("\n  },\n  \"version\": 2\n}\n"), "尾部逐字节一致")

    // 再写一次应当就地替换，不重复添加。
    _ = try MCPJSONWriter.upsert(path: file, key: "mcpServers", binary: "/bin/agent-history-v2",
                                 format: .jsonServers(key: "mcpServers", commandIsArray: false),
                                 backupRoot: backups)
    let again = try String(contentsOfFile: file, encoding: .utf8)
    let againServers = ((try? JSONSerialization.jsonObject(with: Data(again.utf8))) as? [String: Any])?["mcpServers"] as? [String: Any]
    check(againServers?.count == 41, "重复接入不新增第二条")
    check((againServers?["agent-history"] as? [String: Any])?["command"] as? String == "/bin/agent-history-v2",
          "重复接入把路径更新成新的")
    check(again.contains("other-1"), "重复接入也没伤到别的登记")

    // 移除后要回到原样。
    _ = try MCPJSONWriter.remove(path: file, key: "mcpServers", backupRoot: backups)
    let removed = try String(contentsOfFile: file, encoding: .utf8)
    check((try? JSONSerialization.jsonObject(with: Data(removed.utf8))) != nil, "移除后仍是合法 JSON")
    let afterServers = ((try? JSONSerialization.jsonObject(with: Data(removed.utf8))) as? [String: Any])?["mcpServers"] as? [String: Any]
    check(afterServers?.count == 40, "移除后只剩原来那些")
    check(afterServers?["agent-history"] == nil, "本服务那条没了")
    check(removed == original, "移除后与原始文件逐字节一致")

    // 空对象也要能塞进去。
    let emptyFile = root + "/empty.json"
    try "{\n  \"mcpServers\": {}\n}\n".write(toFile: emptyFile, atomically: true, encoding: .utf8)
    _ = try MCPJSONWriter.upsert(path: emptyFile, key: "mcpServers", binary: "/bin/agent-history",
                                 format: .jsonServers(key: "mcpServers", commandIsArray: false),
                                 backupRoot: backups)
    let emptyText = try String(contentsOfFile: emptyFile, encoding: .utf8)
    check((try? JSONSerialization.jsonObject(with: Data(emptyText.utf8))) != nil, "空对象插入后是合法 JSON")
    check(emptyText.contains("\"agent-history\""), "空对象里也塞进去了")

    // 连 mcpServers 都没有。
    let bareFile = root + "/bare.json"
    try "{\n  \"theme\": \"dark\"\n}\n".write(toFile: bareFile, atomically: true, encoding: .utf8)
    _ = try MCPJSONWriter.upsert(path: bareFile, key: "mcpServers", binary: "/bin/agent-history",
                                 format: .jsonServers(key: "mcpServers", commandIsArray: false),
                                 backupRoot: backups)
    let bareText = try String(contentsOfFile: bareFile, encoding: .utf8)
    let bareParsed = (try? JSONSerialization.jsonObject(with: Data(bareText.utf8))) as? [String: Any]
    check(bareParsed?["theme"] as? String == "dark", "缺 mcpServers 时别的键不动")
    check((bareParsed?["mcpServers"] as? [String: Any])?["agent-history"] != nil, "缺 mcpServers 时自动补一层")

    // OpenCode 的 command 必须是数组。
    let ocFile = root + "/opencode.json"
    try "{\n  \"mcp\": {}\n}\n".write(toFile: ocFile, atomically: true, encoding: .utf8)
    _ = try MCPJSONWriter.upsert(path: ocFile, key: "mcp", binary: "/bin/agent-history",
                                 format: .jsonServers(key: "mcp", commandIsArray: true),
                                 backupRoot: backups)
    let ocText = try String(contentsOfFile: ocFile, encoding: .utf8)
    let ocParsed = (try? JSONSerialization.jsonObject(with: Data(ocText.utf8))) as? [String: Any]
    let ocEntry = (ocParsed?["mcp"] as? [String: Any])?["agent-history"] as? [String: Any]
    check(ocEntry?["command"] as? [String] == ["/bin/agent-history", "mcp"], "OpenCode 的 command 写成数组")
    check(ocEntry?["type"] as? String == "local", "OpenCode 的类型是 local")

    // 带尾逗号的文件拒绝动刀。
    let badFile = root + "/bad.json"
    try "{\"a\": 1,}".write(toFile: badFile, atomically: true, encoding: .utf8)
    var refused = false
    do {
        _ = try MCPJSONWriter.upsert(path: badFile, key: "mcpServers", binary: "/bin/x",
                                     format: .jsonServers(key: "mcpServers", commandIsArray: false),
                                     backupRoot: backups)
    } catch { refused = true }
    check(refused, "解析不了的 JSON 直接拒绝，不做手术")
    check(try String(contentsOfFile: badFile, encoding: .utf8) == "{\"a\": 1,}", "被拒绝的文件一个字节没动")
    try? FileManager.default.removeItem(atPath: root)
}

print("MCP 接入：TOML 只动自己那一段")
do {
    let root = NSTemporaryDirectory() + "agent-history-toml-" + UUID().uuidString
    let backups = root + "/backups"
    try FileManager.default.createDirectory(atPath: backups, withIntermediateDirectories: true)
    let file = root + "/config.toml"
    let original = [
        "# 顶部注释",
        "model = \"gpt-5\"",
        "",
        "[mcp_servers.agent-history]",
        "command = \"/old/AgentHistory\"",
        "args = [\"mcp\"]",
        "",
        "[mcp_servers.other]",
        "command = \"/usr/bin/other\"",
        "",
        "[profiles.fast]",
        "model = \"o4-mini\"",
        "",
    ].joined(separator: "\n")
    try original.write(toFile: file, atomically: true, encoding: .utf8)

    _ = try MCPTOMLWriter.upsert(path: file, prefix: "mcp_servers", binary: "/bin/new", backupRoot: backups)
    let updated = try String(contentsOfFile: file, encoding: .utf8)
    check(updated.contains("command = \"/bin/new\""), "路径被改写")
    check(!updated.contains("/old/AgentHistory"), "旧路径没留下")
    check(updated.contains("# 顶部注释"), "顶部注释还在")
    check(updated.contains("[mcp_servers.other]") && updated.contains("/usr/bin/other"), "别的段没动")
    check(updated.contains("[profiles.fast]") && updated.contains("o4-mini"), "无关段没动")
    check(updated.components(separatedBy: "[mcp_servers.agent-history]").count == 2, "段没有重复")

    _ = try MCPTOMLWriter.remove(path: file, prefix: "mcp_servers", backupRoot: backups)
    let stripped = try String(contentsOfFile: file, encoding: .utf8)
    check(!stripped.contains("[mcp_servers.agent-history]"), "整段被删掉")
    check(!stripped.contains("/bin/new"), "段里的内容一起删掉")
    check(stripped.contains("# 顶部注释"), "删段时注释不受影响")
    check(stripped.contains("[mcp_servers.other]") && stripped.contains("[profiles.fast]"), "删段时别的段不受影响")

    // 原本没有这一段时，接在末尾。
    _ = try MCPTOMLWriter.upsert(path: file, prefix: "mcp_servers", binary: "/bin/new", backupRoot: backups)
    let appended = try String(contentsOfFile: file, encoding: .utf8)
    check(appended.contains("[mcp_servers.agent-history]\ncommand = \"/bin/new\""), "缺段时追加到末尾")
    check(appended.hasPrefix("# 顶部注释"), "追加不影响开头")
    try? FileManager.default.removeItem(atPath: root)
}

print("MCP 接入：并发改动会回滚")
do {
    let root = NSTemporaryDirectory() + "agent-history-race-" + UUID().uuidString
    let backups = root + "/backups"
    try FileManager.default.createDirectory(atPath: backups, withIntermediateDirectories: true)
    let file = root + "/mcp.json"
    let original = "{\n  \"mcpServers\": {}\n}\n"
    try original.write(toFile: file, atomically: true, encoding: .utf8)

    // 备份之后、落盘之前，别的工具插一手。
    let intruded = "{\n  \"mcpServers\": {\"别人\": {\"command\": \"/bin/other\"}}\n}\n"
    SafeFile.beforeWriteHook = {
        try? intruded.write(toFile: file, atomically: true, encoding: .utf8)
    }
    var rolledBack = false
    var message = ""
    do {
        _ = try MCPJSONWriter.upsert(path: file, key: "mcpServers", binary: "/bin/x",
                                     format: .jsonServers(key: "mcpServers", commandIsArray: false),
                                     backupRoot: backups)
    } catch {
        rolledBack = true
        message = MCPOnboarder.describe(error)
    }
    SafeFile.beforeWriteHook = nil
    check(rolledBack, "发现被别的工具插了一手就放弃：" + message)
    let finalText = try String(contentsOfFile: file, encoding: .utf8)
    check(!finalText.contains("agent-history"), "没有覆盖掉别人写的内容")
    check(finalText.contains("别人"), "别人写的内容还在")
    let backupDirs = (try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? []
    check(!backupDirs.isEmpty, "放弃前也留了备份")
    try? FileManager.default.removeItem(atPath: root)
}

print("MCP 接入：预览与执行")
do {
    let home = NSTemporaryDirectory() + "agent-history-preview-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: home + "/.kimi-code", withIntermediateDirectories: true)
    let file = home + "/.kimi-code/mcp.json"
    let original = "{\n  \"mcpServers\": {}\n}\n"
    try original.write(toFile: file, atomically: true, encoding: .utf8)
    let target = MCPTargetRegistry.target(.kimi, home: home)

    let preview = try MCPOnboarder.preview(target, action: .connect, binary: "/bin/agent-history")
    check(preview.before == original, "预览里带着改动前的全文")
    check(preview.after.contains("/bin/agent-history"), "预览里能看出要写什么")
    check((try? JSONSerialization.jsonObject(with: Data(preview.after.utf8))) != nil, "预览结果本身就是合法 JSON")
    check(try String(contentsOfFile: file, encoding: .utf8) == original, "只看预览不改文件")
    check(preview.paths == [file], "预览说清改哪个文件")

    // 插件式不给一键接，要说清为什么。
    var pluginRefused = false
    do {
        _ = try MCPOnboarder.preview(MCPTargetRegistry.target(.deepseek, home: home), action: .connect)
    } catch {
        pluginRefused = MCPOnboarder.describe(error).contains("插件")
    }
    check(pluginRefused, "插件式接入明确说清要走插件市场")

    // 片段里的路径就是传进去的那份程序。
    let snippet = MCPOnboarder.snippet(target, binary: "/bin/agent-history")
    check(snippet.contains("/bin/agent-history"), "片段带上真实路径")
    check(snippet.contains("mcpServers"), "片段是对应格式")
    check(snippet.contains("\"mcp\""), "片段里参数是 mcp")

    let tomlSnippet = MCPOnboarder.snippet(MCPTargetRegistry.target(.codex, home: home), binary: "/bin/ah")
    check(tomlSnippet.hasPrefix("[mcp_servers.agent-history]"), "Codex 片段是 TOML 段")
    let claudeSnippet = MCPOnboarder.snippet(MCPTargetRegistry.target(.claude, home: home), binary: "/bin/ah")
    check(claudeSnippet.contains("claude mcp add"), "Claude 片段给的是官方命令")
    try? FileManager.default.removeItem(atPath: home)
}

print("MCP 接入：失效路径能一次改回")
do {
    let home = NSTemporaryDirectory() + "agent-history-repair-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: home + "/.kimi-code", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home + "/.codex", withIntermediateDirectories: true)
    try #"{"mcpServers": {"agent-history": {"command": "/tmp/旧程序", "args": ["mcp"]}}}"#
        .write(toFile: home + "/.kimi-code/mcp.json", atomically: true, encoding: .utf8)
    try "[mcp_servers.agent-history]\ncommand = \"/tmp/旧程序\"\nargs = [\"mcp\"]\n"
        .write(toFile: home + "/.codex/config.toml", atomically: true, encoding: .utf8)

    let reports = MCPOnboarding.inspectAll(home: home, parallel: true)
    check(reports.count == 6, "并行检查也返回六行")
    check(reports.map { $0.target.kind.rawValue } == ["codex", "claude", "workbuddy", "opencode", "kimi", "deepseek"],
          "并行检查仍是固定顺序")
    let stale = MCPOnboarder.staleRegistrations(reports: reports)
    check(stale.count == 2, "两台配置式客户端的路径都失效了")
    check(Set(stale.map { $0.target.kind }) == [.codex, .kimi], "认出的正是这两台")
    check(stale.allSatisfy { $0.oldBinary == "/tmp/旧程序" }, "记下了各自的旧路径")

    let healthy = MCPOnboarding.inspectAll(home: NSTemporaryDirectory() + "ah-空-" + UUID().uuidString)
    check(MCPOnboarder.staleRegistrations(reports: healthy).isEmpty, "都没装的时候没有要修的")
    try? FileManager.default.removeItem(atPath: home)
}

print("MCP 接入：升了级还指着旧包也要修")
do {
    let home = NSTemporaryDirectory() + "ah-outdated-" + UUID().uuidString
    let codex = MCPClientReport(target: MCPTargetRegistry.target(.codex, home: home),
                                state: .connected(path: "/tmp/c.toml", binary: "/tmp/旧程序",
                                                  location: "[mcp_servers.agent-history]",
                                                  tools: ["search_threads"]),
                                configPath: "/tmp/c.toml", checkedAt: Date())
    let outdated = MCPOnboarder.outdatedRegistrations(reports: [codex], binary: "/bin/新程序")
    check(outdated.count == 1, "登记的不是当前这份程序，要修")
    check(outdated.first?.oldBinary == "/tmp/旧程序", "记下了旧路径")
    check(MCPOnboarder.outdatedRegistrations(reports: [codex], binary: "/tmp/旧程序").isEmpty,
          "已经指着当前程序就不用动")
    check(MCPOnboarder.repairable(reports: [codex], binary: "/bin/新程序").count == 1,
          "一个客户端只算一次")

    let kimi = MCPClientReport(target: MCPTargetRegistry.target(.kimi, home: home),
                               state: .connectFailed(path: "/tmp/k.json", binary: "/tmp/没了",
                                                     reason: "文件不在", fixable: true),
                               configPath: "/tmp/k.json", checkedAt: Date())
    let merged = MCPOnboarder.repairable(reports: [kimi, codex], binary: "/bin/新程序")
    check(merged.count == 2, "失效的和落后的各算一个")
    check(Set(merged.map { $0.target.kind }) == [.codex, .kimi], "认出的正是这两台")
}

print("MCP 接入：Claude 多层登记")
do {
    let root = NSTemporaryDirectory() + "agent-history-claude-" + UUID().uuidString
    let backups = root + "/backups"
    try FileManager.default.createDirectory(atPath: backups, withIntermediateDirectories: true)
    let file = root + "/.claude.json"
    let original = [
        "{",
        "  \"numStartups\": 12,",
        "  \"mcpServers\": {",
        "    \"square\": {\"command\": \"/bin/square\"}",
        "  },",
        "  \"projects\": {",
        "    \"/tmp/a\": {",
        "      \"mcpServers\": {},",
        "      \"history\": []",
        "    }",
        "  }",
        "}",
    ].joined(separator: "\n")
    try original.write(toFile: file, atomically: true, encoding: .utf8)

    // 第一次接入：顶层没有，补在顶层。
    _ = try MCPJSONWriter.upsert(path: file, key: "mcpServers", binary: "/bin/ah",
                                 format: .claudeJSON, backupRoot: backups, replaceAll: true)
    let text = try String(contentsOfFile: file, encoding: .utf8)
    let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    check(parsed != nil, "Claude 配置写后仍可解析")
    check(((parsed?["mcpServers"] as? [String: Any])?["agent-history"]) != nil, "顶层登记写进去了")
    check(((parsed?["mcpServers"] as? [String: Any])?["square"]) != nil, "原本的 square 登记还在")
    check(parsed?["numStartups"] as? Int == 12, "旁边的计数没动")
    let project0 = (parsed?["projects"] as? [String: Any])?["/tmp/a"] as? [String: Any]
    check((project0?["history"] as? [Any])?.isEmpty == true, "项目里别的键没动")

    // 有人手工在两个项目层级都加过指向旧路径的登记，一次性改到新路径。
    let withProjects = [
        "{",
        "  \"mcpServers\": {",
        "    \"square\": {\"command\": \"/bin/square\"},",
        "    \"agent-history\": {\"command\": \"/old/ah\"}",
        "  },",
        "  \"projects\": {",
        "    \"/tmp/a\": {\"mcpServers\": {\"agent-history\": {\"command\": \"/old/ah\"}}},",
        "    \"/tmp/b\": {\"mcpServers\": {\"agent-history\": {\"command\": \"/old/ah\"},",
        "      \"other\": {\"command\": \"/bin/o\"}}}",
        "  }",
        "}",
    ].joined(separator: "\n")
    try withProjects.write(toFile: file, atomically: true, encoding: .utf8)
    _ = try MCPJSONWriter.upsert(path: file, key: "mcpServers", binary: "/bin/new-ah",
                                 format: .claudeJSON, backupRoot: backups, replaceAll: true)
    let fixedText = try String(contentsOfFile: file, encoding: .utf8)
    let fixed = (try? JSONSerialization.jsonObject(with: Data(fixedText.utf8))) as? [String: Any]
    check(fixed != nil, "多处改写后仍是合法 JSON")
    check(!fixedText.contains("/old/ah"), "三处旧路径全改掉了")
    check(((fixed?["mcpServers"] as? [String: Any])?["agent-history"] as? [String: Any])?["command"] as? String == "/bin/new-ah",
          "顶层换成新路径")
    let projectA = (fixed?["projects"] as? [String: Any])?["/tmp/a"] as? [String: Any]
    check(((projectA?["mcpServers"] as? [String: Any])?["agent-history"] as? [String: Any])?["command"] as? String == "/bin/new-ah",
          "项目 a 换成新路径")
    let projectB = (fixed?["projects"] as? [String: Any])?["/tmp/b"] as? [String: Any]
    check(((projectB?["mcpServers"] as? [String: Any])?["agent-history"] as? [String: Any])?["command"] as? String == "/bin/new-ah",
          "项目 b 换成新路径")
    check(((projectB?["mcpServers"] as? [String: Any])?["other"]) != nil, "项目 b 里别的登记没动")
    check(((fixed?["mcpServers"] as? [String: Any])?["square"]) != nil, "square 一直没动")

    _ = try MCPJSONWriter.remove(path: file, key: "mcpServers", backupRoot: backups, replaceAll: true)
    let removedText = try String(contentsOfFile: file, encoding: .utf8)
    let removedParsed = (try? JSONSerialization.jsonObject(with: Data(removedText.utf8))) as? [String: Any]
    check(!removedText.contains("agent-history"), "所有层级的本服务登记都删掉")
    check(removedText.contains("square"), "移除后 square 还在")
    check(((removedParsed?["projects"] as? [String: Any])?["/tmp/b"] as? [String: Any])?["mcpServers"] != nil,
          "项目 b 那一层还在")
    try? FileManager.default.removeItem(atPath: root)
}


print("记忆召回")
do {
    let root = NSTemporaryDirectory() + "agent-history-memory-\(UUID().uuidString)"
    let store = try Store(root: root)
    // 迁移只加表，既有三张表一行都不能多也不能少。
    let before = (threads: Int(try store.db.scalarInt("SELECT COUNT(*) FROM threads")),
                  items: Int(try store.db.scalarInt("SELECT COUNT(*) FROM items")),
                  handoffs: Int(try store.db.scalarInt("SELECT COUNT(*) FROM handoffs")))
    _ = try Store(root: root)
    let after = (threads: Int(try store.db.scalarInt("SELECT COUNT(*) FROM threads")),
                 items: Int(try store.db.scalarInt("SELECT COUNT(*) FROM items")),
                 handoffs: Int(try store.db.scalarInt("SELECT COUNT(*) FROM handoffs")))
    check(before == after, "重复迁移不新增会话、条目与交接记录")
    check(try store.db.scalarInt("SELECT COUNT(*) FROM memory_docs") == 0,
          "空库迁移后有记忆表且没有内容")

    // 会话在前，结论才有出处可挂。
    let threadId = try store.upsertThread(ThreadInput(
        sourceId: "codex", nativeId: "m1", projectPath: "/tmp/mem",
        title: "Nexus 升级讨论", createdAt: 1_700_000_000_000, updatedAt: 1_700_000_100_000,
        model: "gpt", threadSource: "user", archived: false, preview: "升级"))
    _ = try store.upsertItems(threadId: threadId, items: [
        ItemInput(nativeId: "n1", ordinal: 1, itemType: "userMessage", role: "user",
                  createdAt: 1_700_000_050_000, text: "Nexus 升级要不要我这边配合", rawJSON: "{}"),
    ])

    // 文件类记忆：按路径幂等，正文变了只更新不新增。
    let handoffPath = root + "/handoffs/demo.md"
    try "交接包正文：服务器归运维".write(toFile: handoffPath, atomically: true, encoding: .utf8)
    let first = try store.upsertMemoryFile(kind: .handoff, path: handoffPath,
                                          title: "demo", body: "交接包正文：服务器归运维",
                                          threadId: threadId)
    check(first.inserted, "首次登记交接包是新增")
    let second = try store.upsertMemoryFile(kind: .handoff, path: handoffPath,
                                           title: "demo", body: "交接包正文：服务器归运维",
                                           threadId: threadId)
    check(!second.inserted && second.id == first.id, "同一份文件再登记不算新增")
    check(try store.db.scalarInt("SELECT COUNT(*) FROM memory_docs WHERE kind='handoff'") == 1,
          "同一份文件只有一行")
    _ = try store.upsertMemoryFile(kind: .handoff, path: handoffPath, title: "demo改",
                                   body: "交接包正文：服务器由运维负责，别找开源组",
                                   threadId: threadId)
    check(try store.db.scalarInt("SELECT COUNT(*) FROM memory_docs WHERE kind='handoff'") == 1,
          "正文改了还是同一行")
    check(try store.searchMemory("开源组").count == 1, "改过的正文立刻能被记忆检索命中")

    // 结论：三值类别、判重、取代、作废。
    let decision = try store.rememberFact(body: "Nexus 升级是公司服务器的事，和开源项目没关系",
                                          category: "决策", threadId: threadId, itemOrdinal: 1)
    check(!decision.duplicate, "首次记结论不是重复")
    let sameAgain = try store.rememberFact(body: "Nexus 升级是公司服务器的事，和开源项目没关系",
                                           category: "决策", threadId: threadId)
    check(sameAgain.duplicate && sameAgain.id == decision.id, "同一会话同一正文判为重复")
    check(try store.db.scalarInt("SELECT COUNT(*) FROM memory_docs WHERE kind='fact'") == 1,
          "重复写入只留一行")
    let spaced = try store.rememberFact(body: "Nexus 升级是公司服务器的事， 和开源项目没关系。",
                                        category: "决策", threadId: threadId)
    check(spaced.duplicate, "多一个空格和句号仍算同一条")
    do {
        _ = try store.rememberFact(body: "随便写", category: "猜测", threadId: threadId)
        check(false, "第四个类别应被拒绝")
    } catch {
        check("\(error)".contains("category"), "第四个类别给出允许值说明")
    }
    do {
        _ = try store.rememberFact(body: "   ", category: "事实")
        check(false, "空正文应被拒绝")
    } catch { check(true, "空正文被拒绝") }
    do {
        _ = try store.rememberFact(body: String(repeating: "长", count: 4001), category: "事实")
        check(false, "超长正文应被拒绝")
    } catch { check(true, "超长正文被拒绝") }
    check(try store.db.scalarInt("SELECT COUNT(*) FROM memory_docs WHERE kind='fact'") == 1,
          "被拒的写入没有留下任何行")

    let replacement = try store.rememberFact(body: "Nexus 归服务器运维，开源项目不跟",
                                             category: "决策", threadId: threadId,
                                             supersedes: decision.id)
    let superseded = try store.memoryDoc(id: decision.id)
    check(superseded?.status == "superseded" && superseded?.supersededBy == replacement.id,
          "被取代的条目状态与指向都对")
    check(superseded?.body.isEmpty == false, "被取代的条目正文还在")
    let active = try store.searchMemory("开源项目")
    check(active.allSatisfy { $0.doc.status == "active" }, "默认检索不返回被取代的条目")
    let all = try store.searchMemory("开源项目", includeInactive: true)
    check(all.count == 2, "勾上包含失效后两条都在")

    do {
        _ = try store.rememberFact(body: "再写一条", category: "事实", threadId: threadId,
                                   supersedes: "不存在的标识")
        check(false, "取代目标不存在应被拒绝")
    } catch { check(true, "取代目标不存在时拒绝写入") }

    _ = try store.voidFact(id: replacement.id)
    check(try store.memoryDoc(id: replacement.id)?.status == "void", "作废只改状态")
    check(try store.voidFact(id: replacement.id) == nil, "重复作废不报错也不改动")
    check(try store.searchMemory("开源项目").isEmpty, "作废后默认检索不再返回")
    do {
        _ = try store.voidFact(id: first.id)
        check(false, "交接包不能当作结论作废")
    } catch { check(true, "交接包不能作废") }

    // 按会话取回：交接包与结论都算这个会话的记忆，汇编不按会话归属。
    let forThread = try store.memoryForThread(threadId)
    check(forThread.contains { $0.kind == .handoff }, "按会话能取回交接包")
    check(forThread.contains { $0.kind == .fact } == false, "作废的结论不出现在会话记忆里")

    // 检索范围：默认只看会话，一个字都不变。
    check(SearchOptions().scope == .threads, "检索范围默认是会话")
    check(SearchScope.allCases.map(\.rawValue) == ["threads", "memory", "all"],
          "范围只有会话、记忆、全部三值")
    let digestPath = root + "/digests/2026-10-26-主题汇编.md"
    try FileManager.default.createDirectory(atPath: root + "/digests", withIntermediateDirectories: true)
    try "汇编正文：Nexus 归运维".write(toFile: digestPath, atomically: true, encoding: .utf8)
    _ = try store.upsertMemoryFile(kind: .digest, path: digestPath, title: "2026-10-26-主题汇编",
                                   body: "汇编正文：Nexus 升级归服务器运维，和开源项目分开")
    let defaultHits = try store.search("运维")
    check(defaultHits.allSatisfy { !$0.isMemory }, "默认范围不会混进记忆")
    var memoryOnly = SearchOptions()
    memoryOnly.scope = .memory
    let memHits = try store.search("运维", options: memoryOnly)
    check(memHits.count == 2 && memHits.allSatisfy(\.isMemory), "记忆范围只返回记忆")
    check(memHits.allSatisfy { $0.memoryId?.isEmpty == false }, "记忆命中带 memory_id")
    var everything = SearchOptions()
    everything.scope = .all
    let both = try store.search("Nexus", options: everything)
    check(both.contains { $0.isMemory } && both.contains { !$0.isMemory },
          "全部范围两类命中同列")
    check(both.contains { $0.isMemory && $0.kindLabel == "汇编" }, "命中行带类别前缀")

    // 会话命中把名额占满时，记忆不能一条都进不来，否则「全部」等于「只看会话」。
    var tight = SearchOptions()
    tight.scope = .all
    tight.limit = 1
    let tightHits = try store.search("Nexus", options: tight)
    check(tightHits.count == 1, "上限收窄后只给一条")
    check(tightHits.first?.isMemory == true, "名额再紧也要给记忆留出来")

    var roomy = SearchOptions()
    roomy.scope = .all
    roomy.limit = 60
    let roomyHits = try store.search("Nexus", options: roomy)
    check(roomyHits.contains { $0.isMemory }, "会话很多时记忆仍然出现")
    check(roomyHits.filter { $0.isMemory }.count <= 30, "记忆最多占一半名额")

    // 补录：只认磁盘上还在的文件，跑第二遍全跳过。
    let firstBackfill = try store.backfillMemory()
    check(firstBackfill.added == 0 && firstBackfill.removed == 0,
          "已经登记过的文件补录不重复")
    try FileManager.default.removeItem(atPath: digestPath)
    let cleaned = try store.backfillMemory()
    check(cleaned.removed == 1, "磁盘上删掉的文件补录时清掉索引")
    check(try store.searchMemory("分开").isEmpty, "清掉之后检索不到")
    check(try store.memoryDoc(id: first.id) != nil, "没删的文件索引一直留着")

    // 来源会话删掉后，结论仍能取回，并看得出出处没了。
    try store.db.run("DELETE FROM threads WHERE id=?", [threadId])
    let orphan = try store.memoryDoc(id: decision.id)
    check(orphan?.threadId == threadId, "来源会话删了也带着原始会话标识")
    check((try? store.thread(id: threadId)) == nil, "来源会话确实不在了")

    let counts = try store.memoryCounts()
    check(counts.handoffs == 1 && counts.facts == 0, "分类计数只数还能用的条目")

    try? FileManager.default.removeItem(atPath: root)
} catch {
    print("  FAIL 记忆用例：\(error)")
    failures += 1
}


print("WorkBuddy 分组")
let wbRoot = NSTemporaryDirectory() + "agent-history-wb-\(UUID().uuidString)"
do {
    let projects = wbRoot + "/projects"
    try FileManager.default.createDirectory(atPath: projects + "/tmp-demo", withIntermediateDirectories: true)
    setenv("AGENT_HISTORY_WORKBUDDY_PROJECTS", projects, 1)
    setenv("AGENT_HISTORY_WORKBUDDY_DB", wbRoot + "/workbuddy.db", 1)
    let ledger = try Database(path: wbRoot + "/workbuddy.db")
    try ledger.exec("""
    CREATE TABLE sessions(id TEXT PRIMARY KEY, cwd TEXT NOT NULL, user_id TEXT NOT NULL,
        title TEXT, custom_title TEXT, status TEXT NOT NULL DEFAULT 'Pending',
        created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, last_activity_at INTEGER,
        deleted_at INTEGER, is_playground INTEGER NOT NULL DEFAULT 0, source_mode TEXT,
        mode TEXT, model TEXT, permission_mode TEXT, unread INTEGER NOT NULL DEFAULT 0,
        project_id TEXT, transport TEXT NOT NULL DEFAULT 'local', conversation_origin TEXT,
        group_id TEXT, group_title TEXT, plugin_context_json TEXT,
        last_user_prompt_expert_selection TEXT)
    """)
    try ledger.run("""
    INSERT INTO sessions(id,cwd,user_id,title,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?)
    """, ["seed", "/tmp/demo", "u1", "占位", "completed", 1, 1])

    // 一条导出会话：侧栏按 cwd 归进「工作空间」靠的是 is_playground=0，写 1 就全掉进「任务」。
    let sid = UUID().uuidString.lowercased()
    let file = projects + "/tmp-demo/" + sid + ".jsonl"
    let lines = [
        "{\"type\":\"ai-title\",\"aiTitle\":\"按项目分组\",\"sessionId\":\"\(sid)\",\"cwd\":\"/tmp/demo\",\"timestamp\":1700000000000}",
        "{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"你好\"}],\"sessionId\":\"\(sid)\",\"cwd\":\"/tmp/demo\",\"timestamp\":1700000000500}",
    ]
    try lines.joined(separator: "\n").appending("\n").write(toFile: file, atomically: true, encoding: .utf8)

    let store = try Store(root: wbRoot + "/store")
    try WorkBuddyRegistry.register(file: file, store: store)
    let playground = try ledger.scalarInt("SELECT is_playground FROM sessions WHERE id=?", [sid])
    check(playground == 0, "导出会话登记成工作空间而不是任务")

    // 早先的导出给同一会话留过一行只有标题、没有文件的重复行，登记时收掉。
    try ledger.run("""
    INSERT INTO sessions(id,cwd,user_id,title,status,created_at,updated_at,is_playground)
    VALUES(?,?,?,?,?,?,?,1)
    """, ["ghost", "/tmp/demo", "u1", "按项目分组", "completed", 1700000000000, 1700000000000])
    try WorkBuddyRegistry.register(file: file, store: store)
    let ghostDeleted = try ledger.scalarInt("SELECT count(*) FROM sessions WHERE id='ghost' AND deleted_at IS NOT NULL")
    let ghostGone = try ledger.scalarInt("SELECT count(*) FROM sessions WHERE deleted_at IS NULL")
    check(ghostDeleted == 1, "没有文件那行被软删")
    check(ghostGone == 2, "侧栏只剩会话本身和占位行")

    // 用户自己删掉的会话不该被重新登记拉回来。
    try ledger.run("UPDATE sessions SET deleted_at=? WHERE id=?", [1_700_000_900_000, sid])
    try WorkBuddyRegistry.register(file: file, store: store)
    let resurrected = try ledger.scalarInt("SELECT count(*) FROM sessions WHERE id=? AND deleted_at IS NULL", [sid])
    check(resurrected == 0, "已删会话不会被重新登记复活")

    unsetenv("AGENT_HISTORY_WORKBUDDY_PROJECTS")
    unsetenv("AGENT_HISTORY_WORKBUDDY_DB")
    try? FileManager.default.removeItem(atPath: wbRoot)
} catch {
    print("  FAIL WorkBuddy 用例：\(error)")
    failures += 1
}

print(failures == 0 ? "全部通过" : "失败 \(failures) 项")

exit(failures == 0 ? 0 : 1)
