// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenMonitor",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "TokenMonitor",
            path: "Sources/TokenMonitor"
        )
    ]
)
