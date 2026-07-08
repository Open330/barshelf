// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "menubucket",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "menubucket", targets: ["MenubucketApp"]),
        .executable(name: "mbk", targets: ["MbkCLI"]),
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
        // mbk CLI — command logic lives in MbkKit (library, unit-testable);
        // the executable target is a thin main.swift. Foundation only, no AppKit.
        .target(
            name: "MbkKit",
            dependencies: ["MenubucketCore"],
            path: "Sources/MbkCLI/MbkKit"
        ),
        .executableTarget(
            name: "MbkCLI",
            dependencies: ["MbkKit"],
            path: "Sources/MbkCLI/Main"
        ),
        .testTarget(
            name: "MenubucketCoreTests",
            dependencies: ["MenubucketCore"]
        ),
        .testTarget(
            name: "MbkCLITests",
            dependencies: ["MbkKit", "MenubucketCore"]
        ),
    ]
)
