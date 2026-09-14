// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacLayoutManager",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "LayoutCore"),
        .executableTarget(name: "MacLayoutManager", dependencies: ["LayoutCore"]),
        .testTarget(name: "LayoutCoreTests", dependencies: ["LayoutCore"]),
    ]
)
