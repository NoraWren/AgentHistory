import Foundation

enum SourceKind: String, CaseIterable {
    case codex, claude, workbuddy, opencode, kimi, deepseek

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

    var rootPath: String {
        let home = NSHomeDirectory()
        switch self {
        case .codex: return home + "/.codex"
        case .claude: return home + "/.claude"
        case .workbuddy: return home + "/.workbuddy"
        case .opencode: return home + "/.local/share/opencode"
        case .kimi: return home + "/.kimi-code"
        case .deepseek: return home + "/Library/Application Support/dsh-desktop/harness"
        }
    }
}

struct SourceInfo: Identifiable {
    let id: String
    let kind: SourceKind
    var available: Bool
    var lastSyncAt: Int64
    var lastError: String?
    var threadCount: Int = 0
}

struct ProjectRow: Identifiable {
    let id: String
    let path: String
    let name: String
    let lastActiveAt: Int64
    var threadCount: Int = 0
}

struct ThreadRow: Identifiable {
    let id: String
    let sourceId: String
    let sourceKind: SourceKind
    let nativeId: String
    let projectPath: String
    let title: String
    let updatedAt: Int64
    let itemCount: Int
    let threadSource: String
    let archived: Bool
}

struct ItemRow: Identifiable {
    let id: String
    let threadId: String
    let ordinal: Int
    let itemType: String
    let role: String
    let createdAt: Int64
    let text: String
    let truncated: Bool
}

struct ItemInput {
    let nativeId: String
    let ordinal: Int
    let itemType: String
    let role: String
    let createdAt: Int64
    let text: String
    let rawJSON: String
    var truncated: Bool = false
}

struct ThreadInput {
    let sourceId: String
    let nativeId: String
    let projectPath: String
    let title: String
    let createdAt: Int64
    let updatedAt: Int64
    let model: String
    let threadSource: String
    let archived: Bool
    let preview: String
}

struct SearchHit: Identifiable {
    let id: String
    let threadId: String
    let threadTitle: String
    let sourceKind: SourceKind
    let itemType: String
    let createdAt: Int64
    let text: String
    let ordinal: Int
}

struct SyncPhase {
    let name: String
    let completed: Int
    let total: Int
}

enum DeliveryMode: String {
    case nativeImport = "原生导入"
    case mcpRead = "MCP 直读"
    case handoff = "交接包"
}

struct TransferPlan {
    let sourceKind: SourceKind
    let targetKind: SourceKind
    let mode: DeliveryMode
    let threadIDs: [String]
    let messageCount: Int
    let duplicateCount: Int
    let redactedCount: Int
    let estimatedBytes: Int
    let targetPath: String
    let notes: [String]
}

enum HistoryError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}
