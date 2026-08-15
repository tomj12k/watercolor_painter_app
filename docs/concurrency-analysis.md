# Concurrency Analysis: Watercolor Studio on `main`

## Scope

This static review covered `WatercolorRenderer.swift`, `StudioModel.swift`, `CanvasEventView.swift`, and `StudioCommands.swift` on `main`. It traced main-actor execution, Metal completion callbacks, preview draining and cancellation, stroke value copying, export lifetime, replay, and renderer resource admission. No production or test files were changed, and no timing claim below depends on a benchmark.

## Summary

The highest-priority defect can leave document history and rendered pixels describing different paintings. Five further issues can drop rapid strokes, make long strokes increasingly expensive, freeze the window during replay or export readback, let stale exports overwrite newer files, and exceed a safe peak Metal working set while building a candidate renderer.

| Priority | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 2 |

## Findings

### C-001: Canceling during final GPU commit can persist a stroke whose pixels were restored away

- **Priority:** Critical
- **Location:** `Sources/WatercolorStudio/StudioModel.swift:220`, `Sources/WatercolorStudio/StudioModel.swift:245`, `Sources/WatercolorEngine/WatercolorRenderer.swift:292`, `Sources/WatercolorEngine/WatercolorRenderer.swift:339`
- **Observed outcome:** A focus change, model swap, or pan gesture can cancel a stroke while its final Metal command is running. The app can then add that stroke to undo history even though the cancellation command restores the pre-stroke textures. The saved project and visible canvas disagree until a later replay.
- **Required interleaving:** `commitStrokePreview` passes its guard and suspends in `finishStrokePreview` while the final command buffer runs. During that suspension, `cancelStrokePreview` clears the model's active ID and queues a snapshot restore on the same Metal command queue. The final-buffer continuation resumes, but `commitStrokePreview` never checks the active ID again after `await renderer.finishStrokePreview(stroke)`. It calls `recordRenderedStroke`, appends to the editor, and publishes the project. Metal queue ordering guarantees the later cancellation restore runs after the final stroke buffer.
- **Likelihood:** The window is bounded by final GPU execution, but the application calls cancellation from ordinary focus loss, canvas-model synchronization, and pan entry. Large canvases and busy GPUs widen it.
- **Evidence:** The renderer completion handler only records the error under a lock and resumes the continuation, which is safe by itself. Actor reentrancy after that suspension is the problem. Canceling the preview-drain task does not cancel the separate commit task, and the checked Metal continuation is not cancellation-aware.
- **Recommended correction:** Drive the transaction with one generation/state token that covers drain, finish, and cancel. After every Metal suspension, verify both the model generation and renderer transaction identity before recording or publishing. Make finish-versus-cancel resolve exactly once, and add a controlled-completion test that cancels after the final buffer is committed but before its continuation resumes.

### C-002: A second rapid stroke can be accepted by the view and silently rejected by the model

- **Priority:** High
- **Location:** `Sources/WatercolorStudio/CanvasEventView.swift:234`, `Sources/WatercolorStudio/CanvasEventView.swift:258`, `Sources/WatercolorStudio/StudioModel.swift:199`, `Sources/WatercolorStudio/StudioModel.swift:220`
- **Observed outcome:** An artist who starts another stroke while the prior mouse-up commit is awaiting Metal can draw a complete gesture that never previews and never enters history.
- **Required interleaving:** `CanvasEventView.completeStroke` clears its builder and launches an untracked main-actor `Task`. While that task awaits drain or final GPU completion, `capabilities.canPaint` remains true. A new mouse-down creates and retains a new builder, but `StudioModel.beginStrokePreview` returns because the old preview ID is active. Later updates are ignored, and the second commit returns because its ID does not match.
- **Likelihood:** This is reachable whenever finalization takes longer than the gap between two gestures. The documented manual acceptance scope includes rapid strokes, and larger canvases make the overlap more likely.
- **Evidence:** The model's begin and commit methods return `Void`, so the view cannot tell that admission failed. The view also stores no handle for the commit task, so it cannot serialize, cancel, or transfer ownership of that work.
- **Recommended correction:** Give stroke admission an explicit result and keep one owned gesture/commit task per canvas. Either queue the next completed gesture behind the current commit or disable stroke admission until finalization completes; do not retain a live builder after the model rejects its preview. Test two back-to-back gestures with the first Metal completion held open.

