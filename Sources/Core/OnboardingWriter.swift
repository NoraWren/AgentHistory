import Foundation

// 配置写入的硬要求：只动本服务这一条，同文件里别的登记一个字节都不能变。
// JSONSerialization 重写会把键序和缩进全换掉，WorkBuddy 那份有近百条，
// 所以这里走文本级增删，不经过任何「解析再序列化」。

/// 找到 JSON 对象里某个键的成员范围。全程按 UTF-8 字节走，
/// 中文键、转义引号都不用特殊照顾。
enum JSONSpan {
    struct Member {
        let key: String
        /// 从键的引号开始，到值的结尾（不含尾部空白和逗号）。
        let start: Int
        let end: Int
        let valueStart: Int
        let valueEnd: Int
    }

    static func skipWhitespace(_ bytes: [UInt8], _ index: Int) -> Int {
        var i = index
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D {
            i += 1
        }
        return i
    }

    /// 返回字符串字面量结束后的位置。
    static func skipString(_ bytes: [UInt8], _ index: Int) -> Int? {
        guard index < bytes.count, bytes[index] == 0x22 else { return nil }
        var i = index + 1
        while i < bytes.count {
            if bytes[i] == 0x5C { i += 2; continue }
            if bytes[i] == 0x22 { return i + 1 }
            i += 1
        }
        return nil
    }

    /// 返回任意值的结束位置。
    static func skipValue(_ bytes: [UInt8], _ index: Int) -> Int? {
        var i = skipWhitespace(bytes, index)
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case 0x22:
            return skipString(bytes, i)
        case 0x7B, 0x5B:
            var depth = 0
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x22 {
                    guard let next = skipString(bytes, i) else { return nil }
                    i = next
                    continue
                }
                if b == 0x7B || b == 0x5B { depth += 1 }
                if b == 0x7D || b == 0x5D {
                    depth -= 1
                    if depth == 0 { return i + 1 }
                }
                i += 1
            }
            return nil
        default:
            while i < bytes.count {
                let b = bytes[i]
                if b == 0x2C || b == 0x7D || b == 0x5D || b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    return i
                }
                i += 1
            }
            return i
        }
    }

    static func stringValue(_ bytes: [UInt8], _ range: Range<Int>) -> String? {
        let slice = Array(bytes[range])
        guard let text = String(bytes: slice, encoding: .utf8),
              let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
            return nil
        }
        return value
    }

    /// 列出某个对象（以 { 开头）下的所有成员。
    static func members(_ bytes: [UInt8], objectStart: Int) -> [Member]? {
        var i = skipWhitespace(bytes, objectStart)
        guard i < bytes.count, bytes[i] == 0x7B else { return nil }
        i += 1
        var out: [Member] = []
        while true {
            i = skipWhitespace(bytes, i)
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x7D { return out }
            guard bytes[i] == 0x22, let keyEnd = skipString(bytes, i) else { return nil }
            let key = stringValue(bytes, i..<(keyEnd)) ?? ""
            var j = skipWhitespace(bytes, keyEnd)
            guard j < bytes.count, bytes[j] == 0x3A else { return nil }
            j += 1
            guard let valueEnd = skipValue(bytes, j) else { return nil }
            let valueStart = skipWhitespace(bytes, j)
            out.append(Member(key: key, start: i, end: valueEnd, valueStart: valueStart, valueEnd: valueEnd))
            var k = skipWhitespace(bytes, valueEnd)
            if k < bytes.count, bytes[k] == 0x2C {
                k += 1
                i = k
                continue
            }
            i = k
            if i < bytes.count, bytes[i] == 0x7D { return out }
            return nil
        }
    }

    /// 根对象的范围。
    static func rootRange(_ bytes: [UInt8]) -> Range<Int>? {
        let start = skipWhitespace(bytes, 0)
        guard start < bytes.count, bytes[start] == 0x7B, let end = skipValue(bytes, start) else { return nil }
        return start..<end
    }

    /// 在对象里按键找成员。
    static func member(_ bytes: [UInt8], objectStart: Int, key: String) -> Member? {
        members(bytes, objectStart: objectStart)?.first { $0.key == key }
    }

    // MARK: 严格校验

    /// JSONSerialization 会放行尾逗号（{"a": 1,} 它认），带着尾逗号做文本手术会切错位置。
    /// 所以这里按文法自己走一遍：多一个逗号、缺一个括弧都算不合格。合格返回 nil。
    static func validate(_ bytes: [UInt8]) -> String? {
        var i = skipWhitespace(bytes, 0)
        guard let end = validateValue(bytes, i) else { return "内容不是合法的 JSON" }
        i = skipWhitespace(bytes, end)
        guard i == bytes.count else {
            return "第 " + String(i) + " 字节之后还有多余内容"
        }
        return nil
    }

    private static func validateValue(_ bytes: [UInt8], _ index: Int) -> Int? {
        let i = skipWhitespace(bytes, index)
        guard i < bytes.count else { return nil }
        switch bytes[i] {
        case 0x7B:
            return validateObject(bytes, i)
        case 0x5B:
            return validateArray(bytes, i)
        case 0x22:
            return skipString(bytes, i)
        case 0x74:
            return matchLiteral(bytes, i, "true")
        case 0x66:
            return matchLiteral(bytes, i, "false")
        case 0x6E:
            return matchLiteral(bytes, i, "null")
        default:
            return validateNumber(bytes, i)
        }
    }

    private static func matchLiteral(_ bytes: [UInt8], _ index: Int, _ word: String) -> Int? {
        let target = [UInt8](word.utf8)
        guard index + target.count <= bytes.count else { return nil }
        guard Array(bytes[index..<(index + target.count)]) == target else { return nil }
        return index + target.count
    }

    private static func validateNumber(_ bytes: [UInt8], _ index: Int) -> Int? {
        var i = index
        if i < bytes.count, bytes[i] == 0x2D { i += 1 }
        var digits = 0
        while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1; digits += 1 }
        if i < bytes.count, bytes[i] == 0x2E {
            i += 1
            var fraction = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1; fraction += 1 }
            if fraction == 0 { return nil }
        }
        if digits == 0 { return nil }
        if i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
            i += 1
            if i < bytes.count, bytes[i] == 0x2B || bytes[i] == 0x2D { i += 1 }
            var exponent = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 { i += 1; exponent += 1 }
            if exponent == 0 { return nil }
        }
        return i
    }

    private static func validateObject(_ bytes: [UInt8], _ index: Int) -> Int? {
        var i = skipWhitespace(bytes, index + 1)
        guard i < bytes.count else { return nil }
        if bytes[i] == 0x7D { return i + 1 }
        while true {
            i = skipWhitespace(bytes, i)
            guard i < bytes.count, bytes[i] == 0x22, let keyEnd = skipString(bytes, i) else { return nil }
            i = skipWhitespace(bytes, keyEnd)
            guard i < bytes.count, bytes[i] == 0x3A else { return nil }
            guard let valueEnd = validateValue(bytes, i + 1) else { return nil }
            i = skipWhitespace(bytes, valueEnd)
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x7D { return i + 1 }
            guard bytes[i] == 0x2C else { return nil }
            i += 1
            // 逗号后面必须还有一个成员，不能直接闭合。
            i = skipWhitespace(bytes, i)
            guard i < bytes.count, bytes[i] != 0x7D else { return nil }
        }
    }

    private static func validateArray(_ bytes: [UInt8], _ index: Int) -> Int? {
        var i = skipWhitespace(bytes, index + 1)
        guard i < bytes.count else { return nil }
        if bytes[i] == 0x5D { return i + 1 }
        while true {
            guard let valueEnd = validateValue(bytes, i) else { return nil }
            i = skipWhitespace(bytes, valueEnd)
            guard i < bytes.count else { return nil }
            if bytes[i] == 0x5D { return i + 1 }
            guard bytes[i] == 0x2C else { return nil }
            i = skipWhitespace(bytes, i + 1)
            guard i < bytes.count, bytes[i] != 0x5D else { return nil }
        }
    }
}

