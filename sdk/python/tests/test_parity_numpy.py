"""Area D parity: shim numpy ops vs reference OpenCV. Integer results must match exactly; float within 1e-5
(relative to magnitude). Image-size cases also print raster_parity.compare() numbers (run with -s to see).

Run: SAFARIUM_RASTER_LIB=<dylib> $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_parity_numpy.py
"""
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import compare, load_pair  # noqa: E402

ref, sr = load_pair()
RNG = np.random.default_rng(20261124)
FULL = (1920, 1080)  # H, W of a Sompong frame
SMALL = (37, 53)


def rand(shape, dt, lo=None, hi=None):
    dt = np.dtype(dt)
    if dt.kind == "f":
        return RNG.uniform(-300 if lo is None else lo, 300 if hi is None else hi, shape).astype(dt)
    info = np.iinfo(dt)
    return RNG.integers(info.min if lo is None else lo, (info.max if hi is None else hi) + 1, shape, dtype=dt)


def same(r, s, name):
    assert isinstance(s, np.ndarray), f"{name}: got {type(s)}"
    assert s.shape == r.shape and s.dtype == r.dtype, f"{name}: {s.shape}{s.dtype} vs ref {r.shape}{r.dtype}"
    if r.dtype.kind == "f":
        rf, sf = r.astype(np.float64), s.astype(np.float64)
        assert np.array_equal(np.isnan(rf), np.isnan(sf)), f"{name}: NaN mismatch"
        m = ~np.isnan(rf)
        tol = 1e-5 * np.maximum(1.0, np.abs(rf[m]))
        bad = np.abs(rf[m] - sf[m]) > tol
        assert not bad.any(), f"{name}: {int(bad.sum())} float values off, max {np.abs(rf[m]-sf[m]).max():g}"
    else:
        diff = r.astype(np.int64) != s.astype(np.int64)
        assert not diff.any(), f"{name}: {int(diff.sum())}/{r.size} px differ, max {np.abs(r.astype(np.int64)-s.astype(np.int64)).max()}"
    if r.ndim >= 2 and min(r.shape[:2]) >= 11 and r.dtype in (np.uint8, np.float32):
        res = compare(r, s, name)
        print(res)
        assert res.ok, str(res)


# ------------------------------------------------------------------ constants
def test_constants_match_reference():
    from cv2 import _constants  # noqa: F401  (shim module, already imported by load_pair)
    names = sys.modules["cv2._constants"].__all__
    assert len(names) > 100
    bad = [(n, getattr(sr, n), getattr(ref, n, None)) for n in names if getattr(sr, n) != getattr(ref, n, None)]
    assert not bad, bad


def test_logging():
    L = sr.utils.logging
    for n in ("SILENT", "FATAL", "ERROR", "WARNING", "INFO", "DEBUG", "VERBOSE"):
        assert getattr(L, "LOG_LEVEL_" + n) == getattr(ref.utils.logging, "LOG_LEVEL_" + n)
    prev = L.getLogLevel()
    L.setLogLevel(L.LOG_LEVEL_ERROR)
    assert L.getLogLevel() == L.LOG_LEVEL_ERROR
    L.setLogLevel(prev)
    assert L.getLogLevel() == prev


def test_threads():
    before = sr.getNumThreads()
    assert sr.setNumThreads(1) is None
    assert sr.getNumThreads() == 1
    sr.setNumThreads(3)
    assert sr.getNumThreads() == 3
    sr.setNumThreads(0)
    assert sr.getNumThreads() == 1
    sr.setNumThreads(before)


# ------------------------------------------------------------------ cvtColor
SWAP_CODES = ["COLOR_BGR2RGB", "COLOR_RGB2BGR", "COLOR_RGBA2BGRA", "COLOR_BGRA2RGBA", "COLOR_BGR2RGBA",
              "COLOR_RGB2BGRA", "COLOR_BGRA2BGR", "COLOR_BGR2BGRA"]


@pytest.mark.parametrize("code", SWAP_CODES)
@pytest.mark.parametrize("cn", [3, 4])
@pytest.mark.parametrize("dt", [np.uint8, np.uint16, np.float32])
def test_cvt_swap(code, cn, dt):
    a = rand(SMALL + (cn,), dt)
    same(ref.cvtColor(a, getattr(ref, code)), sr.cvtColor(a, getattr(sr, code)), f"{code}/{cn}/{np.dtype(dt)}")


