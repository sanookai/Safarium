"""Area D (numpy + glue): cv2 per-pixel arithmetic, colour conversion and small helpers in pure numpy.

Each function mirrors cv2's Python signature and OpenCV 5.x numeric rules (checked against reference cv2 in
sdk/python/tests/test_parity_numpy.py):
- integer results are rounded half-to-even (cvRound) and saturated;
- with two arrays of different depth and dtype=-1 the result takes src1's depth (OpenCV 5 behaviour);
- a Python number scalar applies to every channel, a tuple/array is a per-channel Scalar (missing = 0);
- `dst=` with the right shape/dtype is written in place (views too) and returned; otherwise a new array.
BGR2GRAY fixed-point weights and the RGB2HSV_b tables are ported from OpenCV imgproc (Apache-2.0).
Contract: Projects/Safarium/docs/raster-plan.md
"""
from __future__ import annotations

import ctypes

import numpy as np

from . import _constants as C
from . import _lib
from ._lib import error

__all__ = [
    "cvtColor", "addWeighted", "add", "subtract", "multiply", "absdiff", "merge", "split", "reduce",
    "countNonZero", "convertScaleAbs", "Laplacian", "getNumThreads", "setNumThreads",
]

_DEPTH2DT = {
    C.CV_8U: np.uint8, C.CV_8S: np.int8, C.CV_16U: np.uint16, C.CV_16S: np.int16,
    C.CV_32S: np.int32, C.CV_32F: np.float32, C.CV_64F: np.float64,
}


def _np(a, name="src") -> np.ndarray:
    if isinstance(a, np.ndarray):
        return a
    if a is None:
        raise error(f"{name} is None")
    return np.asarray(a)


def _dtype_of(depth: int, default) -> np.dtype:
    if depth is None or depth < 0:
        return np.dtype(default)
    if depth not in _DEPTH2DT:
        raise error(f"unsupported depth {depth}")
    return np.dtype(_DEPTH2DT[depth])


def _saturate(x: np.ndarray, dt: np.dtype) -> np.ndarray:
    """cv::saturate_cast: round half to even for integer targets (NaN -> 0), clip to the type range."""
    dt = np.dtype(dt)
    if dt.kind == "f":
        return x.astype(dt, copy=False)
    if x.dtype.kind == "f":
        x = np.rint(x)
        x = np.where(np.isnan(x), 0, x)
    info = np.iinfo(dt)
    return np.clip(x, info.min, info.max).astype(dt)


def _finish(res: np.ndarray, dst):
    if isinstance(dst, np.ndarray) and dst.shape == res.shape and dst.dtype == res.dtype:
        np.copyto(dst, res)
        return dst
    return res


def _channels(a: np.ndarray) -> int:
    return 1 if a.ndim == 2 else a.shape[2]


def _is_scalar_like(v) -> bool:
    return isinstance(v, (int, float, np.integer, np.floating, tuple, list)) or (
        isinstance(v, np.ndarray) and v.ndim == 1 and v.size <= 4)


def _scalar_for(v, ref: np.ndarray) -> np.ndarray:
    """cv2 Python scalar -> float64 array broadcastable over `ref` (H,W[,C])."""
    cn = _channels(ref)
    if isinstance(v, (int, float, np.integer, np.floating)):
        vals = [float(v)] * cn  # OpenCV 5 bindings: a bare number applies to every channel
    else:
        lst = [float(x) for x in list(np.asarray(v, dtype=np.float64).ravel())[:4]]
        lst += [0.0] * (4 - len(lst))
        vals = lst[:cn]
    s = np.asarray(vals, dtype=np.float64)
    return s[0] if ref.ndim == 2 else s


