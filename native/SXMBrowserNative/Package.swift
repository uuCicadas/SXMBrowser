// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SXMBrowserNative",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SXMBrowserAppCore", targets: ["SXMBrowserAppCore"]),
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
        .executableTarget(
            name: "SXMBrowserNative",
            dependencies: ["SXMBrowserCore", "SXMBrowserAppCore"]
        ),
        .executableTarget(name: "SXMBrowserSmoke", dependencies: ["SXMBrowserCore"]),
        .executableTarget(name: "SXMBrowserBenchmark", dependencies: ["SXMBrowserCore"]),
        .testTarget(name: "SXMBrowserCoreTests", dependencies: ["SXMBrowserCore"]),
        .testTarget(name: "SXMBrowserAppCoreTests", dependencies: ["SXMBrowserAppCore"]),
    ]
)
