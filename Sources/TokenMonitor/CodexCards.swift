import SwiftUI

/// Codex 相关的共用视觉组件。
///
/// 单独成文件是为了能脱离 `AppState` 做离屏渲染验证 —— 面板里的真实观感
/// 没法截图确认，只能靠渲染出来看排版有没有崩。这里只依赖数据模型，不碰全局状态。

/// 额度配色。剩余越低越危险，所以颜色跟着「剩余」走，而不是「已用」。
enum CodexStyle {
    static func tint(for remaining: Double) -> Color {
        if remaining >= 50 { return .green }
        if remaining >= 20 { return .orange }
        return .red
    }
}

/// 额度条。固定高度 + 内部按比例算宽度。
struct CodexProgressBar: View {
    let remainingPercent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                Capsule()
                    .fill(CodexStyle.tint(for: remainingPercent))
                    // 剩余为 0 时不留那 3pt 的最小宽度 —— 一小段红条看起来像
                    // 「还剩一点点」，而实际是已经用完了。
                    .frame(width: remainingPercent <= 0
                           ? 0
                           : max(3, geo.size.width * remainingPercent / 100))
            }
        }
        .frame(height: 6)
    }
}
