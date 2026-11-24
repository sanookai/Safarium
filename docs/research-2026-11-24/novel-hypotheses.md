---
tags: [safarium, rd, hypotheses, benchmarks, apple-silicon, sf-video-1]
note_type: research
project: "Safarium"
created: 2026-11-24
updated: 2026-11-24
---

# Safarium Falsifiable World Hypotheses (`H1–H7`) & `/tmp` Benchmark Protocol (2026-11-24)

> **Execution Scope for `bench-lab`:** All head-to-head runs MUST execute **strictly inside `/tmp/safarium-world-rd/`** (`0%` writes to external Vault projects; `0%` FFmpeg/Chrome/OpenCV in Safarium production code). Every Safarium invocation runs through `"$HOME/.local/bin/safarium-render"` (`SF-VIDEO-1` single-slot FIFO), and external baseline comparisons (`ffmpeg`, `x264`, `x265`, `SvtAv1EncApp`, `npx hyperframes`, `cv2`) run sequentially—**never nested** inside `safarium-render run --` if the child invokes `safarium-render`, and never concurrently with active Safarium renders.

---

## Global Measurement Invariants & 4-Metric Acceptance Rubric

| Metric | Measurement Method (Mandatory) | Win / Tie / Lose Criteria |
|---|---|---|
| **1. Peak RAM [Primary]** | `libproc` `proc_pid_rusage(RUSAGE_INFO_V6)` `ri_phys_footprint` sampled every `50 ms` across the **entire process tree** (`rootPID` + `WebContent` / `VTEncoderXPCService` / Chrome Renderer+GPU / FFmpeg children) **PLUS** `/usr/bin/time -l` (`maximum resident set size`). Report BOTH; the **worse** verdict governs (never cherry-pick RSS when Metal/IOSurface wires GPU footprint!). | **WIN:** Safarium peak $\le 0.90\times$ competitor (and $\ge 1\text{ MiB}$ delta).<br>**TIE:** Within $0.90\times\text{–}1.10\times$ or $<1\text{ MiB}$.<br>**LOSS:** $\ge 1.10\times$ competitor. |
| **2. Speed** | Fresh subprocess per trial, alternating `A/B/B/A` order, `load1 < 4.0` (`> 8.0` waits; `> 4.0` marked provisional), `60 s` thermal cooldown between blocks, median + IQR / 95% CI over $N \ge 5$ (video renders) or $N \ge 15$ (raster ops). | **WIN:** Safarium median wall time $\le 0.90\times$ competitor (or $\ge 1.10\times$ speedup) with non-overlapping CIs.<br>**LOSS:** $\ge 1.05\text{–}1.10\times$ slower. |
| **3. Equal-SSIM File Size** | Sweep quality/bitrate/CRF/CQF knobs; interpolate output bytes at matched **SSIM = `0.97` / `0.99`** (and `PSNR = 35 dB`) decoded by a **neutral third-party decoder** (`ImageIO`/`AVAssetReader` for video; `Pillow` for still images) + compute Bjontegaard **BD-Rate**. | **WIN:** BD-Rate $\le -5\%$ (bytes $\le 0.95\times$ at equal SSIM).<br>**TIE:** Within $\pm 5\%$.<br>**LOSS:** BD-Rate $\ge +5\%$. |
| **4. Quality Gate (`SF-VIDEO-1`)** | `SafariumPQ` + reference `float64` verification: **`SSIM >= 0.97`**, **`PSNR >= 30 dB`**, **`ΔE00 p95 <= 2.0`**, plus **Vision `th-TH` Thai OCR `100%`** on all Thai text fixtures. | **HARD GATE:** Any candidate failing quality is automatically **LOSE / DISQUALIFIED** regardless of RAM or speed wins. Never lower thresholds silently. |

