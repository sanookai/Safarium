"""Opt-in Metal (GPU) paths: switch semantics, byte-exact OFF behaviour, documented tolerances ON, fallbacks.

Pick's ruling (2026-11-24, docs/raster-roadmap.md section 5): OFF by default and byte-identical to the CPU path; with the
switch on, results may differ slightly from OpenCV within the per-op tolerances asserted here (also listed in
cv2/_gpu.py TOLERANCE).

Run: SAFARIUM_RASTER_LIB=<dylib> $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_gpu.py
"""
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import SHIM_ROOT, load_pair  # noqa: E402

ref, sr = load_pair()
gpu = sr._gpu
core = sr._core                       # the CPU functions as they were before the GPU module existed
RNG = np.random.default_rng(20261124)

OPS = ["sqrt", "exp", "log", "pow", "magnitude", "phase", "cartToPolar", "polarToCart", "multiply", "addWeighted"]
U8_OPS = ("multiply", "addWeighted")
HAVE_METAL = gpu.safarium_gpu_available() if hasattr(gpu, "safarium_gpu_available") else sr.safarium_gpu_available()
needs_metal = pytest.mark.skipif(not HAVE_METAL, reason="no Metal device")
ENV_ON = os.environ.get("SAFARIUM_GPU", "").strip().lower() in ("1", "true", "yes", "on")

SHAPES = [(1, 1), (1, 3), (3, 1), (5, 7), (37, 53), (4, 4, 3), (17, 31, 4), (100, 257), (64, 64, 2)]


@pytest.fixture(autouse=True)
def _reset():
    sr.safarium_set_gpu(False)
    gpu.force_min_elems(None)
    yield
    sr.safarium_set_gpu(False)
    gpu.force_min_elems(None)


@pytest.fixture
def gpu_on():
    if not HAVE_METAL:
        pytest.skip("no Metal device")
    sr.safarium_set_gpu(True)
    gpu.force_min_elems(0)          # tiny test arrays must still reach the GPU
    yield
    sr.safarium_set_gpu(False)
    gpu.force_min_elems(None)


# ------------------------------------------------------------------------------------------ helpers
def ordered(a):
    i = np.ascontiguousarray(a, dtype=np.float32).view(np.int32).astype(np.int64)
    return np.where(i < 0, -(i & 0x7FFFFFFF), i)


def max_ulp(a, b):
    """Largest float32 distance in ulps; NaNs must sit at the same places, equal infinities count as 0."""
    a, b = np.asarray(a, np.float32), np.asarray(b, np.float32)
    assert a.shape == b.shape
    assert np.array_equal(np.isnan(a), np.isnan(b)), "NaN positions differ"
    ok = ~np.isnan(a)
    if not ok.any():
        return 0
    return int(np.abs(ordered(a[ok]) - ordered(b[ok])).max())


def args_for(name, shape, lo=None, hi=None, power=2.2):
    """One random argument tuple per op; the same data feeds every implementation."""
    def u(a, b):
        return RNG.uniform(a, b, shape).astype(np.float32)
    if name == "sqrt":
        return (u(0, 1e4),), {}
    if name == "exp":
        return (u(-80, 80),), {}
    if name == "log":
        return (u(1e-6, 1e6),), {}
    if name == "pow":
        return (u(1e-3, 100), power), {}
    if name in ("magnitude", "phase"):
        return (u(-255, 255), u(-255, 255)), ({"angleInDegrees": True} if name == "phase" else {})
    if name == "cartToPolar":
        return (u(-255, 255), u(-255, 255)), {"angleInDegrees": True}
    if name == "multiply":
        return (RNG.integers(0, 256, shape, dtype=np.uint8), RNG.integers(0, 256, shape, dtype=np.uint8)), {"scale": 1 / 255}
    if name == "addWeighted":
        return (RNG.integers(0, 256, shape, dtype=np.uint8), 0.6, RNG.integers(0, 256, shape, dtype=np.uint8), 0.4, 3.2), {}
    return (u(0, 100), u(0, 360)), {"angleInDegrees": True}      # polarToCart(magnitude, angle)


