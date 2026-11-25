---
tags: [safarium, ci, cloud, macos, github-actions, verification, telemetry]
note_type: research
project: "Safarium"
created: 2026-11-25
updated: 2026-11-25
---

# Safarium macOS Cloud CI Results & Cross-OS Verification (Run `45526649058`)

> **Summary:** **GREEN across both `macos-15` (`15.8.2`, Xcode `16.4`, Swift `6.1.2`) and `macos-26` (`26.7.2`, Xcode `26.6`, Swift `6.3.3`)** on GitHub Actions `macOS Cloud CI` Run **`45526649058`** ([actions/runs/45526649058](https://github.com/sanookai/Safarium/actions/runs/45526649058)) at public mirror commit `efb4a84e848b8f24090cba0a977ad2358d9376d2` (synced from Vault repo commit `32e3450`). All 4 workflow jobs (`Tier 1` and `Tier 2` on both OS releases) finished `success`, and `Tier 2` confirmed **bit-for-bit identical deterministic `H.264` video output hashes** across `macos-15` and `macos-26` inside Apple `Virtualization.framework` Cloud VMs.

---

## 1. Public Repository & Apache-2.0 Hygiene Gate

| Item | Verified Value |
|---|---|
| **Public Repository URL** | `https://github.com/sanookai/Safarium` (`https://github.com/sanookai/Safarium.git`) |
| **Branch / Green HEAD** | `main` @ `efb4a84e848b8f24090cba0a977ad2358d9376d2` (`efb4a84`) |
| **Vault Repo HEAD at Export** | `32e34503af7d145a9c4802e5642b59f1bbf1e5f0` (`32e3450`, `.github/workflows/ci-macos.yml` byte-identical to `Tools/github-export/.github/workflows/ci-macos.yml`) |
| **License & Export Audit** | `python3 Tools/export-public-repo.py --audit-dir /tmp/safarium-public-mirror-v2 --json` -> `scannedFiles: 340`, `violationCount: 0`, `"passed": true`, `"ok": true` |
| **Step 4 CI Self-Audit** | Executed in CI on both `macos-15` and `macos-26` against `/Users/runner/work/Safarium/Safarium`: `violationCount: 0`, `"passed": true` |
| **Excluded / Sanitized Paths** | Private Vault ops docs, personal paths, external benchmark media (`../สำรวจไปกับสมพง` sanitized to `/nonexistent-safarium-bench-assets` in exported `sdk/python/tests/bench_cases/_common.py`), and third-party caches/artifacts excluded (`385` excluded / `45` sanitized on export) |

---

## 2. Commit History (`698df9a` -> `efb4a84`)

Thirteen commits on `https://github.com/sanookai/Safarium.git` (`main`) took Safarium from initial Apache-2.0 public export to full dual-OS Cloud CI green:

| # | Public SHA | Vault SHA | Subject & Key Technical Fix |
|---|---|---|---|
| 1 | `698df9a` | — | `Safarium: Apache-2.0 public release with Apple Silicon media/raster stack and macOS Cloud CI` |
| 2 | `579d83d` | `ca104b9` | `fix(cli): rename @main files away from main.swift for Swift 6.1/6.3 CI` |
| 3 | `ab5d0f9` | `a975334` | `fix(swift): simplify Swift 6.1/6.3 type-checking and UInt8 literal inference for macOS CI` (`DrawText.swift`, `SnapshotQualityProbeTests.swift`, `MPEGTSContainer.swift`, `WebPAVIFEncoder.swift`, `IOCodec.swift`) |
| 4 | `336ce6c` | `1708e42` | `fix(ci): clear Swift 6.1 raster type-checks, temp fixture fallback, and container audio preroll parity` (`IOCodec.swift`, `IOEXR.swift`, `IOJPEG.swift`, `IOWebP.swift`, retained-viewport temp fallback) |
| 5 | `40e64fb` | `a1d48db` | `fix(ci): resolve remaining Swift 6.1 test compile checks and log MP4 audio mismatch details` (`ContainerTests.swift`, `LegacyContainerVorbisTests.swift`, `[diag:]` logging) |
| 6 | `08e8602` | `7a94191` | `Inject AAC roll sample groups and gate macOS 15 AVIF write` (fixes `public.avif` ImageIO write expectations on `macos-15`) |
| 7 | `9d34f0d` | `a3efec7` | `Strip duplicate AAC priming clones on pre-macOS 27 passthrough MP4` (fixes all 4 `ContainerTests` AAC parity cases on `macos-15` & `macos-26`) |
| 8 | `dcf4700` | `c94db45` | `Normalize SwiftPM virtual clock bundle layout in macOS CI` (normalizes `Safarium_SafariumCore.bundle/Contents/Resources/clock.js` layout for `install-render.py`) |
| 9 | `8dce8ed` | `edb6ca8` | `CI: pass SAFARIUM_RENDER_BIN to shell SDK, guard snapshot/subtitle waits, unbuffer XCTest` (`Page.swift` `withTimeout(30)` on snapshot, `SubtitleWriterTests.swift` chronological `si`/`vi` interleave + `waitReady` 15s deadline, `script -q /dev/null` PTY unbuffering, `SAFARIUM_RENDER_BIN` for `safarium-forge.sh`) |
| 10 | `a583d7a` | `1b4cfda` | `CI: fix Step 11 WebP lossless/14-bit policy contract and Step 12 bench_raster env` (`[cv2.IMWRITE_WEBP_QUALITY, 101]` lossless flag, `(False, empty)` contract for >14-bit WebP, `BENCH_CV2_PYTHON`, deselected local-asset Sompong test) |
| 11 | `6bba4c8` | `cf60656` | `SafariumRaster: native BMP & scanline EXR decoders for macOS 15/26 parity` (`IOFormats.swift` `ioDecodeBMP` for BMP V3/V4 BGRA & gray; `IOEXR.swift` `ioDecodeEXR` using Apple `Compression` zlib for `HALF`/`FLOAT` `Y`/`Z`/`B,G,R`/`A,B,G,R`; `IOCodec.swift` `.cv14` gray weights on BMP) |
| 12 | `a12ea04` | `1ab3039` | `CI: guard shared-VM timer-coalescing sleep checks in test_bench_raster` (deselect `test_speed_worker_reports_median_samples_and_load` & `test_run_case_end_to_end_on_a_cheap_case_gives_the_expected_verdicts` under `CI=true`) |
| 13 | `efb4a84` | `32e3450` | `CI: fix bash pytest -k join in Step 12` (fixes bash `IFS=" and "` single-char splitting bug into explicit `"$expr1 and $expr2 and $expr3"`) |

---

## 3. Full Run-by-Run Diagnosis (`45435651176` -> `45526649058`)

All 13 CI runs are archived under [bench/experiments/2026-11-24-cloud-ci/](../../bench/experiments/2026-11-24-cloud-ci/):

| Run ID | Public SHA | Outcome | `macos-15` Diagnosis | `macos-26` Diagnosis | Root Cause & Resolution |
|---|---|---|---|---|---|
| `45435651176` (att 1/2) | `698df9a` | `failure` | Step 6 compile error | Step 6 compile error | `Sources/safarium-regions/main.swift:92:1` `@main` in `main.swift` (`'main' attribute cannot be used in a module that contains top-level code`). Fixed in `579d83d`. |
| `45444268053` | `579d83d` | `failure` | Step 6 compile error | Step 9 test compile error | `macos-15` Swift 6.1 failed on `DrawText.swift:215`, `WebPAVIFEncoder.swift:661` (`Int`->`UInt8`), `MPEGTSContainer.swift:236`, `IOCodec.swift:272,280`; `macos-26` Swift 6.3 failed on `SnapshotQualityProbeTests.swift:18`. Fixed in `ab5d0f9`. |
| `45488412371` | `ab5d0f9` | `failure` | Step 6 compile error | Step 9 `225` tests, `32` skipped, **`6` failures** | `macos-15` Swift 6.1 type-check limits in `IOCodec.swift:461`, `IOEXR.swift:23`, `IOJPEG.swift:391-393`, `IOWebP.swift:85`; `macos-26` hit 2 Vault-only bench fixture misses (`RetainedViewport*`) + 4 `ContainerTests` AAC parity mismatches. Compile + fixtures fixed in `336ce6c`. |
| `45495440137` | `336ce6c` | `failure` | Step 9 test compile error | Step 9 `225` tests, `32` skipped, **`4` failures** | `macos-15` cleared `Sources/` build cleanly; failed compiling `ContainerTests.swift:260-261` and `LegacyContainerVorbisTests.swift:671`. Fixed + `[diag:]` added in `40e64fb`. |
| `45498563869` | `40e64fb` | `failure` | Step 9 `225` tests, `32` skipped, **`7` failures** | Step 9 `225` tests, `32` skipped, **`4` failures** | `macos-15` cleared all Swift 6.1 compilation; hit `public.avif` unsupported write (`testRemuxInspectImageSheetComparePQAndQA`, `testStillImage_AllSupportedFormats_AndAVIFLosslessRejects`) plus same 4 AAC `ContainerTests` (`testEBML_H264_AAC_ThaiSubtitles...`, `testEBML_HEVC_AAC...`, `testMPEGTS_H264_ADTS...`, `testMPEGTS_HEVC_ADTS...`). AVIF gated in `08e8602`. |
| `45502844041` | `08e8602` | `failure` | Step 9 `225` tests, `32` skipped, **`4` failures** | Step 9 `225` tests, `32` skipped, **`4` failures** | AVIF/CLI tests green on `macos-15`; `[diag:]` captured exact root cause of all 4 AAC failures: `stsz cnt=52`, `elst=[(94080,960)]`, duplicate priming packet hash at index `0`/`1` (`76f857...`). Fixed via priming clone strip in `9d34f0d`. |
| `45505961316` | `9d34f0d` | `cancelled` | Step 9 hung after `ContainerTests` (`18/18` passed) | **Step 9 PASSED `226/226` (`0` failures)**; Step 10 failed | `macos-26` cleared Swift XCTest 100%, failed Step 10 because SwiftPM on CI creates flat bundle layout missing `Contents/Resources/clock.js`; `macos-15` log halted in 16 KB block buffer. Bundle normalized in `dcf4700`. |
| `45510182880` | `dcf4700` | `cancelled` | Step 9 still stalled/buffered | Step 9 PASSED `226/226`; Step 10 failed (`exit 127`) | `macos-26` passed `install-render.py` and Python SDK, failed `sdk/shell/safarium-forge.sh:15` defaulting to `/Users/runner/.local/bin/safarium-render` without `SAFARIUM_RENDER_BIN`. Fixed shell env + snapshot/subtitle wait guards + PTY unbuffering in `8dce8ed`. |
| `45514204843` | `8dce8ed` | `failure` | **Steps 1..10 PASSED (`226/226`)**; Step 11 failed | **Steps 1..10 PASSED (`226/226`)**; Step 11 failed | Both OSes cleared XCTest, Queue (`23/23`), Rule-Sync, and Shell SDK; Step 11 smoke failed `AssertionError: .webp lossless roundtrip mismatch` because `.webp` encode without `[cv2.IMWRITE_WEBP_QUALITY, 101]` uses OpenCV lossy q=95 default. Fixed Step 11 contract + Step 12 `BENCH_CV2_PYTHON` in `a583d7a`. |
| `45517243137` | `a583d7a` | `failure` | **Steps 1..11 PASSED**; Step 12 failed `test_parity_io` (BMP + EXR) | **Steps 1..11 PASSED**; Step 12 failed `test_parity_io` (BMP) | Apple ImageIO returned `None` on `BITMAPV4HEADER` BGRA `.bmp` (`(37,53,4)`) on both OSes and downgraded 1-ch `"Y"` float32 `.exr` to `uint8` on `macos-15`. Fixed natively (`IOFormats.swift`, `IOEXR.swift`, `IOCodec.swift`, Apple-only `Compression`) in `6bba4c8`. |
| `45521187989` | `6bba4c8` | `failure` | **All 8 parity suites (`504` I/O) PASSED**; `test_bench_raster` failed sleep-2ms check | **All 8 parity suites (`504` I/O) PASSED**; `test_bench_raster` failed `selftest.ab` verdict | Shared Cloud VM timer coalescing floored `time.sleep(0.002)` at `19.51–27.08 ms` (`med=0.022886708s > 0.02s`), causing `selftest.ab` (`2ms` vs `8ms`) to report `TIE`. Guarded micro-timing sleep assertions under `CI=true` in `a12ea04`. |
| `45524071740` | `a12ea04` | `failure` | Step 12 `pytest -k` syntax error | Step 12 `pytest -k` syntax error | `IFS=" and "` in bash treats each character (`a`, `n`, `d`, ` `) as a delimiter, corrupting `-k`. Fixed explicit `and` string in `efb4a84`. |
| **`45526649058`** | **`efb4a84`** | **`success`** | **Tier 1 `success` (`26m13s`) · Tier 2 `success` (`3m28s`)** | **Tier 1 `success` (`18m19s`) · Tier 2 `success` (`3m54s`)** | **ALL 4 JOBS GREEN** (`138911567138`, `138911567465`, `138921909385`, `138921909598`). |

---

## 4. Exact `macos-15` & `macos-26` Tier 1 Pass Matrix (Run `45526649058`)

### Runner Environment (Step 3 Preflight)

| Metric | `macos-15` (`138911567138`) | `macos-26` (`138911567465`) |
|---|---|---|
| **OS & Build** | `macOS 15.8.2` (`24H232`, `macos-15-arm64`) | `macOS 26.7.2` (`25G332`, `macos-26-arm64`) |
| **Xcode & Swift** | `Xcode 16.4` (`16F6`) · `Apple Swift 6.1.2` (`arm64-apple-macosx15.0`) | `Xcode 26.6` (`17F113`) · `Apple Swift 6.3.3` (`arm64-apple-macosx26.0`) |
| **VM Hardware & Python** | `3` vCPU · `7 GiB` RAM (`7516192768 B`) · `/tmp` `320 GiB` (`44 GiB` free) · `Python 3.15.2` | `3` vCPU · `7 GiB` RAM (`7516192768 B`) · `/tmp` `320 GiB` (`96 GiB` free) · `Python 3.15.2` |

### Step-by-Step Verification Counts

| Tier 1 Check | `macos-15` Result | `macos-26` Result | Notes / Exact Scope |
|---|---|---|---|
| **Step 4: Hygiene & License Gate** | `PASS` (`340` files, `0` violations) | `PASS` (`340` files, `0` violations) | `Tools/export-public-repo.py --audit-dir . --json` |
| **Step 6: Debug + Release Build + `safarium-verify`** | `PASS` (`8m22s`) | `PASS` (`6m51s`) | `xcrun swift build` & `-c release` (`--jobs 2`) + `safarium-verify` |
| **Step 7: Apple-Only Linkage (`otool -L`)** | `PASS` (8/8 Apple-only: `44/44/47/45/44/44/34/33` deps) | `PASS` (8/8 Apple-only: `44/44/47/45/44/44/27/34` deps) | Checked `safarium-html`, `safarium-media`, `safarium-forge`, `safarium-cdp`, `safarium-bench`, `safarium-regions`, `safarium-verify`, `libSafariumRaster.dylib` |
| **Step 8: `SafariumRasterC` ASan + UBSan** | `PASS` (`21s`) | `PASS` (`15s`) | Deflate, VP8L + 14-bit dimension guard, JPEG YCbCr, NEON `src_addsub`, Accelerate BLAS GEMM, CLAHE + Canny |
| **Step 9: Swift XCTest Suite (`--no-parallel`)** | **`226` executed, `32` skipped, `0` failures** (`292.772s` XCTest / `5m44s` step) | **`226` executed, `32` skipped, `0` failures** (`150.916s` XCTest / `3m10s` step) | All unit/integration suites incl. `ContainerTests` (`18` exec, `1` skip). Exact `32` skips: `16` opt-in `SAFARIUM_PROBES=1` probes (`Focus` 2, `Memory` 4, `QualityCompare` 1, `SnapshotQuality` 1, `Video` 8) + `9` missing npm probe-libs (`Font` 2, `Library` 7) + `4` missing `Blender.app`/MetalFX/ANE (`PrismEngineTests`) + `1` `SAFARIUM_PERF=1` (`PerfTests`) + `1` physical ANE Vision cutout (`MediaToolsTests`) + `1` Cloud VM VideoToolbox hw-block skip (`ContainerTests`) |
| **Step 10: Isolated Install + CLI + Queue + Rule-Sync + SDKs** | `PASS` (`1m06s`) | `PASS` (`1m04s`) | `install-render.py` (`c3dd85f6...` / `1707e933...` release hash) + `--check`, `safarium doctor/raster-info/version`, `SafariumForge` Python SDK (`safarium-forge.py --self-test`), Shell SDK (`safarium-forge.sh --help`), `Tests/queue/test_queue.py` (`23/23` OK in `58.055s` / `57.568s`), `rule-sync.py` (`"status": "PASS"`). *(Note: `node` absent on runner PATH, so `if command -v node` skipped `safarium-forge.mjs --self-test`.)* |
| **Step 11: Zero-OpenCV/Zero-SciPy Raster Smoke & WebP 14-bit Policy** | `PASS` (`11s`) | `PASS` (`12s`) | Direct `ctypes` ABI parity check incl. lossless WebP (`[IMWRITE_WEBP_QUALITY, 101]`) & `(False, empty)` reject at `16384px` |
| **Step 12: `test_parity_core.py`** | **`6,373 passed`**, `5 warnings` (`8.52s`) | **`6,373 passed`**, `5 warnings` (`4.91s`) | Exact OpenCV/NumPy parity (core, arith, math, compare, reduce, random) |
| **Step 12: `test_parity_numpy.py`** | **`378 passed, 2 skipped`** (`105.20s`) | **`378 passed, 2 skipped`** (`67.26s`) | NumPy array interop & dtype conversions |
| **Step 12: `test_parity_draw.py`** | **`1,080 passed`** (`376.96s`) | **`1,080 passed`** (`236.67s`) | 2D primitives, anti-aliasing, text rendering parity |
| **Step 12: `test_parity_ops.py`** | **`512 passed`** (`36.46s`) | **`512 passed`** (`21.78s`) | Blur, resize, warp, morphology, threshold parity |
| **Step 12: `test_parity_io.py`** | **`504 passed`** (`32.20s`) | **`504 passed`** (`21.51s`) | PNG, JPEG, TIFF, WebP, GIF, HDR, PNM, **BMP V4 & scanline EXR** across both OSes |
| **Step 12: `test_parity_linalg.py`** | **`64 passed`** (`0.49s`) | **`64 passed`** (`0.40s`) | Accelerate BLAS/LAPACK + vDSP DFT |
| **Step 12: `test_parity_imgproc.py`** | **`138 passed`** (`0.84s`) | **`138 passed`** (`0.81s`) | Canny, CLAHE, contours, colormaps, connected components |
| **Step 12: `test_gpu.py` (Metal/GPU enabled)** | **`579 passed`** (`4.07s`) | **`579 passed`** (`2.81s`) | Runs against `Apple Paravirtual device` GPU in Cloud VMs |
| **Step 12: `test_bench_raster.py`** | **`47 passed, 3 deselected`** (`13.68s`) | **`47 passed, 3 deselected`** (`11.52s`) | *Filtered scope (3 CI deselections):* Sompong local Vault video asset (`1`), shared-VM sleep-coalescing `<20ms` timing micro-checks (`2`) |
| **Step 12: `test_gpu.py` (`SAFARIUM_GPU_DISABLE=1`)** | **`114 passed, 465 skipped`** (`1.17s`) | **`114 passed, 465 skipped`** (`0.80s`) | CPU fallback path verified; GPU-only tests skipped cleanly |

---

## 5. Tier 2 Cloud VM Telemetry & Determinism (`artifacts/safarium-tier2-macos-{15,26}/`)

Both `Tier 2 · Capability Probe & Telemetry` jobs (`138921909385` on `macos-15`, `138921909598` on `macos-26`) installed release builds into an isolated prefix, collected `doctor.json`, `capabilities.json`, `raster-info.json`, and `smoke-telemetry.json`, and uploaded zip artifacts (`4,939 B` `macos-15`, `4,936 B` `macos-26`).

| Telemetry Field | `macos-15` (`15.8.2` `24H232`) | `macos-26` (`26.7.2` `25G332`) | Observation / VM Constraint |
|---|---|---|---|
| **`doctor.json`** | `healthy: true`, `issues: []`, `hints: []`, `tmpFreeGB: 43.41`, `volumesMainMounted: false`, `blender522Installed: false` | `healthy: true`, `issues: []`, `hints: []`, `tmpFreeGB: 95.01`, `volumesMainMounted: false`, `blender522Installed: false` | All 4 workers `present: true, appleOnly: true` (`safarium-html: 44`, `safarium-media: 44`, `safarium-forge: 47`, `safarium-verify: 34`/`27` deps) |
| **Metal (`capabilities.json`)** | `available: true`, `deviceName: "Apple Paravirtual device"`, `hasUnifiedMemory: true`, `recommendedMaxWorkingSetMiB: 4778.671875` | `available: true`, `deviceName: "Apple Paravirtual device"`, `hasUnifiedMemory: true`, `recommendedMaxWorkingSetMiB: 4778.671875` | Paravirtualized GPU supports Core Image / Metal raster ops (`test_gpu.py` 579/579 passed), **not** bare-metal MetalFX/ANE workloads |
| **ANE (`capabilities.json`)** | `aneVisionAvailable: false` | `aneVisionAvailable: false` | Apple `Virtualization.framework` exposes **no physical Apple Neural Engine** to guest VMs (`Vision` mask cutout / ANE probes safely skipped in Tier 1) |
| **ImageIO (`capabilities.json`)** | **`avifWrite: false`**, `heicWrite: true`, `heicsWrite: true`, `jpgWrite: true`, `pngWrite: true`, `webpPureSwiftVP8LWrite: true` | **`avifWrite: true`**, `heicWrite: true`, `heicsWrite: true`, `jpgWrite: true`, `pngWrite: true`, `webpPureSwiftVP8LWrite: true` | **Verified OS capability divergence:** `macos-15` lacks ImageIO `public.avif` encoder; `Safarium` detects this cleanly via `Capabilities` instead of failing |
| **VideoToolbox (`capabilities.json`)** | `h264`/`hevc`/`hevc-alpha`: `hwDecode=true, hwEncode=true`; `prores4444`/`vp9`/`av1`: `hwDecode=true, hwEncode=false` | Same (`h264`/`hevc`/`hevc-alpha` `true/true`; `prores4444`/`vp9`/`av1` `true/false`) | AudioToolbox `aac`/`pcm_wav` `decode=true, encode=true`; `mp3`/`flac`/`caf_opus`/`ogg_vorbis`/`ogg_flac`/`mpeg2_ps` `decode=true`; `ogg_opus` `false` (`'fmt?'`) |
| **Volumes (`capabilities.json`)** | Workspace & `/tmp` on `apfs` (`supportsClonefile: true`, `supportsRenameExcl: true`) | Same (`apfs`, `clonefile: true`, `RENAME_EXCL: true`) | No ExFAT staging penalty inside CI VMs |
| **`raster-info.json`** | `present: true`, `appleOnly: true`, `abi.version: 1`, `symbolCount: 197` | `present: true`, `appleOnly: true`, `abi.version: 1`, `symbolCount: 197` | C ABI symbol parity identical across macOS 15 & macOS 26 |
| **WebKit Smoke Render (`smoke-telemetry.json`)** | `html_exit: 0`, `verify_exit: 0`, `footprintMB: 19.5`, `wallMs: 1682.087`, `html_stderr: "IOServiceMatchingfailed for: AppleM2ScalerParavirtDriver"` | `html_exit: 0`, `verify_exit: 0`, `footprintMB: 21.28`, `wallMs: 2619.425`, `html_stderr: "IOServiceMatchingfailed for: AppleM2ScalerParavirtDriver"` | Synthetic `256x256 @ 30fps`, `10` frames `--video-only` H.264 render; `safarium verify` reports `differingSections: []` |
| **Cross-OS Determinism Hashes (`smoke-telemetry.json`)** | File SHA-256: `85cdc8f37ce49e208fc38722180fa87adf3a3532013c02c52de27597664c49cf`<br>Active NV12 SHA-256: `2aa931c13e7c7601faec8e2881ed70d4490706de7a915f10735314fc8757607f`<br>PTS/Durations SHA-256: `18a47cc8982fc18ddf729533e81ff834460cfb7bd5e9a001419c456a117a6eed` | **Exact byte-for-byte match** (`85cdc8f3...`, `2aa931c1...`, `18a47cc8...`) | Deterministic WebKit `takeSnapshot` + `AVAssetWriter` H.264 output across macOS 15.8.2 and macOS 26.7.2 |

---

## 6. Cloud VM Limitations Observed (Honest Boundary Summary)

1. **No physical ANE / bare-metal MetalFX (`aneVisionAvailable: false`, `Apple Paravirtual device`):** Vision foreground instance cutout, MetalFX spatial upscaling, and Blender+WebKit hybrid E2E probes cannot run on GitHub-hosted macOS VMs; these stay gated for bare-metal verification (`bench-lab` / future MacStadium FOSS bare-metal runner).
2. **Paravirtualized scaler stderr & `node` absence:** `safarium html` logs non-fatal `IOServiceMatchingfailed for: AppleM2ScalerParavirtDriver` on Cloud VMs with `exit 0` and clean `safarium verify` output. Also, `node` is not on the default runner PATH in Step 10, leaving `sdk/node/safarium-forge.mjs --self-test` unexercised in Cloud CI while Python and `/bin/sh` SDKs ran and passed.
3. **Shared-VM timer coalescing (~20–27 ms floor):** Under macOS hypervisor CPU contention, `time.sleep(0.002)` wakes at `19.51–27.08 ms` (`test_bench_raster.py` Run `45521187989`), violating sub-20 ms bare-metal timing thresholds and collapsing a `2 ms` vs `8 ms` A/B difference into `TIE`. Deselecting those 2 sleep micro-timing tests (plus the local Vault Sompong episode fixture test) under `CI=true` keeps all `47` remaining benchmark harness tests active while eliminating hypervisor scheduling flakiness.
4. **macOS 15 OS differences caught & fixed cleanly:**
   - Xcode 16.4 / Swift 6.1 strict type-checker expression timeouts in `Sources/SafariumRaster/` and `Tests/SafariumContainersTests/`.
   - Missing `public.avif` ImageIO encoder on `macos-15` (`Capabilities.imageIO.avifWrite == false`).
   - Duplicate AAC priming packet clones on pre-macOS 27 `AVAssetWriter` passthrough MP4 (`9d34f0d`).
   - Lack of `.sparselyInterleavedWithMainMediaData` requiring chronological `si`/`vi` interleaving with explicit `waitReady` bounds (`8dce8ed`).
   - ImageIO rejecting `BITMAPV4HEADER` BGRA `.bmp` on `macos-15` & `macos-26` and downgrading 1-ch float32 `.exr` to `uint8` on `macos-15`, resolved natively with zero external dependencies (`6bba4c8`).

---

## 7. Evidence Paths

- **Workflow & Sanitized Mirror:** [.github/workflows/ci-macos.yml](../../.github/workflows/ci-macos.yml), [Tools/github-export/.github/workflows/ci-macos.yml](../../Tools/github-export/.github/workflows/ci-macos.yml), [Tools/export-public-repo.py](../../Tools/export-public-repo.py)
- **Archived CI Run Logs & Tier 2 Artifacts (Run `45526649058`):** [bench/experiments/2026-11-24-cloud-ci/run-45526649058/](../../bench/experiments/2026-11-24-cloud-ci/run-45526649058/) (`run.json`, `jobs.json`, `macos-15-tier1.log`, `macos-15-tier2.log`, `macos-26-tier1.log`, `macos-26-tier2.log`, `artifacts/safarium-tier2-macos-15/`, `artifacts/safarium-tier2-macos-26/`)

