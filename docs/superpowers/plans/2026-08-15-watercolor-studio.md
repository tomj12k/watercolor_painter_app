# Watercolor Studio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native, document-based macOS watercolor app with GPU pigment simulation, expressive tools, editable layers, project persistence, and PNG export.

**Architecture:** SwiftUI owns the document scene and studio UI; a main-actor workspace translates semantic painting commands into a Metal renderer hosted in `MTKView`. A platform-neutral core module owns the versioned project model, presets, stroke sampling, and reversible history so persistence and rendering remain independently testable.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Metal/MetalKit, UniformTypeIdentifiers, CoreGraphics/ImageIO, XCTest via Swift Testing, Swift Package Manager.

**Spec:** `docs/superpowers/specs/2026-08-15-watercolor-studio-design.md`

## Global Constraints

- Target macOS 14 or newer and Apple Silicon as the reference hardware.
- Support canvas dimensions from 256 × 256 through 4,096 × 4,096.
- Support at most 12 layers.
- Allocate no Metal textures, buffers, pipeline states, or command queues per pointer event.
- Store deterministic semantic commands in schema-version-1 `.watercolor` JSON documents.
- Keep UI state on the main actor and keep `WatercolorCore` independent of SwiftUI, AppKit, and Metal.
- Do not add third-party runtime dependencies.

---

## Planned file structure

- `Package.swift` — package products, platform floor, targets, and linked Apple frameworks.
- `Sources/WatercolorCore/ProjectModel.swift` — canvas, paper, color, brush, tool, point, command, layer, and project value types.
- `Sources/WatercolorCore/Presets.swift` — preset parameter mapping and display names.
- `Sources/WatercolorCore/StrokeSampler.swift` — gap-free point interpolation.
- `Sources/WatercolorCore/ProjectEditor.swift` — validated layer and command mutations plus undo/redo.
- `Sources/WatercolorCore/DocumentCodec.swift` — stable schema-versioned JSON encoding and decoding.
- `Sources/WatercolorCore/CanvasTransform.swift` — view/canvas coordinate mapping independent of AppKit.
- `Sources/WatercolorEngine/ShaderSource.swift` — embedded Metal stamp, diffusion, composite, and display shader source.
- `Sources/WatercolorEngine/WatercolorRenderer.swift` — Metal resource lifetime, rendering API, replay, and readback.
- `Sources/WatercolorStudio/WatercolorStudioApp.swift` — app entry point and document scene.
- `Sources/WatercolorStudio/PaintingDocument.swift` — versioned file document encoding/decoding.
- `Sources/WatercolorStudio/StudioModel.swift` — single main-actor workspace state and renderer coordination.
- `Sources/WatercolorStudio/MetalCanvasView.swift` — SwiftUI/AppKit/Metal bridge and pointer/tablet event conversion.
- `Sources/WatercolorStudio/StudioView.swift` — three-zone workspace and toolbar composition.
- `Sources/WatercolorStudio/ToolRail.swift` — painting tool selection.
- `Sources/WatercolorStudio/BrushInspector.swift` — color, preset, shape, hair, texture, and numeric brush controls.
- `Sources/WatercolorStudio/PaperInspector.swift` — paper selection and canvas summary.
- `Sources/WatercolorStudio/LayersInspector.swift` — layer selection and management.
- `Sources/WatercolorStudio/StudioCommands.swift` — menu/keyboard command definitions and export panel.
- `Tests/WatercolorCoreTests/*.swift` — model, preset, sampling, history, and document tests.
- `Tests/WatercolorEngineTests/WatercolorRendererTests.swift` — Metal behavior and readback tests.
- `scripts/package_app.sh`, `Resources/Info.plist`, `Makefile` — release app packaging.
- `README.md`, `CLAUDE.md` — build, run, test, architecture, and repository navigation.

### Task 1: Foundation and versioned project model

**Files:**
- Create: `Package.swift`
- Create: `Sources/WatercolorCore/ProjectModel.swift`
- Create: `Tests/WatercolorCoreTests/ProjectModelTests.swift`

