---
tags: [safarium, raster, cv2, plan]
note_type: plan
project: "Safarium"
created: 2026-11-24
updated: 2026-11-24
---
# SafariumRaster — replace OpenCV (cv2) for the Sompong pipeline

Pick's decisions (2026-11-24):
- Safarium replaces OpenCV entirely for the Sompong reel pipeline (Python 3.12, `/opt/homebrew/bin/python3.12`, numpy 2.5.2 + Pillow 12.3 present, **no OpenCV**).
- Parity bar = Safarium's cross-engine bar: **SSIM ≥ 0.97, PSNR ≥ 30 dB, ΔE00 p95 ≤ 2** per op/fixture vs reference OpenCV. Exact pixel parity is NOT required. Never lower the bar silently; report real numbers.
- Reference OpenCV 5.1.0 exists ONLY in a scratch venv for comparison: `$SCRATCH/cvref/bin/python` (has numpy and real `cv2`). The pipeline must never use it.
- Apple frameworks only (Accelerate/vImage, CoreGraphics, ImageIO, AVFoundation). No FFmpeg/libav, no Chromium, no OpenCV source linked in. Porting small algorithms/data tables from OpenCV (Apache-2.0) by rewriting them in Swift is fine; note the origin in a comment.
- One worker thread by default (SF-VIDEO-1); `sr_set_num_threads` may raise it.

`$SCRATCH` = `<scratch>`

## Architecture

- Swift target `Sources/SafariumRaster/` → product `libSafariumRaster.dylib` (`type: .dynamic`), flat C ABI via `@_cdecl("sr_…")`. No dependency on other Safarium targets.
- Python shim package `sdk/python/safarium_cv2/cv2/` — a real module named `cv2` (so `import cv2` and `mock.patch("cv2.imdecode")` work). ctypes over numpy buffers, zero-copy, in place where cv2 draws in place.
- Loader `cv2/_lib.py` finds the dylib via `$SAFARIUM_RASTER_LIB` or `~/.local/libexec/safarium/libSafariumRaster.dylib`.
- Shared plumbing (orchestrator-owned, do not edit): `Sources/SafariumRaster/ABI.swift`, `cv2/_lib.py`, `cv2/__init__.py`, `Package.swift`, `sdk/python/tests/raster_parity.py`.

## ABI conventions

- Image = 6 scalars `(void* data, int32 width, int32 height, int32 strideBytes, int32 channels, int32 depth)`; depth 0=u8, 2=u16, 4=s32, 5=f32. Swift side: `SRImage(...)` initializer in ABI.swift (returns nil on bad args → `srFail(SRStatus.badArgument, "...")`).
- Return `Int32` 0 ok, <0 error with message via `srFail` (Python `_lib.check(rc, "fn")` raises `cv2.error`).
- Colours `const double* color` length 4 (`_lib.color4`), channel order = the array's order (cv2 never swaps).
- Points: `const int32* xy` interleaved x,y; `shift` = fractional bits (coords / 2^shift). `counts` = points per contour.
- Variable-size outputs use opaque handles: `sr_x(…, void** out)`, then `sr_handle_*` getters, then `sr_free_*`.
- Python wrappers reproduce cv2's Python signatures: positional order, keyword names, defaults, `dst=`, return values (draw functions return the image; `resize` returns new array; etc.).
- Build: `swift build -c release --product SafariumRaster --scratch-path $SCRATCH/sr-build-<AREA>` (≈10 s). Use YOUR OWN scratch path. Never `swift build` the whole package, never install into `~/.local`.
- Parity tests: `sdk/python/tests/test_parity_<area>.py`, run with `SAFARIUM_RASTER_LIB=<your dylib> $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_parity_<area>.py` (pytest may need `$SCRATCH/cvref/bin/pip install pytest` — allowed; or write plain-assert scripts). Use `raster_parity.load_pair()` and `compare()`; fixtures 1080x1920 and small sizes, u8 BGR/BGRA/gray and f32 where the pipeline uses them.

## Areas and file ownership (exclusive)

| Area | Swift files | Python files | Tests |
|---|---|---|---|
| A draw | `Sources/SafariumRaster/Draw*.swift`, `Hershey*.swift` | `cv2/_draw.py` | `test_parity_draw.py` |
| B image ops | `Sources/SafariumRaster/Ops*.swift`, `Contours*.swift` | `cv2/_ops.py` | `test_parity_ops.py` |
| C IO + video | `Sources/SafariumRaster/IO*.swift`, `Video*.swift` | `cv2/_io.py` | `test_parity_io.py` |
| D numpy + glue | none | `cv2/_constants.py`, `cv2/_numpy_ops.py`, `cv2/utils/logging.py` | `test_parity_numpy.py`, `test_sompong_suite.md` (report) |

