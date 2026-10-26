import Foundation

// 本机六个客户端的登记方式各不相同。逐客户端写一段 switch 的话，加一个客户端要改好几处，
// 也容易漏掉「配置在但连不上」这种情况。这里用一条注册表描述位置、格式和接入方式，
// 检查、写入、界面都从注册表取。

enum MCPClientKind: String, CaseIterable {
    case codex
    case claude
    case workbuddy
    case opencode
    case kimi
    case deepseek

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .workbuddy: return "WorkBuddy"
        case .opencode: return "OpenCode"
        case .kimi: return "Kimi Code"
        case .deepseek: return "DeepSeek Harness"
        }
    }
}

enum MCPInstallStyle: String {
    /// 直接读写登记文件。
    case config
    /// 客户端自带登记命令，用它免得和别的工具抢同一份文件。
    case command
    /// 靠装插件才能用，和「配置里有没有一条」不是一回事。
    case plugin

    var label: String {
        switch self {
        case .config: return "配置式"
        case .command: return "命令式"
        case .plugin: return "插件式"
        }
    }
}

enum MCPConfigFormat {
    /// JSON 的某一层对象里按名字登记。OpenCode 的键是 mcp，且 command 是数组。
    case jsonServers(key: String, commandIsArray: Bool)
    /// Claude Code 的 .claude.json：顶层一份，每个项目层级还各有一份。
    case claudeJSON
    /// TOML 的 [mcp_servers.<名>] 段。
    case tomlSection(prefix: String)
    /// 插件清单里的 bundles 数组。
    case pluginManifest(bundle: String)
}

struct MCPClientTarget {
    let kind: MCPClientKind
    let style: MCPInstallStyle
    /// 客户端自己的根目录，用来区分「没装」和「装了没接」。
    let rootPath: String
    /// 登记文件；插件式这里是 profile 清单。
    let configPath: String
    let format: MCPConfigFormat
    /// 官方命令的文件名，按 PATH 找。
    let commandName: String?
    let note: String

    var displayName: String { kind.displayName }
}

enum MCPTargetRegistry {
    static let entryName = "agent-history"

    /// 测试和隔离环境用 AGENT_HISTORY_ONBOARD_HOME 顶掉家目录，
    /// 免得验证「接入」时改到本机真实配置。
    static var home: String {
        if let override = ProcessInfo.processInfo.environment["AGENT_HISTORY_ONBOARD_HOME"],
           !override.isEmpty {
            return override
        }
        return NSHomeDirectory()
    }

    static func all(home: String = MCPTargetRegistry.home) -> [MCPClientTarget] {
        [
            MCPClientTarget(
                kind: .codex, style: .config,
                rootPath: home + "/.codex",
                configPath: home + "/.codex/config.toml",
                format: .tomlSection(prefix: "mcp_servers"),
                commandName: nil,
                note: "写 [mcp_servers.agent-history] 段，改完重开 Codex 生效"),
            MCPClientTarget(
                kind: .claude, style: .command,
                rootPath: home + "/.claude",
                configPath: home + "/.claude.json",
                format: .claudeJSON,
                commandName: "claude",
                note: "用 claude mcp add 写到 user 层级，所有项目都能用"),
            MCPClientTarget(
                kind: .workbuddy, style: .config,
                rootPath: home + "/.workbuddy",
                configPath: home + "/.workbuddy/connectors/default/mcp.json",
                format: .jsonServers(key: "mcpServers", commandIsArray: false),
                commandName: nil,
                note: "这条要带 disabled: false，否则 WorkBuddy 不加载"),
            MCPClientTarget(
                kind: .opencode, style: .command,
                rootPath: home + "/.config/opencode",
                configPath: home + "/.config/opencode/opencode.json",
                format: .jsonServers(key: "mcp", commandIsArray: true),
                commandName: "opencode",
                note: "用 opencode mcp add 登记，它的 command 是数组"),
            MCPClientTarget(
                kind: .kimi, style: .config,
                rootPath: home + "/.kimi-code",
                configPath: home + "/.kimi-code/mcp.json",
                format: .jsonServers(key: "mcpServers", commandIsArray: false),
                commandName: nil,
                note: "最简单的一份，只有 command 和 args"),
            MCPClientTarget(
                kind: .deepseek, style: .plugin,
                rootPath: home + "/.dsh",
                configPath: home + "/.dsh/profiles/desktop/package.json",
                format: .pluginManifest(bundle: "@local/agent-history-mcp"),
                commandName: nil,
                note: "插件在 " + home + "/.agent-history/dsh-plugin，不需要另写配置"),
        ]
    }

