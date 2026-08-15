## Project Discovery

- This is one SwiftPM project, `WatercolorStudio`, using Swift tools 6.0 and macOS 14+. It was tested with Apple Swift 6.3.3.
- Products are the `WatercolorCore` and `WatercolorEngine` libraries plus the `WatercolorStudio` executable. The three matching test targets live alongside them.
- `WatercolorEngine` depends on `WatercolorCore` and links CoreGraphics, Metal, and MetalKit. `WatercolorStudio` depends on both libraries and uses SwiftUI, Combine, AppKit, ImageIO, UniformTypeIdentifiers, and MetalKit.
- Sources live in `Sources/WatercolorCore`, `Sources/WatercolorEngine`, and `Sources/WatercolorStudio`; tests mirror that layout under `Tests/`.
- Project documentation lives in `docs/program`; design and plan material lives in `docs/superpowers`.
- Verified commands: `make test`, `make build`, `make app`, and `make run`.
