# Security Analysis: Watercolor Studio on `main`

## Scope

This static review covered all 43 requested files on branch `main`: every file under `Sources/`, `Tests/`, `scripts/`, and `docs/`; `Resources/Info.plist`; `Package.swift`; `Makefile`; `README.md`; and `CLAUDE.md`.

`Package.swift` is the only dependency manifest. It declares Apple platform frameworks and local targets, with no third-party packages. The repository has no `Package.resolved` or other dependency lock file.

The review traced `.watercolor` input through decoding, validation, replay, Metal allocation, and GPU dispatch. It also traced PNG export, document registration, and release-bundle packaging. This was a source review; no production or test files were changed, and no dynamic denial-of-service payload was executed.

## Summary

Two small, valid `.watercolor` documents can exhaust customer resources: one requests 3.875 GiB of base Metal textures, while another drives about 137.4 billion full-canvas GPU thread invocations during open. The local bundle is intentionally unsigned, which becomes a code-integrity vulnerability if that bundle is distributed to customers.

| Severity | Count |
|----------|-------|
| Critical | 0     |
| High     | 2     |
| Medium   | 1     |

Full analysis written to: /Users/tomfisher/watercolor_painter_app/docs/security-analysis.md

## Findings

### A01: Broken Access Control

> **A01 — Broken Access Control:** No proven vulnerability found. Checked the document app entry points, drag-and-drop layer identifiers, file-type registration, and export UI. The app has no accounts, remote endpoints, authorization roles, or cross-user data store.

### A02: Cryptographic Failures

> **A02 — Cryptographic Failures:** No proven vulnerability found. Checked source, tests, scripts, plist, manifest, and documentation for credentials, tokens, private keys, personal data fields, and sensitive values in errors. None were present.

### A03: Injection

> **A03 — Injection:** No proven vulnerability found. Checked all filesystem writes, JSON decoding, shell commands, shader compilation inputs, and displayed document strings. The app has no SQL, template engine, network request builder, or user-controlled process execution. The packaging shell script derives quoted paths from its own location.

### A04: Insecure Design

**SEC-001: A tiny valid document can allocate 3.875 GiB of base Metal textures**

- **OWASP:** A04 — Insecure Design
- **Location:** `Sources/WatercolorCore/ProjectModel.swift:369`, `Sources/WatercolorEngine/WatercolorRenderer.swift:64`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1575`, `Sources/WatercolorStudio/PaintingDocument.swift:30`
- **Evidence:** Document validation accepts a 4,096 × 4,096 canvas with 12 layers. The renderer then allocates two 8-byte-per-pixel pigment arrays, two 2-byte-per-pixel wetness arrays, and two 4-byte-per-pixel composite textures at that layer capacity. The renderer's own formula is:

  ```swift
  let pixelCount = width * height
  let pingPongLayerBytesPerPixel = 2 * 8 + 2 * 2
  let compositeBytesPerPixel = 2 * 4
  return pixelCount * (layerCapacity * pingPongLayerBytesPerPixel + compositeBytesPerPixel)
  ```

  At the accepted maximum, this is `4096 × 4096 × (12 × 20 + 8) = 4,160,749,568` bytes, or 3.875 GiB. `Tests/WatercolorEngineTests/WatercolorRendererTests.swift:99` confirms that exact estimate. No per-device working-set budget is checked before `makeTextures` creates the arrays.
- **EXPLOIT:** An attacker creates a schema-version-2 `.watercolor` file containing a 4,096 × 4,096 canvas, 12 valid layers, and no commands. The file is only a few kilobytes. The customer opens it. `PaintingDocument` accepts the project, and `StudioModel` constructs `WatercolorRenderer`. The renderer creates and clears 3.875 GiB of base textures. On a memory-constrained Apple Silicon Mac, the app fails to open, stalls under memory pressure, or is terminated. The attacker gains reliable local resource exhaustion from a small document; no malformed field is required.
- **Severity:** High
- **Preconditions and likelihood:** The customer must open an attacker-supplied `.watercolor` file. The app registers itself as the owner of that file type, so double-click delivery is a normal path. Impact depends on available unified memory, but the requested allocation is deterministic.

**SEC-002: One accepted dry command can schedule about 137.4 billion full-canvas GPU thread invocations**

- **OWASP:** A04 — Insecure Design
- **Location:** `Sources/WatercolorCore/ProjectModel.swift:376`, `Sources/WatercolorCore/ProjectModel.swift:504`, `Sources/WatercolorEngine/WatercolorRenderer.swift:556`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1018`, `Sources/WatercolorEngine/WatercolorRenderer.swift:1222`
- **Evidence:** Validation accepts `4_096` dry steps. Replay passes that count to `encodeActiveSimulation`. That function pads an active stroke region by the full step count, which expands a centered region to the entire 4,096 × 4,096 canvas. `encodeSimulation` then runs this loop:

  ```swift
  for _ in 0..<steps {
      encoder.dispatchThreads(
          MTLSize(
              width: region.width,
              height: region.height,
              depth: targetSlice == Self.allLayers ? layerCapacity : 1
          ),
          threadsPerThreadgroup: threadgroupSize(for: simulationPipeline)
      )
      encoder.memoryBarrier(scope: .textures)
      frontTextureIndex = destination
      encodeSynchronize(region: region, targetSlice: targetSlice, with: encoder)
  }
  ```

  Each iteration dispatches both the simulation and synchronization kernels. A one-layer maximum canvas therefore requests `4096 × 4096 × 4096 × 2 = 137,438,953,472` pixel-thread invocations. Replay encodes the work into one command buffer and waits for completion at `Sources/WatercolorEngine/WatercolorRenderer.swift:591` on the main actor.
