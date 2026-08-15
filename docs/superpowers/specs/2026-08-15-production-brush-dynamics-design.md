# Production brush dynamics and readiness design

## Decision

Watercolor Studio will use one GPU brush engine with strong, direction-aware brush phenotypes. The same work will add resource admission, bounded replay work, reusable preview storage, incremental input deltas, actionable customer errors, and release-performance gates. The app will keep deterministic document replay and migrate existing `.watercolor` files without changing their prior rendering.

This design addresses four observed customer problems: brushes feel alike, long strokes can lag, valid documents can request unsafe GPU work, and runtime failures do not tell the customer how to recover.

## Success criteria

The release candidate must meet these contracts:

1. Shape, hair, texture, and style choices produce brush-specific stroke metrics with reviewed minimum separation. Byte inequality alone does not pass.
2. A preview update processes only newly sampled points. It does not copy or replay the complete stroke and does not allocate a full-canvas texture at pointer-down.
3. A saved stroke replays to the same final pixels regardless of preview-update boundaries.
4. The app rejects unsafe memory or replay workloads before allocating or dispatching them. Rejection preserves the current document and gives a recovery action.
5. Existing schema-version-1 and schema-version-2 paintings decode, migrate, and render as before.
6. Customer-visible preview p95 stays within two 60 Hz frames on the reference performance Mac at 1600 by 1200 with 1, 8, and 12 layers. Release qualification records commit latency, structural-edit latency, peak memory, and GPU duration.
7. Distribution documentation never calls an unsigned local bundle customer-ready. A separate distribution path fails closed when signing or notarization credentials are absent.

## Brush model

`BrushSettings` will add four persisted dynamics and an internal brush-behavior version:

| Setting | Range | Default | Effect |
| --- | ---: | ---: | --- |
| Spacing | 0.08...0.60 brush diameters | 0.18 | Distance between sampled marks; the renderer enforces a physical minimum of 0.75 pixels. |
| Rotation | -180...180 degrees | 0 | Offset applied after stroke direction or stylus orientation. |
| Bristle strength | 0...1 | 0.50 | Mix between a solid footprint and the selected hair pattern. |
| Texture strength | 0...1 | 0.50 | Mix between smooth coverage and the selected texture. |

The controls scale intrinsic brush behavior. A flat brush remains a chisel at zero bristle strength, and a bristle brush remains drier than sable at zero texture strength. Changing one control does not reset unrelated values. Selecting a watercolor style continues to update opacity, flow, water, granulation, and edge bloom while preserving brush identity and dynamics.

The behavior version is not an inspector control. Legacy strokes use version 0 and retain the current stamp equations. Newly painted strokes use version 1 and the dynamics described below. A migrated painting can contain both versions, so old marks stay stable while new marks receive the improved brush engine.

### Shape phenotypes

Each stamp receives a normalized tangent and stylus tilt. Mouse strokes use the path tangent. Tablet strokes prefer a valid tilt vector and fall back to the tangent. Rotation adds an artist-controlled offset.

| Shape | Footprint contract |
| --- | --- |
| Round | Near-circular, soft radial edge, independent of direction. |
| Flat | Wide chisel aligned across the stroke, with a crisp long edge. |
| Filbert | Directional oval with a soft rounded end. |
| Fan | Five persistent tapered fingers across the stroke width. |
| Rigger | Narrow, continuous directional line with reduced width variation. |

Aspect ratio, edge profile, and coverage area will be measured on horizontal, vertical, curved, and tilted fixtures.

### Hair phenotypes

Hair affects coverage, pigment transfer, water transfer, and edge response:

| Hair | Physical identity |
| --- | --- |
| Sable | Balanced pigment and water with a smooth point. |
| Squirrel | Softer edge, higher water transfer, lower pigment concentration. |
| Synthetic | Crisper edge, higher pigment transfer, lower water retention. |
| Bristle | Persistent separated lanes, low water, broken edge. |
| Mop | Broad soft coverage, high water, low edge sharpness. |

Bristle lanes use a stroke-stable seed and brush-local coordinates. Adjacent stamps continue the same lanes instead of generating unrelated gaps that average into a generic fuzzy band.

### Texture and style phenotypes

Texture modifies spatial coverage at a strength chosen by the artist. Smooth leaves coverage unchanged. Granulating follows paper valleys, dry creates connected skips, mottled creates low-frequency variation, and salt creates sparse blooms with bright centers.

Styles remain combinations of artist-visible controls plus shader behavior. Transparent wash is light and even. Wet-on-wet transfers more water and spreads farther. Dry brush exposes paper and limits diffusion. Glazing deposits a thin controlled film with low disturbance. Bloom concentrates pigment at expanding edges. Tests measure pigment mass, retained wetness, spread radius, void ratio, and edge concentration.

## Input and preview data flow

`CanvasStrokeBuilder` remains the owner of the complete semantic stroke. Its append operation also returns only the newly interpolated points. `StudioModel` queues those deltas in a latest-wins preview mailbox, and `WatercolorRenderer` appends them to the active preview transaction.

The model will not assign the complete growing `StrokeCommand` to pending preview state on every mouse event. That assignment shares the points array and forces copy-on-write allocation when the builder appends again. Pending work contains only points not yet submitted to Metal.

The renderer keeps the complete stroke only for final command recording and deterministic commit. Preview rendering uses the delta, the previous point, and the absolute point-index offset so direction and random seeds remain stable. Mouse-up performs the canonical semantic render required for exact replay; release benchmarks will bound that cost. If commit exceeds the approved budget, the implementation must move canonical encoding off the main actor or adopt fixed canonical preview batches before release.

