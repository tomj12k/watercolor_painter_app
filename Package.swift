// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatercolorStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WatercolorCore", targets: ["WatercolorCore"])
    ],
    targets: [
        .target(name: "WatercolorCore"),
        .testTarget(name: "WatercolorCoreTests", dependencies: ["WatercolorCore"])
    ]
)
