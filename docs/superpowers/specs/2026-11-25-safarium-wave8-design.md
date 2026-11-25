---
tags: [safarium, spec, wave8, raster, migration, calibration]
note_type: spec
project: "Safarium"
created: 2026-11-25
updated: 2026-11-25
---

# Safarium Wave 8 Design Spec — `S5` Closure, Batch 2 Migrations, `SafariumRaster` 1T Perf + Phase 4/8, `H5` Cache CLI & Cross-Engine Colorimetry

## 1. Goal & Scope (Pick's 2026-11-25 Approvals)
1. **HyperFrames `S5` Closure (`0.9.65` + `0.9.72`):** Warm `npx hyperframes@0.9.65` online once (with explicit `2026-11-25` approval), verify `Tests/hf/hf-contract-test.py` offline on both `0.9.65` and `0.9.72` (+ `puppeteer-core 25.18.1`), update `Tests/hf/hf-compat.json`, and close `S5` as `✅`.
2. **Batch 2 Migrations (All 6 Active Projects):** Migrate `เรื่องเงินเงินทองทอง`, `เข้าใจตัวเองเเล้วหรือยัง?`, `ห้วงเวลาขาวดำ`, `Do Not Do`, `lemo-opuscar`, and `Sanook Theme` to `safarium` default via `~/.local/bin/safarium-render`. Preserve `.pre-webkit` backups, working `*_BACKEND=legacy` fallbacks, 100% passing existing tests, and `/tmp`-only A/B & smoke renders (never overwrite real episode outputs). Leave `สำรวจไปกับสมพง` untouched pending full `SafariumRaster`.
3. **Technical Debt (`H4`–`H7`), `SafariumRaster` Phase 4 + 8, & Colorimetry Calibration:**
   - Align `safarium-forge cache` CLI (`hash/stats/lookup/prune`) with `ForgeIncrementalCache` (`.mp4` + `.meta.json` + directory inputs).
   - Eliminate `1T` `SafariumRaster` speed/RAM bottlenecks (`cvtColor`, `erode`/`dilate`/`morphologyEx`, Phase 3 filters, `resize`/`warpAffine`/`remap`, `dft`/`dct`, baseline `imdecode_jpeg` C/NEON, ImageIO/TIFF overhead) to raise official `bench_raster.py` `1T` `WIN+TIE` from `40.7%` toward `>= 65%` and bring `imdecode_jpeg.q90_color` `ΔE00 p95 <= 2.0`.
   - Complete **Phase 4 (`geometry + contours`)** (`100%` of `docs/raster-roadmap.md`) and **Phase 8 (`photo`)** with full parity tests vs `cv2 5.1.0.95`.
   - Diagnose & fix cross-engine `ΔE00 p95` root causes across `SafariumCore` (`AccelerateOps`, `FrameSink`, `Snapshot`), `safarium-html`, `ForgeSequenceIngest`, and `PrismHybridEngine` without weakening `ΔE00 p95 <= 2.0`.
   - Rebuild/install Unified Release (`~/.local`), rerun quiet benchmarks (`load1 <= 3.0`), and sync clean mirror to `https://github.com/sanookai/Safarium.git` verifying `macos-15` & `macos-26` Cloud CI GREEN.

