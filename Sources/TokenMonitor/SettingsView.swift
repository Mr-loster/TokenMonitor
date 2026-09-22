import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    @AppStorage("refreshIntervalMinutes") private var refreshInterval: Int = 5
    @AppStorage("menuBarShowsBalance") private var menuBarShowsBalance: Bool = true
    /// 菜单栏轮播间隔（秒），0 = 不轮播。默认 5 秒，和 `AppState.menuBarRotateSeconds` 保持一致。
    @AppStorage("menuBarRotateSeconds") private var menuBarRotateSeconds: Int = 5
    @AppStorage("defaultAlertThreshold") private var defaultThreshold: Double = 20
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    @LocalState private var confirmingClearCredentials = false
    /// 预警线用字符串暂存。
    /// 直接用 TextField(value:format:) 绑 Double 会有个坑：清空或只输了个小数点时解析失败，
    /// SwiftUI 会把文字弹回原值，表现为「改不动」。改成字符串暂存、只在能解析时写回。
    @LocalState private var thresholdText: String = ""

    /// 「固定显示」选择器的绑定。
    ///
    /// 不能直接绑 `state.menuBarPinnedProviderRaw`：用户选的那一家可能已经被停用或删掉，
    /// 这时存的值不在选项里，Picker 会显示成空白。所以 getter 里做一次兜底 ——
    /// 不在列表里就退到第一家，和菜单栏实际显示的那家保持一致。
    private var pinnedSelection: Binding<String> {
        Binding(
            get: {
                let available = state.menuBarProviders.map(\.rawValue)
                return available.contains(state.menuBarPinnedProviderRaw)
                    ? state.menuBarPinnedProviderRaw
                    : (available.first ?? "")
            },
            set: { raw in
                state.setMenuBarPinnedProvider(Provider(rawValue: raw))
            }
        )
    }

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
                Text("三家都是按「剩余百分比」计量的额度，刷新只是把数字更新一下，间隔短一点更及时。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("菜单栏") {
                Toggle("在菜单栏显示剩余百分比", isOn: $menuBarShowsBalance)
                    .font(.system(size: 12))
                Text("关闭后只显示状态图标，鼠标移上去仍可查看")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                HStack {
                    Text("轮播间隔")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $menuBarRotateSeconds) {
                        Text("不轮播").tag(0)
                        Text("3 秒").tag(3)
                        Text("5 秒").tag(5)
                        Text("10 秒").tag(10)
                        Text("30 秒").tag(30)
                    }
                    .labelsHidden()
                    .frame(width: 108)
                    .onChange(of: menuBarRotateSeconds) { _, _ in
                        state.restartRotationTimer()
                    }
                }

                // 不轮播时让用户自己指定显示哪一家。轮播中不显示这一行 ——
                // 那时「显示哪家」由定时器决定，摆个选择器在这儿只会让人以为选了就固定。
                if menuBarRotateSeconds == 0 && !state.menuBarProviders.isEmpty {
                    HStack {
                        Text("固定显示")
                            .font(.system(size: 12))
                        Spacer()
                        Picker("", selection: pinnedSelection) {
                            ForEach(state.menuBarProviders) { provider in
                                Text(provider.displayName).tag(provider.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 108)
                    }
                }

                Text("三家并排太长，菜单栏改成**轮流显示一家**，颜色跟着它自己的额度状态走。"
                     + "选「不轮播」时可以指定固定显示哪一家。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("预警") {
                HStack {
                    Text("新账号默认预警线")
                        .font(.system(size: 12))
                    Spacer()
                    TextField("20", text: $thresholdText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .onChange(of: thresholdText) { _, newValue in
                            // 只在能解析成非负数字时写回，中间态（空串、只有小数点）不打断输入
                            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                            if let value = Double(trimmed), value >= 0 {
                                defaultThreshold = value
                            }
                        }
                    Text("%")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("剩余百分比低于预警线时发送系统通知。只影响之后新建的账号，"
                     + "已有账号在「账号」页右键单独改。")
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
                        Text("粘贴的 token 存储")
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

                Text("Grok 和 Codex 的凭据默认**不经过这里** —— 直接读它们自己的 auth.json，"
                     + "由它们负责续期，本程序只读不写（唯一的例外是 Grok 的 access_token 过期时，"
                     + "会帮它续一次并写回 auth.json）。只有「粘贴 access_token」方式的账号才存在上面这个文件里。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("已不再使用系统钥匙串，所以不会再弹密码框。代价是：换机器或换主板后密钥对不上，"
                     + "需要重新填入；删掉这个文件也一样。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if !state.accountsNeedingKey.isEmpty {
                    Label("有 \(state.accountsNeedingKey.count) 个账号需要重新填入凭据，到「账号」页编辑即可",
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
                        Button("清空本地凭据") { confirmingClearCredentials = true }
                            .controlSize(.small)
                            .disabled(!state.accounts.contains { !$0.keySuffix.isEmpty })
                    }
                }
            }

            section("数据") {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("数据目录")
                            .font(.system(size: 12))
                        Text(AppPaths.displayPath)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }

                Text("只存账号列表、凭据和诊断日志。三家额度都是实时查询的，不落地。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("打开数据文件夹") {
                    NSWorkspace.shared.open(AppPaths.dataDirectory)
                }
                .controlSize(.small)
            }

            section("关于") {
                HStack {
                    Text("Token查询")
                        .font(.system(size: 12))
                    Spacer()
                    Text("v2.0")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text("监控 Grok、Codex、Gemini Pro 三家的额度余量。"
                     + "三家的接口都不是官方公开 API，改版后可能失效。"
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