**Interfaces:**
- Produces: `PaintingProject`, `CanvasSize`, `PaperTexture`, `PaintTool`, `BrushSettings`, `StrokePoint`, `PaintingCommand`, and `PaintLayer` as `Codable`, `Equatable`, `Sendable`, and `Identifiable` where applicable.
- Produces: `PaintingProject.newDefault()` and `PaintingProject.validate() throws`.

- [ ] **Step 1: Write failing model tests**

```swift
@Test func defaultProjectIsValidAndRoundTrips() throws {
    let project = PaintingProject.newDefault()
    try project.validate()
    let data = try JSONEncoder().encode(project)
    #expect(try JSONDecoder().decode(PaintingProject.self, from: data) == project)
}

@Test func oversizedCanvasIsRejected() {
    var project = PaintingProject.newDefault()
    project.canvas = CanvasSize(width: 4097, height: 1200)
    #expect(throws: ProjectValidationError.self) { try project.validate() }
}
```

- [ ] **Step 2: Verify the model tests fail**

Run: `swift test --filter WatercolorCoreTests.ProjectModelTests`

Expected: compilation fails because `PaintingProject` and related types do not exist.

- [ ] **Step 3: Implement the package and model**

Create one executable product and two library products. Define enum cases exactly as the design names them, validate dimension and layer limits, require unique layer identifiers, and initialize a 1,600 × 1,200 cold-press project with one visible layer and a transparent-wash round sable brush.

```swift
public struct PaintingProject: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var canvas: CanvasSize
    public var paper: PaperTexture
    public var layers: [PaintLayer]
    public var commands: [PaintingCommand]

    public static func newDefault() -> Self
    public func validate() throws
}
```

- [ ] **Step 4: Run the focused and full test suites**

Run: `swift test --filter WatercolorCoreTests.ProjectModelTests && swift test`

Expected: both commands pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/WatercolorCore Tests/WatercolorCoreTests/ProjectModelTests.swift
git commit -m "feat: add versioned watercolor project model"
```

### Task 2: Presets and gap-free stroke sampling

**Files:**
- Create: `Sources/WatercolorCore/Presets.swift`
- Create: `Sources/WatercolorCore/StrokeSampler.swift`
- Create: `Tests/WatercolorCoreTests/PresetTests.swift`
- Create: `Tests/WatercolorCoreTests/StrokeSamplerTests.swift`

**Interfaces:**
- Consumes: `BrushSettings`, `StrokePoint`, and preset enums from Task 1.
- Produces: `BrushSettings.applying(_ preset: WatercolorStyle) -> BrushSettings`.
- Produces: `StrokeSampler.interpolate(from:to:spacing:) -> [StrokePoint]`.

- [ ] **Step 1: Write failing preset and interpolation tests**

```swift
@Test func wetOnWetAddsMoreWaterThanDryBrush() {
    let base = BrushSettings.default
    #expect(base.applying(.wetOnWet).water > base.applying(.dryBrush).water)
}

@Test func samplerFillsFastStrokeWithoutLargeGaps() {
    let a = StrokePoint(x: 0, y: 0, pressure: 1, tiltX: 0, tiltY: 0, time: 0)
    let b = StrokePoint(x: 100, y: 0, pressure: 0.5, tiltX: 0.2, tiltY: 0, time: 1)
    let points = StrokeSampler.interpolate(from: a, to: b, spacing: 12)
    #expect(points.count == 9)
    #expect(points.last?.x == 100)
}
```

- [ ] **Step 2: Verify both focused tests fail**

Run: `swift test --filter PresetTests && swift test --filter StrokeSamplerTests`

Expected: compilation fails for missing preset and sampler APIs.

- [ ] **Step 3: Implement deterministic preset mapping and interpolation**

Map all five style presets to concrete opacity, flow, water, granulation, and edge-bloom values. Interpolate location, pressure, tilt, and time linearly; return only the destination when distance is below spacing.

- [ ] **Step 4: Run focused and full tests**

Run: `swift test --filter WatercolorCoreTests && swift test`

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WatercolorCore Tests/WatercolorCoreTests
git commit -m "feat: add watercolor presets and stroke sampling"
```

