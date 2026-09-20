// swift-tools-version: 6.0

import PackageDescription

// The XcodeGen project is the distributable macOS application. This manifest
// gives the shared DiscordCore layer a reproducible SwiftPM build and test path.
// Keep this package dependency-free until a dependency is justified; when one
// is added, pin it to an exact version and commit the resulting Package.resolved.
let package = Package(
    name: "NativeDiscordClient",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "DiscordCore",
            targets: ["DiscordCore"]
        ),
        .library(
            name: "AuthFeature",
            targets: ["AuthFeature"]
        ),
        .library(
            name: "CacheCore",
            targets: ["CacheCore"]
        )
    ],
    targets: [
        .target(
            name: "DiscordCore",
            path: "Sources/DiscordCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "AuthFeature",
            path: "Sources/AuthFeature",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "CacheCore",
            path: "Sources/CacheCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "DiscordCoreTests",
            dependencies: ["DiscordCore"],
            path: "Tests/DiscordCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "AuthFeatureTests",
            dependencies: ["AuthFeature"],
            path: "Tests/AuthFeatureTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "CacheCoreTests",
            dependencies: ["CacheCore"],
            path: "Tests/CacheCoreTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
