---
tags: [safarium, safarium-forge, architecture, spec, apple-silicon, zero-copy]
note_type: spec
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# `safarium-forge` Architectural Design Specification (macOS-Exclusive Unified Zero-Copy Media Engine)

> **Status:** Approved by Pick (All 5 `/grill-me` branches + Approach A Modular Architecture locked on 2026-11-22/23) · **Platform Floor:** macOS 14+ (verified on Apple M5 `Mac17,3`, macOS 27.2 `26B123`, `MacOSX27.2.sdk`) · **Invariant:** **0% FFmpeg, 0% `ffprobe`, 0% `libav*`, 0% Chrome/Chromium/Playwright, 0% GPL/LGPL binaries.**

## 1. Purpose & Problem Statement
Across 49 real-world projects (`29` Tier 1 + `20` Tier 3) in Pick's Vault and Top-20 global FFmpeg/Chromium workflows (`01`–`05` research reports), legacy pipelines suffer three severe failures:
1. **PCIe / Pipe / Multi-Process Bloat (`GEOSong` `~5 GB`, `เข้าใจตัวเองฯ` full-episode frame lists, `Capcut Skill` dual `frames_bgr`+`all_alphas` pipes, `Ripr.app` 10fps `qtrle` intermediates, `Rea Video` `areverse` OOMs):** Linux/Windows stacks glue Chrome PNGs, Python NumPy/ONNX arrays, and `ffmpeg` subprocesses with serialization/disk churn.
2. **macOS Format, Quality & Storage Walls:** `AVURLAsset` rejects `.mkv`/`.webm` and drops HEVC (`0x24`) tracks in local `.ts`; `ImageIO` cannot encode WebP (`org.webmproject.webp`) or lossless `q=1.0` AVIF; Safari 27.2 WebCodecs emits `39B ES_Descriptor` (`Bug 302253`) causing `76B` double-wrap; an external ExFAT volume is ExFAT (`NO_PERMISSIONS`, `clonefile=false`, `RENAME_EXCL=false`); `VTRegisterSupplementalVideoDecoderIfAvailable` is needed to unlock VP9 HW decode.
3. **Lack of Inline Neural + WebKit Zero-Copy Graph:** Replacing `-filter_complex` string escaping and post-hoc CPU `libvmaf` with a strongly typed declarative graph running directly over `IOSurface`-backed `CVPixelBuffer`s (`153 GB/s` UMA on M5).

## 2. Modular Target Architecture (`Package.swift`)
```
SafariumCore (existing foundation: FrameSink, AccelerateOps, LosslessMuxSplice, SubtitleWriter, HybridCompositor, WarmWorker, Wave2MetalEffects)
   ├──► SafariumContainers (Pure-Swift EBML MKV/WebM, MPEG-TS 188B, VP8L Lossless WebP + ImageIO AVIF/HEIC, Bug 302253 ESDS, VT/AudioToolbox bridges)
   └──► SafariumForgeCore (ForgeRecipe v1, APFSAutoStage, ForgeMetalFilters, ForgeANE [autoReframe, personMatte, SafariumPQ], ForgeAudioDSP, ForgeSheetAndQA, ForgeGraphExecutor)
           └──► safarium-forge (Single unified CLI + JSON Graph runner, scheduled via `safarium-render forge`)
                   └──► sdk/{python,node,shell} (Zero-dependency thin wrappers for all 49 projects)
```

## 3. Core Subsystems & Breakthrough Mechanisms

### 3.1 `SafariumContainers` (Breaking Format & Codec Walls)
1. **Pure-Swift EBML / Matroska (`MKV` & `WebM`) Streaming Demuxer & Muxer (`EBMLMatroska.swift`):**
   - Streaming VINT parser & writer (including `0x01FFFFFFFFFFFFFF` unknown-size clusters/segments).
   - Codec support: `V_MPEG4/ISO/AVC` (`avcC`), `V_MPEGH/ISO/HEVC` (`hvcC`), `V_VP9`, `V_AV1` (`av1C`), `A_AAC` (`AudioSpecificConfig`), `A_OPUS` (`OpusHead`), `A_PCM/INT/LIT`, `S_TEXT/UTF8`.
   - Empirically verified CoreMedia round-trip fixes (`05-wall-breakers-poc.md` PoC 1):
     - Multi-packet audio `CMSampleBuffer` splitting via `CMSampleBufferGetSampleSizeArray` / `CMSampleBufferGetSampleTimingInfoArray`.
     - B-frame pyramid monotonic `DTS` reconstruction (`sortedVPTS[i] - maxShift`) AND subtracting `minVPTS` before `AVAssetWriter` `.mp4` output (eliminating the `31 -> 30` preroll duplicate frame bug).
     - Wrapping raw 2B `AudioSpecificConfig` into a valid `ES_Descriptor` for `CMAudioFormatDescriptionCreate`.
