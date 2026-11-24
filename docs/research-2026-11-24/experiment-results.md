---
tags: [safarium, rd, experiments, benchmarks, apple-silicon, sf-video-1]
note_type: research
project: "Safarium"
created: 2026-11-24
updated: 2026-11-25
---

# Safarium World R&D Experiment Results (`H1–H7`, 2026-11-24 / 2026-11-25)

> **Scope & Provenance:** Empirical evaluation of all seven falsifiable hypotheses defined in [novel-hypotheses.md](docs/research-2026-11-24/novel-hypotheses.md) against installed release `78fd463125ea780e96f72c14aaefa0d8c096afd637f09db7ca009be7d05c2010` (`~/.local/bin/safarium-render` + `~/.local/libexec/safarium/*`), executed sequentially inside `/tmp/safarium-world-rd/` with zero edits to Safarium core sources or external Vault projects. All raw JSON telemetry is preserved in [`bench/experiments/2026-11-24-world-rd/h1.json`..`h7.json`](bench/experiments/2026-11-24-world-rd/).

---

## 1. Execution Environment, Queue Context, and Methodological Disclosures

- **Hardware & OS:** Apple M5 (`Mac17,3`, 10 CPUs), macOS `27.2`, Python `3.12.13` (`/opt/homebrew/bin/python3.12`), reference OpenCV `opencv-python-headless 5.1.0.95` (`cvref`), reference SciPy `1.18.1` + NumPy `2.5.5` (`sciref`), Blender `5.2.2 LTS`, Chrome Headless Shell `158.0.8127.36`, Remotion `4.0.453`, HyperFrames `0.9.72`, `sharp` (Node libvips).
- **4-Metric Acceptance Rubric (per [novel-hypotheses.md](docs/research-2026-11-24/novel-hypotheses.md)):**
  1. **Peak RAM (Primary):** Both `libproc` `proc_pid_rusage(RUSAGE_INFO_V6)` `ri_phys_footprint` (50 ms full process tree including `WebKit`/`VTEncoderXPCService`/`Blender`/children) and `/usr/bin/time -l` (`peak memory footprint` / `maximum resident set size`); the **worse** verdict governs (**WIN** $\le 0.90\times$ and $\ge 1\text{ MiB}$ delta; **TIE** $0.90\times\text{–}1.10\times$ or $<1\text{ MiB}$; **LOSS** $\ge 1.10\times$).
  2. **Speed:** Fresh subprocess per trial in alternating A/B order (**WIN** $\le 0.90\times$ wall time; **LOSS** $\ge 1.10\times$; `bench_raster.py` uses $\le 0.95\times$ / $\ge 1.05\times$ with non-overlapping 95% block-bootstrap CIs).
  3. **Equal-Quality File Size / BD-Rate:** **WIN** $\le -5\%$ BD-Rate ($\le 0.95\times$ bytes); **TIE** within $\pm 5\%$; **LOSS** $\ge +5\%$ ($\ge 1.05\times$ bytes).
  4. **Quality Gate (`SF-VIDEO-1`):** `SSIM >= 0.97`, `PSNR >= 30 dB`, `ΔE00 p95 <= 2.0`, and Vision `th-TH` Thai OCR `100%`. Any failure is **DISQUALIFIED / LOSS**; no thresholds were lowered.
- **Concurrent Queue & High-Load Disclosure (Mandatory):**
  - External sessions actively held `safarium-render` FIFO queue tickets throughout all seven runs (`concurrent_external_queue_active: true` in all 7 JSONs). Per `measure.py` (`safarium_cmd`), when an external ticket occupied the FIFO, Safarium invocations ran sequentially via `~/.local/libexec/safarium/*` rather than deadlocking behind multi-hour external test suites, with **zero concurrent Safarium processes** launched by `bench-lab`:

| JSON Artifact | Timestamp | External Active Ticket (Waiting) | `load1` (Start/Queue → End) | Speed Status (`load1 > 4.0`) | Focus Integrity |
|---|---|---|---|---|---|
| [h1.json](bench/experiments/2026-11-24-world-rd/h1.json) | `2026-11-24T23:57:04+0700` | `3` (`[5]`) | `11.021 → 16.103` | Provisional (`load1 > 4.0`) | `focus_unchanged: true` (`Safari`) |
| [h2.json](bench/experiments/2026-11-24-world-rd/h2.json) | `2026-11-24T23:59:02+0700` | `3` (`[5]`) | `14.764 → 14.276` | Provisional (`load1 > 4.0`) | Windowless |
| [h3.json](bench/experiments/2026-11-24-world-rd/h3.json) | `2026-11-25T00:23:32+0700` | `3` (`[5]`) | `11.335 → 11.964` | Provisional (`load1 > 4.0`) | Headless CLI |
| [h4.json](bench/experiments/2026-11-24-world-rd/h4.json) | `2026-11-25T05:06:00+0700` | `2` (`[3]`) | `6.451 → 7.252` | Provisional (`load1 > 4.0`) | Headless CLI |
| [h5.json](bench/experiments/2026-11-24-world-rd/h5.json) | `2026-11-25T05:07:47+0700` | `4` (`[5]`) | `7.649 → 7.635` | Provisional (`load1 > 4.0`) | Windowless |
| [h6.json](bench/experiments/2026-11-24-world-rd/h6.json) | `2026-11-25T05:09:33+0700` | `4` (`[5]`) | `7.655 → 12.542` | Provisional (`load1 > 4.0`) | Windowless (`darwinBGToggles=1`) |
| [h7.json](bench/experiments/2026-11-24-world-rd/h7.json) | `2026-11-25T05:57:32+0700` | `1` (`[]`) | `7.7 → 8.748` | Provisional (`108/108` rows `†`) | Headless CLI |

- **Optional / Skipped Tools:**
  - `H2`: `gst-launch-1.0` (`SKIPPED_UNINSTALLED`).
  - `H4`: `zopflipng` (`SKIPPED_UNINSTALLED`); `vips` CLI absent while `sharp` Node binding exercised `libvips`. (`magick`, `oxipng`, `cwebp`, `avifenc`, `cjxl`/`djxl` were all installed and executed.)
