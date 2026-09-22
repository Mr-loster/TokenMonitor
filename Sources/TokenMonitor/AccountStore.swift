import Foundation

/// 账号列表的本地持久化（不含任何密钥，密钥在 CredentialStore）
final class AccountStore {
    private let fileURL = AppPaths.file("accounts.json")

    /// 解码失败时把坏文件另存一份，便于事后找回账号列表
    private var backupURL: URL {
        AppPaths.file("accounts.json.broken")
    }

    func load() -> [APIAccount] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        // 逐条解码：**任何一条坏掉都不该拖垮整个列表**。
        //
        // 以前是整数组一次性解码，只要有一个字段解不出来（例如新版本删掉了某个
        // 服务商、而旧文件里还留着它的账号），整个账号列表会变成空 ——
        // 用户看到的是「我的账号全没了」，而且没有任何提示。
        //
        // 现在用一个逐条兜底的包装：坏的那条丢掉并记日志，其余照常加载。
        if let accounts = try? JSONDecoder().decode([LenientAccount].self, from: data) {
            let good = accounts.compactMap(\.value)
            let dropped = accounts.count - good.count
            if dropped > 0 {
                DebugLog.write("账号列表：跳过 \(dropped) 条无法解码的记录（可能来自已移除的服务商）")
                backup(data)
            }
            return good
        }

        // 连数组结构都不对（文件被截断、手改坏了）—— 备份后返回空
        DebugLog.write("账号列表解码失败：整体结构不合法。原文件已备份到 accounts.json.broken")
        backup(data)
        return []
    }

    private func backup(_ data: Data) {
        AppPaths.write(data, to: backupURL)
    }

    func save(_ accounts: [APIAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else {
            DebugLog.write("账号列表编码失败，本次未保存")
            return
        }
        AppPaths.write(data, to: fileURL)
    }
}

/// 单条记录的容错解码器：解不出来就是 nil，不抛错。
private struct LenientAccount: Decodable {
    let value: APIAccount?

    init(from decoder: Decoder) throws {
        value = try? APIAccount(from: decoder)
    }
}
