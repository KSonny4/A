// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Flare",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Flare", targets: ["Flare"]),
    ],
    targets: [
        .target(
            name: "FlareCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Flare",
            dependencies: ["FlareCore"]
        ),
        .testTarget(
            name: "FlareCoreTests",
            dependencies: ["FlareCore"]
        ),
    ]
)
