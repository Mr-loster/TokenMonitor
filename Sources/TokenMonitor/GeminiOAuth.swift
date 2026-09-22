import AppKit
import Foundation
import Security

// MARK: - 凭据

/// Gemini Pro / Antigravity 的 Google OAuth 凭据。
///
/// 为什么需要它：额度其实可以**直接问 Google 云端要**
/// （`v1internal:retrieveUserQuotaSummary`），不必经过本机的 language_server。
/// 这一点很关键 —— 用户关掉 Antigravity 桌面版、只开 Antigravity CLI 或
/// Gemini 桌面版时，本地那条路要么没有 language_server，要么（CLI 模式下）
/// CSRF token 只存在进程内存里、外部拿不到，怎么都读不出额度。
struct GeminiCredentials: Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiry: Date?
    var authMethod: String?
    /// `id_token` 里的 `aud` —— 就是**签发这份凭据的 client id**。
    ///
    /// 本机二进制里躺着好几个 OAuth 客户端，拿错一个去续期会收到
    /// `invalid_client` / `unauthorized_client`。靠这个字段直接对号入座，
    /// 省掉一轮轮试错。
    var idTokenAudience: String?

    /// 还够不够用。留 60 秒余量，免得「刚好在过期那一刻」发出请求被 401。
    var isUsable: Bool {
        guard let expiry else { return true }
        return expiry.timeIntervalSinceNow > 60
    }
}

enum GeminiOAuthError: LocalizedError, Equatable {
    case notLoggedIn
    case noRefreshToken
    /// 本机找不到 Antigravity 的 OAuth 客户端凭据（拿不到就没法续期）。
    case clientCredentialsMissing
    case refreshRejected(String)
    case network(String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:            return "本机没有找到 Antigravity 的登录凭据"
        case .noRefreshToken:         return "凭据里没有 refresh token，无法自动续期"
        case .clientCredentialsMissing: return "读不到 Antigravity 的 OAuth 客户端信息"
        case .refreshRejected(let s): return "续期被 Google 拒绝（\(s)）"
        case .network(let s):         return "连不上 Google 的登录服务（\(s)）"
        case .malformed:              return "凭据文件的结构不是预期的"
        }
    }

    var suggestion: String {
        switch self {
        case .notLoggedIn:
            return "请打开一次 Antigravity（桌面版或 CLI）并登录，之后就能脱离它读取额度了。"
        case .noRefreshToken:
            return "请重新登录一次 Antigravity，让它写入一份完整的凭据。"
        case .clientCredentialsMissing:
            return "程序需要从本机的 Antigravity 二进制里读出它的 OAuth 客户端信息。\n\n"
                + "请确认 Antigravity（桌面版或 CLI）安装完整；装到非默认位置时可能读不到。"
        case .refreshRejected:
            return "登录状态可能已被撤销。请打开 Antigravity 重新登录。"
        case .network:
            return "检查网络或代理后重试。"
        case .malformed:
            return "Antigravity 版本可能变了。请反馈。"
        }
    }
}

// MARK: - 凭据读取

/// 读取本机 Antigravity 的 Google OAuth 凭据，必要时自动续期。
///
/// 两个来源，顺序固定：
/// 1. `~/.gemini/jetski-standalone-oauth-token` —— Antigravity **桌面版**写的 JSON 文件
/// 2. 登录钥匙串 `service=gemini / account=antigravity` —— Antigravity **CLI** 写的
///    值是 `go-keyring-base64:<base64 的 JSON>`，用 `security` 命令行看就是这个形态
///
/// **只读，不回写。** 续期拿到的新 access token 只留在内存里用。
/// 本程序唯一会写别人文件的地方是 Grok 的续期（它的 refresh token 会轮换，
/// 不写回就没法用）；Google 这边不轮换 refresh token，所以没必要去动用户的凭据。
enum GeminiOAuth {