def as_list(r):
    return list(r) if isinstance(r, (tuple, list)) else [r]


def same_bytes(r1, r2):
    a, b = as_list(r1), as_list(r2)
    assert len(a) == len(b)
    for x, y in zip(a, b):
        assert x.dtype == y.dtype and x.shape == y.shape
        assert np.ascontiguousarray(x).tobytes() == np.ascontiguousarray(y).tobytes()


def dispatches():
    return gpu.dispatch_count()


# ------------------------------------------------------------------------------------------ switch + OFF behaviour
@pytest.mark.skipif(ENV_ON, reason="SAFARIUM_GPU=1 in the environment")
def test_default_is_off_and_untouched():
    assert sr.safarium_get_gpu() is False
    for n in OPS:
        assert getattr(sr, n) is gpu._CPU[n], f"{n}: a wrapper sits in front of the CPU function while the GPU is off"


def test_set_get_roundtrip_and_restore():
    before = {n: getattr(sr, n) for n in OPS}
    sr.safarium_set_gpu(True)
    assert sr.safarium_get_gpu() is True
    assert all(getattr(sr, n) is not before[n] for n in OPS)
    sr.safarium_set_gpu(0)
    assert sr.safarium_get_gpu() is False
    assert all(getattr(sr, n) is before[n] for n in OPS)
    sr.safarium_set_gpu(1)
    assert sr.safarium_get_gpu() is True


@pytest.mark.parametrize("name", OPS)
@pytest.mark.parametrize("shape", SHAPES)
def test_off_is_byte_identical_to_cpu_path(name, shape):
    a, kw = args_for(name, shape)
    n0 = dispatches()
    off = getattr(sr, name)(*a, **kw)
    same_bytes(off, getattr(core, name)(*a, **kw))
    # a full on -> off cycle changes nothing
    sr.safarium_set_gpu(True)
    sr.safarium_set_gpu(False)
    same_bytes(getattr(sr, name)(*a, **kw), off)
    assert dispatches() == n0


@pytest.mark.parametrize("name", OPS)
def test_on_but_ineligible_is_byte_identical(name):
    """Switch on, thresholds forced to 0: float64, integer data, odd layouts, integer powers stay on the CPU path."""
    if not HAVE_METAL:
        pytest.skip("no Metal device")
    sr.safarium_set_gpu(True)
    gpu.force_min_elems(0)
    n0 = dispatches()
    cases = []
    for dt in ((np.float64, np.int32) if name in U8_OPS else (np.float64, np.uint8, np.int32)):
        a, kw = args_for(name, (33, 41))
        a = tuple(x.astype(dt) if isinstance(x, np.ndarray) else x for x in a)
        cases.append((a, kw))
    a, kw = args_for(name, (40, 90))                      # non-contiguous: every second column
    cases.append((tuple(x[:, ::2] if isinstance(x, np.ndarray) else x for x in a), kw))
    a, kw = args_for(name, (50,))                         # 1-D
    cases.append((a, kw))
    if name in U8_OPS:
        a8 = RNG.integers(0, 256, (30, 40), dtype=np.uint8)
        b8 = RNG.integers(0, 256, (30, 40), dtype=np.uint8)
        c8 = RNG.integers(0, 256, (30, 40, 1), dtype=np.uint8)
        if name == "multiply":
            cases += [((a8, b8), {"dtype": 2}), ((a8, 3), {}), ((a8, b8[:1]), {}), ((c8, c8), {"scale": 0.5}),
                      ((a8, b8), {"scale": float("nan")}), ((a8, b8[:, :39]), {})]
        else:
            cases += [((a8, 0.5, b8, 0.5, 0.0), {"dtype": 5}), ((a8, 0.5, b8[:1], 0.5, 0.0), {}), ((c8, 0.5, c8, 0.5, 0.0), {}),
                      ((a8, float("inf"), b8, 0.5, 0.0), {}), ((a8, True, b8, 0.5, 0.0), {})]
    if name == "pow":
        for p in (2.0, 3, 0.5, 0, 1, -1, 7.0, 1e300, float("inf"), float("nan")):
            x = RNG.uniform(0.1, 9, (30, 30)).astype(np.float32)
            cases.append(((x, p), {}))
    for a, kw in cases:
        try:
            exp = getattr(core, name)(*a, **kw)
        except sr.error:
            with pytest.raises(sr.error):
                getattr(sr, name)(*a, **kw)
            continue
        same_bytes(getattr(sr, name)(*a, **kw), exp)
    assert dispatches() == n0, "an ineligible call reached the GPU"


