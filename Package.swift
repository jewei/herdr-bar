// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HerdrBar", targets: ["HerdrBar"]),
        .library(name: "HerdrBarCore", targets: ["HerdrBarCore"]),
    ],
    targets: [
        .target(name: "HerdrBarCore"),
        .executableTarget(name: "HerdrBar", dependencies: ["HerdrBarCore"]),
        .testTarget(name: "HerdrBarCoreTests", dependencies: ["HerdrBarCore"]),
    ]
)
