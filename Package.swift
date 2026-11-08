// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SageBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SageBar", targets: ["SageBar"])],
    targets: [
        .target(name: "SageBarCore"),
        .executableTarget(name: "SageBar", dependencies: ["SageBarCore"], resources: [.process("Resources")]),
        .testTarget(name: "SageBarCoreTests", dependencies: ["SageBarCore"])
    ]
)
