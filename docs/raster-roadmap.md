---
tags: [safarium, raster, cv2, plan, roadmap]
note_type: plan
project: "Safarium"
created: 2026-11-24
updated: 2026-11-24
---
# SafariumRaster roadmap — "everything OpenCV does, and better"

Pick's goal (2026-11-24): do everything OpenCV can do AND beat it on speed, peak RAM, quality/accuracy, and file size at equal quality, all before the next Sompong clip. Phase 0 (about 70 functions for the Sompong pipeline, see [raster-plan](docs/raster-plan.md)) is nearly done. This note scopes the rest. Rules unchanged: Apple frameworks only, one worker thread default (SF-VIDEO-1), parity bar SSIM >= 0.97 / PSNR >= 30 / dE00 p95 <= 2 vs OpenCV, never lowered silently.

## 1. Inventory — the reference wheel (opencv-python-headless 5.1.0.95)

Measured by importing the reference `cv2` (read-only) and classifying names by hand. Raw name list: `$SCRATCH/cv_names.txt`. Module grouping is by OpenCV's own module layout (the Python API does not tag modules, so +-2 per bucket).

Totals: **503 top-level functions, 187 classes, 1651 constants, ~30 sub-namespaces.**

| OpenCV module | funcs | main classes / notes |
|---|---|---|
| core | 145 | Mat/UMat, RNG, FileStorage/FileNode, KalmanFilter, TickMeter, PCA/SVD/DFT/DCT, kmeans, solve/eigen, LUT, reduce, norm, bitwise/arith ops |
| imgproc | 99 | filters, morphology, geometry warps, cvtColor, threshold, contours, Hough, draw, histogram, CLAHE, LSD, GeneralizedHough, Subdiv2D, floodFill, grabCut, watershed |
| imgcodecs | 19 | imread/imwrite/imdecode/imencode, multi-page, animation, metadata variants |
| videoio | 2 (+VideoCapture/Writer, `videoio_registry` 13) | backends here: FFMPEG + AVFoundation |
| highgui | 29 | windows, trackbars, mouse, waitKey, selectROI |
| video | 21 | optical flow (Farneback, LK, DIS, Variational), MOG2/KNN, ECC, meanShift/CamShift, 4 trackers (MIL, Nano, Vit, DaSiamRPN) |
| calib (calib3d) | 65 (+ `fisheye` 23) | calibrate, solvePnP, homography/essential/fundamental, undistort, stereoRectify |
| stereo | 5 | StereoBM, StereoSGBM, disparity helpers |
| geometry (new in 5.x) | 23 | convexHull, minAreaRect, fitEllipse*, contourArea, matchShapes, EMD-adjacent |
| features | 29 | ORB, SIFT, FAST, MSER, GFTT, blob, ALIKED, DISK, XFeat, LightGlue, BF/FLANN matchers, corners |
| photo | 29 | inpaint, NLM denoise, seamlessClone, HDR (Debevec/Robertson/Mertens), tonemap, stylization, demosaicing |
| objdetect | 3 (+QRCodeDetector, `aruco` 48 names, `barcode`) | FaceDetectorYN, FaceRecognizerSF, QR encode; no CascadeClassifier/HOGDescriptor exported in this build (verify) |
| ptcloud / 3d | 30 | Octree, normals, outlier removal, mesh/PLY IO, Gaussian splats, rasterizer, Volume/Odometry |
| stitching | 1 (+`detail` 19 funcs, 38 classes) | Stitcher, seam finders, blenders, bundle adjusters |
| flann | 1 (+`flann.Index`) | ANN index |
| dnn | 2 (+`dnn` namespace: 17 funcs, 17 classes, ~190 names) | Net, readNet/ONNX/TFLite, blobFromImage, NMS, Model wrappers (detection, segmentation, text) |
| ccm / mcc | 0 (+63 / 8 names) | colour-correction model, Macbeth chart detector |
| cuda / ocl / ogl | 0 (+75 / 80 / 90 names) | GPU vendor APIs: **out of scope** (Metal replaces them) |
| slam / viz3d / segmentation | 0 (+6 / 18 / 1) | VisualOdometry, 3D viewer, IntelligentScissors |

