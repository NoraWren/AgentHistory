import SwiftUI

enum Theme {
    static let accent = Color(red: 0.365, green: 0.400, blue: 0.945)
    static let accentSoft = Color(red: 0.365, green: 0.400, blue: 0.945).opacity(0.12)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let subtle = Color(nsColor: .separatorColor).opacity(0.35)
    static let tertiary = Color.secondary.opacity(0.75)

    static func source(_ kind: SourceKind) -> Color {
        switch kind {
        case .codex: return Color(red: 0.365, green: 0.400, blue: 0.945)
        case .claude: return Color(red: 0.925, green: 0.545, blue: 0.310)
        case .workbuddy: return Color(red: 0.145, green: 0.678, blue: 0.612)
        case .opencode: return Color(red: 0.545, green: 0.400, blue: 0.890)
        case .kimi: return Color(red: 0.255, green: 0.435, blue: 0.635)
        case .deepseek: return Color(red: 0.145, green: 0.470, blue: 0.960)
        }
    }

    static func sourceIcon(_ kind: SourceKind) -> String {
        switch kind {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkle"
        case .workbuddy: return "person.2.fill"
        case .opencode: return "terminal.fill"
        case .kimi: return "moon.stars.fill"
        case .deepseek: return "waveform"
        }
    }

    /// 记忆三类的颜色：交接包蓝、汇编青、结论橙。与会话来路区分开，扫一眼就知道这行不是聊天。
    static func memory(_ kind: MemoryKind) -> Color {
        switch kind {
        case .handoff: return Color(red: 0.310, green: 0.520, blue: 0.940)
        case .digest: return Color(red: 0.145, green: 0.640, blue: 0.600)
        case .fact: return Color(red: 0.870, green: 0.520, blue: 0.180)
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.accent
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : color)
            .background(filled ? color : color.opacity(0.13))
            .clipShape(Capsule())
    }
}

struct StatCard: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.subtle, lineWidth: 1))
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.subtle, lineWidth: 1))
    }
}
