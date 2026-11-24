"""Tests for the harness logic of bench_raster.py (verdict maths, RAM subprocess measurement, provisional flag,
rate-distortion interpolation, case registry, markdown writer). They test the harness, not SafariumRaster.

Run:  $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_bench_raster.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bench_raster as br  # noqa: E402


# ---------------------------------------------------------------- speed verdict
def _samples(center, spread=0.01, n=15):
    return [center * (1 + spread * ((i % 5) - 2) / 2) for i in range(n)]


def test_median_ci_brackets_the_median_and_is_ordered():
    med, lo, hi = br.median_ci([5, 1, 3, 2, 4, 9, 8, 7, 6, 10, 11, 12, 13, 14, 15])
    assert med == 8
    assert lo <= med <= hi
    assert lo > 1 and hi < 15  # an order-statistic CI at n=15 excludes the extremes


def test_speed_win_needs_ratio_and_non_overlapping_ci():
    ref = _samples(1.0)
    assert br.verdict_speed(_samples(0.5), ref) == "WIN"
    assert br.verdict_speed(_samples(0.94), ref) == "WIN"           # <= 0.95x and CIs apart
    assert br.verdict_speed(_samples(0.97), ref) == "TIE"           # inside the 0.95 threshold
    assert br.verdict_speed(_samples(1.02), ref) == "TIE"
    assert br.verdict_speed(_samples(1.5), ref) == "LOSS"


def test_speed_overlapping_ci_is_a_tie_even_when_median_ratio_is_small():
    ref = [1.0, 2.0, 0.5, 3.0, 1.5, 0.8, 2.5, 1.2, 1.1, 2.2, 0.9, 1.3, 1.6, 2.8, 0.7]   # very noisy
    noisy = [0.9, 1.9, 0.4, 2.9, 1.4, 0.7, 2.4, 1.1, 1.0, 2.1, 0.8, 1.2, 1.5, 2.7, 0.6]  # ~0.93x of it
    assert br.verdict_speed(noisy, ref) == "TIE"


def test_speed_threshold_constants_are_the_stated_ones():
    assert br.SPEED_WIN_RATIO == 0.95
    assert br.RAM_WIN_RATIO == 0.9
    assert br.ACC_WIN_RATIO == 0.9
    assert br.SIZE_WIN_RATIO == 0.95
    assert br.PROVISIONAL_LOAD1 == 4.0
    assert br.MAX_RUN_LOAD1 == 8.0


# ---------------------------------------------------------------- RAM verdict
MB = 1024 * 1024


def test_ram_verdicts():
    assert br.verdict_ram(40 * MB, 100 * MB) == "WIN"
    assert br.verdict_ram(100 * MB, 100 * MB) == "TIE"
    assert br.verdict_ram(95 * MB, 100 * MB) == "TIE"          # 0.95x is inside the 0.9 threshold
    assert br.verdict_ram(150 * MB, 100 * MB) == "LOSS"


def test_ram_noise_floor_never_gives_a_win_or_loss():
    assert br.verdict_ram(0, 400 * 1024) == "TIE"               # both under the 1 MiB page-noise floor
    assert br.verdict_ram(300 * 1024, 100 * 1024) == "TIE"


def test_ram_takes_the_worse_of_rss_and_footprint():
    # RSS says WIN but the GPU-inclusive footprint says LOSS: the lower number may not be the only one shown.
    assert br.verdict_ram_pair((10 * MB, 100 * MB), (200 * MB, 100 * MB)) == "LOSS"
    assert br.verdict_ram_pair((10 * MB, 100 * MB), (10 * MB, 100 * MB)) == "WIN"


def test_ram_slope_leak_detection():
    flat = [(i, 100.0 * MB + (i % 3) * 1000) for i in range(0, 300, 10)]
    leaky = [(i, 100.0 * MB + i * 0.05 * MB) for i in range(0, 300, 10)]   # 5 MB per 100 frames
    assert br.slope_mb_per_100(flat) < 1.0
    assert br.slope_mb_per_100(leaky) == pytest.approx(5.0, rel=0.01)


# ---------------------------------------------------------------- accuracy / quality / size / overall
def test_accuracy_verdicts():
    assert br.verdict_accuracy(0.5, 1.0) == "WIN"
    assert br.verdict_accuracy(1.0, 1.0) == "TIE"
    assert br.verdict_accuracy(1.0005, 1.0) == "TIE"            # inside the 1e-3 relative epsilon
    assert br.verdict_accuracy(1.01, 1.0) == "LOSS"
    assert br.verdict_accuracy(0.0, 0.0) == "TIE"               # bit-exact both: can only tie
    assert br.verdict_accuracy(0.0, 0.3) == "WIN"


def test_quality_verdict_parity_failure_is_a_loss_regardless_of_truth():
    assert br.verdict_quality(parity_ok=False, err_sr=0.1, err_ref=1.0) == "LOSS"
    assert br.verdict_quality(parity_ok=True, err_sr=0.1, err_ref=1.0) == "WIN"
    assert br.verdict_quality(parity_ok=True, err_sr=None, err_ref=None) == "TIE"   # parity-only


def test_size_verdicts():
    assert br.verdict_size(90, 100) == "WIN"
    assert br.verdict_size(97, 100) == "TIE"
    assert br.verdict_size(100, 100) == "TIE"
    assert br.verdict_size(110, 100) == "LOSS"
    assert br.verdict_size(None, 100) is None


def test_overall_never_averages_away_a_loss():
    assert br.overall({"speed": "WIN", "ram": "WIN", "quality": "WIN", "size": None}) == "BETTER"
    assert br.overall({"speed": "WIN", "ram": "LOSS", "quality": "WIN", "size": None}) == "LOSS"
    assert br.overall({"speed": "TIE", "ram": "TIE", "quality": "TIE", "size": None}) == "TIE"
    assert br.overall({"speed": "TIE", "ram": "WIN", "quality": "TIE", "size": "TIE"}) == "BETTER"
    assert br.overall({"speed": "UNSUPPORTED", "ram": None, "quality": None, "size": None}) == "UNSUPPORTED"
    assert br.overall({"speed": "ERROR", "ram": None, "quality": None, "size": None}) == "LOSS"


# ---------------------------------------------------------------- provisional flag / load gate
def test_provisional_flag():
    assert br.is_provisional(4.01) is True
    assert br.is_provisional(4.0) is False
    assert br.is_provisional(0.5, 5.5) is True      # worst of start/end counts


def test_wait_for_quiet_returns_immediately_when_idle():
    sleeps = []
    r = br.wait_for_quiet(load_fn=lambda: 1.0, sleep_fn=sleeps.append)
    assert r.ok and r.waited == 0 and sleeps == []


def test_wait_for_quiet_waits_then_succeeds():
    loads = iter([9.5, 9.0, 3.0])
    sleeps = []
    r = br.wait_for_quiet(load_fn=lambda: next(loads), sleep_fn=sleeps.append, poll=15, max_wait=600)
    assert r.ok and len(sleeps) == 2 and r.waited == 30


def test_wait_for_quiet_gives_up_after_max_wait_and_reports_provisional():
    sleeps = []
    r = br.wait_for_quiet(load_fn=lambda: 12.0, sleep_fn=sleeps.append, poll=15, max_wait=60)
    assert not r.ok and r.provisional and r.waited == 60 and len(sleeps) == 4


# ---------------------------------------------------------------- rate-distortion
def test_interp_bytes_at_ssim_is_linear_between_bracketing_points():
    pts = [(50, 1000, 0.90), (60, 1400, 0.95), (70, 2000, 0.99)]
    assert br.interp_bytes_at_ssim(pts, 0.95) == pytest.approx(1400)
    assert br.interp_bytes_at_ssim(pts, 0.925) == pytest.approx(1200)
    assert br.interp_bytes_at_ssim(pts, 0.999) is None          # target not reachable
    assert br.interp_bytes_at_ssim(pts, 0.5) == pytest.approx(1000)   # below the sweep: smallest point


def test_bisect_quality_finds_bracket_with_few_evaluations():
    calls = []

    def evaluate(q):                      # monotone fake codec: ssim grows with q, bytes grow with q
        calls.append(q)
        return (q, 100 * q, 0.80 + 0.002 * q)

    pts = br.bisect_quality(evaluate, target=0.95, lo=1, hi=100)
    assert len(calls) <= 10
    ssims = [p[2] for p in pts]
    assert min(ssims) < 0.95 <= max(ssims)
    assert br.interp_bytes_at_ssim(pts, 0.95) == pytest.approx(100 * 75, rel=1e-6)   # q=75 exactly hits 0.95


# ---------------------------------------------------------------- subprocess RAM measurement (real processes)
def test_ram_worker_sees_a_big_allocation_and_a_noop_is_small():
    big = br.run_worker_json("ram", "selftest.alloc200", "ref", threads=1)
    noop = br.run_worker_json("ram", "selftest.noop", "ref", threads=1)
    assert big["rss_delta"] >= 150 * MB, big
    assert noop["rss_delta"] < 20 * MB, noop
    assert big["footprint_delta"] >= 100 * MB, big          # phys_footprint also sees it
    assert big["rss_abs"] > big["rss_delta"]


def test_ram_measurement_uses_a_fresh_process_each_time():
    a = br.run_worker_json("ram", "selftest.alloc200", "ref", threads=1)
    b = br.run_worker_json("ram", "selftest.noop", "ref", threads=1)
    assert a["pid"] != b["pid"] and a["pid"] != os.getpid()


def test_speed_worker_reports_median_samples_and_load():
    r = br.run_worker_json("speed", "selftest.sleep2ms", "ref", threads=1, n=5, warmup=1)
    assert len(r["wall"]) == 5 and len(r["cpu"]) == 5
    med = sorted(r["wall"])[2]
    assert 0.0015 < med < 0.02, r["wall"]                    # ~2 ms sleep, seconds
    assert max(r["cpu"]) < 0.002                             # sleeping burns almost no CPU
    assert r["load1_start"] >= 0 and "threads" in r


def test_worker_reports_unsupported_when_shim_lacks_the_function():
    r = br.run_worker_json("speed", "selftest.needs_missing_fn", "shim", threads=1, n=3, warmup=1)
    assert r["status"] == "UNSUPPORTED"


# ---------------------------------------------------------------- registry
def test_registry_is_declarative_and_names_are_unique():
    cases = br.load_cases(include_hidden=True)
    names = [c.name for c in cases]
    assert len(names) == len(set(names))
    for c in cases:
        assert c.area and c.op and callable(c.ref), c.name
        assert c.family in ("cv2", "sci", "py"), c.name


def test_seeded_cases_cover_every_required_area():
    areas = {c.area for c in br.load_cases()}
    assert {"draw", "ops", "numpy", "codec", "video", "sci"} <= areas
    ops = {c.op for c in br.load_cases()}
    for needed in ("circle", "resize", "warpAffine", "remap", "GaussianBlur", "erode", "findContours", "cvtColor",
                   "addWeighted", "imencode_jpeg", "imencode_png", "imencode_tiff", "imdecode_jpeg", "VideoCapture.read",
                   "sosfilt"):
        assert needed in ops, needed


def test_seeded_cases_include_1080x1920_and_real_frame_and_dtype_variants():
    cases = br.load_cases()
    variants = {c.variant for c in cases}
    assert any("1080x1920" in v for v in variants)
    assert any("sompong" in v for v in variants)
    assert any("f32" in v for v in variants)
    assert any("u16" in v or "gray" in v for v in variants)


def test_selection_by_phase_area_op():
    allc = br.load_cases()
    assert all(c.area == "draw" for c in br.select_cases(allc, area="draw"))
    assert all(c.op == "resize" for c in br.select_cases(allc, op="resize"))
    assert all(3 in c.phases for c in br.select_cases(allc, phase=3))
    assert br.select_cases(allc, op="nonexistent") == []


def test_video_cases_are_opt_in_because_of_sf_video_1():
    default_ops = {c.op for c in br.select_cases(br.load_cases(), area="video")}
    assert default_ops == set()                                  # excluded unless --include-video
    with_video = {c.op for c in br.select_cases(br.load_cases(), area="video", include_video=True)}
    assert "VideoCapture.read" in with_video


# ---------------------------------------------------------------- parity + truth plumbing
def test_quality_of_pair_uses_parity_bar_and_truth_errors():
    import numpy as np
    truth = np.linspace(0, 255, 64 * 64 * 3).reshape(64, 64, 3)
    a = np.clip(np.rint(truth), 0, 255).astype(np.uint8)
    b = a.copy()
    q = br.quality_of_pair("t", ref_out=a, sr_out=b, truth=truth)
    assert q["parity_ok"] and q["err_ref"] == q["err_sr"]
    assert q["verdict"] == "TIE"
    b2 = np.clip(np.rint(truth + 3), 0, 255).astype(np.uint8)
    q2 = br.quality_of_pair("t", ref_out=a, sr_out=b2, truth=truth)
    assert q2["err_sr"] > q2["err_ref"] and q2["verdict"] == "LOSS"


def test_quality_of_pair_shape_mismatch_fails_parity():
    import numpy as np
    q = br.quality_of_pair("t", ref_out=np.zeros((8, 8, 3), np.uint8), sr_out=np.zeros((9, 8, 3), np.uint8), truth=None)
    assert not q["parity_ok"] and q["verdict"] == "LOSS"


# ---------------------------------------------------------------- markdown
def test_markdown_has_frontmatter_thresholds_provisional_and_up_line():
    rows = [{"name": "ops.resize.demo", "area": "ops", "op": "resize", "variant": "demo", "provisional": True,
             "speed_1t": "WIN", "speed_dt": "TIE", "ram": "TIE", "quality": "TIE", "size": None, "overall": "BETTER",
             "speed_ratio_1t": 0.5, "speed_ratio_dt": 1.0, "ram_ratio": 1.0, "note": ""}]
    md = br.render_markdown(rows, meta={"load1": 2.0, "n": 15, "selection": "all"})
    assert md.startswith("---\n")
    for key in ("tags:", "note_type: report", 'project: "Safarium"', "created: 2026-11-24", "updated: 2026-11-24"):
        assert key in md
    assert "0.95" in md and "provisional" in md.lower()
    assert md.rstrip().splitlines()[-1] == "Generated by SafariumRaster acceptance harness."


# ---------------------------------------------------------------- summaries
def test_worst_takes_the_lowest_ranked_verdict():
    assert br.worst("WIN", "TIE") == "TIE"
    assert br.worst("WIN", "LOSS", "TIE") == "LOSS"
    assert br.worst(None, "WIN") == "WIN"
    assert br.worst(None, None) is None


def test_summarize_and_worst_losses_list_the_losses_first():
    rows = [
        {"name": "a.x", "area": "ops", "speed_1t": "LOSS", "speed_dt": "TIE", "ram": "WIN", "quality": "TIE", "size": None,
         "overall": "LOSS", "overall_1t": "LOSS", "speed_ratio_1t": 3.0, "sr_ms_1t": 3.0, "ref_ms_1t": 1.0},
        {"name": "a.y", "area": "ops", "speed_1t": "WIN", "speed_dt": "WIN", "ram": "TIE", "quality": "TIE", "size": None,
         "overall": "BETTER", "overall_1t": "BETTER", "speed_ratio_1t": 0.5},
    ]
    sm = br.summarize(rows)
    assert sm["ops"]["speed_1t"] == {"LOSS": 1, "WIN": 1}
    assert sm["ops"]["overall"] == {"LOSS": 1, "BETTER": 1}
    wl = br.worst_losses(rows)
    assert len(wl) == 1 and wl[0].startswith("a.x") and "3.00x" in wl[0]


# ---------------------------------------------------------------- noise floor / error classification
def test_accuracy_below_the_float_resolution_floor_is_a_tie():
    assert br.verdict_accuracy(5.5e-8, 5.2e-8) == "LOSS"                    # without a floor the 6% gap counts
    assert br.verdict_accuracy(5.5e-8, 5.2e-8, floor=2.4e-7) == "TIE"        # both under 2 ulp of float32 at 1.0
    assert br.verdict_accuracy(3e-6, 5e-8, floor=2.4e-7) == "LOSS"           # a real gap is still a loss


def test_quality_of_pair_applies_float32_floor_but_not_for_integer_outputs():
    import numpy as np
    rng = np.random.default_rng(0)
    truth = rng.random((64, 64))
    ref = truth.astype(np.float32)
    sr = (truth + rng.normal(0, 1e-8, truth.shape)).astype(np.float32)       # a hair noisier, still rounding-limited
    assert br.quality_of_pair("f", ref, sr, truth)["verdict"] == "TIE"
    t8 = np.linspace(0, 255, 64 * 64 * 3).reshape(64, 64, 3)
    a = np.clip(np.rint(t8), 0, 255).astype(np.uint8)
    b = np.clip(np.rint(t8 + 0.6), 0, 255).astype(np.uint8)
    assert br.quality_of_pair("u", a, b, t8)["verdict"] == "LOSS"            # u8 has no floor: 0.29 vs 0.55 RMS is real


def test_classify_marks_missing_functionality_unsupported_and_real_failures_error():
    assert br._classify(AttributeError("module has no attribute x")) == "UNSUPPORTED"
    assert br._classify(NotImplementedError("x")) == "UNSUPPORTED"
    assert br._classify(RuntimeError("sr_core_mixchannels: libSafariumRaster is missing this symbol (rebuild the dylib)")) == "UNSUPPORTED"
    assert br._classify(RuntimeError("imencode: could not find a writer for the specified extension '.gif'")) == "UNSUPPORTED"
    assert br._classify(ValueError("boom")) == "ERROR"
    assert br._classify(RuntimeError("shim engine import failed: AttributeError: dlsym ...")) == "ERROR"


# ---------------------------------------------------------------- preflight / snapshot roots
def test_preflight_reports_a_missing_dylib_instead_of_letting_every_case_fail(monkeypatch):
    monkeypatch.setenv("SAFARIUM_RASTER_LIB", "/nonexistent/libSafariumRaster.dylib")
    msg = br.preflight()
    assert msg and "libSafariumRaster" in msg


def test_shim_roots_can_be_pinned_to_a_snapshot_with_env(tmp_path):
    import subprocess
    code = ("import bench_raster as b; print(b.SHIM_CV2_ROOT); print(b.SHIM_SCI_ROOT)")
    env = dict(os.environ, BENCH_SHIM_CV2_ROOT=str(tmp_path / "a"), BENCH_SHIM_SCI_ROOT=str(tmp_path / "b"),
               PYTHONPATH=str(Path(__file__).resolve().parent))
    out = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True).stdout.split()
    assert out == [str(tmp_path / "a"), str(tmp_path / "b")]


# ================================================================ reviewer-driven additions
def test_sompong_frame_is_the_real_episode_frame_not_the_synthetic_fallback():
    from bench_cases import _common as c
    f = c.sompong_frame()
    assert c.SOMPONG.is_dir(), f"Sompong project not found at {c.SOMPONG}"
    assert c.frame_is_real(), "every *_sompong case would silently run on a synthetic frame"
    assert f.shape == (1920, 1080, 3) and f.dtype.name == "uint8"


def test_synthetic_fallback_is_loud(tmp_path):
    import subprocess
    code = ("import sys; sys.path.insert(0, %r); from bench_cases import _common as c; c.sompong_frame(); "
            "print(c.frame_is_real())" % str(Path(__file__).resolve().parent))
    env = dict(os.environ, BENCH_SOMPONG_DIR=str(tmp_path), BENCH_FRAME="")
    r = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True)
    assert r.stdout.strip() == "False"
    assert "SYNTHETIC" in r.stderr


def test_block_bootstrap_ci_is_deterministic_and_brackets_the_median():
    blocks = [[0.9, 0.91, 0.89], [1.0, 1.01, 0.99], [1.1, 1.11, 1.09], [0.95, 0.96, 0.94]]
    a = br.median_ci_blocks(blocks)
    assert a == br.median_ci_blocks(blocks)
    med, lo, hi = a
    assert lo <= med <= hi


def test_block_bootstrap_stable_win_wins_but_half_the_processes_drifting_is_a_tie():
    ref = [[1.0, 1.001, 0.999, 1.0]] * 4
    assert br.verdict_speed([[0.5, 0.501, 0.499, 0.5]] * 4, ref) == "WIN"
    drifted = [[0.5, 0.501, 0.499, 0.5]] * 2 + [[1.5, 1.501, 1.499, 1.5]] * 2     # half the processes hit a load spike
    assert br.verdict_speed(drifted, ref) == "TIE"
    slow = [[1.6, 1.601, 1.599, 1.6]] * 4
    assert br.verdict_speed(slow, ref) == "LOSS"


def test_scratch_dir_comes_from_env_not_a_session_path(monkeypatch, tmp_path):
    monkeypatch.setenv("BENCH_SCRATCH", str(tmp_path))
    assert br.scratch_dir() == str(tmp_path)
    monkeypatch.delenv("BENCH_SCRATCH")
    monkeypatch.setenv("SCRATCH", str(tmp_path / "s"))
    assert br.scratch_dir() == str(tmp_path / "s")
    assert not hasattr(br, "DEFAULT_SCRATCH")


def test_pre_ready_failure_keeps_status_and_message_in_ram_mode():
    r = br.run_worker_json("ram", "selftest.needs_missing_fn", "shim", threads=1)
    assert r["status"] == "UNSUPPORTED"
    assert "this_function_does_not_exist" in r["error"]


def test_worker_timeout_kills_a_hung_child_and_reports_error():
    r = br.run_worker_json("speed", "selftest.hang", "ref", threads=1, n=2, warmup=0, timeout=3)
    assert r["status"] == "ERROR" and "timeout" in r["error"].lower()


def test_noisy_child_does_not_deadlock_on_full_pipes():
    r = br.run_worker_json("speed", "selftest.noisy", "ref", threads=1, n=3, warmup=1, timeout=60)
    assert r["status"] == "OK" and len(r["wall"]) == 3
    r2 = br.run_worker_json("ram", "selftest.noisy", "ref", threads=1, timeout=60)
    assert r2["status"] == "OK"


def test_ram_is_the_ops_own_peak_not_the_import_transient():
    r = br.run_worker_json("ram", "selftest.transient50", "ref", threads=1)   # 300 MB allocated+freed BEFORE the op
    assert 40 * MB <= r["rss_delta"] <= 120 * MB, r
    assert r["rss_sampled_delta"] >= 40 * MB, r


def test_ram_samples_the_real_worker_pid_behind_a_wrapper(monkeypatch):
    monkeypatch.setenv("BENCH_RUN_PREFIX", "/bin/sh -c '\"$@\"; exit $?' sh")   # parent pid != worker pid, like safarium-render
    r = br.run_worker_json("ram", "selftest.alloc200", "ref", threads=1)
    assert r["worker_pid"] != r["pid"]
    assert r["rss_sampled_delta"] >= 150 * MB, r


def test_selftest_engines_run_distinct_functions_so_swapped_labels_fail(tmp_path):
    import numpy as np
    for eng, val in (("ref", 1.0), ("shim", 2.0)):
        p = str(tmp_path / f"{eng}.npz")
        assert br.run_worker_json("out", "selftest.engine_probe", eng, threads=1, out=p)["status"] == "OK"
        with np.load(p) as z:
            assert float(z["out"][0, 0]) == val


def test_run_case_end_to_end_on_a_cheap_case_gives_the_expected_verdicts():
    opts = br.default_opts(n=5, warmup=1, rounds=2, max_wait=0, stream_frames=20)
    row = br.run_case_1t(br.get_case("selftest.ab"), 0, opts)
    row = br.run_case_dt(br.get_case("selftest.ab"), 0, opts, row)
    assert row["speed_1t"] == "WIN" and row["speed_dt"] == "WIN", row
    assert row["ram"] == "WIN", row                        # shim function allocates 10 MB, ref 120 MB
    assert row["quality"] == "TIE", row                    # same output from both functions
    assert row["overall"] == "BETTER", row
    assert row["speed_ratio_1t"] < 0.6


def test_run_case_reports_a_parity_loss_when_the_engines_disagree():
    opts = br.default_opts(n=3, warmup=1, rounds=2, max_wait=0, stream_frames=20)
    row = br.run_case_1t(br.get_case("selftest.engine_probe"), 0, opts)
    assert row["quality"] == "LOSS" and row["overall_1t"] == "LOSS"
