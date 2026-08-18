# Watercolor Studio Local MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in local MCP server that lets an AI inspect and control Watercolor Studio through validated semantic painting tools without changing existing human workflows.

**Architecture:** Add a small `WatercolorMCP` library for JSON-RPC/MCP schemas, framing, endpoint discovery, and Unix-socket bridge messages. Add a `WatercolorStudioMCP` stdio executable that forwards `initialize`, `tools/list`, and `tools/call` requests to the running app. Add an app-owned, opt-in bridge/controller that dispatches validated requests through the existing `StudioModel` on the main actor.

**Tech Stack:** Swift 6 / SwiftPM, Foundation, AppKit, SwiftUI, existing WatercolorCore/WatercolorEngine models, POSIX Unix-domain sockets, JSON-RPC 2.0 over stdio.

**Spec:** `docs/superpowers/specs/2026-08-17-watercolor-studio-mcp-design.md`

## Global Constraints

- Local-only transport: no TCP listener, browser endpoint, cloud service, or network exposure.
- AI Control is off by default and must not alter existing mouse/tablet/keyboard/accessibility/document/save behavior when off.
- All mutations route through `StudioModel`, `CanvasStrokeBuilder`, and existing renderer/resource/work limits.
- Every committed AI stroke is one normal undoable command; failed/cancelled work publishes no partial document mutation.
- MCP results expose stable, customer-safe error codes/messages and never raw paths, UUIDs, or GPU diagnostics in ordinary tool results.
- Existing full tests, release build, Metal validation, packaging, and process-cleanup gates remain required.
- Each task ends with focused tests and a git commit; push completed commits to `origin/main`.

## File Map

- Create `Sources/WatercolorMCP/MCPTypes.swift`: Codable MCP/JSON-RPC, tool, bridge, endpoint, and error value types.
- Create `Sources/WatercolorMCP/JSONRPCFraming.swift`: newline-delimited stdio framing and bounded JSON decoding.
- Create `Sources/WatercolorMCP/EndpointDiscovery.swift`: 0600 endpoint descriptor write/read/remove helpers.
- Create `Sources/WatercolorStudioMCP/main.swift`: stdio MCP executable lifecycle and request forwarding.
- Create `Sources/WatercolorStudio/MCPBridge.swift`: Unix-socket listener/client bridge owned by the app.
- Create `Sources/WatercolorStudio/MCPDrawingController.swift`: main-actor session state and semantic tool dispatch.
- Modify `Package.swift`: add `WatercolorMCP` library, `WatercolorStudioMCP` executable, and test dependencies.
- Modify `Sources/WatercolorStudio/StudioModel.swift`: add narrow read/mutation adapter methods only where the existing public model API cannot safely express a semantic tool.
- Modify `Sources/WatercolorStudio/StudioView.swift` and `Sources/WatercolorStudio/StudioCommands.swift`: opt-in toggle, active-session indicator, Stop action, and accessibility copy.
- Create `Tests/WatercolorMCPTests/MCPProtocolTests.swift`: framing, schema, limits, and stable errors.
- Create `Tests/WatercolorMCPTests/EndpointDiscoveryTests.swift`: permissions, stale descriptor, malformed descriptor, and cleanup.
- Create `Tests/WatercolorStudioTests/MCPDrawingControllerTests.swift`: tool dispatch, ownership, rollback, cancellation, and compatibility.
- Create `Tests/WatercolorStudioTests/MCPBridgeTests.swift`: local socket handshake, disconnect, Stop, and request ordering.
- Modify `Tests/WatercolorStudioTests/StudioModelTests.swift`: AI multi-batch stroke/replay/undo integration coverage.

### Task 1: Protocol and transport foundation

**Files:**
- Create: `Sources/WatercolorMCP/MCPTypes.swift`
- Create: `Sources/WatercolorMCP/JSONRPCFraming.swift`
- Create: `Sources/WatercolorMCP/EndpointDiscovery.swift`
- Modify: `Package.swift`
- Test: `Tests/WatercolorMCPTests/MCPProtocolTests.swift`
- Test: `Tests/WatercolorMCPTests/EndpointDiscoveryTests.swift`

