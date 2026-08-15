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

1. **M1 — Running native shell:** app window launches from `swift run`; tests execute; release `.app` can be packaged.
2. **M2 — First colored mark:** a pointer stroke reaches Metal and deposits pigment on paper.
3. **M3 — Watercolor behavior:** wet pigment diffuses, dries, granulates, and mixes; all six tools operate.
4. **M4 — Complete studio:** presets, paper, color, brush controls, zoom/pan, and 12-layer management are usable.
5. **M5 — Durable artwork:** undo/redo, save/reopen replay, PNG export, and schema errors work.
6. **M6 — Release candidate:** automated tests, release build, packaged app, README, and manual smoke test pass.

## Decision rights

- Product and routine technical trade-offs: implementation lead chooses the documented recommendation.
- Scope expansion beyond the design: deferred to a later release.
- Data-loss risk, destructive repository action, paid service, publishing, or signing/notarization: requires sponsor authorization.

## Active RAID register

| Type | Item | Owner | Tripwire | Mitigation |
|---|---|---|---|---|
| Risk | Metal API/Swift 6 integration friction | P3 | Release build or strict-concurrency compile fails | Isolate engine behind main-actor facade; compile after every slice |
| Risk | Simulation cost grows with layers | P3 | Reference canvas misses interaction target at 8 layers | Dirty regions, array textures, batched stamps, layer cap |
| Risk | Deterministic replay drifts | P2/P3 | Reopened checksum differs | Seed all noise and record simulation counts |
| Risk | App bundle lacks runtime resources | P1/P6 | Packaged app launches differently from `swift run` | Embed shader source in module and smoke-test packaged binary |
| Assumption | Apple Silicon is the primary target | Sponsor | Intel-only support becomes required | Keep portable Metal feature set; document tested target |
| Dependency | P2 command schema must stabilize before replay | P2 | Shader parameters require undocumented fields | Version command payloads and keep render-only fields derived |

## Status rules

- Green: current milestone compiles and its focused tests pass.
- Amber: a critical-path test fails or a milestone is blocked for one work cycle.
- Red: build is broken across two consecutive checkpoints, editable project data is at risk, or the critical path requires scope change.

Closed tasks are reflected in the implementation plan and git history. Risks are reviewed at each milestone rather than accumulated as a passive log.