def _binary(src1, src2, dtype, opname, promote=False):
    """Return (a, b, out_dtype, work) with float64 or int64 operands; one side may be a scalar."""
    s1_scalar = not isinstance(src1, np.ndarray) and _is_scalar_like(src1)
    s2_scalar = not isinstance(src2, np.ndarray) and _is_scalar_like(src2)
    if isinstance(src2, np.ndarray) and src2.ndim == 1 and src2.size <= 4 and isinstance(src1, np.ndarray) and src1.ndim >= 2:
        s2_scalar = True
    if s1_scalar and s2_scalar:
        raise error(f"{opname}: both operands are scalars")
    if s1_scalar or s2_scalar:
        arr = _np(src2 if s1_scalar else src1)
        sc = _scalar_for(src1 if s1_scalar else src2, arr)
        out_dt = _dtype_of(dtype, arr.dtype)
        a = arr.astype(np.float64)
        return (sc, a, out_dt) if s1_scalar else (a, sc, out_dt)
    a1, a2 = _np(src1, "src1"), _np(src2, "src2")
    if a1.shape != a2.shape:
        raise error(f"{opname}: the operation is neither 'array op array' (where arrays have the same size and "
                    f"the same number of channels), nor 'array op scalar'")
    out_dt = _dtype_of(dtype, np.result_type(a1.dtype, a2.dtype) if promote else a1.dtype)
    if a1.dtype.kind in "iu" and a2.dtype.kind in "iu" and out_dt.kind in "iu":
        return a1.astype(np.int64), a2.astype(np.int64), out_dt
    work = np.float32 if (out_dt == np.float32 and a1.dtype.itemsize <= 4 and a2.dtype.itemsize <= 4) else np.float64
    return a1.astype(work), a2.astype(work), out_dt


def _apply_mask(res, mask, dst, base_shape):
    if mask is None:
        return res
    m = _np(mask, "mask")
    if m.shape[:2] != base_shape[:2]:
        raise error("mask size mismatch")
    if isinstance(dst, np.ndarray) and dst.shape == res.shape and dst.dtype == res.dtype:
        out = dst.copy()
    else:
        out = np.zeros_like(res)
    sel = m != 0
    out[sel] = res[sel]
    return out


def _arith(src1, src2, dst, mask, dtype, fn, opname, promote=False):
    a, b, out_dt = _binary(src1, src2, dtype, opname, promote)
    shape = (src1 if isinstance(src1, np.ndarray) and src1.ndim >= 2 else src2).shape
    res = _saturate(fn(a, b), out_dt)
    if res.shape != shape:
        res = np.broadcast_to(res, shape).copy()
    res = _apply_mask(res, mask, dst, shape)
    return _finish(res, dst)


def add(src1, src2, dst=None, mask=None, dtype=-1):
    return _arith(src1, src2, dst, mask, dtype, np.add, "add")


def subtract(src1, src2, dst=None, mask=None, dtype=-1):
    return _arith(src1, src2, dst, mask, dtype, np.subtract, "subtract")


def absdiff(src1, src2, dst=None):
    return _arith(src1, src2, dst, None, -1, lambda a, b: np.abs(a - b), "absdiff", promote=True)  # absdiff promotes mixed depths


def multiply(src1, src2, dst=None, scale=1.0, dtype=-1):
    scale = float(scale)
    wide = any(isinstance(x, np.ndarray) and x.dtype == np.int32 for x in (src1, src2))
    if scale == 1.0:
        fn = np.multiply
    else:
        # OpenCV: saturate((scale * src1) * src2); integer inputs in float32 (matches cv2 5.1 exactly)
        def fn(a, b):
            if a.dtype.kind in "iu" and getattr(b, "dtype", np.dtype(np.float64)).kind in "iu":
                f = np.float64 if wide else np.float32   # int32 does not fit float32's mantissa
                return (f(scale) * a.astype(f)) * b.astype(f)
            return (a * a.dtype.type(scale)) * b
    return _arith(src1, src2, dst, None, dtype, fn, "multiply")


def addWeighted(src1, alpha, src2, beta, gamma, dst=None, dtype=-1):
    a1, a2 = _np(src1, "src1"), _np(src2, "src2")
    if a1.shape != a2.shape:
        raise error("addWeighted: src1 and src2 must have the same size and channel count")
    out_dt = _dtype_of(dtype, a1.dtype)
    if out_dt.kind in "iu" and a1.dtype.itemsize <= 2 and a2.dtype.itemsize <= 2 and a1.dtype.kind in "iu" \
            and a2.dtype.kind in "iu":
        # OpenCV 5.1 addWeighted for 8/16-bit (SIMD): fma(src1, alpha, fma(src2, beta, gamma)) in float32,
        # then cvRound + saturate. A float64 product of an 8/16-bit value and a float32 weight is exact,
        # so rounding to float32 after each add reproduces the two fused multiply-adds bit for bit.
        f = np.float32
        inner = (a2.astype(np.float64) * float(f(beta)) + float(f(gamma))).astype(f)
        res = (a1.astype(np.float64) * float(f(alpha)) + inner.astype(np.float64)).astype(f)
    else:
        res = a1.astype(np.float64) * float(alpha) + a2.astype(np.float64) * float(beta) + float(gamma)
    return _finish(_saturate(res, out_dt), dst)


