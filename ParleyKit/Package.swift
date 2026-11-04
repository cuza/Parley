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
        .package(url: "https://github.com/apple/swift-protobuf", exact: "1.38.1"),
        // CryptoKit's API where CryptoKit doesn't exist (Linux, Windows). Apple platforms keep CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(name: "ParleyDomain"),
        .target(
            name: "ParleyData",
            dependencies: [
                "ParleyDomain", .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])),
            ]),
        // What only runs off Apple platforms, plus the shared helpers both paths go through. Parley's own tests stay in
        // the app's test target.
        .testTarget(name: "ParleyKitTests", dependencies: ["ParleyDomain", "ParleyData"]),
    ]
)