## 2. Architecture & File Ownership Partition
- **Wave 8A (5 Parallel Workers, `workspace: "share"`):**
  - `w8-s5-hf0965`: `Tests/hf/hf-compat.json`, `bench/experiments/2026-11-25-wave8/hf-0965.json`, `hf-0972.json`.
  - `w8-forge-color`: `ForgeShotCache.swift`, `ForgeIncrementalCache.swift`, `ForgeCLI.swift`, `FrameSink.swift`, `AccelerateOps.swift`, `Snapshot.swift`, `Sources/safarium-html/**`, `ForgeSequenceIngest.swift`, `PrismHybridEngine.swift`, `ForgeCacheCLITests.swift`, `ColorCalibrationTests.swift`.
  - `w8-raster-perf`: `Sources/SafariumRasterC/{ops_perf_neon.c,include/sr_ops_perf.h,ops_filter.c,jpeg_dec.c}`, `Sources/SafariumRaster/{OpsMorph,OpsFilter,OpsColor,OpsResize,OpsWarp,IOCodec,CorePerf,CoreTransforms}.swift`, `sdk/python/safarium_cv2/cv2/{_numpy_ops.py,_io.py}`.
  - `w8-raster-p4`: `Sources/SafariumRaster/{GeoContours,GeoHoughSeg}.swift`, `Sources/SafariumRasterC/geo_p4.c`, `sdk/python/safarium_cv2/cv2/_geo.py`, `sdk/python/tests/test_parity_phase4.py`.
  - `w8-raster-p8`: `Sources/SafariumRaster/{PhotoOps,PhotoHDR}.swift`, `Sources/SafariumRasterC/photo_p8.c`, `sdk/python/safarium_cv2/cv2/_photo.py`, `sdk/python/tests/test_parity_phase8.py`.
- **Coordinator Merge & Shared Wiring:** `sdk/python/safarium_cv2/cv2/{__init__.py,_constants.py,_ops.py}`, `.github/workflows/ci-macos.yml`, `Tools/github-export/.github/workflows/ci-macos.yml`, Vault tracking notes.
- **Wave 8B (Batch 2 + Quiet Bench):** Independent external project workers (`w8-mig-money`, `w8-mig-self`, `w8-mig-bw`, `w8-mig-donotdo`, `w8-mig-lemo`, `w8-mig-sanook`) followed by `w8-bench-quiet` (`load1 <= 3.0`).
- **Wave 8C (Cloud CI & Final QA):** `w8-cloud-sync` (`sanookai/Safarium`) + `w8-qa-final` independent verification.

## Edge cases
- **Empty inputs & degenerate geometry:** `convexHull`, `minAreaRect`, `fitEllipse`, `fitLine`, `findContours`, `watershed`, `grabCut`, `inpaint`, `seamlessClone`, and `cache hash` handle `0`-point arrays, collinear points, empty masks, zero-area ROIs, and empty directories cleanly with explicit validation errors or canonical empty returns (`[]` / `0`), never segfaulting in C/NEON loops.
- **Thai / Unicode paths & text:** External project directories containing Thai names (`เรื่องเงินเงินทองทอง`, `เข้าใจตัวเองเเล้วหรือยัง?`, `ห้วงเวลาขาวดำ`, `สำรวจไปกับสมพง`), Unicode image filenames, and Vision `th-TH` Thai OCR verification (`1x` preservation without MetalFX degradation) remain lossless and UTF-8 safe across CLI, IPC, and Cache keys.
- **Timezone & determinism:** Virtual clock (`clock.js`), cache timestamps, and parity/CI reports use deterministic monotonic or UTC ISO timestamps and ignore `._*` AppleDouble ExFAT sidecars in directory hashing and frame sequence discovery.
- **Large inputs & memory ceilings:** C/NEON rolling-row morphology and filters avoid `O(W*H)` multi-frame allocations, maintaining `1T` streaming peak RAM near baseline; baseline JPEG decode avoids extra full-frame copies; large HDR/NLM inputs guard allocation sizes and `AVAssetWriter` keeps bounded pool allocation thresholds.
- **Concurrency & queue serialization:** All renders serialize through `~/.local/bin/safarium-render` (`SF-VIDEO-1` single-slot FIFO queue, `1` worker default); Wave 8A writers run in isolated `workspace:"share"` worktrees with disjoint file ownership; `w8-bench-quiet` runs only after migration workers finish and `load1 <= 3.0`.
- **Error paths:** Missing assets, invalid BT.709/alpha formats, unsupported Progressive/CMYK JPEG fallback paths, and non-matching OpenCV constraints surface explicit structured errors (`srFail` / `SafariumError`) rather than silent truncation or weakened assertions; `*_BACKEND=legacy` preserves instant user-controlled fallback on migrated projects.

