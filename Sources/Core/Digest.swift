import Foundation

// MARK: - 选项

/// 主题汇编的取数口径。默认看最近 7 天。
struct DigestOptions {
    var since: Int64 = Int64((Date().timeIntervalSince1970 - 7 * 86_400) * 1000)
    var until: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    var sourceKind: SourceKind?
    var projectPath: String?
    /// 关掉就只出按天的轮次摘要，不调外部模型。
    var useLLM = true
    /// 外部模型命令：提示词走标准输入，汇编正文从标准输出回来。
    var command = LLMRunner.defaultCommand
    /// 走 HTTP 接口时填这一项，命令行留空也不用。两条通路都在时接口优先。
    var api: LLMAPI?
    /// 单次调用的超时。分段提炼时按每次调用算。
    /// 本机 claude -p 空跑就要一两分钟（后端排队），留足余量，别把慢的段当失败。
    var timeout: TimeInterval = 600
    var title = ""
    /// 指定落盘目录，留空用库目录下的 digests。
    var outputDirectory: String?
    /// 单次调用最多塞多少字的材料，超了就拆成多段提炼。
    /// 一天的场景材料通常在 1 万到 3 万字，取 2.4 万基本是「一天一次调用」。
    var chunkLimit = 24_000
    /// 同时跑几段。
    var parallel = 5
    /// 同一段材料提炼过一次就不再调模型。跑「最近 7 天」时，
    /// 只有今天那一段有变化，前面几天应当直接复用。
    var useCache = true
}

// MARK: - 取数

struct DigestTurn {
    let threadId: String
    let threadTitle: String
    let sourceKind: SourceKind
    let projectPath: String
    /// 这一轮在会话里的序号，同一会话的连续轮次靠它排。
    let ordinal: Int
    let startedAt: Int64
    let question: String
    let answer: String
    let toolCount: Int
}

struct DigestThreadGroup {
    let id: String
    let title: String
    let source: SourceKind
    let path: String
    let turns: [DigestTurn]

    var displayTitle: String { title.isEmpty ? "（无标题会话）" : title }
}

struct DigestDay: Identifiable {
    /// 2026-10-24
    let key: String
    /// 10月24日 周六
    let label: String
    let turns: [DigestTurn]
    var id: String { key }

    /// 同一天里按会话归拢，同一会话的多轮排在一起。
    var threads: [DigestThreadGroup] {
        var order: [String] = []
        var buckets: [String: [DigestTurn]] = [:]
        for turn in turns {
            if buckets[turn.threadId] == nil { order.append(turn.threadId) }
            buckets[turn.threadId, default: []].append(turn)
        }
        return order.compactMap { id in
            guard let list = buckets[id], let first = list.first else { return nil }
            return DigestThreadGroup(id: id, title: first.threadTitle, source: first.sourceKind,
                                     path: first.projectPath, turns: list)
        }
    }
}

struct DigestPlan {
    let options: DigestOptions
    let days: [DigestDay]
    let turns: [DigestTurn]
    let rangeLabel: String
    /// 只有工具输出或模板消息、被挡在汇编外的轮数。
    let skippedTurns: Int

    var threadCount: Int { Set(turns.map { $0.threadId }).count }
    var dayCount: Int { days.count }
    var turnCount: Int { turns.count }
    var isEmpty: Bool { turns.isEmpty }

    var summary: String {
        var parts = ["\(dayCount) 天", "\(threadCount) 个会话", "\(turnCount) 轮"]
        if skippedTurns > 0 { parts.append("另有 \(skippedTurns) 轮是自动化或空轮，已略过") }
        return parts.joined(separator: " · ")
    }
}

