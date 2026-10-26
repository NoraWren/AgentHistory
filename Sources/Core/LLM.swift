import Foundation

// MARK: - 配置存储

/// 接口配置落盘。地址和模型名放 UserDefaults，密钥单独写文件。
///
/// UserDefaults 在 Preferences 下是一个明文 plist，随手备份、传个日志都可能带出去，
/// 密钥不该躺在那儿。这里换成库目录下的 llm.json，权限 0600，换个位置也说得清。
enum LLMConfig {
    /// 密钥文件路径，跟着库目录走，隔离测试时能指到临时目录。
    static var keyPath: String { Store.defaultRoot + "/llm.json" }

    private struct Payload: Codable {
        var apiKey: String
    }

    static func loadKey() -> String {
        guard let data = FileManager.default.contents(atPath: keyPath),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return "" }
        return payload.apiKey
    }

    /// 存密钥。空值就把文件删掉，不留一个空壳。
    static func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if FileManager.default.fileExists(atPath: keyPath) {
                try? FileManager.default.removeItem(atPath: keyPath)
            }
            return
        }
        let dir = (keyPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Payload(apiKey: trimmed)) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: keyPath), options: .atomic)
            // 只有自己读得到。
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        } catch { }
    }

    /// 旧版本把密钥明文写进 UserDefaults，启动时搬到文件里再删掉。
    static func migrateFromDefaults() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: "digestAPIKey"), !legacy.isEmpty else { return }
        if loadKey().isEmpty { saveKey(legacy) }
        defaults.removeObject(forKey: "digestAPIKey")
    }
}

/// 界面上那三个输入框怎么落盘。抽出来是为了能测：填一次、关掉、再打开，值还在。
struct LLMSettings {
    static let baseKey = "digestAPIBase"
    static let modelKey = "digestAPIModel"

    var base = ""
    var model = ""
    var apiKey = ""

    /// 开机读一次。密钥从文件来，地址和模型名从偏好来。
    static func load() -> LLMSettings {
        LLMConfig.migrateFromDefaults()
        let defaults = UserDefaults.standard
        return LLMSettings(base: defaults.string(forKey: baseKey) ?? "",
                           model: defaults.string(forKey: modelKey) ?? "",
                           apiKey: LLMConfig.loadKey())
    }

    /// 改一个字存一个字，不用等点「生成汇编」。
    static func saveBase(_ value: String) {
        UserDefaults.standard.set(value, forKey: baseKey)
    }

    static func saveModel(_ value: String) {
        UserDefaults.standard.set(value, forKey: modelKey)
    }

    static func saveKey(_ value: String) { LLMConfig.saveKey(value) }

    /// 面板上那句提示要用：两条通路是否配全。
    var api: LLMAPI? {
        let api = LLMAPI(baseURL: base, model: model, apiKey: apiKey)
        return api.isEmpty ? nil : api
    }
}

// MARK: - 接口通路

/// 不装任何 CLI 也能用的通路：OpenAI 兼容的 `/chat/completions`。
/// OpenAI、DeepSeek、通义、月之暗面、本地 Ollama 都认这套格式，改地址和模型名就能接。
struct LLMAPI {
    /// 形如 `https://api.openai.com/v1`，也可以直接给到 `/chat/completions`。
    var baseURL: String
    var model: String
    /// 留空则依次看 `AGENT_HISTORY_LLM_API_KEY`、`OPENAI_API_KEY`。
    var apiKey = ""

    static let keyVariables = ["AGENT_HISTORY_LLM_API_KEY", "OPENAI_API_KEY"]

    var isEmpty: Bool {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 界面上给一句话，不占地方也够看懂。
    var summary: String {
        guard !isEmpty else { return "没有配置接口" }
        return "接口 · \(model) · \(Self.host(baseURL))"
    }

    static func host(_ url: String) -> String {
        guard let u = URL(string: url), let h = u.host else { return url }
        return h
    }

    func resolvedKey() -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for name in Self.keyVariables {
            if let v = ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return ""
    }

    /// 测试替换用：拿到请求就自己造响应，不碰网络。
    static var transport: (((URLRequest) throws -> (Int, Data)))?

    func call(prompt: String, timeout: TimeInterval) throws -> String {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw DigestError.message("接口地址是空的") }
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else { throw DigestError.message("没填模型名") }
        var endpoint = base.hasSuffix("/") ? String(base.dropLast()) : base
        if !endpoint.hasSuffix("/chat/completions") { endpoint += "/chat/completions" }
        guard let url = URL(string: endpoint) else {
            throw DigestError.message("接口地址看不懂：\(base)")
        }

        let payload: [String: Any] = [
            "model": modelName,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw DigestError.message("请求体拼不出来")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = resolvedKey()
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body

        let status: Int
        let data: Data
        if let transport = Self.transport {
            (status, data) = try transport(request)
        } else {
            (status, data) = try Self.send(request, timeout: timeout)
        }

        guard (200..<300).contains(status) else {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DigestError.message("接口返回 \(status)" + (snippet.isEmpty ? "" : "：\(snippet)"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
            throw DigestError.message("接口返回的内容读不懂\(snippet.isEmpty ? "" : "：\(snippet)")")
        }
        // 有的服务把正文放 content，有的放 reasoning_content 之外的 text 数组，按常见形状取。
        if let text = message["content"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return joined.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw DigestError.message("接口没有返回正文")
    }

    /// URLSession 的异步回调换成同步等待，外面本来就在后台线程跑。
    private static func send(_ request: URLRequest, timeout: TimeInterval) throws -> (Int, Data) {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Int, Data), Error>?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                outcome = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                outcome = .success((http.statusCode, data ?? Data()))
            } else {
                outcome = .failure(DigestError.message("接口没有返回 HTTP 响应"))
            }
            semaphore.signal()
        }
        task.resume()
        // 比请求自身的超时多留一点，避免库里的超时和网络层的超时互相打架。
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw DigestError.message("接口 \(Int(timeout)) 秒内没有返回")
        }
        guard let outcome = outcome else { throw DigestError.message("接口调用没有结果") }
        return try outcome.get()
    }
}

