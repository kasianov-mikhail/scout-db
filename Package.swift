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
        )
    ],
    targets: [
        .target(
            name: "ScoutDB"
        ),
        .testTarget(
            name: "ScoutDBTests",
            dependencies: ["ScoutDB"]
        ),
    ]
)
