"""Phase 1 (core-numeric) parity: shim vs reference OpenCV 5.1.

Integer results must match exactly; float results within 1e-6 relative (+1e-6 absolute for values near 0).
Where the reference raises cv2.error the shim must raise its own error type.

Run: SAFARIUM_RASTER_LIB=<dylib> $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_parity_core.py
"""
import copy
import itertools
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import load_pair  # noqa: E402

ref, sr = load_pair()
RNG = np.random.default_rng(20261124)

DEPTHS = [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64]
DEPTH_IDS = {np.dtype(d): i for i, d in enumerate(DEPTHS)}
INT_DEPTHS = DEPTHS[:5]
SHAPES = [(1, 1), (3, 7), (37, 53), (16, 64)]


def rand(shape, dt, cn=1, edge=True):
    dt = np.dtype(dt)
    full = tuple(shape) + ((cn,) if cn > 1 else ())
    if dt.kind == "f":
        a = RNG.uniform(-300, 300, full).astype(dt)
        flat = a.reshape(-1)
        if edge and flat.size >= 8:
            flat[:8] = [0.0, 0.5, -0.5, 1.5, 2.5, -2.5, 255.5, 1e6]
        return a
    info = np.iinfo(dt)
    lo, hi = info.min, info.max
    if dt.itemsize == 4:  # keep some mass away from the extremes so non-saturating paths are exercised too
        a = RNG.integers(lo // 4, hi // 4, full, dtype=dt, endpoint=True)
        flat = a.reshape(-1)
        mix = RNG.integers(lo, hi, flat.size, dtype=dt, endpoint=True)
        flat[::3] = mix[::3]
    else:
        a = RNG.integers(lo, hi, full, dtype=dt, endpoint=True)
    flat = a.reshape(-1)
    if edge and flat.size >= 4:
        flat[:4] = [lo, hi, 0, 1]
    return a


def _same(r, s, name):
    if isinstance(r, (tuple, list)):
        assert isinstance(s, (tuple, list)), f"{name}: got {type(s)}"
        assert len(r) == len(s), f"{name}: len {len(s)} vs {len(r)}"
        for i, (x, y) in enumerate(zip(r, s)):
            _same(x, y, f"{name}[{i}]")
        return
    if isinstance(r, np.ndarray):
        assert isinstance(s, np.ndarray), f"{name}: got {type(s)}"
        assert s.shape == r.shape and s.dtype == r.dtype, f"{name}: {s.shape}{s.dtype} vs ref {r.shape}{r.dtype}"
        if r.dtype.kind == "f":
            rf, sf = r.astype(np.float64), s.astype(np.float64)
            assert np.array_equal(np.isnan(rf), np.isnan(sf)), f"{name}: NaN mismatch"
            inf_r, inf_s = np.isinf(rf), np.isinf(sf)
            assert np.array_equal(inf_r, inf_s) and np.array_equal(rf[inf_r], sf[inf_s]), f"{name}: inf mismatch"
            m = np.isfinite(rf)
            tol = 1e-6 * np.abs(rf[m]) + 1e-6
            bad = np.abs(rf[m] - sf[m]) > tol
            assert not bad.any(), f"{name}: {int(bad.sum())} float values off, max {np.abs(rf[m] - sf[m]).max():g}"
        else:
            diff = r != s
            assert not diff.any(), f"{name}: {int(diff.sum())}/{r.size} differ, first idx {np.argwhere(diff)[0]} ref {r[diff][0]} got {s[diff][0]}"
        return
    if isinstance(r, (float, np.floating)):
        assert isinstance(s, (float, np.floating, int)), f"{name}: got {type(s)}"
        if np.isnan(r):
            assert np.isnan(s), f"{name}: {s} vs nan"
        else:
            assert abs(r - s) <= 1e-6 * abs(r) + 1e-9, f"{name}: {s!r} vs ref {r!r}"
        return
    assert r == s and type(r) is type(s) or (isinstance(r, bool) and bool(s) == r) or (r == s), f"{name}: {s!r} vs ref {r!r}"


def both(fn, *args, __exact_float=False, **kw):
    """Call ref.fn and sr.fn with independent copies; compare results and in-place mutations."""
    a1, k1 = copy.deepcopy(args), copy.deepcopy(kw)
    a2, k2 = copy.deepcopy(args), copy.deepcopy(kw)
    try:
        r = getattr(ref, fn)(*a1, **k1)
    except ref.error as e:
        with pytest.raises(sr.error):
            getattr(sr, fn)(*a2, **k2)
        return None
    s = getattr(sr, fn)(*a2, **k2)
    _same(r, s, fn)
    for i, (x, y) in enumerate(zip(a1, a2)):  # in-place mutation of arguments
        if isinstance(x, np.ndarray):
            _same(x, y, f"{fn}.arg{i}")
    for key in k1:
        if isinstance(k1[key], np.ndarray):
            _same(k1[key], k2[key], f"{fn}.{key}")
    return r


def dtname(d):
    return np.dtype(d).name


# --------------------------------------------------------------------------- arithmetic
@pytest.mark.parametrize("op", ["add", "subtract", "absdiff"])
@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("cn", [1, 3])
@pytest.mark.parametrize("shape", SHAPES)
def test_addsub_same_depth(op, dt, cn, shape):
    a, b = rand(shape, dt, cn), rand(shape, dt, cn)
    both(op, a, b)


@pytest.mark.parametrize("op", ["add", "subtract"])
@pytest.mark.parametrize("d1,d2,dtype", [
    (np.uint8, np.uint8, "s16"), (np.uint8, np.uint8, "f32"), (np.uint8, np.int16, "s16"), (np.int8, np.uint8, "s32"),
    (np.float32, np.float32, "u8"), (np.float32, np.uint8, "f32"), (np.int32, np.int32, "f64"),
    (np.uint16, np.int16, "s32"), (np.float64, np.float32, "f32"), (np.uint8, np.float32, "s16"),
    (np.int32, np.float32, "u16"), (np.int16, np.int16, "s8"),
])
def test_addsub_mixed_dtype(op, d1, d2, dtype):
    cvd = {"u8": 0, "s8": 1, "u16": 2, "s16": 3, "s32": 4, "f32": 5, "f64": 6}[dtype]
    a, b = rand((19, 33), d1, 3), rand((19, 33), d2, 3)
    both(op, a, b, dtype=cvd)


@pytest.mark.parametrize("op", ["add", "subtract", "absdiff"])
@pytest.mark.parametrize("d1,d2", [(np.uint8, np.int16), (np.float32, np.uint8), (np.int32, np.float64), (np.int8, np.uint16)])
def test_arith_mixed_depth_no_dtype(op, d1, d2):
    a, b = rand((11, 17), d1), rand((11, 17), d2)
    both(op, a, b)


@pytest.mark.parametrize("op", ["add", "subtract", "absdiff", "multiply", "divide"])
@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.float32, np.float64, np.int32])
@pytest.mark.parametrize("scalar", [3, 2.5, -7, (10, 20, 30), (5, 6), [1.5, 2.5, 3.5, 4.5], 0])
@pytest.mark.parametrize("scalar_first", [False, True])
def test_arith_scalar(op, dt, scalar, scalar_first):
    cn = 3
    a = rand((13, 21), dt, cn)
    if op == "absdiff" and scalar_first:
        both(op, scalar, a)
    elif scalar_first:
        both(op, scalar, a)
    else:
        both(op, a, scalar)


@pytest.mark.parametrize("op", ["add", "subtract"])
@pytest.mark.parametrize("dt", [np.uint8, np.float32, np.int16])
def test_arith_mask_dst_dtype(op, dt):
    a, b = rand((20, 30), dt, 3), rand((20, 30), dt, 3)
    mask = (RNG.integers(0, 2, (20, 30)) * 255).astype(np.uint8)
    both(op, a, b, mask=mask)
    dst = rand((20, 30), dt, 3)
    r = both(op, a, b, dst, mask)
    dst2 = np.zeros((20, 30, 3), dt)
    out = getattr(sr, op)(a, b, dst2)
    assert out is dst2
    both(op, a, 5, mask=mask)


def test_arith_errors():
    a = rand((5, 5), np.uint8)
    b = rand((5, 6), np.uint8)
    both("add", a, b)
    both("add", a, rand((5, 5), np.uint8, 3))
    both("subtract", a, rand((5, 5), np.uint8), mask=rand((5, 5), np.uint8, 3))


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("scale", [1.0, 0.5, 2.25, -1.5])
@pytest.mark.parametrize("cn", [1, 3])
def test_multiply(dt, scale, cn):
    a, b = rand((17, 29), dt, cn), rand((17, 29), dt, cn)
    both("multiply", a, b, scale=scale)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("scale", [1.0, 2.0, 0.3])
def test_divide(dt, scale):
    a, b = rand((17, 29), dt, 3), rand((17, 29), dt, 3)
    b.reshape(-1)[::5] = 0
    both("divide", a, b, scale=scale)


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64], ids=dtname)
def test_divide_scalar_numerator(dt):
    b = rand((9, 13), dt)
    b.reshape(-1)[::4] = 0
    both("divide", 255.0, b)
    both("divide", 3, b, scale=2.0)


@pytest.mark.parametrize("d1,d2,dtype", [(np.uint8, np.uint8, 5), (np.uint8, np.uint8, 3), (np.float32, np.float32, 0), (np.int16, np.int16, 4)])
def test_multiply_divide_dtype(d1, d2, dtype):
    a, b = rand((9, 17), d1, 3), rand((9, 17), d2, 3)
    b.reshape(-1)[::7] = 0
    both("multiply", a, b, dtype=dtype)
    both("divide", a, b, dtype=dtype)


def _spread(shape, dt, cn=3):
    """Random data with products that mostly stay inside every output range, so rounding (not saturation) is tested."""
    dt = np.dtype(dt)
    full = tuple(shape) + (cn,)
    if dt.kind == "f":
        return (RNG.uniform(-1, 1, full) * 10.0 ** RNG.uniform(0, 4, full)).astype(dt)
    info = np.iinfo(dt)
    hi = min(info.max, 1 << 20)
    return RNG.integers(max(info.min, -hi), hi, full, dtype=dt, endpoint=True)


