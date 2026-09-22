import Foundation
import Darwin

// MARK: - 数据模型

/// Grok 的一个额度窗口。
///
/// 目前 xAI 只通过 `GetGrokCreditsConfig` 暴露**一个**周期（实测是 7 天的周额度），
/// 所以结构上保留成数组，将来它多给一个窗口也不用改模型。
struct GrokRateWindow: Equatable {
    /// 已用百分比 0…100
    var usedPercent: Double
    /// 周期长度（秒）。由周期起止时间算出，算不出来时为 0。
    var windowSeconds: Double
    var startsAt: Date?
    var resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    var hasWindowInfo: Bool { windowSeconds > 0 }

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

/// 周额度在各产品之间的拆分。
///
/// 服务端只给数字 id，**没有可读名字**（枚举定义在服务端下发的描述符里，
/// 本机二进制里查不到）。所以这里只对能确定的 id 起名，其余老实显示成「分项 N」，
/// 不编一个可能错的名字出来。
struct GrokProductUsage: Identifiable, Equatable {
    var id: Int
    var usedPercent: Double

    var displayName: String {
        switch id {
        case 1: return "API"
        case 2: return "Grok Build"
        default: return "分项 \(id)"
        }
    }
}

struct GrokUsage: Equatable {
    /// 服务端给的额度窗口，按长度升序（短的在前）。
    var windows: [GrokRateWindow]
    /// 周额度的产品拆分，按已用百分比降序
    var products: [GrokProductUsage]
    /// 服务端明确判定「已用完」
    var limitReached: Bool
    var fetchedAt: Date

    /// 最紧张的那个窗口 —— 它才是真正的约束
    var lowestRemaining: Double? {
        windows.map(\.remainingPercent).min()
    }
}

// MARK: - 错误

enum GrokError: LocalizedError, Equatable {
    case notInstalled
    case notLoggedIn
    case authFileMissing(String)
    case tokenExpired
    case refreshFailed(String)
    case unauthorized
    case blocked
    case network(String)
    case http(Int)
    case decoding
    case grpc(Int)

    var errorDescription: String? {
        switch self {
        case .notInstalled:    return "未检测到 Grok CLI"
        case .notLoggedIn:     return "Grok 未登录"
        case .authFileMissing: return "读不到 Grok 的 auth.json"
        case .tokenExpired:    return "Grok 登录凭据已过期"
        case .refreshFailed:   return "Grok 凭据续期失败"
        case .unauthorized:    return "登录状态被拒绝（401）"
        case .blocked:         return "请求被 grok.com 拦下"
        case .network:         return "连不上 grok.com"
        case .http(let code):  return "接口返回 HTTP \(code)"
        case .decoding:        return "接口返回了预期之外的内容"
        case .grpc(let code):  return "接口返回 gRPC 错误 \(code)"
        }
    }

    var suggestion: String {
        switch self {
        case .notInstalled:
            return "没找到 ~/.grok 目录。装了 Grok CLI 并登录之后，回「总览」点「导入」就能读额度。"
        case .notLoggedIn:
            return "auth.json 里没有可用的登录凭据。在终端里运行一次 `grok login` 登录即可。"
        case .authFileMissing(let path):
            return "这个账号指向的凭据文件不存在：\n\(path)\n\n路径写错了，或者那个 Grok 目录被删了。点「编辑」重新指定。"
        case .tokenExpired:
            return "access_token 已经过期，且没有可用的 refresh_token。\n\n在终端里运行一次 `grok` 或 `grok login` 让它重新登录，然后回来刷新。"
        case .refreshFailed(let detail):
            return "续期请求被拒绝，通常是 refresh_token 已失效。\n\n在终端里运行一次 `grok login` 重新登录。\n\n底层报错：\(detail)"
        case .unauthorized:
            return "凭据被服务端拒绝了。在终端里运行一次 `grok` 让它自动续期，或运行 `grok login` 重新登录。"
        case .blocked:
            return "grok.com 的边缘防护拦下了这次请求（通常是 Cloudflare 的风控）。稍后重试；若持续出现，说明接口的非浏览器访问方式已被封。"
        case .network(let detail):
            return "额度接口挂在 grok.com 上，本机当前访问不到它。需要能正常访问 grok.com（例如开启代理）之后才能读到额度。\n\n底层报错：\(detail)"
        case .http(let code):
            return "接口返回了非预期的状态码 \(code)。这个接口是非官方的，Grok 改版后可能已经变化。"
        case .decoding:
            return "响应不是预期的结构。这个接口是非官方的，Grok 改版后字段可能已经变化。"
        case .grpc(let code):
            return "gRPC 状态码 \(code)。这个接口是非官方的，Grok 改版后可能已经变化。"
        }
    }
}

// MARK: - 凭据

struct GrokAuth {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var email: String?
    var clientID: String?
    /// auth.json 顶层的那个键（形如 `https://auth.x.ai::<client_id>`）。
    /// 写回时必须用它定位条目，不能假设键名固定。
    var entryKey: String

