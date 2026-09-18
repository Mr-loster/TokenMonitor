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

        do {
            return try JSONDecoder().decode([APIAccount].self, from: data)
        } catch {
            // 这里**绝不能**静默返回空数组。
            //
            // 以前就是这个行为：只要有一个字段解不出来（比如新版本加了非可选字段，
            // 而用户的 accounts.json 是旧版本写的），整个账号列表会变成空 ——
            // 用户看到的是「我的账号全没了」，而且没有任何提示。
            //
            // 现在：留一条日志、把坏文件备份下来、仍然返回空数组让程序能启动，
            // 但至少事后能查、能找回。
            DebugLog.write("账号列表解码失败：\(error)。原文件已备份到 accounts.json.broken")
            if let data = try? Data(contentsOf: fileURL) {
                AppPaths.write(data, to: backupURL)
            }
            return []
        }
    }

    func save(_ accounts: [APIAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else {
            DebugLog.write("账号列表编码失败，本次未保存")
            return
        }
        AppPaths.write(data, to: fileURL)
    }
}
