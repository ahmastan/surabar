// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Surabar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MushafRendering", targets: ["MushafRendering"]),
        .library(name: "QuranStore", targets: ["QuranStore"]),
        .executable(name: "surabar-render", targets: ["SurabarRender"]),
    ],
    targets: [
        // Core Text page layout and drawing; independent of where page data comes from.
        .target(name: "MushafRendering"),
        // Read-only access to the generated Quran database through the system SQLite library.
        .target(name: "QuranStore", dependencies: ["MushafRendering"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // Phase 0 harness: renders snapshots and checks every page of a layout for defects.
        .executableTarget(name: "SurabarRender", dependencies: ["MushafRendering", "QuranStore"]),
        .testTarget(name: "MushafRenderingTests", dependencies: ["MushafRendering"]),
    ]
)
