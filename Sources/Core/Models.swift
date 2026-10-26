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
    /// 同族里除自己以外的会话数，0 表示没有副本。
    var copyCount: Int = 0
    var familyId: String? = nil
    /// original / copy / 空字符串（未归族）。
    var lineageRole: String = ""
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
    /// 所属轮次在本会话里的序号，0 表示没归到任何一轮。
    var turnOrdinal: Int = 0
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
    /// 来源原生的轮次标识。Codex 直接取投影库的 turn_id，其余来源由适配器给出；
    /// 留空表示这条接在会话已有的最后一轮后面。
    var turnId: String? = nil
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
    /// 命中条目实际所在的会话。合并视角下它可能是副本。
    var hitThreadId: String? = nil
    var copyCount: Int = 0
    var groupHits: Int = 1
    /// 短语命中 / 宽松命中
    var matchKind: String = "短语"

    var targetThreadId: String { hitThreadId ?? threadId }
}

struct SearchOptions {
    var sourceKind: SourceKind? = nil
    var projectPath: String? = nil
    var since: Int64? = nil
    var until: Int64? = nil
    var onlyUser: Bool = false
    var limit: Int = 60
    var mergeCopies: Bool = true
}

struct LineageMember: Identifiable {
    let id: String
    let title: String
    let sourceKind: SourceKind
    let nativeId: String
    /// original 或 copy
    let role: String
    /// confirmed（同步记录）或 inferred（按内容推断）
    let relation: String
    let direction: String
    let targetRef: String
    let createdAt: Int64
    let itemCount: Int

    var isRepresentative: Bool { role == "original" }
    var relationLabel: String { relation == "confirmed" ? "同步记录" : "按内容推断" }
}

struct LineageInfo {
    let familyId: String
    let members: [LineageMember]

    var representative: LineageMember? { members.first(where: { $0.isRepresentative }) ?? members.first }
    var copies: [LineageMember] { members.filter { !$0.isRepresentative } }
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
