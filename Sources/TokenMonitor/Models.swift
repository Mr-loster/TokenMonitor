import Foundation

// MARK: - 服务商

/// 三个服务商现在**都是按「剩余百分比」计量**的。
/// 原来的 DeepSeek（按金额计量、需要余额快照推算消耗趋势）已经移除，
/// 所以模型里不再有金额、币种、快照这些东西。
enum Provider: String, Codable, CaseIterable, Identifiable {
    /// xAI 的 Grok，额度来自 Grok CLI 的登录凭据（`~/.grok/auth.json`）
    case grok
    /// OpenAI 的 Codex，凭据复用 Codex 自己的登录（`~/.codex/auth.json`）
    case codex
    /// Antigravity 里的 Gemini Pro，凭据由本地语言服务器自动提供
    case gemini

    var id: String { rawValue }

    /// 界面里的显示顺序：**Gemini Pro 排第一**（HD 的日常主力），其余保持原相对顺序。
    ///
    /// 直接覆盖 `allCases`，而不是另开一个 `displayOrder` 数组：总览页的分组顺序、
    /// 菜单栏的轮播顺序、账号编辑器里的服务商下拉，三处都走 `allCases`，
    /// 只改一个地方就不会出现「总览 Gemini 第一、下拉里 Gemini 第三」这种不一致。
    ///
    /// ⚠️ **新增服务商时必须加进这个数组**，否则界面里根本看不到它。
    static var allCases: [Provider] { [.gemini, .grok, .codex] }

    var displayName: String {
        switch self {
        case .grok:   return "Grok"
        case .codex:  return "Codex"
        case .gemini: return "Gemini Pro"
        }
    }

    /// 菜单栏上的短前缀，避免两个百分比数字分不清是谁的
    var menuBarPrefix: String {
        switch self {
        case .grok:   return "GR"
        case .codex:  return "CX"
        case .gemini: return "GP"
        }
    }

    /// 凭据从哪来（账号列表里的副标题）
    var credentialSummary: String {
        switch self {
        case .grok:   return "Grok CLI 的 auth.json"
        case .codex:  return "Codex 的 auth.json"
        case .gemini: return "Antigravity 的登录凭据"
        }
    }

    /// 需要用户指定一个本地凭据文件路径（Grok / Codex 都是读别人的 auth.json）
    var usesAuthFile: Bool { self == .grok || self == .codex }

    /// 充值 / 升级页面
    var consoleURL: URL {
        switch self {
        case .grok:   return URL(string: "https://grok.com/?_s=usage")!
        case .codex:  return URL(string: "https://chatgpt.com/#pricing")!
        case .gemini: return URL(string: "https://aistudio.google.com/app/usage")!
        }
    }

    /// 预警线单位。三个服务商现在统一是百分比。
    var thresholdUnit: String { "%" }
}

// MARK: - 本地凭据来源

/// 一个账号的凭据是怎么来的（Grok 与 Codex 共用）。
///
/// - `authFile`：读对方自己的 `auth.json`。**推荐** —— 对方会自己续期，
///   本程序只在 Grok 的 token 过期时帮它续一次（Codex 则完全不动）。
/// - `pastedToken`：用户直接粘 access_token。省事，但有效期很短
///   （Codex 约 10 天、Grok 只有 6 小时），到期后必须重新粘。
enum LocalCredentialKind: String, Codable, CaseIterable, Identifiable {
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

// MARK: - 账号

struct APIAccount: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var provider: Provider
    /// 只保存 Key 的后四位用于界面显示，完整 Key 存在 CredentialStore
    var keySuffix: String = ""
    /// 剩余百分比低于这个值就预警
    var alertThreshold: Double = 20
    var isEnabled: Bool = true

    // MARK: - 凭据字段
    //
    // 全部声明成 Optional 是**刻意的**：`AccountStore.load()` 走的是
    // `decodeIfPresent`，缺 key 不抛错，天然向后兼容。

    /// auth.json 的路径。nil 或空表示用该服务商的默认路径。
    var authFilePath: String?
    /// 凭据来源。用 String 而不是枚举，同样是为了解码容错。
    var credentialKindRaw: String?
    /// 粘贴 token 模式下附带的账号 id（Codex 用 ChatGPT account id，非机密）
    var accountIDHint: String?