    /// 桌面版凭据文件。
    static var tokenFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENMONITOR_GEMINI_TOKEN_FILE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/jetski-standalone-oauth-token")
    }

    /// 内存里缓存一份，避免每次刷新都去读盘 / 开钥匙串。
    private static let cacheLock = NSLock()
    private static var cached: GeminiCredentials?

    /// 拿一个能用的 access token。过期就自动续期。
    static func accessToken() async throws -> String {
        let credentials: GeminiCredentials
        do {
            credentials = try load()
        } catch {
            throw error
        }

        if credentials.isUsable { return credentials.accessToken }
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw GeminiOAuthError.noRefreshToken
        }

        let refreshed = try await refresh(refreshToken: refreshToken,
                                          audience: credentials.idTokenAudience)
        store(refreshed)
        return refreshed.accessToken
    }

    /// 读凭据：先文件，再钥匙串。
    static func load() throws -> GeminiCredentials {
        cacheLock.lock()
        if let cached { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        if let fromFile = credentialsFromFile() {
            store(fromFile)
            return fromFile
        }
        if let fromKeychain = credentialsFromKeychain() {
            store(fromKeychain)
            return fromKeychain
        }
        throw GeminiOAuthError.notLoggedIn
    }

    /// 本机有没有可用的登录凭据。
    /// **不校验是否已过期** —— 只要拿得到 refresh token 就能续期，照样算可用。
    ///
    /// 界面用它决定要不要提示「导入本机 Gemini Pro」。注意它和
    /// 「Antigravity 进程在不在跑」是两回事：有凭据就能读额度，不需要进程。
    static var hasCredentials: Bool {
        (try? load()) != nil
    }

    private static func store(_ credentials: GeminiCredentials) {
        cacheLock.lock()
        cached = credentials
        cacheLock.unlock()
    }

    /// 清掉缓存，强制下次重新读盘。设置页「重新检测」用得上。
    static func invalidateCache() {
        cacheLock.lock()
        cached = nil
        cacheLock.unlock()
    }

    // MARK: - 文件

    private static func credentialsFromFile() -> GeminiCredentials? {
        guard let data = try? Data(contentsOf: tokenFileURL) else { return nil }
        return parse(credentialsJSON: data)
    }

    // MARK: - 钥匙串

    /// Antigravity CLI 把凭据存在登录钥匙串里。
    /// 用 `security find-generic-password -s gemini -a antigravity -w` 能直接看到。
    private static func credentialsFromKeychain() -> GeminiCredentials? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }

        // 值可能是裸 JSON，也可能是 `go-keyring-base64:` 前缀的 base64。
        if let parsed = parse(credentialsJSON: data) { return parsed }

        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "go-keyring-base64:"
        guard text.hasPrefix(prefix) else { return nil }
        let base64 = String(text.dropFirst(prefix.count))
        guard let decoded = Data(base64Encoded: base64) else { return nil }
        return parse(credentialsJSON: decoded)
    }

    // MARK: - 解析

    /// 解析凭据 JSON。桌面版文件和钥匙串里存的是**同一个结构**：
    /// ```json
    /// { "token": { "access_token": "...", "refresh_token": "...", "expiry": "..." },
    ///   "auth_method": "consumer", "id_token": "..." }
    /// ```
    /// 也容忍 token 字段直接铺在顶层（老版本）。
    static func parse(credentialsJSON data: Data) -> GeminiCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let token = (root["token"] as? [String: Any]) ?? root

        guard let accessToken = token["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }

        return GeminiCredentials(
            accessToken: accessToken,
            refreshToken: token["refresh_token"] as? String,
            expiry: parseExpiry(token["expiry"] ?? token["expires_at"]),
            authMethod: root["auth_method"] as? String,
            idTokenAudience: audience(fromIDToken: root["id_token"] as? String)
        )
    }

    /// 从 JWT 形式的 `id_token` 里读出 `aud`。
    ///
    /// 只解 payload 段、**不验签** —— 这个值只用来挑「该用哪个 OAuth 客户端」，
    /// 不当作身份凭证，所以没必要引入验签。
    private static func audience(fromIDToken idToken: String?) -> String? {
        guard let idToken else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["aud"] as? String
    }

    /// `expiry` 是带时区偏移的 ISO8601（如 `2026-09-22T15:30:23.452322+08:00`），
    /// 也见过不带小数秒的写法，两种都要认。
    private static func parseExpiry(_ value: Any?) -> Date? {
        if let epoch = value as? Double { return Date(timeIntervalSince1970: epoch) }
        guard let text = value as? String else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        return nil
    }

    // MARK: - 续期

    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    /// 已经试通过的客户端凭据。配错会拿到 `invalid_client`，试对一次就记住，
    /// 之后不再每次去扫二进制。
    private static let clientLock = NSLock()
    private static var workingClient: GeminiOAuthClient.Credentials?

    /// 用 refresh token 换一个新的 access token。
    /// Google 对这类客户端**不轮换 refresh token**，所以换完不必回写。
    static func refresh(refreshToken: String, audience: String? = nil) async throws -> GeminiCredentials {
        let candidates = candidateClients(audience: audience)
        guard !candidates.isEmpty else { throw GeminiOAuthError.clientCredentialsMissing }

        var lastError = GeminiOAuthError.clientCredentialsMissing
        for client in candidates {
            do {
                let credentials = try await refresh(refreshToken: refreshToken, using: client)
                rememberWorkingClient(client)
                return credentials
            } catch let error as GeminiOAuthError {
                lastError = error
                // 只有「这个客户端不被认」才值得换下一组。网络问题、refresh token 被撤销
                // 这些换多少个客户端结果都一样，直接抛出去。
                if case .refreshRejected(let detail) = error, isClientMismatch(detail) {
                    continue
                }
                throw error
            }
        }
        throw lastError
    }

    /// 记住试通的客户端。
    /// 单独抽成同步函数 —— 直接在 `async` 里 `lock()/unlock()` 会被 Swift 6
    /// 判成错误（`NSLock` 这两个方法标了 `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`）。
    private static func rememberWorkingClient(_ client: GeminiOAuthClient.Credentials) {
        clientLock.lock()
        workingClient = client
        clientLock.unlock()
    }

    /// 这个错误是不是「客户端不对」。
    ///
    /// - `invalid_client`：这个 id/secret 组合根本不成立
    /// - `unauthorized_client`：组合成立，但这个 client 不允许用 refresh 换 token
    ///
    /// 两种都说明该换下一组试。**`invalid_grant` 不算** —— 那是 refresh token 自己
    /// 失效了（被撤销 / 换过账号），换多少个客户端都一样。
    private static func isClientMismatch(_ detail: String) -> Bool {
        detail.contains("invalid_client") || detail.contains("unauthorized_client")
    }

    /// 候选客户端，按命中概率排序：
    /// 1. client id 与 `id_token` 的 `aud` 相同的那组 —— 凭据就是它签的，基本一击即中
    /// 2. 上次试通的
    /// 3. 其余全部（兜底：凭据里没有 `id_token` 时只能挨个试）
    private static func candidateClients(audience: String?) -> [GeminiOAuthClient.Credentials] {
        var list: [GeminiOAuthClient.Credentials] = []
        func append(_ candidate: GeminiOAuthClient.Credentials) {
            if !list.contains(candidate) { list.append(candidate) }
        }

        let discovered = GeminiOAuthClient.discover()
        if let audience {
            for candidate in discovered where candidate.clientID == audience { append(candidate) }
        }
        clientLock.lock()
        let remembered = workingClient
        clientLock.unlock()
        if let remembered { append(remembered) }
        for candidate in discovered { append(candidate) }
        return list
    }

    private static func refresh(refreshToken: String,
                                using client: GeminiOAuthClient.Credentials) async throws -> GeminiCredentials {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id",     value: client.clientID),
            URLQueryItem(name: "client_secret", value: client.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type",    value: "refresh_token"),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GeminiOAuthError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // Google 在错误体里给 `error` / `error_description`
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0?["error"] as? String) } ?? "HTTP \(http.statusCode)"
            throw GeminiOAuthError.refreshRejected(detail)
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String, !accessToken.isEmpty else {
            throw GeminiOAuthError.malformed
        }

        let expiresIn = (root["expires_in"] as? Double) ?? 3600
        return GeminiCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiry: Date().addingTimeInterval(expiresIn),
            authMethod: nil
        )
    }
}

