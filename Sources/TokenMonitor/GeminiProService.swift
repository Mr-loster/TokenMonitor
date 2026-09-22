import Foundation

// MARK: - 数据模型

/// Gemini Pro 额度窗口，与 CodexRateWindow 对齐。
struct GeminiRateWindow: Equatable {
    var usedPercent: Double
    /// 窗口长度（秒）。服务端不给时为 0，这时靠 `windowRaw` 兜底显示。
    var windowSeconds: Double
    /// 服务端给的原始窗口标识（实测是自由文本，如 `5h` / `weekly`）
    var windowRaw: String?
    var resetsAt: Date?

    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }

    /// 有没有拿到足够的信息把窗口说清楚。
    /// 秒数和原始标识都拿不到时，界面不该硬凑一个「额度窗口」出来。
    var hasWindowInfo: Bool {
        windowSeconds > 0 || !(windowRaw ?? "").isEmpty
    }

    var windowLabel: String {
        if windowSeconds > 0 {
            let hours = windowSeconds / 3600
            if hours < 1 { return "\(Int((windowSeconds / 60).rounded())) 分钟窗口" }
            if hours < 24 { return "\(Int(hours.rounded())) 小时窗口" }
            let days = hours / 24
            if days < 10 { return "\(Int(days.rounded())) 天窗口" }
            return "\(Int((days / 30).rounded())) 个月窗口"
        }
        if let raw = windowRaw, !raw.isEmpty { return "\(raw) 窗口" }
        return "额度窗口"
    }
}

struct GeminiProUsage: Equatable {
    /// 短窗口（如 5 小时）。没有短窗口时是唯一那个。
    var primary: GeminiRateWindow?
    /// 长窗口（如每周）。只有多窗口套餐才有。
    var secondary: GeminiRateWindow?
    /// 服务端明确判定额度已耗尽
    var limitReached: Bool
    var fetchedAt: Date
}

// MARK: - 错误

enum GeminiProError: LocalizedError, Equatable {
    case notRunning
    case noPort
    case noCSRFToken
    case probeFailed
    /// 读不到 Google 登录凭据、或续期失败。云端那条路的前提。
    case credentials(GeminiOAuthError)
    case network(String)
    case unauthorized
    case http(Int)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notRunning:   return "未检测到 Antigravity"
        case .noPort:       return "找不到 Antigravity 监听端口"
        case .noCSRFToken:  return "无法获取 CSRF Token"
        case .probeFailed:  return "无法读取 Antigravity 的运行状态"
        case .credentials(let e): return e.errorDescription
        case .network(let s): return "连不上额度服务 (\(s))"
        case .unauthorized: return "额度服务拒绝了请求"
        case .http(let c):  return "额度服务返回 HTTP \(c)"
        case .decoding:     return "额度服务返回了预期之外的内容"
        }
    }

    var suggestion: String {
        switch self {
        case .notRunning:
            return "本机既没有可用的登录凭据，也没有检测到 Antigravity 在运行。\n\n"
                + "打开一次 Antigravity（桌面版或 CLI）登录，之后即使关掉它也能读额度。"
        case .noPort:
            return "Antigravity 进程在跑，但读不到它的监听端口。请重启 Antigravity 后重试。"
        case .noCSRFToken:
            return "CLI 模式下的 language_server 不对外暴露 CSRF Token，这条本地路走不通。\n\n"
                + "请确认 Antigravity 已登录，程序会改走云端读取。"
        case .probeFailed:
            return "系统拒绝了「列出进程」（ps 被拦下），同时也读不到 Antigravity 的日志。\n\n"
                + "如果 Antigravity 确实在运行，请检查是否开了什么安全软件在拦截进程枚举。"
        case .credentials(let e):
            return e.suggestion
        case .network(let detail):
            return "请求没发出去或超时。检查网络 / 代理后重试。\n\n底层报错：\(detail)"
        case .unauthorized:
            return "登录状态可能已失效。打开一次 Antigravity 重新登录即可。"
        case .http:
            return "额度服务返回了非预期的状态码。请确认版本兼容性。"
        case .decoding:
            return "响应不是预期的结构。Google 的接口可能已变化。"
        }
    }
}

