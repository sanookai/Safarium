#!/usr/bin/env python3
"""
Safarium Wave 11E — Reproducible Offline Benchmark Oracle Harness (`spec_bench.py`)

Offline research & benchmarking oracle ONLY (never imported or linked by Safarium production
Swift/Metal binaries). Implements strict reproducibility standards:
  - Pins git commit/dirty state, Safarium binary SHA-256, input SHA-256, macOS version/build,
    Apple Silicon chip brand, AC power status (`pmset -g batt`), and thermal state.
  - Runs >= N (default 5) randomized trials after warm-up, reporting raw observations plus
    median, p5, p95, min, max, and failure_rate (never single-run averages).
  - Compares Safarium native scenarios/modes vs offline FFmpeg baselines (`hevc_videotoolbox`,
    `libx265`, `libx264`) on matched bitrate or matched quality.
  - Measures VMAF, VMAF-NEG (when model present), PSNR, SSIM, XPSNR via offline FFmpeg/libvmaf
    plus Safarium native `pq` (MS-SSIM, CIEDE2000 mean/p95, PQ score), bitrate_kbps,
    size_error_pct, fps, realtime_x, peak_rss_mb, and wall_s.
  - Computes 3D (quality ↑, bitrate ↓, wall_s ↓) and 2D RD (quality ↑, bitrate ↓) Pareto frontiers
    and emits stable JSON (`schema_version: 2`).
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

SCHEMA_VERSION = 2

DEFAULT_FFMPEG = "/opt/homebrew/bin/ffmpeg"
DEFAULT_FFPROBE = "/opt/homebrew/bin/ffprobe"
DEFAULT_VMAF = "/opt/homebrew/bin/vmaf"

VMAF_MODEL_SEARCH_DIRS = [
    "/opt/homebrew/share/libvmaf/model",
    "/usr/local/share/libvmaf/model",
]

ALL_CANDIDATES = [
    "safarium_hevc_vt",
    "safarium_hevc10_vt",
    "safarium_h264_vt",
    "safarium_scenario",
    "ffmpeg_hevc_vt",
    "ffmpeg_libx265",
    "ffmpeg_libx264",
]

DEFAULT_CANDIDATES = [
    "safarium_hevc_vt",
    "safarium_hevc10_vt",
    "ffmpeg_hevc_vt",
    "ffmpeg_libx265",
    "ffmpeg_libx264",
]

SMOKE_CANDIDATES = [
    "safarium_hevc_vt",
    "ffmpeg_hevc_vt",
    "ffmpeg_libx264",
]


# ---------------------------------------------------------------------------
# Provenance & System Helpers
# ---------------------------------------------------------------------------


def sha256_file(path: Optional[str]) -> Optional[str]:
    if not path or not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def run_capture(cmd: Sequence[str], cwd: Optional[str] = None, timeout: int = 30) -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(
            list(cmd),
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as exc:
        return -1, "", str(exc)


def resolve_tool(preferred: str, fallback_name: str) -> Optional[str]:
    if os.path.isfile(preferred) and os.access(preferred, os.X_OK):
        return preferred
    found = shutil.which(fallback_name)
    return found


def resolve_safarium_bin(explicit: Optional[str]) -> Optional[str]:
    if explicit:
        p = os.path.expanduser(explicit)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return os.path.realpath(p)
        found = shutil.which(explicit)
        if found:
            return os.path.realpath(found)
        return None

    for candidate in ("safarium", "safarium-forge"):
        found = shutil.which(candidate)
        if found:
            return found

    home_bin = os.path.expanduser("~/.local/bin/safarium")
    if os.path.isfile(home_bin) and os.access(home_bin, os.X_OK):
        return home_bin
    return None


def find_vmaf_models(width: int) -> Dict[str, Optional[str]]:
    search_dirs = list(VMAF_MODEL_SEARCH_DIRS)
    cellar = Path("/opt/homebrew/Cellar/libvmaf")
    if cellar.is_dir():
        for p in sorted(cellar.glob("*/share/libvmaf/model"), reverse=True):
            search_dirs.append(str(p))

    is_4k = width >= 3000
    std_names = ["vmaf_4k_v0.6.1.json", "vmaf_v0.6.1.json"] if is_4k else ["vmaf_v0.6.1.json"]
    neg_names = ["vmaf_4k_v0.6.1neg.json", "vmaf_v0.6.1neg.json"] if is_4k else ["vmaf_v0.6.1neg.json"]

    def locate(names: Sequence[str]) -> Optional[str]:
        for d in search_dirs:
            for name in names:
                p = os.path.join(d, name)
                if os.path.isfile(p):
                    return p
        return None

    return {
        "vmaf": locate(std_names),
        "vmaf_neg": locate(neg_names),
    }


def collect_git_info(repo_dir: str) -> Dict[str, Any]:
    rc_head, head, _ = run_capture(["git", "rev-parse", "HEAD"], cwd=repo_dir)
    rc_short, short_head, _ = run_capture(["git", "rev-parse", "--short", "HEAD"], cwd=repo_dir)
    rc_stat, stat_out, _ = run_capture(["git", "status", "--porcelain"], cwd=repo_dir)
    return {
        "commit": head if rc_head == 0 else None,
        "short_commit": short_head if rc_short == 0 else None,
        "dirty": bool(stat_out) if rc_stat == 0 else None,
    }


def collect_power_state() -> Dict[str, Any]:
    rc, out, err = run_capture(["pmset", "-g", "batt"])
    if rc != 0:
        return {"on_ac_power": None, "battery_pct": None, "source": None, "raw": err}
    on_ac = "AC Power" in out
    pct_match = re.search(r"(\d+)%", out)
    src_match = re.search(r"Now drawing from '([^']+)'", out)
    return {
        "on_ac_power": on_ac,
        "battery_pct": int(pct_match.group(1)) if pct_match else None,
        "source": src_match.group(1) if src_match else None,
        "raw": out,
    }


def collect_thermal_state() -> Dict[str, Any]:
    rc, out, err = run_capture(["pmset", "-g", "therm"])
    if rc != 0:
        return {"cpu_speed_limit": None, "scheduler_limit": None, "raw": err}
    cpu_lim = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", out)
    sched_lim = re.search(r"CPU_Scheduler_Limit\s*=\s*(\d+)", out)
    no_warnings = "No thermal warning level has been recorded" in out
    return {
        "cpu_speed_limit": int(cpu_lim.group(1)) if cpu_lim else 100,
        "scheduler_limit": int(sched_lim.group(1)) if sched_lim else 100,
        "nominal": no_warnings or (cpu_lim is not None and int(cpu_lim.group(1)) == 100),
        "raw": out,
    }


def collect_system_info() -> Dict[str, Any]:
    _, mac_ver, _ = run_capture(["sw_vers", "-productVersion"])
    _, mac_build, _ = run_capture(["sw_vers", "-buildVersion"])
    _, chip, _ = run_capture(["sysctl", "-n", "machdep.cpu.brand_string"])
    _, mem_raw, _ = run_capture(["sysctl", "-n", "hw.memsize"])
    ram_gb = round(int(mem_raw) / (1024.0 ** 3), 2) if mem_raw.isdigit() else None
    return {
        "macos_version": mac_ver or platform.mac_ver()[0],
        "macos_build": mac_build or None,
        "arch": platform.machine(),
        "chip_brand": chip or platform.processor(),
        "cpu_cores": os.cpu_count(),
        "ram_gb": ram_gb,
        "ac_power": collect_power_state(),
        "thermal_state": collect_thermal_state(),
    }


def probe_video(ffprobe_bin: str, video_path: str) -> Dict[str, Any]:
    cmd = [
        ffprobe_bin,
        "-v", "error",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,codec_name,pix_fmt,duration",
        "-show_entries", "format=duration,size,bit_rate",
        "-of", "json",
        video_path,
    ]
    rc, out, err = run_capture(cmd, timeout=30)
    if rc != 0:
        raise RuntimeError(f"ffprobe failed on {video_path}: {err}")
    data = json.loads(out)
    streams = data.get("streams") or []
    fmt = data.get("format") or {}
    if not streams:
        raise RuntimeError(f"ffprobe found no video stream in {video_path}")
    s = streams[0]

    def parse_frac(val: Optional[str]) -> float:
        if not val or val == "0/0":
            return 0.0
        if "/" in val:
            a, b = val.split("/", 1)
            denom = float(b)
            return float(a) / denom if denom > 0 else 0.0
        return float(val)

    fps = parse_frac(s.get("avg_frame_rate")) or parse_frac(s.get("r_frame_rate")) or 30.0
    duration_s = float(fmt.get("duration") or s.get("duration") or 0.0)
    nb_frames_raw = s.get("nb_frames")
    if nb_frames_raw and str(nb_frames_raw).isdigit():
        frame_count = int(nb_frames_raw)
    else:
        frame_count = max(1, int(round(duration_s * fps)))

    return {
        "width": int(s["width"]),
        "height": int(s["height"]),
        "fps": round(fps, 6),
        "duration_s": round(duration_s, 6),
        "frame_count": frame_count,
        "codec_name": s.get("codec_name"),
        "pix_fmt": s.get("pix_fmt"),
        "size_bytes": os.path.getsize(video_path),
    }


# ---------------------------------------------------------------------------
# Synthetic Smoke Clip Generator
# ---------------------------------------------------------------------------


def generate_smoke_clip(ffmpeg_bin: str, out_path: str) -> str:
    """Generates a 2-second 640x360 @ 30fps reference test clip with motion, gradients, and sharp graphics."""
    cmd = [
        ffmpeg_bin,
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-f", "lavfi",
        "-i", "testsrc2=size=640x360:rate=30:duration=2",
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-crf", "10",
        "-pix_fmt", "yuv420p",
        "-color_primaries", "bt709",
        "-color_trc", "bt709",
        "-colorspace", "bt709",
        "-movflags", "+faststart",
        out_path,
    ]
    rc, _, err = run_capture(cmd, timeout=60)
    if rc != 0:
        raise RuntimeError(f"Failed to generate smoke reference clip: {err}")
    return out_path


# ---------------------------------------------------------------------------
# Candidate Command Builders & Timed Execution
# ---------------------------------------------------------------------------


def build_safarium_forge_prefix(safarium_bin: str) -> List[str]:
    base = os.path.basename(safarium_bin)
    if base == "safarium-forge":
        return [safarium_bin]
    return [safarium_bin, "forge"]


def build_candidate_command(
    candidate: str,
    input_path: str,
    output_path: str,
    target_bitrate_kbps: Optional[int],
    quality: Optional[float],
    safarium_bin: Optional[str],
    ffmpeg_bin: str,
    safarium_scenario: str,
    safarium_mode: str,
) -> List[str]:
    bps = (target_bitrate_kbps or 3000) * 1000
    kbps_str = f"{target_bitrate_kbps or 3000}k"

    if candidate.startswith("safarium_"):
        if not safarium_bin:
            raise RuntimeError(f"Candidate '{candidate}' requested but safarium binary was not found")
        prefix = build_safarium_forge_prefix(safarium_bin)
        cmd = prefix + ["transcode", input_path, "-o", output_path, "--overwrite"]
        if candidate == "safarium_hevc_vt":
            cmd += ["--codec", "hevc"]
            if quality is not None:
                cmd += ["--quality", f"{quality:.3f}"]
            else:
                cmd += ["--bitrate", str(bps)]
        elif candidate == "safarium_hevc10_vt":
            cmd += ["--codec", "hevc-10bit", "--mode", "high-quality"]
            if quality is not None:
                cmd += ["--quality", f"{quality:.3f}"]
            else:
                cmd += ["--bitrate", str(bps)]
        elif candidate == "safarium_h264_vt":
            cmd += ["--codec", "h264"]
            if quality is not None:
                cmd += ["--quality", f"{quality:.3f}"]
            else:
                cmd += ["--bitrate", str(bps)]
        elif candidate == "safarium_scenario":
            cmd += ["--scenario", safarium_scenario]
            if safarium_mode:
                cmd += ["--mode", safarium_mode]
            if quality is not None:
                cmd += ["--quality", f"{quality:.3f}"]
            elif target_bitrate_kbps is not None:
                cmd += ["--bitrate", str(bps)]
        else:
            raise ValueError(f"Unknown Safarium candidate: {candidate}")
        return cmd

    if candidate == "ffmpeg_hevc_vt":
        cmd = [
            ffmpeg_bin, "-y", "-hide_banner", "-loglevel", "error",
            "-i", input_path,
            "-c:v", "hevc_videotoolbox",
            "-tag:v", "hvc1",
            "-an",
        ]
        if quality is not None:
            q_vt = max(1, min(100, int(round(quality * 100))))
            cmd += ["-q:v", str(q_vt)]
        else:
            cmd += ["-b:v", kbps_str]
        cmd += ["-movflags", "+faststart", output_path]
        return cmd

    if candidate == "ffmpeg_libx265":
        cmd = [
            ffmpeg_bin, "-y", "-hide_banner", "-loglevel", "error",
            "-i", input_path,
            "-c:v", "libx265",
            "-preset", "medium",
            "-x265-params", "log-level=error",
            "-tag:v", "hvc1",
            "-an",
        ]
        if quality is not None:
            crf = max(0, min(51, int(round((1.0 - quality) * 40.0 + 10.0))))
            cmd += ["-crf", str(crf)]
        else:
            cmd += ["-b:v", kbps_str]
        cmd += ["-movflags", "+faststart", output_path]
        return cmd

    if candidate == "ffmpeg_libx264":
        cmd = [
            ffmpeg_bin, "-y", "-hide_banner", "-loglevel", "error",
            "-i", input_path,
            "-c:v", "libx264",
            "-preset", "medium",
            "-an",
        ]
        if quality is not None:
            crf = max(0, min(51, int(round((1.0 - quality) * 40.0 + 10.0))))
            cmd += ["-crf", str(crf)]
        else:
            cmd += ["-b:v", kbps_str]
        cmd += ["-movflags", "+faststart", output_path]
        return cmd

    raise ValueError(f"Unknown candidate: {candidate}")


def run_timed_encode(cmd: Sequence[str], timeout: int = 300) -> Dict[str, Any]:
    """Executes an encode command wrapped with macOS `/usr/bin/time -l` to capture wall_s and peak_rss_mb."""
    use_time = os.path.isfile("/usr/bin/time")
    wrapped = (["/usr/bin/time", "-l"] + list(cmd)) if use_time else list(cmd)
    t0 = time.perf_counter()
    try:
        proc = subprocess.run(
            wrapped,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
        )
        wall_s = time.perf_counter() - t0
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "wall_s": time.perf_counter() - t0,
            "peak_rss_mb": None,
            "error": f"timeout after {timeout}s",
        }
    except Exception as exc:
        return {
            "ok": False,
            "wall_s": time.perf_counter() - t0,
            "peak_rss_mb": None,
            "error": str(exc),
        }

    peak_rss_mb: Optional[float] = None
    if use_time:
        # macOS `/usr/bin/time -l` reports `maximum resident set size` in bytes.
        m = re.search(r"(\d+)\s+maximum resident set size", proc.stderr)
        if m:
            peak_rss_mb = round(int(m.group(1)) / (1024.0 * 1024.0), 3)

    if proc.returncode != 0:
        err_tail = (proc.stderr or proc.stdout or "").strip().splitlines()[-5:]
        return {
            "ok": False,
            "wall_s": round(wall_s, 6),
            "peak_rss_mb": peak_rss_mb,
            "error": f"exit {proc.returncode}: {' | '.join(err_tail)}",
        }

    return {
        "ok": True,
        "wall_s": round(wall_s, 6),
        "peak_rss_mb": peak_rss_mb,
        "error": None,
    }


# ---------------------------------------------------------------------------
# Quality Oracle (Offline FFmpeg libvmaf/psnr/ssim/xpsnr + Safarium pq)
# ---------------------------------------------------------------------------


def escape_lavfi_path(path: str) -> str:
    return path.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")


def measure_ffmpeg_quality(
    ffmpeg_bin: str,
    ref_path: str,
    cand_path: str,
    vmaf_models: Dict[str, Optional[str]],
    tmp_dir: str,
) -> Dict[str, Optional[float]]:
    metrics: Dict[str, Optional[float]] = {
        "vmaf": None,
        "vmaf_neg": None,
        "psnr": None,
        "ssim": None,
        "xpsnr": None,
    }

    # 1. VMAF (+ VMAF-NEG if available) via libvmaf JSON log.
    vmaf_model = vmaf_models.get("vmaf")
    vmaf_neg_model = vmaf_models.get("vmaf_neg")
    if vmaf_model:
        log_path = os.path.join(tmp_dir, f"vmaf_{time.time_ns()}.json")
        model_specs = [f"path={escape_lavfi_path(vmaf_model)}\\:name=vmaf"]
        if vmaf_neg_model:
            model_specs.append(f"path={escape_lavfi_path(vmaf_neg_model)}\\:name=vmaf_neg")
        models_arg = "|".join(model_specs)
        vmaf_filter = (
            f"[0:v]setpts=PTS-STARTPTS[dist];"
            f"[1:v]setpts=PTS-STARTPTS[ref];"
            f"[dist][ref]libvmaf=log_fmt=json:log_path={escape_lavfi_path(log_path)}"
            f":n_threads=4:model='{models_arg}'"
        )
        cmd = [
            ffmpeg_bin, "-hide_banner", "-loglevel", "error",
            "-i", cand_path, "-i", ref_path,
            "-lavfi", vmaf_filter,
            "-f", "null", "-",
        ]
        rc, _, _ = run_capture(cmd, timeout=180)
        if rc == 0 and os.path.isfile(log_path):
            try:
                with open(log_path, "r", encoding="utf-8") as f:
                    vdata = json.load(f)
                pooled = vdata.get("pooled_metrics") or {}
                if "vmaf" in pooled and "mean" in pooled["vmaf"]:
                    metrics["vmaf"] = round(float(pooled["vmaf"]["mean"]), 4)
                if "vmaf_neg" in pooled and "mean" in pooled["vmaf_neg"]:
                    metrics["vmaf_neg"] = round(float(pooled["vmaf_neg"]["mean"]), 4)
            except Exception:
                pass
            finally:
                try:
                    os.remove(log_path)
                except OSError:
                    pass

    # 2. PSNR, SSIM, and XPSNR in a single fused split filtergraph pass.
    fused_filter = (
        "[0:v]setpts=PTS-STARTPTS,split=3[d1][d2][d3];"
        "[1:v]setpts=PTS-STARTPTS,split=3[r1][r2][r3];"
        "[d1][r1]psnr[out_p];"
        "[d2][r2]ssim[out_s];"
        "[d3][r3]xpsnr[out_x]"
    )
    cmd_psx = [
        ffmpeg_bin, "-hide_banner", "-loglevel", "info",
        "-i", cand_path, "-i", ref_path,
        "-lavfi", fused_filter,
        "-map", "[out_p]", "-map", "[out_s]", "-map", "[out_x]",
        "-f", "null", "-",
    ]
    rc, _, err = run_capture(cmd_psx, timeout=180)
    if rc == 0:
        m_psnr = re.search(r"PSNR\s+.*?average:([0-9.]+|inf)", err)
        if m_psnr:
            val = m_psnr.group(1)
            metrics["psnr"] = 100.0 if val == "inf" else round(float(val), 4)

        m_ssim = re.search(r"SSIM\s+.*?All:([0-9.]+)", err)
        if m_ssim:
            metrics["ssim"] = round(float(m_ssim.group(1)), 6)

        # FFmpeg xpsnr logs: "XPSNR  y: 41.23  u: 45.67  v: 46.12  (minimum: 41.23)"
        # Compute standard 6:1:1 weighted YUV XPSNR if all three planes are reported.
        m_xpsnr = re.search(
            r"XPSNR\s+y:\s*([0-9.]+|inf)\s+u:\s*([0-9.]+|inf)\s+v:\s*([0-9.]+|inf)",
            err,
        )
        if m_xpsnr:
            vals = [100.0 if g == "inf" else float(g) for g in m_xpsnr.groups()]
            metrics["xpsnr"] = round((6.0 * vals[0] + vals[1] + vals[2]) / 8.0, 4)

    return metrics


def measure_safarium_pq(
    safarium_bin: Optional[str],
    ref_path: str,
    cand_path: str,
    samples: int = 8,
) -> Dict[str, Optional[float]]:
    out_metrics: Dict[str, Optional[float]] = {
        "ms_ssim": None,
        "delta_e00_mean": None,
        "delta_e00_p95": None,
        "pq_score": None,
    }
    if not safarium_bin:
        return out_metrics

    cmd = build_safarium_forge_prefix(safarium_bin) + [
        "pq", ref_path, cand_path, "--samples", str(samples)
    ]
    rc, out, _ = run_capture(cmd, timeout=120)
    if rc != 0 or not out:
        return out_metrics
    try:
        # Extract JSON object even if wrapper emitted leading diagnostic text.
        start = out.find("{")
        end = out.rfind("}")
        if start >= 0 and end > start:
            data = json.loads(out[start : end + 1])
            if "msSSIM" in data:
                out_metrics["ms_ssim"] = round(float(data["msSSIM"]), 6)
            if "deltaE00Mean" in data:
                out_metrics["delta_e00_mean"] = round(float(data["deltaE00Mean"]), 4)
            if "deltaE00P95" in data:
                out_metrics["delta_e00_p95"] = round(float(data["deltaE00P95"]), 4)
            if "score0To100" in data:
                out_metrics["pq_score"] = round(float(data["score0To100"]), 3)
    except Exception:
        pass
    return out_metrics


# ---------------------------------------------------------------------------
# Robust Statistics & Pareto Frontier
# ---------------------------------------------------------------------------


def linear_percentile(sorted_vals: Sequence[float], pct: float) -> float:
    n = len(sorted_vals)
    if n == 0:
        return math.nan
    if n == 1:
        return float(sorted_vals[0])
    pos = (pct / 100.0) * (n - 1)
    lo = int(math.floor(pos))
    hi = min(n - 1, lo + 1)
    frac = pos - lo
    return float(sorted_vals[lo] * (1.0 - frac) + sorted_vals[hi] * frac)


def summarize_metric(values: Sequence[Optional[float]]) -> Optional[Dict[str, Any]]:
    clean = sorted(float(v) for v in values if v is not None and not math.isnan(float(v)))
    if not clean:
        return None
    return {
        "n": len(clean),
        "median": round(linear_percentile(clean, 50.0), 6),
        "p5": round(linear_percentile(clean, 5.0), 6),
        "p95": round(linear_percentile(clean, 95.0), 6),
        "min": round(clean[0], 6),
        "max": round(clean[-1], 6),
    }


def compute_pareto_frontier(
    candidate_summaries: Dict[str, Dict[str, Any]],
    quality_metric: str = "vmaf",
) -> Dict[str, Any]:
    """Computes non-dominated Pareto frontiers on (quality ↑, bitrate_kbps ↓, wall_s ↓) and 2D RD."""
    points: List[Dict[str, Any]] = []
    chosen_metric = quality_metric

    # Pick fallback quality metric if preferred metric is unavailable across all candidates.
    fallback_order = [quality_metric, "vmaf", "vmaf_neg", "ms_ssim", "xpsnr", "psnr", "ssim"]
    for m in fallback_order:
        if any(
            (s.get("metrics", {}).get(m) or {}).get("median") is not None
            for s in candidate_summaries.values()
        ):
            chosen_metric = m
            break

    for name, summ in candidate_summaries.items():
        m = summ.get("metrics") or {}
        q_stat = m.get(chosen_metric)
        b_stat = m.get("bitrate_kbps")
        w_stat = m.get("wall_s")
        if not q_stat or not b_stat or not w_stat:
            continue
        points.append({
            "candidate": name,
            "quality_metric": chosen_metric,
            "quality_median": q_stat["median"],
            "bitrate_kbps_median": b_stat["median"],
            "wall_s_median": w_stat["median"],
        })

    def dominated_3d(a: Dict[str, Any], b: Dict[str, Any]) -> bool:
        return (
            b["quality_median"] >= a["quality_median"]
            and b["bitrate_kbps_median"] <= a["bitrate_kbps_median"]
            and b["wall_s_median"] <= a["wall_s_median"]
            and (
                b["quality_median"] > a["quality_median"]
                or b["bitrate_kbps_median"] < a["bitrate_kbps_median"]
                or b["wall_s_median"] < a["wall_s_median"]
            )
        )

    def dominated_rd(a: Dict[str, Any], b: Dict[str, Any]) -> bool:
        return (
            b["quality_median"] >= a["quality_median"]
            and b["bitrate_kbps_median"] <= a["bitrate_kbps_median"]
            and (
                b["quality_median"] > a["quality_median"]
                or b["bitrate_kbps_median"] < a["bitrate_kbps_median"]
            )
        )

    frontier_3d = [
        p for p in points
        if not any(dominated_3d(p, q) for q in points if q["candidate"] != p["candidate"])
    ]
    frontier_rd = [
        p for p in points
        if not any(dominated_rd(p, q) for q in points if q["candidate"] != p["candidate"])
    ]
    frontier_3d.sort(key=lambda x: (-x["quality_median"], x["bitrate_kbps_median"], x["wall_s_median"]))
    frontier_rd.sort(key=lambda x: (-x["quality_median"], x["bitrate_kbps_median"]))

    return {
        "quality_metric": chosen_metric,
        "objectives_3d": ["quality_median:max", "bitrate_kbps_median:min", "wall_s_median:min"],
        "pareto_frontier_3d": frontier_3d,
        "objectives_rd": ["quality_median:max", "bitrate_kbps_median:min"],
        "pareto_frontier_rd": frontier_rd,
    }


# ---------------------------------------------------------------------------
# Main Benchmark Runner
# ---------------------------------------------------------------------------


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="spec_bench.py",
        description=(
            "Safarium Wave 11E Reproducible Offline Benchmark Oracle Harness.\n"
            "Compares Safarium native encoding modes against offline FFmpeg baselines "
            "(hevc_videotoolbox, libx265, libx264) using randomized multi-trial execution, "
            "median/p5/p95/min/max statistics, libvmaf/PSNR/SSIM/XPSNR + Safarium PQ, "
            "and Pareto frontier analysis (schema_version: 2)."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--input", "-i", help="Path to reference input video (optional in --smoke mode)")
    p.add_argument("--output", "-o", help="Path to write JSON report (default: stdout)")
    p.add_argument(
        "--candidates",
        default=None,
        help=(
            "Comma-separated candidates to benchmark. Available: "
            + ", ".join(ALL_CANDIDATES)
        ),
    )
    p.add_argument("--runs", type=int, default=5, help="Measured randomized trials per candidate (default: 5)")
    p.add_argument("--warmup", type=int, default=1, help="Unmeasured warm-up runs per candidate (default: 1)")
    p.add_argument("--seed", type=int, default=20261125, help="PRNG seed for randomized trial order")
    p.add_argument(
        "--target-bitrate-kbps",
        type=int,
        default=None,
        help="Matched target video bitrate in kbps (default: 3000; 1800 in --smoke)",
    )
    p.add_argument(
        "--quality",
        type=float,
        default=None,
        help="Matched quality factor in [0.0..1.0] (mutually exclusive with --target-bitrate-kbps)",
    )
    p.add_argument("--safarium-bin", default=None, help="Path to `safarium` or `safarium-forge` binary")
    p.add_argument("--safarium-scenario", default="youtube", help="Wave 10 scenario for `safarium_scenario` candidate")
    p.add_argument("--safarium-mode", default="balanced", help="Encoding mode for `safarium_scenario` candidate")
    p.add_argument("--ffmpeg-bin", default=DEFAULT_FFMPEG, help="Path to offline FFmpeg binary")
    p.add_argument("--ffprobe-bin", default=DEFAULT_FFPROBE, help="Path to offline ffprobe binary")
    p.add_argument("--vmaf-bin", default=DEFAULT_VMAF, help="Path to offline vmaf binary")
    p.add_argument("--pq-samples", type=int, default=8, help="Frame samples for Safarium `pq` evaluator")
    p.add_argument("--skip-pq", action="store_true", help="Skip Safarium `pq` evaluation")
    p.add_argument(
        "--pareto-metric",
        default="vmaf",
        choices=["vmaf", "vmaf_neg", "ms_ssim", "xpsnr", "psnr", "ssim"],
        help="Quality metric maximized on the Pareto frontier (default: vmaf)",
    )
    p.add_argument(
        "--smoke",
        action="store_true",
        help="Self-test mode: synthesizes a 2s 640x360 clip and runs 2 randomized trials (~15s)",
    )
    return p.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)

    if args.quality is not None and args.target_bitrate_kbps is not None:
        print("Error: specify either --target-bitrate-kbps or --quality, not both.", file=sys.stderr)
        return 2

    ffmpeg_bin = resolve_tool(args.ffmpeg_bin, "ffmpeg")
    ffprobe_bin = resolve_tool(args.ffprobe_bin, "ffprobe")
    vmaf_bin = resolve_tool(args.vmaf_bin, "vmaf")
    safarium_bin = resolve_safarium_bin(args.safarium_bin)

    if not ffmpeg_bin or not ffprobe_bin:
        print("Error: offline ffmpeg/ffprobe not found (expected at /opt/homebrew/bin/ffmpeg).", file=sys.stderr)
        return 2

    if args.smoke:
        runs = min(args.runs, 2) if args.runs == 5 else max(1, args.runs)
        warmup = min(args.warmup, 1)
        target_kbps = args.target_bitrate_kbps if args.target_bitrate_kbps is not None else (
            None if args.quality is not None else 1800
        )
        candidates = (
            [c.strip() for c in args.candidates.split(",") if c.strip()]
            if args.candidates
            else list(SMOKE_CANDIDATES)
        )
    else:
        if not args.input:
            print("Error: --input <video> is required unless --smoke is set.", file=sys.stderr)
            return 2
        runs = max(1, args.runs)
        warmup = max(0, args.warmup)
        target_kbps = args.target_bitrate_kbps if args.target_bitrate_kbps is not None else (
            None if args.quality is not None else 3000
        )
        candidates = (
            [c.strip() for c in args.candidates.split(",") if c.strip()]
            if args.candidates
            else list(DEFAULT_CANDIDATES)
        )

    for c in candidates:
        if c not in ALL_CANDIDATES:
            print(f"Error: unknown candidate '{c}'. Valid: {', '.join(ALL_CANDIDATES)}", file=sys.stderr)
            return 2
        if c.startswith("safarium_") and not safarium_bin:
            print(
                f"Error: candidate '{c}' requires `safarium` or `safarium-forge` binary (--safarium-bin).",
                file=sys.stderr,
            )
            return 2

    repo_dir = str(Path(__file__).resolve().parents[2])
    with tempfile.TemporaryDirectory(prefix="safarium-spec-bench-") as tmp_dir:
        if args.smoke and not args.input:
            input_path = generate_smoke_clip(ffmpeg_bin, os.path.join(tmp_dir, "smoke_ref_360p_2s.mp4"))
        else:
            input_path = os.path.abspath(args.input)
            if not os.path.isfile(input_path):
                print(f"Error: input file not found: {input_path}", file=sys.stderr)
                return 2

        input_probe = probe_video(ffprobe_bin, input_path)
        vmaf_models = find_vmaf_models(input_probe["width"])

        _, ffmpeg_ver_raw, _ = run_capture([ffmpeg_bin, "-version"])
        ffmpeg_ver = ffmpeg_ver_raw.splitlines()[0] if ffmpeg_ver_raw else None
        _, vmaf_ver_raw, _ = run_capture([vmaf_bin, "--version"]) if vmaf_bin else (-1, "", "")

        provenance = {
            "timestamp_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
            "git": collect_git_info(repo_dir),
            "safarium_binary": {
                "path": safarium_bin,
                "realpath": os.path.realpath(safarium_bin) if safarium_bin else None,
                "sha256": sha256_file(os.path.realpath(safarium_bin)) if safarium_bin else None,
            },
            "input": {
                "path": input_path,
                "sha256": sha256_file(input_path),
                "synthetic_smoke": bool(args.smoke and not args.input),
                **input_probe,
            },
            "system": collect_system_info(),
            "oracle_tools": {
                "ffmpeg_path": ffmpeg_bin,
                "ffmpeg_version": ffmpeg_ver,
                "ffprobe_path": ffprobe_bin,
                "vmaf_path": vmaf_bin,
                "vmaf_version": vmaf_ver_raw or None,
                "vmaf_models": vmaf_models,
            },
            "experiment": {
                "mode": "matched_quality" if args.quality is not None else "matched_bitrate",
                "target_bitrate_kbps": target_kbps,
                "quality": args.quality,
                "runs": runs,
                "warmup": warmup,
                "seed": args.seed,
                "candidates": candidates,
                "safarium_scenario": args.safarium_scenario,
                "safarium_mode": args.safarium_mode,
                "smoke": bool(args.smoke),
            },
        }

        # 1. Warm-up phase (unmeasured, primes caches/Media Engines).
        if warmup > 0:
            print(f"[spec_bench] Warming up {len(candidates)} candidate(s) x {warmup} run(s)...", file=sys.stderr)
            for cand in candidates:
                for w_idx in range(warmup):
                    w_out = os.path.join(tmp_dir, f"warmup_{cand}_{w_idx}.mp4")
                    cmd = build_candidate_command(
                        candidate=cand,
                        input_path=input_path,
                        output_path=w_out,
                        target_bitrate_kbps=target_kbps,
                        quality=args.quality,
                        safarium_bin=safarium_bin,
                        ffmpeg_bin=ffmpeg_bin,
                        safarium_scenario=args.safarium_scenario,
                        safarium_mode=args.safarium_mode,
                    )
                    run_timed_encode(cmd)
                    if os.path.exists(w_out):
                        try:
                            os.remove(w_out)
                        except OSError:
                            pass

        # 2. Build randomized trial schedule across all candidates.
        schedule: List[Tuple[str, int]] = []
        for trial_idx in range(runs):
            for cand in candidates:
                schedule.append((cand, trial_idx))
        rng = random.Random(args.seed)
        rng.shuffle(schedule)

        print(
            f"[spec_bench] Executing {len(schedule)} randomized trial(s) "
            f"({runs} runs x {len(candidates)} candidates, seed={args.seed})...",
            file=sys.stderr,
        )

        raw_by_candidate: Dict[str, List[Dict[str, Any]]] = {c: [] for c in candidates}
        quality_cache: Dict[str, Dict[str, Optional[float]]] = {}

        duration_s = max(1e-6, float(input_probe["duration_s"]))
        frame_count = max(1, int(input_probe["frame_count"]))

        for order_idx, (cand, trial_idx) in enumerate(schedule):
            out_file = os.path.join(tmp_dir, f"trial_{cand}_{trial_idx}_{order_idx}.mp4")
            cmd = build_candidate_command(
                candidate=cand,
                input_path=input_path,
                output_path=out_file,
                target_bitrate_kbps=target_kbps,
                quality=args.quality,
                safarium_bin=safarium_bin,
                ffmpeg_bin=ffmpeg_bin,
                safarium_scenario=args.safarium_scenario,
                safarium_mode=args.safarium_mode,
            )
            timing = run_timed_encode(cmd)

            obs: Dict[str, Any] = {
                "candidate": cand,
                "trial_index": trial_idx,
                "order_index": order_idx,
                "ok": False,
                "wall_s": timing["wall_s"],
                "peak_rss_mb": timing["peak_rss_mb"],
                "fps": None,
                "realtime_x": None,
                "output_bytes": None,
                "output_sha256": None,
                "bitrate_kbps": None,
                "size_error_pct": None,
                "vmaf": None,
                "vmaf_neg": None,
                "psnr": None,
                "ssim": None,
                "xpsnr": None,
                "ms_ssim": None,
                "delta_e00_mean": None,
                "delta_e00_p95": None,
                "pq_score": None,
                "quality_cached_by_sha256": False,
                "error": timing["error"],
            }

            if timing["ok"] and os.path.isfile(out_file) and os.path.getsize(out_file) > 0:
                out_bytes = os.path.getsize(out_file)
                out_sha = sha256_file(out_file)
                wall_s = max(1e-6, float(timing["wall_s"]))
                bitrate_kbps = (out_bytes * 8.0) / (duration_s * 1000.0)
                size_err_pct = (
                    round(((bitrate_kbps - target_kbps) / float(target_kbps)) * 100.0, 4)
                    if target_kbps
                    else None
                )

                obs.update({
                    "ok": True,
                    "fps": round(frame_count / wall_s, 3),
                    "realtime_x": round(duration_s / wall_s, 3),
                    "output_bytes": out_bytes,
                    "output_sha256": out_sha,
                    "bitrate_kbps": round(bitrate_kbps, 3),
                    "size_error_pct": size_err_pct,
                })

                if out_sha and out_sha in quality_cache:
                    q_metrics = quality_cache[out_sha]
                    obs["quality_cached_by_sha256"] = True
                else:
                    q_metrics = measure_ffmpeg_quality(
                        ffmpeg_bin=ffmpeg_bin,
                        ref_path=input_path,
                        cand_path=out_file,
                        vmaf_models=vmaf_models,
                        tmp_dir=tmp_dir,
                    )
                    if not args.skip_pq:
                        pq_metrics = measure_safarium_pq(
                            safarium_bin=safarium_bin,
                            ref_path=input_path,
                            cand_path=out_file,
                            samples=args.pq_samples,
                        )
                        q_metrics.update(pq_metrics)
                    if out_sha:
                        quality_cache[out_sha] = q_metrics

                obs.update(q_metrics)
            elif timing["ok"]:
                obs["error"] = "encoder exited 0 but produced empty or missing output"

            raw_by_candidate[cand].append(obs)
            if os.path.exists(out_file):
                try:
                    os.remove(out_file)
                except OSError:
                    pass

        # 3. Aggregate robust statistics per candidate (median, p5, p95, min, max, failure_rate).
        metric_keys = [
            "vmaf", "vmaf_neg", "ms_ssim", "delta_e00_mean", "delta_e00_p95", "pq_score",
            "psnr", "ssim", "xpsnr",
            "bitrate_kbps", "size_error_pct", "fps", "realtime_x", "peak_rss_mb", "wall_s",
        ]

        results: Dict[str, Dict[str, Any]] = {}
        for cand in candidates:
            obs_list = sorted(raw_by_candidate[cand], key=lambda o: o["trial_index"])
            ok_obs = [o for o in obs_list if o["ok"]]
            total = len(obs_list)
            failed = total - len(ok_obs)
            metrics_summary = {
                k: summarize_metric([o.get(k) for o in ok_obs])
                for k in metric_keys
            }
            results[cand] = {
                "total_runs": total,
                "ok_runs": len(ok_obs),
                "failure_rate": round(failed / float(total), 6) if total > 0 else 1.0,
                "metrics": metrics_summary,
                "raw_observations": obs_list,
            }

        pareto = compute_pareto_frontier(results, quality_metric=args.pareto_metric)

        report = {
            "schema_version": SCHEMA_VERSION,
            "provenance": provenance,
            "candidates": results,
            "pareto": pareto,
        }

        json_text = json.dumps(report, indent=2, sort_keys=False) + "\n"
        if args.output:
            out_p = Path(args.output)
            out_p.parent.mkdir(parents=True, exist_ok=True)
            out_p.write_text(json_text, encoding="utf-8")
            print(f"[spec_bench] Wrote schema_version={SCHEMA_VERSION} report to {args.output}", file=sys.stderr)
        else:
            sys.stdout.write(json_text)

        # Print concise human summary table to stderr.
        print("\n[spec_bench] Summary (median across randomized trials):", file=sys.stderr)
        print(
            f"{'Candidate':<20} {'OK':>5} {'VMAF':>7} {'V-NEG':>7} {'XPSNR':>7} "
            f"{'MS-SSIM':>8} {'dE00p95':>8} {'kbps':>8} {'wall_s':>7} {'RTx':>6} {'RSS_MB':>7}",
            file=sys.stderr,
        )
        for cand, res in results.items():
            m = res["metrics"]
            def fmt(key: str, dec: int = 2) -> str:
                s = m.get(key)
                if not s or s.get("median") is None:
                    return "-"
                return f"{s['median']:.{dec}f}"

            print(
                f"{cand:<20} {res['ok_runs']:>2}/{res['total_runs']:<2} "
                f"{fmt('vmaf', 2):>7} {fmt('vmaf_neg', 2):>7} {fmt('xpsnr', 2):>7} "
                f"{fmt('ms_ssim', 4):>8} {fmt('delta_e00_p95', 2):>8} "
                f"{fmt('bitrate_kbps', 1):>8} {fmt('wall_s', 3):>7} {fmt('realtime_x', 2):>6} "
                f"{fmt('peak_rss_mb', 1):>7}",
                file=sys.stderr,
            )
        p3d = [p["candidate"] for p in pareto["pareto_frontier_3d"]]
        prd = [p["candidate"] for p in pareto["pareto_frontier_rd"]]
        print(f"[spec_bench] Pareto 3D ({pareto['quality_metric']}↑, kbps↓, wall_s↓): {p3d}", file=sys.stderr)
        print(f"[spec_bench] Pareto RD ({pareto['quality_metric']}↑, kbps↓): {prd}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
