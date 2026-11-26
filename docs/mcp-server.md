# Safarium MCP Server (`safarium-mcp`)

Zero-dependency **Model Context Protocol (MCP)** `stdio` JSON-RPC 2.0 server (`bin/safarium-mcp`) that lets **any MCP-compatible AI agent** — Claude Code, Claude Desktop, Cursor, Gemini CLI, Codex CLI, Windsurf, or custom agent runtimes — drive Safarium directly on macOS Apple Silicon.

- **Zero third-party packages:** pure Python 3 stdlib (`#!/usr/bin/python3 -ISB`), installed alongside `safarium` at `~/.local/bin/safarium-mcp` via `Tools/install-render.py`.
- **Protocol versions:** negotiates `2025-06-18`, `2025-03-26`, and `2024-11-05` cleanly.
- **SF-VIDEO-1 safe by construction:** fast read-only tools bypass the render queue instantly; heavy render/verify/QA tools automatically serialize through Safarium's single-slot FIFO queue (`~/.safarium-render-queue`) and stream `--progress jsonl` events as MCP `notifications/progress`.
- **Strict validation:** canonicalizes paths (zero shell execution, zero flag injection), rejects AppleDouble (`._*`) files, refuses accidental overwrites, and forwards structured `E_*` error envelopes so AI agents can self-correct.

---

## Exposed Tools (30 — MCP v3)

### Fast Read-Only Tools (FIFO Bypass — Instant)

| Tool | Purpose |
|---|---|
| `doctor` | Environment, worker, Apple-only `otool -L`, and queue health audit |
| `status` | Live SF-VIDEO-1 FIFO queue status, active ticket, waiting jobs, and thermal state |
| `capabilities` | Hardware capabilities (Metal GPU, ANE, Media Engines, all 12 VideoToolbox codecs, VTFrameProcessor, AudioToolbox, APFS `clonefile`) |
| `encoding_capabilities` | **Wave 11** live Apple VideoToolbox runtime capability profiler: enumerates real HW/SW encoders (`avc1`, `hvc1`, `muxa`, `apcn`, `apch`, `ap4h`, `av01`) and probes live `VTCompressionSession` properties (`Main10`, 2-pass, SpatialAQ, LookAhead, CQF) with per-machine/OS cache |
| `encoding_conformance` | **Wave 11** independent zero-FFmpeg bitstream & HLS validator: inspects ISOBMFF (`ftyp`/`moov`/`stsd`/`hvcC`/`avcC`/`dvcC`/`colr`/`mdcv`/`clli`/`moof`/`tfdt`/`trun`), 188-byte MPEG-TS (`PAT`/`PMT`/`CC`/`PCR`/`PTS`), or full RFC 8216/8216bis + Apple HLS Authoring ladders plus optional independent `AVAssetReader` frame decode |
| `encoding_plan` | **Wave 13/18** SPEC dry-run perceptual planner: analyzes shots, noise/grain, Vision text/face masks, banding risk (`max_cambi`), and transition types (hard cut vs flash/fade/pan), returning a structured per-shot `SPECPlan` with optional reusable `SPECAnalysisSidecar` JSON |
| `timeline_interop` | **Wave 17** bidirectional pro-NLE timeline exchange: converts losslessly between Final Cut Pro **FCPXML 1.11** (`.fcpxml`) and **OpenTimelineIO** (`.otio`) for DaVinci Resolve / Premiere / FCP, or inspects tracks, rational clip timings, gaps, and chapter markers |
| `qa_detect_defects` | **Wave 18** Self-Healing QA defect detector: scans video natively for black/frozen runs, **Native CAMBI** banding spikes, Thai/English text edge-clipping, chroma shifts, and **EBU R128 / ATSC A/85** loudness/clipping/dead-air issues, returning exact frame ranges, bounding boxes, and actionable `suggestedFix` instructions |
| `raster_info` | `libSafariumRaster.dylib` path, Apple-only linkage, ABI version, and symbol count (`418` symbols) |
| `forge_schema` | Machine-readable JSON schemas (`all`, `recipe`, `subcommands`, `errors`) |
| `forge_validate` | Validate a Forge recipe file or inline JSON object (with optional `--dry-run`) |
| `probe_media` | Native AVFoundation media inspection (codecs, resolution, fps, duration, colorimetry) |
| `cache_stats` | APFS copy-on-write incremental scene/shot cache statistics |
| `analyze_shots` | Wave 9 Metal/GPU shot-cut, spatial/temporal complexity, and gradient banding-risk analyzer (Safarium Mini-CAE planner) |
| `list_scenarios` | Wave 10 built-in catalog of all **19 video encoding scenarios** (`youtube`, `youtube-4k`, `shorts`, `tiktok`, `reels`, `web-streaming`, `web-compat`, `screen-recording`, `cinema-master`, `cinema-vfx`, `transparent-vfx`, `hdr-dolby-vision`, `hdr10`, `spatial-visionos`, `archival`, `live-low-latency`, `podcast-video`, `webp-clip`, `gif-clip`) |