### Local Tool Availability Probe (Verified `2026-11-24` on Apple M5 `Mac17,3` · macOS `27.2`)
- **Installed today:** `ffmpeg`, `x264`, `x265`, `SvtAv1EncApp`, `cwebp`, `avifenc`, `magick`, `blender`, `npx`, `python3`, `swift`, `$HOME/.local/bin/safarium-render`.
- **Optional (install in Homebrew or skip cleanly with explicit `SKIPPED_UNINSTALLED` status if missing):** `gst-launch-1.0` (`gstreamer`), `cjxl` (`jpeg-xl`), `vips` (`libvips`), `oxipng`, `zopflipng`, plus `hyperframes@0.9.72` / `remotion` in `/tmp/safarium-world-rd/node_tools/` and `opencv-python-headless==5.1.0.95` + `scipy` in `/tmp/safarium-world-rd/venv/`.

---

## Hypothesis H1: Windowless WebKit→Metal→VideoToolbox vs Chrome / HyperFrames / Remotion

- **Target Claim:** On `1080×1920` `30 fps` HTML/CSS/GSAP/Canvas2D scenes with Thai typography, Safarium's windowless `WKWebView` + persistent Metal `CIContext` + single-pass interleaved `AVAssetWriter` (`--hybrid-layers` / `Mode C` where applicable) uses **$\ge 50\%$ less Peak `ri_phys_footprint`** (`<= 0.50x`) and runs **faster (`>= 1.5x`)** than Headless Chromium (`HyperFrames 0.9.72` / `Remotion` + FFmpeg) while achieving `SSIM >= 0.97`, `PSNR >= 30 dB`, `ΔE00 p95 <= 2.0`, and **`100%` Thai OCR** (`0` dropped frames, `0` Dock focus steal).
- **Null Hypothesis ($H_0$):** Safarium uses $\ge 0.90\times$ the Peak `ri_phys_footprint` of Chromium+FFmpeg, or runs slower (`< 1.10x`), or fails `SSIM >= 0.97` / `ΔE00 p95 <= 2.0` / Thai OCR against the visual reference.
- **Falsification Criteria:**
  - **Refuted if:** `WebContent` + `VTEncoderXPCService` combined peak footprint exceeds `90%` of single-worker Chromium (`HyperFrames -w 1`) across all 3 scene classes (static Thai card, GSAP kinetic typography, Canvas2D particle+Thai HUD), OR if multi-worker Remotion (`--concurrency=4`) beats Safarium wall time *without* exceeding `2×` RAM AND without quality loss, OR if WebKit vs Chromium typography discrepancy yields `ΔE00 p95 > 2.0` even when identical `.ttf`/`.otf` fonts are pinned via `--font-dir`.
- **Bench-Lab Fixture & Exact Commands:**
  - **Fixtures (`/tmp/safarium-world-rd/h1/`):** (A) `thai_card_gsap.html` (1080×1920, 30fps, 5s = 150f, pinned Noto Sans Thai / Sarabun font + CSS shadows + GSAP timeline + WAV narration), (B) `canvas2d_hud.html` (dynamic Canvas2D + crisp Thai captions).
  ```bash
  # Arm A1: Safarium native HTML (single-pass audio+video)
  "$HOME/.local/bin/safarium-render" html /tmp/safarium-world-rd/h1/thai_card_gsap.html \
    --fps 30 --size 1080x1920 --duration 5 --audio /tmp/safarium-world-rd/h1/voice.wav \
    --codec h264 -o /tmp/safarium-world-rd/h1/out_safarium_html.mp4 --overwrite

  # Arm A2: Safarium CDP shim driving HyperFrames 0.9.72 (zero Chrome)
  SAFARIUM_CDP="$HOME/.local/libexec/safarium/safarium-cdp" \
    "$HOME/.local/bin/safarium-render" run -- npx --prefix /tmp/safarium-world-rd/hf hyperframes render \
    /tmp/safarium-world-rd/h1/hf_proj -w 1 -o /tmp/safarium-world-rd/h1/out_safarium_hf.mp4

  # Arm B1: Baseline HyperFrames 0.9.72 + Chrome Headless Shell + FFmpeg
  "$HOME/.local/bin/safarium-render" run -- npx --prefix /tmp/safarium-world-rd/hf hyperframes render \
    /tmp/safarium-world-rd/h1/hf_proj -w 1 -o /tmp/safarium-world-rd/h1/out_chrome_hf.mp4

  # Arm B2: Baseline Remotion (single-worker & default multi-tab)
  "$HOME/.local/bin/safarium-render" run -- npx --prefix /tmp/safarium-world-rd/remotion remotion render \
    /tmp/safarium-world-rd/h1/remotion_entry.ts ThaiCard /tmp/safarium-world-rd/h1/out_remotion.mp4 --concurrency=1

  # Verify & 4-Metric PQ Gate
  "$HOME/.local/bin/safarium-render" forge pq /tmp/safarium-world-rd/h1/out_chrome_hf.mp4 \
    /tmp/safarium-world-rd/h1/out_safarium_html.mp4 --samples 15 --thai-ocr --expected-thai "สวัสดีประเทศไทย" --strict
  ```