@pytest.mark.parametrize("name", ["sqrt", "magnitude"])
def test_bandwidth_bound_ops_never_use_gpu_by_default(name):
    """Calibrated thresholds: sqrt/magnitude only tie the CPU (memory bound) so the GPU is never picked for them."""
    if not HAVE_METAL:
        pytest.skip("no Metal device")
    sr.safarium_set_gpu(True)
    a, kw = args_for(name, (1500, 1500))
    n0 = dispatches()
    same_bytes(getattr(sr, name)(*a, **kw), getattr(core, name)(*a, **kw))
    assert dispatches() == n0


@needs_metal
def test_default_thresholds_gate_by_size():
    sr.safarium_set_gpu(True)
    small, _ = args_for("exp", (64, 64))
    big, _ = args_for("exp", (2000, 2000))
    n0 = dispatches()
    same_bytes(sr.exp(*small), core.exp(*small))
    assert dispatches() == n0
    out = sr.exp(*big)
    assert dispatches() == n0 + 1
    assert max_ulp(out, core.exp(*big)) <= 3


@needs_metal
@pytest.mark.parametrize("name", U8_OPS)
def test_u8_default_threshold(name):
    sr.safarium_set_gpu(True)
    small, kw = args_for(name, (200, 300, 3))
    big, kw2 = args_for(name, (1100, 1900, 3))
    n0 = dispatches()
    same_bytes(getattr(sr, name)(*small, **kw), getattr(core, name)(*small, **kw))
    assert dispatches() == n0
    out = getattr(sr, name)(*big, **kw2)
    assert dispatches() == n0 + 1
    assert np.abs(out.astype(int) - getattr(core, name)(*big, **kw2).astype(int)).max() <= 1


@pytest.mark.parametrize("name", OPS)
def test_errors_do_not_depend_on_switch(name):
    sr.safarium_set_gpu(True)
    gpu.force_min_elems(0)
    bad = {
        "sqrt": ((np.zeros((4, 4), np.uint8),), {}),
        "exp": ((np.zeros((4, 4), np.int32),), {}),
        "log": (("not an array",), {}),
        "pow": ((np.zeros((4, 4), np.float32), "x"), {}),
        "magnitude": ((np.zeros((4, 4), np.float32), np.zeros((5, 4), np.float32)), {}),
        "phase": ((np.zeros((4, 4), np.float32), np.zeros((4, 4), np.float64)), {}),
        "cartToPolar": ((np.zeros((4, 4), np.float32), np.zeros((3, 4), np.float32)), {}),
        "polarToCart": ((np.zeros((4, 4), np.float32), np.zeros((4, 4), np.float64)), {}),
        "multiply": ((np.zeros((4, 4), np.uint8), np.zeros((5, 4), np.uint8)), {}),
        "addWeighted": ((np.zeros((4, 4), np.uint8), 0.5, np.zeros((5, 4), np.uint8), 0.5, 0.0), {}),
    }[name]
    with pytest.raises(Exception) as off:
        sr.safarium_set_gpu(False)
        getattr(sr, name)(*bad[0], **bad[1])
    sr.safarium_set_gpu(True)
    with pytest.raises(type(off.value)):
        getattr(sr, name)(*bad[0], **bad[1])


