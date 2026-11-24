---
tags: [safarium, wave5, design-spec, ring-encode, warm-daemon, apfs-cache, ab-gallery]
note_type: spec
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# Safarium Wave 5 Design Spec — Slot-Scoped Warm Daemon, Zero-Copy `mmap` Ring, APFS Shot Cache, Safari A/B Gallery & 5 Real-Project Migrations

> **Design Basis:** Pick's locked Wave 5 choices (`2026-11-23 14:14–15:01`): defer `cua-go` Safari; follow **Approach A** (build Wave 5 Apple Silicon core innovations → run Scratch A/B benchmarks & Safari Visual Diff Gallery → migrate passing projects with `safarium` default + `*_BACKEND=legacy` fallback + `.pre-webkit` backups).
> **Strict Constraints:** `0%` FFmpeg/ffprobe/libav*, `0%` Chrome/Chromium/Playwright in Safarium paths, `otool -L` `non_apple=[]` on all 4 installed binaries, strict `SF-VIDEO-1` compliance (single foreground FIFO slot via `~/.local/bin/safarium-render`).

---

## 1. Core Wave 5 Innovations (Apple Silicon & macOS Exclusive)

1. **`ForgeSharedRingEncoder` (`Sources/SafariumForgeCore/ForgeSharedRingEncoder.swift`):**
   - Cross-process zero-copy `mmap` ring encoder listening on atomic `0700` UDS `/tmp/sfr-<hex>/r.sock` (`0600` socket, `getpeereid` UID enforcement).
   - **Dual transport modes:**
     - *Mode A (`SCM_RIGHTS`):* Python (`socket.sendmsg`) / Swift passes unlinked APFS `mmap` FD once during `RING_START <json>`.
     - *Mode B (`ring_open_path`):* Zero-dep Node.js ESM (`fs.writeSync`) opens a private `0700`/`0600` APFS backing file validated with `fstat`/`lstat` (`S_IFREG`, `st_uid == getuid()`, mode `0600`, `st_size >= totalBytes`) preventing `SIGBUS`.
   - **Zero-copy acceleration:** `vImage` / Accelerate SIMD conversion (`rgb24 | bgr24 | rgba | bgra`) with optional **`--vflip`** (contiguous reverse-row scan for OpenGL/WebGL2 `gl.readPixels` frames), `2..8` slots, consistent straight-vs-premultiplied alpha handling for `prores4444` & `hevc-alpha`, single-pass **dual-output tee** (`ProRes 4444 + H.264`), `--audio <wav>` + `--subtitles <srt>`, `flushPool()` every 60 frames, and `APFSAutoStage` ExFAT-safe atomic publish.

2. **`ForgeShotCache` (`Sources/SafariumForgeCore/ForgeShotCache.swift`):**
   - Content-addressed shot/clip cache on internal APFS (`~/Library/Caches/com.safarium.forge-shot-cache`, `0700`, verified `supportsClonefile && supportsRenameExcl`).
   - Every directory scan skips AppleDouble `._*` sidecars created on external ExFAT volume.
   - **`store`:** computes deterministic SHA-256 over namespace + params + input file fingerprints and stores via APFS `clonefile` (or bounded 1 MiB `streamCopy` from ExFAT).
   - **`lookup`:** on hit, preserves the cached artifact and materializes the destination via **`Darwin.clonefile(cached, siblingTemp, 0)` + `SafeFilePublisher.publish`** on same-device APFS (`0 B` extra storage, instant CoW) or `APFSAutoStage.streamCopy` + `SafeFilePublisher.publish` on external ExFAT volume. Supports `stats` & LRU `prune --max-bytes`.

3. **`ForgeWarmDaemon` (`Sources/SafariumForgeCore/ForgeWarmDaemon.swift` — Model 1 Slot-Scoped Warm Session):**
   - Strictly `SF-VIDEO-1`-compliant: runs INSIDE `safarium-render forge daemon --socket <path> [--idle-timeout 20]` holding the single FIFO slot only for an active batch.
   - Pre-warms Metal (`SafariumMetalContext.shared`), `SafariumPQEngine` compiled Metal shaders, `ForgeShotCache`, and reusable encoders/bridges (`~10–30 ms` warm dispatch latency per JSON-line RPC: `ping`, `capabilities`, `inspect`, `pq`, `sheet`, `cache_lookup`, `cache_store`, `ring_start`/`S`/`ring_finish`, `shutdown`).
   - Uses `poll(2)` on the listening socket so after `idleTimeoutSeconds` (`20s` default) or client disconnect/EOF it exits cleanly, releasing the FIFO slot and returning RAM to `0 MB`.

