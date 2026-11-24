---
tags: [safarium, safarium-forge, plan, tdd, zero-copy]
note_type: plan
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# `safarium-forge` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Follow strict TDD (`test -> RED -> minimal implementation -> GREEN -> verify`). Complete every task against exact public signatures below with ZERO placeholders (`TBD`/`TODO` forbidden) and ZERO forbidden binaries (`ffmpeg`, `ffprobe`, `libav*`, `Chrome`, `Chromium`, `Playwright`).

**Goal:** Build and install `safarium-forge` — a unified zero-copy Apple Silicon macOS-exclusive media engine (`SafariumContainers` + `SafariumForgeCore` + `safarium-forge` CLI + `safarium-render forge` queue + Python/Node/Shell SDKs + 3 representative `/tmp` dry-runs + real M5 benchmarks) eliminating FFmpeg/Chrome dependencies across all 49 Vault Tier 1 & Tier 3 projects.

**Architecture:** Modular SwiftPM libraries (`SafariumContainers`, `SafariumForgeCore`) atop existing `SafariumCore`, consumed by executable `safarium-forge` (single binary with short CLI subcommands + declarative `run --recipe <json>` Zero-Copy IOSurface Pipeline Graph), registered in `bin/safarium-render` (`SF-VIDEO-1` single foreground slot) and `Tools/install-render.py` (`otool -L` Apple-only), and distributed via zero-dependency `sdk/{python,node,shell}`.

**Tech Stack:** Swift 5.9+, macOS 14+ (`MacOSX27.2.sdk` on M5), `AVFoundation`, `VideoToolbox`, `AudioToolbox`, `CoreMedia`, `CoreVideo` (`IOSurface`), `Metal`, `MetalFX`, `CoreImage`, `Vision` (ANE), `Accelerate` (`vDSP`/`vImage`/`vForce`), `CoreGraphics`, `ImageIO`, `WebKit`.

**Spec:** [`docs/superpowers/specs/2026-11-23-safarium-forge-design.md`](../specs/2026-11-23-safarium-forge-design.md)
**49-Project Dissection:** [`docs/49-projects-deep-dissection-2026-11-23.md`](../../49-projects-deep-dissection-2026-11-23.md)
**Empirical Wall-Breaker PoCs:** [`research_notes/2026-11-23-safarium-forge/05-wall-breakers-poc.md`](../../../research_notes/2026-11-23-safarium-forge/05-wall-breakers-poc.md)

## Global Constraints
- Platform floor: `.macOS(.v14)`. Zero third-party Swift/Python/Node dependencies (`otool -L` Apple system libs only).
- ExFAT safety: an external ExFAT volume lacks `clonefile` and `RENAME_EXCL`; build scratch on internal APFS (`/tmp/...`) and use `APFSAutoStage` + `SafeFilePublisher`.
- Re-use existing `SafariumCore` primitives (`SafeFilePublisher`, `AVAssetWriterSink`, `SafariumAccelerate`, `LoudnessMeter`, `OfflinePeakLimiter`, `SidechainDucker`, `AudioMixer`, `LosslessSoundtrackMux`, `ClosedGOPStitcher`, `PacketProbe`, `NativeQAAnalyzer`, `FrameExtractor`, `Wave2MetalEffectsEngine`, `SafariumHybridCompositor`, `SafariumMetalContext`, `SafariumTX3G`, `SafariumSequentialVideoReader`, `WarmWorkerServer`, `SafariumError`). Do NOT duplicate their logic.
- WebKit 1× Thai Shield: `htmlOverlay`/`CoreText` text rendering MUST stay downstream of any spatial scaler (`MTLFXSpatialScaler` / `autoReframe`).
- All `safarium-render` CLI / benchmark runs execute strictly sequentially (one foreground job at a time).
- Non-Safarium production files (the 49 projects and `cua-go`) are STRICTLY READ-ONLY; representative integrations run only in `/tmp/safarium-forge-demos/`.

---

## Shared Cross-Module Contracts (`SafariumContainers` -> `SafariumForgeCore` -> `safarium-forge`)

