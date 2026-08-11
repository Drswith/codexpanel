// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "CodexPanelCore",
    products: [
        .library(name: "CodexPanelCore", targets: ["CodexPanelCore"]),
    ],
    targets: [
        .target(name: "CodexPanelCore"),
        .testTarget(
            name: "CodexPanelCoreTests",
            dependencies: ["CodexPanelCore"]
        ),
    ]
)