### Task 3: Validated layer editing and reversible command history

**Files:**
- Create: `Sources/WatercolorCore/ProjectEditor.swift`
- Create: `Tests/WatercolorCoreTests/ProjectEditorTests.swift`

**Interfaces:**
- Consumes: `PaintingProject`, `PaintLayer`, and `PaintingCommand`.
- Produces: mutating `ProjectEditor.addLayer(named:)`, `duplicateLayer(id:)`, `removeLayer(id:)`, `moveLayer(id:to:)`, `mergeDown(id:)`, `append(_:)`, `undo()`, and `redo()`.
- Produces: `ProjectEditor.project` and `ProjectEditor.canUndo/canRedo`.

- [ ] **Step 1: Write failing editor tests**

```swift
@Test func removingTheOnlyLayerKeepsOneLayer() throws {
    var editor = ProjectEditor(project: .newDefault())
    try editor.removeLayer(id: editor.project.layers[0].id)
    #expect(editor.project.layers.count == 1)
}

@Test func undoAndRedoRestoreAStrokeCommand() throws {
    var editor = ProjectEditor(project: .newDefault())
    let command = PaintingCommand.stroke(.fixture(layerID: editor.project.layers[0].id))
    editor.append(command)
    #expect(editor.undo() == command)
    #expect(editor.project.commands.isEmpty)
    #expect(editor.redo() == command)
}
```

- [ ] **Step 2: Verify the editor tests fail**

Run: `swift test --filter ProjectEditorTests`

Expected: compilation fails because `ProjectEditor` is missing.

- [ ] **Step 3: Implement validated mutations and bounded redo storage**

Keep at least one layer, cap layer creation at 12, clear redo after a new command, and make every structural mutation return enough state for exact reversal. Reject missing layer identifiers with `ProjectEditingError.layerNotFound`.

- [ ] **Step 4: Run all core tests**

Run: `swift test --filter WatercolorCoreTests`

Expected: all core tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WatercolorCore/ProjectEditor.swift Tests/WatercolorCoreTests/ProjectEditorTests.swift
git commit -m "feat: add layer editing and command history"
```

### Task 4: Metal pigment, wetness, and composite renderer

**Files:**
- Create: `Sources/WatercolorEngine/ShaderSource.swift`
- Create: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Create: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`

**Interfaces:**
- Consumes: `PaintingProject`, `StrokeCommand`, `PaperTexture`, and ordered layer metadata.
- Produces: `@MainActor final class WatercolorRenderer` with `init(project:device:) throws`, `resizeViewport(_:)`, `render(stroke:) throws`, `replay(project:) throws`, `dry(layerID:steps:) throws`, `draw(in:)`, and `makeCGImage() throws -> CGImage`.
- Produces: `RendererError` cases for unavailable Metal, shader compilation, allocation, unknown layer, and readback.

- [ ] **Step 1: Write failing Metal integration tests**

```swift
@Test @MainActor func redAndBlueWetStrokesMix() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try WatercolorRenderer(project: .testCanvas(64), device: device)
    try renderer.render(stroke: .testLine(color: .red, y: 32, water: 0.9))
    try renderer.render(stroke: .testLine(color: .blue, y: 32, water: 0.9))
    let pixel = try renderer.debugPixel(x: 32, y: 32)
    #expect(pixel.red > 0.1 && pixel.blue > 0.1)
}

@Test @MainActor func eraserLowersConcentration() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let renderer = try WatercolorRenderer(project: .testCanvas(64), device: device)
    try renderer.render(stroke: .testDot(tool: .brush, pressure: 1))
    let before = try renderer.debugPixel(x: 32, y: 32).alpha
    try renderer.render(stroke: .testDot(tool: .eraser, pressure: 1))
    #expect(try renderer.debugPixel(x: 32, y: 32).alpha < before)
}
```

- [ ] **Step 2: Verify renderer tests fail**

Run: `swift test --filter WatercolorRendererTests`

Expected: compilation fails because the engine target and renderer are missing.

- [ ] **Step 3: Implement reusable GPU resources and embedded shaders**