- **Harness Bugs Fixed in `/tmp/safarium-world-rd/` (Zero Edits to Safarium Core):**
  1. `/tmp/safarium-world-rd/h4_bench.py:79`: Fixed `IndentationError` on `code = f"""` inside `bench_webp_14bit_guard()`.
  2. `/tmp/safarium-world-rd/h4_bench.py:71` & `/tmp/safarium-world-rd/h7_bench.py:34`: Increased `bench_raster.py` subprocess timeouts (`900s → 3600s` for H4 codec; `1800s → 7200s` for H7 all-108 cases) and streamed `stderr` live because OpenCV PNG `-c 9` at `1080×1920` took ~57 s/round under load.
  3. `/tmp/safarium-world-rd/h4_bench.py:177`: Escaped f-string dict literal braces (`{{'webp_ll':...}}`) in `bench_inproc_lib_trials()`.
  4. `/tmp/safarium-world-rd/h7_bench.py:72`: Guarded `from PIL import Image` + Sompong PNG load behind `if cid.startswith('p3_'):` so `sciref/bin/python` (which has `scipy 1.18.1` without `Pillow`) executed all 6 `p2_*` SciPy baselines cleanly (`rc=0`), then re-ran `h7_bench.py` completely from scratch.

---

## 2. Executive Summary Matrix (`H1–H7`)

| Hypothesis | Primary Comparison | 1. Peak RAM Verdict | 2. Speed Verdict | 3. File Size / BD-Rate Verdict | 4. Quality Gate (`SSIM/PSNR/ΔE00/OCR`) | Overall Hypothesis Verdict |
|---|---|---|---|---|---|---|
| **H1** Windowless WebKit vs Chrome/HF & Remotion | `safarium_html` / `safarium_cdp_hf` vs `chrome_hf` / `remotion_c1,c4` | **WIN** (`safarium_html`: `0.06×–0.19×`) / **TIE** (`cdp_hf` vs `chrome_hf`: `0.98×` `tl_fp`, `0.76×` `lp_fp`) | **WIN** (`safarium_html`: `2.78–3.31s` = `1.69×–3.55×`) / **Mixed** (`cdp_hf`: `0.85×` ScA, **LOSS** `1.67×` ScB) | **LOSS** (`6.44×`/`4.35×` default bitrate); **TIE** at `q=0.72` vs Remotion (`1.02×`) & ScB Chrome (`1.03×`) | **Mixed / Strict Cross-Gate DISQUALIFIED for `safarium_html`** (`msSSIM >= 0.991`, `Thai OCR 100%`, `verify=0`, **but `ΔE00 p95 = 2.002` ScA & `2.288` ScB > 2.0**; `cdp_hf` **PASS** ScA `1.702`, **FAIL** ScB score `84.59 < 85`; `remotion` failed `verify` & `ΔE00=2.448`) | **PARTIALLY CONFIRMED** (RAM/Speed/Focus/OCR confirmed; strict WebKit-vs-Chrome `ΔE00 <= 2.0` refuted on `safarium_html`) |
| **H2** Zero-Copy Metal DAG (`safarium-forge`) vs FFmpeg | `safarium_forge` vs `ffmpeg_vt` & `ffmpeg_x264` (`gst` skipped) | **WIN** (`100.2/302.2 MiB` vs `vt` `307.5/355.6 MiB` [`0.326×`/`0.850×`], vs `x264` `933.2 MiB` [`0.107×`/`0.324×`]) | **WIN** (`4.08s` vs `vt` `11.82s` [`2.901×`] & `x264` `11.20s` [`2.749×`]) | **LOSS** (`2.71 MB` vs `vt` `1.53 MB` [`1.77×`] & `x264` `1.17 MB` [`2.31×`] at `8M` target) | **PASS** (`msSSIM 0.9967/0.9968`, `ΔE00 p95 1.854/1.654`, `Thai OCR 100%`, `\|LUFS err\| = 0.0002 <= 0.1`, `verify=0`; note all 3 arms triggered `qa freezedetect(1)` on fixture) | **CONFIRMED** (note `libproc` combined RAM win is `-15.0%` vs `ffmpeg_vt`, narrower than `-60%` target, while `time -l` is `-67.4%`) |
| **H3** VideoToolbox vs `x264` / `x265` / `SVT-AV1` Pareto | `vt_h264/hevc` (`CQF 0.72`) vs 7 SW configs (`1T` & `dflt`) | **WIN** (`14/14` pairwise WINs; `vt_hevc` `72.3/123.8 MiB` vs `355.7–1367.1 MiB`) | **WIN** (`14/14` pairwise WINs; `vt_hevc` `1.30s` = `1.96×–11.75×` faster) | **LOSS** (`8/8` BD-Rate **LOSS**: `+174%..+1045%` HEVC / `+294%..+1371%` H.264 SSIM BD-Rate vs SW) | **Mixed** (at mid-quality `CQF 0.72`, `SSIM 0.948–0.952`, `ΔE00 p95 3.59–3.64` vs raw 4:4:4; `SVT-AV1 p5 crf28` reached `SSIM 0.9699`) | **CONFIRMED (Two-Sided Pareto)** (VT dominates RAM+Speed `14/14`; SW dominates BD-Rate `8/8`) |
| **H4** `SafariumRaster` Still Codecs vs Rivals | PNG, VP8L, Fused C/NEON JPEG, WebP/AVIF + `bench_raster codec` | **Mixed** (`sr_jpeg` **TIE** vs `cv2`; `sr_png` **TIE** vs `cv2`/`oxipng`; `sr_vp8l` **LOSS** vs `cwebp` CLI; official `codec` `3W/1T/11L`) | **WIN** (`sr_png` `2.30×` vs `cv2`; `sr_vp8l` `1.43×–2.28×` vs `cwebp`; `sr_jpeg` `1.18×–1.35×` vs `cv2`; official `1T` `7W/3T/5L`) | **WIN/TIE** (`sr_jpeg` vs `cv2` BD-Rate `+0.32%` **TIE**, `-24.2%` vs ImageIO **WIN**, `+20.6%` vs `mozjpeg` **LOSS**; `sr_vp8l` `+0.88%` **TIE**; `sr_webp` `-0.47%` **TIE**; `sr_avif` `+17.9%` vs `avifenc` **LOSS**, `-44.0%` vs `cjxl` **WIN**) | **PASS** on all custom encodes (`PNG/VP8L` bit-exact `True`, `JPEG q90 SSIM 0.9864–0.9877 ΔE00 1.92`, WebP 14-bit guard `6/6` clean reject); **1 LOSS** in official `codec` (`imdecode_jpeg.q90_color ΔE00 p95=2.177 > 2.0`) | **PARTIALLY CONFIRMED** (PNG/VP8L/C-NEON JPEG targets met; `imdecode` RAM/quality & `avifenc` BD-Rate lag) |
| **H5** APFS `clonefile` Cache + Mode C vs Monolithic | 4-scene v2 edit (Scene 3 changed; `._*` injected in Sc 1) | **TIE** (`126.5/183.1 MiB` vs `126.0/183.7 MiB` = `1.005×`/`0.997×`; `-25%` peak RAM claim refuted) | **WIN** (`3.854×`: `2.89s` vs `11.13s`, `hits=3/4`, Mode C `60` cap / `90` reused) | Bit-exact packet reuse (`150/150` SHA-256 identical on Scenes 1, 2, 4) | **PASS** (`verify=0`, `PQ 99.9998`, `msSSIM 0.999999`, `ΔE00 p95=0`, `Thai OCR 100%`, Mode C **0/150** diff frames `max_abs=0`) | **CONFIRMED ON SPEED & EXACTNESS; REFUTED ON PEAK RAM** (`3.854×` speed & `0` FN proven; single-scene peak RAM unchanged) |
| **H6** `SafariumPrism` vs Cold Blender+Chrome+FFmpeg | `6A` preview stills & `6B` 30f 3D+WebGL2+Thai composite | `6A` **WIN** footprint (`24.95 vs 1721.36 MiB` `0.0145×`); `6B` **LOSS** (`2037.5 vs 1721.1 MiB` `1.184×` concurrent engines) | `6A` **WIN** (`3.121×`: `628ms vs 1961ms`); `6B` **TIE** (`0.985×`: `11.43s vs 11.26s`, encoding MP4+ProRes4444) | `6B` **`0 B` intermediate PNGs** (**100% eliminated** vs `24.78 MB` / `61` PNGs); primary MP4 `1.38 MB` vs `0.54 MB` (`2.59×` **LOSS**) | `verify_mp4=0`, `verify_prores4444_mov=0` (`ap4h`, `hasAlpha=true`), `MetalFX 0.67×` caught Thai OCR fail & fell back to `1×`, `Thai OCR 100%`, `msSSIM 0.9954`, **but cross-engine `ΔE00 p95 = 2.412 > 2.000`** | **PARTIALLY CONFIRMED** (`0 B` PNGs, `6A` preview win, `1×` Thai shield & `ProRes 4444` proven; `6B` concurrent tree RAM LOSS & `ΔE00 2.412` cross-engine diff) |
| **H7** `SafariumRaster` Accelerate + Metal vs OpenCV/SciPy | `108` official cases + `10` P2 linalg + `14` P3 filter + `13` GPU | Official `108`: `15W/58T/35L`; P2: `8T/2L`; P3: `7T/7L`; GPU `4K`: **`9T/0L`**, GPU `1080p`: **`0T/4L`** (`1.22×`) | Official `108` (`1T`): `29W/28T/51L` (`40.7%` WIN+TIE vs `>=65%` target); P2: `7/10` W+T; P3: `1W/13L`; GPU `4K`: **`8W/1T`**, `1080p`: **`4W`** (`1.2×–6.3×`) | N/A (`codec` subset covered in H4) | Official `108`: **`103/108` (95.4%) PASS** (5 losses); P2: `9/9` PASS (`rel_err<=3.2e-15`); P3: **`14/14` PASS** (`max_abs=0`); GPU: **`13/13` PASS** (`rel_err=0`) | **MIXED / REFUTED ON OVERALL `>=65%` 1T PARITY TARGET** (`40.7%` official `1T` WIN+TIE, P3 `13/14` speed LOSS, `1080p` GPU RAM LOSS; P2 linalg `70%` & `4K` Metal GPU `89%` speed WINs) |

