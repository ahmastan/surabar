// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SurabarKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MushafRendering", targets: ["MushafRendering"]),
        .library(name: "QuranStore", targets: ["QuranStore"]),
        .executable(name: "surabar-render", targets: ["SurabarRender"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.10.0"),
    ],
    targets: [
        // Core Text page layout and drawing; independent of where page data comes from.
        .target(name: "MushafRendering"),
        // Read-only access to the generated Quran database, and navigation queries over it.
        .target(name: "QuranStore", dependencies: ["MushafRendering", .product(name: "GRDB", package: "GRDB.swift")]),
        // Phase 0 harness: renders snapshots and checks every page of a layout for defects.
        .executableTarget(name: "SurabarRender", dependencies: ["MushafRendering", "QuranStore"]),
        .testTarget(name: "MushafRenderingTests", dependencies: ["MushafRendering"]),
        .testTarget(name: "QuranStoreTests", dependencies: ["QuranStore", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
