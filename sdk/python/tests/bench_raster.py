#!/usr/bin/env python3
"""bench_raster.py - "better than OpenCV" acceptance harness for SafariumRaster (docs/raster-roadmap.md section 3).

Compares the Safarium cv2 shim (and scipy/tifffile stand-ins) with real OpenCV 5.1 / scipy on four metrics per case:
speed, peak RAM, quality/accuracy and (encoders) file size at equal quality. Verdicts are WIN / TIE / LOSS per metric.

Usage (parent runs under the reference venv, which has numpy + Pillow + real cv2 5.1):
    $SCRATCH/cvref/bin/python sdk/python/tests/bench_raster.py --phase 3 [--n 15] [--json] [--write-md]
    $SCRATCH/cvref/bin/python sdk/python/tests/bench_raster.py --area ops | --op resize | --list
Env: SAFARIUM_RASTER_LIB (dylib), BENCH_CV2_PYTHON / BENCH_SCI_PYTHON (default $SCRATCH/cvref|sciref/bin/python).

Method (every number comes from a fresh subprocess per engine):
  speed    warmup, then N timed samples (wall + CPU) per engine, in two configs: 1 thread (cv2.setNumThreads(1) on both,
           the SF-VIDEO-1 default) and default threads (GPU/ANE count only here). A/B order alternates per case and block.
  RAM      one fresh child per (case, engine); baseline = after imports + input allocation; peak = max(ru_maxrss growth,
           peak of RSS sampled by the parent every ~1 ms - baseline); phys_footprint (sees GPU/unified memory) is measured
           the same way and the WORSE of the RSS and footprint verdicts is reported.
  quality  parity vs cv2 (raster_parity.compare: SSIM/PSNR/dE00) and, where a ground truth exists, RMSE vs truth for both.
  size     encoders: bytes at matched SSIM (quality knob bisected for each engine, decoded with Pillow) or lossless bytes.
Thresholds (stated in the output): speed WIN <= 0.95x cv2 median with non-overlapping 95% CIs (LOSS >= 1.05x, CIs apart);
RAM WIN <= 0.9x (and >= 1 MiB apart); accuracy WIN <= 0.9x cv2 error, LOSS > cv2 error*(1+1e-3); size WIN <= 0.95x bytes.
Runs wait while load1 > 8 (max 10 min, then provisional); results with load1 > 4 are marked provisional.
Video cases are opt-in (--include-video) because SF-VIDEO-1 requires the safarium-render queue for decoding.
"""
from __future__ import annotations

import argparse
import ctypes
import gc
import hashlib
import io
import json
import math
import os
import resource
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

# Other agents edit the shim and the Swift target while a run is in progress; pin a consistent snapshot with these two
# env vars (copy the shim next to the freshly built dylib) so every worker of one run sees the same code.
SHIM_CV2_ROOT = Path(os.environ.get("BENCH_SHIM_CV2_ROOT", HERE.parent / "safarium_cv2"))
SHIM_SCI_ROOT = Path(os.environ.get("BENCH_SHIM_SCI_ROOT", HERE.parent / "safarium_sci"))
PROJECT_ROOT = HERE.parents[2]
RESULTS_MD = PROJECT_ROOT / "docs" / "bench-results.md"


def scratch_dir():
    """Scratch root: $BENCH_SCRATCH, else $SCRATCH, else <tmp>/safarium-bench. Holds cvref/ sciref/ kodak/ and build output."""
    import tempfile
    return os.environ.get("BENCH_SCRATCH") or os.environ.get("SCRATCH") or os.path.join(tempfile.gettempdir(), "safarium-bench")

# ------------------------------------------------------------------ thresholds (stated in every report)
SPEED_WIN_RATIO = 0.95        # Safarium median <= 0.95x cv2 median AND CIs do not overlap
SPEED_LOSS_RATIO = 1.05       # Safarium median >= 1.05x cv2 median AND CIs do not overlap
RAM_WIN_RATIO = 0.9
RAM_LOSS_RATIO = 1.1
RAM_NOISE_BYTES = 1024 * 1024  # below / within 1 MiB is page-granularity noise
ACC_WIN_RATIO = 0.9
ACC_LOSS_EPS = 1e-3            # error may exceed cv2's by this relative amount and still tie
SIZE_WIN_RATIO = 0.95
SIZE_LOSS_RATIO = 1.05
PROVISIONAL_LOAD1 = 4.0
MAX_RUN_LOAD1 = 8.0
LEAK_MB_PER_100 = 1.0
NUMERIC_PARITY_REL = 1e-6      # Pick's bar for float64 filters (scipy stand-ins)
MB = 1024 * 1024
RANK = {"LOSS": 0, "TIE": 1, "WIN": 2}


# ------------------------------------------------------------------ pure verdict maths
def median_ci(samples, z=0.98):
    """(median, lo, hi): nonparametric ~95% CI of the median from order statistics."""
    s = sorted(samples)
    n = len(s)
    if n == 0:
        raise ValueError("no samples")
    med = s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])
    lo = max(0, int(math.floor(n / 2 - z * math.sqrt(n))))
    hi = min(n - 1, int(math.ceil(n / 2 + z * math.sqrt(n))))
    return med, s[lo], s[hi]


def _is_blocks(x):
    return len(x) > 0 and isinstance(x[0], (list, tuple))


def median_ci_blocks(blocks, reps=2000, seed=1):
    """Block bootstrap of the median: samples inside one process are correlated (same warm caches, same load window), so
    whole processes are resampled. Returns (median of pooled samples, lo, hi) with a 95% interval."""
    import random
    rnd = random.Random(seed)
    pooled = [x for b in blocks for x in b]
    meds = []
    for _ in range(reps):
        pick = [rnd.choice(blocks) for _ in blocks]
        meds.append(median_ci([x for b in pick for x in b])[0])
    meds.sort()
    return median_ci(pooled)[0], meds[int(0.025 * reps)], meds[int(0.975 * reps) - 1]


def _ci(x):
    return median_ci_blocks(x) if _is_blocks(x) else median_ci(x)


def verdict_speed(sr, ref):
    """sr / ref: flat sample lists (order-statistic CI) or lists of per-process sample lists (block bootstrap CI)."""
    m_s, lo_s, hi_s = _ci(sr)
    m_r, lo_r, hi_r = _ci(ref)
    if m_r <= 0:
        return "TIE"
    ratio = m_s / m_r
    if ratio <= SPEED_WIN_RATIO and hi_s < lo_r:
        return "WIN"
    if ratio >= SPEED_LOSS_RATIO and lo_s > hi_r:
        return "LOSS"
    return "TIE"


def verdict_ram(sr_bytes, ref_bytes):
    if max(sr_bytes, ref_bytes) < RAM_NOISE_BYTES:
        return "TIE"
    if sr_bytes <= RAM_WIN_RATIO * ref_bytes and ref_bytes - sr_bytes >= RAM_NOISE_BYTES:
        return "WIN"
    if sr_bytes >= RAM_LOSS_RATIO * ref_bytes and sr_bytes - ref_bytes >= RAM_NOISE_BYTES:
        return "LOSS"
    return "TIE"


