# Safarium

**Native macOS Apple Silicon HTML, 3D, Raster, and Media Rendering Engine — with an OS-agnostic Core ready for Windows.**

[![License](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

Safarium renders HTML/CSS/SVG/WebGL animations, composites video/audio DAG graphs, encodes still & animated media, and exposes an in-process 2D raster C ABI (`SafariumRaster`) using **strictly system frameworks** — with **0% FFmpeg / ffprobe / libav**, **0% Chrome / Chromium / Playwright**, and **0% OpenCV** in production binaries.

---

## Core Architecture & Design Invariants

| Invariant | Implementation |
|---|---|
| **macOS Apple Silicon First** | `WKWebView` (windowless `NSApplication .prohibited`, zero desktop focus steal) + `Metal` + `VideoToolbox` + `AudioToolbox` + `Accelerate` (`BLAS`/`LAPACK`/`vDSP`/`vImage`) + `Vision`/ANE + `APFS` `clonefile(2)` |
| **Zero Forbidden Dependencies** | **0% FFmpeg / ffprobe / libav**, **0% Chrome / Chromium**, **0% OpenCV** linked or bundled. Verified by `otool -L` against `/System/Library/*` and `/usr/lib/*` only |
| **Peak RAM First (`SF-VIDEO-1`)** | Single-slot account FIFO queue (`bin/safarium` & `bin/safarium-render`), bounded frame rings (`<= 4` buffers), `CIContext(.cacheIntermediates: false)`, and single-worker default |
| **Exact Quality & Determinism** | `VirtualClock` (`clock.js`) deterministic JS time virtualization, `SSIM >= 0.97`, `PSNR >= 30 dB`, `ΔE00 p95 <= 2.0`, Thai diacritic preservation (`1×` sharp overlay shield & `tx3g` subtitles) |
| **Windows-Ready Core Split** | OS-agnostic IR (`safarium-forge/graph-v1`, `safarium-prism/scene-v1`), pure container bitstreams, ring IPC, and `SafariumPlatformBackend` (`AppleMacOSBackend` today; `Edge WebView2 + DirectX 12 + Media Foundation` roadmap) |

---

## Components

- **`SafariumCore`** (`Sources/SafariumCore/`): Windowless `WKWebView` engine, `VirtualClock` (`clock.js`), Mode C static-hold probe, `AVAssetWriterSink` (H.264, HEVC, HEVC-with-alpha, ProRes 422/4444), `SequentialVideoReader`, `LosslessSoundtrackMux`, `OfflinePeakLimiter`, `SafariumTX3G`, and `SafariumPlatformBackend` (`PlatformBackend.swift`).
- **`SafariumContainers`** (`Sources/SafariumContainers/`): Pure-Swift bitstream muxers/demuxers & decoders (EBML/MKV/WebM, MPEG-TS with 33-bit PTS unwrapping, MPEG-2 Program Stream, Ogg/Vorbis I + FLAC, WebP RIFF/VP8L).
- **`SafariumForgeCore` + `safarium-forge`** (`Sources/SafariumForgeCore/`, `Sources/safarium-forge/`): Declarative JSON DAG media engine, Metal filter shaders, `ForgeSharedRingEncoder` (`AF_UNIX` + `SCM_RIGHTS` unlinked `mmap`), `ForgeIncrementalCache` (APFS CoW `clonefile(2)`), `APFSAutoStage`, `SafariumPQ` (MS-SSIM, CIEDE2000, Vision Thai OCR), `ForgeBatchDOM`, `ForgeSequenceIngest`, and AI JSON control plane (`--progress jsonl`, `--json-errors`, `E_*` taxonomy).
- **`SafariumPrism`** (`Sources/SafariumPrism/`, `Tools/prism-blender-worker.py`): Hybrid 3D engine uniting Blender (`BLENDER_EEVEE`/`CYCLES` over warm SHM) + WebKit WebGL2/Three.js + `1×` crisp HTML/Thai HUD overlay, MetalFX/LLSR upscaling with `SafariumPQ` fallback, and HID/thermal Anti-Lag Governor.
- **`SafariumRaster` + `SafariumRasterC`** (`Sources/SafariumRaster/`, `Sources/SafariumRasterC/`): Dynamic C ABI library (`libSafariumRaster.dylib`, `sr_*`) powered by `Accelerate`, `CoreGraphics`, `ImageIO`, `AVFoundation`, `Metal`, and custom C99/NEON still codecs (PNG/deflate, JPEG YCbCr/DCT/Huffman, WebP VP8/VP8L with strict 14-bit `<= 16383` & `<= 2^27 px` pre-alloc policy, TIFF, GIF).
- **`safarium-cdp` & `bin/safarium-hf`** (`Sources/safarium-cdp/`): Chrome DevTools Protocol pipe shim driving `WKWebView` for Puppeteer and HyperFrames without Chrome.
- **Unified CLI & SDKs** (`bin/safarium`, `bin/safarium-render`, `sdk/`):
  - Unified `safarium` entrypoint alongside 100% backward-compatible `safarium-render`.
  - Zero-dependency SDKs: Python (`sdk/python/safarium_forge.py`), Node ESM (`sdk/node/safarium-forge.mjs`), POSIX Shell (`sdk/shell/safarium-forge.sh`).
  - Drop-in Python shims backed by `libSafariumRaster.dylib`: `sdk/python/safarium_cv2` (`import cv2`) and `sdk/python/safarium_sci` (`scipy` / `tifffile`).

---

## Quick Start (macOS 14+ / Xcode 16+)

> Always pass `--scratch-path` on an APFS volume (e.g., `/tmp/safarium-build`) when building outside local internal disks.

```sh
# 1. Build Release binaries & libSafariumRaster.dylib
xcrun swift build -c release --jobs 2 --scratch-path /tmp/safarium-build \
  --product safarium-html --product safarium-media --product safarium-forge \
  --product safarium-cdp --product SafariumRaster

# 2. Build standalone media comparator
xcrun swiftc -parse-as-library -O Tools/safarium-verify.swift -o /tmp/safarium-build/safarium-verify

# 3. Install into ~/.local (verifies Apple-only otool -L & SHA-256 manifest)
RELEASE="$(xcrun swift build -c release --scratch-path /tmp/safarium-build --show-bin-path)"
python3 Tools/install-render.py --release "$RELEASE" --verifier /tmp/safarium-build/safarium-verify
python3 Tools/install-render.py --check

# 4. Inspect environment & capabilities
"$HOME/.local/bin/safarium" doctor --json
"$HOME/.local/bin/safarium" capabilities
"$HOME/.local/bin/safarium" raster info
```

### Example Commands

```sh
# Deterministic windowless HTML -> MP4 render
safarium html scene.html --output out.mp4 --width 1080 --height 1920 --fps 30 --frames 90 --video-only

# Verify decoded video/audio/tx3g essence & timing (zero FFmpeg)
safarium verify reference.mp4 out.mp4

# Run declarative media/WebKit DAG recipe with JSONL telemetry
safarium forge run --recipe graph.json --progress jsonl --json-errors

# Use SafariumRaster Python cv2 shim (set SAFARIUM_RASTER_LIB if not installed in ~/.local)
PYTHONPATH=sdk/python/safarium_cv2 SAFARIUM_RASTER_LIB="$RELEASE/libSafariumRaster.dylib" \
  python3 -c 'import cv2; print(cv2.__version__)'
```

---

## Verification & 2-Tier Cloud CI

- **Tier 1 (Blocking Cloud macOS CI on `macos-15` & `macos-26`):**
  Static hygiene audit (`0` personal paths/secrets/`._*`), dual-SDK debug+release build (`#if compiler(>=6.2)` guards), `otool -L` Apple-only linkage verification, C99 ASan/UBSan kernel tests, headless XCTest suite (`--no-parallel`), queue/installer tests, and `SafariumRaster` `ctypes`/policy checks.
- **Tier 2 (Capability Probe & Telemetry):**
  Collects `safarium doctor --json`, `capabilities`, and `raster info` artifacts under Apple `Virtualization.framework` limits (where physical ANE/Metal GPU may be absent or paravirtualized).

---

## Cross-Platform Roadmap (Windows)

Safarium's OS-agnostic Core (`ForgeRecipe` IR, `PrismSceneIR`, `VirtualClock` JS, container bitstreams, ring IPC, AI JSON control plane, and C99 codecs) isolates OS primitives behind `SafariumPlatformBackend`. Planned Windows adapter (`WindowsBackend`):

- **Web Frame Renderer:** Microsoft Edge `WebView2` Evergreen (`ICoreWebView2CompositionController`) + `Windows.Graphics.Capture`
- **GPU Compositor & Filters:** Direct3D 12 (`ID3D12Device`) + HLSL Compute + Direct2D
- **Hardware Video / Audio:** Media Foundation (`IMFSinkWriter` + `IMFDXGIDeviceManager` -> NVENC/QSV/AMF) / D3D12 Video Encode & WASAPI/C99 DSP
- **CoW Cache & IPC:** ReFS (`FSCTL_DUPLICATE_EXTENTS_TO_FILE`) + Named Pipes + Win32 Job Objects

See [Cross-Platform Core & Windows Blueprint](docs/research-2026-11-24/cross-platform-core-windows-blueprint.md) and [Free Cloud macOS Runners](docs/research-2026-11-24/free-cloud-macos-runners.md).

---

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) for full text.
