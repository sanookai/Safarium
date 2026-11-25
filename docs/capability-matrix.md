# Safarium Capability Matrix (Apple Silicon macOS)

> **Architectural Contract:** All production Safarium binaries (`SafariumCore`, `SafariumContainers`, `SafariumForgeCore`, `SafariumPrism`, `SafariumRaster`, `safarium-html`, `safarium-media`, `safarium-forge`, `safarium-mcp`) link **100% Apple native macOS frameworks only** (`AVFoundation`, `VideoToolbox`, `AudioToolbox`, `CoreMedia`, `CoreVideo`, `Metal`, `MetalFX`, `Accelerate`, `Vision`, `CoreImage`, `ImageIO`, `WebKit`). Zero FFmpeg, zero Chrome, zero OpenCV, and zero software fallback shims exist in production targets.

---

## Status Classification Legend

| Status | Meaning |
|---|---|
| **Supported (Bitstream + Decode Verified)** | Production-ready on Apple Silicon; output bitstream structure, metadata tags, and native AVFoundation/VideoToolbox decode parity verified by automated test suites. |
| **Experimental (Plumbed, Expanded Conformance Ongoing)** | Wired cleanly through Apple native APIs with unit/smoke coverage, undergoing expanded multi-generation hardware, SDK, and external player conformance validation. |
| **Unsupported / Out of Scope** | Explicitly not supported due to Apple Silicon hardware walls or intentional product boundaries; requests fail fast with structured `E_UNSUPPORTED_CODEC` / `E_USAGE` envelopes rather than silently falling back to software or third-party tools. |

---

## 1. Platform & Apple Silicon Hardware Baseline

| Feature / Capability | macOS 14 (Sonoma) | macOS 15 (Sequoia) | macOS 26+ (Tahoe+) | Hardware / SDK Notes |
|---|---|---|---|---|
| Apple Silicon M1 / M2 / M3 / M4+ Core Pipeline | **Supported (Bitstream + Decode Verified)** | **Supported (Bitstream + Decode Verified)** | **Supported (Bitstream + Decode Verified)** | Unified memory zero-copy `IOSurface` + `CVMetalTextureCache` |
| Spatial Adaptive Quantization (`SpatialAQ`) | Unsupported (OS Wall) | **Supported (Bitstream + Decode Verified)** | **Supported (Bitstream + Decode Verified)** | `kVTCompressionPropertyKey_SpatialAdaptiveQPLevel` (macOS 15+) |
| `VTFrameProcessor` Optical Flow / Denoise / Retime | Unsupported (OS Wall) | **Experimental (Plumbed, Expanded Conformance Ongoing)** | **Supported (Bitstream + Decode Verified)** | Requires macOS 15.4+ / 26+ Apple Silicon Neural Engine & GPU |
| Hardware HEVC 4:2:2 10-bit Encode | Unsupported (HW/OS Wall) | **Experimental (Plumbed, Expanded Conformance Ongoing)** | **Supported (Bitstream + Decode Verified)** | Hardware accelerated on M4 / M4 Pro / M4 Max Media Engines; probed via `capabilities` |
| Intel x86_64 / Windows / Linux | **Unsupported / Out of Scope** | **Unsupported / Out of Scope** | **Unsupported / Out of Scope** | Apple Silicon macOS-only architecture |

---

## 2. Video Codecs