### A draw
circle, rectangle (incl. `(pt1, pt2)` and rect forms), line, polylines, fillPoly (`offset`), ellipse (full + arcs, angle), putText, getTextSize. lineType FILLED(-1 thickness) / LINE_4 / LINE_8 / LINE_AA; `shift` (pipeline uses shift=4). Hershey SIMPLEX + DUPLEX glyphs (port data table). Works on u8 1/3/4-ch and f32 1/3-ch arrays. Per-frame hot path: many small AA filled circles (dot grid) — keep per-call overhead low.

### B image ops
resize (INTER_NEAREST/LINEAR/AREA/CUBIC; `dsize=(w,h)` or `fx,fy`), warpAffine (+WARP_INVERSE_MAP; BORDER_REPLICATE/REFLECT_101/CONSTANT+borderValue; INTER_NEAREST/LINEAR/CUBIC; cv2 pixel-centre convention), getRotationMatrix2D (may be numpy in _ops), GaussianBlur (ksize (0,0)+sigma or explicit ksize; borderType), sepFilter2D, pyrDown, erode/dilate/morphologyEx(MORPH_OPEN/CLOSE) with kernels (u8 + f32 images), getStructuringElement (MORPH_ELLIPSE/RECT/CROSS — numpy ok), distanceTransform (DIST_L2, maskSize 3 and 5/PRECISE ok), connectedComponents / connectedComponentsWithStats (4/8, CC_STAT_*), findContours (RETR_LIST/EXTERNAL, CHAIN_APPROX_NONE/SIMPLE; returns (contours, hierarchy) as cv2 4.x+), approxPolyDP, arcLength, pointPolygonTest. dtypes u8 and f32 (+ s32 labels).

### C IO + video
imdecode / imread (IMREAD_COLOR → BGR u8, IMREAD_UNCHANGED keeps alpha / 16-bit / f32 TIFF / gray 1-ch, IMREAD_GRAYSCALE, IMREAD_REDUCED_COLOR_2/4/8), imencode / imwrite (.jpg + IMWRITE_JPEG_QUALITY, .png (+compression ok to ignore), .tif/.tiff incl. f32 1-ch). imread/imwrite read/write bytes in Python (non-ASCII paths) and return None on failure like cv2. VideoCapture class (open path, isOpened, read() → (ok, BGR u8), get/set CAP_PROP_POS_MSEC/POS_FRAMES/FRAME_COUNT/FPS/FRAME_WIDTH/FRAME_HEIGHT, release) via AVAssetReader.

### D numpy + glue
All constants used (LINE_*, FILLED, INTER_*, BORDER_*, WARP_INVERSE_MAP, IMREAD_*, IMWRITE_*, COLOR_*, MORPH_*, DIST_*, CC_STAT_*, RETR_*, CHAIN_*, REDUCE_*, FONT_HERSHEY_*, CAP_PROP_*, CV_8U/CV_32F etc. — values identical to OpenCV), cvtColor (codes used: BGR2RGB, RGB2BGR, RGBA2BGRA, BGRA2RGBA, BGR2RGBA, RGB2BGRA, BGRA2BGR, BGR2BGRA, GRAY2RGB, GRAY2BGR, RGB2GRAY, BGR2GRAY, RGB2HSV, BGR2HSV — with cv2's exact gray weights and rounding), addWeighted, subtract, add, multiply, absdiff (scalar tuples, saturate, `dst=` in place), merge, split, reduce (REDUCE_MAX/MIN/SUM/AVG), countNonZero, convertScaleAbs, Laplacian (CV_32F ksize 1/3), getNumThreads/setNumThreads (→ sr_set_num_threads), `utils.logging` (getLogLevel/setLogLevel/LOG_LEVEL_*). Then: run the Sompong pipeline test-suite with the shim and report.

## Done when
1. `swift build` of SafariumRaster clean; each area's parity tests PASS the bar (list real numbers).
2. Sompong unit tests pass with the shim on `sys.path` and **no OpenCV installed** (`/opt/homebrew/bin/python3.12`).
3. A real Sompong preview/render works through `safarium-render run --`.

