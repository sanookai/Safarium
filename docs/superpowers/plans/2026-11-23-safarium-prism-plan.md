---
tags: [safarium, safarium-prism, plan, tdd, blender, threejs, webkit]
note_type: plan
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# `SafariumPrism` Implementation Plan

> **For agentic workers:** Follow strict TDD (`test -> RED -> implementation -> GREEN -> verify`). ZERO `XCTSkip`, ZERO `TODO`/`TBD`, ZERO `ffmpeg`/`ffprobe`/`Chrome`/`Chromium`/`Playwright`.

**Goal:** Deliver `SafariumPrism` (`Sources/SafariumPrism/`, `Tools/prism-blender-worker.py`, `Tests/SafariumPrismTests/PrismEngineTests.swift`) wired into `safarium-forge` CLI (`prism ...`), `Tools/install-render.py`, `sdk/{python,node,shell}`, and `bench/experiments/2026-11-23-safarium-prism/results.json`.

**Spec:** [`docs/superpowers/specs/2026-11-23-safarium-prism-design.md`](../specs/2026-11-23-safarium-prism-design.md)
**Empirical R&D:** [`research_notes/2026-11-23-safarium-prism/01-blender-threejs-apple-silicon-rd.md`](../../../research_notes/2026-11-23-safarium-prism/01-blender-threejs-apple-silicon-rd.md)

## Tasks

### Task 1: `Package.swift` & `PrismStub.swift` (Coordinator)
- [ ] Add `.library(name: "SafariumPrism", targets: ["SafariumPrism"])`, `.target(name: "SafariumPrism", dependencies: ["SafariumCore", "SafariumContainers", "SafariumForgeCore"])`, `.testTarget(name: "SafariumPrismTests", ...)`, and link `"SafariumPrism"` into `safarium-forge`.
- [ ] Create `Sources/SafariumPrism/PrismStub.swift` (`SafariumPrismModuleInfo.version`) and verify `swift build --target safarium-forge` exits 0.

### Task 2: `SafariumPrism` Core Module + `prism-blender-worker.py` (`prism-core`)
Files (strict ownership):
- `Sources/SafariumPrism/PrismSceneIR.swift`
- `Sources/SafariumPrism/PrismAntiLagGovernor.swift`
- `Tools/prism-blender-worker.py`
- `Sources/SafariumPrism/PrismWarmBlenderBridge.swift`
- `Sources/SafariumPrism/PrismWebKit3D.swift`
- `Sources/SafariumPrism/PrismHybridEngine.swift`
- `Tests/SafariumPrismTests/PrismEngineTests.swift` (ZERO `XCTSkip`!)

TDD Tests required in `PrismEngineTests.swift`:
1. `testCameraAndCoordinateMathRoundTripIncludingPortraitAutoTrap`: Verify Z-up <-> Y-up point & quaternion round-trip (`< 1e-6`), and verify `sensor_fit = .auto` @ `1080x1920` (`36x24`, `35mm`) yields `~54.432°` vertical FOV (not `37.849°`!), round-tripping cleanly to focal length.
2. `testHIDAntiLagGovernorPacingAndThermalDecisions`: Using injectable HID/thermal mocks + live `CGEventSource` capability check, prove active HID (`idle < 1.5s`) triggers adaptive pause & Darwin BG while idle (`>= 1.5s`) yields `0ms` sleep, and live physical footprint telemetry returns `> 0`.
3. `testWebKit3DOfflineGLBPreviewAndInstantStills`: Load a real generated binary `.glb` into `PrismWebKit3D` (`WKWebView` headless `.prohibited`), capture 3 multi-angle `1080x1920` (or `540x960`) stills, assert non-blank pixels & multi-tile contact sheet written via `APFSAutoStage`.
4. `testWarmBlenderBridgeSyncApplyDeltaAndZeroPNGMMAP`: Launch real `/Applications/Blender.app/Contents/MacOS/Blender` 5.2.2 worker (`ping` -> load procedurally created temp `.blend` -> `export_glb_and_ir` -> `render_frame_shm` x 2 with camera delta -> clean `shutdown`), verify distinct non-black SHA-256 BGRA frames over `MAP_SHARED` mmap, 0 PNG files created, and zero stray Blender processes left behind.
5. `testAutoVerifyMetalFXAndForcedFallback`: Confirm smooth 3D `0.67x -> 1x` `MTLFXSpatialScaler` passes `SafariumPQ`, while `1px` grid + `24pt` Thai synthetic pattern triggers `didFallbackTo1x == true` automatically.
6. `testTwoEngineZeroCopyHybridCompositeAndDualTee`: Render transparent Blender sphere frame (`film_transparent=True` via warm bridge `mmap`) + Three.js WebKit 3D background + 1x Thai HUD -> single-pass Metal composite -> playable `.mp4` verified via `PacketProbe` & `SafariumPQ` (`thaiOCROK == true`).

Verify `swift test --filter SafariumPrismTests` -> 6+ tests, 0 failures, **0 skips**.

### Task 3: Wire `prism` into CLI, Installer, Queue, SDKs & Demo 4 (`forge-cli-sdk`)
Files (strict ownership):
- `Sources/safarium-forge/main.swift` (`prism` subcommands: `sync-ir`, `preview-stills`, `render-web`, `render-blender`, `composite`, `capabilities`)
- `Tools/install-render.py` (package & require `libexec/safarium/prism-blender-worker.py` in `payload()` & `if require_media:`)
- `Tests/SafariumForgeTests/CLIIntegrationTests.swift` (add CLI `prism capabilities` + `prism preview-stills` tests, ZERO `XCTSkip`)
- `sdk/{python/safarium_forge.py,node/safarium-forge.mjs,shell/safarium-forge.sh,README.md}` (`prism` helpers)
- `docs/safarium-forge-guide-2026-11-23.md` (add `Safarium Prism` Blender+Three.js guide section)
- `/tmp/safarium-forge-demos/demo4_prism_blender_threejs_hybrid.py`

### Task 4: Unified Release Install, Full Suites & Track A + Track B M5 Benchmarks (`forge-verifier`)
- Release build & install `~/.local` -> `install-render.py --check` -> `otool -L` across all 4 binaries -> `swift test -j 3` (all 5 suites, 0 skips) -> `test_queue.py` (`21/21`) -> `verify-shared-standard.py --swift --rules` -> M5 Benchmarks (`bench/experiments/2026-11-23-safarium-forge/results.json` & `bench/experiments/2026-11-23-safarium-prism/results.json`) -> external ExFAT volume smoke -> SDK E2E -> clean queue & zero focus steal.