Create 12-slice `rgba16Float` pigment and `r16Float` wetness texture pairs, ping-pong them for simulation, and create one final `bgra8Unorm` composite texture. Compile embedded Metal source once. The stamp kernel must implement every tool and combine shape, hair, texture, pressure, and seeded paper noise. The simulation kernel must diffuse water faster than pigment and evaporate wetness. The composite kernel must honor layer visibility, opacity, order, and paper grain.

- [ ] **Step 4: Implement replay, readback, and focused assertions**

`replay(project:)` clears textures and processes commands in stored order with fixed simulation counts. `makeCGImage()` reads the composite texture into a `CGDataProvider` with top-left orientation. Add debug pixel access only under `DEBUG`.

- [ ] **Step 5: Run engine and full tests**

Run: `swift test --filter WatercolorEngineTests && swift test`

Expected: pigment mixing and erasing assertions pass with no Metal validation errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/WatercolorEngine Tests/WatercolorEngineTests Package.swift
git commit -m "feat: add Metal watercolor simulation engine"
```

### Task 5: Editable document and studio state

**Files:**
- Create: `Sources/WatercolorCore/DocumentCodec.swift`
- Create: `Sources/WatercolorStudio/PaintingDocument.swift`
- Create: `Sources/WatercolorStudio/StudioModel.swift`
- Create: `Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift`

**Interfaces:**
- Consumes: project editor and renderer APIs.
- Produces: `PaintingDocumentCodec.encode(_:)` and `decode(_:)` in WatercolorCore.
- Produces: `PaintingDocument` conforming to `FileDocument`, with custom UTType `com.watercolorstudio.painting` and extension `.watercolor`.
- Produces: `@MainActor final class StudioModel: ObservableObject` with published project, selected layer/tool, brush, zoom, pan, error, and capability state.

- [ ] **Step 1: Write failing document codec tests**

```swift
@Test func codecRejectsNewerSchema() throws {
    var project = PaintingProject.newDefault()
    project.schemaVersion = PaintingProject.currentSchemaVersion + 1
    let data = try JSONEncoder().encode(project)
    #expect(throws: DocumentCodecError.unsupportedSchema(project.schemaVersion)) {
        _ = try PaintingDocumentCodec.decode(data)
    }
}
```

- [ ] **Step 2: Verify the codec test fails**

Run: `swift test --filter PaintingDocumentCodecTests`

Expected: compilation fails because the document codec is missing.

- [ ] **Step 3: Implement codec, FileDocument, and workspace mutation flow**

Encode sorted-key JSON for stable diffs. Validate before encode and after decode. Make `StudioModel` the only object allowed to mutate project state; after each completed stroke it appends the command, updates the bound document through a closure, and publishes an error instead of discarding the project if rendering fails.

- [ ] **Step 4: Run codec and full tests**

Run: `swift test --filter PaintingDocumentCodecTests && swift test`

Expected: schema and round-trip tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/WatercolorCore/DocumentCodec.swift Sources/WatercolorStudio/PaintingDocument.swift Sources/WatercolorStudio/StudioModel.swift Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift Package.swift
git commit -m "feat: add editable watercolor documents and studio state"
```

### Task 6: Metal canvas, tablet input, zoom, and pan

**Files:**
- Create: `Sources/WatercolorCore/CanvasTransform.swift`
- Create: `Sources/WatercolorStudio/MetalCanvasView.swift`
- Create: `Sources/WatercolorStudio/CanvasEventView.swift`
- Create: `Tests/WatercolorCoreTests/CanvasTransformTests.swift`

**Interfaces:**
- Consumes: `StudioModel`, `WatercolorRenderer`, and `StrokeSampler`.
- Produces: `MetalCanvasView: NSViewRepresentable` and `CanvasEventView: MTKView`.
- Emits canvas-coordinate points with normalized pressure and tilt and commits exactly one command per pointer-down/up stroke.

- [ ] **Step 1: Add coordinate-transform tests**

