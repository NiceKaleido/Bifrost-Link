// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BifrostLink",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "BifrostLink", path: "Sources/BifrostLink"),
        .testTarget(name: "BifrostLinkTests", dependencies: ["BifrostLink"], path: "Tests/BifrostLinkTests"),
    ]
)
