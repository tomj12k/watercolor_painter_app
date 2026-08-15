# Customer Release Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give customers recoverable failures, prepare a fail-closed signed distribution path, and qualify the app with honest Metal, latency, memory, and customer-UX evidence.

**Architecture:** Typed failure categories carry safe recovery text and diagnostic metadata from Core/Engine into SwiftUI. Local packaging remains unchanged; a separate script owns Developer ID signing and notarization. Release qualification separates deterministic tests from environment-gated hardware and signing gates.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Metal, Bash, `codesign`, `xcrun notarytool`, `spctl`, `plutil`.

**Spec:** `docs/superpowers/specs/2026-08-15-production-brush-dynamics-design.md`

## Global Constraints

- Diagnostics never include painting pixels, pigment values, file paths, or document names.
- Local packaging stays unsigned and is never described as customer-distributable.
- Distribution stops when identity, notarization, stapling, or verification is absent or fails.
- Metal qualification cannot report pass when no Metal device ran the renderer tests.
- Every production edit follows RED, GREEN, refactor, then an atomic commit.

---

### Task 1: Actionable customer failures and safe diagnostics

**Files:**
- Create: `Sources/WatercolorStudio/StudioDiagnostic.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Modify: `Sources/WatercolorStudio/WatercolorStudioApp.swift`
- Modify: `Sources/WatercolorStudio/NewCanvasConfiguration.swift`
- Modify: `Tests/WatercolorStudioTests/StudioModelTests.swift`
- Modify: `Tests/WatercolorStudioTests/StudioDocumentHostTests.swift`

**Interfaces:**
- Produces `StudioFailure.Code` stable string codes.
- Produces `StudioFailure.recoverySuggestion` and `diagnostic: StudioDiagnostic`.
- Produces `StudioDiagnostic.customerText` with app, OS, GPU, canvas, layer, command, and error-code metadata only.

- [ ] **Step 1: Write RED failure-mapping and privacy tests**

```swift
@Test func resourceFailureExplainsRecoveryWithoutDocumentContent() throws {
    let failure = StudioFailure.resourceBudget(required: 3_000_000_000, available: 1_000_000_000, context: context)
    #expect(failure.code == .resourceBudget)
    #expect(failure.recoverySuggestion.contains("Reduce the canvas size or layer count"))
    #expect(!failure.diagnostic.customerText.contains(project.layers[0].name))
    #expect(!failure.diagnostic.customerText.contains(documentURL.path))
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run: `swift test --filter StudioModelTests/resourceFailureExplainsRecoveryWithoutDocumentContent`

Expected: compile failure because typed failures and diagnostics do not exist.

- [ ] **Step 3: Add stable failure categories**

Map resource budget, work budget, Metal unavailable, GPU execution, malformed document, newer schema, export, and unknown failures. Customer messages state what happened, whether the painting remains safe, and one next action. Keep raw UUIDs and allocation implementation terms out of the primary message.

- [ ] **Step 4: Add Copy Details and recovery actions**

Use SwiftUI’s alert builder with Dismiss and Copy Details. Resource failure in the new-canvas sheet keeps the sheet open. Renderer initialization failure offers Retry. Copy Details writes only `StudioDiagnostic.customerText` to `NSPasteboard`.

- [ ] **Step 5: Test state preservation and retry**

Inject a first-attempt renderer/resource failure and second-attempt success. Assert the original document remains unchanged after failure and the retry replaces it exactly once after success.

- [ ] **Step 6: Run studio tests and commit**

Run: `swift test --filter WatercolorStudioTests`

```bash
git add Sources/WatercolorStudio Tests/WatercolorStudioTests
git commit -m "feature: add recoverable studio failures"
```

### Task 2: Real document adapter recovery coverage

**Files:**
- Modify: `Sources/WatercolorStudio/PaintingDocument.swift`
- Modify: `Sources/WatercolorCore/DocumentCodec.swift`
- Modify: `Tests/WatercolorStudioTests/PaintingDocumentTests.swift`
- Modify: `Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift`

**Interfaces:**
- Consumes schema-version-3 codec and typed localized errors.
- Produces distinct malformed, invalid, over-budget, and newer-version categories at the `FileDocument` boundary.

- [ ] **Step 1: Write RED adapter round-trip and invalid-input tests**

Construct real `FileWrapper` and `FileDocument.ReadConfiguration` values for a representative version-3 painting, malformed bytes, invalid nested brush dynamics, and newer schema.

- [ ] **Step 2: Run tests and verify RED**

Run: `swift test --filter PaintingDocumentTests`

Expected: current adapter coverage lacks the fixtures or collapses categories.

- [ ] **Step 3: Preserve error categories through the adapter**

Do not replace codec errors with a generic malformed error. Keep localized recovery text stable by category. Preserve the current host/model when replacement fails.

- [ ] **Step 4: Run codec and document tests**

Run: `swift test --filter PaintingDocumentCodecTests && swift test --filter PaintingDocumentTests && swift test --filter StudioDocumentHostTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/WatercolorCore/DocumentCodec.swift Sources/WatercolorStudio/PaintingDocument.swift Tests/WatercolorCoreTests/PaintingDocumentCodecTests.swift Tests/WatercolorStudioTests/PaintingDocumentTests.swift
git commit -m "test: cover document recovery boundaries"
```

### Task 3: Serialize exports by destination

**Files:**
- Modify: `Sources/WatercolorStudio/StudioModel.swift`
- Modify: `Tests/WatercolorStudioTests/StudioModelTests.swift`

**Interfaces:**
- Produces: a destination-keyed export coordinator that prevents older work from overwriting newer output.
- Guarantees: different destinations may export concurrently; the same standardized URL commits in request order with the newest request last.

- [ ] **Step 1: Write a controlled-completion RED test**

Start two exports to the same destination, hold the first worker, complete the second, then release the first. Assert the final bytes belong to the second request. Add a parallel test proving two different URLs do not block each other.

- [ ] **Step 2: Run the test and verify RED**

Run: `swift test --filter StudioModelTests/newerSameDestinationExportCannotBeOverwritten`

Expected: the older worker writes after the newer worker and overwrites it.

- [ ] **Step 3: Coordinate final writes per standardized URL**

Encode to a unique temporary sibling file, then pass destination generation through a small actor. Only the latest generation for that standardized URL may atomically replace the destination; stale generations delete their temporary output. Keep UI error publication guarded by export ID as it is today.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter StudioModelTests`

```bash
git add Sources/WatercolorStudio/StudioModel.swift Tests/WatercolorStudioTests/StudioModelTests.swift
git commit -m "fix: serialize exports by destination"
```

### Task 4: Fail-closed Developer ID distribution pipeline

**Files:**
- Create: `scripts/package_distribution.sh`
- Modify: `Makefile`
- Modify: `README.md`
- Create: `Tests/Packaging/package_distribution_test.sh`

**Interfaces:**
- Consumes `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_PROFILE` environment variables.
- Produces `.build/distribution/Watercolor Studio.app` only after sign, notarize, staple, and verify succeed.

- [ ] **Step 1: Write RED shell contract tests**

```bash
env -u DEVELOPER_ID_APPLICATION -u NOTARYTOOL_PROFILE scripts/package_distribution.sh
test "$?" -ne 0
test ! -e '.build/distribution/Watercolor Studio.app'
```

Use temporary fake `codesign`, `xcrun`, and `spctl` executables on `PATH` to assert argument order without using real credentials.

- [ ] **Step 2: Run the shell tests and verify RED**

Run: `bash Tests/Packaging/package_distribution_test.sh`

Expected: failure because the distribution script does not exist.

- [ ] **Step 3: Implement the distribution script**

The script calls `scripts/package_app.sh`, copies to a temporary distribution directory, signs with `--options runtime --timestamp`, verifies with `codesign --verify --deep --strict`, submits with `xcrun notarytool submit --wait --keychain-profile`, staples, assesses with `spctl --assess --type execute`, and only then moves the app to the final path. A trap removes incomplete output.

- [ ] **Step 4: Add Makefile and documentation contracts**

Add `make distribution` without changing `make app`. README states exactly which command is local-only, which needs Apple credentials, and which verification commands run.

- [ ] **Step 5: Run packaging checks**

Run: `bash -n scripts/package_distribution.sh && bash Tests/Packaging/package_distribution_test.sh && make app && plutil -lint '.build/release/Watercolor Studio.app/Contents/Info.plist'`

- [ ] **Step 6: Commit**

```bash
git add scripts/package_distribution.sh Tests/Packaging/package_distribution_test.sh Makefile README.md
git commit -m "build: add signed distribution pipeline"
```

### Task 5: Honest Metal and performance qualification

**Files:**
- Modify: `Tests/WatercolorEngineTests/WatercolorRendererTests.swift`
- Create: `Tests/WatercolorStudioTests/PerformanceQualificationTests.swift`
- Create: `scripts/qualify_release.sh`
- Modify: `Makefile`
- Modify: `README.md`

**Interfaces:**
- Consumes `WATERCOLOR_REQUIRE_METAL=1` and `WATERCOLOR_RUN_BENCHMARK=1`.
- Produces machine-readable benchmark lines for p50/p95 preview, commit, structural edit, peak resource estimate, and GPU duration.

- [ ] **Step 1: Write RED no-device and release-lane tests**

Pass `device: nil` and assert `RendererError.metalUnavailable`. Add a qualification precondition that throws when `WATERCOLOR_REQUIRE_METAL=1` and `MTLCreateSystemDefaultDevice()` returns nil instead of returning early.

- [ ] **Step 2: Run focused tests and verify RED where coverage is missing**

Run: `swift test --filter WatercolorRendererTests/metalUnavailableIsReported && env WATERCOLOR_REQUIRE_METAL=1 swift test --filter WatercolorRendererTests`

- [ ] **Step 3: Add performance and UI-responsiveness fixtures**

Drive 120 Hz delta batches through `StudioModel` at 1600 by 1200 for 1, 8, and 12 layers. Warm up, record at least 30 samples, and print p50/p95. Enforce preview p95 at 16.7 ms and pointer-up commit p95 at 33.3 ms on the pinned release Mac. During undo, redo, layer merge, document replacement, and export readback, schedule a 60 Hz main-actor heartbeat and assert no gap exceeds 100 ms. If a common operation misses that bound, move replay/encoding/readback work behind a dedicated serialized renderer executor while keeping MTKView presentation and published state changes on `MainActor`.

- [ ] **Step 4: Build the release qualification script**

Run clean tests, required-Metal renderer tests with validation variables, the benchmark lane, release packaging, plist lint, executable/icon checks, exact-PID five-second liveness, and `git diff --check`. The script writes `.build/qualification/report.txt` and exits nonzero on any failed gate.

- [ ] **Step 5: Run qualification**

Run: `scripts/qualify_release.sh`

Expected: deterministic gates pass. Signing/notarization is reported as NOT RUN unless credentials were explicitly supplied; it is never reported as pass.

- [ ] **Step 6: Commit**

```bash
git add Tests/WatercolorEngineTests Tests/WatercolorStudioTests/PerformanceQualificationTests.swift scripts/qualify_release.sh Makefile README.md
git commit -m "test: add customer release qualification"
```

### Task 6: Consolidated production review and remediation

**Files:**
- Create: `docs/code-review-production-readiness.md`
- Modify only source, tests, scripts, or docs required by validated findings.

**Interfaces:**
- Consumes specialist reports in `docs/*analysis.md`, `docs/test-plan.md`, and `docs/junior-developer-review.md`.
- Produces one severity-calibrated review report and a clean release candidate.

- [ ] **Step 1: Re-review the exact implementation head**

Run general, security, behavioral, concurrency, edge-case, test, UX, and performance review lenses over the complete diff from `adb3d27`. Validate every corrective finding against reachable customer behavior.

- [ ] **Step 2: Write RED tests for accepted Critical and Warning findings**

Do not modify production for unproven suggestions. Record external signing credentials as a distribution blocker, not a code failure.

- [ ] **Step 3: Implement and verify remediation**

Run focused tests after each fix, then `make test` and Metal validation.

- [ ] **Step 4: Write the consolidated report**

Use task IDs, file-line evidence, customer impact, fix route, severity counts, strengths, and a release recommendation. Keep raw specialist reports as evidence or remove them only after their findings appear in the consolidated report.

- [ ] **Step 5: Run final release qualification and manual UX smoke**

Run: `scripts/qualify_release.sh`

Then use Computer Use on an isolated app instance to create a disposable canvas, test every brush family and dynamics control, paint a long stroke, undo/redo, add/reorder/merge layers, save/reopen, export PNG, and exercise one recoverable resource failure. Preserve any existing user process and document.

- [ ] **Step 6: Commit final remediation and report**

```bash
git add Sources Tests scripts Makefile README.md docs
git commit -m "fix: complete production readiness review"
```