**Not in this wheel (so not in scope unless Pick wants it):** `ml` (SVM, KNearest, RTrees, ANN_MLP — absent in 5.1 Python), `gapi`, and all of **opencv_contrib** (ximgproc, xfeatures2d, tracking KCF/CSRT, face, text, bgsegm, optflow extras, xphoto, bioinspired, wechat_qrcode, cudaXXX). "Everything OpenCV can do" is therefore defined here as **this 503-function surface**, not contrib. Build info also shows: Accelerate used for LAPACK/BLAS, OpenCL on, GCD threading, no Eigen, no IPP. So OpenCV is already partly Apple-accelerated; the speed gap to close is smaller than against Linux x86 builds.

## 2. Phases

Effort = agent-days (one focused sub-agent day, including parity tests). Ordered by value to Sompong/Safarium and dependency. **Realistic total for the full surface: ~150-210 agent-days.** Doing it all "before the next clip" is not achievable by any parallelism that respects exclusive-file rules and the SF-VIDEO-1 queue; Q1 asks Pick to cut scope.

| # | Phase | Covers | Build on | Days | Main risks |
|---|---|---|---|---|---|
| 0 | Finish Phase 0 + harness | ~70 pipeline funcs; the 4-metric harness of section 3 | vImage, CoreGraphics, ImageIO | 3-5 | harness itself is new work; gates everything after |
| 1 | core-numeric | arith/bitwise/compare, LUT, reduce, norm, mean/meanStdDev, minMaxLoc, split/merge/mixChannels, flip/rotate/transpose/concat, convertTo, normalize, sort, random | vDSP/vForce, simd, Accelerate | 8-12 | dtype matrix (8 depths x 1-4 ch x saturate rules); the long tail of broadcasting rules |
| 2 | linalg + transforms | gemm, solve, SVD, eigen, invert, PCA, dft/dct/idft, mulSpectrums, kmeans, Mahalanobis, calcCovar, solvePoly | LAPACK/BLAS in Accelerate, vDSP FFT | 8-10 | LAPACK sign/ordering conventions differ from OpenCV; 1-D vs 2-D DFT flags |
| 3 | imgproc-filter | blur, box, Sobel/Scharr/Laplacian/Canny, bilateral, median, stackBlur, filter2D, sepFilter2D, integral, pyr, morph, threshold/adaptive, histograms, CLAHE, equalizeHist, colour maps, remap, warpPerspective, getPerspective, cvtColor (all ~150 codes), Lab/Luv/YUV/Bayer | vImage, MPS (Gaussian, median, Sobel, morphology, histogram), Metal compute | 15-20 | cvtColor code zoo; Canny/Hough tie-break fidelity |
| 4 | geometry + contours | findContours (all modes), moments, hull, minAreaRect, fitEllipse/Line, contourArea, matchShapes, Subdiv2D, floodFill, watershed, grabCut, connected components (all algos), Hough family, LSD | Swift + simd; Metal for Hough accumulator | 15-20 | topology/hierarchy conventions; grabCut GMM |
| 5 | codecs + still file size | JPEG/PNG/TIFF/WebP/HEIC/AVIF/JP2/BMP/EXR/HDR read+write, multi-page, animation, metadata, EXIF orient, 16-bit/f32 | ImageIO, CoreGraphics; own quantiser/entropy tuning for size | 10-15 | "smaller at equal SSIM" needs real encoder work (see 3.4); ImageIO format coverage (no PBM/SR/WebP-write on some OS) |
| 6 | videoio | VideoCapture/Writer (file), seeking, props, VideoWriter (H.264/HEVC/ProRes), image-sequence, camera capture | AVFoundation, VideoToolbox | 10-12 | exact-frame seek, VFR/PTS, bitrate control; no FFmpeg allowed so exotic containers (AVI/MKV/WebM) may be unsupported |
| 7 | draw + text completion | full draw family, FontFace/TrueType, putText unicode | CoreText/CoreGraphics + own AA raster | 4-6 | AA identity vs OpenCV |
| 8 | photo | inpaint (both), NLM + colored/multi, seamlessClone/colorChange/illumination/texture, edgePreserving/detailEnhance/pencilSketch/stylization, HDR (merge/calibrate/tonemap), decolor, demosaicing | Metal, MPS, vImage | 12-15 | NLM cost; HDR response-curve numerics |
| 9 | features + matching | corners (Harris/MinEig/GFTT/subpix), FAST, ORB, SIFT, MSER, blob, BF/FLANN/ANN matchers, drawKeypoints/Matches | Metal, simd, Accelerate | 15-20 | SIFT/ORB descriptors must match for cross-compat; ORB random pattern table |
| 10 | video analysis | LK + pyramid, Farneback, DIS, Variational, MOG2/KNN, ECC, meanShift/CamShift, phaseCorrelate | Metal, MPS, vImage; Vision `VNTrack*`/optical-flow request as an alternative impl | 12-15 | algorithm fidelity; Vision's flow is a different algorithm (can't claim parity) |
| 11 | calib + stereo + fisheye | all 65 + 23 + 5, solvePnP family, RANSAC/USAC (`UsacParams`), undistort maps, stereo BM/SGBM | Accelerate LAPACK, simd, Metal (SGBM) | 20-25 | numerical optimisation tails (LM); RANSAC is random — seed-dependent |
| 12 | objdetect + codes | QR detect/decode/encode, barcode, ArUco/ChArUco, FaceDetectorYN, FaceRecognizerSF | Vision (`VNDetectBarcodes`, face), CoreML | 8-12 | Vision output differs from OpenCV (finder order, sub-pixel corners) |
| 13 | dnn | Net, readNet ONNX/TFLite, blobFromImage, NMS, Model wrappers, text detect/recognise | CoreML + ANE, BNNS Graph, MPSGraph | 25-35 | arbitrary-ONNX-to-CoreML coverage is the hard part; op-by-op fallback needed |
| 14 | 3D / ptcloud / slam | Octree, normals, outliers, mesh/PLY IO, Gaussian splats, triangleRasterize, Volume, Odometry, VisualOdometry | Metal, Model I/O, simd | 15-20 | large new 5.x surface with weak reference docs |
| 15 | stitching + flann | Stitcher, `detail` pipeline, seam finders, blenders, bundle adjust, flann Index, ccm/mcc | Metal, Accelerate | 12-15 | graph-cut seam finder, bundle adjustment fidelity |
| 16 | highgui + misc | namedWindow/imshow/waitKey/trackbar/mouse, FileStorage (YAML/XML/JSON), TickMeter, ocl/cuda stubs | AppKit/SwiftUI (own window thread) | 4-6 | headless server: see 3.5; AppKit needs main thread |

