import Foundation
import Security

/// 旧版的钥匙串存储，**只保留读取和删除，供一次性迁移用**，不再写入。
///
/// 弃用原因见 `CredentialStore` 的注释：钥匙串条目的访问控制绑定创建它的程序的
/// 代码签名标识，ad-hoc 签名每次编译都会变，于是每次都弹密码框。
///
/// 迁移完成后这个文件就是死代码了。留着是为了让「从旧版本升上来」这条路径可走 ——
/// 直接删掉的话，老用户升级后 Key 就找不回来了。
enum LegacyKeychain {
    private static let service = "com.hdc.tokenmonitor.apikey"

    /// 读取会同步等待系统授权（弹一次密码框）。调用方注意别放在主线程上。
    static func read(for accountID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for accountID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.uuidString
        ]
        SecItemDelete(query as CFDictionary)
    }
}