@pytest.mark.parametrize("code", ["COLOR_GRAY2RGB", "COLOR_GRAY2BGR", "COLOR_GRAY2BGRA", "COLOR_GRAY2RGBA"])
@pytest.mark.parametrize("dt", [np.uint8, np.float32])
def test_cvt_from_gray(code, dt):
    a = rand(SMALL, dt)
    same(ref.cvtColor(a, getattr(ref, code)), sr.cvtColor(a, getattr(sr, code)), code)


@pytest.mark.parametrize("code", ["COLOR_RGB2GRAY", "COLOR_BGR2GRAY", "COLOR_RGBA2GRAY", "COLOR_BGRA2GRAY"])
@pytest.mark.parametrize("dt", [np.uint8, np.uint16, np.float32])
def test_cvt_to_gray(code, dt):
    cn = 4 if "A2" in code else 3
    a = rand(FULL + (cn,), dt, *((0, 1) if dt == np.float32 else ()))
    same(ref.cvtColor(a, getattr(ref, code)), sr.cvtColor(a, getattr(sr, code)), f"{code}/{np.dtype(dt)}")


def test_cvt_gray_all_u8_triplets():
    v = np.arange(256, dtype=np.uint8)
    for g in (0, 1, 77, 128, 254, 255):
        a = np.stack(list(np.meshgrid(v, v, indexing="ij")) + [np.full((256, 256), g, np.uint8)], axis=2)
        same(ref.cvtColor(a, ref.COLOR_BGR2GRAY), sr.cvtColor(a, sr.COLOR_BGR2GRAY), f"gray-exhaustive g={g}")


@pytest.mark.parametrize("code", ["COLOR_RGB2HSV", "COLOR_BGR2HSV"])
def test_cvt_hsv_u8_exhaustive(code):
    v = np.arange(256, dtype=np.uint8)
    for third in range(0, 256, 5):
        a = np.stack(list(np.meshgrid(v, v, indexing="ij")) + [np.full((256, 256), third, np.uint8)], axis=2)
        r, s = ref.cvtColor(a, getattr(ref, code)), sr.cvtColor(a, getattr(sr, code))
        assert np.array_equal(r, s), f"{code} third={third}: {(r != s).sum()} differ"


@pytest.mark.parametrize("code", ["COLOR_RGB2HSV", "COLOR_BGR2HSV"])
@pytest.mark.parametrize("hi", [1.0, 255.0])
def test_cvt_hsv_f32(code, hi):
    a = rand(FULL + (3,), np.float32, 0, hi)
    a[:10, :10] = 0.5 * hi  # grey pixels (diff == 0)
    same(ref.cvtColor(a, getattr(ref, code)), sr.cvtColor(a, getattr(sr, code)), f"{code}/f32/{hi}")


@pytest.mark.parametrize("code", ["COLOR_RGB2HSV", "COLOR_BGR2HSV"])
@pytest.mark.parametrize("dt", [np.uint8, np.float32], ids=["u8", "f32"])
def test_cvt_hsv_peak_ram_stays_near_output_size(code, dt):
    """The bench found 261 MiB of temporaries for a 1080x1920 frame (cv2: 2.5 MiB). Peak allocation on top of the input and
    the 3-channel output must stay a small constant, not a multiple of the frame."""
    import tracemalloc

    a = rand((1080, 1920, 3), dt, 0, 255) if dt == np.uint8 else rand((1080, 1920, 3), dt, 0, 1)
    sr.cvtColor(a[:8], getattr(sr, code))  # warm-up (lazy tables)
    tracemalloc.start()
    base = tracemalloc.get_traced_memory()[0]
    out = sr.cvtColor(a, getattr(sr, code))
    peak = tracemalloc.get_traced_memory()[1] - base
    tracemalloc.stop()
    extra = peak - out.nbytes
    assert extra < 24 * 2**20, f"{code}/{np.dtype(dt).name}: {extra / 2**20:.1f} MiB of temporaries beyond the output"
    same(ref.cvtColor(a, getattr(ref, code)), out, f"{code} big frame")


