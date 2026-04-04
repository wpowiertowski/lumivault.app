// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LumiVault",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "LumiVault",
            path: "LumiVault",
            exclude: [
                "Info.plist",
                "LumiVault.entitlements",
                "LumiVault.Debug.entitlements"
            ],
            resources: [
                .process("Resources/Assets.xcassets")
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),
        .testTarget(
            name: "LumiVaultTests",
            dependencies: [
                "LumiVault",
            ],
            path: "Tests"
        ),
    ]
)
