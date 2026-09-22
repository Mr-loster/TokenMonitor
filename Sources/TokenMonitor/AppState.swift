import Foundation
import SwiftUI

/// 菜单栏的状态档位。
///
/// 和环形图共用同一套配色口径（`QuotaStyle.tint`）：**≥50% 绿 / ≥20% 橙 / <20% 红**。
/// 之所以不是「有没有低于预警线」这种二值判断：面板里 Grok 37% 画的是橙环，
/// 菜单栏轮到 Grok 却显示绿色的话，同一个数字两处两个颜色，会被当成两个不同的东西。
/// 预警线（`alertThreshold`）只负责**发系统通知**，不再参与配色。
enum MenuBarStatus {
    /// ≥50%
    case normal
    /// 20% ~ 50%
    case warning
    /// <20%，或服务端已熔断
    case critical
    /// 取不到数（凭据失效、网络不通、对方应用没开）
    case error
    /// 还没查到（首次刷新中）
    case loading
}

@MainActor
final class AppState: ObservableObject {

    @Published var accounts: [APIAccount] = []
    @Published var balances: [UUID: AccountBalance] = [:]
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    /// 「账号」页里高亮的那一行。
    ///
    /// 面板顶部原来有个「选择当前账号」的下拉，总览页跟着它走；总览改成按服务商
    /// 一屏列出全部账号之后那个下拉就删了，所以这个值现在**只**用来在账号列表里做标记，
    /// 不再影响总览显示什么。
    @Published var selectedAccountID: UUID?
    /// 预览用的临时 Key，只在内存里，保存时才进本地凭据文件
    @Published var editingKeyDraft: String = ""
    /// 凭据缺失或解不开、需要用户重新填入的账号
    @Published var accountsNeedingKey: Set<UUID> = []
    /// 本机是否检测到 Antigravity。
    ///
    /// 之所以做成 @Published 的状态而不是让界面直接问 `AntigravityProbe.isRunning`：
    /// 探测要起 `ps` 子进程并同步等待，而 SwiftUI 的 body 每次重绘都会执行 ——
    /// 直接在 body 里探测等于每帧 fork 一个进程，面板会卡到没法用。
    @Published var geminiAvailable = false

    /// 菜单栏轮播到第几家（对启用中的服务商取模）。
    ///
    /// 三家并排写成 `GR 37% · CX 20% · GP 85%` 太长了，菜单栏那一格会被挤掉别的图标。
    /// 改成轮流显示一家，每家的颜色跟着**它自己**的额度状态走。
    @Published var menuBarRotation: Int = 0

    /// 不轮播时固定显示哪一家，存 `Provider.rawValue`；空串 = 用轮播顺序的第一家。
    ///
    /// 做成 `@Published` 而不是每次去读 UserDefaults：改了之后菜单栏要**立刻**换人，
    /// 而 `MenuBarLabel` 只监听 `@Published` 的变化，直接读 UserDefaults 它不会重绘。
    @Published var menuBarPinnedProviderRaw: String = ""

    private static let pinnedProviderKey = "menuBarPinnedProvider"

    private let accountStore = AccountStore()
    private let credentials = CredentialStore.shared
    private var timer: Timer?
    /// 菜单栏轮播的定时器，和刷新定时器分开 —— 两者周期不同（刷新按分钟，轮播按秒）
    private var rotationTimer: Timer?

    /// Grok 账号的默认预警线（剩余百分比）
    static let defaultThreshold: Double = 20

    init() {
        accounts = accountStore.load()
        menuBarPinnedProviderRaw = UserDefaults.standard.string(forKey: Self.pinnedProviderKey) ?? ""
        seedLocalAccountsIfNeeded()
        selectedAccountID = accounts.first?.id
        refreshAccountsNeedingKey()

        Task { @MainActor in
            // 探测 Antigravity 要起进程，放在这里而不是 init 里同步做，避免拖慢启动
            await refreshGeminiAvailability()
            seedLocalGeminiIfNeeded()
            logStartup()
            await refreshAll()
            if await migrateLegacyCredentialsIfNeeded() {
                await refreshAll()      // 迁移到了新凭据，再刷一次
            }
        }
        restartTimer()
        restartRotationTimer()
    }

