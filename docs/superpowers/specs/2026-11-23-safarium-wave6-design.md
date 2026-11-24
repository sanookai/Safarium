---
tags: [safarium, wave6, design-spec, ai-control, containers, vorbis, mpeg2, adaptive-pool, image-sequence]
note_type: spec
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# Safarium Wave 6 Design Spec — Full-Stack Superpowers, AI Terminal Control, Legacy Pure-Swift Decoders & Batch 2 Verification

> **Design Basis (Pick's Locked Choices `2026-11-23 19:08–19:22`):**
> 1. **Milestone 2 (`cua-go`) permanently cancelled** — supersede `2026-11-22` decision row in `decisions.md`, remove from `current-state.md`, focus 100% on `Safarium`.
> 2. **Approach A (Full-Stack Wave 6 in 3 sequential phases):** Combine `(1)` Core Engine Superpowers + `(2)` Batch 2 `/tmp` Real-Project A/B Benchmarks + `(3)` AI-First Terminal Control Plane (no web UI) + `(4)` Apple-Silicon R&D.
> 3. **Pure-Swift Ogg Vorbis I Decoder R&D (+ MPEG-2 PS & Ogg FLAC)** inside `Sources/SafariumContainers/` (`0%` FFmpeg, `0%` third-party C libs, `otool -L` strictly Apple-only), numerically verified (`Pearson r >= 0.999`) against real project assets.
> 4. **Opt-In Adaptive Multi-WebKit Pool (`--adaptive-workers --budget-mb`):** Strictly `workers = 1` default (`SF-VIDEO-1` RAM guarantee); scale 2..N dynamically inside the single FIFO slot only under strict `ri_phys_footprint` + thermal ceilings + closed-GOP lossless stitch; promote only after M5 verification.
> 5. **Global `safarium` AI Skill:** Create `skills/safarium/SKILL.md` + `docs/ai-control-protocol.md` and install into `~/.claude/skills/safarium/SKILL.md` & `~/.gemini/config/skills/safarium/SKILL.md`.
> 6. **Quality & Isolation Bar:** Beat FFmpeg/Chrome on BOTH RAM and speed (`SafariumPQ >= 85`, `msSSIM >= 0.97`, `ΔE00 p95 <= 2.0`, `thaiOCROK = true`), ZERO edits to external project files, ZERO Chrome/FFmpeg invocations in benchmarks.

---

## 1. Phase 1 Architecture — Vault Alignment, Bug Fixes & AI Terminal Control Plane

1. **Bug Fixes (`SafariumForgeCore`, `Tools/safarium-verify.swift`):**
   - Implement `.whiteNoise(seed:)` in `ForgeProceduralSynth` (`ForgeAudioDSP.swift:286-300`).
   - Replace per-frame `AVAssetWriterSink.allocateStandalonePixelBuffer` inside `ForgeGraphExecutor` `.deinterlace` (`L1322`) with 2 pooled ping-pong history buffers.
   - Add per-track `startSeconds: [Double]?` (`adelay`), `fadeInSeconds`/`fadeOutSeconds`, `trimStartSeconds`/`trimEndSeconds`, `padToDurationSeconds`, `tempoRate` to `ForgeAudioOp` and wire into `AudioMixer` + 4× oversampled true-peak limiter ceiling.
   - Allow `"muxa"` fourCC in `Tools/safarium-verify.swift` (`isAlpha = true`).
2. **AI-First Terminal Control Plane (`bin/safarium-render`, `SafariumCore/Errors.swift`, `safarium-forge`, `safarium-html`, `safarium-media`):**
   - Strictly read-only FIFO bypass in `bin/safarium-render` (`status`, `doctor`, `capabilities`, `version`, `forge schema|validate|inspect|probe|capabilities|version`, `forge cache stats`, `forge run --dry-run`); mutating/render/WebKit/Blender paths ALWAYS acquire the exclusive `SF-VIDEO-1` FIFO slot.
   - `safarium-render doctor --json`: single-call environment, queue, orphan process, Apple-only Mach-O linkage, ExFAT/APFS disk, thermal, and tool availability audit.
   - `SafariumErrorCode` structured error envelopes (`E_*` + `recoverable` + `hint`), `--progress jsonl` stderr telemetry, `safarium-forge schema`, `safarium-forge run --dry-run`, `safarium-html --hash --json`, `status --json-detail`.
3. **Contracts & Determinism:**
   - `ClockTests` upgraded from 4/60 sampled frames to all **60/60 frames** rolling SHA-256 across 3 runs + 3-run `safarium-html --hash` CLI verification (`P1-E`).
   - HyperFrames `S3`/`S5`: `Tests/hf/hf-compat.json` + zero-FFmpeg `Tests/hf/hf-contract-test.py` exercising `bin/safarium-hf` (`0.9.72`).

## 2. Phase 2 Architecture — Core Superpowers & Next-Gen Apple Silicon R&D

1. **Native `ImageIO` Sequence Ingest & Inline Sheet Tee (`ForgeSequenceIngest.swift`, `ForgeSheetAndQA.swift`):**
   - Bounded 2–3 slot concurrent `CGImageSource` decode-ahead into Metal/IOSurface `CVPixelBufferPool` (zero Python/PIL buffer copies, skips ExFAT `._*`).
   - `ForgeInlineSheetCollector` downscales sampled frames directly from in-flight BGRA `CVPixelBuffer`s during encode (**zero 2nd `AVAssetReader` decode pass**), unlocking faster-than-FFmpeg + `-84%` RAM on `Cut Something` and single-pass `Stickman Fighting`.
2. **Flexible `PrismWebKit3D`, Local Font Loopback, Metal SVG Surgery & `batch-dom`:**
   - Configurable `--ready-expr`, `--init-js`/`--init-file`, `--seek-expr`, `--output-fps`, `--grain`, inline 2-pass `loudnorm`+`apad`, validated sandboxed `--font-dir` on `127.0.0.1` loopback HTTP, `--metal-svg-filters` DOM surgery (`W2-4B`), and `safarium-forge batch-dom` warm auto-bbox PNG batcher.
3. **Graph/Dual-Tee Completeness & Wave 1/2 Apple-Silicon Winners:**
   - `ForgeTimeExprParser` `lt`/`lte`/`gt`/`gte`/`eq`, `.geom` `aspectFill`, `ptsFactor` (`setpts`), `holdTailSeconds` (`tpad`), `monochromeCheck`, Dual-Tee `--primary-audio-codec pcm_s16le`, `transcode --max-bytes`, `ForgeIncrementalCache` (Closed-GOP APFS `clonefile` scene cache wiring dead fields `ForgeRecipe.swift:183-184`), `memflush`, `RGBA16F` `tmix`, `K.grief`, double-buffered async Metal, `#available`-guarded `LLSR` upscaler with `SafariumPQ` 1× auto-fallback, bounded animated WebP/HEICS memory cap.
4. **Pure-Swift Wall-Breakers (`SafariumContainers/`):**
   - `MPEG2ProgramStream`: Pure-Swift MPEG-2 PS demuxer -> VideoToolbox `kCMVideoCodecType_MPEG2Video` decode.
   - `OggContainer`: RFC 3533 Ogg page parser + CRC-32 + Ogg FLAC -> native FLAC bridge.
   - `OggVorbisDecoder`: Pure-Swift Vorbis I specification decoder (`Codebooks`, `Floor 0/1`, `Residue 0/1/2`, `Mappings` polar coupling, `Accelerate/vDSP` `vDSP_fft_zrip` `N/4`-pt IMDCT + windowing + overlap-add, streaming `O(blocksize)` PCM blocks).
5. **Opt-In Adaptive Multi-WebKit Pool (`ForgeAdaptiveWebKitPool.swift`):**
   - `--adaptive-workers <N> --budget-mb <MB>` (`1` strictly default), runtime `ri_phys_footprint` + `thermalState` scaling & auto-drain + lossless `ClosedGOPStitcher`.

## 3. Phase 3 Architecture — Release Gate, `/tmp` Batch 2 A/B, Global Skill & Audit

- Release build (`swift test` 0 failures across all 6 Swift test targets), `Tools/install-render.py`, `otool -L` Apple-only `4/4`, 9-step `verify-shared-standard.py ALL_PASSED`, `hf-contract-test.py`, `doctor --json` healthy.
- Sequential quiet-Mac M5 `/tmp/safarium-wave6-ab/` A/B runs vs existing project references (`Cut Something`, `เรื่องเงินเงินทองทอง`, `lemo-opuscar`, `เข้าใจตัวเองเเล้วหรือยัง?`, `Sanook Theme`, `Do Not Do`, `Stickman Fighting`, `ห้วงเวลาขาวดำ`, `สำรวจไปกับสมพง`, Closed-GOP Incremental Cache, Adaptive Pool, `P1-E` 3-run `--hash`), archived to `bench/experiments/2026-11-23-wave6-real-ab/`.
- `skills/safarium/SKILL.md` + `docs/ai-control-protocol.md` + installed copies in `~/.claude/skills/safarium/` and `~/.gemini/config/skills/safarium/`.
- `code-reviewer` + `security-auditor` sign-off -> final QA -> Vault sync & Session Log.

