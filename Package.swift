// swift-tools-version: 6.0

import CompilerPluginSupport
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
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0")
    ],
    targets: [
        .target(
            name: "ScoutDB",
            dependencies: ["ScoutDBMacros"]
        ),
        .macro(
            name: "ScoutDBMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
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