extension Store {
    /// 删掉汇编自己留下的假会话：claude 把工具的工作目录记成会话，同步时会一起收进来。
    /// 只按项目路径和来源认，不碰真实对话。返回删掉的会话数。
    @discardableResult
    func purgeDigestScratch(sourceId: String = SourceKind.claude.rawValue) throws -> Int {
        let candidates = try db.query("SELECT id, cwd FROM threads WHERE source_id=?", [sourceId]) { st in
            (id: st.text(0), cwd: st.text(1))
        }
        let ids = candidates.filter { LLMRunner.isScratchPath($0.cwd) }.map(\.id)
        guard !ids.isEmpty else { return 0 }
        try db.transaction {
            for id in ids {
                let projectIds = try db.query("SELECT DISTINCT project_id FROM threads WHERE id=? AND project_id IS NOT NULL",
                                              [id]) { $0.text(0) }
                // 检索索引按 items 的 rowid 存，删条目前先把对应行一起清掉。
                let rowids = try db.query("SELECT rowid FROM items WHERE thread_id=?", [id]) { $0.int64(0) }
                for rid in rowids { try db.run("DELETE FROM search_docs WHERE rowid=?", [rid]) }
                for (table, column) in [("items", "thread_id"), ("turns", "thread_id"),
                                        ("thread_links", "thread_id"), ("sync_state", "thread_id")] {
                    try db.run("DELETE FROM \(table) WHERE \(column)=?", [id])
                }
                try db.run("DELETE FROM threads WHERE id=?", [id])
                // 只为这些假会话建的项目一起收掉，别让侧边栏继续挂着 digests/work 这种目录。
                for pid in projectIds {
                    let left = try db.scalarInt("SELECT COUNT(*) FROM threads WHERE project_id=?", [pid])
                    if left == 0 { try db.run("DELETE FROM projects WHERE id=?", [pid]) }
                }
            }
        }
        return ids.count
    }

    /// 取时间窗内的轮次。副本会话不进汇编，避免同一段对话写两遍。
    func digestTurns(_ options: DigestOptions) throws -> [DigestTurn] {
        var sql = """
        SELECT t.thread_id, th.title, th.source_id, th.cwd, t.ordinal,
               COALESCE(NULLIF(t.started_at,0),
                        (SELECT MIN(i.created_at) FROM items i WHERE i.turn_id=t.id)) AS ts,
               COALESCE((SELECT i.text FROM items i WHERE i.turn_id=t.id AND i.role='user'
                         ORDER BY i.ordinal LIMIT 1),'') AS question,
               COALESCE((SELECT i.text FROM items i WHERE i.turn_id=t.id AND i.item_type='agentMessage'
                         ORDER BY i.ordinal DESC LIMIT 1),'') AS answer,
               (SELECT COUNT(*) FROM items i WHERE i.turn_id=t.id
                  AND i.item_type IN ('commandExecution','toolResult','fileChange','mcpToolCall')) AS tools
        FROM turns t
        JOIN threads th ON th.id=t.thread_id
        LEFT JOIN thread_links l ON l.thread_id=th.id
        WHERE COALESCE(l.role,'')<>'copy'
          AND COALESCE(NULLIF(t.started_at,0),
                       (SELECT MIN(i.created_at) FROM items i WHERE i.turn_id=t.id))>=?
          AND COALESCE(NULLIF(t.started_at,0),
                       (SELECT MIN(i.created_at) FROM items i WHERE i.turn_id=t.id))<?
        """
        var binds: [Any?] = [options.since, options.until]
        if let kind = options.sourceKind { sql += " AND th.source_id=?"; binds.append(kind.rawValue) }
        if let path = options.projectPath { sql += " AND th.cwd=?"; binds.append(path) }
        sql += " ORDER BY ts ASC, t.ordinal ASC"

        return try db.query(sql, binds) { st in
            DigestTurn(threadId: st.text(0), threadTitle: st.text(1),
                       sourceKind: SourceKind(rawValue: st.text(2)) ?? .codex,
                       projectPath: st.text(3), ordinal: st.int(4), startedAt: st.int64(5),
                       question: st.text(6), answer: st.text(7), toolCount: st.int(8))
        }
    }
}

// MARK: - 分段

/// 一次模型调用吃的材料。
struct DigestSegment {
    let dayKey: String
    let dayLabel: String
    /// 同一天材料太长时拆开，这里记第几段。
    let part: Int
    let turns: [DigestTurn]
    let material: String
}

// MARK: - 组装材料

enum DigestPlanner {
    static let questionLimit = 500
    static let answerLimit = 700

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 这些轮次是定时任务自己跟自己说话，写进汇编只会变成噪音。
    static func isNoise(_ turn: DigestTurn) -> Bool {
        let q = turn.question
        if q.contains("<heartbeat>") || q.contains("<automation_id>") { return true }
        if q.contains("Automation ID:") && q.contains("Automation memory:") { return true }
        let asked = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let answered = turn.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return asked.isEmpty && answered.isEmpty
    }

    static func build(store: Store, options: DigestOptions) throws -> DigestPlan {
        let raw = try store.digestTurns(options)
        let kept = raw.filter { !isNoise($0) }
        return DigestPlan(options: options, days: group(kept), turns: kept,
                          rangeLabel: rangeLabel(options.since, options.until),
                          skippedTurns: raw.count - kept.count)
    }