---

## 3. Detailed Hypothesis-by-Hypothesis Findings

### H1: Windowless WebKit → Metal → VideoToolbox vs Chrome / HyperFrames / Remotion ([h1.json](bench/experiments/2026-11-24-world-rd/h1.json))

- **Setup:** `1080×1920`, `30 fps`, `5s` (`150` frames + `48 kHz` WAV narration), `N=3` interleaved trials per arm under `load1=11.02 → 16.10` (`ticket 3` active).
  - **Scene A (`scene_a_gsap`):** Pinned `KanitPinned` Thai card + GSAP timeline (`"สวัสดีประเทศไทย"`).
  - **Scene B (`scene_b_canvas2d`):** Dynamic Canvas2D particle HUD + Thai text (`"สวัสดีประเทศไทย"`).
- **Results Table:**

| Scene & Arm | Median Wall (ms) | `time -l` Peak FP (MiB) | `libproc` Tree FP (MiB) | `time -l` Max RSS (MiB) | Output Bytes | `verify` | Cross-Gate vs `chrome_hf` (`MS-SSIM` / `ΔE00 p95` / `Score` / `OCR`) |
|---|---|---|---|---|---|---|---|
| **Scene A:** `safarium_html` | **3,305.2** (`WIN` 3.55×) | **45.35** (`WIN`) | **115.67** (`WIN`) | **87.17** | 1,746,386 (`LOSS` 6.44×) | `0` | `0.9958` / **2.002** (`>2.0`) / `87.77` / `OK` (**DISQUALIFIED**) |
| **Scene A:** `safarium_html_q72` | **3,026.0** (`WIN` 3.87×) | **45.02** (`WIN`) | **123.60** (`WIN`) | **86.39** | 364,408 (`LOSS` 1.34× vs HF; `TIE` 1.02× vs Rem) | `0` | `0.9957` / **2.002** (`>2.0`) / `87.09` / `OK` (**DISQUALIFIED**) |
| **Scene A:** `safarium_cdp_hf` | **9,913.3** (`WIN` 1.18×) | 245.67 (`TIE` 0.98×) | 758.16 (`WIN` 0.76×) | 518.17 (`TIE`) | 397,019 (`LOSS` 1.46×) | `0` | `0.9965` / **1.702** / `89.93` / `OK` (**PASS**) |
| **Scene A:** `chrome_hf` (ref) | 11,718.4 | 250.44 | 994.49 | 485.70 | 271,231 | `0` | Self `0.999999` / `0.0` / `100.0` / `OK` |
| **Scene A:** `remotion_c1` | 10,834.4 | 769.97 | 1,604.60 | 677.11 | 358,782 | **`1`** | `0.9967` / **2.448** (`>2.0`) / `87.70` / `OK` (**DISQUALIFIED**) |
| **Scene A:** `remotion_c4` | 5,579.3 | 776.30 | 1,975.03 | 760.61 | 358,782 | **`1`** | `0.9967` / **2.448** (`>2.0`) / `87.70` / `OK` (**DISQUALIFIED**) |
| **Scene B:** `safarium_html` | **2,775.1** (`WIN` 3.35×) | **56.86** (`WIN`) | **127.94** (`WIN`) | **100.20** | 3,451,263 (`LOSS` 4.35×) | `0` | `0.9906` / **2.288** (`>2.0`) / **82.74** (`<85`) / `OK` (**DISQUALIFIED**) |
| **Scene B:** `safarium_html_q72` | **2,503.5** (`WIN` 3.71×) | **46.41** (`WIN`) | **122.46** (`WIN`) | **92.47** | 818,837 (`TIE` 1.03×) | `0` | `0.9905` / **2.550** (`>2.0`) / **82.07** (`<85`) / `OK` (**DISQUALIFIED**) |
| **Scene B:** `safarium_cdp_hf` | 15,557.3 (`LOSS` 1.67×) | 234.82 (`WIN` 0.77×) | 786.47 (`WIN` 0.45×) | 489.77 (`TIE` 0.99×) | 1,025,017 (`LOSS` 1.29×) | `0` | `0.9905` / **1.464** / **84.59** (`<85`) / `OK` (**DISQUALIFIED**) |
| **Scene B:** `chrome_hf` (ref) | 9,298.4 | 305.80 | 1,762.48 | 496.30 | 792,944 | `0` | Self `0.9999998` / `0.0` / `100.0` / `OK` |

