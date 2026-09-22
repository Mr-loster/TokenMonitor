import Foundation
import UserNotifications

/// 低额度预警。走系统通知，不弹自家窗口打扰。
///
/// 三个服务商现在统一是「剩余百分比」口径，所以这里不再有金额分支。
@MainActor
final class AlertEngine {
    static let shared = AlertEngine()

    /// 每个账号上次通知时间，避免持续骚扰
    private var lastNotified: [UUID: Date] = [:]
    /// 同一账号两次通知的最小间隔
    private let cooldown: TimeInterval = 6 * 3600

    private init() {}

    /// 有没有 app bundle。
    ///
    /// `UNUserNotificationCenter.current()` 在没有 bundle 时会**直接抛 NSException**
    /// （`bundleProxyForCurrentProcess is nil`），不是返回 nil、也不是 throw ——
    /// 所以 do/catch 拦不住，必须在碰它之前先判断。
    /// 直接用二进制跑（开发调试、离屏渲染验证）就会踩到这一点。
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestAuthorization() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(account: APIAccount, balance: AccountBalance) {
        guard account.isEnabled, balance.errorMessage == nil else { return }

        // 统一用 comparableValue：服务端已熔断的一律按 0 算
        guard balance.comparableValue <= account.alertThreshold else {
            // 额度回升，重置冷却
            lastNotified[account.id] = nil
            return
        }

        if let last = lastNotified[account.id], Date().timeIntervalSince(last) < cooldown {
            return
        }
        lastNotified[account.id] = Date()
        send(account: account, balance: balance)
    }

    private func send(account: APIAccount, balance: AccountBalance) {
        guard notificationsAvailable else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(account.provider.displayName) 额度不足"

        let percent = Int((balance.remainingPercent ?? 0).rounded())
        if balance.isLimitReached {
            content.body = "「\(account.name)」的额度已经用完，请等待重置或升级套餐。"
        } else {
            content.body = "「\(account.name)」剩余额度仅 \(percent)%，"
                + "已低于预警线 \(String(format: "%.0f", account.alertThreshold))%。"
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