- **EXPLOIT:** An attacker creates a valid `.watercolor` file with a 4,096 × 4,096 canvas, one valid centered wet stroke, and one dry-layer command with `steps: 4096`. The customer opens the small file. The stroke leaves an active simulation region. The dry command expands it to the full canvas and encodes 4,096 simulation passes plus 4,096 synchronization passes. The main actor blocks while Metal completes the command buffer, freezing the document window and placing extreme load on the GPU. The attacker gains local application denial of service and may trigger a GPU reset or process termination.
- **Severity:** High
- **Preconditions and likelihood:** The customer must open an attacker-supplied document. The payload uses accepted values and only two commands, so schema validation does not reduce the workload.

### A05: Security Misconfiguration

> **A05 — Security Misconfiguration:** No additional proven vulnerability found. Checked production/debug conditionals, localized errors, plist declarations, Metal failure handling, and package defaults. Debug-only renderer inspection remains behind `#if DEBUG`; user-visible failures do not expose file contents, secrets, or stack traces. The unsigned distribution issue is reported under A08.

### A06: Vulnerable and Outdated Components

> **A06 — Vulnerable and Outdated Components:** No proven vulnerability found. `Package.swift` declares no external package dependencies, and there is no resolved dependency graph requiring a CVE match. Apple frameworks come from the target macOS installation rather than repository-pinned third-party versions.

### A07: Identification and Authentication Failures

> **A07 — Identification and Authentication Failures:** No proven vulnerability found. The application has no login, session, token, password, identity provider, or security-sensitive comparison path.

### A08: Software and Data Integrity Failures

**SEC-003: The release bundle has no verifiable code identity if it is distributed to customers**

- **OWASP:** A08 — Software and Data Integrity Failures
- **Location:** `scripts/package_app.sh:9`, `README.md:49`, `README.md:57`
- **Evidence:** The release script builds and copies the executable, plist, and icon but never invokes `codesign`, notarization tooling, or a packaging step that preserves a trusted signature:

  ```bash
  swift build -c release --product WatercolorStudio
  rm -rf "${application_bundle}"
  mkdir -p "${contents_directory}/MacOS" "${contents_directory}/Resources"
  cp ".build/release/WatercolorStudio" "${contents_directory}/MacOS/WatercolorStudio"
  cp "Resources/Info.plist" "${contents_directory}/Info.plist"
  cp "Resources/WatercolorStudio.icns" "${contents_directory}/Resources/WatercolorStudio.icns"
  ```

  The README states that the bundle is intentionally unsigned and tells users to bypass the unsigned-app warning with Finder or Privacy & Security. No entitlements or signing configuration exists in the reviewed tree.
- **EXPLOIT:** This path requires the local-development bundle to be sent to customers through a channel where an attacker can replace or alter it. The attacker swaps the executable inside `Watercolor Studio.app`. The customer follows the documented warning-bypass flow because the expected artifact is unsigned. macOS has no developer signature or notarization ticket to distinguish the modified executable from the intended one, and the attacker's code runs with the user's app permissions.
- **Severity:** Medium
- **Preconditions and likelihood:** The finding applies only if the current `make app` output is distributed outside a trusted local checkout. The README correctly says this package is not prepared for distribution, so local developer use alone does not satisfy the exploit precondition.

