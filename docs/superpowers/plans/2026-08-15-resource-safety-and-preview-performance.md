# Resource Safety and Preview Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reject unsafe documents and Metal workloads before allocation or dispatch, make stroke finalization race-free, reuse bounded preview storage, and pass only cadence-independent mouse-point deltas during live painting.

**Architecture:** Pure policy types perform document-size, memory, and thread-cost admission before decoding, resource creation, or work encoding. A generation-tagged preview transaction resolves finish or cancel exactly once. The renderer owns one reusable single-layer preview snapshot. `CanvasStrokeBuilder` uses residual arc length to retain one durable stroke while returning appended deltas to a bounded latest-wins mailbox.

**Tech Stack:** Swift 6, Swift Testing, AppKit, SwiftUI, Metal, MetalKit.

**Spec:** `docs/superpowers/specs/2026-08-15-production-brush-dynamics-design.md`

## Global Constraints

- Support macOS 14 and later with no third-party dependencies.
- Preserve deterministic replay and exact preview-commit equivalence.
- Reject unsafe work before Metal allocation or command-buffer submission.
- Keep `make app` as the unsigned local-development bundle.
- Every production edit follows RED, GREEN, refactor, then an atomic commit.

---

### Task 0: Bound document decode and command growth

**Files:**
- Modify: `Sources/WatercolorCore/DocumentCodec.swift`
- Modify: `Sources/WatercolorCore/ProjectModel.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Modify: `Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift`
- Modify: `Tests/WatercolorStudioTests/StudioModelTests.swift`

**Interfaces:**
- Produces: `PaintingDocumentCodec.maximumDocumentBytes`
- Produces: `PaintingProject.maximumTotalStrokePointCount`
- Produces: `ProjectValidationError.documentByteLimitExceeded` and `totalStrokePointLimitExceeded`
- Produces: `StudioModel` command-capacity preflight before render or preview admission.

- [ ] **Step 1: Write RED tests for byte, aggregate-point, and command-boundary admission**

Create a data buffer one byte above the document limit and assert it is rejected before either JSON decode. Create a valid-size project whose strokes exceed the aggregate point limit and assert validation rejects it. Start at exactly `maximumCommandCount` and assert a new preview/complete stroke is rejected before renderer mutation.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter PaintingDocumentCodecTests && swift test --filter StudioModelTests/commandCapacityIsCheckedBeforeRendering`

Expected: missing limits and a renderer/project divergence at the command boundary.

- [ ] **Step 3: Enforce limits before expensive work**

Check `data.count` before constructing `JSONDecoder`. Use a conservative 256 MiB maximum because the format is uncompressed JSON; aggregate decoded stroke points with checked addition during project validation and cap them at 2,000,000. Keep per-stroke limits unchanged.

- [ ] **Step 4: Preflight new commands before preview and synchronous rendering**

Add one shared capacity predicate used by `beginStrokePreview` and `completeStroke`. On rejection, leave renderer, editor, and document unchanged and publish a recoverable capacity failure.

- [ ] **Step 5: Run focused tests and commit**

Run: `swift test --filter PaintingDocumentCodecTests && swift test --filter ProjectModelTests && swift test --filter StudioModelTests`

```bash
git add Sources/WatercolorCore Sources/WatercolorStudio/StudioModel.swift Tests/WatercolorCoreTests Tests/WatercolorStudioTests/StudioModelTests.swift
git commit -m "fix: bound document and command growth"
```

### Task 1: Checked renderer resource admission

**Files:**
- Create: `Sources/WatercolorEngine/RendererResourcePolicy.swift`
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Create: `Tests/WatercolorEngineTests/RendererResourcePolicyTests.swift`
- Modify: `Tests/WatercolorStudioTests/StudioDocumentHostTests.swift`

