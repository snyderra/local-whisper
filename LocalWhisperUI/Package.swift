// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalWhisperUI",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalWhisperUI",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/LocalWhisperUI"
        )
    ]
)
