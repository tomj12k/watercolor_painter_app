# Edge-Case Analysis: Document, Resource, and Brush Paths

## Bottom line

The current limits reject malformed values, but they do not bound the work created by valid values in combination. A valid project can request several gigabytes of Metal textures or billions of stroke points. A normal low-pressure drag can also cross the stroke limit before validation and discard the mark. The planned brush-dynamics work needs an explicit schema migration because the current decoder cannot add required brush fields safely.

## Scope

This static review covered `ProjectModel.swift`, `DocumentCodec.swift`, `Presets.swift`, `StrokeSampler.swift`, `WatercolorRenderer.swift`, `ShaderSource.swift`, `NewCanvasConfiguration.swift`, `CanvasEventView.swift`, `StudioModel.swift`, and `BrushInspector.swift`. It focused on combined resource limits, legacy decoding, boundary control values, extreme strokes, failure recovery, and visible brush behavior. No production or test files were changed.

## Findings

### EC-001: Accepted canvas and layer limits exceed a practical working-set budget

- **Priority:** High
- **User-visible outcome:** A customer can create or open a supported 4,096 × 4,096 painting, then see a long stall, an allocation alert, or process termination. Starting a stroke or making a structural edit raises the peak further.
- **Preconditions:** The project has a maximum-size canvas and enough live layers to raise the renderer's array length. This is reachable through a valid document; the new-canvas screen also advertises 4,096 as supported.
- **Evidence:** Project validation checks canvas dimensions and layer count independently (`Sources/WatercolorCore/ProjectModel.swift:369-376`, `Sources/WatercolorCore/ProjectModel.swift:429-443`). The renderer's own formula allocates 20 bytes per pixel per live layer plus 8 composite bytes (`Sources/WatercolorEngine/WatercolorRenderer.swift:56-70`). At 12 layers, the base textures total 4,160,749,568 bytes, or 3.875 GiB. Beginning a stroke adds full-canvas pigment and wetness snapshots totaling another 2,013,265,920 bytes, bringing the active renderer to about 5.75 GiB before buffers (`Sources/WatercolorEngine/WatercolorRenderer.swift:238-262`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1641-1668`). A structural edit can keep the old renderer while allocating a candidate, so two base renderers can overlap at roughly 7.75 GiB (`Sources/WatercolorStudio/StudioModel.swift:697-724`). The 256 MiB checkpoint budget does not guard these live and candidate allocations (`Sources/WatercolorStudio/StudioModel.swift:70-73`, `Sources/WatercolorStudio/StudioModel.swift:802-816`).
- **Recommendation:** Add one device-aware admission budget covering the current renderer, preview snapshot, candidate renderer, readback, and retained checkpoints. Reject or downgrade the configuration before allocation. The error should offer a usable next action, such as reducing dimensions or layers, while preserving the current document.

### EC-002: Per-field limits do not cap total decoded memory or replay work

