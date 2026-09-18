import Foundation
import UserNotifications

/// 低余额预警。走系统通知，不弹自家窗口打扰。
@MainActor
final class AlertEngine {
    static let shared = AlertEngine()

    /// 每个账号上次通知时间，避免持续骚扰
    private var lastNotified: [UUID: Date] = [:]
    /// 同一账号两次通知的最小间隔
    private let cooldown: TimeInterval = 6 * 3600

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(account: APIAccount, balance: AccountBalance) {
        guard account.isEnabled, balance.errorMessage == nil else { return }

        // 统一用 comparableValue：金额账号是余额，百分比账号是剩余百分比，
        // 服务端已熔断的一律按 0 算。
        guard balance.comparableValue <= account.alertThreshold else {
            // 余额回升，重置冷却
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
        let content = UNMutableNotificationContent()
        content.title = account.provider.isPercentBased ? "额度不足提醒" : "余额不足提醒"

        if let percent = balance.remainingPercent {
            var body = "「\(account.name)」剩余额度仅 \(Int(percent.rounded()))%，"
                + "已低于预警线 \(String(format: "%.0f", account.alertThreshold))%。"
            if balance.isLimitReached {
                body = "「\(account.name)」的额度已经用完，请等待重置或升级套餐。"
            }
            content.body = body
        } else {
            content.body = "「\(account.name)」余额仅剩 \(balance.currencySymbol)\(String(format: "%.2f", balance.totalBalance))，"
                + "已低于预警线 \(String(format: "%.2f", account.alertThreshold))。"
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
