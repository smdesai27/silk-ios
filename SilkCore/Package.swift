// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SilkCore",
    platforms: [.iOS("26.5"), .macOS("26.0")],
    products: [
        .library(name: "SilkCore", targets: ["SilkCore"])
    ],
    targets: [
        .target(name: "SilkCore"),
        .testTarget(name: "SilkCoreTests", dependencies: ["SilkCore"]),
    ]
)
