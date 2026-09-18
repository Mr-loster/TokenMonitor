import Foundation

// MARK: - 数据模型

/// 一个额度窗口。Codex 一般给两个：短周期（如 5 小时）和长周期（如周）。
struct CodexRateWindow: Equatable {
    var usedPercent: Double
    /// 窗口长度（秒）。接口偶尔不返回，此时为 0。
    var windowSeconds: Double
    var resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// 「5 小时窗口」这类说明。接口没给窗口长度时退化成中性说法。
    var windowLabel: String {
        guard windowSeconds > 0 else { return "额度窗口" }
        let hours = windowSeconds / 3600
        if hours < 1 { return "\(Int((windowSeconds / 60).rounded())) 分钟窗口" }
        if hours < 24 { return "\(Int(hours.rounded())) 小时窗口" }
        let days = hours / 24
        if days < 10 { return "\(Int(days.rounded())) 天窗口" }
        return "\(Int((days / 30).rounded())) 个月窗口"
    }
}

struct CodexCredits: Equatable {
    var hasCredits: Bool
    var unlimited: Bool
    var balance: Double?
}

struct CodexUsage: Equatable {
    var planType: String?
    var primary: CodexRateWindow?
    var secondary: CodexRateWindow?
    var credits: CodexCredits?

    /// 服务端明确判定「额度已用完」。
    ///
    /// 比 `remainingPercent == 0` 更可靠：服务端可能提前熔断（百分比还没走到 100
    /// 就已经拒绝请求），也可能因为缓存让百分比滞后。界面靠这个字段决定要不要
    /// 顶一条「已用完」横幅，而不是只看百分比。
    var limitReached: Bool

    var fetchedAt: Date
}

// MARK: - 错误

/// 每种失败都要能告诉用户「下一步做什么」。
/// 这个接口依赖三个前提（装了 Codex、登录了 ChatGPT、网络能到 chatgpt.com），
/// 任何一个不满足都会失败，界面上必须说清是哪一个，而不是丢一个转圈。
enum CodexUsageError: LocalizedError, Equatable {
    case notInstalled
    case notLoggedIn
    case authFileMissing(String)
    case tokenExpired(Date?)
    case unauthorized
    case network(String)
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notInstalled:      return "未检测到 Codex"
        case .notLoggedIn:       return "Codex 未登录 ChatGPT 账号"
        case .authFileMissing:   return "读不到 auth.json"
        case .tokenExpired:      return "Codex 登录凭据已过期"
        case .unauthorized:      return "登录状态被拒绝（401）"
        case .network:           return "连不上 chatgpt.com"
        case .http(let code):    return "接口返回 HTTP \(code)"
        case .decoding:          return "接口返回了预期之外的内容"
        }
    }

    /// 界面上的操作建议
    var suggestion: String {
        switch self {
        case .notInstalled:
            return "没找到 ~/.codex 目录。装了 Codex 并用 ChatGPT 账号登录之后，回「总览」点一下「导入」就能读额度。"
        case .notLoggedIn:
            return "auth.json 里没有 ChatGPT 的 access_token。如果你是用 API Key 方式配置的 Codex，那它没有 ChatGPT 订阅额度可读 —— 打开一次 Codex 用 ChatGPT 账号登录即可。"
        case .authFileMissing(let path):
            return "这个账号指向的凭据文件不存在：\n\(path)\n\n路径写错了，或者那个 Codex 目录被删了。点「编辑」重新指定，或改成粘贴 token。"
        case .tokenExpired:
            return "access_token 已经过期。本程序刻意不自己续期（刷新会轮换 refresh_token，写错会破坏你的 Codex 登录）。\n\n· 用 auth.json 的账号：打开一次 Codex，它会自动续期，然后回来点刷新。\n· 粘贴 token 的账号：从 Codex 的 auth.json 里重新复制一个 access_token 粘进来。"
        case .unauthorized:
            return "凭据被服务端拒绝了，通常也是过期或被吊销。用 auth.json 的账号请打开一次 Codex 重新登录；粘贴 token 的账号请重新粘一个。"
        case .network(let detail):
            return "额度接口挂在 chatgpt.com 上，本机当前访问不到它。需要让 Codex 能正常联网（例如开启代理）之后才能读到额度。\n\n底层报错：\(detail)"
        case .http(let code):
            return "接口返回了非预期的状态码 \(code)。这个接口是非官方的，Codex 改版后可能已经变化。"
        case .decoding:
            return "响应不是预期的结构。这个接口是非官方的，Codex 改版后字段可能已经变化。"
        }
    }
}

// MARK: - 解析

/// 单独拆出来是为了能脱离网络测试。
enum CodexUsageParser {