// MARK: - OAuth 客户端凭据

/// Antigravity 的 Google OAuth 客户端凭据（client id + secret）。
///
/// **刻意不写死在源码里。** 这两个值是 Google 给「已安装应用」的客户端凭据，
/// 官方文档说这类 secret 不算机密（它无法用来冒充服务端），Antigravity 自己也
/// 是明文带着它们跑。但 GitHub 的 secret scanning 只认 `GOCSPX-` 这个前缀，
/// 一律判成泄露的密钥并**直接拒绝推送**（实测被拦过）。
///
/// 与其去申请例外、或者把字符串拆开藏起来，不如运行时从**用户本机的 Antigravity
/// 二进制**里读 —— 那些值本来就在那儿，而且要用它的凭据，就说明这台机器上一定
/// 装着它。这样仓库里干干净净，也不依赖某个会变的具体值。
enum GeminiOAuthClient {

    struct Credentials: Equatable {
        var clientID: String
        var clientSecret: String
    }

    private static let cacheLock = NSLock()
    private static var cached: [Credentials]?

    /// 扫描本机的 Antigravity 二进制，列出所有可用的客户端凭据组合。
    /// 结果会缓存 —— 二进制有 150MB，不该每次刷新都扫。
    static func discover() -> [Credentials] {
        cacheLock.lock()
        if let cached { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        var result: [Credentials] = []
        for binary in candidateBinaries {
            guard let data = try? Data(contentsOf: binary, options: .mappedIfSafe) else { continue }
            let ids = findClientIDs(in: data)
            let secrets = findSecrets(in: data)
            guard !ids.isEmpty, !secrets.isEmpty else { continue }
            for id in ids {
                for secret in secrets {
                    let pair = Credentials(clientID: id, clientSecret: secret)
                    if !result.contains(pair) { result.append(pair) }
                }
            }
            if !result.isEmpty { break }
        }

        cacheLock.lock()
        cached = result
        cacheLock.unlock()
        return result
    }

    /// 可能的二进制位置：桌面版的 language_server、CLI 的 `agy`。
    /// 两个都可能缺席（只装 CLI 或只装桌面版），所以都试。
    private static var candidateBinaries: [URL] {
        var urls: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") {
            urls.append(app.appendingPathComponent("Contents/Resources/bin/language_server"))
        }
        urls.append(URL(fileURLWithPath: "/Applications/Antigravity.app/Contents/Resources/bin/language_server"))
        let home = FileManager.default.homeDirectoryForCurrentUser
        urls.append(home.appendingPathComponent(".local/bin/agy"))
        return urls
    }

