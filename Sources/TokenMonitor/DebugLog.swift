import Foundation

/// 轻量诊断日志，用于排查面板交互问题。
/// 位置：~/Library/Application Support/Token查询/debug.log
enum DebugLog {
    private static let url: URL? = AppPaths.file("debug.log")

    static func write(_ message: String) {
        guard let url else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
