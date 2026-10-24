import Foundation

struct SyncSummary {
    var insertedItems = 0
    var insertedThreads = 0
    var perSource: [String: Int] = [:]
    var errors: [String] = []
    var duration: TimeInterval = 0
}

final class SyncEngine {
    let store: Store

    init(store: Store) { self.store = store }

    @discardableResult
    func sync(kinds: [SourceKind]? = nil, progress: @escaping (Double, String) -> Void = { _, _ in }) throws -> SyncSummary {
        let start = Date()
        var summary = SyncSummary()
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
                let message = "\(adapter.kind.displayName)：\(error)"
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
}
