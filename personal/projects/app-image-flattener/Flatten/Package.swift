// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlattenCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "FlattenCore",
            targets: ["IndexStore", "ScanKit", "CatalogKit", "RulesKit", "RenderKit", "PipelineKit", "JournalKit"]
        ),
        .executable(name: "flatten-cli", targets: ["FlattenCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "IndexStore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "ScanKit", dependencies: ["IndexStore"]),
        .target(
            name: "CatalogKit",
            dependencies: ["IndexStore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "RulesKit", dependencies: ["IndexStore"]),
        .target(name: "RenderKit"),
        .target(name: "JournalKit", dependencies: ["IndexStore"]),
        .target(name: "PipelineKit", dependencies: ["IndexStore", "RenderKit", "JournalKit"]),
        .executableTarget(
            name: "FlattenCLI",
            dependencies: [
                "IndexStore", "ScanKit", "CatalogKit", "RulesKit", "PipelineKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "IndexStoreTests", dependencies: ["IndexStore"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit", "IndexStore"]),
        .testTarget(
            name: "CatalogKitTests",
            dependencies: [
                "CatalogKit", "IndexStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(name: "RulesKitTests", dependencies: ["RulesKit"]),
    ]
)
