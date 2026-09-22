import SwiftUI

/// 总览页：把**所有服务商**的额度并到一屏里。
///
/// 结构上刻意做成「按服务商分组、每组若干账号卡片」的通用形状 ——
/// 每张卡片里有多少个额度窗口就画多少个环形图，不为某一家写特例。
/// Grok 目前只有 1 个窗口（周），Codex / Gemini 通常有 2 个（5 小时 + 周）。
struct OverviewView: View {
    @EnvironmentObject var state: AppState

    /// 正在查询的账号集合。
    ///
    /// 用集合而不是一个 Bool：总览里每个账号各有一个按钮，
    /// 共用一个状态会变成「点其中一个、另一个也跟着转」。
    @LocalState private var queryingIDs: Set<UUID> = []
    /// 转一圈的时长。查询快于这个时长时，也会把这一圈转完再停。
    private let spinPeriod: TimeInterval = 0.9

    var body: some View {
        Group {
            if state.accounts.isEmpty {
                EmptyHint(
                    icon: "plus.circle",
                    title: "还没有添加账号",
                    message: "到「账号」页添加 Grok、Codex 或 Gemini Pro 账号，\n就能开始监控额度了。"
                )
            } else if state.enabledAccounts.isEmpty {
                EmptyHint(
                    icon: "pause.circle",
                    title: "账号都已停用",
                    message: "到「账号」页把要监控的账号重新启用，\n这里才会显示额度。"
                )
            } else {
                dashboard
            }
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Provider.allCases) { provider in
                providerSection(provider)
            }
            // 三家都是非官方接口，与其在每张卡片下面各说一遍，不如底部统一说一次
            if !state.enabledAccounts.isEmpty {
                Text("三家接口都不是官方公开 API，厂商改版后可能失效。数据只存在本机。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - 服务商分组

    @ViewBuilder
    private func providerSection(_ provider: Provider) -> some View {
        let enabled = state.enabledAccounts(of: provider)
        let anyAccount = state.accounts.contains { $0.provider == provider }

        if !enabled.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    "\(provider.displayName) 额度",
                    trailing: enabled.count > 1 ? "\(enabled.count) 个账号" : nil
                )
                ForEach(enabled) { account in
                    accountCard(account)
                }
            }
        } else if !anyAccount, let hint = importHint(for: provider) {
            importSection(provider: provider, hint: hint)
        }
    }

    /// 本机装了但还没加进账号列表时，给一个一键导入入口
    private func importHint(for provider: Provider) -> (title: String, detail: String, action: String)? {
        switch provider {
        case .grok:
            guard GrokAuthStore.hasDefaultCredential else { return nil }
            return ("检测到本机已登录 Grok CLI", "导入之后额度会显示在这里和菜单栏。", "导入")
        case .codex:
            guard CodexAuthStore.hasDefaultCredential else { return nil }
            return ("检测到本机已登录 Codex", "导入之后额度会显示在这里和菜单栏。", "导入")
        case .gemini:
            guard state.geminiAvailable else { return nil }
            return ("检测到本机正在运行 Antigravity", "添加后 Gemini Pro 额度会显示在这里和菜单栏。", "添加")
        }
    }

