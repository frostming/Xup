// swift-tools-version:6.2
import PackageDescription

// 部署目标 macOS 26：SwiftPM 会把它同时写入 LC_BUILD_VERSION 的 sdk 字段，
// 系统据此启用 macOS 26+ 的新设计（Liquid Glass）。低于 26 会被按兼容样式渲染。
let package = Package(
    name: "Xup",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Xup",
            path: "Sources/Xup",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 独立 CLI：不链接 App 代码，通过 Unix socket(JSON) 与运行中的 App 通信，
        // 纯配置操作直接读写 config.json。
        .executableTarget(
            name: "xup-cli",
            path: "Sources/xup-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "XupTests",
            dependencies: ["Xup"],
            path: "Tests/XupTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
