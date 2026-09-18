import SwiftUI

/// 总览页：把**所有服务商**的额度并到一屏里。
///
/// 之前这里是「当前选中账号的详情」—— 选中的是 DeepSeek 就看不到 Codex，反之亦然。
/// 但「总览」的意义本来就是一眼看到全部，所以改成按服务商分区块并列，
/// 每个区块各带自己的「实时查询」按钮。
///
/// 「选中账号」现在只影响三处：菜单栏的「当前账号」模式、趋势页、
/// 以及有多个 DeepSeek 账号时总览展示哪一个。
struct OverviewView: View {
    @EnvironmentObject var state: AppState

    /// 正在查询的账号集合。
    ///
    /// 用集合而不是一个 Bool：总览里 DeepSeek 和 Codex 各有一个按钮，
    /// 共用一个状态会变成「点其中一个、另一个也跟着转」。
    @LocalState private var queryingIDs: Set<UUID> = []
    /// 转一圈的时长。查询快于这个时长时，也会把这一圈转完再停。
    private let spinPeriod: TimeInterval = 0.9

    private var enabledDeepseek: [APIAccount] { state.deepseekAccounts.filter(\.isEnabled) }
    private var enabledCodex: [APIAccount] { state.codexAccounts.filter(\.isEnabled) }

    var body: some View {
        Group {
            if state.accounts.isEmpty {
                EmptyHint(
                    icon: "plus.circle",
                    title: "还没有添加账号",
                    message: "到「账号」页添加一个 DeepSeek API Key 或 Codex 账号，\n就能开始监控额度了。"
                )
            } else if enabledDeepseek.isEmpty && enabledCodex.isEmpty {
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

    /// 总览 = 全部服务商并列，不再只显示「当前选中账号」。
    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let account = deepseekAccount {
                deepseekSection(account)
            }
            if !enabledCodex.isEmpty {
                codexSection
            } else if state.codexAccounts.isEmpty, CodexAuthStore.isInstalled {
                // 本机装了 Codex 但账号列表里没有 —— 给个一键导入的入口。
                // 这块原来是 Codex 页签里的空状态，页签去掉后挪到这里。
                codexImportSection
            }
        }
    }

    /// 总览里展示哪个 DeepSeek 账号：选中的那个优先，否则第一个已启用的。
    private var deepseekAccount: APIAccount? {
        if let selected = state.selectedAccount,
           selected.provider == .deepseek,
           selected.isEnabled {
            return selected
        }
        return enabledDeepseek.first
    }

    // MARK: - 区块标题

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

    // MARK: - DeepSeek（金额）

    @ViewBuilder
    private func deepseekSection(_ account: APIAccount) -> some View {
        let balance = state.balances[account.id]
        let todayCost = state.todayCost(for: account.id)
        let monthCost = state.monthCost(for: account.id)
        let daysLeft = state.estimatedDaysRemaining(for: account.id)

        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "DeepSeek 余额",
                // 只有一个 DeepSeek 账号时不必重复账号名 —— 面板顶部已经写了
                trailing: enabledDeepseek.count > 1 ? account.name : nil
            )

            if enabledDeepseek.count > 1 {
                deepseekTotalBlock
            }

            balanceBlock(balance, account: account)

            HStack(spacing: 8) {
                MetricCard(
                    label: "今日消耗",
                    value: "¥" + formatMoney(todayCost),
                    tint: todayCost > 0 ? .primary : .secondary
                )
                MetricCard(label: "本月消耗", value: "¥" + formatMoney(monthCost))
            }

            if let daysLeft, daysLeft < 999 {
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("按近 14 天消耗速度，余额大约还能用 \(String(format: "%.0f", daysLeft)) 天")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            miniTrend(account: account)
        }
    }

