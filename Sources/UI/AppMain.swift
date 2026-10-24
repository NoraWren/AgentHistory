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
    @Published var stats = Store.Stats()
    @Published var activity: [(day: String, count: Int)] = []
    @Published var selectedThreadId: String?
    @Published var items: [ItemRow] = []
    @Published var searchText = ""
    @Published var searchHits: [SearchHit] = []
    @Published var filterSource: SourceKind?
    @Published var filterProject: String?
    @Published var syncing = false
    @Published var progress: Double = 0
    @Published var phase = ""
    @Published var statusText = ""
    @Published var showSync = false
    @Published var showStatus = false
    @Published var highlightItemId: String?
    @Published var searchFocused = false

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
        do {
            sources = try store.sources()
            projects = try store.projects()
            threads = try store.threads(sourceKind: filterSource, projectPath: filterProject, limit: 500)
            stats = try store.stats()
            activity = try store.dailyActivity(days: 30)
            statusText = "\(stats.threadCount) 个会话 · \(stats.itemCount) 条记录"
        } catch {
            statusText = "读取失败：\(error)"
        }
    }

    func select(_ thread: ThreadRow?) {
        selectedThreadId = thread?.id
        items = []
        guard let id = thread?.id else { return }
        do { items = try store.items(threadId: id, limit: 200) }
        catch { statusText = "读取会话失败：\(error)" }
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
        guard !q.isEmpty else { searchHits = []; return }
        do { searchHits = try store.search(q, sourceKind: filterSource) }
        catch { statusText = "搜索失败：\(error)"; searchHits = [] }
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
                    self.statusText = "新增 \(summary.insertedItems) 条，耗时 \(String(format: "%.1f", summary.duration)) 秒"
                    self.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    self.syncing = false
                    self.statusText = "同步失败：\(error)"
                }
            }
        }
    }

    func openThread(_ id: String) {
        if let t = threads.first(where: { $0.id == id }) { select(t) }
    }

    func openHit(_ hit: SearchHit) {
        searchText = ""
        searchHits = []
        if let t = threads.first(where: { $0.id == hit.threadId }) {
            select(t)
        } else {
            reload()
            if let t = threads.first(where: { $0.id == hit.threadId }) { select(t) }
        }
        var guardCount = 0
        while !items.contains(where: { $0.ordinal == hit.ordinal }) && guardCount < 20 {
            let before = items.count
            loadMore()
            guardCount += 1
            if items.count == before { break }
        }
        highlightItemId = items.first(where: { $0.ordinal == hit.ordinal })?.id
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
        showWindow()
        FileHandle.standardError.write(Data("windows=\(NSApp.windows.count) frame=\(String(describing: window?.frame))\n".utf8))
        installStatusItem()
        registerHotKey()
        buildMenu()
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
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc func syncAll() { model?.runSync() }

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
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "打开 Agent 记忆", action: #selector(openMain), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "立即同步", action: #selector(syncAll), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        item.menu = menu
        statusItem = item
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
        var id = EventHotKeyID(signature: OSType(0x41474831), id: 1)
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