    /// 提前 10 分钟算过期 —— 免得请求刚好卡在过期边界上失败。
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 600
    }
}

enum GrokAuthStore {

    /// Grok 家目录。`GROK_HOME` 优先，跟 CLI 自己的查找规则一致。
    static var homeDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["GROK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok", isDirectory: true)
    }

    static var defaultAuthFileURL: URL {
        homeDirectory.appendingPathComponent("auth.json")
    }

    /// 本机装没装 Grok CLI（有 ~/.grok 目录就算装了）
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: homeDirectory.path)
    }

    static var hasDefaultCredential: Bool {
        load(from: defaultAuthFileURL) != nil
    }

    /// 从指定路径读凭据。
    ///
    /// auth.json 的顶层是「issuer::client_id → 凭据」的映射，键名随登录方式变化，
    /// 所以不能写死键名，得扫一遍找那个带 `key` 的条目。
    static func load(from url: URL) -> GrokAuth? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(root: root)
    }

    static func parse(root: [String: Any]) -> GrokAuth? {
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String,
                  !token.isEmpty else { continue }

            // 过期时间优先读 JWT 里的 exp —— 它是权威值，而且不依赖日期格式。
            // 退回到 expires_at 字段（xAI 写的是 6 位小数秒，要单独处理）。
            var expires = jwtExpiry(token)
            if expires == nil, let text = entry["expires_at"] as? String {
                expires = parseISO8601(text)
            }

            return GrokAuth(
                accessToken: token,
                refreshToken: entry["refresh_token"] as? String,
                expiresAt: expires,
                email: entry["email"] as? String,
                clientID: entry["oidc_client_id"] as? String,
                entryKey: key
            )
        }
        return nil
    }

    /// 把续期后的 token 写回 auth.json。
    ///
    /// **这是本程序唯一会写别人文件的地方**，所以规矩定得很死：
    /// - 先加 `auth.json.lock` 的文件锁，跟 CLI 自己串行化（CLI 也用这个锁文件）
    /// - 拿到锁之后**重新读一遍盘**，只改 `key` / `refresh_token` / `expires_at` 三个字段，
    ///   其余原样保留 —— 绝不整份覆盖，免得抹掉 CLI 新写的别的状态
    /// - 原子替换（写临时文件再 rename），权限收到 600
    ///
    /// 失败不致命：调用方可以只用内存里的新 token 把这次请求跑完。
    @discardableResult
    static func save(_ auth: GrokAuth, accessToken: String, refreshToken: String?, expiresAt: Date?, to url: URL) -> Bool {
        let lockPath = url.deletingLastPathComponent().appendingPathComponent("auth.json.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer {
            if fd >= 0 { flock(fd, LOCK_UN); close(fd) }
        }

        // 锁到手之后重新读，避免用一份过期的快照做读-改-写
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var entry = root[auth.entryKey] as? [String: Any] else {
            DebugLog.write("Grok 凭据：写回前读不到 \(url.lastPathComponent)，跳过写回")
            return false
        }

        entry["key"] = accessToken
        if let refreshToken, !refreshToken.isEmpty { entry["refresh_token"] = refreshToken }
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            entry["expires_at"] = formatter.string(from: expiresAt)
        }
        root[auth.entryKey] = entry

        guard let encoded = try? JSONSerialization.data(withJSONObject: root,
                                                        options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent("auth.json.tm-write-\(UUID().uuidString.prefix(8))")
        do {
            try encoded.write(to: tmp)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            DebugLog.write("Grok 凭据：续期成功，已写回 auth.json")
            return true
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            DebugLog.write("Grok 凭据：写回失败 \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 日期

    /// 解 JWT 的 `exp`。不校验签名 —— 我们不是拿它做鉴权，只是想提前知道什么时候过期。
    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = object["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    /// xAI 的 `expires_at` 写成 `2026-09-22T06:51:17.928680Z`（**6 位**小数秒），
    /// `ISO8601DateFormatter` 带 `.withFractionalSeconds` 时对超过 3 位的小数秒
    /// 并不总能解析，所以先原样试、再把小数秒截到 3 位重试。
    static func parseISO8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }

        let trimmed = text.replacingOccurrences(of: #"\.(\d{3})\d+"#,
                                               with: ".$1",
                                               options: .regularExpression)
        if trimmed != text, let date = fractional.date(from: trimmed) { return date }
        return nil
    }
}

// MARK: - protobuf 读取

/// 极简 protobuf 读取器。只做我们需要的几件事：读 varint / fixed32 / 长度前缀块，
/// 认不出来的字段按 wire type 跳过。
///
/// 之所以手写而不是引入 swift-protobuf：这个接口是非官方的，连 `.proto` 都没有，
/// 字段号是从响应里逆出来的（见 `GrokUsageParser` 的注释），用不上代码生成。
struct ProtoReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { index >= bytes.count }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    mutating func readFixed32() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
        index += 4
        return value
    }

    mutating func readFloat() -> Float? {
        guard let raw = readFixed32() else { return nil }
        return Float(bitPattern: raw)
    }

    mutating func readBytes() -> [UInt8]? {
        guard let rawLength = readVarint(),
              let length = Int(exactly: rawLength),
              length >= 0,
              index + length <= bytes.count else { return nil }
        let out = Array(bytes[index..<(index + length)])
        index += length
        return out
    }

    /// 读字段头，返回 (字段号, wire type)
    mutating func readKey() -> (field: Int, wire: Int)? {
        guard let key = readVarint() else { return nil }
        return (Int(key >> 3), Int(key & 0x07))
    }

    mutating func skip(wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint() != nil
        case 1:
            guard index + 8 <= bytes.count else { return false }
            index += 8
            return true
        case 2: return readBytes() != nil
        case 5: return readFixed32() != nil
        default: return false
        }
    }
}

