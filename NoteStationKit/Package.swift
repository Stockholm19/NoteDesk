// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoteStationKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "NoteStationKit", targets: ["NoteStationKit"]),
        .executable(name: "nsctl", targets: ["nsctl"]),
    ],
    targets: [
        .target(name: "NoteStationKit"),
        .executableTarget(name: "nsctl", dependencies: ["NoteStationKit"]),
        .testTarget(name: "NoteStationKitTests", dependencies: ["NoteStationKit"]),
    ]
)