    /// 解析 `/wham/usage` 的响应。
    ///
    /// 官方没有公开这个接口，字段命名在版本之间变过，两种形态都见过：
    /// - `rate_limit.primary_window` + `limit_window_seconds` + `reset_at`
    /// - `rate_limit.primary` + `window_minutes` + `resets_at`
    /// 所以两套都认，顺序是「先试新命名，再退到旧命名」。
    static func parse(data: Data, planTypeHint: String? = nil) throws -> CodexUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexUsageError.decoding
        }

        // 有的版本把 rate_limit 摊平在顶层
        let rateLimit = (root["rate_limit"] as? [String: Any]) ?? root

        let primary = window(rateLimit["primary_window"] ?? rateLimit["primary"])
        let secondary = window(rateLimit["secondary_window"] ?? rateLimit["secondary"])
        let credits = creditInfo(root["credits"])

        // 三样全空说明结构对不上，别假装成功
        guard primary != nil || secondary != nil || credits != nil else {
            throw CodexUsageError.decoding
        }

        return CodexUsage(
            planType: (root["plan_type"] as? String) ?? planTypeHint,
            primary: primary,
            secondary: secondary,
            credits: credits,
            limitReached: limitReached(rateLimit),
            fetchedAt: Date()
        )
    }

    /// 「用完了」有两个信号，任一成立即算。
    /// `limit_reached` 是新命名的布尔；老版本只给 `allowed`，取反即等价。
    private static func limitReached(_ rateLimit: [String: Any]) -> Bool {
        if let reached = rateLimit["limit_reached"] as? Bool { return reached }
        if let allowed = rateLimit["allowed"] as? Bool { return !allowed }
        return false
    }

    private static func window(_ value: Any?) -> CodexRateWindow? {
        guard let dict = value as? [String: Any],
              let used = number(dict["used_percent"]) else { return nil }

        var seconds = number(dict["limit_window_seconds"]) ?? 0
        if seconds == 0, let minutes = number(dict["window_minutes"]) {
            seconds = minutes * 60
        }

        return CodexRateWindow(
            usedPercent: used,
            windowSeconds: seconds,
            resetsAt: resetDate(dict)
        )
    }

    /// 重置时间有三种字段、四种写法：
    /// `reset_at` / `resets_at` 给的是**绝对时间**（epoch 秒或 ISO 字符串），
    /// `reset_after_seconds` 给的是**相对现在的秒数**，得自己加。
    /// 绝对时间优先 —— 相对时间会随请求时刻漂移，而界面要显示的是同一个时刻。
    private static func resetDate(_ dict: [String: Any]) -> Date? {
        if let absolute = date(dict["reset_at"]) ?? date(dict["resets_at"]) {
            return absolute
        }
        if let after = number(dict["reset_after_seconds"]) {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    private static func creditInfo(_ value: Any?) -> CodexCredits? {
        guard let dict = value as? [String: Any] else { return nil }
        return CodexCredits(
            hasCredits: dict["has_credits"] as? Bool ?? false,
            unlimited: dict["unlimited"] as? Bool ?? false,
            balance: number(dict["balance"])
        )
    }

    /// 兼容数字和数字字符串
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// reset 时间见过三种写法：epoch 秒、ISO 字符串、数字字符串
    private static func date(_ value: Any?) -> Date? {
        if let epoch = number(value) { return Date(timeIntervalSince1970: epoch) }
        guard let text = value as? String else { return nil }
        if let parsed = ISO8601DateFormatter().date(from: text) { return parsed }
        if let epoch = Double(text) { return Date(timeIntervalSince1970: epoch) }
        return nil
    }
}

// MARK: - 请求

final class CodexUsageService {
    static let shared = CodexUsageService()

    /// 非官方接口 —— Codex 桌面版自己在用这个路径，但没有公开文档，改版可能变。
    static let defaultEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let endpoint: URL
    private let session: URLSession

    /// endpoint 可注入，方便用本地假服务器验证整条链路
    init(endpoint: URL = CodexUsageService.defaultEndpoint, timeout: TimeInterval = 15) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func fetch(credential: CodexCredential) async throws -> CodexUsage {
        // authFile 模式下先确认文件在不在 —— 这样能给出「路径写错了」这种可操作的
        // 提示，而不是笼统的「未登录」。
        if case .authFile(let url) = credential,
           !FileManager.default.fileExists(atPath: url.path) {
            throw CodexUsageError.authFileMissing(url.path)
        }

        guard let auth = CodexAuthStore.resolve(credential) else {
            throw CodexUsageError.notLoggedIn
        }
        if auth.isExpired { throw CodexUsageError.tokenExpired(auth.expiresAt) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TokenMonitor/1.10", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = auth.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexUsageError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401, 403:  throw CodexUsageError.unauthorized
            default:        throw CodexUsageError.http(http.statusCode)
            }
        }

        return try CodexUsageParser.parse(data: data, planTypeHint: auth.planType)
    }

    /// 便利方法：读默认的 `~/.codex/auth.json`。
    /// 只用于「测试连接」这类不涉及具体账号的场景。
    func fetchDefault() async throws -> CodexUsage {
        try await fetch(credential: .authFile(CodexAuthStore.defaultAuthFileURL))
    }
}
