# Behavioral Analysis: Watercolor Studio on `main`

## Bottom line

The saved command stream is deterministic after a stroke commits, but the live path has six behavioral gaps. Four have direct customer impact: input cadence changes paint density, supported canvases can exceed the combined Metal resource budget, tablet tilt has no rendering effect, and the 100,000-command boundary can produce an unsavable edit. Two lower-likelihood gaps affect preview fidelity and failure recovery.

No production or test file was changed. `make test` passed all 166 tests in 15 suites. The current suite proves post-commit replay equivalence, but it does not cover preview-versus-commit pixels, event-cadence invariance, long-stroke limits, combined live Metal resources, or rollback failure.

## Scope and method

This review traced runtime data through the eight requested files:

- `Sources/WatercolorCore/ProjectModel.swift`
- `Sources/WatercolorCore/DocumentCodec.swift`
- `Sources/WatercolorCore/StrokeSampler.swift`
- `Sources/WatercolorEngine/WatercolorRenderer.swift`
- `Sources/WatercolorEngine/ShaderSource.swift`
- `Sources/WatercolorStudio/CanvasEventView.swift`
- `Sources/WatercolorStudio/StudioModel.swift`
- `Sources/WatercolorStudio/BrushInspector.swift`

The findings are ordered by customer impact. Warnings have a deterministic customer-visible failure or a resource request beyond the supported envelope. Suggestions retain the default severity because their visible impact depends on timing, image content, or a second failure.

## Prioritized findings

### B-001 — Warning: Resample by path distance so input cadence cannot change paint or discard long strokes

**Locations:** `Sources/WatercolorCore/StrokeSampler.swift:15`, `Sources/WatercolorStudio/CanvasEventView.swift:30`, `Sources/WatercolorEngine/WatercolorRenderer.swift:951`, `Sources/WatercolorEngine/ShaderSource.swift:167`

A customer can draw the same path twice and get different pigment, wetness, and diffusion because every short input segment contributes one point. A thin, low-pressure stroke can also cross the persisted 65,536-point limit, slow the main thread, raise an error, and disappear on pointer-up. Cadence-dependent paint affects ordinary mouse and tablet input; the point-limit failure needs a long path with a small pressure-scaled spacing.

`StrokeSampler.interpolate` returns the destination whenever one raw segment is shorter than the requested spacing. `CanvasStrokeBuilder` keeps no unused-distance remainder between segments, so it stamps once per operating-system event in that case. For a 100-pixel path with 9-pixel spacing, one segment produces 13 stored points including the start, while 100 one-pixel segments produce 101. The renderer deposits paint for every point and advances two simulation steps per point, so the difference changes color as well as command size.

The supported minimum brush size and pressure floor make the long-stroke boundary reachable. At size `1` and pressure `0.12`, spacing is `1 × 0.12 × 0.18 = 0.0216` pixels. A 4,096-pixel path can therefore request about 189,630 intervals, almost three times `PaintingProject.maximumStrokePointCount`. The builder does not enforce that cap. Before rejection, each preview validation scans all accumulated points. After rejection, the builder continues growing and handing off full stroke values until pointer-up, although the model ignores them.

**Recommended fix:** Test-first. Keep a residual path distance in `CanvasStrokeBuilder`, emit samples at global arc-length intervals, and reserve the final destination for finish rather than every short event. Enforce the 65,536-point budget before allocation, then either decimate without changing the path or stop the stroke with a recoverable result. Add cadence-invariance and maximum-length tests.

### B-002 — Warning: Budget the live renderer, candidate, preview snapshot, and checkpoints as one Metal peak

**Locations:** `Sources/WatercolorEngine/WatercolorRenderer.swift:56`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1641`, `Sources/WatercolorStudio/StudioModel.swift:72`, `Sources/WatercolorStudio/StudioModel.swift:708`, `Sources/WatercolorStudio/StudioModel.swift:785`

A customer using supported canvas and layer limits can see pointer-down or a structural edit stall, fail, or terminate the process under unified-memory pressure. The request is deterministic; the exact failure depends on the Mac's available memory.

The renderer's own formula places a 4,096 × 4,096, 12-slice base renderer at `4,160,749,568` bytes, or 3.875 GiB. Beginning a stroke allocates another pigment and wetness array, adding `4096 × 4096 × 12 × 10 = 2,013,265,920` bytes, or 1.875 GiB. A paper or structural edit creates a complete candidate before replacing the live renderer, so two maximum base renderers can overlap at 7.75 GiB.

The 256 MiB budget applies only to cached checkpoints. `estimatedResourceBytes` excludes the preview snapshot, and `prepareCurrentRendererCheckpointForCandidateAllocation` does not include the live renderer or the candidate in its sum. Evicting checkpoints therefore does not bound either 5.75 GiB at pointer-down or 7.75 GiB during candidate replay.

**Recommended fix:** Test-first. Define a checked peak-resource budget using the device's recommended working set. Include the live renderer, candidate overlap, preview snapshot, transaction composite, checkpoint cache, wetness buffers, and export readback. Reject or downgrade an operation before Metal allocation, and report which canvas or layer reduction will fit.

### B-003 — Warning: Make captured tablet tilt affect an active rendering path

**Locations:** `Sources/WatercolorStudio/CanvasEventView.swift:299`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1090`, `Sources/WatercolorEngine/ShaderSource.swift:138`, `Sources/WatercolorEngine/ShaderSource.swift:173`

