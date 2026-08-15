# Watercolor Studio — Product and Technical Design

## Product goal

Watercolor Studio is a native macOS painting app that makes digital watercolor feel immediate and physical. A person can create a textured paper canvas, paint with pressure-sensitive brushes, manipulate wet pigment, organize the work in layers, save an editable project, and export the result as a PNG.

The first release favors responsive, expressive painting over scientific fluid simulation. Its simulation must visibly produce pigment mixing, wet-edge blooms, granulation, diffusion, and drying while keeping input latency low on Apple Silicon.

## Release success criteria

- A new painting can be created, painted, saved, reopened, and exported without losing its layer structure.
- Brush feedback remains interactive on a 1,600 × 1,200 canvas with up to 12 visible layers on a current Apple Silicon Mac.
- Red and blue wet strokes visibly mix to purple where they overlap; drying reduces later diffusion.
- Mouse, trackpad, and pressure-sensitive tablet input all work, with pressure affecting width and pigment flow.
- Every destructive editing action participates in undo/redo.
- Core model tests and Metal engine integration tests pass from the command line.

## Scope

### Included

- Native multiwindow macOS document workflow.
- Canvas presets and custom dimensions up to 4,096 × 4,096.
- Hot press, cold press, rough, handmade, and canvas paper textures.
- Round, flat, filbert, fan, and rigger brush shapes.
- Sable, squirrel, synthetic, bristle, and mop hair behavior.
- Smooth, granulating, dry, mottled, and salt brush textures.
- Transparent wash, wet-on-wet, dry brush, glazing, and bloom style presets.
- Brush, water, eraser, smudge, smear, and dry tools.
- System color-wheel picker, swatches, size, opacity, flow, and water controls.
- Layer creation, naming, duplication, deletion, reordering, visibility, opacity, and merge-down.
- Zoom, pan, fit-to-window, undo/redo, dry-layer, clear-layer, save/open, and PNG export.

### Deliberately excluded from the first release

- Vector shapes, text, animation, cloud sync, collaboration, third-party brush packs, print color management, and PSD import/export.
- A full Navier–Stokes fluid solver. The visual model is a stable diffusion/advection approximation designed for painting responsiveness.

## Recommended architecture

The app uses Swift 6 and SwiftUI for its document scene and inspectors, with a small AppKit bridge for tablet-quality pointer events. `MTKView` hosts a Metal renderer. This gives standard macOS document behavior without sacrificing direct access to pressure, tilt, and GPU textures.

The repository is a Swift package with a library target, executable app target, and test target. A packaging script wraps the release executable in a standard `.app` bundle and registers the `.watercolor` document type. This avoids a generated project dependency while remaining openable in Xcode and buildable with `swift build`.

### Modules

1. **WatercolorCore** — Codable project model, layers, brush/tool settings, stroke sampling, preset definitions, history commands, and color-mixing helpers. It has no UI dependency.
2. **WatercolorEngine** — Metal device and pipelines, per-layer pigment/wetness textures, brush stamping, diffusion/drying, compositing, texture readback, and deterministic replay.
3. **WatercolorStudio** — document lifecycle, workspace state, SwiftUI studio chrome, AppKit/Metal canvas bridge, commands, inspectors, and export panels.

Each unit exposes a narrow interface: the UI submits semantic stroke commands; the engine renders commands and returns images; the document stores the command history and project metadata.

## Painting model

Each layer is represented on the GPU by two texture-array slices:

- `pigment`: linear RGB plus concentration/coverage in `rgba16Float`.
- `wetness`: water amount in `r16Float`.

A brush stamp deposits pigment and/or water through a shape-and-bristle mask. The mask combines the selected brush shape, hair breakup, texture noise, pressure, tilt, and paper height. Pigment is mixed by concentration in linear color space rather than alpha-replacing the previous color.

The simulation compute pass moves wet pigment toward neighboring pixels, modulated by paper fibers. Wetness diffuses faster than pigment and evaporates each step. Higher paper roughness increases granulation and edge variation. The composite pass applies layer visibility and opacity, then multiplies subtle paper lighting over the result.

Simulation is deterministic. Each sampled input point advances a fixed simulation step; explicit dry operations add a recorded number of steps. Saving command history therefore recreates the same image and keeps project files compact. Runtime checkpoints avoid replaying the entire history during ordinary undo/redo.

Tool semantics:

- **Brush:** deposits pigment and water.
- **Water:** deposits water only, reactivating and spreading existing pigment.
- **Eraser:** removes concentration and some wetness with a soft mask.
- **Smudge:** pulls pigment a short distance along the stroke while largely preserving water.
- **Smear:** moves more pigment over a longer vector and introduces water.
- **Dry:** removes wetness locally, locking pigment in place.

