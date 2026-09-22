import SwiftUI

/// 额度相关的共用视觉组件。
///
/// 单独成文件是为了能脱离 `AppState` 做离屏渲染验证 —— 面板里的真实观感
/// 没法截图确认，只能靠渲染出来看排版有没有崩。这里只依赖数据模型，不碰全局状态。

/// 额度配色。剩余越低越危险，所以颜色跟着「剩余」走，而不是「已用」。
///
/// 三档：≥50% 绿、≥20% 橙、其余红。预警线默认也是 20%，两边口径一致。
enum QuotaStyle {
    static func tint(for remaining: Double) -> Color {
        if remaining >= 50 { return .green }
        if remaining >= 20 { return .orange }
        return .red
    }
}

/// 环形进度图（甜甜圈）。
///
/// 一个窗口一个环：外圈是轨道，内圈按**剩余**比例上色，圆心是剩余百分比，
/// 下面跟窗口名（「5 小时」/「周」）和重置时刻。
///
/// 几个刻意的选择：
/// - 剩余为 0 时不画任何弧（`trim` 到 0），而不是留一小段圆头 ——
///   一小段红弧看起来像「还剩一点点」，实际是已经用完了。
/// - 数据过期时整个环转灰，和实时数据区分开，而不是继续用红/绿误导。
/// - 弧长变化带 0.35s 动画，刷新后能看出「刚才动了」。
struct QuotaRing: View {
    let title: String
    let remainingPercent: Double
    /// 重置说明（已经格式化好的短句，例如「9月27日 20:56 重置」）
    var resetHint: String?
    var isStale: Bool = false
    var isLimitReached: Bool = false
    var size: CGFloat = 72
    var lineWidth: CGFloat = 8

    private var tint: Color {
        isStale ? Color.secondary : QuotaStyle.tint(for: remainingPercent)
    }

    private var fraction: Double {
        max(0, min(1, remainingPercent / 100))
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // 从 12 点方向开始顺时针走
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.35), value: fraction)

                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(remainingPercent.rounded()))")
                        // 不用 design: .monospaced —— SF Mono 的数字 0 带斜杠，
                        // 「0%」会读成「Ø%」。monospacedDigit 一样对齐，没这个问题。
                        .font(.system(size: 19, weight: .semibold).monospacedDigit())
                    Text("%")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, lineWidth)
            }
            .frame(width: size, height: size)

            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    if isLimitReached {
                        Text("已用完")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }
                if let resetHint {
                    Text(resetHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 还没取到数时的占位环，避免卡片高度在加载前后跳动
struct QuotaRingPlaceholder: View {
    var title: String
    var size: CGFloat = 72
    var lineWidth: CGFloat = 8

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: lineWidth)
                ProgressView().controlSize(.small)
            }
            .frame(width: size, height: size)

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 时间格式化

enum QuotaFormat {

    /// 「9月27日 20:56」
    static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    /// 「还有 5 天 3 小时」。只给「重置」而不给时间尺度，等于没说。
    static func remainingText(from now: Date = Date(), to date: Date) -> String {
        let parts = Calendar.current.dateComponents([.day, .hour], from: now, to: date)
        let days = parts.day ?? 0
        let hours = parts.hour ?? 0
        if days > 0 { return "还有 \(days) 天 \(hours) 小时" }
        let minutes = Calendar.current.dateComponents([.minute], from: now, to: date).minute ?? 0
        if hours > 0 { return "还有 \(hours) 小时 \(minutes) 分" }
        return "还有 \(max(0, minutes)) 分"
    }

    /// 「9月27日 20:56 重置」—— 环下面那一行，要短，所以不带「还有多久」。
    static func resetHint(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        return "\(shortDateTime(date)) 重置"
    }

    /// 详情行里用的长版本：「9月27日 20:56 重置（还有 5 天 3 小时）」
    static func resetDetail(_ date: Date?) -> String? {
        guard let date, date > Date() else { return nil }
        return "\(shortDateTime(date)) 重置（\(remainingText(to: date))）"
    }
}