**Interfaces:**
- `public struct MCPJSONRPCRequest: Codable, Sendable { let jsonrpc: String; let id: MCPRequestID?; let method: String; let params: JSONValue? }`
- `public struct MCPJSONRPCResponse: Codable, Sendable { let jsonrpc: String; let id: MCPRequestID?; let result: JSONValue?; let error: MCPRPCError? }`
- `public enum JSONValue: Codable, Equatable, Sendable`
- `public struct MCPTool: Codable, Sendable { let name: String; let description: String; let inputSchema: JSONValue }`
- `public struct MCPBridgeRequest: Codable, Sendable { let token: String; let request: MCPJSONRPCRequest }`
- `public struct MCPBridgeResponse: Codable, Sendable { let response: MCPJSONRPCResponse }`
- `public actor JSONRPCLineReader` and `public struct JSONRPCLineWriter` with a 1 MiB frame limit.
- `public struct MCPEndpointDescriptor: Codable, Sendable { let socketPath: String; let token: String; let protocolVersion: String }`

- [ ] **Step 1: Add failing protocol tests** for valid/invalid JSON-RPC requests, notification IDs, malformed JSON, oversized lines, tool schema encoding, and stable error serialization.
- [ ] **Step 2: Run `swift test --filter MCPProtocolTests`** and verify the missing types/framing APIs fail.
- [ ] **Step 3: Implement the bounded Codable value types and newline framing**; reject non-object requests, invalid `jsonrpc`, frames over 1 MiB, non-finite numeric JSON values, and unknown required fields only where the schema requires it.
- [ ] **Step 4: Add failing endpoint tests** for descriptor round-trip, 0600 permissions, malformed/stale descriptor rejection, and cleanup.
- [ ] **Step 5: Implement endpoint discovery** under `~/Library/Application Support/WatercolorStudio/mcp-endpoint.json`, writing atomically with owner-only permissions and removing only a descriptor whose token matches the active session.
- [ ] **Step 6: Run `swift test --filter 'MCPProtocolTests|EndpointDiscoveryTests'`** and `swift build`; verify green.
- [ ] **Step 7: Commit** with `feat: add local MCP protocol foundation` and push `origin/main`.

### Task 2: Stdio MCP executable

**Files:**
- Create: `Sources/WatercolorStudioMCP/main.swift`
- Modify: `Package.swift`
- Test: `Tests/WatercolorMCPTests/MCPServerTests.swift`

**Interfaces:**
- `MCPServer.run(stdin: FileHandle, stdout: FileHandle, endpoint: MCPEndpointLocator) async throws`
- MCP methods: `initialize`, `notifications/initialized`, `tools/list`, `tools/call`.
- Bridge request method: `watercolor/toolsCall`.

- [ ] **Step 1: Add failing server tests** for initialization negotiation, tool listing, notification handling, unknown method errors, malformed tool arguments, and forwarding one request to a fake bridge.
- [ ] **Step 2: Run `swift test --filter MCPServerTests`** and verify compile/behavior RED.
- [ ] **Step 3: Implement stdio server dispatch** with bounded line reads, MCP protocol version negotiation (`2025-06-18` preferred, compatible fallback accepted), no stdout logging, stderr diagnostics only, and clean EOF shutdown.
- [ ] **Step 4: Implement endpoint discovery and Unix-socket forwarding**; connect only to the descriptor path, send the token on every request, apply a 30-second request timeout, and map disconnects to `bridgeUnavailable` without retrying mutations automatically.
- [ ] **Step 5: Run protocol/server tests and `swift build --product WatercolorStudioMCP`**; verify no app process is launched by server unit tests.
- [ ] **Step 6: Commit** with `feat: add stdio MCP server` and push `origin/main`.

### Task 3: App bridge and AI-control lifecycle

**Files:**
- Create: `Sources/WatercolorStudio/MCPBridge.swift`
- Create: `Sources/WatercolorStudio/MCPDrawingController.swift`
- Modify: `Sources/WatercolorStudio/WatercolorStudioApp.swift`
- Modify: `Sources/WatercolorStudio/StudioView.swift`
- Modify: `Sources/WatercolorStudio/StudioCommands.swift`
- Test: `Tests/WatercolorStudioTests/MCPBridgeTests.swift`
- Test: `Tests/WatercolorStudioTests/MCPDrawingControllerTests.swift`

