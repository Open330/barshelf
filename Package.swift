// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "barshelf",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "barshelf-app", targets: ["MenubucketApp"]),
        .executable(name: "barshelf", targets: ["BarShelfCLI"]),
        .executable(name: "bsf", targets: ["BsfCLI"]),
        .library(name: "MenubucketCore", targets: ["MenubucketCore"]),
    ],
    targets: [
        .target(
            name: "MenubucketCore"
        ),
        .executableTarget(
            name: "MenubucketApp",
            dependencies: ["MenubucketCore"]
        ),
        // barshelf CLI — command logic lives in BarShelfKit (library, unit-testable);
        // the executable target is a thin main.swift. Foundation only, no AppKit.
        .target(
            name: "BarShelfKit",
            dependencies: ["MenubucketCore"],
            path: "Sources/BarShelfCLI/BarShelfKit"
        ),
        .executableTarget(
            name: "BarShelfCLI",
            dependencies: ["BarShelfKit"],
            path: "Sources/BarShelfCLI/Main"
        ),
        .executableTarget(
            name: "BsfCLI",
            dependencies: ["BarShelfKit"],
            path: "Sources/BsfCLI/Main"
        ),
        .testTarget(
            name: "MenubucketCoreTests",
            dependencies: ["MenubucketCore"]
        ),
        .testTarget(
            name: "MenubucketAppTests",
            dependencies: ["MenubucketApp", "MenubucketCore"]
        ),
        .testTarget(
            name: "BarShelfCLITests",
            dependencies: ["BarShelfKit", "MenubucketCore"]
        ),
    ]
)