def worst(*verdicts):
    vs = [v for v in verdicts if v in RANK]
    return min(vs, key=RANK.__getitem__) if vs else None


def verdict_ram_pair(rss, footprint):
    """rss / footprint = (sr_bytes, ref_bytes). The lower of the two numbers is never allowed to stand alone."""
    return worst(verdict_ram(*rss), verdict_ram(*footprint))


def slope_mb_per_100(points):
    """Least-squares slope of (frame_index, rss_bytes) in MiB per 100 frames."""
    n = len(points)
    if n < 2:
        return 0.0
    mx = sum(p[0] for p in points) / n
    my = sum(p[1] for p in points) / n
    den = sum((p[0] - mx) ** 2 for p in points)
    if den == 0:
        return 0.0
    return sum((p[0] - mx) * (p[1] - my) for p in points) / den * 100 / MB


def verdict_accuracy(err_sr, err_ref, floor=0.0):
    """`floor` = output resolution (e.g. 2 ulp of float32): errors that are both below it are rounding noise = TIE."""
    if err_sr == 0 and err_ref == 0:
        return "TIE"
    if max(err_sr, err_ref) <= floor:
        return "TIE"
    if err_sr <= ACC_WIN_RATIO * err_ref:
        return "WIN"
    if err_sr > err_ref * (1 + ACC_LOSS_EPS) + 1e-12:
        return "LOSS"
    return "TIE"


def verdict_quality(parity_ok, err_sr, err_ref, floor=0.0):
    if not parity_ok:
        return "LOSS"
    if err_sr is None or err_ref is None:
        return "TIE"
    return verdict_accuracy(err_sr, err_ref, floor)


def verdict_size(sr_bytes, ref_bytes):
    if sr_bytes is None or ref_bytes is None or ref_bytes <= 0:
        return None
    if sr_bytes <= SIZE_WIN_RATIO * ref_bytes:
        return "WIN"
    if sr_bytes >= SIZE_LOSS_RATIO * ref_bytes:
        return "LOSS"
    return "TIE"


def overall(v):
    """BETTER = no LOSS on any metric and at least one WIN (roadmap 3). A loss is never averaged away."""
    vals = [x for x in v.values() if x is not None]
    if any(x in ("LOSS", "ERROR") for x in vals):
        return "LOSS"
    if any(x == "REF_ERROR" for x in vals):
        return "REF_ERROR"
    if any(x == "UNSUPPORTED" for x in vals):
        return "UNSUPPORTED"
    if any(x == "WIN" for x in vals):
        return "BETTER"
    return "TIE"


def is_provisional(*loads):
    return max(loads) > PROVISIONAL_LOAD1


@dataclass
class QuietResult:
    ok: bool
    waited: float
    load: float
    provisional: bool


def wait_for_quiet(load_fn=None, sleep_fn=time.sleep, poll=15, max_wait=600, max_load=MAX_RUN_LOAD1):
    """Block while load1 > max_load (max `max_wait` s); if it never calms down, run anyway but provisional."""
    load_fn = load_fn or (lambda: os.getloadavg()[0])
    waited = 0
    load = load_fn()
    while load > max_load and waited < max_wait:
        sleep_fn(poll)
        waited += poll
        load = load_fn()
    ok = load <= max_load
    return QuietResult(ok, waited, load, (not ok) or load > PROVISIONAL_LOAD1)


# ------------------------------------------------------------------ rate-distortion helpers
def interp_bytes_at_ssim(points, target):
    """points = [(knob, bytes, ssim)]. Linear interpolation of bytes at SSIM == target; None if unreachable."""
    pts = sorted(points, key=lambda p: p[2])
    if not pts or target > pts[-1][2]:
        return None
    if target <= pts[0][2]:
        return float(pts[0][1])
    for a, b in zip(pts, pts[1:]):
        if a[2] <= target <= b[2]:
            if b[2] == a[2]:
                return float(b[1])
            t = (target - a[2]) / (b[2] - a[2])
            return a[1] + t * (b[1] - a[1])
    return None


def bisect_quality(evaluate, target, lo, hi):
    """Smallest integer knob with ssim >= target (ssim monotone in knob). Returns the evaluated points."""
    pts = {}

    def ev(q):
        if q not in pts:
            pts[q] = evaluate(q)
        return pts[q]

    if ev(hi)[2] >= target:
        a, b = lo, hi
        while b - a > 1:
            m = (a + b) // 2
            if ev(m)[2] >= target:
                b = m
            else:
                a = m
        ev(a)
        ev(b)
    return [pts[k] for k in sorted(pts)]


# ------------------------------------------------------------------ registry
def load_cases(include_hidden=False):
    import bench_cases
    return [c for c in bench_cases.CASES if include_hidden or not c.hidden]


def select_cases(cases, phase=None, area=None, op=None, name=None, include_video=False):
    out = []
    for c in cases:
        if c.video and not include_video:
            continue
        if phase is not None and phase not in c.phases:
            continue
        if area is not None and c.area != area:
            continue
        if op is not None and c.op != op:
            continue
        if name is not None and c.name != name:
            continue
        out.append(c)
    return out


def get_case(name):
    for c in load_cases(include_hidden=True):
        if c.name == name:
            return c
    raise KeyError(name)


# ------------------------------------------------------------------ process / memory plumbing (macOS)
_libproc = None


def proc_rusage(pid):
    """Current resident size, phys_footprint and lifetime max phys_footprint of a process (proc_pid_rusage v4)."""
    global _libproc
    if _libproc is None:
        _libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        _libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    buf = (ctypes.c_uint64 * 128)()
    if _libproc.proc_pid_rusage(pid, 4, buf) != 0:
        return None
    return {"resident": buf[8], "footprint": buf[9], "lifetime_max_footprint": buf[30]}


def _python_for(family):
    scratch = scratch_dir()
    if family == "cv2":
        return os.environ.get("BENCH_CV2_PYTHON", f"{scratch}/cvref/bin/python")
    if family == "sci":
        return os.environ.get("BENCH_SCI_PYTHON", f"{scratch}/sciref/bin/python")
    return sys.executable


def _dylib():
    scratch = scratch_dir()
    return os.environ.get("SAFARIUM_RASTER_LIB",
                          f"{scratch}/sr-build-bench/release/libSafariumRaster.dylib")


