import SwiftUI
import AppKit

/// 记忆清单：交接包、汇编、结论分类列出，结论可以筛类别、也可以作废。
/// 状态都放在 AppModel 上：这套构建没有 SwiftUI 宏插件，视图里不能存 @State。
struct MemoryListView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 720, height: 560, alignment: .topLeading)
        .onAppear { model.refreshMemoryList() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("记忆清单").font(.system(size: 16, weight: .semibold))
                Text("交接包、汇编与结论都在这里；结论可以作废，作废后默认不再被召回。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
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
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(get: { model.memoryListKind },
                    set: { model.memoryListKind = $0; model.refreshMemoryList() })) {
                ForEach(MemoryKind.allCases, id: \.self) { k in
                    Text(k.displayName).tag(k)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .controlSize(.small)

            if model.memoryListKind == .fact {
                Picker("类别", selection: Binding(get: { model.memoryListCategory },
                        set: { model.memoryListCategory = $0; model.refreshMemoryList() })) {
                    Text("全部类别").tag("")
                    ForEach(MemoryKind.factCategories, id: \.self) { c in
                        Text(c).tag(c)
                    }
                }
                .frame(width: 130)
                .controlSize(.small)

                Toggle("含已作废", isOn: Binding(get: { model.memoryListIncludeInactive },
                        set: { model.memoryListIncludeInactive = $0; model.refreshMemoryList() }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }
            Spacer()
            if !model.memoryListNote.isEmpty {
                Text(model.memoryListNote).font(.system(size: 10)).foregroundStyle(.orange)
            }
            Button("重新读取") { model.refreshMemoryList() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if model.memoryListDocs.isEmpty {
                    Text(emptyHint)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                ForEach(model.memoryListDocs) { doc in
                    row(doc)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyHint: String {
        switch model.memoryListKind {
        case .fact: return "还没有结论。agent 做事时可以主动记一条，记下来的会出现在这里。"
        case .handoff: return "还没有交接包。让 agent 写一份交接包，导出的也会进这里。"
        case .digest: return "还没有汇编。点工具栏的「汇编」生成一份，生成后立刻进这里。"
        }
    }

    private func row(_ doc: MemoryDoc) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.memory(doc.kind))
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if !doc.category.isEmpty {
                        Pill(text: doc.category, color: Theme.memory(doc.kind))
                    }
                    if !doc.statusLabel.isEmpty {
                        Pill(text: doc.statusLabel, color: .gray)
                    }
                    Text(doc.title.isEmpty ? "（无标题）" : doc.title)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(stamp(doc.createdAt)).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(doc.body.replacingOccurrences(of: "\n", with: " ").prefix(140))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    if doc.threadId.isEmpty {
                        Text(doc.kind == .digest ? "汇编不归属单个会话" : "无出处")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    } else {
                        Button("来源会话") { openSource(doc) }
                            .buttonStyle(.link).font(.system(size: 9))
                    }
                    Button("查看正文") { model.previewMemory(doc) }
                        .buttonStyle(.link).font(.system(size: 9))
                    if doc.kind == .fact, doc.status == "active" {
                        Button("作废") { model.voidFact(doc.id) }
                            .buttonStyle(.link).font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }

    private func openSource(_ doc: MemoryDoc) {
        guard let thread = try? model.store.thread(id: doc.threadId) else {
            model.memoryListNote = "来源会话已不在库里：\(doc.threadId)"
            return
        }
        dismiss()
        model.openThread(thread.id)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(model.memoryListDocs.count) 条").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
            Button("关闭") { dismiss() }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

/// 记忆正文：文件不在磁盘上时也能看到索引里存的那一份。
struct MemoryPreviewView: View {
    let doc: MemoryDoc
    @Environment(\.dismiss) private var dismiss

    private var fileExists: Bool {
        !doc.path.isEmpty && FileManager.default.fileExists(atPath: doc.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Pill(text: doc.kind.displayName, color: Theme.memory(doc.kind), filled: true)
                        if !doc.category.isEmpty { Pill(text: doc.category, color: Theme.memory(doc.kind)) }
                        if !doc.statusLabel.isEmpty { Pill(text: doc.statusLabel, color: .gray) }
                    }
                    Text(doc.title.isEmpty ? "（无标题）" : doc.title)
                        .font(.system(size: 15, weight: .semibold))
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            HStack(spacing: 10) {
                Text(stamp(doc.createdAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                if !doc.threadId.isEmpty {
                    Label(doc.threadId, systemImage: "bubble.left")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                if doc.threadId.isEmpty, doc.kind == .fact {
                    Text("无出处").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            if !fileExists {
                Text(doc.path.isEmpty
                     ? "这条结论只存在库里，没有对应文件。"
                     : "文件 \(doc.path) 已不在磁盘上，下面是索引里保存的正文。")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }

            Divider()

            ScrollView {
                Text(doc.body.isEmpty ? "（正文为空）" : doc.body)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }

            Divider()

            HStack(spacing: 12) {
                Button("复制正文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(doc.body, forType: .string)
                }
                .disabled(doc.body.isEmpty)
                if fileExists {
                    Button("打开文件") { NSWorkspace.shared.open(URL(fileURLWithPath: doc.path)) }
                        .buttonStyle(.link).font(.system(size: 11))
                    Button("在访达中显示") {
                        NSWorkspace.shared.selectFile(doc.path, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.link).font(.system(size: 11))
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .frame(width: 700, height: 560, alignment: .topLeading)
    }
}