@pytest.mark.parametrize("code", ["COLOR_RGB2HSV", "COLOR_BGR2HSV"])
def test_cvt_hsv_u8_bgra_views_and_odd_sizes(code):
    for shape in [(1, 1), (3, 5), (17, 31), (64, 3)]:
        a4 = rand(shape + (4,), np.uint8)
        same(ref.cvtColor(a4, getattr(ref, code)), sr.cvtColor(a4, getattr(sr, code)), f"{code} bgra {shape}")
        big = rand((shape[0] + 4, shape[1] + 6, 3), np.uint8)
        v = big[2:2 + shape[0], 3:3 + shape[1]]  # row-strided view
        same(ref.cvtColor(v, getattr(ref, code)), sr.cvtColor(v, getattr(sr, code)), f"{code} view {shape}")
        w = np.ascontiguousarray(rand((shape[0], shape[1], 3), np.uint8)[:, ::-1])  # reversed copy is contiguous
        nc = rand((shape[0], shape[1] * 2, 3), np.uint8)[:, ::2]  # column-strided view
        same(ref.cvtColor(nc, getattr(ref, code)), sr.cvtColor(nc, getattr(sr, code)), f"{code} colview {shape}")
        same(ref.cvtColor(w, getattr(ref, code)), sr.cvtColor(w, getattr(sr, code)), f"{code} rev {shape}")


@pytest.mark.parametrize("code", ["COLOR_RGB2HSV", "COLOR_BGR2HSV"])
@pytest.mark.parametrize("width", [1, 5, 7, 9, 15, 17])
def test_cvt_hsv_u8_scalar_tail_exhaustive(code, width):
    """OpenCV converts the last cols % 8 pixels of each row with a scalar tail whose saturation rounds differently from
    its 8-pixel SIMD blocks; every (V, V - min) pair must match in both regions."""
    vv, dd = np.meshgrid(np.arange(256), np.arange(256), indexing="ij")
    m = dd <= vv
    v, d = vv[m], dd[m]
    px = np.stack([(v - d), v, v], axis=1).astype(np.uint8)
    for order in ([0, 1, 2], [1, 2, 0], [2, 0, 1]):
        img = np.repeat(px[:, order][:, None, :], width, axis=1)
        r, s = ref.cvtColor(img, getattr(ref, code)), sr.cvtColor(img, getattr(sr, code))
        assert np.array_equal(r, s), f"{code} width {width} order {order}: {(r != s).any(axis=2).sum()} pixels differ"


def test_cvt_full_frame_and_dst():
    a = rand(FULL + (3,), np.uint8)
    same(ref.cvtColor(a, ref.COLOR_BGR2RGB), sr.cvtColor(a, sr.COLOR_BGR2RGB), "BGR2RGB full")
    d = np.empty_like(a)
    out = sr.cvtColor(a, sr.COLOR_BGR2RGB, dst=d)
    assert out is d and np.array_equal(d, a[..., ::-1])


def test_cvt_errors():
    with pytest.raises(sr.error):
        sr.cvtColor(rand(SMALL + (3,), np.uint8), sr.COLOR_GRAY2RGB)
    with pytest.raises(sr.error):
        sr.cvtColor(rand(SMALL, np.uint8), sr.COLOR_RGB2GRAY)


# ------------------------------------------------------------------ arithmetic
@pytest.mark.parametrize("op", ["add", "subtract", "absdiff", "multiply"])
@pytest.mark.parametrize("dt", [np.uint8, np.uint16, np.float32])
@pytest.mark.parametrize("cn", [1, 3, 4])
def test_arith_arrays(op, dt, cn):
    shape = FULL if cn == 1 else FULL + (cn,)
    hi = 20 if (op == "multiply" and dt == np.uint8) else None
    a, b = rand(shape, dt, 0, hi), rand(shape, dt, 0, hi)
    same(getattr(ref, op)(a, b), getattr(sr, op)(a, b), f"{op}/{np.dtype(dt)}/{cn}")


