import SwiftUI

struct AccountsView: View {
    @EnvironmentObject var state: AppState
    let onAdd: () -> Void
    let onEdit: (APIAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.accounts.isEmpty {
                EmptyHint(
                    icon: "key",
                    title: "还没有账号",
                    message: "可以添加 Grok、Codex 和 Gemini Pro 账号，\n每个账号独立显示额度与预警。",
                    actionTitle: "添加账号",
                    action: onAdd
                )
                importButtons
            } else {
                ForEach(state.accounts) { account in
                    row(account)
                }

                addButton
                importButtons
            }
        }
    }

    // MARK: - 添加

    private var addButton: some View {
        Button(action: onAdd) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("添加账号")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help("添加 Grok、Codex 或 Gemini Pro 账号")
    }

    /// 一键把本机已登录的服务加进来。已经加过的就不显示。
    @ViewBuilder
    private var importButtons: some View {
        let grokTarget = GrokAuthStore.defaultAuthFileURL
        let grokAdded = state.accounts.contains {
            $0.provider == .grok && $0.credentialKind == .authFile
                && $0.resolvedAuthURL.path == grokTarget.path
        }
        if !grokAdded, GrokAuthStore.hasDefaultCredential {
            importButton(icon: "bolt.horizontal.circle", title: "导入本机 Grok",
                         help: "把 ~/.grok/auth.json 作为一个 Grok 账号加入监控") {
                state.addLocalGrokAccount()
            }
        }

        let codexTarget = CodexAuthStore.defaultAuthFileURL
        let codexAdded = state.accounts.contains {
            $0.provider == .codex && $0.credentialKind == .authFile
                && $0.resolvedAuthURL.path == codexTarget.path
        }
        if !codexAdded, CodexAuthStore.hasDefaultCredential {
            importButton(icon: "arrow.down.doc", title: "导入本机 Codex",
                         help: "把 ~/.codex/auth.json 作为一个 Codex 账号加入监控") {
                state.addLocalCodexAccount()
            }
        }

        let geminiAdded = state.accounts.contains { $0.provider == .gemini }
        if !geminiAdded, state.geminiAvailable {
            importButton(icon: "sparkles", title: "导入本机 Gemini Pro",
                         help: "将本机 Antigravity 运行的 Gemini Pro 额度加入监控") {
                state.addLocalGeminiAccount()
            }
        }
    }

    private func importButton(icon: String,
                              title: String,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .help(help)
    }

    // MARK: - 账号行

    private func row(_ account: APIAccount) -> some View {
        let balance = state.balances[account.id]
        let isSelected = account.id == state.selectedAccountID

        return Button {
            state.selectedAccountID = account.id
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(statusColor(account: account, balance: balance))
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(account.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(account.provider.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                    Text(subtitle(for: account))
                        .font(.system(size: 10))
                        .foregroundStyle(state.needsKey(account) ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 6)

                if let balance, balance.hasValue {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int((balance.remainingPercent ?? 0).rounded()))%")
                            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                            // 刷新失败时保留上次数值，但压暗，避免被当成实时数据
                            .foregroundStyle(balance.isStale
                                             ? Color.secondary
                                             : QuotaStyle.tint(for: balance.remainingPercent ?? 0))
                        if balance.isLimitReached {
                            Text("已用完")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    Text("—")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.1)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑…") { onEdit(account) }
            Button(account.isEnabled ? "停用" : "启用") {
                var updated = account
                updated.isEnabled.toggle()
                state.updateAccount(updated, newKey: nil)
            }
            Divider()
            Button("删除", role: .destructive) { state.deleteAccount(account) }
        }
    }

    private func statusColor(account: APIAccount, balance: AccountBalance?) -> Color {
        guard account.isEnabled else { return Color.secondary.opacity(0.4) }
        guard let balance else { return .secondary }
        if balance.errorMessage != nil { return .red }
        return balance.comparableValue <= account.alertThreshold ? .orange : .green
    }

    /// 账号行副标题。缺凭据的时候要把「需重新填入」顶到最前面 ——
    /// 这时还显示「••••••••abcd」会让人以为凭据还在，白白浪费时间排查额度为什么取不到。
    private func subtitle(for account: APIAccount) -> String {
        var parts: [String] = []
        parts.append(state.needsKey(account) ? "需重新填入凭据" : account.credentialSummary)
        if !account.isEnabled { parts.append("已停用") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 添加 / 编辑账号（内联在面板里，不用 sheet）

/// 注意：这里刻意不是 sheet。
/// MenuBarExtra 的面板失去焦点就会自动收起，弹 sheet 会把面板的 key 状态夺走，
/// 结果是面板关掉、编辑器被孤立、输入框打不进字。内联显示没有这个问题。
///
/// 同理**不用 `NSOpenPanel` 选文件** —— 它同样会夺走 key 状态。
/// auth.json 的路径让用户直接粘贴，配一个「填入本机路径」的快捷按钮。
struct AccountEditorView: View {
    @EnvironmentObject var state: AppState

    let account: APIAccount?
    let onDone: () -> Void

    @LocalState private var name: String = ""
    @LocalState private var provider: Provider = .grok
    @LocalState private var apiKey: String = ""
    @LocalState private var threshold: String = "20"
    @LocalState private var enabled: Bool = true
    @LocalState private var test: TestState = .idle

    // Grok / Codex 共用
    @LocalState private var credentialKind: LocalCredentialKind = .authFile
    @LocalState private var authPath: String = ""
    @LocalState private var accountIDHint: String = ""

    /// 「测试连接」的结果
    enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    private var isEditing: Bool { account != nil }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedPath: String {
        authPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    onDone()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("返回账号列表")

                Text(isEditing ? "编辑账号" : "添加账号")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()
            }

            field("备注名称") {
                TextField(placeholderName, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            field("服务商") {
                Picker("", selection: $provider) {
                    ForEach(Provider.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: provider) { _, newValue in
                    test = .idle
                    // 新建时按服务商换一个合适的默认预警线
                    if !isEditing {
                        let fallback = state.defaultAlertThreshold
                        threshold = String(format: "%.0f", fallback)
                    }
                    _ = newValue
                }
            }

            if provider.usesAuthFile {
                localCredentialFields
            } else {
                geminiFields
            }

            HStack(spacing: 8) {
                Button("测试连接") { runTest() }
                    .controlSize(.small)
                    .disabled(!canTest || test == .running)
                testStatusLine
                Spacer(minLength: 0)
            }

            field("低额度预警线（\(provider.thresholdUnit)）") {
                TextField("20", text: $threshold)
                    .textFieldStyle(.roundedBorder)
            }

            if isEditing {
                Toggle("启用此账号", isOn: $enabled)
                    .font(.system(size: 12))
            }

            HStack {
                Text(credentialFooterHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("取消") { onDone() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "添加") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(.top, 2)
        }
        .onAppear(perform: prefill)
    }

    private var placeholderName: String {
        switch provider {
        case .grok:   return "例如：Grok 主力"
        case .codex:  return "例如：Codex 小号"
        case .gemini: return "例如：Gemini Pro 本机"
        }
    }

    private var credentialFooterHint: String {
        switch provider {
        case .grok:   return "凭据由 Grok CLI 自己维护"
        case .codex:  return "凭据由 Codex 自己维护"
        case .gemini: return "凭据由 Antigravity 自动提供"
        }
    }

    // MARK: - Grok / Codex 字段

    @ViewBuilder
    private var localCredentialFields: some View {
        field("凭据来源") {
            Picker("", selection: $credentialKind) {
                ForEach(LocalCredentialKind.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: credentialKind) { _, _ in
                test = .idle
            }
        }

        switch credentialKind {
        case .authFile:
            field("auth.json 路径") {
                VStack(alignment: .leading, spacing: 5) {
                    TextField(defaultAuthPlaceholder, text: $authPath)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 6) {
                        Button("填入本机路径") {
                            authPath = defaultAuthURL.path
                            test = .idle
                        }
                        .controlSize(.small)
                        Button("清空（用默认）") {
                            authPath = ""
                            test = .idle
                        }
                        .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                }
            }

            Text(authFileHelpText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

        case .pastedToken:
            field(isEditing ? "access_token（留空表示不修改）" : "access_token") {
                SecureField("粘一个 access_token", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            if provider == .codex {
                field("ChatGPT account id（可选）") {
                    TextField("可从 auth.json 的 tokens.account_id 复制", text: $accountIDHint)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text(pastedTokenWarning)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultAuthURL: URL {
        provider == .grok ? GrokAuthStore.defaultAuthFileURL : CodexAuthStore.defaultAuthFileURL
    }

    private var defaultAuthPlaceholder: String {
        provider == .grok ? "留空 = ~/.grok/auth.json" : "留空 = ~/.codex/auth.json"
    }

    private var authFileHelpText: String {
        switch provider {
        case .grok:
            return "推荐这种方式。Grok 的 access_token 只有 6 小时有效期，"
                + "用 auth.json 时本程序会在过期时自动帮它续期并写回，不用你管。"
        case .codex:
            return "要监控第二个 Codex 账号，先用另一个 CODEX_HOME 登录一次：\n"
                + "CODEX_HOME=~/.codex-work codex login\n"
                + "然后把 ~/.codex-work/auth.json 的路径填在上面。\n"
                + "这样 Codex 会自己续期，凭据长期有效。"
        default:
            return ""
        }
    }

    private var pastedTokenWarning: String {
        switch provider {
        case .grok:
            return "⚠️ Grok 的 access_token 只有约 6 小时有效期，而且粘贴方式**无法自动续期**。"
                + "除非只是临时用一下，否则建议改用 auth.json 方式。"
        default:
            return "⚠️ 粘贴的 token 有效期约 10 天。本程序刻意不自动续期"
                + "（refresh_token 是轮换的，写错会破坏你自己的 Codex 登录），"
                + "所以到期后需要重新粘一次。长期使用建议改用 auth.json 方式。"
        }
    }

    // MARK: - Gemini 字段

    @ViewBuilder
    private var geminiFields: some View {
        Text("Gemini Pro 额度通过本机运行的 Antigravity 语言服务器自动获取，"
             + "不需要手动输入 API Key。\n\n"
             + "请确保 Antigravity 桌面应用正在运行并已登录；"
             + "没有运行时会显示「未检测到 Antigravity」。")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 测试连接

    @ViewBuilder
    private var testStatusLine: some View {
        switch test {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在验证…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .success(let detail):
            Label(detail, systemImage: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - 状态

    /// 编辑态下留空表示「不改」，所以只有新建时才要求必填
    private var canSubmit: Bool {
        guard !isEditing else { return true }
        guard provider.usesAuthFile else { return true }
        return credentialKind == .authFile ? true : !trimmedKey.isEmpty
    }

    private var canTest: Bool {
        guard provider.usesAuthFile else { return true }
        return credentialKind == .authFile ? true : !trimmedKey.isEmpty
    }

    // MARK: - 动作

    private func prefill() {
        if let account {
            name = account.name
            provider = account.provider
            threshold = String(format: "%.0f", account.alertThreshold)
            enabled = account.isEnabled
            credentialKind = account.credentialKind
            authPath = account.authFilePath ?? ""
            accountIDHint = account.accountIDHint ?? ""
        } else {
            // 新账号的预警线取设置页里的默认值，而不是写死
            threshold = String(format: "%.0f", state.defaultAlertThreshold)
        }
        DebugLog.write("编辑器就绪：\(isEditing ? "编辑" : "新建")，服务商=\(provider.displayName)，预警线=\(threshold)")
    }

    private func runTest() {
        test = .running
        DebugLog.write("测试连接…服务商=\(provider.displayName)")

        switch provider {
        case .grok:
            let credential = currentGrokCredential()
            Task { @MainActor in
                do {
                    let usage = try await GrokUsageService.shared.fetch(credential: credential)
                    var detail = "连接正常"
                    if let remaining = usage.lowestRemaining {
                        detail += " · 剩余 \(Int(remaining.rounded()))%"
                    }
                    test = .success(detail)
                    DebugLog.write("测试连接成功：\(detail)")
                } catch let error as GrokError {
                    test = .failure(error.errorDescription ?? "读取失败")
                    DebugLog.write("测试连接失败：\(error.errorDescription ?? "未知")")
                } catch {
                    test = .failure(error.localizedDescription)
                }
            }

        case .codex:
            // 粘贴模式且编辑态留空时，用已保存的凭据去测
            var credential = currentCodexCredential()
            if case .token(let value, let hint) = credential, value.isEmpty {
                if let account, case .found(let saved) = state.lookupCredential(account.id) {
                    credential = .token(saved, accountID: hint ?? account.accountIDHint)
                }
            }
            Task { @MainActor in
                do {
                    let usage = try await CodexUsageService.shared.fetch(credential: credential)
                    let remaining = [usage.primary, usage.secondary]
                        .compactMap { $0?.remainingPercent }.min()
                    var detail = "连接正常"
                    if let plan = usage.planType { detail += " · \(plan)" }
                    if let remaining { detail += " · 剩余 \(Int(remaining.rounded()))%" }
                    test = .success(detail)
                    DebugLog.write("测试连接成功：\(detail)")
                } catch let error as CodexUsageError {
                    test = .failure(error.errorDescription ?? "读取失败")
                    DebugLog.write("测试连接失败：\(error.errorDescription ?? "未知")")
                } catch {
                    test = .failure(error.localizedDescription)
                }
            }

        case .gemini:
            Task { @MainActor in
                do {
                    let usage = try await GeminiProService.shared.fetch()
                    let remaining = [usage.primary, usage.secondary]
                        .compactMap { $0?.remainingPercent }.min()
                    var detail = "连接正常"
                    if let remaining { detail += " · 剩余 \(Int(remaining.rounded()))%" }
                    test = .success(detail)
                    DebugLog.write("测试连接成功：\(detail)")
                } catch {
                    test = .failure(error.localizedDescription)
                    DebugLog.write("测试连接失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 把界面上的选择拼成一次请求要用的凭据
    private func currentGrokCredential() -> GrokCredential {
        switch credentialKind {
        case .authFile:
            let url = trimmedPath.isEmpty
                ? GrokAuthStore.defaultAuthFileURL
                : URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            return .authFile(url)
        case .pastedToken:
            return .token(trimmedKey)
        }
    }

    private func currentCodexCredential() -> CodexCredential {
        switch credentialKind {
        case .authFile:
            let url = trimmedPath.isEmpty
                ? CodexAuthStore.defaultAuthFileURL
                : URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            return .authFile(url)
        case .pastedToken:
            return .token(trimmedKey, accountID: accountIDHint.isEmpty ? nil : accountIDHint)
        }
    }

    private func submit() {
        let value = Double(threshold) ?? state.defaultAlertThreshold
        DebugLog.write("提交账号：\(isEditing ? "编辑" : "新建")，服务商=\(provider.displayName)")

        if let account {
            var updated = account
            updated.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? account.name : name
            updated.provider = provider
            updated.alertThreshold = value
            updated.isEnabled = enabled
            if provider.usesAuthFile {
                updated.credentialKind = credentialKind
                updated.authFilePath = trimmedPath.isEmpty ? nil : trimmedPath
                updated.accountIDHint = accountIDHint.isEmpty ? nil : accountIDHint
                // 切到 auth.json 模式就把残留的 token 删掉，避免留一份用不上的密钥
                if credentialKind == .authFile {
                    state.clearCredential(for: account.id)
                    updated.keySuffix = ""
                    state.updateAccount(updated, newKey: nil)
                    onDone()
                    return
                }
            } else {
                updated.authFilePath = nil
                updated.accountIDHint = nil
                updated.keySuffix = ""
            }
            state.updateAccount(updated, newKey: trimmedKey.isEmpty ? nil : trimmedKey)
        } else {
            state.addAccount(
                name: name,
                provider: provider,
                apiKey: provider.usesAuthFile && credentialKind == .authFile ? "" : trimmedKey,
                threshold: value,
                authFilePath: trimmedPath.isEmpty ? nil : trimmedPath,
                credentialKind: credentialKind,
                accountIDHint: accountIDHint.isEmpty ? nil : accountIDHint
            )
        }
        onDone()
    }
}