@pytest.mark.parametrize("opname", ["multiply", "divide"])
@pytest.mark.parametrize("scale", [1.0, 0.3, 1 / 255.0])
@pytest.mark.parametrize("dtype", range(7))
@pytest.mark.parametrize("d2", DEPTHS, ids=dtname)
@pytest.mark.parametrize("d1", DEPTHS, ids=dtname)
def test_mul_div_mixed_depth_scale_bit_exact(opname, d1, d2, dtype, scale):
    """multiply/divide of two arrays of different depth with an explicit dtype: OpenCV 5.1 picks the working type from
    the input depths only (never from dtype), so scale*a*b must agree bit for bit, not just within 1e-6."""
    a, b = _spread((9, 17), d1), _spread((9, 17), d2)
    if opname == "divide":
        b = np.where(b == 0, 1, b).astype(b.dtype)
    try:
        r = getattr(ref, opname)(a, b, scale=scale, dtype=dtype)
    except ref.error:
        with pytest.raises(sr.error):
            getattr(sr, opname)(a, b, scale=scale, dtype=dtype)
        return
    s = getattr(sr, opname)(a, b, scale=scale, dtype=dtype)
    assert s.dtype == r.dtype and s.shape == r.shape
    bad = ~((r == s) | (np.isnan(r.astype(np.float64)) & np.isnan(s.astype(np.float64))))
    assert not bad.any(), (f"{opname} {dtname(d1)} x {dtname(d2)} -> dtype {dtype}, scale {scale}: {int(bad.sum())}/{r.size} differ, "
                           f"first a={a[bad][0]} b={b[bad][0]} ref {r[bad][0]!r} got {s[bad][0]!r}")


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("cn", [1, 3])
def test_addweighted(dt, cn):
    a, b = rand((23, 31), dt, cn), rand((23, 31), dt, cn)
    both("addWeighted", a, 0.7, b, 0.3, 5.5)
    both("addWeighted", a, -1.25, b, 2.0, -20.0)
    both("addWeighted", a, 1.0, b, 1.0, 0.0, dtype=cvd(np.float32) if dt != np.float32 else 0)


def cvd(dt):
    return DEPTH_IDS[np.dtype(dt)]


@pytest.mark.parametrize("dt", [np.float32, np.float64])
def test_scaleadd(dt):
    a, b = rand((9, 21), dt, 3), rand((9, 21), dt, 3)
    both("scaleAdd", a, 0.37, b)
    both("scaleAdd", a, -2.0, b)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("a,b", [(1.0, 0.0), (0.5, 3.0), (-1.7, 10.2), (300.0, 0.0), (1.0, -200.0)])
def test_convertscaleabs(dt, a, b):
    x = rand((17, 31), dt, 3)
    both("convertScaleAbs", x, alpha=a, beta=b)


# --------------------------------------------------------------------------- bitwise / compare / min-max
@pytest.mark.parametrize("op", ["bitwise_and", "bitwise_or", "bitwise_xor"])
@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64], ids=dtname)
def test_bitwise_binary(op, dt):
    a, b = rand((13, 17), dt, 3), rand((13, 17), dt, 3)
    both(op, a, b)
    mask = (RNG.integers(0, 2, (13, 17)) * 255).astype(np.uint8)
    both(op, a, b, mask=mask)
    if dt == np.uint8:
        both(op, a, (3, 255, 7))


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
def test_bitwise_not(dt):
    a = rand((13, 17), dt, 3)
    both("bitwise_not", a)
    mask = (RNG.integers(0, 2, (13, 17)) * 255).astype(np.uint8)
    both("bitwise_not", a, mask=mask)


@pytest.mark.parametrize("op", [0, 1, 2, 3, 4, 5])
@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
def test_compare(op, dt):
    a, b = rand((13, 17), dt, 3), rand((13, 17), dt, 3)
    b.reshape(-1)[::3] = a.reshape(-1)[::3]
    both("compare", a, b, op)
    both("compare", a, 5, op)
    both("compare", 3.5, a, op)
    both("compare", a, (1, 2, 3), op)
    if dt == np.float32:
        a.reshape(-1)[2] = np.nan
        both("compare", a, b, op)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("cn", [1, 3, 4])
def test_inrange(dt, cn):
    a = rand((13, 17), dt, cn)
    lo, hi = (np.array([-5, 0, 10, 3][:cn]), np.array([50, 100, 90, 7][:cn]))
    both("inRange", a, tuple(lo.tolist()), tuple(hi.tolist()))
    both("inRange", a, 10, 60)
    both("inRange", a, np.full_like(a, 10), np.full_like(a, 60))
    both("inRange", a, rand((13, 17), dt, cn), rand((13, 17), dt, cn))


@pytest.mark.parametrize("op", ["min", "max"])
@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
def test_minmax_arrays(op, dt):
    a, b = rand((13, 17), dt, 3), rand((13, 17), dt, 3)
    both(op, a, b)
    both(op, a, 20)
    both(op, 20, a)
    dst = np.zeros_like(a)
    out = getattr(sr, op)(a, b, dst)
    assert out is dst


# --------------------------------------------------------------------------- math
@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("fn", ["sqrt", "exp", "log"])
def test_math_unary(fn, dt):
    a = rand((23, 31), dt, 3)
    if fn == "sqrt":
        a.reshape(-1)[::4] = np.abs(a.reshape(-1)[::4])
    if fn == "log":
        a = np.abs(a) + 1e-3
        a.reshape(-1)[::9] = 0
    if fn == "exp":
        a = a / 30
    both(fn, a)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("p", [2, 3, 0.5, -1.0, 2.5, 0, 1, -2, 4])
def test_pow_float(dt, p):
    a = np.abs(rand((13, 17), dt, 3)) + 0.1
    a.reshape(-1)[::7] *= -1
    both("pow", a, p)


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32])
@pytest.mark.parametrize("p", [2, 3, 0, 1, 0.5, -1.0, 1.5, 4])
def test_pow_int(dt, p):
    a = rand((11, 13), dt, 3)
    a = a.astype(np.int64)
    a = np.clip(a, -20, 40).astype(dt) if dt in (np.int8, np.int16, np.int32) else np.clip(a, 0, 40).astype(dt)
    both("pow", a, p)
    b = rand((11, 13), dt, 3)
    both("pow", b, 2)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("deg", [False, True])
def test_polar(dt, deg):
    x, y = rand((19, 27), dt), rand((19, 27), dt)
    x.reshape(-1)[0] = 0
    y.reshape(-1)[0] = 0
    both("magnitude", x, y)
    both("phase", x, y, angleInDegrees=deg)
    both("cartToPolar", x, y, angleInDegrees=deg)
    m, ang = ref.cartToPolar(x, y, angleInDegrees=deg)
    both("polarToCart", m, ang, angleInDegrees=deg)


def test_fastatan2_cuberoot():
    for y, x in [(1.0, 1.0), (-3.0, 2.0), (0.0, -1.0), (0.0, 0.0), (5.0, 0.0), (-5.0, -5.0)]:
        both("fastAtan2", y, x)
    for v in [8.0, -27.0, 0.0, 2.0, 1e-3]:
        both("cubeRoot", v)


def test_checkrange_patchnans_finitemask():
    a = rand((9, 11), np.float32, 1)
    a.reshape(-1)[5] = np.nan
    a.reshape(-1)[7] = np.inf
    both("checkRange", a)
    b = rand((9, 11), np.float32, 1)
    both("checkRange", b)
    both("checkRange", b, True, -1000.0, 1000.0)
    both("checkRange", b, True, -10.0, 10.0)
    both("patchNaNs", a, 3.5)
    both("finiteMask", a)
    c = rand((9, 11), np.int16)
    both("checkRange", c)
    both("checkRange", c, True, -10.0, 10.0)


# --------------------------------------------------------------------------- LUT
@pytest.mark.parametrize("sdt", [np.uint8, np.int8])
@pytest.mark.parametrize("ddt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("lut_cn,src_cn", [(1, 1), (1, 3), (3, 3)])
def test_lut(sdt, ddt, lut_cn, src_cn):
    a = rand((17, 23), sdt, src_cn)
    lut = rand((256,), ddt, lut_cn) if lut_cn == 1 else rand((256,), ddt, lut_cn)
    lut = lut.reshape(256, 1) if lut_cn == 1 else lut.reshape(256, 1, lut_cn)
    both("LUT", a, lut)
    both("LUT", a, lut.reshape(1, 256, -1).squeeze() if lut_cn == 1 else lut.reshape(1, 256, lut_cn))


# --------------------------------------------------------------------------- reductions
@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("rtype", [0, 1, 2, 3])
@pytest.mark.parametrize("dim", [0, 1])
@pytest.mark.parametrize("cn", [1, 3])
def test_reduce(dt, rtype, dim, cn):
    a = rand((13, 17), dt, cn)
    both("reduce", a, dim, rtype)
    for out in (np.float32, np.float64, np.int32):
        both("reduce", a, dim, rtype, dtype=cvd(out))
    both("reduce", a, dim, rtype, dtype=cvd(dt))


@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.float32, np.int32])
@pytest.mark.parametrize("fn", ["reduceArgMax", "reduceArgMin"])
@pytest.mark.parametrize("axis", [0, 1])
@pytest.mark.parametrize("last", [False, True])
def test_reduce_arg(fn, dt, axis, last):
    a = RNG.integers(0, 4, (13, 17)).astype(dt)
    both(fn, a, axis, last)


