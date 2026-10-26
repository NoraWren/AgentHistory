import SwiftUI
import AppKit

// 接入面板：六个客户端各自装没装、接没接、握手通不通。
// 检查要拉六个子进程，全放后台，界面先画出来再一格一格填。

final class MCPOnboardingModel: ObservableObject {
    @Published var reports: [MCPClientReport] = []
    @Published var checking = false
    @Published var lastChecked: Date?
    /// 正在执行动作的客户端，按钮上转圈用。
    @Published var busy: MCPClientKind?
    /// 做完一件事的一句结论。
    @Published var notice: String?
    /// 出错时的原因，比 notice 显眼。
    @Published var problem: String?
    /// 待确认的改动：有值时先给用户看差异，点了确认才写盘。
    @Published var pending: PendingAction?
    @Published var snippetTitle = ""
    @Published var snippetText: String?
    @Published var snippetNote = ""

    struct PendingAction: Identifiable {
        let id = UUID()
        let target: MCPClientTarget
        let action: MCPOnboarder.Action
        let preview: MCPActionPreview
    }

    private var generation = 0

    var targets: [MCPClientTarget] { MCPTargetRegistry.all() }

    var usableCount: Int { reports.filter { $0.state.isUsable }.count }

    /// 只算「本来能用却用不了」的，未接入是常态，别拿来吓人。
    var failures: [MCPClientReport] { reports.filter { $0.state.isFailure } }

    var staleCount: Int { MCPOnboarder.staleRegistrations(reports: reports).count }

    var lastCheckedText: String {
        guard let lastChecked else { return "还没检查" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: lastChecked)
    }

    /// 结论一句话，面板底部和菜单栏都用它。
    var summary: String {
        if reports.isEmpty { return checking ? "正在检查…" : "还没检查" }
        var line = "\(usableCount)/\(reports.count) 个客户端能调用本服务"
        if !failures.isEmpty { line += "，" + String(failures.count) + " 个连不上" }
        if staleCount > 0 { line += "，" + String(staleCount) + " 个路径失效" }
        return line
    }

    func report(for kind: MCPClientKind) -> MCPClientReport? {
        reports.first { $0.target.kind == kind }
    }

    /// 后台把六个客户端都过一遍。并发跑，整体就是最慢那一个的时间。
    func refresh(reason: String = "") {
        guard !checking else { return }
        checking = true
        problem = nil
        if !reason.isEmpty { notice = reason }
        generation += 1
        let mine = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = MCPOnboarding.inspectAll(parallel: true)
            DispatchQueue.main.async {
                guard let self, mine == self.generation else { return }
                self.reports = result
                self.checking = false
                self.lastChecked = Date()
            }
        }
    }

    /// 接入前先算差异，算不出来就把原因说清，别让按钮点了没反应。
    func ask(_ target: MCPClientTarget, action: MCPOnboarder.Action) {
        problem = nil
        do {
            let preview = try MCPOnboarder.preview(target, action: action)
            pending = PendingAction(target: target, action: action, preview: preview)
        } catch {
            problem = MCPOnboarder.describe(error)
        }
    }

    func cancelPending() { pending = nil }

    /// 真写盘。写入本身已经做过并发校验，这里只需要把结果讲清楚。
    func confirmPending() {
        guard let task = pending else { return }
        pending = nil
        busy = task.target.kind
        notice = nil
        let target = task.target
        let action = task.action
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try MCPOnboarder.perform(target, action: action)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = nil
                    self.notice = result.message
                    if let backup = result.backupPath {
                        self.notice = (self.notice ?? "") + "（原文件已备份：" + backup + "）"
                    }
                    self.refresh()
                    AppDelegate.shared?.refreshStatusMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = nil
                    self.problem = MCPOnboarder.describe(error)
                }
            }
        }
    }

    /// 一次把路径失效的都改回当前这份程序。
    func repairAll() {
        let items = MCPOnboarder.staleRegistrations(reports: reports)
        guard !items.isEmpty else { notice = "没有失效路径，不需要修"; return }
        busy = nil
        problem = nil
        notice = "正在修 " + String(items.count) + " 个客户端的路径"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = MCPOnboarder.repair(items: items)
            DispatchQueue.main.async {
                guard let self else { return }
                let ok = results.filter { $0.ok }.count
                self.notice = "修好 " + String(ok) + " 个，失败 " + String(results.count - ok) + " 个"
                let bad = results.filter { !$0.ok }.map(\.message)
                if !bad.isEmpty { self.problem = bad.joined(separator: "；") }
                self.refresh()
                AppDelegate.shared?.refreshStatusMenu()
            }
        }
    }

    /// 手工配置用：给一份能直接粘的片段。
    func showSnippet(_ target: MCPClientTarget) {
        snippetTitle = target.displayName
        snippetText = MCPOnboarder.snippet(target)
        snippetNote = target.note
    }

    func copyToPasteboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        notice = "片段已复制，粘到对应配置里就行"
    }

    /// 撤销刚打开的那个片段弹层。
    func dismissSnippet() { snippetText = nil }
}

