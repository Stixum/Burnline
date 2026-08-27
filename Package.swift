// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burnline",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "BurnlineCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Burnline",
            dependencies: ["BurnlineCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                // Xcode would set this via an embed build phase. Without a
                // project file, the executable must be told at link time where
                // to find the framework inside the bundle at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "BurnlineProbe",
            dependencies: ["BurnlineCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BurnlineStatusline",
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
