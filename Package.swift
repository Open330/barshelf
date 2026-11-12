// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "barshelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "barshelf-app", targets: ["BarShelfAppMain"]),
        .executable(name: "barshelf-media", targets: ["BarShelfMedia"]),
        .executable(name: "barshelf", targets: ["BarShelfCLI"]),
        .executable(name: "bsf", targets: ["BsfCLI"]),
        .library(name: "MenubucketCore", targets: ["MenubucketCore"]),
    ],
    targets: [
        .target(
            name: "MenubucketCore"
        ),
        // The app. A library, so the executable below is one line and
        // development tools can drive the real views without shipping in it.
        .target(
            name: "BarShelfAutomation",
            dependencies: ["MenubucketCore"]
        ),
        // Feature engines: state and logic without views. They sit below the
        // app and cannot reach into it; their pages and panels stay in the app.
        .target(
            name: "BarShelfDock",
            dependencies: ["MenubucketCore", "BarShelfAutomation"]
        ),
        .target(
            name: "BarShelfBuilder",
            dependencies: ["MenubucketCore"]
        ),
        .target(
            name: "MenubucketApp",
            dependencies: ["MenubucketCore", "BarShelfAutomation", "BarShelfDock", "BarShelfBuilder"]
        ),
        .executableTarget(
            name: "BarShelfAppMain",
            dependencies: ["MenubucketApp"]
        ),
        // Renders the landing page's videos and stills from the app's views.
        // Development only (debug builds): never part of BarShelf.app.
        .executableTarget(
            name: "BarShelfMedia",
            dependencies: ["MenubucketApp", "BarShelfAutomation", "BarShelfDock", "BarShelfBuilder", "MenubucketCore"]
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
            dependencies: ["MenubucketApp", "BarShelfAutomation", "BarShelfDock", "BarShelfBuilder", "MenubucketCore"]
        ),
        .testTarget(
            name: "BarShelfCLITests",
            dependencies: ["BarShelfKit", "MenubucketCore"]
        ),
    ]
)