    static func target(_ kind: MCPClientKind, home: String = MCPTargetRegistry.home) -> MCPClientTarget {
        all(home: home).first { $0.kind == kind } ?? all(home: home)[0]
    }

    /// 命令行里认三种写法：英文短名、显示名、去空格的显示名，再补几个习惯叫法。
    static func parse(_ raw: String, home: String = MCPTargetRegistry.home) -> MCPClientTarget? {
        let wanted = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if wanted.isEmpty { return nil }
        for target in all(home: home) {
            let names = [target.kind.rawValue,
                         target.displayName.lowercased(),
                         target.displayName.replacingOccurrences(of: " ", with: "").lowercased()]
            if names.contains(wanted) { return target }
        }
        switch wanted {
        case "claudecode", "cc": return target(.claude, home: home)
        case "dsh", "harness", "deepseekharness": return target(.deepseek, home: home)
        case "kimicode": return target(.kimi, home: home)
        case "opencode-ai": return target(.opencode, home: home)
        case "work-buddy", "wb": return target(.workbuddy, home: home)
        default: return nil
        }
    }

    static var allNames: String {
        all().map { $0.kind.rawValue }.joined(separator: " / ")
    }

    /// 官方命令在 PATH 里找。界面启动时 PATH 很短，补上常装命令的目录。
    static func commandPath(_ name: String, home: String = MCPTargetRegistry.home) -> String? {
        let fm = FileManager.default
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + [home + "/.npm-global/bin", home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        for dir in dirs {
            let candidate = dir + "/" + name
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// 当前这份程序自己的路径。登记里写的必须是它，否则客户端拉起的还是旧的那份。
    static func currentBinary() -> String {
        if let override = ProcessInfo.processInfo.environment["AGENT_HISTORY_BINARY"], !override.isEmpty {
            return override
        }
        if let path = Bundle.main.executablePath, path.contains(".app/Contents/MacOS") {
            return path
        }
        let argv0 = CommandLine.arguments.first ?? ""
        if argv0.contains("/") {
            return URL(fileURLWithPath: argv0).resolvingSymlinksInPath().path
        }
        // 从 PATH 里敲起来的，argv[0] 只有名字，得自己找回来。
        if !argv0.isEmpty, let found = commandPath(argv0) { return found }
        return NSHomeDirectory() + "/Applications/AgentHistory.app/Contents/MacOS/AgentHistory"
    }

    /// 插件实体放在本服务自己的目录下，跟登记它的客户端无关。
    static func pluginRoot(home: String = MCPTargetRegistry.home) -> String {
        home + "/.agent-history/dsh-plugin"
    }

    static var pluginRoot: String { pluginRoot() }
}


// MARK: - 登记读取

enum MCPRegistration {
    /// 登记文件本身不在。客户端装了但没配过，或者装的是别的版本。
    case configMissing(path: String)
    case parseFailed(path: String, message: String)
    case notRegistered(path: String)
    /// 登记在，位置在 location，指向的可执行文件是 binary（可能已经失效）。
    case registered(path: String, binary: String, location: String)
}

enum MCPRegistrationReader {
    static func read(target: MCPClientTarget) -> MCPRegistration {
        if case let .pluginManifest(bundle) = target.format {
            return readPlugin(target: target, bundle: bundle)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.configPath) else {
            return .configMissing(path: target.configPath)
        }
        // 家目录里软链不少见。读的时候跟着链接走，写的时候也要写回真身。
        let real = realPath(target.configPath)
        switch target.format {
        case let .tomlSection(prefix):
            guard let text = try? String(contentsOfFile: real, encoding: .utf8) else {
                return .parseFailed(path: target.configPath, message: "读不出这份文件")
            }
            guard let section = TOMLSection.find(text: text, prefix: prefix, name: MCPTargetRegistry.entryName) else {
                return .notRegistered(path: target.configPath)
            }
            guard let command = TOMLSection.value(section.text, key: "command") else {
                return .parseFailed(path: target.configPath, message: "段里没有 command")
            }
            return .registered(path: target.configPath,
                               binary: stripQuotes(command),
                               location: "[" + prefix + "." + MCPTargetRegistry.entryName + "]")
        case let .jsonServers(key, commandIsArray):
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: real)) else {
                return .parseFailed(path: target.configPath, message: "读不出这份文件")
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .parseFailed(path: target.configPath,
                                    message: "这份 JSON 解析不了，可能有尾逗号或被别的工具写坏了")
            }
            guard let servers = root[key] as? [String: Any],
                  let entry = servers[MCPTargetRegistry.entryName] as? [String: Any] else {
                return .notRegistered(path: target.configPath)
            }
            let binary: String?
            if commandIsArray {
                binary = (entry["command"] as? [Any])?.first as? String
            } else {
                binary = entry["command"] as? String
            }
            guard let binary, !binary.isEmpty else {
                return .parseFailed(path: target.configPath, message: "这条登记里没有 command")
            }
            return .registered(path: target.configPath, binary: binary, location: key)
        case .claudeJSON:
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: real)) else {
                return .parseFailed(path: target.configPath, message: "读不出这份文件")
            }
            guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .parseFailed(path: target.configPath, message: "这份 JSON 解析不了")
            }
            var places: [(String, String)] = []
            if let top = root["mcpServers"] as? [String: Any],
               let entry = top[MCPTargetRegistry.entryName] as? [String: Any],
               let command = entry["command"] as? String, !command.isEmpty {
                places.append(("顶层", command))
            }
            for (project, value) in (root["projects"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let object = value as? [String: Any],
                      let servers = object["mcpServers"] as? [String: Any],
                      let entry = servers[MCPTargetRegistry.entryName] as? [String: Any],
                      let command = entry["command"] as? String, !command.isEmpty else { continue }
                places.append((project, command))
            }
            guard let first = places.first else {
                return .notRegistered(path: target.configPath)
            }
            let location = places.count == 1 ? first.0 : first.0 + " 等 " + String(places.count) + " 处"
            return .registered(path: target.configPath, binary: first.1, location: location)
        case .pluginManifest:
            return .notRegistered(path: target.configPath)
        }
    }

    private static func readPlugin(target: MCPClientTarget, bundle: String) -> MCPRegistration {
        guard FileManager.default.fileExists(atPath: target.configPath) else {
            return .configMissing(path: target.configPath)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.configPath)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .parseFailed(path: target.configPath, message: "profile 清单解析不了")
        }
        let dsh = root["dsh"] as? [String: Any]
        let profile = dsh?["profile"] as? [String: Any]
        let bundles = profile?["bundles"] as? [String] ?? []
        guard bundles.contains(bundle) else {
            return .notRegistered(path: target.configPath)
        }
        // 登记了还要看实体在不在，否则客户端启动时才报错。
        // 这里按这台客户端的家目录算，隔离环境里才不会去读真实目录。
        let home = (target.rootPath as NSString).deletingLastPathComponent
        let pluginPath = MCPTargetRegistry.pluginRoot(home: home)
        guard FileManager.default.fileExists(atPath: pluginPath) else {
            return .parseFailed(path: target.configPath,
                                message: "清单里有插件，但 " + pluginPath + " 不存在")
        }
        return .registered(path: target.configPath,
                           binary: pluginPath,
                           location: "dsh.profile.bundles")
    }

    static func stripQuotes(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    static func realPath(_ path: String) -> String {
        (path as NSString).resolvingSymlinksInPath
    }
}