---

## Hypothesis H2: Zero-Copy Metal DAG (`safarium-forge`) vs FFmpeg `-filter_complex` & GStreamer

- **Target Claim:** On a realistic multi-layer reel composition (`1080p`/`4K` video + 3D LUT `.cube` + Gaussian blur + Ken Burns + animated alpha Thai HTML overlay + `loudnorm` `BS.1770-4` + `PeakLimiter` audio), `safarium-forge run --recipe` (`<= 4` `IOSurface` ring + fused single-init Metal + `O(4096)` `vDSP`) cuts Peak `ri_phys_footprint` by **$\ge 60\%$** (`<= 0.40x`) and improves wall-clock throughput by **$\ge 2.0\times$** over FFmpeg `-filter_complex` (both `libx264` and `h264_videotoolbox` output arms) and GStreamer `gst-launch-1.0` (`videoconvert` + `vtenc_h264`), while holding `SSIM >= 0.97`, `PSNR >= 30 dB`, `ΔE00 p95 <= 2.0`, and `|LUFS_err| <= 0.1`.
- **Null Hypothesis ($H_0$):** FFmpeg (`h264_videotoolbox` with minimal CPU filters) or GStreamer matches or beats `safarium-forge` on Peak `ri_phys_footprint` (`< 1.10x`) or wall speed (`< 1.10x`) at equal visual/audio quality.
- **Falsification Criteria:**
  - **Refuted if:** `safarium-forge` peak `ri_phys_footprint` exceeds `0.90x` of FFmpeg `h264_videotoolbox`, OR if FFmpeg (`hwdownload`/`lut3d`/`overlay`/`loudnorm`) finishes faster than `safarium-forge`'s Metal DAG (`< 1.10x` speedup), OR if `safarium-forge` Metal shader colorimetry drifts past `ΔE00 p95 > 2.0`.
- **Bench-Lab Fixture & Exact Commands:**
  - **Fixture (`/tmp/safarium-world-rd/h2/`):** 10s `1080×1920` 30fps MP4 (`bt709` `1-1-1`), 33×33×33 `.cube` LUT, 3 PNG/HTML overlays (`x(t), y(t)`), 48 kHz stereo voice+BGM WAV.
  ```bash
  # Arm A: Safarium Forge DAG (zero-copy Metal + O(4096) vDSP audio)
  "$HOME/.local/bin/safarium-render" forge run --recipe /tmp/safarium-world-rd/h2/graph.json --progress jsonl

  # Arm B1: FFmpeg filter_complex -> h264_videotoolbox (matched HW codec arm)
  "$HOME/.local/bin/safarium-render" run -- ffmpeg -y -i /tmp/safarium-world-rd/h2/bg.mp4 \
    -loop 1 -t 10 -i /tmp/safarium-world-rd/h2/ov1.png -loop 1 -t 10 -i /tmp/safarium-world-rd/h2/ov2.png \
    -i /tmp/safarium-world-rd/h2/voice.wav -filter_complex "[0:v]lut3d=/tmp/safarium-world-rd/h2/grade.cube,gblur=sigma=2[b];[b][1:v]overlay=x='20*sin(t)':y=100[o1];[o1][2:v]overlay=0:0,format=yuv420p[v];[3:a]loudnorm=I=-16:TP=-1.05:LRA=11:linear=true[a]" \
    -map "[v]" -map "[a]" -c:v h264_videotoolbox -b:v 8M -c:a aac -b:a 192k /tmp/safarium-world-rd/h2/out_ffmpeg_vt.mp4

  # Arm B2: GStreamer pipeline (if gst-launch-1.0 installed via brew; else explicit SKIPPED)
  # gst-launch-1.0 filesrc location=... ! qtdemux ! vtdec_hw ! compositor ! vtenc_h264 ! mp4mux ! filesink ...

  "$HOME/.local/bin/safarium-render" forge pq /tmp/safarium-world-rd/h2/out_ffmpeg_vt.mp4 \
    /tmp/safarium-world-rd/h2/out_safarium.mp4 --samples 16 --thai-ocr --strict
  ```

