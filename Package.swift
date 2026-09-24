// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexTokenBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexTokenBar", targets: ["CodexTokenBar"])],
    targets: [
        .target(name: "TokenBarCore", resources: [.process("Resources")]),
        .executableTarget(name: "CodexTokenBar", dependencies: ["TokenBarCore"]),
        .testTarget(name: "TokenBarCoreTests", dependencies: ["TokenBarCore"]),
        .testTarget(name: "CodexTokenBarTests", dependencies: ["CodexTokenBar", "TokenBarCore"]),
    ]
)
