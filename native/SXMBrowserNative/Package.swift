// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SXMBrowserNative",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SXMBrowserNative", targets: ["SXMBrowserNative"]),
        .executable(name: "SXMBrowserSmoke", targets: ["SXMBrowserSmoke"]),
        .executable(name: "SXMBrowserBenchmark", targets: ["SXMBrowserBenchmark"]),
    ],
    targets: [
        .target(name: "SXMBrowserCore"),
        .executableTarget(name: "SXMBrowserNative", dependencies: ["SXMBrowserCore"]),
        .executableTarget(name: "SXMBrowserSmoke", dependencies: ["SXMBrowserCore"]),
        .executableTarget(name: "SXMBrowserBenchmark", dependencies: ["SXMBrowserCore"]),
        .testTarget(name: "SXMBrowserCoreTests", dependencies: ["SXMBrowserCore"]),
    ]
)