### C-003: Pointer bursts copy and rescan ever-growing full strokes on the main actor

- **Priority:** High
- **Location:** `Sources/WatercolorStudio/CanvasEventView.swift:14`, `Sources/WatercolorStudio/CanvasEventView.swift:30`, `Sources/WatercolorStudio/StudioModel.swift:214`, `Sources/WatercolorEngine/WatercolorRenderer.swift:265`, `Sources/WatercolorEngine/WatercolorRenderer.swift:403`
- **Observed outcome:** Long strokes become progressively more expensive and can lag even though the renderer submits only newly appended points.
- **Required condition:** `CanvasStrokeBuilder.append` copies the `StrokeCommand` property into a local variable, mutates its `Array`, then assigns it back. Passing `currentStroke` into `pendingStrokePreview` and an in-flight renderer call also keeps older array storage alive. The next append must detach from any still-shared buffer under Swift copy-on-write. Each submitted renderer update then validates every accumulated point before slicing out the appended suffix.
- **Likelihood:** Shared prior snapshots are expected during the bursts this drain was built to coalesce. With `n` successively appended samples, repeated full-buffer detaches and validation scans can approach the growing series `1 + 2 + ... + n`. The accepted stroke limit is 65,536 points.
- **Evidence:** Incremental encoding at `WatercolorRenderer.swift:403` reduces GPU stamp work, but it happens after the main-actor copy-on-write pressure and full validation scan. Coalescing lowers submission count; it does not change the full-stroke values exchanged by the builder, model, and renderer.
- **Recommended correction:** Keep mutable point storage with unique ownership for the active gesture and pass append-only chunks plus an immutable header to the preview drain. Validate new points as they arrive, then assemble one durable `StrokeCommand` at commit. Measure pointer-handler time and copied bytes for a maximum-length synthetic stroke.

### C-004: Large replay and export readback work still holds the UI actor