### Heavy Render, Encode, AI Edit, Streaming & Repair Tools (SF-VIDEO-1 FIFO Serialized)

| Tool | Purpose |
|---|---|
| `encoding_encode` | **Wave 13/14/18** intent-level SPEC closed-loop quality-target hardware encode: declare perceptual goals (`target_vmaf`, `target_ms_ssim`, `max_deltae_p95`, `max_cambi`, `protect_text`, `protect_faces`, `preserve_grain`, `banding_sensitive`, `hdr_policy`, `power_budget`); runs short-window proxy convergence measuring real MS-SSIM, CIEDE2000 p95, and Native CAMBI, encodes via VideoToolbox + thermal hysteresis scheduler + atomic staging publish |
| `encoding_ladder` | **Wave 13/14** Per-Title Convex-Hull HLS ABR Ladder planner & packager: reuses one `SPECAnalysisSidecar` across all rungs (zero upscaling), aligns shared-IDR boundaries, packages CMAF fMP4 or MPEG-TS HLS, and auto-validates via `HLSConformanceValidator` *(pass `plan_only: true` for instant FIFO-bypass planning)* |
| `ai_reframe_vertical` | **Wave 15** on-device ANE/Vision **Thai-safe smart auto-reframe** (`16:9 → 9:16`, `1:1`, `4:5`): tracks faces, attention saliency, and Thai+English text bounding boxes with spring-damped velocity-capped panning so captions/titles are never clipped |
| `ai_auto_edit` | **Wave 15** on-device **Auto-Highlight & Silence-Cut** engine: detects dead-air gaps via `Accelerate` vDSP RMS with smooth crossfades or ranks peak audio/motion/visual highlight clips *(pass `plan_only: true` for instant FIFO-bypass planning)* |
| `ai_enhance_video` | **Wave 15** **Metal edge-masked de-banding + hardware super-resolution upscaling** before VideoToolbox encode with before/after Native CAMBI reduction metrics *(pass `probe_av1: true` for instant FIFO-bypass hardware AV1 readiness check)* |
| `stream_package_llhls_dash` | **Wave 16/17** native streaming packager: generates **RFC 8216bis Low-Latency HLS (LL-HLS)** (`#EXT-X-PART`, `#EXT-X-SERVER-CONTROL`, `#EXT-X-PRELOAD-HINT`) or **Dual CMAF HLS + ISO/IEC 23009-1 MPEG-DASH (`.mpd`)** sharing one set of fMP4 segments with automatic validation |
| `qa_surgical_repair` | **Wave 18** **Self-Healing bit-exact Closed-GOP surgical shot repair**: splices re-rendered replacement shot(s) into the original video with **zero re-encoding of untouched shots**, verifies SHA-256 bit-exact preservation, publishes atomically, and runs conformance + defect re-verification |
| `forge_run` | Run a declarative SafariumForge JSON DAG recipe (`--progress jsonl`, `--json-errors`) |
| `html_render` | Render HTML/CSS/SVG/WebGL2 deterministically via windowless `WKWebView` + `VideoToolbox` (all 12 codecs, 10-bit P010/P210/P410, CQF, SpatialAQ, Dolby Vision 8.4/HDR10/HLG) |
| `transcode_supremacy` | Wave 9/10 Apple Silicon hardware transcode: **19 built-in `--scenario` presets**, hardware **HDR→SDR tone-mapping (`tonemap_sdr`)**, 10-bit HEVC (`4:2:0`/`4:2:2`/`4:4:4`), 6 ProRes tiers, SpatialAQ + LookAhead + VBV, CQF, **True 2-Pass `VTMultiPassStorage`**, **Mini-CAE** multi-engine adaptive encoding, zero-copy `VTFrameProcessor` denoise/retime, and HDR mastering |
| `package_hls` | Wave 10 **0%-FFmpeg native HLS ABR ladder packager** (`.fmp4` CMAF via `AVAssetWriter` + `.ts` via pure-Swift 188-byte MPEG-TS muxer, multi-rung scaling, Closed-GOP aligned segments, RFC 8216 `master.m3u8`, optional WebVTT subtitles) |
| `export_animated_clip` | Wave 10 direct video-to-animated clip exporter (`webp` lossless VP8L `RIFF....WEBPVP8X`, `gif`, `apng` via `AVAssetReader` + `ImageIO` — 0% FFmpeg) |
| `audio_encode` | Wave 9 Apple AudioToolbox mastering encoder (`aac-max`, `he-aac`, `he-aac-v2`, `alac`, `opus`, `apac`, `pcm16/24/32f`) |
| `verify_media` | Zero-FFmpeg AVFoundation inspection or reference-vs-candidate parity comparison |
| `qa_inspect` | Scene-cut/silence detection, perceptual MS-SSIM/CIEDE2000 comparison, Vision Thai OCR, and contact sheets |

