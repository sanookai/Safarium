---
name: safarium
description: Use when inspecting, rendering, transcoding, encoding image sequences, compositing, audio-mixing, or QA-verifying videos, HTML/CSS/SVG/WebGL canvases, or Blender scenes on macOS with Safarium.
note_type: skill
tags: [safarium, skill, video, macos, sf-video-1]
created: 2026-11-23
updated: 2026-11-23
---

# Safarium — macOS Pure-Apple Media & WebKit Render Skill

## Overview

Safarium (`"$HOME/.local/bin/safarium-render"`) is Pick's macOS-native rendering and media engine using Apple WebKit (`WKWebView`), Metal, VideoToolbox, AudioToolbox, Accelerate, CoreImage, Vision/ANE, and APFS — with **zero FFmpeg/ffprobe/libav**, **zero Chrome/Chromium**, and **zero Safari.app window focus steals**.

## Mandatory SF-VIDEO-1 Rules

1. **Single entrypoint:** Always call `"$HOME/.local/bin/safarium-render"` (`bin/safarium-render`), never invoke `ffmpeg`, `ffprobe`, `libav`, Chrome/Chromium, or launch `Safari.app`.
2. **Single-slot FIFO queue:** Heavy renders (`html`, `media`, `forge run`, `forge seq-encode`, `forge batch-dom`, `forge transcode`, `forge prism render-web|render-blender|composite|preview-stills`, `forge pq|qa|compare`, `verify`) automatically serialize one foreground job at a time. Never spawn parallel queued renders or bypass the lock.
3. **Zero-wait read-only commands:** These bypass the FIFO queue immediately without booting WebKit/encoders:
   - `"$HOME/.local/bin/safarium-render" doctor --json`
   - `"$HOME/.local/bin/safarium-render" status [--json-detail | --verbose]`
   - `"$HOME/.local/bin/safarium-render" capabilities` / `version` / `schema [all|recipe|subcommands|errors]`
   - `"$HOME/.local/bin/safarium-render" forge {inspect|probe|validate|schema|help|--help|--version}`
   - `"$HOME/.local/bin/safarium-render" forge cache stats`
   - `"$HOME/.local/bin/safarium-render" forge capabilities --fast` (bare `forge capabilities` stays queued)
   - `"$HOME/.local/bin/safarium-render" forge run --recipe <path.json> (--dry-run | --validate-only)`
4. **Preserve specs & verify outputs:** Never drop resolution/fps/audio (`--video-only` only when source truly has no audio) to save RAM. Verify rendered outputs via `safarium-render verify` or `safarium-render forge pq --thai-ocr --strict`.
5. **macOS SwiftPM scratch on APFS:** When compiling or testing Safarium itself, never create `.build` inside an external ExFAT volume (ExFAT); always pass `--scratch-path /tmp/<name>`.

## Preflight Check (Run Before Long Jobs)

```bash
"$HOME/.local/bin/safarium-render" doctor --json
"$HOME/.local/bin/safarium-render" status --json-detail
```

Confirm `"healthy": true` and empty queue before starting multi-step renders.

## Quick Reference — Core Commands

| Task | Command |
|---|---|
| Preflight & schema | `safarium-render forge schema all` |
| Validate recipe without running | `safarium-render forge run --recipe job.json --dry-run --json-errors` |
| Inspect container/packets/volume | `safarium-render forge inspect input.mp4 [--include-audio-packets]` |
| Execute DAG recipe w/ telemetry | `safarium-render forge run --recipe job.json --progress jsonl --json-errors` |
| Image sequence -> video + sheet | `safarium-render forge seq-encode --dir frames/ --glob "*.png" --fps 30 -o out.mp4 --inline-sheet sheet.png --sheet-cols 6 --sheet-rows 4 --overwrite` |
| Batch HTML card -> transparent PNGs | `safarium-render forge batch-dom --manifest cards.json --font-dir fonts/ --overwrite` |
| Size-constrained transcode | `safarium-render forge transcode in.mp4 -o out.mp4 --max-bytes 15000000 --overwrite` |
| WebGL/Pixi/Three/SVG -> video | `safarium-render forge prism render-web http://127.0.0.1:PORT/app.html -o out.mp4 --allow-loopback-http --width 1080 --height 1920 --fps 30 --frames 90 --overwrite` |
| Deterministic HTML frame hash | `safarium-render html page.html --output out.mp4 --width 320 --height 240 --fps 30 --frames 30 --video-only --hash --json` |
| Objective quality + Thai OCR gate | `safarium-render forge pq ref.mp4 cand.mp4 --samples 12 --thai-ocr --strict` |
| Verify track/frame/audio parity | `safarium-render verify [ref.mp4] cand.mp4` |