2. **Pure-Swift `188`-Byte MPEG-TS Demuxer & Muxer (`MPEGTSContainer.swift`):**
   - Spec-compliant `0x47` TS packetizer/depacketizer, PAT (`0x0000`) & PMT (`0x1000`) with big-endian **CRC-32/MPEG-2**, PCR adaptation fields, PES headers (`0xE0` video, `0xC0` audio), `33`-bit 90 kHz wraparound `PTSUnwrapper`.
   - Bi-directional **Annex-B <-> AVCC/HVCC** NAL converter (stripping AUD/SPS/PPS/VPS into `CMVideoFormatDescriptionCreateFromH264ParameterSets`/`HEVCParameterSets` on demux; injecting AUD+SPS/PPS/VPS on IDRs during mux) + **7-byte ADTS <-> raw AAC** framing. Supports both `0x1B` (H.264) and `0x24` (HEVC) that Apple's local `AVURLAsset` drops.
3. **Pure-Swift Lossless WebP (`VP8L` RIFF) & `ImageIO` AVIF / HEIC (`WebPAVIFEncoder.swift`):**
   - Pure-Swift RFC 9649 **`VP8L`** lossless bitstream encoder (LSB bit-writer, `SubtractGreen` transform, RLE LZ77, 15-bit/7-bit Package-Merge canonical Huffman) writing both static (`RIFF WEBP VP8L`) and animated (`VP8X + ANIM + ANMF`) WebP images verified byte-for-byte via Apple `ImageIO` decode.
   - Native **`ImageIO` AVIF / HEIC / HEICS** encoder: supports `public.avif` (`q < 1.0`, opaque & alpha), `public.heic`, and `public.heics` (explicitly rejecting invalid requests like animated `avif` or lossless `q=1.0` `avif` with structured `SafariumError` rather than silent distortion).
4. **`MediaCompatBridge.swift` (OS Decoder Unlockers & Subtitle/Audio Bridges):**
   - Calls `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)` once via static initializer; builds 12-byte ISO BMFF `vpcC` FullBox (`01 00 00 00 ...`) for WebM `V_VP9` `VTDecompressionSession` hardware decoding; supports `av01` hardware decoding (`VTIsHardwareDecodeSupported`).
   - `AudioToolbox` / `AVAudioFile` universal decoder to streamed `Float32` PCM (`48 kHz` or requested rate) covering `.mp3`, `.flac`, `.caf`/Opus, `.mp4`/Opus, `.wav`, `.m4a`, `.aiff` (catching `.ogg` Vorbis/Opus honestly if OS lacks container support).
   - Lossless MP3 packet splitter via `AudioFileOpenURL` / `AudioFileReadPacketData` (for `Pain point` 20-minute chunk splits without `libmp3lame`!).
   - Recursive **Safari Bug `302253` `39B`/`76B` `ESDS` unwrapper** (`03 -> 04 -> 05 -> raw 2B ASC`) + File-based `fMP4` (`movieFragmentInterval`) `'tx3g'` & HLS `.vtt` sidecar support.

### 3.2 `SafariumForgeCore` (Unified Zero-Copy Apple Silicon Engine)
1. **`ForgeRecipe.swift` & `ForgeGraphExecutor.swift` (Declarative Zero-Copy DAG):**
   - Compiles JSON graph upfront before Frame 0: enforces positive even dimensions for YUV, `Fix A (ITU_R_709_2 + Left)` colorimetry, **1× Text/DOM Shield** (blocking any scaler downstream of sharp Thai typography), bounded ring buffer (`<= 4` `IOSurface`-backed `CVPixelBuffer` slots), per-frame `autoreleasepool` + `CVMetalTextureCacheFlush`, `InputReadyGate` backpressure, and `ProcessInfo.thermalState` pacing without quality loss.
   - Dual-output tee support (`ProRes 4444` alpha `.mov` + composited `H.264` `.mp4` in ONE pass for `Sanook Theme` & `Capcut Skill`).
   - Direct streaming `rawFrameStream` (`pipe-encode`: `rgb24`/`bgr24`/`rgba`/`bgra` binary pipe or unlinked `SCM_RIGHTS` `mmap` ring) writing straight into pooled `IOSurface` `CVPixelBuffer`s.
