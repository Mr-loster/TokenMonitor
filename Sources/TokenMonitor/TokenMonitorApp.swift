import SwiftUI

@main
struct TokenMonitorApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AlertEngine.shared.requestAuthorization()
        }
    }

    /// 快照写盘做了节流，退出前补一次，避免丢掉最后一段数据
    func applicationWillTerminate(_ notification: Notification) {
        SnapshotStore.shared.flush()
    }
}

/// 菜单栏常驻标签：图标 + 余额数字
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @AppStorage("menuBarShowsBalance") private var showsBalance: Bool = true
    @AppStorage("menuBarDisplayMode") private var displayMode: String = MenuBarDisplayMode.current.rawValue

    private var mode: MenuBarDisplayMode {
        MenuBarDisplayMode(rawValue: displayMode) ?? .current
    }

    private var status: MenuBarStatus { state.menuBarStatus(mode: mode) }

    var body: some View {
        HStack(spacing: 3) {
            // 有彩色版本就用彩色图，取不到再退回普通符号（形状本身也能区分状态）
            if let icon = MenuBarIcon.image(symbol: state.menuBarSymbol(mode: mode), status: status) {
                Image(nsImage: icon)
            } else {
                Image(systemName: state.menuBarSymbol(mode: mode))
            }

            if showsBalance && !state.menuBarText(mode: mode).isEmpty {
                Text(state.menuBarText(mode: mode))
                    // 用默认字体的等宽数字：design: .monospaced 是 SF Mono，
                    // 数字 0 带斜杠，菜单栏上「CX 0%」会读成「CX Ø%」。
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MenuBarIcon.color(for: status))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// 菜单栏图标上色。
///
/// 菜单栏默认把标签内容当**模板图**处理 —— 只取 alpha，颜色会被抹掉。
/// 所以这里把 SF Symbol 先画进一张自建 NSImage，用 sourceAtop 上色，再把 isTemplate 关掉。
@MainActor
enum MenuBarIcon {

    static func color(for status: MenuBarStatus) -> Color {
        switch status {
        case .normal: return .green
        case .warning: return .yellow
        case .error: return .red
        case .loading: return .secondary
        }
    }

    private static func nsColor(for status: MenuBarStatus) -> NSColor {
        switch status {
        case .normal: return .systemGreen
        case .warning: return .systemYellow
        case .error: return .systemRed
        case .loading: return .secondaryLabelColor
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, status: MenuBarStatus) -> NSImage? {
        // 加载态不上色：留成系统模板图，能跟着浅色/深色菜单栏自动变色。
        // 上色成灰/黑反而会在深色菜单栏下看不见。
        guard status != .loading else { return nil }

        let key = "\(symbol)|\(status)"
        if let cached = cache[key] { return cached }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }

        let tinted = tint(base, with: nsColor(for: status))
        cache[key] = tinted
        return tinted
    }

    private static func tint(_ image: NSImage, with color: NSColor) -> NSImage {
        let size = image.size
        let result = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        // 关键：关掉模板模式，否则菜单栏还是会把颜色抹成单色
        result.isTemplate = false
        return result
    }
}