# NORM_INF=1, L1=2, L2=4, L2SQR=5, HAMMING=6, HAMMING2=7, RELATIVE=8, MINMAX=32. Invalid types and flags must raise
# exactly when the reference raises (both() asserts that), valid ones must agree.
@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("nt", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 16, 17, 18, 20, 32, 33, 36, 40])
@pytest.mark.parametrize("cn", [1, 3])
def test_norm(dt, nt, cn):
    a = rand((13, 17), dt, cn)
    b = rand((13, 17), dt, cn)
    mask = (RNG.integers(0, 2, (13, 17)) * 255).astype(np.uint8)
    both("norm", a, nt)
    both("norm", a, nt, mask)
    both("norm", a, b, nt)
    both("norm", a, b, nt, mask)


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.int32, np.float32, np.float64], ids=dtname)
@pytest.mark.parametrize("nt", [1, 2, 4, 5, 1 | 8, 2 | 8, 4 | 8])
def test_norm_two_arrays_masks(dt, nt):
    a, b = rand((19, 23), dt, 3), rand((19, 23), dt, 3)
    mask = (RNG.integers(0, 2, (19, 23)) * 255).astype(np.uint8)
    both("norm", a, b, nt)
    both("norm", a, b, nt, mask)
    both("norm", a, nt, mask)


def test_norm_hamming():
    a, b = rand((9, 13), np.uint8, 3), rand((9, 13), np.uint8, 3)
    both("norm", a, b, 6)
    both("norm", a, b, 7)
    both("norm", a, 6)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("cn", [1, 2, 3, 4])
def test_mean_stddev_sum(dt, cn):
    a = rand((23, 29), dt, cn)
    mask = (RNG.integers(0, 2, (23, 29)) * 255).astype(np.uint8)
    both("mean", a)
    both("mean", a, mask)
    both("meanStdDev", a)
    both("meanStdDev", a, mask=mask)
    both("sumElems", a)
    both("mean", a, np.zeros((23, 29), np.uint8))
    both("meanStdDev", a, mask=np.zeros((23, 29), np.uint8))


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
def test_minmaxloc(dt):
    a = rand((23, 29), dt)
    mask = (RNG.integers(0, 2, (23, 29)) * 255).astype(np.uint8)
    both("minMaxLoc", a)
    both("minMaxLoc", a, mask)
    both("minMaxLoc", np.zeros((5, 5), dt))
    b = RNG.integers(0, 3, (23, 29)).astype(dt)  # many ties -> first occurrence rule
    both("minMaxLoc", b)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
def test_nonzero(dt):
    a = RNG.integers(0, 3, (23, 29)).astype(dt)
    both("countNonZero", a)
    both("hasNonZero", a)
    both("findNonZero", a)
    z = np.zeros((7, 9), dt)
    both("countNonZero", z)
    both("hasNonZero", z)
    both("findNonZero", z)
    both("countNonZero", a[:, :11].copy())


def test_countnonzero_multichannel_error():
    both("countNonZero", rand((5, 5), np.uint8, 3))


# --------------------------------------------------------------------------- structure
@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("cn", [1, 2, 3, 4, 5])
def test_split_merge(dt, cn):
    a = rand((9, 11), dt, cn)
    r = both("split", a)
    both("merge", list(ref.split(a)))
    both("merge", tuple(ref.split(a)))


def test_split_dst_and_merge_errors():
    a = rand((5, 5), np.uint8, 3)
    both("merge", [a[..., 0].copy(), rand((5, 6), np.uint8)])
    both("merge", [rand((5, 5), np.uint8), rand((5, 5), np.int16)])


@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.float32, np.float64])
def test_mixchannels_extract_insert(dt):
    a = rand((9, 11), dt, 4)
    b = rand((9, 11), dt, 3)
    both("mixChannels", [a], [b.copy()], [3, 0, 2, 1, 0, 2])
    both("mixChannels", [a, b], [np.zeros((9, 11, 5), dt)], [0, 0, 1, 1, 4, 2, 5, 3, 6, 4])
    both("mixChannels", [a], [np.zeros((9, 11), dt), np.zeros((9, 11), dt)], [1, 0, 2, 1])
    for c in range(4):
        both("extractChannel", a, c)
        both("insertChannel", rand((9, 11), dt), a.copy(), c)
    both("extractChannel", a, 4)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("cn", [1, 3, 4])
@pytest.mark.parametrize("shape", [(1, 1), (7, 5), (37, 53)])
def test_flip_rotate_transpose(dt, cn, shape):
    a = rand(shape, dt, cn)
    for code in (-1, 0, 1):
        both("flip", a, code)
    for code in (0, 1, 2):
        both("rotate", a, code)
    both("transpose", a)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("cn", [1, 3])
def test_repeat_concat(dt, cn):
    a, b = rand((7, 5), dt, cn), rand((7, 9), dt, cn)
    both("repeat", a, 2, 3)
    both("repeat", a, 1, 1)
    both("hconcat", [a, b])
    both("vconcat", [a, rand((4, 5), dt, cn)])
    both("hconcat", (a, b, a))
    both("concat", [a, b], 1)
    both("concat", [a, rand((3, 5), dt, cn)], 0)


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64], ids=dtname)
@pytest.mark.parametrize("bt", [0, 1, 2, 3, 4, 5, 16 | 0])
@pytest.mark.parametrize("cn", [1, 3])
def test_copymakeborder(dt, bt, cn):
    a = rand((7, 9), dt, cn)
    both("copyMakeBorder", a, 2, 3, 4, 5, bt, value=(1, 2, 3, 4))
    both("copyMakeBorder", a, 12, 1, 0, 14, bt, value=7)
    both("copyMakeBorder", a, 0, 0, 0, 0, bt)


def test_border_interpolate():
    for bt in (0, 1, 2, 3, 4, 5):
        for p in (-12, -5, -1, 0, 3, 6, 7, 9, 20):
            both("borderInterpolate", p, 7, bt)
        both("borderInterpolate", 3, 1, bt)
        both("borderInterpolate", -3, 1, bt)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
@pytest.mark.parametrize("norm", [1, 2, 4])
def test_normalize(dt, norm):
    a = rand((13, 17), dt, 3)
    mask = (RNG.integers(0, 2, (13, 17)) * 255).astype(np.uint8)
    both("normalize", a, None, 1.0, 0.0, norm)
    both("normalize", a, None, 200.0, 0.0, norm)
    both("normalize", a, None, 1.0, 0.0, norm, mask=mask)
    both("normalize", a, None, 1.0, 0.0, norm, dtype=5)


@pytest.mark.parametrize("dt", DEPTHS, ids=dtname)
def test_normalize_minmax(dt):
    a = rand((13, 17), dt, 3)
    mask = (RNG.integers(0, 2, (13, 17)) * 255).astype(np.uint8)
    for al, be in [(0, 255), (0, 1), (-1, 1), (10, 5), (255, 0)]:
        both("normalize", a, None, al, be, 32)
        both("normalize", a, None, al, be, 32, dtype=5)
        both("normalize", a, None, al, be, 32, dtype=0)
        both("normalize", a, None, al, be, 32, mask=mask)
    both("normalize", np.full((5, 5), 7, dt), None, 0, 255, 32)
    both("normalize", np.zeros((5, 5), dt), None, 1, 0, 4)


@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.int32, np.float32, np.float64], ids=dtname)
@pytest.mark.parametrize("flags", [0, 1, 16, 17, 1 | 0 | 16])
def test_sort(dt, flags):
    a = rand((7, 11), dt)
    both("sort", a, flags)
    both("sortIdx", a, flags)
    both("sort", RNG.integers(0, 3, (7, 11)).astype(dt), flags)


def test_sort_errors():
    both("sort", rand((4, 4), np.uint8, 3), 0)
    both("sort", rand((4, 4), np.uint8), 3)


@pytest.mark.parametrize("dt", [np.float32, np.float64, np.int32, np.uint8])
def test_matrix_helpers(dt):
    a = rand((6, 6), dt)
    both("setIdentity", a.copy())
    both("setIdentity", a.copy(), 3)
    both("setIdentity", rand((4, 7), dt), 2)
    both("completeSymm", a.copy())
    both("completeSymm", a.copy(), True)
    both("trace", a)
    both("trace", rand((4, 7), dt))
    both("trace", rand((3, 3), dt, 3))
    if dt in (np.float32, np.float64):
        for n in (1, 2, 3, 4, 5, 6):
            m = RNG.uniform(-3, 3, (n, n)).astype(dt)
            both("determinant", m)
        both("determinant", np.zeros((3, 3), dt))


def test_getoptimaldftsize():
    for n in list(range(0, 200)) + [1000, 1023, 1024, 1025, 4000, 2147483, 100000]:
        both("getOptimalDFTSize", n)


# --------------------------------------------------------------------------- 5.x ND helpers and misc
def test_nd_helpers():
    a = rand((4, 5), np.float32, 3)
    both("flatten", a)
    both("reshape", a, (2, 30))
    both("transposeND", rand((3, 4, 5), np.int16), [2, 0, 1])
    both("flipND", rand((3, 4, 5), np.int16), 1)
    both("squeeze", rand((1, 4, 1), np.int16))
    both("unsqueeze", rand((4, 5), np.int16), [0])
    both("broadcast", rand((1, 5), np.int16), (4, 5))
    both("slice", rand((6, 7), np.int16), [1, 2], [5, 6], [1, 2])
    both("copyTo", rand((6, 7), np.uint8, 3), (RNG.integers(0, 2, (6, 7)) * 255).astype(np.uint8))


def test_system_info():
    assert sr.getNumberOfCPUs() == ref.getNumberOfCPUs() or sr.getNumberOfCPUs() >= 1
    assert sr.getVersionMajor() == 5 and sr.getVersionMinor() == ref.getVersionMinor()
    assert isinstance(sr.getVersionString(), str)
    assert sr.getTickFrequency() > 0
    t0 = sr.getTickCount()
    t1 = sr.getTickCount()
    assert t1 >= t0
    assert sr.useOptimized() in (True, False)
    assert isinstance(sr.getCPUTickCount(), int)
    assert sr.getThreadNum() == 0


# --------------------------------------------------------------------------- random
@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64], ids=dtname)
def test_randu_stream_matches_opencv(dt):
    for seed in (0, 1, 12345, 2147483647, -1):  # cv2.setRNGSeed takes a C int
        ref.setRNGSeed(seed)
        sr.setRNGSeed(seed)
        a = np.zeros((11, 13, 3), dt)
        b = np.zeros((11, 13, 3), dt)
        lo, hi = ((0, 256) if dt != np.float32 and dt != np.float64 else (-3.5, 9.25))
        r = ref.randu(a, lo, hi)
        s = sr.randu(b, lo, hi)
        _same(r, s, "randu")
        r2 = ref.randu(a, (1, 2, 3), (10, 200, 300))  # second draw continues the stream
        s2 = sr.randu(b, (1, 2, 3), (10, 200, 300))
        _same(r2, s2, "randu2")