// MARK: - 握手

enum MCPHandshakeFailure: Equatable {
    case missingBinary(String)
    case notExecutable(String)
    case launchFailed(String)
    case timeout(Int)
    case noToolList(String)

    var reason: String {
        switch self {
        case let .missingBinary(path): return "登记的可执行文件不在了：" + path
        case let .notExecutable(path): return "登记的文件没有执行权限：" + path
        case let .launchFailed(detail): return "进程起不来：" + detail
        case let .timeout(seconds): return "握手超时，" + String(seconds) + " 秒内没回应"
        case let .noToolList(detail):
            return detail.isEmpty ? "连上了但拿不到工具清单" : "连上了但拿不到工具清单：" + detail
        }
    }

    /// 路径类问题能直接改写，进程和超时问题得先看现场。
    var isPathProblem: Bool {
        switch self {
        case .missingBinary, .notExecutable: return true
        default: return false
        }
    }
}

enum MCPHandshakeOutcome {
    case ok(tools: [String])
    case failed(MCPHandshakeFailure)
}

enum MCPHandshake {
    static let defaultTimeout: Int = 5

    /// 拉起一次 AgentHistory mcp，只走 initialize 与 tools/list，不调任何工具，
    /// 免得检查动作顺手把同步跑一遍。
    static func runAsync(binary: String, timeout: Int = defaultTimeout,
                         completion: @escaping (MCPHandshakeOutcome) -> Void) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: binary, isDirectory: &isDir), !isDir.boolValue else {
            completion(.failed(.missingBinary(binary)))
            return
        }
        guard fm.isExecutableFile(atPath: binary) else {
            completion(.failed(.notExecutable(binary)))
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["mcp"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        var env = ProcessInfo.processInfo.environment
        // 检查不该改库：把补同步关掉。
        env["AGENT_HISTORY_MCP_SYNC"] = "0"
        process.environment = env

        do {
            try process.run()
        } catch {
            completion(.failed(.launchFailed(error.localizedDescription)))
            return
        }

        let box = HandshakeBox()
        let inFD = input.fileHandleForWriting.fileDescriptor
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        let done = DispatchSemaphore(value: 0)

        // stderr 不排空的话，服务端写多了会阻塞；这里只留尾部，够判断原因。
        DispatchQueue.global(qos: .utility).async {
            var tail = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = chunk.withUnsafeMutableBytes { read(errFD, $0.baseAddress, 4096) }
                if n <= 0 { break }
                tail.append(contentsOf: chunk[0..<n])
                if tail.count > 32_000 { tail.removeFirst(tail.count - 32_000) }
            }
            box.setStderr(String(decoding: tail, as: UTF8.self))
        }

        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            // 对端提前退出时写管道会拿到 SIGPIPE，默认动作是直接把我们杀掉。
            signal(SIGPIPE, SIG_IGN)
            let lines = [
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"agent-history-onboarding\",\"version\":\"0.1.0\"}}}",
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}",
            ]
            for line in lines {
                guard PipeWriter.writeLine(fd: inFD, line: line) else { break }
            }
            let reader = FDLineReader(fd: outFD)
            while let line = reader.nextLine() {
                guard let data = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                box.observe(object)
                if box.hasToolsResult() { break }
            }
            box.markReaderDone()
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        var finished = false
        while Date() < deadline {
            if done.wait(timeout: .now() + 0.02) == .success { finished = true; break }
        }
        if !finished {
            box.markTimeout()
        }
        // 收尾：先关 stdin 让它自己退，不走就杀。
        close(inFD)
        if process.isRunning { process.terminate() }
        let grace = Date().addingTimeInterval(1.2)
        while process.isRunning && Date() < grace { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        // 读线程可能还卡在 read 上，进程没了自然返回；给一小段时间收 stderr。
        box.waitForStderr(within: 0.3)

        if !finished {
            completion(.failed(.timeout(timeout)))
            return
        }
        if let tools = box.tools {
            guard !tools.isEmpty else {
                completion(.failed(.noToolList(box.firstStderrLine())))
                return
            }
            completion(.ok(tools: tools))
            return
        }
        let stderrLine = box.firstStderrLine()
        if !stderrLine.isEmpty {
            completion(.failed(.noToolList(stderrLine)))
            return
        }
        completion(.failed(.launchFailed("进程退出码 " + String(process.terminationStatus) + "，没有返回工具清单")))
    }

    /// 同步封装：拿到结果就返回。界面用异步那版，命令行和测试用这版。
    static func probe(binary: String, timeout: Int = defaultTimeout) -> MCPHandshakeOutcome {
        var outcome: MCPHandshakeOutcome?
        let done = DispatchSemaphore(value: 0)
        runAsync(binary: binary, timeout: timeout) { value in
            outcome = value
            done.signal()
        }
        _ = done.wait(timeout: .now() + TimeInterval(timeout) + 8)
        return outcome ?? .failed(.timeout(timeout))
    }
}