2. **`APFSAutoStage.swift` (`ExFAT` an external ExFAT volume Zero-Failure Accelerator):**
   - Queries `statfs` + `getattrlist` on target path. If target lacks `VOL_CAP_INT_CLONE` / `VOL_CAP_INT_RENAME_EXCL` (`exfat` an external ExFAT volume), stages intermediate multi-pass caches, `+faststart` rewrites, and closed-GOP segments inside private `0700` `~/Library/Caches/com.safarium.forge-stage/<uuid>/` on APFS (`0.25 ms` `clonefile`), then publishes atomically via `SafeFilePublisher` with zero `._*` AppleDouble pollution.
3. **`ForgeMetalFilters.swift` (Single-Init TBDR Metal 4 / CoreImage Pipeline):**
   - Single-init `device.makeLibrary(source:)` + `MTLBinaryArchive` cache (no runtime `xcrun metal` needed).
   - Operations on `IOSurface`-backed textures: `geom` (`scale`, `crop`, `pad`, `rotate`, `flip`), **`deinterlace`** (motion-adaptive TFF/BFF replacing `bwdif`), **`kenBurns`** (sub-pixel GPU pan/zoom with zero `8000 px` RAM bloat), **`chromaKey`** (HSV/YCbCr key + luma-preserving green/blue `despill` + morphological disk `erode`!), `gblur`, `colorGrade` (`brightness`, `contrast`, `saturation`, `gamma`, `grayscale`), `lut3d` (`.cube` parser -> `MTLTexture` `type3D`), `vignette`, `grain`, **`overlay` / `blend` / `xfade` / `hstack` / `vstack`** with typed math expressions (`x(t), y(t), opacity(t), scale(t), enable(t)`) and `LRU <= 4` texture cache, plus `Wave2MetalEffects` (`paperCutout`, `markerTexture`, `tmix`, Split `MetalFX` + `1×` Thai shield).
4. **`ForgeANE.swift` (Apple Neural Engine Exclusives):**
   - **`autoReframe`:** `420v` Plane-0 cut detector (`MAD`) + `VNGenerateAttentionBasedSaliencyImageRequest` / `VNDetectFaceRectanglesRequest` keyframe detection + `VNTrackObjectRequest` tracking + EMA low-pass smoothing + dead-zone hysteresis + hard tracker reset on shot cuts (`16:9 -> 9:16` / `1:1`).
   - **`personMatte`:** `VNGeneratePersonSegmentationRequest` / `VNGenerateForegroundInstanceMaskRequest` (`[ANE, GPU]`) + temporal EMA alpha mask smoothing (`α=0.35`) + direct BG replace or `HEVCWithAlpha` (`muxa`) / `ProRes 4444` output.
   - **`SafariumPQ`:** Inline & standalone ANE `VNGenerateImageFeaturePrintRequest` (`usesCPUOnly = false`, `~5.59 ms`) + Metal 5-scale `MS-SSIM` + Metal Sharma-2005 `CIEDE2000` `mean` & `p95` (`~7.09 ms`) + optional `VNRecognizeTextRequest` `.accurate` Thai OCR hard gate -> calibrated `0..100` perceptual index (`pass` gate requires `dE00 p95 <= maxDeltaE00P95` and optional Thai OCR match!).
5. **`ForgeAudioDSP.swift` (`O(4096)` Streaming AMX `Accelerate` DSP):**
   - Zero full-track buffers, zero `areverse` OOMs:
     - `vDSP_biquadD` double-precision parametric EQ, highpass, lowpass (`max_abs_error = 0.0`).
     - Streaming `acrossfade` (triangular/equal-power crossfade) + zero-fill silence splice.
     - Procedural `vDSP` synth (`sine`, `pinkNoise`, AM pad replacing `aevalsrc`/`sine`!).
     - RMS compressor + `SidechainDucker` + `LoudnessMeter` (BS.1770-4 gated LUFS/LRA/`4×` `dBTP`) + `OfflinePeakLimiter`.
     - Two-cursor **`silenceTrim`** (`vDSP_measqv` envelope scan records active `[start, end]` bounds in `O(4096)` RAM, trims via `AVAssetReader.timeRange` without reversing samples in RAM!).
     - Live-ready persistent waveform peak extractor (`60..600` bins in `O(4096)` RAM for `Ripr.app`).