```swift
@Test func viewCenterMapsToCanvasCenterAtFitZoom() {
    let transform = CanvasTransform(viewSize: .init(width: 1000, height: 800), canvasSize: .init(width: 1600, height: 1200), zoom: 1, pan: .zero)
    #expect(transform.canvasPoint(fromView: .init(x: 500, y: 400)) == .init(x: 800, y: 600))
}
```

- [ ] **Step 2: Verify the transform test fails**

Run: `swift test --filter CanvasTransformTests`

Expected: compilation fails because `CanvasTransform` is missing.

- [ ] **Step 3: Implement transforms and the AppKit event bridge**

Subclass `MTKView`; override `mouseDown`, `mouseDragged`, `mouseUp`, `tabletPoint`, `magnify`, and `scrollWheel`. Use event pressure only for valid mouse/tablet event types, fall back to `1`, clamp all input, interpolate using 18% of effective brush diameter, and use Space-drag or middle-button drag for pan.

- [ ] **Step 4: Run tests and build the app target**

Run: `swift test && swift build --product WatercolorStudio`

Expected: tests pass and the native executable links AppKit, SwiftUI, Metal, and MetalKit.

- [ ] **Step 5: Commit**

```bash
git add Sources/WatercolorStudio/MetalCanvasView.swift Sources/WatercolorStudio/CanvasEventView.swift Sources/WatercolorCore/CanvasTransform.swift Tests/WatercolorCoreTests/CanvasTransformTests.swift
git commit -m "feat: add pressure canvas input and viewport controls"
```

### Task 7: Complete studio UI and layer management

**Files:**
- Create: `Sources/WatercolorStudio/WatercolorStudioApp.swift`
- Create: `Sources/WatercolorStudio/StudioView.swift`
- Create: `Sources/WatercolorStudio/ToolRail.swift`
- Create: `Sources/WatercolorStudio/BrushInspector.swift`
- Create: `Sources/WatercolorStudio/PaperInspector.swift`
- Create: `Sources/WatercolorStudio/LayersInspector.swift`

**Interfaces:**
- Consumes: all `StudioModel` published state and methods.
- Produces: document-based app window with tool rail, central canvas, inspector, and toolbar.

- [ ] **Step 1: Implement the studio shell and inspectors**

Use a 52-point tool rail, flexible canvas viewport, and 292-point inspector. Use `ColorPicker` for the native wheel and enumerated pickers for every style, shape, hair, texture, and paper case. Numeric controls must show their current value and support keyboard increments. Layer rows expose selection, visibility, editable name, and opacity; buttons add, duplicate, delete, move, merge, and clear through `StudioModel`.

- [ ] **Step 2: Implement app commands and alert presentation hooks**

Create the `DocumentGroup`, set a minimum window size of 1,050 × 680, add tool shortcuts, bracket size shortcuts, undo/redo, fit, dry layer, and export hooks. Show renderer/document failures through one identifiable alert value.

- [ ] **Step 3: Build and run automated tests**

Run: `swift test && swift build --product WatercolorStudio`

Expected: all tests pass and the app product builds without warnings introduced by these files.

- [ ] **Step 4: Commit**

```bash
git add Sources/WatercolorStudio Tests
git commit -m "feat: build the watercolor studio interface"
```

### Task 8: Undo/replay, merge, dry, and PNG export

**Files:**
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Create: `Sources/WatercolorStudio/StudioCommands.swift`
- Create: `Tests/WatercolorEngineTests/ReplayAndExportTests.swift`

**Interfaces:**
- Consumes: renderer replay/readback and project editor history.
- Produces: `StudioModel.undo()`, `redo()`, `drySelectedLayer()`, `mergeSelectedLayerDown()`, and `exportPNG(to:) async`.

- [ ] **Step 1: Write replay and export tests**

```swift
@Test @MainActor func replayProducesEquivalentPixels() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let project = PaintingProject.twoColorFixture()
    let first = try WatercolorRenderer(project: project, device: device)
    try first.replay(project: project)
    let expected = try first.pixelChecksum()
    let second = try WatercolorRenderer(project: project, device: device)
    try second.replay(project: project)
    #expect(try second.pixelChecksum() == expected)
}
```

- [ ] **Step 2: Verify the focused test fails**