### Contract 1: `Sources/SafariumContainers/ContainerInterfaces.swift` (Locked Interface Types)
- `public enum ContainerFormat: String, Codable, Sendable { case mp4, mov, mkv, webm, ts, m4a, wav, mp3, flac, caf, webp, avif, heic, heics, gif, png, jpg }`
- `public enum ContainerTrackKind: String, Codable, Sendable { case video, audio, subtitle }`
- `public struct ContainerTrackInfo: Codable, Sendable`: `trackNumber: Int`, `kind: ContainerTrackKind`, `codecID: String`, `width: Int?`, `height: Int?`, `sampleRate: Int?`, `channels: Int?`, `language: String?`, `codecPrivate: Data`
- `public struct DemuxedPacket: Sendable`: `trackNumber: Int`, `kind: ContainerTrackKind`, `pts90k: Int64`, `dts90k: Int64`, `duration90k: Int64`, `isKeyframe: Bool`, `data: Data`
- `public struct RemuxReport: Codable, Sendable`: `inputPath: String`, `outputPath: String`, `sourceContainer: String`, `targetContainer: String`, `videoPackets: Int`, `audioPackets: Int`, `subtitleCues: Int`, `wallMs: Double`
- `public struct WebPEncodeReport: Codable, Sendable`: `outputPath: String`, `width: Int`, `height: Int`, `frameCount: Int`, `animated: Bool`, `bytes: Int`, `wallMs: Double`
- `public struct SplitAudioReport: Codable, Sendable`: `inputPath: String`, `outputDir: String`, `chunkSeconds: Double`, `chunks: [String]`, `wallMs: Double`
- Static entrypoints produced by `SafariumContainers`:
  - `EBMLMatroskaCodec`: `inspect(url:)`, `demuxToMP4(inputURL:outputURL:overwrite:)`, `muxFromMP4OrMOV(inputURL:outputURL:docType:overwrite:)`
  - `MPEGTSCodec`: `inspect(url:)`, `demuxToMP4(inputURL:outputURL:overwrite:)`, `muxFromMP4OrMOV(inputURL:outputURL:overwrite:)`
  - `WebPAVIFEncoder`: `writeLosslessWebP(images:to:loopCount:overwrite:)`, `writeStillImage(cgImage:format:quality:to:overwrite:)`, `writeHEICSSequence(images:quality:loopCount:to:overwrite:)`
  - `MediaCompatBridge`: `registerSupplementalDecoders()`, `supportsHardwareDecode(fourCC:)`, `supportsHardwareEncode(fourCC:)`, `unwrapWebCodecsESDS(_:)`, `makeVPCCFullBox(...)`, `makeESDescriptorWrappingASC(_:)`, `decodeAudioToFloat32PCM(...)`, `splitMP3PacketsLosslessly(...)`

---

## Tasks

### Task 1: `SafariumContainers` Module (`forge-containers`)
**Files:**
- Modify/Create inside `Sources/SafariumContainers/`:
  - `EBMLMatroska.swift`
  - `MPEGTSContainer.swift`
  - `WebPAVIFEncoder.swift`
  - `MediaCompatBridge.swift`
- Test: `Tests/SafariumContainersTests/ContainerTests.swift`

- [ ] **Step 1 (RED):** Write `ContainerTests.swift` covering MKV/WebM round-trip + Thai UTF-8, MPEG-TS `0x1B`/`0x24` + 33-bit wrap round-trip, Lossless `VP8L` WebP static+animated `0`-diff verify + `ImageIO` AVIF `q=0.80` vs `q=1.0` failure, `VTRegisterSupplementalVideoDecoderIfAvailable`, `39B`/`76B` ESDS unwrap, AudioToolbox `.mp3`/`.flac` decode, and lossless MP3 split.
- [ ] **Step 2:** Implement `EBMLMatroska.swift`, `MPEGTSContainer.swift`, `WebPAVIFEncoder.swift`, `MediaCompatBridge.swift` reusing `SafeFilePublisher` and verified byte specs from `05-wall-breakers-poc.md`.
- [ ] **Step 3 (GREEN):** Run `swift test --filter SafariumContainersTests` -> 0 failures.

