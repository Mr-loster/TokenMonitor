import Foundation

/// App 自报的版本号，**唯一事实来源是打包后的 `Info.plist`**。
///
/// 不要在源码里写死 `"v2.0"` 这种字面量：以前「设置 → 关于」和启动日志各写了一份，
/// 结果升到 2.0 时两边都还显示 2.0、`Info.plist` 里却留着 1.10，三处对不上。
/// `build.sh` 会按脚本顶部的 VERSION / BUILD 把值注入 `Info.plist`，
/// 所以这里读到什么，安装包和 App 里就是什么。
enum AppVersion {
    /// 形如 `2.0.1`。没有 bundle（例如离屏渲染的测试程序）时退化成 `dev`。
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// 形如 `v2.0.1`，给界面和日志用。
    static var display: String { "v" + short }
}
