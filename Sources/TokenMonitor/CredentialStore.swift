import Foundation
import CryptoKit

/// 凭据读取结果。
///
/// 必须区分「没存过」和「解不开」：前者是正常状态（新账号还没填 Key），
/// 后者说明密文和本机密钥对不上（换过机器/主板，或密钥文件被删），
/// 界面得明确提示重新填入，否则用户只会看到一个没头没脑的报错。
enum CredentialLookup: Equatable {
    case found(String)
    case missing
    case undecryptable(String)

    var value: String? {
        if case .found(let text) = self { return text }
        return nil
    }
}

/// API Key 的本地加密存储，取代钥匙串。
///
/// ## 为什么不用钥匙串
/// 钥匙串条目的访问控制绑定的是**创建它的那个程序的代码签名标识**。
/// 本项目用 ad-hoc 签名（`codesign --sign -`），标识就是二进制哈希，
/// 每重新编译一次哈希就变，系统认为「这不是原来那个程序」，于是每次都弹密码框。
/// 换成固定自签证书能解决，但那意味着继续用钥匙串 —— 需求是不再用，所以改成文件。
///
/// ## 安全边界（写清楚，别自欺）
/// - 密文用本机 `IOPlatformUUID` 派生的密钥加密（HKDF-SHA256 → AES-GCM）。
///   文件被拷到别的机器、被云盘同步、被 Time Machine 备份、被误发出去，
///   都只是一堆乱码。这是它相对明文的价值。
/// - 但同一台机器上、以当前用户身份运行的程序**仍然能解密** —— 它同样读得到
///   `IOPlatformUUID`。这一点上确实不如钥匙串。属于用安全性换安静，是明确的降级。
/// - 换机或换主板后派生源变了，解不开，需要重新填入 Key。这是加密的必然代价。
///
/// ## 落盘结构
/// - `credentials.json`：账号 ID → base64(AES-GCM 密文)，权限 600
/// - `credentials.vault.json`：HKDF 的 salt + 种子来源，权限 600
final class CredentialStore {
    static let shared = CredentialStore()

    // MARK: - 落盘格式

    private struct VaultFile: Codable {
        var version: Int
        /// HKDF 的 salt，首次使用时随机生成
        var salt: Data
        /// `machine` = 密钥由本机 IOPlatformUUID 派生；`file` = 本机取不到，退化成随机密钥
        var seedSource: String
        /// seedSource == "file" 时使用
        var fileSeed: Data?
    }

    private struct CredentialFile: Codable {
        var version: Int
        /// accountID.uuidString -> base64(AES.GCM sealedBox.combined)
        var entries: [String: String]
    }

    // MARK: - 状态

    private let vaultURL = AppPaths.file("credentials.vault.json")
    private let storeURL = AppPaths.file("credentials.json")

    private let lock = NSLock()
    private var vault: VaultFile?
    private var entries: [String: String] = [:]
    private var didLoad = false
    private var keyCache: SymmetricKey?

    private init() {}

    // MARK: - 对外读写

    func lookup(for accountID: UUID) -> CredentialLookup {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        guard let stored = entries[accountID.uuidString] else { return .missing }
        return open(stored)
    }