- **Honest Assessment:**
  - `safarium_html` crushes Headless Chromium on Peak RAM (`81%–88%` lower `libproc` footprint vs `chrome_hf`; `93%–94%` lower vs `remotion_c1/c4`) and wall speed (`3.35×–3.87×` faster than `chrome_hf`; even `1.69×–1.84×` faster than 4-worker `remotion_c4` at `<6%` of its RAM!), steals zero focus (`focus_unchanged: true`), and achieves `100%` self Thai OCR + `verify=0` (while Remotion failed `verify_rc=1`).
  - **Where H1 fails strict falsification:** Even with pinned `KanitPinned` `.ttf` fonts, WebKit's subpixel font rasterization + Canvas2D AA differs slightly from Chromium Skia, pushing `ΔE00 p95` to `2.002` (Scene A, `0.002` above `2.000`) and `2.288` (Scene B). On `safarium_cdp_hf`, `ΔE00 p95` passed (`1.702` and `1.464`), `time_l_fp` tied Chrome on Scene A (`0.981×`), and Scene B fell `1.67×` slower with ANE PQ score `84.59 < 85.00`.

---

### H2: Zero-Copy Metal DAG (`safarium-forge`) vs FFmpeg `-filter_complex` & GStreamer ([h2.json](bench/experiments/2026-11-24-world-rd/h2.json))

- **Setup:** `10s` (`300f` @ `1080×1920`, `30 fps`) `bg.mp4` + `33×33×33` `.cube` LUT + `gblur(sigma=2)` + animated `ov1.png` (`20*sin(t)`) + Thai HTML card `ov2.png` (`"ทดสอบกราฟิกไทย"`) + `loudnorm(-16 LUFS, -1.05 dBTP)`. `N=3` interleaved trials under `load1=14.76 → 14.28` (`ticket 3` active). `gst-launch-1.0` = `SKIPPED_UNINSTALLED`.
- **Results:**

| Arm | Median Wall (ms) | `time -l` FP (MiB) | `libproc` Combined FP (MiB) | Max RSS (MiB) | Size (B) | Measured LUFS (`\|err\|`) | `SafariumPQ --strict` vs Arm |
|---|---|---|---|---|---|---|---|
| `safarium_forge` | **4,075.6** (**WIN** `2.90×` / `2.75×`) | **100.19** (**WIN** `0.326×` / `0.107×`) | **302.24** (**WIN** `0.850×` / `0.324×`) | **72.66** | 2,705,102 (**LOSS** `1.77×` / `2.31×`) | **-15.9998** (`0.0002 <= 0.1`) | Ref: `vt` / `x264` |
| `ffmpeg_vt` (`h264_videotoolbox -b:v 8M`) | 11,823.9 | 307.47 | 355.61 | 310.11 | 1,529,068 | -16.0607 (`0.0607`) | `msSSIM 0.9967`, `ΔE00 p95 1.854`, `OCR=true`, **PASS** (`88.69`) |
| `ffmpeg_x264` (`libx264 medium -b:v 8M`) | 11,202.7 | 933.24 | 933.24 | 898.70 | **1,170,499** | -16.0607 (`0.0607`) | `msSSIM 0.9968`, `ΔE00 p95 1.654`, `OCR=true`, **PASS** (`89.02`) |

- **Honest Assessment:** `safarium-forge` cleanly wins **Speed (`2.90×` vs `ffmpeg_vt`, `2.75×` vs `ffmpeg_x264`)**, **RAM (`-67.4%` `time -l`, `-15.0%` `libproc` combined vs `ffmpeg_vt`; `-89.3%` / `-67.6%` vs `ffmpeg_x264`)**, **Audio LUFS precision (`0.0002` LU error)**, and **Strict Quality (`msSSIM >= 0.9967`, `ΔE00 p95 <= 1.854`, `100%` Thai OCR)**. Two honest caveats: (1) `libproc` combined footprint reduction vs `ffmpeg_vt` is `-15.0%` (`0.850×`), narrower than the `<= 0.40×` target claim because Metal/VT XPC helpers still wire ~202 MiB; (2) `safarium-forge` output bytes are `1.77×–2.31×` larger at nominal `8M` bitrate; and (3) `safarium-forge qa` reported `freezedetect(1)` on all 3 arms due to the synthetic fixture's small moving badge.

---

### H3: VideoToolbox H.264/HEVC vs `x264` / `x265` / `SVT-AV1` Pareto Frontier ([h3.json](bench/experiments/2026-11-24-world-rd/h3.json))

- **Setup:** `150` frames `1080×1920`, `30 fps` deterministic pan + moving HUD from `sompong_cover.jpg` (`src.bgra` / `src.y4m`), 5-point RD sweep per encoder + `N=3` interleaved headline trials under `load1=11.34 → 11.96` (`ticket 3` active).
- **Headline Operating Points (`N=3`):**