# ------------------------------------------------------------------------------------------ ON: accuracy vs OpenCV
@needs_metal
@pytest.mark.parametrize("shape", SHAPES)
def test_sqrt_exact(gpu_on, shape):
    (x,), _ = args_for("sqrt", shape)
    x[(0,) * x.ndim] = 0.0
    n0 = dispatches()
    g = sr.sqrt(x)
    assert dispatches() == n0 + 1
    assert max_ulp(g, ref.sqrt(x)) == 0
    assert max_ulp(g, core.sqrt(x)) == 0


@needs_metal
@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize("lo,hi", [(-80, 80), (-5, 5), (-1e-3, 1e-3)])
def test_exp_within_3_ulp(gpu_on, shape, lo, hi):
    x = RNG.uniform(lo, hi, shape).astype(np.float32)
    n0 = dispatches()
    g = sr.exp(x)
    assert dispatches() == n0 + 1
    assert max_ulp(g, ref.exp(x)) <= 3


@needs_metal
@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize("lo,hi", [(1e-6, 1e6), (0.5, 2.0), (0.9, 1.1)])
def test_log_within_4_ulp(gpu_on, shape, lo, hi):
    x = RNG.uniform(lo, hi, shape).astype(np.float32)
    g = sr.log(x)
    r = ref.log(x)
    err = np.abs(g.astype(np.float64) - r.astype(np.float64))
    assert (err <= 4 * np.spacing(np.abs(r)) + 2e-7).all()


@needs_metal
@pytest.mark.parametrize("name,vals", [
    ("exp", [0.0, -0.0, 1.0, -1.0, 88.0, 89.0, 100.0, -87.0, -100.0, -104.0, np.inf, -np.inf, np.nan]),
    ("log", [1.0, 0.0, -0.0, np.inf, np.nan, -1.0, 1e-30, 3.4e38]),
    ("sqrt", [0.0, 1.0, 4.0, np.inf, np.nan, -1.0, 2.0, 3.4e38]),
])
def test_special_values_match_opencv(gpu_on, name, vals):
    """NaN/inf/zero behave as in OpenCV; results in the denormal range (|r| < 1.18e-38) may flush to zero on the GPU."""
    x = np.array(vals, np.float32).reshape(1, -1)
    g, r = getattr(sr, name)(x), getattr(ref, name)(x)
    assert np.array_equal(np.isnan(g), np.isnan(r)), (name, g, r)
    assert np.array_equal(np.isinf(g), np.isinf(r)) and np.array_equal(np.signbit(g) & np.isinf(g), np.signbit(r) & np.isinf(r))
    tiny = np.abs(r) < np.finfo(np.float32).tiny
    assert (g[tiny] == 0).all() or max_ulp(g[tiny], r[tiny]) <= 4
    keep = ~(tiny | np.isinf(r) | np.isnan(r))
    assert max_ulp(g[keep], r[keep]) <= 4


@needs_metal
@pytest.mark.parametrize("shape", [(1, 1), (37, 53), (4, 4, 3), (100, 257)])
@pytest.mark.parametrize("power", [0.3, 0.7, 1.5, 2.2, 2.5, 3.3, -0.5, -1.7, 1e-3])
def test_pow_accuracy(gpu_on, shape, power):
    """Against float64 truth the GPU is within 8 ulp (OpenCV's own float32 pow is up to ~26 ulp off for these cases),
    against OpenCV itself within 2e-6 relative."""
    x = RNG.uniform(1e-3, 100, shape).astype(np.float32)
    n0 = dispatches()
    g = sr.pow(x, power)
    assert dispatches() == n0 + 1
    truth = (x.astype(np.float64) ** power).astype(np.float32)
    assert max_ulp(g, truth) <= 8
    r = ref.pow(x, power)
    assert np.allclose(g, r, rtol=2e-6, atol=0)


