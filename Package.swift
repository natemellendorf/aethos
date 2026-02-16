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
        .target(
            name: "AethosCLILib",
            dependencies: [
                .product(name: "AethosCore", package: "AethosCore")
            ],
            path: "Sources/AethosCLILib"
        ),
        .executableTarget(
            name: "AethosCLI",
            dependencies: [
                "AethosCLILib"
            ],
            path: "Sources/AethosCLI"
        ),
        .testTarget(
            name: "AethosCLITests",
            dependencies: [
                "AethosCLILib"
            ],
            path: "Tests/AethosCLITests",
            resources: [
                .copy("Snapshots")
            ]
        )
    ]
)