6. **`ForgeSheetAndQA.swift` & System WebKit Layer:**
   - Flexible `contactSheet` (`cols × rows`, padding/bg color, `--every N` frames or `--timestamps`, decoded `PTS` JSON sidecar, ref-vs-ours comparison strips) + structured `qa` (`black`, `freeze`, `scene`, `silence`, `BS.1770-4`, `dBTP`).
   - Headless System `WKWebView` layer (`Mode C` dirty probe, `200f` serial recycle, zero Chromium, zero focus steal).

### 3.3 `safarium-forge` CLI + Queue + 3-Language SDK + 49-Project Rollout
- **CLI Modes:** `run --recipe <json|->`, `validate --recipe <json>`, `capabilities`, `remux`, `transcode`, `filter`, `pipe-encode`, `audio`, `ai-reframe`, `ai-matte`, `webp`, `pq`, `sheet`, `web-overlay`, `extract`, `probe`, `qa`, `split-mp3`.
- **Queue (`bin/safarium-render` + `Tools/install-render.py`):** Registered as native `forge` mode (`SF-VIDEO-1` single foreground slot, exit cleanly after every invocation, signed/verified Apple-only Mach-O).
- **Zero-Dependency SDKs (`sdk/`):** Python (`sdk/python/safarium_forge.py`), Node ESM (`sdk/node/safarium-forge.mjs`), Shell (`sdk/shell/safarium-forge.sh`), supporting fluent `ForgePipeline` graph building + short CLI methods + transparent nested-slot fallback (`returncode == 64` -> `libexec/safarium/safarium-forge`).
- **Browser Split Rule (Milestone 2 Handoff):** Graphic HTML/Canvas/WebGL/Three.js/PixiJS renders go to `safarium-forge`; interactive Chrome scraping/clicking in `Blender Work`, `Cua For Facebook`, `Drama`, `Javis`, `lemo-opuscar/films/ck-fastwork/tools/clip.mjs`, and E2E suites remain documented `cua-go` Safari targets (0 edits to `cua-go` in this wave).

## 4. Edge Cases & Error Contracts
- **Empty Inputs:** `0`-frame video, `0`-byte WAV/MP3/MKV/TS, empty SRT, or `0×0` WebP throw explicit `SafariumError` with non-zero CLI exit without leaving orphan temp files.
- **Thai & Unicode:** Filenames containing Thai characters/trailing spaces (e.g., `น้องถังแก๊สเดินได้ `), UTF-8 `S_TEXT/UTF8` / `.srt` Thai captions, and `WKWebView` complex vowels/tone marks preserve `1×` resolution upstream/downstream shield (tested by ANE `SafariumPQ` + Thai OCR).
- **Timestamps & B-Frames:** MKV decode-order B-frames reconstruct monotonic `DTS` and zero-align `minVPTS` to avoid preroll duplicates; MPEG-TS `33`-bit 90 kHz timestamps unwrap cleanly across rollover boundaries.
- **Large 600f+ Streams & Concurrency:** Streaming Demux/Mux, `O(4096)` Audio DSP, `O(1)` 4-slot `IOSurface` ring, per-frame `autoreleasepool` + `CVMetalTextureCacheFlush`, and single-slot `safarium-render` FIFO serialization guarantee bounded memory even on long episodes and ExFAT targets.
- **external ExFAT volume & Error Paths:** Every output goes through `APFSAutoStage` + `SafeFilePublisher` (`!overwrite` strictly preserves existing files and refuses symlinks cleanly). OS encoder absences (`AV1`/`VP9` encode, `MP3` encode, `AVIF q=1.0`, `AVIF` animated) fail loudly with explicit `SafariumError.unsupported(...)` messages explaining valid native alternatives (`HEVC`/`HEIC`/`VP8L` WebP/`AAC`).

