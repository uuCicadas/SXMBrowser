// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SXMBrowserNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SXMBrowserAppCore", targets: ["SXMBrowserAppCore"]),
        .library(name: "SXMBrowserNativeUI", targets: ["SXMBrowserNativeUI"]),
        .executable(name: "SXMBrowserNative", targets: ["SXMBrowserNative"]),
        .executable(name: "SXMBrowserSmoke", targets: ["SXMBrowserSmoke"]),
        .executable(name: "SXMBrowserBenchmark", targets: ["SXMBrowserBenchmark"]),
    ],
    targets: [
        .target(
            name: "SXMBrowserCore",
            resources: [
                .embedInCode("Resources/palettes.json"),
            ]
        ),
        .target(name: "SXMBrowserAppCore", dependencies: ["SXMBrowserCore"]),
        .target(
            name: "SXMBrowserNativeUI",
            dependencies: ["SXMBrowserCore", "SXMBrowserAppCore"]
        ),
        .executableTarget(
            name: "SXMBrowserNative",
            dependencies: ["SXMBrowserNativeUI", "SXMBrowserAppCore", "SXMBrowserCore"]
        ),
        .executableTarget(name: "SXMBrowserSmoke", dependencies: ["SXMBrowserCore"]),
        .executableTarget(name: "SXMBrowserBenchmark", dependencies: ["SXMBrowserCore"]),
        .testTarget(name: "SXMBrowserCoreTests", dependencies: ["SXMBrowserCore"]),
        .testTarget(name: "SXMBrowserAppCoreTests", dependencies: ["SXMBrowserAppCore"]),
        .testTarget(
            name: "SXMBrowserNativeUITests",
            dependencies: ["SXMBrowserNativeUI", "SXMBrowserAppCore", "SXMBrowserCore"]
        ),
    ]
)
