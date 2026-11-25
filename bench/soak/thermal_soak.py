#!/usr/bin/env python3
"""Wave 14A: Sustained Thermal & Energy Soak Harness for Safarium.

Repeatedly encodes a deterministic synthetic clip via `"$HOME/.local/bin/safarium" forge transcode`
(zero FFmpeg dependency), recording per-iteration:
  - wall_s
  - fps
  - peak_rss_mb (from macOS `/usr/bin/time -l`)
  - pmset -g therm (raw + parsed CPU_Speed_Limit / CPU_Scheduler_Limit / CPU_Available_CPUs)
  - output_sha256 (plus ISOBMFF mdat_sha256 to prove media output never drifts under thermal load)

Usage:
  python3 bench/soak/thermal_soak.py --quick
  python3 bench/soak/thermal_soak.py --duration-sec 1800 --output-json /tmp/safarium-soak.json
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import resource
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


_STOP_REQUESTED = False


def _handle_signal(signum: int, _frame: Any) -> None:
    global _STOP_REQUESTED
    _STOP_REQUESTED = True


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def sha256_isobmff_mdat(path: Path) -> str | None:
    """Computes SHA-256 over all top-level ISOBMFF `mdat` payloads (invariant to mvhd timestamps)."""
    data = path.read_bytes()
    n = len(data)
    offset = 0
    h = hashlib.sha256()
    found_mdat = False

    while offset + 8 <= n:
        size32, box_type = struct.unpack_from(">I4s", data, offset)
        header_size = 8
        if size32 == 1:
            if offset + 16 > n:
                break
            box_size = struct.unpack_from(">Q", data, offset + 8)[0]
            header_size = 16
        elif size32 == 0:
            box_size = n - offset
        else:
            box_size = size32

        if box_size < header_size or offset + box_size > n:
            break

        if box_type == b"mdat":
            h.update(data[offset + header_size : offset + box_size])
            found_mdat = True

        offset += box_size

    return h.hexdigest() if found_mdat else None


def read_pmset_therm() -> dict[str, Any]:
    """Queries macOS `pmset -g therm` and parses key thermal throttling metrics."""
    try:
        proc = subprocess.run(
            ["pmset", "-g", "therm"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        raw = (proc.stdout or proc.stderr or "").strip()
    except Exception as exc:
        return {
            "raw": f"pmset_error: {exc}",
            "cpu_speed_limit": None,
            "cpu_scheduler_limit": None,
            "cpu_available_cpus": None,
            "thermal_warnings": True,
        }

    def _extract_int(key: str) -> int | None:
        m = re.search(rf"{re.escape(key)}\s*=\s*(\d+)", raw)
        return int(m.group(1)) if m else None

    speed_limit = _extract_int("CPU_Speed_Limit")
    sched_limit = _extract_int("CPU_Scheduler_Limit")
    avail_cpus = _extract_int("CPU_Available_CPUs")
    has_warning = (
        ("No thermal warning level has been recorded" not in raw and "warning" in raw.lower())
        or (speed_limit is not None and speed_limit < 100)
    )

    return {
        "raw": raw,
        "cpu_speed_limit": speed_limit,
        "cpu_scheduler_limit": sched_limit,
        "cpu_available_cpus": avail_cpus,
        "thermal_warnings": has_warning,
    }


def parse_macos_time_l_max_rss_mb(stderr_text: str) -> float | None:
    """Extracts peak RSS in MiB from macOS `/usr/bin/time -l` stderr output."""
    m = re.search(r"(\d+)\s+maximum resident set size", stderr_text)
    if m:
        # On macOS/Darwin, `maximum resident set size` from `/usr/bin/time -l` is in bytes.
        return int(m.group(1)) / (1024.0 * 1024.0)
    return None


def generate_deterministic_clip(
    safarium_bin: Path,
    output_mp4: Path,
    width: int,
    height: int,
    fps: int,
    frames: int,
) -> None:
    """Synthesizes a deterministic BGRA clip natively via `safarium forge pipe-encode` (zero FFmpeg)."""
    cmd = [
        str(safarium_bin),
        "forge",
        "pipe-encode",
        "--width",
        str(width),
        "--height",
        str(height),
        "--fps",
        str(fps),
        "--pix-fmt",
        "bgra",
        "--codec",
        "h264",
        "--bitrate",
        "4000000",
        "-o",
        str(output_mp4),
        "--overwrite",
    ]

    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdin is not None

    row_bytes = width * 4
    base_x = bytearray(row_bytes)
    for x in range(width):
        off = x * 4
        base_x[off] = (x * 3) & 0xFF
        base_x[off + 1] = (x * 5) & 0xFF
        base_x[off + 2] = (x * 7) & 0xFF
        base_x[off + 3] = 255

    # Build deterministic moving color-bar + gradient frames cheaply using slicing.
    stripe_period = max(16, width // 8)
    try:
        for f in range(frames):
            shift = (f * 6) % width
            shifted_row = bytes(base_x[shift * 4 :]) + bytes(base_x[: shift * 4])
            alt_shift = ((f * 11) + stripe_period) % width
            alt_row = bytes(base_x[alt_shift * 4 :]) + bytes(base_x[: alt_shift * 4])

            frame_chunks: list[bytes] = []
            for y in range(height):
                if ((y // 16) + f) % 2 == 0:
                    frame_chunks.append(shifted_row)
                else:
                    frame_chunks.append(alt_row)
            proc.stdin.write(b"".join(frame_chunks))
        proc.stdin.flush()
        proc.stdin.close()
        proc.stdin = None
    except BrokenPipeError:
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except Exception:
            pass
        proc.stdin = None

    stdout_b, stderr_b = proc.communicate(timeout=120)
    if proc.returncode != 0 or not output_mp4.exists() or output_mp4.stat().st_size == 0:
        raise RuntimeError(
            f"Failed to synthesize deterministic input clip (rc={proc.returncode}): "
            f"{stderr_b.decode('utf-8', errors='replace')}\n{stdout_b.decode('utf-8', errors='replace')}"
        )


def run_transcode_iteration(
    safarium_bin: Path,
    input_clip: Path,
    output_clip: Path,
    codec: str,
    bitrate: int,
    frames: int,
) -> dict[str, Any]:
    transcode_cmd = [
        str(safarium_bin),
        "forge",
        "transcode",
        str(input_clip),
        "-o",
        str(output_clip),
        "--codec",
        codec,
        "--bitrate",
        str(bitrate),
        "--overwrite",
    ]

    use_usr_time = Path("/usr/bin/time").exists()
    cmd = ["/usr/bin/time", "-l", *transcode_cmd] if use_usr_time else transcode_cmd

    t0 = time.perf_counter()
    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        check=False,
    )
    wall_s = max(1e-6, time.perf_counter() - t0)

    peak_rss_mb = parse_macos_time_l_max_rss_mb(proc.stderr) if use_usr_time else None
    if peak_rss_mb is None:
        # Fallback to RUSAGE_CHILDREN (bytes on macOS).
        peak_rss_mb = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / (1024.0 * 1024.0)

    therm = read_pmset_therm()
    ok = proc.returncode == 0 and output_clip.exists() and output_clip.stat().st_size > 0

    output_bytes = output_clip.stat().st_size if ok else 0
    output_sha = sha256_file(output_clip) if ok else None
    mdat_sha = sha256_isobmff_mdat(output_clip) if ok else None

    return {
        "timestamp_utc": utc_now_iso(),
        "ok": ok,
        "returncode": proc.returncode,
        "wall_s": round(wall_s, 4),
        "fps": round(frames / wall_s, 2) if ok else 0.0,
        "peak_rss_mb": round(peak_rss_mb, 2),
        "pmset_therm": therm,
        "output_bytes": output_bytes,
        "output_sha256": output_sha,
        "mdat_sha256": mdat_sha,
        "stderr_tail": proc.stderr[-400:].strip() if not ok else "",
    }


def percentile(sorted_values: list[float], pct: float) -> float:
    if not sorted_values:
        return 0.0
    if len(sorted_values) == 1:
        return sorted_values[0]
    idx = (len(sorted_values) - 1) * (pct / 100.0)
    lo = int(idx)
    hi = min(len(sorted_values) - 1, lo + 1)
    frac = idx - lo
    return sorted_values[lo] * (1.0 - frac) + sorted_values[hi] * frac


def summarize_iterations(iterations: list[dict[str, Any]]) -> dict[str, Any]:
    ok_iters = [it for it in iterations if it.get("ok")]
    wall_vals = sorted(float(it["wall_s"]) for it in ok_iters)
    fps_vals = [float(it["fps"]) for it in ok_iters]
    rss_vals = [float(it["peak_rss_mb"]) for it in ok_iters]
    speed_limits = [
        int(it["pmset_therm"]["cpu_speed_limit"])
        for it in ok_iters
        if it.get("pmset_therm", {}).get("cpu_speed_limit") is not None
    ]
    out_hashes = [it["output_sha256"] for it in ok_iters if it.get("output_sha256")]
    mdat_hashes = [it["mdat_sha256"] for it in ok_iters if it.get("mdat_sha256")]

    fps_degradation_pct = 0.0
    if len(fps_vals) >= 4:
        q = max(1, len(fps_vals) // 4)
        first_q = statistics.mean(fps_vals[:q])
        last_q = statistics.mean(fps_vals[-q:])
        if first_q > 0:
            fps_degradation_pct = ((first_q - last_q) / first_q) * 100.0

    rss_growth_mb = (rss_vals[-1] - rss_vals[0]) if len(rss_vals) >= 2 else 0.0

    return {
        "iterations_total": len(iterations),
        "iterations_succeeded": len(ok_iters),
        "iterations_failed": len(iterations) - len(ok_iters),
        "mean_wall_s": round(statistics.mean(wall_vals), 4) if wall_vals else 0.0,
        "p50_wall_s": round(percentile(wall_vals, 50.0), 4) if wall_vals else 0.0,
        "p95_wall_s": round(percentile(wall_vals, 95.0), 4) if wall_vals else 0.0,
        "mean_fps": round(statistics.mean(fps_vals), 2) if fps_vals else 0.0,
        "min_fps": round(min(fps_vals), 2) if fps_vals else 0.0,
        "max_fps": round(max(fps_vals), 2) if fps_vals else 0.0,
        "fps_degradation_pct": round(fps_degradation_pct, 2),
        "max_peak_rss_mb": round(max(rss_vals), 2) if rss_vals else 0.0,
        "rss_growth_mb": round(rss_growth_mb, 2),
        "min_cpu_speed_limit": min(speed_limits) if speed_limits else None,
        "unique_output_sha256_count": len(set(out_hashes)),
        "output_sha256_consistent": len(set(out_hashes)) <= 1 and len(out_hashes) == len(ok_iters),
        "unique_mdat_sha256_count": len(set(mdat_hashes)),
        "mdat_sha256_consistent": len(set(mdat_hashes)) <= 1 and len(mdat_hashes) == len(ok_iters),
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Safarium Wave 14A sustained thermal & energy soak harness."
    )
    parser.add_argument(
        "--duration-sec",
        type=float,
        default=1800.0,
        help="Total soak duration in seconds (default: 1800 for 30-min lab soak).",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="Quick 20-second verification soak mode (overrides --duration-sec to 20).",
    )
    parser.add_argument(
        "--safarium-bin",
        type=Path,
        default=Path(os.path.expanduser("~/.local/bin/safarium")),
        help="Path to the safarium executable (default: ~/.local/bin/safarium).",
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=None,
        help="Optional existing deterministic clip; if omitted, synthesizes one via `safarium forge pipe-encode`.",
    )
    parser.add_argument(
        "--output-json",
        type=Path,
        default=None,
        help="Destination path for the soak summary JSON report.",
    )
    parser.add_argument("--width", type=int, default=640, help="Synthetic clip width (default: 640).")
    parser.add_argument("--height", type=int, default=360, help="Synthetic clip height (default: 360).")
    parser.add_argument("--fps", type=int, default=30, help="Synthetic clip fps (default: 30).")
    parser.add_argument("--frames", type=int, default=60, help="Synthetic clip frame count (default: 60).")
    parser.add_argument("--codec", type=str, default="hevc", help="Transcode codec (default: hevc).")
    parser.add_argument(
        "--bitrate",
        type=int,
        default=2_500_000,
        help="Target bitrate in bps for deterministic transcode (default: 2500000).",
    )
    parser.add_argument(
        "--pause-sec",
        type=float,
        default=0.0,
        help="Optional pause between iterations in seconds (default: 0.0).",
    )
    parser.add_argument(
        "--keep-artifacts",
        action="store_true",
        help="Keep temporary synthetic input and transcoded output directory after completion.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    args = parse_args(sys.argv[1:] if argv is None else argv)
    duration_sec = 20.0 if args.quick else max(1.0, float(args.duration_sec))
    safarium_bin = args.safarium_bin.expanduser()

    if not safarium_bin.exists():
        print(f"error: safarium binary not found at {safarium_bin}", file=sys.stderr)
        return 2

    work_dir = Path(tempfile.mkdtemp(prefix="safarium-thermal-soak-"))
    output_json = (
        args.output_json.expanduser()
        if args.output_json is not None
        else Path(tempfile.gettempdir()) / f"safarium-thermal-soak-{int(time.time())}.json"
    )

    started_at = utc_now_iso()
    soak_t0 = time.monotonic()
    baseline_therm = read_pmset_therm()
    iterations: list[dict[str, Any]] = []

    try:
        if args.input is not None:
            input_clip = args.input.expanduser()
            if not input_clip.exists():
                print(f"error: input clip not found: {input_clip}", file=sys.stderr)
                return 2
        else:
            input_clip = work_dir / "deterministic_input.mp4"
            generate_deterministic_clip(
                safarium_bin=safarium_bin,
                output_mp4=input_clip,
                width=args.width,
                height=args.height,
                fps=args.fps,
                frames=args.frames,
            )

        input_sha = sha256_file(input_clip)
        iter_out = work_dir / "soak_iter_output.mp4"
        iteration_num = 0

        while not _STOP_REQUESTED:
            elapsed = time.monotonic() - soak_t0
            if iteration_num > 0 and elapsed >= duration_sec:
                break

            iteration_num += 1
            rec = run_transcode_iteration(
                safarium_bin=safarium_bin,
                input_clip=input_clip,
                output_clip=iter_out,
                codec=args.codec,
                bitrate=args.bitrate,
                frames=args.frames,
            )
            rec["iteration"] = iteration_num
            iterations.append(rec)

            speed = rec["pmset_therm"].get("cpu_speed_limit")
            sha_short = (rec["output_sha256"] or "none")[:12]
            mdat_short = (rec["mdat_sha256"] or "none")[:12]
            print(
                f"[iter {iteration_num:04d}] ok={rec['ok']} wall={rec['wall_s']:.3f}s "
                f"fps={rec['fps']:.1f} rss={rec['peak_rss_mb']:.1f}MB "
                f"cpu_speed={speed} sha={sha_short} mdat={mdat_short}",
                flush=True,
            )

            if args.pause_sec > 0.0 and not _STOP_REQUESTED:
                time.sleep(args.pause_sec)

        elapsed_total = time.monotonic() - soak_t0
        report = {
            "schema_version": 1,
            "mode": "quick" if args.quick else "sustained",
            "started_at_utc": started_at,
            "finished_at_utc": utc_now_iso(),
            "elapsed_s": round(elapsed_total, 3),
            "host": {
                "platform": platform.platform(),
                "machine": platform.machine(),
                "python": platform.python_version(),
                "baseline_pmset_therm": baseline_therm,
            },
            "config": {
                "duration_sec": duration_sec,
                "safarium_bin": str(safarium_bin),
                "input_clip": str(input_clip),
                "input_sha256": input_sha,
                "width": args.width,
                "height": args.height,
                "fps": args.fps,
                "frames": args.frames,
                "codec": args.codec,
                "bitrate": args.bitrate,
            },
            "summary": summarize_iterations(iterations),
            "iterations": iterations,
        }

        output_json.parent.mkdir(parents=True, exist_ok=True)
        output_json.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(f"\nSoak summary written to: {output_json}")
        print(json.dumps(report["summary"], indent=2))

        summary = report["summary"]
        if summary["iterations_succeeded"] == 0 or summary["iterations_failed"] > 0:
            return 1
        return 0
    finally:
        if not args.keep_artifacts:
            shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