// MARK: - 差异

enum MCPDiff {
    struct Line: Identifiable {
        enum Kind { case same, removed, added }
        let id: Int
        let kind: Kind
        let text: String
    }

    /// 配置文件的改动通常只有一小块，去掉首尾相同的行，中间只留三条上下文。
    static func render(before: String, after: String, context: Int = 3) -> [Line] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tailOld = old.count
        var tailNew = new.count
        while tailOld > head, tailNew > head, old[tailOld - 1] == new[tailNew - 1] {
            tailOld -= 1
            tailNew -= 1
        }
        var lines: [Line] = []
        var id = 0
        let headStart = max(0, head - context)
        for i in headStart..<head {
            lines.append(Line(id: id, kind: .same, text: old[i])); id += 1
        }
        if head - headStart > 0 && headStart > 0 {
            lines.append(Line(id: id, kind: .same, text: "…")); id += 1
        }
        for i in head..<tailOld {
            lines.append(Line(id: id, kind: .removed, text: old[i])); id += 1
        }
        for i in head..<tailNew {
            lines.append(Line(id: id, kind: .added, text: new[i])); id += 1
        }
        let tailEnd = min(old.count, tailOld + context)
        for i in tailOld..<tailEnd {
            lines.append(Line(id: id, kind: .same, text: old[i])); id += 1
        }
        if tailEnd < old.count {
            lines.append(Line(id: id, kind: .same, text: "…")); id += 1
        }
        return lines
    }
}

// MARK: - 面板

