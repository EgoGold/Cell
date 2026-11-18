// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cell",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cell", targets: ["Cell"]),
        .executable(name: "cell-cli", targets: ["CellCLI"]),
        .library(name: "CellCore", targets: ["CellCore"]),
        .library(name: "CellUI", targets: ["CellUI"]),
    ],
    targets: [
        .target(name: "CellArchive", linkerSettings: [.linkedLibrary("archive")]),
        // Everything that is not UI: containers, Wine engines, analysis, Autopilot, plugins, launching.
        .target(
            name: "CellCore",
            dependencies: ["CellArchive"],
            linkerSettings: [
                .linkedFramework("CoreText"),
                .linkedFramework("Carbon"),
                .linkedFramework("ImageIO"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Virtualization"),
            ]
        ),
        // SwiftUI views and view models. Kept separate so the UI can be redesigned freely.
        .target(name: "CellUI", dependencies: ["CellCore"]),
        // The macOS app entry point.
        .executableTarget(name: "Cell", dependencies: ["CellUI"]),
        // Command line tool, also used by "Add to Applications" shortcuts for fast launches.
        .executableTarget(name: "CellCLI", dependencies: ["CellCore"]),
        .testTarget(name: "CellCoreTests", dependencies: ["CellCore"]),
    ],
    swiftLanguageModes: [.v5]
)