def merge(mv, dst=None):
    parts = [_np(m) for m in mv]
    if not parts:
        raise error("merge: empty input")
    dt, hw = parts[0].dtype, parts[0].shape[:2]
    for p in parts:
        if p.dtype != dt or p.shape[:2] != hw:
            raise error("merge: (-215:Assertion failed) mv[i].size == mv[0].size && mv[i].depth() == depth")
    planes = [p if p.ndim == 3 else p[..., None] for p in parts]
    res = np.concatenate(planes, axis=2) if len(planes) > 1 else planes[0]
    if res.shape[2] == 1:
        res = res[..., 0]
    return _finish(np.ascontiguousarray(res), dst)


def split(m, mv=None):
    a = _np(m)
    if a.ndim == 2:
        return (a.copy(),)
    return tuple(np.ascontiguousarray(a[..., i]) for i in range(a.shape[2]))


def _opt_declare(name: str, argtypes: list, restype=_lib.I32):
    try:
        return _lib.declare(name, argtypes, restype=restype)
    except AttributeError:
        def _missing(*_a, _n=name):
            raise error(f"{_n}: libSafariumRaster is missing this symbol (rebuild the dylib)")
        return _missing


_np_bgr2gray = _opt_declare("sr_np_bgr2gray", [_lib.VP, ctypes.c_ssize_t, _lib.VP, ctypes.c_ssize_t, _lib.I32, _lib.I32, _lib.I32, _lib.I32, _lib.I32])
_np_cvt_swap = _opt_declare("sr_np_cvt_swap", [_lib.VP, ctypes.c_ssize_t, _lib.VP, ctypes.c_ssize_t, _lib.I32, _lib.I32, _lib.I32, _lib.I32, _lib.I32, _lib.I32])
_np_gray2bgr = _opt_declare("sr_np_gray2bgr", [_lib.VP, ctypes.c_ssize_t, _lib.VP, ctypes.c_ssize_t, _lib.I32, _lib.I32, _lib.I32, _lib.I32])
_np_reduce_u8 = _opt_declare("sr_np_reduce_u8", [_lib.VP, ctypes.c_ssize_t, _lib.VP, ctypes.c_ssize_t, _lib.I32, _lib.I32, _lib.I32, _lib.I32, _lib.I32, _lib.I32])
_np_laplacian = _opt_declare("sr_np_laplacian", [_lib.VP, ctypes.c_ssize_t, _lib.I32, _lib.VP, ctypes.c_ssize_t, _lib.I32,
                                                 _lib.I32, _lib.I32, _lib.I32, _lib.I32, _lib.F64, _lib.F64, _lib.I32])

_DEPTH_CODE = {np.dtype(np.uint8): 0, np.dtype(np.int8): 1, np.dtype(np.uint16): 2, np.dtype(np.int16): 3,
               np.dtype(np.int32): 4, np.dtype(np.float32): 5, np.dtype(np.float64): 6}


def _usable_src(a: np.ndarray) -> np.ndarray:
    item = a.dtype.itemsize
    if a.ndim == 2:
        ok = a.strides[1] == item and a.strides[0] >= 0
    elif a.ndim == 3:
        ok = a.strides[2] == item and a.strides[1] == a.shape[2] * item and a.strides[0] >= 0
    else:
        ok = False
    return a if ok else np.ascontiguousarray(a)


def _alloc_or_direct(dst, shape: tuple, dt: np.dtype, src_a: np.ndarray):
    if isinstance(dst, np.ndarray) and dst.shape == shape and dst.dtype == dt and dst.flags.writeable:
        item = dt.itemsize
        if dst.ndim == 2:
            ok = dst.strides[1] == item and dst.strides[0] >= shape[1] * item
        elif dst.ndim == 3:
            ok = dst.strides[2] == item and dst.strides[1] == shape[2] * item and dst.strides[0] >= shape[1] * shape[2] * item
        else:
            ok = False
        if ok and not np.shares_memory(src_a, dst):
            return dst, True
    return np.empty(shape, dt), False


