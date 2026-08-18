# Watercolor Studio

Watercolor Studio is a native macOS watercolor-painting application built with SwiftUI and Metal.

## Prerequisites and quick start

- macOS 14 or later
- Apple Swift 6.0 or later (Apple Swift 6.3.3 is the tested reference)
- Xcode Command Line Tools, including the Metal toolchain

Run the app from a checkout:

```sh
make run
```

The other development commands are:

```sh
make test    # run the Swift test suite
make build   # build the debug executable
make app     # build the unsigned, local-only release .app bundle
make distribution # build a signed and notarized customer .app bundle
make qualify # run the complete local customer-release qualification lane
```

## Studio tools and shortcuts

The **Tools** menu selects Brush (`B`), Eraser (`E`), Water (`W`), Smudge (`S`), Smear (`M`), and Dry (`D`). Use `[` and `]` to decrease or increase brush size. Bare tool shortcuts are disabled while a text field is focused.

The **Canvas** menu provides Fit Canvas (`⌘0`), Dry Selected Layer (`⇧⌘D`), and Export PNG (`⇧⌘E`). Standard editing uses Undo (`⌘Z`) and Redo (`⇧⌘Z`).

## Project documents and replay

Painting documents use the `.watercolor` extension and the `com.watercolorstudio.painting` type. They are JSON documents containing a validated project schema: canvas dimensions, paper texture, layers, and ordered painting commands. The Metal renderer reconstructs the painting by replaying those recorded commands, which keeps saved artwork editable.

## PNG export

Choose **Canvas → Export PNG…**, select a destination in the save panel, and the current rendered canvas is written as a PNG image. Export creates a snapshot of the canvas; it does not change the `.watercolor` project.

## Local AI control (MCP)

Watercolor Studio includes a local MCP bridge for AI-assisted painting. As soon
as a canvas is open, the app publishes a short-lived, owner-only endpoint under
`~/Library/Application Support/WatercolorStudio/mcp-endpoint.json`; it is
removed when **AI Control** is turned off or the canvas closes. No network
listener is opened.

The standalone stdio MCP executable is built as `WatercolorStudioMCP` and is also included in packaged builds at `Contents/Helpers/WatercolorStudioMCP`. Point an MCP host at that executable (or run `swift run WatercolorStudioMCP` from a checkout). It discovers the active app endpoint and forwards MCP `tools/list` and `tools/call` requests through the private Unix socket.

Available local tools include canvas and brush catalogs, layer inspection and management, semantic watercolor strokes (`stroke_begin`, `stroke_append`, `stroke_end`, `stroke_cancel`), drying, undo/redo, and PNG export. The toolbar keeps an **AI Control** switch and **Stop AI** action so the customer can end a local session at any time. Requests are bounded by the same renderer, project, history, and validation limits as normal drawing.

## Architecture

| Module | Responsibility |
| --- | --- |
| `WatercolorCore` | Project model, editing commands, presets, stroke sampling, and JSON document codecs. |
| `WatercolorEngine` | Metal-backed replay and rendering. |
| `WatercolorStudio` | SwiftUI document app, AppKit save panel, Metal canvas, and studio controls. |
| `WatercolorMCP` / `WatercolorStudioMCP` | Local MCP protocol, stdio host, and authenticated Unix-socket transport. |

Source targets live in `Sources/WatercolorCore`, `Sources/WatercolorEngine`, and `Sources/WatercolorStudio`; matching tests live under `Tests/`.

## Tests and release packaging

Run `make test` before shipping a change. `make app` performs a release build and creates an unsigned, local-only bundle:

```text
.build/release/Watercolor Studio.app
```

For local development use, launch it with:

```sh
open '.build/release/Watercolor Studio.app'
```

On launch, Watercolor Studio opens the in-app **New Watercolor** screen. It
does not open an Open panel or create/save an untitled painting. Choose a
preset or canvas size, then select **Create Watercolor Canvas** to begin an
in-memory draft. Saving is deferred until you explicitly select **Save
Painting** in the editor. Use **File → Open** when you explicitly want to load an existing
`.watercolor` painting.

macOS may present its normal unsigned-app warning; use Finder’s Control-click **Open** flow or System Settings → Privacy & Security to allow this local build. Never distribute the `make app` output to customers: it does not include signing or notarization.

### Signed customer distribution

`make distribution` is the fail-closed customer packaging path. It requires an installed Developer ID Application signing identity and a notarytool keychain profile. Supply both explicitly:

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Company (TEAMID)'
export NOTARYTOOL_PROFILE='watercolor-studio-notary'
make distribution
```

Create the named keychain profile beforehand with `xcrun notarytool store-credentials`. The distribution command signs with the hardened runtime and a trusted timestamp, runs `codesign --verify --deep --strict`, archives the app, runs `xcrun notarytool submit --wait`, staples and checks the ticket with `xcrun stapler validate`, verifies the stapled signature again, and runs `spctl --assess --type execute`.

Only after every gate succeeds does it publish:

```text
.build/distribution/Watercolor Studio.app
```

Missing credentials or any signing, notarization, stapling, or Gatekeeper failure exits nonzero and does not publish an incomplete replacement.

### Release qualification

Run `make qualify` on the release Mac before distributing a build. It performs a clean correctness run with SwiftPM process-level test parallelism disabled, requires a real Metal device, enables Metal API and shader validation in a separate renderer lane, records 30-sample p50/p95 performance measurements, packages and validates the local app and icon, runs the packaged release executable's customer-input benchmark under a hard timeout, performs an exact-process five-second liveness check, terminates every exact test process with bounded cleanup, and checks the Git diff. A terminal PASS or FAIL report is published atomically even when an early gate fails. Results and machine-readable `WATERCOLOR_QUALIFICATION` lines are written to:

```text
.build/qualification/report.txt
```

The debug Metal lane requires batched preview p95 at or below 16.7 ms, pointer-up commit p95 at or below 33.3 ms, and main-actor heartbeat gaps at or below 100 ms. The packaged release lane independently delivers eight mouse events per stroke at 120 Hz through the real coalescing path; it requires input-handler p95 at or below 8.33 ms, scheduling lateness p95 at or below 16.7 ms, final-event backlog p95 at or below 25 ms, and commit p95 at or below 33.3 ms. Both lanes cover 1600×1200 canvases with 1, 8, and 12 layers and report 30 measured samples per layer count.

Signing and notarization are reported as `NOT_RUN` unless both `DEVELOPER_ID_APPLICATION` and `NOTARYTOOL_PROFILE` are supplied. The qualification report never treats missing signing credentials as a pass.

The reference development platform is macOS 14 or later on Apple Silicon. The release bundle is built for the architecture of the Mac that runs `make app`.