@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.int32, np.float32, np.float64], ids=dtname)
def test_randn_stream_matches_opencv(dt):
    ref.setRNGSeed(7)
    sr.setRNGSeed(7)
    a = np.zeros((11, 13, 3), dt)
    b = np.zeros((11, 13, 3), dt)
    r = ref.randn(a, 100.0 if dt != np.float32 else 0.5, 20.0)
    s = sr.randn(b, 100.0 if dt != np.float32 else 0.5, 20.0)
    _same(r, s, "randn")


def test_randshuffle_stream_matches_opencv():
    for dt in (np.uint8, np.int32, np.float32):
        ref.setRNGSeed(99)
        sr.setRNGSeed(99)
        a = np.arange(40).astype(dt).reshape(8, 5)
        r = ref.randShuffle(a.copy())
        s = sr.randShuffle(a.copy())
        _same(r, s, "randShuffle")
        a = np.arange(40).astype(dt).reshape(8, 5)
        ref.setRNGSeed(3)
        sr.setRNGSeed(3)
        _same(ref.randShuffle(a.copy(), 2.0), sr.randShuffle(a.copy(), 2.0), "randShuffle2")


# --------------------------------------------------------------------------- dst= / views / odd layouts
def test_dst_in_place_and_views():
    a = rand((20, 30, 3), np.uint8)
    b = rand((20, 30, 3), np.uint8)
    big = np.zeros((40, 60, 3), np.uint8)
    view = big[5:25, 7:37]
    out = sr.add(a, b, view)
    assert out is view or np.shares_memory(out, big)
    _same(ref.add(a, b), np.ascontiguousarray(view), "add view")
    # non-contiguous inputs (strided view / transposed)
    c = rand((30, 20, 3), np.uint8).transpose(1, 0, 2)
    both("add", a, c)
    both("absdiff", a[::2], b[::2])
    both("flip", a[:, ::2], 1)
    both("split", a[::-1])
    both("mean", a[:, 3:17])


def test_large_frame_u8():
    a, b = rand((1080, 1920), np.uint8, 3, edge=False), rand((1080, 1920), np.uint8, 3, edge=False)
    for op in ("add", "subtract", "absdiff", "bitwise_and", "min", "max"):
        both(op, a, b)
    both("addWeighted", a, 0.5, b, 0.5, 0)
    both("compare", a, b, 2)
    both("mean", a)
    both("meanStdDev", a)
    both("norm", a, b, 2)
    both("countNonZero", a[..., 0].copy())
    both("minMaxLoc", a[..., 1].copy())
    both("flip", a, 1)
    both("rotate", a, 0)
    both("transpose", a)
    both("split", a)
    both("convertScaleAbs", a, alpha=1.3, beta=-10)
    both("reduce", a, 0, 2, dtype=5)
    both("LUT", a, np.arange(255, -1, -1).astype(np.uint8).reshape(256, 1))
    both("copyMakeBorder", a, 10, 10, 10, 10, 4)


def test_large_frame_f32():
    a, b = rand((1080, 1920), np.float32, 3, edge=False), rand((1080, 1920), np.float32, 3, edge=False)
    for op in ("add", "subtract", "absdiff", "multiply", "min", "max"):
        both(op, a, b)
    both("addWeighted", a, 0.5, b, 0.5, 1.0)
    both("sqrt", np.abs(a))
    both("magnitude", a[..., 0].copy(), a[..., 1].copy())
    both("normalize", a, None, 0, 1, 32)
    both("minMaxLoc", a[..., 0].copy())
    both("meanStdDev", a)


# --------------------------------------------------------------------------- RNG: block boundaries, small ranges, tails
@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64], ids=dtname)
@pytest.mark.parametrize("shape", [(5, 7), (1, 1), (37, 53), (40, 31, 3), (30, 50, 4), (21, 27, 2), (100, 100)])
@pytest.mark.parametrize("rng_range", [(0, 16), (0, 256), (-100, 100), (5, 20), (0, 1000), (0, 70000), (-2.5, 7.5)])
def test_randu_grid(dt, shape, rng_range):
    lo, hi = rng_range
    ref.setRNGSeed(3)
    sr.setRNGSeed(3)
    a = np.zeros(shape, dt)
    b = np.zeros(shape, dt)
    _same(ref.randu(a, lo, hi), sr.randu(b, lo, hi), "randu grid")
    _same(ref.randu(a, (lo, lo + 1, lo + 2, lo + 3), (hi, hi + 5, hi + 10, hi + 15)),
          sr.randu(b, (lo, lo + 1, lo + 2, lo + 3), (hi, hi + 5, hi + 10, hi + 15)), "randu grid per-channel")


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64], ids=dtname)
@pytest.mark.parametrize("shape", [(37, 53), (40, 31, 3), (100, 100)])
def test_randn_grid(dt, shape):
    for mean, std in ((0.0, 1.0), (100.0, 20.0), (-3.0, 0.25), (127.0, 60.0)):
        ref.setRNGSeed(11)
        sr.setRNGSeed(11)
        a = np.zeros(shape, dt)
        b = np.zeros(shape, dt)
        _same(ref.randn(a, mean, std), sr.randn(b, mean, std), "randn grid")


def test_rng_sequence_continues_across_calls():
    ref.setRNGSeed(21)
    sr.setRNGSeed(21)
    for dt in (np.uint8, np.float32, np.int16):
        a = np.zeros((9, 11), dt)
        b = np.zeros((9, 11), dt)
        _same(ref.randu(a, 0, 100), sr.randu(b, 0, 100), "seq randu")
        _same(ref.randn(a, 50, 5), sr.randn(b, 50, 5), "seq randn")
        _same(ref.randShuffle(a.copy()), sr.randShuffle(b.copy()), "seq shuffle")


def test_randshuffle_pixels():
    for cn in (1, 3):
        for n in (1, 2, 33):
            shape = (n, 7, cn) if cn > 1 else (n, 7)
            a = np.arange(int(np.prod(shape)), dtype=np.int16).reshape(shape)
            ref.setRNGSeed(5)
            sr.setRNGSeed(5)
            _same(ref.randShuffle(a.copy()), sr.randShuffle(a.copy()), "shuffle pixels")


# --------------------------------------------------------------------------- reviewer round: memory safety, aliasing, NaN, empties, 1-D
def _strided3(shape, dt, cn=3):
    """Non-contiguous inputs: a column-strided view, a transposed view and a channel-reversed view."""
    base = rand((shape[0], shape[1] * 2, cn), dt)
    return [base[:, ::2], rand((shape[1], shape[0], cn), dt).transpose(1, 0, 2), rand(shape + (cn,), dt)[..., ::-1]]


BINARY_NOARGS = ["add", "subtract", "absdiff", "multiply", "divide", "bitwise_and", "bitwise_or", "bitwise_xor", "min", "max"]


@pytest.mark.parametrize("op", BINARY_NOARGS)
@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.float32])
def test_binary_ops_non_contiguous_operands(op, dt):
    for a in _strided3((11, 13), dt):
        for b in _strided3((11, 13), dt):
            assert a.shape == b.shape
            both(op, a, b)        # either operand strided: a temporary contiguous copy must stay alive during the call
            both(op, a, b.copy())
            both(op, a.copy(), b)


@pytest.mark.parametrize("dt", [np.uint8, np.float32])
def test_other_binary_ops_non_contiguous(dt):
    for a, b in zip(_strided3((11, 13), dt), _strided3((11, 13), dt)):
        both("compare", a, b, 1)
        both("addWeighted", a, 0.4, b, 0.6, 1.0)
        both("inRange", a, b, b)
        both("inRange", a, (1, 2, 3), (200, 100, 90))
        if dt == np.float32:
            both("scaleAdd", a, 0.5, b)
            both("magnitude", a, b)
            both("phase", a, b)
            both("cartToPolar", a, b)
            both("polarToCart", a, b)
        if dt == np.uint8:
            both("bitwise_and", a, (3, 255, 7))
        both("norm", a, b, 2)
        both("mean", a)
        both("split", a)
        both("merge", [a[..., 0], b[..., 1]])
        both("flip", a, 0)
        both("rotate", a, 1)
        both("transpose", a)
        both("LUT", a.astype(np.uint8) if dt != np.uint8 else a, np.arange(256, dtype=np.uint8).reshape(256, 1))
        both("copyMakeBorder", a, 1, 2, 3, 4, 1)
        both("minMaxLoc", a[..., 0])
        both("countNonZero", a[..., 0])
        both("reduce", a, 0, 0, dtype=6)


@pytest.mark.parametrize("op", ["add", "subtract", "absdiff", "multiply", "bitwise_and", "min", "max"])
def test_dst_aliases_src(op):
    for dt in (np.uint8, np.int16, np.float32):
        a, b = rand((9, 21), dt, 3), rand((9, 21), dt, 3)
        r = getattr(ref, op)(a.copy(), b.copy())
        a1, b1 = a.copy(), b.copy()
        out = getattr(sr, op)(a1, b1, a1)       # dst is src1
        assert out is a1
        _same(r, a1, f"{op} dst=src1")
        a2, b2 = a.copy(), b.copy()
        out = getattr(sr, op)(a2, b2, b2)       # dst is src2
        assert out is b2
        _same(r, b2, f"{op} dst=src2")


