// swift-tools-version: 6.0
import PackageDescription

var aethosCoreDeps: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
]

var extraTargets: [Target] = []

#if os(Linux)
aethosCoreDeps.append(.target(name: "CSQLite3"))
extraTargets.append(
    .systemLibrary(name: "CSQLite3", path: "AethosCore/Sources/CSQLite3")
)
#endif

let package = Package(
    name: "AethosCLI",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "AethosCore", targets: ["AethosCore"]),
        .executable(name: "aethos", targets: ["AethosCLI"]),
        .executable(name: "aethos-swift-runner", targets: ["AethosSwiftRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: extraTargets + [
        .target(
            name: "AethosCore",
            dependencies: aethosCoreDeps,
            path: "AethosCore/Sources/AethosCore"
        ),
        .target(
            name: "AethosCLILib",
            dependencies: [
                "AethosCore"
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
        .executableTarget(
            name: "AethosSwiftRunner",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Tests/compatibility/runners/swift_impl"
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
        ),
        .testTarget(
            name: "AethosCoreTests",
            dependencies: [
                "AethosCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "AethosCore/Tests/AethosCoreTests",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