/// 按现有文件的缩进习惯生成片段，避免把 2 空格的 WorkBuddy 配置写成 4 空格。
enum JSONIndent {
    static func unit(_ bytes: [UInt8], objectStart: Int) -> String {
        guard let member = JSONSpan.members(bytes, objectStart: objectStart)?.first else { return "  " }
        var i = member.start
        var spaces = 0
        while i > 0 {
            let b = bytes[i - 1]
            if b == 0x20 { spaces += 1; i -= 1; continue }
            if b == 0x09 { return "\t" }
            break
        }
        return spaces > 0 ? String(repeating: " ", count: spaces) : "  "
    }

    /// 某个位置紧邻的缩进（同一行里、它前面连续的空格制表符）。
    static func lineIndent(_ bytes: [UInt8], at index: Int) -> String {
        var i = index
        var spaces = 0
        var tabs = 0
        while i > 0 {
            let b = bytes[i - 1]
            if b == 0x20 { spaces += 1; i -= 1; continue }
            if b == 0x09 { tabs += 1; i -= 1; continue }
            break
        }
        if tabs > 0 { return String(repeating: "\t", count: tabs) }
        return String(repeating: " ", count: spaces)
    }

    /// 某个位置所在那一行的行首缩进。位置前有冒号或逗号时，靠它才拿得对。
    static func lineStartIndent(_ bytes: [UInt8], at index: Int) -> String {
        var lineStart = index
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var i = lineStart
        var spaces = 0
        var tabs = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x20 { spaces += 1; i += 1; continue }
            if b == 0x09 { tabs += 1; i += 1; continue }
            break
        }
        if tabs > 0 { return String(repeating: "\t", count: tabs) }
        return String(repeating: " ", count: spaces)
    }
}

enum MCPWriteError: Error, LocalizedError {
    case notWritable(String)
    case parseFailed(String)
    case concurrentChange(String)
    case officialCommandFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .notWritable(path): return "写不进 " + path
        case let .parseFailed(message): return message
        case let .concurrentChange(path):
            return path + " 在检查之后被别的工具改过，已回滚，请重试"
        case let .officialCommandFailed(message): return message
        case let .unsupported(message): return message
        }
    }
}

/// 写文件前后的现场比对。旁边常有别的工具在改同一份配置，
/// 差一点就当成被抢了，回滚比悄悄覆盖更安全。
enum SafeFile {
    struct Stamp: Equatable {
        let size: Int
        let modified: Date
    }

    static func stamp(_ path: String) -> Stamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = attrs[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return Stamp(size: size, modified: modified)
    }

    /// 备份到库目录下的时间戳目录，和传输前备份放在一起。
    @discardableResult
    static func backup(path: String, backupRoot: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dir = backupRoot + "/" + String(stamp) + "-mcp"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = dir + "/" + (path as NSString).lastPathComponent
        if FileManager.default.fileExists(atPath: dest) {
            try FileManager.default.removeItem(atPath: dest)
        }
        try FileManager.default.copyItem(atPath: path, toPath: dest)
        return dest
    }