struct MCPOnboardingView: View {
    @ObservedObject var model: MCPOnboardingModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.targets, id: \.kind) { target in
                        row(target)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 580, alignment: .topLeading)
        .sheet(item: $model.pending) { task in
            MCPPreviewSheet(model: model, task: task)
        }
        .sheet(isPresented: Binding(get: { model.snippetText != nil },
                                    set: { if !$0 { model.dismissSnippet() } })) {
            MCPSnippetSheet(model: model)
        }
        .onAppear { if model.reports.isEmpty { model.refresh() } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("MCP 接入").font(.system(size: 16, weight: .semibold))
                Text("让别的 AI 客户端也能查这份历史。每个客户端各自登记，互不影响。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.checking {
                ProgressView().controlSize(.small)
            }
            Button {
                model.refresh()
            } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .disabled(model.checking)
            .help("重新握手检查六个客户端")
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("关闭")
            .accessibilityLabel("关闭")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func row(_ target: MCPClientTarget) -> some View {
        let report = model.report(for: target.kind)
        let state = report?.state
        let tint = MCPOnboardingView.tint(state)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: Theme.sourceIcon(MCPOnboardingView.sourceKind(target.kind)))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.displayName).font(.system(size: 12, weight: .medium))
                    Pill(text: target.style.label, color: .secondary)
                    Spacer()
                    if model.busy == target.kind {
                        ProgressView().controlSize(.mini)
                    }
                    if let state {
                        Pill(text: state.label, color: tint, filled: state.isUsable)
                    } else {
                        Text(model.checking ? "检查中" : "未检查")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                if let report {
                    Text(report.reason)
                        .font(.system(size: 10))
                        .foregroundStyle(report.state.isFailure ? Color.orange : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Text(MCPOnboardingView.shortPath(report.configPath))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if report.state.toolCount > 0 {
                            Text("\(report.state.toolCount) 个工具").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text(target.configPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            actions(target, state: state)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(state?.isFailure == true ? Color.orange.opacity(0.45) : Theme.subtle, lineWidth: 1))
    }

    @ViewBuilder
    private func actions(_ target: MCPClientTarget, state: MCPClientState?) -> some View {
        HStack(spacing: 6) {
            if target.style == .plugin {
                // 插件式没法一键写，只能告诉人去哪儿装。
                Button("怎么装") { model.showSnippet(target) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if state?.isUsable == true {
                Button("移除") { model.ask(target, action: .disconnect) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if state?.isFixable == true {
                Button("修好路径") { model.ask(target, action: .connect) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button("接入") { model.ask(target, action: .connect) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state == nil || (state?.isFailure == true && state?.isFixable == false))
            }
            Menu {
                Button("复制配置片段") { model.showSnippet(target) }
                if target.style != .plugin {
                    Button(state?.isUsable == true ? "重新写入路径" : "接入") {
                        model.ask(target, action: .connect)
                    }
                }
                if state?.isUsable == true {
                    Button("移除登记") { model.ask(target, action: .disconnect) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("更多")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let problem = model.problem {
                Text(problem)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(model.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                Text("最近检查 " + model.lastCheckedText).font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if model.staleCount > 0 {
                    Button("修复全部失效路径") { model.repairAll() }
                        .controlSize(.small)
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    static func sourceKind(_ kind: MCPClientKind) -> SourceKind {
        SourceKind(rawValue: kind.rawValue) ?? .codex
    }

    static func tint(_ state: MCPClientState?) -> Color {
        guard let state else { return .secondary }
        switch state {
        case .connected, .pluginInstalled: return .green
        case .connectFailed, .broken: return .orange
        case .notConfigured, .pluginMissing: return .secondary
        case .notInstalled: return Color.secondary.opacity(0.6)
        }
    }

    /// 家目录太长，中间省略，只留尾巴和开头。
    static func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - 差异预览

struct MCPPreviewSheet: View {
    @ObservedObject var model: MCPOnboardingModel
    let task: MCPOnboardingModel.PendingAction
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.action == .connect ? "确认接入" : "确认移除")
                    .font(.system(size: 15, weight: .semibold))
                Text(task.preview.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(task.preview.paths.joined(separator: "、"))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(MCPDiff.render(before: task.preview.before, after: task.preview.after)) { line in
                        HStack(spacing: 6) {
                            Text(marker(line.kind))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .frame(width: 10, alignment: .leading)
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(line.kind == .same ? Color.secondary : Color.primary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(color(line.kind).opacity(line.kind == .same ? 0 : 0.12))
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))

            Divider()
            HStack(spacing: 10) {
                Text("只改本服务这一条，同文件里别的登记不动；写之前会先备份。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(task.action == .connect ? "写入" : "移除") {
                    dismiss()
                    model.pending = task
                    model.confirmPending()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 620, height: 460, alignment: .topLeading)
    }

    private func marker(_ kind: MCPDiff.Line.Kind) -> String {
        switch kind {
        case .same: return ""
        case .removed: return "−"
        case .added: return "+"
        }
    }

    private func color(_ kind: MCPDiff.Line.Kind) -> Color {
        switch kind {
        case .same: return .secondary
        case .removed: return .red
        case .added: return .green
        }
    }
}

// MARK: - 片段

struct MCPSnippetSheet: View {
    @ObservedObject var model: MCPOnboardingModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.snippetTitle + " 的配置片段")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.snippetNote).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
            Divider()
            ScrollView {
                Text(model.snippetText ?? "")
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 10) {
                Text("片段里的路径是当前这份程序的真实位置。")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button("复制") { model.copyToPasteboard(model.snippetText ?? "") }
                    .keyboardShortcut(.defaultAction)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560, height: 380, alignment: .topLeading)
    }
}

