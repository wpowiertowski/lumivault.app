// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LumiVault",
    defaultLocalization: "en",
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
                .process("Resources/Assets.xcassets"),
                .copy("Resources/LumiVault.help"),
                .copy("Resources/TipJar.storekit")
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .treatAllWarnings(as: .error)
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