    // MARK: - 字节级扫描
    //
    // 二进制有 150MB，转成 String 再正则既慢又费内存。直接按字节扫，
    // 一遍过，只在命中时才拼字符串。

    private static let idSuffix = Array(".apps.googleusercontent.com".utf8)
    private static let secretPrefix = Array("GOCSPX-".utf8)
    /// `GOCSPX-` 后面固定 28 个字符。**必须按长度截断**，不能贪心吃到非字母为止 ——
    /// 实测两个 secret 在二进制里是**紧挨着**的（中间没有任何分隔符），
    /// 贪心会把它们连成一个无效的长串。
    private static let secretBodyLength = 28

    private static func findClientIDs(in data: Data) -> [String] {
        var results: [String] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var index = 0
            while index + idSuffix.count <= count {
                guard matches(base, at: index, needle: idSuffix) else { index += 1; continue }
                // 从后缀往前退，把 id 主体一起吃进来
                var start = index
                while start > 0, isClientIDByte(base[start - 1]) { start -= 1 }
                if start < index {
                    let slice = UnsafeBufferPointer(start: base + start, count: index - start)
                    if let window = String(bytes: slice, encoding: .utf8),
                       let id = trailingClientID(in: window),
                       !results.contains(id) {
                        results.append(id)
                    }
                }
                index += idSuffix.count
            }
        }
        return results
    }

    /// 从「后缀前面那一段」里切出真正的 client id。
    ///
    /// ⚠️ 不能简单地一路往前退到非字母为止：二进制里紧挨着的文本会被一起吃掉。
    /// 实测往前会多带进 `runtime` / `it` 这样的前缀字母，拿这种 id 去换 token
    /// 会直接 `invalid_client`。
    /// client id 的形状是固定的 `<10 位以上数字>-<小写字母数字>`，
    /// 所以按这个形状从**尾部**锚定取，而不是靠边界字符猜。
    private static let clientIDPattern = try! NSRegularExpression(
        pattern: #"([0-9]{10,}-[a-z0-9]+)$"#)

    private static func trailingClientID(in window: String) -> String? {
        let range = NSRange(window.startIndex..., in: window)
        guard let match = clientIDPattern.firstMatch(in: window, range: range),
              let matchRange = Range(match.range(at: 1), in: window) else { return nil }
        return String(window[matchRange])
    }

    private static func findSecrets(in data: Data) -> [String] {        var results: [String] = []
        let total = secretPrefix.count + secretBodyLength
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var index = 0
            while index + total <= count {
                guard matches(base, at: index, needle: secretPrefix) else { index += 1; continue }
                let body = UnsafeBufferPointer(start: base + index + secretPrefix.count,
                                               count: secretBodyLength)
                if body.allSatisfy(isSecretByte),
                   let text = String(bytes: body, encoding: .utf8) {
                    let full = "GOCSPX-" + text
                    if !results.contains(full) { results.append(full) }
                }
                index += total
            }
        }
        return results
    }

    private static func matches(_ base: UnsafePointer<UInt8>,
                                at offset: Int,
                                needle: [UInt8]) -> Bool {
        for (i, byte) in needle.enumerated() where base[offset + i] != byte { return false }
        return true
    }

    private static func isClientIDByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || isLower(byte) || isUpper(byte) || byte == UInt8(ascii: "-")
    }

    private static func isSecretByte(_ byte: UInt8) -> Bool {
        isClientIDByte(byte) || byte == UInt8(ascii: "_")
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 48 && byte <= 57 }
    private static func isLower(_ byte: UInt8) -> Bool { byte >= 97 && byte <= 122 }
    private static func isUpper(_ byte: UInt8) -> Bool { byte >= 65 && byte <= 90 }
}
