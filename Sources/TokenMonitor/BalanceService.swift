import Foundation

enum BalanceError: LocalizedError {
    case invalidKey
    case network(String)
    case decoding
    case rateLimited
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "API Key 无效或已失效"
        case .network(let message): return "网络错误：\(message)"
        case .decoding: return "返回数据解析失败"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .http(let code): return "服务端返回 \(code)"
        }
    }

    /// 值不值得重试。
    /// Key 无效、解析失败、被限流 —— 重试多少次结果都一样；
    /// 只有网络抖动和服务端 5xx 是临时故障，值得再试一次。
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .http(let code): return code >= 500
        case .invalidKey, .decoding, .rateLimited: return false
        }
    }
}

/// DeepSeek 余额接口返回体
/// GET https://api.deepseek.com/user/balance
struct DeepSeekBalancePayload: Decodable {
    let isAvailable: Bool
    let balanceInfos: [Info]

    struct Info: Decodable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    enum CodingKeys: String, CodingKey {
        case isAvailable = "is_available"
        case balanceInfos = "balance_infos"
    }
}

final class BalanceService {
    static let shared = BalanceService()

    private let session: URLSession
    /// 总尝试次数（含首次）
    private let maxAttempts = 2
    /// 两次尝试之间的等待
    private let retryDelay: Duration = .milliseconds(1500)

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// 查询单个账号余额。网络抖动或服务端 5xx 会自动重试一次。
    func fetchBalance(apiKey: String, provider: Provider) async throws -> DeepSeekBalancePayload {
        var lastError: Error = BalanceError.network("未知错误")

        for attempt in 0..<maxAttempts {
            do {
                return try await performFetch(apiKey: apiKey, provider: provider)
            } catch {
                lastError = error
                let retryable = (error as? BalanceError)?.isRetryable ?? true
                guard retryable, attempt < maxAttempts - 1 else { throw error }
                try? await Task.sleep(for: retryDelay)
            }
        }
        throw lastError
    }

    /// 校验 Key 是否可用。给「测试连接」按钮用，不写入任何状态。
    /// 返回 nil 表示可用，否则返回失败原因。
    func validate(apiKey: String, provider: Provider) async -> String? {
        do {
            _ = try await fetchBalance(apiKey: apiKey, provider: provider)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func performFetch(apiKey: String, provider: Provider) async throws -> DeepSeekBalancePayload {
        var request = URLRequest(url: provider.balanceEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // 余额是实时数据，别让中间层缓存
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BalanceError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BalanceError.network("无效响应")
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw BalanceError.invalidKey
        case 429:
            throw BalanceError.rateLimited
        default:
            throw BalanceError.http(http.statusCode)
        }

        guard let payload = try? JSONDecoder().decode(DeepSeekBalancePayload.self, from: data) else {
            throw BalanceError.decoding
        }
        return payload
    }
}