def reduce(src, dim, rtype, dst=None, dtype=-1):
    a = _np(src)
    if dim not in (0, 1):
        raise error("reduce: dim must be 0 or 1")
    out_dt = _dtype_of(dtype, a.dtype)
    if rtype in (C.REDUCE_MAX, C.REDUCE_MIN):
        if out_dt != a.dtype:
            raise error("reduce: MIN/MAX need dtype == src depth")
    elif rtype in (C.REDUCE_SUM, C.REDUCE_AVG):
        if rtype == C.REDUCE_SUM and a.dtype.kind in "iu" and np.dtype(out_dt).itemsize <= a.dtype.itemsize \
                and out_dt.kind in "iu":
            raise error("reduce: (-210:Unsupported format or combination of formats) "
                        f"Unsupported combination of input and output array formats")
    else:
        raise error(f"reduce: unsupported rtype {rtype}")
    if a.dtype == np.uint8 and a.ndim in (2, 3) and a.shape[0] > 0 and a.shape[1] > 0 \
            and np.dtype(out_dt) in (np.uint8, np.int32, np.float32, np.float64):
        au = _usable_src(a)
        h, w = au.shape[:2]
        cn = 1 if au.ndim == 2 else au.shape[2]
        out_shape = (1, w) if dim == 0 else (h, 1)
        if au.ndim == 3:
            out_shape = out_shape + (cn,)
        out, direct = _alloc_or_direct(dst, out_shape, np.dtype(out_dt), au)
        _lib.check(_np_reduce_u8(au.ctypes.data, au.strides[0], out.ctypes.data, out.strides[0],
                                 w, h, cn, int(dim), int(rtype), _DEPTH_CODE[np.dtype(out_dt)]), "reduce")
        return out if direct else _finish(out, dst)
    if rtype in (C.REDUCE_MAX, C.REDUCE_MIN):
        res = (a.max if rtype == C.REDUCE_MAX else a.min)(axis=dim, keepdims=True)
    else:
        acc = np.float64 if (a.dtype.kind == "f" or out_dt.kind == "f") else np.int64
        res = a.astype(acc).sum(axis=dim, keepdims=True)
        if rtype == C.REDUCE_AVG:
            res = res.astype(np.float64) / a.shape[dim]
        res = _saturate(res, out_dt)
    return _finish(np.ascontiguousarray(res.astype(out_dt, copy=False)), dst)


def countNonZero(src) -> int:
    a = _np(src)
    if a.ndim == 3 and a.shape[2] != 1:
        raise error("countNonZero: (-215:Assertion failed) cn == 1")
    return int(np.count_nonzero(a))


def convertScaleAbs(src, dst=None, alpha=1.0, beta=0.0):
    a = _np(src)
    f = np.float32
    res = np.abs(a.astype(f) * f(alpha) + f(beta))
    return _finish(_saturate(res, np.uint8), dst)


_LAP_TAPS = {  # (dy, dx, coef) in OpenCV's row-major nonzero-coefficient order
    1: [(-1, 0, 1.0), (0, -1, 1.0), (0, 0, -4.0), (0, 1, 1.0), (1, 0, 1.0)],
    3: [(-1, -1, 2.0), (-1, 1, 2.0), (0, 0, -8.0), (1, -1, 2.0), (1, 1, 2.0)],
}
_PAD_MODE = {C.BORDER_REFLECT_101: "reflect", C.BORDER_REPLICATE: "edge", C.BORDER_REFLECT: "symmetric",
             C.BORDER_WRAP: "wrap", C.BORDER_CONSTANT: "constant"}