// MARK: - 进程探测

/// 探测本机运行的 Antigravity 语言服务器，提取端口和 CSRF Token。
///
/// 实测（Antigravity 2.14）它这样启动：
/// ```
/// language_server --standalone --override_ide_name antigravity --subclient_type hub
///   --https_server_port 0 --csrf_token <uuid> --app_data_dir antigravity ...
/// ```
/// 注意 `--https_server_port 0` —— 端口是**动态分配**的，进程参数里拿不到真实值，
/// 必须再用 lsof 把监听端口找出来。
///
/// 另外 `ps` 并不是在所有环境下都能用（沙箱、MDM 限制下会被系统拦掉）。
/// 这时退回读 Antigravity 自己的日志（见 `serverInfoFromLogs`），
/// 那里面既有 CSRF Token 也有它报出来的真实端口，反而比 `ps` 更直接。
enum AntigravityProbe {

    struct ServerInfo: Equatable, Sendable {
        var pid: Int32
        /// `--https_server_port` 显式指定的端口。传 0（动态）时为 nil。
        var httpsPort: Int?
        /// 候选端口：进程参数给的在前，lsof 发现的在后，已去重。
        var ports: [Int]
        var csrfToken: String
    }

    enum Detection: Equatable, Sendable {
        case found(ServerInfo)
        case notRunning
        /// 进程在跑，但一个监听端口都没找到 —— 和「没在跑」是两回事，
        /// 提示语也不一样，不能混成一个。
        case noPort
        /// 连「本机有哪些进程」都读不到（`ps` 被系统拦下），日志也没有可用线索。
        /// 这跟「Antigravity 没开」是两回事，报错了要能区分，
        /// 否则用户会去反复重启一个本来就正常的应用。
        case probeFailed
    }

    /// 探测本机的 Antigravity 语言服务器。
    ///
    /// 两条路径：
    /// 1. **进程扫描**：`ps` 列出全部进程，找 `language_server`（桌面版 fork 的）
    ///    或 `agy`（Antigravity CLI —— 它内嵌了 language_server，进程名就是 agy）。
    ///    端口靠 `lsof` 发现。
    /// 2. **日志兜底**：`ps` 起不来（沙箱、MDM 限制）时，读 Antigravity 自己写的日志。
    ///    桌面版在 `~/Library/Logs/Antigravity/main.log`，CLI 在
    ///    `~/.gemini/antigravity-cli/log/cli-*.log`。
    ///
    /// ⚠️ 这条路**只覆盖「桌面版在跑」的情况**。CLI 模式下 language_server 的
    /// CSRF token 只存在进程内存里，外部读不到（环境变量里没有、日志里也不记），
    /// 所以即使探测到了端口也调不通。CLI / Gemini 桌面版的额度走 `GeminiCloudQuota`
    /// 那条云端路径，见 `GeminiProService.fetch()`。
    ///
    /// **会起 `ps` / `lsof` 子进程并同步等待**，不要在主线线程或 SwiftUI 的 body 里调。
    static func detect() -> Detection {
        if let processes = listProcesses() {
            var sawLanguageServer = false
            for (pid, command) in processes {
                guard isAntigravityLanguageServer(command) else { continue }
                sawLanguageServer = true

                let token = extractCSRFToken(from: command) ?? ""
                let hinted = extractPort(from: command)

                var ports: [Int] = []
                if let hinted { ports.append(hinted) }
                ports.append(contentsOf: discoverPorts(pid: pid))

                var seen = Set<Int>()
                let unique = ports.filter { $0 > 0 && seen.insert($0).inserted }
                guard !unique.isEmpty else { continue }

                return .found(ServerInfo(pid: pid,
                                         httpsPort: hinted,
                                         ports: unique,
                                         csrfToken: token))
            }

            // `ps` 能用且没找到 Antigravity 相关进程 —— 那就是真的没在跑。
            // 不必再去翻日志：如果桌面版和 CLI 都没起 `language_server`/`agy` 进程，
            // 日志里也不会有新鲜的端口信息。
            return sawLanguageServer ? .noPort : .notRunning
        }

        // `ps` 起不来（沙箱、MDM 限制）。退回读 Antigravity 自己的日志：
        // 里面的信息其实比 ps 更直接 —— 端口是它自己写下来的准确值，不用在一堆候选里试。
        if let info = serverInfoFromLogs() { return .found(info) }
        return .probeFailed
    }