---

## Hypothesis H3: VideoToolbox H.264/HEVC vs `x264` / `x265` / `SVT-AV1` Pareto Frontier (Honest Trade-Offs)

- **Target Claim:** On `1080×1920` and `1920×1080` real motion + UI-overlay sequences, Apple `VideoToolbox` (via `safarium-forge pipe-encode` / `transcode` using H.264 & HEVC `CQF` / bitrate sweeps) dominates the **RAM + Speed Pareto frontier** (**$\ge 4\times$ faster** than `x264 --preset slow`, `x265 --preset medium`, and `SVT-AV1 --preset 5`, with **$\ge 50\%$ lower Peak `ri_phys_footprint`** than `x265`/`SVT-AV1` lookahead heaps) — **WHILE** software `x265` and `SVT-AV1` win **equal-SSIM file size (BD-Rate)** by `10–30%` at low-bitrate ceilings (`1–4 Mbps`).
- **Null Hypothesis ($H_0$):** Either (a) `VideoToolbox` `CQF` matches `x265`/`SVT-AV1` BD-rate within $\pm 5\%$ (surprising upside!) OR (b) `x264 --preset veryfast` / `SVT-AV1 --preset 8` beats `VideoToolbox` on Speed/RAM without losing `> 5%` BD-Rate or breaking `SSIM >= 0.97`.
- **Falsification Criteria:**
  - **Honest Pareto Mapping (No Bias):** `bench-lab` sweeps 5 quality points per encoder (`VideoToolbox H.264 CQF 0.35..0.85`, `VideoToolbox HEVC CQF 0.35..0.85`, `x264 -crf 18..28`, `x265 -crf 20..30`, `SVT-AV1 --preset 5 & 8 --crf 24..40`) from an identical lossless `Y4M`/raw BGRA source, measuring Speed, Peak `ri_phys_footprint`, Bytes, `SSIM`, `PSNR`, and `ΔE00 p95` against the uncompressed reference. Explicitly report WIN on Speed/RAM and WIN or LOSE on BD-Rate!
- **Bench-Lab Fixture & Exact Commands:**
  ```bash
  # Generate deterministic 150-frame 1080x1920 raw Y4M/BGRA corpus in /tmp/safarium-world-rd/h3/
  # Arm A: Safarium VideoToolbox (pipe-encode H.264 / HEVC at matched bitrates & CQF)
  "$HOME/.local/bin/safarium-render" forge pipe-encode --width 1080 --height 1920 --fps 30 \
    --pix-fmt bgra --codec hevc --quality 0.72 -o /tmp/safarium-world-rd/h3/vt_hevc_q72.mp4 < /tmp/safarium-world-rd/h3/src.bgra

  # Arm B1/B2/B3: x264, x265, SVT-AV1 (1-thread SF-VIDEO-1 AND default multi-thread sweeps)
  "$HOME/.local/bin/safarium-render" run -- x264 --crf 22 --preset slow --threads 1 -o /tmp/safarium-world-rd/h3/x264_s1.mp4 /tmp/safarium-world-rd/h3/src.y4m
  "$HOME/.local/bin/safarium-render" run -- x265 --crf 24 --preset medium --input /tmp/safarium-world-rd/h3/src.y4m -o /tmp/safarium-world-rd/h3/x265.hevc
  "$HOME/.local/bin/safarium-render" run -- SvtAv1EncApp -i /tmp/safarium-world-rd/h3/src.y4m --preset 5 --crf 28 -b /tmp/safarium-world-rd/h3/svtav1.ivf

  # Neutral Quality Evaluation via SafariumPQ (decoded to BGRA by AVAssetReader / reference Y4M)
  "$HOME/.local/bin/safarium-render" forge pq /tmp/safarium-world-rd/h3/ref_lossless.mov \
    /tmp/safarium-world-rd/h3/vt_hevc_q72.mp4 --samples 20 --strict
  ```

