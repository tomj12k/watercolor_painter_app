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
```

## Studio tools and shortcuts

The **Tools** menu selects Brush (`B`), Eraser (`E`), Water (`W`), Smudge (`S`), Smear (`M`), and Dry (`D`). Use `[` and `]` to decrease or increase brush size. Bare tool shortcuts are disabled while a text field is focused.

The **Canvas** menu provides Fit Canvas (`⌘0`), Dry Selected Layer (`⇧⌘D`), and Export PNG (`⇧⌘E`). Standard editing uses Undo (`⌘Z`) and Redo (`⇧⌘Z`).

## Project documents and replay

Painting documents use the `.watercolor` extension and the `com.watercolorstudio.painting` type. They are JSON documents containing a validated project schema: canvas dimensions, paper texture, layers, and ordered painting commands. The Metal renderer reconstructs the painting by replaying those recorded commands, which keeps saved artwork editable.

## PNG export

Choose **Canvas → Export PNG…**, select a destination in the save panel, and the current rendered canvas is written as a PNG image. Export creates a snapshot of the canvas; it does not change the `.watercolor` project.

## Architecture

| Module | Responsibility |
| --- | --- |
| `WatercolorCore` | Project model, editing commands, presets, stroke sampling, and JSON document codecs. |
| `WatercolorEngine` | Metal-backed replay and rendering. |
| `WatercolorStudio` | SwiftUI document app, AppKit save panel, Metal canvas, and studio controls. |

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

The reference development platform is macOS 14 or later on Apple Silicon. The release bundle is built for the architecture of the Mac that runs `make app`.