    /// 写入。传空串等于删除。返回是否真的落盘成功。
    @discardableResult
    func setKey(_ key: String, for accountID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            entries[accountID.uuidString] = nil
            return persist()
        }
        guard let sealed = seal(trimmed) else {
            DebugLog.write("凭据：加密失败，账号 \(accountID.uuidString.prefix(8))")
            return false
        }
        entries[accountID.uuidString] = sealed
        return persist()
    }

    @discardableResult
    func removeKey(for accountID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        entries[accountID.uuidString] = nil
        return persist()
    }

    /// 清空全部凭据。只删密文，不删密钥文件 —— 密钥留着，下次还能继续用。
    @discardableResult
    func removeAll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        entries.removeAll()
        return persist()
    }

    // MARK: - 展示用

    var storageLocation: String { storeURL.path }

    var isMachineBound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadOrCreateVault()?.seedSource == "machine"
    }

    /// 给界面看的绑定说明。
    /// 必须读 vault 里实际记的 seedSource，不能拿「现在能不能读到 UUID」去猜 ——
    /// 首次初始化时读不到 UUID 会退化成文件密钥，之后即使 UUID 可用了，
    /// 那份凭据也仍然是文件密钥加密的，说明文字要跟着真实情况走。
    var bindingDescription: String {
        lock.lock()
        defer { lock.unlock() }
        switch loadOrCreateVault()?.seedSource {
        case "machine": return "密钥绑定本机硬件"
        case "file": return "密钥存于本机文件"
        default: return "密钥不可用"
        }
    }

    var hasStoredCredentials: Bool {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return !entries.isEmpty
    }

    // MARK: - 加解密

    private func seal(_ plaintext: String) -> String? {
        guard let key = encryptionKey(),
              let data = plaintext.data(using: .utf8),
              let box = try? AES.GCM.seal(data, using: key),
              let combined = box.combined else { return nil }
        return combined.base64EncodedString()
    }

    private func open(_ ciphertext: String) -> CredentialLookup {
        guard let key = encryptionKey() else {
            return .undecryptable("本机密钥不可用（换过机器或主板？）")
        }
        guard let combined = Data(base64Encoded: ciphertext) else {
            return .undecryptable("凭据格式损坏")
        }
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(box, using: key)
            guard let text = String(data: plaintext, encoding: .utf8) else {
                return .undecryptable("凭据内容损坏")
            }
            return .found(text)
        } catch {
            return .undecryptable("本机密钥不匹配（换过机器或主板？）")
        }
    }

    private func encryptionKey() -> SymmetricKey? {
        if let keyCache { return keyCache }
        guard let vault = loadOrCreateVault() else { return nil }

        let seed: Data
        switch vault.seedSource {
        case "machine":
            guard let uuid = DeviceIdentity.platformUUID else {
                DebugLog.write("凭据：凭据按机器绑定写入，但本机 UUID 取不到")
                return nil
            }
            seed = Data(uuid.utf8)
        default:
            guard let fileSeed = vault.fileSeed else { return nil }
            seed = fileSeed
        }

        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: vault.salt,
            info: Data("Token查询.credentials.v1".utf8),
            outputByteCount: 32
        )
        keyCache = key
        return key
    }

    // MARK: - 落盘

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        guard let data = try? Data(contentsOf: storeURL),
              let file = try? JSONDecoder().decode(CredentialFile.self, from: data) else { return }
        entries = file.entries
    }

    private func persist() -> Bool {
        let file = CredentialFile(version: 1, entries: entries)
        guard let data = try? JSONEncoder().encode(file) else { return false }
        return AppPaths.write(data, to: storeURL)
    }

    private func loadOrCreateVault() -> VaultFile? {
        if let vault { return vault }

        if let data = try? Data(contentsOf: vaultURL),
           let existing = try? JSONDecoder().decode(VaultFile.self, from: data) {
            vault = existing
            return existing
        }

        // 有密文却没有密钥文件 —— 这不是首次使用，是密钥文件被删了。
        // 此时绝不能新建 salt：那会静默生成一个解不开已存凭据的新密钥，
        // 用户只会看到「余额取不到」而完全不知道原因。宁可明确失败。
        if FileManager.default.fileExists(atPath: storeURL.path) {
            DebugLog.write("凭据：密钥文件缺失但存在密文，拒绝新建密钥")
            return nil
        }

        // 真正的首次使用
        let machineBound = DeviceIdentity.platformUUID != nil
        var created = VaultFile(version: 1,
                                salt: Self.randomBytes(),
                                seedSource: machineBound ? "machine" : "file",
                                fileSeed: nil)
        if !machineBound { created.fileSeed = Self.randomBytes() }

        vault = created
        if let data = try? JSONEncoder().encode(created) {
            AppPaths.write(data, to: vaultURL)
        }
        DebugLog.write("凭据：初始化密钥（\(created.seedSource)）")
        return created
    }

    /// 32 字节密码学随机数。CryptoKit 生成随机对称密钥就是取随机字节，
    /// 比自己调 SecRandomCopyBytes 少一个 import。
    private static func randomBytes() -> Data {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }
        return Data(bytes)
    }
}