    private var deepseekTotalBlock: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DeepSeek 余额合计")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("¥" + formatMoney(state.deepseekTotalBalance))
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 6)
            Text("\(enabledDeepseek.count) 个账号")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Codex（百分比）

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "Codex 额度",
                trailing: enabledCodex.count > 1 ? "\(enabledCodex.count) 个账号" : nil
            )
            ForEach(enabledCodex) { account in
                codexAccountCard(account)
            }
            Text("Codex 非官方接口，改版后可能失效。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 本机装了 Codex、但账号列表里还没有它时显示的导入入口
    private var codexImportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Codex 额度")
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("检测到本机已登录 Codex")
                        .font(.system(size: 12, weight: .medium))
                    Text("导入之后额度会显示在这里和菜单栏。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button("导入") {
                    state.addLocalCodexAccount()
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    /// 单个 Codex 账号的紧凑卡片：名称 + 套餐徽章 + 剩余百分比 + 额度条 + 重置时间，
    /// 右上角是这个账号自己的「实时查询」按钮。
    private func codexAccountCard(_ account: APIAccount) -> some View {
        let balance = state.balances[account.id]
        let usage = balance?.codexUsage

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(account.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let plan = usage?.planType, !plan.isEmpty {
                    Text(planDisplayName(plan))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.14))
                        )
                }

                Spacer(minLength: 4)

                queryButton(for: account)
            }

            // 主指标：剩余百分比
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let balance, balance.hasValue, let percent = balance.remainingPercent {
                    Text("\(Int(percent.rounded()))%")
                        // 不用 design: .monospaced —— SF Mono 的数字 0 带斜杠，
                        // 「0%」会读成「Ø%」。monospacedDigit 一样对齐，没这个问题。
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                        .foregroundStyle(balance.isStale ? Color.secondary : CodexStyle.tint(for: percent))
                        .lineLimit(1)
                    Text("剩余")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if balance.isLimitReached {
                        Text("已用完")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.red)
                    }
                } else if balance?.errorMessage != nil {
                    Text("—")
                        .font(.system(size: 22, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                } else {
                    ProgressView().controlSize(.small)
                    Spacer(minLength: 4)
                }
            }

            if let balance, balance.hasValue, let percent = balance.remainingPercent {
                CodexProgressBar(remainingPercent: percent)
            }

            // 重置时间。带上窗口长度，否则「重置」没有时间尺度。
            if let usage, let hint = resetHint(usage) {
                Text(primaryWindowLabel(usage).map { "\($0) · \(hint)" } ?? hint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 第二个窗口：主指标只反映最紧张的那个，另一个得单独列出来
            if let secondary = usage?.secondary {
                detailRow(secondary.windowLabel,
                          trailing: "已用 \(Int(secondary.usedPercent.rounded()))%"
                                  + " · 剩余 \(Int(secondary.remainingPercent.rounded()))%")
            }

            // 额外额度。免费版通常没有，有值才显示。
            if let credits = usage?.credits, credits.unlimited || credits.hasCredits {
                detailRow("额外额度",
                          trailing: credits.unlimited
                              ? "不限量"
                              : (credits.balance.map { "$" + String(format: "%.2f", $0) } ?? "有可用额度"))
            }

            // 服务端熔断时说明「只能等重置」—— 免费版尤其需要这一句，
            // 否则用户会去界面里找根本不存在的「充值」入口。
            if balance?.isLimitReached == true, usage?.planType?.lowercased() == "free" {
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

            // 错误：有旧值就先标「已过期」，别让用户以为这是刚取到的数
            if let error = balance?.codexError {
                if balance?.hasValue == true {
                    warningLine(title: "额度可能已过期", detail: error.errorDescription ?? "")
                } else {
                    warningLine(title: error.errorDescription, detail: error.suggestion)
                }
            } else if let message = balance?.errorMessage, balance?.hasValue != true {
                warningLine(title: nil, detail: message)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    /// 「10月11日 11:41 重置（还有 26 天 20 小时）」
    private func resetHint(_ usage: CodexUsage?) -> String? {
        guard let usage else { return nil }
        let now = Date()
        let upcoming = [usage.primary, usage.secondary]
            .compactMap { $0?.resetsAt }
            .filter { $0 > now }
            .min()
        guard let next = upcoming else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        let parts = Calendar.current.dateComponents([.day, .hour], from: now, to: next)
        let days = parts.day ?? 0
        let hours = parts.hour ?? 0
        let left = days > 0 ? "还有 \(days) 天 \(hours) 小时" : "还有 \(hours) 小时"
        return "\(formatter.string(from: next)) 重置（\(left)）"
    }

    /// 主窗口的长度说明（如「30 天窗口」）。
    /// 接口偶尔不给窗口长度，这时 `windowLabel` 会退化成没有信息量的「额度窗口」，
    /// 那就不显示了。
    private func primaryWindowLabel(_ usage: CodexUsage) -> String? {
        guard let primary = usage.primary, primary.windowSeconds > 0 else { return nil }
        return primary.windowLabel
    }

    /// 一行「左标签 ——— 右说明」，用于多窗口 / 额外额度这类明细
    private func detailRow(_ label: String, trailing: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(trailing)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 额度大字

    @ViewBuilder
    private func balanceBlock(_ balance: AccountBalance?, account: APIAccount) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                if let balance, balance.hasValue {
                    Text(balance.displayValue)
                        // 用默认字体的等宽数字，而不是 design: .monospaced：
                        // 后者是 SF Mono，数字 0 带斜杠，30pt 下「0%」会读成「Ø%」。
                        .font(.system(size: 30, weight: .medium).monospacedDigit())
                        // 刷新失败时保留数值但压暗，和实时数据区分开
                        .foregroundStyle(balance.isStale ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else if balance?.errorMessage != nil {
                    Text("—")
                        .font(.system(size: 30, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }

                Spacer(minLength: 4)

                queryButton(for: account)
            }

            if let balance, balance.hasValue {
                Text("充值 ¥\(formatMoney(balance.toppedUpBalance)) · 赠送 ¥\(formatMoney(balance.grantedBalance))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if let balance, let error = balance.errorMessage {
                warningLine(title: nil, detail: error)
            } else {
                Text("正在获取…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if let balance, balance.hasValue, let error = balance.errorMessage {
                warningLine(title: "额度可能已过期", detail: error)
            }
        }
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
        .help(account.provider.isPercentBased
              ? "立即向 Codex 查询这个账号的额度"
              : "立即向 DeepSeek 查询这个账号的当前余额")
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
            // force: 绕过 Codex 的失败退避 —— 用户手点的就该真的发一次
            await state.refresh(account, force: true)

            // 查得太快也把这一圈转完再停，否则动画一闪而过，等于没有反馈
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < spinPeriod {
                try? await Task.sleep(for: .seconds(spinPeriod - elapsed))
            }
            queryingIDs.remove(account.id)
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
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 迷你趋势

    private func miniTrend(account: APIAccount) -> some View {
        let costs = state.dailyCosts(for: account.id, days: 7)
        let maxCost = max(costs.map(\.cost).max() ?? 0, 0.0001)

        return VStack(alignment: .leading, spacing: 6) {
            Text("近 7 天消耗")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: 5) {
                ForEach(costs) { item in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(item.cost > 0
                                  ? Color.accentColor.opacity(0.8)
                                  : Color.secondary.opacity(0.18))
                            .frame(height: max(3, 38 * item.cost / maxCost))
                        Text(shortWeekday(item.day))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 54, alignment: .bottom)
        }
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEEE"
        return formatter.string(from: date)
    }
}