Run: `swift test --filter ReplayAndExportTests`

Expected: compilation fails for missing fixture/checksum/export APIs.

- [ ] **Step 3: Complete replay-backed editing and PNG writing**

Undo and redo must update the document before replay and restore the previous project if replay fails. Merge-down appends an explicit merge command. Dry appends a fixed 24-step dry command. Export uses `CGImageDestination` with `UTType.png.identifier`, writes atomically to the chosen URL, and leaves the document unchanged.

- [ ] **Step 4: Run engine, document, and full tests**

Run: `swift test --filter WatercolorEngineTests && swift test`

Expected: replay checksums match, PNG dimensions match the canvas, and the full suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/WatercolorStudio Sources/WatercolorEngine Tests/WatercolorEngineTests
git commit -m "feat: add durable editing and PNG export"
```

### Task 9: Release packaging and repository guidance

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/package_app.sh`
- Create: `Makefile`
- Create: `README.md`
- Create: `CLAUDE.md`

**Interfaces:**
- Produces: `make test`, `make build`, `make app`, and `make run`.
- Produces: `.build/release/Watercolor Studio.app` with `.watercolor` document registration.

- [ ] **Step 1: Write the package script and application property list**

The script must run `swift build -c release --product WatercolorStudio`, create `Contents/MacOS` and `Contents/Resources`, copy the executable, copy the property list, and fail on every shell error. The property list must declare `LSMinimumSystemVersion` as `14.0`, `NSHighResolutionCapable`, bundle identifier `com.watercolorstudio.app`, and exported UTI `com.watercolorstudio.painting` with extension `watercolor`.

- [ ] **Step 2: Add build commands and concise documentation**

Document prerequisites, first run, tool shortcuts, project format, tests, release packaging, unsigned-app launch behavior, and architecture. `CLAUDE.md` records source/test layout, Swift 6/SwiftUI/Metal stack, and the four verified make commands.

- [ ] **Step 3: Build and inspect the packaged app**

Run: `make test && make app && plutil -lint '.build/release/Watercolor Studio.app/Contents/Info.plist' && test -x '.build/release/Watercolor Studio.app/Contents/MacOS/WatercolorStudio'`

Expected: tests pass, release build succeeds, property list is valid, and the executable exists.

- [ ] **Step 4: Smoke-launch the packaged executable**

Run the executable for five seconds with stdout/stderr captured, then terminate only that exact PID. Expected: it stays alive with no immediate crash or shader-compilation error.

- [ ] **Step 5: Commit**

```bash
git add Resources scripts Makefile README.md CLAUDE.md
git commit -m "build: package the native macOS application"
```

### Task 10: Release verification and scope audit

**Files:**
- Modify: `README.md` only if a verified command or behavior differs.
- Modify: `docs/program/watercolor-studio-program.md` to record final milestone status and closed risks.

**Interfaces:**
- Produces: a tested unsigned macOS app bundle and an evidence-backed handoff.

- [ ] **Step 1: Run clean verification**

Run: `swift package clean && make test && make app`

Expected: a clean checkout-equivalent build and all tests pass.

- [ ] **Step 2: Inspect repository and release artifacts**

Run: `git diff --check && git status --short && find '.build/release/Watercolor Studio.app' -maxdepth 3 -type f -print`

Expected: no whitespace errors; only the intentional program-status change is pending; the bundle contains the executable and property list.

- [ ] **Step 3: Perform the feature audit**

Confirm each paper, style, brush shape, hair, texture, painting tool, and layer action has a visible UI control and a concrete engine/model case. Confirm save/open, undo/redo, zoom/pan, dry, and PNG export are wired from UI to implementation.

- [ ] **Step 4: Update program status and commit**

Mark M1–M6 complete only when their evidence passes, move mitigated risks out of the active table, and record the final build/test commands.

```bash
git add docs/program/watercolor-studio-program.md README.md
git commit -m "docs: record watercolor studio release verification"
```

- [ ] **Step 5: Review final history**

Run: `git log --oneline --decorate -12 && git status --short --branch`

Expected: milestone commits are present and the working tree is clean.
