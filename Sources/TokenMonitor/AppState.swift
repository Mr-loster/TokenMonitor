import Foundation
import SwiftUI

enum MenuBarStatus {
    case normal
    case warning
    case error
    case loading
}

@MainActor
final class AppState: ObservableObject {

    @Published var accounts: [APIAccount] = []
    @Published var balances: [UUID: AccountBalance] = [:]
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    @Published var selectedAccountID: UUID?
    /// 预览用的临时 Key，只在内存里，保存时才进本地凭据文件
    @Published var editingKeyDraft: String = ""
    /// 凭据缺失或解不开、需要用户重新填入的账号
    @Published var accountsNeedingKey: Set<UUID> = []

    private let accountStore = AccountStore()
    private let credentials = CredentialStore.shared
    private let service = BalanceService.shared
    private let snapshots = SnapshotStore.shared
    private var timer: Timer?

    init() {
        accounts = accountStore.load()
        seedLocalCodexIfNeeded()
        selectedAccountID = accounts.first?.id
        refreshAccountsNeedingKey()
        // 启动时留一条痕迹。「余额取不到」这类问题第一步就是看这里：
        // 账号数对不对、有几个凭据需要重填、密钥是绑机器的还是存文件的。
        DebugLog.write("启动 v1.10：账号 \(accounts.count) 个（DeepSeek \(deepseekAccounts.count) / Codex \(codexAccounts.count)），"
                       + "需重填凭据 \(accountsNeedingKey.count) 个，\(credentials.bindingDescription)")

        // 先刷一次让面板立刻有数据，再去做迁移。
        // 顺序反过来的话，用户在钥匙串授权框前多停一会儿，面板就一直空着。
        Task { @MainActor in
            await refreshAll()
            if await migrateLegacyCredentialsIfNeeded() {
                await refreshAll()      // 迁移到了新凭据，再刷一次
            }
        }
        restartTimer()
    }

    // MARK: - 首次运行自动导入本机 Codex

