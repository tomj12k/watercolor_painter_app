# Brush Dynamics and Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every brush shape, hair, texture, and watercolor style immediately recognizable while adding safe artist controls for spacing, rotation, bristle strength, and texture strength.

**Architecture:** Schema version 3 records dynamics and a hidden behavior version. Legacy strokes retain shader behavior version 0; new strokes use direction-aware version 1. CPU code supplies tangent/orientation and stable seeds, while one Metal pipeline branches by behavior version and brush enums.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, AppKit, Metal Shading Language.

**Spec:** `docs/superpowers/specs/2026-08-15-production-brush-dynamics-design.md`

## Global Constraints

- Preserve version-1 and version-2 document rendering after migration.
- Use semantic image metrics with tolerance, not pixel-perfect cross-GPU goldens.
- Keep one shared GPU brush pipeline and no third-party UI or image libraries.
- Keep spacing above 0.08 brush diameters and 0.75 physical pixels.
- Every production edit follows RED, GREEN, refactor, then an atomic commit.

---

### Task 0: Resolve carried preview terminal races

**Files:**
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Modify: `Sources/WatercolorStudio/CanvasEventView.swift`
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`
- Modify: `Tests/WatercolorStudioTests/StudioModelTests.swift`
- Modify: `Tests/WatercolorStudioTests/CanvasEventViewTests.swift`

**Interfaces:**
- Keeps one trailing canonical batch of 1...8 points unrendered until pointer-up fields are final.
- Makes asynchronous cancel/finish cleanup object- and phase-owned; stale cleanup cannot clear a later transaction.
- Preserves typed point-capacity exhaustion through exactly one cancellation.

- [ ] **Step 1: Write deterministic RED tests for the three carried findings**

Cover an exact 8/16-point stroke whose same-position pointer-up changes pressure, tilt, and time; live pixels after finish must equal fresh replay and save/reopen. Suspend a real renderer append while capacity cancellation starts and assert the drain cannot start a second cancellation or replace the actionable error. Suspend actual GPU finish completion, cancel it, begin a later stroke after restoration, and assert stale finish/restore work cannot clear or poison the later transaction. Use continuations or command-completion seams, never sleeps.

- [ ] **Step 2: Keep the trailing canonical batch until finish**

Preview only canonical batches strictly before the final batch, so `StrokePreviewTransaction` retains 1...8 trailing points. Finish renders that bounded batch after same-position endpoint fields are finalized. Do not restore or re-encode the earlier canonical prefix. Prove brush, smudge, smear, wet non-selected layers, cumulative work budget, and absolute seed/direction indices remain exact.

- [ ] **Step 3: Make cancellation phase and transaction owned**

Renderer async finish/cancel/replay may clear `strokePreview` only when the exact transaction object and expected phase still own it. Studio drain failure during `.cancelling` is stale cleanup and must not initiate cancellation again or replace the pending exhaustion reason. Keep painting/project edits disabled until the authoritative cancellation resolves.

- [ ] **Step 4: Run focused, full, Metal, and latency gates**

Run: `swift test --filter WatercolorRendererTests && swift test --filter StudioModelTests && swift test --filter CanvasEventViewTests && swift test`

Then run Metal validation and the configured-maximum preview latency fixture. Require exact replay, no duplicate cancellation, stable exhaustion text, and continued painting.

- [ ] **Step 5: Commit**

```bash
git add Sources/WatercolorEngine Sources/WatercolorStudio Tests/WatercolorEngineTests Tests/WatercolorStudioTests
git commit -m "fix: serialize preview terminal ownership"
```

### Task 1: Schema-version-3 brush dynamics and migration

**Files:**
- Modify: `Sources/WatercolorCore/ProjectModel.swift`
- Modify: `Sources/WatercolorCore/DocumentCodec.swift`
- Modify: `Sources/WatercolorCore/Presets.swift`
- Modify: `Tests/WatercolorCoreTests/ProjectModelTests.swift`
- Modify: `Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift`
- Modify: `Tests/WatercolorCoreTests/PresetTests.swift`

**Interfaces:**
- Produces `BrushSettings.behaviorVersion: Int`
- Produces `spacing`, `rotation`, `bristleStrength`, and `textureStrength` as `Double`
- Produces `BrushSettings.legacyDynamics` and version-1 defaults in `.default`

- [ ] **Step 1: Write migration and validation RED tests**

```swift
@Test func versionTwoBrushesMigrateToLegacyBehaviorWithoutVisualFieldLoss() throws {
    let decoded = try PaintingDocumentCodec.decode(versionTwoFixture)
    let stroke = try #require(decoded.commands.compactMap { command -> StrokeCommand? in
        guard case let .stroke(stroke) = command else { return nil }
        return stroke
    }.first)
    #expect(decoded.schemaVersion == 3)
    #expect(stroke.brush.behaviorVersion == 0)
    #expect(stroke.brush.spacing == 0.18)
    #expect(stroke.brush.rotation == 0)
    #expect(stroke.brush.bristleStrength == 0.5)
    #expect(stroke.brush.textureStrength == 0.5)
}

