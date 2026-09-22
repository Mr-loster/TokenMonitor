import SwiftUI

/// 面板内容区当前显示什么。
///
/// 账号编辑器刻意不做成 sheet：MenuBarExtra 的面板一旦失去焦点就会自动收起，
/// 而弹出 sheet 会夺走面板的 key 状态 —— 面板关掉，编辑器被孤立，输入框就打不进字。
/// 所以编辑器直接内联在面板里。宽度也才塞得下（面板 322，内容区 294）。
enum PanelRoute: Equatable {
    case tabs
    case newAccount
    case editAccount(APIAccount)
}

struct PanelView: View {
    @EnvironmentObject var state: AppState
    @LocalState private var tab: Tab = .overview
    @LocalState private var route: PanelRoute = .tabs

    /// 供离屏预览指定初始页签；正常运行时用默认值
    init(initialTab: Tab = .overview) {
        _tab = LocalState(wrappedValue: initialTab)
    }

    /// 原来的「趋势」页签已经去掉了 —— 它存在的唯一理由是给 DeepSeek 的金额画消耗曲线，
    /// 而现在三个服务商都是按百分比计量的额度，接口不提供用量明细，画不出曲线。
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "总览"
        case accounts = "账号"
        case settings = "设置"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if route == .tabs {
                tabBar
                Divider()
            }
            contentScroll
            Divider()
            footer
        }
        .frame(width: 322)
        .onAppear {
            DebugLog.write("面板打开，当前页签=\(tab.rawValue)")
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            // 这里原来是个「选择当前账号」的下拉菜单。总览页现在按服务商分组、
            // 一屏把**所有**账号的额度都列出来，下拉已经没有任何东西可切了 ——
            // 留着反而让人以为切换它会改变下面的内容。所以只留个标题。
            Text("Token查询")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if let last = state.lastRefresh {
                Text(last, style: .relative)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button {
                Task { await state.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(state.isRefreshing ? 360 : 0))
                    .animation(
                        state.isRefreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: state.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .help("立即刷新")
            .disabled(state.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 内容

    /// 内容区必须给确定高度：在菜单栏弹窗里，只设 maxHeight 的 ScrollView 会塌缩成 0，
    /// 把页签和内容一起吞掉。
    ///
    /// 高度 540 是按总览页最挤的情况定的 —— 三个服务商各一张卡片
    /// （含环形图、重置时刻、明细）实测约 660pt，所以三家都启用时仍需轻微滚动，
    /// 但两家以内可以完整看全。面板整体约 680pt，仍在 800pt 逻辑高度的屏幕内。
    private var contentScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            currentContent
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(height: 540)
    }

    @ViewBuilder
    private var currentContent: some View {
        switch route {
        case .newAccount:
            AccountEditorView(account: nil, onDone: closeEditor)
        case .editAccount(let account):
            AccountEditorView(account: account, onDone: closeEditor)
        case .tabs:
            switch tab {
            case .overview:
                OverviewView()
            case .accounts:
                AccountsView(
                    onAdd: { openEditor(.newAccount) },
                    onEdit: { openEditor(.editAccount($0)) }
                )
            case .settings:
                SettingsView()
            }
        }
    }

    private func openEditor(_ target: PanelRoute) {
        DebugLog.write("打开账号编辑器：\(target == .newAccount ? "新建" : "编辑")")
        route = target
    }

    private func closeEditor() {
        DebugLog.write("关闭账号编辑器")
        route = .tabs
        tab = .accounts
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    DebugLog.write("点击页签：\(item.rawValue)")
                    withAnimation(.easeOut(duration: 0.15)) { tab = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(tab == item ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text("每 \(state.refreshIntervalMinutes) 分钟自动刷新")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - 共用小组件

/// 空状态提示
struct EmptyHint: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
    }
}