// MARK: - gRPC-web 分帧

enum GRPCWeb {

    struct Frame {
        var isTrailer: Bool
        var payload: [UInt8]
    }

    /// 把响应切成帧。每帧 5 字节头：1 字节标志 + 4 字节大端长度。
    /// 最高位为 1 表示这是 trailer（里面是 `grpc-status: N` 这种文本）。
    static func frames(from data: Data) -> [Frame] {
        let bytes = [UInt8](data)
        var out: [Frame] = []
        var i = 0
        while i + 5 <= bytes.count {
            let flag = bytes[i]
            let length = (Int(bytes[i + 1]) << 24)
                | (Int(bytes[i + 2]) << 16)
                | (Int(bytes[i + 3]) << 8)
                | Int(bytes[i + 4])
            i += 5
            guard length >= 0, i + length <= bytes.count else { break }
            out.append(Frame(isTrailer: (flag & 0x80) != 0,
                             payload: Array(bytes[i..<(i + length)])))
            i += length
        }
        return out
    }

    /// 从 trailer 里取 `grpc-status`
    static func status(inTrailer payload: [UInt8]) -> Int? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("grpc-status:") else { continue }
            let value = trimmed.dropFirst("grpc-status:".count)
                .trimmingCharacters(in: .whitespaces)
            return Int(value)
        }
        return nil
    }
}

// MARK: - 响应解析

/// `GetGrokCreditsConfig` 的响应解析。
///
/// 官方没有公开 `.proto`，字段号是从真实响应里逆出来的。实测（Grok Build CLI 1.0.40）：
///
/// ```
/// payload
/// └─ field 1 (message)              ← 配置本体
///    ├─ field 1 (fixed32 float)     ← 总已用百分比（0…100）
///    ├─ field 4 (message Timestamp) ← 当前周期开始
///    ├─ field 5 (message Timestamp) ← 重置时刻
///    ├─ field 7 (repeated message)  ← 产品拆分 { 1: id varint, 2: 百分比 fixed32 }
///    └─ field 8 (message)           ← 周期元数据（再嵌一套起止时间）
/// ```
///
/// 关键点：**百分比是 fixed32 浮点，不是 varint** —— 按 varint 读会读出天文数字。
/// Timestamp 是标准的 `{ 1: 秒 varint, 2: 纳秒 varint }`。
enum GrokUsageParser {