**Interfaces:**
- Produces: `RendererResourcePolicy.init(maximumWorkingSetBytes:)`
- Produces: `RendererResourcePolicy.admit(width:height:layerCapacity:structuralCandidateCapacity:) throws`
- Produces: `RendererResourceEstimate.liveBytes`, `previewBytes`, `candidateBytes`, and `totalBytes`
- Produces: `RendererError.resourceBudgetExceeded(required: Int, available: Int)`

- [ ] **Step 1: Write failing checked-arithmetic and admission tests**

```swift
@Test func unsafeMaximumProjectIsRejectedBeforeRendererAllocation() throws {
    let policy = RendererResourcePolicy(maximumWorkingSetBytes: 2 * 1024 * 1024 * 1024)
    #expect(throws: RendererError.self) {
        try policy.admit(width: 4096, height: 4096, layerCapacity: 12, structuralCandidateCapacity: 12)
    }
}

@Test func defaultTwelveLayerProjectFitsTheReferenceBudget() throws {
    let policy = RendererResourcePolicy(maximumWorkingSetBytes: 2 * 1024 * 1024 * 1024)
    let estimate = try policy.admit(
        width: 1600, height: 1200, layerCapacity: 12, structuralCandidateCapacity: 12
    )
    #expect(estimate.totalBytes < policy.maximumWorkingSetBytes)
}

@Test func estimateRejectsIntegerOverflow() {
    let policy = RendererResourcePolicy(maximumWorkingSetBytes: .max)
    #expect(throws: RendererError.self) {
        try policy.admit(width: .max, height: .max, layerCapacity: 12, structuralCandidateCapacity: 12)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter RendererResourcePolicyTests`

Expected: compile failure because `RendererResourcePolicy` does not exist.

- [ ] **Step 3: Implement checked estimates and device policy**

```swift
struct RendererResourcePolicy: Sendable {
    static let absoluteMaximumBytes = 2 * 1024 * 1024 * 1024
    static let fallbackMaximumBytes = 512 * 1024 * 1024

    let maximumWorkingSetBytes: Int

    static func live(device: MTLDevice) -> Self {
        let recommended = Int(clamping: device.recommendedMaxWorkingSetSize)
        let fraction = recommended / 100 * 35
        return Self(maximumWorkingSetBytes: min(max(fraction, fallbackMaximumBytes), absoluteMaximumBytes))
    }

    @discardableResult
    func admit(
        width: Int,
        height: Int,
        layerCapacity: Int,
        structuralCandidateCapacity: Int
    ) throws -> RendererResourceEstimate {
        // Use multipliedReportingOverflow and addedReportingOverflow for every term.
        // live: pixelCount * (layerCapacity * 20 + 8)
        // preview: pixelCount * 10 for one pigment and wetness slice
        // candidate: pixelCount * (structuralCandidateCapacity * 20 + 8)
        // Throw resourceBudgetExceeded on overflow or total > maximumWorkingSetBytes.
    }
}
```

- [ ] **Step 4: Admit before renderer and candidate allocation**

Call the policy before `makeTextures`, preview snapshot creation, and structural candidate creation. Preserve the old renderer and document on rejection. Map the error to: “This canvas needs X MiB, but Watercolor Studio can safely use Y MiB. Reduce the canvas size or layer count.”

- [ ] **Step 5: Run focused and nearby tests**

Run: `swift test --filter RendererResourcePolicyTests && swift test --filter StudioDocumentHostTests && swift test --filter WatercolorRendererTests`

Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/WatercolorEngine Tests/WatercolorEngineTests/RendererResourcePolicyTests.swift Tests/WatercolorStudioTests/StudioDocumentHostTests.swift
git commit -m "fix: admit renderer resources before allocation"
```

### Task 2: Bounded simulation and dry-work admission

**Files:**
- Create: `Sources/WatercolorEngine/RendererWorkPolicy.swift`
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Create: `Tests/WatercolorEngineTests/RendererWorkPolicyTests.swift`
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`
- Modify: `Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift`