@Test func invalidDynamicsFailValidation() {
    var stroke = StrokeCommand.testStroke()
    stroke.brush.spacing = .nan
    var invalidProject = project
    invalidProject.commands.append(.stroke(stroke))
    #expect(throws: ProjectValidationError.invalidBrushParameter(stroke.id)) {
        try invalidProject.validate()
    }
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter PaintingDocumentCodecTests && swift test --filter ProjectModelTests`

Expected: compile failures for missing fields and schema expectation failures.

- [ ] **Step 3: Add explicit `BrushSettings` Codable behavior**

Decode missing dynamics to legacy defaults. Encode every field in schema version 3. Validate behavior versions 0 and 1, spacing 0.08...0.60, rotation -180...180, and both strengths 0...1.

- [ ] **Step 4: Migrate version 1 and 2 commands without changing old colors twice**

Keep the existing version-1 sRGB migration. Map every legacy stroke to behavior version 0 and dynamics defaults, then set the project schema to 3. New `BrushSettings.default` uses behavior version 1.

- [ ] **Step 5: Preserve dynamics through style application**

Extend `PresetTests` so every style preserves behavior version, spacing, rotation, bristle strength, texture strength, shape, hair, texture, color, and size.

- [ ] **Step 6: Run core tests and commit**

Run: `swift test --filter PresetTests && swift test --filter ProjectModelTests && swift test --filter PaintingDocumentCodecTests`

```bash
git add Sources/WatercolorCore Tests/WatercolorCoreTests
git commit -m "feature: add versioned brush dynamics"
```

### Task 2: Perceptual brush metric test harness

**Files:**
- Create: `Tests/WatercolorEngineTests/BrushPhenotypeMetrics.swift`
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`

**Interfaces:**
- Produces `BrushPhenotypeMetrics` with `area`, `aspectRatio`, `orientation`, `edgeRoughness`, `voidRatio`, `laneCount`, `pigmentMass`, `wetnessMass`, `spreadRadius`, and `edgeConcentration`.
- Produces deterministic canonical horizontal, vertical, curved, and tilted strokes.

- [ ] **Step 1: Write independent metric-unit and fixture tests**

```swift
@Test func phenotypeMetricsMeasureKnownSyntheticMask() {
    let metrics = BrushPhenotypeMetrics.measure(syntheticEllipseWithTwoVoids)
    #expect(abs(metrics.aspectRatio - 2) < 0.1)
    #expect(metrics.laneCount == 2)
    #expect(metrics.voidRatio > 0)
}
```

- [ ] **Step 2: Run the metric tests and verify RED**

Run: `swift test --filter BrushPhenotypeMetricTests`

Expected: compile failure because `BrushPhenotypeMetrics` does not exist.

- [ ] **Step 3: Implement metrics from full renderer outputs**