def test_dst_aliases_src_other():
    for dt in (np.uint8, np.float32):
        a = rand((9, 21), dt, 3)
        for code in (-1, 0, 1):
            x = a.copy()
            _same(ref.flip(a.copy(), code), sr.flip(x, code, x), f"flip in place {code}")
        x = a.copy()
        _same(ref.bitwise_not(a.copy()), sr.bitwise_not(x, x), "bitwise_not in place")
        x = a.copy()
        _same(ref.addWeighted(a.copy(), .3, a.copy(), .7, 1), sr.addWeighted(x, .3, x, .7, 1, x), "addWeighted in place")
        x = a.copy()
        _same(ref.convertScaleAbs(a.copy(), None, 2, 3), sr.convertScaleAbs(x, x, 2, 3) if dt == np.uint8 else sr.convertScaleAbs(x, None, 2, 3), "csa")
        sq = rand((8, 8), dt, 1)
        x = sq.copy()
        _same(ref.transpose(sq.copy()), sr.transpose(x, x), "transpose square in place")
        x = sq.copy()
        _same(ref.rotate(sq.copy(), 0), sr.rotate(x, 0, x), "rotate in place")
    f = rand((9, 21), np.float32, 1)
    for fn in ("sqrt", "exp", "log"):
        x = np.abs(f) + 1
        _same(getattr(ref, fn)(x.copy()), getattr(sr, fn)(x, x), f"{fn} in place")


NAN_F = np.array([[np.nan, 1, 2, 3], [4, 5, np.nan, 7], [8, 9, 10, 11]], np.float32)


def test_nan_handling():
    for arr in (NAN_F, NAN_F.astype(np.float64), np.full((3, 4), np.nan, np.float32), NAN_F[::-1].copy(), NAN_F.T.copy()):
        r = ref.minMaxLoc(arr)
        s = sr.minMaxLoc(arr)
        assert np.isnan(r[0]) == np.isnan(s[0]) and np.isnan(r[1]) == np.isnan(s[1]), (r, s)
        if arr is NAN_F:
            assert r[2:] == s[2:], (r, s)   # lead NaN: location is the first element (elsewhere cv2's location is SIMD-lane dependent)
    for a_, b_ in ((NAN_F, NAN_F.copy()), (NAN_F, np.zeros_like(NAN_F))):
        for op in range(6):
            both("compare", a_, b_, op)
        both("compare", a_, 3.0, 1)
        both("inRange", a_, 1.0, 9.0)
        both("countNonZero", a_)
        both("checkRange", a_)
        both("finiteMask", a_)
        both("patchNaNs", a_.copy(), 2.5)
    both("max", NAN_F, 3.0)
    both("min", NAN_F, 3.0)
    both("sqrt", NAN_F)
    both("convertScaleAbs", NAN_F, None, 2.0, 1.0)
    both("normalize", np.nan_to_num(NAN_F), None, 0, 1, 32)
    both("add", NAN_F, 1.0)
    both("add", NAN_F, NAN_F, dtype=0)
    both("multiply", NAN_F, NAN_F, dtype=3)


@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.float32, np.float64])
def test_empty_inputs(dt):
    for shp in ((0, 5), (5, 0), (0, 0)):
        e = np.zeros(shp, dt)
        for fn, args in (("mean", ()), ("norm", ()), ("countNonZero", ()), ("sumElems", ()),
                         ("flip", (1,)), ("hasNonZero", ())):
            both(fn, e, *args)
        if dt == np.uint8:
            both("minMaxLoc", e)   # for other depths cv2 returns uninitialised garbage on empty input
        both("copyMakeBorder", e, 1, 1, 1, 1, 0)
        both("reduce", e, 0, 0, dtype=6)
        if dt != np.uint8:
            both("reduce", e, 1, 3)
        both("sort", e, 0)
        both("transpose", e)
        both("split", np.zeros(shp + (3,), dt))
    both("borderInterpolate", -1, 0, 0)


def test_one_dimensional_inputs():
    for dt in (np.uint8, np.int32, np.float32, np.float64):
        v = rand((7,), dt)
        both("minMaxLoc", v)
        both("mean", v)
        both("norm", v)
        both("countNonZero", v)
        both("sumElems", v)
        both("flip", v, 0)
        both("flip", v, 1)
        ref.setRNGSeed(4)
        sr.setRNGSeed(4)
        a = np.zeros(11, dt)
        b = np.zeros(11, dt)
        r1 = ref.randu(a, 0, 100)
        r2 = sr.randu(b, 0, 100)
        _same(r1, r2, "randu 1-D")
        assert b.shape == (11,)
        _same(ref.randn(a, 5, 2), sr.randn(b, 5, 2), "randn 1-D")
        _same(ref.randShuffle(a.copy()), sr.randShuffle(b.copy()), "randShuffle 1-D")


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32, np.float32, np.float64], ids=dtname)
@pytest.mark.parametrize("rng_range", [(0, float("inf")), (float("nan"), 5), (0, 1e30), (0, 2.0 ** 32), (-2.0 ** 31, 2.0 ** 31),
                                       (0, 2.0 ** 33), (5, 5), (7, 3), (-1e30, 1e30), (float("-inf"), float("inf"))])
def test_randu_extreme_ranges_never_trap(dt, rng_range):
    lo, hi = rng_range
    ref.setRNGSeed(1)
    sr.setRNGSeed(1)
    a = np.zeros((3, 5), dt)
    b = np.zeros((3, 5), dt)
    r = ref.randu(a, lo, hi)
    s = sr.randu(b, lo, hi)   # must neither crash the process nor raise
    assert s.shape == r.shape and s.dtype == r.dtype
    in_int32 = all(np.isfinite(v) and -2.0 ** 31 <= v <= 2.0 ** 31 for v in (lo, hi))
    if in_int32 or not np.isfinite(lo) and np.isnan(lo):
        # bounds representable as C int: the stream must equal cv2's value for value
        _same(r, s, "randu extreme")
    elif dt in (np.float32, np.float64):
        pass   # float outputs from inf/1e30 bounds: NaN/inf patterns are not meaningfully specified by cv2 either


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32], ids=dtname)
@pytest.mark.parametrize("p", [2, 3, 4, 5, 8, 9, -1, -2, -3])
def test_pow_integer_wrap(dt, p):
    info = np.iinfo(dt)
    x = np.array([[0, 1, 2, 3, 4, 5, 10, 15, 16, 31, 32, 100, 255, 256, 1000, 1290, 1291, 46340, 46341, 65535,
                   info.max, info.min, -2, -3, -33, -100]], np.int64)
    x = np.clip(x, info.min, info.max).astype(dt)
    both("pow", x, p)


def test_pow_f32_integer_powers_match_double_rounding():
    x = np.array([[1.0000001, 1.1, 2.3, -1.7, 3.3, 0.0, 1e10, 1e-10]], np.float32)
    for p in (2, 3, 4, 5, 7, 9, 10, -1, -2, -3, 0.5, 2.5):
        both("pow", x, p)


@pytest.mark.parametrize("cn", [1, 2, 3, 4])
@pytest.mark.parametrize("width", [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 33, 64, 100, 257])
@pytest.mark.parametrize("dim", [0, 1])
def test_reduce_float_sum_order_is_bit_exact(cn, width, dim):
    for dt in (np.float32, np.float64):
        a = RNG.uniform(-300, 300, (13, width, cn) if cn > 1 else (13, width)).astype(dt)
        for rt in (0, 1):
            r = ref.reduce(a, dim, rt)
            s = sr.reduce(a, dim, rt)
            assert r.shape == s.shape and r.dtype == s.dtype
            if rt == 0:
                assert np.array_equal(r, s), f"{dt.__name__} cn={cn} w={width} dim={dim}: not bit exact"
            else:
                assert np.allclose(r, s, rtol=1e-6, atol=0)


@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.float32, np.float64])
def test_randn_float_formula_exact(dt):
    for mean, std in ((100.3, 20.7), (-3.5, 0.25), (0.0, 1.0)):
        ref.setRNGSeed(11)
        sr.setRNGSeed(11)
        a = np.zeros((50, 70), dt)
        b = np.zeros((50, 70), dt)
        ref.randn(a, mean, std)
        sr.randn(b, mean, std)
        assert np.array_equal(a, b), f"randn {dt.__name__} {mean},{std}: {int((a != b).sum())} differ"


def test_rng_state_is_per_thread():
    import threading
    out = {}

    def work(tag, seed):
        sr.setRNGSeed(seed)
        a = np.zeros((20, 20), np.uint8)
        out[tag] = sr.randu(a, 0, 256).copy()

    sr.setRNGSeed(5)
    main_expected = None
    a = np.zeros((20, 20), np.uint8)
    main_expected = sr.randu(a, 0, 256).copy()
    t = threading.Thread(target=work, args=("t", 99))
    sr.setRNGSeed(5)
    t.start()
    t.join()
    b = np.zeros((20, 20), np.uint8)
    main_after = sr.randu(b, 0, 256)
    assert np.array_equal(main_after, main_expected), "another thread's seeding changed this thread's stream"
    ref.setRNGSeed(99)
    c = np.zeros((20, 20), np.uint8)
    assert np.array_equal(out["t"], ref.randu(c, 0, 256))


@pytest.mark.parametrize("op", ["multiply", "divide", "add", "subtract", "absdiff"])
@pytest.mark.parametrize("dt", [np.uint8, np.int16, np.int32, np.float32, np.float64])
@pytest.mark.parametrize("scalar", [(0.3, -7.7, 100.25), (1.0 / 3.0, 2.0 / 3.0, 0.1), (255.4, 0.5, -0.5)])
def test_arith_fractional_scalars(op, dt, scalar):
    a = rand((37, 53), dt, 3)
    both(op, a, scalar)
    both(op, scalar, a)
    if op in ("multiply", "divide"):
        both(op, a, scalar, scale=0.7)


# --------------------------------------------------------------------------- second pass: NEON kernels, odd sizes, integer reduce order
@pytest.mark.parametrize("shape", [(33, 70), (5, 17), (64, 64), (1, 100), (100, 1), (17, 33)])
@pytest.mark.parametrize("dim", [0, 1])
@pytest.mark.parametrize("rt", [0, 1, 2, 3])
def test_reduce_u8_all_destinations_exact(shape, dim, rt):
    a = rand(shape, np.uint8, 1)
    a[:] = np.where(RNG.random(shape) < 0.3, 255, a)   # saturating sums stay far from u8 limits in the wider types
    for dtype in (-1, 0, 3, 4, 5, 6):
        both("reduce", a, dim, rt, dtype=dtype)


