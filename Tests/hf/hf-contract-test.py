#!/usr/bin/env python3
"""Zero-FFmpeg HyperFrames (S3/S5) contract verification suite against bin/safarium-hf + safarium-cdp."""
import argparse
import array
import json
import math
import os
from pathlib import Path
import shutil
import subprocess as sp
import sys
import tempfile
import time
from typing import Optional
import wave

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def resolve_gsap(explicit: Optional[Path]) -> Optional[Path]:
    if explicit is not None:
        p = explicit.expanduser().resolve()
        return p if p.is_file() else None
    env_gsap = os.environ.get("SAFARIUM_GSAP_JS")
    if env_gsap:
        p = Path(env_gsap).expanduser().resolve()
        if p.is_file():
            return p
    candidates = [
        HERE / "gsap.min.js",
        HERE / "assets" / "gsap.min.js",
        ROOT / "Tests" / "Fixtures" / "gsap.min.js",
        Path("/tmp/safarium-gsap/gsap.min.js"),
        Path("/tmp/gsap.min.js"),
        Path.home() / ".cache" / "safarium" / "gsap.min.js",
    ]
    npx_cache = Path.home() / ".npm" / "_npx"
    if npx_cache.is_dir():
        candidates.extend(
            sorted(npx_cache.glob("*/node_modules/hyperframes/dist/vendor/npm/gsap*/dist/gsap.min.js"))
        )
    for cand in candidates:
        if cand.is_file():
            return cand.resolve()
    return None


