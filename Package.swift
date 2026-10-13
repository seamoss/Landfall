// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Landfall",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "landfall", targets: ["landfall"]),
    ],
    dependencies: [
        // Auto-updates (the app only; LandfallCore stays dependency-free).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "LandfallCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "landfall",
            dependencies: ["LandfallCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                // Sparkle.framework is embedded in Landfall.app/Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", "@loader_path"]),
            ]
        ),
        .testTarget(name: "LandfallCoreTests", dependencies: ["LandfallCore"]),
    ]
)
