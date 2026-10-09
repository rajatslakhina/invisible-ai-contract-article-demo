// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "InvisibleAI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "InvisibleAI", targets: ["InvisibleAI"])
    ],
    targets: [
        .target(name: "InvisibleAI"),
        .testTarget(name: "InvisibleAITests", dependencies: ["InvisibleAI"])
    ]
)
