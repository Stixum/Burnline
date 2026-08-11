// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burnline",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BurnlineCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BurnlineProbe",
            dependencies: ["BurnlineCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BurnlineCoreTests",
            dependencies: ["BurnlineCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