---

## Hypothesis H4: `SafariumRaster` Optimizing Still Encoders vs `OpenCV` / `ImageMagick` / `cwebp` / `avifenc` / `libvips` / `oxipng` / `cjxl`

- **Target Claim:**
  1. **Lossless PNG (`IOPNG.swift`):** Beats `OpenCV 5.1` (`IMWRITE_PNG_COMPRESSION=9`) and `ImageMagick` on **both speed (`<= 0.7x` time) and file size (`<= 0.95x` bytes)** at `1` thread, and matches `oxipng -o 2` within $\pm 5\%$ size at lower binary/dependency footprint.
  2. **Lossless WebP (`webp_ll.c` DP `VP8L`):** Achieves **$\le 1.05\times$ `cwebp -lossless -m 4` byte size** (`bit-exact` round-trip verified by `Pillow`) with `0` `libwebp` code and `< 1.1x` Peak RAM.
  3. **Fused C/NEON Color JPEG (`Sources/SafariumRasterC/`):** After Wave 7's 16-row strip MCU+NEON FDCT+Annex K C fusion, matches `OpenCV 5.1` (`libjpeg-turbo`) byte size within $\pm 2\%$ at `q=90`, runs within **`<= 1.25x` time (`1T`)**, and cleanly beats `ImageIO` JPEG's `+60%` size overhead (`SSIM >= 0.99`).
  4. **Lossy `AVIF` (`ImageIO` `q<1.0`) & `WebP VP8`:** Honest size comparison vs `avifenc`, `cwebp`, `libvips`, and `cjxl` across Kodak24 + Sompong `1080×1920` UI frames.
- **Null Hypothesis ($H_0$):** `SafariumRaster` PNG/WebP-LL/JPEG encoders are $> 5\%$ larger at equal SSIM (or bit-exact round-trip), $> 1.5\times$ slower at `1` thread than `OpenCV 5.1`/`cwebp`, or fail `SSIM >= 0.97` / Pillow neutral decode verification.
- **Falsification Criteria:**
  - **Refuted per codec if:** (a) Pillow neutral decode fails bit-exact check for lossless PNG/WebP-LL or fails `SSIM >= 0.97` / `ΔE00 p95 <= 2.0` for JPEG; (b) fused C/NEON color JPEG remains slower than `1.5x` `cv2` at `1` thread; (c) WebP 14-bit limit (`>16383` px or `>2^27` px) crashes or allocates before returning `SRStatus.badArgument`.
- **Bench-Lab Exact Commands:**
  ```bash
  # Run SafariumRaster codec acceptance suite (uses Pillow neutral decoder + fresh subprocess RAM)
  SAFARIUM_RASTER_LIB=/tmp/safarium-raster-build/release/libSafariumRaster.dylib \
    /tmp/safarium-world-rd/venv/bin/python sdk/python/tests/bench_raster.py --area codec --n 15 --json

  # Head-to-head CLI still sweep vs cwebp, avifenc, magick, (optional oxipng/vips/cjxl/zopflipng)
  "$HOME/.local/bin/safarium-render" run -- python3 /tmp/safarium-world-rd/h4/bench_stills.py \
    --corpus /tmp/safarium-world-rd/kodak_and_sompong --lib /tmp/safarium-raster-build/release/libSafariumRaster.dylib
  ```