**Interfaces:**
- `@MainActor final class MCPDrawingController: ObservableObject`
- `@Published private(set) var isEnabled: Bool`, `isConnected: Bool`, `sessionLabel: String?`
- `func setEnabled(_ enabled: Bool)`
- `func stopSession()`
- `func handle(_ request: MCPJSONRPCRequest) async -> MCPJSONRPCResponse`
- `@MainActor final class MCPBridge` with `start()`, `stop()`, and an injected socket implementation for tests.

- [ ] **Step 1: Add failing lifecycle tests** for disabled-by-default state, no endpoint while disabled, enable/disable cleanup, handshake token validation, Stop cancellation, disconnect cleanup, and no UI shortcut/focus changes.
- [ ] **Step 2: Run focused lifecycle tests** and capture RED.
- [ ] **Step 3: Implement the app-owned Unix listener** with owner-only socket permissions, random path, per-session token, one active client, bounded request size, serialized request handling, and graceful shutdown on disable/window close.
- [ ] **Step 4: Add the controller state machine** (`disabled`, `enabled`, `connected`, `stopping`) and ensure Stop rejects new mutations, cancels active strokes, and leaves the document unchanged for uncommitted work.
- [ ] **Step 5: Add the visible AI Control UI** as an additive toolbar/menu control with accessible label/value/hint, active-session indicator, and Stop action. Do not change existing tool rail, brush inspector, save flow, or keyboard shortcuts.
- [ ] **Step 6: Run focused bridge/lifecycle tests plus `swift test --filter 'InitialDocumentFlowTests|StudioDocumentHostTests|StudioShortcutRouterTests'`**; verify existing UX contracts remain green.
- [ ] **Step 7: Commit** with `feat: add opt-in app MCP bridge` and push `origin/main`.

### Task 4: Read-only tools and validated brush/layer control

**Files:**
- Modify: `Sources/WatercolorStudio/MCPDrawingController.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift` only for safe adapter methods
- Test: `Tests/WatercolorStudioTests/MCPDrawingControllerTests.swift`

**Interfaces:**
- Tools: `canvas_state`, `brush_catalog`, `layer_list`, `canvas_snapshot`, `set_brush`, `select_tool`, `select_layer`.
- Every tool returns `{ "ok": true, "data": ... }` or `{ "ok": false, "error": { "code": ..., "message": ... } }`.

- [ ] **Step 1: Add failing tests** for complete brush catalog ranges, atomic set-brush validation, invalid/non-finite values, selected tool/layer, snapshot availability, and no mutation when AI Control is disabled.
- [ ] **Step 2: Implement read-only snapshots and catalog generation** from the same enums/presentation metadata used by the current UI; never duplicate option lists as unrelated literals.
- [ ] **Step 3: Implement atomic brush updates** by validating a complete candidate `BrushSettings` before assigning it; preserve unrelated fields and reject values outside the UI ranges.
- [ ] **Step 4: Implement selected-tool/layer validation** through existing capability checks; return stable errors rather than silently selecting a different object.
- [ ] **Step 5: Run focused tests and existing BrushInspector/StudioModel suites**; verify current accessibility/presentation tests remain green.
- [ ] **Step 6: Commit** with `feat: expose MCP brush and canvas state tools` and push `origin/main`.

### Task 5: Semantic strokes, layers, history, and export

**Files:**
- Modify: `Sources/WatercolorStudio/MCPDrawingController.swift`
- Modify: `Sources/WatercolorStudio/StudioModel.swift` only for an adapter that reuses `CanvasStrokeBuilder`
- Test: `Tests/WatercolorStudioTests/MCPDrawingControllerTests.swift`
- Test: `Tests/WatercolorStudioTests/StudioModelTests.swift`