@pytest.mark.parametrize("dt", [np.int8, np.uint16, np.int16, np.int32])
@pytest.mark.parametrize("cn", [1, 3])
def test_reduce_integer_sums_are_exact(dt, cn):
    a = rand((41, 67), dt, cn)
    for dim in (0, 1):
        for rt in (0, 1, 2, 3):
            for dtype in (-1, 5, 6):
                both("reduce", a, dim, rt, dtype=dtype)


@pytest.mark.parametrize("cols", [1, 2, 15, 16, 17, 31, 47, 48, 49, 63, 64, 65, 255, 1000])
@pytest.mark.parametrize("cn", [1, 2, 3, 4])
def test_u8_sum_family_odd_widths(cols, cn):
    a = rand((7, cols), np.uint8, cn)
    a[0, :] = 255
    b = rand((7, cols), np.uint8, cn)
    both("mean", a)
    both("meanStdDev", a)
    both("sumElems", a)
    for nt in (1, 2, 4, 5):
        both("norm", a, nt)
        both("norm", a, b, nt)
    if cn == 1:
        both("minMaxLoc", a)
        both("countNonZero", a)
        both("reduce", a, 0, 2)
        both("reduce", a, 1, 3)


@pytest.mark.parametrize("shape", [(8, 8), (9, 17), (16, 40), (23, 8), (64, 64), (33, 31), (50, 13)])
@pytest.mark.parametrize("cn", [1, 3, 4])
@pytest.mark.parametrize("dt", [np.uint8, np.uint16, np.float32, np.float64])
def test_transpose_rotate_tiles(shape, cn, dt):
    a = rand(shape, dt, cn)
    both("transpose", a)
    for code in (0, 1, 2):
        both("rotate", a, code)
    for code in (-1, 0, 1):
        both("flip", a, code)


@pytest.mark.parametrize("n", [1, 15, 16, 17, 63, 64, 65, 1000, 4097])
@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.float32, np.float64])
def test_elementwise_kernels_odd_lengths(n, dt):
    a, b = rand((3, n), dt), rand((3, n), dt)
    for op in ("add", "subtract", "absdiff", "multiply", "min", "max"):
        both(op, a, b)
    both("multiply", a, b, scale=0.37)
    both("addWeighted", a, 0.3, b, 0.7, 2.0)
    both("convertScaleAbs", a, alpha=1.7, beta=-3)
    both("compare", a, b, 3)
    if dt in (np.float32, np.float64):
        both("divide", a, b)
        both("divide", a, b, scale=2.5)
    if dt == np.float32:
        both("sqrt", np.abs(a))
    both("add", a, 5)
    both("subtract", 5, a)
    both("absdiff", a, 5)


@pytest.mark.parametrize("shape", [(200, 301, 3), (50, 1030), (10, 10, 4), (33, 77, 2)])
@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16, np.int32])
def test_randu_int_big_arrays_all_modes(shape, dt):
    for lo, hi in ((0, 256), (0, 16), (3, 100), (-100, 100), (0, 65536), (0, 1000)):
        ref.setRNGSeed(17)
        sr.setRNGSeed(17)
        a, b = np.zeros(shape, dt), np.zeros(shape, dt)
        _same(ref.randu(a, lo, hi), sr.randu(b, lo, hi), "randu big")
    ref.setRNGSeed(17)
    sr.setRNGSeed(17)
    a, b = np.zeros(shape, dt), np.zeros(shape, dt)
    _same(ref.randn(a, 100, 30), sr.randn(b, 100, 30), "randn big")


@pytest.mark.parametrize("his", [(16, 65536, 65536), (65536, 65536, 16), (65536, 16, 65536), (16, 16, 65536), (65536, 65536, 256),
                                 (256, 65536, 65536), (65536, 256, 256), (2 ** 24, 2 ** 24, 200), (200, 2 ** 30, 2 ** 30)])
@pytest.mark.parametrize("dt", [np.uint16, np.int32, np.uint8])
def test_randu_small_mode_depends_on_last_channel(his, dt):
    ref.setRNGSeed(17)
    sr.setRNGSeed(17)
    a, b = np.zeros((9, 11, 3), dt), np.zeros((9, 11, 3), dt)
    _same(ref.randu(a, (0, 0, 0), his), sr.randu(b, (0, 0, 0), his), "randu small-mode rule")


# ----------------------------------------------------------------------------------------------------------------
# C bridge (cv2/_srcore.c): every call must behave exactly like the pure-Python (ctypes) implementation, including the
# error cases and the inputs the bridge hands back to Python. Skipped when the extension is not built / disabled
# (SAFARIUM_NO_SRCORE=1); the whole suite above then runs on the ctypes path, and otherwise on the bridge path.
# ----------------------------------------------------------------------------------------------------------------
import glob  # noqa: E402
import os  # noqa: E402

_CV2_DIR = Path(sr.__file__).resolve().parent
_BRIDGE_BUILT = bool(glob.glob(str(_CV2_DIR / "_srcore*.so")))
_BRIDGE_WANTED = _BRIDGE_BUILT and not os.environ.get("SAFARIUM_NO_SRCORE")


@pytest.mark.skipif(not _BRIDGE_WANTED, reason="_srcore extension not built (build_core.sh) or SAFARIUM_NO_SRCORE set")
def test_bridge_is_active_and_replaces_every_covered_function():
    core = sr._core
    assert core.fast is not None
    assert set(core._FAST_NAMES) >= {"add", "subtract", "absdiff", "multiply", "divide", "addWeighted", "convertScaleAbs", "bitwise_and",
                                      "bitwise_not", "compare", "inRange", "min", "max", "sqrt", "exp", "log", "pow", "magnitude", "LUT",
                                      "reduce", "norm", "mean", "meanStdDev", "minMaxLoc", "countNonZero", "split", "merge", "flip",
                                      "rotate", "transpose", "copyMakeBorder", "hconcat", "vconcat"}
    for n in core._FAST_NAMES:
        assert getattr(sr, n) is getattr(core.fast, n), n
        assert getattr(sr, n) is not core._py_core[n], n