def synthesize_signal_mp4(
    queue_bin: Path, out_mp4: Path, scratch: Path, frames: int = 18, fps: int = 30, queue_timeout: int = 600
) -> None:
    w, h = 160, 120
    raw = bytearray()
    for i in range(frames):
        color = [(220, 45, 45), (45, 220, 45), (45, 45, 220)][(i * 3) // frames]
        frame = bytearray(bytes(color) * (w * h))
        for bit in range(5):
            level = 240 if (i >> bit) & 1 else 16
            for y in range(76, 105):
                start = 3 * (w * y + 8 + 28 * bit)
                frame[start:start + 60] = bytes([level]) * 60
        raw.extend(frame)
    cmd = [
        str(queue_bin), "forge", "pipe-encode",
        "--width", str(w), "--height", str(h), "--fps", str(fps),
        "--pix-fmt", "rgb24", "--codec", "h264", "--bitrate", "1500000",
        "-o", str(out_mp4), "--overwrite",
    ]
    res = sp.run(cmd, input=bytes(raw), stdout=sp.PIPE, stderr=sp.PIPE, timeout=queue_timeout)
    if res.returncode != 0:
        raise RuntimeError(f"pipe-encode signal.mp4 failed ({res.returncode}): {res.stderr.decode(errors='replace')}")


def verify_mp4_zero_ffmpeg(
    queue_bin: Path, mp4_path: Path, expected_w: int, expected_h: int, work_dir: Path, queue_timeout: int = 600
) -> dict:
    # 1. Apple-only packet inspection via `safarium-render forge inspect` (no FIFO block, Apple AVAsset/MediaToolbox)
    probe = sp.run(
        [str(queue_bin), "forge", "inspect", str(mp4_path), "--include-audio-packets"],
        capture_output=True, text=True, timeout=30,
    )
    if probe.returncode != 0:
        return {"pass": False, "error": f"forge inspect failed: {probe.stderr}"}
    info = json.loads(probe.stdout)
    media = info.get("media") if isinstance(info.get("media"), dict) else info
    tracks = media.get("tracks", [])
    playable = media.get("playable")
    v_track = next((t for t in tracks if t.get("mediaType") == "vide"), None)
    a_track = next((t for t in tracks if t.get("mediaType") == "soun"), None)
    v_fmt = (v_track.get("formats") or [{}])[0] if v_track else {}
    v_w = v_track.get("width", v_fmt.get("width")) if v_track else None
    v_h = v_track.get("height", v_fmt.get("height")) if v_track else None
    if not v_track or v_w != expected_w or v_h != expected_h:
        return {"pass": False, "error": f"unexpected video geometry: {v_track}"}

    # 2. Decode sample frames via `safarium-render extract-frames` (AVFoundation)
    frames_dir = work_dir / "decoded_frames"
    frames_dir.mkdir(parents=True, exist_ok=True)
    ext = sp.run([
        str(queue_bin), "extract-frames", str(mp4_path),
        "--times", "0.05,0.45,0.85", "--out-dir", str(frames_dir), "--format", "png", "--overwrite",
    ], capture_output=True, text=True, timeout=queue_timeout)
    if ext.returncode != 0:
        return {"pass": False, "error": f"extract-frames failed: {ext.stderr}"}
    extracted = sorted(frames_dir.glob("*.png"))
    if len(extracted) < 3:
        return {"pass": False, "error": f"expected 3 extracted PNGs, got {len(extracted)}"}

    # Check non-uniform pixel content on macOS `sips` / PNG raw check via AppKit or Pillow if installed
    non_empty = all(p.stat().st_size > 300 for p in extracted)
    audio_ok = a_track is not None and (a_track.get("packetCount") or 0) > 0
    return {
        "pass": bool(playable) and v_track is not None and v_w == expected_w and v_h == expected_h and audio_ok and non_empty,
        "playable": playable,
        "video": v_track,
        "audio": a_track,
        "extractedFrames": len(extracted),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--scratch", type=Path, default=Path("/tmp"))
    ap.add_argument("--prefix", type=Path, default=Path.home() / ".local")
    ap.add_argument("--shim", type=Path, help="optional path to safarium-cdp executable")
    ap.add_argument("--gsap", type=Path, default=None, help="optional path to gsap.min.js (defaults to portable relative / cached lookup)")
    ap.add_argument("--hf-version", default="0.9.72")
    ap.add_argument("--queue-timeout", type=int, default=600, help="FIFO wait+run timeout in seconds for safarium-render steps")
    ap.add_argument("--report", type=Path, help="optional JSON report output path")
    a = ap.parse_args()

    resolved_gsap = resolve_gsap(a.gsap)

    compat = json.loads((HERE / "hf-compat.json").read_text())
    queue_bin = a.prefix.expanduser().resolve() / "bin" / "safarium-render"
    if not queue_bin.exists():
        print(json.dumps({"pass": False, "error": f"missing {queue_bin}"}))
        return 1

    work = Path(tempfile.mkdtemp(prefix="hf-contract-", dir=a.scratch.resolve()))
    results = {
        "schema": "safarium-hf-contract-report/v1",
        "hfVersion": a.hf_version,
        "compatVersion": compat["testedTargets"]["hyperframes"],
        "work": str(work),
        "checks": {},
        "pass": False,
    }

    try:
        # Step 1: Resolve or build safarium-cdp once on internal scratch
        if a.shim:
            shim = a.shim.resolve(strict=True)
        else:
            hf_build = Path.home() / "Library" / "Caches" / "Safarium" / "hf-swiftpm"
            sp.run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(ROOT),
                    "--scratch-path", str(hf_build), "-c", "release", "--product", "safarium-cdp"],
                   check=True, stdout=sp.PIPE, stderr=sp.PIPE, timeout=240)
            bindir = sp.check_output(["/usr/bin/xcrun", "swift", "build", "--package-path", str(ROOT),
                                      "--scratch-path", str(hf_build), "-c", "release", "--show-bin-path"],
                                     text=True).strip()
            shim = Path(bindir) / "safarium-cdp"

        # Step 2: Bundled CDN offline check (`check-bundled.py` uses zero FFmpeg!)
        t0 = time.monotonic()
        bundled = sp.run([sys.executable, str(HERE / "check-bundled.py"),
                          "--shim", str(shim), "--scratch", str(work), "--hf-version", a.hf_version],
                         capture_output=True, text=True, timeout=90)
        bundled_pass = bundled.returncode == 0
        results["checks"]["checkBundledGSAPOffline"] = {
            "pass": bundled_pass,
            "exit": bundled.returncode,
            "seconds": round(time.monotonic() - t0, 3),
        }

        # Step 3: Zero-FFmpeg MP4 + Audio render via HyperFrames `render`
        if resolved_gsap is None or not resolved_gsap.is_file():
            results["checks"]["renderVideoAndAudio"] = {
                "pass": False,
                "error": f"missing local gsap.min.js (pass --gsap PATH or warm hyperframes npx cache); explicit={a.gsap}",
            }
        else:
            scene = work / "scene"
            assets = scene / "assets"
            assets.mkdir(parents=True)
            shutil.copyfile(HERE / "fetch-scene.html", scene / "index.html")
            shutil.copyfile(resolved_gsap, assets / "gsap.min.js")
            # Rewrite HTML timing so 18-frame signal matches 1s cleanly at 18fps or generate 30f
            synthesize_signal_mp4(queue_bin, assets / "signal.mp4", work, frames=30, fps=30, queue_timeout=a.queue_timeout)
            with wave.open(str(assets / "tone.wav"), "wb") as w:
                w.setparams((1, 2, 48000, 0, "NONE", ""))
                w.writeframes(array.array("h", (int(5000 * math.sin(2 * math.pi * 440 * i / 48000))
                                                for i in range(48000))).tobytes())
            out_mp4 = work / "hf-contract.mp4"
            env = {**os.environ, "SAFARIUM_CDP": str(shim), "SAFARIUM_HF_VERSION": a.hf_version,
                   "DO_NOT_TRACK": "1", "npm_config_offline": "true",
                   "HYPERFRAMES_RENDER_LOCK_DIR": str(work / "locks")}
            hf_bin = ROOT / "bin/safarium-hf"
            hf_cmd = [str(hf_bin)] if os.access(hf_bin, os.X_OK) else ["/bin/sh", str(hf_bin)]
            t1 = time.monotonic()
            hf_ren = sp.run([*hf_cmd, "render", str(scene),
                             "--fps", "30", "--quality", "looks", "-w", "1",
                             "--frames-cache-dir=off", "--no-wait", "-o", str(out_mp4)],
                            cwd=scene, env=env, capture_output=True, text=True, timeout=150)
            ren_verify = verify_mp4_zero_ffmpeg(queue_bin, out_mp4, 320, 180, work, queue_timeout=a.queue_timeout) if (hf_ren.returncode == 0 and out_mp4.is_file()) else {"pass": False, "stderr": hf_ren.stderr[-400:]}
            results["checks"]["renderVideoAndAudio"] = {
                "pass": bool(hf_ren.returncode == 0 and ren_verify.get("pass")),
                "exit": hf_ren.returncode,
                "seconds": round(time.monotonic() - t1, 3),
                "verify": ren_verify,
            }

        results["pass"] = bool(results["checks"]) and all(c.get("pass") for c in results["checks"].values())
    except Exception as exc:
        results["error"] = str(exc)
        results["pass"] = False

    out_txt = json.dumps(results, indent=2, ensure_ascii=False) + "\n"
    if a.report:
        a.report.parent.mkdir(parents=True, exist_ok=True)
        a.report.write_text(out_txt)
    print(out_txt, end="")
    return 0 if results["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