@pytest.mark.parametrize("op", ["add", "subtract", "absdiff", "multiply"])
@pytest.mark.parametrize("dt", [np.uint8, np.float32])
@pytest.mark.parametrize("scalar", [(1.5, 2.5, 3.5, 9.0), (0.3, -7.7, 100.25), 5, 5.5, (-0.5, 0.5, 1.5, 0.0)])
@pytest.mark.parametrize("cn", [1, 3, 4])
def test_arith_scalar(op, dt, scalar, cn):
    shape = SMALL if cn == 1 else SMALL + (cn,)
    a = rand(shape, dt, 0, 255)
    same(getattr(ref, op)(a, scalar), getattr(sr, op)(a, scalar), f"{op}/{np.dtype(dt)}/{scalar}/{cn}")
    if op in ("add", "subtract", "absdiff"):
        same(getattr(ref, op)(scalar, a), getattr(sr, op)(scalar, a), f"{op}/rev/{np.dtype(dt)}/{scalar}/{cn}")


@pytest.mark.parametrize("dt1,dt2", [(np.uint8, np.float32), (np.float32, np.uint8)])
@pytest.mark.parametrize("op", ["add", "subtract", "multiply", "absdiff"])
def test_arith_mixed(dt1, dt2, op):
    a, b = rand(SMALL + (3,), dt1, 0, 200), rand(SMALL + (3,), dt2, 0, 200)
    same(getattr(ref, op)(a, b), getattr(sr, op)(a, b), f"{op}/{np.dtype(dt1)}+{np.dtype(dt2)}")


@pytest.mark.parametrize("op", ["add", "subtract", "multiply"])
def test_arith_dtype(op):
    a, b = rand(SMALL + (3,), np.uint8), rand(SMALL + (3,), np.uint8)
    same(getattr(ref, op)(a, b, dtype=ref.CV_32F), getattr(sr, op)(a, b, dtype=sr.CV_32F), f"{op}/dtype")
    same(getattr(ref, op)(a, b, dtype=ref.CV_16S), getattr(sr, op)(a, b, dtype=sr.CV_16S), f"{op}/dtype16s")


@pytest.mark.parametrize("scale", [0.01, 1.0 / 255, 2.0, 0.5])
@pytest.mark.parametrize("dt", [np.uint8, np.float32])
def test_multiply_scale(scale, dt):
    a, b = rand(SMALL + (3,), dt, 0, 255), rand(SMALL + (3,), dt, 0, 255)
    same(ref.multiply(a, b, scale=scale), sr.multiply(a, b, scale=scale), f"mul scale {scale}")


def test_add_subtract_mask():
    a, b = rand(SMALL + (3,), np.uint8), rand(SMALL + (3,), np.uint8)
    m = rand(SMALL, np.uint8, 0, 1)
    same(ref.add(a, b, mask=m), sr.add(a, b, mask=m), "add mask")
    d1, d2 = a.copy(), a.copy()
    same(ref.subtract(a, b, dst=d1, mask=m), sr.subtract(a, b, dst=d2, mask=m), "sub mask dst")


def test_glow_layers_pattern_in_place_on_views():
    """The exact in-place sequence from reel/effects/glow.py and reel/layers.py on a strided f32 view."""
    outs = []
    for cv in (ref, sr):
        frame = np.random.default_rng(7).uniform(0, 255, (200, 300, 3)).astype(np.float32)
        a = np.random.default_rng(8).uniform(0, 1, (50, 80)).astype(np.float32)
        reg = frame[30:80, 40:120]
        d = cv.subtract(reg, (12.0, 200.0, 99.5) + (0.0,))
        r1 = cv.multiply(d, cv.merge((a, a, a)), dst=d)
        assert r1 is d
        r2 = cv.subtract(reg, d, dst=reg)
        assert r2 is reg
        outs.append(frame)
    same(outs[0], outs[1], "glow pattern")


# ------------------------------------------------------------------ addWeighted
@pytest.mark.parametrize("dt", [np.uint8, np.float32])
@pytest.mark.parametrize("ab", [(0.5, 0.5, 0.0), (0.3, 0.7, 0.0), (0.25, 0.5, 0.3), (1.0 - 0.37, 0.37, 0.0),
                                (0.123456, 0.876544, 2.5)])
