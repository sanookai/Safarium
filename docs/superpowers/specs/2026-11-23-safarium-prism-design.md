---
tags: [safarium, safarium-prism, design-spec, blender, threejs, webkit, metal, zero-copy]
note_type: spec
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# `SafariumPrism` Design Spec — Unified Blender 5.2 + Three.js + System WebKit Engine

> **Design Gate Basis:** Approved by Pick across all 4 `/grill-me` questions (`2026-11-23 01:15–01:19`) and empirically validated by Probes A–F ([`01-blender-threejs-apple-silicon-rd.md`](../../../research_notes/2026-11-23-safarium-prism/01-blender-threejs-apple-silicon-rd.md)).
> **Strict Constraints:** Zero `ffmpeg`, `ffprobe`, `libav*`, `Chrome`, `Chromium`, `Playwright`, or third-party dependencies. Zero edits to external project folders or `cua-go`. Runs serially via `safarium-render forge prism ...` (`SF-VIDEO-1`).

---

## 1. Problem & Novel Engine Solution (`Safarium Prism`)

Pick's 3D workflows span two disconnected worlds that suffer from opposite failure modes:
- **Blender 5.2.2 LTS (`Cut Something`, `Buildology`, `Stickman Fighting`, `Sanook Theme`):** High-fidelity EEVEE/Cycles Metal renders, but slow cold startup (`~1.1–8.3 s/frame`), PNG disk churn (`%05d.png`), fixed `CUT_PAUSE_MS=5000` sleep stalling total runtime even when idle, and `ffmpeg` re-encoding.
- **Three.js (`Why Stickman?`, `lemo-opuscar`, `รอบโลกกับสมหญิง`, `เรื่องเงินเงินทองทอง`):** Fast WebGL2/WebGPU 3D graphics, currently shackled to multi-worker Headless Chromium (`~GiBs` RAM), `toDataURL`/HTTP Base64 frame dumps (`-vf vflip`), and external `ffmpeg`.

**`SafariumPrism`** unifies both inside one macOS-exclusive `IOSurface` + Apple Metal + System WebKit engine (`Sources/SafariumPrism/` + `Tools/prism-blender-worker.py`):

1. **Bidirectional `PrismSceneIR` (`safarium-prism/scene-v1`):**
   - Canonical intermediate representation synchronizing camera extrinsics (`Blender Z-up <-> Three.js Y-up`: $\mathbf{p}_T = (x_B, z_B, -y_B)$, $\mathbf{q}_T = \mathbf{q}_x(-90^\circ)\otimes\mathbf{q}_B$), `sensor_fit` vertical FOV (`AUTO` portrait trap solved cleanly to `2.82e-07` NDC parity and `0.99968` IoU), `shift_x`/`shift_y`, `dof` (`focus_distance`, `fstop`), `storyTime`/`videoTime` + hard-cut barriers (`cuts[]`), cadence/hitstop (`Stickman Fighting`), and projected 2D anchor tracks (`anchors[]` for `Anchored` Thai overlays).
2. **Two-Tier Instant Preview Pyramid (`preview-stills`):**
   - **Tier 0 (`WebKit Instant Proxy`, `~7–8 ms/still`, `~119–183 MiB` combined):** Windowless `WKWebView` (`NSApplication.setActivationPolicy(.prohibited)`) using WebGL2 (Metal) + zero-dependency built-in offline binary `.glb` PBR parser/renderer OR arbitrary local Three.js HTML page + `takeSnapshot` -> Metal GPU contact sheet (`APFSAutoStage`). Renders multi-angle camera previews in milliseconds without waking Blender.
   - **Tier 1 (`Warm Blender Worker`):** Persistent background `/Applications/Blender.app/Contents/MacOS/Blender` (`AF_UNIX` `0700` UDS + `MAP_SHARED` `mmap` buffer) keeping `.blend` loaded in memory (`3.04×` faster EEVEE, `2.42×` faster Cycles), supporting `apply_ir_delta` camera/focal-length updates without reloading `.blend`, and writing zero PNGs (`save_render BMP BGRA` -> APFS `mmap` for bit-exact alpha & Cycles/Compositor support with flat `472 MiB` RSS; opt-in `GPUOffScreen` for `220 ms/f` EEVEE viewport preview).
3. **`MetalFX` + `SafariumPQ` Auto-Verify & Automatic `1.0x` Fallback:**
   - Smooth 3D frames render at `0.67x` and upscale in `~1.5–4 ms` via `MTLFXSpatialScaler`, keeping Thai HUD/typography strictly downstream at `1.0x` (`Split MetalFX` Thai Shield).
   - Periodically samples rendered frames against `1.0x` ground truth with **`SafariumPQ`** (`ANE FeaturePrint` + Metal `MS-SSIM >= 0.97` + `CIEDE2000 p95 <= 2.0` + optional `Vision` Thai OCR). If fine wireframes, aliasing, or Thai diacritics fail the quality gate, `SafariumPrism` **automatically falls back to native `1.0x` rendering** for that sequence/shot with full telemetry in the JSON report.
