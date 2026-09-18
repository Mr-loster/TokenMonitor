import Foundation

/// Codex 的登录信息。
///
/// **只读** auth.json，不写入、不刷新 token。
///
/// 为什么不做自动续期：Codex 的 `refresh_token` 是轮换的，刷新成功后必须把新的
/// refresh_token 写回 auth.json。写错就会把用户 Codex 自己的登录搞坏 ——
/// 拿一个「看一眼额度」的功能去冒这个风险不划算。所以凭据过期时只是提示
/// 用户打开一次 Codex（它会自己续期），再回来刷新。
struct CodexAuth {
    var accessToken: String
    var accountID: String?
    var planType: String?
    var expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }
}

/// 一次 Codex 额度查询用哪份凭据。
enum CodexCredential: Equatable {
    /// 读一个 auth.json。Codex 自己维护续期，凭据长期有效 —— 推荐路径。
    case authFile(URL)
    /// 用户直接粘的 access_token。约 10 天过期，本程序不续期。
    case token(String, accountID: String?)
}

enum CodexAuthStore {

    /// 默认的 Codex 家目录。CODEX_HOME 优先，跟 Codex 自己的查找规则保持一致。
    static var defaultHomeDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static var defaultAuthFileURL: URL {
        defaultHomeDirectory.appendingPathComponent("auth.json")
    }

    /// 本机装没装 Codex（有 ~/.codex 目录就算装了）
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: defaultHomeDirectory.path)
    }

    /// 本机的默认凭据是否可读（用于「一键导入本机 Codex」）
    static var hasDefaultCredential: Bool {
        load(from: defaultAuthFileURL) != nil
    }

    /// 从指定路径读凭据。文件不存在、没有 access_token 都返回 nil。
    static func load(from url: URL) -> CodexAuth? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(root: root)
    }

    /// 按凭据来源解析。`token` 分支直接构造，不碰磁盘。
    static func resolve(_ credential: CodexCredential) -> CodexAuth? {
        switch credential {
        case .authFile(let url):
            return load(from: url)
        case .token(let token, let accountID):
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // 粘贴的 token 也解一下 JWT，好把套餐和过期时间显示出来
            return makeAuth(token: trimmed, accountID: accountID)
        }
    }

    // MARK: - 解析

    private static func parse(root: [String: Any]) -> CodexAuth? {
        let tokens = root["tokens"] as? [String: Any] ?? [:]
        guard let token = (tokens["access_token"] as? String) ?? (root["access_token"] as? String),
              !token.isEmpty else {
            return nil
        }
        let accountID = (tokens["account_id"] as? String) ?? (root["account_id"] as? String)
        return makeAuth(token: token, accountID: accountID)
    }

    private static func makeAuth(token: String, accountID: String?) -> CodexAuth {
        // 套餐类型和过期时间都在 JWT 里，解出来给界面用
        let claims = decodeJWTPayload(token)
        let authBlock = claims?["https://api.openai.com/auth"] as? [String: Any]

        var expiresAt: Date?
        if let exp = claims?["exp"] as? Double {
            expiresAt = Date(timeIntervalSince1970: exp)
        }

        return CodexAuth(
            accessToken: token,
            accountID: accountID,
            planType: authBlock?["chatgpt_plan_type"] as? String,
            expiresAt: expiresAt
        )
    }

    /// 解 JWT 的 payload 段。
    /// 刻意不校验签名 —— 我们不是拿它做鉴权（鉴权由服务端做），
    /// 只是想把套餐类型和过期时间显示出来。
    private static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}
