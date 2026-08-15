# Junior-Developer Review: Watercolor Studio on `main`

## Scope

Reviewed the Watercolor Studio application on branch `main`: package and release configuration, all source and test targets, and project documentation. This was a whole-app review, not a change-diff review. The review focused on production readiness, customer and support experience, painting performance, and the weak perceptual separation between brush choices.

## Plain-language restatement

The app has a careful document model and a substantial Metal test suite, but it is not ready for customer distribution or a confident watercolor-quality claim. The most visible product issue comes from treating brushes as dense sequences of independent, axis-aligned stamps. That design records several brush properties without carrying them into a coherent stroke-level mark.

## Questions behind the findings

- **Q1 [Answered]:** Does starting a stroke allocate new Metal textures? Yes. `beginStrokePreview` creates two full-canvas texture arrays for every stroke (`Sources/WatercolorEngine/WatercolorRenderer.swift:238`).
- **Q2 [Answered]:** Does tablet tilt orient or reshape a painted brush mark? No. Tilt is placed in the stamp parameters, but no active brush path uses it to transform coverage (`Sources/WatercolorEngine/WatercolorRenderer.swift:1090`, `Sources/WatercolorEngine/ShaderSource.swift:138`).
- **Q3 [Answered]:** Do automated tests prove that brush options look meaningfully different across a stroke? No. The enum test reduces three pixels from one dot to one integer (`Tests/WatercolorEngineTests/WatercolorRendererTests.swift:517`, `Tests/WatercolorEngineTests/WatercolorRendererTests.swift:1190`).
- **Q4 [Open]:** Is “production ready” intended to mean a local developer build or an app customers can install? Distribution readiness depends on that answer; the current bundle is explicitly local-only (`README.md:57`).
- **Q5 [Assumed]:** Can customers recover from renderer failures without support? The interface assumes dismissal is enough. If that is wrong, failures leave customers without a retry or useful diagnostic path (`Sources/WatercolorStudio/WatercolorStudioApp.swift:29`).

## Findings

### JD-001: A full-canvas GPU snapshot is allocated at the start of every stroke

- **Severity:** Muddies artifact
- **Protocol:** Standards & Conventions Conflict
- **Location:** `Sources/WatercolorEngine/WatercolorRenderer.swift:238`; `Sources/WatercolorEngine/WatercolorRenderer.swift:1641`; `docs/superpowers/specs/2026-08-15-watercolor-studio-design.md:114`
- **Violated standard:** The design requires no GPU resource allocation per pointer event and calls for reusable textures.
- **Evidence:** `beginStrokePreview` calls `makeStrokePreviewSnapshot`, which creates new full-canvas pigment and wetness texture arrays. At the supported 4,096 × 4,096, 12-layer limit, the existing renderer estimate is 4,160,749,568 bytes (`Tests/WatercolorEngineTests/WatercolorRendererTests.swift:99`), and the per-stroke snapshot adds about 2,013,265,920 bytes before buffers.
- **Why this matters:** A customer can see a pause or allocation failure at pointer-down, especially as layer count grows. This directly works against immediate brush feedback.
- **Suggested next step:** Reuse a bounded preview snapshot or capture only dirty slices and regions. Add a pointer-down allocation test and run the existing benchmark by default on the release reference machine.
- **Specialist to consult:** `devops-engineer` for release resource limits and `behavioral-analyst` for the preview transaction.

### JD-002: Common editing actions rebuild and replay the renderer on the main actor