@needs_metal
def test_pow_negative_base_and_zero(gpu_on):
    x = np.array([[-8.0, -2.5, 0.0, 1.0, np.inf, np.nan, 4.0]], np.float32)
    for p in (0.3, 2.5, -0.5):
        g, r = sr.pow(x, p), ref.pow(x, p)
        assert np.array_equal(np.isnan(g), np.isnan(r)), (p, g, r)
        assert np.array_equal(np.isinf(g), np.isinf(r)), (p, g, r)
        fin = np.isfinite(r)
        assert np.allclose(g[fin], r[fin], rtol=2e-6)


@needs_metal
@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize("scale", [1e-3, 1.0, 255.0, 1e15])
def test_magnitude_within_4_ulp(gpu_on, shape, scale):
    x = RNG.uniform(-scale, scale, shape).astype(np.float32)
    y = RNG.uniform(-scale, scale, shape).astype(np.float32)
    n0 = dispatches()
    g = sr.magnitude(x, y)
    assert dispatches() == n0 + 1
    assert max_ulp(g, ref.magnitude(x, y)) <= 4


@needs_metal
@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize("scale", [1e-3, 1.0, 255.0, 1e15])
@pytest.mark.parametrize("deg", [True, False])
def test_phase_within_4_ulp(gpu_on, shape, scale, deg):
    x = RNG.uniform(-scale, scale, shape).astype(np.float32)
    y = RNG.uniform(-scale, scale, shape).astype(np.float32)
    n0 = dispatches()
    g = sr.phase(x, y, angleInDegrees=deg)
    assert dispatches() == n0 + 1
    assert max_ulp(g, ref.phase(x, y, angleInDegrees=deg)) <= 4


@needs_metal
@pytest.mark.parametrize("deg", [True, False])
def test_phase_axes_and_zero(gpu_on, deg):
    v = np.array([0.0, -0.0, 1.0, -1.0, 5.0, -5.0, np.inf, -np.inf], np.float32)
    x, y = np.meshgrid(v, v)
    x, y = np.ascontiguousarray(x), np.ascontiguousarray(y)
    g, r = sr.phase(x, y, angleInDegrees=deg), ref.phase(x, y, angleInDegrees=deg)
    assert np.array_equal(np.isnan(g), np.isnan(r))
    ok = ~np.isnan(r)
    assert np.allclose(g[ok], r[ok], rtol=1e-5, atol=1e-6)


@needs_metal
@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize("deg", [True, False])
def test_cart_to_polar_fused(gpu_on, shape, deg):
    x = RNG.uniform(-255, 255, shape).astype(np.float32)
    y = RNG.uniform(-255, 255, shape).astype(np.float32)
    n0 = dispatches()
    gm, ga = sr.cartToPolar(x, y, angleInDegrees=deg)
    assert dispatches() == n0 + 1, "cartToPolar must be one fused dispatch"
    rm, ra = ref.cartToPolar(x, y, angleInDegrees=deg)
    assert max_ulp(gm, rm) <= 4
    assert max_ulp(ga, ra) <= 4


@needs_metal
@pytest.mark.parametrize("shape", SHAPES)
@pytest.mark.parametrize("deg,span", [(False, 7.0), (False, 100.0), (True, 720.0)])
@pytest.mark.parametrize("with_mag", [True, False])
def test_polar_to_cart(gpu_on, shape, deg, span, with_mag):
    """|error| <= 4e-7 * max(|magnitude|) for |angle| <= 100 rad (float32 argument reduction limits larger angles)."""
    a = RNG.uniform(-span, span, shape).astype(np.float32)
    m = RNG.uniform(0, 100, shape).astype(np.float32) if with_mag else None
    n0 = dispatches()
    gx, gy = sr.polarToCart(m, a, angleInDegrees=deg)
    assert dispatches() == n0 + 1
    rx, ry = ref.polarToCart(m, a, angleInDegrees=deg)
    bound = 4e-7 * (100.0 if with_mag else 1.0)
    assert np.abs(gx.astype(np.float64) - rx).max() <= bound
    assert np.abs(gy.astype(np.float64) - ry).max() <= bound


