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
}

/// 菜单栏常驻标签：图标 + **当前轮播到的那一家**的剩余百分比。
///
/// 之所以只显示一家：三家并排写成 `GR 37% · CX 20% · GP 85%` 太长，
/// 菜单栏那一格会宽到把旁边的图标挤掉。改成轮流显示，颜色跟着它自己的额度状态走。
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @AppStorage("menuBarShowsBalance") private var showsBalance: Bool = true

    private var status: MenuBarStatus { state.menuBarStatus() }

    var body: some View {
        HStack(spacing: 3) {
            // 有彩色版本就用彩色图，取不到再退回普通符号（形状本身也能区分状态）
            if let icon = MenuBarIcon.image(symbol: state.menuBarSymbol(), status: status) {
                Image(nsImage: icon)
            } else {
                Image(systemName: state.menuBarSymbol())
            }

            if showsBalance && !state.menuBarText().isEmpty {
                Text(state.menuBarText())
                    // 用默认字体的等宽数字：design: .monospaced 是 SF Mono，
                    // 数字 0 带斜杠，菜单栏上「CX 0%」会读成「CX Ø%」。
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(MenuBarIcon.color(for: status))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        // 换一家时让文字和颜色过渡一下，否则每 5 秒硬切一次看着像在闪
        .animation(.easeInOut(duration: 0.25), value: state.menuBarRotation)
    }
}

/// 菜单栏图标上色。
///
/// 菜单栏默认把标签内容当**模板图**处理 —— 只取 alpha，颜色会被抹掉。
/// 所以这里把 SF Symbol 先画进一张自建 NSImage，用 sourceAtop 上色，再把 isTemplate 关掉。
///
/// 配色和环形图同口径（≥50% 绿 / ≥20% 橙 / <20% 红），
/// 这样面板里 Grok 是橙环、菜单栏轮到 Grok 也是橙字，不会出现「同一个数字两个颜色」。
@MainActor
enum MenuBarIcon {

    static func color(for status: MenuBarStatus) -> Color {
        switch status {
        case .normal:   return .green
        case .warning:  return .orange
        case .critical: return .red
        case .error:    return .red
        case .loading:  return .secondary
        }
    }

    private static func nsColor(for status: MenuBarStatus) -> NSColor {
        switch status {
        case .normal:   return .systemGreen
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        case .error:    return .systemRed
        case .loading:  return .secondaryLabelColor
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
