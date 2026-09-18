import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @AppStorage("refreshIntervalMinutes") private var refreshInterval: Int = 5
    @AppStorage("menuBarShowsBalance") private var menuBarShowsBalance: Bool = true
    @AppStorage("menuBarDisplayMode") private var displayMode: MenuBarDisplayMode = .current
    @AppStorage("defaultAlertThreshold") private var defaultThreshold: Double = 10
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    @LocalState private var confirmingClearAll = false
    @LocalState private var confirmingClearCredentials = false
    /// 预警线用字符串暂存。
    /// 直接用 TextField(value:format:) 绑 Double 会有个坑：清空或只输了个小数点时解析失败，
    /// SwiftUI 会把文字弹回原值，表现为「改不动」。改成字符串暂存、只在能解析时写回。
    @LocalState private var thresholdText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            section("刷新") {
                HStack {
                    Text("自动刷新间隔")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $refreshInterval) {
                        Text("1 分钟").tag(1)
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("1 小时").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 108)
                    .onChange(of: refreshInterval) { _, _ in
                        state.restartTimer()
                    }
                }
                Text("间隔越短，消耗趋势越准，但请求也越频繁")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            section("菜单栏") {
                Toggle("在菜单栏显示余额数字", isOn: $menuBarShowsBalance)
                    .font(.system(size: 12))
                Text("关闭后只显示状态图标，鼠标移上去仍可查看")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if state.enabledAccounts.count > 1 {
                    Divider()
                    HStack {
                        Text("显示内容")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: $displayMode) {
                            ForEach(MenuBarDisplayMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 128)
                    }
                    Text("DeepSeek 看当前账号或合计金额；Codex 始终显示最低的剩余百分比，两者并排。状态色取更紧张的一方。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            section("预警") {
                HStack {
                    Text("新账号默认预警线")
                        .font(.system(size: 12))
                    Spacer()
                    TextField("10", text: $thresholdText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: thresholdText) { _, newValue in
                            // 只在能解析成非负数字时写回，中间态（空串、只有小数点）不打断输入
                            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                            if let value = Double(trimmed), value >= 0 {
                                defaultThreshold = value
                            }
                        }
                    Text("元")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("余额低于预警线时发送系统通知。只影响之后新建的 DeepSeek 账号，"
                     + "已有账号在「账号」页右键单独改。\nCodex 账号的预警线是「剩余百分比」，"
                     + "新建时默认 \(Int(AppState.defaultCodexThreshold))%。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("启动") {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .font(.system(size: 12))
                    .onChange(of: launchAtLogin) { _, newValue in
                        applyLaunchAtLogin(newValue)
                    }
                Text("未做开发者签名的 App 可能注册失败，失败不影响其他功能")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            section("凭据") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DeepSeek API Key 存储")
                            .font(.system(size: 12))
                        Text("\(state.credentialBindingDescription) · AES-GCM 加密")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(state.credentialStorageLocation)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                }

                Text("已不再使用系统钥匙串，所以不会再弹密码框。代价是：换机器或换主板后密钥对不上，需要重新填入 Key；删掉这个文件也一样。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Codex 账号的凭据不走这里 —— 默认直接读 Codex 自己的 auth.json，"
                     + "由 Codex 负责续期，本程序只读不写。只有「粘贴 access_token」方式的账号才存在上面这个文件里。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !state.accountsNeedingKey.isEmpty {
                    Label("有 \(state.accountsNeedingKey.count) 个账号需要重新填入 Key，到「账号」页编辑即可",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button("在 Finder 中显示") {
                        let url = URL(fileURLWithPath: state.credentialStorageLocation)
                        if FileManager.default.fileExists(atPath: url.path) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else {
                            NSWorkspace.shared.open(AppPaths.dataDirectory)
                        }
                    }
                    .controlSize(.small)

                    if confirmingClearCredentials {
                        Button("取消") { confirmingClearCredentials = false }
                            .controlSize(.small)
                        Button("确认清空") {
                            state.clearAllCredentials()
                            confirmingClearCredentials = false
                        }
                        .controlSize(.small)
                    } else {
                        Button("清空本地 Key") { confirmingClearCredentials = true }
                            .controlSize(.small)
                            .disabled(!state.accounts.contains { !$0.keySuffix.isEmpty })
                    }
                }
            }

            section("数据") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("快照存储位置")
                            .font(.system(size: 12))
                        Text("~/Library/Application Support/Token查询")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }

                Text("已记录 \(state.snapshotCount) 条快照，自动保留最近 90 天")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Button("打开数据文件夹") {
                        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                            in: .userDomainMask).first
                        if let url = base?.appendingPathComponent("Token查询") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)

                    Button("清空当前账号历史") {
                        if let account = state.selectedAccount {
                            state.clearHistory(for: account.id)
                        }
                    }
                    .controlSize(.small)
                    .disabled(state.selectedAccount == nil)
                }

                if confirmingClearAll {
                    HStack(spacing: 8) {
                        Text("确认清空全部账号的历史数据？")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                        Spacer(minLength: 4)
                        Button("取消") { confirmingClearAll = false }
                            .controlSize(.small)
                        Button("确认清空") {
                            state.clearAllHistory()
                            confirmingClearAll = false
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button("清空全部历史数据") { confirmingClearAll = true }
                        .controlSize(.small)
                        .disabled(state.snapshotCount == 0)
                }
            }

            section("关于") {
                HStack {
                    Text("Token查询")
                        .font(.system(size: 12))
                    Spacer()
                    Text("v1.10")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text("余额来自 DeepSeek 官方接口，消耗趋势由本机快照推算。"
                     + "Codex 额度来自 Codex 自己的后端接口（非官方公开 API）。"
                     + "所有数据只存在你的电脑上。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            thresholdText = String(format: "%.0f", defaultThreshold)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 未签名的 App 可能注册失败，忽略即可，不影响其他功能
        }
    }
}