    /// 启动时留一条痕迹。「额度取不到」这类问题第一步就是看这里：
    /// 账号数对不对、有几个凭据需要重填、密钥是绑机器的还是存文件的。
    private func logStartup() {
        DebugLog.write("启动 v2.0：账号 \(accounts.count) 个（Grok \(grokAccounts.count)"
                       + " / Codex \(codexAccounts.count) / Gemini \(geminiAccounts.count)），"
                       + "需重填凭据 \(accountsNeedingKey.count) 个，\(credentials.bindingDescription)")
    }

    /// 重新探测本机有没有 Antigravity。
    /// 结果只在真的变了的时候才写回，免得每次自动刷新都无谓地触发一轮界面重绘。
    func refreshGeminiAvailability() async {
        let available = await Task.detached(priority: .utility) {
            AntigravityProbe.isRunning
        }.value
        if geminiAvailable != available { geminiAvailable = available }
    }

    // MARK: - 首次运行自动导入本机服务

    /// 本机装了哪个 CLI 就自动把哪个收进账号列表。
    /// 只跑一次（UserDefaults 打标记），删掉之后不会再自己冒出来。
    private func seedLocalAccountsIfNeeded() {
        let defaults = UserDefaults.standard

        if !defaults.bool(forKey: "grokAutoSeedDone") {
            defaults.set(true, forKey: "grokAutoSeedDone")
            if !accounts.contains(where: { $0.provider == .grok }) {
                if GrokAuthStore.hasDefaultCredential {
                    var account = APIAccount(name: "Grok（本机）",
                                             provider: .grok,
                                             alertThreshold: Self.defaultThreshold)
                    account.credentialKind = .authFile
                    accounts.append(account)
                    accountStore.save(accounts)
                    DebugLog.write("Grok 自动导入：已把 ~/.grok/auth.json 加入账号列表")
                } else {
                    DebugLog.write("Grok 自动导入：本机没有可读的 auth.json，跳过")
                }
            }
        }

        if !defaults.bool(forKey: "codexAutoSeedDone") {
            defaults.set(true, forKey: "codexAutoSeedDone")
            if !accounts.contains(where: { $0.provider == .codex }) {
                if CodexAuthStore.hasDefaultCredential {
                    var account = APIAccount(name: "Codex（本机）",
                                             provider: .codex,
                                             alertThreshold: Self.defaultThreshold)
                    account.credentialKind = .authFile
                    accounts.append(account)
                    accountStore.save(accounts)
                    DebugLog.write("Codex 自动导入：已把 ~/.codex/auth.json 加入账号列表")
                } else {
                    DebugLog.write("Codex 自动导入：本机没有可读的 auth.json，跳过")
                }
            }
        }
    }