## Preview storage

Each renderer will allocate one reusable preview snapshot for one layer, not two full texture arrays at every stroke. The snapshot stores one pigment slice and one wetness slice because a stroke targets one layer. Capture and restore blits address the selected array slice.

Resource admission includes live renderer textures, the reusable one-slice preview snapshot, reduction buffers, and the largest allowed structural candidate overlap. A checked integer calculation runs before Metal allocation. Tests inject a device budget; production uses a conservative fraction of `MTLDevice.recommendedMaxWorkingSetSize` with a documented absolute cap. A project that exceeds the budget fails with the required and available byte counts and guidance to reduce canvas size or layers.

## Replay work admission

The renderer will account for encoded simulation and synchronization threads before dispatch. The budget includes region area, affected slice count, simulation steps, and the paired synchronization pass. Checked multiplication rejects overflow.

A command that exceeds the per-command budget or a project that exceeds the replay budget fails before command-buffer submission. The error identifies the expensive operation in customer language. Routine drying uses small chunks so cancellation and progress remain possible. The existing dry-step field remains accepted only when its computed work fits the budget; the migration will not silently clamp saved values.

## Document compatibility

The project schema advances from version 2 to version 3. `BrushSettings` receives explicit `Codable` behavior so missing dynamics decode to version-2 defaults. Migration order is:

1. Version 1 colors convert from sRGB to linear values, as they do today.
2. Version 1 and version 2 recorded strokes receive behavior version 0, spacing 0.18, rotation 0, bristle strength 0.50, and texture strength 0.50.
3. New brush settings use behavior version 1. New strokes added to a migrated document therefore use the dynamics engine without rewriting old strokes.
4. The project schema becomes version 3 and passes full validation.

Version-2 fixtures must render to the same checksum before and after migration. Version-3 validation rejects non-finite or out-of-range dynamics before renderer construction.

## Inspector and customer UX

The brush inspector will group controls into Identity, Color, Paint, and Dynamics. Identity contains style, shape, hair, and texture. A one-line description under the pickers explains the selected shape, hair, texture, and style in artist language.

Dynamics contains Spacing, Rotation, Bristle, and Texture Strength plus a Reset Dynamics button. All controls expose stable accessibility labels, values, keyboard adjustment, and help text. The inspector remains scrollable at the minimum supported window size.

Resource and renderer failures will use stable customer categories instead of raw GPU or UUID details. Messages state what happened, whether the painting is safe, and the next action. Resource failures offer a path back to canvas configuration or recommend smaller dimensions/layer counts. A copyable diagnostic reference may include app version, macOS version, GPU name, canvas size, layer count, command count, and an error code; it never includes painting content or file paths.

## Distribution boundary

`make app` remains the unsigned local-development bundle. A separate distribution command will require a Developer ID Application identity and notarization profile, enable hardened runtime, sign nested code and the bundle, submit with `notarytool`, staple the result, and verify signatures. It must stop before publication when any credential or verification step is missing.

Signing and notarization cannot be completed in this repository without the owner's Apple Developer identity and notarization credentials. The final readiness report will distinguish code-ready status from distributable status until those external inputs exist.

## Test strategy

Tests will be written before each production change.

### Brush behavior

- Shape tests measure alpha-mask area, aspect ratio, orientation, radial profile, and fan-lane count.
- Hair tests measure edge roughness, lane persistence, pigment mass, and wetness-to-pigment ratio.
- Texture tests measure void ratio and spatial-frequency bands.
- Style tests measure mass, wetness, spread radius, and edge concentration.
- Tests use fixed UUIDs and semantic metrics with tolerance; they do not require pixel-perfect images across GPU families.

### Compatibility and safety

- Version-1 and version-2 fixtures migrate to version 3 and preserve visual output.
- Invalid dynamic values fail during document validation.
- Injected memory budgets reject unsafe projects before texture allocation and preserve the current document.
- Maximum combined replay work rejects before Metal dispatch, including the 4,096 by 4,096 and 4,096-step hostile fixture.
- Metal-required qualification reports a skipped or failed hardware lane when no device exists instead of counting early returns as coverage.

### Performance and customer paths

- A long 120 Hz stroke proves each preview submission contains only new points and bounded stamp/simulation work.
- Pointer-down proves the reusable snapshot does not allocate again.
- An environment-gated performance lane records p50 and p95 preview latency, commit latency, structural-edit latency, GPU duration, and peak memory for 1, 8, and 12 layers.
- Accessibility-driven smoke coverage changes every brush control, paints the next stroke, and verifies the recorded settings and semantic render metrics.
- Document adapter tests cover save/reopen plus malformed, invalid, over-budget, and newer-schema files with recoverable customer messages.

## Implementation boundaries

The work will land as reviewable phases: resource admission, schema and model dynamics, direction-aware rendering, inspector UX, incremental input deltas and preview storage, customer recovery, distribution preparation, and final qualification. Each phase must leave all earlier tests green.

The implementation will not add a separate renderer per brush family, a network service, telemetry upload, cloud storage, pixel-perfect cross-GPU golden images, or the full Cartesian product of brush combinations.

## Release decision

Code is ready for a customer release only when all functional, Metal-validation, hostile-document, perceptual brush, and pinned-hardware performance gates pass. The app is distributable only after Developer ID signing and notarization also pass. These are separate claims and will be reported separately.