- **Severity:** Muddies artifact
- **Protocol:** Specialist-Domain Boundary
- **Location:** `Sources/WatercolorStudio/StudioModel.swift:68`; `Sources/WatercolorStudio/StudioModel.swift:696`; `Sources/WatercolorEngine/WatercolorRenderer.swift:488`; `docs/superpowers/specs/2026-08-15-watercolor-studio-design.md:121`
- **Violated standard:** The design says UI state stays on the main actor while GPU encoding uses a dedicated serial queue.
- **Evidence:** `performProjectEdit` synchronously creates a candidate renderer and replays the full command history. `WatercolorRenderer` is main-actor isolated, and replay waits for GPU completion. Paper changes, clear, dry, add, delete, duplicate, merge, and fallback undo can all take this path.
- **Why this matters:** Larger paintings can freeze the entire window during ordinary edits. The optional performance test covers direct stroke rendering, not long-history replay from these UI actions (`Tests/WatercolorEngineTests/WatercolorRendererTests.swift:110`).
- **Suggested next step:** Move candidate replay behind an asynchronous transaction, keep the old renderer visible until completion, and measure action latency with long histories at 8 and 12 layers.
- **Specialist to consult:** `concurrency-analyst` and `behavioral-analyst`.

### JD-003: Brush shape and tablet tilt never become a stroke-oriented footprint

- **Severity:** Muddies artifact
- **Protocol:** Hidden-Assumption Audit
- **Location:** `Sources/WatercolorStudio/CanvasEventView.swift:317`; `Sources/WatercolorEngine/WatercolorRenderer.swift:1090`; `Sources/WatercolorEngine/WatercolorRenderer.swift:1123`; `Sources/WatercolorEngine/ShaderSource.swift:75`; `docs/superpowers/specs/2026-08-15-watercolor-studio-design.md:60`
- **Challenged assumption:** Repeating a fixed, axis-aligned stamp is enough to preserve the identity of flat, filbert, fan, and rigger brushes across a moving stroke.
- **Evidence:** Input captures and stores tilt, but painted stamps always use equal horizontal and vertical radii. The shape function receives unrotated coordinates. Tilt is passed as two effect values, yet the active brush path never uses those values to rotate or deform coverage.
- **Why this matters:** Flat and rigger marks do not follow stroke direction or stylus angle. Dense overlap then turns their distinct single-dot masks into similar soft trails, which matches the reported customer experience.
- **Suggested next step:** Add stroke tangent and stylus orientation to stamp parameters. Define per-shape aspect ratios and rotation rules, then compare full horizontal, vertical, curved, and tilted strokes in image-based tests.
- **Specialist to consult:** `user-experience-designer` for expected brush behavior and `behavioral-analyst` for the rendering contract.

### JD-004: Hair and texture breakup is random per stamp, then averaged by dense overlap

- **Severity:** Worth clarifying
- **Protocol:** Evidence-and-Reasoning Check
- **Location:** `Sources/WatercolorStudio/CanvasEventView.swift:35`; `Sources/WatercolorEngine/WatercolorRenderer.swift:1153`; `Sources/WatercolorEngine/ShaderSource.swift:145`; `Tests/WatercolorEngineTests/WatercolorRendererTests.swift:517`; `Tests/WatercolorEngineTests/WatercolorRendererTests.swift:1190`; `docs/program/watercolor-studio-program.md:41`
- **Challenged assumption:** Distinct checksums from isolated random stamps prove that hair and texture choices remain visibly distinct while painting.
- **Evidence:** Sampling places stamps at 18% of the pressure-scaled diameter. Each stamp changes its noise seed by point index, so bristle and texture gaps do not persist as hairs along the stroke. The release test then checks one dot at only three pixels and collapses those values into an integer.
- **Why this matters:** Overlapping unrelated masks average into a common fuzzy band. The test can pass when every enum changes a few numbers while customers still see the same brush.
- **Suggested next step:** Generate stable stroke-local bristle lanes and texture coordinates. Replace the single-dot signature with full-stroke image comparisons and perceptual thresholds, backed by a manual brush matrix.
- **Specialist to consult:** `test-engineer` and `user-experience-designer`.

### JD-005: The packaged app is a local build, not a customer-ready release