def _bridge_cases():
    r = np.random.default_rng(5)
    u3 = r.integers(0, 256, (13, 17, 3), dtype=np.uint8)
    u3b = r.integers(0, 256, (13, 17, 3), dtype=np.uint8)
    u1 = u3[..., 0].copy()
    u1b = u3b[..., 0].copy()
    f1 = r.uniform(0.1, 3, (13, 17)).astype(np.float32)
    f1b = r.uniform(0.1, 3, (13, 17)).astype(np.float32)
    d3 = r.uniform(-3, 3, (13, 17, 3))
    s16 = r.integers(-30000, 30000, (13, 17), dtype=np.int16)
    mask = (u1 > 100).astype(np.uint8) * 255
    lut = np.arange(255, -1, -1).astype(np.uint8)
    cases = []

    def add(name, *args, **kw):
        cases.append((name, args, kw))

    for fn in ("add", "subtract", "absdiff", "multiply", "divide"):
        add(fn, u3, u3b)
        add(fn, u1, u1b)
        add(fn, f1, f1b)
        add(fn, d3, d3)
        add(fn, s16, s16)
        add(fn, u3, (5, 6, 7))
        add(fn, (5, 6, 7), u3)
        add(fn, u3, 5)
        add(fn, f1, 2.5)
        add(fn, u3, u3b, dst=np.zeros_like(u3))
        add(fn, u3, u3b, dst=np.zeros(u3.shape, np.float32))          # wrong dtype: replaced
        add(fn, u3, u3b, dst=np.zeros((3, 3), np.uint8))              # wrong shape: replaced
        add(fn, u3, u3b, dst=np.zeros(u3.shape, np.uint8))
        ro = np.zeros_like(u3)
        ro.flags.writeable = False
        add(fn, u3, u3b, dst=ro)
        add(fn, u3[::2], u3b[::2])                                   # row-strided views
        add(fn, u3[:, ::2], u3b[:, ::2])                             # column-strided views
        add(fn, u3[::-1], u3b)                                       # negative row stride
        add(fn, u3, u3b[..., :1])                                    # broadcasting (python path)
        add(fn, u3, u3b[:5])                                         # size mismatch -> error
        add(fn, u3, f1)                                              # type mismatch
        add(fn, u3, np.int64(5))                                     # numpy scalar
        add(fn, u3, [1, 2, 3])
        add(fn, np.zeros((0, 4), np.uint8), np.zeros((0, 4), np.uint8))
        add(fn, u3.astype(np.int64), u3b.astype(np.int64))
        add(fn, u3.astype(np.float16), u3b.astype(np.float16))
        add(fn, u1.reshape(13, 17, 1), u1b.reshape(13, 17, 1))
        add(fn, u3, u3b, None, mask)
        add(fn, u3, u3b, dtype=cvdepth(5))
        add(fn, src1=u3, src2=u3b)
        add(fn, u3, u3b, bogus=1)
        add(fn, u3)
        add(fn, 5, 6)
    add("multiply", f1, f1b, scale=2.5)
    add("multiply", u3, u3b, None, 0.25)
    add("divide", f1, f1b, scale=2)
    add("divide", 2.0, f1)
    add("addWeighted", u3, 0.7, u3b, 0.3, 2.0)
    add("addWeighted", f1, 1, f1b, 2, 0, dtype=-1)
    add("addWeighted", f1, 1, f1b, 2, 0, dtype=0)
    add("addWeighted", u3, 0.7, u3b[:3], 0.3, 2.0)
    add("addWeighted", u3, np.float32(0.7), u3b, 0.3, 2.0)
    add("addWeighted", u3, 0.7, u3b, 0.3, 2.0, np.zeros_like(u3))
    add("convertScaleAbs", u3)
    add("convertScaleAbs", f1, alpha=3, beta=-100)
    add("convertScaleAbs", s16, None, 0.01, 1)
    add("convertScaleAbs", d3, np.zeros(d3.shape, np.uint8))
    for fn in ("bitwise_and", "bitwise_or", "bitwise_xor"):
        add(fn, u3, u3b)
        add(fn, u1, u1b, mask=mask)
        add(fn, u3, (3, 4, 5))
        add(fn, f1, f1b)
        add(fn, u3, u3b, np.empty_like(u3))
    add("bitwise_not", u3)
    add("bitwise_not", f1)
    add("bitwise_not", u3, np.empty_like(u3))
    add("bitwise_not", u3, mask=mask)
    for op in range(6):
        add("compare", u3, u3b, op)
        add("compare", f1, 1.5, op)
        add("compare", 1.5, f1, op)
        add("compare", s16, (0, 5), op)
        add("compare", u3, u3b, op, np.zeros(u3.shape, np.uint8))
    add("compare", u3, u3b, 9)
    add("compare", u3, u3b, np.int64(2))
    add("inRange", u3, (10, 20, 30), (200, 210, 220))
    add("inRange", u1, 10, 200)
    add("inRange", f1, 0.5, 2.0)
    add("inRange", u3, u3, u3)
    add("inRange", u3, (1, 2, 3), (9, 9, 9), np.zeros(u3.shape[:2], np.uint8))
    for fn in ("min", "max"):
        add(fn, u3, u3b)
        add(fn, f1, f1b)
        add(fn, f1, 1.0)
        add(fn, 1.0, f1)
        add(fn, s16, s16[::-1].copy())
        add(fn, u3, u3b, dst=np.empty_like(u3))
    for fn in ("sqrt", "exp", "log"):
        add(fn, f1)
        add(fn, d3)
        add(fn, f1, np.empty_like(f1))
        add(fn, u3)
        add(fn, f1[::2])
    add("pow", f1, 2.5)
    add("pow", f1, 2)
    add("pow", u1, 2)
    add("pow", f1, np.float32(2))
    add("magnitude", f1, f1b)
    add("magnitude", d3, d3)
    add("magnitude", u3, u3b)
    add("magnitude", f1, f1b[:4])
    add("LUT", u3, lut)
    add("LUT", u1, lut.reshape(256, 1))
    add("LUT", u1, lut.astype(np.float32))
    add("LUT", u3, np.stack([lut, lut[::-1], lut], axis=1).reshape(256, 1, 3))
    add("LUT", u3, lut[::2])
    add("LUT", f1, lut)
    add("LUT", u1, lut, np.empty_like(u1))
    for dim in (0, 1):
        for rt in range(4):
            add("reduce", u1, dim, rt)
            add("reduce", f1, dim, rt)
            add("reduce", u3, dim, rt, dtype=5)
            add("reduce", d3, dim, rt)
            add("reduce", s16, dim, rt, dtype=6)
    add("reduce", u1, 2, 0)
    add("reduce", u1, 0, 7)
    add("reduce", f1, 0, 0, dtype=0)
    for nt in (1, 2, 4, 5, 6, 7, 8, 12):
        add("norm", u3, nt)
        add("norm", f1, f1b, nt)
        add("norm", u1, u1b, nt)
    add("norm", u3)
    add("norm", f1, f1b)
    add("norm", u3, u3b[:3])
    add("norm", u3, 4, mask)
    add("norm", u1, 4, mask)
    add("norm", u3, normType=1)
    add("mean", u3)
    add("mean", f1)
    add("mean", u1, mask)
    add("mean", u3, mask=mask)
    add("mean", np.zeros((3, 3, 5), np.uint8))
    add("meanStdDev", u3)
    add("meanStdDev", f1)
    add("meanStdDev", u1, mask=mask)
    add("meanStdDev", u3, mask=np.zeros_like(mask))
    add("meanStdDev", d3)
    add("meanStdDev", np.full((4, 4), 7, np.uint8))
    add("minMaxLoc", u1)
    add("minMaxLoc", f1)
    add("minMaxLoc", u1, mask)
    add("minMaxLoc", s16)
    add("minMaxLoc", u3)
    add("minMaxLoc", u1.reshape(-1))
    add("countNonZero", mask)
    add("countNonZero", f1)
    add("countNonZero", u3)
    add("split", u3)
    add("split", u3[:, :, ::-1])
    add("split", u1)
    add("split", np.zeros((3, 4, 9), np.uint8))
    add("split", f1.reshape(13, 17, 1))
    add("merge", [u1, u1b, u1])
    add("merge", (u1, u1b))
    add("merge", [f1, f1b, f1, f1b])
    add("merge", [u1, u1b, u1], np.empty((13, 17, 3), np.uint8))
    add("merge", [u1, f1])
    add("merge", [u1, u1b[:3]])
    add("merge", [u3, u1])
    add("merge", [u1])
    add("merge", u3)
    add("merge", [])
    for code in (0, 1, -1, 5):
        add("flip", u3, code)
        add("flip", f1, code)
        add("flip", u3, code, np.empty_like(u3))
    add("flip", u1.reshape(-1), 1)
    add("flip", u3[::2, ::3], 1)
    for code in (0, 1, 2, 3):
        add("rotate", u3, code)
        add("rotate", f1, code)
        add("rotate", u1, code, np.empty((17, 13) if code != 1 else (13, 17), np.uint8))
    add("transpose", u3)
    add("transpose", f1)
    add("transpose", d3)
    add("transpose", u1, np.empty((17, 13), np.uint8))
    add("transpose", np.zeros((0, 3), np.uint8))
    for bt in (0, 1, 2, 3, 4, 16 | 4, 9):
        add("copyMakeBorder", u3, 2, 3, 4, 5, bt)
        add("copyMakeBorder", f1, 1, 0, 0, 2, bt, value=2.5)
        add("copyMakeBorder", u3, 2, 2, 2, 2, bt, None, (1, 2, 3))
    add("copyMakeBorder", u3, 0, 0, 0, 0, 0)
    add("copyMakeBorder", u3, -1, 0, 0, 0, 0)
    add("copyMakeBorder", u3, 1, 1, 1, 1, 0, np.empty((15, 19, 3), np.uint8))
    add("copyMakeBorder", u3, 1, 1, 1, 1, 0, value=[1, 2, 3])
    add("copyMakeBorder", u3, 1.0, 1, 1, 1, 0)
    for fn in ("hconcat", "vconcat"):
        add(fn, [u3, u3b])
        add(fn, (u3, u3b, u3))
        add(fn, [u1, u1b])
        add(fn, [f1, f1b, f1])
        add(fn, [u3, u1])
        add(fn, [u3, f1.astype(np.uint8)[:, :, None].repeat(3, 2)])
        add(fn, [u3, u3b[:5]])
        add(fn, [u3])
        add(fn, [])
        add(fn, u3)
        add(fn, [u3[::2], u3b[::2]])
        add(fn, [u3, u3b], dst=np.empty((13, 34, 3) if fn == "hconcat" else (26, 17, 3), np.uint8))
        add(fn, [u3, u3b], dst=np.empty((3, 3), np.uint8))
        add(fn, [u3, u3b], dst=np.empty((13, 34, 3) if fn == "hconcat" else (26, 17, 3), np.float32))
        add(fn, src=[u3, u3b])
    return cases


def cvdepth(d):
    return d


def _outcome(fn, args, kw):
    try:
        return "ok", fn(*[a.copy() if isinstance(a, np.ndarray) else a for a in args], **kw)
    except Exception as exc:  # noqa: BLE001
        return "err", exc


def _deep_equal(x, y, label):
    if isinstance(x, (tuple, list)):
        assert type(x) is type(y) and len(x) == len(y), label
        for i, (p, q) in enumerate(zip(x, y)):
            _deep_equal(p, q, f"{label}[{i}]")
    elif isinstance(x, np.ndarray):
        assert isinstance(y, np.ndarray) and x.dtype == y.dtype and x.shape == y.shape, f"{label}: {getattr(y, 'dtype', y)} {getattr(y, 'shape', '')}"
        assert x.tobytes() == y.tobytes() or (x.dtype.kind == "f" and np.array_equal(x, y, equal_nan=True)), label
    elif isinstance(x, float):
        assert type(y) is float and (x == y or (x != x and y != y)) and np.signbit(x) == np.signbit(y), f"{label}: {x!r} vs {y!r}"
    else:
        assert type(x) is type(y) and x == y, f"{label}: {x!r} vs {y!r}"


@pytest.mark.skipif(not _BRIDGE_WANTED, reason="_srcore extension not built (build_core.sh) or SAFARIUM_NO_SRCORE set")
def test_bridge_matches_python_path_on_every_input_shape():
    core = sr._core
    n = 0
    for name, args, kw in _bridge_cases():
        want = _outcome(core._py_core[name], args, kw)
        got = _outcome(getattr(core.fast, name), args, kw)
        label = f"{name} {[getattr(a, 'shape', a) if not isinstance(a, list) else 'list' for a in args]} {kw if len(str(kw)) < 60 else '...'}"
        assert want[0] == got[0], f"{label}: python {want[0]} ({want[1]!r:.80}) vs bridge {got[0]} ({got[1]!r:.80})"
        if want[0] == "err":
            assert type(want[1]) is type(got[1]) and str(want[1]) == str(got[1]), f"{label}: {want[1]!r} vs {got[1]!r}"
        else:
            _deep_equal(want[1], got[1], label)
        n += 1
    assert n > 400


@pytest.mark.skipif(not _BRIDGE_WANTED, reason="_srcore extension not built (build_core.sh) or SAFARIUM_NO_SRCORE set")
def test_bridge_in_place_and_dst_identity():
    core = sr._core
    a = RNG.integers(0, 256, (9, 11, 3), dtype=np.uint8)
    b = RNG.integers(0, 256, (9, 11, 3), dtype=np.uint8)
    want = core._py_core["add"](a, b)
    out = np.zeros_like(a)
    assert core.fast.add(a, b, out) is out and np.array_equal(out, want)
    c = a.copy()
    assert core.fast.add(c, b, c) is c and np.array_equal(c, want)
    f = a.copy()
    assert core.fast.flip(f, 1, f) is f and np.array_equal(f, a[:, ::-1])
    assert core.fast.add(a, b, dst=out) is out
    assert core.fast.split(a)[0].flags.owndata or True
    # inputs must not be modified and no buffer export may leak (arrays stay resizable)
    z = np.arange(24, dtype=np.uint8).reshape(4, 6)
    core.fast.countNonZero(z)
    core.fast.add(z, z)
    z.resize((2, 12), refcheck=True)