@needs_metal
@pytest.mark.parametrize("shape", SHAPES + [(1080, 1920, 3), (255, 1000)])
@pytest.mark.parametrize("alpha,beta,gamma", [(0.6, 0.4, 3.2), (1.5, -0.7, -10.0), (1.0, 1.0, 0.0), (0.5, 0.5, 0.5),
                                              (0.0, 0.0, 300.0), (255.0, 255.0, 0.0), (-1.0, 2.0, 100.0)])
def test_add_weighted_u8_within_1_lsb(gpu_on, shape, alpha, beta, gamma):
    a = RNG.integers(0, 256, shape, dtype=np.uint8)
    b = RNG.integers(0, 256, shape, dtype=np.uint8)
    n0 = dispatches()
    g = sr.addWeighted(a, alpha, b, beta, gamma)
    assert dispatches() == n0 + 1 and g.dtype == np.uint8 and g.shape == a.shape
    assert np.abs(g.astype(np.int16) - ref.addWeighted(a, alpha, b, beta, gamma).astype(np.int16)).max() <= 1


@needs_metal
@pytest.mark.parametrize("shape", SHAPES + [(1080, 1920, 3), (255, 1000)])
@pytest.mark.parametrize("scale", [1.0, 1 / 255, 0.003, 2.5, 0.0, -1.0])
def test_multiply_u8_within_1_lsb(gpu_on, shape, scale):
    a = RNG.integers(0, 256, shape, dtype=np.uint8)
    b = RNG.integers(0, 256, shape, dtype=np.uint8)
    n0 = dispatches()
    g = sr.multiply(a, b, scale=scale)
    assert dispatches() == n0 + 1 and g.dtype == np.uint8 and g.shape == a.shape
    d = np.abs(g.astype(np.int16) - ref.multiply(a, b, scale=scale).astype(np.int16))
    assert d.max() <= (0 if scale == 1.0 else 1)


@needs_metal
def test_u8_in_place_dst_and_strided(gpu_on):
    a = RNG.integers(0, 256, (50, 70, 3), dtype=np.uint8)
    b = RNG.integers(0, 256, (50, 70, 3), dtype=np.uint8)
    expect = core.addWeighted(a, 0.3, b, 0.7, 1.0)
    y = a.copy()
    n0 = dispatches()
    out = sr.addWeighted(y, 0.3, b, 0.7, 1.0, y)               # dst is src1: elementwise in place
    assert out is y and dispatches() == n0 + 1
    assert np.abs(y.astype(int) - expect.astype(int)).max() <= 1
    wide = np.zeros((50, 140, 3), np.uint8)
    v = wide[:, 10:80]
    assert sr.addWeighted(a, 0.3, b, 0.7, 1.0, v) is v
    assert np.abs(v.astype(int) - expect.astype(int)).max() <= 1 and not wide[:, :10].any() and not wide[:, 80:].any()
    sa, sb = a[3:40, 5:60], b[3:40, 5:60]                       # strided, odd byte offsets
    assert sr.multiply(sa, sb, scale=0.01).shape == sa.shape
    assert np.abs(sr.multiply(sa, sb, scale=0.01).astype(int) - core.multiply(sa, sb, scale=0.01).astype(int)).max() <= 1
    c = a.copy()                                                # partial overlap -> CPU
    n1 = dispatches()
    d = c[:, :69]
    sr.multiply(c[:, 1:], c[:, :69], d, scale=0.01)
    assert dispatches() == n1