/// 读线程与主线程之间的交换箱：工具名、stderr、超时标记分开存。
final class HandshakeBox {
    private let lock = NSLock()
    private var storedTools: [String]?
    private var timedOut = false
    private var stderrText = ""
    private let stderrReady = DispatchSemaphore(value: 0)

    var tools: [String]? {
        lock.lock(); defer { lock.unlock() }
        return storedTools
    }

    func observe(_ object: [String: Any]) {
        let raw = object["id"]
        let id = (raw as? NSNumber)?.intValue ?? (raw as? Int) ?? -1
        guard id == 2 else { return }
        var names: [String] = []
        var note = ""
        if let result = object["result"] as? [String: Any],
           let tools = result["tools"] as? [[String: Any]] {
            names = tools.compactMap { $0["name"] as? String }
        } else if let error = object["error"] as? [String: Any] {
            note = error["message"] as? String ?? "tools/list 报错"
        }
        lock.lock()
        storedTools = names
        if !note.isEmpty, stderrText.isEmpty { stderrText = note }
        lock.unlock()
    }

    func hasToolsResult() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedTools != nil
    }

    func markReaderDone() {}

    func markTimeout() {
        lock.lock(); timedOut = true; lock.unlock()
    }

    func setStderr(_ text: String) {
        lock.lock(); stderrText = text; lock.unlock()
        stderrReady.signal()
    }

    func waitForStderr(within seconds: Double) {
        _ = stderrReady.wait(timeout: .now() + seconds)
    }

    /// 原因文案只取第一行有意义的内容，太长会把界面撑开。
    func firstStderrLine() -> String {
        lock.lock(); defer { lock.unlock() }
        for line in stderrText.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // 服务端正常启动时会打「已启动」，那不是失败原因。
            if trimmed.contains("已启动") { continue }
            return String(trimmed.prefix(160))
        }
        return ""
    }
}