# ----------------------------------------------------------------------------------------------------------------
# Phase 1b kernels: masked u8 sums, column sums beyond one u16 block, 4-row f32 row sums, pattern add/sub, f32 compare,
# vector exp, copyMakeBorder strips, tiled 1/3-byte transposes. Compared against the reference with exact integers.
# ----------------------------------------------------------------------------------------------------------------
def _mask_variants(rows, cols):
    r = np.random.default_rng(rows * 1000 + cols)
    yield "random255", (r.random((rows, cols)) > 0.5).astype(np.uint8) * 255
    yield "random_small_values", r.integers(0, 3, (rows, cols), dtype=np.uint8)
    yield "all_set", np.full((rows, cols), 255, np.uint8)
    yield "all_clear", np.zeros((rows, cols), np.uint8)
    yield "one_pixel", np.eye(rows, cols, dtype=np.uint8) * 7
    yield "s8_negative", r.integers(-128, 128, (rows, cols), dtype=np.int8)


@pytest.mark.parametrize("cn", [1, 2, 3, 4])
@pytest.mark.parametrize("shape", [(1, 1), (3, 15), (7, 16), (5, 17), (40, 333), (130, 70), (2, 4100)])
def test_masked_u8_mean_stddev_sum(cn, shape):
    a = rand(shape, np.uint8, cn)
    for label, m in _mask_variants(*shape):
        both("mean", a, m)
        both("meanStdDev", a, mask=m)
    both("meanStdDev", np.full(shape + ((cn,) if cn > 1 else ()), 255, np.uint8), mask=np.full(shape, 255, np.uint8))


@pytest.mark.parametrize("shape", [(1, 70), (255, 64), (256, 64), (257, 64), (513, 131), (300, 16), (1000, 17), (3, 1), (600, 15), (2, 1920)])
@pytest.mark.parametrize("rt,dtype", [(0, 4), (0, 5), (0, 6), (1, 5), (1, 6), (1, 4)])
def test_reduce_u8_columns_cross_u16_block_boundary(shape, rt, dtype):
    a = np.full(shape, 255, np.uint8) if shape[0] % 2 else rand(shape, np.uint8, 1)
    for dim in (0, 1):
        both("reduce", a, dim, rt, dtype=dtype)
    view = np.ascontiguousarray(rand((shape[0], shape[1] + 9), np.uint8, 1))[:, 3:3 + shape[1]]   # row stride != width
    both("reduce", view, 0, 0, dtype=5)


@pytest.mark.parametrize("shape", [(1, 1), (3, 5), (4, 16), (5, 17), (9, 1030), (33, 1920), (7, 4097)])
@pytest.mark.parametrize("rt", [0, 1])
def test_reduce_f32_rows_bit_exact_incl_strided_dst(shape, rt):
    a = (RNG.standard_normal(shape) * 1000).astype(np.float32)
    r = ref.reduce(a, 1, rt)
    s = sr.reduce(a, 1, rt)
    assert s.dtype == r.dtype and s.shape == r.shape and s.tobytes() == r.tobytes()
    store = np.zeros((shape[0], 2), np.float32)       # non-packed destination column
    out = store[:, 0:1]
    r2 = ref.reduce(a, 1, rt, dst=np.zeros((shape[0], 1), np.float32))
    s2 = sr.reduce(a, 1, rt, dst=out)
    assert np.array_equal(r2, s2)


@pytest.mark.parametrize("dt", [np.uint8, np.int8, np.uint16, np.int16])
@pytest.mark.parametrize("cn", [1, 2, 3, 4])
@pytest.mark.parametrize("w", [1, 2, 3, 5, 7, 8, 15, 16, 17, 31, 33, 47, 49, 100])
@pytest.mark.parametrize("op", ["add", "subtract", "absdiff"])
def test_scalar_pattern_kernels_every_width(op, dt, cn, w, dt_ids=None):
    a = rand((3, w), dt, cn)
    info = np.iinfo(dt)
    sc = tuple(int(v) for v in RNG.integers(info.min, info.max, 4, endpoint=True))
    both(op, a, sc)
    both(op, sc, a)
    both(op, a, (info.max, info.min, 0, 1))


@pytest.mark.parametrize("op", range(6))
@pytest.mark.parametrize("n", [1, 3, 15, 16, 17, 63, 1000])
def test_compare_f32_and_u8_kernels_with_nan(op, n):
    a = (RNG.integers(-2, 3, n)).astype(np.float32)
    b = (RNG.integers(-2, 3, n)).astype(np.float32)
    a[::5] = np.nan
    b[::7] = np.nan
    both("compare", a.reshape(1, n), b.reshape(1, n), op)
    if n > 1:   # a 1x1 array against a scalar is broadcast to the scalar's 4x1 shape by cv2: a separate quirk, not exercised here
        both("compare", a.reshape(1, n), 1.0, op)
        both("compare", a.reshape(1, n), float("nan"), op)
        both("compare", 0.0, a.reshape(1, n), op)
    u, v = RNG.integers(0, 4, (2, 5, n), dtype=np.uint8)
    both("compare", u, v, op)


def test_exp_f32_full_range_ulp_level():
    x = np.concatenate([np.linspace(-110, 110, 200001), RNG.uniform(-5, 5, 100000), [0.0, -0.0, 88.72, 88.73, -87.3, -87.4, -103.9, -104.0, 1e-30, -1e-30,
                                                                                  np.inf, -np.inf, np.nan, 709.0, -709.0, 1e30, -1e30]]).astype(np.float32).reshape(1, -1)
    r, s = ref.exp(x), sr.exp(x)
    assert np.array_equal(np.isnan(r), np.isnan(s)) and np.array_equal(np.isinf(r), np.isinf(s))
    ok = np.isfinite(r) & (r > 1.2e-38)
    rel = np.abs(r[ok].astype(np.float64) - s[ok].astype(np.float64)) / r[ok].astype(np.float64)
    assert rel.max() < 4e-7, rel.max()
    d = ~ok & np.isfinite(r)
    assert np.all(np.abs(r[d].astype(np.float64) - s[d].astype(np.float64)) < 1e-37)
    y = x.copy()
    z = sr.exp(y, y)   # in place
    assert z is y and np.array_equal(np.isnan(z), np.isnan(s))


@pytest.mark.parametrize("dt,cn", [(np.uint8, 1), (np.uint8, 3), (np.uint8, 4), (np.uint16, 3), (np.float32, 1), (np.float32, 3), (np.float64, 4), (np.int16, 2),
                                   (np.float32, 5)])
@pytest.mark.parametrize("bt", [0, 1, 2, 3, 4])
@pytest.mark.parametrize("borders", [(1, 1, 1, 1), (0, 5, 0, 5), (20, 20, 20, 20), (7, 0, 13, 2), (3, 40, 41, 0)])
@pytest.mark.parametrize("shape", [(1, 1), (2, 3), (9, 14)])
def test_copymakeborder_borders_larger_than_the_image(dt, cn, bt, borders, shape):
    a = rand(shape, dt, cn)
    both("copyMakeBorder", a, *borders, bt, value=(1, 2, 3, 4))
    both("copyMakeBorder", a, *borders, bt, value=(5, 5, 5, 5))


@pytest.mark.parametrize("shape", [(64, 64), (65, 130), (130, 65), (200, 331), (8, 9), (9, 8), (127, 63), (192, 192), (1, 100), (100, 1), (7, 7)])
@pytest.mark.parametrize("cn", [1, 3])
def test_tiled_transpose_and_rotate_u8(shape, cn):
    a = rand(shape, np.uint8, cn)
    both("transpose", a)
    for code in (0, 1, 2):
        both("rotate", a, code)
    view = np.ascontiguousarray(rand((shape[0], shape[1] + 5) + ((cn,) if cn > 1 else ()), np.uint8, 1))[:, 2:2 + shape[1]]
    both("transpose", view)
    both("rotate", view, 0)


@pytest.mark.parametrize("alpha,beta", [(1.0, 0.0), (1.3, -10.0), (-1.0, 0.0), (0.5, 0.25), (2.5, 0.5), (-0.37, 100.0), (1e9, 0.0), (0.0, 300.0), (0.1, -0.5)])
@pytest.mark.parametrize("shape", [(1, 300), (17, 33, 3), (40, 64), (5, 129, 4)])
def test_convert_scale_abs_u8_table_path(alpha, beta, shape):
    a = RNG.integers(0, 256, shape, dtype=np.uint8)
    both("convertScaleAbs", a, alpha=alpha, beta=beta)
    out = np.empty_like(a)
    both("convertScaleAbs", a, out, alpha, beta)
    c = a.copy()
    r = ref.convertScaleAbs(a, alpha=alpha, beta=beta)
    assert np.array_equal(sr.convertScaleAbs(c, c, alpha, beta), r)     # in place
    view = np.zeros((shape[0], shape[1] + 7) + shape[2:], np.uint8)[:, 3:3 + shape[1]]
    both("convertScaleAbs", a, view, alpha, beta)


@pytest.mark.parametrize("deg", [True, False])
def test_phase_f32_vector_path_with_specials(deg):
    n = 5003
    x = (RNG.integers(-1000, 1001, n) * 0.37).astype(np.float32).reshape(1, n)
    y = (RNG.integers(-1000, 1001, n) * 0.91).astype(np.float32).reshape(1, n)
    x[0, ::97] = 0
    y[0, ::89] = 0
    x[0, ::1013] = np.nan
    y[0, ::1019] = np.inf
    y[0, 7] = -np.inf
    x[0, 11], y[0, 11] = -0.0, -0.0
    r, s = ref.phase(x, y, angleInDegrees=deg), sr.phase(x, y, angleInDegrees=deg)
    assert np.array_equal(np.isnan(r), np.isnan(s))
    ok = ~np.isnan(r)
    ulp = np.abs(r[ok].view(np.int32).astype(np.int64) - s[ok].view(np.int32).astype(np.int64))
    assert ulp.max() <= 4, ulp.max()   # cv2's SIMD/tail arrangement differs from ours by a few ulp (pre-existing); never more
