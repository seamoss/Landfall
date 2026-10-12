// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Landfall",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "landfall", targets: ["landfall"]),
    ],
    targets: [
        .target(
            name: "LandfallCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "landfall", dependencies: ["LandfallCore"]),
        .testTarget(name: "LandfallCoreTests", dependencies: ["LandfallCore"]),
    ]
)
