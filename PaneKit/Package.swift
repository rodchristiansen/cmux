// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PaneKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PaneKit",
            targets: ["PaneKit"]
        ),
    ],
    targets: [
        .target(
            name: "PaneKit",
            dependencies: [],
            path: "Sources/PaneKit"
        ),
        .testTarget(
            name: "PaneKitTests",
            dependencies: ["PaneKit"],
            path: "Tests/PaneKitTests"
        ),
    ]
)