# ------------------------------------------------------------------------------------------ ON: memory layouts and dst=
@needs_metal
@pytest.mark.parametrize("name", ["exp", "log", "pow", "phase", "polarToCart"])
def test_strided_offset_and_readonly_views(gpu_on, name):
    base_a, kw = args_for(name, (60, 90))
    for sl in (np.s_[3:50, 5:80], np.s_[:, :], np.s_[1:, 1:]):      # row stride != row length, odd 4-byte offsets
        a = tuple(x[sl] if isinstance(x, np.ndarray) else x for x in base_a)
        n0 = dispatches()
        g = getattr(sr, name)(*a, **kw)
        assert dispatches() == n0 + 1
        r = getattr(core, name)(*a, **kw)
        for gg, rr in zip(as_list(g), as_list(r)):
            assert np.allclose(gg, rr, rtol=3e-5, atol=2e-5)
    ro = tuple(x.copy() if isinstance(x, np.ndarray) else x for x in base_a)
    for x in ro:
        if isinstance(x, np.ndarray):
            x.setflags(write=False)
    g = getattr(sr, name)(*ro, **kw)
    r = getattr(core, name)(*ro, **kw)
    for gg, rr in zip(as_list(g), as_list(r)):
        assert np.allclose(gg, rr, rtol=3e-5, atol=2e-5)


@needs_metal
@pytest.mark.parametrize("name", ["sqrt", "exp", "log"])
def test_in_place_and_dst(gpu_on, name):
    (x,), _ = args_for(name, (40, 70))
    x = np.abs(x) + 1.0
    expect = getattr(core, name)(x)
    y = x.copy()
    n0 = dispatches()
    out = getattr(sr, name)(y, y)
    assert out is y and dispatches() == n0 + 1
    assert max_ulp(y, expect) <= 4
    d = np.empty_like(x)
    assert getattr(sr, name)(x, d) is d
    assert max_ulp(d, expect) <= 4
    wide = np.zeros((40, 140), np.float32)                  # dst is a strided view
    v = wide[:, 10:80]
    assert getattr(sr, name)(x, v) is v
    assert max_ulp(v, expect) <= 4 and not wide[:, :10].any() and not wide[:, 80:].any()
    # a dst of the wrong dtype is replaced, as in cv2
    bad = np.empty((40, 70), np.float64)
    res = getattr(sr, name)(x, bad)
    assert res is not bad and res.dtype == np.float32


@needs_metal
def test_readonly_mapped_source(gpu_on, tmp_path):
    """A source living in a read-only file mapping (np.frombuffer of an ACCESS_READ mmap) is read in place."""
    import mmap
    x = RNG.uniform(0.1, 9, 250_000).astype(np.float32)
    path = tmp_path / "ro.bin"
    path.write_bytes(x.tobytes())
    with open(path, "rb") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        ro = np.frombuffer(mm, dtype=np.float32).reshape(500, 500)
        assert not ro.flags.writeable
        n0 = dispatches()
        g = sr.exp(ro)
        assert dispatches() == n0 + 1
        assert max_ulp(g, core.exp(ro)) <= 3
        del ro
        mm.close()


@needs_metal
def test_partial_alias_falls_back_to_cpu(gpu_on):
    buf = np.arange(1, 201, dtype=np.float32).reshape(10, 20)
    src = buf[:, :19]
    dst = buf[:, 1:]                                    # overlaps src, shifted by one element
    n0 = dispatches()
    expect_buf = buf.copy()
    core.sqrt(expect_buf[:, :19], expect_buf[:, 1:])
    sr.sqrt(src, dst)
    assert dispatches() == n0
    assert np.array_equal(buf, expect_buf)


