// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "StatBar",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "StatBar",
            path: "Sources/StatBar"
        ),
        .testTarget(
            name: "StatBarTests",
            dependencies: ["StatBar"],
            path: "Tests/StatBarTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