    /// 本机是否有 Antigravity 语言服务器在跑。只判断「在不在」，不碰端口。
    static var isRunning: Bool {
        if let processes = listProcesses() {
            return processes.contains { isAntigravityLanguageServer($0.1) }
        }
        return logsSuggestRunning()
    }

    // MARK: - 日志兜底（ps 不可用时）

    /// Antigravity 的日志目录。
    /// 默认 `~/Library/Logs/Antigravity`；环境变量可覆盖，便于日志被重定向到别处的安装方式。
    private static var logDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TOKENMONITOR_ANTIGRAVITY_LOG_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Antigravity", isDirectory: true)
    }

    /// `language_server.log` 多久没动静就认为语言服务器已经不在了。
    /// 它在运行期间是持续写入的（CDP 探测、HTTP 调用都会记一行），所以 mtime 是相当可靠的存活信号。
    private static let logLivenessWindow: TimeInterval = 10 * 60

    private static func logsSuggestRunning() -> Bool {
        // 桌面版：language_server.log 在运行期间是持续写入的
        let desktopLog = logDirectory.appendingPathComponent("language_server.log")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: desktopLog.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < logLivenessWindow {
            return true
        }
        // CLI：glog 按次启动分文件写（cli-20260922_143341.log），看最新那个的 mtime
        if let modified = latestLogModification(in: cliLogDirectory),
           Date().timeIntervalSince(modified) < logLivenessWindow {
            return true
        }
        return false
    }

    /// Antigravity CLI 的日志目录。CLI 走 glog，每次启动写一个新文件。
    private static var cliLogDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/log", isDirectory: true)
    }

    /// 目录下最新的一个 `.log` 文件的修改时间。
    private static func latestLogModification(in directory: URL) -> Date? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        var newest: Date?
        for name in names where name.hasSuffix(".log") {
            let path = directory.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }

    /// 从桌面版的 `main.log` 里抠出 CSRF Token 和 HTTPS 端口。两者都在同一份日志里：
    /// ```
    /// Spawning: .../language_server ... --https_server_port 0 --csrf_token <uuid> --app_data_dir antigravity ...
    /// [Auto-Restart] Port changed! Reloading all windows with URL: https://127.0.0.1:53098/
    /// ```
    /// 端口是**应用自己报出来的实际值**（`--https_server_port` 传的是 0），比 lsof 猜更准。
    ///
    /// ⚠️ 存活判断必须用**这份日志自己的** mtime，不能复用 `logsSuggestRunning()` ——
    /// 那个还会看 CLI 的日志目录。否则「CLI 在跑、桌面版早关了」的时候，
    /// 这里会把 main.log 里**过期**的端口和 CSRF token 当成有效值返回，
    /// 让调用方去连一个早就没人听的端口。
    private static func serverInfoFromLogs() -> ServerInfo? {
        let log = logDirectory.appendingPathComponent("main.log")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: log.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < logLivenessWindow else { return nil }
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return serverInfo(fromLogText: text)
    }

    /// 纯函数：把日志文本翻译成 `ServerInfo`。
    /// 从 `serverInfoFromLogs` 里抽出来是为了能拿固定文本直接验证 ——
    /// 不必依赖本机真的装着 Antigravity，也不必依赖 `ps` 在这台机器上能不能用。
    static func serverInfo(fromLogText text: String) -> ServerInfo? {
        // 逐行扫，只保留最后一次出现的值 —— 应用重启过的话，只有最后那条是有效的
        var token: String?
        var port: Int?
        for line in text.components(separatedBy: "\n") {
            if line.contains("Spawning:"), let value = extractFlag("--csrf_token", from: line) {
                token = value
            }
            if let value = extractLocalhostPort(from: line) { port = value }
        }

        guard let token, !token.isEmpty, let port else { return nil }
        // pid 在这里没有意义（日志里没记），调用方也不用它
        return ServerInfo(pid: 0, httpsPort: port, ports: [port], csrfToken: token)
    }

    // MARK: - 内部

    private static func listProcesses() -> [(Int32, String)]? {
        guard let output = run("/bin/ps", ["-ax", "-o", "pid=,command="]) else { return nil }

        var results: [(Int32, String)] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // 格式: "1234 /path/to/binary --args"
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            results.append((pid, String(parts[1])))
        }
        return results
    }

    /// 这条命令行是不是 Antigravity 的 language_server。
    ///
    /// 两种形态：
    /// - **桌面版**：Electron fork 出 `.../Antigravity.app/Contents/Resources/bin/language_server`，
    ///   命令行里同时有 `language_server` 和 `antigravity`。
    /// - **CLI**：`agy` 把 language_server 跑在**自己进程里**，进程名就是 `agy`，
    ///   命令行里根本不出现 `language_server` 字样 —— 只按关键词找是永远找不到它的。
    ///   实测 CLI 进程就是 `~/.local/bin/agy` 这一个词。
    private static func isAntigravityLanguageServer(_ command: String) -> Bool {
        let lower = command.lowercased()

        if lower.contains("language_server") || lower.contains("language-server") {
            // 桌面版的 language_server 一定带着 antigravity 的路径或 --app_data_dir
            return lower.contains("antigravity")
        }

        return isAntigravityCLI(command)
    }

    /// 是不是 Antigravity CLI 的可执行文件（`agy`）。
    ///
    /// 只认「命令行的第一个词就是 agy 本身」，不去全文搜 `agy` 子串 ——
    /// 那会把 `--some-flag=agy` 之类的东西一起捞进来。
    private static func isAntigravityCLI(_ command: String) -> Bool {
        let first = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .lowercased()
        guard let first else { return false }
        return first.hasSuffix("/agy") || first == "agy"
    }

    private static func extractCSRFToken(from command: String) -> String? {
        extractFlag("--csrf_token", from: command)
    }

    /// Antigravity 2.14 用的是 `--https_server_port`（实测传 0）。
    /// 早期分支/其他 IDE 用过 `--extension_server_port`，两个都认，取到就返回。
    private static func extractPort(from command: String) -> Int? {
        for flag in ["--https_server_port", "--extension_server_port"] {
            if let value = extractFlag(flag, from: command), let port = Int(value), port > 0 {
                return port
            }
        }
        return nil
    }

    private static func extractFlag(_ flag: String, from command: String) -> String? {
        guard let range = command.range(of: flag) else { return nil }
        let after = command[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let value = after.prefix(while: { !$0.isWhitespace })
        return value.isEmpty ? nil : String(value)
    }

    /// 从 `https://127.0.0.1:<port>/` 这种串里取端口。
    ///
    /// ⚠️ 别用 `line[range].filter(\.isNumber)` 这种写法：`range` 是**整个匹配**，
    /// 会把 IP 里的 `127`、`0`、`0`、`1` 一起算进去，
    /// `https://127.0.0.1:56871/` 会变成 `12700156871`，端口彻底错掉。
    /// 必须锚定冒号，只吃它后面连续的数字。
    private static let localhostURLPrefix = "https://127.0.0.1:"

    private static func extractLocalhostPort(from line: String) -> Int? {
        guard let range = line.range(of: localhostURLPrefix) else { return nil }
        let digits = line[range.upperBound...].prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let value = Int(digits), (1...65535).contains(value) else { return nil }
        return value
    }

    /// 通过 lsof 发现进程监听的所有 TCP 端口。
    /// 语言服务器会同时开 HTTPS（gRPC）和 HTTP 两个端口，两个都会出现在这里，
    /// 调用方逐个试即可 —— 对 HTTP 端口发 HTTPS 请求会立刻握手失败，代价很小。
    private static func discoverPorts(pid: Int32) -> [Int] {
        guard let output = run("/usr/sbin/lsof",
                               ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)"]) else { return [] }

        var ports: [Int] = []
        for line in output.components(separatedBy: "\n") {
            guard let portRange = line.range(of: #":(\d+)\s"#, options: .regularExpression) else { continue }
            let portStr = line[portRange]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if let port = Int(portStr), !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    /// 跑一个子进程并把 stdout 读成字符串。失败返回 nil。
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            // 先读干净管道再等退出：输出量大时管道缓冲区写满会让子进程卡死，
            // waitUntilExit 就永远不返回。
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - 响应解析

enum GeminiProParser {

    /// 解析 `RetrieveUserQuotaSummary` 或 `GetUserStatus` 的响应。
    static func parse(data: Data) throws -> GeminiProUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiProError.decoding
        }
        if let usage = parseQuotaSummary(root) { return usage }
        if let usage = parseUserStatus(root) { return usage }
        throw GeminiProError.decoding
    }

    // MARK: - RetrieveUserQuotaSummary
    //
    // Antigravity 2.14 的 proto（从语言服务器二进制里读出来的）：
    //
    //   RetrieveUserQuotaSummaryResponse { buckets[], groups[], description }
    //   QuotaSummaryGroup   { display_name, description, buckets[] }
    //   QuotaSummaryBucket  { bucket_id, display_name, description, window,
    //                         remaining_fraction, remaining_amount, disabled, reset_time }
    //
    // 注意 `window` 是**字符串**字段（服务端给自由文本），不是秒数。

    private static func parseQuotaSummary(_ root: [String: Any]) -> GeminiProUsage? {
        // Connect 的 JSON 编解码把消息包在 "response" 里；直接给裸结构时也能用
        let container = (root["response"] as? [String: Any]) ?? root

        let groups = (container["groups"] as? [[String: Any]])
            ?? (container["quota_groups"] as? [[String: Any]])
            ?? (container["quotaGroups"] as? [[String: Any]])

        if let groups, !groups.isEmpty {
            // 优先找明确叫 Gemini 的分组（同一个响应里通常还有 Claude 的分组）
            if let gemini = groups.first(where: { groupName($0)?.lowercased().contains("gemini") == true }),
               let usage = parseBuckets(buckets(in: gemini)) {
                return usage
            }
            // 没有 Gemini 分组时，退回到第一个能解析出窗口的分组
            for group in groups {
                if let usage = parseBuckets(buckets(in: group)) { return usage }
            }
        }

        // 有些版本只回顶层 buckets
        if let usage = parseBuckets(container["buckets"] as? [[String: Any]]) {
            return usage
        }
        return nil
    }

    private static func groupName(_ group: [String: Any]) -> String? {
        (group["displayName"] as? String)
            ?? (group["display_name"] as? String)
            ?? (group["name"] as? String)
            ?? (group["label"] as? String)
    }

    private static func buckets(in group: [String: Any]) -> [[String: Any]]? {
        (group["buckets"] as? [[String: Any]])
            ?? (group["windows"] as? [[String: Any]])
            ?? (group["rate_windows"] as? [[String: Any]])
    }

    private static func parseBuckets(_ buckets: [[String: Any]]?) -> GeminiProUsage? {
        guard let buckets, !buckets.isEmpty else { return nil }

        var windows: [GeminiRateWindow] = []
        var limitReached = false

        for bucket in buckets {
            // 被服务端标成 disabled 的桶对当前套餐不生效。
            // 把它算进「最紧张的那个」会凭空造出一个不存在的约束。
            if bucket["disabled"] as? Bool == true { continue }

            if let window = parseWindow(bucket) {
                windows.append(window)
                if window.remainingPercent <= 0 { limitReached = true }
            }
            if bucket["limit_reached"] as? Bool == true { limitReached = true }
            if let allowed = bucket["allowed"] as? Bool, !allowed { limitReached = true }
        }

        guard !windows.isEmpty else { return nil }

        // 按窗口长度排序，短窗口（如 5 小时）为 primary，长窗口（如每周）为 secondary
        windows.sort { $0.windowSeconds < $1.windowSeconds }

        return GeminiProUsage(
            primary: windows.first,
            secondary: windows.count > 1 ? windows[1] : nil,
            limitReached: limitReached,
            fetchedAt: Date()
        )
    }

    // MARK: - GetUserStatus（老接口，保留兼容）

    private static func parseUserStatus(_ root: [String: Any]) -> GeminiProUsage? {
        let container = (root["response"] as? [String: Any]) ?? root
        let rateLimit = (container["rate_limit"] as? [String: Any]) ?? container

        let primary = parseWindow(rateLimit["primary_window"] ?? rateLimit["primary"])
        let secondary = parseWindow(rateLimit["secondary_window"] ?? rateLimit["secondary"])

        guard primary != nil || secondary != nil else { return nil }

        var limitReached = false
        if let reached = rateLimit["limit_reached"] as? Bool { limitReached = reached }
        if let allowed = rateLimit["allowed"] as? Bool { limitReached = !allowed }

        return GeminiProUsage(
            primary: primary,
            secondary: secondary,
            limitReached: limitReached,
            fetchedAt: Date()
        )
    }

    // MARK: - 通用字段解析

    private static func parseWindow(_ value: Any?) -> GeminiRateWindow? {
        guard let dict = value as? [String: Any] else { return nil }

        // 已用百分比，按可信度依次尝试：
        //   remaining_fraction = 0.1445 → 剩余 14.45%（proto 里是 0…1 的比例）
        //   used_percent / usedPercent = 14.45
        //   fraction = 0.1445（已用比例）
        var used: Double?
        if let fraction = number(dict["remainingFraction"] ?? dict["remaining_fraction"]) {
            // 个别版本给的是百分比口径（>1）。>1 时按百分比理解，
            // 否则 (1 - 14.45) 会算出 -1345%，被夹成 0 后显示「剩余 100%」。
            let normalized = fraction > 1 ? fraction / 100 : fraction
            used = (1 - normalized) * 100
        } else if let u = number(dict["used_percent"] ?? dict["usedPercent"]) {
            used = u
        } else if let f = number(dict["fraction"]) {
            used = f * 100
        }
        guard let used else { return nil }
        let usedPercent = max(0, min(100, used))

        let raw = (dict["window"] as? String) ?? (dict["windowLabel"] as? String)

        return GeminiRateWindow(
            usedPercent: usedPercent,
            windowSeconds: windowSeconds(dict, raw: raw),
            windowRaw: raw,
            resetsAt: resetDate(dict)
        )
    }

    private static func windowSeconds(_ dict: [String: Any], raw: String?) -> Double {
        if let s = number(dict["limit_window_seconds"] ?? dict["windowSeconds"]), s > 0 { return s }
        if let m = number(dict["window_minutes"] ?? dict["windowMinutes"]), m > 0 { return m * 60 }
        if let h = number(dict["window_hours"] ?? dict["windowHours"]), h > 0 { return h * 3600 }
        if let s = number(dict["window_seconds"]), s > 0 { return s }
        if let raw { return duration(from: raw) }
        return 0
    }

    /// 把 `5h` / `weekly` / `7d` / `30m` 这类自由文本折算成秒数。
    /// 认不出来就返回 0 —— 界面会退化成显示原始标识，而不是编一个长度出来。
    private static func duration(from raw: String) -> Double {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()

        // 先认固定写法
        switch text {
        case "hourly", "1h":       return 3600
        case "daily", "1d", "24h": return 86_400
        case "weekly", "7d", "1w": return 7 * 86_400
        case "monthly", "30d":     return 30 * 86_400
        case "yearly", "1y":       return 365 * 86_400
        default: break
        }

        // 再把 `5-hour` / `30_minutes` 这类词形归一成 `5h` / `30m`，然后按「数字 + 单位」拆
        let normalized = text
            .replacingOccurrences(of: "hours", with: "h")
            .replacingOccurrences(of: "hour", with: "h")
            .replacingOccurrences(of: "days", with: "d")
            .replacingOccurrences(of: "day", with: "d")
            .replacingOccurrences(of: "weeks", with: "w")
            .replacingOccurrences(of: "week", with: "w")
            .replacingOccurrences(of: "minutes", with: "m")
            .replacingOccurrences(of: "minute", with: "m")
            .replacingOccurrences(of: "seconds", with: "s")
            .replacingOccurrences(of: "second", with: "s")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        guard let unit = normalized.last,
              let value = Double(normalized.dropLast()),
              value > 0 else { return 0 }

        switch unit {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        case "d": return value * 86_400
        case "w": return value * 7 * 86_400
        default:  return 0
        }
    }

    private static func resetDate(_ dict: [String: Any]) -> Date? {
        if let absolute = date(dict["resetTime"])
            ?? date(dict["reset_time"])
            ?? date(dict["reset_at"])
            ?? date(dict["resets_at"])
            ?? date(dict["resetAt"]) {
            return absolute
        }
        // 相对现在的秒数，是绝对时间缺失时的兜底
        if let after = number(dict["reset_after_seconds"] ?? dict["resetAfterSeconds"]) {
            return Date().addingTimeInterval(after)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let epoch = number(value) {
            // 毫秒时间戳的兜底：秒级时间戳要到公元 5138 年才超过 1e11
            return Date(timeIntervalSince1970: epoch > 1e11 ? epoch / 1000 : epoch)
        }
        guard let text = value as? String else { return nil }

        // proto 的 Timestamp 走 JSON 映射是 RFC3339 字符串，
        // 秒级（"2026-10-11T11:41:00Z"）和带小数秒的两种都见过，都得认。
        let plain = ISO8601DateFormatter()
        if let parsed = plain.date(from: text) { return parsed }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: text) { return parsed }
        if let epoch = Double(text) { return Date(timeIntervalSince1970: epoch) }
        return nil
    }
}

// MARK: - 请求

final class GeminiProService {
    static let shared = GeminiProService()

    private static let quotaSummaryPath = "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    private static let userStatusPath   = "exa.language_server_pb.LanguageServerService/GetUserStatus"

    /// 云端额度接口。桌面版的 language_server 内部调的就是它，
    /// 响应结构和本地那条路**完全一致**，所以解析器能直接复用。
    private static let cloudQuotaEndpoint =
        URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!

    private let session: URLSession

    /// 云端请求用的 session。本地那条要放行 `127.0.0.1` 的自签证书，这条**不要** ——
    /// 对着公网地址跳过证书校验等于自己拆掉 HTTPS。
    private let cloudSession: URLSession

    /// 上次调通的端口。语言服务器的端口是动态分配的，每次刷新都重新 lsof 太慢，
    /// 记住它先试，命中就省掉一轮探测。
    private var lastGoodPort: Int?

    init(timeout: TimeInterval = 8) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 本地语言服务器用自签证书，必须挂 delegate 放行。
        // session 要留成属性：每次请求新建 session 会把 delegate 一起丢掉。
        session = URLSession(configuration: config,
                             delegate: InsecureLocalhostDelegate(),
                             delegateQueue: nil)

        // 云端给宽一点：续期 + 查询可能跨两次请求，8 秒容易误判成网络故障。
        let cloudConfig = URLSessionConfiguration.ephemeral
        cloudConfig.timeoutIntervalForRequest = 20
        cloudConfig.timeoutIntervalForResource = 30
        cloudConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        cloudSession = URLSession(configuration: cloudConfig)
    }

    /// 取 Gemini Pro 额度。
    ///
    /// **先走云端，再退本地。** 顺序很重要：
    /// - 云端那条（`fetchViaCloud`）只依赖登录凭据，**不要求任何 Antigravity 进程在跑**。
    ///   用户关掉桌面版、只开着 Antigravity CLI 或 Gemini 桌面版时，只有这条路能出数。
    /// - 本地那条（`fetchViaLanguageServer`）要求 language_server 在跑，而且实际上必须是
    ///   **桌面版**启动的那种 —— CLI 模式下 CSRF token 只在进程内存里，外部拿不到。
    ///
    /// 所以本地那条现在只是兜底：万一凭据读不到、但桌面版正好开着。
    func fetch() async throws -> GeminiProUsage {
        do {
            return try await fetchViaCloud()
        } catch let cloudError {
            do {
                return try await fetchViaLanguageServer()
            } catch {
                // 两条都不通。报云端那个错 —— 它的提示更贴近「去登录一次」
                // 这种用户真正能执行的动作。
                throw cloudError
            }
        }
    }

    // MARK: - 云端直连

    /// 直接问 Google 云端要额度。
    ///
    /// 接口：`POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`，
    /// 带 `Authorization: Bearer <access token>`。返回结构：
    /// ```json
    /// { "groups": [ { "displayName": "Gemini Models",
    ///                 "buckets": [ { "bucketId": "gemini-5h", "window": "5h",
    ///                                "remainingFraction": 0.9048, "resetTime": "..." } ] } ] }
    /// ```
    /// 和本地 language_server 的响应同构，所以解析器直接复用 `GeminiProParser`。
    private func fetchViaCloud() async throws -> GeminiProUsage {
        let token: String
        do {
            token = try await GeminiOAuth.accessToken()
        } catch let error as GeminiOAuthError {
            // 转成 GeminiProError，让上层的错误处理（提示语、退避策略）能认出它
            throw GeminiProError.credentials(error)
        }

        var request = URLRequest(url: Self.cloudQuotaEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.httpBody = "{}".data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await cloudSession.data(for: request)
        } catch {
            throw GeminiProError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401, 403:  throw GeminiProError.unauthorized
            default:        throw GeminiProError.http(http.statusCode)
            }
        }

        return try GeminiProParser.parse(data: data)
    }

    // MARK: - 本地 language_server（兜底）

    private func fetchViaLanguageServer() async throws -> GeminiProUsage {
        // ps / lsof 都是同步等待的子进程，挪到后台线程，别卡住调用方（多半是主线程）
        let detection = await Task.detached(priority: .userInitiated) {
            AntigravityProbe.detect()
        }.value

        let server: AntigravityProbe.ServerInfo
        switch detection {
        case .found(let info): server = info
        case .notRunning:      throw GeminiProError.notRunning
        case .noPort:          throw GeminiProError.noPort
        case .probeFailed:     throw GeminiProError.probeFailed
        }

        // 语言服务器带 CsrfInterceptor，没有 token 一定被拒 —— 与其发一个注定失败的请求
        // 换回一句含糊的 401，不如在这里明确说是哪一环缺了。
        guard !server.csrfToken.isEmpty else { throw GeminiProError.noCSRFToken }

        var lastError: Error?
        for port in orderedPorts(server) {
            // 每个端口上先试 RetrieveUserQuotaSummary，失败再退到 GetUserStatus
            for path in [Self.quotaSummaryPath, Self.userStatusPath] {
                do {
                    let usage = try await request(port: port, csrfToken: server.csrfToken, path: path)
                    lastGoodPort = port
                    return usage
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError ?? GeminiProError.decoding
    }

    /// 校验连通性。返回 nil 表示可用，否则返回失败原因。
    func validate() async -> String? {
        do {
            _ = try await fetch()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 先试上次调通的端口，再试进程参数给的，最后才是 lsof 发现的其他端口。
    private func orderedPorts(_ server: AntigravityProbe.ServerInfo) -> [Int] {
        var ports: [Int] = []
        if let cached = lastGoodPort, server.ports.contains(cached) { ports.append(cached) }
        if let hinted = server.httpsPort, !ports.contains(hinted) { ports.append(hinted) }
        ports.append(contentsOf: server.ports.filter { !ports.contains($0) })
        return ports
    }

    private func request(port: Int, csrfToken: String, path: String) async throws -> GeminiProUsage {
        let url = URL(string: "https://127.0.0.1:\(port)/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = "{}".data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GeminiProError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200...299: break
            case 401, 403:  throw GeminiProError.unauthorized
            default:        throw GeminiProError.http(http.statusCode)
            }
        }

        return try GeminiProParser.parse(data: data)
    }
}

/// URLSession delegate：只放行 `127.0.0.1` 的自签证书，其他一律走默认校验。
private final class InsecureLocalhostDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