    /// 把本机的 `~/.codex/auth.json` 自动收进账号列表。
    ///
    /// 为什么自动做：这个功能的需求原话是「菜单栏现在没有显示 codex 的额度」。
    /// 本机已经登录过 Codex 的情况下，让用户先去点一次「添加账号」纯属多余 ——
    /// 直接导入，它立刻出现在账号列表和菜单栏里。
    ///
    /// 用 UserDefaults 标记位保证只做一次：用户删掉这个账号之后不会再自己冒出来。
    private func seedLocalCodexIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "codexAutoSeedDone") else { return }
        defaults.set(true, forKey: "codexAutoSeedDone")

        guard !accounts.contains(where: { $0.isCodex }) else { return }
        guard CodexAuthStore.hasDefaultCredential else {
            DebugLog.write("Codex 自动导入：本机没有可读的 auth.json，跳过")
            return
        }

        var account = APIAccount(
            name: "Codex（本机）",
            provider: .codex,
            alertThreshold: AppState.defaultCodexThreshold
        )
        account.codexCredentialKind = CodexCredentialKind.authFile.rawValue
        accounts.append(account)
        accountStore.save(accounts)
        DebugLog.write("Codex 自动导入：已把 ~/.codex/auth.json 加入账号列表")
    }

    /// Codex 账号的默认预警线（剩余百分比）
    static let defaultCodexThreshold: Double = 20

    // MARK: - 定时刷新

    var refreshIntervalMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: "refreshIntervalMinutes")
        return v > 0 ? v : 5
    }

    func restartTimer() {
        timer?.invalidate()
        let interval = TimeInterval(refreshIntervalMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAll() }
        }
    }

    // MARK: - 刷新

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }

        await withTaskGroup(of: Void.self) { group in
            for account in accounts where account.isEnabled {
                group.addTask { @MainActor in
                    await self.refresh(account)
                }
            }
        }
    }

    /// Codex 请求失败后的退避截止时间。
    ///
    /// chatgpt.com 不可达时（国内直连就是这种情况），每 5 分钟的自动刷新都会失败，
    /// debug.log 会被刷满、还白白发请求。失败后安静 15 分钟，手动刷新不受限制。
    private var codexBackoffUntil: [UUID: Date] = [:]
    private let codexBackoffInterval: TimeInterval = 15 * 60

    func refresh(_ account: APIAccount, force: Bool = false) async {
        switch account.provider {
        case .deepseek:
            await refreshDeepSeek(account)
        case .codex:
            await refreshCodex(account, force: force)
        }
    }

    private func refreshDeepSeek(_ account: APIAccount) async {
        let key: String
        switch credentials.lookup(for: account.id) {
        case .found(let value):
            key = value
        case .missing:
            balances[account.id] = AccountBalance(
                accountID: account.id,
                errorMessage: "未设置 API Key"
            )
            return
        case .undecryptable(let reason):
            balances[account.id] = AccountBalance(
                accountID: account.id,
                errorMessage: "凭据无法解密（\(reason)），请重新填入 API Key"
            )
            accountsNeedingKey.insert(account.id)
            return
        }

        do {
            let payload = try await service.fetchBalance(apiKey: key, provider: account.provider)
            guard let info = payload.balanceInfos.first(where: { $0.currency.uppercased() == "CNY" })
                    ?? payload.balanceInfos.first else {
                throw BalanceError.decoding
            }

            let balance = AccountBalance(
                accountID: account.id,
                totalBalance: Double(info.totalBalance) ?? 0,
                grantedBalance: Double(info.grantedBalance) ?? 0,
                toppedUpBalance: Double(info.toppedUpBalance) ?? 0,
                currency: info.currency,
                isAvailable: payload.isAvailable,
                updatedAt: Date(),
                successAt: Date(),
                errorMessage: nil
            )
            balances[account.id] = balance

            snapshots.append(BalanceSnapshot(
                accountID: account.id,
                timestamp: Date(),
                totalBalance: balance.totalBalance,
                grantedBalance: balance.grantedBalance,
                toppedUpBalance: balance.toppedUpBalance,
                currency: balance.currency
            ))

            AlertEngine.shared.evaluate(account: account, balance: balance)

        } catch {
            // 失败时保留上一次成功的金额，只把错误挂上去，界面会标成「数据已过期」
            var previous = balances[account.id] ?? AccountBalance(accountID: account.id)
            previous.errorMessage = error.localizedDescription
            previous.updatedAt = Date()
            balances[account.id] = previous
        }
    }

    /// Codex 额度。凭据两种来源：auth.json 路径（Codex 自己续期）或用户粘贴的 token。
    private func refreshCodex(_ account: APIAccount, force: Bool) async {
        if !force, let until = codexBackoffUntil[account.id], until > Date() {
            return
        }

        let credential: CodexCredential
        switch account.credentialKind {
        case .authFile:
            credential = .authFile(account.resolvedAuthURL)

        case .pastedToken:
            guard case .found(let token) = credentials.lookup(for: account.id), !token.isEmpty else {
                balances[account.id] = AccountBalance(
                    accountID: account.id,
                    errorMessage: "未设置 access_token"
                )
                accountsNeedingKey.insert(account.id)
                return
            }
            credential = .token(token, accountID: account.codexAccountID)
        }

        do {
            let usage = try await CodexUsageService.shared.fetch(credential: credential)
            let windows = [usage.primary, usage.secondary].compactMap { $0 }
            // 多窗口时取最紧张的那个作为账号级的「剩余」
            let remaining = windows.map(\.remainingPercent).min()

            let balance = AccountBalance(
                accountID: account.id,
                updatedAt: Date(),
                successAt: Date(),
                errorMessage: nil,
                remainingPercent: remaining ?? 0,
                isLimitReached: usage.limitReached,
                codexUsage: usage,
                codexError: nil
            )
            balances[account.id] = balance
            accountsNeedingKey.remove(account.id)
            codexBackoffUntil[account.id] = nil
            AlertEngine.shared.evaluate(account: account, balance: balance)

            DebugLog.write("Codex 额度「\(account.name)」：套餐=\(usage.planType ?? "?")，"
                           + "剩余=\(remaining.map { String(format: "%.0f%%", $0) } ?? "无")，"
                           + "熔断=\(usage.limitReached)")

        } catch {
            // 失败保留上次的数值，只把错误挂上去 —— 界面会显示「数据已过期」而不是清空
            var previous = balances[account.id] ?? AccountBalance(accountID: account.id)
            previous.errorMessage = error.localizedDescription
            previous.codexError = error as? CodexUsageError
            previous.updatedAt = Date()
            balances[account.id] = previous
            codexBackoffUntil[account.id] = Date().addingTimeInterval(codexBackoffInterval)
            DebugLog.write("Codex 额度「\(account.name)」读取失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 账号管理

    func addAccount(name: String,
                    provider: Provider,
                    apiKey: String,
                    threshold: Double,
                    codexAuthPath: String? = nil,
                    codexCredentialKind: CodexCredentialKind = .authFile,
                    codexAccountID: String? = nil) {
        var account = APIAccount(
            name: name.isEmpty ? provider.displayName : name,
            provider: provider,
            alertThreshold: threshold
        )
        account.codexAuthPath = codexAuthPath
        account.codexCredentialKind = codexCredentialKind.rawValue
        account.codexAccountID = codexAccountID
        // 凭据只有粘贴 token 时才存进加密文件；auth.json 模式的凭据由 Codex 自己维护
        if !apiKey.isEmpty { account.keySuffix = String(apiKey.suffix(4)) }

        accounts.append(account)
        accountStore.save(accounts)
        if !apiKey.isEmpty { credentials.setKey(apiKey, for: account.id) }
        accountsNeedingKey.remove(account.id)
        if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
        Task { await refresh(account, force: true) }
    }

    func updateAccount(_ account: APIAccount, newKey: String?) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        var updated = account
        if let newKey, !newKey.isEmpty {
            updated.keySuffix = String(newKey.suffix(4))
            credentials.setKey(newKey, for: account.id)
            accountsNeedingKey.remove(account.id)
        }
        accounts[index] = updated
        accountStore.save(accounts)
        Task { await refresh(updated, force: true) }
    }

    func deleteAccount(_ account: APIAccount) {
        accounts.removeAll { $0.id == account.id }
        balances[account.id] = nil
        credentials.removeKey(for: account.id)
        accountsNeedingKey.remove(account.id)
        codexBackoffUntil[account.id] = nil
        snapshots.removeAll(for: account.id)
        accountStore.save(accounts)
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
        }
    }

    /// 「添加 Codex 账号」用：把本机的 `~/.codex/auth.json` 加进来。
    /// 已经加过就不重复添加，返回 nil。
    @discardableResult
    func addLocalCodexAccount() -> APIAccount? {
        let target = CodexAuthStore.defaultAuthFileURL
        let already = accounts.contains {
            $0.isCodex && $0.credentialKind == .authFile && $0.resolvedAuthURL.path == target.path
        }
        guard !already else { return nil }

        var account = APIAccount(
            name: "Codex（本机）",
            provider: .codex,
            alertThreshold: AppState.defaultCodexThreshold
        )
        account.codexCredentialKind = CodexCredentialKind.authFile.rawValue
        accounts.append(account)
        accountStore.save(accounts)
        if selectedAccountID == nil { selectedAccountID = account.id }
        Task { await refresh(account, force: true) }
        return account
    }

    // MARK: - 凭据

    /// 这个账号是不是缺 Key（迁移没成功，或凭据文件被删/换机后解不开）
    func needsKey(_ account: APIAccount) -> Bool {
        accountsNeedingKey.contains(account.id)
    }

    /// 供编辑器「测试连接」用：取已保存的凭据，不改动任何状态
    func lookupCredential(_ id: UUID) -> CredentialLookup {
        credentials.lookup(for: id)
    }

    /// 删掉某个账号已保存的凭据（例如 Codex 账号从「粘贴 token」切成「读 auth.json」）
    func clearCredential(for id: UUID) {
        credentials.removeKey(for: id)
        accountsNeedingKey.remove(id)
    }

    /// 扫一遍凭据，找出需要用户重新填入 Key 的账号。
    /// 只标记「曾经有过 Key」的账号 —— 从没填过的走正常的新建流程，不用额外提示。
    private func refreshAccountsNeedingKey() {
        var needs: Set<UUID> = []
        for account in accounts where !account.keySuffix.isEmpty {
            if case .found = credentials.lookup(for: account.id) { continue }
            needs.insert(account.id)
        }
        accountsNeedingKey = needs
    }

    /// 一次性迁移：把钥匙串里的 Key 搬进本地加密文件。
    ///
    /// 读取钥匙串会弹一次系统授权框 —— 这是最后一次，之后不再用钥匙串。
    /// 用户取消或读取失败都不影响账号可用性，只是那个账号会被标成「需重新填入」。
    ///
    /// 返回值表示是否真的搬到了东西，调用方据此决定要不要重刷。
    @discardableResult
    private func migrateLegacyCredentialsIfNeeded() async -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "credentialMigrationDone") else { return false }
        defaults.set(true, forKey: "credentialMigrationDone")

        let candidates = accounts.filter { !$0.keySuffix.isEmpty }
        guard !candidates.isEmpty else {
            DebugLog.write("凭据迁移：没有需要迁移的账号，跳过")
            return false
        }

        // 先让菜单栏图标画出来再弹授权框，否则看起来像启动卡住了
        try? await Task.sleep(for: .seconds(1.2))
        DebugLog.write("凭据迁移：开始，候选账号 \(candidates.count) 个")

        let ids = candidates.map(\.id)
        // SecItemCopyMatching 会同步阻塞等用户授权，放后台线程做，别冻住界面
        let found = await Task.detached(priority: .utility) { () -> [UUID: String] in
            var result: [UUID: String] = [:]
            for id in ids {
                if let key = LegacyKeychain.read(for: id), !key.isEmpty {
                    result[id] = key
                }
            }
            return result
        }.value

        // 只清理确实写进新存储的那些，读失败的原样留着，避免误删唯一的副本
        var migratedIDs: [UUID] = []
        for (id, key) in found where credentials.setKey(key, for: id) {
            migratedIDs.append(id)
        }

        if !migratedIDs.isEmpty {
            await Task.detached(priority: .utility) {
                for id in migratedIDs { LegacyKeychain.delete(for: id) }
            }.value
        }

        if migratedIDs.isEmpty {
            DebugLog.write("凭据迁移：\(candidates.count) 个候选都没读到（未授权或钥匙串里已无条目），需手动重填")
        } else {
            DebugLog.write("凭据迁移：成功 \(migratedIDs.count)/\(candidates.count)，已清理对应钥匙串条目")
        }
        refreshAccountsNeedingKey()
        return !migratedIDs.isEmpty
    }

    /// 清空本地保存的全部 API Key（账号、预警线、历史都不动）
    func clearAllCredentials() {
        credentials.removeAll()
        for index in accounts.indices where !accounts[index].keySuffix.isEmpty {
            accountsNeedingKey.insert(accounts[index].id)
        }
        accountStore.save(accounts)
        DebugLog.write("凭据：已清空本地全部 API Key")
    }

    /// 设置页展示用：凭据文件的真实路径
    var credentialStorageLocation: String { credentials.storageLocation }

    /// 设置页展示用：密钥绑定方式
    var credentialBindingDescription: String { credentials.bindingDescription }

    // MARK: - 派生数据

    var selectedAccount: APIAccount? {
        guard let id = selectedAccountID else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }

    var selectedBalance: AccountBalance? {
        guard let account = selectedAccount else { return nil }
        return balances[account.id]
    }

    // MARK: - 按服务商分组

    var deepseekAccounts: [APIAccount] { accounts.filter { $0.provider == .deepseek } }
    var codexAccounts: [APIAccount] { accounts.filter { $0.provider == .codex } }

    /// 已启用的 DeepSeek 账号余额合计（同币种简单相加）
    var deepseekTotalBalance: Double {
        deepseekAccounts.filter(\.isEnabled).reduce(0) { partial, account in
            partial + (balances[account.id]?.totalBalance ?? 0)
        }
    }

    /// 兼容旧调用点：合计只统计 DeepSeek。
    /// Codex 是按百分比计量的，把 12.34 和 0% 相加没有任何意义。
    var totalBalanceAllAccounts: Double { deepseekTotalBalance }

    /// 已启用 Codex 账号里最低的剩余百分比 —— 最紧张的那个才是真正的约束
    var codexLowestRemaining: Double? {
        codexAccounts
            .filter(\.isEnabled)
            .compactMap { balances[$0.id]?.remainingPercent }
            .min()
    }

    var enabledAccounts: [APIAccount] {
        accounts.filter(\.isEnabled)
    }

    var hasAccounts: Bool { !accounts.isEmpty }

    /// 菜单栏展示的账号：优先选中的，否则第一个
    var menuBarBalance: AccountBalance? {
        guard let account = selectedAccount else { return nil }
        return balances[account.id]
    }

    /// 设置页里「新账号默认预警线」
    var defaultAlertThreshold: Double {
        let value = UserDefaults.standard.double(forKey: "defaultAlertThreshold")
        return value > 0 ? value : 10
    }

    // MARK: - 菜单栏

    /// 菜单栏状态取「最严重」的一方。
    /// 余额充足但 Codex 已经用完了，也该是黄的 —— 只取其中一方会漏报。
    func menuBarStatus(mode: MenuBarDisplayMode) -> MenuBarStatus {
        guard hasAccounts else { return .error }

        var candidates: [MenuBarStatus] = []
        if let status = deepseekMenuBarStatus(mode: mode) { candidates.append(status) }
        if let status = codexMenuBarStatus() { candidates.append(status) }

        guard !candidates.isEmpty else { return .loading }
        return candidates.max { severity($0) < severity($1) } ?? .loading
    }

    private func severity(_ status: MenuBarStatus) -> Int {
        switch status {
        case .normal:  return 0
        case .loading: return 1
        case .warning: return 2
        case .error:   return 3
        }
    }

    private func deepseekMenuBarStatus(mode: MenuBarDisplayMode) -> MenuBarStatus? {
        let enabled = deepseekAccounts.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }

        // `.current` 且选中的就是 DeepSeek 账号时看它自己，否则退回合计
        if mode == .current,
           let selected = selectedAccount, selected.provider == .deepseek {
            guard let balance = balances[selected.id] else { return .loading }
            if balance.errorMessage != nil { return .error }
            return balance.comparableValue <= selected.alertThreshold ? .warning : .normal
        }
        return deepseekTotalStatus(enabled: enabled)
    }

    private func deepseekTotalStatus(enabled: [APIAccount]) -> MenuBarStatus {
        let known = enabled.compactMap { balances[$0.id] }
        guard !known.isEmpty else { return .loading }
        // 只有全部账号都取不到数才算错误，个别失败不影响合计的参考价值
        if known.allSatisfy({ $0.errorMessage != nil }) { return .error }
        let thresholdSum = enabled.reduce(0) { $0 + $1.alertThreshold }
        return deepseekTotalBalance <= thresholdSum ? .warning : .normal
    }

    private func codexMenuBarStatus() -> MenuBarStatus? {
        let enabled = codexAccounts.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }

        let known = enabled.compactMap { balances[$0.id] }
        guard !known.isEmpty else { return .loading }

        // 取数失败就是红灯。菜单栏上 Codex 只显示一个数字，数据坏了那个数字就没有意义 ——
        // 这时候给黄灯会被误读成「额度低」。
        if known.contains(where: { $0.errorMessage != nil }) { return .error }

        for account in enabled {
            guard let balance = balances[account.id] else { continue }
            // 服务端熔断，或剩余低于预警线 → 黄灯
            if balance.isLimitReached { return .warning }
            if let percent = balance.remainingPercent, percent <= account.alertThreshold {
                return .warning
            }
        }
        return .normal
    }

    /// 菜单栏文本：各服务商并排，用 ` · ` 连接。
    /// DeepSeek 给金额，Codex 给最低剩余百分比（带 `CX` 前缀避免和金额混淆）。
    func menuBarText(mode: MenuBarDisplayMode) -> String {
        guard hasAccounts else { return "" }

        var parts: [String] = []
        if let money = deepseekMenuBarText(mode: mode) { parts.append(money) }
        if let codex = codexMenuBarText() { parts.append(codex) }

        return parts.isEmpty ? "…" : parts.joined(separator: " · ")
    }

    private func deepseekMenuBarText(mode: MenuBarDisplayMode) -> String? {
        let enabled = deepseekAccounts.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }

        if mode == .current,
           let selected = selectedAccount, selected.provider == .deepseek,
           let balance = balances[selected.id] {
            if balance.errorMessage != nil && !balance.hasValue { return "!" }
            return balance.currencySymbol + balance.formattedTotal
        }

        let known = enabled.compactMap { balances[$0.id] }
        guard !known.isEmpty else { return "…" }
        if known.allSatisfy({ $0.errorMessage != nil && !$0.hasValue }) { return "!" }
        return "¥" + formatMoney(deepseekTotalBalance)
    }

    private func codexMenuBarText() -> String? {
        let enabled = codexAccounts.filter(\.isEnabled)
        guard !enabled.isEmpty else { return nil }
        guard let lowest = codexLowestRemaining else { return "CX …" }
        return "CX \(Int(lowest.rounded()))%"
    }

    func menuBarSymbol(mode: MenuBarDisplayMode) -> String {
        guard hasAccounts else { return "dollarsign.circle" }
        switch menuBarStatus(mode: mode) {
        case .normal: return "dollarsign.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .loading: return "arrow.triangle.2.circlepath"
        }
    }

    // MARK: - 趋势

    func snapshots(for accountID: UUID) -> [BalanceSnapshot] {
        snapshots.snapshots(for: accountID)
    }

    func dailyCosts(for accountID: UUID, days: Int) -> [DailyCost] {
        TrendAnalyzer.dailyCosts(snapshots: snapshots.snapshots(for: accountID), days: days)
    }

    func todayCost(for accountID: UUID) -> Double {
        TrendAnalyzer.todayCost(snapshots: snapshots.snapshots(for: accountID))
    }

    /// 本月消耗。从今天往前推「今天是几号」天，起点正好落在本月 1 日，即自然月至今。
    func monthCost(for accountID: UUID) -> Double {
        let calendar = Calendar.current
        let dayOfMonth = calendar.component(.day, from: Date())
        return TrendAnalyzer.totalCost(snapshots: snapshots.snapshots(for: accountID), days: dayOfMonth)
    }

    func estimatedDaysRemaining(for accountID: UUID) -> Double? {
        // Codex 按百分比计量，没有「按消耗速度还能用几天」这回事
        guard accounts.first(where: { $0.id == accountID })?.provider == .deepseek else { return nil }
        guard let balance = balances[accountID] else { return nil }
        return TrendAnalyzer.estimatedDaysRemaining(
            balance: balance.totalBalance,
            snapshots: snapshots.snapshots(for: accountID)
        )
    }

    /// 清空某个账号的历史快照
    func clearHistory(for accountID: UUID) {
        snapshots.removeAll(for: accountID)
        objectWillChange.send()
    }

    /// 清空所有账号的历史快照
    func clearAllHistory() {
        snapshots.removeAll()
        objectWillChange.send()
    }

    /// 历史快照总条数，设置页展示用
    var snapshotCount: Int { snapshots.totalCount }

    // MARK: - Codex

    /// 取某个 Codex 账号的凭据摘要（套餐 / 过期时间），总览页展示用。
    /// 不缓存 —— 每次读盘很便宜，而且 auth.json 会被 Codex 随时更新。
    func codexAuthSummary(for account: APIAccount) -> CodexAuth? {
        switch account.credentialKind {
        case .authFile:
            return CodexAuthStore.load(from: account.resolvedAuthURL)
        case .pastedToken:
            guard case .found(let token) = credentials.lookup(for: account.id) else { return nil }
            return CodexAuthStore.resolve(.token(token, accountID: account.codexAccountID))
        }
    }
}
