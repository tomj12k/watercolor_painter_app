# Watercolor Studio Program Charter

## Outcome

Deliver a self-contained, native macOS watercolor application that is pleasant to paint with, preserves editable projects, and can be built and tested from a fresh checkout.

Audience: the implementation working team. The user is the product sponsor and has authorized the recommended decision at every routine implementation fork.

## Benefits baseline and targets

| Benefit | Baseline | Release target | Evidence |
|---|---:|---:|---|
| Usable watercolor workflow | No app | Create → paint → layer → save → reopen → export succeeds | Acceptance test |
| Responsive painting | No renderer | Interactive 1,600 × 1,200 painting on Apple Silicon | Frame timing/manual test |
| Natural color behavior | No simulation | Wet complementary strokes mix and diffuse visibly | Metal integration test + visual check |
| Maintainable delivery | Empty repository | Repeatable build, tests, package, and documented architecture | CI-equivalent local commands |

## Program structure

| Project | Deliverable | Depends on |
|---|---|---|
| P1 Foundation | Swift package, app shell, shared conventions, build/package commands | — |
| P2 Domain & Documents | Codable model, commands, layers, presets, `.watercolor` lifecycle | P1 |
| P3 Metal Painting Engine | Texture model, stamp/simulation/composite shaders, replay/readback | P1, P2 contracts |
| P4 Input & Tools | Tablet events, sampling, brush/water/erase/smudge/smear/dry semantics | P2, P3 |
| P5 Studio UI | Workspace, tool rail, inspectors, color, paper, layers, zoom/pan | P2, P3, P4 |
| P6 Persistence, Export & Quality | Undo checkpoints, reopen equivalence, PNG, tests, packaging, docs | P2, P3, P5 |

## Critical path

`P1 Foundation → P2 command contracts → P3 pigment engine → P4 stroke delivery → P5 integrated workspace → P6 acceptance and package`

The UI model and shader research may proceed beside P2, but the first end-to-end painting slice cannot complete until P2–P4 join.

## Milestones and exit gates

| Milestone | Status | Release-verification evidence (2026-08-15) |
|---|---|---|
| **M1 — Running native shell** | Complete | `swift package clean && make test && make app` exited 0; `make app` produced the arm64 `.app` bundle. |
| **M2 — First colored mark** | Complete | The Metal renderer’s GPU-backed tests cover pigment deposit and readback; the `CanvasStrokeIntegrationTests` suite covers pointer stroke completion. |
| **M3 — Watercolor behavior** | Complete | Metal API and GPU validation were enabled for 27 `WatercolorRendererTests`, including wet color mixing, wetness decay, every brush/paper enum, and every tool effect; all passed without validation findings. |
| **M4 — Complete studio** | Complete | Source audit confirms visible controls and model/renderer paths for five papers, styles, shapes, hairs, textures, six tools, color picker, numeric brush controls, viewport controls, and 12-layer actions. The retained design variance is direct drag reordering: the shipped UI uses accessible Move up/Move down controls. |
| **M5 — Durable artwork** | Complete | The 125-test suite covers command history, document codec/schema rejection, deterministic replay, `.watercolor` `FileDocument` lifecycle, and non-mutating PNG export. |
| **M6 — Release candidate** | Complete | Fresh clean test/build and plist/executable checks passed. The packaged executable remained alive for five seconds under its exact launched PID and was then terminated deliberately. |

## Decision rights

- Product and routine technical trade-offs: implementation lead chooses the documented recommendation.
- Scope expansion beyond the design: deferred to a later release.
- Data-loss risk, destructive repository action, paid service, publishing, or signing/notarization: requires sponsor authorization.

## Active RAID register

| Type | Item | Owner | Tripwire | Mitigation / release status |
|---|---|---|---|---|
| Risk | Simulation cost grows with layers | P3 | Reference 1,600 × 1,200 canvas misses interaction target at 8–12 layers | Fixed layer cap and reusable texture arrays are implemented, but no release frame-timing or 8/12-layer manual performance run was performed. Retained. |
| Assumption | Apple Silicon is the primary target | Sponsor | Intel-only support becomes required | Fresh verification ran on arm64/Apple Silicon. Intel support was not tested. Retained. |
| Risk | Physical tablet/input acceptance | P4 | Tablet pressure, tilt, rapid strokes, or focus transitions misbehave on hardware | Builder/event-bridge tests and compilation passed; no physical tablet was available for this release verification. Retained. |
| Risk | Accessibility and visual acceptance | P5 | VoiceOver semantics or appearance/regressions are discovered in use | Native accessibility labels are present in source, but VoiceOver and visual screen-capture acceptance were not performed. Retained. |
| Scope variance | Direct drag layer reordering and custom canvas dimensions | P5 | Product requires those design-specified UI interactions in this release | Layer ordering is exposed by Move up/Move down; the model supports 256–4,096 dimensions but the document UI does not expose custom-size creation. Retained for product decision. |

### Closed release risks

| Item | Evidence closing it |
|---|---|
| Metal API/Swift 6 integration friction | Fresh production build passed; 27 renderer tests passed with Metal API Validation and Metal GPU Validation enabled and no findings. |
| Deterministic replay drift | Independent-renderer replay checksum, saved/decoded duplicate replay, and paper-change reopen tests passed in the full suite. |
| App bundle lacks runtime resources | `make app` produced an executable bundle; plist lint and executable checks passed; the packaged executable survived an exact-PID five-second smoke launch. |
| Command schema/replay dependency | Stable schema validation and all semantic command cases are covered by codec and replay tests. |

## Status rules

- Green: current milestone compiles and its focused tests pass.
- Amber: a critical-path test fails or a milestone is blocked for one work cycle.
- Red: build is broken across two consecutive checkpoints, editable project data is at risk, or the critical path requires scope change.

## Final verification record

```text
swift package clean && make test && make app
```

Result: exit 0. `make test` ran **125 tests in 15 suites** with zero failures; the release `WatercolorStudio` product built and was packaged.

```text
env MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1 swift test --filter WatercolorRendererTests
swift test --filter ReplayAndExportTests
```

Result: Metal API Validation and Metal GPU Validation were enabled. **27 renderer tests** and **1 replay/export test** passed with zero failures and no validation findings.

```text
plutil -lint '.build/release/Watercolor Studio.app/Contents/Info.plist'
test -x '.build/release/Watercolor Studio.app/Contents/MacOS/WatercolorStudio'
```

Result: plist `OK`; bundle contains `Contents/Info.plist` and executable `Contents/MacOS/WatercolorStudio` (arm64). The executable’s exact spawned PID stayed alive for five seconds before controlled termination (expected status 143).

The release smoke is process-liveness only. It did not test physical tablet hardware, VoiceOver, signing/notarization, App Store submission, direct drag reordering, or visual screen capture.

Closed tasks are reflected in the implementation plan and git history. Residual risks above remain release follow-ups rather than unsubstantiated completion claims.