- **Priority:** High
- **User-visible outcome:** Opening a schema-valid file can exhaust memory during JSON decoding or freeze the window during replay, even though every field passes validation.
- **Preconditions:** The document combines values near independent maxima. It does not need malformed numbers or unsupported schema data.
- **Evidence:** Validation allows 100,000 commands, 65,536 points in each stroke, and 4,096 drying steps (`Sources/WatercolorCore/ProjectModel.swift:369-376`, `Sources/WatercolorCore/ProjectModel.swift:463-465`, `Sources/WatercolorCore/ProjectModel.swift:504-510`, `Sources/WatercolorCore/ProjectModel.swift:530-532`). The command and point limits therefore permit 6,553,600,000 points, about 293 GiB for the six `Double` fields alone before array and JSON overhead. `JSONDecoder` materializes the complete `PaintingProject` before validation runs (`Sources/WatercolorCore/DocumentCodec.swift:31-56`). Replay then records every action into one command buffer and waits on the main actor (`Sources/WatercolorEngine/WatercolorRenderer.swift:530-591`). A single accepted 4,096-step dry action can expand a centered active region to the full maximum canvas and dispatch both simulation and synchronization for every step: `4,096 × 4,096 × 4,096 × 2 = 137,438,953,472` pixel-thread invocations (`Sources/WatercolorEngine/WatercolorRenderer.swift:1018-1051`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1222-1291`).
- **Recommendation:** Define aggregate byte and replay-work budgets. Inspect document structure and collection counts before building nested arrays, then reject projects whose total points, dry work, estimated texture bytes, or replay dispatch estimate exceeds the supported budget.

### EC-003: One low-pressure diagonal event can overflow the stroke limit and lose the whole mark

- **Priority:** High
- **User-visible outcome:** A fast, light drag with the one-point brush can show a partial preview and then disappear behind an internal validation alert. The customer cannot keep the valid prefix or retry at a coarser sample rate.
- **Preconditions:** A pointer update spans much of a maximum canvas while pressure is at or below the 0.12 floor. Coalesced input, a brief event-delivery pause, or a fast corner-to-corner drag can create that segment.
- **Evidence:** Sampling spacing is `size × max(pressure, 0.12) × 0.18`, with no output cap (`Sources/WatercolorStudio/CanvasEventView.swift:30-38`). At size 1 and pressure 0.12, spacing is 0.0216 pixels. A 4,096-square diagonal is about 5,792.62 pixels, so `StrokeSampler` eagerly creates 268,177 points for one append (`Sources/WatercolorCore/StrokeSampler.swift:11-34`). The renderer accepts at most 65,536 points and validates only after the builder has allocated and appended them (`Sources/WatercolorCore/ProjectModel.swift:530-532`, `Sources/WatercolorEngine/WatercolorRenderer.swift:265-289`). On failure, `StudioModel` cancels the preview and keeps only a generic localized error; `CanvasEventView` has already cleared its builder when commit begins (`Sources/WatercolorStudio/StudioModel.swift:278-317`, `Sources/WatercolorStudio/CanvasEventView.swift:258-266`).
- **Recommendation:** Give the sampler a point budget and split or decimate before allocation. When a stroke reaches the persistence limit, commit bounded chunks under one user action or preserve the last valid prefix. Report a plain recovery message instead of exposing `invalidStrokePointCount` details.

### EC-004: Required brush-dynamics fields would make legacy files fail before migration

- **Priority:** High for the planned dynamics change
- **User-visible outcome:** After adding pressure or tilt response settings, existing `.watercolor` files can become “malformed” and refuse to open instead of receiving default dynamics.
- **Preconditions:** New dynamics are added as non-optional `BrushSettings` properties using synthesized `Codable`, whether the schema remains version 2 or advances to version 3.
- **Evidence:** `BrushSettings` currently relies on synthesized `Codable`, and every stored property is required (`Sources/WatercolorCore/ProjectModel.swift:127-163`). The codec decodes the full current `PaintingProject` before it invokes any migration (`Sources/WatercolorCore/DocumentCodec.swift:31-56`). Missing new keys therefore fail at line 46 and are collapsed to `malformedData`; the version-one migration at lines 72-86 is never reached. The existing migration works only because version-one JSON already matches the current Swift shape and needs a color-space conversion after decode.
- **Recommendation:** Bump the schema and decode legacy versions through version-specific transfer types, or give `BrushSettings` a custom decoder that uses documented defaults for absent dynamics. Add fixtures for versions 1 and 2 with missing dynamics, plus a current-version round trip that preserves non-default curves exactly.

### EC-005: Tablet tilt is stored but has no active visual effect

- **Priority:** Medium
- **User-visible outcome:** Tilting the stylus does not rotate, widen, or reshape a flat, fan, filbert, or rigger mark. Saved tilt data gives the appearance of supported dynamics without changing the painting.
- **Preconditions:** Any tablet stroke uses nonzero `tiltX` or `tiltY`.
- **Evidence:** Input clamps and records tablet tilt (`Sources/WatercolorStudio/CanvasEventView.swift:299-322`), and the document model validates and persists it (`Sources/WatercolorCore/ProjectModel.swift:534-553`). Paint rendering uses equal horizontal and vertical radii, then passes tilt in `effects.zw` (`Sources/WatercolorEngine/WatercolorRenderer.swift:1111-1147`). The stamp shader computes shape coverage from unrotated coordinates and only reads `effects.zw` inside tool cases 3 and 4 (`Sources/WatercolorEngine/ShaderSource.swift:138-155`, `Sources/WatercolorEngine/ShaderSource.swift:192-210`). Those tools never enter the stamp shader because the renderer routes smudge and smear to `encodeSmudge`, which derives direction from point movement and does not read tilt (`Sources/WatercolorEngine/WatercolorRenderer.swift:1097-1105`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1166-1204`).
- **Recommendation:** Define the visible contract for tilt per shape, then send brush orientation and aspect ratio into the coverage calculation. Verify it with image comparisons for opposite tilts, horizontal and vertical motion, and reopening a saved stroke.

### EC-006: Zero and low pressure advance simulation faster than full pressure

- **Priority:** Medium
- **User-visible outcome:** A very light stroke can diffuse or dry recent paint more than a firm stroke over the same distance. A zero-pressure stroke deposits nothing but can still change wet paint.
- **Preconditions:** Pressure approaches the accepted lower boundary while wet simulation regions remain active.
- **Evidence:** Pressure is valid from 0 through 1 (`Sources/WatercolorCore/ProjectModel.swift:534-546`). Sampling uses a 0.12 pressure floor, so low-pressure paths create up to 8.33 times as many points per unit distance as full-pressure paths (`Sources/WatercolorStudio/CanvasEventView.swift:35-37`). The stamp shader multiplies pigment and water deposit by pressure, making both zero at pressure 0 (`Sources/WatercolorEngine/ShaderSource.swift:167-180`). The renderer still registers a nonempty region using the same 0.12 floor and schedules two simulation steps per sampled point (`Sources/WatercolorEngine/WatercolorRenderer.swift:965-983`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1861-1872`). Simulation advances every active region, not only pixels that received pigment in the current stamp (`Sources/WatercolorEngine/WatercolorRenderer.swift:1018-1059`).
- **Recommendation:** Separate sampling density from the pressure response curve. Skip deposit-driven simulation for zero-contact samples, and advance wetness from elapsed time or distance with a bounded rate. Test exact pressure values 0, 0.01, 0.119, 0.12, and 1 across equal-length strokes on a previously wet layer.

## Suggested order

1. Add aggregate document and renderer admission budgets before expanding the file format.
2. Make brush-dynamics decoding backward compatible before saving any new fields.
3. Bound live sampling and preserve a recoverable stroke prefix.
4. Define and test the visible pressure and tilt contracts.