    static func segments(_ plan: DigestPlan, limit: Int) -> [DigestSegment] {
        var out: [DigestSegment] = []
        for day in plan.days {
            var bucket: [DigestTurn] = []
            var part = 1
            func flush() {
                guard !bucket.isEmpty else { return }
                out.append(DigestSegment(dayKey: day.key, dayLabel: day.label, part: part,
                                         turns: bucket,
                                         material: materialText(bucket, dayLabel: day.label)))
                bucket = []
                part += 1
            }
            for turn in day.turns {
                // 按真拼出来的长度算，单轮估长会把同一会话的表头重复计进去，白拆一段。
                if !bucket.isEmpty {
                    bucket.append(turn)
                    let size = materialText(bucket, dayLabel: day.label).count
                    bucket.removeLast()
                    if size > limit { flush() }
                }
                bucket.append(turn)
            }
            flush()
        }
        return out
    }

    static func group(_ turns: [DigestTurn]) -> [DigestDay] {
        var order: [String] = []
        var buckets: [String: [DigestTurn]] = [:]
        for turn in turns {
            let key = dayKey(turn.startedAt)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(turn)
        }
        return order.map { key in
            DigestDay(key: key, label: dayLabel(key), turns: buckets[key] ?? [])
        }
    }

    static func dayKey(_ ms: Int64) -> String {
        guard ms > 0 else { return "未标时间" }
        return keyFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    static func dayLabel(_ key: String) -> String {
        guard let date = keyFormatter.date(from: key) else { return key }
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        let comps = cal.dateComponents([.month, .day, .weekday], from: date)
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = max(1, min(7, comps.weekday ?? 1)) - 1
        return "\(comps.month ?? 0)月\(comps.day ?? 0)日 \(names[index])"
    }

    static func rangeLabel(_ since: Int64, _ until: Int64) -> String {
        let a = dayLabel(dayKey(since))
        let b = dayLabel(dayKey(until))
        return a == b ? a : "\(a) 至 \(b)"
    }

    static func materialText(_ turns: [DigestTurn], dayLabel: String) -> String {
        var out = "# 对话材料 · \(dayLabel)\n"
        for thread in group(turns).first?.threads ?? [] {
            out += "\n### \(thread.displayTitle) ｜\(thread.source.displayName)"
            if !thread.path.isEmpty { out += " ｜\(thread.path)" }
            out += "\n"
            for turn in thread.turns {
                let clock = turn.startedAt > 0
                    ? clockFormatter.string(from: Date(timeIntervalSince1970: Double(turn.startedAt) / 1000))
                    : "--:--"
                out += "- \(clock) 问：\(clip(turn.question, questionLimit))\n"
                let answer = clip(turn.answer, answerLimit)
                if !answer.isEmpty {
                    out += "  答：\(answer.replacingOccurrences(of: "\n", with: "\n  "))\n"
                }
                if turn.toolCount > 0 { out += "  （当轮另有 \(turn.toolCount) 条工具输出，已省略）\n" }
            }
        }
        return out
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}

// MARK: - 外部模型

enum DigestError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}

enum LLMRunner {
    /// 老版本写死的那条命令，只用于迁移已存的设置，不再当默认值。
    static let legacyCommand = "claude -p --no-session-persistence"

    /// 默认命令不写死：按本机实际装了什么挑第一条能跑的。一个都没探测到就留空，
    /// 让上层提示「没有可用通路」，而不是硬塞一条注定失败的 claude。
    /// Claude Code 那条的 --no-session-persistence 是必须的：不加的话每次调用都会在
    /// ~/.claude/projects 落一份会话，同步时会被当成真实对话收进库，汇编自己喂自己。
    static var defaultCommand: String {
        LLMDetector.detect().first?.preset.command ?? ""
    }

    /// 命令的第一个词就是可执行文件名，带引号的先去掉引号。
    static func binary(of command: String) -> String {
        let first = command.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first.map(String.init) ?? ""
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// 命令里的可执行文件在不在。找不到就给一句能照着办的话，别只说「命令失败」。
    static func check(command: String) throws {
        let name = binary(of: command)
        guard !name.isEmpty else { throw DigestError.message("汇编命令是空的") }
        if name.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: name) else {
                throw DigestError.message("找不到 \(name)")
            }
            return
        }
        guard LLMDetector.which(name) != nil else {
            let found = LLMDetector.detect(force: true).map { $0.preset.label }.joined(separator: "、")
            let hint = found.isEmpty
                ? "这台机器上没找到可用的模型命令行。填一个接口地址和模型名就能用，或者装上 Claude Code、Codex 之类的工具"
                : "本机能用的有\(found)，换成对应的命令就行"
            throw DigestError.message("找不到 \(name) 这个命令。\(hint)")
        }
    }

