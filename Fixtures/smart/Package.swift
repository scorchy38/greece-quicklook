// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GreeceKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "GreeceKit", targets: ["GreeceKit"]),
        .executable(name: "greece", targets: ["GreeceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.1.4")),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.17.6"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
        .package(path: "../GreeceCore"),
    ],
    targets: [
        .target(name: "GreeceKit", dependencies: [.product(name: "Collections", package: "swift-collections")]),
        .executableTarget(name: "GreeceCLI", dependencies: ["GreeceKit", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(name: "GreeceKitTests", dependencies: ["GreeceKit"]),
    ]
)
