// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "TokenUsageMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TokenUsageMonitor", targets: ["TokenUsageMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "TokenUsageMonitor",
            path: "Sources/TokenUsageMonitor"
        )
    ]
)