Read alpha, pigment, and wetness fields through existing debug readback helpers. Compute moments and histograms with hand-derived formulas. Do not reuse shader logic in expectations.

- [ ] **Step 4: Add passing deterministic renderer-fixture characterization**

Render canonical horizontal, vertical, curved, and tilted strokes twice and assert every metric is deterministic within tolerance and finite. Record current values only as diagnostics; Tasks 3 and 4 add customer-visible thresholds immediately before their implementations.

- [ ] **Step 5: Keep old enum checksum test only as a smoke check**

Rename it to state that it checks deterministic participation, not customer-visible separation.

- [ ] **Step 6: Commit the green metric harness**

```bash
git add Tests/WatercolorEngineTests
git commit -m "test: define perceptual brush phenotypes"
```

### Task 3: Direction-aware shape rendering

**Files:**
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Modify: `Sources/WatercolorEngine/ShaderSource.swift`
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`

**Interfaces:**
- Extends `StampParameters` with behavior version, tangent, rotation, shape aspect, bristle strength, and texture strength.
- Consumes absolute point index and previous/next point from incremental preview and replay.

- [ ] **Step 1: Add RED orientation tests**

Render horizontal and vertical flat/rigger strokes and assert the measured footprint rotates with the path. Render a tilted tablet fixture and assert tilt overrides tangent before applying rotation.

- [ ] **Step 2: Run orientation tests and verify RED**

Run: `swift test --filter WatercolorRendererTests/versionOneShapeOrientationFollowsStroke`

Expected: current axis-aligned stamps fail.

- [ ] **Step 3: Encode tangent and rotation per point**

```swift
let direction = normalizedDirection(previous: previousPoint, point: point, next: nextPoint)
let stylus = normalizedTilt(point)
let base = stylus ?? direction
let rotated = base.rotated(byDegrees: stroke.brush.rotation)
```

Round ignores direction. Flat, filbert, fan, and rigger use the rotated brush-local coordinate system. Behavior version 0 retains the current unrotated path.

- [ ] **Step 4: Implement distinct shape distance functions**

Use reviewed constants for chisel aspect, filbert capsule, five fan lobes, and narrow rigger width. Keep antialiasing widths proportional to the footprint so small brushes remain stable.

- [ ] **Step 5: Run phenotype, replay, preview, and Metal tests**

Run: `swift test --filter WatercolorRendererTests && swift test --filter StudioModelTests/multiUpdatePreviewCommitExactlyMatchesFreshSemanticReplay`

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/WatercolorEngine Tests/WatercolorEngineTests
git commit -m "feature: orient watercolor brush shapes"
```

### Task 4: Stable hair, texture, and style behavior

**Files:**
- Modify: `Sources/WatercolorEngine/ShaderSource.swift`
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`

**Interfaces:**
- Consumes behavior version and dynamics from `StampParameters`.
- Produces stable brush-local hair lanes and texture-strength interpolation.

- [ ] **Step 1: Add RED lane-persistence and strength-control tests**

Assert that bristle gaps remain correlated along a line, bristle strength zero approaches the solid intrinsic footprint, and texture strength one increases the selected texture metric without changing another dynamics field.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter WatercolorRendererTests/versionOneBristleLanesPersist && swift test --filter WatercolorRendererTests/textureStrengthControlsSelectedTexture`

Expected: current point-index noise produces uncorrelated lanes or missing controls.

- [ ] **Step 3: Implement stroke-stable hair coordinates**

Seed lanes from the stroke UUID without the point index. Evaluate lanes in rotated brush-local cross-stroke coordinates. Blend intrinsic hair coverage with solid coverage by bristle strength.

- [ ] **Step 4: Implement texture-strength interpolation**

Keep smooth equal to base coverage. Granulating follows paper noise, dry produces connected skips, mottled uses low-frequency variation, and salt creates sparse centers and rings. Blend by texture strength.

- [ ] **Step 5: Strengthen style deposition and water ratios**