def Laplacian(src, ddepth, dst=None, ksize=1, scale=1.0, delta=0.0, borderType=C.BORDER_DEFAULT):
    a = _np(src)
    if ksize not in _LAP_TAPS:
        raise error(f"Laplacian: only ksize 1 and 3 are supported by the Safarium shim (got {ksize})")
    out_dt = _dtype_of(ddepth, a.dtype)
    b = int(borderType) & ~C.BORDER_ISOLATED
    mode = _PAD_MODE.get(b)
    if mode is None:
        raise error(f"Laplacian: unsupported borderType {borderType}")
    if a.ndim in (2, 3) and a.shape[0] > 0 and a.shape[1] > 0 \
            and a.dtype in _DEPTH_CODE and np.dtype(out_dt) in _DEPTH_CODE:
        au = _usable_src(a)
        cn = 1 if au.ndim == 2 else au.shape[2]
        out, direct = _alloc_or_direct(dst, au.shape, np.dtype(out_dt), au)
        _lib.check(_np_laplacian(au.ctypes.data, au.strides[0], _DEPTH_CODE[au.dtype],
                                 out.ctypes.data, out.strides[0], _DEPTH_CODE[np.dtype(out_dt)],
                                 au.shape[1], au.shape[0], cn, int(ksize), float(scale), float(delta), b), "Laplacian")
        return out if direct else _finish(out, dst)
    work = np.float64 if (a.dtype == np.float64 or out_dt == np.float64) else np.float32
    x = a.astype(work)
    h, w = x.shape[:2]
    p = x
    for axis, n in ((0, h), (1, w)):
        pad = [(0, 0)] * x.ndim
        pad[axis] = (1, 1)
        # OpenCV REFLECT_101 on a 1-pixel axis degenerates to replicate
        p = np.pad(p, pad, mode="edge" if (mode == "reflect" and n == 1) else mode)
    acc = np.full(x.shape, work(delta), dtype=work)
    for dy, dx, k in _LAP_TAPS[ksize]:
        acc = acc + p[1 + dy:1 + dy + h, 1 + dx:1 + dx + w] * work(k * scale)
    return _finish(_saturate(acc, out_dt), dst)


# ---------------------------------------------------------------- cvtColor
_SWAP = {  # code: (allowed scn, dcn, swap R/B)
    C.COLOR_BGR2BGRA: ((3, 4), 4, False), C.COLOR_BGRA2BGR: ((3, 4), 3, False),
    C.COLOR_BGR2RGBA: ((3, 4), 4, True), C.COLOR_RGBA2BGR: ((3, 4), 3, True),
    C.COLOR_BGR2RGB: ((3, 4), 3, True), C.COLOR_BGRA2RGBA: ((3, 4), 4, True),
}
_TO_GRAY = {C.COLOR_BGR2GRAY: 0, C.COLOR_RGB2GRAY: 2, C.COLOR_BGRA2GRAY: 0, C.COLOR_RGBA2GRAY: 2}  # blue index
_FROM_GRAY = {C.COLOR_GRAY2BGR: 3, C.COLOR_GRAY2BGRA: 4}
_TO_HSV = {C.COLOR_BGR2HSV: 0, C.COLOR_RGB2HSV: 2}  # blue index

_HSV_SHIFT = 12


def _hsv_tables():
    i = np.arange(256, dtype=np.float64)
    with np.errstate(divide="ignore"):
        sdiv = np.where(i > 0, np.rint((255 << _HSV_SHIFT) / np.maximum(i, 1)), 0).astype(np.int64)
        hdiv = np.where(i > 0, np.rint((180 << _HSV_SHIFT) / (6.0 * np.maximum(i, 1))), 0).astype(np.int64)
    return sdiv, hdiv


_SDIV, _HDIV180 = _hsv_tables()

# (V, V - min) pairs where OpenCV 5.1's u8 saturation is one lower than the table formula above (its SIMD path
# divides through an approximate float reciprocal). Measured exhaustively over all 2^24 BGR triplets against
# reference cv2 5.1.0; with these the shim matches every u8 input exactly (H already did).
_S_LOWER = [(2, 1), (4, 2), (14, 7), (18, 3), (18, 9), (18, 15), (118, 59), (118, 90), (209, 25), (209, 75),
            (209, 125), (209, 134), (209, 175), (209, 184), (209, 193)]


def _s_lut() -> np.ndarray:
    v = np.arange(256, dtype=np.int64)[:, None]
    d = np.arange(256, dtype=np.int64)[None, :]
    lut = (d * _SDIV[v] + (1 << (_HSV_SHIFT - 1))) >> _HSV_SHIFT
    for vv, dd in _S_LOWER:
        lut[vv, dd] -= 1
    return np.clip(lut, 0, 255)