Dependencies: 0 -> everything. 1 -> 2, 3, 4. 3 -> 4, 8, 9, 10. 4 -> 9, 12. 5, 6, 7, 16 independent after 0. 9 -> 11, 15. 13 depends on 3 (blobFromImage) only.

Parallel plan (3-5 agents per round, exclusive file ownership per area as in raster-plan.md): round A = {1, 5, 6, 7}; round B = {2, 3, 16}; round C = {4, 8}; round D = {9, 10, 12}; round E = {11, 13, 14, 15}. Shared files (ABI.swift, `_lib.py`, `cv2/__init__.py`, Package.swift, `raster_parity.py`) stay orchestrator-only and are touched sequentially at the start/end of each round. Each phase's DoD: its functions pass section 3 gates; runnable check = `SAFARIUM_RASTER_LIB=<dylib> $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_parity_<area>.py` plus `bench_raster.py --phase N` (to be built in Phase 0).

## 3. "Better than OpenCV" acceptance harness

Per-op, per-fixture record with 4 numbers; a function is "better" only if it ties-or-wins all four AND wins at least one by the margin below. Verdict per function is one of WIN / TIE / LOSE-explained. Never average away a loss.

### 3.1 Speed
- Fixtures: 1080x1920 u8 BGR/gray/f32 plus 256x256 and 4096x4096 (cold-cache and small-call overhead both matter).
- Protocol: fresh process; 5 warmup calls discarded; N = 31 timed calls via `time.perf_counter_ns`, report median and IQR; inputs pre-allocated, outputs pre-allocated (`dst=`) where API allows; Python-call overhead included (that is what the pipeline pays).
- Two configs: **1 thread** (`cv2.setNumThreads(1)` vs `sr_set_num_threads(1)`; this is the SF-VIDEO-1 default and the headline) and **default threads** (both libraries at their own default, reported separately). GPU/ANE paths count only in "default"; headline = 1 CPU thread.
- Alternate A/B order every run; fixed CPU state: plugged in, `taskpolicy -b` NOT used for measuring (use the same QoS for both), 60 s cooldown per block (as benchmark-protocol.md). 
- Win = median >= 1.10x faster and IQRs do not overlap. Tie within 1.10x.

