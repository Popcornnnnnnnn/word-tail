// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WordTail",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WordTailCore", targets: ["WordTailCore"]),
        .executable(name: "WordTail", targets: ["WordTailApp"])
    ],
    targets: [
        .target(
            name: "WordTailCore",
            path: "Sources/WordTailCore"
        ),
        .executableTarget(
            name: "WordTailApp",
            dependencies: ["WordTailCore"],
            path: "Sources/WordTailApp"
        ),
        .testTarget(
            name: "WordTailTests",
            dependencies: ["WordTailCore"],
            path: "Tests/WordTailTests"
        )
    ]
)