---

## Hypothesis H5: APFS `clonefile` Closed-GOP Scene Cache + Mode C Dirty-Region Capture vs Full Re-Render

- **Target Claim:** Across multi-scene iterative video workflows (4 scenes $\times$ 5 s, where only Scene 3 changes — a typical AI agent edit cycle) and slide/caption videos with static holds (`>= 40%` hold frames), combining **`ForgeIncrementalCache` (APFS `clonefile` Closed-GOP)** + **`StaticHoldProbe` Mode C** reduces incremental re-render wall time by **$\ge 3.0\times$**, Peak `ri_phys_footprint` by **$\ge 25\%$**, and incremental cache disk bloat by **$\ge 90\%$** (`0 B` CoW clone overhead on APFS) while achieving **bit-exact (`SHA-256` identical packets)** on unchanged scenes vs full monolithic re-render!
- **Null Hypothesis ($H_0$):** Full monolithic re-render (`WKWebView` / `HyperFrames` without cache/Mode C) runs within `< 1.5x` of incremental `clonefile`+Mode C, OR Mode C drops a subtle CSS/WAAPI/WebGL animation frame (`recall < 1.0`), OR `clonefile` stitch breaks `.mp4` `stsd`/PTS playability.
- **Falsification Criteria:**
  - **Refuted if:** Any cached scene packet `SHA-256` differs from clean v1, OR `safarium-render verify` reports unplayable/PTS drift (`diff != []` on unchanged scenes), OR `Mode C` produces $\ge 1$ false-negative hold frame (`pixel diff > 0` while marked static), OR directory input hashing fails to invalidate when a nested file inside Scene 3's asset folder changes (while ignoring `._*` AppleDouble files).
- **Bench-Lab Exact Commands:**
  ```bash
  # Run v1 full render (populates APFS scene cache), mutate Scene 3 only, run v2 incremental vs v2 monolithic
  "$HOME/.local/bin/safarium-render" forge cache stats
  "$HOME/.local/bin/safarium-render" forge run --recipe /tmp/safarium-world-rd/h5/ep_v1.json --progress jsonl
  # Mutate Scene 3 HTML/asset + create dummy ._appledouble in Scene 1 asset dir (must still HIT cache!)
  "$HOME/.local/bin/safarium-render" forge run --recipe /tmp/safarium-world-rd/h5/ep_v2_inc.json --progress jsonl
  "$HOME/.local/bin/safarium-render" forge run --recipe /tmp/safarium-world-rd/h5/ep_v2_full.json --progress jsonl

  # Verify packet-level exactness on unchanged scenes 1, 2, 4 + Mode C zero-FN pixel check
  "$HOME/.local/bin/safarium-render" verify /tmp/safarium-world-rd/h5/out_v1.mp4 /tmp/safarium-world-rd/h5/out_v2_inc.mp4
  "$HOME/.local/bin/safarium-render" forge pq /tmp/safarium-world-rd/h5/out_v2_full.mp4 /tmp/safarium-world-rd/h5/out_v2_inc.mp4 --strict
  ```

---

## Hypothesis H6: Hybrid 2-Engine 3D+Web+Thai (`Safarium Prism`) vs Blender PNG-Dump + FFmpeg/Chrome Compositing

