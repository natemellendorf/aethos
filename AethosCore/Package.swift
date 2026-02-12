// swift-tools-version: 6.0
import PackageDescription

var aethosDeps: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),
]

var extraTargets: [Target] = []

#if os(Linux)
aethosDeps.append(.target(name: "CSQLite3"))
extraTargets.append(
    .systemLibrary(name: "CSQLite3", path: "Sources/CSQLite3")
)
#endif

let package = Package(
    name: "AethosCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AethosCore", targets: ["AethosCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: extraTargets + [
        .target(
            name: "AethosCore",
            dependencies: aethosDeps,
            path: "Sources/AethosCore"
        ),
        .testTarget(
            name: "AethosCoreTests",
            dependencies: [
                "AethosCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/AethosCoreTests"
        ),
    ]
)
