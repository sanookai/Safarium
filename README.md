<div align="center">

# Safarium

**100% Native macOS Apple Silicon HTML, 3D, 2D Raster, and Media Rendering Engine — Built for Multi-AI Agents (`MCP`).**

[![macOS Cloud CI](https://github.com/sanookai/Safarium/actions/workflows/ci-macos.yml/badge.svg)](https://github.com/sanookai/Safarium/actions/workflows/ci-macos.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![Platform: macOS 14+ Apple Silicon Only](https://img.shields.io/badge/macOS-14%2B%20Apple%20Silicon%20Only-000000?logo=apple&logoColor=white)](#quick-start)
[![Swift 6](https://img.shields.io/badge/Swift-6.1%20%7C%206.3-F05138?logo=swift&logoColor=white)](#verified-cloud-ci)
[![Zero External Binaries](https://img.shields.io/badge/FFmpeg%20%7C%20Chrome%20%7C%20OpenCV-0%25-2ea44f)](#why-safarium)
[![MCP Server](https://img.shields.io/badge/MCP-safarium--mcp%20v2%20(23%20tools)-0969da)](#multi-ai-agent-integration-mcp)
[![Waves 11-14 SPEC](https://img.shields.io/badge/Waves%2011--14-SPEC%20%7C%20Conformance%20%7C%20Chroma%20Fidelity-ff6b00)](#waves-1114--spec-perceptual-controller-chroma-fidelity--5-run-apple-m5-benchmark)
[![C ABI Symbols](https://img.shields.io/badge/SafariumRaster%20ABI-418%20symbols%20%7C%20Phases%201--16%20%2B%20contrib-6f42c1)](#3-image-processing-2d-raster--still-codecs)

<p>
  <a href="#why-safarium">Why Safarium?</a> •
  <a href="#waves-1114--spec-perceptual-controller-chroma-fidelity--5-run-apple-m5-benchmark">SPEC & Conformance</a> •
  <a href="#multi-ai-agent-integration-mcp">AI & MCP v2</a> •
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

**Safarium** goes **100% all-in on macOS & Apple Silicon** (no cross-platform compromises), replacing that entire toolchain with one unified native engine built strictly on **pre-installed macOS system frameworks** (`WKWebView`, `Metal`, `VideoToolbox`, `VTFrameProcessor`, `AudioToolbox`, `CoreImage`, `CoreML`, `Accelerate`, `Vision`/ANE, and `APFS`):

- **0% FFmpeg / ffprobe / libav**, **0% Chrome / Chromium / Playwright**, and **0% OpenCV** in production binaries (verified by `otool -L` against `/System/Library/*` and `/usr/lib/*` only).
- **Waves 11–14 SPEC Perceptual Encoding Controller, Chroma Fidelity & Bitstream Conformance (0% FFmpeg):** adds live Apple Silicon **Runtime Capability Profiling** (`probe-capabilities`), **independent zero-FFmpeg Bitstream & HLS Conformance** in both Swift (`conformance`) and a `#![forbid(unsafe_code)]` zero-dependency **Rust CLI** (`Tools/safarium-conformance-rs`), **Metal Chroma Fidelity** (`NV12 → P010` lossless widen + full BT.709/BT.2020 colorimetry achieving **`ΔE00 p95 = 1.27`** and beating FFmpeg `hevc_videotoolbox` on VMAF, VMAF-NEG, XPSNR, and bitrate simultaneously), **HDR Metadata Integrity** (`preserve`/`recompute`/`strip`/`tone-map`), **SPEC** closed-loop quality-target encoding & Per-Title Convex-Hull HLS ladders (`spec-plan`, `spec-encode`, `spec-ladder`) with text/face/grain-safe `VTTemporalNoiseFilter`, **Hardware Auto-Tuner & Thermal Hysteresis** (`calibrate-hw`), **Zero-4:2:0 ProRes**, and **Atomic Staging Publish**.
- **Wave 10 Every Video Encoding Scenario (0% FFmpeg):** ships **19 one-flag scenario presets** (`--scenario youtube`, `youtube-4k`, `shorts`, `tiktok`, `reels`, `web-streaming`, `web-compat`, `screen-recording`, `cinema-master`, `cinema-vfx`, `transparent-vfx`, `hdr-dolby-vision`, `hdr10`, `spatial-visionos`, `archival`, `live-low-latency`, `podcast-video`, `webp-clip`, `gif-clip`), a **native HLS ABR ladder packager** (`.fmp4` CMAF via `AVAssetWriter` + `.ts` via pure-Swift 188-byte MPEG-TS muxer + WebVTT subtitles + shared-IDR alignment), **hardware HDR→SDR tone-mapping** (`CIToneMapHeadroom` + BT.709), and **direct video → Animated WebP / GIF / APNG** export.
- **Wave 9 Apple Silicon Encoding Supremacy (0% FFmpeg):** unlocks hardware capabilities **FFmpeg `hevc_videotoolbox` cannot even access** — **True 2-Pass `VTMultiPassStorage`** (`MS-SSIM 0.9939` at `3.55 Mbps`, **`6.9×` faster** than 2-pass `libx265` and **+0.020 MS-SSIM** above FFmpeg `hevc_videotoolbox`!), **10-bit HEVC (`4:2:0`/`4:2:2`/`4:4:4`)** with 4×4 Bayer dithering, **SpatialAQ + LookAhead + CQF + VBV**, **"Safarium Mini-CAE"** per-shot adaptive multi-engine chunking, zero-copy **`VTFrameProcessor`** (`VTTemporalNoiseFilter` AFBC hardware denoise, `VTFrameRateConversion` optical-flow retiming, `VTMotionBlur`), **Dolby Vision 8.4 / HDR10 / HLG / Apple Log**, **MV-HEVC Spatial Video**, all **6 ProRes tiers**, and **AudioToolbox Pro Mastering** (`AAC-Max`, `HE-AAC v1/v2`, `ALAC`, `Opus`, `APAC` Spatial Audio, `24/32f PCM`).
- **81%–94% lower Peak RAM** than Chrome-based HTML video renderers and **3×–4× faster** end-to-end delivery.
- **Windowless & zero focus steal** (`NSApplication .prohibited`) with deterministic JavaScript time (`VirtualClock`).
- **Multi-AI ready out of the box (`MCP v2`):** ships a zero-dependency **Model Context Protocol (`safarium-mcp` v2.0.0)** server (**23 tools**, including intent-level `encoding_capabilities`, `encoding_conformance`, `encoding_plan`, `encoding_encode`, and `encoding_ladder`) + JSON/JSONL CLI (`--progress jsonl`, `--json-errors`, `E_*`) so **Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI**, and custom agents can plan, encode, verify conformance, and publish safely through one serialized FIFO queue (`SF-VIDEO-1`).
- **One unified stack** covering HTML/CSS/SVG/WebGL2 video, Metal filter DAGs, hardware encoding, pure-Swift containers, a **`418`-symbol** `import cv2`-compatible 2D raster/CV engine (**Phases 1–16 + popular `contrib`**, including NEON-accelerated BBDT connected components, ORB/FAST/Harris, Lucas-Kanade/Farneback/MOG2, PnP/Homography/StereoBM, Vision QR/Barcode/ArUco, CoreML ANE DNN, Guided Filter/WB/CSRT), and hybrid 3D (Blender + WebGL2 + crisp HTML HUD).
- **Strict quality gates & transparent engineering**: every claim below is backed by reproducible multi-run Apple Silicon benchmarks, a transparent [Capability Matrix](docs/capability-matrix.md), and a [2025–2026 Global Video Encoding Encyclopedia](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md) — including **exact areas where competitors still win**.

---

## Multi-AI Agent Integration (`MCP`)

Safarium ships a zero-dependency **Model Context Protocol (MCP)** stdio JSON-RPC 2.0 server (`bin/safarium-mcp` v2.0.0 / `safarium mcp`) supporting MCP `2025-06-18`, `2025-03-26`, and `2024-11-05` with **23 tools** (13 fast read-only FIFO-bypass tools including `encoding_capabilities`, `encoding_conformance`, `encoding_plan`, `list_scenarios`, and `analyze_shots` + 10 SF-VIDEO-1 FIFO-serialized render/encode/packaging/QA tools including intent-level `encoding_encode`, `encoding_ladder`, `transcode_supremacy`, `package_hls`, `export_animated_clip`, and `audio_encode` with live `notifications/progress` streaming), **5 documentation/status resources**, and **3 prompt templates**.

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

> Full client snippets (Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI), 23-tool schemas, and safety rules: **[docs/mcp-server.md](docs/mcp-server.md)** and **[docs/ai-control-protocol.md](docs/ai-control-protocol.md)**.

---

## At-a-Glance Comparison

How Safarium compares across the entire video, web-to-video, computer-vision, and 3D rendering ecosystem:

| Tool / Stack | HTML / WebGL to Video | Video / Audio / HLS Pipeline | 2D Raster / CV (`cv2`) | 3D Hybrid + HUD | AI / MCP Ready | External Binaries Needed | Typical Peak RAM (1080p) | Best For |
|---|:---:|:---:|:---:|:---:|:---:|---|---:|---|
| **Safarium** *(macOS Apple Silicon Only)* | ✅ Native `WKWebView` | ✅ `Metal` + `VideoToolbox` + SPEC + Native HLS/CMAF | ✅ `418` C-ABI ops (Phases 1–16) + GPU | ✅ `Prism` (WebGL2 + Warm Blender) | ✅ Native `safarium-mcp` v2 (23 tools) | **None** (`0%` FFmpeg / Chrome / OpenCV) | **38–302 MiB** | Fast, low-RAM all-in-one HTML/3D/Media/HLS/CV/AI pipelines on Apple Silicon |
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

*`SafariumRaster` (`libSafariumRaster.dylib`, ABI v1 — **418 C-ABI symbols** covering **Phases 1–16 + popular `contrib`**, **9,911+ parity tests passed, 0 failed**) vs. OpenCV 5.1.0, `libvips`/`sharp`, ImageMagick, `cwebp`/`oxipng`/`mozjpeg`/`avifenc`/`cjxl`*

| Competitor | How It Works | Where Safarium Wins | Where the Competitor Wins |
|---|---|---|---|
| **OpenCV (`cv2` 5.1.0)** | C++ whole-matrix computer vision library (Python wheel bundles FFmpeg) | **0% FFmpeg/OpenCV bloat**, drop-in `import cv2` Python shim covering **Phases 1–16 + `contrib`** (Core, `Accelerate` Linear Algebra, Filters, Geometry/Contours/Hough/LSD/Subdiv2D, VideoIO, Photo/Inpaint/HDR/Bayer, **Features2D `ORB`/`FAST`/`Harris`/`BFMatcher`**, **Video `PyrLK`/`Farneback`/`phaseCorrelate`/`MOG2`/`MeanShift`/`ECC`**, **Calib3D `findHomography`/`Rodrigues`/`solvePnP`/`StereoBM`**, **ObjDetect Vision QR/Barcode + ArUco**, **CoreML ANE `dnn`**, **3D PLY**, **Stitcher/FLANN/CCM**, **`FileStorage`/`ximgproc`/`xphoto`/`TrackerCSRT`**); **19/24 key 1T NEON ops beat/tie OpenCV 5.1.0** (`cc8`: `0.557 ms`, `add`: `0.174 ms`, `merge`: `0.124 ms`, `resize`: `0.050 ms`, `warpAffine`: `1.175 ms`), **bit-exact C/NEON JPEG decode** (`ΔE00 = 0.0`, `SSIM = 1.0`, `0.907×` faster), **PNG `2.30×` faster**, **4K Metal GPU `8/9` wins (`1.4×–6.3×`)** | Multi-core CPU thread-pool scaling on huge batch arrays, plus niche legacy C++ `contrib` modules |
| **`libvips` / `sharp`** | Streaming multi-threaded C tile engine (Node N-API addon) | Zero native npm C++ addon rebuilds across Node ABI bumps, plus adds **Metal GPU**, **ANE person matting/reframe**, and **full video timelines** (`libvips`/`sharp` are stills-only) | Ultra-low-RAM multi-core server thumbnailing of gigantic (`10,000×10,000+`) still images on Linux |
| **ImageMagick** | Eager full-canvas rasterizer with 200+ format delegates | **4×–8× faster** contact sheets & transforms without 200 MB delegate trees or `/tmp` pixel-cache RAM explosions (`127 MiB` streaming contact sheets, zero re-decode inline sheets) | Niche legacy print/vector formats (EPS, PSD, CMYK PDF, 200+ formats) |
| **`cwebp` / `oxipng` / `mozjpeg` / `avifenc` / `cjxl`** | Specialized standalone still-image encoders | Pure-Swift/C99 **PNG & WebP `VP8L`/`VP8`** (including **Animated WebP `RIFF....WEBPVP8X`**) written from scratch (`WebP VP8L` **`1.43×–2.28×` faster than `cwebp`** with strict 14-bit `<= 16383` guard; solves Apple `ImageIO`'s missing WebP write support) + zero-dep Apple `ImageIO` HEIC/HEICS/AVIF/APNG/GIF | Deep offline lossy/lossless size density (`avifenc`, `cjxl`, `mozjpeg` trellis, `zopflipng` brute-force) when file size beats speed |

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

All measurements below were collected on Apple Silicon (macOS, Apple M5) using `proc_pid_rusage` (`ri_phys_footprint` / `libproc` process tree RAM) and verified perceptual/media gates (`SSIM >= 0.97`, `PSNR >= 30 dB`, `ΔE00 p95 <= 2.0`, zero-FFmpeg `safarium verify`, `safarium probe`, and Swift/Rust `conformance`). Full datasets live in [`bench/experiments/2026-11-26-wave11-14-spec/results.json`](bench/experiments/2026-11-26-wave11-14-spec/results.json), [`bench/experiments/2026-11-26-wave11-14-spec/soak_quick.json`](bench/experiments/2026-11-26-wave11-14-spec/soak_quick.json), [docs/research-2026-11-24/experiment-results.md](docs/research-2026-11-24/experiment-results.md), [`bench/experiments/2026-11-25-wave9-supremacy/results.json`](bench/experiments/2026-11-25-wave9-supremacy/results.json), and [`bench/experiments/2026-11-25-wave10-complete/results.json`](bench/experiments/2026-11-25-wave10-complete/results.json).

### Waves 11–14 — SPEC Perceptual Controller, Chroma Fidelity & 5-Run Apple M5 Benchmark

*5-run randomized benchmark (`30` trials, seed `20261126`, `testsrc2` `1280×720` `30 fps` `4s`, target `3,000 kbps`) run via [`bench/harness/spec_bench.py`](bench/harness/spec_bench.py) — offline `libvmaf`/`ffmpeg` strictly isolated inside the benchmark oracle (`0%` FFmpeg in production Safarium binaries); data in [`bench/experiments/2026-11-26-wave11-14-spec/results.json`](bench/experiments/2026-11-26-wave11-14-spec/results.json):*

| Candidate (`5/5` runs OK) | VMAF ↑ | VMAF-NEG ↑ | XPSNR ↑ | MS-SSIM ↑ | ΔE00 p95 ↓ | Bitrate (kbps) ↓ | Wall Time ↓ | Speed | Peak RSS ↓ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **`safarium_hevc10_vt`** *(Wave 12 Metal Chroma + 10-bit P010)* | **96.45** | **95.51** | **41.90** | **0.9986** | **1.27** | **2,837.3** | **0.725 s** | **5.52× RT** | 137.0 MB |
| **`safarium_hevc_vt`** *(8-bit HEVC VT)* | **96.37** | **95.46** | **41.95** | **0.9985** | **1.34** | **2,830.3** | **0.860 s** | **4.65× RT** | **37.8 MB** |
| **`safarium_h264_vt`** *(H.264 High VT — 3D & 2D Pareto!)* | **96.71** | **95.80** | **42.63** | **0.9987** | **1.90** | **2,824.6** | **0.682 s** | **5.87× RT** | **37.8 MB** |
| *Reference `ffmpeg_hevc_vt` (3000k)* | 96.17 | 95.33 | 41.73 | 0.9988 | 1.26 | 3,073.0 | 0.511 s | 7.83× RT | 103.4 MB |
| *Reference CPU `ffmpeg_libx265` (medium, 3000k)* | 96.75 | 95.70 | 42.86 | 0.9990 | 1.12 | 3,065.8 | 2.219 s | 1.80× RT | 432.1 MB |
| *Reference CPU `ffmpeg_libx264` (medium, 3000k)* | 97.24 | 95.93 | 43.42 | 0.9990 | 1.25 | 3,128.1 | 0.701 s | 5.70× RT | 365.0 MB |

> **Empirical Highlights (Waves 11–14 on Apple M5):**
> - **Wave 12 Chroma Fidelity Fix (`ΔE00 p95 <= 2.0` achieved!):** Lossless `NV12 → P010` widening + Metal `ChromaPipeline` + exact BT.709/BT.2020 colorimetry tags lowered Safarium HEVC 10-bit `ΔE00 p95` to **`1.27`** (matching `ffmpeg_hevc_vt` `1.26` and `libx264` `1.25`).
> - **Beats `ffmpeg_hevc_vt` across quality AND bitrate simultaneously:** `safarium_hevc10_vt` delivers higher **VMAF (`96.45` vs `96.17`)**, higher **VMAF-NEG (`95.51` vs `95.33`)**, higher **XPSNR (`41.90` vs `41.73`)**, at **`-7.7%` lower bitrate** (`2,837` vs `3,073 kbps`), while running **`3.06×` faster** with **`3.15×` less RAM** than CPU `libx265`.
> - **Ultra-low-RAM Pareto Leaders:** `safarium_hevc_vt` runs in **`37.8 MB` Peak RSS** (`2.74×` less RAM than `ffmpeg_hevc_vt`, **`11.4×` less than `libx265`**); `safarium_h264_vt` sits on **both** the **3D Pareto frontier** (`vmaf↑, kbps↓, wall_s↓`) and **2D RD Pareto frontier** (`vmaf↑, kbps↓`) at `37.8 MB` RSS (`9.7×` less RAM than `libx264`).
> - **Thermal Soak & Memory Stability (`bench/soak/thermal_soak.py`, `soak_quick.json`, 0% FFmpeg):** **`31/31` encodes succeeded (`0` failures)** over sustained load at **`111.6 FPS`** mean (`p50 0.495 s`, max `133.9 FPS`) with **`36.08 MB` Peak RSS** (`+0.06 MB` drift = zero memory leaks). **Honest note:** Apple VideoToolbox hardware rate-control exhibits minor run-to-run `mdat` bitstream variance across sessions (logged transparently in `soak_quick.json`).
> - **Hardware Auto-Tuner (`safarium forge calibrate-hw` on Apple M5):** Empirically scales HEVC sessions (`1 → 130.7 FPS`, `2 → 782.3 FPS (+498.7%)`, `3 → 841.2 FPS (+7.5% < 10% threshold)`), recommending **2 parallel sessions** on M5 automatically.

### Wave 10 — Every Video Encoding Scenario, Native HLS, Animated Clips & 1T NEON (Apple M5)

*Measured on a 5s 1080p30 A/V source (`150` frames + `48 kHz` stereo audio) — **0% FFmpeg / 0% OpenCV / 0% Chrome** (`bench/experiments/2026-11-25-wave10-complete/results.json`):*

| Workload / Scenario | Codec / Format | Wall Time | Speed | Output Size | Verification |
|---|---|---:|---:|---:|:---:|
| **`--scenario youtube`** | 10-bit HEVC (`hvc1`) + AAC-Max | **2.393 s** | **2.09× RT** (`62.7 fps`) | 7.14 MB | ✅ `verify` + `probe` |
| **`--scenario web-compat`** | H.264 High (`avc1`) + AAC-Max | **1.977 s** | **2.53× RT** (`75.9 fps`) | 3.02 MB | ✅ `verify` + `probe` |
| **`--scenario live-low-latency`** | Zero-B-frame H.264 (`avc1`) + AAC | **1.345 s** | **3.72× RT** (`111.5 fps`) | 3.01 MB | ✅ `verify` + `probe` |
| **`--scenario cinema-master`** | ProRes 422 HQ (`apch`) + 24-bit LPCM | **1.545 s** | **3.24× RT** (`97.1 fps`) | 124.02 MB | ✅ `probe` (`150` pkts) |
| **`--scenario hdr-dolby-vision`** | 10-bit HEVC DV 8.4 (`hvc1`) + AAC | **3.174 s** | **1.58× RT** (`47.3 fps`) | 17.78 MB | ✅ `probe` (`150` pkts) |
| **`--scenario podcast-video`** | Low-bitrate HEVC (`hvc1`) + AAC | **2.247 s** | **2.23× RT** (`66.8 fps`) | 2.04 MB | ✅ `verify` + `probe` |
| **Native HLS CMAF (`fmp4`) + WebVTT** | 3-rung ABR (`1080p, 720p, 480p`), 9 `.m4s` | **2.093 s** | **2.39× RT** (all 3 rungs!) | 4.73 MB | ✅ RFC 8216 `master.m3u8` |
| **Native HLS MPEG-TS (`ts`)** | 2-rung ABR (`720p, 480p`), 6 `.ts` | **0.969 s** | **5.16× RT** | 3.01 MB | ✅ RFC 8216 `master.m3u8` |
| **Direct Video → Animated WebP / GIF / APNG** | `480px @ 12fps` (`2.5s`) | **0.811 s / 0.555 s / 0.661 s** | **3.1×–4.5× RT** | 11.4 MB / 569 KB / 4.2 MB | ✅ `ImageIO` multi-frame |

> **All 19 built-in scenarios (`safarium forge scenarios` / MCP `list_scenarios`):** `youtube`, `youtube-4k`, `shorts`, `tiktok`, `reels`, `web-streaming`, `web-compat`, `screen-recording`, `cinema-master`, `cinema-vfx`, `transparent-vfx`, `hdr-dolby-vision`, `hdr10`, `spatial-visionos`, `archival`, `live-low-latency`, `podcast-video`, `webp-clip`, `gif-clip` — plus `--tonemap-sdr` hardware CoreImage HDR→SDR tone-mapping.
>
> **Wave 10 `SafariumRaster` 1T NEON & Phases 9–16 Timings (Apple M5):** `connectedComponents` 8-conn 1080p: **`0.557 ms`** (BBDT C99, bit-exact OpenCV label order), `cc8_withStats`: **`0.805 ms`**, `addWeighted` f32/u8: **`0.727 ms` / `0.999 ms`**, `add` u8: **`0.174 ms`**, `merge` 3ch: **`0.124 ms`**, `gray2bgr`: **`0.084 ms`**, `arcLength` (20k pts): **`0.011 ms`**, `pointPolygonTest` (20k pts): **`0.030 ms`**, `resize` 1080p→540p: **`0.091 ms`**, `warpAffine` rot5 nearest 1080p: **`1.175 ms`**, `ORB` 480p: **`8.191 ms`**, `phaseCorrelate` (`vDSP` 2D FFT) 480p: **`6.659 ms`**, `ximgproc.guidedFilter` 480p: **`10.066 ms`**.

### Wave 9 Apple Silicon Encoding Supremacy (Apple M5)

*3-shot 1080p30 9s (270 frames) stress master (`ProRes 422 HQ`, `222.2 MiB` — Shot 0: dark banding-prone gradient, Shot 1: fast high-motion diagonal kinetic scene, Shot 2: high-ISO synthetic grain), target `3.5 Mbps`, measured against the ProRes 422 HQ master via `safarium-forge pq --samples 27` (`MetalShotAnalyzer` detected exact scene cuts `[90, 180]` in `434.6 ms`):*

| Encoder / Mode | Wall Time | Speed | Bitrate | MS-SSIM ↑ | ΔE00 Mean ↓ | ΔE00 p95 ↓ | ANE Dist ↓ | PQ Score ↑ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Safarium W9 — 10-bit CQF `0.62` + SpatialAQ** | **2.19 s** | **4.11× RT** (`123.3 fps`) | 4.89 Mbps | **0.9987** | 0.88 | 6.34 | **0.043** | **91.4** |
| **Safarium W9 — True 2-Pass (`VTMultiPassStorage` + Shot-Cut IDR)** | **3.87 s** | **2.32× RT** (`69.7 fps`) | **3.55 Mbps** | **0.9939** | 1.01 | 6.71 | **0.098** | **90.2** |
| **Safarium W9 — 10-bit HQ (`SpatialAQ + LookAhead + VBV`)** | **2.25 s** | **4.01× RT** (`120.2 fps`) | 3.72 Mbps | **0.9922** | 0.95 | 6.52 | **0.097** | **90.1** |
| **Safarium W9 — Mini-CAE (Per-Shot Adaptive, 3 chunks)** | **2.07 s** | **4.35× RT** (`130.6 fps`) | 3.90 Mbps | **0.9826** | 0.94 | 6.57 | 0.157 | **89.4** |
| **Safarium W9 — `VTTemporalNoiseFilter` (AFBC HW) + Mini-CAE** | 5.14 s | 1.75× RT (`52.5 fps`) | 3.79 Mbps | 0.9754* | 1.03 | 6.70 | 0.216 | 88.4 |
| *Safarium W8 Legacy VT (8-bit HEVC 1-Pass Fast)* | 0.96 s | 9.34× RT (`280.1 fps`) | 3.52 Mbps | 0.9650 | 1.14 | 9.72 | 0.359 | 84.4 |
| *Reference FFmpeg `hevc_videotoolbox` (default `3.5M`)* | 1.68 s | 5.35× RT (`160.4 fps`) | 3.50 Mbps | 0.9741 | 1.09 | 9.49 | 0.246 | 87.6 |
| *Reference CPU `libx265` 10-bit (`medium`, `3.5M` 2-pass)* | 26.85 s | 0.34× RT (`10.1 fps`) | 3.79 Mbps | 0.9683 | **0.78** | **3.17** | 0.217 | 91.2 |
| *Reference CPU `libx264` (`medium`, `3.5M` 1-pass)* | 5.08 s | 1.77× RT (`53.2 fps`) | 4.79 Mbps | 0.9644 | 1.08 | 8.74 | 0.399 | 84.5 |

> **Key Takeaways (Empirical):**
> - **Crushes FFmpeg `hevc_videotoolbox` at identical bitrate:** Safarium True 2-Pass (`3.55 Mbps`) delivers **+0.0198 MS-SSIM** (`0.9939` vs `0.9741`), **-29.3% lower ΔE00 p95** (`6.71` vs `9.49`), **-60% lower ANE perceptual distance**, and **+2.6 PQ** (`90.2` vs `87.6`) — using hardware `VTMultiPassStorage` that FFmpeg cannot access.
> - **Dramatic generational leap over Wave 8 Legacy VT:** At the same `3.55 Mbps`, Wave 9 2-Pass lifts MS-SSIM from `0.9650 → 0.9939` (+`0.0289`) and cuts ΔE00 p95 from `9.72 → 6.71` (-`30.9%`).
> - **Beats CPU `libx265` 10-bit 2-pass on speed, size, MS-SSIM, & composite PQ:** Wave 9 True 2-Pass is **`6.94×` faster**, **6.3% smaller**, and **+0.0256 higher MS-SSIM**; Wave 9 CQF `0.62` is **`12.25×` faster** with the highest composite PQ (`91.4`) and MS-SSIM (`0.9987`) of all 9 encoders. *(And Wave 12's Metal `ChromaPipeline` + full BT.709/BT.2020 colorimetry fix subsequently brought HEVC 10-bit `ΔE00 p95` down to **`1.27`** on 720p30 — see the Waves 11–14 table above!)*
> - **Beats CPU `libx264` on every single metric:** Faster (`2.07–3.87 s` vs `5.08 s`), smaller (`3.55–3.90 Mbps` vs `4.79 Mbps`), and dramatically higher quality (`MS-SSIM 0.9939` vs `0.9644`).
> - *\*Note on `VTTemporalNoiseFilter`:* Intentionally strips Shot 2's synthetic high-ISO film grain, so pixel-wise MS-SSIM vs the noisy master drops slightly while visually denoising real camera grain at zero CPU cost (via hardware Lossless AFBC `'&8v0'`/`'&xv0'`). Wave 13's `AdaptiveDenoiseController` automatically protects crisp text/UI, faces, and intentional film grain.

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
| **Safarium (`safarium-forge`)** | **4.08 s** | **100 MiB** | **302 MiB** | `0.9967` / `1.65–1.85` / `0.0002 LU` | 1.77×–2.31× larger *(1-pass H.264 baseline; use Wave 9/12 HEVC 2-pass/VBV or SPEC for strict bitrate budgets)* |
| FFmpeg (`h264_videotoolbox`) | 11.82 s | 307 MiB | 356 MiB | Reference | 1.00× |
| FFmpeg (`libx264`) | 11.20 s | 933 MiB | 933 MiB | Reference | 0.77× |

### Hardware vs. Software Encoders Pareto (`H3`), Incremental Cache (`H5`), & 3D Hybrid (`H6`)

| Experiment | Metric | Safarium Result | Baseline / Rival | Delta |
|---|---|---:|---:|---|
| **`H3` Wave 8 VT vs `x264`/`x265`/`SVT-AV1`** | Peak RAM & Encode Speed | **72–143 MiB**, **1.30–1.45 s** | 356–1,367 MiB, 2.5–17.0 s | **14/14 wins** on RAM & Speed (`1.96×–11.75×` faster); Wave 9/12 10-bit 2-Pass, SPEC & Metal Chroma now beat FFmpeg VT on VMAF + bitrate + `ΔE00 p95 = 1.27` |
| **`H4` Still Codecs (`SafariumRaster`)** | JPEG decode / PNG / WebP VP8L | Bit-exact JPEG (`ΔE00 = 0.0`, `SSIM = 1.0`) | OpenCV 5.1.0 & `cwebp` | JPEG **`0.907×`** WIN; PNG **`2.30×`** faster & smaller; WebP VP8L **`1.43×–2.28×`** faster than `cwebp` |
| **`H5` APFS `clonefile` Closed-GOP Cache** | Partial-edit re-render (`150f`) | **2.89 s** (`0/150` diff frames) | 11.13 s full re-render | **`3.854×` faster**, bit-exact packet reuse (`150/150` SHA-256 identical) |
| **`H6` `SafariumPrism` Tier-0 `webkitGLB`** | Multi-angle 3D preview stills | **25 MiB** RAM, **0 B** temp PNGs | Cold Blender **1,721 MiB**, **24.8 MB** PNGs | **`3.12×–4.68×` faster**, **`-98.5%` RAM**, `HEVCWithAlpha` **`42.85×` smaller** than ProRes 4444 |

---

## Honest Trade-Offs — When NOT to Use Safarium

We prefer transparent engineering over hype (see our full [Capability Matrix](docs/capability-matrix.md)). You should **not** choose Safarium as your primary tool if:

1. **You need Linux or Windows execution.** Safarium is **100% macOS / Apple Silicon Only** by deliberate architectural choice — maximizing deep hardware integration (`WKWebView`, `Metal`, `VideoToolbox`, `VTFrameProcessor`, `AudioToolbox`, `ANE`, `APFS`) rather than diluting it across cross-platform lowest-common-denominator layers.
2. **You need royalty-free AV1 / VP9 / VVC / AV2 or MP3 encoding, or bit-exact deterministic hardware rate control.** Wave 12's Metal `ChromaPipeline` + full BT.709/BT.2020 colorimetry closed the chroma-edge gap (`ΔE00 p95 = 1.27` on `testsrc2` 720p30) and beats FFmpeg `hevc_videotoolbox` on VMAF, VMAF-NEG, XPSNR, and bitrate simultaneously, **but** offline next-gen software encoders (`SVT-AV1 4.3`, `VVenC 1.14`, `AV2`) remain smaller per bit for ultra-low-bitrate CDN archives, Apple Silicon has no hardware encoder for `AV1`, `VP9`, or `MP3` (honestly reported by `probe-capabilities`), and Apple VideoToolbox hardware rate-control exhibits minor run-to-run `mdat` bitstream variance across sessions.
3. **You run heavy multi-core CPU OpenCV pipelines.** `SafariumRaster` covers **Phases 1–16 + popular `contrib`** (`418` C-ABI symbols, **9,911+** parity tests passed) and beats OpenCV on Metal 4K GPU (`8/9`), custom still codecs, and 19/24 optimized 1T NEON kernels (including `cc8`, `addWeighted`, `add`, `merge`, `resize`, `warpAffine`, `pointPolygonTest`), but OpenCV still wins when scaling across 12+ CPU threads on massive batch arrays or niche legacy C++ `contrib` modules.
4. **You need deep offline still compression (`cjxl`, `avifenc`, `mozjpeg`, `zopflipng`).** Safarium optimizes for fast, zero-dependency, universally playable PNG/JPEG/WebP/HEIC/AVIF rather than slow brute-force compression.
5. **You keep full Blender + WebGL2 resident at the exact same instant.** Concurrent hybrid rendering (`H6B`) peaks higher combined RAM (`2,038 MiB` vs `1,721 MiB`) than running a single engine alone unless using Tier-0 `webkitGLB` previews.

---

## Architecture

```mermaid
flowchart LR
    subgraph Inputs["Inputs, SDKs & Multi-AI Entrypoints"]
        I1["HTML / CSS / SVG / GSAP / WebGL2"]
        I2["JSON Media DAG (graph-v1), 19 Scenarios & SPEC Contracts"]
        I3["Python import cv2 (Phases 1–16) / Node / Shell"]
        I4["Blender .glb / Warm SHM + HUD"]
        I5["AI Agents (Claude / Gemini / Cursor / Codex via MCP v2)"]
    end

    subgraph Core["Safarium Unified Engine (macOS Native + FIFO Queue)"]
        C0["safarium-mcp v2 (23 tools) & Unified CLI\\nIntent-Level SPEC · SF-VIDEO-1 FIFO"]
        C1["SafariumCore, SPEC & HLSPackager\\nSPEC Controller · Metal Chroma · 19 Scenarios · CMAF/TS HLS"]
        C2["SafariumForge & VTFrameProcessor\\nMetal DAG · AFBC Denoise · Auto-Tuner · APFS Cache · PQ"]
        C3["SafariumRaster (ABI v1)\\n418 C-ABI Symbols (Phases 1–16) · NEON & Vision/CoreML"]
        C4["SafariumPrism, SafariumContainers & Conformance\\nHybrid 3D · Pure-Swift Mux · Swift/Rust Bitstream Validators"]
    end

    subgraph Apple["Apple Silicon Native Hardware (Zero External Binaries)"]
        A1["WKWebView (.prohibited)"]
        A2["Metal & CoreImage (UMA)"]
        A3["VideoToolbox / VTFrameProcessor / AudioToolbox"]
        A4["Accelerate (BLAS/vDSP/vImage) & ARM64 NEON"]
        A5["Vision / CoreML / Neural Engine (ANE)"]
        A6["APFS clonefile(2) & SCM_RIGHTS mmap"]
    end

    subgraph Outputs["Verified Deliverables"]
        O1["H.264 / 10-bit HEVC (4:2:0/4:2:2/4:4:4) / DV 8.4 / MV-HEVC / 6x ProRes"]
        O2["MP4 / MOV / HLS CMAF & TS / MKV / WebM / tx3g · AAC-Max / ALAC / Opus / APAC"]
        O3["PNG / JPEG / Animated WebP (VP8L) / GIF / APNG / AVIF / HEIC"]
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
| **`safarium-mcp` v2** | `bin/safarium-mcp`, `docs/mcp-server.md` | Zero-dependency Python 3 MCP stdio JSON-RPC 2.0 server (**`23` tools**, `5` resources, `3` prompts, live JSONL progress notifications) including intent-level `encoding_capabilities`, `encoding_conformance`, `encoding_plan`, `encoding_encode`, and `encoding_ladder` |
| **`SafariumCore`** | `Sources/SafariumCore/` | Windowless `WKWebView` engine, `VirtualClock`, **Waves 11–14** `EncoderCapabilityProfiler`, `FrameLease`, `PipelineResilience` (`AtomicOutputPublisher`), `ChromaPipeline` (Metal 10-bit 4:2:0/4:2:2/4:4:4), `HDRIntegrity`, `SPECAnalyzer` + `AdaptiveDenoiseController` + `SPECController`, `HardwareAutoTuner` + `ThermalHysteresisScheduler`, `ProResPipeline` (Zero-4:2:0), **Wave 10** `EncodingScenarios` (`19` presets), `HLSPackager` (shared-IDR CMAF + MPEG-TS + WebVTT), `HardwareToneMapper`, `AnimatedClipExporter`, **Wave 9** `SupremacyEncoder` (`MetalShotAnalyzer`, `VTMultiPassEncoder`, `MultiEngineChunkEncoder`, `MVHEVCSpatialEncoder`), **12 codecs**, `ProAudioEncoder`, `SafariumTX3G` |
| **`SafariumForgeCore` + `safarium-forge`** | `Sources/SafariumForgeCore/`, `Sources/safarium-forge/` | Declarative JSON DAG media engine, Metal filter shaders, `ForgeVTProcessor` (hardware AFBC `VTTemporalNoiseFilter`, `VTFrameRateConversion`, `VTMotionBlur`), `probe-capabilities`, `conformance`, `spec-plan`, `spec-encode`, `spec-ladder`, `calibrate-hw`, `AF_UNIX` + `SCM_RIGHTS` unlinked `mmap` ring encoder, APFS `clonefile(2)` incremental cache, `APFSAutoStage`, `SafariumPQ`, and AI JSONL control plane |
| **`SafariumPrism`** | `Sources/SafariumPrism/`, `Tools/prism-blender-worker.py` | Hybrid 3D engine uniting Warm Blender SHM (`EEVEE`/`CYCLES`) + WebKit WebGL2/Three.js + `1× Thai Shield` HUD overlay, MetalFX/LLSR upscaling with `SafariumPQ` fallback, and HID/thermal Anti-Lag Governor |
| **`SafariumRaster` + `SafariumRasterC`** | `Sources/SafariumRaster/`, `Sources/SafariumRasterC/` | Dynamic C-ABI library (`libSafariumRaster.dylib`, **`418` symbols**, **Phases 1–16 + popular `contrib`**): Core, `Accelerate` Linear Algebra, ImgProc Filters, Geometry/Contours/BBDT NEON CC/Hough/LSD/Subdiv2D, VideoIO, Photo/Inpaint/NLM/HDR/Bayer, **Features2D** (`ORB`/`FAST`/`Harris`/`BFMatcher`), **Video** (`PyrLK`/`Farneback`/`phaseCorrelate`/`MOG2`/`MeanShift`/`ECC`), **Calib3D** (`findHomography`/`Rodrigues`/`solvePnP`/`StereoBM`), **ObjDetect** (Vision QR/Barcode + ArUco), **CoreML ANE `dnn`**, **3D PLY**, **Stitcher/FLANN/CCM**, **`FileStorage`/`ximgproc`/`xphoto`/`TrackerCSRT`**, opt-in Metal GPU, and custom C99/NEON still codecs |
| **`SafariumContainers` & Rust Conformance CLI** | `Sources/SafariumContainers/`, `Tools/safarium-conformance-rs/` | Pure-Swift bitstream muxers/demuxers (EBML/MKV/WebM, MPEG-TS, MPEG-2 PS, Ogg/Vorbis I + FLAC, WebP RIFF/VP8L), **`BitstreamConformance`** + **`HLSConformanceValidator`**, plus an independent `#![forbid(unsafe_code)]` zero-dependency **Rust ISOBMFF/MPEG-TS/HLS conformance CLI** |
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

# 3. Install into ~/.local (includes safarium, safarium-render, safarium-mcp v2 + Apple-only otool -L check)
RELEASE="$(xcrun swift build -c release --scratch-path /tmp/safarium-build --show-bin-path)"
python3 Tools/install-render.py --release "$RELEASE" --verifier /tmp/safarium-build/safarium-verify
python3 Tools/install-render.py --check

# 4. Verify environment, live hardware capabilities, 19 scenarios, and 418-symbol C ABI
"$HOME/.local/bin/safarium" doctor --json
"$HOME/.local/bin/safarium" forge probe-capabilities
"$HOME/.local/bin/safarium" forge scenarios
"$HOME/.local/bin/safarium" raster info
```

### Everyday Examples

```sh
# 1. Waves 11–14: Probe live VideoToolbox capabilities & auto-calibrate parallel Media Engine sessions
safarium forge probe-capabilities
safarium forge calibrate-hw --codec hevc-10bit

# 2. Waves 11–14: SPEC Perceptual Encoding Plan + Closed-Loop Quality-Target Encode + Bitstream Conformance
safarium forge spec-plan master.mov --codec hevc-10bit --save-sidecar plan_sidecar.json
safarium forge spec-encode master.mov -o delivery.mp4 --target-ms-ssim 0.995 --max-deltae-p95 2.0 --overwrite
safarium forge conformance delivery.mp4 --expected-codec hvc1 --expected-bit-depth 10 --strict

# 3. Waves 11–14: Per-Title Convex-Hull HLS Ladder (reuses sidecar + shared-IDR + auto HLS conformance)
safarium forge spec-ladder master.mov -o ./hls_out --load-sidecar plan_sidecar.json --format fmp4 --max-rungs 4

# 4. Independent zero-dependency Rust conformance verifier (ISOBMFF / HEVC / MPEG-TS / HLS)
cargo run --manifest-path Tools/safarium-conformance-rs/Cargo.toml -- --input delivery.mp4
cargo run --manifest-path Tools/safarium-conformance-rs/Cargo.toml -- --input ./hls_out/master.m3u8 --type hls

# 5. One-flag Video Scenario Encoding (19 built-in scenarios: youtube, tiktok, cinema-master, hdr-dolby-vision, etc.)
safarium forge transcode master.mov -o youtube.mp4 --scenario youtube --overwrite
safarium forge transcode hdr_master.mov -o sdr.mp4 --scenario web-compat --tonemap-sdr --overwrite

# 6. Direct Video -> Animated WebP / GIF / APNG Clip (0% FFmpeg)
safarium forge clip master.mov -o preview.webp --format webp --fps 12 --max-width 640 --max-duration 5.0 --overwrite

# 7. Deterministic windowless HTML/CSS/SVG/WebGL2 -> 10-bit HEVC MP4 (with SpatialAQ + CQF)
safarium html scene.html --output out.mp4 --width 1080 --height 1920 --fps 30 --frames 90 \
  --codec hevc10 --pixel-format p010 --spatial-aq high --cqf 0.62 --video-only

# 8. Wave 9 True 2-Pass Hardware HEVC Transcode (VTMultiPassStorage + Shot-Cut IDR, 0% FFmpeg)
safarium forge transcode master.mov -o delivery.mp4 \
  --codec hevc-10bit --mode 2pass --bitrate 3500000 --spatial-aq

# 9. Native AudioToolbox Pro Mastering (AAC-Max, HE-AAC v1/v2, ALAC, Opus, APAC, 24/32f PCM)
safarium forge audio encode mix.wav -o master.m4a --codec alac

# 10. Start the 23-tool MCP v2 stdio server for Claude / Gemini / Cursor / Codex
safarium mcp

# 11. Drop-in Python cv2 backed by libSafariumRaster.dylib (Phases 1–16 + contrib, 0% OpenCV / FFmpeg)
PYTHONPATH=sdk/python/safarium_cv2 \
  python3 -c 'import cv2; print(cv2.__version__, hasattr(cv2, "ORB_create"), hasattr(cv2, "ximgproc"))'
```

---

## Verified Cloud CI

Every push is verified by 2-Tier GitHub Actions macOS Cloud CI ([`.github/workflows/ci-macos.yml`](.github/workflows/ci-macos.yml)) across **two macOS & Swift generations** — **4/4 GREEN**:

| Check | `macos-15` (Xcode 16.4 / Swift 6.1.2) | `macos-26` (Xcode 26.6 / Swift 6.3.3) |
|---|---|---|
| **Public Repo Hygiene Audit** (`0` personal paths / secrets / forbidden calls) | ✅ `0` violations | ✅ `0` violations |
| **Apple-Only `otool -L` Linkage** (`0%` FFmpeg / Chrome / OpenCV) | ✅ `8/8` Apple-only | ✅ `8/8` Apple-only |
| **C99 Codec + NEON ASan/UBSan + Swift XCTest Suite (Waves 1–14)** | ✅ **`283` executed, `0` failed** | ✅ **`283` executed, `0` failed** |
| **Queue, Installer & 23-Tool MCP v2 Tests (`test_queue.py` + `test_mcp.py`)** | ✅ `27/27` OK | ✅ `27/27` OK |
| **Independent Rust Conformance CLI (`Tools/safarium-conformance-rs`)** | ✅ `5/5` `cargo test` PASS | ✅ `5/5` `cargo test` PASS |
| **`SafariumRaster` Reference Parity Suite (Phases 1–16 + contrib)** | ✅ **`9,911+` passed, `0` failed** | ✅ **`9,911+` passed, `0` failed** |
| **Cross-OS H.264 Smoke Determinism** | ✅ Identical SHA-256 across both OSes | ✅ Identical SHA-256 across both OSes |

---

## Waves 9–14 Apple Silicon Encoding Supremacy & SPEC (Shipped)

All encoding pillars from our [Global Video Encoding Encyclopedia (2025–2026)](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md) and Waves 11–14 engineering architecture (100% macOS / 0% FFmpeg) are **shipped, tested (`283` Swift XCTests + `27` Queue/MCP tests + `5` Rust tests), exposed via CLI & 23-tool MCP v2, and empirically benchmarked on Apple M5**:

1. **Wave 11 — Truth, Conformance & Resilience:** Live `EncoderCapabilityProfiler` (`probe-capabilities`), transparent [Capability Matrix](docs/capability-matrix.md), independent zero-FFmpeg Swift & Rust ISOBMFF/HEVC/MPEG-TS/HLS conformance validators (`conformance` + `Tools/safarium-conformance-rs`), bounded zero-copy `FrameLease`, and `AtomicOutputPublisher` / `WatchdogTimer` / `VTSessionRecoveryPolicy`.
2. **Wave 12 — Metal Chroma Fidelity & HDR Integrity:** Metal 10-bit `4:2:0`/`4:2:2`/`4:4:4` `ChromaPipeline` + lossless `NV12 → P010` widening + exact BT.709/BT.2020 colorimetry (cutting `ΔE00 p95` to **`1.27`** and beating FFmpeg `hevc_videotoolbox` on VMAF, VMAF-NEG, XPSNR, and bitrate simultaneously), strict `HDRIntegrity` (`preserve`/`recompute`/`strip`/`tone-map`), and shared-IDR + exact measured peak `BANDWIDTH` in `HLSPackager`.
3. **Wave 13 — SPEC Perceptual Encoding Controller:** Multi-signal `SPECAnalyzer` (hard cut vs flash/fade/pan, grain/noise, banding risk, Vision text/face masks, reusable `SPECAnalysisSidecar`), text/face/grain-safe `AdaptiveDenoiseController`, closed-loop quality-target `SPECController` (`spec-plan`, `spec-encode`), and Per-Title Convex-Hull HLS ABR ladder generation (`spec-ladder`).
4. **Wave 14 — Hardware Auto-Tuner, Zero-4:2:0 ProRes, Reproducible Oracle & MCP v2:** `HardwareAutoTuner` (`calibrate-hw`) + `ThermalHysteresisScheduler`, Zero-4:2:0 `ProResPipeline`, multi-run randomized benchmark oracle (`bench/harness/spec_bench.py`) & thermal soak (`bench/soak/thermal_soak.py`), and 23-tool intent-level `safarium-mcp` v2.
5. **Wave 10 — 19 One-Flag Scenarios, Native HLS & Animated Clips:** Instant presets covering YouTube/4K, Shorts/TikTok/Reels, Web/Streaming, Screen Recording, Cinema/VFX/Alpha, HDR10/Dolby Vision 8.4, VisionOS Spatial, Archival, Live Low-Latency, Podcast, and WebP/GIF/APNG; native `.fmp4` CMAF & `.ts` MPEG-TS HLS ladder generation with WebVTT subtitles; CoreImage HDR→SDR tone-mapping.
6. **Wave 9 — VideoToolbox Supremacy & Pro Audio:** `SpatialAdaptiveQPLevel`, `LookAheadFrames`, Constrained `VBR + VBV`, `ConstantQualityFactor` (`CQF`), **True 2-Pass `VTMultiPassStorage`**, **"Safarium Mini-CAE"** multi-engine chunking, zero-copy `VTFrameProcessor` (`VTTemporalNoiseFilter` AFBC, `VTFrameRateConversion`, `VTMotionBlur`), all **12 video codecs** (including 6 ProRes tiers, DV 8.4, MV-HEVC), and `ProAudioEncoder` (`AAC-Max`, `HE-AAC v1/v2`, `ALAC`, `Opus`, `APAC`, `16/24/32f PCM`).

---

## Documentation & Research

- **[Capability Matrix (Supported / Experimental / Unsupported)](docs/capability-matrix.md)** — Honest, live-probed Apple Silicon hardware & codec matrix
- **[MCP Server v2 & Multi-AI Integration (`safarium-mcp`)](docs/mcp-server.md)** — Setup for Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI + **23-tool** intent-level schema
- **[Independent Rust Bitstream & HLS Validator](Tools/safarium-conformance-rs/src/main.rs)** — `#![forbid(unsafe_code)]`, zero-dependency ISOBMFF / MPEG-TS / HLS verifier
- **[Reproducible Benchmark Harness & Thermal Soak](bench/harness/spec_bench.py)** — Multi-run randomized VMAF / VMAF-NEG / XPSNR / MS-SSIM / ΔE00 p95 oracle + [`thermal_soak.py`](bench/soak/thermal_soak.py)
- **[Global Video Encoding Encyclopedia (2025–2026)](docs/research-2026-11-24/global-video-encoding-encyclopedia-2026.md)** — Complete worldwide comparison (Software, Next-Gen AV2/VVC, Cloud CAE, GPU/ASICs, Cinema/Mezzanine/APV, Neural AI, Audio) + shipped Wave 9 Apple M5 benchmark results
- **[World Video, Web-to-Video, Image & Hardware Ecosystem Matrix (47 Tools)](docs/research-2026-11-24/world-video-ecosystem-matrix.md)** — Deep technical comparison across all 4 ecosystem categories
- **[Empirical Benchmark Results (`H1–H7`)](docs/research-2026-11-24/experiment-results.md)** — Full Apple M5 measurements, methodology, wins, and losses
- **[Cloud CI Results (`macos-15` & `macos-26`)](docs/research-2026-11-24/cloud-ci-results.md)** — Reproducible dual-OS CI verification report
- **[SafariumForge Guide](docs/safarium-forge-guide-2026-11-23.md)** — Declarative JSON DAG recipes, Metal filters, and audio mastering
- **[SafariumRaster Roadmap](docs/raster-roadmap.md)** — `418`-symbol C-ABI architecture & OpenCV Phases 1–16 + `contrib` coverage
- **[AI Control Protocol](docs/ai-control-protocol.md)** — Machine-readable `--progress jsonl`, `--json-errors`, and `E_*` taxonomy
- **[Chrome-less CDP Shim (`safarium-cdp`)](docs/cdp-shim.md)** — Running Puppeteer & HyperFrames on `WKWebView`

---

## License

Licensed under the **Apache License, Version 2.0**. See [LICENSE](LICENSE) for the full text.