def test_add_weighted(dt, ab):
    a, b = rand(FULL + (3,), dt, 0, 255), rand(FULL + (3,), dt, 0, 255)
    same(ref.addWeighted(a, ab[0], b, ab[1], ab[2]), sr.addWeighted(a, ab[0], b, ab[1], ab[2]), f"aw {ab}")


def test_add_weighted_u8_many_weights():
    a, b = rand(SMALL + (3,), np.uint8), rand(SMALL + (3,), np.uint8)
    for w in np.linspace(0, 1, 97):
        same(ref.addWeighted(a, 1 - w, b, w, 0.0), sr.addWeighted(a, 1 - w, b, w, 0.0), f"aw w={w}")


def test_add_weighted_dst_and_dtype():
    a, b = rand(SMALL + (3,), np.float32, 0, 255), rand(SMALL + (3,), np.float32, 0, 255)
    big = rand((80, 90, 3), np.float32, 0, 255)
    reg = big[5:5 + SMALL[0], 7:7 + SMALL[1]]
    want = ref.addWeighted(reg, 0.4, b, 0.6, 0.0)
    got = sr.addWeighted(reg, 0.4, b, 0.6, 0.0, dst=reg)
    assert got is reg
    same(want, big[5:5 + SMALL[0], 7:7 + SMALL[1]], "aw dst view")
    u = rand(SMALL + (3,), np.uint8)
    same(ref.addWeighted(u, 0.5, u, 0.25, 0.3, dtype=ref.CV_32F),
         sr.addWeighted(u, 0.5, u, 0.25, 0.3, dtype=sr.CV_32F), "aw dtype")
    same(ref.addWeighted(u, 0.5, a, 0.5, 0), sr.addWeighted(u, 0.5, a, 0.5, 0), "aw mixed")


# ------------------------------------------------------------------ merge / split / reduce / count
@pytest.mark.parametrize("dt", [np.uint8, np.float32])
def test_merge_split(dt):
    a = rand(SMALL + (4,), dt)
    rs, ss = ref.split(a), sr.split(a)
    assert type(ss) is type(rs) and len(ss) == len(rs)
    for x, y in zip(rs, ss):
        same(x, y, "split")
    same(ref.merge(rs), sr.merge(ss), "merge")
    same(ref.merge([rs[0]]), sr.merge([ss[0]]), "merge1")
    same(ref.merge([a[..., :3], rs[3]]), sr.merge([a[..., :3], ss[3]]), "merge 3d+2d")
    with pytest.raises(sr.error):
        sr.merge([rs[0], rs[1].astype(np.float64)])


@pytest.mark.parametrize("dim", [0, 1])
@pytest.mark.parametrize("rtype,dtype", [("REDUCE_MAX", -1), ("REDUCE_MIN", -1), ("REDUCE_SUM", "CV_32S"),
                                         ("REDUCE_SUM", "CV_32F"), ("REDUCE_SUM", "CV_64F"), ("REDUCE_AVG", -1),
                                         ("REDUCE_AVG", "CV_32F")])
@pytest.mark.parametrize("dt,cn", [(np.uint8, 1), (np.uint8, 3), (np.float32, 1)])
def test_reduce(dim, rtype, dtype, dt, cn):
    if dt == np.float32 and dtype == "CV_32S":
        pytest.skip("not a valid cv2 combination")
    a = rand(FULL if cn == 1 else FULL + (cn,), dt, 0, 255)
    rd = dtype if dtype == -1 else getattr(ref, dtype)
    same(ref.reduce(a, dim, getattr(ref, rtype), dtype=rd), sr.reduce(a, dim, getattr(sr, rtype), dtype=rd),
         f"reduce {dim} {rtype} {dtype}")


def test_reduce_sum_u8_errors():
    with pytest.raises(sr.error):
        sr.reduce(rand(SMALL, np.uint8), 1, sr.REDUCE_SUM)


def test_count_non_zero():
    a = rand(FULL, np.uint8, 0, 3)
    assert sr.countNonZero(a) == ref.countNonZero(a)
    f = np.array([[0, -0.0, 0.1, np.nan, 1e-30]], np.float32)
    assert sr.countNonZero(f) == ref.countNonZero(f)
    with pytest.raises(sr.error):
        sr.countNonZero(rand(SMALL + (3,), np.uint8))