    /// 若本机运行着 Antigravity，自动把 Gemini Pro 加入账号列表
    private func seedLocalGeminiIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "geminiAutoSeedDone") else { return }

        guard !accounts.contains(where: { $0.provider == .gemini }) else {
            defaults.set(true, forKey: "geminiAutoSeedDone")
            return
        }
        guard geminiAvailable else {
            DebugLog.write("Gemini 自动导入：本机未检测到 Antigravity，跳过")
            return
        }

        defaults.set(true, forKey: "geminiAutoSeedDone")
        let account = APIAccount(name: "Gemini Pro",
                                 provider: .gemini,
                                 alertThreshold: Self.defaultThreshold)
        accounts.append(account)
        accountStore.save(accounts)
        DebugLog.write("Gemini 自动导入：已把 Gemini Pro 加入账号列表")
    }

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

    // MARK: - 菜单栏轮播

    /// 轮播间隔（秒）。0 = 不轮播，只显示最紧张的那一家。
    /// UserDefaults 里没有这个键时给 5 秒 —— `integer(forKey:)` 读不到键会返回 0，
    /// 那会跟「用户主动选了不轮播」混起来，所以要先判键在不在。
    var menuBarRotateSeconds: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "menuBarRotateSeconds") != nil else { return 5 }
        return defaults.integer(forKey: "menuBarRotateSeconds")
    }

    func restartRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        menuBarRotation = 0

        let seconds = menuBarRotateSeconds
        guard seconds > 0 else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds),
                                             repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advanceMenuBarRotation() }
        }
    }

    private func advanceMenuBarRotation() {
        // 只有一家（或一家都没启用）时没必要轮播，省掉无谓的重绘
        let count = menuBarProviders.count
        guard count > 1 else {
            if menuBarRotation != 0 { menuBarRotation = 0 }
            return
        }
        menuBarRotation = (menuBarRotation + 1) % count
    }

    // MARK: - 刷新

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = Date()
        }

        // 顺手更新一次 Antigravity 的存在性：用户可能是刷新的同时才把 Antigravity 打开，
        // 总览里的「导入本机 Gemini Pro」入口要跟着出现。
        await refreshGeminiAvailability()

        await withTaskGroup(of: Void.self) { group in
            for account in accounts where account.isEnabled {
                group.addTask { @MainActor in
                    await self.refresh(account)
                }
            }
        }
    }

    /// 请求失败后的退避截止时间。
    ///
    /// 服务端不可达时（国内直连 chatgpt.com / grok.com 就是这种情况），
    /// 每 5 分钟的自动刷新都会失败，debug.log 会被刷满、还白白发请求。
    /// 失败后安静 15 分钟，手动刷新不受限制。
    private var backoffUntil: [UUID: Date] = [:]
    private let backoffInterval: TimeInterval = 15 * 60

    func refresh(_ account: APIAccount, force: Bool = false) async {
        if !force, let until = backoffUntil[account.id], until > Date() { return }

        switch account.provider {
        case .grok:   await refreshGrok(account)
        case .codex:  await refreshCodex(account)
        case .gemini: await refreshGemini(account)
        }
    }

    /// 统一处理「拿到额度 → 写状态 → 评估预警」，三个服务商共用。
    private func applySuccess(_ account: APIAccount,
                              remaining: Double?,
                              limitReached: Bool,
                              grok: GrokUsage? = nil,
                              codex: CodexUsage? = nil,
                              gemini: GeminiProUsage? = nil) {
        let balance = AccountBalance(
            accountID: account.id,
            updatedAt: Date(),
            successAt: Date(),
            errorMessage: nil,
            remainingPercent: remaining ?? 0,
            isLimitReached: limitReached,
            grokUsage: grok,
            codexUsage: codex,
            geminiUsage: gemini
        )
        balances[account.id] = balance
        accountsNeedingKey.remove(account.id)
        backoffUntil[account.id] = nil
        AlertEngine.shared.evaluate(account: account, balance: balance)
    }

    /// 统一处理失败：保留上一次的值，只把错误挂上去 —— 界面会标成「数据已过期」。
    /// `treatAsTemporary` 为真时不退避（例如「对方应用没开」，用户随时可能打开）。
    private func applyFailure(_ account: APIAccount,
                              error: Error,
                              message: String,
                              temporary: Bool = false,
                              grokError: GrokError? = nil,
                              codexError: CodexUsageError? = nil,
                              geminiError: GeminiProError? = nil) {
        var previous = balances[account.id] ?? AccountBalance(accountID: account.id)
        previous.errorMessage = message
        previous.updatedAt = Date()
        if let grokError { previous.grokError = grokError }
        if let codexError { previous.codexError = codexError }
        if let geminiError { previous.geminiError = geminiError }
        balances[account.id] = previous

        backoffUntil[account.id] = temporary ? nil : Date().addingTimeInterval(backoffInterval)
        DebugLog.write("「\(account.name)」额度读取失败：\(message)")
    }

    /// 清掉上一次的结构化错误（成功时不能留着旧错误，否则界面会一直显示告警）
    private func clearErrors(_ id: UUID) {
        guard var balance = balances[id] else { return }
        balance.grokError = nil
        balance.codexError = nil
        balance.geminiError = nil
        balances[id] = balance
    }

    // MARK: - Grok

    private func refreshGrok(_ account: APIAccount) async {
        let credential: GrokCredential
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
            credential = .token(token)
        }

        do {
            let usage = try await GrokUsageService.shared.fetch(credential: credential)
            clearErrors(account.id)
            applySuccess(account,
                         remaining: usage.lowestRemaining,
                         limitReached: usage.limitReached,
                         grok: usage)
            DebugLog.write("Grok 额度「\(account.name)」："
                           + "剩余=\(usage.lowestRemaining.map { String(format: "%.0f%%", $0) } ?? "无")，"
                           + "窗口=\(usage.windows.map(\.windowLabel).joined(separator: " / "))")
        } catch {
            let grokError = error as? GrokError
            // 「对方应用没开 / 没登录」是最常见的临时状态，不退避 ——
            // 否则用户登录完还得干等 15 分钟才会再连一次。
            let temporary: Bool
            switch grokError {
            case .notInstalled, .notLoggedIn, .authFileMissing, .tokenExpired: temporary = true
            default: temporary = false
            }
            applyFailure(account,
                         error: error,
                         message: error.localizedDescription,
                         temporary: temporary,
                         grokError: grokError)
        }
    }

    // MARK: - Codex

    /// Codex 额度。凭据两种来源：auth.json 路径（Codex 自己续期）或用户粘贴的 token。
    private func refreshCodex(_ account: APIAccount) async {
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
            credential = .token(token, accountID: account.accountIDHint)
        }

        do {
            let usage = try await CodexUsageService.shared.fetch(credential: credential)
            let windows = [usage.primary, usage.secondary].compactMap { $0 }
            // 多窗口时取最紧张的那个作为账号级的「剩余」
            let remaining = windows.map(\.remainingPercent).min()
            clearErrors(account.id)
            applySuccess(account,
                         remaining: remaining,
                         limitReached: usage.limitReached,
                         codex: usage)
            DebugLog.write("Codex 额度「\(account.name)」：套餐=\(usage.planType ?? "?")，"
                           + "剩余=\(remaining.map { String(format: "%.0f%%", $0) } ?? "无")，"
                           + "熔断=\(usage.limitReached)")
        } catch {
            applyFailure(account,
                         error: error,
                         message: error.localizedDescription,
                         codexError: error as? CodexUsageError)
        }
    }

    // MARK: - Gemini Pro

    private func refreshGemini(_ account: APIAccount) async {
        do {
            let usage = try await GeminiProService.shared.fetch()
            let windows = [usage.primary, usage.secondary].compactMap { $0 }
            let remaining = windows.map(\.remainingPercent).min()
            clearErrors(account.id)
            applySuccess(account,
                         remaining: remaining,
                         limitReached: usage.limitReached,
                         gemini: usage)
            DebugLog.write("Gemini 额度「\(account.name)」："
                           + "剩余=\(remaining.map { String(format: "%.0f%%", $0) } ?? "无")，"
                           + "窗口=\(windows.map(\.windowLabel).joined(separator: " / "))，"
                           + "熔断=\(usage.limitReached)")
        } catch {
            // 「Antigravity 没开」是最常见的临时状态，用户随时可能把它打开。
            // 这种情况不退避 —— 否则要干等满 15 分钟才会再去连一次。
            let temporary: Bool
            if case .notRunning = (error as? GeminiProError) { temporary = true } else { temporary = false }
            applyFailure(account,
                         error: error,
                         message: error.localizedDescription,
                         temporary: temporary,
                         geminiError: error as? GeminiProError)
        }
    }

    // MARK: - 账号管理

    func addAccount(name: String,
                    provider: Provider,
                    apiKey: String,
                    threshold: Double,
                    authFilePath: String? = nil,
                    credentialKind: LocalCredentialKind = .authFile,
                    accountIDHint: String? = nil) {
        var account = APIAccount(
            name: name.isEmpty ? provider.displayName : name,
            provider: provider,
            alertThreshold: threshold
        )
        account.authFilePath = authFilePath
        account.credentialKind = credentialKind
        account.accountIDHint = accountIDHint
        // 凭据只有粘贴 token 时才存进加密文件；auth.json 模式的凭据由对方自己维护
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
        backoffUntil[account.id] = nil
        accountStore.save(accounts)
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
        }
    }

    /// 「导入本机 Grok」用：把 `~/.grok/auth.json` 加进来。已经加过就返回 nil。
    @discardableResult
    func addLocalGrokAccount() -> APIAccount? {
        let target = GrokAuthStore.defaultAuthFileURL
        let already = accounts.contains {
            $0.provider == .grok && $0.credentialKind == .authFile
                && $0.resolvedAuthURL.path == target.path
        }
        guard !already else { return nil }

        var account = APIAccount(name: "Grok（本机）",
                                 provider: .grok,
                                 alertThreshold: Self.defaultThreshold)
        account.credentialKind = .authFile
        accounts.append(account)
        accountStore.save(accounts)
        if selectedAccountID == nil { selectedAccountID = account.id }
        Task { await refresh(account, force: true) }
        return account
    }

    /// 「导入本机 Codex」用：把 `~/.codex/auth.json` 加进来。已经加过就返回 nil。
    @discardableResult
    func addLocalCodexAccount() -> APIAccount? {
        let target = CodexAuthStore.defaultAuthFileURL
        let already = accounts.contains {
            $0.provider == .codex && $0.credentialKind == .authFile
                && $0.resolvedAuthURL.path == target.path
        }
        guard !already else { return nil }

        var account = APIAccount(name: "Codex（本机）",
                                 provider: .codex,
                                 alertThreshold: Self.defaultThreshold)
        account.credentialKind = .authFile
        accounts.append(account)
        accountStore.save(accounts)
        if selectedAccountID == nil { selectedAccountID = account.id }
        Task { await refresh(account, force: true) }
        return account
    }

    /// 「导入本机 Gemini Pro」用：把本机 Antigravity 探测加进来。
    @discardableResult
    func addLocalGeminiAccount() -> APIAccount? {
        let already = accounts.contains { $0.provider == .gemini }
        guard !already else { return nil }

        let account = APIAccount(name: "Gemini Pro",
                                 provider: .gemini,
                                 alertThreshold: Self.defaultThreshold)
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

    /// 删掉某个账号已保存的凭据（例如从「粘贴 token」切成「读 auth.json」）
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

    /// 清空本地保存的全部 API Key（账号、预警线都不动）
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

    // MARK: - 按服务商分组

    var grokAccounts: [APIAccount] { accounts.filter { $0.provider == .grok } }
    var codexAccounts: [APIAccount] { accounts.filter { $0.provider == .codex } }
    var geminiAccounts: [APIAccount] { accounts.filter { $0.provider == .gemini } }

    func enabledAccounts(of provider: Provider) -> [APIAccount] {
        accounts.filter { $0.provider == provider && $0.isEnabled }
    }

    /// 某个服务商下所有已启用账号里最低的剩余百分比 —— 最紧张的那个才是真正的约束
    func lowestRemaining(of provider: Provider) -> Double? {
        enabledAccounts(of: provider)
            .compactMap { balances[$0.id]?.remainingPercent }
            .min()
    }

    var enabledAccounts: [APIAccount] {
        accounts.filter(\.isEnabled)
    }

    var hasAccounts: Bool { !accounts.isEmpty }

    /// 设置页里「新账号默认预警线」
    var defaultAlertThreshold: Double {
        let value = UserDefaults.standard.double(forKey: "defaultAlertThreshold")
        return value > 0 ? value : Self.defaultThreshold
    }

    // MARK: - Codex

    /// 取某个 Codex 账号的凭据摘要（套餐 / 过期时间），总览页展示用。
    /// 不缓存 —— 每次读盘很便宜，而且 auth.json 会被 Codex 随时更新。
    func codexAuthSummary(for account: APIAccount) -> CodexAuth? {
        switch account.credentialKind {
        case .authFile:
            return CodexAuthStore.load(from: account.resolvedAuthURL)
        case .pastedToken:
            guard case .found(let token) = credentials.lookup(for: account.id) else { return nil }
            return CodexAuthStore.resolve(.token(token, accountID: account.accountIDHint))
        }
    }

    // MARK: - 菜单栏

    /// 菜单栏要轮播的服务商（只含已启用的）。
    ///
    /// 顺序固定按 `Provider.allCases`，不跟着账号列表的增删走 ——
    /// 否则每次导入一个账号，轮播的先后顺序就变一遍，看着像在乱跳。
    var menuBarProviders: [Provider] {
        Provider.allCases.filter { !enabledAccounts(of: $0).isEmpty }
    }

    /// 不轮播时固定显示的那一家。没设过、或设的那家已经不在列表里 → nil。
    var menuBarPinnedProvider: Provider? {
        Provider(rawValue: menuBarPinnedProviderRaw)
    }

    /// 设置「不轮播时固定显示哪一家」。传 nil 表示回到轮播顺序的第一家。
    func setMenuBarPinnedProvider(_ provider: Provider?) {
        let value = provider?.rawValue ?? ""
        guard value != menuBarPinnedProviderRaw else { return }
        menuBarPinnedProviderRaw = value
        UserDefaults.standard.set(value, forKey: Self.pinnedProviderKey)
        DebugLog.write("菜单栏：固定显示 \(provider?.displayName ?? "（未指定，用第一家）")")
    }

    /// 当前轮到的那一家。一家都没启用时返回 nil。
    var currentMenuBarProvider: Provider? {
        let providers = menuBarProviders
        guard !providers.isEmpty else { return nil }

        // 不轮播：听用户选的那一家。选的那家被停用/删掉了就退回第一家 ——
        // 不能因为一个失效的选择让菜单栏整块变空。
        if menuBarRotateSeconds <= 0 {
            if let pinned = menuBarPinnedProvider, providers.contains(pinned) { return pinned }
            return providers[0]
        }

        // 轮播：取模而不是直接索引 —— 账号被删掉之后 `menuBarRotation` 可能已经越界，
        // 取模能让它在下一个 tick 之前也落在合法范围里。
        return providers[menuBarRotation % providers.count]
    }

    /// 某一家的菜单栏状态。配色口径和环形图完全一致，见 `MenuBarStatus` 的注释。
    ///
    /// 数据取不到就是红灯：菜单栏上每家只显示一个数字，数据坏了那个数字就没有意义 ——
    /// 这时候给橙色会被误读成「额度偏低」。
    func menuBarStatus(for provider: Provider) -> MenuBarStatus {
        let enabled = enabledAccounts(of: provider)
        guard !enabled.isEmpty else { return .loading }

        let known = enabled.compactMap { balances[$0.id] }
        guard !known.isEmpty else { return .loading }

        if known.contains(where: { $0.errorMessage != nil }) { return .error }
        if known.contains(where: { $0.isLimitReached }) { return .critical }

        guard let lowest = lowestRemaining(of: provider) else { return .loading }
        // 和 QuotaStyle.tint 同一套分档：≥50 绿 / ≥20 橙 / <20 红
        if lowest < 20 { return .critical }
        if lowest < 50 { return .warning }
        return .normal
    }

    /// 菜单栏当前显示的那一家的状态（无参版本给 `MenuBarLabel` 用）。
    func menuBarStatus() -> MenuBarStatus {
        guard hasAccounts else { return .error }
        guard let provider = currentMenuBarProvider else { return .loading }
        return menuBarStatus(for: provider)
    }

    /// 某一家的菜单栏文本，形如 `GR 37%`。
    /// 同一家可能有多个账号，取最短的那个剩余百分比。
    func menuBarText(for provider: Provider) -> String {
        guard !enabledAccounts(of: provider).isEmpty else { return "" }
        guard let lowest = lowestRemaining(of: provider) else {
            return "\(provider.menuBarPrefix) …"
        }
        return "\(provider.menuBarPrefix) \(Int(lowest.rounded()))%"
    }

    /// 菜单栏当前显示的那一家的文本。
    ///
    /// 只显示一家（而不是三家并排）是刻意的：`GR 37% · CX 20% · GP 85%` 太长了，
    /// 菜单栏那一格会把旁边的图标挤掉。轮流显示，颜色跟着**它自己**的额度状态走。
    func menuBarText() -> String {
        guard let provider = currentMenuBarProvider else {
            return hasAccounts ? "…" : ""
        }
        return menuBarText(for: provider)
    }

    func menuBarSymbol(for provider: Provider) -> String {
        Self.symbol(for: menuBarStatus(for: provider))
    }

    func menuBarSymbol() -> String {
        guard hasAccounts else { return "gauge.medium" }
        return Self.symbol(for: menuBarStatus())
    }

    /// 状态 → 图标。形状表达「哪一类问题」，颜色表达「多严重」：
    /// 仪表盘 = 正常，三角 = 额度偏低，八角 = 快用完，圆圈 = 取不到数，箭头 = 还在查。
    private static func symbol(for status: MenuBarStatus) -> String {
        switch status {
        case .normal:   return "gauge.medium"
        case .warning:  return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .error:    return "exclamationmark.circle.fill"
        case .loading:  return "arrow.triangle.2.circlepath"
        }
    }
}