### Resources (5) & Prompts (3)

- **Resources:** `safarium://docs/render-standard`, `safarium://docs/project-video-rule`, `safarium://docs/ai-control-protocol`, `safarium://schema/all`, `safarium://status/live`
- **Prompts:** `preflight_check`, `render_and_verify`, `diagnose_render_failure`

---

## Quick Setup for Every AI Client

> Replace `/Users/<username>` with your actual macOS home directory path (GUI clients like Claude Desktop and Cursor do not expand `~`).

### Claude Code

```sh
claude mcp add --transport stdio --scope user safarium -- "$HOME/.local/bin/safarium-mcp"
```

Or project-level `.mcp.json`:

```json
{
  "mcpServers": {
    "safarium": {
      "type": "stdio",
      "command": "/Users/<username>/.local/bin/safarium-mcp",
      "args": [],
      "env": {
        "SAFARIUM_JSON_ERRORS": "1"
      }
    }
  }
}
```

### Claude Desktop (macOS)

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "safarium": {
      "command": "/Users/<username>/.local/bin/safarium-mcp",
      "args": [],
      "env": {
        "SAFARIUM_JSON_ERRORS": "1"
      }
    }
  }
}
```

### Cursor

Add to `~/.cursor/mcp.json` (or `.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "safarium": {
      "type": "stdio",
      "command": "/Users/<username>/.local/bin/safarium-mcp",
      "args": [],
      "env": {
        "SAFARIUM_JSON_ERRORS": "1"
      }
    }
  }
}
```

### Gemini CLI

```sh
gemini mcp add -s user safarium "$HOME/.local/bin/safarium-mcp"
```

Or in `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "safarium": {
      "command": "/Users/<username>/.local/bin/safarium-mcp",
      "args": [],
      "env": {
        "SAFARIUM_JSON_ERRORS": "1"
      }
    }
  }
}
```

### Codex CLI

```sh
codex mcp add safarium --command "$HOME/.local/bin/safarium-mcp"
```

Or in `~/.codex/config.toml`:

```toml
[mcp_servers.safarium]
command = "/Users/<username>/.local/bin/safarium-mcp"
args = []
startup_timeout_sec = 15
tool_timeout_sec = 900

[mcp_servers.safarium.env]
SAFARIUM_JSON_ERRORS = "1"
```

---

## Verification

```sh
python3 -m unittest Tests/mcp/test_mcp.py -v
```
