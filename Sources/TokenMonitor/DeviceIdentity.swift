import Foundation
import IOKit

/// 本机标识。用于给凭据加密派生密钥，不参与任何联网请求。
enum DeviceIdentity {

    /// 主板 UUID（IOPlatformExpertDevice 的 IOPlatformUUID）。
    ///
    /// 特点：同一台机器上稳定不变，换机器或换主板会变。
    /// 这正是我们要的 —— 凭据文件被拷到别的机器就解不开。
    static let platformUUID: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let raw = IORegistryEntryCreateCFProperty(service,
                                                        kIOPlatformUUIDKey as CFString,
                                                        kCFAllocatorDefault,
                                                        0)?.takeRetainedValue() as? String,
              !raw.isEmpty else { return nil }
        return raw
    }()
}
