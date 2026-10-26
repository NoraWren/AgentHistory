import Foundation

enum TextTools {
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    static func isWordChar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let c = scalar.value
            let isDigit = (0x30...0x39).contains(c)
            let isUpper = (0x41...0x5A).contains(c)
            let isLower = (0x61...0x7A).contains(c)
            return isDigit || isUpper || isLower || c == 0x5F || c == 0x2D || c == 0x2E || c == 0x40 || c == 0x3A
        }
        return false
    }

    /// 连续汉字拆成单字，英文与数字保留整词，其余字符作为分隔。
    static func segment(_ text: String) -> [String] {
        var tokens: [String] = []
        var word = ""
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(Character(scalar)))
            } else if isWordChar(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                tokens.append(word)
                word = ""
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens
    }

    static func segmentJoined(_ text: String) -> String {
        segment(text).joined(separator: " ")
    }

    /// 连续汉字作为短语，英文数字作为独立词，用 AND 连接。
    static func makeMatchQuery(_ query: String) -> String {
        var parts: [String] = []
        var run: [String] = []
        var runIsCJK = false
        var word = ""

        func flushRun() {
            if !run.isEmpty {
                let body = run.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                parts.append(runIsCJK ? body.joined(separator: " ") : body.joined(separator: " "))
            }
            run = []
        }
        func flushWord() {
            if !word.isEmpty {
                parts.append("\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                word = ""
            }
        }

        for scalar in query.unicodeScalars {
            if isCJK(scalar) {
                flushWord()
                if !runIsCJK && !run.isEmpty { flushRun() }
                runIsCJK = true
                run.append(String(Character(scalar)))
            } else if isWordChar(scalar) {
                flushRun()
                word.unicodeScalars.append(scalar)
            } else {
                flushRun(); flushWord()
            }
        }
        flushRun(); flushWord()
        return parts.isEmpty ? "" : parts.joined(separator: " AND ")
    }

    /// 与 makeMatchQuery 同源，但把连续汉字拆成单字后用 AND 连接，
    /// 用于短语命中不足时的宽松补充。
    static func makeLooseQuery(_ query: String) -> String {
        var parts: [String] = []
        var word = ""
        func flushWord() {
            if !word.isEmpty {
                parts.append("\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                word = ""
            }
        }
        for scalar in query.unicodeScalars {
            if isCJK(scalar) {
                flushWord()
                parts.append("\"" + String(Character(scalar)) + "\"")
            } else if isWordChar(scalar) {
                word.unicodeScalars.append(scalar)
            } else {
                flushWord()
            }
        }
        flushWord()
        return parts.isEmpty ? "" : parts.joined(separator: " AND ")
    }

    /// 连续汉字保留为一个真正的 FTS5 短语（"表 格"），用于短语优先的第一段检索。
    static func makePhraseQuery(_ query: String) -> String {
        var parts: [String] = []
        var run: [String] = []
        var word = ""
        func flushRun() {
            if !run.isEmpty {
                parts.append("\"" + run.joined(separator: " ") + "\"")
                run = []
            }
        }
        func flushWord() {
            if !word.isEmpty {
                parts.append("\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\"")
                word = ""
            }
        }
        for scalar in query.unicodeScalars {
            if isCJK(scalar) {
                flushWord()
                run.append(String(Character(scalar)))
            } else if isWordChar(scalar) {
                flushRun()
                word.unicodeScalars.append(scalar)
            } else {
                flushRun(); flushWord()
            }
        }
        flushRun(); flushWord()
        return parts.isEmpty ? "" : parts.joined(separator: " AND ")
    }

    /// 去掉检索词里的 FTS5 语法字符，避免用户输入被当成表达式。
    static func sanitize(_ query: String) -> String {
        let stripped = query.unicodeScalars.filter { scalar in
            !"\"*(){}[]^~:\\".unicodeScalars.contains(scalar)
        }
        return String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Redactor {
    struct Rule {
        let name: String
        let regex: NSRegularExpression
    }

    static let rules: [Rule] = {
        let defs: [(String, String)] = [
            ("openai", #"\bsk-[A-Za-z0-9_-]{20,}"#),
            ("github", #"\bgh[pousr]_[A-Za-z0-9]{30,}"#),
            ("gitlab", #"\bglpat-[A-Za-z0-9_-]{15,}"#),
            ("aws", #"\bAKIA[0-9A-Z]{16}\b"#),
            ("jwt", #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}"#),
            ("bearer", #"(?i)\bBearer\s+[A-Za-z0-9._-]{20,}"#),
            ("private_key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
        ]
        return defs.compactMap { name, pattern in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            return Rule(name: name, regex: re)
        }
    }()

    struct Result {
        let text: String
        let hits: Int
    }

    static func mask(_ input: String) -> Result {
        guard !input.isEmpty else { return Result(text: input, hits: 0) }
        var current = input
        var hits = 0
        for rule in rules {
            let range = NSRange(current.startIndex..., in: current)
            let matches = rule.regex.matches(in: current, range: range)
            if matches.isEmpty { continue }
            hits += matches.count
            for m in matches.reversed() {
                guard let r = Range(m.range, in: current) else { continue }
                let original = String(current[r])
                current.replaceSubrange(r, with: placeholder(original, rule: rule.name))
            }
        }
        return Result(text: current, hits: hits)
    }

    private static func placeholder(_ s: String, rule: String) -> String {
        if rule == "private_key" { return "[已遮蔽的私钥块]" }
        if s.count <= 10 { return "[已遮蔽]\(s.prefix(2))…" }
        return "\(s.prefix(6))…[已遮蔽:\(rule)]…\(s.suffix(4))"
    }
}
