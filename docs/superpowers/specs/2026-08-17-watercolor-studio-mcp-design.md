# Watercolor Studio Local MCP Design

## Status

Design approved in conversation; implementation has not started.

## Goal

Allow a local AI agent to create watercolor artwork through Watercolor Studio's existing painting model. The AI must be able to choose tools and their options, manage layers, draw semantic strokes, inspect state, and export results. Existing mouse, tablet, keyboard, accessibility, document, undo/redo, renderer safety, and save workflows must not change when AI Control is off.

## Architecture

Use two processes:

1. `WatercolorStudioMCP` is a standalone SwiftPM executable that speaks MCP JSON-RPC over stdin/stdout. It contains no renderer or document logic.
2. Watercolor Studio owns a private Unix-domain socket bridge. The bridge is created only while the app is running and AI Control is enabled. It uses a randomly named socket under the user's temporary directory, filesystem permissions restricted to the current user, and a per-session capability token exchanged during initialization.

The MCP process sends versioned bridge requests. The app validates the token, dispatches requests on the main actor, and returns structured results. No TCP listener, browser endpoint, cloud service, or raw Metal access is added.

## User experience and safety

- AI Control is off by default and is opt-in from a visible app control.
- The app shows an active-session indicator and a Stop button while a client is connected.
- Stop immediately rejects new mutations and cancels an in-flight AI stroke through the existing cancellation path.
- Human mouse/tablet input remains available unless the existing renderer/model state says painting is unavailable. AI activity never silently steals focus or changes the current tool for a human user.
- AI mutations use the current document and selected layer unless the request explicitly selects another valid layer.
- Every committed AI stroke is one normal undoable stroke command. Failed or cancelled requests publish no partial document mutation.
- Existing notices, alerts, recovery banners, save prompts, accessibility announcements, and performance/resource limits remain the source of truth. MCP receives stable error codes and customer-safe messages; internal paths, UUIDs, and raw GPU diagnostics are not exposed in ordinary tool results.

## MCP tools, first version

Read tools:

- `canvas_state`: canvas dimensions, paper, selected layer/tool, capabilities, busy/recovery state, and safe capacity summary.
- `brush_catalog`: available tools, shapes, hairs, textures, styles, and valid ranges/steps.
- `layer_list`: ordered layer metadata and visibility/opacity.
- `canvas_snapshot`: an image snapshot or documented unavailable result; no raw Metal texture access.

Mutation tools:

- `set_brush`: atomically update any supported brush identity, color, paint, and dynamics attributes with validation.
- `select_tool` and `select_layer`.
- `create_layer`, `duplicate_layer`, `delete_layer`, `move_layer`, `merge_layer`, `clear_layer`, and `set_layer_properties`, using existing model capabilities.
- `stroke_begin`, `stroke_append`, `stroke_end`, and `stroke_cancel`. Points use normalized or canvas coordinates, pressure, tilt, and optional timestamps. The bridge owns a request ID and rejects stale, duplicate, out-of-order, or oversized batches.
- `undo`, `redo`, and `dry_layer` where the existing model permits them.
- `export_png` through the existing durable export coordinator and save semantics.

All schemas are explicit, versioned, finite-number validated, and bounded. The first version does not expose arbitrary file writes, shell commands, network requests, pixel writes, shader inputs, or direct document JSON mutation.

## State and concurrency

The app bridge is an adapter over `StudioModel`; it does not create a second editing model. Requests are serialized per session and use the model's existing main-actor admission checks. A stroke session has one owner, one request ID, and one terminal state. Disconnect, Stop, timeout, validation failure, renderer failure, or app shutdown cancels the session and clears uncommitted points without changing the saved project.

The bridge must never block the main actor on MCP I/O. Reads are snapshots. Long AI drawings append bounded point batches through the same preview queue used by pointer input, preserving replay equivalence and the existing work/resource budgets.

## Compatibility contracts

Before enabling AI Control, all current UI behavior must remain unchanged. Existing tests for document launch/save, brush controls, accessibility, paper changes, deferred strokes, renderer recovery, resource/work limits, replay, export, and long-scribble performance remain mandatory gates. New MCP tests must prove that disabling AI leaves no socket, no background task, no changed shortcut behavior, and no document mutation.

## Verification

- Unit tests for JSON-RPC framing, schema validation, bounded numbers, stable errors, capability-token handshake, and request ordering.
- Bridge tests for permissions, disconnect, Stop, timeout, stale IDs, cancellation, and app shutdown.
- Model integration tests for every mutation tool, one-stroke undo/replay equivalence, failed-operation rollback, and human-input compatibility.
- A real-Metal AI stroke test that chooses a non-default brush, draws a multi-batch stroke, commits it, reopens/replays it, and exports a PNG.
- Existing full test suite, release build, Metal validation, packaging, and process-cleanup gates must pass. The MCP executable must be tested separately over stdio with no app process left after tests.

## Explicit non-goals for version one

- Remote MCP access or network exposure.
- Autonomous file discovery or opening arbitrary customer documents.
- Raw pixel, texture, shader, or filesystem control.
- Background AI generation inside the app; the MCP client remains responsible for deciding what to draw.
- Any change to the current default canvas, brush UI, save flow, or accessibility presentation.