    var credentialKind: LocalCredentialKind {
        get { credentialKindRaw.flatMap(LocalCredentialKind.init(rawValue:)) ?? .authFile }
        set { credentialKindRaw = newValue.rawValue }
    }

    var usesPastedToken: Bool { credentialKind == .pastedToken }

    /// 实际使用的 auth.json 路径（未指定则用该服务商的默认值）
    var resolvedAuthURL: URL {
        guard let path = authFilePath, !path.isEmpty else {
            switch provider {
            case .grok:   return GrokAuthStore.defaultAuthFileURL
            case .codex:  return CodexAuthStore.defaultAuthFileURL
            case .gemini: return CodexAuthStore.defaultAuthFileURL   // 不用，占位
            }
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// 界面展示用的凭据说明
    var credentialSummary: String {
        if provider == .gemini { return "Antigravity 的登录凭据" }
        guard provider.usesAuthFile else { return maskedKey }
        switch credentialKind {
        case .pastedToken:
            let suffix = keySuffix.isEmpty ? "" : "…\(keySuffix)"
            return "粘贴的 token\(suffix)"
        case .authFile:
            let fallback = provider == .grok ? "~/.grok/auth.json" : "~/.codex/auth.json"
            let path = authFilePath?.isEmpty == false ? authFilePath! : fallback
            return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    var maskedKey: String {
        keySuffix.isEmpty ? "未设置" : "••••••••\(keySuffix)"
    }

    // MARK: - 旧字段迁移
    //
    // v1.11 及以前这几个字段叫 codexAuthPath / codexCredentialKind / codexAccountID。
    // 现在 Grok 也共用它们，改成了通用名字。解码时先读新名，读不到再回退旧名，
    // 这样老用户的 Codex 账号不会因为改名而丢配置。

    enum CodingKeys: String, CodingKey {
        case id, name, provider, keySuffix, alertThreshold, isEnabled
        case authFilePath, credentialKindRaw, accountIDHint
        case legacyAuthPath = "codexAuthPath"
        case legacyCredentialKind = "codexCredentialKind"
        case legacyAccountID = "codexAccountID"
    }

    init(name: String, provider: Provider, alertThreshold: Double = 20) {
        self.name = name
        self.provider = provider
        self.alertThreshold = alertThreshold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名"
        provider = try container.decode(Provider.self, forKey: .provider)
        keySuffix = try container.decodeIfPresent(String.self, forKey: .keySuffix) ?? ""
        alertThreshold = try container.decodeIfPresent(Double.self, forKey: .alertThreshold) ?? 20
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

        authFilePath = try container.decodeIfPresent(String.self, forKey: .authFilePath)
            ?? container.decodeIfPresent(String.self, forKey: .legacyAuthPath)
        credentialKindRaw = try container.decodeIfPresent(String.self, forKey: .credentialKindRaw)
            ?? container.decodeIfPresent(String.self, forKey: .legacyCredentialKind)
        accountIDHint = try container.decodeIfPresent(String.self, forKey: .accountIDHint)
            ?? container.decodeIfPresent(String.self, forKey: .legacyAccountID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(provider, forKey: .provider)
        try container.encode(keySuffix, forKey: .keySuffix)
        try container.encode(alertThreshold, forKey: .alertThreshold)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(authFilePath, forKey: .authFilePath)
        try container.encodeIfPresent(credentialKindRaw, forKey: .credentialKindRaw)
        try container.encodeIfPresent(accountIDHint, forKey: .accountIDHint)
    }
}

// MARK: - 实时额度状态

struct AccountBalance: Equatable {
    var accountID: UUID
    /// 最后一次刷新尝试的时间（无论成功失败）
    var updatedAt: Date = Date()
    /// 最后一次成功取到额度的时间。失败时保留上次的值，靠这个字段标注「数据已过期」
    var successAt: Date?
    var errorMessage: String?

    /// 剩余百分比。取所有窗口里**最紧张**的那个（剩余最低）。
    var remainingPercent: Double?
    /// 服务端明确判定「额度已用完」。可能百分比还没到 0（服务端提前熔断）。
    var isLimitReached: Bool = false

    /// 各服务商的完整额度结构，供总览页展示窗口细节
    var grokUsage: GrokUsage?
    var codexUsage: CodexUsage?
    var geminiUsage: GeminiProUsage?

    /// 结构化的错误。界面要靠它展示「出了什么事 + 下一步做什么」，
    /// 光有 `errorMessage` 一句话不够。
    var grokError: GrokError?
    var codexError: CodexUsageError?
    var geminiError: GeminiProError?

    /// 是否曾经成功取到过额度
    var hasValue: Bool { successAt != nil }

    /// 有值但最近一次刷新失败 —— 界面要标成过期而不是直接藏起来
    var isStale: Bool { errorMessage != nil && hasValue }

    /// 阈值比较统一走这个属性。
    ///
    /// 服务端已熔断时直接返回 0 —— 比任何预警线都紧急。
    /// 否则会出现「显示还剩 12%、判定正常、实际已经被拒」的误导。
    var comparableValue: Double {
        if isLimitReached { return 0 }
        return remainingPercent ?? 0
    }

    /// 结构化的错误说明与建议，总览页统一渲染
    var structuredError: (title: String, suggestion: String?)? {
        if let grokError { return (grokError.errorDescription ?? "读取失败", grokError.suggestion) }
        if let codexError { return (codexError.errorDescription ?? "读取失败", codexError.suggestion) }
        if let geminiError { return (geminiError.errorDescription ?? "读取失败", geminiError.suggestion) }
        return nil
    }

    // MARK: - 统一的窗口列表

    /// 把三个服务商各自不同的窗口模型，统一成界面要画的形状。
    ///
    /// 总览页只认这个列表 —— 有几个窗口就画几个环，不需要为每家写一套渲染逻辑。
    /// Grok 目前只有 1 个（周），Codex 和 Gemini 通常有 2 个（5 小时 + 周）。
    var quotaWindows: [QuotaWindow] {
        if let grokUsage {
            return grokUsage.windows.enumerated().map { index, window in
                QuotaWindow(
                    id: "grok-\(index)",
                    title: shortWindowTitle(seconds: window.windowSeconds),
                    remainingPercent: window.remainingPercent,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt
                )
            }
        }
        if let codexUsage {
            return [codexUsage.primary, codexUsage.secondary]
                .compactMap { $0 }
                .enumerated()
                .map { index, window in
                    QuotaWindow(
                        id: "codex-\(index)",
                        title: shortWindowTitle(seconds: window.windowSeconds),
                        remainingPercent: window.remainingPercent,
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt
                    )
                }
        }
        if let geminiUsage {
            return [geminiUsage.primary, geminiUsage.secondary]
                .compactMap { $0 }
                .enumerated()
                .map { index, window in
                    QuotaWindow(
                        id: "gemini-\(index)",
                        title: shortWindowTitle(seconds: window.windowSeconds),
                        remainingPercent: window.remainingPercent,
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt
                    )
                }
        }
        return []
    }

    /// 最早的、还没到期的重置时刻（多窗口时用来给一句「什么时候恢复」）
    var nextReset: Date? {
        let now = Date()
        return quotaWindows.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}

// MARK: - 统一的额度窗口

/// 界面上要画的一个额度窗口。三个服务商的窗口模型不一样，
/// 统一成这个之后总览页只需要一套渲染逻辑。
struct QuotaWindow: Identifiable, Equatable {
    var id: String
    /// 「5 小时」/「周」/「额度」
    var title: String
    var remainingPercent: Double
    var usedPercent: Double
    var resetsAt: Date?
}

/// 窗口长度的短说法，给环形图当标题用。
func shortWindowTitle(seconds: Double) -> String {
    guard seconds > 0 else { return "额度" }
    let hours = seconds / 3600
    if hours < 1 { return "\(Int((seconds / 60).rounded())) 分钟" }
    if hours < 24 { return "\(Int(hours.rounded())) 小时" }
    let days = hours / 24
    // 7 天就说「周」，比「7 天」更像人话
    if days >= 6, days <= 8 { return "周" }
    if days < 10 { return "\(Int(days.rounded())) 天" }
    return "\(Int((days / 30).rounded())) 个月"
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