    /// 汇编用的临时工作目录，同步时按这个前缀排除，避免把提示词当成对话。
    static let workDirectoryName = "digests/work"

    /// 判断一个路径是不是汇编的临时工作目录。
    /// 不只看当前库根目录：换过库目录、或者用副本库跑过，历史里也会留下别的根下的路径，
    /// 所以按路径片段认，只要落在某个 digests/work 下面就算。
    static func isScratchPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return normalized.contains("/" + workDirectoryName + "/")
            || normalized.hasSuffix("/" + workDirectoryName)
            || normalized == workDirectoryName
    }

    /// 超时标记要跨线程读写，单独包一层。
    private final class Flag {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// 简单命令前面加 exec，超时的时候杀的是真正干活的进程，不留孤儿子进程。
    private static func isSimpleCommand(_ command: String) -> Bool {
        if command.contains("\u{60}") { return false }
        let meta = CharacterSet(charactersIn: ";|&<>$()")
        return command.rangeOfCharacter(from: meta) == nil
    }

    static func run(command: String, prompt: String, timeout: TimeInterval,
                    workDir: String) throws -> (output: String, seconds: TimeInterval) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DigestError.message("汇编命令是空的") }
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: workDir, withIntermediateDirectories: true) }
        catch { throw DigestError.message("无法建工作目录 \(workDir)：\(error)") }
        let promptFile = workDir + "/prompt.md"
        let errorFile = workDir + "/stderr.log"
        do { try prompt.write(toFile: promptFile, atomically: true, encoding: .utf8) }
        catch { throw DigestError.message("无法写入提示词：\(error)") }
        fm.createFile(atPath: errorFile, contents: nil)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", isSimpleCommand(trimmed) ? "exec " + trimmed : trimmed]
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        var env = ProcessInfo.processInfo.environment
        env["AGENT_HISTORY_DIGEST"] = "1"
        process.environment = env
        guard let input = FileHandle(forReadingAtPath: promptFile) else {
            throw DigestError.message("无法读取提示词文件")
        }
        process.standardInput = input
        let outPipe = Pipe()
        process.standardOutput = outPipe
        guard let errHandle = FileHandle(forWritingAtPath: errorFile) else {
            throw DigestError.message("无法写入错误日志")
        }
        process.standardError = errHandle

        let started = Date()
        do { try process.run() }
        catch { throw DigestError.message("无法启动汇编命令：\(error.localizedDescription)") }

        let flag = Flag()
        let watch = DispatchWorkItem {
            flag.mark()
            process.terminate()
            // 给 3 秒收尾，之后强杀，避免卡死在等模型的调用里。
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(5, timeout), execute: watch)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watch.cancel()
        try? input.close()
        try? errHandle.close()
        let seconds = Date().timeIntervalSince(started)

        if flag.isSet {
            throw DigestError.message("模型 \(Int(timeout)) 秒内没有返回")
        }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            let stderr = ((try? String(contentsOfFile: errorFile, encoding: .utf8)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = stderr.isEmpty ? "" : "：" + String(stderr.suffix(240))
            throw DigestError.message("汇编命令退出码 \(process.terminationStatus)\(tail)")
        }
        guard !output.isEmpty else { throw DigestError.message("汇编命令没有输出内容") }
        return (output, seconds)
    }
}

// MARK: - 执行与落盘

/// 提炼结果的磁盘缓存。
///
/// 「最近 7 天」这种范围，第二天再跑一遍时前面几天一个字都没变，却要重新付一次
/// 模型调用的钱和时间。这里按材料正文算一个稳定指纹，命中就直接复用。
/// 指纹里带上通路标识：换了模型或换了接口，缓存自动失效，不会拿旧模型的结果充数。
enum DigestCache {
    /// FNV-1a。String.hashValue 每个进程都不一样，不能落盘。
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    static func directory(storeRoot: String) -> String {
        storeRoot + "/digests/cache"
    }

    static func key(material: String, route: String) -> String {
        fingerprint(route + " # " + material)
    }

    static func load(storeRoot: String, key: String) -> String? {
        let path = directory(storeRoot: storeRoot) + "/" + key + ".md"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(storeRoot: String, key: String, text: String) {
        let dir = directory(storeRoot: storeRoot)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: dir + "/" + key + ".md", atomically: true, encoding: .utf8)
    }

