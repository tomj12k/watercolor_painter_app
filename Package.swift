// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WatercolorStudio",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WatercolorCore", targets: ["WatercolorCore"]),
        .library(name: "WatercolorEngine", targets: ["WatercolorEngine"]),
        .library(name: "WatercolorMCP", targets: ["WatercolorMCP"]),
        .executable(name: "WatercolorStudio", targets: ["WatercolorStudio"]),
        .executable(name: "WatercolorStudioMCP", targets: ["WatercolorStudioMCP"])
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
        .target(name: "WatercolorMCP"),
        .executableTarget(
            name: "WatercolorStudioMCP",
            dependencies: ["WatercolorMCP"]
        ),
        .executableTarget(
            name: "WatercolorStudio",
            dependencies: ["WatercolorCore", "WatercolorEngine", "WatercolorMCP"]
        ),
        .testTarget(name: "WatercolorCoreTests", dependencies: ["WatercolorCore"]),
        .testTarget(
            name: "WatercolorEngineTests",
            dependencies: ["WatercolorCore", "WatercolorEngine"]
        ),
        .testTarget(
            name: "WatercolorStudioTests",
            dependencies: ["WatercolorCore", "WatercolorEngine", "WatercolorStudio"]
        ),
        .testTarget(
            name: "WatercolorMCPTests",
            dependencies: ["WatercolorMCP"]
        )
    ]
)
