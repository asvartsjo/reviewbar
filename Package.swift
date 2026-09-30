// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReviewBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ReviewBar", path: "Sources/ReviewBar"),
        .testTarget(name: "ReviewBarTests", dependencies: ["ReviewBar"], path: "Tests/ReviewBarTests"),
    ]
)