    /// 读全量，写回，写后核对。读和写之间文件被人改过就放弃。
    /// 测试用：备份之后、落盘之前调一次，好在那几百毫秒的窗口里插一手验证回滚。
    static var beforeWriteHook: (() -> Void)?

    static func rewrite(path: String, newText: String, backupRoot: String) throws -> String? {
        let real = (path as NSString).resolvingSymlinksInPath
        let before = stamp(real)
        guard let original = try? String(contentsOfFile: real, encoding: .utf8) else {
            throw MCPWriteError.notWritable(path)
        }
        let backupPath = try backup(path: real, backupRoot: backupRoot)
        beforeWriteHook?()
        // 备份动作本身也可能花时间，写完这一遍再比一次。
        guard stamp(real) == before else {
            throw MCPWriteError.concurrentChange(path)
        }
        try newText.write(toFile: real, atomically: true, encoding: .utf8)
        guard let written = try? String(contentsOfFile: real, encoding: .utf8) else {
            throw MCPWriteError.notWritable(path)
        }
        guard written == newText else {
            // 写回的内容对不上，说明中途有人插了一手，把备份放回去。
            if let backupPath {
                try? FileManager.default.removeItem(atPath: real)
                try? FileManager.default.copyItem(atPath: backupPath, toPath: real)
            }
            throw MCPWriteError.concurrentChange(path)
        }
        _ = original
        return backupPath
    }
}


/// 一条登记该写成什么样，按客户端分别给。
enum MCPEntryTemplate {
    static func entryJSON(format: MCPConfigFormat, binary: String) -> String {
        switch format {
        case let .jsonServers(_, commandIsArray):
            if commandIsArray {
                // OpenCode 的 command 是数组，写成字符串它认不出来。
                return "{\n  \"type\": \"local\",\n  \"command\": [" + quote(binary) + ", \"mcp\"]\n}"
            }
            return "{\n  \"type\": \"stdio\",\n  \"command\": " + quote(binary)
                + ",\n  \"args\": [\"mcp\"],\n  \"timeout\": 60000,\n  \"disabled\": false\n}"
        case .claudeJSON:
            return "{\n  \"type\": \"stdio\",\n  \"command\": " + quote(binary)
                + ",\n  \"args\": [\"mcp\"]\n}"
        default:
            return "{\n  \"command\": " + quote(binary) + ",\n  \"args\": [\"mcp\"]\n}"
        }
    }

    static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    /// 把一条登记渲染成「键 + 对象」的成员块。
    /// 第一行不带前导缩进（替换时就地对齐），后面每行按 indent 计算。
    /// 这里不经过 JSONSerialization：它会把键重排，写进 WorkBuddy 那份配置里
    /// 就和旁边几十条登记的写法不一样了。
    static func member(name: String, compact: String, indent: String, unit: String) -> String {
        let lines = compact.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for (index, line) in lines.enumerated() {
            let trimmed = String(line.drop { $0 == " " || $0 == "\t" })
            if index == 0 {
                // 首行是 { ，接在键后面。
                out.append(quote(name) + ": " + trimmed)
                continue
            }
            if trimmed == "}" {
                // 闭合括号和键对齐，不再往里缩一级。
                out.append(indent + trimmed)
                continue
            }
            out.append(indent + unit + trimmed)
        }
        return out.joined(separator: "\n")
    }
}

