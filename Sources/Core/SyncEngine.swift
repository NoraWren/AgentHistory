import Foundation

struct SyncSummary {
    var insertedItems = 0
    var insertedThreads = 0
    var perSource: [String: Int] = [:]
    var errors: [String] = []
    var duration: TimeInterval = 0
    /// 另一个进程正在同步，本次没有真正执行。
    var skipped = false
}

final class SyncEngine {
    let store: Store

    init(store: Store) { self.store = store }

    /// 跨进程非阻塞排他锁：界面点同步、MCP 补同步可能同时发生，谁先拿到锁谁写。
    /// 返回 nil 表示别人正在同步，调用方按「已经很新了」处理即可。
    final class Lock {
        private let fd: Int32
        private init(fd: Int32) { self.fd = fd }

        static func acquire(store: Store) -> Lock? {
            let path = store.root + "/sync.lock"
            let fd = open(path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
            return Lock(fd: fd)
        }

        func release() { flock(fd, LOCK_UN); close(fd) }
    }

    @discardableResult
    func sync(kinds: [SourceKind]? = nil, progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> SyncSummary {
        let start = Date()
        var summary = SyncSummary()
        // 界面点同步和 MCP 补同步可能同时发生，先抢锁，抢不到就让对方写。
        guard let lock = Lock.acquire(store: store) else {
            summary.skipped = true
            summary.duration = Date().timeIntervalSince(start)
            return summary
        }
        defer { lock.release() }
        let adapters = AdapterFactory.all().filter { kinds == nil || kinds!.contains($0.kind) }
        let usable = adapters.filter { $0.isAvailable }

        for adapter in adapters {
            try store.registerSource(adapter.kind, available: adapter.isAvailable,
                                     error: adapter.unavailableReason)
        }
        guard !usable.isEmpty else {
            summary.errors.append("没有可用的数据来源")
            summary.duration = Date().timeIntervalSince(start)
            return summary
        }

        for (index, adapter) in usable.enumerated() {
            let base = Double(index) / Double(usable.count)
            let span = 1.0 / Double(usable.count)
            progress(base, "同步 \(adapter.kind.displayName)")
            let beforeThreads = try store.db.scalarInt("SELECT COUNT(*) FROM threads WHERE source_id=?", [adapter.kind.rawValue])
            do {
                let inserted = try adapter.sync(into: store) { phase in
                    let total = max(phase.total, 1)
                    let fraction = Double(phase.completed) / Double(total)
                    progress(base + span * min(max(fraction, 0), 1), phase.name)
                }
                summary.perSource[adapter.kind.displayName] = inserted
                summary.insertedItems += inserted
                try store.markSynced(adapter.kind)
            } catch {
                let message = "\(adapter.kind.displayName)：\(SyncEngine.describe(error))"
                summary.errors.append(message)
                try? store.markSourceError(adapter.kind, message)
            }
            let afterThreads = try store.db.scalarInt("SELECT COUNT(*) FROM threads WHERE source_id=?", [adapter.kind.rawValue])
            summary.insertedThreads += Int(afterThreads - beforeThreads)
            progress(base + span, "完成 \(adapter.kind.displayName)")
        }
        summary.duration = Date().timeIntervalSince(start)
        return summary
    }

    /// 来源库被别的进程锁住、只读打开失败时，把 sqlite 的原话翻成能看懂的一句。
    static func describe(_ error: Error) -> String {
        if let d = error as? DBError {
            if d.isLocked {
                return "来源库正被其他程序占用，先关掉对应客户端再同步（也可以直接跳过这个来源）"
            }
            if d.isUnreadable {
                return "来源库打不开，检查文件是否存在、当前账号是否有读权限"
            }
            return d.description
        }
        if let h = error as? HistoryError { return h.description }
        return (error as NSError).localizedDescription
    }
}