## Document and history model

`.watercolor` is a JSON document containing schema version, canvas and paper settings, ordered layer metadata, and ordered painting commands. Commands are strokes, clear/merge operations, and explicit drying operations. Every command has a stable identifier and layer identifier.

Undo/redo moves commands between active and redo stacks and asks the engine to rebuild from the nearest in-memory checkpoint. Structural layer changes are commands too, so save state and visual state cannot diverge.

The document format starts at schema version 1. The reader rejects newer unsupported schemas with a useful error instead of silently corrupting them. Autosave is provided by SwiftUI's document lifecycle. PNG export reads the final composited Metal texture and encodes it with ImageIO.

## User experience

The window has three visual zones:

- A narrow leading tool rail for brush, water, eraser, smudge, smear, and dry.
- A central, dark-neutral viewport containing the paper canvas, zoom controls, and a small wetness activity indicator.
- A trailing inspector with Brush, Color, Paper, and Layers sections. Layers remain visible while painting and use direct drag reordering plus concise icon actions.

The toolbar contains new/open/save through normal macOS commands, undo/redo, zoom, fit, dry layer, and export. `ColorPicker` supplies the native color wheel; a small recent-color row accelerates reuse. Keyboard shortcuts use familiar macOS conventions, including B/E/W/S/D for tools, bracket keys for brush size, and Space-drag for panning.

The initial visual language is quiet and studio-like: charcoal chrome, off-white paper, restrained separators, compact controls, and color reserved for paint and selection state.

## Input and rendering flow

1. The AppKit canvas receives a mouse or tablet event and converts it into canvas coordinates, normalized pressure, tilt, and timestamp.
2. A stroke sampler interpolates points so fast pointer motion cannot leave gaps.
3. The workspace snapshots the active tool and brush settings into a stroke command.
4. The renderer encodes stamp and simulation compute passes into a command buffer.
5. The compositor blends visible layers and the paper surface into the drawable.
6. On stroke completion, the command is committed to document history, autosave is notified, and a checkpoint may be captured.

View transforms never alter document coordinates. Resize, zoom, and pan only affect presentation.

## Failure handling

- If Metal is unavailable, the app presents a clear unsupported-hardware message rather than opening a blank canvas.
- Shader compilation and texture allocation failures surface in a non-destructive alert and leave the document intact.
- Canvas-size validation prevents allocations above the supported limit.
- Save decoding identifies malformed files and unsupported schema versions.
- Export failures preserve the project and report the destination error.

## Performance constraints

- Reuse command queues, pipelines, buffers, samplers, and textures; allocate no GPU resources per pointer event.
- Coalesce pointer events and submit stamps in batches.
- Simulate only a padded dirty region while a stroke is active; a full pass is reserved for explicit drying and export.
- Cap layers at 12 and dimensions at 4,096 × 4,096 for predictable memory use.
- Render the viewport at its drawable resolution while keeping document textures at document resolution.
- Keep UI state on the main actor and GPU encoding on a dedicated serial queue.

## Test strategy

- **Unit:** Codable round trips, schema rejection, layer invariants, preset mapping, stroke interpolation, coordinate transforms, history/redo behavior, and color mixing.
- **Metal integration:** engine initialization, pigment deposit, red/blue mixing, erase reduction, wetness decay, layer compositing, and texture readback.
- **Document integration:** save/open replay equivalence and PNG export dimensions.
- **Manual acceptance:** pressure tablet behavior, rapid strokes, 12-layer stress, every paper/preset/tool combination, undo/redo, reopen, export, multiple documents, dark/light appearance, and window resizing.

## Key product risks

- **Simulation looks synthetic.** Tripwire: overlap colors replace instead of mix, or edges remain uniformly soft. Mitigation: concentration-weighted mixing, fiber noise, separated water/pigment diffusion, and preset-specific parameters.
- **GPU work misses interaction targets.** Tripwire: visible input lag or sustained frame time above 16.7 ms on the reference canvas. Mitigation: dirty-region dispatch, point batching, fixed layer cap, and GPU timing instrumentation.
- **Replay differs from the saved image.** Tripwire: pixel checksum changes after save/reopen. Mitigation: seeded noise, fixed simulation counts, and replay equivalence tests.
- **SwiftUI/AppKit state diverges.** Tripwire: selected layer or tool differs between inspector and rendered output. Mitigation: one main-actor workspace model and semantic engine commands.