enum MCPJSONWriter {
    /// 在 JSON 文件的某个对象键下增删本服务这一条，其他键逐字节保留。
    /// replaceAll 用于 Claude Code：项目和顶层几处都有时一起改。
    static func upsert(path: String, key: String, binary: String,
                       format: MCPConfigFormat, backupRoot: String,
                       replaceAll: Bool = false) throws -> String {
        let real = (path as NSString).resolvingSymlinksInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: real)) else {
            throw MCPWriteError.notWritable(path)
        }
        let bytes = [UInt8](data)
        // 先确认整份文件能解析，带尾逗号的那种直接拒绝，别在上面做手术。
        // 注意 JSONSerialization 认尾逗号，用它校验会把 {"a": 1,} 放过去，所以走严格那套。
        if let problem = JSONSpan.validate(bytes) {
            throw MCPWriteError.parseFailed("这份 JSON 不能改：" + problem + "，先修好再加")
        }
        guard let root = JSONSpan.rootRange(bytes) else {
            throw MCPWriteError.parseFailed("根不是 JSON 对象")
        }
        let unit = JSONIndent.unit(bytes, objectStart: root.lowerBound)
        var newText: String
        if replaceAll {
            newText = try upsertAll(bytes: bytes, root: root, key: key, binary: binary,
                                    format: format, unit: unit)
        } else {
            newText = try upsertOne(bytes: bytes, root: root, key: key, binary: binary,
                                    format: format, unit: unit)
        }
        return try SafeFile.rewrite(path: real, newText: newText, backupRoot: backupRoot) ?? ""
    }

    static func remove(path: String, key: String, backupRoot: String, replaceAll: Bool = false) throws -> String {
        let real = (path as NSString).resolvingSymlinksInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: real)) else {
            throw MCPWriteError.notWritable(path)
        }
        let bytes = [UInt8](data)
        if let problem = JSONSpan.validate(bytes) {
            throw MCPWriteError.parseFailed("这份 JSON 不能改：" + problem + "，先修好再移除")
        }
        guard let root = JSONSpan.rootRange(bytes) else {
            throw MCPWriteError.parseFailed("根不是 JSON 对象")
        }
        var newText: String
        if replaceAll {
            newText = try removeAll(bytes: bytes, root: root, key: key)
        } else {
            newText = try removeOne(bytes: bytes, root: root, key: key,
                                    name: MCPTargetRegistry.entryName)
        }
        return try SafeFile.rewrite(path: real, newText: newText, backupRoot: backupRoot) ?? ""
    }

    private static func upsertOne(bytes: [UInt8], root: Range<Int>, key: String, binary: String,
                                 format: MCPConfigFormat, unit: String) throws -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        let compact = MCPEntryTemplate.entryJSON(format: format, binary: binary)
        var updated = text

        // 找到外层对象（mcpServers / mcp）的位置，没有就在根里补一个。
        if let outer = JSONSpan.member(bytes, objectStart: root.lowerBound, key: key) {
            let members = JSONSpan.members(bytes, objectStart: outer.valueStart) ?? []
            if let existing = members.first(where: { $0.key == MCPTargetRegistry.entryName }) {
                let indent = JSONIndent.lineStartIndent(bytes, at: existing.start)
                let rendered = MCPEntryTemplate.member(name: MCPTargetRegistry.entryName,
                                                       compact: compact, indent: indent, unit: unit)
                updated = replace(text: text, bytes: bytes, range: existing.start..<existing.end, with: rendered)
            } else {
                // 新条目的缩进跟着同层其他成员走，没有别的成员就比外层键多一级。
                let outerIndent = JSONIndent.lineStartIndent(bytes, at: outer.start)
                let indent = members.first.map { JSONIndent.lineStartIndent(bytes, at: $0.start) } ?? (outerIndent + unit)
                let rendered = MCPEntryTemplate.member(name: MCPTargetRegistry.entryName,
                                                       compact: compact, indent: indent, unit: unit)
                updated = insertMember(text: text, bytes: bytes, objectStart: outer.valueStart,
                                       member: rendered, indent: indent)
            }
        } else {
            // 整块新建：根里加 mcpServers，里面再放本服务。
            let rootIndent = JSONIndent.lineStartIndent(bytes, at: root.lowerBound)
            let keyIndent = rootIndent + unit
            let innerIndent = keyIndent + unit
            let rendered = MCPEntryTemplate.member(name: MCPTargetRegistry.entryName,
                                                   compact: compact, indent: innerIndent, unit: unit)
            let memberText = MCPEntryTemplate.quote(key) + ": {\n" + innerIndent + rendered
                + "\n" + keyIndent + "}"
            updated = insertMember(text: text, bytes: bytes, objectStart: root.lowerBound,
                                   member: memberText, indent: keyIndent)
        }
        return updated
    }

    /// Claude Code 的几处登记一起改。项目层级里那些也属于同一个客户端。
    private static func upsertAll(bytes: [UInt8], root: Range<Int>, key: String, binary: String,
                                  format: MCPConfigFormat, unit: String) throws -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        let compact = MCPEntryTemplate.entryJSON(format: format, binary: binary)
        var updated = text
        // 从后往前改，保证前面的下标不受影响。
        var targets: [(Range<Int>, String)] = []
        let current = [UInt8](updated.utf8)
        if let outer = JSONSpan.member(current, objectStart: root.lowerBound, key: key) {
            for member in JSONSpan.members(current, objectStart: outer.valueStart) ?? [] {
                guard member.key == MCPTargetRegistry.entryName else { continue }
                let indent = JSONIndent.lineStartIndent(current, at: member.start)
                targets.append((member.start..<member.end,
                                MCPEntryTemplate.member(name: MCPTargetRegistry.entryName,
                                                        compact: compact, indent: indent, unit: unit)))
            }
        }
        // 项目层级：projects.<路径>.mcpServers
        if let projects = JSONSpan.member(current, objectStart: root.lowerBound, key: "projects") {
            for project in JSONSpan.members(current, objectStart: projects.valueStart) ?? [] {
                guard let servers = JSONSpan.member(current, objectStart: project.valueStart, key: key) else { continue }
                for member in JSONSpan.members(current, objectStart: servers.valueStart) ?? [] {
                    guard member.key == MCPTargetRegistry.entryName else { continue }
                    let indent = JSONIndent.lineStartIndent(current, at: member.start)
                    targets.append((member.start..<member.end,
                                    MCPEntryTemplate.member(name: MCPTargetRegistry.entryName,
                                                            compact: compact, indent: indent, unit: unit)))
                }
            }
        }
        if targets.isEmpty {
            // 顶层没有就插一条，这是最常用的一处。
            return try upsertOne(bytes: current, root: root, key: key, binary: binary, format: format, unit: unit)
        }
        for (range, rendered) in targets.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            let currentBytes = [UInt8](updated.utf8)
            updated = replace(text: updated, bytes: currentBytes, range: range, with: rendered)
        }
        _ = text
        return updated
    }

    private static func removeAll(bytes: [UInt8], root: Range<Int>, key: String) throws -> String {
        var updated = String(decoding: bytes, as: UTF8.self)
        var removed = 0
        while true {
            let current = [UInt8](updated.utf8)
            guard let currentRoot = JSONSpan.rootRange(current) else { break }
            var hit: (String, JSONSpan.Member)?
            if let outer = JSONSpan.member(current, objectStart: currentRoot.lowerBound, key: key),
               let member = (JSONSpan.members(current, objectStart: outer.valueStart) ?? [])
                .first(where: { $0.key == MCPTargetRegistry.entryName }) {
                hit = (key, member)
            }
            if hit == nil,
               let projects = JSONSpan.member(current, objectStart: currentRoot.lowerBound, key: "projects") {
                for project in JSONSpan.members(current, objectStart: projects.valueStart) ?? [] {
                    guard let servers = JSONSpan.member(current, objectStart: project.valueStart, key: key),
                          let member = (JSONSpan.members(current, objectStart: servers.valueStart) ?? [])
                            .first(where: { $0.key == MCPTargetRegistry.entryName }) else { continue }
                    hit = (key, member)
                    break
                }
            }
            guard let (_, member) = hit else { break }
            updated = removeMember(text: updated, bytes: current, member: member)
            removed += 1
        }
        _ = removed
        return updated
    }

    private static func removeOne(bytes: [UInt8], root: Range<Int>, key: String, name: String) throws -> String {
        guard let outer = JSONSpan.member(bytes, objectStart: root.lowerBound, key: key),
              let member = (JSONSpan.members(bytes, objectStart: outer.valueStart) ?? [])
                .first(where: { $0.key == name }) else {
            // 本来就没有，不用改文件。
            return String(decoding: bytes, as: UTF8.self)
        }
        let text = String(decoding: bytes, as: UTF8.self)
        return removeMember(text: text, bytes: bytes, member: member)
    }

    /// 删掉成员连同它前面的逗号或后面的逗号，保证剩下的 JSON 合法。
    static func removeMember(text: String, bytes: [UInt8], member: JSONSpan.Member) -> String {
        // 往后看：逗号在后面，就把「成员 + 逗号 + 空白」一起删掉。
        var after = JSONSpan.skipWhitespace(bytes, member.end)
        if after < bytes.count, bytes[after] == 0x2C {
            after += 1
            var lineEnd = after
            while lineEnd < bytes.count, bytes[lineEnd] == 0x20 || bytes[lineEnd] == 0x09 { lineEnd += 1 }
            if lineEnd < bytes.count, bytes[lineEnd] == 0x0A { lineEnd += 1 }
            return replace(text: text, bytes: bytes, range: member.start..<lineEnd, with: "")
        }
        // 逗号在前面，连同行首缩进一起删。
        var lineStart = member.start
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        var before = lineStart
        while before > 0, bytes[before - 1] != 0x2C {
            let b = bytes[before - 1]
            if b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { break }
            before -= 1
        }
        if before > 0, bytes[before - 1] == 0x2C {
            return replace(text: text, bytes: bytes, range: (before - 1)..<member.end, with: "")
        }
        return replace(text: text, bytes: bytes, range: member.start..<member.end, with: "")
    }

    /// 往对象末尾插一个成员。空对象直接放，非空对象补逗号换行。
    /// member 的第一行不带缩进，由这里补上，后续行的缩进在渲染时已经算好。
    static func insertMember(text: String, bytes: [UInt8], objectStart: Int,
                             member: String, indent: String) -> String {
        guard let members = JSONSpan.members(bytes, objectStart: objectStart) else { return text }
        if let last = members.last {
            let insertion = ",\n" + indent + member
            return insert(text: text, at: last.end, content: insertion)
        }
        // 空对象：{ } 之间塞一行。先按「没有成员」算出闭合花括号的位置。
        let close = JSONSpan.skipValue(bytes, objectStart) ?? (objectStart + 1)
        let closeBrace = close - 1
        let outerIndent = JSONIndent.lineStartIndent(bytes, at: objectStart)
        let insertion = "\n" + indent + member + "\n" + outerIndent
        return replace(text: text, bytes: bytes, range: (objectStart + 1)..<closeBrace, with: insertion)
    }

    static func replace(text: String, bytes: [UInt8], range: Range<Int>, with content: String) -> String {
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: range.lowerBound)
        let end = text.utf8.index(text.utf8.startIndex, offsetBy: range.upperBound)
        var out = text
        out.replaceSubrange(start..<end, with: content)
        _ = bytes
        return out
    }

    static func insert(text: String, at offset: Int, content: String) -> String {
        let index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
        var out = text
        out.insert(contentsOf: content, at: index)
        return out
    }
}