- **Target Claim:** For 3D character + Three.js background + crisp Thai HUD videos (`1080×1920`, `30 fps`), `SafariumPrism` (`webkitGLB` Tier-0 preview + Warm Blender 5.2 SHM/mmap worker + single-pass Metal composite + `1× Thai Shield` + dual-tee `.mp4` + `ProRes 4444 .mov`) eliminates **`100%` of intermediate PNG disk bytes** (`0 B` vs `19+ MB`/10f), cuts camera-preview wall latency by **$\ge 3.5\times$** (`webkitGLB` vs cold Blender), reduces composite Peak `ri_phys_footprint` vs traditional multi-process Blender PNG-dump + Chrome HUD + FFmpeg composite, and guarantees **`100%` Thai OCR** (`--metalfx` auto-verify falls back cleanly to `1×` if Thai strokes degrade).
- **Null Hypothesis ($H_0$):** Traditional cold `blender -b` -> PNG sequence -> headless Chrome HUD -> FFmpeg composite runs faster (`< 1.15x`), uses less Peak `ri_phys_footprint`, or achieves higher `SafariumPQ` / Thai OCR fidelity than `SafariumPrism`.
- **Falsification Criteria:**
  - **Refuted if:** `Prism` composite fails `safarium-render verify` or `ProRes 4444` alpha round-trip, OR `Prism` camera alignment (`sync-ir` `.glb` vs Blender `EEVEE`) diverges beyond `SSIM < 0.97` / geometric silhouette shift `> 2 px`, OR `--metalfx` corrupts Thai HUD text (`"กำ"→"ก่า"`), OR HID Anti-Lag adds $> 100\text{ ms}$ overhead during idle runs.
- **Bench-Lab Exact Commands:**
  ```bash
  # 1. Sync Blender hero scene -> GLB + IR
  "$HOME/.local/bin/safarium-render" forge prism sync-ir /tmp/safarium-world-rd/h6/hero.blend \
    --glb /tmp/safarium-world-rd/h6/hero.glb --ir /tmp/safarium-world-rd/h6/hero_ir.json --overwrite

  # 2. Tier-0 webkitGLB preview stills vs cold blender -b
  "$HOME/.local/bin/safarium-render" forge prism preview-stills /tmp/safarium-world-rd/h6/hero.glb \
    --tier webkitGLB --angles 0,45,90 -o /tmp/safarium-world-rd/h6/preview_sheet.png --overwrite

  # 3. Single-pass 2-Engine Composite (Three.js BG + Blender Alpha Hero + 1x Thai HUD -> MP4 + ProRes4444)
  "$HOME/.local/bin/safarium-render" forge prism composite /tmp/safarium-world-rd/h6/hero.blend \
    --bg-html /tmp/safarium-world-rd/h6/three_bg.html --overlay-html /tmp/safarium-world-rd/h6/thai_hud.html \
    -o /tmp/safarium-world-rd/h6/prism_comp.mp4 --secondary-mov /tmp/safarium-world-rd/h6/prism_alpha.mov \
    --frames 30 --fps 30 --metalfx --scale 0.67 --thai-ocr --expected-thai "สำรวจโลกสามมิติ" --overwrite

  # 4. Baseline: Cold Blender PNG dump + Chrome HUD PNGs + FFmpeg composite -> compare 4 metrics
  "$HOME/.local/bin/safarium-render" forge pq /tmp/safarium-world-rd/h6/baseline_ffmpeg.mp4 \
    /tmp/safarium-world-rd/h6/prism_comp.mp4 --samples 10 --thai-ocr --strict
  ```

---

## Hypothesis H7: `Accelerate` LAPACK/vDSP + Opt-In Metal (`SafariumRaster` Phase 2 & 3) vs `OpenCV 5.1` & `SciPy`

- **Target Claim:**
  1. **Phase 2 (`linalg` + `transforms` via Apple `Accelerate` BLAS/LAPACK/`vDSP`):** Matches `OpenCV 5.1.0.95` and `float64` `numpy.linalg`/`numpy.fft` ground truth (`rel_err <= 1e-6`), beats or ties `OpenCV` on `1`-thread (`SF-VIDEO-1`) speed (`<= 1.05x` time) and Peak `ri_phys_footprint` (`<= 0.90x` on streaming/in-place transforms) — recognizing honestly that `OpenCV` on macOS already links `Accelerate` for BLAS/LAPACK so `gemm`/`solve`/`SVD` may **TIE** on raw LAPACK compute while `SafariumRaster` wins via zero Python/Mat wrapper overhead & bounded memory!
  2. **Phase 3 (`imgproc-filter` — `Sobel`, `Scharr`, `Canny`, `bilateralFilter`, `medianBlur`, `CLAHE`, `warpPerspective`, `cvtColor`):** Eliminates current Phase 1/2 `LOSS` bottlenecks (e.g., `cvtColor` `261 MiB` RAM spike & `40–120×` slowdown vs `cv2` in [docs/bench-results.md](../bench-results.md)) to achieve **Parity (`SSIM >= 0.97`, `PSNR >= 30`, `ΔE00 p95 <= 2.0`)** and **$\ge 65\%$ `WIN+TIE` rate** at `1` thread, while **Opt-In Metal (`cv2.safarium_set_gpu(True)` / `SAFARIUM_GPU=1`)** delivers **$\ge 2.0\times$ speedups** on compute-bound `4096×4096` float32 `sqrt`/`exp`/`log`/`magnitude`/`phase`/`bilateralFilter` over `1`-thread CPU `cv2`!