def preflight():
    """None if the shim imports against the dylib; otherwise the import error (a stale dylib breaks EVERY case)."""
    py = _python_for("cv2")
    code = f"import sys; sys.path.insert(0, {str(SHIM_CV2_ROOT)!r}); import cv2; print(cv2.__version__)"
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", SAFARIUM_RASTER_LIB=_dylib())
    r = subprocess.run([py, "-c", code, ], env=env, capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.startswith("safarium"):
        return None
    return (r.stderr or r.stdout).strip()[-400:] or "shim import failed"


def _worker_cmd(mode, case, engine, threads, n, warmup, out, stream_frames):
    import shlex
    cmd = [_python_for(case.family), str(Path(__file__).resolve()), "--worker", mode, "--case", case.name,
           "--engine", engine, "--threads", str(threads), "--n", str(n), "--warmup", str(warmup),
           "--stream-frames", str(stream_frames)]
    if out:
        cmd += ["--out", out]
    prefix = shlex.split(os.environ.get("BENCH_RUN_PREFIX", ""))
    if case.video:  # SF-VIDEO-1: decoding goes through the single render queue
        prefix = [str(Path.home() / ".local/bin/safarium-render"), "run", "--"]
    return prefix + cmd


WORKER_TIMEOUT = float(os.environ.get("BENCH_WORKER_TIMEOUT", "900"))


def _pump(stream, sink):
    """Drain a pipe continuously so a chatty child can never block on a full 64 KB buffer."""
    for line in iter(stream.readline, ""):
        sink.put(line)
    sink.put(None)


def run_worker_json(mode, case_name, engine, threads=1, n=15, warmup=5, out=None, stream_frames=300, timeout=None):
    """Run one measurement in a FRESH subprocess and return its JSON result (always a dict with a `status`).
    stdout and stderr are drained by threads; a hung child is killed after `timeout` seconds (status ERROR)."""
    import queue
    case = get_case(case_name)
    timeout = WORKER_TIMEOUT if timeout is None else timeout
    cmd = _worker_cmd(mode, case, engine, threads, n, warmup, out, stream_frames)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", SAFARIUM_RASTER_LIB=_dylib())
    deadline = time.monotonic() + timeout
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, text=True)
    outq, errq = queue.Queue(), queue.Queue()
    threading.Thread(target=_pump, args=(p.stdout, outq), daemon=True).start()
    threading.Thread(target=_pump, args=(p.stderr, errq), daemon=True).start()
    lines, errlines, state = [], [], {"eof": False, "out_eof": False, "err_eof": False}
    sampled = {"resident": 0, "footprint": 0}
    stop = threading.Event()

    def drain(q, sink, wait=0.0, key=None):
        try:
            while True:
                ln = q.get(timeout=wait) if wait else q.get_nowait()
                if ln is None:
                    if key:
                        state[key] = True
                    return True
                sink.append(ln)
                wait = 0.0
        except queue.Empty:
            return False

    def get_line(limit):
        while True:
            for i, ln in enumerate(lines):
                if ln.startswith("{") and i >= state.get("consumed", 0):
                    state["consumed"] = i + 1
                    return ln
            if state["eof"] or time.monotonic() > limit:
                return None
            state["eof"] = drain(outq, lines, 0.05, "out_eof") or state["eof"]

    timed_out = False
    base = ready = None
    th = None
    try:
        if mode == "ram":
            first = get_line(deadline)
            try:
                obj = json.loads(first) if first else None
            except ValueError:
                obj = None
            if obj and obj.get("event") == "ready":
                ready = obj
                wpid = obj.get("pid", p.pid)       # under a wrapper (safarium-render) p.pid is not the worker
                base = proc_rusage(wpid) or {"resident": 0, "footprint": 0}

                def sampler():
                    while not stop.is_set():
                        r = proc_rusage(wpid)
                        if r:
                            sampled["resident"] = max(sampled["resident"], r["resident"])
                            sampled["footprint"] = max(sampled["footprint"], r["footprint"])
                        time.sleep(0.001)

                th = threading.Thread(target=sampler, daemon=True)
                th.start()
                p.stdin.write("go\n")
                p.stdin.flush()
            # else: the worker failed before "ready"; its JSON line is the answer and stays in `lines`
            elif first:
                state["consumed"] = 0
        ru = None
        while True:
            state["eof"] = drain(outq, lines, 0.0, "out_eof") or state["eof"]
            drain(errq, errlines, 0.0, "err_eof")
            pid, status, ru = os.wait4(p.pid, os.WNOHANG)
            if pid:
                p.returncode = os.waitstatus_to_exitcode(status)
                break
            if time.monotonic() > deadline:
                timed_out = True
                p.kill()
                _, status, ru = os.wait4(p.pid, 0)
                p.returncode = os.waitstatus_to_exitcode(status)
                break
            time.sleep(0.002)
        stop.set()
        time.sleep(0.05)
        for _ in range(100):                       # child exited: collect what is left in the pipes
            if not state["out_eof"]:
                drain(outq, lines, 0.05, "out_eof")
            if not state["err_eof"]:
                drain(errq, errlines, 0.05, "err_eof")
            if state["out_eof"] and state["err_eof"]:
                break
    finally:
        stop.set()
        if p.poll() is None and p.returncode is None:
            p.kill()
    if timed_out:
        return {"status": "ERROR", "error": f"timeout after {timeout:g}s", "pid": p.pid}
    jl = [ln for ln in lines if ln.startswith("{")]
    cands = [json.loads(ln) for ln in jl if '"event": "ready"' not in ln]
    if not cands:
        return {"status": "ERROR", "error": ("".join(errlines) or "".join(lines))[-600:], "pid": p.pid}
    res = cands[-1]
    res["pid"] = p.pid
    res["worker_pid"] = (ready or {}).get("pid", p.pid)
    res["parent_maxrss"] = ru.ru_maxrss if ru else None
    if mode == "ram" and base is not None and res.get("status") == "OK":
        b0 = res["base"]
        samp_rss = max(sampled["resident"] - base["resident"], 0)
        samp_fp = max(sampled["footprint"] - base["footprint"], 0)
        # own peak = peak seen by the 1 ms sampler above the baseline taken right before the op; the child's own maxrss /
        # lifetime-footprint GROWTH (not the lifetime value, which holds import transients) only backs up ops too short to sample
        res["rss_sampled_delta"] = int(samp_rss)
        res["rss_delta"] = int(max(res["maxrss_end"] - b0["maxrss"], samp_rss, 0))
        res["footprint_delta"] = int(max(res["end"]["lifetime_max_footprint"] - b0["lifetime_max_footprint"], samp_fp, 0))
        res["rss_abs"] = int(max(res["maxrss_end"], sampled["resident"]))
    return res


# ------------------------------------------------------------------ worker side (runs inside the subprocess)
def _hash_input(inp):
    h = hashlib.sha1()
    for k in sorted(inp):
        v = inp[k]
        h.update(k.encode())
        if hasattr(v, "tobytes"):
            h.update(v.tobytes())
        else:
            h.update(repr(v).encode())
    return h.hexdigest()


def _import_engine(case, engine):
    import types
    if case.family == "py":
        return types.SimpleNamespace(__version__="py")
    if case.family == "cv2":
        if engine == "shim":
            sys.path.insert(0, str(SHIM_CV2_ROOT))
        import cv2
        assert engine != "shim" or cv2.__version__.startswith("safarium"), "shim cv2 not loaded"
        assert engine != "ref" or not cv2.__version__.startswith("safarium"), "reference cv2 expected"
        return cv2
    if engine == "shim":
        sys.path.insert(0, str(SHIM_SCI_ROOT))
    import scipy
    assert (engine == "shim") == ("safarium" in scipy.__file__), scipy.__file__
    return scipy