### Task 2: `SafariumForgeCore` Module (`forge-engine`)
**Files:**
- Create inside `Sources/SafariumForgeCore/`:
  - `ForgeRecipe.swift` (Declarative DAG JSON schema + upfront graph validator including 1× Thai shield & odd-dim guards)
  - `APFSAutoStage.swift` (`statfs` + `getattrlist` ExFAT->APFS CoW auto-stager + `clonefile`)
  - `ForgeMetalFilters.swift` (`MTLComputePipelineState` library + `CVMetalTextureCache` single-pass shaders: `geom`, `deinterlace` TFF/BFF, `kenBurns`, `chromaKey`+`despill`+disk `erode`, `gblur`, `colorGrade`, `lut3d` `.cube`, `vignette`, `grain`, `overlay`/`xfade`/`hstack`/`vstack` math expr + `Wave2MetalEffects`)
  - `ForgeANE.swift` (`autoReframe`, `personMatte` w/ EMA, and **`SafariumPQ`** ANE FeaturePrint + Metal 5-scale MS-SSIM + Metal Sharma-2005 `CIEDE2000` `mean`/`p95` + optional `VNRecognizeTextRequest` Thai OCR)
  - `ForgeAudioDSP.swift` (`vDSP_biquadD` HPF/LPF/EQ, `acrossfade`, procedural `vDSP` synth `sine`/`pinkNoise`, `silenceTrim` 2-cursor `O(4096)` avoiding `areverse`, waveform bins `O(4096)`, BS.1770-4 / `PeakLimiter` / `SidechainDucker`)
  - `ForgeSheetAndQA.swift` (`contactSheet` custom grid/pad/every-frames/PTS JSON + ref-vs-cand strip + `qa` fault detector)
  - `ForgeGraphExecutor.swift` (Unified zero-copy graph compiler/runner: `IOSurface` <=4-slot ring, `autoreleasepool`, `InputReadyGate`, thermal governor, headless `WKWebView` `Mode C` layer, dual ProRes4444+H.264 tee output, `pipeEncode` raw stream receiver)
- Test: `Tests/SafariumForgeTests/ForgeEngineTests.swift`

- [ ] **Step 1 (RED):** Write `ForgeEngineTests.swift` testing recipe validator, `APFSAutoStage`, `ForgeMetalFilters`, `ForgeANE` (`SafariumPQ` blur/color/Thai discrimination + `autoReframe` + `personMatte`), `ForgeAudioDSP`, and full multi-stage `ForgeGraphExecutor` (`video` + `metal` + `WKWebView` Thai + `audioDSP` + inline `SafariumPQ` -> `.mp4` + `pipeEncode` dual `.mov`/`.mp4`).
- [ ] **Step 2:** Implement the 7 focused files cleanly, reusing `SafariumCore` & `SafariumContainers`.
- [ ] **Step 3 (GREEN):** Run `swift test --filter SafariumForgeTests` -> 0 failures.

### Task 3: `safarium-forge` CLI, `safarium-render forge` Queue, Installer, 3-Language SDK & 3 Project Dry-Runs (`forge-cli-sdk`)
**Files:**
- Create/Modify:
  - `Sources/safarium-forge/main.swift`
  - `bin/safarium-render` (`forge` mode + `HELP`)
  - `Tools/install-render.py` (`libexec/safarium/safarium-forge` + `otool -L`)
  - `Tests/queue/test_queue.py` (`test_forge_pins_safarium_forge_through_same_slot`)
  - `sdk/python/safarium_forge.py`, `sdk/node/safarium-forge.mjs`, `sdk/shell/safarium-forge.sh`, `sdk/README.md`
  - `docs/safarium-forge-guide-2026-11-23.md`
  - Scratch dry-runs ONLY in `/tmp/safarium-forge-demos/`

### Task 4: Independent Verification, Release Install & Real M5 Benchmarks (`forge-verifier`)
- Release build (`/tmp/safarium-forge-release/build`) -> `install-render.py` + `--check` -> `otool -L` Apple-only on ALL 4 binaries -> `swift test -j 3` -> `Tests/queue/test_queue.py` -> `Tests/verify-shared-standard.py --swift --rules` -> Real M5 Benchmarks (`bench/experiments/2026-11-23-safarium-forge/results.json`) -> external ExFAT volume direct-write smoke -> SDK tests -> idle queue & zero focus steal.