4. **`ForgeABGallery` (`Sources/SafariumForgeCore/ForgeABGallery.swift`):**
   - Generates offline Safari-viewable visual diff galleries (`gallery.html` + `assets/*.jpg` + `summary.json`) from a JSON manifest of baseline vs Safarium candidate clips.
   - Computes real `SafariumPQ` (`score`, `msSSIM`, `deltaE00P95`, `aneSimilarity`, `thaiOCROK`) and renders interactive split-slider comparisons, RAM/speed/disk delta cards, and pass/fail badges with strict HTML and `</script>` escaping (zero inline full-clip base64).

5. **`PrismWebKit3D` Loopback HTTP + Audio Enabler (`Sources/SafariumPrism/`):**
   - Adds `--allow-loopback-http` and `--audio <wav>` to `prism render-web` (and `--allow-loopback-http` to `prism preview-stills`).
   - Installs a `WKContentRuleList` blocking all external `^https?://` traffic EXCEPT `^https?://(127\.0\.0\.1|localhost)(:|/)`, enabling local Three.js ES modules (`Why Stickman?`) and local React/SVG/WebGL2 bundles (`GEOSong`) to render cleanly inside Windowless `WKWebView` with zero Chrome.

---

## 2. Five Real-Project Targets & Quality / Test Preservation Contract

| # | Project | Primary Legacy Cost Replaced | Default Migration (`*_BACKEND=legacy` keeps old path) | Preserved Tests / Backup Rule |
|---:|---|---|---|---|
| 1 | `Why Stickman?` | Headless Chrome + `toDataURL`/HTTP Base64 + `ffmpeg` pipe & MP3 decode | `engine/render.mjs` → `safarium-render forge prism render-web --allow-loopback-http` / `ForgeRingSession` + `safarium-media mux`; `sampler.py`/`music_lib.py` → `safarium-render extract-audio` (`WHY_*_BACKEND=legacy`) | `node --test engine/test/*.test.mjs` + `pytest engine/audio/`; `*.pre-webkit` backups |
| 2 | `เอาตัวรอดกับแสงมณี` | `tools_shared/render_new.py` `ffmpeg` concat/x264/mux + `InsertReader` + `music_pick.py` + `finish_ep.sh` | `ForgeRingSession` (`rgb24`) + `InsertReader` (`safarium-media` / AVFoundation) + `LosslessSoundtrackMux`; `vdsp_audio.py`; `safarium-forge inspect`/`qa` (`RENDER_BACKEND=legacy`, preserve `ffmpeg_cmd()`) | `pytest tools_shared/tests` (`211+` tests, `test_compat_frames_and_argv_unchanged` intact); keep `render_new.py.pre-webkit` & `ep01–ep30` untouched |
| 3 | `Buildology` | `render_animatic.py` `ffmpeg` VideoToolbox/loudnorm/QA sheet + `analyze_reference.py` + cold Blender PNGs | `safarium-forge` (`ring-encode` w/ 0.25s white fade + `audio process` + `sheet` + `inspect`/`qa`) + `tools/prism_render.py` (`--samples 8`, `BUILDOLOGY_BACKEND=legacy`) | `.venv/bin/pytest` (all 5 test files); `ep01-flooded-basement` & `mcp_config.json` untouched; `*.pre-webkit` backups |
| 4 | `Cut Something` | `cutlib/encode.py` `ffmpeg` x264 & 6×4 contact sheet + `clip_check.sh` + fixed `5000ms` pause | `safarium-forge` (`ring-encode`/`pipe-encode`, `sheet`, `inspect`/`qa`) + opt-in `CUT_ANTI_LAG=1` (`CUT_BACKEND=legacy`, explicit `CUT_PAUSE_MS` respected) | `bash .claude/verify.sh` (`47` tests in Blender 5.2.2); **backups of `cutlib/*` stored in `blender/.pre-webkit-backups/` outside `cutlib/`!** |
| 5 | `GEOSong` | `geosong.py`/`render.sh` 8–10 Chrome tabs + Remotion FFmpeg + `check.py`/`sheet.py`/`beats.py` FFmpeg | Standalone Safarium HTML entry (`Baloo 2` vendored locally + 7-API shim) + single-worker WebKit `render-web --allow-loopback-http --audio` + `safarium-forge`/`media` checks (`GEOSONG_BACKEND=legacy`) | `pytest` (`226+` tests) + `tsc --noEmit` + `check.py` flag-fill pass; `out/final.mp4` untouched; `*.pre-webkit` backups |