enum PipeWriter {
    static func writeLine(fd: Int32, line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: offset), bytes.count - offset)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            offset += n
        }
        return true
    }
}

/// 按行读管道。不用 FileHandle 的现成读法，是因为它在对端消失时会抛异常，
/// 而我们只想安静收场。
final class FDLineReader {
    private let fd: Int32
    private var buffer = [UInt8]()
    private var offset = 0

    init(fd: Int32) { self.fd = fd }

    func nextLine() -> String? {
        while true {
            if offset < buffer.count, let idx = buffer[offset...].firstIndex(of: 0x0A) {
                let line = Array(buffer[offset..<idx])
                offset = idx + 1
                if offset > 128_000 {
                    buffer.removeFirst(offset)
                    offset = 0
                }
                return String(decoding: line, as: UTF8.self)
            }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, 8192) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        if offset < buffer.count {
            let rest = Array(buffer[offset...])
            offset = buffer.count
            return rest.isEmpty ? nil : String(decoding: rest, as: UTF8.self)
        }
        return nil
    }
}



// MARK: - 状态判定

enum MCPClientState: Equatable {
    case notInstalled(rootPath: String)
    case notConfigured(path: String)
    /// 文件里有东西但读不懂，或者登记残缺。
    case broken(path: String, reason: String)
    case connectFailed(path: String, binary: String, reason: String, fixable: Bool)
    case connected(path: String, binary: String, location: String, tools: [String])
    case pluginInstalled(path: String, location: String)
    case pluginMissing(path: String)

    var label: String {
        switch self {
        case .notInstalled: return "未安装"
        case .notConfigured: return "未接入"
        case .broken: return "配置有问题"
        case .connectFailed: return "配置在，连不上"
        case .connected: return "已接入"
        case .pluginInstalled: return "插件已装"
        case .pluginMissing: return "插件未装"
        }
    }

    /// 只有「本来能用却用不了」才算失败，未接入是常态。
    var isFailure: Bool {
        switch self {
        case .connectFailed, .broken: return true
        default: return false
        }
    }