@needs_metal
def test_only_one_dispatch_per_call_and_no_copy_for_numpy_buffers(gpu_on):
    x = RNG.uniform(0.1, 9, (1080, 1920)).astype(np.float32)
    c0 = gpu.dispatch_count(True)
    n0 = dispatches()
    for _ in range(5):
        sr.log(x)
    assert dispatches() == n0 + 5
    assert gpu.dispatch_count(True) == c0, "numpy buffers should be wrapped zero-copy"


# ------------------------------------------------------------------------------------------ fallback
@needs_metal
@pytest.mark.parametrize("name", OPS)
def test_gpu_error_falls_back_to_cpu_result(gpu_on, monkeypatch, name):
    a, kw = args_for(name, (20, 30))
    exp = getattr(core, name)(*a, **kw)
    for sym in ("_g_unary", "_g_binary", "_g_polar"):
        monkeypatch.setattr(gpu, sym, lambda *args: -2)
    same_bytes(getattr(sr, name)(*a, **kw), exp)


@pytest.mark.parametrize("name", OPS)
def test_missing_gpu_symbols_fall_back(monkeypatch, name):
    """A stale dylib without sr_gpu_* entry points: the switch can be on, everything stays on the CPU path."""
    monkeypatch.setattr(gpu, "_probed", False)
    monkeypatch.setattr(gpu, "_ok", False)
    monkeypatch.setattr(gpu, "_g_avail", None)
    sr.safarium_set_gpu(True)
    gpu.force_min_elems(0)
    assert sr.safarium_get_gpu() is True and sr.safarium_gpu_available() is False
    a, kw = args_for(name, (20, 30))
    same_bytes(getattr(sr, name)(*a, **kw), getattr(core, name)(*a, **kw))


def _run_child(code, **env):
    full = dict(os.environ)
    full.update(env)
    full.pop("PYTHONPATH", None)
    py = Path(sys.prefix) / "bin" / "python"          # the venv's interpreter (sys.executable may be the framework app)
    return subprocess.run([str(py if py.exists() else sys.executable), "-c", code], capture_output=True, text=True, env=full, timeout=120)


_CHILD_HEAD = f"import sys, numpy as np; sys.path.insert(0, {str(SHIM_ROOT)!r}); import cv2; "


def test_env_switch_starts_on():
    probe = _CHILD_HEAD + "print(cv2.safarium_get_gpu(), cv2.sqrt is cv2._gpu._CPU['sqrt'])"
    p = _run_child(probe, SAFARIUM_GPU="1")
    assert p.returncode == 0, p.stderr
    assert p.stdout.split() == ["True", "False"], p.stdout        # on, and a wrapper is installed
    p = _run_child(probe, SAFARIUM_GPU="")
    assert p.stdout.split() == ["False", "True"], p.stdout        # off, and nothing wraps the CPU function


def test_metal_unavailable_is_graceful():
    """SAFARIUM_GPU_DISABLE=1 makes the dylib report no Metal: the switch still round-trips and results are CPU results."""
    code = _CHILD_HEAD + (
        "x = np.random.default_rng(1).uniform(0.1, 9, (300, 300)).astype(np.float32)\n"
        "cpu = {n: getattr(cv2, n)(x) for n in ('sqrt', 'exp', 'log')}; cpu['pow'] = cv2.pow(x, 2.2)\n"
        "cv2.safarium_set_gpu(True); cv2._gpu.force_min_elems(0)\n"
        "assert cv2.safarium_get_gpu() is True and cv2.safarium_gpu_available() is False\n"
        "for n in ('sqrt', 'exp', 'log'):\n"
        "    assert getattr(cv2, n)(x).tobytes() == cpu[n].tobytes(), n\n"
        "assert cv2.pow(x, 2.2).tobytes() == cpu['pow'].tobytes()\n"
        "assert cv2._gpu.dispatch_count() == 0\n"
        "print('OK')\n")
    p = _run_child(code, SAFARIUM_GPU_DISABLE="1", SAFARIUM_GPU="")
    assert p.returncode == 0 and "OK" in p.stdout, p.stdout + p.stderr
