import AppKit
import SwiftUI
import Carbon.HIToolbox

func uiLog(_ message: String) {
    let path = "/tmp/agent-history-ui.log"
    let line = "\(Date()) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

final class AppModel: ObservableObject {
    let store: Store
    let engine: SyncEngine

    @Published var sources: [SourceInfo] = []
    @Published var projects: [ProjectRow] = []
    @Published var threads: [ThreadRow] = []
    /// 会话列表一页多大。早先写死 500 条，去重后本机是 759 个会话，
    /// 后 259 个永远不到列表里，也没有任何提示。
    static let threadPageSize = 200
    /// 当前列表是不是已经取到最后一个会话，用来决定要不要画「加载更多」。
    @Published var threadListExhausted = false
    /// 生效的筛选条件对应的会话总数，状态栏和「加载更多」都用它。
    @Published var threadListTotal = 0
    /// 菜单栏的「最近会话」用这一份：不受主窗口的来源/项目筛选影响，
    /// 否则在界面里筛了来源，菜单栏列的就不是真的最近。
    @Published var recentThreads: [ThreadRow] = []
    @Published var stats = Store.Stats()
    @Published var activity: [(day: String, count: Int)] = []
    @Published var selectedThreadId: String?
    @Published var items: [ItemRow] = []
    /// 当前会话的轮次表，用来做轮次跳转。
    @Published var turns: [Store.TurnRow] = []
    /// 视口里正在看的那一轮，表头显示「第几轮 / 共几轮」。
    @Published var currentTurn = 0
    @Published var searchText = ""
    @Published var searchHits: [SearchHit] = []
    /// 这一轮检索到底跑没跑过。用来区分「还没搜」和「搜了没有」，
    /// 后者不能退回会话列表——那看起来像搜索压根没生效。
    @Published var searchRan = false
    /// 检索范围。默认只看会话，和命令行、MCP 的默认一致。
    @Published var searchScope: SearchScope = .threads {
        didSet { if !searchText.isEmpty { runSearch() } }
    }
    /// 记忆命中的预览：文件还在就直接打开，不在就拿索引里的正文顶上。
    @Published var memoryPreview: MemoryDoc?
    @Published var showMemoryPreview = false
    @Published var showMemoryList = false
    // 记忆清单的状态。和别的页面一样放在 model 上，视图里不存状态：
    // 这套构建没有 SwiftUI 宏插件，@State 编译不过。
    @Published var memoryListKind: MemoryKind = .fact
    @Published var memoryListCategory = ""
    @Published var memoryListIncludeInactive = false
    @Published var memoryListDocs: [MemoryDoc] = []
    @Published var memoryListNote = ""
    @Published var filterSource: SourceKind?
    @Published var filterProject: String?
    @Published var mergeCopies = UserDefaults.standard.object(forKey: "mergeCopies") == nil
        ? true : UserDefaults.standard.bool(forKey: "mergeCopies")
    @Published var filterDays = 0
    @Published var onlyUser = false
    @Published var syncing = false
    @Published var progress: Double = 0
    @Published var phase = ""
    @Published var statusText = ""
    @Published var totals = (all: 0, merged: 0)
    @Published var showSync = false
    @Published var showStatus = false
    @Published var showOnboarding = false
    /// 接入面板的状态。菜单栏要读它，所以放在 model 上带着跑。
    let onboarding = MCPOnboardingModel()
    @Published var highlightItemId: String?
    /// 每次主动跳转都加一。只靠 highlightItemId 的话，连着点同一轮或者
    /// 重新进同一个命中，id 没变，SwiftUI 不会重新触发滚动。
    @Published var jumpToken = 0
    @Published var searchFocused = false
    @Published var jumpNotice: String?
    @Published var lastExport: ExportReport?
    // 主题汇编：条件都放在 model 上，界面只读它，避免在视图里用 SwiftUI 宏存状态。
    @Published var showDigest = false
    @Published var digestRunning = false
    @Published var digestPhase = ""
    @Published var digestResult: DigestResult?
    @Published var digestDays = 7
    @Published var digestSource: SourceKind?
    @Published var digestProject: String?
    @Published var digestUseLLM = true
    /// 默认吃缓存。勾掉就这一次强制重跑，用来确认某段结论是不是真的旧了。
    @Published var digestUseCache = true
    @Published var digestCommand = AppModel.savedDigestCommand()
    // 接口通路：不装任何命令行也能用。地址和模型名都填了才生效，否则走命令行。
    /// 填完就存，不必等到点「生成汇编」。地址和模型名放 UserDefaults，改一个字就落盘。
    /// 密钥不跟其他设置一起放 UserDefaults，那是个明文 plist。这里落库目录下的 0600 文件。
    @Published var digestAPIBase = LLMSettings.load().base {
        didSet { LLMSettings.saveBase(digestAPIBase) }
    }
    @Published var digestAPIModel = LLMSettings.load().model {
        didSet { LLMSettings.saveModel(digestAPIModel) }
    }
    @Published var digestAPIKey = LLMSettings.load().apiKey {
        didSet { LLMSettings.saveKey(digestAPIKey) }
    }
    @Published var digestDetected: [LLMDetector.Hit] = LLMDetector.detect()

    /// 老版本存下的是不带 --no-session-persistence 的 claude -p，
    /// 那种调用会在 ~/.claude 里留下会话、被同步成假对话，这里顺手换掉。
    private static func savedDigestCommand() -> String {
        let key = "digestCommand"
        guard let saved = UserDefaults.standard.string(forKey: key),
              !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LLMRunner.defaultCommand
        }
        // 旧版本把探测出的预设命令存了下来，那不是我填的，清掉重新按本机探测。
        if LLMDetector.isPresetCommand(saved) {
            UserDefaults.standard.removeObject(forKey: key)
            return LLMRunner.defaultCommand
        }
        let legacy = "claude -p"
        if saved.trimmingCharacters(in: .whitespaces) == legacy { return LLMRunner.defaultCommand }
        if saved.contains("claude") && !saved.contains("--no-session-persistence")
            && !saved.contains("--session-id") && !saved.contains("--resume") {
            let migrated = saved + " --no-session-persistence"
            UserDefaults.standard.set(migrated, forKey: key)
            return migrated
        }
        return saved
    }

    init(store: Store) {
        self.store = store
        self.engine = SyncEngine(store: store)
        if let raw = UserDefaults.standard.string(forKey: "filterSource") { filterSource = SourceKind(rawValue: raw) }
        filterProject = UserDefaults.standard.string(forKey: "filterProject")
        reload()
    }

    func reload() {
        UserDefaults.standard.set(filterSource?.rawValue, forKey: "filterSource")
        UserDefaults.standard.set(filterProject, forKey: "filterProject")
        UserDefaults.standard.set(mergeCopies, forKey: "mergeCopies")
        do {
            sources = try store.sources()
            projects = try store.projects()
            threads = try store.threads(sourceKind: filterSource, projectPath: filterProject,
                                        limit: AppModel.threadPageSize, mergeCopies: mergeCopies)
            threadListExhausted = threads.count < AppModel.threadPageSize
            threadListTotal = try store.threadCount(sourceKind: filterSource,
                                                    projectPath: filterProject,
                                                    mergeCopies: mergeCopies)
            recentThreads = try store.threads(limit: 5, mergeCopies: true)
            stats = try store.stats()
            activity = try store.dailyActivity(days: 30)
            totals = try store.threadTotals()
            statusText = mergeCopies && totals.merged < totals.all
                ? "\(totals.merged) 个会话（合并前 \(totals.all)） · \(stats.itemCount) 条记录"
                : "\(stats.threadCount) 个会话 · \(stats.itemCount) 条记录"
        } catch {
            statusText = "读取失败：\(error)"
        }
    }

    /// 列表滚到底时再取下一页。按 updated_at 游标接，不按 offset 数，
    /// 同步中途有新会话插进来也不会重复或漏掉。
    func loadMoreThreads() {
        guard !threadListExhausted, let last = threads.last else { return }
        do {
            let more = try store.threads(sourceKind: filterSource, projectPath: filterProject,
                                         limit: AppModel.threadPageSize, mergeCopies: mergeCopies,
                                         before: last.updatedAt, beforeId: last.id)
            if more.isEmpty {
                threadListExhausted = true
            } else {
                threads.append(contentsOf: more)
                if more.count < AppModel.threadPageSize { threadListExhausted = true }
            }
        } catch {
            statusText = "加载更多失败：\(error)"
        }
    }

    func select(_ thread: ThreadRow?) {
        selectedThreadId = thread?.id
        items = []
        turns = []
        currentTurn = 0
        highlightItemId = nil
        guard let id = thread?.id else { return }
        do {
            items = try store.items(threadId: id, limit: 200)
            turns = try store.turns(threadId: id)
            currentTurn = items.first?.turnOrdinal ?? 0
        } catch { statusText = "读取会话失败：\(error)" }
    }

    /// 跳到第 N 轮：按这一轮第一条记录的序号取一页，命中条目高亮。
    /// 长会话一次只载 200 条，直接改 offset 比一路 loadMore 快得多。
    func jumpToTurn(_ ordinal: Int) {
        guard let id = selectedThreadId,
              let turn = turns.first(where: { $0.ordinal == ordinal }),
              let first = try? store.firstItemOrdinal(turnId: turn.id) else {
            jumpNotice = "第 \(ordinal) 轮找不到记录"
            uiLog("jump 失败 turn=\(ordinal) turns=\(turns.count) thread=\(selectedThreadId ?? "nil")")
            return
        }
        do {
            let position = try store.itemPosition(threadId: id, ordinal: first, itemId: nil)
            // 前面多带三十条是为了有上下文，高亮仍落在这一轮的第一条。
            let page = try store.itemsPage(threadId: id, offset: max(0, (position ?? 0) - 30), limit: 400)
            items = page
            highlightItemId = page.first(where: { $0.ordinal >= first })?.id
            currentTurn = ordinal
            jumpNotice = nil
            jumpToken += 1
            uiLog("jump 第\(ordinal)轮 first=\(first) position=\(position ?? -1) 取到\(page.count)条 高亮=\(highlightItemId ?? "nil")")
        } catch {
            jumpNotice = "跳到第 \(ordinal) 轮失败：\(error)"
        }
    }

    func loadMore() {
        guard let id = selectedThreadId, let last = items.last else { return }
        do {
            let more = try store.items(threadId: id, afterOrdinal: last.ordinal, limit: 200)
            if !more.isEmpty { items.append(contentsOf: more) }
        } catch { statusText = "加载失败：\(error)" }
    }

    func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchHits = []; searchRan = false; return }
        var options = SearchOptions()
        options.sourceKind = filterSource
        options.projectPath = filterProject
        options.onlyUser = onlyUser
        options.scope = searchScope
        if filterDays > 0 {
            options.since = Int64(Date().timeIntervalSince1970) * 1000 - Int64(filterDays) * 86_400_000
        }
        do { searchHits = try store.search(q, options: options); searchRan = true }
        catch { statusText = "搜索失败：\(error)"; searchHits = []; searchRan = false }
    }

    /// 点开一条记忆命中。文件在就交给系统打开，文件没了就把索引里的正文拿出来看，
    /// 不能点了没反应——那和「搜到了却是空的」是一回事。
    func openMemoryHit(_ hit: SearchHit) {
        guard let id = hit.memoryId else { return }
        guard let doc = try? store.memoryDoc(id: id) else {
            jumpNotice = "这条记忆已经不在库里：\(id)"
            return
        }
        if !doc.path.isEmpty, FileManager.default.fileExists(atPath: doc.path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: doc.path))
            return
        }
        memoryPreview = doc
        showMemoryPreview = true
        if !doc.path.isEmpty {
            jumpNotice = "文件 \(doc.path) 已不在磁盘上，显示的是索引里的正文"
        }
    }

    func previewMemory(_ doc: MemoryDoc) {
        memoryPreview = doc
        showMemoryPreview = true
    }

    /// 作废一条结论。清单与检索结果一起失效，免得一边显示已作废、一边还能搜到。
    func voidFact(_ id: String) {
        do {
            _ = try store.voidFact(id: id)
            refreshMemoryList()
            if !searchText.isEmpty { runSearch() }
        } catch { statusText = "作废失败：\(error)" }
    }

    // MARK: - 记忆清单

    func refreshMemoryList() {
        do {
            switch memoryListKind {
            case .fact:
                memoryListDocs = try store.facts(category: memoryListCategory,
                                                 includeInactive: memoryListIncludeInactive)
            case .handoff:
                memoryListDocs = try store.handoffDocs()
            case .digest:
                memoryListDocs = try store.listMemory(kind: .digest, includeInactive: true,
                                                      limit: 300)
            }
            memoryListNote = memoryListKind == .fact && memoryListIncludeInactive
                ? "含已作废与已被取代的条目" : ""
        } catch {
            memoryListDocs = []
            memoryListNote = "读取失败：\(error)"
        }
    }

    func runSync() {
        guard !syncing else { return }
        syncing = true; progress = 0; phase = "准备"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let summary = try self.engine.sync { fraction, phase in
                    DispatchQueue.main.async {
                        self.progress = fraction
                        self.phase = phase
                    }
                }
                DispatchQueue.main.async {
                    self.syncing = false
                    self.progress = 1
                    self.phase = "完成"
                    var line = summary.skipped
                        ? "另一个进程刚同步过，这次跳过"
                        : "新增 \(summary.insertedItems) 条，耗时 \(String(format: "%.1f", summary.duration)) 秒"
                    // 某个来源失败时别的来源照常同步，失败原因在这里明说，别只报总数。
                    if !summary.errors.isEmpty {
                        line += "；\(summary.errors.count) 个来源出错：" + summary.errors.joined(separator: "；")
                    }
                    self.statusText = line
                    self.reload()
                    AppDelegate.shared?.refreshStatusMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.syncing = false
                    self.statusText = "同步失败：\(SyncEngine.describe(error))"
                    AppDelegate.shared?.refreshStatusMenu()
                }
            }
        }
    }

    func openThread(_ id: String) {
        if let t = threads.first(where: { $0.id == id }) { select(t) }
    }

    func openHit(_ hit: SearchHit) {
        jumpNotice = nil
        // 记忆类命中没有会话可跳，走另一条路。
        if hit.isMemory { openMemoryHit(hit); return }
        // 命中在代表会话上直接取；在副本上则先切到代表，避免误跳。
        let targetId = hit.threadId
        searchText = ""
        searchHits = []
        if threads.first(where: { $0.id == targetId }) == nil {
            reload()
        }
        let fallback = try? store.thread(id: targetId)
        if let t = threads.first(where: { $0.id == targetId }) ?? fallback {
            select(t)
        } else {
            jumpNotice = "会话已不存在：\(targetId)"
            return
        }
        // 按命中位置直接取页，替换过去的最多 20 页循环。
        if let position = try? store.itemPosition(threadId: targetId, ordinal: hit.ordinal,
                                                  itemId: hit.id.isEmpty ? nil : hit.id) {
            items = (try? store.itemsPage(threadId: targetId, offset: max(0, position - 100))) ?? items
            highlightItemId = items.first(where: { $0.ordinal == hit.ordinal })?.id
            currentTurn = items.first(where: { $0.ordinal == hit.ordinal })?.turnOrdinal ?? currentTurn
            jumpToken += 1
        } else {
            items = []
            loadMore()
            highlightItemId = items.first(where: { $0.ordinal == hit.ordinal })?.id
            jumpToken += 1
            if highlightItemId == nil {
                jumpNotice = "命中条目已不在库中，已打开会话开头"
            }
        }
    }

    func exportCurrent() {
        guard let id = selectedThreadId else { return }
        exportThreads([id])
    }

    func exportThreads(_ ids: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let report = Exporter.export(store: store, threadIds: ids, directory: url.path)
        lastExport = report
    }

    func exportSearchResults() {
        exportThreads(searchHits.map(\.targetThreadId))
    }

    func copyItem(_ item: ItemRow) {
        let text = ExportFormatter.renderItem(item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - 主题汇编

    func digestOptions() -> DigestOptions {
        var options = DigestOptions()
        options.since = Int64((Date().timeIntervalSince1970 - Double(max(1, digestDays)) * 86400) * 1000)
        options.sourceKind = digestSource
        options.projectPath = digestProject
        options.useLLM = digestUseLLM
        options.useCache = digestUseCache
        options.command = digestCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        // 这里不再兜底塞默认命令：用户把命令清空、又没填接口，就是明确表示不用模型，
        // 面板要照实说「没有可用的模型通路」，而不是偷偷拿一条他没填的命令去跑。
        // 开机时探测到的那条已经在 digestCommand 的初值里了。
        // 接口地址和模型名都填了才走接口，填一半不算数，免得空配置盖掉本来能跑的命令行。
        let api = LLMAPI(baseURL: digestAPIBase, model: digestAPIModel, apiKey: digestAPIKey)
        options.api = api.isEmpty ? nil : api
        // 只给一个来源或一个项目时，标题带上它，几次汇编不会混在同一个文件名里。
        var tags: [String] = []
        if let s = digestSource { tags.append(s.displayName) }
        if let p = digestProject { tags.append((p as NSString).lastPathComponent) }
        options.title = tags.isEmpty ? "主题汇编" : tags.joined(separator: "-")
        return options
    }

    func runDigest() {
        guard !digestRunning else { return }
        let options = digestOptions()
        // 自动探测出来的命令不写进配置：换一台机器时那条命令可能根本不存在，
        // 存下来会让面板带着一个跑不通的值。留空表示「下次开机重新探测」。
        UserDefaults.standard.set(LLMDetector.isPresetCommand(options.command) ? "" : options.command,
                                  forKey: "digestCommand")
        digestRunning = true
        digestPhase = "整理轮次"
        digestResult = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = DigestRunner.run(store: self.store, options: options) { phase in
                DispatchQueue.main.async { self.digestPhase = phase }
            }
            DispatchQueue.main.async {
                self.digestRunning = false
                self.digestPhase = ""
                self.digestResult = result
            }
        }
    }

    func copyDigest() {
        guard let result = digestResult, !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.markdown, forType: .string)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    static var keepAlive: AppDelegate?
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var model: AppModel?
    private var hotKeyRef: EventHotKeyRef?
    static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileHandle.standardError.write(Data("launched\n".utf8))
        AppDelegate.shared = self
        let store: Store
        do { store = try Store() }
        catch {
            let alert = NSAlert()
            alert.messageText = "无法打开历史库"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let model = AppModel(store: store)
        self.model = model
        if ProcessInfo.processInfo.environment["AGENT_HISTORY_AUTO_SYNC"] == "1" { model.showSync = true }
        // 验收用：直接把接入面板打开，省得每次手点。
        if ProcessInfo.processInfo.environment["AGENT_HISTORY_AUTO_ONBOARD"] == "1" { model.showOnboarding = true }
        if ProcessInfo.processInfo.environment["AGENT_HISTORY_AUTO_SELECT"] == "1", let first = model.threads.first {
            model.select(first)
        }
        if let q = ProcessInfo.processInfo.environment["AGENT_HISTORY_AUTO_SEARCH"], !q.isEmpty {
            model.searchText = q
            model.runSearch()
            if ProcessInfo.processInfo.environment["AGENT_HISTORY_AUTO_HIT"] == "1", let hit = model.searchHits.first {
                model.openHit(hit)
            }
        }
        // 性能验收用：指定会话 ID 直接打开，便于给大会话量首屏和滚动的耗时。
        if let id = ProcessInfo.processInfo.environment["AGENT_HISTORY_AUTO_THREAD"], !id.isEmpty {
            let started = Date()
            model.openThread(id)
            let loadMs = Date().timeIntervalSince(started) * 1000
            uiLog("thread=\(id) 条目=\(model.items.count) 取页 \(String(format: "%.1f", loadMs))ms")
            // 首屏画完再来一次：SwiftUI 第一次布局是异步的，紧跟取值量不出渲染耗时。
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                uiLog("thread=\(id) 首屏完成 累计 \(String(format: "%.1f", Date().timeIntervalSince(started) * 1000))ms")
            }
        }
        showWindow()
        FileHandle.standardError.write(Data("windows=\(NSApp.windows.count) frame=\(String(describing: window?.frame))\n".utf8))
        installStatusItem()
        registerHotKey()
        buildMenu()
        // 启动后先静默查一遍谁接上了，菜单栏那一行才有内容。查一次六个子进程，几秒钟内完成。
        model.onboarding.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            uiLog("check visible=\(String(describing: self.window?.isVisible)) frame=\(String(describing: self.window?.frame)) windows=\(NSApp.windows.count)")
        }
    }

    func showWindow() {
        guard let model else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Agent 记忆"
            w.minSize = NSSize(width: 900, height: 520)
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.contentView = NSHostingView(rootView: RootView(model: model))
            w.delegate = self
            let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
            let saved = UserDefaults.standard.string(forKey: "windowFrame")
            if let saved, !saved.isEmpty, NSRectFromString(saved).width > 600 {
                w.setFrame(NSRectFromString(saved), display: true)
            } else if let vf = primary?.visibleFrame {
                let width = min(1180, vf.width - 80)
                let height = min(760, vf.height - 60)
                w.setFrame(NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2,
                                  width: width, height: height), display: true)
            } else {
                w.center()
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
        }
        uiLog("showWindow frame=\(String(describing: window?.frame)) visible=\(String(describing: window?.isVisible))")
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 Agent 记忆", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "同步全部来源", action: #selector(syncAll), keyEquivalent: "r"))
        appMenu.addItem(NSMenuItem(title: "主题汇编…", action: #selector(openDigest), keyEquivalent: "d"))
        appMenu.addItem(NSMenuItem(title: "MCP 接入…", action: #selector(openOnboarding), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc func syncAll() { model?.runSync() }

    @objc func openDigest() {
        showWindow()
        model?.showDigest = true
    }

    @objc func openOnboarding() {
        showWindow()
        model?.showOnboarding = true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        FileHandle.standardError.write(Data("terminating\n".utf8))
        if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "windowFrame") }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "windowFrame") }
    }

    func windowDidResize(_ notification: Notification) {
        if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "windowFrame") }
    }

    func windowDidMove(_ notification: Notification) {
        if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "windowFrame") }
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "记忆"
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item
        refreshStatusMenu()
    }

    /// 规格要求点开菜单栏能看到今日新增、最近会话和同步状态。
    /// 每次弹菜单前重算一次，省得为了几个数字挂着定时器。
    func refreshStatusMenu() {
        guard let item = statusItem, let model else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false

        let todayLine = NSMenuItem(title: "今日新增 \(model.stats.todayItems) 条记录", action: nil, keyEquivalent: "")
        todayLine.isEnabled = false
        menu.addItem(todayLine)

        let dbLine = NSMenuItem(title: "库里 \(Self.bytes(model.store.dbSizeBytes())) · \(model.stats.threadCount) 个会话",
                                action: nil, keyEquivalent: "")
        dbLine.isEnabled = false
        menu.addItem(dbLine)

        let syncLine: String
        if model.syncing {
            syncLine = "正在同步 \(Int(model.progress * 100))%  \(model.phase)"
        } else {
            syncLine = Self.syncSummary(model.sources)
        }
        let syncItem = NSMenuItem(title: syncLine, action: nil, keyEquivalent: "")
        syncItem.isEnabled = false
        menu.addItem(syncItem)

        let failed = model.sources.filter { $0.available && $0.lastError != nil }
        if !failed.isEmpty {
            let bad = NSMenuItem(title: "\(failed.count) 个来源同步出错", action: nil, keyEquivalent: "")
            bad.isEnabled = false
            menu.addItem(bad)
        }

        // 接入结论只写一行。「没接上」是常态，别弹窗；只有本来能用却连不上才提示。
        let onboarding = model.onboarding
        if !onboarding.reports.isEmpty {
            let line = NSMenuItem(title: "MCP " + onboarding.summary, action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            let failures = onboarding.failures
            if !failures.isEmpty {
                let names = failures.prefix(2).map(\.displayName).joined(separator: "、")
                let bad = NSMenuItem(title: "\(names)\(failures.count > 2 ? " 等 \(failures.count) 个" : "") 已接入但连不上",
                                     action: #selector(openOnboarding), keyEquivalent: "")
                bad.target = self
                bad.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
                menu.addItem(bad)
            }
        }

        menu.addItem(.separator())
        let recentHeader = NSMenuItem(title: "最近会话", action: nil, keyEquivalent: "")
        recentHeader.isEnabled = false
        menu.addItem(recentHeader)
        let recent = model.recentThreads
        if recent.isEmpty {
            let empty = NSMenuItem(title: "还没有同步过会话", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for thread in recent {
            let title = thread.title.isEmpty ? "（无标题）" : thread.title
            let entry = NSMenuItem(title: Self.clip(title, 42),
                                   action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = thread.id
            entry.toolTip = "\(thread.sourceKind.displayName) · \(thread.projectPath)"
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开 Agent 记忆", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let sync = NSMenuItem(title: model.syncing ? "正在同步…" : "立即同步",
                              action: #selector(syncAll), keyEquivalent: "")
        sync.target = self
        sync.isEnabled = !model.syncing
        menu.addItem(sync)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu

        // 图标上直接标今日条数，不点开也能看到动静。
        item.button?.title = model.stats.todayItems > 0 ? "记忆 \(model.stats.todayItems)" : "记忆"
        item.button?.toolTip = Self.syncSummary(model.sources)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showWindow()
        if let thread = model?.threads.first(where: { $0.id == id }) {
            model?.select(thread)
        } else if let thread = try? model?.store.thread(id: id) {
            model?.select(thread)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 「同步」那一行：全部来源都新鲜就报最近一次，有一个落后就点名，
    /// 免得只看最新时间以为全都同步上了。
    private static func syncSummary(_ sources: [SourceInfo]) -> String {
        let available = sources.filter { $0.available }
        guard !available.isEmpty else { return "没有可同步的来源" }
        let now = Date().timeIntervalSince1970
        let ages = available.compactMap { MCPSyncPolicy.age($0, now: now) }
        guard !ages.isEmpty else { return "还没同步过" }
        let stale = available.filter { MCPSyncPolicy.isStale($0, now: now, threshold: 3600) }
        if stale.count == available.count, stale.count > 1 {
            return "所有来源都超过一小时没同步"
        }
        if !stale.isEmpty {
            let names = stale.prefix(2).map(\.kind.displayName).joined(separator: "、")
            return "\(names)\(stale.count > 2 ? " 等 \(stale.count) 个来源" : "")超过一小时没同步"
        }
        let latest = available.map(\.lastSyncAt).max() ?? 0
        return "上次同步 \(clockFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(latest))))"
    }

    private static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: value)
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem?.menu { refreshStatusMenu() }
    }

    @objc func openMain() {
        showWindow()
        NotificationCenter.default.post(name: .focusSearch, object: nil)
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            AppDelegate.shared?.openMain()
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x41474831), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(cmdKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

extension Notification.Name {
    static let focusSearch = Notification.Name("AgentHistoryFocusSearch")
}

func runUI() {
    FileHandle.standardError.write(Data("runUI start\n".utf8))
    let app = NSApplication.shared
    let delegate = AppDelegate()
    AppDelegate.keepAlive = delegate
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    FileHandle.standardError.write(Data("runUI running\n".utf8))
    app.run()
}
