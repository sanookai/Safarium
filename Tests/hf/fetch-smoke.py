#!/usr/bin/env python3
"""Exercise real HyperFrames check + its video frame transport through Safarium.

Uses a local copy of GSAP, encodes a five-bit number into each source frame and
checks the number after HF renders/mixes the clip. Everything goes into a new
scratch directory; no reference Chrome or dependency installation is needed.
"""
from __future__ import annotations

import argparse
import array
import collections
from fractions import Fraction
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import tempfile
import wave

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
N, FPS, W, H = 30, 30, 160, 120


def make_assets(scene: Path, gsap: Path) -> None:
    assets = scene / "assets"
    assets.mkdir(parents=True)
    shutil.copyfile(HERE / "fetch-scene.html", scene / "index.html")
    shutil.copyfile(gsap, assets / "gsap.min.js")
    frames = bytearray()
    for i in range(N):
        color = [(220, 45, 45), (45, 220, 45), (45, 45, 220)][i // 10]
        frame = bytearray(bytes(color) * (W * H))
        for bit in range(5):
            level = 240 if (i >> bit) & 1 else 16
            for y in range(76, 105):
                start = 3 * (W * y + 8 + 28 * bit)
                frame[start:start + 60] = bytes([level]) * 60
        frames.extend(frame)
    subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pixel_format", "rgb24",
                    "-video_size", f"{W}x{H}", "-framerate", str(FPS), "-i", "pipe:0",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "1", "-crf", "12",
                    str(assets / "signal.mp4")], input=frames, check=True)
    with wave.open(str(assets / "tone.wav"), "wb") as w:
        w.setparams((1, 2, 48000, 0, "NONE", ""))
        w.writeframes(array.array("h", (int(4000 * math.sin(2 * math.pi * 440 * i / 48000))
                                        for i in range(48000))).tobytes())


def cli(cmd, cwd, env, log):
    with log.open("wb") as f:
        p = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT,
                             start_new_session=True)
        try:
            return p.wait(timeout=65)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
            return 124


def tone_stats(samples):
    power = sum(x*x for x in samples)
    if not power:
        return 0.0, 0.0
    fraction = 2 * sum(sum(x*fn(2*math.pi*440*i/8000) for i, x in enumerate(samples))**2
                       for fn in (math.sin, math.cos)) / (len(samples)*power)
    return math.sqrt(power/len(samples)), fraction


def audio_coverage(stream, samples):
    # Allow one video frame of encoder delay/padding; require container timing AND decoded audio.
    span, tol = Fraction(N, FPS), Fraction(1, FPS)
    def ts(ticks, seconds):
        try:
            return int(stream[ticks]) * Fraction(stream["time_base"])
        except (KeyError, ValueError, TypeError, ZeroDivisionError):
            try:
                return Fraction(stream[seconds])
            except (KeyError, ValueError, TypeError, ZeroDivisionError):
                return None
    start, duration = ts("start_pts", "start_time"), ts("duration_ts", "duration")
    decoded = Fraction(len(samples), 8000)
    covers = (start is not None and duration is not None and abs(start) <= tol
              and abs(duration-span) <= tol and abs(start+duration-span) <= tol and abs(decoded-span) <= tol)
    # 100-ms windows (44 cycles) close to each end, measured on the output timeline.
    offset = round((start or 0)*8000)
    windows = {}
    for label, at in (("start", 320), ("end", 6880)):  # 40–140 ms, 860–960 ms
        first = at-offset
        part = samples[first:first+800] if first >= 0 else []
        rms, tone = tone_stats(part)
        windows[label] = {"samples": len(part), "rms_s16": round(rms, 2), "tone_440hz_fraction": round(tone, 4),
                          "pass": len(part) == 800 and rms > 100 and tone > .8}
    return {"pass": covers and all(w["pass"] for w in windows.values()), "timing_ok": covers,
            "start_seconds": float(start) if start is not None else None,
            "duration_seconds": float(duration) if duration is not None else None,
            "decoded_seconds": float(decoded), "tolerance_seconds": float(tol), "windows": windows}