| Encoder Config | Wall (ms) | `time -l` FP (MiB) | `libproc` FP (MiB) | Bitrate (kbps) | `SSIM` Mean | `PSNR` Mean | `ΔE00 p95` Max |
|---|---|---|---|---|---|---|---|
| `vt_h264_q72` | **1,454.6** | **85.58** | **142.96** | 4,635.25 | 0.9524 | 35.96 | 3.592 |
| `vt_hevc_q72` | **1,301.9** | **72.25** | **123.78** | 2,951.11 | 0.9477 | 35.60 | 3.637 |
| `x264_slow_dflt_crf21` | 4,235.4 | 711.47 | 711.47 | 1,988.10 | 0.9661 | 37.32 | 3.367 |
| `x264_slow_1t_crf21` | 11,643.7 | 402.75 | 402.75 | 1,975.33 | 0.9661 | 37.32 | 3.367 |
| `x265_med_dflt_crf23` | 4,069.1 | 588.89 | 588.89 | 922.53 | 0.9594 | 36.95 | 3.253 |
| `x265_med_1t_crf23` | 15,292.0 | 435.81 | 435.81 | 884.28 | 0.9594 | 36.97 | 3.263 |
| `svtav1_p5_dflt_crf28` | 7,156.6 | 1,367.14 | 1,367.14 | 1,318.31 | **0.9699** | **38.13** | **2.611** |
| `svtav1_p8_dflt_crf28` | 2,550.3 | 771.88 | 771.88 | 1,543.35 | 0.9669 | 37.86 | 2.744 |
| `svtav1_p8_1t_crf28` | 9,172.8 | 355.70 | 355.70 | 1,543.35 | 0.9669 | 37.86 | 2.744 |

- **Pairwise Verdicts (`VideoToolbox` vs Software Encoders):**
  - **RAM & Speed (`14/14` WINs):** `vt_hevc_q72` achieves **`1.96×–11.75×` speedup** (`1.96×` vs `svtav1_p8_dflt`, `3.13×–3.25×` vs `x265_med_dflt`/`x264_slow_dflt`, `5.50×` vs `svtav1_p5_dflt`, `7.05×–11.75×` vs 1-thread SW) and uses **`5.28%–34.80%` of SW Peak RAM** (`123.78 MiB` `libproc` vs `1,367.14 MiB` `svtav1_p5`). `vt_h264_q72` likewise wins **`7/7` RAM** and **`7/7` Speed** (`1.75×–10.52×`).
  - **Equal-Quality BD-Rate (`8/8` LOSSes — Honest Trade-Off):**

| VT Curve vs Software Reference | BD-Rate (SSIM) | BD-Rate (PSNR) | BD-Rate Verdict |
|---|---|---|---|
| `vt_h264` vs `x264 (slow)` | **+294.41%** | +286.78% | **LOSS** |
| `vt_h264` vs `x265 (medium)` | **+534.61%** | +687.44% | **LOSS** |
| `vt_h264` vs `svtav1 (p5)` | **+1,370.94%** | +2,407.70% | **LOSS** |
| `vt_h264` vs `svtav1 (p8)` | **+847.25%** | +1,431.51% | **LOSS** |
| `vt_hevc` vs `x264 (slow)` | **+174.41%** | +167.14% | **LOSS** |
| `vt_hevc` vs `x265 (medium)` | **+366.01%** | +451.95% | **LOSS** |
| `vt_hevc` vs `svtav1 (p5)` | **+1,045.17%** | +1,768.61% | **LOSS** |
| `vt_hevc` vs `svtav1 (p8)` | **+644.71%** | +1,036.56% | **LOSS** |

- **Interpretation:** H3 cleanly maps the Apple Silicon Pareto frontier: hardware VideoToolbox is ideal for fast, low-RAM intermediate/high-bitrate authoring (`1.3–1.45s`, `<143 MiB`), while software `x265`/`SVT-AV1` deliver dramatically higher compression efficiency at low-bitrate ceilings (`1–2 Mbps`), with `vt_hevc` failing to reach `SSIM >= 0.97` even at `CQF 0.92` (`14.9 Mbps`, `SSIM 0.9666`).

---

### H4: `SafariumRaster` Optimizing Still Encoders vs OpenCV / ImageMagick / `cwebp` / `avifenc` / `cjxl` / `oxipng` / `sharp` ([h4.json](bench/experiments/2026-11-24-world-rd/h4.json))

- **WebP 14-Bit Guard Proof:** `6/6` oversize probes (`16384×1`, `1×16384`, `16000×9000` × lossy VP8 & lossless VP8L) returned `ok=False`, `buf_size=0`, exact string `'WebP dimensions exceed 14-bit limit (max 16383x16383 and 2^27 pixels)'`, with `0.00–0.03 MiB` footprint delta (zero allocation leak/crash).
- **Lossless PNG (`1080×1920` Sompong, `N=15`, all `bit_exact=True` via Pillow):**
  - `sr_png_c9`: **`936.4 ms`**, `2,524,246 B`, `57.30 MiB` `time -l`/`libproc`.
  - vs `cv2_png_c9` (`2,156.3 ms`, `2,564,311 B`, `55.17 MiB`): **Speed WIN (`2.30×` faster / `0.434×` time)**, Size `-1.56%` (**TIE** `<5%`), RAM **TIE** (`1.039×`).
  - vs `magick -c9` (`2,139.1 ms`, `2,488,630 B`, `50.41 MiB` CLI): **Speed WIN (`2.28×` faster)**, Size `+1.43%` (**TIE**), RAM **LOSS** (`1.137×` incl. Python+NumPy heap).
  - vs `oxipng -o 2` (`1,422.2 ms`, `2,427,590 B`, `62.02 MiB` CLI): **Speed WIN (`1.52×` faster)**, Size `+3.98%` (**TIE** within `±5%`), RAM **TIE** (`0.924×`).
  - vs `sharp_png_c9` (`97.1 ms`, `3,529,065 B`, `94.53 MiB`): **Speed LOSS** (`9.64×` slower), **Size WIN** (`-28.5%`), **RAM WIN** (`0.606×`).
- **Lossless WebP (`VP8L`, 0% `libwebp`, all `bit_exact=True` via Pillow):**
  - `1080×1920`: `sr_vp8l` (`496.9 ms`, `1,839,700 B`, `105.55 MiB`) vs `cwebp -m 4` (`712.8 ms`, `1,823,704 B`, `88.28 MiB`): **Speed WIN (`1.43×` faster)**, Size **`1.0088×` (`+0.88%`, TIE well below `<= 1.05×` claim)**, **RAM LOSS** (`1.196×` vs C CLI). Beats `sharp_webp_ll` on speed (`1.81×`) and RAM (`0.776×`) at `+0.50%` size (**TIE**).
  - `512×512`: `sr_vp8l` (`62.9 ms`, `257,994 B`, `37.94 MiB`) vs `cwebp -m 4` (`143.4 ms`, `254,340 B`, `20.22 MiB`): **Speed WIN (`2.28×` faster)**, Size **`1.0144×` (`+1.44%`, TIE)**, **RAM LOSS** (`1.876×` vs CLI); vs `sharp` **WIN** Speed (`1.80×`) & RAM (`0.759×`).
