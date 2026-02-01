// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AethosCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AethosCore", targets: ["AethosCore"]),
    ],
    targets: [
        .target(
            name: "AethosCore",
            path: "Sources"
        ),
        .testTarget(
            name: "AethosCoreTests",
            dependencies: ["AethosCore"],
            path: "Tests/AethosCoreTests"
        ),
    ]
)