Tablet users always get the same mark for the same position and pressure regardless of stylus tilt. This is certain for every current tool, even though tilt is captured, interpolated, validated, saved, and sent to the stamp shader.

The normal stamp path places `tiltX` and `tiltY` in `effects.zw`, but brush, water, eraser, and dry shader branches never read those values. Only shader cases 3 and 4 read them as a direction. Those cases are unreachable because the renderer routes smudge and smear to `encodeSmudge`, whose separate parameters derive direction from point movement and contain no tilt. The stamp footprint also uses equal horizontal and vertical radii and never rotates its normalized coordinates.

This contradicts the documented brush contract that combines pressure and tilt in the mask. It also means replay faithfully preserves data that can never influence pixels.

**Recommended fix:** Test-first. Define tilt behavior by tool and shape, then rotate or deform brush coverage from stylus orientation. If smudge and smear should use tilt, pass it through their parameter block. Add paired render tests where only tilt changes and require a directional pixel or pigment-moment difference.

### B-004 — Warning: Preflight the command budget before rendering and publishing a stroke

**Locations:** `Sources/WatercolorCore/ProjectModel.swift:374`, `Sources/WatercolorCore/DocumentCodec.swift:23`, `Sources/WatercolorEngine/WatercolorRenderer.swift:231`, `Sources/WatercolorStudio/StudioModel.swift:220`, `Sources/WatercolorStudio/StudioModel.swift:319`

A project containing exactly 100,000 commands can accept and display one more stroke, then fail when the document tries to save. The failure is deterministic at that boundary. Reaching it takes a very long editing history, but the result puts the visible canvas ahead of the last encodable document.

Full project validation rejects more than `PaintingProject.maximumCommandCount`. Stroke completion does not run that validation. Both completion paths validate only the incoming stroke, render it, append it to the renderer's project, append it to the editor, and publish the result. `PaintingDocumentCodec.encode` later validates the full 100,001-command project and throws `commandLimitExceeded`.

Structural commands take the candidate-renderer path and receive full-project validation. Strokes bypass it, so the limit has different behavior depending on which editing action crosses it.

**Recommended fix:** Test-first. Reserve command capacity before beginning or finishing a stroke. If no slot remains, keep the renderer and editor unchanged and tell the customer how to preserve the painting, such as saving a compacted copy or flattening history. Add boundary tests at 99,999, 100,000, and 100,001 commands for both direct and preview completion.

### B-005 — Suggestion: Use the same stable batch boundaries for preview and commit

**Locations:** `Sources/WatercolorEngine/WatercolorRenderer.swift:265`, `Sources/WatercolorEngine/WatercolorRenderer.swift:292`, `Sources/WatercolorEngine/WatercolorRenderer.swift:383`, `Sources/WatercolorEngine/WatercolorRenderer.swift:951`

The live mark can change when the customer releases the pointer because preview batching depends on when pending updates reach the GPU, while commit batching always starts at point zero. This happens during normal multi-event strokes, but the visible size of the jump depends on wetness, overlap, and how preview updates are coalesced.

Each preview update drops the points already rendered, then `encodeStrokeAndSimulation` starts new groups of eight from the first newly appended point. It advances simulation after every local group. Commit restores the pre-stroke snapshot and renders the entire stroke in groups `0...7`, `8...15`, and so on. For a preview that first renders one point and later receives two more, preview simulates after point one and again after points two and three; commit stamps all three before the same total number of simulation steps. The diffusion shader is stateful, so those operation orders are not equivalent.

The existing equivalence tests compare the post-commit image with a fresh replay. They do not compare the final preview image immediately before `finishStrokePreview` with the committed image immediately after it.

**Recommended fix:** Test-first. Make simulation partition-independent, or keep stable global eight-point boundaries across updates. To preserve immediate feedback with stable boundaries, snapshot the last completed boundary and rerender only the incomplete tail as it grows. Add preview-before-finish and post-commit checksum tests across update partitions such as `[1, 3, 9, 17]`.

### B-006 — Suggestion: Treat rollback failure as a renderer-state failure instead of discarding it

**Locations:** `Sources/WatercolorEngine/WatercolorRenderer.swift:292`, `Sources/WatercolorEngine/WatercolorRenderer.swift:339`, `Sources/WatercolorStudio/StudioModel.swift:235`, `Sources/WatercolorStudio/StudioModel.swift:311`

After a preview or commit error, a second error during rollback can leave the raster out of sync with the unchanged project while painting remains enabled. This may never occur on a healthy GPU; it requires both the original rendering failure and failure of snapshot restore or replay.

`cancelStrokePreview` clears the renderer's transaction before it allocates the restore command buffer and submits the restore. If that work throws, the transaction is no longer available for another attempt. `failStrokePreview` ignores that error with `try?`. The commit catch similarly ignores `renderer.replay(project:)` failure. Both paths clear the model's active preview and retain normal painting capabilities, so the next stroke or PNG export can use an unverified raster.

The alert reports only the first error. It does not tell the customer that recovery also failed, replace the renderer from the preserved project, or disable actions that depend on raster correctness.

**Recommended fix:** Test-first. Make cancel preserve its transaction until restore completes. If rollback fails, create a replacement renderer from the last valid project; if that also fails, enter an explicit unavailable state that blocks paint and export while keeping the document data intact. Report the original and recovery failures as one customer action with a retry path.
