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
                    message: "可以添加 DeepSeek API Key 和 Codex 账号，\n每个账号独立显示额度与预警。",
                    actionTitle: "添加账号",
                    action: onAdd
                )
                importLocalCodexButton
            } else {
                ForEach(state.accounts) { account in
                    row(account)
                }

                addButton
                importLocalCodexButton
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
        .help("添加 DeepSeek API Key，或在编辑器里把服务商切换成 Codex")
    }

    /// 一键把本机的 Codex 登录加进来。
    /// 已经加过就不显示 —— 免得出现两个指向同一个 auth.json 的账号。
    @ViewBuilder
    private var importLocalCodexButton: some View {
        let target = CodexAuthStore.defaultAuthFileURL
        let alreadyAdded = state.accounts.contains {
            $0.isCodex && $0.credentialKind == .authFile && $0.resolvedAuthURL.path == target.path
        }

        if !alreadyAdded && CodexAuthStore.hasDefaultCredential {
            Button {
                state.addLocalCodexAccount()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text("导入本机 Codex")
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
            .help("把 ~/.codex/auth.json 作为一个 Codex 账号加入监控")
        }
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
                        if account.provider.isPercentBased {
                            Text("Codex")
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .foregroundStyle(.secondary)
                        }
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
                        Text(balance.displayValue)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            // 刷新失败时保留上次数值，但压暗，避免被当成实时数据
                            .foregroundStyle(balance.isStale ? Color.secondary : Color.primary)
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
    @LocalState private var provider: Provider = .deepseek
    @LocalState private var apiKey: String = ""
    @LocalState private var threshold: String = "10"
    @LocalState private var enabled: Bool = true
    @LocalState private var test: TestState = .idle

    // Codex 专用
    @LocalState private var credentialKind: CodexCredentialKind = .authFile
    @LocalState private var authPath: String = ""
    @LocalState private var codexAccountID: String = ""

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
                TextField(provider == .codex ? "例如：Codex 小号" : "例如：主力 Key", text: $name)
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
                    // 新建时按服务商换一个合适的默认预警线：DeepSeek 是元，Codex 是百分比
                    if !isEditing {
                        let fallback = newValue.isPercentBased
                            ? AppState.defaultCodexThreshold
                            : state.defaultAlertThreshold
                        threshold = String(format: "%.0f", fallback)
                    }
                }
            }

            if provider == .codex {
                codexFields
            } else {
                deepseekFields
            }

            HStack(spacing: 8) {
                Button("测试连接") { runTest() }
                    .controlSize(.small)
                    .disabled(!canTest || test == .running)
                testStatusLine
                Spacer(minLength: 0)
            }

            field("低额度预警线（\(provider.thresholdUnit)）") {
                TextField(provider == .codex ? "20" : "10", text: $threshold)
                    .textFieldStyle(.roundedBorder)
            }

            if isEditing {
                Toggle("启用此账号", isOn: $enabled)
                    .font(.system(size: 12))
            }

            HStack {
                Text(provider == .codex
                     ? "凭据由 Codex 自己维护"
                     : "Key 加密保存在本机数据目录")
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

    // MARK: - DeepSeek 字段

    @ViewBuilder
    private var deepseekFields: some View {
        field(isEditing ? "API Key（留空表示不修改）" : "API Key") {
            SecureField("sk-…", text: $apiKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Codex 字段

    @ViewBuilder
    private var codexFields: some View {
        field("凭据来源") {
            Picker("", selection: $credentialKind) {
                ForEach(CodexCredentialKind.allCases) { item in
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
                    TextField("留空 = ~/.codex/auth.json", text: $authPath)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 6) {
                        Button("填入本机路径") {
                            authPath = CodexAuthStore.defaultAuthFileURL.path
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

            Text("要监控第二个 Codex 账号，先用另一个 CODEX_HOME 登录一次：\n"
                 + "CODEX_HOME=~/.codex-work codex login\n"
                 + "然后把 ~/.codex-work/auth.json 的路径填在上面。\n"
                 + "这样 Codex 会自己续期，凭据长期有效。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

        case .pastedToken:
            field(isEditing ? "access_token（留空表示不修改）" : "access_token") {
                SecureField("粘一个 access_token", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            field("ChatGPT account id（可选）") {
                TextField("可从 auth.json 的 tokens.account_id 复制", text: $codexAccountID)
                    .textFieldStyle(.roundedBorder)
            }
            Text("⚠️ 粘贴的 token 有效期约 10 天。本程序刻意不自动续期"
                 + "（refresh_token 是轮换的，写错会破坏你自己的 Codex 登录），"
                 + "所以到期后需要重新粘一次。长期使用建议改用 auth.json 方式。")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        switch provider {
        case .deepseek: return !trimmedKey.isEmpty
        case .codex:
            return credentialKind == .authFile ? true : !trimmedKey.isEmpty
        }
    }

    private var canTest: Bool {
        switch provider {
        case .deepseek: return !trimmedKey.isEmpty
        case .codex:
            return credentialKind == .authFile ? true : !trimmedKey.isEmpty
        }
    }

    // MARK: - 动作

    private func prefill() {
        if let account {
            name = account.name
            provider = account.provider
            threshold = String(format: "%.0f", account.alertThreshold)
            enabled = account.isEnabled
            credentialKind = account.credentialKind
            authPath = account.codexAuthPath ?? ""
            codexAccountID = account.codexAccountID ?? ""
        } else {
            // 新账号的预警线取设置页里的默认值，而不是写死 10
            threshold = String(format: "%.0f", state.defaultAlertThreshold)
        }
        DebugLog.write("编辑器就绪：\(isEditing ? "编辑" : "新建")，服务商=\(provider.displayName)，预警线=\(threshold)")
    }

    /// 把界面上的选择拼成一次请求要用的凭据
    private func currentCredential() -> CodexCredential {
        switch credentialKind {
        case .authFile:
            let url = trimmedPath.isEmpty
                ? CodexAuthStore.defaultAuthFileURL
                : URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
            return .authFile(url)
        case .pastedToken:
            return .token(trimmedKey, accountID: codexAccountID.isEmpty ? nil : codexAccountID)
        }
    }

    private func runTest() {
        test = .running
        DebugLog.write("测试连接…服务商=\(provider.displayName)")

        switch provider {
        case .deepseek:
            let key = trimmedKey
            Task { @MainActor in
                if let error = await BalanceService.shared.validate(apiKey: key, provider: provider) {
                    test = .failure(error)
                    DebugLog.write("测试连接失败：\(error)")
                } else {
                    test = .success("连接正常，Key 可用")
                    DebugLog.write("测试连接成功")
                }
            }

        case .codex:
            // 粘贴模式且编辑态留空时，用已保存的凭据去测
            var credential = currentCredential()
            if case .token(let value, let accountID) = credential, value.isEmpty {
                if let existing = account, case .found(let saved) = state.lookupCredential(existing.id) {
                    credential = .token(saved, accountID: accountID ?? existing.codexAccountID)
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
            if provider == .codex {
                updated.codexCredentialKind = credentialKind.rawValue
                updated.codexAuthPath = trimmedPath.isEmpty ? nil : trimmedPath
                updated.codexAccountID = codexAccountID.isEmpty ? nil : codexAccountID
                // 切到 auth.json 模式就把残留的 token 删掉，避免留一份用不上的密钥
                if credentialKind == .authFile {
                    state.clearCredential(for: account.id)
                    updated.keySuffix = ""
                    state.updateAccount(updated, newKey: nil)
                    onDone()
                    return
                }
            }
            state.updateAccount(updated, newKey: trimmedKey.isEmpty ? nil : trimmedKey)
        } else {
            state.addAccount(
                name: name,
                provider: provider,
                apiKey: trimmedKey,
                threshold: value,
                codexAuthPath: trimmedPath.isEmpty ? nil : trimmedPath,
                codexCredentialKind: credentialKind,
                codexAccountID: codexAccountID.isEmpty ? nil : codexAccountID
            )
        }
        onDone()
    }
}