4. **Unprivileged HID-Aware Anti-Lag Governor (`PrismAntiLagGovernor`):**
   - Queries `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .anyInputEventType)` (`CGPreflightListenEventAccess() == true`), `ProcessInfo.processInfo.thermalState`, `/usr/sbin/taskpolicy -b`, and `task_vm_info` physical footprint.
   - Paces heavy Blender/3D frames by yielding `80–150 ms` + `PRIO_DARWIN_BG` ONLY when Pick actively touched mouse/keyboard (`idleSeconds < pauseWindowSeconds`), running full speed when Pick steps away (eliminating blind `5000 ms` sleeps), and pausing cleanly on `.critical` thermals.
5. **World-First Two-Engine Zero-Copy Composite (`composite`):**
   - Pulls transparent hero RGBA (`film_transparent=True`) from **Warm Blender 5.2** via `mmap` directly into Metal texture, captures matching-camera 3D background/environment from **Windowless `WKWebView` Three.js/GLB** (`IOSurface`/WebGL2) + optional `1x` Thai WebKit HUD (`Mode C`), composites on Apple Metal GPU in a single pass, and encodes directly through **Apple Media Engine** (`H.264` / `HEVC` / `HEVC-Alpha` / dual `ProRes 4444 + H.264` tee) — zero PNGs, zero Chrome, zero FFmpeg.

---

## 2. Architecture & Locked Module Layout

- **`Sources/SafariumPrism/PrismSceneIR.swift`**: `Codable` IR structs (`PrismSceneIR`, `PrismCameraIR`, `PrismTimelineIR`, `PrismCompositeIR`, `PrismQualityPolicy`, `PrismCameraTransform`), deterministic SHA-256 hash, and exact `blenderToThree`/`threeToBlender` math.
- **`Sources/SafariumPrism/PrismAntiLagGovernor.swift`**: HID idle monitor, `PRIO_DARWIN_BG` + `/usr/sbin/taskpolicy -b`, thermal governor, `task_vm_info` RSS/footprint sampler, adaptive sleep controller (injectable clocks/HID provider for fast unit testing).
- **`Tools/prism-blender-worker.py`**: Self-contained Python 3 daemon run inside `/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python-exit-code 1 -P prism-blender-worker.py -- --socket ... --shm ... --idle-timeout ...` handling Blender 5.2.2 LTS (`BLENDER_EEVEE` / `CYCLES` `METAL`, `compositing_node_group`), `.glb` export, `apply_ir_delta`, and `render_frame_shm` (`bmp_mmap` default / `gpu_offscreen` opt-in). Uses strict keyword `access=mmap.ACCESS_WRITE`!
- **`Sources/SafariumPrism/PrismWarmBlenderBridge.swift`**: Swift UDS framing client, worker locator (`libexec/safarium/prism-blender-worker.py` + dev fallback `Tools/prism-blender-worker.py`), guaranteed child cleanup (`deinit`/explicit `shutdown()`).
- **`Sources/SafariumPrism/PrismWebKit3D.swift`**: `@MainActor` `WKWebView` (`NSApplication.shared.setActivationPolicy(.prohibited)`) WebGL2/WebGPU 3D host + embedded zero-dependency offline `.glb` PBR viewer + `takeSnapshot` -> `CVPixelBuffer`/`CGImage` capture + `MetalFX` upscale helper.
- **`Sources/SafariumPrism/PrismHybridEngine.swift`**: High-level entrypoints (`syncFromBlender`, `previewStills`, `renderWeb3D`, `renderBlenderAdaptive`, `compositeHybrid`, `capabilities`) integrating `APFSAutoStage`, `SafariumMetalContext`, `ForgeMetalFilterEngine`, `SafariumPQEngine`, and `AVAssetWriterSink`.

---

## 3. Honest macOS / Physical Boundaries Documented in Outputs & Reports
1. Cycles raytracing and Grease Pencil strokes remain Blender Metal workloads (WebKit GLB tier renders rapid PBR/camera previews, not Cycles path-traced caustics).
2. `GPUOffScreen` in Blender 5.2 is EEVEE-only (skips `compositing_node_group` and returns grey for async Cycles) and shows `+11.4 MiB/f` driver drift — therefore `bmp_mmap` (`APFS` RAM-cached BGRA, `0` compression, flat RSS, works on EEVEE+Cycles+Alpha) is the default, while `gpu_offscreen` is opt-in with periodic recycle.
3. Blender scene asset footprint in RAM depends on the `.blend` file's own meshes/textures; Safarium Prism minimizes host, preview, transport, and encoder memory overhead.

