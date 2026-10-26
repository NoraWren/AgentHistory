import SwiftUI
import AppKit

/// 主题汇编：选时间、来源、项目，交给外部模型提炼成一份按天排的汇编。
/// 这一页只读 AppModel 上的状态，条件改完点「生成」才真的取数。
struct DigestView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var availableSources: [SourceKind] {
        model.sources.filter { $0.available }.map(\.kind)
    }

    /// 项目列表直接用侧边栏那份，选出来的是路径，和检索口径一致。
    private var projects: [ProjectRow] { model.projects }

    /// 地址和模型名都填了才算配好接口。
    private var apiReady: Bool {
        !model.digestAPIBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.digestAPIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var routeLabel: String {
        if apiReady {
            return LLMAPI(baseURL: model.digestAPIBase, model: model.digestAPIModel).summary
        }
        return model.digestCommand
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 620, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("主题汇编").font(.system(size: 16, weight: .semibold))
                Text("把一段时间的对话压缩成结论，不搬原文。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
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
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("时间范围").font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach([3, 7, 14, 30], id: \.self) { days in
                            Button("\(days) 天") { model.digestDays = days }
                                .buttonStyle(.bordered)
                                .tint(model.digestDays == days ? Theme.accent : nil)
                                .controlSize(.small)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("来源").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.digestSource?.rawValue ?? "all" },
                        set: { model.digestSource = SourceKind(rawValue: $0) }
                    )) {
                        Text("全部来源").tag("all")
                        ForEach(availableSources, id: \.self) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("项目").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { model.digestProject ?? "" },
                        set: { model.digestProject = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("全部项目").tag("")
                        ForEach(projects.prefix(60)) { p in
                            Text(p.name).tag(p.path)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .controlSize(.small)
                }
                Spacer()
            }

            routeRow
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// 模型怎么走：本机命令行，或者不依赖任何 CLI 的接口。两条都在就画个说明，别让人猜哪条生效。
    private var routeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("接模型提炼", isOn: Binding(
                    get: { model.digestUseLLM },
                    set: { model.digestUseLLM = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                Toggle("复用上次结果", isOn: Binding(
                    get: { model.digestUseCache },
                    set: { model.digestUseCache = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .disabled(!model.digestUseLLM)
                .help("关掉就这一次强制重跑：材料没变也重新调模型，用来确认某段结论是不是真的旧了")
                TextField("命令", text: Binding(
                    get: { model.digestCommand },
                    set: { model.digestCommand = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 260)
                .disabled(!model.digestUseLLM || apiReady)
                .help("提示词走标准输入，汇编正文从标准输出读回")
                Button("探测本机") {
                    LLMDetector.reset()
                    model.digestDetected = LLMDetector.detect(force: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.digestUseLLM)
                .help("重新扫一遍本机装了哪些模型命令行")
                Spacer()
            }

            HStack(spacing: 6) {
                Text("接口") .font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("https://api.openai.com/v1", text: Binding(
                    get: { model.digestAPIBase },
                    set: { model.digestAPIBase = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 200)
                .disabled(!model.digestUseLLM)
                .help("OpenAI 兼容的 /chat/completions 地址，填到 /v1 即可；不填就只用上面的命令")
                TextField("模型名", text: Binding(
                    get: { model.digestAPIModel },
                    set: { model.digestAPIModel = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 140)
                .disabled(!model.digestUseLLM)
                SecureField("密钥（可留空，读环境变量）", text: Binding(
                    get: { model.digestAPIKey },
                    set: { model.digestAPIKey = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 180)
                .disabled(!model.digestUseLLM)
                .help("留空时依次读 AGENT_HISTORY_LLM_API_KEY、OPENAI_API_KEY")
                Spacer()
            }

            Text(routeHint)
                .font(.system(size: 9))
                .foregroundStyle(apiReady || hasCommand ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasCommand: Bool {
        !model.digestCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 现在到底会走哪条，以及这台机器上有什么可换。
    private var routeHint: String {
        let detected = model.digestDetected.map(\.preset.label)
        let found = detected.isEmpty ? "没探测到模型命令行" : "本机可用：" + detected.joined(separator: "、")
        if apiReady { return "走接口 \(routeLabel)，命令那一行不生效。" + found }
        if !hasCommand { return "没有命令也没有接口，只能出按天摘要。" + found }
        return "走命令 \(routeLabel)。" + found + "；填上接口地址和模型名可以改用接口"
    }

    private var content: some View {
        ScrollView {
            if let result = model.digestResult {
                if result.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(result.note.isEmpty ? "没有可汇编的对话" : result.note)
                            .font(.system(size: 11))
                        Text("换个时间范围，或者先同步一次。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Pill(text: result.usedLLM ? "模型提炼" : "按天摘要",
                                 color: result.usedLLM ? Theme.accent : .orange, filled: true)
                            Text(result.note).font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(result.markdown)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if model.digestRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.digestPhase.isEmpty ? "生成中" : model.digestPhase)
                        .font(.system(size: 11))
                    Text("模型提炼通常要几十秒").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("选好范围后点「生成汇编」。")
                    Text("会先按天把每轮的提问和答复整理成材料，再交给模型压成结论；模型跑不通时退回按天摘要，并说明原因。")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let result = model.digestResult, !result.isEmpty {
                Text("\(result.dayCount) 天 · \(result.threadCount) 个会话 · \(result.turnCount) 轮")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if !result.path.isEmpty {
                    Button("在访达中显示") {
                        NSWorkspace.shared.selectFile(result.path, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.link).font(.system(size: 10))
                }
                if result.cachedCalls > 0 {
                    Text("复用 \(result.cachedCalls) 段")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help("这一段材料跟上次一样，直接用上次的提炼结果，没再调模型")
                }
                Button("打开文件") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: result.path))
                }
                .buttonStyle(.link).font(.system(size: 10))
                .disabled(result.path.isEmpty)
            }
            Spacer()
            Button("复制") { model.copyDigest() }
                .disabled(model.digestResult?.isEmpty ?? true)
            Button {
                dismiss()
            } label: {
                Text("关闭")
            }
            Button(model.digestRunning ? "生成中…" : "生成汇编") { model.runDigest() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.digestRunning)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }
}