    private func importSection(provider: Provider,
                               hint: (title: String, detail: String, action: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("\(provider.displayName) 额度")
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hint.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(hint.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button(hint.action) { importLocal(provider) }
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private func importLocal(_ provider: Provider) {
        switch provider {
        case .grok:   state.addLocalGrokAccount()
        case .codex:  state.addLocalCodexAccount()
        case .gemini: state.addLocalGeminiAccount()
        }
    }

    // MARK: - 账号卡片

    private func accountCard(_ account: APIAccount) -> some View {
        let balance = state.balances[account.id]
        let windows = balance?.quotaWindows ?? []

        return VStack(alignment: .leading, spacing: 9) {
            headerRow(account: account, balance: balance)

            ringRow(account: account, balance: balance, windows: windows)

            if let balance, balance.hasValue {
                if balance.isLimitReached {
                    limitReachedLine(for: account)
                }
                details(for: account, balance: balance)
            }

            errorLine(balance: balance)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func headerRow(account: APIAccount, balance: AccountBalance?) -> some View {
        HStack(spacing: 6) {
            Text(account.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if let plan = planBadge(account: account, balance: balance) {
                Text(plan)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Color.secondary.opacity(0.14)))
            }

            Spacer(minLength: 4)

            queryButton(for: account)
        }
    }

    private func planBadge(account: APIAccount, balance: AccountBalance?) -> String? {
        guard account.provider == .codex,
              let plan = balance?.codexUsage?.planType, !plan.isEmpty else { return nil }
        return planDisplayName(plan)
    }

    /// 环形图那一行：有几个窗口画几个环，左对齐。
    @ViewBuilder
    private func ringRow(account: APIAccount,
                         balance: AccountBalance?,
                         windows: [QuotaWindow]) -> some View {
        if let balance, balance.hasValue, !windows.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                ForEach(windows) { window in
                    QuotaRing(
                        title: window.title,
                        remainingPercent: window.remainingPercent,
                        resetHint: QuotaFormat.resetHint(window.resetsAt),
                        isStale: balance.isStale,
                        isLimitReached: balance.isLimitReached && window.remainingPercent <= 0.5
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        } else {
            // 三种情况都退到占位环，别让卡片塌成一条线
            HStack(spacing: 10) {
                QuotaRingPlaceholder(title: placeholderTitle(balance))
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    /// 占位环上的文案要分清三种状态：还没查到 / 查询失败 / 查到了但接口一个窗口都没给。
    /// 都写成「正在获取」会让失败的那张卡片永远在转圈，看不出其实是报错了。
    private func placeholderTitle(_ balance: AccountBalance?) -> String {
        if balance?.hasValue == true { return "无窗口数据" }
        if balance?.errorMessage != nil { return "无数据" }
        return "正在获取"
    }

    /// 服务端明确熔断时的提示。必须给「什么时候恢复」，否则用户只能干等。
    private func limitReachedLine(for account: APIAccount) -> some View {
        let reset = state.balances[account.id]?.nextReset
        let text: String
        if let detail = QuotaFormat.resetDetail(reset) {
            text = "额度已用完，\(detail)后恢复。"
        } else {
            text = "额度已用完，等窗口重置后恢复。"
        }
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 各家的附加明细

    @ViewBuilder
    private func details(for account: APIAccount, balance: AccountBalance) -> some View {
        switch account.provider {
        case .grok:
            grokDetails(balance: balance)
        case .codex:
            codexDetails(account: account, balance: balance)
        case .gemini:
            EmptyView()
        }
    }

    /// Grok：周额度的产品拆分。
    /// 服务端只给数字 id，没有可读名字，所以能确定的才起名，其余显示成「分项 N」。
    @ViewBuilder
    private func grokDetails(balance: AccountBalance) -> some View {
        if let products = balance.grokUsage?.products, products.count > 1 {
            let text = products
                .map { "\($0.displayName) \(Int($0.usedPercent.rounded()))%" }
                .joined(separator: " · ")
            detailRow("额度分项", trailing: text)
        }
    }

    /// Codex：额外额度 + 凭据到期日
    @ViewBuilder
    private func codexDetails(account: APIAccount, balance: AccountBalance) -> some View {
        if let credits = balance.codexUsage?.credits, credits.unlimited || credits.hasCredits {
            detailRow("额外额度",
                      trailing: credits.unlimited
                          ? "不限量"
                          : (credits.balance.map { "$" + String(format: "%.2f", $0) } ?? "有可用额度"))
        }

        // 服务端熔断时说明「只能等重置」—— 免费版尤其需要这一句，
        // 否则用户会去界面里找根本不存在的「充值」入口。
        if balance.isLimitReached, balance.codexUsage?.planType?.lowercased() == "free" {
            Text("免费版没有额外额度可买，只能等重置。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        // 凭据到期：粘贴 token 的账号只有约 10 天有效期，这个日期是刚需
        if let expiry = state.codexAuthSummary(for: account)?.expiresAt {
            Text("登录凭据 \(expiry.formatted(date: .numeric, time: .omitted)) 到期")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    /// 一行「左标签 ——— 右说明」
    private func detailRow(_ label: String, trailing: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(trailing)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 错误行

    @ViewBuilder
    private func errorLine(balance: AccountBalance?) -> some View {
        if let balance, let error = balance.structuredError {
            if balance.hasValue {
                // 有旧值就先标「已过期」，别让用户以为这是刚取到的数
                warningLine(title: "额度可能已过期", detail: error.title)
            } else {
                warningLine(title: error.title, detail: error.suggestion ?? "")
            }
        } else if let message = balance?.errorMessage, balance?.hasValue != true {
            warningLine(title: nil, detail: message)
        }
    }

    private func warningLine(title: String?, detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                }
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 即时查询

    private func isQuerying(_ account: APIAccount) -> Bool {
        queryingIDs.contains(account.id)
    }

    /// 额度旁的按钮：只查当前这个账号，不等其他账号
    private func queryButton(for account: APIAccount) -> some View {
        let busy = isQuerying(account)

        return Button {
            runQuery(account)
        } label: {
            HStack(spacing: 4) {
                spinningIcon(busy: busy)
                Text(busy ? "查询中" : "实时查询")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(busy ? 0.06 : 0.14))
            )
            .foregroundStyle(busy ? Color.secondary : Color.accentColor)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("立即向 \(account.provider.displayName) 查询这个账号的额度")
    }

    /// 转圈图标。
    ///
    /// 不用 `rotationEffect` + `repeatForever`：那样在状态切回 false 时动画会被打断，
    /// 查询一快就只转到一半，看着像卡住了。改成按真实时间算角度，转多少完全由时间决定。
    @ViewBuilder
    private func spinningIcon(busy: Bool) -> some View {
        if busy {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(spinAngle(at: context.date)))
            }
        } else {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .semibold))
        }
    }

    /// 每 `spinPeriod` 秒转满一圈
    private func spinAngle(at date: Date) -> Double {
        let turns = date.timeIntervalSinceReferenceDate / spinPeriod
        return (turns - floor(turns)) * 360
    }

    private func runQuery(_ account: APIAccount) {
        guard !queryingIDs.contains(account.id) else { return }
        queryingIDs.insert(account.id)
        DebugLog.write("手动查询额度：\(account.name)")

        Task { @MainActor in
            let started = Date()
            // force: 绕过失败退避 —— 用户手点的就该真的发一次
            await state.refresh(account, force: true)

            // 查得太快也把这一圈转完再停，否则动画一闪而过，等于没有反馈
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < spinPeriod {
                try? await Task.sleep(for: .seconds(spinPeriod - elapsed))
            }
            queryingIDs.remove(account.id)
        }
    }

    // MARK: - 小组件

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }
}
