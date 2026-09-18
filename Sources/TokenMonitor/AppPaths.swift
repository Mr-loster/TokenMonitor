import Foundation

/// 应用数据目录。
///
/// 之前 AccountStore / SnapshotStore / DebugLog 各自拼了一遍路径，
/// 加凭据文件时再拼第四遍就容易写歪，统一收到这里。
enum AppPaths {

    /// ~/Library/Application Support/Token查询
    static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Token查询", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL {
        dataDirectory.appendingPathComponent(name)
    }

    /// 给用户看的路径写法（真实路径里带用户名，没必要暴露）
    static let displayPath = "~/Library/Application Support/Token查询"

    /// 写入并收紧到 0600。
    ///
    /// `.atomic` 是「写临时文件再改名」，新文件的权限跟着 umask 走（通常是 644），
    /// 所以必须在写完后再改一次，不能指望 write 的 options 带权限。
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            return true
        } catch {
            DebugLog.write("写盘失败 \(url.lastPathComponent)：\(error.localizedDescription)")
            return false
        }
    }
}