- **Priority:** High
- **Location:** `Sources/WatercolorEngine/WatercolorRenderer.swift:41`, `Sources/WatercolorEngine/WatercolorRenderer.swift:488`, `Sources/WatercolorEngine/WatercolorRenderer.swift:715`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1468`, `Sources/WatercolorStudio/StudioModel.swift:587`, `Sources/WatercolorStudio/StudioModel.swift:670`
- **Observed outcome:** Opening or structurally editing a long project can freeze the whole window through replay. Export can also pause the window before background PNG encoding begins.
- **Required condition:** `WatercolorRenderer` is main-actor isolated. Replay validates and plans up to 100,000 commands, encodes every replay action, and calls `waitUntilCompleted`. Studio history fallbacks and structural edits construct candidates synchronously from main-actor methods. Export detaches ImageIO encoding only after `makeCGImage` waits for the latest command buffer, allocates and fills the full four-byte BGRA readback `Data`, and constructs the `CGImage` on the main actor. A 4,096-square readback alone copies 67,108,864 bytes.
- **Likelihood:** The synchronous work is unconditional on these paths; only its duration varies with document size, command history, and GPU load. The project design requires low input latency and says GPU encoding belongs on a dedicated serial queue, while the implementation keeps it on the main actor.
- **Evidence:** The existing blocked-export test proves the actor remains schedulable during the injected worker operation. It starts blocking after the synchronous snapshot, so it does not cover readback latency. Awaiting a Metal completion would avoid a CPU-blocking wait, but replay planning and encoding must also leave the UI actor.
- **Recommended correction:** Put renderer mutation and command encoding behind one dedicated actor or serial executor. Submit an immutable project snapshot, keep the old renderer visible, and publish a completed candidate on the main actor only when its operation generation is still current. Move readback into that renderer executor and return an immutable snapshot to the export worker. Do not use `Task.detached` to access the current main-actor renderer.

### C-005: Older export tasks can overwrite a newer export to the same destination

- **Priority:** Medium
- **Location:** `Sources/WatercolorStudio/StudioCommands.swift:37`, `Sources/WatercolorStudio/StudioModel.swift:143`, `Sources/WatercolorStudio/StudioModel.swift:587`
- **Observed outcome:** If two exports target the same file and complete out of order, the older canvas snapshot can become the final file after the newer export has completed.
- **Required interleaving:** Every panel completion creates an untracked task, and every export creates a detached encoding/write task. Starting a later export changes `latestPNGExportID`, but that token only suppresses stale error-state updates after the worker returns. It neither cancels the older worker nor prevents its atomic write. If export B finishes and then export A finishes to the same URL, A replaces B with its older snapshot.
- **Likelihood:** Two save panels or repeated exports to the same chosen name are required. Slow storage or a large PNG makes out-of-order completion plausible. Even with different destinations, repeated exports retain one full snapshot and encoder workload each with no concurrency cap.
- **Evidence:** Atomic writing protects each individual replacement from a partial file; it does not impose newest-request-wins ordering across separate tasks. No export task handle or per-destination generation is stored.
- **Recommended correction:** Own export tasks in the model and serialize writes per canonical destination. Recheck a destination generation immediately before replacement, or cancel superseded work with cooperative checks before encoding and writing. Add a controlled-worker test where the newer same-URL export completes first.

### C-006: Candidate replay has no peak resource admission while old renderers remain live

- **Priority:** Medium
- **Location:** `Sources/WatercolorEngine/WatercolorRenderer.swift:56`, `Sources/WatercolorEngine/WatercolorRenderer.swift:214`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1575`, `Sources/WatercolorStudio/StudioModel.swift:697`, `Sources/WatercolorStudio/StudioModel.swift:802`
- **Observed outcome:** A structural edit can place the process under severe unified-memory pressure or fail during Metal allocation even though checkpoint storage is nominally within its 256 MiB budget.
- **Required condition:** The checkpoint budget counts retained checkpoints only. `makeCandidate` allocates and fully replays a second renderer while the active renderer must stay live for rollback and display. A preview snapshot, export snapshot, and retained checkpoints can overlap that pair. No check compares this peak against a device or application working-set budget before allocation.
- **Likelihood:** The overlap occurs on every candidate build; dangerous pressure depends on canvas size and layer capacity. The renderer's own base-texture formula reaches 4,160,749,568 bytes at the accepted 4,096 × 4,096, 12-layer limit, before the active renderer or preview snapshot is counted.
- **Evidence:** `prepareCurrentRendererCheckpointForCandidateAllocation` evicts old checkpoints, but it cannot release the active renderer before candidate success. Allocation failure preserves the old model, which is good transactional behavior, but it does not prevent the allocation attempt, main-actor stall, or system memory pressure.
- **Recommended correction:** Admit replay before allocation using checked arithmetic and a peak estimate that includes active, candidate, preview, export, and checkpoint resources. Permit only one candidate build at a time. Combine that gate with the generation-based renderer executor from C-004 so obsolete candidates are not published and queued work can be dropped before Metal submission.

## Verified Concurrency Strengths

- Metal completion handlers do not directly mutate main-actor renderer state. They record errors through a locked transaction and resume the continuation; actor-isolated code continues after the hop back to the main actor.
- The preview-drain ID guards prevent an old canceled drain from clearing a newer drain's task fields when its non-cancelable Metal wait eventually resumes.
- PNG encoding and filesystem writing run away from the main actor, and stale export completions cannot overwrite a newer unrelated model error.
- Candidate renderers are published only after construction and replay succeed, so an ordinary candidate-construction failure leaves the active renderer and project in place.