    /// 清掉整个缓存，命令行 digest-clean 用得上。
    @discardableResult
    static func purge(storeRoot: String) -> (count: Int, bytes: Int64) {
        let dir = directory(storeRoot: storeRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return (0, 0) }
        var count = 0
        var bytes: Int64 = 0
        for name in names where name.hasSuffix(".md") {
            let path = dir + "/" + name
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
            if (try? FileManager.default.removeItem(atPath: path)) != nil {
                count += 1
                bytes += size
            }
        }
        return (count, bytes)
    }

    /// 缓存只留最近的若干份。
    /// 会话改一个字指纹就变，旧条目再也不会被命中，不清的话这个目录会一直长下去。
    @discardableResult
    static func trim(storeRoot: String, keep: Int = 600) -> Int {
        let dir = directory(storeRoot: storeRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
        let entries: [(path: String, at: Date)] = names.filter { $0.hasSuffix(".md") }.compactMap { name in
            let path = dir + "/" + name
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let at = attrs[.modificationDate] as? Date else { return nil }
            return (path, at)
        }
        guard entries.count > keep else { return 0 }
        var removed = 0
        for item in entries.sorted(by: { $0.at > $1.at }).dropFirst(keep)
        where (try? FileManager.default.removeItem(atPath: item.path)) != nil {
            removed += 1
        }
        return removed
    }
}

struct DigestResult {
    var markdown = ""
    var path = ""
    /// 这一份是怎么来的：模型提炼还是按天摘要，连同原因。
    var note = ""
    var usedLLM = false
    var seconds: TimeInterval = 0
    var turnCount = 0
    var dayCount = 0
    var threadCount = 0
    /// 走了几次模型调用。
    var calls = 0
    /// 其中有多少段是直接复用的上次结果。
    var cachedCalls = 0

    var isEmpty: Bool { markdown.isEmpty }
}

enum DigestRunner {
    static let dayInstruction = """
    你是我的工作助理。下面是我某一天的对话记录，请把这一天压成要点。

    要求：
    1. 只写这天真正定下来的事项：结论、决定、方案取舍、进度、做过的事。
    2. 不要复述聊天过程，不要写「用户问」「助手答」「我让助手」「继续」。
    3. 一条一行，以「- 」开头。具体，带数字、带名字、带结论。判断不出来的不要编。
    4. 同一天里同一件事反复出现的只写一条。
    5. 中文短句，不要客套话，不要开头结尾的说明，直接输出要点列表。
    6. 如果这一天没有值得记的事，只输出「- 无实质进展」。
    """

    static let mergeInstruction = """
    你是我的工作助理。下面是按天整理的要点，请合并成一份主题汇编。

    要求：
    1. 第一行固定写「# 主题汇编 · 起止日期」，日期用我给你的范围。
    2. 按天分节，小标题写成「## 10月24日 周六」。每天沿用当天的要点，可以精简合并，不要新增内容。
    3. 同一个主题跨天反复出现的，合到它最早出现的那天，并在后面用括号标出还出现在哪几天。
    4. 末尾写「## 未决事项」，列出有意愿但还没定的事；没有就写「暂时没有」。
    5. 中文短句，不要「综上」「总之」这类收尾，直接输出 Markdown。
    """