/// TOML 只做行级操作：定位目标段的标题行到下一个段标题之间的范围，整体替换。
/// 段外面一个字节都不动，注释和别的段都还在。
enum TOMLSection {
    struct Section {
        /// 段标题行的起点。
        let headerStart: Int
        /// 段结束位置（下一个段标题的起点或文件末尾）。
        let end: Int
        /// 段内的正文（不含标题行）。
        let text: String
    }

    static func find(text: String, prefix: String, name: String) -> Section? {
        let lines = text.components(separatedBy: "\n")
        var offsets: [Int] = []
        var running = 0
        for line in lines {
            offsets.append(running)
            running += line.utf8.count + 1
        }
        let wanted = "[" + prefix + "." + name + "]"
        var headerIndex: Int?
        var endIndex = lines.count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }
            if headerIndex == nil {
                if trimmed == wanted { headerIndex = index }
                continue
            }
            // 子表（[a.b.c]）也算同一段的延续？不算。mcp_servers 下每个服务都是独立表，
            // 但 http_headers 这种是它的子表，应当算在内。
            if trimmed.hasPrefix("[" + prefix + "." + name + ".") { continue }
            endIndex = index
            break
        }
        guard let start = headerIndex else { return nil }
        let headerStart = offsets[start]
        let end = endIndex < lines.count ? offsets[endIndex] : text.utf8.count
        let bodyStart = min(text.utf8.count, headerStart + lines[start].utf8.count + 1)
        let body = bodyStart < end
            ? String(decoding: Array(text.utf8)[bodyStart..<min(end, text.utf8.count)], as: UTF8.self)
            : ""
        return Section(headerStart: headerStart, end: end, text: body)
    }

    /// 段里取一个键的值，只认一级键，不碰子表里的同名键。
    static func value(_ body: String, key: String) -> String? {
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            guard name == key else { continue }
            var raw = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // 去掉行尾注释，但要认住引号里的 #。
            if let hash = firstUnquoted(raw, character: "#") {
                raw = raw[..<hash].trimmingCharacters(in: .whitespaces)
            }
            return raw
        }
        return nil
    }

    static func firstUnquoted(_ text: String, character: Character) -> String.Index? {
        var inString = false
        var quote: Character = "\""
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if c == "\\" {
                    index = text.index(after: index)
                    if index < text.endIndex { index = text.index(after: index) }
                    continue
                }
                if c == quote { inString = false }
            } else if c == "\"" || c == "'" {
                inString = true
                quote = c
            } else if c == character {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum MCPTOMLWriter {
    static func upsert(path: String, prefix: String, binary: String, backupRoot: String) throws -> String {
        let real = (path as NSString).resolvingSymlinksInPath
        guard let text = try? String(contentsOfFile: real, encoding: .utf8) else {
            throw MCPWriteError.notWritable(path)
        }
        let body = "command = \"" + TOMLSection.escape(binary) + "\"\nargs = [\"mcp\"]\n"
        var newText: String
        if let section = TOMLSection.find(text: text, prefix: prefix, name: MCPTargetRegistry.entryName) {
            newText = replace(text: text, range: section.headerStart..<section.end,
                              with: "[" + prefix + "." + MCPTargetRegistry.entryName + "]\n" + body + "\n")
        } else {
            // 新段插到文件末尾；末尾没换行先补一个，别把新标题粘到最后一行上。
            var head = text
            if !head.hasSuffix("\n") { head += "\n" }
            if !head.hasSuffix("\n\n"), !head.isEmpty { head += "\n" }
            newText = head + "[" + prefix + "." + MCPTargetRegistry.entryName + "]\n" + body
        }
        // 写前校验：段数不能变少，新内容必须能重新定位到。
        guard TOMLSection.find(text: newText, prefix: prefix, name: MCPTargetRegistry.entryName) != nil else {
            throw MCPWriteError.parseFailed("改写后的 TOML 里找不到本服务的段，已放弃")
        }
        return try SafeFile.rewrite(path: real, newText: newText, backupRoot: backupRoot) ?? ""
    }

    static func remove(path: String, prefix: String, backupRoot: String) throws -> String {
        let real = (path as NSString).resolvingSymlinksInPath
        guard let text = try? String(contentsOfFile: real, encoding: .utf8) else {
            throw MCPWriteError.notWritable(path)
        }
        guard let section = TOMLSection.find(text: text, prefix: prefix, name: MCPTargetRegistry.entryName) else {
            return ""
        }
        let newText = replace(text: text, range: section.headerStart..<section.end, with: "")
        return try SafeFile.rewrite(path: real, newText: newText, backupRoot: backupRoot) ?? ""
    }

    static func replace(text: String, range: Range<Int>, with content: String) -> String {
        let start = text.utf8.index(text.utf8.startIndex, offsetBy: range.lowerBound)
        let end = text.utf8.index(text.utf8.startIndex, offsetBy: range.upperBound)
        var out = text
        out.replaceSubrange(start..<end, with: content)
        return out
    }
}


// MARK: - 接入 / 移除 / 修复

struct MCPActionPreview {
    let target: MCPClientTarget
    let summary: String
    /// 将要改动的文件。命令式可能是客户端自己决定写哪，这里只说明会调什么。
    let paths: [String]
    let before: String
    let after: String
    let commandLine: String?
}

struct MCPActionResult {
    let ok: Bool
    let message: String
    let backupPath: String?
    let report: MCPClientReport?
}

enum MCPOnboarder {
    static var backupRoot: String { Store.defaultRoot + "/backups" }

    /// 先算出「改完长什么样」，界面拿它做预览，命令行的 --dry-run 也用它。
    static func preview(_ target: MCPClientTarget, action: Action,
                        binary: String = MCPTargetRegistry.currentBinary()) throws -> MCPActionPreview {
        switch target.style {
        case .plugin:
            throw MCPWriteError.unsupported("DeepSeek Harness 是插件式接入，请在它的插件市场里装 " + MCPTargetRegistry.pluginRoot)
        case .command:
            let command = try commandLine(target, action: action, binary: binary)
            return MCPActionPreview(
                target: target,
                summary: action == .connect
                    ? "调用 " + target.displayName + " 的官方命令登记本服务"
                    : "调用 " + target.displayName + " 的官方命令移除本服务",
                paths: [target.configPath],
                before: "由 " + target.displayName + " 自己维护，不直接改文件",
                after: command.joined(separator: " "),
                commandLine: command.joined(separator: " "))
        case .config:
            let real = (target.configPath as NSString).resolvingSymlinksInPath
            let original = (try? String(contentsOfFile: real, encoding: .utf8)) ?? ""
            let updated: String
            switch target.format {
            case let .tomlSection(prefix):
                updated = try renderTOML(original: original, prefix: prefix, binary: binary, action: action)
            case let .jsonServers(key, _):
                updated = try renderJSON(original: original, path: real, key: key,
                                          binary: binary, format: target.format, action: action)
            case .claudeJSON:
                updated = try renderJSON(original: original, path: real, key: "mcpServers",
                                          binary: binary, format: target.format, action: action)
            case .pluginManifest:
                updated = original
            }
            return MCPActionPreview(
                target: target,
                summary: action == .connect
                    ? "在 " + target.displayName + " 的登记文件里加一条本服务"
                    : "从 " + target.displayName + " 的登记文件里删掉本服务这条",
                paths: [target.configPath],
                before: original,
                after: updated,
                commandLine: nil)
        }
    }

    enum Action: String {
        case connect
        case disconnect
    }

    /// 真正执行。写文件前已经做过一次 preview，这里重算一次再落地，
    /// 避免预览到确认之间文件被改过却没发现。
    static func perform(_ target: MCPClientTarget, action: Action,
                        binary: String = MCPTargetRegistry.currentBinary()) throws -> MCPActionResult {
        switch target.style {
        case .plugin:
            throw MCPWriteError.unsupported("插件式接入不能一键完成，请按面板里的指引安装")
        case .command:
            let command = try commandLine(target, action: action, binary: binary)
            let result = try runCommand(command)
            guard result.status == 0 else {
                throw MCPWriteError.officialCommandFailed(
                    target.displayName + " 的命令返回 " + String(result.status) + "：" + result.output)
            }
            let report = MCPOnboarding.inspect(target)
            return MCPActionResult(ok: true,
                                   message: target.displayName + "：" + (action == .connect ? "已接入" : "已移除")
                                       + "（用的是官方命令）",
                                   backupPath: nil, report: report)
        case .config:
            let real = (target.configPath as NSString).resolvingSymlinksInPath
            let fm = FileManager.default
            switch target.format {
            case let .tomlSection(prefix):
                if action == .connect {
                    let backup = try MCPTOMLWriter.upsert(path: real, prefix: prefix, binary: binary, backupRoot: backupRoot)
                    return finish(target, action: action, backup: backup)
                }
                let backup = try MCPTOMLWriter.remove(path: real, prefix: prefix, backupRoot: backupRoot)
                return finish(target, action: action, backup: backup)
            case let .jsonServers(key, _):
                if action == .connect {
                    if !fm.fileExists(atPath: real) {
                        try fm.createDirectory(atPath: (real as NSString).deletingLastPathComponent,
                                               withIntermediateDirectories: true)
                        let seed = "{\n  \"" + key + "\": {}\n}\n"
                        try seed.write(toFile: real, atomically: true, encoding: .utf8)
                    }
                    let backup = try MCPJSONWriter.upsert(path: real, key: key, binary: binary,
                                                           format: target.format, backupRoot: backupRoot)
                    return finish(target, action: action, backup: backup)
                }
                guard fm.fileExists(atPath: real) else {
                    return MCPActionResult(ok: true, message: target.displayName + " 本来就没有登记", backupPath: nil,
                                           report: MCPOnboarding.inspect(target))
                }
                let backup = try MCPJSONWriter.remove(path: real, key: key, backupRoot: backupRoot)
                return finish(target, action: action, backup: backup)
            case .claudeJSON:
                guard fm.fileExists(atPath: real) else {
                    throw MCPWriteError.notWritable(target.configPath)
                }
                if action == .connect {
                    let backup = try MCPJSONWriter.upsert(path: real, key: "mcpServers", binary: binary,
                                                           format: target.format, backupRoot: backupRoot,
                                                           replaceAll: true)
                    return finish(target, action: action, backup: backup)
                }
                let backup = try MCPJSONWriter.remove(path: real, key: "mcpServers",
                                                       backupRoot: backupRoot, replaceAll: true)
                return finish(target, action: action, backup: backup)
            case .pluginManifest:
                throw MCPWriteError.unsupported("插件式接入不能一键完成")
            }
        }
    }

    private static func finish(_ target: MCPClientTarget, action: Action, backup: String?) -> MCPActionResult {
        let report = MCPOnboarding.inspect(target)
        var message: String
        switch report.state {
        case .connected(let path, _, _, let tools):
            message = target.displayName + "：已接入，" + path + "，" + String(tools.count) + " 个工具可用"
        case .connectFailed(_, _, let reason, _):
            message = target.displayName + "：登记写好了，但握手没通过 —— " + reason
        default:
            message = target.displayName + "：" + action.rawValue + " 完成，" + report.state.label
        }
        if action == .disconnect, !report.state.isUsable {
            message = target.displayName + "：已移除登记"
        }
        return MCPActionResult(ok: action == .disconnect || report.state.isUsable,
                               message: message, backupPath: backup, report: report)
    }

    // MARK: 渲染

    static func renderTOML(original: String, prefix: String, binary: String, action: Action) throws -> String {
        let body = "command = \"" + TOMLSection.escape(binary) + "\"\nargs = [\"mcp\"]\n"
        if let section = TOMLSection.find(text: original, prefix: prefix, name: MCPTargetRegistry.entryName) {
            if action == .disconnect {
                return MCPTOMLWriter.replace(text: original, range: section.headerStart..<section.end, with: "")
            }
            return MCPTOMLWriter.replace(text: original, range: section.headerStart..<section.end,
                                         with: "[" + prefix + "." + MCPTargetRegistry.entryName + "]\n" + body + "\n")
        }
        guard action == .connect else { return original }
        var head = original
        if !head.hasSuffix("\n") { head += "\n" }
        if !head.isEmpty, !head.hasSuffix("\n\n") { head += "\n" }
        return head + "[" + prefix + "." + MCPTargetRegistry.entryName + "]\n" + body
    }

    /// 预览用：在内存里算出改完的全文。写盘还是走 MCPJSONWriter，两边算法一致。
    static func renderJSON(original: String, path: String, key: String, binary: String,
                           format: MCPConfigFormat, action: Action) throws -> String {
        let tempRoot = NSTemporaryDirectory() + "agent-history-preview-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tempRoot) }
        try FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
        let temp = tempRoot + "/" + (path as NSString).lastPathComponent
        try original.write(toFile: temp, atomically: true, encoding: .utf8)
        let backupDir = tempRoot + "/backups"
        try FileManager.default.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
        if action == .connect {
            _ = try MCPJSONWriter.upsert(path: temp, key: key, binary: binary, format: format, backupRoot: backupDir)
        } else {
            _ = try MCPJSONWriter.remove(path: temp, key: key, backupRoot: backupDir)
        }
        return (try? String(contentsOfFile: temp, encoding: .utf8)) ?? original
    }

    // MARK: 官方命令

    static func commandLine(_ target: MCPClientTarget, action: Action, binary: String) throws -> [String] {
        guard let name = target.commandName, let path = MCPTargetRegistry.commandPath(name) else {
            throw MCPWriteError.officialCommandFailed(
                (target.commandName ?? "命令") + " 不在 PATH 里，装好之后再来，或者按面板里的片段手工配置")
        }
        switch target.kind {
        case .claude:
            // 默认 scope 是 local，只对当前目录生效；写 user 层级才对所有项目都可读。
            return action == .connect
                ? [path, "mcp", "add", "-s", "user", MCPTargetRegistry.entryName, "--", binary, "mcp"]
                : [path, "mcp", "remove", "-s", "user", MCPTargetRegistry.entryName]
        case .opencode:
            return action == .connect
                ? [path, "mcp", "add", MCPTargetRegistry.entryName, "--", binary, "mcp"]
                : [path, "mcp", "remove", MCPTargetRegistry.entryName]
        default:
            throw MCPWriteError.unsupported(target.displayName + " 没有官方登记命令")
        }
    }

    struct CommandResult {
        let status: Int32
        let output: String
    }

    static func runCommand(_ argv: [String]) throws -> CommandResult {
        guard let exe = argv.first else { throw MCPWriteError.officialCommandFailed("命令是空的") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // 有些命令会等着读输入，给个空 stdin 直接关闭，免得挂住。
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
        } catch {
            throw MCPWriteError.officialCommandFailed("起不来：" + error.localizedDescription)
        }
        try? input.fileHandleForWriting.close()
        // 命令可能去连网，最多等 20 秒。
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning {
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw MCPWriteError.officialCommandFailed(exe + " 20 秒没有返回，已经中断")
        }
        process.waitUntilExit()
        let outText = readPipe(out)
        let errText = readPipe(err)
        let combined = [outText, errText].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " / ")
        return CommandResult(status: process.terminationStatus, output: String(combined.suffix(400)))
    }

    private static func readPipe(_ pipe: Pipe) -> String {
        let handle = pipe.fileHandleForReading
        let data = handle.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 修复

    struct FixItem {
        let target: MCPClientTarget
        let oldBinary: String
    }

    /// 收集所有「登记在但路径失效」的客户端。
    static func staleRegistrations(reports: [MCPClientReport]) -> [FixItem] {
        reports.compactMap { report in
            guard case let .connectFailed(_, binary, _, fixable) = report.state, fixable else { return nil }
            return FixItem(target: report.target, oldBinary: binary)
        }
    }

    /// 收集「连得上但登记的不是当前这份程序」的客户端。
    /// 升了级却还指着旧包时，握手只会拿到旧包里的工具，光看「已接入」发现不了。
    static func outdatedRegistrations(reports: [MCPClientReport],
                                      binary: String = MCPTargetRegistry.currentBinary()) -> [FixItem] {
        let current = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        return reports.compactMap { report in
            guard case let .connected(_, registered, _, _) = report.state else { return nil }
            let resolved = URL(fileURLWithPath: registered).resolvingSymlinksInPath().path
            guard resolved != current else { return nil }
            return FixItem(target: report.target, oldBinary: registered)
        }
    }

    /// 一次要修的都在这里：路径失效的和版本落后的。同一个客户端只出现一次。
    static func repairable(reports: [MCPClientReport],
                           binary: String = MCPTargetRegistry.currentBinary()) -> [FixItem] {
        let broken = staleRegistrations(reports: reports)
        let seen = Set(broken.map { $0.target.kind })
        return broken + outdatedRegistrations(reports: reports, binary: binary)
            .filter { !seen.contains($0.target.kind) }
    }

    static func repair(items: [FixItem], binary: String = MCPTargetRegistry.currentBinary()) -> [MCPActionResult] {
        items.map { item in
            do {
                return try perform(item.target, action: .connect, binary: binary)
            } catch {
                return MCPActionResult(ok: false,
                                       message: item.target.displayName + "：改写失败 —— " + describe(error),
                                       backupPath: nil, report: nil)
            }
        }
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription { return text }
        return String(describing: error)
    }

    // MARK: 配置片段

    /// 手工粘贴用的片段，路径取当前这份程序的真实路径。
    static func snippet(_ target: MCPClientTarget, binary: String = MCPTargetRegistry.currentBinary()) -> String {
        switch target.format {
        case let .tomlSection(prefix):
            return "[" + prefix + "." + MCPTargetRegistry.entryName + "]\ncommand = \"" + binary + "\"\nargs = [\"mcp\"]"
        case let .jsonServers(key, _):
            let entry = MCPEntryTemplate.entryJSON(format: target.format, binary: binary)
            let member = MCPEntryTemplate.member(name: MCPTargetRegistry.entryName,
                                                 compact: entry, indent: "    ", unit: "  ")
            return "{\n  \"" + key + "\": {\n    " + member + "\n  }\n}"
        case .claudeJSON:
            return "claude mcp add -s user " + MCPTargetRegistry.entryName + " -- " + binary + " mcp"
        case .pluginManifest:
            return "重启 DeepSeek Harness，插件 " + MCPTargetRegistry.pluginRoot + " 会自动加载"
        }
    }
}





