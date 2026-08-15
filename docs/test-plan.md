# Test Plan: Watercolor Studio production-readiness coverage

## Scope

Reviewed every Swift file under `Sources/WatercolorCore`, `Sources/WatercolorEngine`, and `Sources/WatercolorStudio`, together with all related Swift files under `Tests/`, on branch `main`. This is coverage analysis only: no tests were executed and no production or test code was changed.

The review emphasized customer-visible behavior, support and recovery paths, real interaction latency, resource limits, and whether brush shapes, hairs, textures, styles, and papers are both adjustable and immediately distinguishable.

## Summary

The suite has strong deterministic replay, editing, failure-rollback, and renderer-state coverage. Its main production gaps are that visual variety is accepted on checksum uniqueness, the only latency benchmark has no pass/fail budget, the maximum advertised canvas can imply multi-gigabyte allocations without a qualification test, and no end-to-end test proves that artists can operate every brush control and receive useful file-open recovery.

| Priority | Count |
|----------|-------|
| High     | 4     |
| Medium   | 2     |
| Low      | 0     |
| Skipped  | 2     |

Full analysis written to: /Users/tomfisher/watercolor_painter_app/docs/test-plan.md

## Coverage Assessment

Core document encoding, project validation, undo/redo, layer editing, deterministic replay, export integrity, transactional failure recovery, incremental stroke preview, wetness tracking, and directional smudge behavior are covered well. The tests generally assert observable state or pixels and use deterministic fixtures.

Production confidence is still incomplete. Renderer tests commonly return successfully when Metal is unavailable, visual-variety tests reduce output to checksum-like signatures, and the opt-in benchmark prints elapsed time without enforcing a customer-facing budget. SwiftUI controls and the `FileDocument` adapter also lack a customer-path test. These gaps are concentrated in active code: recent commits changed live preview coalescing, incremental rendering, dirty-region performance, checkpoint memory limits, and brush behavior.

## Findings

**T1: Prove each brush and paper choice has a perceptually distinct visual phenotype**
- **Priority:** High
- **Test level:** Integration
- **Entry point:** `Sources/WatercolorEngine/WatercolorRenderer.swift:227` — `renderAndWait(stroke:)`
- **Gap type:** Partially tested
- **Test approach:**
  - **Behavior:** A representative stroke rendered with each shape, hair, texture, style, and paper must differ enough for an artist to recognize the selected choice immediately. The current test only requires unique scalar signatures for each enum (`Tests/WatercolorEngineTests/WatercolorRendererTests.swift:517`) and compresses three alpha samples into one integer (`Tests/WatercolorEngineTests/WatercolorRendererTests.swift:1190`); a one-pixel or imperceptible change can pass.
  - **Stubs:** None. Use the real Metal renderer with fixed command identifiers, color, pressure, size, stroke path, and canvas.
  - **Input/Action:** Render one canonical dot and one canonical line per enum case. Capture the alpha mask, color image, wetness field, and pigment moments after a fixed simulation interval.
  - **Expected output:** Assert category-specific, tolerant metrics: shape silhouette area/aspect/radial profile; hair edge roughness and coverage distribution; texture void/grain frequency; style pigment mass, spread, edge concentration, and retained wetness; paper background contrast and diffusion profile. Require a reviewed minimum pairwise perceptual distance within each category, not merely unequal bytes or checksums.
  - **Expected commands:** None.
- **Brittleness assessment:** Deterministic seeds and semantic image statistics avoid pixel-perfect golden files and tolerate small GPU rounding differences. Calibrate thresholds from approved reference renders on supported GPUs, then keep broad safety margins.