# ------------------------------------------------------------------ convertScaleAbs / Laplacian
@pytest.mark.parametrize("dt", [np.float32, np.uint8, np.int16])
@pytest.mark.parametrize("ab", [(1.0, 0.0), (0.5, 3.0), (-2.0, 1.5), (255.0, 0.0)])
def test_convert_scale_abs(dt, ab):
    a = rand(FULL + (3,), dt, *((-400, 400) if dt == np.float32 else ()))
    if dt == np.float32:
        a[0, :8, 0] = [0.5, 1.5, 2.5, -3.5, np.nan, np.inf, -np.inf, 254.5]
    same(ref.convertScaleAbs(a, alpha=ab[0], beta=ab[1]), sr.convertScaleAbs(a, alpha=ab[0], beta=ab[1]), f"csa {ab}")


@pytest.mark.parametrize("ksize", [1, 3])
@pytest.mark.parametrize("dt,cn", [(np.float32, 1), (np.float32, 3), (np.uint8, 1), (np.uint8, 3)])
def test_laplacian(ksize, dt, cn):
    a = rand(FULL if cn == 1 else FULL + (cn,), dt, 0, 255)
    same(ref.Laplacian(a, ref.CV_32F, ksize=ksize), sr.Laplacian(a, sr.CV_32F, ksize=ksize), f"lap k{ksize}")
    same(ref.Laplacian(a, ref.CV_32F, ksize=ksize, scale=0.5, delta=3),
         sr.Laplacian(a, sr.CV_32F, ksize=ksize, scale=0.5, delta=3), f"lap k{ksize} scaled")


def test_laplacian_small_and_borders():
    for shape in [(1, 5), (5, 1), (2, 2), (3, 7)]:
        a = rand(shape, np.float32, 0, 255)
        for k in (1, 3):
            same(ref.Laplacian(a, ref.CV_32F, ksize=k), sr.Laplacian(a, sr.CV_32F, ksize=k), f"lap {shape} k{k}")
    a = rand(SMALL, np.uint8)
    for bt in ("BORDER_REPLICATE", "BORDER_CONSTANT", "BORDER_REFLECT"):
        same(ref.Laplacian(a, ref.CV_32F, borderType=getattr(ref, bt)),
             sr.Laplacian(a, sr.CV_32F, borderType=getattr(sr, bt)), f"lap {bt}")
    same(ref.Laplacian(a, -1), sr.Laplacian(a, -1), "lap u8->u8")
    same(ref.Laplacian(a, ref.CV_16S, ksize=3), sr.Laplacian(a, sr.CV_16S, ksize=3), "lap u8->16s")


@pytest.mark.parametrize("name", ["add", "subtract", "multiply", "absdiff", "addWeighted", "convertScaleAbs"])
def test_public_arithmetic_runs_on_core_kernels_not_numpy(name):
    """The bench saw cv2.add(frame, scalar) 75x slower than cv2 because it ran the numpy implementation of this module.
    The public names must resolve to the Swift/NEON core (ctypes `_core` or the `_srcore` C bridge)."""
    import cv2._numpy_ops as numpy_ops

    fn = getattr(sr, name)
    assert fn is not getattr(numpy_ops, name)
    mod = getattr(fn, "__module__", "") or ""
    assert not mod.endswith("_numpy_ops"), (name, mod)


@pytest.mark.parametrize("scale", [1 / 255.0, 0.5, 0.3, 2.25])
@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32], ids=lambda d: np.dtype(d).name)
def test_numpy_fallback_multiply_scale_matches_reference(dt, scale):
    """cv2._numpy_ops.multiply is the pure-numpy fallback; int32 inputs need double arithmetic (float32 lost bits)."""
    import cv2._numpy_ops as numpy_ops

    a, b = rand((300, 400, 3), dt), rand((300, 400, 3), dt)
    same(ref.multiply(a, b, scale=scale), numpy_ops.multiply(a, b, scale=scale), f"numpy multiply {np.dtype(dt).name} {scale}")