- **Fused C/NEON Color JPEG (`q=90`):**
  - `256×256`: `sr` `0.099 ms` / `17,441 B` / `23.30 MiB` (`SSIM 0.9718`) vs `cv2` `0.102 ms` / `17,528 B` / `25.11 MiB` (`SSIM 0.9719`).
  - `1080×1920`: `sr` **`3.494 ms`** / **`443,893 B`** / `50.06 MiB` (`SSIM 0.9864`, `PSNR 43.35`, `ΔE00 p95 1.917`) vs `cv2` (`libjpeg-turbo`) `4.718 ms` / `444,087 B` / `53.06 MiB` (**Speed WIN `1.35×` faster / `0.741×` time**, Size **TIE `-0.04%`**, RAM **TIE `0.943×`**); vs Apple `ImageIO` (`585,550 B`, `43.28 ms`) **`12.4×` faster and `-24.2%` smaller (`WIN`)**; vs `sharp_mozjpeg` (`373,297 B`, `183.5 ms`) **Speed WIN (`52.5×` faster)** / **Size LOSS (`+18.9%`)**.
  - `4096×4096`: `sr` **`21.767 ms`** / `1,737,428 B` / `298.31 MiB` (`SSIM 0.9877`) vs `cv2` `25.780 ms` / `1,755,612 B` / `300.66 MiB` (**Speed WIN `1.18×`**, Size **TIE `-1.04%`**, RAM **TIE `0.992×`**).
- **Lossy Still BD-Rate (`1080×1920` Sompong, `q=[50..95]/[50..92]` via Pillow/`djxl`):**
  - `sr_jpeg` vs `cv2_jpeg`: **`+0.317%`** (**TIE**)
  - `sr_jpeg` vs `sharp_mozjpeg`: **`+20.585%`** (**LOSS**)
  - `sr_webp` vs `cwebp`: **`-0.467%`** (**TIE**)
  - `sr_avif` (`ImageIO`) vs `avifenc`: **`+17.877%`** (**LOSS**)
  - `sr_avif` (`ImageIO`) vs `cjxl`: **`-44.000%`** (**WIN**)
- **Official `bench_raster.py --area codec --n 15` (`15` cases):**
  - `speed_1t`: **`7W / 3T / 5L`** · `speed_dt`: **`9W / 0T / 6L`** · `ram`: **`3W / 1T / 11L`** · `quality`: **`14T / 1L`** (`imdecode_jpeg.q90_color` `SSIM 0.9883` **but `ΔE00 p95 = 2.177 > 2.0` -> LOSS**) · `size`: **`3W / 4T / 0L`** · overall: **`2 BETTER / 0 TIE / 13 LOSS`** (`1T`: `2 BETTER / 1 TIE / 12 LOSS`). Encoders (`imencode_jpeg`, `imencode_png`) win speed/size while `imdecode_*` and `imencode_png` delta-RAM trigger the `11/15` RAM losses.

---

### H5: APFS `clonefile` Closed-GOP Scene Cache + Mode C Dirty-Region Capture ([h5.json](bench/experiments/2026-11-24-world-rd/h5.json))

- **Setup:** 4-scene × 5 s (`600` frames total @ `1080×1920`, `30 fps`); each scene has `60%` static hold (`90/150` hold frames). Populated `v1` cache (`9,080.5 ms`, `240` captured, `360` Mode C reused), mutated Scene 3 only + injected `._appledouble_junk` into Scene 1 assets, ran `N=3` interleaved trials of `v2_inc` (cache + Mode C) vs `v2_full` (no cache, no Mode C).
- **Results:**
  - **Speed:** `2,887.28 ms` (`v2_inc`) vs `11,126.57 ms` (`v2_full`) = **`3.854×` speedup (`WIN`)**, beating `>= 3.0×`! Scene cache hit `3/4` scenes (`hits=3/4`), Scene 3 captured `60` frames and reused `90` hold frames (`cap=60`, `reused=90`) vs `600` captured / `0` reused in `v2_full`.
  - **Peak RAM:** `126.55 MiB` `time -l` / `183.14 MiB` `libproc` (`v2_inc`) vs `125.97 MiB` / `183.69 MiB` (`v2_full`) = **`TIE` (`1.005×` / `0.997×`)**. The `>= 25%` peak RAM reduction claim is **REFUTED** because rendering the invalidated Scene 3 still incurs the single-scene WebKit/VT footprint peak.
  - **Bit-Exactness & Zero-False-Negative Verification:**
    - `packet_sha256_verification`: `600` total packets; Scenes 1, 2, 4 **`150/150` SHA-256 bit-exact** (`scene1_bit_exact_150f=true` despite `._appledouble_junk`!), Scene 3 invalidated (`scene3_invalidated_and_changed=true`).
    - `safarium-verify`: `rc=0` on both `v2_inc` and `v2_full` (`600` frames, `ITU_R_709_2`, `Left`).
    - `pq_v2_inc_vs_v2_full`: `msSSIM=0.99999917`, `ΔE00 p95=0.0`, `score=99.9998`, `thaiOCROK=true`, `passed=true`.
    - **Mode C Exhaustive 150-Frame Pixel Diff (Scene 3):** **`global_max_abs = 0`, `nonzero_diff_frames = 0`, `mean_abs = 0.0`**, `pq_strict` `thaiOCROK=true` (`"ฉากที่สามแก้ไขแล้ว"`), `score=99.99987`.
  - **CLI Telemetry Quirks Recorded Honestly:** `forge run` successfully wrote & hit `<hash>.mp4` + `<hash>.meta.json` in `/tmp/safarium-world-rd/h5/cache/`, whereas the standalone `safarium-forge cache stats/lookup` CLI returned `entryCount: 0` / `hit: false` (schema mismatch with `ForgeShotCache`) and `safarium-forge cache hash --inputs <dir>` exited `rc=1` on directories (`ForgeIncrementalCache` handles directory hashing in-process during `forge run`).

---

### H6: `SafariumPrism` 2-Engine 3D+Web+Thai vs Cold Blender PNG + Chrome + FFmpeg ([h6.json](bench/experiments/2026-11-24-world-rd/h6.json))