    static func parse(data: Data) throws -> GrokUsage {
        let frames = GRPCWeb.frames(from: data)

        // 服务端报错时数据帧是空的，错误只在 trailer 里
        if let trailer = frames.first(where: \.isTrailer),
           let status = GRPCWeb.status(inTrailer: trailer.payload),
           status != 0 {
            throw GrokError.grpc(status)
        }

        guard let payload = frames.first(where: { !$0.isTrailer })?.payload,
              !payload.isEmpty else {
            throw GrokError.decoding
        }

        // 顶层只认 field 1 那个消息
        var root = ProtoReader(payload)
        var configBytes: [UInt8]?
        scan: while let (field, wire) = root.readKey() {
            if field == 1, wire == 2 {
                configBytes = root.readBytes()
                break scan
            }
            guard root.skip(wire: wire) else { break scan }
        }
        guard let config = configBytes else { throw GrokError.decoding }

        var reader = ProtoReader(config)
        var usedPercent: Double?
        var startsAt: Date?
        var resetsAt: Date?
        var products: [GrokProductUsage] = []

        loop: while let (field, wire) = reader.readKey() {
            switch (field, wire) {
            case (1, 5):
                if let value = reader.readFloat() { usedPercent = Double(value) }
            case (4, 2):
                if let bytes = reader.readBytes() { startsAt = timestamp(bytes) }
            case (5, 2):
                if let bytes = reader.readBytes() { resetsAt = timestamp(bytes) }
            case (7, 2):
                if let bytes = reader.readBytes(), let product = productUsage(bytes) {
                    products.append(product)
                }
            default:
                guard reader.skip(wire: wire) else { break loop }
            }
        }

        guard let usedPercent else { throw GrokError.decoding }

        var seconds: Double = 0
        if let startsAt, let resetsAt {
            seconds = max(0, resetsAt.timeIntervalSince(startsAt))
        }

        // 已用完有两个信号：百分比见底，或服务端在明细里把它标满
        let limitReached = usedPercent >= 99.5

        return GrokUsage(
            windows: [GrokRateWindow(usedPercent: max(0, min(100, usedPercent)),
                                     windowSeconds: seconds,
                                     startsAt: startsAt,
                                     resetsAt: resetsAt)],
            products: products.sorted { $0.usedPercent > $1.usedPercent },
            limitReached: limitReached,
            fetchedAt: Date()
        )
    }

    /// `{ 1: 秒, 2: 纳秒 }`
    private static func timestamp(_ bytes: [UInt8]) -> Date? {
        var reader = ProtoReader(bytes)
        var seconds: Double?
        var nanos: Double = 0
        loop: while let (field, wire) = reader.readKey() {
            switch (field, wire) {
            case (1, 0):
                if let value = reader.readVarint() { seconds = Double(value) }
            case (2, 0):
                if let value = reader.readVarint() { nanos = Double(value) }
            default:
                guard reader.skip(wire: wire) else { break loop }
            }
        }
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds + nanos / 1_000_000_000)
    }

    /// `{ 1: id varint, 2: 百分比 fixed32 }`
    private static func productUsage(_ bytes: [UInt8]) -> GrokProductUsage? {
        var reader = ProtoReader(bytes)
        var id: Int?
        var percent: Double?
        loop: while let (field, wire) = reader.readKey() {
            switch (field, wire) {
            case (1, 0):
                if let value = reader.readVarint() { id = Int(value) }
            case (2, 5):
                if let value = reader.readFloat() { percent = Double(value) }
            default:
                guard reader.skip(wire: wire) else { break loop }
            }
        }
        guard let id, let percent else { return nil }
        return GrokProductUsage(id: id, usedPercent: max(0, min(100, percent)))
    }
}

// MARK: - 请求

final class GrokUsageService {
    static let shared = GrokUsageService()

    /// 非官方接口 —— Grok Build CLI 自己在用这个路径，但没有公开文档，改版可能变。
    static let creditsEndpoint = URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!
    static let tokenEndpoint = URL(string: "https://auth.x.ai/oauth2/token")!

    private let session: URLSession
    private let endpoint: URL