    /// 跑一次汇编：先按天分段提炼，再合并成一份。
    /// 模型这条路出问题就逐级退回——单段失败退当天的规则摘要，整体失败退按天摘要。
    static func run(store: Store, options: DigestOptions,
                    progress: @escaping (String) -> Void = { _ in }) -> DigestResult {
        var result = DigestResult()
        progress("整理轮次")
        let plan: DigestPlan
        do { plan = try DigestPlanner.build(store: store, options: options) }
        catch {
            result.note = "取数失败：\(error)"
            return result
        }
        result.turnCount = plan.turnCount
        result.dayCount = plan.dayCount
        result.threadCount = plan.threadCount
        guard !plan.isEmpty else {
            result.note = "这段时间没有可汇编的对话"
            return result
        }

        let started = Date()
        var body = ""
        var note = ""
        if options.useLLM {
            // 通路不通就一次性说清楚，别等每一天都跑失败一遍。
            do { _ = try LLMRunner.preflight(options) }
            catch {
                result.seconds = Date().timeIntervalSince(started)
                result.markdown = fallback(plan)
                result.note = "没走成模型，改出按天摘要：\(error)"
                return result
            }
            let segments = DigestPlanner.segments(plan, limit: max(2_000, options.chunkLimit))
            progress("提炼 \(segments.count) 段材料")
            let outcomes = runSegments(segments, options: options, store: store, progress: progress)
            // calls 只算真的调了模型的次数，缓存命中单列，报告里才说得清花了多少钱。
            let succeeded = outcomes.filter { $0.value != nil }.count
            result.cachedCalls = outcomes.filter { $0.cached }.count
            result.calls = succeeded - result.cachedCalls
            let failures = outcomes.compactMap { $0.value == nil ? $0.error : nil }

            // 每一段拿到要点；某段失败就退当天的规则摘要，别让整天消失。
            var byDay: [String: [String]] = [:]
            var dayOrder: [String] = []
            var degradedDays = Set<String>()
            for (segment, outcome) in zip(segments, outcomes) {
                if byDay[segment.dayKey] == nil { dayOrder.append(segment.dayKey) }
                if let text = outcome.value {
                    byDay[segment.dayKey, default: []].append(text)
                } else {
                    degradedDays.insert(segment.dayKey)
                    byDay[segment.dayKey, default: []].append(ruleDigest(segment))
                }
            }
            // 缓存目录顺手收拾一次，别让它随改写的会话越堆越多。
            if options.useCache, !segments.isEmpty {
                DigestCache.trim(storeRoot: store.root)
            }
            let labels = Dictionary(uniqueKeysWithValues: plan.days.map { ($0.key, $0.label) })
            var sections: [String] = []
            for key in dayOrder {
                let label = labels[key] ?? key
                sections.append("## \(label)\n\n" + (byDay[key] ?? []).joined(separator: "\n\n"))
            }
            let merged = sections.joined(separator: "\n\n")

            if succeeded == 0 {
                // 一次都没成，直接出规则版，省得把半成品当提炼结果。
                body = fallback(plan)
                note = "没走成模型，改出按天摘要：\(failures.first ?? "模型没有输出")"
            } else if degradedDays.isEmpty {
                progress("合并各天要点")
                let prompt = mergeInstruction + "\n\n范围：\(plan.rangeLabel)\n\n" + merged
                // 合并这一步也吃缓存：各天要点一个字没变，重跑就该直接出上次的成品。
                let cacheRoute = LLMRunner.route(options)?.label ?? "none"
                let mergeKey = DigestCache.key(material: prompt, route: cacheRoute)
                if options.useCache, let hit = DigestCache.load(storeRoot: store.root, key: mergeKey) {
                    body = hit
                    result.usedLLM = true
                    note = "模型提炼"
                    if result.calls > 0 { note += " · \(result.calls) 次调用" }
                    if result.cachedCalls > 0 { note += "（\(result.cachedCalls) 段复用上次结果）" }
                    note += " · \(String(format: "%.0f", Date().timeIntervalSince(started))) 秒 · \(plan.summary)"
                } else {
                    do {
                        let out = try LLMRunner.ask(options, prompt: prompt,
                                                    workDir: store.root + "/digests/work/merge")
                        if out.output.contains("# 对话材料") {
                            throw DigestError.message("模型把材料原样回显了")
                        }
                        body = out.output
                        result.calls += 1
                        result.usedLLM = true
                        if options.useCache {
                            DigestCache.save(storeRoot: store.root, key: mergeKey, text: out.output)
                        }
                        note = "模型提炼 · \(result.calls) 次调用"
                        if result.cachedCalls > 0 { note += "（\(result.cachedCalls) 段复用上次结果）" }
                        note += " · \(String(format: "%.0f", Date().timeIntervalSince(started))) 秒 · \(plan.summary)"
                    } catch {
                        // 合并没成也不丢各天的提炼结果，直接按天拼起来。
                        body = "# 主题汇编 · \(plan.rangeLabel)\n\n" + merged + "\n\n## 未决事项\n\n暂时没有。\n"
                        result.usedLLM = true
                        note = "各天提炼成功，合并那一步没成，按天拼好了：\(error)"
                    }
                }
            } else {
                // 有几天没提炼成：能提炼的天照用，缺的天用规则摘要，并在开头说明。
                body = "# 主题汇编 · \(plan.rangeLabel)\n\n"
                body += "> 有 \(degradedDays.count) 天模型没能提炼，这几天按原文要点列出。\n\n"
                body += merged + "\n\n## 未决事项\n\n参看上面按天的条目。\n"
                result.usedLLM = true
                note = "部分提炼 · \(succeeded)/\(segments.count) 段成功 · \(plan.summary)"
            }
        } else {
            body = fallback(plan)
            note = "按天摘要（没开模型提炼）· \(plan.summary)"
        }

        result.seconds = Date().timeIntervalSince(started)
        result.markdown = body
        if result.note.isEmpty { result.note = note }
        result.path = save(store: store, options: options, plan: plan, markdown: body)
        store.indexDigest(path: result.path, plan: plan, markdown: body)
        return result
    }