**Interfaces:**
- Produces: `RendererWorkPolicy.init(maximumCommandThreads:maximumProjectThreads:)`
- Produces: `RenderWorkBudget.consume(regionArea:steps:sliceDepth:passCount:) throws`
- Produces: `RendererError.workBudgetExceeded(required: UInt64, available: UInt64)`
- Consumes: actual region, step, and depth values at every simulation dispatch.

- [ ] **Step 1: Write the hostile-document RED tests**

```swift
@Test func maximumCanvasAndDryStepsAreRejectedBeforeSubmission() throws {
    let policy = RendererWorkPolicy(
        maximumCommandThreads: 1_000_000_000,
        maximumProjectThreads: 2_000_000_000
    )
    var budget = policy.makeProjectBudget()
    #expect(throws: RendererError.self) {
        try budget.consume(
            regionArea: 4096 * 4096,
            steps: 4096,
            sliceDepth: 1,
            passCount: 2
        )
    }
}

@Test func normalDryWorkFitsTheBudget() throws {
    let policy = RendererWorkPolicy.live
    var budget = policy.makeProjectBudget()
    try budget.consume(regionArea: 1600 * 1200, steps: 24, sliceDepth: 1, passCount: 2)
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter RendererWorkPolicyTests`

Expected: compile failure because `RendererWorkPolicy` does not exist.

- [ ] **Step 3: Implement checked thread accounting**

```swift
struct RendererWorkPolicy: Sendable {
    static let live = Self(
        maximumCommandThreads: 1_000_000_000,
        maximumProjectThreads: 2_000_000_000
    )
    let maximumCommandThreads: UInt64
    let maximumProjectThreads: UInt64
    func makeProjectBudget() -> RenderWorkBudget { /* zero consumed work */ }
}
```

Use `multipliedReportingOverflow` for `area * steps * depth * passCount`. Count simulation and synchronization as two passes. Track command and project totals. Throw before calling `dispatchThreads`.

- [ ] **Step 4: Thread the throwing budget through replay and live rendering**

Make `encodeSimulation`, `encodeActiveSimulation`, `encodeStrokeAndSimulation`, dry replay, and their callers propagate errors. Start a project budget at replay entry and a command budget at public render entry. Do not clamp persisted dry steps.

- [ ] **Step 5: Prove no Metal preview/replay command is submitted on rejection**

Add a command-buffer label counter to the hostile fixture and assert zero `Watercolor replay` submissions after work admission fails.

- [ ] **Step 6: Run focused and full renderer tests**

Run: `swift test --filter RendererWorkPolicyTests && swift test --filter WatercolorRendererTests && swift test --filter PaintingDocumentCodecTests`

Expected: all selected tests pass, including the accepted normal dry fixture.

- [ ] **Step 7: Commit**

```bash
git add Sources/WatercolorEngine Tests/WatercolorEngineTests Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift
git commit -m "fix: bound watercolor replay work"
```

### Task 3: Reusable one-slice preview snapshots