**T2: Gate live painting and structural editing on measured customer latency**
- **Priority:** High
- **Test level:** End-to-end
- **Entry point:** `Sources/WatercolorStudio/StudioModel.swift:199` — `beginStrokePreview(_:)`, `updateStrokePreview(_:)`, and `commitStrokePreview(_:)`
- **Gap type:** Partially tested
- **Test approach:**
  - **Behavior:** Pointer input must become visible quickly and remain responsive during long strokes, while stroke commit, undo/redo, paper changes, and layer operations must not cause multi-second stalls on supported Macs. The preview suite verifies coalescing and command counts (`Tests/WatercolorStudioTests/StudioModelTests.swift:113`), but not elapsed input-to-visible latency. The only renderer benchmark is environment-gated, prints timing, and asserts no timing threshold (`Tests/WatercolorEngineTests/WatercolorRendererTests.swift:110`).
  - **Stubs:** Use a deterministic input-event driver; keep the real `StudioModel`, renderer, command queue, and display synchronization. Run in a dedicated performance lane on pinned supported hardware rather than the ordinary unit-test lane.
  - **Input/Action:** Replay 120 Hz pointer samples for representative 1600×1200 and 4096×4096 documents with 1, 8, and 12 layers; include a long wet stroke, commit, undo/redo, paper change, layer duplicate, and PNG snapshot.
  - **Expected output:** Record and enforce agreed budgets for p50/p95 input-to-preview completion, commit latency, structural-edit latency, export snapshot latency, frame misses, GPU duration, and peak resident memory. As an initial release gate, require visible preview p95 within two 60 Hz frames and establish explicit product-approved budgets for the remaining operations.
  - **Expected commands:** Verify exactly one durable painting command and document publication per committed stroke; do not assert internal command-buffer ordering.
- **Brittleness assessment:** Wall-clock gates are noisy in shared CI. Use warm-up iterations, percentiles, pinned power/thermal conditions, and regression tolerances against a stored baseline. Keep absolute budgets only in the release-performance lane.

**T3: Qualify the maximum advertised canvas and layer combination without process-ending allocation pressure**
- **Priority:** High
- **Test level:** Integration
- **Entry point:** `Sources/WatercolorStudio/NewCanvasConfiguration.swift:65` — `makeProject()`
- **Gap type:** Untested
- **Test approach:**
  - **Behavior:** A configuration accepted by the New Canvas UI must either open successfully within the supported memory budget or fail before dangerous allocation with an actionable error while preserving the current document. The UI accepts dimensions through 4096 (`Sources/WatercolorStudio/NewCanvasConfiguration.swift:43`), while the suite calculates that a 4096×4096, 12-layer renderer needs 4,160,749,568 texture bytes but only asserts the number exceeds the checkpoint budget (`Tests/WatercolorEngineTests/WatercolorRendererTests.swift:99`).
  - **Stubs:** For deterministic failure coverage, inject an allocator/renderer candidate that reports a known resource limit. Separately run a real-device qualification matrix on minimum-supported hardware.
  - **Input/Action:** Create maximum-width/height projects, grow them from 1 to 12 live layers, paint and undo, and repeat candidate allocation. Exercise the same transition through `StudioDocumentHost.configureNewDocument` so existing work is in scope.
  - **Expected output:** On qualified configurations, assert successful display and bounded peak memory/latency. On unsupported configurations, assert early rejection, no crash or OS termination, unchanged document/model/renderer, and a message that tells the customer to reduce canvas size or layer count.
  - **Expected commands:** Successful creation publishes the new project once; rejection publishes nothing and leaves the configuration sheet recoverable.
- **Brittleness assessment:** Do not allocate four gigabytes in routine CI. Use injected admission/failure tests for every run and reserve real maximum-size allocation for controlled release hardware with memory metrics.

**T4: Prove every brush control changes the next real stroke from the customer interface**
- **Priority:** High
- **Test level:** End-to-end
- **Entry point:** `Sources/WatercolorStudio/BrushInspector.swift:8` — `BrushInspector.body`
- **Gap type:** Partially tested
- **Test approach:**
  - **Behavior:** An artist can choose every style, shape, hair, and texture and adjust size, opacity, flow, water, granulation, edge bloom, and color; the next stroke uses the displayed values and produces the expected direction of visual change. The inspector exposes these controls at `Sources/WatercolorStudio/BrushInspector.swift:12` and `Sources/WatercolorStudio/BrushInspector.swift:91`, but current tests mutate `StudioModel.brush` directly or verify that a prebuilt brush is snapshotted (`Tests/WatercolorStudioTests/CanvasEventViewTests.swift:11`).
  - **Stubs:** None for the primary customer-path smoke test. Use accessibility identifiers/labels to drive the app and the real canvas. A smaller model-level table test may supplement it but must not replace the interface test.
  - **Input/Action:** Launch a document, operate every picker and numeric control at a representative value plus each boundary, draw a stroke, then inspect the resulting `StrokeCommand.brush` and rendered metrics. Repeat one control change during an active stroke to confirm the current stroke keeps its pointer-down settings while the next stroke uses the new settings.
  - **Expected output:** The UI value, durable stroke settings, and rendered output agree. Numeric controls remain within their advertised ranges, keyboard/VoiceOver adjustment works, and changing one control does not silently reset unrelated brush identity except when selecting a style intentionally applies its preset.
  - **Expected commands:** Each completed gesture appends exactly one stroke command; merely changing a brush control does not mutate the document.
