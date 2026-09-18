import Foundation

/// 余额快照的本地持久化。
/// DeepSeek 没有公开的用量接口，所以消耗趋势靠这里记录的快照做差值推算。
///
/// 内部按账号分组存放，组内保持时间升序：
/// - 查询某个账号的快照是 O(1)，不再每次渲染都对全部数据做 filter + sort
/// - 超出保留期的数据自动裁掉，文件不会无限膨胀
/// - 写盘做节流，避免每次刷新都全量序列化一遍
final class SnapshotStore {
    static let shared = SnapshotStore()

    private let fileURL: URL
    private var byAccount: [UUID: [BalanceSnapshot]] = [:]
    private var dirty = false
    private var lastPersist = Date.distantPast

    /// 只保留最近这么多天
    private let retentionDays = 90
    /// 两次落盘的最小间隔
    private let persistInterval: TimeInterval = 60

    private init() {
        fileURL = AppPaths.file("snapshots.json")
        load()
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let flat = (try? makeDecoder().decode([BalanceSnapshot].self, from: data)) ?? []
        byAccount = Dictionary(grouping: flat, by: \.accountID)
            .mapValues { $0.sorted { $0.timestamp < $1.timestamp } }
        prune()
    }

    /// 强制落盘。退出前调用一次，兜住被节流跳过的写入。
    func flush() {
        guard dirty else { return }
        persist()
    }

    private func persist() {
        let flat = byAccount.values.flatMap { $0 }.sorted { $0.timestamp < $1.timestamp }
        guard let data = try? makeEncoder().encode(flat) else { return }
        AppPaths.write(data, to: fileURL)
        dirty = false
        lastPersist = Date()
    }

    private func persistIfDue() {
        guard dirty else { return }
        guard Date().timeIntervalSince(lastPersist) >= persistInterval else { return }
        persist()
    }

    /// 裁掉保留期之外的数据
    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) else { return }
        for (id, list) in byAccount {
            let kept = list.drop { $0.timestamp < cutoff }
            if kept.count != list.count {
                byAccount[id] = Array(kept)
                dirty = true
            }
        }
    }

    // MARK: - 对外

    func append(_ snapshot: BalanceSnapshot) {
        byAccount[snapshot.accountID, default: []].append(snapshot)
        dirty = true
        prune()
        persistIfDue()
    }

    /// 某个账号的全部快照，按时间升序
    func snapshots(for accountID: UUID) -> [BalanceSnapshot] {
        byAccount[accountID] ?? []
    }

    func latest(for accountID: UUID) -> BalanceSnapshot? {
        byAccount[accountID]?.last
    }

    /// 全部账号的快照总数，设置页展示用
    var totalCount: Int {
        byAccount.values.reduce(0) { $0 + $1.count }
    }

    func removeAll(for accountID: UUID) {
        byAccount[accountID] = nil
        dirty = true
        persist()
    }

    /// 清空所有账号的历史数据
    func removeAll() {
        byAccount.removeAll()
        dirty = true
        persist()
    }

    /// 数据文件位置，设置页里给用户看
    var storageLocation: String { fileURL.path }
}