**Files:**
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`
- Modify: `Tests/WatercolorStudioTests/StudioModelTests.swift`

**Interfaces:**
- Produces renderer-owned `previewPigmentSnapshot: MTLTexture` and `previewWetnessSnapshot: MTLTexture`
- Produces debug identities and allocation count in `RendererDebugResources`
- Consumes the active layer slice during snapshot capture and restore.

- [ ] **Step 1: Write the pointer-down allocation RED test**

```swift
@Test func repeatedStrokesReuseSingleLayerPreviewTextures() async throws {
    let renderer = try WatercolorRenderer(project: project, device: device)
    let before = renderer.debugResources.previewTextures
    for index in 0..<20 {
        let stroke = StrokeCommand.testDot(layerID: layer.id, x: Double(20 + index), y: 32)
        try renderer.beginStrokePreview(stroke)
        try await renderer.updateStrokePreview(stroke)
        try await renderer.finishStrokePreview(stroke)
    }
    #expect(renderer.debugResources.previewTextures == before)
    #expect(renderer.debugResources.previewArrayLength == 1)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter WatercolorRendererTests/repeatedStrokesReuseSingleLayerPreviewTextures`

Expected: compile failure because the debug fields do not exist, followed by an allocation-identity failure once exposed.

- [ ] **Step 3: Allocate reusable 2D snapshot textures at renderer initialization**

Create one `.rgba16Float` pigment texture and one `.r16Float` wetness texture with canvas width and height. Do not set a texture-array length. Include their bytes in `RendererResourcePolicy`.

- [ ] **Step 4: Capture and restore only the selected slice**

Use blit copies with `sourceSlice` or `destinationSlice` set to the transaction’s layer slice and slice zero for the 2D snapshot. Remove `makeStrokePreviewSnapshot` from `beginStrokePreview`.

- [ ] **Step 5: Run preview, cancellation, failure, and exact-replay tests**

Run: `swift test --filter StudioModelTests && swift test --filter WatercolorRendererTests`

Expected: all tests pass; repeated pointer-down reuses the two snapshot texture identities.

- [ ] **Step 6: Commit**

```bash
git add Sources/WatercolorEngine/WatercolorRenderer.swift Tests/WatercolorEngineTests/WatercolorRendererTests.swift Tests/WatercolorStudioTests/StudioModelTests.swift
git commit -m "perf: reuse single-layer preview snapshots"
```

### Task 4: Generation-safe preview finalization

**Files:**
- Modify: `Sources/WatercolorStudio/CanvasEventView.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Modify: `Tests/WatercolorStudioTests/CanvasEventViewTests.swift`
- Modify: `Tests/WatercolorStudioTests/StudioModelTests.swift`

**Interfaces:**
- Produces: `StrokePreviewAdmission` from `StudioModel.beginStrokePreview(_:)`
- Produces: a monotonically increasing preview generation stored with the active stroke ID.
- Guarantees: finish and cancel resolve a renderer transaction exactly once.

- [ ] **Step 1: Write controlled-completion RED tests**

Inject a renderer preview operation whose update and finish suspensions can be released by the test. Cover: cancel while finish is suspended; failure while cancel runs; and a second pointer-down while the first stroke is finalizing. Assert no canceled stroke is recorded or published, the renderer checksum matches the project, and a rejected second begin never leaves a `CanvasStrokeBuilder` behind.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter StudioModelTests/previewCancelCannotCommitAfterSuspendedFinish && swift test --filter CanvasEventViewTests/rejectedPreviewAdmissionDoesNotBuildStroke`

Expected: the canceled finish resumes and commits, and the view can retain an unadmitted second gesture.

- [ ] **Step 3: Add an explicit preview transaction state machine**

Represent idle, active, and finalizing states with stroke ID plus generation. Capture both values before each `await`; after every suspension, require that the same generation is still finalizing before calling `recordRenderedStroke`, appending the editor command, or publishing. Invalidate the generation before cancellation and make renderer finish/cancel idempotently reject stale transaction IDs.

- [ ] **Step 4: Make input admission explicit**

Return `.accepted` or `.busy`/`.unavailable` from `beginStrokePreview`. `CanvasEventView` creates or retains a builder only after `.accepted`; while finalization is active, `capabilities.canPaint` is false and the cursor/accessibility help communicates “Finishing stroke.” This makes the brief busy interval explicit instead of silently dropping a completed gesture.

- [ ] **Step 5: Verify rollback failure is not swallowed**

If cancel or replay restoration fails, disable painting, expose a typed renderer recovery error, and keep the document unchanged until a successful renderer rebuild. Add a test that injects restoration failure and asserts `canPaint == false`.

- [ ] **Step 6: Run tests and commit**

Run: `swift test --filter StudioModelTests && swift test --filter CanvasEventViewTests && swift test --filter WatercolorRendererTests`

```bash
git add Sources/WatercolorStudio Sources/WatercolorEngine/WatercolorRenderer.swift Tests/WatercolorStudioTests Tests/WatercolorEngineTests/WatercolorRendererTests.swift
git commit -m "fix: serialize stroke preview finalization"
```

### Task 5: Cadence-independent sampling and point budgets

**Files:**
- Modify: `Sources/WatercolorCore/StrokeSampler.swift`
- Modify: `Sources/WatercolorStudio/CanvasEventView.swift`
- Modify: `Tests/WatercolorCoreTests/StrokeSamplerTests.swift`
- Modify: `Tests/WatercolorStudioTests/CanvasEventViewTests.swift`

**Interfaces:**
- Produces: residual-distance sampling state owned by `CanvasStrokeBuilder`.
- Guarantees: identical geometric paths sampled at coarse and fine event cadences produce equivalent point positions within tolerance.
- Guarantees: no append allocates or stores beyond `maximumStrokePointCount`.

- [ ] **Step 1: Write cadence, pressure, and exhaustion RED tests**

Feed the same polyline as one long event and as hundreds of short events; compare generated positions and endpoint. Repeat at pressure zero and one and assert sampling count is independent of pressure. Exercise a size-one stroke longer than the point budget and assert bounded storage with a recoverable admission result.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter StrokeSamplerTests && swift test --filter CanvasStrokeBuilderTests`

Expected: event partitioning changes the samples, pressure changes sample count, and the long path can exceed the durable point limit.

- [ ] **Step 3: Implement residual arc-length sampling**

Track distance remaining to the next sample across events. Base spacing on brush size with a 0.75-pixel physical floor; do not multiply geometry cadence by pressure. Skip zero-contact deposition without generating extra simulation samples. Interpolate pressure, tilt, and time at geometric sample positions and include the final pointer-up endpoint once.

- [ ] **Step 4: Bound point production before allocation**

Compute each batch’s maximum remaining capacity, append no more than that capacity, and return a typed exhaustion result. End the active preview consistently when exhausted; never render points that cannot be persisted.

- [ ] **Step 5: Run tests and commit**

Run: `swift test --filter StrokeSamplerTests && swift test --filter CanvasStrokeBuilderTests && swift test --filter StudioModelTests`

```bash
git add Sources/WatercolorCore/StrokeSampler.swift Sources/WatercolorStudio/CanvasEventView.swift Tests/WatercolorCoreTests/StrokeSamplerTests.swift Tests/WatercolorStudioTests/CanvasEventViewTests.swift
git commit -m "perf: make stroke sampling cadence independent"
```

### Task 6: Incremental preview delta mailbox

**Files:**
- Modify: `Sources/WatercolorStudio/CanvasEventView.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Modify: `Sources/WatercolorEngine/WatercolorRenderer.swift`
- Modify: `Tests/WatercolorStudioTests/CanvasEventViewTests.swift`
- Modify: `Tests/WatercolorStudioTests/StudioModelTests.swift`
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`

**Interfaces:**
- Produces: `CanvasStrokeBuilder.append(_:) -> [StrokePoint]`
- Produces: `StudioModel.appendStrokePreview(id: UUID, points: [StrokePoint])`
- Produces: `WatercolorRenderer.appendStrokePreview(id: UUID, points: [StrokePoint]) async throws`
- Keeps: `finishStrokePreview(_ completeStroke: StrokeCommand) async throws`

- [ ] **Step 1: Write RED tests for exact deltas and bounded pending state**

```swift
@Test func builderReturnsOnlyNewInterpolatedPoints() {
    var builder = CanvasStrokeBuilder(canvasSize: CGSize(width: 512, height: 512))
    builder.begin(layerID: layerID, tool: .brush, brush: .default, point: start)
    let appended = builder.append(end)
    #expect(appended == Array(builder.currentStroke!.points.dropFirst()))
}

@Test func rapidUpdatesQueueOnlyUnsubmittedPoints() async throws {
    model.beginStrokePreview(initialStroke)
    for batch in pointBatches { model.appendStrokePreview(id: initialStroke.id, points: batch) }
    #expect(model.pendingStrokePreviewPointCountForTesting == pointBatches.joined().count)
    await model.commitStrokePreview(completeStroke)
    #expect(try renderer.studioChecksum() == replayed.studioChecksum())
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter CanvasEventViewTests/builderReturnsOnlyNewInterpolatedPoints && swift test --filter StudioModelTests/rapidUpdatesQueueOnlyUnsubmittedPoints`

Expected: compile failure because append returns `Void` and delta APIs do not exist.

- [ ] **Step 3: Return appended points from the builder**

Compute interpolation once, append it to the durable stroke, and return the same array. Mouse and tablet event paths pass that delta to the model.

- [ ] **Step 4: Replace pending full strokes with a delta accumulator**

Store `pendingStrokePreviewPoints: [StrokePoint]`. Appending a new batch extends only that array. The drain takes and clears the accumulated delta before awaiting the renderer. Task-ID guards and latest-wins recovery remain unchanged.

- [ ] **Step 5: Append deltas in canonical renderer batches**

Store the stroke template, last rendered point, absolute point count, and fewer-than-eight point remainder in `StrokePreviewTransaction`. Build temporary segment commands from only complete canonical eight-stamp batches, using the prior point and absolute index offset for direction and deterministic seeds. Flush the remainder at finish. The pixels immediately before semantic commit must equal fresh replay so pointer-up never visually snaps.

- [ ] **Step 6: Run focused, full, and benchmark checks**

Run: `swift test --filter CanvasEventViewTests && swift test --filter StudioModelTests && make test`

Then run: `env WATERCOLOR_RUN_BENCHMARK=1 swift test --filter WatercolorRendererTests/benchmark1600By1200AtEightAndTwelveLayers`

Expected: all tests pass; long updates process only delta points; exact replay remains equal.

- [ ] **Step 7: Commit**

```bash
git add Sources/WatercolorStudio/CanvasEventView.swift Sources/WatercolorStudio/StudioModel.swift Sources/WatercolorEngine/WatercolorRenderer.swift Tests/WatercolorStudioTests Tests/WatercolorEngineTests/WatercolorRendererTests.swift
git commit -m "perf: pass incremental preview point deltas"
```

### Task 7: Phase verification and review

**Files:**
- Modify only files required by verified review findings.

**Interfaces:**
- Consumes every contract from Tasks 0 through 6.
- Produces a clean, review-approved phase boundary.

- [ ] **Step 1: Run the complete clean gate**

Run: `swift package clean && make test && make app`

Expected: all tests pass and the release bundle builds.

- [ ] **Step 2: Run Metal validation**

Run: `env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 swift test --filter WatercolorRendererTests`

Expected: all renderer tests pass with no Metal validation diagnostics.

- [ ] **Step 3: Run hostile-resource fixtures and benchmark**

Run: `swift test --filter RendererResourcePolicyTests && swift test --filter RendererWorkPolicyTests && env WATERCOLOR_RUN_BENCHMARK=1 swift test --filter WatercolorRendererTests/benchmark1600By1200AtEightAndTwelveLayers`

Expected: unsafe fixtures reject before allocation/dispatch; benchmark output is recorded.

- [ ] **Step 4: Request code review and remediate Critical or Warning findings**

Review resource admission math, overflow behavior, preview cancellation, exact replay, and MainActor stalls. Add a RED test for each accepted finding before production changes.

- [ ] **Step 5: Commit any review remediation**

```bash
git add Sources Tests
git commit -m "fix: address resource phase review"
```