## Wave 6 `prism render-web` Hooks & Flags

- **Lifecycle hooks:** `--ready-expr "window.__ready === true"`, `--init-js "..."` / `--init-file init.js`, `--seek-expr "void window.renderFrame(t)"`, `--ready-timeout 30`, `--allow-loopback-http`
- **Local fonts (zero internet hang):** `--font-dir /path/to/fonts` (serves loopback CORS `@font-face`, skips `._*` AppleDouble sidecars, supports percent-encoded Thai/Unicode)
- **Visual & FPS upgrades:** `--output-fps 60`, `--grain 0.035 --grain-size 1.2`, `--metal-svg-filters`, `--no-sharp-text-1x`
- **Audio & scaling:** `--audio track.wav --loudnorm -16 --true-peak -1.5 --apad`, `--adaptive-workers 2 --budget-mb 650`, `--metalfx --thai-ocr`

## AI Machine Interface (`--progress jsonl` & `--json-errors`)

- Pass `--progress jsonl` on `forge run`, `audio`, `seq-encode`, `transcode`, or `prism render-web` to receive line-delimited JSON progress on `stderr` while keeping the single final JSON report cleanly on `stdout`.
- Pass `--json-errors` (or set `SAFARIUM_JSON_ERRORS=1`) to receive typed error envelopes on `stderr` with `ok: false`, `error.code`, `error.category`, `error.message`, `error.hint`, `error.recoverable`.

### Error Recovery Map

| Code | Meaning | Action |
|---|---|---|
| `E_USAGE` | Invalid flags or recipe field | Check `safarium-forge schema errors` / subcommand `--help` |
| `E_INPUT_MISSING` | Missing/unreadable file or dir | Verify paths exist and are regular files (skip `._*`) |
| `E_UNSUPPORTED_CODEC` | Unsupported fourCC/container | Check `safarium-render capabilities`; note `.ogg`/`.oga`/`.mpeg` route via Pure-Swift `SafariumContainers` |
| `E_QUEUE_BUSY` | Another job owns SF-VIDEO-1 slot | Poll `status --json-detail` cleanly; do not bypass lock |
| `E_TIMEOUT` | Render or ready check timed out | Raise `--ready-timeout` or split long timelines |
| `E_JS_EVAL` | Page JS error / false ready expr | Inspect DOM script errors, mount `--font-dir`, wrap `seek-expr` with `void ...` |
| `E_NAVIGATION` | Page/origin navigation blocked | Pass `--allow-loopback-http` for `http://127.0.0.1:...` local servers |
| `E_SNAPSHOT` | WKWebView snapshot failure | Retry with `--adaptive-workers 1` and verify even dimensions |
| `E_ENCODE` | VideoToolbox / AVAssetWriter error | Check even width/height, BT.709 colorimetry, and APFS free space |
| `E_VERIFY_FAIL` | `pq` / `qa` / `verify` mismatch | Inspect `msSSIM`, `deltaE00P95`, `thaiOCROK`, and `differingSections` |
| `E_THERMAL_OR_MEM` | RAM budget or thermal pressure | Lower `--adaptive-workers` to `1` or reduce worker count |

## References

- [Safarium AI Control Protocol](docs/ai-control-protocol.md)
- [SF-VIDEO-1 Standard](docs/render-standard.md)
- [render-command](docs/render-command.md)