| Codec / Profile | macOS 14 | macOS 15 | macOS 26+ | Status & Technical Notes |
|---|---|---|---|---|
| **H.264 / AVC (8-bit 4:2:0)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — High/Main/Baseline, Closed-GOP, VBV, True 2-Pass `VTMultiPassStorage`, Mini-CAE |
| **HEVC / H.265 (8-bit 4:2:0, `hvc1`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Hardware Media Engine, CQF, LookAhead, SpatialAQ (15+), 2-Pass, Mini-CAE |
| **HEVC / H.265 (10-bit 4:2:0, Main 10 / `P010`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — 10-bit `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` + Wave 12A Metal Chroma Pipeline |
| **HEVC / H.265 (10-bit 4:2:2, `P210`)** | Unsupported | Experimental | Supported (M4+) | **Experimental (Plumbed, Expanded Conformance Ongoing)** — Hardware-gated by Apple Silicon generation (M4+ Media Engine) |
| **HEVC / H.265 (10-bit 4:4:4, `P410` / `Y416`)** | Experimental | Experimental | Experimental | **Experimental (Plumbed, Expanded Conformance Ongoing)** — Plumbed via VideoToolbox Main 4:4:4 10; decode/player matrix verification ongoing |
| **HEVC with Alpha (`muxa` / `.mov`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Dual-layer alpha video in `.mov` for macOS/iOS/Safari transparent VFX |
| **Apple ProRes (6 Tiers)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — `422 Proxy`, `422 LT`, `422`, `422 HQ`, `4444` (with alpha), `4444 XQ` |
| **MV-HEVC (Stereoscopic Spatial Video)** | Experimental | Experimental | Experimental | **Experimental (Plumbed, Expanded Conformance Ongoing)** — Plumbed via `spatial-encode` (`heroEye`, FOV, baseline mm, disparity) for visionOS `.mov` |
| **Hardware AV1 Encode** | Unsupported | Unsupported | Unsupported | **Unsupported / Out of Scope** — Apple Silicon M3/M4 provides hardware AV1 *decode* only; no Apple HW AV1 encoder exists |
| **VVC (H.266) / AV2 / VP9 Encode** | Unsupported | Unsupported | Unsupported | **Unsupported / Out of Scope** — No Apple Silicon hardware encode support; never emulated with slow software codecs |

---

## 3. Delivery, Containers & Streaming

| Capability | macOS 14 | macOS 15 | macOS 26+ | Status & Technical Notes |
|---|---|---|---|---|
| **MP4 / MOV (`+faststart` `moov`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Native `AVAssetWriter` + `SafariumContainers` lossless mux/splice & metadata |
| **VOD HLS ABR — CMAF `.fmp4`** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — 0%-FFmpeg multi-rung ABR ladder (`360p`–`2160p`), Closed-GOP aligned segments, RFC 8216 `master.m3u8` |
| **VOD HLS ABR — MPEG-TS (`.ts`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Pure-Swift 188-byte PAT/PMT/PES MPEG-TS muxer (`HLSPackager`), zero external muxers |
| **WebVTT (`.vtt`) / SRT / TX3G Subtitles** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Native `SubtitleWriter` + HLS `EXT-X-MEDIA:TYPE=SUBTITLES` + Thai UTF-8 support |
| **Animated Clips (`WebP`, `GIF`, `APNG`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Native `AVAssetReader` + `ImageIO` (`RIFF....WEBPVP8X`, GIF, APNG) |
| **Live / Low-Latency HLS (LL-HLS) Ingest** | Unsupported | Unsupported | Unsupported | **Unsupported / Out of Scope** — Safarium targets deterministic offline/VOD file & pipeline production |
| **MPEG-DASH (`.mpd`)** | Unsupported | Unsupported | Unsupported | **Unsupported / Out of Scope** — VOD HLS CMAF/TS only |
| **FairPlay / Widevine / PlayReady Multi-DRM** | Unsupported | Unsupported | Unsupported | **Unsupported / Out of Scope** — DRM license servers and encrypted CENC/CBCS packaging are out of scope |

---

## 4. Colorimetry, Chroma Fidelity & HDR

| Capability | macOS 14 | macOS 15 | macOS 26+ | Status & Technical Notes |
|---|---|---|---|---|
| **BT.709 SDR (8-bit NV12 & 10-bit P010)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Exact ITU-R BT.709 primaries/transfer/matrix tags |
| **Wave 12A Metal Chroma Fidelity Pipeline** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Zero-copy `BGRA8 → linear RGBA16F → phase-aware luma-guided 4:2:0` (`NV12`/`P010`) + temporal IGN dithering + masked CIEDE2000 |
| **BT.2020 PQ (HDR10)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — 10-bit `P010`, ST.2084 PQ transfer, BT.2020 primaries, mastering display (`MDCV`) & `CLLI` metadata |
| **HLG (Hybrid Log-Gamma, BT.2020)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — ARIB STD-B67 HLG 10-bit pipeline |
| **Dolby Vision Profile 8.4** | Experimental | Experimental | Experimental | **Experimental (Plumbed, Expanded Conformance Ongoing)** — Apple HLG-compatible DV 8.4 mastering profile; cross-device certification ongoing |
| **Apple Log / Apple Log 2** | Experimental | Experimental | Experimental | **Experimental (Plumbed, Expanded Conformance Ongoing)** — Native color tagging and wide-gamut ProRes/HEVC-10bit workflows |
| **Hardware HDR → SDR Tone-Mapping** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Metal / CoreImage / VideoToolbox hardware tone-mapping (`--tonemap-sdr`) to BT.709 SDR |

> ### Stale Dynamic-Metadata Protection Policy
> Whenever a Safarium pipeline applies pixel-altering transforms — including **HDR→SDR tone-mapping, geometric crop/reframe/scale, HTML/3D compositing, alpha matting, color grading, or denoise/retime** — pre-existing input HDR10+ SEI, Dolby Vision RPU, or mastering `MDCV`/`CLLI` statistics become physically invalid for the transformed frames. Safarium **explicitly strips stale dynamic/mastering metadata** during destructive transforms rather than blindly copying mismatched metadata into the output bitstream; dynamic metadata is only emitted when freshly authored or explicitly preserved on a verified lossless passthrough path.

---

## 5. Audio Codecs & Mastering (`ProAudioEncoder`)

| Codec / Feature | macOS 14 | macOS 15 | macOS 26+ | Status & Technical Notes |
|---|---|---|---|---|
| **AAC-LC / AAC-Max (`aac`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Apple CoreAudio / AudioToolbox `kAudioFormatMPEG4AAC` mastering quality |
| **HE-AAC v1 (`he-aac`) & HE-AAC v2 (`he-aac-v2`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Native AudioToolbox SBR / Parametric Stereo low-bitrate speech & streaming |
| **ALAC (Apple Lossless)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Bit-exact lossless archival in `.m4a` / `.mp4` / `.mov` |
| **Opus (`opus`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Native AudioToolbox `kAudioFormatOpus` |
| **APAC (Apple Positional Audio Codec)** | Experimental | Experimental | Supported | **Experimental (Plumbed, Expanded Conformance Ongoing)** — Spatial audio mastering for visionOS / MV-HEVC workflows |
| **LPCM (16-bit / 24-bit / 32-bit Float)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Broadcast & cinema uncompressed mastering |
| **EBU R128 Loudness & True-Peak Limiter** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Native `Accelerate` DSP (`AudioLimiter`) targeting `-14` / `-16` LUFS & `-1.0 dBTP` |

---

## 6. 2D Raster & Computer Vision (`SafariumRaster`)

| Capability | macOS 14 | macOS 15 | macOS 26+ | Status & Technical Notes |
|---|---|---|---|---|
| **`libSafariumRaster.dylib` Flat C ABI** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — **418 exported C-ABI symbols** (`ctypes`-compatible drop-in `cv2` replacement for Python) |
| **Core Image Ops, Geometry, Morphology, Filtering (Phases 1–16)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — `Accelerate` (`vImage`/`vDSP`/`LAPACK`) + Metal GPU + `ImageIO` |
| **Contrib & Vision Modules (Contours, Optical Flow, QR/Features, LUTs)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — 0% OpenCV / 0% FFmpeg linkage verified via `otool -L` |

---

## 7. Multi-AI Orchestration & MCP (`safarium-mcp`)

| Capability | macOS 14 | macOS 15 | macOS 26+ | Status & Technical Notes |
|---|---|---|---|---|
| **MCP `stdio` JSON-RPC 2.0 Server (`safarium-mcp`)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Zero-dependency Python 3 stdlib server; negotiates `2025-06-18`, `2025-03-26`, `2024-11-05` |
| **18 Exposed Tools (10 Read-Only + 8 Render/Encode/QA)** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Fast tools bypass queue; heavy jobs serialize via `SF-VIDEO-1` single-slot FIFO (`~/.safarium-render-queue`) |
| **Resources (5), Prompts (3) & Structured `E_*` Errors** | Supported | Supported | Supported | **Supported (Bitstream + Decode Verified)** — Machine-readable recovery hints and `--progress jsonl` → MCP `notifications/progress` streaming |

---

## 8. Quality Verification & Offline Benchmark Oracle

| Component | Production Linkage | Status & Scope |
|---|---|---|
| **Safarium Native QA (`SafariumPQ`, `verify`, `qa`)** | 100% Apple Native (`Metal`, `Accelerate`, `Vision`, `AVFoundation`) | **Supported (Bitstream + Decode Verified)** — Perceptual MS-SSIM, exact CIEDE2000 (mean/p95/saturated-edge/text-mask), ANE feature distance, Vision Thai OCR |
| **Offline Benchmark Oracle (`bench/harness/spec_bench.py`)** | Offline research script ONLY (never imported/linked by Safarium) | **Supported (Offline Research Oracle)** — Reproducible `schema_version: 2` harness pinning git/binary/input SHA-256 + macOS/chip/power/thermal state; randomized multi-trial median/p5/p95/min/max/failure_rate; `libvmaf` / `VMAF-NEG` / `PSNR` / `SSIM` / `XPSNR` + Safarium `pq` + 3D/RD Pareto frontier |
