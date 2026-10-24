import SwiftUI

final class WizardModel: ObservableObject {
    let store: Store
    @Published var source: SourceKind = .codex
    @Published var target: SourceKind = .workbuddy
    @Published var plan: TransferPlan?
    @Published var running = false
    @Published var previewing = false
    @Published var progress: Double = 0
    @Published var phase = ""
    @Published var message = "选择来源和目标，先看预览。预览不会写入任何文件。"
    @Published var artifacts: [String] = []
    @Published var cancelRequested = false
    @Published var finished = false

    init(store: Store) { self.store = store }

    func preview() {
        guard !running, !previewing else { return }
        previewing = true
        message = "正在统计会话和消息…"
        let src = source, dst = target
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try TransferPlanner.plan(store: self.store, source: src, target: dst) }
            DispatchQueue.main.async {
                self.previewing = false
                guard self.source == src, self.target == dst else { return }
                switch outcome {
                case .success(let p):
                    self.plan = p
                    self.finished = false
                    self.progress = 0
                    self.message = p.threadIDs.isEmpty
                        ? "这个来源还没有可交付的会话，先同步一次历史。"
                        : "预览完成，尚未写入任何文件。"
                case .failure(let error):
                    self.plan = nil
                    self.message = "预览失败：\(error)"
                }
            }
        }
    }

    func execute() {
        guard let plan, !running else { return }
        running = true
        cancelRequested = false
        finished = false
        progress = 0
        phase = "准备"
        artifacts = []
        message = "正在执行"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try TransferRunner(store: self.store).execute(
                    plan: plan,
                    shouldCancel: { self.cancelRequested }
                ) { fraction, phase in
                    DispatchQueue.main.async {
                        self.progress = fraction
                        self.phase = phase
                    }
                }
                DispatchQueue.main.async {
                    self.running = false
                    self.finished = true
                    self.progress = 1
                    self.phase = "完成"
                    self.message = "\(result.detail)\n成功 \(result.written)，跳过 \(result.skipped)，失败 \(result.failed)"
                    self.artifacts = result.artifacts
                }
            } catch {
                DispatchQueue.main.async {
                    self.running = false
                    self.message = "执行失败：\(error)"
                }
            }
        }
    }
}

struct SyncWizardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var wizard: WizardModel
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _wizard = ObservedObject(wrappedValue: WizardModel(store: model.store))
    }

    private var availableSources: [SourceKind] {
        model.sources.filter { $0.available }.map(\.kind)
    }

    private var step: Int {
        if wizard.finished { return 3 }
        if wizard.plan != nil { return 2 }
        return 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pickers
                    if let plan = wizard.plan { planCard(plan) }
                    if wizard.running || wizard.previewing || wizard.progress > 0 { progressBlock }
                    Text(wizard.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !wizard.artifacts.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(wizard.artifacts.prefix(3), id: \.self) { a in
                                Text((a as NSString).lastPathComponent)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let first = availableSources.first { wizard.source = first }
            if wizard.target == wizard.source {
                wizard.target = SourceKind.allCases.first { $0 != wizard.source } ?? .codex
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("同步历史").font(.system(size: 17, weight: .semibold))
                Text("把会话历史交给另一个客户端").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                stepDot(1, "选择")
                stepLine
                stepDot(2, "预览")
                stepLine
                stepDot(3, "完成")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func stepDot(_ index: Int, _ label: String) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(step >= index ? Theme.accent : Color.gray.opacity(0.25))
                if step > index {
                    Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(index)").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(step >= index ? .white : .secondary)
                }
            }
            .frame(width: 15, height: 15)
            Text(label).font(.system(size: 9)).foregroundStyle(step >= index ? .primary : .tertiary)
        }
    }

    private var stepLine: some View {
        Rectangle().fill(Color.gray.opacity(0.2)).frame(width: 14, height: 1)
    }

    private var pickers: some View {
        HStack(spacing: 12) {
            pickerCard(title: "来源", kind: wizard.source, enabled: true) { k in
                wizard.source = k; wizard.plan = nil; wizard.finished = false
                if k == wizard.target {
                    wizard.target = SourceKind.allCases.first { $0 != k } ?? .workbuddy
                }
            }
            Image(systemName: "arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            pickerCard(title: "目标", kind: wizard.target, enabled: true) { k in
                wizard.target = k; wizard.plan = nil; wizard.finished = false
            }
        }
    }

    private func pickerCard(title: String, kind: SourceKind, enabled: Bool,
                            onChange: @escaping (SourceKind) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.source(kind).opacity(0.14))
                    Image(systemName: Theme.sourceIcon(kind))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.source(kind))
                }
                .frame(width: 30, height: 30)
                Picker("", selection: Binding(get: { kind }, set: { onChange($0) })) {
                    if title == "来源" {
                        ForEach(availableSources, id: \.self) { k in Text(k.displayName).tag(k) }
                    } else {
                        ForEach(SourceKind.allCases.filter { $0 != wizard.source }, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.subtle, lineWidth: 1))
    }

    private func planCard(_ plan: TransferPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Pill(text: plan.mode.rawValue, color: Theme.accent, filled: true)
                Spacer()
                Text(plan.targetPath)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 0) {
                metric("\(plan.threadIDs.count)", "会话")
                divider
                metric("\(plan.messageCount)", "消息")
                divider
                metric("\(plan.duplicateCount)", "重复")
                divider
                metric("\(plan.redactedCount)", "遮蔽")
            }
            Text("预计写入 \(ByteCountFormatter.string(fromByteCount: Int64(plan.estimatedBytes), countStyle: .file))")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
            ForEach(plan.notes, id: \.self) { note in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "info.circle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.subtle, lineWidth: 1))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Theme.subtle).frame(width: 1, height: 26)
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if wizard.previewing {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: wizard.progress)
            }
            HStack {
                Text(wizard.previewing ? "统计中" : wizard.phase).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if !wizard.previewing {
                    Text("\(Int(wizard.progress * 100))%").font(.system(size: 10)).monospacedDigit()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("取消") {
                if wizard.running { wizard.cancelRequested = true } else { dismiss() }
            }
            Spacer()
            Button("预览") { wizard.preview() }
                .disabled(wizard.running || wizard.previewing)
            Button(wizard.plan == nil ? "下一步" : (wizard.finished ? "完成" : "开始同步")) {
                if wizard.plan == nil { wizard.preview() }
                else if wizard.finished { dismiss() }
                else { wizard.execute() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .keyboardShortcut(.defaultAction)
            .disabled(wizard.running || wizard.previewing || availableSources.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
