// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "scout-db",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "ScoutDB",
            targets: ["ScoutDB"]
        ),
        .library(
            name: "ScoutDBTesting",
            targets: ["ScoutDBTesting"]
        ),
        .plugin(
            name: "ScoutDBCodegenPlugin",
            targets: ["ScoutDBCodegenPlugin"]
        ),
    ],
    targets: [
        .target(
            name: "ScoutDB"
        ),
        .target(
            name: "ScoutDBTesting",
            dependencies: ["ScoutDB"]
        ),
        .executableTarget(
            name: "scoutdb-codegen",
            dependencies: ["ScoutDB"]
        ),
        .plugin(
            name: "ScoutDBCodegenPlugin",
            capability: .buildTool(),
            dependencies: ["scoutdb-codegen"]
        ),
        .testTarget(
            name: "ScoutDBTests",
            dependencies: ["ScoutDB", "ScoutDBTesting"]
        ),
    ]
)
