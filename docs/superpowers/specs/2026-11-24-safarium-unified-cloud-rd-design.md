---
tags: [safarium, spec, rd, cloud-ci, raster, wave7, cross-platform]
note_type: spec
project: "Safarium"
created: 2026-11-24
updated: 2026-11-24
---

# Safarium Unified Architecture, Global R&D & Cloud CI Spec (2026-11-24)

> **Design Basis (Pick's Confirmed Rulings `2026-11-24`):**
> 1. **Unified Brand & Backward Compatibility:** Consolidate under the umbrella brand **Safarium** (`bin/safarium`) while preserving `bin/safarium-render` 100% as a compatible alias (`SF-VIDEO-1` single-slot FIFO preserved across both).
> 2. **macOS-First, Windows-Ready Core Split:** Optimize macOS Apple Silicon first (`WKWebView`, `Metal`, `VideoToolbox`, `AudioToolbox`, `Accelerate`, `Vision/ANE`, `APFS`), while cleanly isolating OS-agnostic Core interfaces/specs from `AppleMacOSBackend` (`PlatformBackend.swift`) so future Windows support (`Edge WebView2`, `DirectX 12/D2D`, `Media Foundation`) requires zero public CLI/IR/SDK rewrite.
> 3. **Global R&D + Falsifiable Novel Hypotheses (`H1–H7`):** Benchmark head-to-head in `/tmp` only (0% FFmpeg/Chrome/OpenCV in Safarium production binaries) across 4 metrics: **Peak RAM (primary)**, **Speed**, **File Size at equal SSIM/PSNR**, and **Quality (`SSIM >= 0.97`, `PSNR >= 30 dB`, `ΔE00 p95 <= 2.0`, Thai OCR)**. Report WIN, TIE, and LOSE honestly.
> 4. **Public GitHub Repo & Free 2-Tier Cloud macOS CI:** Target `https://github.com/sanookai/Safarium` under **Apache-2.0** License (`Tools/export-public-repo.py`). Export ONLY clean Safarium source/tests/docs/SDK/CI templates — ZERO personal Vault files, ZERO secrets/PII, ZERO `._*`, ZERO hardcoded `external ExFAT volume/...` paths. CI runs Tier 1 (headless Cloud VM build + Core/Containers/Raster/WebKit tests without assuming real Metal/ANE hardware) + Tier 2 (capability probe + micro-benchmark artifacts) on `macos-15` and `macos-14`.
> 5. **Wave 7 & `SafariumRaster` Scope:** Complete Wave 7 minor fixes + 1× `npx hyperframes@0.9.72` cache warmup & E2E `hf-contract-test.py`; enforce WebP 14-bit error policy (`<= 16383` px width/height and `<= 2^27` pixels, error before allocation); rerun `videoio` ProRes 4444 alpha test via FIFO; optimize color JPEG C/NEON encoder vs `cv2`; implement `SafariumRaster` Phase 2 (`linalg + transforms`) & high-impact Phase 3 (`imgproc-filter`). Do **NOT** edit external Batch 2 project files in this round.

---

## 1. Module & File Ownership Map

| Component / Area | Owner (Swarm) | Exclusive Files / Directories |
|---|---|---|
| Global R&D, Cloud Matrix, Cross-Platform Blueprint, Hypotheses | `rd-architect` | `docs/research-2026-11-24/{world-video-ecosystem-matrix.md,free-cloud-macos-runners.md,cross-platform-core-windows-blueprint.md,novel-hypotheses.md}` |
| Wave 7 Core, Unified CLI, OS Abstraction, SDK Guards, HF S5 | `core-wave7` | `Sources/SafariumForgeCore/{ForgeAdaptiveWebKitPool.swift,ForgeIncrementalCache.swift,ForgeMetalFilters.swift}`, `Sources/SafariumContainers/OggVorbisDecoder.swift`, `Sources/SafariumCore/PlatformBackend.swift`, `Sources/SafariumPrism/**` (SDK/Metal guards only), `bin/safarium`, `Tools/install-render.py`, `Tests/SafariumCoreTests/**`, `Tests/SafariumForgeTests/**`, `Tests/SafariumContainersTests/**`, `Tests/queue/test_queue.py`, `Tests/hf/**` |
| SafariumRaster (WebP Policy, JPEG Speed, Phase 2 & 3) | `raster-engine` | `Sources/SafariumRaster/**`, `Sources/SafariumRasterC/**`, `sdk/python/safarium_cv2/**`, `sdk/python/tests/**` |
| Reproducible World Head-to-Head Lab (`/tmp`) | `bench-lab` (Wave B) | `bench/experiments/2026-11-24-world-rd/**`, `docs/research-2026-11-24/experiment-results.md` |
| Clean Public Repo Export & Cloud macOS CI | `cloud-release` (Wave B) | `Tools/export-public-repo.py`, `Tools/github-export/**`, `.github/workflows/ci-macos.yml`, `bench/experiments/2026-11-24-cloud-ci/**`, `docs/research-2026-11-24/cloud-ci-results.md` |
| Final Gate & Audit | `verifier` (Wave C) | Read-only audit across repo, release binaries, tests, and public CI |

---

## 2. Core Technical Specifications

### 2.1 Wave 7 & macOS 14/15 Cloud SDK Compatibility
- **`ForgeAdaptiveWebKitPool.swift`:** Walk Darwin `proc_listallpids` + `proc_pidinfo(..., PROC_PIDTBSDINFO, ...)` parent→child trees from `rootPIDs` so `telemetrySampler` accounts for worker AND WebKit XPC helper (`com.apple.WebKit.*`) physical footprints.
- **`ForgeIncrementalCache.swift`:** Directory inputs in `computeKey(...)` recurse deterministically in lexicographical relative-path order, skip `._*`, reject symlinks outside regular tree, and digest `(relPath, byteSize, sha256)`.
- **`ForgeMetalFilters.swift` (`ForgeLLSRUpscaler` + Cloud Metal Guard):** Reuse `VTFrameProcessor` session + resolved NV12 `CVPixelBuffer`s keyed by `(inW, inH, targetW, targetH, matchedScale)` with cleanup on resize/`deinit`. Guard macOS 26+ `VTFrameProcessor`/`VTLowLatencySuperResolutionScalerConfiguration` with `#if compiler(>=6.2)` (or verified SDK compile guard) so Xcode 15/16 on `macos-14`/`macos-15` compiles cleanly. Handle `MTLCreateSystemDefaultDevice() == nil` gracefully in Metal engines with explicit `SafariumError` (no nil force-unwrap crashes on headless VMs).
- **`PlatformBackend.swift`:** Protocols (`SafariumPlatformBackend`, `WebFrameRendererBackend`, `VideoEncoderBackend`, `FilesystemCloneBackend`) + `AppleMacOSBackend` reporting live OS/hardware capability metadata.
- **`bin/safarium` + `Tools/install-render.py`:** Unified CLI aliasing `safarium` alongside `safarium-render`, plus `safarium hf ...` and `safarium raster info`.

### 2.2 `SafariumRaster` WebP Policy, Color JPEG, Phase 2 & High-Impact Phase 3
- **WebP 14-bit Policy:** Enforce `width > 0 && height > 0 && width <= 16383 && height <= 16383 && Int64(width) * Int64(height) <= (1 << 27)` at both Swift (`IOWebP.swift`, `IOWebPLossy.swift`) and C (`webp_ll.c`, `webp_vp8.c`) entrypoints BEFORE allocation; return `SRStatus.badArgument` with descriptive message.
- **Color JPEG Optimization:** Fuse MCU YCbCr 4:2:0 + NEON FDCT + quantization + Annex K Huffman bit-packing + `0xFF` byte-stuffing in C (`Sources/SafariumRasterC/`) over 16-row strips to remove Swift↔C per-block dispatch overhead while preserving byte/SSIM parity with IJG/OpenCV and ASan/UBSan safety.
- **Phase 2 (`linalg + transforms`):** `gemm`, `solve`, `invert`, `SVDecomp`, `SVBackSubst`, `eigen`, `eigenNonSymmetric`, `determinant`, `trace`, `PCACompute`/`PCAProject`/`PCABackProject`, `dft`, `idft`, `dct`, `idct`, `mulSpectrums`, `getOptimalDFTSize`, `kmeans`, `Mahalanobis`, `calcCovarMatrix`, `solvePoly` via Accelerate `BLAS`/`LAPACK`/`vDSP`.
- **Phase 3 (`imgproc-filter` core):** `Sobel`, `Scharr`, `Laplacian`, `Canny`, `bilateralFilter`, `medianBlur`, `boxFilter`, `filter2D`, `sepFilter2D`, `integral`, `pyrDown`, `pyrUp`, `createCLAHE`, `equalizeHist`, `adaptiveThreshold`, `applyColorMap`, `getPerspectiveTransform`, `warpPerspective`, expanded `cvtColor` (Lab/Luv/YUV/YCrCb/HLS/HSV/RGB/BGR/Gray).

---

## 3. Edge Cases & Verification Gates

1. **Empty / degenerate inputs:** Zero-byte files, 0×0 images, empty input folders, singular/non-square matrices (`solve`/`invert`), empty `kmeans` inputs -> explicit typed error (`SafariumError` / `SRStatus.badArgument`), zero crashes or NaN propagation.
2. **Thai / Unicode:** Diacritics/tone marks in WebKit render + Vision OCR, percent-encoded Thai filenames in `--font-dir`, UTF-8 paths in `export-public-repo.py` & `SafariumRaster` IO.
3. **Timezone / determinism:** Explicit UTC/Asia-Bangkok timestamps, 3-run identical `VirtualClock` hash, deterministic RNG seeds in `kmeans` and benchmarks.
4. **Large inputs & memory safety:** WebP `>16383` or `>2^27 px` rejected pre-alloc; bounded strip buffers in color JPEG verified under ASan/UBSan; `psutil`/`resource`/`vmmap` physical footprint captured alongside `ru_maxrss`.
5. **Concurrency & queue safety:** Never steal or abort another session's `safarium-render` FIFO lock; child process cleanup verified on error/cancel; `._*` AppleDouble files filtered across directory scans and public export.
6. **Cloud VM / Older SDKs:** No unconditional reliance on macOS 26+ SDK headers or live Metal/ANE hardware in CI Tier 1; CI workflows run cleanly on `macos-15` and `macos-14` without secrets or personal Vault dependencies.