def _worker_prepare(case, engine, threads):
    import numpy as np
    try:
        mod = _import_engine(case, engine)
    except Exception as exc:  # an import failure is a broken build/shim, not "function not implemented"
        raise RuntimeError(f"{engine} engine import failed: {type(exc).__name__}: {exc}") from exc
    missing = [r for r in case.requires if engine == "shim" and not hasattr(mod, r)]
    if missing:
        raise NotImplementedError(f"shim lacks {missing}")
    if threads and hasattr(mod, "setNumThreads"):
        mod.setNumThreads(int(threads))
    inp = case.make_input(np.random.default_rng(case.seed))
    fn = case.callable_for(engine)
    return mod, inp, fn


_UNSUPPORTED_HINTS = ("missing this symbol", "could not find a writer", "not implemented", "not supported", "unsupported")


def _classify(exc):
    """UNSUPPORTED = the shim does not provide it (yet); ERROR = it exists but failed."""
    if isinstance(exc, (AttributeError, NotImplementedError)):
        return "UNSUPPORTED"
    msg = str(exc).lower()
    if not isinstance(exc, RuntimeError) or "import failed" not in msg:
        if any(h in msg for h in _UNSUPPORTED_HINTS):
            return "UNSUPPORTED"
    return "ERROR"


def _synth():
    from bench_cases import _common
    return bool(_common.SYNTH_USED)


def _emit(d):
    sys.stdout.write(json.dumps(d) + "\n")
    sys.stdout.flush()


def _call(case, fn, mod, inp):
    x = case.fresh(inp) if case.fresh else inp
    return fn(mod, x), x


def _worker_speed(case, engine, threads, n, warmup):
    mod, inp, fn = _worker_prepare(case, engine, threads)
    load0 = os.getloadavg()[0]
    wall, cpu = [], []
    gc.collect()
    for i in range(warmup + n):
        x = case.fresh(inp) if case.fresh else inp
        c0, t0 = time.process_time_ns(), time.perf_counter_ns()
        for _ in range(case.reps):
            fn(mod, x)
        t1, c1 = time.perf_counter_ns(), time.process_time_ns()
        if i >= warmup:
            wall.append((t1 - t0) / 1e9 / case.reps)
            cpu.append((c1 - c0) / 1e9 / case.reps)
    return {"status": "OK", "wall": wall, "cpu": cpu, "load1_start": load0, "load1_end": os.getloadavg()[0],
            "threads": mod.getNumThreads() if hasattr(mod, "getNumThreads") else None,
            "version": getattr(mod, "__version__", ""), "engine": engine, "in_sha": _hash_input(inp), "synth": _synth()}