### 3.2 Peak RAM
- One fresh subprocess per (op, library, fixture); child runs warmup + 5 calls, then reports `resource.getrusage(RUSAGE_SELF).ru_maxrss` (bytes on macOS) minus the maxrss measured after import + input allocation (baseline captured in the same child before the call). Parent also records `proc_pid_rusage` `ri_peak` equivalent via `/usr/bin/time -l` as cross-check ("maximum resident set size").
- Report delta over baseline and absolute. Library import footprint (dylib + OpenCV .so) reported separately as a fixed cost, since "peak RAM" of the whole pipeline includes it.
- Win = delta <= 0.9x OpenCV's. For streaming ops (VideoCapture, imdecode of a large TIFF) also run a 1000-frame loop and require flat RSS (slope < 1 MB per 100 frames).
- Caveat: Metal/IOSurface memory is not in ru_maxrss on Apple Silicon (unified memory is accounted partly as wired/GPU). GPU paths must additionally report `footprint` from `vmmap -summary` or `task_info(TASK_VM_INFO).phys_footprint`; the lower of the two is not allowed to be the only number shown.

### 3.3 Quality / accuracy
Ground truth, in order of preference (OpenCV is judged against it too, so "better" is measured, not assumed):
1. **Analytic shapes/signals:** rendered circles/lines with exact coverage (supersampled 16x16 box reference), known-rotation warps of synthetic bandlimited images, known blur sigma (compare to float64 Gaussian), known homographies/camera params for calib (synthetic projections with known pose).
2. **float64 reference implementations** (numpy/scipy-free where possible; own double-precision code in the harness, reviewed once) for filters, colour conversion (CIE with D65 constants), resize (Lanczos/area in f64), DFT (numpy.fft in f64), SVD/eigen (numpy.linalg in f64).
3. **Standard datasets** for the algorithms that have them: Kodak24 + CLIC-pro subset (codecs, denoise, resize), Middlebury 2014 (stereo), KITTI flow 2015 (optical flow), HPatches (features), Set12/BSD68 (NLM denoise), MIT-Adobe-5k, DIV2K (resize). Datasets are downloaded only with Pick's OK (Q5).
- Metrics: PSNR, SSIM, dE00 (p95) vs ground truth for both libraries; geometric ops also max/mean sub-pixel error; calib reprojection RMS; flow EPE; stereo bad-pixel %; feature repeatability/matching score.
- Two separate gates: (a) **parity gate** = Safarium vs OpenCV >= SSIM 0.97 / PSNR 30 / dE00 p95 <= 2 (existing, unchanged; protects cv2-compatibility). (b) **accuracy gate** = error vs ground truth <= OpenCV's error (+ small epsilon 1e-3 relative). Win = Safarium error <= 0.9x OpenCV's.
- Note the tension: being *more accurate* than OpenCV moves *away* from OpenCV's output. When parity gate and accuracy gate conflict (e.g. a correct Lanczos-3 resize differs from OpenCV's fixed-point bilinear by SSIM 0.96), default = keep parity and expose an `accurate=True` extension flag. This is Q2.

