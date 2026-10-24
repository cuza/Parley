// swift-tools-version: 6.0
// Parley's inner layers as modules, so the compiler holds them to the dependency rule: Domain uses only the system,
// Data uses Domain. The app target adds Store, Shared, Features, App and Intents on top.
import PackageDescription

let package = Package(
    name: "ParleyKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ParleyDomain", targets: ["ParleyDomain"]),
        .library(name: "ParleyData", targets: ["ParleyData"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf", exact: "1.38.1")
    ],
    targets: [
        .target(name: "ParleyDomain"),
        .target(
            name: "ParleyData",
            dependencies: ["ParleyDomain", .product(name: "SwiftProtobuf", package: "swift-protobuf")]),
    ]
)