def _worker_ram(case, engine, threads, stream_frames):
    mod, inp, fn = _worker_prepare(case, engine, threads)
    x0 = case.fresh(inp) if case.fresh else inp
    gc.collect()
    snap = proc_rusage(os.getpid())
    base = {"maxrss": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss, **snap}
    _emit({"event": "ready", "pid": os.getpid()})
    sys.stdin.readline()                                   # parent starts its sampler, then sends "go"
    t_start = time.perf_counter()
    calls = 0
    while calls < 6 or (time.perf_counter() - t_start < 0.25 and calls < 300):   # warmup + 5 calls, then >=0.25 s of looks
        x = case.fresh(inp) if case.fresh else inp
        fn(mod, x)
        calls += 1
    end = proc_rusage(os.getpid())
    res = {"status": "OK", "base": base, "end": end, "calls": calls, "in_sha": _hash_input(inp), "synth": _synth(),
           "maxrss_end": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
    del x0
    if case.stream:
        pts = []
        for i in range(stream_frames):
            x = case.fresh(inp) if case.fresh else inp
            fn(mod, x)
            if i % 10 == 0:
                pts.append((i, proc_rusage(os.getpid())["resident"]))
        res["slope_mb_per_100"] = slope_mb_per_100(pts[len(pts) // 4:])   # skip the first quarter (allocator warm-up)
    return res


def _worker_out(case, engine, threads, out_path):
    import numpy as np
    mod, inp, fn = _worker_prepare(case, engine, threads)
    out, x = _call(case, fn, mod, inp)
    norm = case.norm or _default_norm
    arrays = {"out": np.asarray(norm(out if out is not None else x))}
    if engine == "ref" and case.truth is not None:
        arrays["truth"] = np.asarray(case.truth(mod, inp), dtype=np.float64)
    np.savez(out_path, **arrays)
    return {"status": "OK", "in_sha": _hash_input(inp), "synth": _synth(), "shape": list(arrays["out"].shape), "dtype": str(arrays["out"].dtype)}


def _default_norm(out):
    import numpy as np
    if isinstance(out, (tuple, list)) and out and hasattr(out[0], "shape") and len(out) > 0:
        return np.asarray(out[-1] if len(out) > 1 and getattr(out[0], "ndim", 0) == 0 else out[0])
    return np.asarray(out)


def _worker_size(case, engine, threads):
    import numpy as np
    import raster_parity as rp
    from bench_cases._common import pil_decode_bgr
    spec = case.size
    mod, _inp, _fn = _worker_prepare(case, engine, threads)
    img = spec.make_image(np.random.default_rng(case.seed))
    if spec.kind == "lossless":
        data = np.asarray(spec.encode(mod, img, 0), dtype=np.uint8)
        dec = pil_decode_bgr(data)
        return {"status": "OK", "bytes": int(data.size), "exact": bool(np.array_equal(dec, img))}
    if spec.kind == "fixed":
        data = np.asarray(spec.encode(mod, img, 0), dtype=np.uint8)
        dec = pil_decode_bgr(data)
        return {"status": "OK", "bytes": int(data.size),
                "ssim": float(rp.ssim(img, dec)) if dec.shape == img.shape else 0.0}

    def evaluate(q):
        data = np.asarray(spec.encode(mod, img, q), dtype=np.uint8)
        dec = pil_decode_bgr(data)
        return (q, int(data.size), float(rp.ssim(img, dec)))

    res = {"status": "OK", "bytes_at": {}, "points": {}}
    for t in spec.targets:
        pts = bisect_quality(evaluate, t, *spec.knob_range)
        res["bytes_at"][str(t)] = interp_bytes_at_ssim(pts, t)
        res["points"][str(t)] = pts
    return res


def worker_main(a):
    case = get_case(a.case)
    try:
        if a.worker == "speed":
            res = _worker_speed(case, a.engine, a.threads, a.n, a.warmup)
        elif a.worker == "ram":
            res = _worker_ram(case, a.engine, a.threads, a.stream_frames)
        elif a.worker == "out":
            res = _worker_out(case, a.engine, a.threads, a.out)
        elif a.worker == "size":
            res = _worker_size(case, a.engine, a.threads)
        else:
            res = {"status": "ERROR", "error": f"unknown mode {a.worker}"}
    except BaseException as exc:  # noqa: BLE001 - the worker must always answer with a status
        res = {"status": _classify(exc), "error": "".join(traceback.format_exception_only(type(exc), exc)).strip(),
               "trace": traceback.format_exc()[-800:]}
    _emit(res)
    return 0


# ------------------------------------------------------------------ quality
def _is_image(a, metric=None):
    if metric == "numeric":
        return False
    if metric == "image":
        return True
    return a.ndim in (2, 3) and min(a.shape[:2]) >= 8 and (a.ndim == 2 or a.shape[2] <= 4)


def _rmse(a, b):
    import numpy as np
    return float(math.sqrt(np.mean((np.asarray(a, np.float64) - np.asarray(b, np.float64)) ** 2)))


def quality_of_pair(name, ref_out, sr_out, truth=None, metric=None):
    import numpy as np
    ref_out, sr_out = np.asarray(ref_out), np.asarray(sr_out)
    q = {"name": name, "ssim": None, "psnr": None, "de00_p95": None, "max_abs": None, "rel_err": None,
         "err_ref": None, "err_sr": None, "truth": truth is not None}
    if ref_out.shape != sr_out.shape or ref_out.dtype != sr_out.dtype:
        q.update(parity_ok=False, note=f"shape/dtype {ref_out.shape}{ref_out.dtype} vs {sr_out.shape}{sr_out.dtype}")
        q["verdict"] = "LOSS"
        return q
    if _is_image(ref_out, metric):
        import raster_parity as rp
        r = rp.compare(ref_out, sr_out, name)
        q.update(parity_ok=bool(r.ok), ssim=r.ssim, psnr=r.psnr, de00_p95=r.de00_p95, max_abs=r.max_abs)
    else:
        diff = float(np.max(np.abs(ref_out.astype(np.float64) - sr_out.astype(np.float64)))) if ref_out.size else 0.0
        scale = float(np.max(np.abs(ref_out.astype(np.float64)))) if ref_out.size else 0.0
        rel = diff / scale if scale > 0 else diff
        q.update(parity_ok=rel <= NUMERIC_PARITY_REL, rel_err=rel, max_abs=diff)
    if truth is not None and np.asarray(truth).shape == ref_out.shape:
        q["err_ref"] = _rmse(ref_out, truth)
        q["err_sr"] = _rmse(sr_out, truth)
        if ref_out.dtype.kind == "f":   # float outputs cannot be more accurate than their own rounding
            q["floor"] = 2 * float(np.finfo(ref_out.dtype).eps) * max(1.0, float(np.max(np.abs(truth))))
    q["verdict"] = verdict_quality(q["parity_ok"], q["err_sr"], q["err_ref"], q.get("floor", 0.0))
    return q


# ------------------------------------------------------------------ orchestration
def _med(res):
    return median_ci(res["wall"])[0]


def _loads(*results):
    return [x for r in results for x in (r.get("load1_start"), r.get("load1_end")) if x is not None]


def default_opts(**kw):
    import argparse as _ap
    o = _ap.Namespace(n=15, warmup=5, rounds=4, no_ram=False, no_quality=False, no_size=False, stream_frames=300, poll=15,
                      max_wait=600, wait_left=None)
    for k, v in kw.items():
        setattr(o, k, v)
    if o.wait_left is None:
        o.wait_left = o.max_wait
    return o


def _status_of(e, r):
    return "REF_ERROR" if e == "ref" else r.get("status", "ERROR")


def _failed(res):
    for e in ("ref", "shim"):
        if res[e].get("status") != "OK":
            return e, res[e]
    return None, None


def measure_speed(case, idx, opts, threads, tag):
    """Interleaved A/B: `rounds` fresh processes per engine, order flipping every round (ABBA...), so slow drift of the
    machine lands on both engines alike. Returns (res dict of per-engine lists of per-process results) or the failure."""
    first = ("ref", "shim") if (idx % 2 == 0) else ("shim", "ref")
    per = max(3, -(-opts.n // opts.rounds))
    runs = {"ref": [], "shim": []}
    for k in range(opts.rounds):
        order = first if k % 2 == 0 else first[::-1]
        for e in order:
            r = run_worker_json("speed", case.name, e, threads=threads, n=per, warmup=opts.warmup)
            if r.get("status") != "OK":
                return None, (e, r)
            runs[e].append(r)
    return runs, None


def run_case_1t(case, idx, opts):
    """Stage 1: everything measured at one thread (speed 1T, RAM, quality, size). Default-thread speed runs later."""
    import numpy as np
    row = {"name": case.name, "area": case.area, "op": case.op, "variant": case.variant, "note": case.note,
           "speed_1t": None, "speed_dt": None, "ram": None, "quality": None, "size": None,
           "speed_ratio_1t": None, "speed_ratio_dt": None, "ram_ratio": None, "provisional": False,
           "provisional_dt": False, "synth": False}
    gate = wait_for_quiet(poll=opts.poll, max_wait=max(0, opts.wait_left))   # one waiting budget per run
    opts.wait_left -= gate.waited
    loads = [gate.load]
    row["waited_s"] = gate.waited
    first = ("ref", "shim") if idx % 2 == 0 else ("shim", "ref")
    errs = {}

    runs, bad = measure_speed(case, idx, opts, 1, "1t")
    if bad:
        e, r = bad
        row["speed_1t"] = _status_of(e, r)
        errs["speed_1t"] = f"{e}: {r.get('error', '')}"
    else:
        allr = runs["ref"] + runs["shim"]
        loads += _loads(*allr)
        if any(x["in_sha"] != runs["ref"][0]["in_sha"] for x in allr):
            row["speed_1t"] = "ERROR"
            errs["speed_1t"] = "engines got different inputs"
        else:
            sr = [r["wall"] for r in runs["shim"]]
            rf = [r["wall"] for r in runs["ref"]]
            row["speed_1t"] = verdict_speed(sr, rf)
            ms, mr = median_ci([x for b in sr for x in b])[0], median_ci([x for b in rf for x in b])[0]
            row["speed_ratio_1t"] = ms / mr if mr else None
            row.update(ref_ms_1t=mr * 1e3, sr_ms_1t=ms * 1e3,
                       ref_cpu_ms_1t=median_ci([x for r in runs["ref"] for x in r["cpu"]])[0] * 1e3,
                       sr_cpu_ms_1t=median_ci([x for r in runs["shim"] for x in r["cpu"]])[0] * 1e3,
                       threads_1t=(runs["ref"][0].get("threads"), runs["shim"][0].get("threads")),
                       ref_version=runs["ref"][0].get("version"))
            row["synth"] = any(x.get("synth") for x in allr)
    if row["speed_1t"] in ("UNSUPPORTED", "ERROR", "REF_ERROR"):   # nothing else is meaningful for a missing function
        for k in ("ram", "quality"):
            row[k] = row["speed_1t"]
        row["provisional"] = bool(is_provisional(*loads)) or not gate.ok
        row["overall"] = row["overall_1t"] = overall({"speed": row["speed_1t"]})
        row["note"] = (row["note"] + " " + errs.get("speed_1t", "")).strip()[:300]
        row["skip_dt"] = True
        return row

    if not opts.no_ram:
        res = {e: run_worker_json("ram", case.name, e, threads=1, stream_frames=opts.stream_frames) for e in first}
        e, r = _failed(res)
        if e:
            row["ram"] = _status_of(e, r)
            errs["ram"] = f"{e}: {r.get('error', '')}"
        else:
            sr, rf = res["shim"], res["ref"]
            row["ram"] = verdict_ram_pair((sr["rss_delta"], rf["rss_delta"]), (sr["footprint_delta"], rf["footprint_delta"]))
            row["ram_ratio"] = sr["rss_delta"] / rf["rss_delta"] if rf["rss_delta"] else None
            row.update(ref_rss_mb=rf["rss_delta"] / MB, sr_rss_mb=sr["rss_delta"] / MB,
                       ref_fp_mb=rf["footprint_delta"] / MB, sr_fp_mb=sr["footprint_delta"] / MB)
            if case.stream:
                row["slope_ref"], row["slope_sr"] = rf.get("slope_mb_per_100"), sr.get("slope_mb_per_100")
                if row["slope_sr"] is not None and row["slope_sr"] > LEAK_MB_PER_100 >= (row["slope_ref"] or 0):
                    row["ram"] = "LOSS"
                    row["note"] += f" leak {row['slope_sr']:.1f} MiB/100 frames"

    if not opts.no_quality:
        import tempfile
        os.makedirs(scratch_dir(), exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch_dir()) as td:
            paths = {e: os.path.join(td, f"{e}.npz") for e in first}
            res = {e: run_worker_json("out", case.name, e, threads=1, out=paths[e]) for e in first}
            e, r = _failed(res)
            if e:
                row["quality"] = _status_of(e, r)
                errs["quality"] = f"{e}: {r.get('error', '')}"
            else:
                with np.load(paths["ref"]) as zr, np.load(paths["shim"]) as zs:
                    truth = zr["truth"] if "truth" in zr.files else None
                    q = quality_of_pair(case.name, zr["out"], zs["out"], truth, case.metric)
                row["quality"] = q["verdict"]
                row.update({f"q_{k}": v for k, v in q.items() if k not in ("name", "verdict")})

    if case.size is not None and not opts.no_size:
        res = {e: run_worker_json("size", case.name, e, threads=1) for e in first}
        e, r = _failed(res)
        if e:
            row["size"] = _status_of(e, r)
            errs["size"] = f"{e}: {r.get('error', '')}"
        else:
            row["size"] = _size_verdict(case.size, res, row)

    row["provisional"] = bool(is_provisional(*loads)) or not gate.ok
    row["overall_1t"] = overall({"speed": row["speed_1t"], "ram": row["ram"], "quality": row["quality"], "size": row["size"]})
    row["overall"] = row["overall_1t"]
    if row["synth"]:
        row["note"] += " SYNTH: synthetic frame used (real Sompong frame missing)"
    if errs:
        row["note"] = (row["note"] + " " + "; ".join(f"{k}: {v}" for k, v in errs.items())).strip()[:300]
    return row


def run_case_dt(case, idx, opts, row):
    """Stage 2: default-thread speed (GPU/ANE may count here). Runs after every 1-thread measurement of the whole run, so the
    extra load of multi-threaded runs cannot make later 1-thread cases provisional."""
    if row.get("skip_dt"):
        row["speed_dt"] = row["speed_1t"]
        return row
    gate = wait_for_quiet(poll=opts.poll, max_wait=max(0, opts.wait_left))
    opts.wait_left -= gate.waited
    loads = [gate.load]
    runs, bad = measure_speed(case, idx + 1, opts, 0, "dt")      # idx+1: opposite starting engine from the 1T stage
    if bad:
        e, r = bad
        row["speed_dt"] = _status_of(e, r)
        row["note"] = (row["note"] + f" speed_dt {e}: {r.get('error', '')}").strip()[:300]
    else:
        loads += _loads(*(runs["ref"] + runs["shim"]))
        sr = [r["wall"] for r in runs["shim"]]
        rf = [r["wall"] for r in runs["ref"]]
        row["speed_dt"] = verdict_speed(sr, rf)
        ms, mr = median_ci([x for b in sr for x in b])[0], median_ci([x for b in rf for x in b])[0]
        row["speed_ratio_dt"] = ms / mr if mr else None
        row.update(ref_ms_dt=mr * 1e3, sr_ms_dt=ms * 1e3,
                   ref_cpu_ms_dt=median_ci([x for r in runs["ref"] for x in r["cpu"]])[0] * 1e3,
                   sr_cpu_ms_dt=median_ci([x for r in runs["shim"] for x in r["cpu"]])[0] * 1e3,
                   threads_dt=(runs["ref"][0].get("threads"), runs["shim"][0].get("threads")))
    row["provisional_dt"] = bool(is_provisional(*loads)) or not gate.ok
    row["overall"] = overall({"speed": row["speed_dt"], "ram": row["ram"], "quality": row["quality"], "size": row["size"]})
    return row


def run_case(case, idx, opts):
    return run_case_dt(case, idx, opts, run_case_1t(case, idx, opts))


def _size_verdict(spec, res, row):
    sr, rf = res["shim"], res["ref"]
    if spec.kind == "lossless":
        row.update(size_ref=rf["bytes"], size_sr=sr["bytes"])
        if not sr["exact"]:
            row["note"] += " shim lossless round-trip NOT exact"
            return "LOSS"
        return verdict_size(sr["bytes"], rf["bytes"])
    if spec.kind == "fixed":
        row.update(size_ref=rf["bytes"], size_sr=sr["bytes"], size_ssim_ref=rf["ssim"], size_ssim_sr=sr["ssim"])
        if abs(rf["ssim"] - sr["ssim"]) > 0.002:
            row["note"] += f" size not comparable (SSIM {sr['ssim']:.4f} vs {rf['ssim']:.4f})"
            return None
        return verdict_size(sr["bytes"], rf["bytes"])
    vs = []
    for t in spec.targets:
        s, r = sr["bytes_at"].get(str(t)), rf["bytes_at"].get(str(t))
        row[f"size_ref_{t}"], row[f"size_sr_{t}"] = r, s
        v = verdict_size(s, r)
        if v is None and (s is None) != (r is None):
            v = "LOSS" if s is None else "WIN"
        vs.append(v)
    return worst(*vs)


# ------------------------------------------------------------------ reporting
def summarize(rows):
    out = {}
    for r in rows:
        area = out.setdefault(r["area"], {})
        for m in ("speed_1t", "speed_dt", "ram", "quality", "size", "overall", "overall_1t"):
            v = r.get(m)
            if v is None:
                continue
            area.setdefault(m, {})
            area[m][v] = area[m].get(v, 0) + 1
    return out


def worst_losses(rows, k=10):
    items = []
    for r in rows:
        if r.get("speed_1t") == "LOSS" and r.get("speed_ratio_1t"):
            items.append((r["speed_ratio_1t"], f"{r['name']}: speed 1T {r['speed_ratio_1t']:.2f}x cv2 time "
                          f"({r.get('sr_ms_1t', 0):.2f} vs {r.get('ref_ms_1t', 0):.2f} ms)"))
        if r.get("speed_dt") == "LOSS" and r.get("speed_ratio_dt") and r.get("speed_1t") != "LOSS":
            items.append((r["speed_ratio_dt"] * 0.5, f"{r['name']}: speed default-threads {r['speed_ratio_dt']:.2f}x cv2 time"))
        if r.get("ram") == "LOSS":
            items.append(((r.get("ram_ratio") or 2) * 0.8, f"{r['name']}: RAM {r.get('sr_rss_mb', 0):.1f} vs {r.get('ref_rss_mb', 0):.1f} MiB"
                          f" (footprint {r.get('sr_fp_mb', 0):.1f} vs {r.get('ref_fp_mb', 0):.1f})"))
        if r.get("quality") == "LOSS":
            ssim = r.get("q_ssim")
            why = ("parity FAIL " + (f"SSIM {ssim:.4f} PSNR {r.get('q_psnr', 0):.1f}" if ssim is not None else str(r.get("q_note") or r.get("q_rel_err"))))\
                if not r.get("q_parity_ok", True) else f"error vs truth {r.get('q_err_sr'):.4g} > cv2 {r.get('q_err_ref'):.4g}"
            items.append((10.0, f"{r['name']}: quality {why}"))
        if r.get("size") == "LOSS":
            items.append((3.0, f"{r['name']}: file size {r.get('size_sr', r.get('size_sr_0.97'))} vs {r.get('size_ref', r.get('size_ref_0.97'))} bytes"))
    items.sort(key=lambda t: -t[0])
    return [t[1] for t in items[:k]]


def _cell(v, ratio=None):
    if v is None:
        return "-"
    return f"{v}" + (f" {ratio:.2f}x" if ratio else "")


def render_markdown(rows, meta):
    sm = summarize(rows)
    L = ["---", "tags: [safarium, raster, cv2, benchmark, report]", "note_type: report", 'project: "Safarium"',
         "created: 2026-11-24", "updated: 2026-11-24", "---",
         "# SafariumRaster vs OpenCV 5.1 - acceptance benchmark", ""]
    prov = sum(1 for r in rows if r.get("provisional"))
    L += [f"Generated by `sdk/python/tests/bench_raster.py` (selection: {meta.get('selection', 'all')}; N = {meta.get('n', '?')} timed "
          f"samples per engine; load1 at start {meta.get('load1', '?')}). Rows marked `†` are **provisional** (load1 > "
          f"{PROVISIONAL_LOAD1:g} during the run): {prov} of {len(rows)}. Reference: {meta.get('ref', 'cv2 5.1.0')}; shim dylib: "
          f"`{meta.get('dylib', '?')}`. Machine: {meta.get('machine', '?')}.", ""]
    L += ["## Verdict rules (thresholds)", "",
          f"- **Speed**: median wall time over N samples after warmup, Python-call overhead included. Each engine runs in several fresh processes "
          "interleaved A/B/B/A (order flips every round and per case); the CI is a block bootstrap over processes, so one process caught in a load "
          "spike cannot fake a win. All 1-thread work of the whole run is done before any default-thread run. "
          f"WIN = Safarium <= {SPEED_WIN_RATIO}x cv2 median and 95% order-statistic CIs do not overlap; LOSS = >= {SPEED_LOSS_RATIO}x with "
          "CIs apart; else TIE. Two configs: `1T` = both libraries at `setNumThreads(1)` (SF-VIDEO-1 default, the CPU headline) and "
          "`dflt` = each library at its own default thread count (GPU/ANE/Metal count only here, per Pick's Q3 ruling).",
          f"- **RAM**: fresh child per (case, engine); baseline taken after imports and input allocation; peak = max(ru_maxrss growth, "
          f"1 ms-sampled RSS peak - baseline), and the same for `phys_footprint` (sees GPU/unified memory); the worse of the two verdicts "
          f"counts. WIN <= {RAM_WIN_RATIO}x cv2, LOSS >= {RAM_LOSS_RATIO}x, differences under 1 MiB are noise = TIE. Streaming cases also "
          f"require RSS slope < {LEAK_MB_PER_100:g} MiB per 100 frames.",
          f"- **Quality**: parity gate = raster_parity bar (SSIM >= 0.97, PSNR >= 30 dB, dE00 p95 <= 2; numeric outputs rel. error <= "
          f"{NUMERIC_PARITY_REL:g}); failing it is a LOSS. Where a float64/analytic ground truth exists the accuracy gate compares RMSE vs "
          f"truth: WIN <= {ACC_WIN_RATIO}x cv2's error, LOSS > cv2's error * (1 + {ACC_LOSS_EPS:g}). No truth = parity-only (TIE when it "
          "passes). Default output matches OpenCV; more accurate results would sit behind an opt-in flag.",
          f"- **File size** (encoders): bytes at equal SSIM (quality knob bisected per engine, decoded with Pillow) or lossless bytes with "
          f"exact round-trip. WIN <= {SIZE_WIN_RATIO}x, LOSS >= {SIZE_LOSS_RATIO}x.",
          "- **Overall** (`dflt` speed headline): BETTER = no LOSS on any metric and at least one WIN; a LOSS is never averaged away. "
          "`Overall 1T` uses the 1-thread speed instead. UNSUPPORTED = the shim does not implement it yet.", ""]
    L += ["## Summary per area (headline speed = default threads; 1T beside it)", "",
          "| Area | Cases | Speed 1T W/T/L | Speed dflt W/T/L | RAM W/T/L | Quality W/T/L | Size W/T/L | BETTER / TIE / LOSS / UNSUP |",
          "|---|---|---|---|---|---|---|---|"]

    def wtl(d):
        d = d or {}
        return f"{d.get('WIN', 0)}/{d.get('TIE', 0)}/{d.get('LOSS', 0)}" + (f" (+{d.get('UNSUPPORTED', 0)} unsup)" if d.get("UNSUPPORTED") else "")

    for area, d in sm.items():
        o = d.get("overall", {})
        n = sum(1 for r in rows if r["area"] == area)
        L.append(f"| {area} | {n} | {wtl(d.get('speed_1t'))} | {wtl(d.get('speed_dt'))} | {wtl(d.get('ram'))} | {wtl(d.get('quality'))} | "
                 f"{wtl(d.get('size'))} | {o.get('BETTER', 0)} / {o.get('TIE', 0)} / {o.get('LOSS', 0)} / {o.get('UNSUPPORTED', 0)} |")
    L += ["", "## Worst losses", ""]
    wl = worst_losses(rows)
    L += [f"- {t}" for t in wl] if wl else ["- none"]
    L += ["", "## Per-case table", "",
          "| Case | Speed 1T | Speed dflt | RAM (RSS) | Quality | Size | Overall | Overall 1T |", "|---|---|---|---|---|---|---|---|"]
    for r in rows:
        mark = (" †" if r.get("provisional") else "") + (" **SYNTH**" if r.get("synth") else "")
        L.append(f"| `{r['name']}`{mark} | {_cell(r.get('speed_1t'), r.get('speed_ratio_1t'))} | {_cell(r.get('speed_dt'), r.get('speed_ratio_dt'))}{' †' if r.get('provisional_dt') else ''} | "
                 f"{_cell(r.get('ram'), r.get('ram_ratio'))} | {_cell(r.get('quality'))}{_q_detail(r)} | {_cell(r.get('size'))}{_size_detail(r)} | "
                 f"**{r.get('overall', '-')}** | {r.get('overall_1t', '-')} |")
    notes = [r for r in rows if r.get("note", "").strip()]
    if notes:
        L += ["", "## Notes", ""] + [f"- `{r['name']}`: {r['note'].strip()}" for r in notes]
    L += ["", "Speed cells show Safarium time / cv2 time (lower is better); RAM shows Safarium / cv2 peak growth.", "",
          "Generated by SafariumRaster acceptance harness."]
    return "\n".join(L) + "\n"


def _q_detail(r):
    if r.get("q_ssim") is not None:
        s = f" (SSIM {r['q_ssim']:.4f}"
        if r.get("q_err_sr") is not None:
            s += f"; err {r['q_err_sr']:.3g} vs {r['q_err_ref']:.3g}"
        return s + ")"
    if r.get("q_rel_err") is not None:
        return f" (rel {r['q_rel_err']:.1e})"
    return ""


def _size_detail(r):
    a, b = r.get("size_sr", r.get("size_sr_0.97")), r.get("size_ref", r.get("size_ref_0.97"))
    return f" ({a:.0f}/{b:.0f} B)" if a and b else ""


def _machine():
    try:
        mdl = subprocess.run(["sysctl", "-n", "hw.model", "hw.ncpu"], capture_output=True, text=True).stdout.split()
        return f"{mdl[0]}, {mdl[1]} CPUs"
    except Exception:  # noqa: BLE001
        return "?"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--phase", type=int)
    ap.add_argument("--area")
    ap.add_argument("--op")
    ap.add_argument("--case", help="exact case name (also used by workers)")
    ap.add_argument("--json", action="store_true", help="print results as JSON on stdout")
    ap.add_argument("--write-md", action="store_true", help=f"write {RESULTS_MD.relative_to(PROJECT_ROOT)}")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--n", type=int, default=15)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--rounds", type=int, default=4, help="fresh processes per engine per config, interleaved ABBA (samples per process = n/rounds)")
    ap.add_argument("--no-ram", action="store_true")
    ap.add_argument("--no-quality", action="store_true")
    ap.add_argument("--no-size", action="store_true")
    ap.add_argument("--include-video", action="store_true", help="VideoCapture cases (run through safarium-render, SF-VIDEO-1)")
    ap.add_argument("--stream-frames", type=int, default=300)
    ap.add_argument("--poll", type=int, default=15)
    ap.add_argument("--max-wait", type=int, default=600, help="total seconds to wait for load1 <= 8 across the whole run")
    ap.add_argument("--worker", help=argparse.SUPPRESS)
    ap.add_argument("--engine", help=argparse.SUPPRESS)
    ap.add_argument("--threads", type=int, default=0, help=argparse.SUPPRESS)
    ap.add_argument("--out", help=argparse.SUPPRESS)
    a = ap.parse_args(argv)
    if a.worker:
        return worker_main(a)
    cases = select_cases(load_cases(), phase=a.phase, area=a.area, op=a.op, name=a.case, include_video=a.include_video)
    if a.list:
        for c in cases:
            print(c.name, "phases=" + ",".join(map(str, c.phases)))
        return 0
    if not cases:
        print("no cases selected", file=sys.stderr)
        return 2
    bad = preflight()
    if bad:
        print(f"preflight FAILED (shim does not import against {_dylib()}); rebuild the dylib or pin a matching snapshot:\n{bad}",
              file=sys.stderr)
        return 3
    sel = " ".join(f"--{k} {v}" for k, v in (("phase", a.phase), ("area", a.area), ("op", a.op)) if v is not None) or "all"
    rows = []
    a.wait_left = a.max_wait
    for i, c in enumerate(cases):          # stage 1: all 1-thread work first (headline CPU numbers, RAM, quality, size)
        print(f"[1T {i + 1}/{len(cases)}] {c.name}", file=sys.stderr, flush=True)
        rows.append(run_case_1t(c, i, a))
        print(f"    1T {rows[-1].get('speed_1t')} ram {rows[-1].get('ram')} q {rows[-1].get('quality')} "
              f"size {rows[-1].get('size')}", file=sys.stderr, flush=True)
    for i, c in enumerate(cases):          # stage 2: default-thread speed (own load cannot taint stage 1)
        print(f"[dflt {i + 1}/{len(cases)}] {c.name}", file=sys.stderr, flush=True)
        run_case_dt(c, i, a, rows[i])
        print(f"    dflt {rows[i].get('speed_dt')} => {rows[i]['overall']}", file=sys.stderr, flush=True)
    meta = {"selection": sel, "n": a.n, "load1": f"{os.getloadavg()[0]:.1f}", "machine": _machine(),
            "ref": "opencv-python-headless 5.1.0.95", "dylib": os.path.basename(_dylib())}
    if a.json:
        print(json.dumps({"meta": meta, "rows": rows, "summary": summarize(rows)}, indent=1, default=str))
    else:
        for r in rows:
            print(f"{r['overall']:11s} {r['name']:60s} 1T={_cell(r['speed_1t'], r['speed_ratio_1t'])} dflt={_cell(r['speed_dt'], r['speed_ratio_dt'])} "
                  f"ram={_cell(r['ram'], r['ram_ratio'])} q={r['quality']} size={r['size']}")
    if not a.json:
        print()
        for area, d in summarize(rows).items():
            def wtl(m):
                c = d.get(m, {})
                return f"{c.get('WIN', 0)}W/{c.get('TIE', 0)}T/{c.get('LOSS', 0)}L"
            print(f"{area:8s} speed1T {wtl('speed_1t')}  speed-dflt {wtl('speed_dt')}  ram {wtl('ram')}  quality {wtl('quality')}  "
                  f"size {wtl('size')}  overall {d.get('overall', {})}")
    if a.write_md:
        RESULTS_MD.write_text(render_markdown(rows, meta), encoding="utf-8")
        print(f"wrote {RESULTS_MD}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        import numpy  # noqa: F401
    except ImportError:  # run the parent under the reference venv (numpy + Pillow + cv2 5.1)
        py = _python_for("cv2")
        if os.path.exists(py) and sys.executable != py:
            os.execv(py, [py] + sys.argv)
        raise
    sys.exit(main())
