import Foundation

// MARK: - 服务商

enum Provider: String, Codable, CaseIterable, Identifiable {
    /// 按金额计量，凭据是本程序自己保存的 API Key
    case deepseek
    /// 按「剩余百分比」计量，凭据复用 Codex 自己的登录（auth.json）
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .codex:    return "Codex"
        }
    }

    /// 这个服务商按百分比计量，而不是金额。
    /// 决定阈值单位、界面文案、菜单栏格式，以及哪些指标（充值/赠送/消耗趋势）不适用。
    var isPercentBased: Bool { self == .codex }

    /// 预警线输入框后面的单位
    var thresholdUnit: String { isPercentBased ? "%" : "元" }

    /// 余额查询接口
    var balanceEndpoint: URL {
        switch self {
        case .deepseek:
            return URL(string: "https://api.deepseek.com/user/balance")!
        case .codex:
            return CodexUsageService.defaultEndpoint
        }
    }

    /// 充值 / 升级页面
    var consoleURL: URL {
        switch self {
        case .deepseek:
            return URL(string: "https://platform.deepseek.com/top_up")!
        case .codex:
            return URL(string: "https://chatgpt.com/#pricing")!
        }
    }
}

// MARK: - Codex 凭据来源

/// 一个 Codex 账号的凭据是怎么来的。
///
/// - `authFile`：读某个 `auth.json`。**推荐**，因为 Codex 自己会续期，
///   凭据长期有效。第二个账号的做法是另开一个 `CODEX_HOME` 目录登录。
/// - `pastedToken`：用户直接粘 access_token。省事，但 token 只有约 10 天有效期，
///   而本程序刻意不做自动续期（refresh_token 是轮换的，写错会破坏用户自己的登录），
///   所以到期后必须重新粘一次。
enum CodexCredentialKind: String, Codable, CaseIterable, Identifiable {
    case authFile
    case pastedToken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .authFile:    return "读取 auth.json"
        case .pastedToken: return "粘贴 access_token"
        }
    }
}

// MARK: - 菜单栏显示模式

/// 多账号时菜单栏那一格显示什么
enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    /// 只显示当前选中账号的余额
    case current
    /// 显示所有已启用账号的合计余额
    case total

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .current: return "当前账号"
        case .total: return "全部账号合计"
        }
    }
}

// MARK: - 账号