**Interfaces:**
- Tools: `stroke_begin`, `stroke_append`, `stroke_end`, `stroke_cancel`, `create_layer`, `duplicate_layer`, `delete_layer`, `move_layer`, `merge_layer`, `clear_layer`, `set_layer_properties`, `undo`, `redo`, `dry_layer`, `export_png`.
- Stroke IDs are server-generated opaque strings; only the owning session may append/end/cancel them.
- Point batches are capped at 512 points per request and the existing project/stroke limits remain authoritative.

- [ ] **Step 1: Add failing tests** for one AI stroke using the current brush, multi-batch append, normalized coordinate conversion, pressure/tilt/time validation, stale/duplicate IDs, cancellation rollback, and one-command undo/replay equivalence.
- [ ] **Step 2: Implement stroke session ownership** with `CanvasStrokeBuilder`; normalize coordinates at the bridge boundary, clamp only according to existing builder rules, reject non-finite values, and feed bounded batches through the existing preview queue.
- [ ] **Step 3: Add failing layer/history/export tests** for capability rejection, layer ordering, undo/redo, PNG destination validation, and failed export preservation.
- [ ] **Step 4: Implement layer/history/export adapters** by calling existing model methods; do not write document commands directly from the MCP controller.
- [ ] **Step 5: Add real-Metal AI integration coverage** that selects a non-default brush, draws a 16+ point stroke, commits it, compares fresh replay checksum, and exports an image through the normal coordinator.
- [ ] **Step 6: Run focused MCP/model/renderer tests plus `make test`**; verify no AI stroke changes current mouse/tablet behavior.
- [ ] **Step 7: Commit** with `feat: expose MCP watercolor drawing tools` and push `origin/main`.

### Task 6: Documentation, packaging, and release qualification

**Files:**
- Modify: `README.md`
- Modify: `Makefile`
- Modify: `scripts/package_app.sh`
- Modify: `scripts/qualify_release.sh`
- Create: `docs/superpowers/mcp-usage.md`
- Test: `Tests/Packaging/*` and MCP protocol tests

- [ ] **Step 1: Add failing packaging tests** for the MCP executable, endpoint descriptor cleanup, no stdout logging, and no leftover socket/process after qualification.
- [ ] **Step 2: Package both `Watercolor Studio.app` and the standalone `WatercolorStudioMCP` executable** without changing existing app bundle identifiers or document registration.
- [ ] **Step 3: Document local MCP host configuration, AI Control opt-in, tool schemas, safety limits, Stop behavior, and the fact that signing/notarization remain separate distribution concerns.
- [ ] **Step 4: Run `make test`, `make build`, packaging tests, Metal validation, release packaging, and MCP stdio smoke tests**; explicitly check `pgrep -x WatercolorStudio` and the endpoint descriptor/socket are absent after each run.
- [ ] **Step 5: Commit** with `docs: document local MCP integration` and push `origin/main`.

### Task 7: Final compatibility review

**Files:**
- Review all changed files and existing customer-path files; no broad refactor.

- [ ] **Step 1: Run the complete test/build/Metal/package gates from a clean tree.**
- [ ] **Step 2: Exercise the existing human path manually only if needed: launch, create canvas, select brush options, draw, undo, save, reopen, export, and stop the app. Do not leave the app running.
- [ ] **Step 3: Verify AI Control is off by default, no MCP socket exists when off, and current accessibility tree/tool shortcuts are unchanged.**
- [ ] **Step 4: Review `git diff --check`, untracked files, endpoint cleanup, process cleanup, and remote commit history.
- [ ] **Step 5: Commit any final documentation-only corrections and push `origin/main`.

## Plan Self-Review

- Spec coverage: architecture, opt-in UX, capability token, local socket, semantic tools, existing model reuse, bounded strokes, safe errors, cancellation, testing, packaging, and non-goals are covered by Tasks 1–7.
- Compatibility: current UI and model paths are modified only through additive controls and narrow adapters; existing suites remain mandatory at every integration boundary.
- Placeholder scan: no TBD/TODO or unassigned implementation step appears in the plan.
- Type consistency: protocol values are defined in Task 1; the executable consumes them in Task 2; the app bridge/controller owns Task 3; read and mutation tools build on those exact request/response types in Tasks 4–5.