    var isUsable: Bool {
        switch self {
        case .connected, .pluginInstalled: return true
        default: return false
        }
    }

    var toolCount: Int {
        if case let .connected(_, _, _, tools) = self { return tools.count }
        return 0
    }

    /// 路径失效的才算能一键修，进程起不来改了路径也没用。
    var isFixable: Bool {
        if case let .connectFailed(_, _, _, fixable) = self { return fixable }
        return false
    }

    var detail: String {
        switch self {
        case let .notInstalled(root): return "没有 " + root
        case let .notConfigured(path): return path + " 里没有本服务"
        case let .broken(_, reason): return reason
        case let .connectFailed(_, _, reason, _): return reason
        case let .connected(_, _, location, tools):
            return "登记在 " + location + "，握手拿到 " + String(tools.count) + " 个工具"
        case let .pluginInstalled(_, location): return "登记在 " + location
        case let .pluginMissing(path): return path + " 里没有插件"
        }
    }
}

struct MCPClientReport {
    let target: MCPClientTarget
    let state: MCPClientState
    let configPath: String
    let checkedAt: Date

    var displayName: String { target.displayName }
    var styleLabel: String { target.style.label }

    var stateLabel: String { state.label }
    var reason: String { state.detail }
}

enum MCPOnboarding {
    /// 检查一个客户端。顺序固定：先看装没装，再看有没有登记，最后握手。
    /// 只看文件会把「配置在但连不上」误报成已接入。
    static func inspect(_ target: MCPClientTarget, timeout: Int = MCPHandshake.defaultTimeout) -> MCPClientReport {
        let now = Date()
        guard FileManager.default.fileExists(atPath: target.rootPath) else {
            return MCPClientReport(target: target, state: .notInstalled(rootPath: target.rootPath),
                                   configPath: target.configPath, checkedAt: now)
        }
        switch MCPRegistrationReader.read(target: target) {
        case let .configMissing(path):
            let state: MCPClientState = target.style == .plugin ? .pluginMissing(path: path) : .notConfigured(path: path)
            return MCPClientReport(target: target, state: state, configPath: path, checkedAt: now)
        case let .parseFailed(path, message):
            return MCPClientReport(target: target, state: .broken(path: path, reason: message),
                                   configPath: path, checkedAt: now)
        case let .notRegistered(path):
            let state: MCPClientState = target.style == .plugin ? .pluginMissing(path: path) : .notConfigured(path: path)
            return MCPClientReport(target: target, state: state, configPath: path, checkedAt: now)
        case let .registered(path, binary, location):
            if target.style == .plugin {
                return MCPClientReport(target: target,
                                       state: .pluginInstalled(path: path, location: location),
                                       configPath: path, checkedAt: now)
            }
            switch MCPHandshake.probe(binary: binary, timeout: timeout) {
            case let .ok(tools):
                return MCPClientReport(target: target,
                                       state: .connected(path: path, binary: binary, location: location, tools: tools),
                                       configPath: path, checkedAt: now)
            case let .failed(failure):
                return MCPClientReport(target: target,
                                       state: .connectFailed(path: path, binary: binary,
                                                             reason: failure.reason, fixable: failure.isPathProblem),
                                       configPath: path, checkedAt: now)
            }
        }
    }

    static func inspectAll(home: String = MCPTargetRegistry.home,
                           timeout: Int = MCPHandshake.defaultTimeout,
                           parallel: Bool = true) -> [MCPClientReport] {
        let targets = MCPTargetRegistry.all(home: home)
        guard parallel else {
            return targets.map { inspect($0, timeout: timeout) }
        }
        // 六个客户端各拉一个子进程，串起来要十几秒。并行之后整体就是最慢那一个的时间。
        let lock = NSLock()
        var results: [MCPClientReport] = []
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let report = inspect(targets[index], timeout: timeout)
            lock.lock(); results.append(report); lock.unlock()
        }
        let order = Dictionary(uniqueKeysWithValues: targets.enumerated().map { ($0.element.kind, $0.offset) })
        return results.sorted { (order[$0.target.kind] ?? 0) < (order[$1.target.kind] ?? 0) }
    }
}