    init(endpoint: URL = GrokUsageService.creditsEndpoint, timeout: TimeInterval = 15) {
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    // MARK: - 取额度

    func fetch(credential: GrokCredential) async throws -> GrokUsage {
        switch credential {
        case .authFile(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw GrokError.authFileMissing(url.path)
            }
            var auth = GrokAuthStore.load(from: url)
            if auth == nil {
                // 目录在但文件读不出内容，区分「没装」和「没登录」
                throw GrokAuthStore.isInstalled ? GrokError.notLoggedIn : GrokError.notInstalled
            }
            if let current = auth, current.isExpired {
                auth = try await refreshed(current, fileURL: url)
            }
            guard let usable = auth else { throw GrokError.notLoggedIn }
            return try await request(accessToken: usable.accessToken)

        case .token(let token):
            return try await request(accessToken: token)
        }
    }

    /// 便利方法：读默认的 `~/.grok/auth.json`。
    func fetchDefault() async throws -> GrokUsage {
        try await fetch(credential: .authFile(GrokAuthStore.defaultAuthFileURL))
    }

    func validate(credential: GrokCredential) async -> String? {
        do {
            _ = try await fetch(credential: credential)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - 续期

    /// 用 refresh_token 换一个新的 access_token，并写回 auth.json。
    ///
    /// xAI 的 refresh_token **会轮换**（实测换一次就变一个），所以拿到新的必须写回，
    /// 否则下次续期会失败。写回失败不影响本次请求 —— 内存里的新 token 照样能用，
    /// 只是下次还得再续一次。
    private func refreshed(_ auth: GrokAuth, fileURL: URL) async throws -> GrokAuth {
        guard let refreshToken = auth.refreshToken, !refreshToken.isEmpty else {
            throw GrokError.tokenExpired
        }

        var body = "grant_type=refresh_token"
            + "&refresh_token=" + formEncode(refreshToken)
        if let clientID = auth.clientID, !clientID.isEmpty {
            body += "&client_id=" + formEncode(clientID)
        }

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(body.utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrokError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw GrokError.refreshFailed("HTTP \(http.statusCode) \(detail)")
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty else {
            throw GrokError.refreshFailed("响应里没有 access_token")
        }

        let newRefresh = object["refresh_token"] as? String
        let expiresIn = (object["expires_in"] as? Double) ?? 21_600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        var updated = auth
        updated.accessToken = accessToken
        if let newRefresh, !newRefresh.isEmpty { updated.refreshToken = newRefresh }
        updated.expiresAt = expiresAt

        // 写回是「尽力而为」：CLI 可能正开着，锁也可能拿不到。
        // 失败就只在内存里用，不让整个查询挂掉。
        let wrote = GrokAuthStore.save(updated,
                                       accessToken: accessToken,
                                       refreshToken: newRefresh,
                                       expiresAt: expiresAt,
                                       to: fileURL)
        DebugLog.write("Grok 凭据续期：拿到新 token（\(Int(expiresIn / 3600)) 小时），写回\(wrote ? "成功" : "失败")")
        return updated
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - 网络

    private func request(accessToken: String) async throws -> GrokUsage {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "x-grpc-web")
        request.setValue("https://grok.com", forHTTPHeaderField: "Origin")
        request.setValue("https://grok.com/?_s=usage", forHTTPHeaderField: "Referer")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // gRPC-web 的空请求体：标志字节 0 + 长度 0
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GrokError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299:
                break
            case 401:
                throw GrokError.unauthorized
            case 403:
                // Cloudflare 的风控也回 403。用 UA 区分：真·无权限是 JSON，
                // 风控回的是 `error code: 1010` 这种纯文本。
                let body = String(data: data, encoding: .utf8) ?? ""
                throw body.contains("error code:") ? GrokError.blocked : GrokError.unauthorized
            default:
                throw GrokError.http(http.statusCode)
            }
        }

        return try GrokUsageParser.parse(data: data)
    }

    /// grok.com 前面挂着 Cloudflare，默认的 `URLSession` UA 会被直接拦掉
    /// （回 `403 error code: 1010`）。必须带一个浏览器 UA。
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
}

/// 一次 Grok 额度查询用哪份凭据。
enum GrokCredential: Equatable {
    /// 读 Grok CLI 的 auth.json。**推荐**：CLI 自己维护续期，本程序只在过期时帮它续一次。
    case authFile(URL)
    /// 直接粘一个 access_token。只有 6 小时有效期，且无法续期 —— 仅作临时手段。
    case token(String)
}
