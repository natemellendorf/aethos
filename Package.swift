// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AethosCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "aethos", targets: ["AethosCLI"])
    ],
    dependencies: [
        .package(path: "AethosCore")
    ],
    targets: [
        .executableTarget(
            name: "AethosCLI",
            dependencies: [
                .product(name: "AethosCore", package: "AethosCore")
            ],
            path: "Sources/AethosCLI"
        )
    ]
)
