// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReviewBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ReviewBar", path: "Sources/ReviewBar"),
        .testTarget(name: "ReviewBarTests", dependencies: ["ReviewBar"], path: "Tests/ReviewBarTests"),
    ]
)