    private struct SegmentOutcome {
        let value: String?
        let error: String?
        /// 这次没真的调模型，直接用的磁盘缓存。
        var cached = false
    }

    /// 分段提炼，最多同时跑 options.parallel 路。每段用独立的工作目录，
    /// 不然并发时提示词和日志会互相覆盖。
    private static func runSegments(_ segments: [DigestSegment], options: DigestOptions,
                                    store: Store, progress: @escaping (String) -> Void) -> [SegmentOutcome] {
        let lock = NSLock()
        var outcomes = [SegmentOutcome?](repeating: nil, count: segments.count)
        var done = 0
        let limit = max(1, min(options.parallel, segments.count))
        let semaphore = DispatchSemaphore(value: limit)
        let group = DispatchGroup()
        // 缓存键带通路标识：换成别的模型或接口后，旧结果不该被复用。
        let routeKey = LLMRunner.route(options)?.label ?? "none"

        for (index, segment) in segments.enumerated() {
            semaphore.wait()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { semaphore.signal(); group.leave() }
                let cacheKey = DigestCache.key(material: segment.material, route: routeKey)
                if options.useCache, let hit = DigestCache.load(storeRoot: store.root, key: cacheKey) {
                    lock.lock()
                    outcomes[index] = SegmentOutcome(value: hit, error: nil, cached: true)
                    done += 1
                    let current = done
                    lock.unlock()
                    progress("已提炼 \(current)/\(segments.count) 段")
                    return
                }
                let prompt = dayInstruction + "\n\n" + segment.material
                var outcome: SegmentOutcome
                do {
                    let out = try LLMRunner.ask(
                        options, prompt: prompt,
                        workDir: store.root + "/digests/work/\(segment.dayKey)-\(segment.part)")
                    if out.output.contains("# 对话材料") {
                        throw DigestError.message("模型把材料原样回显了")
                    }
                    outcome = SegmentOutcome(value: out.output, error: nil)
                    if options.useCache {
                        DigestCache.save(storeRoot: store.root, key: cacheKey, text: out.output)
                    }
                } catch {
                    outcome = SegmentOutcome(value: nil, error: "\(error)")
                }
                lock.lock()
                outcomes[index] = outcome
                done += 1
                let current = done
                lock.unlock()
                progress("已提炼 \(current)/\(segments.count) 段")
            }
        }
        group.wait()
        return outcomes.map { $0 ?? SegmentOutcome(value: nil, error: "未执行") }
    }

    /// 单段的规则摘要：只列这一段的提问。
    static func ruleDigest(_ segment: DigestSegment) -> String {
        var out = ""
        for thread in DigestPlanner.group(segment.turns).first?.threads ?? [] {
            out += "**\(thread.displayTitle)**（\(thread.source.displayName)）\n\n"
            for turn in thread.turns {
                let q = DigestPlanner.clip(turn.question, 120)
                    .replacingOccurrences(of: "\n", with: " ")
                if !q.isEmpty { out += "- \(q)\n" }
            }
            out += "\n"
        }
        return out
    }

    /// 整体规则版：按天列出每轮问了什么，不带模型。
    static func fallback(_ plan: DigestPlan) -> String {
        var out = "# 主题汇编 · \(plan.rangeLabel)\n\n"
        out += "> 这一份是按天摘的轮次，没有经过模型提炼。\n\n"
        for day in plan.days {
            out += "## \(day.label)\n\n"
            for thread in day.threads {
                out += "**\(thread.displayTitle)**（\(thread.source.displayName)）\n\n"
                for turn in thread.turns {
                    let q = DigestPlanner.clip(turn.question, 160)
                        .replacingOccurrences(of: "\n", with: " ")
                    if !q.isEmpty { out += "- \(q)\n" }
                }
                out += "\n"
            }
        }
        out += "---\n\n覆盖 \(plan.dayCount) 天、\(plan.threadCount) 个会话、\(plan.turnCount) 轮。\n"
        return out
    }

    static func save(store: Store, options: DigestOptions, plan: DigestPlan, markdown: String) -> String {
        let dir = options.outputDirectory ?? (store.root + "/digests")
        do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        catch { return "" }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var name = options.title.isEmpty ? "主题汇编" : options.title
        name = name.components(separatedBy: illegal).joined(separator: " ")
        let label = plan.rangeLabel.replacingOccurrences(of: " ", with: "")
        let path = "\(dir)/\(stamp.string(from: Date()))-\(name)-\(label).md"
        do { try markdown.write(toFile: path, atomically: true, encoding: .utf8) }
        catch { return "" }
        return path
    }
}

