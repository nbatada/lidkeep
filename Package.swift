// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "LidKeep",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "LidKeepCore", targets: ["LidKeepCore"]),
        .executable(name: "LidKeep", targets: ["LidKeepApp"]),
        .executable(name: "LidKeepPowerHelper", targets: ["LidKeepPowerHelper"]),
        .executable(name: "LidKeepCoreTests", targets: ["LidKeepCoreTests"]),
    ],
    targets: [
        .target(
            name: "LidKeepCore",
            path: "Sources/LidKeepCore"
        ),
        .executableTarget(
            name: "LidKeepApp",
            dependencies: ["LidKeepCore"],
            path: "Sources/LidKeepApp"
        ),
        .executableTarget(
            name: "LidKeepPowerHelper",
            dependencies: ["LidKeepCore"],
            path: "Sources/LidKeepPowerHelper"
        ),
        .executableTarget(
            name: "LidKeepCoreTests",
            dependencies: ["LidKeepCore"],
            path: "Tests/LidKeepCoreTests"
        ),
    ]
)
