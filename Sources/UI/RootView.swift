import SwiftUI
import AppKit

private let dayFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
}()

func shortTime(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    return dayFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

func highlighted(_ text: String, query: String) -> AttributedString {
    var attr = AttributedString(text)
    attr.foregroundColor = .secondary
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return attr }
    var cursor = attr.startIndex
    while cursor < attr.endIndex,
          let found = attr[cursor...].range(of: q, options: [.caseInsensitive]) {
        attr[found].backgroundColor = Color.yellow.opacity(0.35)
        attr[found].foregroundColor = Color.primary
        attr[found].inlinePresentationIntent = .stronglyEmphasized
        cursor = found.upperBound
    }
    return attr
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 290)
        } content: {
            ThreadListView(model: model)
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 430)
        } detail: {
            DetailView(model: model)
        }
        .toolbar {
            // 用 primaryAction：.automatic 在这个窗口里会把第一个按钮折进溢出菜单，
            // 「汇编」就点不到了。
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showDigest = true
                } label: {
                    Label("汇编", systemImage: "text.append")
                }
                .help("把一段时间的对话汇编成结论")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showStatus = true
                } label: {
                    Label("来源状态", systemImage: "gauge.medium")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showSync = true
                } label: {
                    Label("同步", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBarView(model: model) }
        .sheet(isPresented: Binding(get: { model.showSync }, set: { model.showSync = $0 })) {
            SyncWizardView(model: model)
        }
        .sheet(isPresented: Binding(get: { model.showStatus }, set: { model.showStatus = $0 })) {
            SourceStatusView(model: model)
        }
        .sheet(isPresented: Binding(get: { model.showDigest }, set: { model.showDigest = $0 })) {
            DigestView(model: model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            model.searchFocused = true
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.65)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agent 记忆").font(.system(size: 13, weight: .semibold))
                    Text("跨客户端历史").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    group("来源") {
                        sourceRow(title: "全部来源", count: model.stats.threadCount, tint: Theme.accent,
                                  icon: "square.stack.3d.up.fill", selected: model.filterSource == nil) {
                            model.filterSource = nil; model.reload()
                        }
                        ForEach(model.sources.filter { $0.available }) { src in
                            sourceRow(title: src.kind.displayName, count: src.threadCount,
                                      tint: Theme.source(src.kind), icon: Theme.sourceIcon(src.kind),
                                      selected: model.filterSource == src.kind,
                                      warning: src.lastError) {
                                model.filterSource = src.kind; model.reload()
                            }
                        }
                        ForEach(model.sources.filter { !$0.available }) { src in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(Color.gray.opacity(0.4)).frame(width: 6, height: 6).padding(.top, 4)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(src.kind.displayName).font(.system(size: 11)).foregroundStyle(.tertiary)
                                    // 目录没装和装上却读不出来是两件事，别都写成「未安装」。
                                    if let reason = src.lastError, !reason.contains("未找到"), !reason.isEmpty {
                                        Text(reason).font(.system(size: 9)).foregroundStyle(.orange)
                                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                                Text(unavailableLabel(src.lastError)).font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .help(src.lastError ?? "数据目录不存在")
                        }
                    }

                    group("项目") {
                        ForEach(model.projects.prefix(30)) { p in
                            HStack(spacing: 8) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(model.filterProject == p.path ? Theme.accent : Color.secondary.opacity(0.6))
                                Text(p.name).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Text("\(p.threadCount)").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(model.filterProject == p.path ? Theme.accentSoft : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.filterProject = (model.filterProject == p.path) ? nil : p.path
                                model.reload()
                            }
                            .help(p.path)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            content()
        }
    }

    /// 不可用来源右侧的短标签：目录不在叫「未安装」，装在但读不了叫「读取失败」。
    private func unavailableLabel(_ reason: String?) -> String {
        guard let reason else { return "未安装" }
        if reason.contains("未找到") { return "未安装" }
        if reason.contains("占用") { return "被占用" }
        if reason.contains("zstd") { return "缺少解压工具" }
        return "读取失败"
    }

    private func sourceRow(title: String, count: Int, tint: Color, icon: String,
                           selected: Bool, warning: String? = nil,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint).frame(width: 13)
            Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer()
            // 目录在、但上次同步失败：来源本身还列着，得给个提示，不然看不出它这次没同步上。
            if let warning, !warning.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9)).foregroundStyle(.orange)
                    .help(warning)
            }
            Text("\(count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(selected ? tint : Color.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(selected ? tint.opacity(0.14) : Color.clear, in: Capsule())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

struct ThreadListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索会话、命令、结论", text: Binding(get: { model.searchText }, set: { model.searchText = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { model.runSearch() }
                if !model.searchText.isEmpty {
                    Button { model.searchText = ""; model.searchHits = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.subtle, lineWidth: 1))
            .padding(10)

            filterBar

            if !model.searchHits.isEmpty {
                HStack {
                    Text("找到 \(model.searchHits.count) 个会话").font(.system(size: 9)).foregroundStyle(.secondary)
                    if model.searchHits.contains(where: { $0.copyCount > 0 }) {
                        Text("已合并副本").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("导出结果") { model.exportSearchResults() }
                        .buttonStyle(.link).font(.system(size: 10))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            }

            if let notice = model.jumpNotice {
                Text(notice)
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 4)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    if !model.searchHits.isEmpty {
                        ForEach(model.searchHits) { hit in
                            Button { model.openHit(hit) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(hit.threadTitle)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Text(highlighted(hit.text.replacingOccurrences(of: "\n", with: " "), query: model.searchText))
                                        .font(.system(size: 11))
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Pill(text: hit.sourceKind.displayName, color: Theme.source(hit.sourceKind))
                                        Text(shortTime(hit.createdAt)).font(.system(size: 9)).foregroundStyle(.tertiary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(model.selectedThreadId == hit.threadId ? Theme.accentSoft : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 6)
                            .contextMenu {
                                Button("导出此会话") { model.exportThreads([hit.threadId]) }
                            }
                        }
                    } else {
                        ForEach(model.threads) { t in
                            ThreadRowView(thread: t, selected: model.selectedThreadId == t.id)
                                .onTapGesture { model.select(t) }
                                .padding(.horizontal, 6)
                        }
                        if !model.threadListExhausted {
                            Button {
                                model.loadMoreThreads()
                            } label: {
                                Text("加载更多（已显示 \(model.threads.count) / \(model.threadListTotal)）")
                                    .font(.system(size: 10))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        } else if model.threads.count < model.threadListTotal {
                            Text("只显示了 \(model.threads.count) 个")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                                .padding(.top, 8)
                        }
                        if model.threads.isEmpty {
                            Text("没有符合条件的历史")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .padding(.top, 40)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.35))
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { model.mergeCopies },
                                 set: { model.mergeCopies = $0; model.reload() })) {
                Text("合并副本").font(.system(size: 10))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Divider().frame(height: 12)
            Picker("时间", selection: Binding(get: { model.filterDays },
                    set: { model.filterDays = $0; if !model.searchText.isEmpty { model.runSearch() } })) {
                Text("全部").tag(0)
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
            }
            .frame(maxWidth: 110)
            Toggle(isOn: Binding(get: { model.onlyUser },
                    set: { model.onlyUser = $0; if !model.searchText.isEmpty { model.runSearch() } })) {
                Text("只看提问").font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

struct ThreadRowView: View {
    let thread: ThreadRow
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(thread.title.isEmpty ? "（无标题）" : thread.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Pill(text: thread.sourceKind.displayName, color: Theme.source(thread.sourceKind))
                if thread.copyCount > 0 {
                    Text("另有 \(thread.copyCount) 处副本")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text((thread.projectPath as NSString).lastPathComponent)
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(shortTime(thread.updatedAt)).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(selected ? Theme.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

struct DetailView: View {
    @ObservedObject var model: AppModel

    var thread: ThreadRow? {
        model.threads.first { $0.id == model.selectedThreadId }
    }

    var body: some View {
        if let t = thread {
            threadBody(t)
        } else {
            OverviewView(model: model)
        }
    }

    private func threadBody(_ t: ThreadRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(t.title.isEmpty ? "（无标题）" : t.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Pill(text: t.sourceKind.displayName, color: Theme.source(t.sourceKind))
                    Label((t.projectPath as NSString).lastPathComponent, systemImage: "folder")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("\(t.itemCount) 条记录").font(.system(size: 10)).foregroundStyle(.tertiary)
                    if !model.turns.isEmpty {
                        turnPicker
                    }
                    Spacer()
                    Button {
                        model.exportCurrent()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.down")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.link)
                    .help("导出为 Markdown")
                    if t.sourceKind == .codex {
                        Button {
                            if let url = URL(string: "codex://threads/\(t.nativeId)") { NSWorkspace.shared.open(url) }
                        } label: {
                            Label("在 Codex 打开", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.link)
                    }
                }
                if let lineage = try? model.store.lineage(threadId: t.id), lineage.members.count > 1 {
                    lineageSection(lineage, current: t)
                }
                if let notice = model.jumpNotice {
                    Text(notice).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .padding(.top, 52)
            .background(.regularMaterial)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            // 轮次变了就插一条分隔，长会话里能一眼看出问到第几轮。
                            if item.turnOrdinal > 0,
                               index == 0 || model.items[index - 1].turnOrdinal != item.turnOrdinal {
                                turnDivider(item.turnOrdinal)
                            }
                            MessageBubble(item: item, highlighted: model.highlightItemId == item.id)
                                .id(item.id)
                                .contextMenu {
                                    Button("复制完整正文") { model.copyItem(item) }
                                }
                                .onAppear {
                                    if item.id == model.items.last?.id { model.loadMore() }
                                }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                }
                // LazyVStack 里目标条目往往还没渲染，一次 scrollTo 经常落空。
                // 连滚几拍，等条目进入布局后再滚也能滚到位。
                // 依赖里带上 jumpToken：连着点同一轮时 id 没变，光看 id 不会重新滚。
                .task(id: "\(model.selectedThreadId ?? "")#\(model.jumpToken)") {
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    guard !Task.isCancelled else { return }
                    if let id = model.highlightItemId {
                        for attempt in 0..<8 {
                            if attempt > 0 {
                                try? await Task.sleep(nanoseconds: 70_000_000)
                            }
                            guard !Task.isCancelled else { return }
                            proxy.scrollTo(id, anchor: .center)
                        }
                    } else if let first = model.items.first?.id {
                        // 换了会话就从顶上开始，别停在上一份对话的滚动位置。
                        proxy.scrollTo(first, anchor: .top)
                    }
                }
            }
        }
    }

    private func turnDivider(_ ordinal: Int) -> some View {
        turnDivider(ordinal, prompt: model.turns.first { $0.ordinal == ordinal }?.prompt ?? "")
    }

    private func turnDivider(_ ordinal: Int, prompt: String) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
            Text("第 \(ordinal) 轮")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            if !prompt.isEmpty {
                Text(prompt.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
        }
        .padding(.top, 4)
    }

    /// 轮次跳转。几十上百轮的会话靠滚动找某一轮不现实，直接从表头跳。
    private var turnPicker: some View {
        Menu {
            ForEach(model.turns) { turn in
                Button {
                    model.jumpToTurn(turn.ordinal)
                } label: {
                    Text(model.currentTurn == turn.ordinal ? "✓ " + turnLabel(turn) : turnLabel(turn))
                }
            }
        } label: {
            Label("共 \(model.turns.count) 轮", systemImage: "list.number")
                .font(.system(size: 10))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(model.currentTurn > 0 ? "当前在第 \(model.currentTurn) 轮，点开可跳转" : "点开跳到某一轮")
    }

    private func turnLabel(_ turn: Store.TurnRow) -> String {
        let prompt = turn.prompt.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = prompt.count > 34 ? String(prompt.prefix(34)) + "…" : prompt
        return head.isEmpty ? "第 \(turn.ordinal) 轮 · \(turn.itemCount) 条" : "第 \(turn.ordinal) 轮 · \(head)"
    }

    private func lineageSection(_ lineage: LineageInfo, current: ThreadRow) -> some View {
        HStack(spacing: 8) {
            Label("内容族 \(lineage.members.count) 个成员", systemImage: "square.stack.3d.up")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(lineage.members.filter { $0.id != current.id }) { m in
                Button {
                    model.select(nil)
                    if let t = model.threads.first(where: { $0.id == m.id }) {
                        model.select(t)
                    } else if let t = try? model.store.thread(id: m.id) {
                        model.select(t)
                    }
                } label: {
                    Text("\(m.sourceKind.displayName)\(m.role == "copy" ? " 副本" : " 原创会话")")
                        .font(.system(size: 9))
                }
                .buttonStyle(.link)
                .help("\(m.relationLabel)，目标标识 \(m.nativeId)")
            }
            Spacer()
        }
    }
}

struct MessageBubble: View {
    let item: ItemRow
    var highlighted: Bool = false

    private var isUser: Bool { item.itemType == "userMessage" }
    private var isTool: Bool { item.itemType == "commandExecution" || item.itemType == "toolResult" }
    private var isReasoning: Bool { item.itemType == "reasoning" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if !isUser {
                        Text(label)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(shortTime(item.createdAt))
                        .font(.system(size: 9))
                        .foregroundStyle(isUser ? Color.white.opacity(0.65) : Color.secondary.opacity(0.6))
                }
                if isTool || isReasoning, highlighted {
                    // 命中的是折叠的工具调用或思考时，直接摊开正文，不让用户再点一次。
                    Text(item.text)
                        .font(.system(size: 11, design: isTool ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(12)
                } else if isTool || isReasoning {
                    DisclosureGroup {
                        Text(item.text)
                            .font(.system(size: 11, design: isTool ? .monospaced : .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Text(compact)
                            .font(.system(size: 10, design: isTool ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(item.text)
                        .font(.system(size: 12))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .foregroundStyle(isUser ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(highlighted ? Color.yellow : Color.clear, lineWidth: 1.5))
            if !isUser { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var bubbleBackground: Color {
        if isUser { return Theme.accent }
        if isTool || isReasoning { return Color(nsColor: .controlBackgroundColor).opacity(0.6) }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var label: String {
        switch item.itemType {
        case "agentMessage": return "助手"
        case "reasoning": return "思考"
        case "commandExecution": return "命令"
        case "toolResult": return "输出"
        case "plan": return "计划"
        default: return item.itemType
        }
    }

    private var tint: Color {
        switch item.itemType {
        case "agentMessage": return .green
        case "reasoning": return .purple
        default: return .orange
        }
    }

    private var compact: String {
        let single = item.text.replacingOccurrences(of: "\n", with: " ")
        return isReasoning ? "思考 \(item.text.count) 字，点击展开" : String(single.prefix(96))
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("总览").font(.system(size: 18, weight: .semibold))
                Text("本机各客户端的会话、项目和任务记录都在这里")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    StatCard(value: "\(model.stats.threadCount)", label: "会话", icon: "bubble.left.and.bubble.right.fill", tint: Theme.accent)
                    StatCard(value: compactNumber(model.stats.itemCount), label: "记录", icon: "text.alignleft", tint: .teal)
                    StatCard(value: "\(model.stats.projectCount)", label: "项目", icon: "folder.fill", tint: .orange)
                    StatCard(value: "\(model.stats.todayItems)", label: "今日新增", icon: "bolt.fill", tint: .pink)
                }

                SectionCard(title: "近 30 天") {
                    ActivityBars(data: model.activity)
                }

                SectionCard(title: "最近会话") {
                    VStack(spacing: 2) {
                        ForEach(model.threads.prefix(7)) { t in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Theme.source(t.sourceKind))
                                    .frame(width: 3, height: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title.isEmpty ? "（无标题）" : t.title)
                                        .font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text((t.projectPath as NSString).lastPathComponent)
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(shortTime(t.updatedAt)).font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(t) }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.2))
    }

    private func compactNumber(_ n: Int) -> String {
        n >= 10000 ? "\(n / 10000)万" : "\(n)"
    }
}

struct ActivityBars: View {
    let data: [(day: String, count: Int)]

    var body: some View {
        let maxValue = max(data.map(\.count).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(data, id: \.day) { item in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.25 + 0.75 * Double(item.count) / Double(maxValue)))
                        .frame(height: max(3, 52 * Double(item.count) / Double(maxValue)))
                    if item.day.hasSuffix("01") || item.day == data.first?.day {
                        Text(String(item.day.suffix(2)))
                            .font(.system(size: 7)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .help("\(item.day)：\(item.count) 条")
            }
        }
        .frame(height: 70, alignment: .bottom)
    }
}

struct StatusBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.syncing {
                ProgressView(value: model.progress).frame(width: 140)
                Text(model.phase).font(.system(size: 10))
                Text("\(Int(model.progress * 100))%").font(.system(size: 10)).monospacedDigit()
            } else {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(model.statusText).font(.system(size: 10)).foregroundStyle(.secondary)
                if let report = model.lastExport {
                    Text("· 导出：\(report.written) 个文件").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button("在访达中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: report.directory) }
                        .buttonStyle(.link).font(.system(size: 10))
                }
                Text("· 今日 \(model.stats.todayItems)").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("立即同步") { model.runSync() }.buttonStyle(.link).font(.system(size: 10))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(.bar)
    }
}

struct SourceStatusView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text("来源状态").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
                .accessibilityLabel("关闭")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.sources) { src in
                        sourceCard(src)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 4)
            }

            Divider().padding(.top, 10)

            HStack(spacing: 16) {
                Text("总会话 \(model.stats.threadCount)")
                Text("总条目 \(model.stats.itemCount)")
                Text("库 \(ByteCountFormatter.string(fromByteCount: model.store.dbSizeBytes(), countStyle: .file))")
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(width: 520, height: 440, alignment: .topLeading)
    }

    private func sourceCard(_ src: SourceInfo) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(src.available ? Color.green : Color.gray)
                .frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(src.kind.displayName).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(src.threadCount) 个会话").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(src.available ? "可用 · 上次同步 \(shortTime(src.lastSyncAt * 1000))" : "不可用")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if let err = src.lastError, !err.isEmpty {
                    Text(err).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }
}