- **Brittleness assessment:** Select controls by stable accessibility identifiers and assert semantic values, not view hierarchy coordinates. Use the perceptual metrics from T1 rather than screenshots.

**T5: Exercise the real document adapter and customer-facing open/save recovery**
- **Priority:** Medium
- **Test level:** Integration
- **Entry point:** `Sources/WatercolorStudio/PaintingDocument.swift:30` — `init(configuration:)` and `fileWrapper(configuration:)`
- **Gap type:** Untested
- **Test approach:**
  - **Behavior:** A saved `.watercolor` file reopens identically, while missing bytes, malformed JSON, invalid nested data, and a newer schema produce stable, understandable customer messages without replacing the current document. Codec behavior is well covered, but the actual `FileDocument` read/write boundary at `Sources/WatercolorStudio/PaintingDocument.swift:30` is not exercised by `Tests/WatercolorStudioTests/PaintingDocumentTests.swift`.
  - **Stubs:** Construct real `FileWrapper`/`ReadConfiguration` fixtures; use the real codec and `StudioDocumentHost` for replacement preservation.
  - **Input/Action:** Save and reopen a representative multilayer project containing every command type; then attempt the four invalid inputs through the document adapter and host path.
  - **Expected output:** Round-trip equality includes schema, paper, layers, brush settings, commands, and `needsInitialConfiguration == false`. Failures distinguish malformed, invalid, and newer-version files; the message gives a useful recovery direction, and the prior project remains paintable and saveable.
  - **Expected commands:** Failed opens/replacements publish no document update and do not discard the existing renderer.
- **Brittleness assessment:** Assert error category plus essential support text, not the complete prose or enum debug rendering. Fixed byte fixtures make this deterministic.

**T6: Make GPU coverage fail visibly instead of silently passing without Metal**
- **Priority:** Medium
- **Test level:** Integration
- **Entry point:** `Sources/WatercolorEngine/WatercolorRenderer.swift:109` — `init(project:device:)`
- **Gap type:** Partially tested
- **Test approach:**
  - **Behavior:** Unsupported hardware receives the documented “Metal is unavailable” failure, and release qualification cannot report renderer coverage when every GPU test returned early. Renderer tests currently use `guard let device = MTLCreateSystemDefaultDevice() else { return }`, including the first rendering test at `Tests/WatercolorEngineTests/WatercolorRendererTests.swift:8`.
  - **Stubs:** Pass `nil` explicitly for the unsupported-device unit case. Use a real device for the qualification smoke suite.
  - **Input/Action:** Initialize with `device: nil`, then run a tagged Metal smoke group that renders, previews, replays, reads back, and exports one canonical document.
  - **Expected output:** The nil-device case throws `RendererError.metalUnavailable` with its localized customer message. The release job fails or reports “not run” when Metal is absent; it must not count early returns as passing renderer tests.
  - **Expected commands:** None.
- **Brittleness assessment:** Splitting deterministic no-device behavior from a clearly tagged hardware-required lane keeps ordinary CI portable while making the production coverage status honest.

## Deferred / Skipped Tests

**S1: Pixel-perfect golden images for every brush combination**
- **Entry point:** `Sources/WatercolorEngine/WatercolorRenderer.swift:227`
- **Reason:** Exact images are brittle across GPU families and shader refinements. The trigger to add a small reviewed golden set is a stable cross-device rendering contract; until then, T1's tolerant perceptual metrics provide more durable customer-visible coverage.

**S2: Exhaustive Cartesian testing of all shape × hair × texture × style × paper combinations**
- **Entry point:** `Sources/WatercolorEngine/WatercolorRenderer.swift:227`
- **Reason:** The full matrix duplicates the same interactions at high runtime cost and encourages checksum chasing. Add pairwise/combinatorial cases only when a real interaction bug appears; per-axis phenotype tests plus a small pairwise sample cover realistic failures now.

## Coverage Estimate

After T1–T6, the suite would cover the major observable contracts needed for release: durable editing, deterministic rendering, perceptible brush variety, operable controls, measured responsiveness, bounded supported configurations, honest hardware qualification, and recoverable document failures. Remaining untested areas would mainly be intentionally deferred cross-GPU pixel exactness and exhaustive brush combinations rather than missing customer workflows.
