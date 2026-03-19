// swift-tools-version: 6.0
import PackageDescription

var aethosDeps: [Target.Dependency] = []

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
    dependencies: [],
    targets: extraTargets + [
        .target(
            name: "AethosCore",
            dependencies: aethosDeps,
            path: "Sources/AethosCore"
        ),
        .testTarget(
            name: "AethosCoreTests",
            dependencies: [
                "AethosCore"
            ],
            path: "Tests/AethosCoreTests"
        ),
    ]
)