def verify(video):
    streams = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-count_frames",
                         "-show_entries", "stream=codec_type,codec_name,width,height,nb_read_frames,avg_frame_rate,duration,"
                         "start_time,start_pts,duration_ts,time_base",
                         "-of", "json", str(video)]))["streams"]
    v = next(s for s in streams if s["codec_type"] == "video")
    if (v["width"], v["height"]) != (320, 180):
        return {"pass": False, "streams": streams, "error": "wrong canvas size"}
    raw = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(video), "-map", "0:v:0",
                                  "-fps_mode", "passthrough", "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"])
    timing = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                        "-show_entries", "frame=best_effort_timestamp:stream=time_base", "-of", "json", str(video)]))
    unit = Fraction(timing["streams"][0]["time_base"])
    aligned = [int(f["best_effort_timestamp"])*unit for f in timing["frames"]] == [Fraction(i,FPS) for i in range(N)]
    size = 3 * 320 * 180
    ids, bands = [], []
    for offset in range(0, len(raw), size):
        def rgb(x, y):
            p = offset + 3 * (y * 320 + x)
            return raw[p:p + 3]
        ids.append(sum((sum(rgb(18 + bit * 28, 90)) > 3 * 128) << bit for bit in range(5)))
        channels = rgb(82, 40)
        bands.append(max(range(3), key=channels.__getitem__) if max(channels)-min(channels)>80 else -1)
    audio = array.array("h")
    a = next((s for s in streams if s["codec_type"] == "audio"), {})
    if a:
        audio.frombytes(subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(video),
                        "-map", "0:a:0", "-ac", "1", "-ar", "8000", "-f", "s16le", "pipe:1"]))
    rms = math.sqrt(statistics.mean(x*x for x in audio)) if audio else 0
    _, tone = tone_stats(audio[800:7200])
    coverage = audio_coverage(a, audio)
    return {"pass": ids == list(range(N)) and bands == [i//10 for i in range(N)] and rms>100 and tone>.8 and aligned
            and v["avg_frame_rate"] == "30/1" and v["nb_read_frames"] == "30" and coverage["pass"],
            "streams": streams, "frame_ids": ids, "correct_ids": sum(i==k for i,k in enumerate(ids)),
            "correct_color_bands": sum(i//10==k for i,k in enumerate(bands)), "exact_timestamps": aligned,
            "audio_rms_s16": round(rms, 2), "tone_440hz_fraction": round(tone,4), "audio_coverage": coverage}


def audit_summary(directory):
    paths = sorted(directory.glob("audit-*.json"))
    counts = collections.Counter()
    unique = set()
    accepted, complete = 0, bool(paths)
    for path in paths:
        try:
            report = json.loads(path.read_bytes())
            complete &= report["format"] == 1 and report["complete"] is True
            counts.update(report["counts"])
            seen = set()
            for row in report["frames"]:
                if (row["route"] == "hf-video-frame" and row["reply"] == "success" and row["responseCode"] == 200
                    and row["contentType"] in ("image/jpeg", "image/png") and row["length"] > 0
                    and isinstance(row["sessionId"], str) and row["sessionId"]
                    and isinstance(row["requestId"], str) and row["requestId"]
                    and type(row["commandId"]) is int and row["commandId"] >= 0
                    and re.fullmatch("[0-9a-f]{64}", row["sha256"])):
                    pair = (row["sessionId"], row["requestId"], row["commandId"])
                    if pair in seen:
                        complete = False
                        continue
                    seen.add(pair)
                    accepted += 1
                    unique.add(row["sha256"])
        except (OSError, ValueError, KeyError, TypeError):
            complete = False
    return {"counts": dict(counts), "audit_files": len(paths), "complete": complete,
            "successful_frame_replies": accepted, "distinct_successful_image_bodies": len(unique),
            "pass": complete and len(unique) >= N}


def audit_wrapper(work, phase, shim):
    # HF may sanitize the browser environment. Bake absolute paths into this fixture's wrapper.
    directory = work / f"{phase}-audit"
    directory.mkdir()
    wrapper = work / f"webkit-only-{phase}"
    node = shutil.which("node")
    if not node:
        raise RuntimeError("node is required for the local CDP pipe observer")
    tap = shlex.join([node, str(HERE / "fetch-audit-pipe.mjs"), str(shim), str(directory)])
    wrapper.write_text("#!/bin/sh\nunset SAFARIUM_CDP_TRACE\nexport SAFARIUM_CDP_LOG=" + shlex.quote(str(work / "unknown.log")) +
                       '\nfor arg do\n  if [ "$arg" = --remote-debugging-pipe ]; then\n    exec ' + tap +
                       ' "$@"\n  fi\ndone\nexec ' + shlex.quote(str(shim)) + ' "$@"\n')
    wrapper.chmod(0o700)
    return str(wrapper), directory


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shim", type=Path, required=True)
    ap.add_argument("--gsap", type=Path, required=True, help="existing local gsap.min.js")
    ap.add_argument("--scratch", type=Path, required=True)
    ap.add_argument("--hf-version", default="0.9.72", help="exact, locally cached HyperFrames release")
    phase = ap.add_mutually_exclusive_group()
    phase.add_argument("--check-only", action="store_true")
    phase.add_argument("--render-only", action="store_true")
    a = ap.parse_args()
    work = Path(tempfile.mkdtemp(dir=a.scratch.resolve(), prefix="hf-fetch-"))
    scene = work / "scene"
    make_assets(scene, a.gsap)
    shim = a.shim.resolve()
    env = {**os.environ, "SAFARIUM_HF_VERSION": a.hf_version,
           "HYPERFRAMES_RENDER_LOCK_DIR": str(work / "locks"),
           "npm_config_offline": "true", "DO_NOT_TRACK": "1"}
    run = [str(ROOT / "bin/safarium-hf")]
    print("evidence:", work, flush=True)
    summary = {"hyperframes": a.hf_version, "coverage": "render" if a.render_only else "check" if a.check_only else "check+render"}
    ok = True
    if not a.render_only:
        check_wrapper, check_dir = audit_wrapper(work, "check", shim)
        rc1 = cli(run + ["check", str(scene), "--json", "--samples", "2", "--no-cache",
                         "--budget", "30s"], scene, {**env, "SAFARIUM_CDP": check_wrapper}, work / "check.log")
        check_audit = audit_summary(check_dir)
        checks = {"rc": rc1, "trace": check_audit["counts"], "audit_complete": check_audit["complete"]}
        reports = list((scene/".hyperframes/artifacts/checks").glob("*.json"))
        text = (work / "check.log").read_text(errors="replace")
        try:
            obj = (json.loads(reports[0].read_text()) if len(reports) == 1 else
                   json.JSONDecoder().raw_decode(text[text.index('{\n  "ok"'):])[0])
            checks.update({k: obj[k] for k in ("ok", "browserSkipped") if k in obj})
        except (ValueError, KeyError):
            pass
        summary["check"] = checks
        ok = (rc1 == 0 and checks.get("ok") is True and checks.get("browserSkipped") is False
              and checks["audit_complete"] and checks["trace"].get("Fetch.enable", 0) > 0)
    if not a.check_only:
        video = work / "transport.mp4"
        render_wrapper, render_dir = audit_wrapper(work, "render", shim)
        rc2 = cli(run + ["render", str(scene), "--fps", str(FPS), "--quality", "looks", "-w", "1",
                         "--frames-cache-dir=off", "--no-wait", "-o", str(video)],
                  scene, {**env, "SAFARIUM_CDP": render_wrapper}, work / "render.log")
        render_audit = audit_summary(render_dir)
        render_counts = render_audit["counts"]
        summary["render"] = {"rc": rc2, "trace": render_counts, "transport": render_audit}
        if rc2 == 0 and video.exists():
            summary["render"].update(verify(video))
        render = summary["render"]
        render["media_pass"] = render.get("pass") is True
        render["pass"] = render["media_pass"] and render_counts.get("video_frame_pauses_visible_in_trace", 0)>0 and render_audit["pass"]
        ok = ok and render["pass"]
    summary["pass"] = ok
    (work / "evidence.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
