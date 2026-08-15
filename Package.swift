// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatercolorStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WatercolorCore", targets: ["WatercolorCore"]),
        .library(name: "WatercolorEngine", targets: ["WatercolorEngine"])
    ],
    targets: [
        .target(name: "WatercolorCore"),
        .target(
            name: "WatercolorEngine",
            dependencies: ["WatercolorCore"],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit")
            ]
        ),
        .testTarget(name: "WatercolorCoreTests", dependencies: ["WatercolorCore"]),
        .testTarget(
            name: "WatercolorEngineTests",
            dependencies: ["WatercolorCore", "WatercolorEngine"]
        )
    ]
)