_S_LUT = _s_lut()  # [V, diff] -> S


def _alpha_max(dt: np.dtype):
    return 1.0 if dt.kind == "f" else np.iinfo(dt).max


def _check_depth(a: np.ndarray, allowed: tuple):
    if a.dtype not in [np.dtype(d) for d in allowed]:
        raise error(f"cvtColor: Unsupported depth of input image: {a.dtype}")


def cvtColor(src, code, dst=None, dstCn=0, hint=None):
    a = _np(src)
    scn = _channels(a)
    if code in _SWAP:
        allowed, dcn, swap = _SWAP[code]
        _check_depth(a, (np.uint8, np.uint16, np.float32))
        if scn not in allowed:
            raise error(f"cvtColor: (-15:Bad number of channels) Invalid number of channels in input image: {scn}")
        if dstCn:
            dcn = dstCn
        au = _usable_src(a)
        h, w = au.shape[:2]
        out_shape = (h, w, dcn)
        out, direct = _alloc_or_direct(dst, out_shape, au.dtype, au)
        if h and w:
            _lib.check(_np_cvt_swap(au.ctypes.data, au.strides[0], out.ctypes.data, out.strides[0],
                                    w, h, scn, dcn, _DEPTH_CODE[au.dtype], 1 if swap else 0), "cvtColor")
        return out if direct else _finish(out, dst)
    elif code in _FROM_GRAY:
        _check_depth(a, (np.uint8, np.uint16, np.float32))
        if scn != 1:
            raise error(f"cvtColor: (-15:Bad number of channels) Invalid number of channels in input image: {scn}")
        g = a if a.ndim == 2 else a[..., 0]
        dcn = dstCn or _FROM_GRAY[code]
        gu = _usable_src(g)
        h, w = gu.shape[:2]
        out_shape = (h, w, dcn)
        out, direct = _alloc_or_direct(dst, out_shape, gu.dtype, gu)
        if h and w:
            _lib.check(_np_gray2bgr(gu.ctypes.data, gu.strides[0], out.ctypes.data, out.strides[0],
                                    w, h, dcn, _DEPTH_CODE[gu.dtype]), "cvtColor")
        return out if direct else _finish(out, dst)
    elif code in _TO_GRAY:
        _check_depth(a, (np.uint8, np.uint16, np.float32))
        if scn not in (3, 4):
            raise error(f"cvtColor: (-15:Bad number of channels) Invalid number of channels in input image: {scn}")
        bi = _TO_GRAY[code]
        au = _usable_src(a)
        h, w = au.shape[:2]
        out_shape = (h, w)
        out, direct = _alloc_or_direct(dst, out_shape, au.dtype, au)
        if h and w:
            _lib.check(_np_bgr2gray(au.ctypes.data, au.strides[0], out.ctypes.data, out.strides[0],
                                    w, h, scn, _DEPTH_CODE[au.dtype], bi), "cvtColor")
        return out if direct else _finish(out, dst)
    elif code in _TO_HSV:
        _check_depth(a, (np.uint8, np.float32))
        if scn not in (3, 4):
            raise error(f"cvtColor: (-15:Bad number of channels) Invalid number of channels in input image: {scn}")
        bi = _TO_HSV[code]
        if a.dtype == np.uint8:
            au = _usable_src(a if a.ndim == 3 else a[..., None])
            h, w, cn = au.shape
            out, direct = _alloc_or_direct(dst, (h, w, 3), np.uint8, au)
            if h and w:
                _lib.check(_hsv_u8_c(au.ctypes.data, au.strides[0], out.ctypes.data, out.strides[0],
                                     h, w, cn, bi, _S_LUT_U8.ctypes.data, _S_TAIL_U8.ctypes.data,
                                     _HDIV180_I32.ctypes.data), "cvtColor")
            return out if direct else _finish(out, dst)
        res = _hsv_f32_rows(a, bi)
        return _finish(np.ascontiguousarray(res), dst)
    else:
        raise error(f"cvtColor: colour conversion code {code} is not supported by the Safarium shim")