struct APIAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var provider: Provider
    /// 只保存 Key 的后四位用于界面显示，完整 Key 存在 CredentialStore
    var keySuffix: String = ""
    /// DeepSeek 是「低于这个金额预警」，Codex 是「低于这个剩余百分比预警」
    var alertThreshold: Double = 10
    var isEnabled: Bool = true

    // MARK: - Codex 专用字段
    //
    // 全部声明成 Optional 是**刻意的**，不要「顺手」改成非可选：
    // `AccountStore.load()` 解码失败时会返回空数组，也就是任何一个非可选字段
    // 在旧数据里缺失，都会把用户已有的账号**静默清空**。Optional 走
    // `decodeIfPresent`，缺 key 不抛错，天然向后兼容。

    /// auth.json 的路径。nil 或空表示用默认的 `~/.codex/auth.json`。
    var codexAuthPath: String?
    /// 凭据来源。用 String 而不是枚举，同样是为了解码容错。
    var codexCredentialKind: String?
    /// 粘贴 token 模式下的 ChatGPT account id（非机密，明文存即可）
    var codexAccountID: String?

    var isCodex: Bool { provider == .codex }

    var credentialKind: CodexCredentialKind {
        get { codexCredentialKind.flatMap(CodexCredentialKind.init(rawValue:)) ?? .authFile }
        set { codexCredentialKind = newValue.rawValue }
    }

    var usesPastedToken: Bool { isCodex && credentialKind == .pastedToken }

    /// 实际使用的 auth.json 路径（未指定则用默认的）
    var resolvedAuthURL: URL {
        guard let path = codexAuthPath, !path.isEmpty else {
            return CodexAuthStore.defaultAuthFileURL
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// 界面展示用的凭据说明
    var credentialSummary: String {
        guard isCodex else { return maskedKey }
        switch credentialKind {
        case .pastedToken:
            let suffix = keySuffix.isEmpty ? "" : "…\(keySuffix)"
            return "粘贴的 token\(suffix)"
        case .authFile:
            let path = codexAuthPath?.isEmpty == false ? codexAuthPath! : "~/.codex/auth.json"
            return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    var maskedKey: String {
        keySuffix.isEmpty ? "未设置" : "••••••••\(keySuffix)"
    }
}

// MARK: - 余额快照（本地记录，用于推算消耗趋势）

struct BalanceSnapshot: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var accountID: UUID
    var timestamp: Date
    var totalBalance: Double
    var grantedBalance: Double
    var toppedUpBalance: Double
    var currency: String
}

// MARK: - 实时余额状态

struct AccountBalance: Equatable {
    var accountID: UUID
    var totalBalance: Double = 0
    var grantedBalance: Double = 0
    var toppedUpBalance: Double = 0
    var currency: String = "CNY"
    var isAvailable: Bool = true
    /// 最后一次刷新尝试的时间（无论成功失败）
    var updatedAt: Date = Date()
    /// 最后一次成功取到余额的时间。失败时保留上次的金额，靠这个字段标注「数据已过期」
    var successAt: Date?
    var errorMessage: String?

    // MARK: - 百分比类账号（Codex）

    /// 剩余百分比。非 nil 表示这是按百分比计量的账号，此时 `totalBalance` 无意义。
    /// 取的是所有窗口里**最紧张**的那个（剩余最低）。
    var remainingPercent: Double?
    /// 服务端明确判定「额度已用完」。注意可能百分比还没到 0（服务端提前熔断）。
    var isLimitReached: Bool = false
    /// 完整额度结构，供总览页展示窗口细节
    var codexUsage: CodexUsage?
    /// 结构化的 Codex 错误。界面要靠它展示「出了什么事 + 下一步做什么」，
    /// 光有 `errorMessage` 一句话不够。
    var codexError: CodexUsageError?

    /// 是否曾经成功取到过余额
    var hasValue: Bool { successAt != nil }

    /// 有金额但最近一次刷新失败 —— 界面要标成过期而不是直接藏起来
    var isStale: Bool { errorMessage != nil && hasValue }

    var isPercentAccount: Bool { remainingPercent != nil }

    /// 阈值比较统一走这个属性。
    ///
    /// 服务端已熔断时直接返回 0 —— 比任何预警线都紧急。
    /// 否则会出现「显示还剩 12%、判定正常、实际已经被拒」的误导。
    var comparableValue: Double {
        if isLimitReached { return 0 }
        return remainingPercent ?? totalBalance
    }

    var currencySymbol: String {
        if isPercentAccount { return "" }
        switch currency.uppercased() {
        case "CNY": return "¥"
        case "USD": return "$"
        default: return ""
        }
    }

    /// 按货币习惯格式化金额
    var formattedTotal: String {
        String(format: "%.2f", totalBalance)
    }

    /// 界面统一使用的展示值：`¥12.34` 或 `0%`
    var displayValue: String {
        if let percent = remainingPercent {
            return "\(Int(percent.rounded()))%"
        }
        return currencySymbol + formattedTotal
    }
}

/// 金额格式化：固定两位小数
func formatMoney(_ value: Double) -> String {
    String(format: "%.2f", value)
}

/// 套餐名的中文写法。接口给的是 `free` / `plus` 这种小写标识。
func planDisplayName(_ raw: String) -> String {
    switch raw.lowercased() {
    case "free":       return "免费版"
    case "plus":       return "Plus"
    case "pro":        return "Pro"
    case "team":       return "Team"
    case "business":   return "Business"
    case "enterprise": return "Enterprise"
    default:           return raw
    }
}