### 3.4 File size at equal quality (codecs only)
- For each of JPEG/PNG/WebP/HEIC/AVIF/TIFF and video H.264/HEVC: sweep the quality knob, fit a rate-distortion curve per image on Kodak24 + CLIC + the Sompong frames; report **bytes at SSIM = 0.97 / 0.99 and PSNR = 35**, interpolated; plus BD-rate (Bjontegaard) over the sweep. Decoder must be a third-party-neutral one (Pillow/ImageIO of the same file) so the encoder cannot cheat.
- PNG/TIFF/lossless: bytes at identical pixels (bit-exact round-trip check), compared to OpenCV `IMWRITE_PNG_COMPRESSION=9` and libpng/ImageIO.
- Win = BD-rate <= -5 % (smaller by >= 5 % at equal SSIM) on the corpus median.

### 3.5 Where "better" is ill-defined or likely impossible
| Area | Problem | Proposed meaning of "better" |
|---|---|---|
| Bit-exact deterministic ops (add/bitwise/flip/LUT/threshold/integer morphology/connected components/findContours topology) | Accuracy can only tie; there is one right answer | Accuracy = bit-exact TIE (0 error). Better = speed + RAM only |
| Fixed-point OpenCV algorithms (resize bilinear 11-bit, cvtColor gray weights) | Correct answer is *OpenCV's quirk* if cv2-compat is the goal | Parity gate wins; accuracy gate measured vs f64 but reported only |
| DNN inference | Model weights decide accuracy; same ONNX gives same result up to fp error | Accuracy = max abs diff vs f32 ONNX reference <= OpenCV's; "better" = latency, energy, RAM on ANE/GPU. Allow fp16 only if top-1/mAP delta < 0.1 pt, and say so |
| Random/iterative algorithms (RANSAC, kmeans, ORB pattern, grabCut) | Output depends on RNG/initialisation | Compare success rate/median error over 100 seeds, not one output |
| Optical flow / stereo / features / trackers | No single right answer; ground truth exists only on datasets | Win on EPE/bad-pixel/repeatability against dataset GT; ties acceptable |
| Vision/CoreML replacements (QR, face, barcode) | Different algorithm, different outputs | Judge on detection rate + corner error against labelled set, not on parity |
| highgui | Windows have no pixel output; headless wheel has none anyway (`currentUIFramework` empty in headless) | Not measurable; define as "API-compatible + works on macOS main thread"; skip speed/RAM/size |
| videoio file size | Hardware encoders (VideoToolbox) are fast but rate-control is looser than x264 | Bytes at equal VMAF/SSIM; software HEVC may be needed to win size, which costs speed (trade-off, Q3) |
| cuda/ocl | Vendor-specific | Out of scope; stubs that raise `cv2.error` |
| "Everything" including contrib | Not in the wheel | Excluded unless Pick adds it |

Honest forecast: CPU-bound classical ops at 1 thread — expect WIN on speed for ~40-60 % of functions (vImage/MPS/Accelerate are strong; OpenCV already uses Accelerate for BLAS), TIE for most of the rest, a few LOSEs on exotic paths. RAM: easy to win on streaming/in-place ops, hard on simple whole-image ops (both need the output buffer). Size: winning vs libjpeg-turbo/libpng at equal SSIM requires real encoder work (trellis quantisation, optimal Huffman/zopfli-class deflate, perceptual RDO); ImageIO's own encoders are not smaller than OpenCV's by default. Quality "win" on all four for all 503 is **unlikely**; per-function verdicts will show where.

## 4. Decisions for Pick (max 6)