# The last (cols % 8) pixels of every row go through OpenCV's scalar tail, whose saturation is the round-half-up integer
# quotient (diff * 255 + v / 2) / v, except for these (V, V - min) pairs where its float arithmetic lands one lower
# (measured exhaustively over every pair with 1-pixel-wide images against reference cv2 5.1.0).
_S_TAIL_LOWER = [(82, 41), (94, 47), (110, 55), (122, 61), (164, 82), (166, 83), (188, 94), (194, 97), (214, 107),
                 (218, 109), (220, 110), (230, 23), (230, 115), (230, 161), (230, 207), (242, 121), (244, 122),
                 (246, 123), (246, 205)]


def _s_tail_lut() -> np.ndarray:
    v = np.arange(256, dtype=np.int64)[:, None]
    d = np.arange(256, dtype=np.int64)[None, :]
    vv = np.maximum(v, 1)
    lut = (d * 255 + vv // 2) // vv
    for vv_, dd in _S_TAIL_LOWER:
        lut[vv_, dd] -= 1
    return np.ascontiguousarray(np.clip(lut, 0, 255).astype(np.uint8))


_S_LUT_U8 = np.ascontiguousarray(_S_LUT.astype(np.uint8))
_S_TAIL_U8 = _s_tail_lut()
_HDIV180_I32 = np.ascontiguousarray(_HDIV180.astype(np.int32))
_hsv_u8_c = _opt_declare("sr_np_hsv_u8", [_lib.VP, ctypes.c_ssize_t, _lib.VP, ctypes.c_ssize_t, _lib.I32,
                                             _lib.I32, _lib.I32, _lib.I32, _lib.VP, _lib.VP, _lib.VP])


def _hsv_u8(a: np.ndarray, bi: int) -> np.ndarray:
    # OpenCV RGB2HSV_b (color_hsv.simd.hpp), hrange 180, as a streaming Swift kernel (no frame-sized temporaries)
    if a.ndim == 2:
        a = a[..., None]
    if a.strides[1] != a.shape[2] or a.strides[2] != 1:
        a = np.ascontiguousarray(a)
    h, w, cn = a.shape
    out = np.empty((h, w, 3), np.uint8)
    if h and w:
        _lib.check(_hsv_u8_c(a.ctypes.data, a.strides[0], out.ctypes.data, out.strides[0], h, w, cn, bi,
                             _S_LUT_U8.ctypes.data, _S_TAIL_U8.ctypes.data, _HDIV180_I32.ctypes.data), "cvtColor")
    return out


def _hsv_f32(a: np.ndarray, bi: int) -> np.ndarray:
    # Port of OpenCV RGB2HSV_f: H 0..360, S 0..1, V as input
    f = np.float32
    eps = f(np.finfo(np.float32).eps)
    b = a[..., bi].astype(f)
    g = a[..., 1].astype(f)
    r = a[..., 2 - bi].astype(f)
    v = np.maximum(np.maximum(r, g), b)
    vmin = np.minimum(np.minimum(r, g), b)
    diff = v - vmin
    s = diff / (np.abs(v) + eps)
    k = (60.0 / (diff + eps).astype(np.float64)).astype(f)
    h = np.where(v == r, (g - b) * k, np.where(v == g, (b - r) * k + f(120), (r - g) * k + f(240)))
    h = np.where(h < 0, h + f(360), h).astype(f)
    return np.stack([h, s.astype(f), v], axis=2)


def _hsv_f32_rows(a: np.ndarray, bi: int) -> np.ndarray:
    """_hsv_f32 in bands of rows so the float temporaries stay a few MiB instead of several frames."""
    h, w = a.shape[:2]
    out = np.empty((h, w, 3), np.float32)
    band = max(1, (1 << 18) // max(w, 1))
    for y in range(0, h, band):
        out[y:y + band] = _hsv_f32(a[y:y + band], bi)
    return out


# ---------------------------------------------------------------- threads
_set_threads = _lib.declare("sr_set_num_threads", [_lib.I32])
_get_threads = _lib.declare("sr_get_num_threads", [])


def setNumThreads(nthreads) -> None:
    n = int(nthreads)
    _lib.check(_set_threads(ctypes.c_int32(n if n > 0 else 1)), "setNumThreads")


def getNumThreads() -> int:
    return int(_get_threads())
