// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatercolorStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WatercolorCore", targets: ["WatercolorCore"]),
        .library(name: "WatercolorEngine", targets: ["WatercolorEngine"]),
        .executable(name: "WatercolorStudio", targets: ["WatercolorStudio"])
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
        .executableTarget(
            name: "WatercolorStudio",
            dependencies: ["WatercolorCore", "WatercolorEngine"]
        ),
        .testTarget(name: "WatercolorCoreTests", dependencies: ["WatercolorCore"]),
        .testTarget(
            name: "WatercolorEngineTests",
            dependencies: ["WatercolorCore", "WatercolorEngine"]
        ),
        .testTarget(
            name: "WatercolorStudioTests",
            dependencies: ["WatercolorCore", "WatercolorEngine", "WatercolorStudio"]
        )
    ]
)