- **Null Hypothesis ($H_0$):** `SafariumRaster` Phase 2/3 still suffers $> 1.10\times$ Peak RAM or $> 1.10\times$ latency vs `cv2.setNumThreads(1)` on core `imgproc` ops, OR `Accelerate` LAPACK sign/permutation differences break `OpenCV`/`SciPy` parity (`rel_err > 1e-6`), OR opt-in Metal GPU `phys_footprint` overhead negates speedup wins on `1080×1920` arrays.
- **Falsification Criteria:**
  - **Refuted per op if:** (a) Any `linalg` (`gemm`, `solve`, `invert`, `SVDecomp`, `eigen`, `PCACompute`, `dft`, `kmeans`) or `imgproc` (`Sobel`, `Canny`, `bilateralFilter`, `CLAHE`, `warpPerspective`, `cvtColor`) function fails `bench_raster.py` Quality/Parity gate or NaN/singular-matrix handling; (b) `cvtColor` BGR2HSV/BGR2GRAY retains the `30–260 MiB` RAM overhead seen in `docs/bench-results.md`; (c) Opt-in Metal `4096×4096` dispatch takes $> 0.90\times$ of CPU `cv2` wall time or corrupts memory-bandwidth accounting (`phys_footprint` unreported).
- **Bench-Lab Exact Commands:**
  ```bash
  # 1-Thread (SF-VIDEO-1 headline) & Default/Opt-in GPU acceptance run via existing bench_raster.py harness
  SAFARIUM_RASTER_LIB=/tmp/safarium-raster-build/release/libSafariumRaster.dylib \
    BENCH_CV2_PYTHON=/tmp/safarium-world-rd/venv/bin/python \
    BENCH_SCI_PYTHON=/tmp/safarium-world-rd/venv/bin/python \
    /tmp/safarium-world-rd/venv/bin/python sdk/python/tests/bench_raster.py --n 15 --json --write-md

  # Opt-in Metal GPU comparison (4096x4096 & 1080x1920 f32 compute-bound kernels)
  SAFARIUM_GPU=1 SAFARIUM_RASTER_LIB=/tmp/safarium-raster-build/release/libSafariumRaster.dylib \
    /tmp/safarium-world-rd/venv/bin/python sdk/python/tests/bench_raster.py --area ops --n 15 --json
  ```

---

## References & Anchor Files

- [docs/benchmark-protocol.md](../benchmark-protocol.md) · [docs/raster-roadmap.md](../raster-roadmap.md) · [docs/bench-results.md](../bench-results.md)
- [docs/apple-silicon-innovations-2026-11-22.md](../apple-silicon-innovations-2026-11-22.md) · [docs/mac-native-innovations-wave2-2026-11-22.md](../mac-native-innovations-wave2-2026-11-22.md)
- [docs/superpowers/specs/2026-11-24-safarium-unified-cloud-rd-design.md](../superpowers/specs/2026-11-24-safarium-unified-cloud-rd-design.md)
- [sdk/python/tests/bench_raster.py](../../sdk/python/tests/bench_raster.py) · [bin/safarium-render](../../bin/safarium-render) · [Sources/safarium-forge/main.swift](../../Sources/safarium-forge/main.swift)

