# Contributing to Safarium

Thank you for contributing to Safarium. Because Safarium is built around strict native media, memory-safety, and zero-dependency guarantees, every pull request must satisfy the architectural invariants and CI gates below.

## Core Engineering Invariants

1. **Zero Forbidden Runtime Dependencies (`SF-VIDEO-1`):**
   - Never link, invoke, bundle, or embed **FFmpeg / ffprobe / libav***, **Google Chrome / Chromium / Playwright**, or **OpenCV** source code inside `Sources/`, `bin/`, `Tools/`, or `sdk/`.
   - All native executables and `libSafariumRaster.dylib` must link strictly against Apple system frameworks and libraries (`/System/Library/`, `/usr/lib/`, `/Library/Apple/System/`, `/System/Volumes/Preboot/Cryptexes/OS/`), verified via `otool -L`.
2. **Peak RAM First & Deterministic Timing:**
   - Bound frame queues and ring buffers (stream frame-by-frame with backpressure; never buffer full episodes as raw RGBA/PNG/JPEG arrays in memory).
   - Keep single-worker execution as the default (`sr_get_num_threads() == 1`, FIFO queue slot in `bin/safarium` / `bin/safarium-render`).
   - Preserve exact resolution, FPS, PTS, color tags, alpha channel, and audio sync — never silently downgrade specs to save RAM.
3. **Quality & Parity Bar:**
   - Cross-engine parity threshold: **`SSIM >= 0.97`**, **`PSNR >= 30 dB`**, and **`DeltaE00 p95 <= 2.0`** (plus Thai OCR / diacritic integrity for HUD/caption tests).
   - Report real measurements honestly (`WIN` / `TIE` / `LOSE`); never relax assertions silently.
4. **SDK & Cloud VM Compatibility:**
   - Wrap macOS 26+ SDK-only symbols (e.g., `VTFrameProcessor`, `VTLowLatencySuperResolutionScalerConfiguration`, `.mediaDataLocation`, `.cvMetalTextureCache`) with **both** `#if compiler(>=6.2)` and `if #available(macOS 26.0, *)` so Xcode 16 (`macos-15`) compiles cleanly.
   - Wrap macOS 15+ SDK symbols with `#if compiler(>=6.0)` / `if #available(macOS 15.0, *)` where applicable.
   - Never force-unwrap `MTLCreateSystemDefaultDevice()!`; handle `SafariumMetalContext.shared == nil` with typed `SafariumError` errors or `XCTSkipIf` in GPU tests.
   - Never require local personal drives, personal dotfiles, or preinstalled third-party GUI apps (such as `/Applications/Blender.app`) unconditionally in default unit tests.

## Local Verification Checklist

Always use an APFS scratch path (`--scratch-path /tmp/safarium-dev-build`) for SwiftPM builds:

```sh
# 1. Static hygiene & policy check
python3 Tools/export-public-repo.py --audit-dir . --json

# 2. Build Debug & Release targets + standalone verifier
xcrun swift build --scratch-path /tmp/safarium-dev-build --jobs 2
xcrun swift build -c release --scratch-path /tmp/safarium-dev-build --jobs 2
xcrun swiftc -parse-as-library -O Tools/safarium-verify.swift -o /tmp/safarium-dev-build/safarium-verify

# 3. Run Swift tests serially (respects 7 GB Cloud VM RAM ceilings)
xcrun swift test --no-parallel --jobs 2 --scratch-path /tmp/safarium-dev-build

# 4. Run Python queue & rule-sync tests
python3 -ISB Tests/queue/test_queue.py -v
python3 Tests/queue-integration/rule-sync.py --scratch /tmp
```

## Export Hygiene

This repository can be audited or exported cleanly via `Tools/export-public-repo.py`. Ensure PRs never commit `._*` AppleDouble sidecars, `.DS_Store`, `__pycache__/`, `.pyc`, `.so`, `.dylib`, large media binaries, or hardcoded personal paths.