- **Severity:** Muddies artifact
- **Protocol:** Scope & Definition-of-Done
- **Location:** `README.md:51`; `README.md:57`; `README.md:63`; `README.md:65`; `docs/program/watercolor-studio-program.md:44`
- **Challenged assumption:** A passing release build and five-second process-liveness check are enough to call the result a release candidate for customers.
- **Evidence:** The bundle is unsigned, not notarized, and built only for the architecture of the packaging Mac. The documented launch path asks users to bypass the unsigned-app warning. Visible app launch and manual interaction remain unverified.
- **Why this matters:** Customers receive a security warning and an installation path that creates avoidable support requests. Intel users can receive an incompatible binary.
- **Suggested next step:** Decide the distribution channel, then add signing, notarization, supported-architecture packaging, upgrade/version policy, and an install-and-launch smoke test on a clean Mac.
- **Specialist to consult:** `devops-engineer`.

### JD-006: Runtime failures expose a dead end instead of a recovery and support path

- **Severity:** Worth clarifying
- **Protocol:** Plain-Language Reframing
- **Location:** `Sources/WatercolorStudio/WatercolorStudioApp.swift:29`; `Sources/WatercolorStudio/WatercolorStudioApp.swift:51`; `Sources/WatercolorStudio/StudioModel.swift:199`; `Sources/WatercolorEngine/WatercolorRenderer.swift:18`
- **Challenged assumption:** Showing `localizedDescription` under the title “Studio issue” with a Dismiss button gives customers enough information to recover or get help.
- **Evidence:** Renderer initialization failure leaves a permanent “renderer is unavailable” screen. The alert offers only Dismiss. Several error messages contain implementation details such as allocation wording, GPU execution, or internal layer identifiers.
- **Why this matters:** A customer cannot retry, reduce the canvas, reopen safely, or copy useful diagnostics. Support receives a paraphrased error without device, document, or failure context.
- **Suggested next step:** Map failures to customer actions such as Retry, Open Without Rendering, reduce canvas/layers, or preserve and close. Add a copyable diagnostic reference containing app version, macOS version, GPU name, canvas size, and command count without document content.
- **Specialist to consult:** `user-experience-designer` and `devops-engineer`.

## Strengths worth keeping

- Document decoding validates nested numeric bounds, command counts, identifiers, and schema versions before rendering (`Sources/WatercolorCore/DocumentCodec.swift:31`; `Sources/WatercolorCore/ProjectModel.swift:424`).
- The editor preserves exact before-and-after project states for bounded undo and redo (`Sources/WatercolorCore/ProjectEditor.swift:155`).
- Renderer work uses dirty regions, active slices, reusable pipelines, and deterministic replay. Those are useful foundations for the performance work above (`Sources/WatercolorEngine/WatercolorRenderer.swift:951`; `Sources/WatercolorEngine/WatercolorRenderer.swift:1743`).
- Export writes atomically and runs PNG encoding away from the main actor, with tests for destination preservation and stale async results (`Sources/WatercolorStudio/StudioModel.swift:587`; `Tests/WatercolorStudioTests/DurableEditingAndExportTests.swift:229`).
- The UI includes accessible labels for tools, layer actions, swatches, and numeric controls (`Sources/WatercolorStudio/ToolRail.swift:51`; `Sources/WatercolorStudio/LayersInspector.swift:67`; `Sources/WatercolorStudio/BrushInspector.swift:198`).

## Protocol coverage

- **Clarifying-question sweep:** Established five decision-changing questions above.
- **Hidden-assumption audit:** Found unsupported assumptions in brush orientation, texture continuity, distribution, and recovery UX.
- **Evidence-and-reasoning check:** Compared release claims with the actual brush and performance tests.
- **Standards and conventions:** Checked `CLAUDE.md`, the design, implementation plan, program charter, and adjacent code. Findings JD-001 and JD-002 name direct design conflicts.
- **Specialist-domain boundary:** Deferred deeper UX, performance, concurrency, and deployment judgments to the named specialists.
- **Scope and definition of done:** Found that “release candidate” does not define a customer distribution path.
- **YAGNI evidence sweep:** No YAGNI finding raised. This whole-branch review has no introducing diff, so pre-existing constructs cannot be fairly attributed as speculative additions.
- **Plain-language reframing:** The app saves and replays paint reliably, but its current brush model produces randomized stamps rather than persistent brush hairs, and its release bundle remains local-only.