- **6A Preview Stills (`0°, 45°, 90°` @ `1080×1920`, `N=3`):**
  - `prism sync-ir`: `1,252.2 ms` (`rc=0`, `fovYDeg=54.4322°`, `hero.glb` `72,772 B`).
  - `webkitGLB`: **`628.4 ms`** median vs `cold_blender`: `1,961.4 ms` -> **`3.121×` faster (`WIN`)** (note: slightly under the `>= 3.5×` claim under `load1=12.5`), **`0` PNGs** vs `3` PNGs (`2,425,638 B`), and **`24.95 MiB` vs `1,721.36 MiB` Peak Footprint (`0.0145×` = `-98.55%` `time_l` & `libproc` WIN)**. *(Note: `h6.json` `preview_6a.ram.verdict` logged `"TIE"` only because `h6_bench.py:423` omitted RSS arguments so `rss_verdict` defaulted to `"TIE"` in `verdict_ram_worse`.)*
- **6B End-to-End 30-Frame Composite (`1080×1920`, `30 fps`, WebGL2 BG + Blender Alpha Hero + Thai HUD `"สำรวจโลกสามมิติ"`, `N=3`):**
  - **Intermediate PNG Disk:** `safarium_prism` **`0 B` (`0` PNGs) — `100%` elimination (`WIN`)** vs `blender_chrome_ffmpeg` `24,777,585 B` (`23.63 MiB`, `61` PNGs).
  - **Speed:** `11,426.4 ms` (`safarium_prism` writing **both** `H.264 .mp4` + `ProRes 4444 .mov`) vs `11,259.8 ms` (`blender_chrome_ffmpeg` `.mp4` only) -> **`0.985×` (`TIE`)**.
  - **Peak RAM:** `2,037.52 MiB` (`libproc` combined tree) / `291.67 MiB` (`time -l`) / `466.56 MiB` (`max_rss`) vs `1,721.10 MiB` (`libproc`) / `1.59 MiB` (`time -l` of `/bin/sh` wrapper) / `512.89 MiB` (`max_rss`) -> **`LOSS` (`1.184×` `libproc` tree footprint)** because `Prism` keeps Blender + 2 WebKit views + Metal + dual-tee encoders resident simultaneously.
  - **Output Size:** Primary MP4 `1,383,873 B` vs `535,135 B` (`2.59×` **LOSS**) + secondary `ProRes 4444 .mov` `16,609,915 B` (`ap4h`, `hasAlpha=true`).
  - **Quality, `1×` Thai Shield & HID Anti-Lag:** `verify_mp4` `rc=0`, `verify_prores4444_mov` `rc=0`, HID Anti-Lag `totalYieldMs=0` (`0` pause events). Critically, `--metalfx --scale 0.67` auto-verify detected Thai OCR failure (`"Thai OCR missing expected 'สำรวจโลกสามมิติ' (got '')"`) on frame 0 and **automatically fell back to `1×` (`didFallbackTo1x: true`)**, producing **`thaiOCROK: true`** in `pq_vs_baseline`, `msSSIM = 0.9954`, `score = 86.38`, **but `ΔE00 p95 = 2.412 > 2.000`** (`FAIL` strict cross-engine colorimetry vs Chrome+FFmpeg `overlay`).

---

### H7: `SafariumRaster` Phase 2 (`Accelerate`), Phase 3 (`imgproc-filter`), and Opt-In Metal vs OpenCV 5.1 & SciPy ([h7.json](bench/experiments/2026-11-24-world-rd/h7.json))

- **1. Official `bench_raster.py --n 15` (`108` cases across 5 areas, `load1=7.7 → 8.75`, all `†` provisional):**

| Area | Cases | Speed `1T` (W/T/L) | Speed `dflt` (W/T/L) | Peak RAM (W/T/L) | Quality (W/T/L) | Size (W/T/L) | `Overall 1T` (`WIN+TIE` %) | `Overall dflt` (`WIN+TIE` %) |
|---|---|---|---|---|---|---|---|---|
| `draw` | 17 | `5 / 9 / 3` | `12 / 2 / 3` | `0 / 14 / 3` | `0 / 17 / 0` | — | `4B / 7T / 6L` (**64.7%**) | `10B / 2T / 5L` (**70.6%**) |
| `ops` | 42 | `7 / 5 / 30` | `0 / 3 / 39` | `5 / 27 / 10` | `2 / 37 / 3` | — | `7B / 4T / 31L` (**26.2%**) | `0B / 3T / 39L` (**7.1%**) |
| `numpy` | 23 | `5 / 8 / 10` | `4 / 2 / 17` | `1 / 15 / 7` | `0 / 23 / 0` | — | `4B / 8T / 11L` (**52.2%**) | `3B / 2T / 18L` (**21.7%**) |
| `codec` | 15 | `8 / 1 / 6` | `9 / 0 / 6` | `2 / 2 / 11` | `0 / 14 / 1` | `3 / 4 / 0` | `1B / 1T / 13L` (**13.3%**) | `2B / 0T / 13L` (**13.3%**) |
| `sci` | 11 | `4 / 5 / 2` | `4 / 4 / 3` | `9 / 0 / 2` | `1 / 9 / 1` | — | `8B / 0T / 3L` (**72.7%**) | `8B / 0T / 3L` (**72.7%**) |
| **TOTAL** | **108** | **`29 / 28 / 51`** | **`29 / 11 / 68`** | **`17 / 58 / 33`** | **`3 / 100 / 5`** | **`3 / 4 / 0`** | **`24B / 20T / 64L` (`40.7%`)** | **`23B / 7T / 78L` (`27.8%`)** |

- **Overall Acceptance Check:** `40.7%` (`44/108`) `1T` `WIN+TIE` (**REFUTES** the `>= 65% WIN+TIE` hypothesis target; only `sci` `72.7%` and `draw dflt` `70.6%` clear `65%`). Quality parity passes **`103/108` (`95.4%`)**; the 5 quality losses are 3 analytic float32 `warpAffine`/`remap` RMSE differences (`0.072–0.193` vs `0.055–0.187`), `codec.imdecode_jpeg.q90_color` (`ΔE00 p95 = 2.177 > 2.0`), and `sci.tifffile.imwrite` byte-layout (`rel = 1.08e-4`).
- **`cvtColor` Bottleneck Audit vs [bench-results.md](docs/bench-results.md):** `bgr2hsv_u8` (`261 MiB` RAM spike & `121×` slowdown in prior run) is **fixed on RAM** (`0.14` vs `0.34 MiB` RSS, `0.02 MiB` footprint = **RAM TIE**; speed `1.42×`), alongside RAM **TIE** on `bgr2gray_f32` (`0.11 MiB`) and `bgra2bgr_u8` (`0.11 MiB`). However, `bgr2gray_u8` (`33.58 MiB` / `19.1×` slow), `rgb2gray_u8` (`33.59 MiB` / `19.6×` slow), `bgr2gray_u16` (`31.80 MiB`), `bgr2rgb_u8` (`6.06 MiB` / `53.7×` slow), `bgr2bgra_u8` (`3.84 MiB` / `41.2×` slow), and `gray2bgr_u8` (`2.09 MiB` / `22.5×` slow) still show RAM & speed losses.