1. **Scope vs deadline.** All 503 functions before the next clip is not possible (~150-210 agent-days). Options: (A) Phases 0-7 first = everything an image/video pipeline uses, ~85-120 days, ship, then continue **(recommended)**; (B) all phases, next clip waits months; (C) Phase 0 only for the next clip, rest runs in background after. Gain/loss: A gets broad value and honest milestones; B delivers the promise but blocks work; C ships clips now but "everything" slips.
2. **Parity vs accuracy when they conflict.** (A) default = OpenCV-compatible output, optional `accurate=True` extension **(recommended)**; (B) default = most accurate, break parity bar where needed; (C) both always, separate function names. Gain/loss: A keeps old results and the existing bar; B is "better" but silently changes cv2 results; C doubles the API.
3. **What may count as "default threads / GPU".** (A) headline = 1 CPU thread (SF-VIDEO-1), GPU/ANE reported separately **(recommended)**; (B) allow Metal/ANE in the headline. Gain/loss: A is fair and queue-safe but under-uses the Mac; B shows bigger wins but breaks the one-worker spirit and RAM numbers.
4. **File-size goal: how deep.** (A) use ImageIO/VideoToolbox encoders with tuned settings, accept TIE where they can't beat libjpeg-turbo/x264 **(recommended)**; (B) write own optimising encoders (JPEG RDO, PNG zopfli-class, perceptual quantiser) ~15-25 extra days; (C) add software HEVC/AV1 encoder. Gain/loss: A is cheap, may only tie; B wins size but costs days and CPU time; C costs the most and risks rule SF-VIDEO-1 (no libav).
5. **Reference datasets and external downloads.** (A) allow public datasets (Kodak, CLIC, Middlebury, KITTI, HPatches) into scratch only **(recommended)**; (B) synthetic + Sompong frames only. Gain/loss: A gives standard, citable numbers; B is offline but weaker evidence for flow/stereo/features.
6. **Scope edges: contrib/ml/dnn/highgui.** Choose: (A) exclude contrib, ml, cuda/ocl; dnn = ONNX subset via CoreML; highgui = thin AppKit window **(recommended)**; (B) also port popular contrib (ximgproc, xphoto, tracking KCF/CSRT, face); (C) exclude dnn and highgui too. Gain/loss: A matches the 503 surface; B adds ~40-60 days; C saves ~30 days but is not "everything".

## 5. Pick's rulings (2026-11-24)

- **Order:** every phase (0-16 + popular contrib) is finished **before** the next Sompong clip. Pick confirmed this after seeing the 150-210 agent-day estimate.
- **Q2 parity vs accuracy:** (A) the default matches OpenCV, and `accurate=True` (or a parallel API) gives the more accurate result.
- **Q3 speed headline:** (B) GPU/ANE (Metal, MPS, CoreML) may count in the headline. CPU 1-thread numbers are still reported next to it.
- **Q4 file size:** (B) write our own optimising encoders for JPEG, PNG and WebP. Accept the +15-25 days.
- **Q5 datasets:** (A) public datasets allowed, kept in scratch only. Check each dataset's licence.
- **Q6 scope edges:** (B) include popular contrib (ximgproc, xphoto, tracking KCF/CSRT, face) on top of the 503-function surface. Adds about 40-60 days.
- **Font:** `putText` looks like OpenCV 5.1, not 4.x Hershey.
- **FFmpeg exception for comparisons (2026-11-24):** the reference cv2's FFmpeg-backed `VideoCapture`/`VideoWriter` may be run only to compare against Safarium, only in scratch, and only through the `safarium-render` queue. It is never used by Safarium code or for real work.
- **GPU opt-in (2026-11-24):** compute-bound ops that only tie cv2 on one CPU thread (sqrt, pow, exp, log, polarToCart, magnitude, phase, and others) get a Metal path. It is OFF by default and turned on explicitly. With it on, results may differ slightly from OpenCV. With it off, the default output stays OpenCV-exact. Ties caused by memory bandwidth are accepted once proven.
- **scipy and tifffile:** the subset Sompong uses (netcdf_file, wavfile, signal, minimum_filter1d, tifffile) is also replaced by Safarium (Area E).

