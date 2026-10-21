// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "NoteDeskMCP", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "NoteDeskMCP", targets: ["NoteDeskMCP"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .target(name: "NoteDeskMCP", dependencies: [.product(name: "MCP", package: "swift-sdk", condition: .when(platforms: [.macOS])), .product(name: "NIOCore", package: "swift-nio", condition: .when(platforms: [.macOS])), .product(name: "NIOPosix", package: "swift-nio", condition: .when(platforms: [.macOS])), .product(name: "NIOHTTP1", package: "swift-nio", condition: .when(platforms: [.macOS]))]),
        .testTarget(name: "NoteDeskMCPTests", dependencies: ["NoteDeskMCP"]),
        .testTarget(name: "ReadServiceTests", dependencies: ["NoteDeskMCP"], swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])])
    ])