### A09: Security Logging and Monitoring Failures

> **A09 — Security Logging and Monitoring Failures:** No proven vulnerability found. Checked error publication, document-open failures, GPU failures, and export failures. This offline desktop app has no authentication or authorization events to monitor, and its errors do not contain secrets or personal data. Resource telemetry would improve supportability but does not create a separate exploit path beyond SEC-001 and SEC-002.

### A10: Server-Side Request Forgery

> **A10 — Server-Side Request Forgery:** No proven vulnerability found. The reviewed app contains no networking client, URL session, remote-content loader, redirect handler, or server-side request path. File URLs selected by `NSSavePanel` are used only as local PNG destinations.

### Attack-Angle Protocol 1: Input-to-Sink Tracing

SEC-001 and SEC-002 cover the exploitable `.watercolor` path: `FileWrapper.regularFileContents` flows through `JSONDecoder`, project validation, replay planning, Metal texture allocation, and GPU dispatch. The document's numeric values are validated individually, but their combined memory and compute cost is not bounded.

The PNG path flows from a user-selected `NSSavePanel` URL to ImageIO and an atomic `Data.write`. Document data cannot select the destination, change the output type, or reach a shell command. No additional proven input-to-sink vulnerability was found.

### Attack-Angle Protocol 2: Authentication and Authorization Decisions

> **Authentication and authorization audit:** No proven vulnerability found. The app has no identity boundary, privileged role, remote service, shared database, or protected endpoint. Local document and export access are mediated by normal macOS open/save UI.

### Attack-Angle Protocol 3: Secrets and Personal Data Search

> **Secrets and personal data search:** No proven vulnerability found. Searched the complete scope for password, secret, API-key, token, credential, Social Security number, payment-card, private-key, bearer-token, authorization-header, and related patterns. Matches were ordinary words such as test signaling and renderer snapshots, not sensitive values.

### Attack-Angle Protocol 4: Dependency Vulnerability Check

> **Dependency vulnerability check:** No proven vulnerability found. `Package.swift` has no third-party dependencies, and no lock file exists. There is no repository-pinned dependency version to match against a CVE or security advisory.

## Verified Strengths

- Project validation rejects non-finite coordinates and brush values, out-of-range colors, duplicate identifiers, oversized nested arrays, unsupported schemas, excess layers, excess commands, and dry counts above the declared limit.
- The renderer repeats safety validation at its public rendering boundary before converting document numbers into integer GPU regions.
- Metal shaders check texture coordinates and array slices before reads and writes. The reviewed code did not expose a document-controlled out-of-bounds GPU access.
- PNG export uses ImageIO and an atomic write to a destination chosen by the macOS save panel. It does not use document-controlled paths or shell commands.
- The project has no third-party package supply chain, credentials, personal data collection, network client, or remote attack surface.
- The README clearly labels the generated app as unsigned and unsuitable for notarized or App Store distribution. This makes SEC-003's deployment precondition visible instead of silently presenting the bundle as production-ready.

## Security Improvement Summary

### What Was Found

SEC-001 and SEC-002 allow small, schema-valid documents to consume extreme Metal memory or GPU work during open. SEC-003 means the current local bundle cannot prove its identity if someone distributes it to customers.

### How to Improve

1. **SEC-001:** Replace independent dimension and layer limits with a checked, device-aware byte budget before any Metal allocation. Reject documents whose total base textures, preview snapshots, readback buffers, candidate renderer overlap, and checkpoint overlap exceed that budget.
2. **SEC-002:** Bound total replay work, not only the value on one command. Cap the product of canvas area, affected layers, stroke points, and simulation steps. Split accepted replay across bounded command buffers with cancellation and progress reporting.
3. **SEC-003:** Keep `make app` explicitly local-only. Add a separate distribution pipeline that uses Developer ID signing, hardened runtime settings, notarization, stapling, and signature verification before publication.

### How to Prevent This Going Forward

1. Add hostile-document tests with tiny payloads at the maximum combined memory and replay-work boundaries. Assert rejection before renderer construction or Metal command encoding.
2. Treat every persisted work count as one term in a total cost equation. Test the largest valid combination, not only one-above-the-limit rejection.
3. Measure peak unified-memory use and replay time on the lowest-memory supported Mac before raising format limits.
4. Prevent release automation from publishing an unsigned or unnotarized bundle, while preserving the documented local-development package path.