// MARK: - 汇编产物进索引

extension Store {
    /// 汇编落盘后补一次索引登记。单独提出来，是因为 Digest.save 是静态方法、
    /// 拿不到 store 之外的上下文，调用点只要一行就能接上。
    /// 汇编由多个会话汇总而成，没有单一来源会话，thread_id 留空是如实的。
    func indexDigest(path: String, plan: DigestPlan, markdown: String) {
        guard !path.isEmpty else { return }
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let meta = "覆盖 \(plan.dayCount) 天、\(plan.threadCount) 个会话、\(plan.turnCount) 轮"
        _ = try? upsertMemoryFile(kind: .digest, path: path, title: title,
                                  body: markdown, meta: meta)
    }
}

// MARK: - 会话目录打扫

/// `claude -p` 就算加了 `--no-session-persistence`，还是会在会话目录里建一个项目文件夹
/// （里面只有一个空的 memory 目录）。汇编一天跑十几次就攒十几个空壳，越积越多。
/// 这里只删「一个 jsonl 都没有、除了空目录什么都没有」的项目文件夹，真实会话一个不碰。
enum ScratchCleaner {
    struct Report {
        var roots: [String] = []
        var removedProjects = 0
        var removedEmptyDirs = 0

        var summary: String {
            if removedProjects == 0 && removedEmptyDirs == 0 {
                return "没有需要清理的空项目目录"
            }
            var parts: [String] = []
            if removedProjects > 0 { parts.append("删掉 \(removedProjects) 个空项目目录") }
            if removedEmptyDirs > 0 { parts.append("顺带清掉 \(removedEmptyDirs) 个空子目录") }
            return parts.joined(separator: "，")
        }
    }

    /// 列目录时用到的属性，只认文件类型和大小。
    private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]

    /// 一个目录里有没有 jsonl。有就当作真实项目，整棵跳过。
    private static func hasSession(_ dir: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return true }
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            return true
        }
        return false
    }

    /// 目录是不是空的，或者只有空子目录。有任何一个普通文件就算有内容。
    private static func isEmptyTree(_ dir: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            // 0 字节的普通文件也算痕迹，保守点留下。
            return false
        }
        return true
    }

    static func clean(projectsRoot: String = WriteSupport.claudeProjects) -> Report {
        var report = Report()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: projectsRoot)
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return report }
        report.roots.append(projectsRoot)

        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if hasSession(entry) { continue }
            if !isEmptyTree(entry) { continue }
            // 有会话的项目不动，只删连会话都没有的空壳。
            if (try? fm.removeItem(at: entry)) != nil { report.removedProjects += 1 }
        }

        // 真实项目里也可能留着空的 memory 目录，一并收掉。
        if let kept = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) {
            for entry in kept {
                let memory = entry.appendingPathComponent("memory")
                guard fm.fileExists(atPath: memory.path) else { continue }
                if isEmptyTree(memory), (try? fm.removeItem(at: memory)) != nil {
                    report.removedEmptyDirs += 1
                }
            }
        }
        return report
    }
}

// MARK: - 工作目录打扫

/// 每次提炼都会在 `digests/work/<日期>-<段号>` 留一份 prompt.md 和 stderr.log。
/// 提示词里是对话原文的副本，留着只是把同一段内容存两遍，跑多了还会越堆越大。
/// 这里是纯临时区，清理时整片收掉，下次汇编按需重建。
enum DigestWorkspace {
    struct Report {
        var removed = 0
        var bytes: Int64 = 0

        var summary: String {
            guard removed > 0 else { return "没有需要清理的汇编工作目录" }
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "删掉 \(removed) 个汇编工作目录，腾出 \(size)"
        }
    }

    static func purge(storeRoot: String) -> Report {
        var report = Report()
        let fm = FileManager.default
        let root = storeRoot + "/" + LLMRunner.workDirectoryName
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return report }
        for name in entries {
            let path = root + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            let size = directorySize(path)
            if (try? fm.removeItem(atPath: path)) != nil {
                report.removed += 1
                report.bytes += size
            }
        }
        return report
    }

    private static func directorySize(_ path: String) -> Int64 {
        guard let walker = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let rel as String in walker {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path + "/" + rel)
            total += (attrs?[.size] as? Int64) ?? 0
        }
        return total
    }
}

