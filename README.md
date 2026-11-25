<div align="center">

# Safarium

**100% Native macOS Apple Silicon HTML, 3D, 2D Raster, and Media Rendering Engine — Built for Multi-AI Agents (`MCP`).**

[![macOS Cloud CI](https://github.com/sanookai/Safarium/actions/workflows/ci-macos.yml/badge.svg)](https://github.com/sanookai/Safarium/actions/workflows/ci-macos.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![Platform: macOS 14+ Apple Silicon Only](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon%20Only-000000?logo=apple&logoColor=white)](#quick-start)
[![Swift 6](https://img.shields.io/badge/Swift-6.1%20%7C%206.3-F05138?logo=swift&logoColor=white)](#verified-cloud-ci)
[![Zero External Binaries](https://img.shields.io/badge/FFmpeg%20%7C%20Chrome%20%7C%20OpenCV-0%25-2ea44f)](#why-safarium)
[![MCP Server](https://img.shields.io/badge/MCP-safarium--mcp%20(12%20tools)-0969da)](#multi-ai-agent-integration-mcp)
[![C ABI Symbols](https://img.shields.io/badge/SafariumRaster%20ABI-371%20symbols%20%7C%209%2C884%20parity%20tests-6f42c1)](#3-image-processing-2d-raster--still-codecs)

<p>
  <a href="#why-safarium">Why Safarium?</a> •
  <a href="#multi-ai-agent-integration-mcp">AI & MCP</a> •
  <a href="#at-a-glance-comparison">Comparisons</a> •
  <a href="#real-benchmarks-apple-m5">Benchmarks</a> •
  <a href="#honest-trade-offs--when-not-to-use-safarium">Honest Trade-Offs</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#documentation--research">Docs</a>
</p>

</div>

---

## Why Safarium?

Modern programmatic video, image, and AI-media pipelines typically glue together **Headless Chrome + FFmpeg + OpenCV + Blender**. On a Mac, that stack regularly burns **1.5–4+ GiB of RAM per job**, copies uncompressed frames across processes and disk, ships hundreds of megabytes of third-party binaries, and steals desktop focus or throttles your system.

**Safarium** goes **100% all-in on macOS & Apple Silicon** (no cross-platform compromises), replacing that entire toolchain with one unified native engine built strictly on **pre-installed macOS system frameworks** (`WKWebView`, `Metal`, `VideoToolbox`, `AudioToolbox`, `Accelerate`, `Vision`/ANE, and `APFS`):

- **0% FFmpeg / ffprobe / libav**, **0% Chrome / Chromium / Playwright**, and **0% OpenCV** in production binaries (verified by `otool -L` against `/System/Library/*` and `/usr/lib/*` only).
- **81%–94% lower Peak RAM** than Chrome-based HTML video renderers and **3×–4× faster** end-to-end delivery.
- **Windowless & zero focus steal** (`NSApplication .prohibited`) with deterministic JavaScript time (`VirtualClock`).
- **Multi-AI ready out of the box:** ships a zero-dependency **Model Context Protocol (`safarium-mcp`)** server + JSON/JSONL CLI (`--progress jsonl`, `--json-errors`, `E_*`) so **Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI**, and custom agents can drive renders safely through one serialized FIFO queue (`SF-VIDEO-1`).
- **One unified stack** covering HTML/CSS/SVG/WebGL2 video, Metal filter DAGs, hardware encoding, pure-Swift containers, a `371`-symbol `import cv2`-compatible 2D raster engine, and hybrid 3D (Blender + WebGL2 + crisp HTML HUD).
- **Strict quality gates & transparent engineering**: every claim below is backed by reproducible Apple Silicon benchmarks and a [2025–2026 Global Video Encoding Encyclopedia](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md) — including **exact areas where competitors still win**.

---

## Multi-AI Agent Integration (`MCP`)

Safarium ships a zero-dependency **Model Context Protocol (MCP)** stdio JSON-RPC 2.0 server (`bin/safarium-mcp` / `safarium mcp`) supporting MCP `2025-06-18`, `2025-03-26`, and `2024-11-05` with **12 tools** (8 fast read-only tools that bypass the render queue + 4 FIFO-queued heavy render/QA tools with live `notifications/progress` streaming), **5 documentation/status resources**, and **3 prompt templates**.

Works seamlessly with **Claude Code**, **Claude Desktop**, **Cursor**, **Gemini CLI**, **Codex CLI**, and any MCP-compatible AI client:

```sh
# Claude Code (one-line registration)
claude mcp add --transport stdio safarium -- "$HOME/.local/bin/safarium-mcp"
```

```json
{
  "mcpServers": {
    "safarium": {
      "command": "/path/to/.local/bin/safarium-mcp",
      "args": []
    }
  }
}
```

> Full client snippets (Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI), tool schemas, and safety rules: **[docs/mcp-server.md](docs/mcp-server.md)** and **[docs/ai-control-protocol.md](docs/ai-control-protocol.md)**.

---

## At-a-Glance Comparison

How Safarium compares across the entire video, web-to-video, computer-vision, and 3D rendering ecosystem:

| Tool / Stack | HTML / WebGL to Video | Video / Audio Pipeline | 2D Raster / CV (`cv2`) | 3D Hybrid + HUD | AI / MCP Ready | External Binaries Needed | Typical Peak RAM (1080p) | Best For |
|---|:---:|:---:|:---:|:---:|:---:|---|---:|---|
| **Safarium** *(macOS Apple Silicon Only)* | ✅ Native `WKWebView` | ✅ `Metal` + `VideoToolbox` | ✅ `371` C-ABI ops + GPU | ✅ `Prism` (WebGL2 + Warm Blender) | ✅ Native `safarium-mcp` + JSONL | **None** (`0%` FFmpeg / Chrome / OpenCV) | **100–302 MiB** | Fast, low-RAM all-in-one HTML/3D/Media/CV/AI pipelines on Apple Silicon |
| **FFmpeg (`libav*`)** | ❌ None | ✅ Universal gold standard | 🟡 Basic filters only | ❌ None | ❌ CLI only | `ffmpeg` + codec libs (GPL/LGPL) | 307–1,438 MiB | Maximum codec breadth (AV1, VP9, MP3, legacy formats) & archival encodes |
| **Remotion** | ✅ React + Chromium | 🟡 Calls FFmpeg | ❌ None | 🟡 Via Three.js in Chrome | 🟡 Separate ecosystem | Chromium + Node + FFmpeg | 1,605–1,975+ MiB | React component teams prioritizing cloud Linux farm scaling |
| **HyperFrames** | ✅ HTML/GSAP + Chrome | 🟡 Calls FFmpeg | ❌ None | 🟡 Via WebGL in Chrome | 🟡 CLI | `chrome-headless-shell` + FFmpeg | 994–1,762 MiB | AI-generated HTML/GSAP timelines *(runs **without Chrome** via `safarium-hf`)* |
| **Playwright / Puppeteer** | 🟡 Screenshots/CDP | ❌ Needs FFmpeg | ❌ None | ❌ None | 🟡 External MCP | Chromium + Node/Python | 350–1,800 MiB | Interactive web scraping & E2E browser testing (not built for fast video) |
| **Motion Canvas / Revideo** | ✅ TS Canvas 2D | 🟡 Calls FFmpeg | ❌ None | ❌ None | ❌ | Browser/Chromium + FFmpeg | 400–900 MiB | Procedural TypeScript vector/diagram animations |
| **OpenCV (`cv2`)** | ❌ None | 🟡 Bundles FFmpeg | ✅ Industry standard | ❌ None | ❌ | `opencv` wheel (~100 MB, bundles FFmpeg) | 20–250 MiB | Heavy multi-core CPU computer vision & legacy ecosystem compatibility |
| **`libvips` / `sharp`** | ❌ None | ❌ Stills only | ✅ Streaming image ops | ❌ None | ❌ | `libvips` + codec libs | 20–90 MiB | High-throughput server-side still image thumbnails & resizing |
| **Cold Blender CLI** | ❌ None | 🟡 Basic VSE | ❌ None | ✅ Cinema PBR / Cycles | ❌ | Blender (+ FFmpeg/Chrome for HUD) | 1,721–4,000+ MiB | Offline path-traced 3D cinema renders |

> **Legend:** ✅ First-class built-in · 🟡 Partial or delegates to external tools · ❌ Not supported

---

## Detailed Comparisons by Category

### 1. HTML & Web-to-Video Renderers

*Safarium vs. Remotion, HyperFrames (Chrome), Playwright/Puppeteer, Motion Canvas/Revideo, Manim, Skia/Vello/Rive*

| Competitor | How It Works | Where Safarium Wins | Where the Competitor Wins |
|---|---|---|---|
| **Remotion** | Multi-tab Headless Chromium + React + PNG pipe to FFmpeg | **93–94% less Peak RAM** (`116–128 MiB` vs `1,605–1,975 MiB`), **1.7×–1.8× faster** than 4-worker Remotion using only 1 slot, zero Chrome/FFmpeg install, zero focus steal | Cross-platform (Linux cloud Lambda/Docker farms), large React template ecosystem |
| **HyperFrames (Chrome)** | Puppeteer + `chrome-headless-shell` + FFmpeg | **81–88% less Peak RAM** (`116–128 MiB` vs `994–1,762 MiB`), **3.35×–3.87× faster**; `safarium-cdp` even runs HyperFrames directly over `--remote-debugging-pipe` with **zero Chrome** (`SSIM 0.99685`) | Exact Chromium Blink pixel output on Linux servers |
| **Playwright / Puppeteer** | Base64 PNG screenshots over CDP WebSocket | Eliminates Base64/PNG roundtrips via native `WKWebView` + zero-copy `SCM_RIGHTS` mmap ring (`130 MiB` vs `1,558 MiB`) and deterministic `VirtualClock` | General web automation, clicking, form login, and cross-browser QA |
| **Motion Canvas / Revideo** | TypeScript Canvas 2D + headless Chromium + FFmpeg | Supports full **HTML5/CSS Grid/Flexbox/SVG/WebGL2 + native Thai shaping**, plus `7.31×` faster native video decode (`SequentialVideoReader`) without browser frame stalls | Interactive live Vite timeline editor for pure procedural TypeScript vector scenes |
| **Manim (Community / GL)** | Python + Cairo CPU (or deprecated OpenGL) + FFmpeg | No deprecated macOS OpenGL or slow Cairo CPU bottlenecks; GPU-accelerated Metal/WebGL2 + direct `VideoToolbox` encode | Rich LaTeX math animation library & huge Python educator community |
| **Skia / Vello / Rive** | Native/WASM/GPU 2D vector renderers | Full W3C HTML/CSS/SVG/WebGL2 + audio mastering + `tx3g` subtitles + MP4/ProRes delivery out of the box with `0 B` third-party runtime | Ultra-low-level embedded UI/game vector rendering or interactive `.riv` state machines |

---

### 2. Worldwide Video Encoders, Pipelines & Muxers (2025–2026)

*Safarium vs. Software Encoders (`x264`/`x265`/`SVT-AV1`/`libaom`/`VVenC`/`AV2`), Cloud CAE (`Netflix`/`Beamr`/`Bitmovin`/`Ateme`), Hardware/ASICs (`Blackwell NVENC`/`Arc QSV`/`NETINT`/`Alveo`), Cinema/Mezzanine (`ProRes`/`APV`/`DNx`/`JPEG XS`/`FFV1`), and Neural AI Codecs (`DCVC-UF`/`MLVC`/`Cool-Chic`). Full breakdown in **[Global Video Encoding Encyclopedia (2025–2026)](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md)**.*

| Competitor Family | Representative Tech (2025–2026) | Where Safarium Wins | Where the Competitor Wins |
|---|---|---|---|
| **FFmpeg (`libav*`) & GStreamer** | `filter_complex`, `libswscale`, `gst-launch-1.0` | **2.75×–2.90× faster** Metal DAG (`4.08s` vs `11.20–11.82s`), **67%–89% lower host RAM** (`100 MiB` vs `307–933 MiB`), zero GPL/LGPL binary bundling, streaming `O(4096)` audio DSP, native HTML/3D/ANE in one pass | Universal format/codec support (**AV1, VP9, MP3, legacy broadcast**) and live RTSP/SRT/WebRTC streaming servers |
| **Software Encoders (AVC / HEVC / AV1 / Next-Gen)** | `x264`, `x265 4.3`, `SVT-AV1 4.3` / `-HDR`, `libaom 3.15`, `VVenC 1.14`, **AOMedia `AV2` (`avm 1.0`)**, `LCEVC`, `AVS3` | **2×–12×+ faster** and **3×–10× lower Peak RAM** (`72–143 MiB` vs `356–12,000 MiB`) via Apple Silicon Media Engine ASIC (`VideoToolbox`), zero GPL/patent hassle, universal playback today | **Wins on equal-SSIM compression density (BD-Rate):** `x265` (−20–35%), `SVT-AV1` (−35–55%), `VVenC`/`AV2` (−50–65%+, with AV2 >40% over AV1 on screen content) |
| **Cloud Perceptual CAE** | Netflix Dynamic Optimizer, Beamr CABR, Bitmovin V3, MediaKind EyeQ, Ateme TITAN | **Zero cloud egress/per-minute encoding bills**, total local privacy, zero-copy local `WKWebView`/Metal capture-to-encode + native `safarium-mcp` | Multi-pass cloud convex hulls & closed-loop perceptual BQM/VMAF cutting CDN bitrates 30–50% *(key inspiration for Safarium's planned native macOS Mini-CAE)* |
| **Discrete GPUs & Datacenter ASICs** | NVIDIA Blackwell 9th-Gen NVENC (AV1 UHQ), Intel Arc Xe2 QSV, AMD VCN 5, NETINT Quadra, AMD Alveo MA35D, Google Argos, Meta MSVP | Integrated silent **Apple Silicon UMA** (zero PCIe copies, native **ProRes ASIC**, `HEVCWithAlpha`, `MV-HEVC`, WebKit + Metal on one chip) | **Hardware AV1 encoding** (Apple Silicon M1–M5 decodes AV1/VVC in HW but has no HW AV1 encoder yet) and 32–64-stream datacenter transcode density |
| **Cinema / Mezzanine / Lossless / VJ** | Apple ProRes, **IETF APV (RFC 9924)**, Avid DNx, JPEG XS, HTJ2K, **FFV1 (Vulkan)**, OpenEXR 3.5, HAP / NotchLC | Native hardware **ProRes 422/4444** + pure-Swift containers (`MP4/MOV/MKV/WebM/TS/MPEG-2 PS/Ogg/tx3g`) at `9.9 MiB` RAM + `APFSAutoStage` | Royalty-free cross-platform mezzanine (**APV** on Android 16/Resolve), sub-frame IP broadcast (**JPEG XS**), mathematical archival (**Vulkan FFV1**), and live VJ textures (**HAP/NotchLC**) |
| **Neural / AI Video Codecs** | Microsoft `DCVC-RT` / `DCVC-UF` / `MLVC` (CoreML ANE), Orange `Cool-Chic v5`, Diffusion/DiT | Standard hardware-decoded MP4/MOV playability everywhere + exact pixel/text fidelity (`1× Thai Shield`) | Research-grade extreme bitrate reduction (−42% vs VVC for `DCVC-UF`; non-standard bitstreams, generative artifacts on text) |

---

### 3. Image Processing, 2D Raster & Still Codecs

*`SafariumRaster` (`libSafariumRaster.dylib`, ABI v1 — **371 C-ABI symbols**, **9,884 parity tests passed, 0 failed**) vs. OpenCV 5.1.0, `libvips`/`sharp`, ImageMagick, `cwebp`/`oxipng`/`mozjpeg`/`avifenc`/`cjxl`*

| Competitor | How It Works | Where Safarium Wins | Where the Competitor Wins |
|---|---|---|---|
| **OpenCV (`cv2` 5.1.0)** | C++ whole-matrix computer vision library (Python wheel bundles FFmpeg) | **0% FFmpeg/OpenCV bloat**, drop-in `import cv2` Python shim covering Core, Linear Algebra (`Accelerate`), ImgProc Filters, Geometry/Contours/Hough/LSD/Subdiv2D, VideoIO, Photo/Inpaint/NLM/HDR/Bayer; **bit-exact C/NEON JPEG decode** (`ΔE00 = 0.0`, `SSIM = 1.0`, `0.907×` faster), **PNG `2.30×` faster & smaller**, **4K Metal GPU `8/9` speed wins (`1.4×–6.3×`)** | Multi-core CPU SIMD throughput on general `ops` (single-threaded `cv2` benchmark currently `47/97` WIN+TIE provisionally under load), plus decades of niche CV/calib3d/ML modules |
| **`libvips` / `sharp`** | Streaming multi-threaded C tile engine (Node N-API addon) | Zero native npm C++ addon rebuilds across Node ABI bumps, plus adds **Metal GPU**, **ANE person matting/reframe**, and **full video timelines** (`libvips`/`sharp` are stills-only) | Ultra-low-RAM multi-core server thumbnailing of gigantic (`10,000×10,000+`) still images on Linux |
| **ImageMagick** | Eager full-canvas rasterizer with 200+ format delegates | **4×–8× faster** contact sheets & transforms without 200 MB delegate trees or `/tmp` pixel-cache RAM explosions (`127 MiB` streaming contact sheets, zero re-decode inline sheets) | Niche legacy print/vector formats (EPS, PSD, CMYK PDF, 200+ formats) |
| **`cwebp` / `oxipng` / `mozjpeg` / `avifenc` / `cjxl`** | Specialized standalone still-image encoders | Pure-Swift/C99 **PNG & WebP `VP8L`/`VP8`** written from scratch (`WebP VP8L` **`1.43×–2.28×` faster than `cwebp`** with strict 14-bit `<= 16383` guard; solves Apple `ImageIO`'s missing WebP write support) + zero-dep Apple `ImageIO` HEIC/HEICS/AVIF | Deep offline lossy/lossless size density (`avifenc`, `cjxl`, `mozjpeg` trellis, `zopflipng` brute-force) when file size beats speed |

---

### 4. 3D / VFX Hybrid & Incremental Pipelines

*`SafariumPrism` + `ForgeIncrementalCache` vs. Cold Blender CLI + Chrome + FFmpeg, VapourSynth, MLT*

| Competitor | How It Works | Where Safarium Wins | Where the Competitor Wins |
|---|---|---|---|
| **Cold Blender CLI + Chrome + FFmpeg** | Spawns cold `blender -b` to PNGs on disk, then Chrome + FFmpeg to composite HUD | **Tier-0 `webkitGLB` multi-angle previews: `3.12×–4.68×` faster at `25 MiB` vs `1,721 MiB` (`-98.5%` RAM)**; Warm Blender SHM worker eliminates cold startups; **`0 B` intermediate PNG disk churn** (vs `61` PNGs / `24.8 MB`); **`1× Thai Shield`** protects typography from MetalFX distortion; **`HEVCWithAlpha` `42.85×` smaller** than ProRes 4444 | Maximum offline Cycles path-traced render farms on multi-GPU Linux/Windows nodes |
| **VapourSynth / AviSynth+** | Scripted CPU frame server piping raw video to FFmpeg/`x264` | Native Apple Silicon ARM64 (`Metal + Accelerate + ANE`) without fragmented macOS `.dylib` plugins or `vspipe` roundtrips | Deep archival video restoration plugins (`QTGMC`, `BM3D`, `znedi3`) on x86 Linux/Windows |
| **MLT / `melt`** | C NLE timeline engine (Shotcut / Kdenlive) over FFmpeg + OpenGL | Native **Metal TBDR** (`3.87 ms/frame`), no deprecated macOS OpenGL (`Movit`), native `WKWebView` `VirtualClock` HTML overlays, and **APFS `clonefile(2)` Closed-GOP cache (`3.854×` faster, `0/150` diff frames)** | Desktop GUI NLE integrations (Shotcut / Kdenlive project `.mlt` ecosystem) |

---

## Real Benchmarks (Apple M5)

All measurements below were collected on Apple Silicon (macOS, Apple M5) using `proc_pid_rusage` (`ri_phys_footprint` / `libproc` process tree RAM) and verified perceptual/media gates (`SSIM >= 0.97`, `PSNR >= 30 dB`, `ΔE00 p95 <= 2.0`, zero-FFmpeg `safarium verify`). Full datasets live in [docs/research-2026-11-24/experiment-results.md](docs/research-2026-11-24/experiment-results.md).

### HTML-to-Video (`H1`: 1080×1920, 30 fps, 5s)

| Engine | Wall Time | Peak Tree RAM | Speedup vs Chrome HF | RAM Saved | `safarium verify` |
|---|---:|---:|---:|---:|:---:|
| **Safarium (`safarium-html`)** | **2.78–3.31 s** | **116–128 MiB** | **3.35×–3.87× faster** | **-81% to -88%** | ✅ Pass (`0`) |
| HyperFrames (Chrome) | 10.67–11.11 s | 994–1,762 MiB | 1.00× (baseline) | — | ✅ Pass (`0`) |
| Remotion (`concurrency=4`) | 5.11–5.59 s | 1,605–1,975 MiB | 1.99×–2.09× | **+61% more RAM** | ❌ Failed (`1`) |

> *Honest note:* Subpixel anti-aliasing differences between WebKit and Chromium Skia produced `ΔE00 p95 = 2.002–2.288` on raw cross-engine `safarium-html` vs Chrome (`safarium-cdp` passed at `1.464–1.702`). Wave 8 added `ColorCalibrationTests` and colorimetry calibration to tighten alignment.

### Media Filter DAG + Audio Loudnorm (`H2`: 1080×1920, 10s — LUT + Blur + Overlays + BS.1770-4)

| Engine | Wall Time | Host Peak RAM | Combined Tree RAM | Quality (`MS-SSIM` / `ΔE00 p95` / LUFS err) | Output Size (`8M` target) |
|---|---:|---:|---:|---|---:|
| **Safarium (`safarium-forge`)** | **4.08 s** | **100 MiB** | **302 MiB** | `0.9967` / `1.65–1.85` / `0.0002 LU` | 1.77×–2.31× larger *(honest 1-pass VT trade-off)* |
| FFmpeg (`h264_videotoolbox`) | 11.82 s | 307 MiB | 356 MiB | Reference | 1.00× |
| FFmpeg (`libx264`) | 11.20 s | 933 MiB | 933 MiB | Reference | 0.77× |

### Hardware vs. Software Encoders Pareto (`H3`), Incremental Cache (`H5`), & 3D Hybrid (`H6`)

| Experiment | Metric | Safarium Result | Baseline / Rival | Delta |
|---|---|---:|---:|---|
| **`H3` VideoToolbox vs `x264`/`x265`/`SVT-AV1`** | Peak RAM & Encode Speed | **72–143 MiB**, **1.30–1.45 s** | 356–1,367 MiB, 2.5–17.0 s | **14/14 wins** on RAM & Speed (`1.96×–11.75×` faster); **0/8** on BD-Rate *(SW wins equal-SSIM bytes)* |
| **`H4` Still Codecs (`SafariumRaster`)** | JPEG decode / PNG / WebP VP8L | Bit-exact JPEG (`ΔE00 = 0.0`, `SSIM = 1.0`) | OpenCV 5.1.0 & `cwebp` | JPEG **`0.907×`** WIN; PNG **`2.30×`** faster & smaller; WebP VP8L **`1.43×–2.28×`** faster than `cwebp` |
| **`H5` APFS `clonefile` Closed-GOP Cache** | Partial-edit re-render (`150f`) | **2.89 s** (`0/150` diff frames) | 11.13 s full re-render | **`3.854×` faster**, bit-exact packet reuse (`150/150` SHA-256 identical) |
| **`H6` `SafariumPrism` Tier-0 `webkitGLB`** | Multi-angle 3D preview stills | **25 MiB** RAM, **0 B** temp PNGs | Cold Blender **1,721 MiB**, **24.8 MB** PNGs | **`3.12×–4.68×` faster**, **`-98.5%` RAM**, `HEVCWithAlpha` **`42.85×` smaller** than ProRes 4444 |

---

## Honest Trade-Offs — When NOT to Use Safarium

We prefer transparent engineering over hype. You should **not** choose Safarium as your primary tool if:

1. **You need Linux or Windows execution.** Safarium is **100% macOS / Apple Silicon Only** by deliberate architectural choice — maximizing deep hardware integration (`WKWebView`, `Metal`, `VideoToolbox`, `VTFrameProcessor`, `AudioToolbox`, `ANE`, `APFS`) rather than diluting it across cross-platform lowest-common-denominator layers.
2. **You need the smallest possible archival video file size (BD-Rate) or AV1/VP9/MP3 encoding.** Apple's `VideoToolbox` prioritizes real-time speed and low RAM over exhaustive multi-pass RDO. Software `x264`, `x265 4.3`, `SVT-AV1 4.3`, `VVenC 1.14`, and `AV2` beat single-pass `VideoToolbox` on equal-SSIM bitrate efficiency, and Apple Silicon has no hardware encoder for `AV1`, `VP9`, or `MP3`. *(See our [macOS Apple Silicon Encoding Upgrade Roadmap](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md#7-actionable-macos-apple-silicon-upgrade-roadmap-for-safarium-wave-9--0-ffmpeg) for how we plan to close the BD-Rate gap natively via 2-pass `VTMultiPassStorage`, macOS 15–27 `SpatialAdaptiveQP`/`CQF`, and Metal Mini-CAE.)*
3. **You run heavy multi-core CPU OpenCV pipelines.** `SafariumRaster` passes **9,884** reference parity tests and beats OpenCV on Metal 4K GPU (`8/9`) and custom still codecs, but its single-threaded CPU `ops` path currently trails OpenCV 5.1.0 on several kernels (`47/97` = `48.5%` WIN+TIE provisionally under high host load: `numpy 65.2%`, `codec 60.0%`, `draw 58.8%`, `ops 31.0%`).
4. **You need deep offline still compression (`cjxl`, `avifenc`, `mozjpeg`, `zopflipng`).** Safarium optimizes for fast, zero-dependency, universally playable PNG/JPEG/WebP/HEIC/AVIF rather than slow brute-force compression.
5. **You keep full Blender + WebGL2 resident at the exact same instant.** Concurrent hybrid rendering (`H6B`) peaks higher combined RAM (`2,038 MiB` vs `1,721 MiB`) than running a single engine alone unless using Tier-0 `webkitGLB` previews.

---

## Architecture

```mermaid
flowchart LR
    subgraph Inputs["Inputs, SDKs & Multi-AI Entrypoints"]
        I1["HTML / CSS / SVG / GSAP / WebGL2"]
        I2["JSON Media DAG (graph-v1) & Audio"]
        I3["Python import cv2 / Node / Shell"]
        I4["Blender .glb / Warm SHM + HUD"]
        I5["AI Agents (Claude / Gemini / Cursor / Codex via MCP)"]
    end

    subgraph Core["Safarium Unified Engine (macOS Native + FIFO Queue)"]
        C0["safarium-mcp & Unified CLI\\nMCP stdio JSON-RPC 2.0 · SF-VIDEO-1 FIFO"]
        C1["SafariumCore & safarium-cdp\\nVirtualClock · Mode C Static-Hold · tx3g"]
        C2["SafariumForge\\nMetal DAG · APFS CoW Cache · SafariumPQ"]
        C3["SafariumRaster (ABI v1)\\n371 C-ABI Symbols · C99/NEON Codecs"]
        C4["SafariumPrism & SafariumContainers\\nHybrid 3D · 1x Thai Shield · Pure-Swift Mux"]
    end

    subgraph Apple["Apple Silicon Native Hardware (Zero External Binaries)"]
        A1["WKWebView (.prohibited)"]
        A2["Metal & CoreImage (UMA)"]
        A3["VideoToolbox & AudioToolbox"]
        A4["Accelerate (BLAS/vDSP/vImage) & NEON"]
        A5["Vision / Neural Engine (ANE)"]
        A6["APFS clonefile(2) & SCM_RIGHTS mmap"]
    end

    subgraph Outputs["Verified Deliverables"]
        O1["H.264 / HEVC / HEVC+Alpha / ProRes 4444"]
        O2["MP4 / MOV / MKV / WebM / TS / tx3g"]
        O3["PNG / JPEG / WebP (VP8L/VP8) / AVIF / HEIC"]
    end

    I5 --> C0
    I1 & C0 --> C1
    I2 & C0 --> C2
    I3 & C0 --> C3
    I4 --> C4
    C1 & C2 & C3 & C4 --> A1 & A2 & A3 & A4 & A5 & A6
    A1 & A2 & A3 & A4 & A5 & A6 --> O1 & O2 & O3
```

### Core Components

| Module | Location | What It Does |
|---|---|---|
| **`safarium-mcp`** | `bin/safarium-mcp`, `docs/mcp-server.md` | Zero-dependency Python 3 MCP stdio JSON-RPC 2.0 server (`12` tools, `5` resources, `3` prompts, live JSONL progress notifications) connecting any AI agent to Safarium safely |
| **`SafariumCore`** | `Sources/SafariumCore/` | Windowless `WKWebView` engine, `VirtualClock` (`clock.js`), Mode C static-hold probe, `AVAssetWriterSink` (H.264, HEVC, HEVC-with-alpha, ProRes 422/4444), `SequentialVideoReader`, `LosslessSoundtrackMux`, `OfflinePeakLimiter`, `SafariumTX3G`, and Apple Silicon hardware capability probes |
| **`SafariumForgeCore` + `safarium-forge`** | `Sources/SafariumForgeCore/`, `Sources/safarium-forge/` | Declarative JSON DAG media engine, Metal filter shaders, `AF_UNIX` + `SCM_RIGHTS` unlinked `mmap` ring encoder, APFS `clonefile(2)` incremental cache, `APFSAutoStage` (ExFAT-safe), `SafariumPQ` (MS-SSIM, CIEDE2000, Vision OCR), and AI JSONL control plane (`--progress jsonl`, `--json-errors`) |
| **`SafariumPrism`** | `Sources/SafariumPrism/`, `Tools/prism-blender-worker.py` | Hybrid 3D engine uniting Warm Blender SHM (`EEVEE`/`CYCLES`) + WebKit WebGL2/Three.js + `1× Thai Shield` HUD overlay, MetalFX/LLSR upscaling with `SafariumPQ` fallback, and HID/thermal Anti-Lag Governor |
| **`SafariumRaster` + `SafariumRasterC`** | `Sources/SafariumRaster/`, `Sources/SafariumRasterC/` | Dynamic C-ABI library (`libSafariumRaster.dylib`, **`371` symbols**): Core, `Accelerate` Linear Algebra, ImgProc Filters, Geometry/Contours/Hough/LSD/Segmentation/Subdiv2D, VideoIO, Photo/Inpaint/NLM/SeamlessClone/NPR/HDR/Bayer, opt-in Metal GPU, and custom C99/NEON still codecs (PNG, JPEG, WebP VP8/VP8L, TIFF, GIF) |
| **`SafariumContainers`** | `Sources/SafariumContainers/` | Pure-Swift bitstream muxers/demuxers: EBML/MKV/WebM, MPEG-TS (33-bit PTS unwrapping), MPEG-2 PS, Ogg/Vorbis I + FLAC, WebP RIFF/VP8L |
| **`safarium-cdp` & `bin/safarium-hf`** | `Sources/safarium-cdp/`, `bin/safarium-hf` | Chrome DevTools Protocol pipe shim driving `WKWebView` so Puppeteer and HyperFrames run with **zero Chrome** |
| **Unified CLI & Drop-In SDKs** | `bin/safarium`, `bin/safarium-render`, `sdk/` | Single-slot FIFO render queue (`SF-VIDEO-1`), zero-dep Python/Node/Shell SDKs, plus drop-in `sdk/python/safarium_cv2` (`import cv2`) and `sdk/python/safarium_sci` |

---

## Quick Start

**Requirements:** macOS 14+ (Apple Silicon), Xcode 16+ / Swift 6.1+.

> **Tip:** Always pass `--scratch-path` on an APFS volume (e.g., `/tmp/safarium-build`) when building from an external ExFAT disk.

```sh
# 1. Build Release binaries & libSafariumRaster.dylib
xcrun swift build -c release --jobs 2 --scratch-path /tmp/safarium-build \
  --product safarium-html --product safarium-media --product safarium-forge \
  --product safarium-cdp --product SafariumRaster

# 2. Build standalone zero-FFmpeg media verifier
xcrun swiftc -parse-as-library -O Tools/safarium-verify.swift -o /tmp/safarium-build/safarium-verify

# 3. Install into ~/.local (includes safarium, safarium-render, safarium-mcp + Apple-only otool -L check)
RELEASE="$(xcrun swift build -c release --scratch-path /tmp/safarium-build --show-bin-path)"
python3 Tools/install-render.py --release "$RELEASE" --verifier /tmp/safarium-build/safarium-verify
python3 Tools/install-render.py --check

# 4. Verify environment, capabilities, and 371-symbol C ABI
"$HOME/.local/bin/safarium" doctor --json
"$HOME/.local/bin/safarium" capabilities
"$HOME/.local/bin/safarium" raster info
```

### Everyday Examples

```sh
# 1. Deterministic windowless HTML/CSS/SVG/WebGL2 -> MP4
safarium html scene.html --output out.mp4 --width 1080 --height 1920 --fps 30 --frames 90 --video-only

# 2. Run a declarative Metal/Audio/Overlay DAG with AI-friendly JSONL telemetry
safarium forge run --recipe graph.json --progress jsonl --json-errors

# 3. Verify decoded video, audio, and tx3g subtitle timing (zero FFmpeg)
safarium verify reference.mp4 out.mp4

# 4. Run HyperFrames timelines without installing Chrome
safarium-hf render project/ --output out.mp4

# 5. Start the MCP stdio server for Claude / Gemini / Cursor / Codex
safarium mcp

# 6. Drop-in Python cv2 backed by libSafariumRaster.dylib (zero OpenCV / FFmpeg)
PYTHONPATH=sdk/python/safarium_cv2 \
  python3 -c 'import cv2; print(cv2.__version__, hasattr(cv2, "inpaint"), hasattr(cv2, "findContours"))'
```

---

## Verified Cloud CI

Every push is verified by 2-Tier GitHub Actions macOS Cloud CI ([`.github/workflows/ci-macos.yml`](.github/workflows/ci-macos.yml)) across **two macOS & Swift generations** — latest run **4/4 GREEN**:

| Check | `macos-15` (Xcode 16.4 / Swift 6.1.2) | `macos-26` (Xcode 26.6 / Swift 6.3.3) |
|---|---|---|
| **Public Repo Hygiene Audit** (`0` personal paths / secrets / forbidden calls) | ✅ `0` violations | ✅ `0` violations |
| **Apple-Only `otool -L` Linkage** (`0%` FFmpeg / Chrome / OpenCV) | ✅ `6/6` Apple-only | ✅ `6/6` Apple-only |
| **C99 Codec ASan/UBSan + Swift XCTest Suite** | ✅ `234` executed, `0` failed | ✅ `234` executed, `0` failed |
| **Queue, Installer & MCP Server Tests (`test_queue.py` + `test_mcp.py`)** | ✅ `27/27` OK | ✅ `27/27` OK |
| **`SafariumRaster` Reference Parity Suite** | ✅ **`9,884` passed, `0` failed** | ✅ **`9,884` passed, `0` failed** |
| **Cross-OS H.264 Smoke Determinism** | ✅ Identical SHA-256 across both OSes | ✅ Identical SHA-256 across both OSes |

---

## macOS Apple Silicon Encoding Roadmap (Wave 9)

Guided by our [Global Video Encoding Encyclopedia (2025–2026)](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md), upcoming native Apple Silicon upgrades (all **0% FFmpeg**) focus on closing VideoToolbox's BD-Rate gap against `x265`/`SVT-AV1` and unlocking pro mastering capabilities:

- **Modern VideoToolbox Rate-Control (macOS 15–27):** `SpatialAdaptiveQPLevel`, `HighQuality` preset dictionaries, constrained `VariableBitRate` + VBV (macOS 26), perceptual `ConstantQualityFactor` (`CQF`) + `ConsistentQuality` (macOS 27), and default **10-bit HEVC (`Main10`)** even for SDR gradients.
- **Native Two-Pass Hardware Encoding (`VTMultiPassStorage`):** Unlocks 2-pass VideoToolbox offline rate allocation (something FFmpeg's `hevc_videotoolbox` still lacks).
- **"Safarium Mini-CAE" + Multi-Engine Max/Ultra Scaling:** Zero-copy Metal shot-cut detection + `ForceKeyFrame` + per-shot quality steering + parallel `VTCompressionSession` chunking (`MoreFramesBeforeStart`/`MoreFramesAfterEnd`) across 2–4 Media Engines.
- **Pre-Encode `VTFrameProcessor` & Pro Mastering:** Zero-copy Metal temporal denoising (`VTTemporalNoiseFilterConfiguration`), optical-flow retiming, **10-bit HEVC 4:2:2 / 4:4:4**, **Dolby Vision Profile 8.4** (`VTHDRPerFrameMetadataGenerationSession`), **MV-HEVC Spatial Video**, all 6 ProRes tiers, and **Apple Spatial Audio (`APAC`)**.

---

## Documentation & Research

- **[Global Video Encoding Encyclopedia (2025–2026)](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md)** — Complete worldwide comparison (Software, Next-Gen AV2/VVC, Cloud CAE, GPU/ASICs, Cinema/Mezzanine/APV, Neural AI, Audio) + macOS Apple Silicon upgrade roadmap
- **[MCP Server & Multi-AI Integration (`safarium-mcp`)](docs/mcp-server.md)** — Setup for Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI + 12-tool schema
- **[World Video, Web-to-Video, Image & Hardware Ecosystem Matrix (47 Tools)](docs/research-2026-11-24/world-video-ecosystem-matrix.md)** — Deep technical comparison across all 4 ecosystem categories
- **[Empirical Benchmark Results (`H1–H7`)](docs/research-2026-11-24/experiment-results.md)** — Full Apple M5 measurements, methodology, wins, and losses
- **[Cloud CI Results (`macos-15` & `macos-26`)](docs/research-2026-11-24/cloud-ci-results.md)** — Reproducible dual-OS CI verification report
- **[SafariumForge Guide](docs/safarium-forge-guide-2026-11-23.md)** — Declarative JSON DAG recipes, Metal filters, and audio mastering
- **[SafariumRaster Roadmap](docs/raster-roadmap.md)** — `371`-symbol C-ABI architecture & OpenCV parity coverage
- **[AI Control Protocol](docs/ai-control-protocol.md)** — Machine-readable `--progress jsonl`, `--json-errors`, and `E_*` taxonomy
- **[Chrome-less CDP Shim (`safarium-cdp`)](docs/cdp-shim.md)** — Running Puppeteer & HyperFrames on `WKWebView`

---

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) for the full text.
