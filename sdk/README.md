---
tags: [safarium, safarium-forge, sdk, python, node, shell]
note_type: reference
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# `safarium-forge` Zero-Dependency 3-Language SDK (`sdk/`)

> **SF-VIDEO-1 Invariant:** Every SDK helper routes strictly through `SAFARIUM_RENDER_BIN` (default `~/.local/bin/safarium-render`) with subcommand `forge`, keeping every job serialized under the single foreground queue slot with **0% FFmpeg / ffprobe / libav / Chrome / Playwright** and **zero third-party pip/npm packages**.

## SDK Files

| Language | Path | Key Primitives |
|---|---|---|
| **Python 3** | [`sdk/python/safarium_forge.py`](python/safarium_forge.py) | `SafariumForge`, `ForgePipeline` DAG builder, `open_pipe_encode()`, `html_overlay_recipe()`, `extract_frame_sheet()`, `unwrap_esds_bytes()`, `prism_capabilities()`, `prism_sync_ir()`, `prism_preview_stills()`, `prism_render_web()`, `prism_render_blender()`, `prism_composite()` |
| **Node ESM** | [`sdk/node/safarium-forge.mjs`](node/safarium-forge.mjs) | `SafariumForge`, `ForgePipeline` DAG builder, `openPipeEncode()`, `htmlOverlayRecipe()`, `unwrapWebCodecsESDS()`, `prismCapabilities()`, `prismSyncIr()`, `prismPreviewStills()`, `prismRenderWeb()`, `prismRenderBlender()`, `prismComposite()` |
| **POSIX / zsh** | [`sdk/shell/safarium-forge.sh`](shell/safarium-forge.sh) | `forge_exec`, `forge_run`, `forge_validate`, `forge_remux`, `forge_inspect`, `forge_image`, `forge_audio`, `forge_sheet`, `forge_compare`, `forge_pq`, `forge_qa`, `forge_reframe`, `forge_matte`, `forge_pipe_encode`, `forge_capabilities`, `forge_prism*` |

## Common Migration Patterns (49 Projects)

1. **Replace `cv2.VideoCapture` / multi-seek `ffmpeg` sampling (`Mobile use`, `3D เล่าให้ฟัง`, `สำรวจไปกับสมพง`):**
   - Use `extract_frame_sheet(video, "sheet.jpg", cols=6, rows=4, every_frames=2, manifest_path="pts.json")` in Python (or `forge.sheet(...)` in Node/Shell) for single-pass decoded PTS manifests without spawning 20+ processes or decoding full RGB arrays into RAM.
2. **Replace `HyperFrames` / `Puppeteer` / `Remotion` HTML renders (`GEOSong`, `TNN News Skill`, `Rea Video`, `เรื่องเงินเงินทองทอง`, `Why Stickman?`):**
   - Use `html_overlay_recipe(html_path, out_mp4, width=1080, height=1920, fps=30, frames=...)` to render windowless `WKWebView` Mode C dirty-hold layers directly over Metal/video inside one bounded `IOSurface` loop.
3. **Replace `rawvideo` stdin pipes (`Capcut Skill`, `Sanook Theme`, `Physics lover`, `Stickman Fighting`):**
   - Use `with forge.open_pipe_encode("alpha.mov", w, h, fps=30, pix_fmt="rgba", codec="prores4444", secondary="comp.mp4", secondary_codec="h264") as pipe:` and push one frame at a time via `pipe.write_frame(frame_bytes)` for single-pass dual tee output without buffering episodes in RAM.
4. **Fix Safari Bug `302253` (`39B` / `76B` double-wrapped `ESDS`) in WebCodecs (`เว็บตัดต่อ`):**
   - Call `unwrapWebCodecsESDS(esdsUint8Array)` (JS) or `unwrap_esds_bytes(data)` (Python) to recursively unwrap `0x03 -> 0x04 -> 0x05` down to the raw 2-byte `AudioSpecificConfig` (e.g. `11 90`) before muxing.
5. **Safarium Prism 3D Hybrid (Blender 5.2 + Three.js WebKit 3D + 1x Thai HUD):**
   - `prism_sync_ir(blend, glb, ir)` extracts `safarium-prism/scene-v1` camera/timeline IR + `.glb` from Blender 5.2 LTS (`BLENDER_EEVEE` / `CYCLES`).
   - `prism_preview_stills(..., tier="webkitGLB")` captures multi-angle stills + contact sheet via WebKit WebGL2/WebGPU without waking Blender, or `tier="warmBlender"` via persistent background Blender SHM (`bmp_mmap` / `gpu_offscreen`).
   - `prism_render_web` / `prism_render_blender` / `prism_composite` run the HID Anti-Lag Governor (auto-yielding on IOKit keyboard/mouse activity + thermal pressure + Darwin background priority) and optional MetalFX 0.67x spatial upscaling with `SafariumPQ` auto-verification & `1x` Thai HUD shielding.

## Self-Checks

```sh
python3 sdk/python/safarium_forge.py --self-check
node sdk/node/safarium-forge.mjs --self-check
chmod +x sdk/shell/safarium-forge.sh && sdk/shell/safarium-forge.sh --help
```