- **2. Phase 2 Custom (`Accelerate` BLAS/LAPACK/`vDSP`, 10 cases, 1T):**
  - **Speed vs `cv2` (`7/10 WIN+TIE`):** **2 WIN** (`eigen_128_f64`: `0.888 vs 16.729 ms` = **`18.8×` faster**; `pca_512x64_f32`: `0.263 vs 1.736 ms` = **`6.6×` faster**), **5 TIE** (`gemm_512_f32` `0.240 vs 0.233 ms`, `gemm_512_f64` `0.833 vs 0.828 ms`, `solve_256_f64` `0.317 vs 0.347 ms`, `invert_256_f64` `1.003 vs 0.976 ms`, `svd_256_f64` `7.400 vs 7.936 ms`), **3 LOSS** (`dft_1024_f32` `19.525 vs 1.997 ms` [`9.78×`], `dct_512_f32` `4.410 vs 1.350 ms` [`3.27×`], `kmeans_50kx3` `26.137 vs 18.389 ms` [`1.42×`]).
  - **vs `SciPy` (`1.18.1`):** Safarium beats `SciPy` on `solve_256_f64` (`0.317 vs 0.352 ms`), while `SciPy` beats Safarium on `invert` (`0.566 ms`), `svd` (`3.633 ms`), `eigen` (`0.537 ms`), `dft` (`1.961 ms`), and `dct` (`0.660 ms`).
  - **RAM (`8/10 TIE`, `2/10 LOSS` on `dft` `1.48×` & `dct` `1.11×`)** and **Parity (`9/9 PASS`, `rel_err <= 3.16e-15` on f64, `1.04e-6` on f32 `gemm`)**.

- **3. Phase 3 Custom (`imgproc-filter`, 14 cases @ `1080×1920` / `512×512`, 1T):**
  - **Parity:** **`14/14` PASS** (`SSIM = 1.0`, `max_abs = 0.0`, `Canny edge_f1 = 1.0`).
  - **Speed:** **`1/14 WIN`** (`CLAHE` `6.96 vs 8.96 ms` = `0.776×`), **`13/14 LOSS`** (`Canny` `1.11×`, `equalizeHist` `1.71×`, `bgr2hsv` `1.47×`, `bilateral` `3.27×`, `warpPerspective` `10.05×`, `bgr2lab` `12.46×`, `filter2D` `17.52×`, `boxFilter` `18.87×`, `bgr2gray` `20.80×`, `Sobel` `21.54×`, `Scharr` `22.18×`, `Laplacian` `24.61×`, `medianBlur` `54.38×`).
  - **RAM:** **`7/14 TIE`**, **`7/14 LOSS`** (`1.40×–1.76×` on `Sobel`, `Scharr`, `Laplacian`, `Canny`, `boxFilter`, `filter2D`, `bgr2gray`).

- **4. Opt-In Metal GPU (`SAFARIUM_GPU=1`, 13 cases vs `cv2` 1T CPU):**
  - **`4096×4096` (`9` cases):** **`8/9` Speed WIN** (`pow` **`6.32×`**, `log` **`4.33×`**, `phase` **`3.33×`**, `polarToCart` **`3.26×`**, `addWeighted_u8` **`2.81×`**, `exp` **`1.82×`**, `cartToPolar` **`1.69×`**, `magnitude` **`1.43×`** [CPU vDSP path, `disp=0`]), `1` `TIE` (`sqrt` `1.01×`, `disp=0`); **`9/9` Peak RAM TIE** (`0.861×–1.040×`); **`9/9` Parity PASS (`rel_err = 0.0`, `SSIM = 1.0`)**.
  - **`1080×1920` (`4` cases):** **`4/4` Speed WIN** (`pow` **`2.97×`**, `log` **`2.83×`**, `phase` **`1.69×`**, `exp` **`1.22×`**), **BUT `4/4` Peak RAM LOSS (`1.22×`: `129.8–130.5 MiB` vs `106.4–106.6 MiB`)** due to `~23.5 MiB` fixed Metal device/command-queue page-mapping footprint at `1080p`—confirming the exact `1080p` GPU footprint caveat in H7's null hypothesis while proving `>= 2×` speedups at `4K` with zero RAM penalty.

---

## 4. Key Gaps Uncovered for Next Engineering Wave

1. **Cross-Engine WebKit vs Chromium `ΔE00 p95` (`2.002–2.412` in H1 & H6):** Self-consistency and Thai OCR are `100%`, and `MS-SSIM >= 0.9905`, but strict cross-engine `ΔE00 p95 <= 2.0` fails by `0.002` (H1 Scene A) to `0.412` (H6). Needs sRGB/linear compositing calibration or explicit cross-engine vs single-engine reference policy.
2. **SafariumRaster `1T` `ops` & `imdecode` RAM/Speed (`H4`, `H7`):** `40.7%` overall `1T` WIN+TIE falls short of `>= 65%` due to `ops` (`26.2%`: morphology/distance/filters) and `imdecode_*` / `bgr2gray_u8` (`19–39 MiB` delta-RAM + `imdecode_jpeg.q90_color` `ΔE00 p95 = 2.177`). Conversely, `Accelerate` linalg (`70%`), `sci` (`72.7%`), `draw` (`64.7%`), `imencode_jpeg`/`png`, and `4K` Metal GPU (`89%` speed WIN, `0` RAM penalty) are strong wins.
3. **H5 CLI Schema Alignment & H6 Concurrent Footprint:** Align `safarium-forge cache stats/lookup/hash` CLI with `ForgeIncrementalCache` `<hash>.meta.json` + directory inputs, and document `Prism` (`2,038 MiB` concurrent footprint vs `0 B` PNG disk) vs `webkitGLB` (`25 MiB`) clearly for callers.