// MARK: - 本机命令行探测

/// 一次提炼走哪条路。接口配好了就走接口，否则走命令行。
enum ModelRoute {
    case api(LLMAPI)
    case command(String)

    var label: String {
        switch self {
        case .api(let api): return api.summary
        case .command(let cmd): return cmd
        }
    }
}

extension LLMRunner {
    /// 按选项决定通路。接口优先：它不依赖本机装了什么。
    static func route(_ options: DigestOptions) -> ModelRoute? {
        if let api = options.api, !api.isEmpty { return .api(api) }
        let command = options.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        return .command(command)
    }

    /// 开跑之前先确认这条路走得通，别让每一段都失败一遍才告诉用户命令行不存在。
    static func preflight(_ options: DigestOptions) throws -> ModelRoute {
        guard let route = route(options) else {
            throw DigestError.message("没有可用的模型通路：填一个接口地址和模型名，或者写一条命令行")
        }
        if case .command(let cmd) = route { try check(command: cmd) }
        return route
    }

    /// 统一入口：提示词进，正文出。接口和命令行在这里合流，调用方不用分情况。
    static func ask(_ options: DigestOptions, prompt: String, workDir: String) throws -> (output: String, seconds: TimeInterval) {
        switch try preflight(options) {
        case .api(let api):
            let started = Date()
            let text = try api.call(prompt: prompt, timeout: options.timeout)
            return (text, Date().timeIntervalSince(started))
        case .command(let cmd):
            return try run(command: cmd, prompt: prompt, timeout: options.timeout, workDir: workDir)
        }
    }
}

/// 一个可用的命令行通路。命令都按「提示词走标准输入、正文从标准输出读回」写。
struct LLMPreset {
    let id: String
    let label: String
    let binary: String
    let command: String
    /// 为什么要带这些参数，填到界面上给用户看。
    let note: String
}

/// 开局不假设用户装了什么。用户机器上可能只有 Codex、只有 Gemini、什么都没有。
enum LLMDetector {
    static let presets: [LLMPreset] = [
        LLMPreset(
            id: "claude", label: "Claude Code", binary: "claude",
            command: "claude -p --no-session-persistence",
            note: "不写会话文件，避免汇编自己喂自己"),
        LLMPreset(
            id: "codex", label: "Codex", binary: "codex",
            command: "codex exec --ephemeral --skip-git-repo-check -s read-only -",
            note: "临时会话、只读沙箱，提示词从标准输入读"),
        LLMPreset(
            id: "gemini", label: "Gemini CLI", binary: "gemini",
            command: "gemini -p 照做下面的要求",
            note: "需要先配好 GEMINI_API_KEY"),
        LLMPreset(
            id: "ollama", label: "Ollama", binary: "ollama",
            command: "ollama run qwen3",
            note: "本地模型，命令里的模型名按已下载的改"),
        LLMPreset(
            id: "llm", label: "llm", binary: "llm",
            command: "llm",
            note: "simonw 的 llm 工具，按已配好的默认模型跑"),
    ]

    /// 从访达或 Dock 启动时 PATH 很短，必须走一次 login shell 才看得见 npm、homebrew 装的命令。
    static func which(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", "command -v \(binary)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// 探测结果，`path` 是找到的可执行文件。
    struct Hit {
        let preset: LLMPreset
        let path: String
    }

    /// 一次扫完所有预设。结果缓存在进程内，开面板不用每次都跑五个 shell。
    static func detect(force: Bool = false) -> [Hit] {
        lock.lock()
        defer { lock.unlock() }
        if !force, let cached = cache { return cached }
        var hits: [Hit] = []
        for preset in presets where preset.id != "ollama" {
            if let path = which(preset.binary) { hits.append(Hit(preset: preset, path: path)) }
        }
        // 本地模型单独判：装了不等于下了模型，只有列得出来才算能跑。
        if let path = which("ollama"), !ollamaModels(path).isEmpty {
            let preset = presets.first { $0.id == "ollama" }!
            hits.append(Hit(preset: preset, path: path))
        }
        cache = hits
        return hits
    }

    private static let lock = NSLock()
    private static var cache: [Hit]?

    static func reset() { lock.lock(); cache = nil; lock.unlock() }

    /// ollama 的模型列表，第一行是表头，后面每行一个名字。
    static func ollamaModels(_ path: String) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["list"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .dropFirst()
            .compactMap { $0.split(separator: " ").first.map(String.init) }
    }

    /// 没装 CLI 也别让面板空着：接口通路优先，其次是第一个探测到的 CLI。
    static func recommended(api: LLMAPI?) -> (command: String, label: String)? {
        if let api = api, !api.isEmpty { return ("", api.summary) }
        if let first = detect().first { return (first.preset.command, first.preset.label) }
        return nil
    }

    /// 这条命令是不是预设里自动填的那一条。
    ///
    /// 预设是按本机探测结果填的，存进配置就等于把「这台机器装了什么」写死了。
    /// 换一台没装 Claude Code 的电脑，配置里还留着 `claude -p ...`，面板会拿着一条
    /// 不存在的命令去跑。所以自动填的值一律不落盘，留空表示下次启动重新探测。
    static func isPresetCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return presets.contains { $0.command == trimmed }
    }
}