Use distinct paint/water/edge constants to satisfy the semantic thresholds. Do not add a separate pipeline. Behavior version 0 retains current constants.

- [ ] **Step 6: Run all renderer and migration tests**

Run: `swift test --filter WatercolorRendererTests && swift test --filter PaintingDocumentCodecTests`

Expected: all tests pass; legacy checksums remain stable.

- [ ] **Step 7: Commit**

```bash
git add Sources/WatercolorEngine Tests/WatercolorEngineTests
git commit -m "feature: differentiate brush hair and texture"
```

### Task 5: Brush inspector dynamics and artist-language guidance

**Files:**
- Modify: `Sources/WatercolorStudio/BrushInspector.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Create: `Tests/WatercolorStudioTests/BrushInspectorModelTests.swift`
- Modify: `Tests/WatercolorStudioTests/CanvasEventViewTests.swift`

**Interfaces:**
- Produces `StudioModel.setBrushSpacing`, `setBrushRotation`, `setBristleStrength`, `setTextureStrength`, and `resetBrushDynamics`.
- Produces display descriptions for style, shape, hair, and texture.

- [ ] **Step 1: Write RED model and description tests**

```swift
@Test func dynamicsClampAndResetWithoutChangingIdentity() throws {
    model.brush.shape = .fan
    model.brush.hair = .bristle
    model.setBrushSpacing(99)
    model.setBrushRotation(-999)
    model.resetBrushDynamics()
    #expect(model.brush.shape == .fan)
    #expect(model.brush.hair == .bristle)
    #expect(model.brush.spacing == 0.18)
    #expect(model.brush.rotation == 0)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter BrushInspectorModelTests`

Expected: compile failure because dynamics APIs and descriptions do not exist.

- [ ] **Step 3: Group inspector controls**

Use section titles Identity, Color, Paint, and Dynamics. Dynamics contains spacing 8...60%, rotation -180...180 degrees, bristle 0...100%, texture strength 0...100%, and Reset Dynamics.

- [ ] **Step 4: Add artist-language descriptions and accessibility**

Show one concise line for the selected style, shape, hair, and texture. Give every slider, stepper, picker, and reset button a stable accessibility label, value, and help string.

- [ ] **Step 5: Prove pointer-down snapshots dynamics**

Extend `CanvasEventViewTests` so a control change during a stroke does not alter that stroke, while the next stroke uses the new dynamics.

- [ ] **Step 6: Run studio tests and build**

Run: `swift test --filter WatercolorStudioTests && make build`

Expected: all tests and the debug app build pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/WatercolorStudio Tests/WatercolorStudioTests
git commit -m "feature: add adjustable brush dynamics"
```

### Task 6: Phase verification and visual review

**Files:**
- Modify only files required by verified review findings.

**Interfaces:**
- Consumes all schema, shader, and inspector contracts.
- Produces an approved brush matrix and clean phase boundary.

- [ ] **Step 1: Run clean functional and release gates**

Run: `swift package clean && make test && make app`

- [ ] **Step 2: Run Metal API/GPU validation**

Run: `env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 swift test --filter WatercolorRendererTests`

- [ ] **Step 3: Generate and inspect a deterministic brush matrix**

Add an environment-gated test helper that exports one PNG matrix with rows for shape, hair, texture, and style. Open the image and confirm the semantic metrics correspond to visible differences. Do not commit generated PNG output.

- [ ] **Step 4: Exercise inspector controls with Computer Use**

Launch the isolated release app, create a disposable document, operate every identity and dynamics control through accessibility labels, and paint representative strokes. Preserve any pre-existing user process and document.

- [ ] **Step 5: Request code and UX review**

Review schema compatibility, shader bounds, perceptual thresholds, control discoverability, minimum-window scrolling, and preview performance. Add RED tests for accepted findings.

- [ ] **Step 6: Commit review remediation**

```bash
git add Sources Tests
git commit -m "fix: address brush dynamics review"
```
