"""Phase 1 (core-numeric): OpenCV 5.1 `core` functions backed by libSafariumRaster (Core*.swift).

Imported after _numpy_ops, so the functions here replace the numpy versions of the same name. Signatures, defaults,
return values and error behaviour mirror cv2's Python API (checked against reference cv2 in
sdk/python/tests/test_parity_core.py). Heavy per-element loops run in Swift; this module only validates arguments,
allocates outputs and applies cv2's Python-level conventions (dst=, dtype=, scalar broadcasting, masks).
Contract: Projects/Safarium/docs/raster-plan.md, raster-roadmap.md section 2 row 1.
"""
from __future__ import annotations

import builtins
import ctypes
import os
import time as _time

import numpy as np

from . import _constants as C
from . import _lib
from ._lib import error

# Core constants the shared _constants.py does not carry (values identical to OpenCV 5.1): CMP_*, NORM_*, ROTATE_*, SORT_*,
# DECOMP_*, DFT_*, DCT_*, RNG_*, KMEANS_*, COVAR_*, GEMM_*, SVD_*, ... Only names missing from _constants are added.
_EXTRA_CONSTANTS = {
    "ALGO_HINT_ACCURATE": 1, "ALGO_HINT_APPROX": 2, "ALGO_HINT_DEFAULT": 0, "CMP_EQ": 0, "CMP_GE": 2, "CMP_GT": 1,
    "CMP_LE": 4, "CMP_LT": 3, "CMP_NE": 5, "COVAR_COLS": 16, "COVAR_NORMAL": 1, "COVAR_ROWS": 8, "COVAR_SCALE": 4,
    "COVAR_SCRAMBLED": 0, "COVAR_USE_AVG": 2, "DCT_INVERSE": 1, "DCT_ROWS": 4, "DECOMP_CHOLESKY": 3, "DECOMP_EIG": 2,
    "DECOMP_LU": 0, "DECOMP_NORMAL": 16, "DECOMP_QR": 4, "DECOMP_SVD": 1, "DFT_COMPLEX_INPUT": 64,
    "DFT_COMPLEX_OUTPUT": 16, "DFT_INVERSE": 1, "DFT_REAL_OUTPUT": 32, "DFT_ROWS": 4, "DFT_SCALE": 2, "GEMM_1_T": 1,
    "GEMM_2_T": 2, "GEMM_3_T": 4, "KMEANS_PP_CENTERS": 2, "KMEANS_RANDOM_CENTERS": 0, "KMEANS_USE_INITIAL_LABELS": 1,
    "NORM_HAMMING": 6, "NORM_HAMMING2": 7, "NORM_INF": 1, "NORM_L1": 2, "NORM_L2": 4, "NORM_L2SQR": 5, "NORM_MINMAX":
    32, "NORM_RELATIVE": 8, "NORM_TYPE_MASK": 7, "QUAT_ASSUME_NOT_UNIT": 0, "QUAT_ASSUME_UNIT": 1,
    "QUAT_ENUM_EULER_ANGLES_MAX_VALUE": 24, "QUAT_ENUM_EXT_XYX": 18, "QUAT_ENUM_EXT_XYZ": 12, "QUAT_ENUM_EXT_XZX": 19,
    "QUAT_ENUM_EXT_XZY": 13, "QUAT_ENUM_EXT_YXY": 20, "QUAT_ENUM_EXT_YXZ": 14, "QUAT_ENUM_EXT_YZX": 15,
    "QUAT_ENUM_EXT_YZY": 21, "QUAT_ENUM_EXT_ZXY": 16, "QUAT_ENUM_EXT_ZXZ": 22, "QUAT_ENUM_EXT_ZYX": 17,
    "QUAT_ENUM_EXT_ZYZ": 23, "QUAT_ENUM_INT_XYX": 6, "QUAT_ENUM_INT_XYZ": 0, "QUAT_ENUM_INT_XZX": 7,
    "QUAT_ENUM_INT_XZY": 1, "QUAT_ENUM_INT_YXY": 8, "QUAT_ENUM_INT_YXZ": 2, "QUAT_ENUM_INT_YZX": 3,
    "QUAT_ENUM_INT_YZY": 9, "QUAT_ENUM_INT_ZXY": 4, "QUAT_ENUM_INT_ZXZ": 10, "QUAT_ENUM_INT_ZYX": 5,
    "QUAT_ENUM_INT_ZYZ": 11, "RNG_NORMAL": 1, "RNG_UNIFORM": 0, "ROTATE_180": 1, "ROTATE_90_CLOCKWISE": 0,
    "ROTATE_90_COUNTERCLOCKWISE": 2, "SORT_ASCENDING": 0, "SORT_DESCENDING": 16, "SORT_EVERY_COLUMN": 1,
    "SORT_EVERY_ROW": 0, "SVD_FULL_UV": 4, "SVD_MODIFY_A": 1, "SVD_NO_UV": 2
}
for _k, _v in _EXTRA_CONSTANTS.items():
    if not hasattr(C, _k):
        globals()[_k] = _v
        setattr(C, _k, _v)  # so `C.NORM_L2` below and other modules see them
del _k, _v

_DT = [np.dtype(np.uint8), np.dtype(np.int8), np.dtype(np.uint16), np.dtype(np.int16), np.dtype(np.int32),
       np.dtype(np.float32), np.dtype(np.float64)]
_DEPTH = {dt: i for i, dt in enumerate(_DT)}
_NAMES = ["8U", "8S", "16U", "16S", "32S", "32F", "64F"]


class _Mat(ctypes.Structure):
    """Mirror of Swift `CoreMat` (CoreTypes.swift): 40 bytes."""
    _fields_ = [("data", ctypes.c_void_p), ("rows", ctypes.c_int64), ("cols", ctypes.c_int64),
                ("step", ctypes.c_int64), ("cn", ctypes.c_int32), ("depth", ctypes.c_int32)]


_VP = ctypes.c_void_p
_I32 = ctypes.c_int32
_F64 = ctypes.c_double
_PF = ctypes.POINTER(ctypes.c_double)
_lib_ = _lib.lib


def _decl(name, argtypes):
    fn = getattr(_lib_, name)
    fn.argtypes = argtypes
    fn.restype = _I32
    return fn


def _fn(name, argtypes):
    """Declare lazily-tolerant: a missing symbol (stale dylib) becomes an error at call time, not import time."""
    try:
        return _decl(name, argtypes)
    except AttributeError:
        def missing(*a, _n=name):
            raise error(f"{_n}: libSafariumRaster is missing this symbol (rebuild the dylib)")
        return missing


def _chk(rc, what):
    if rc != 0:
        raise error(f"{what}: {_lib.last_error()} (rc={rc})")


# ------------------------------------------------------------------------------------------ array plumbing
def _arr(a, name="src") -> np.ndarray:
    if isinstance(a, np.ndarray):
        x = a
    elif a is None:
        raise error(f"{name} is None")
    else:
        x = np.asarray(a)
        if x.dtype == np.int64 and x.ndim >= 1:
            x = x.astype(np.int32)
        elif x.dtype == np.bool_:
            x = x.astype(np.uint8)
    if x.dtype not in _DEPTH:
        if x.dtype == np.int64 or x.dtype == np.uint64 or x.dtype == np.bool_:
            raise error(f"{name}: unsupported array data type {x.dtype}")
        raise error(f"{name}: unsupported array data type {x.dtype}")
    if x.ndim == 1:
        x = x.reshape(-1, 1)
    if x.ndim not in (2, 3):
        raise error(f"{name}: unsupported array dimensions {x.ndim}")
    return x


def _cn(a: np.ndarray) -> int:
    return 1 if a.ndim == 2 else a.shape[2]


def _inner_contig(a: np.ndarray) -> bool:
    item = a.dtype.itemsize
    if a.ndim == 2:
        return a.shape[1] <= 1 or a.strides[1] == item
    c = a.shape[2]
    return (a.shape[1] <= 1 or a.strides[1] == c * item) and (c <= 1 or a.strides[2] == item)


def _usable(a: np.ndarray) -> bool:
    return _inner_contig(a) and (a.shape[0] <= 1 or a.strides[0] > 0) and a.strides[0] >= 0


def _contig(a: np.ndarray) -> np.ndarray:
    return a if _usable(a) else np.ascontiguousarray(a)


def _mat(a: np.ndarray) -> _Mat:
    h, w = a.shape[:2]
    c = _cn(a)
    step = a.strides[0] if h > 1 else w * c * a.dtype.itemsize
    return _Mat(a.ctypes.data, h, w, step, c, _DEPTH[a.dtype])


def _byref(m: _Mat):
    return ctypes.byref(m)


def _depth_dtype(depth, default) -> np.dtype:
    if depth is None or depth < 0:
        return np.dtype(default)
    if depth >= len(_DT):
        raise error(f"unsupported depth {depth}")
    return _DT[depth]


def _empty(shape, dtype, zero=False):
    return np.zeros(shape, dtype) if zero else np.empty(shape, dtype)


def _out(dst, shape, dtype, zero=False):
    """cv2 semantics: a dst array of the right shape/dtype is written in place; anything else is replaced.
    Returns (array to write into, finish) where finish() yields the object to return."""
    dtype = np.dtype(dtype)
    if isinstance(dst, np.ndarray) and dst.shape == tuple(shape) and dst.dtype == dtype and dst.flags.writeable:
        if _usable(dst):
            return dst, lambda: dst
        tmp = np.ascontiguousarray(dst)

        def fin(tmp=tmp, dst=dst):
            np.copyto(dst, tmp)
            return dst
        return tmp, fin
    out = _empty(shape, dtype, zero)
    return out, lambda: out


def _mask_arr(mask, rows, cols, name="mask"):
    if mask is None:
        return None
    m = _arr(mask, name)
    if m.dtype not in (np.dtype(np.uint8), np.dtype(np.int8)) or m.ndim != 2 and _cn(m) != 1:
        raise error(f"{name}: (-215:Assertion failed) mask.type() == CV_8UC1 || mask.type() == CV_8SC1")
    if m.ndim == 3:
        m = m[..., 0]
    if m.shape != (rows, cols):
        raise error(f"{name}: (-215:Assertion failed) mask.size == src.size")
    return _contig(m)


def _hwc(a: np.ndarray):
    return (a.shape[0], a.shape[1], 1) if a.ndim == 2 else tuple(a.shape)


def _shape_hwc(h, w, c):
    return (h, w) if c == 1 else (h, w, c)


def _canon(a: np.ndarray) -> np.ndarray:
    """cv2 returns single-channel images as 2-D: drop a trailing channel axis of size 1."""
    return a[..., 0] if a.ndim == 3 and a.shape[2] == 1 else a


def _pair(a: np.ndarray, b: np.ndarray, name: str):
    """OpenCV 5.1 broadcasting for array-array element-wise ops: dims (rows, cols, channels) match or are 1."""
    a, b = _canon(a), _canon(b)
    if a.shape == b.shape:
        return a, b
    sa, sb = _hwc(a), _hwc(b)
    out = []
    for x, y in zip(sa, sb):
        if x == y or y == 1:
            out.append(x)
        elif x == 1:
            out.append(y)
        else:
            raise error(f"{name}: (-215:Assertion failed) broadcastShape(bshapes.data(), ninputs, full) && "
                        f"\"ew: input shapes are not compatible\"")
    shp = _shape_hwc(*out)
    full = tuple(out)

    def expand(x):
        v = x.reshape(_hwc(x))
        return np.ascontiguousarray(np.broadcast_to(v, full)).reshape(shp)
    return (a if a.shape == shp else expand(a)), (b if b.shape == shp else expand(b))


def _is_scalar_like(v) -> bool:
    # cv2 accepts Python numbers, tuples and small 1-D ndarrays as a cv::Scalar; lists and numpy scalars are rejected.
    return isinstance(v, (int, float, tuple)) or (
        isinstance(v, np.ndarray) and v.ndim == 1 and v.size <= 4)


def _scalar4(v, fill=True) -> "ctypes.Array":
    """cv::Scalar. Arithmetic ops (add/subtract/multiply/divide/absdiff) broadcast a bare number to every channel
    (fill=True); compare/bitwise/min/max/inRange use cv::Scalar(v) = (v, 0, 0, 0) (fill=False), as cv2 5.1 does.
    Tuples are padded with zeros."""
    if isinstance(v, (int, float, np.integer, np.floating)):
        vals = [float(v)] * 4 if fill else [float(v), 0.0, 0.0, 0.0]
    else:
        vals = [float(x) for x in np.asarray(v, dtype=np.float64).ravel()[:4]]
        vals += [0.0] * (4 - len(vals))
    return (ctypes.c_double * 4)(*vals)


# ------------------------------------------------------------------------------------------ arithmetic
_arith = _fn("sr_core_arith", [_I32, _VP, _VP, _VP, _I32, _VP, _VP, _F64])
_addw = _fn("sr_core_addweighted", [_VP, _F64, _VP, _F64, _F64, _VP])
_scaleadd = _fn("sr_core_scaleadd", [_VP, _F64, _VP, _VP])
_convert = _fn("sr_core_convert", [_VP, _VP, _F64, _F64, _I32])

_OPNAME = {0: "add", 1: "subtract", 2: "absdiff", 3: "multiply", 4: "divide"}


def _promote_depth(d1: np.dtype, d2: np.dtype) -> np.dtype:
    return np.result_type(d1, d2)


def _arith_call(op, src1, src2, dst, mask, dtype, scale=1.0):
    name = _OPNAME[op]
    s1_scalar = not isinstance(src1, np.ndarray) and _is_scalar_like(src1)
    s2_scalar = not isinstance(src2, np.ndarray) and _is_scalar_like(src2)
    if isinstance(src2, np.ndarray) and src2.ndim == 1 and src2.size <= 4 and isinstance(src1, np.ndarray) and src1.ndim >= 2:
        s2_scalar = True
    if s1_scalar and s2_scalar:
        raise error(f"{name}: (-215:Assertion failed) both operands are scalars")
    scalar = None
    swap = 0
    b = None
    if s1_scalar or s2_scalar:
        a = _canon(_arr(src2 if s1_scalar else src1, "src"))
        scalar = _scalar4(src1 if s1_scalar else src2)
        swap = 1 if s1_scalar else 0
        out_dt = _depth_dtype(dtype, a.dtype)
    else:
        a, b = _pair(_arr(src1, "src1"), _arr(src2, "src2"), name)
        if dtype is not None and dtype >= 0:
            out_dt = _depth_dtype(dtype, a.dtype)
        elif op == 2:
            out_dt = _promote_depth(a.dtype, b.dtype)
        else:
            out_dt = a.dtype
    shape = a.shape
    m = _mask_arr(mask, shape[0], shape[1])
    res, fin = _out(dst, shape, out_dt, zero=m is not None)
    keep = [a]
    bm = None
    if b is not None:
        bb = _contig(b)
        bm = _mat(bb)
        keep.append(bb)
    a_c = _contig(a)
    am = _mat(a_c)
    mm = _mat(m) if m is not None else None
    rm = _mat(res)
    _chk(_arith(op, _byref(am), _byref(bm) if bm else None, scalar, swap, _byref(rm), _byref(mm) if mm else None,
                float(scale)), name)
    return fin()


def add(src1, src2, dst=None, mask=None, dtype=-1):
    return _arith_call(0, src1, src2, dst, mask, dtype)


def subtract(src1, src2, dst=None, mask=None, dtype=-1):
    return _arith_call(1, src1, src2, dst, mask, dtype)


def absdiff(src1, src2, dst=None):
    return _arith_call(2, src1, src2, dst, None, -1)


def multiply(src1, src2, dst=None, scale=1.0, dtype=-1):
    return _arith_call(3, src1, src2, dst, None, dtype, scale)


def divide(src1, src2=None, dst=None, scale=1.0, dtype=-1):
    if src2 is None or (not isinstance(src2, np.ndarray) and not _is_scalar_like(src2)):
        # divide(scale, src2) overload: cv2.divide(2.0, arr)
        pass
    return _arith_call(4, src1, src2, dst, None, dtype, scale)


def addWeighted(src1, alpha, src2, beta, gamma, dst=None, dtype=-1):
    a, b = _pair(_arr(src1, "src1"), _arr(src2, "src2"), "addWeighted")
    a, b = _contig(a), _contig(b)
    out_dt = _depth_dtype(dtype, a.dtype)
    res, fin = _out(dst, a.shape, out_dt)
    _chk(_addw(_byref(_mat(a)), float(alpha), _byref(_mat(b)), float(beta), float(gamma), _byref(_mat(res))), "addWeighted")
    return fin()


def scaleAdd(src1, alpha, src2, dst=None):
    a, b = _contig(_arr(src1, "src1")), _contig(_arr(src2, "src2"))
    if a.shape != b.shape or a.dtype != b.dtype or a.dtype.kind != "f":
        raise error("scaleAdd: (-215:Assertion failed) src1 and src2 must be float arrays of the same type and size")
    res, fin = _out(dst, a.shape, a.dtype)
    _chk(_scaleadd(_byref(_mat(a)), float(alpha), _byref(_mat(b)), _byref(_mat(res))), "scaleAdd")
    return fin()


def convertScaleAbs(src, dst=None, alpha=1.0, beta=0.0):
    a = _contig(_canon(_arr(src)))
    res, fin = _out(dst, a.shape, np.uint8)
    _chk(_convert(_byref(_mat(a)), _byref(_mat(res)), float(alpha), float(beta), 1), "convertScaleAbs")
    return fin()


def _convert_to(a: np.ndarray, dtype, alpha=1.0, beta=0.0) -> np.ndarray:
    """cv::Mat::convertTo (internal helper for normalize etc.)."""
    a = _contig(a)
    res = np.empty(a.shape, dtype)
    _chk(_convert(_byref(_mat(a)), _byref(_mat(res)), float(alpha), float(beta), 0), "convertTo")
    return res


# ------------------------------------------------------------------------------------------ bitwise / compare / min-max
_bitwise = _fn("sr_core_bitwise", [_I32, _VP, _VP, _VP, _VP, _VP])
_compare = _fn("sr_core_compare", [_I32, _VP, _VP, _VP, _VP])
_inrange = _fn("sr_core_inrange", [_VP, _VP, _VP, _VP, _VP, _VP])
_minmax = _fn("sr_core_minmax", [_I32, _VP, _VP, _VP, _VP])


def _sat_cast(vals, dt: np.dtype) -> np.ndarray:
    """cv::saturate_cast of Scalar slots to one element type (ties-to-even for integers, NaN -> 0)."""
    v = np.asarray(vals, dtype=np.float64)
    if dt.kind == "f":
        return v.astype(dt)
    info = np.iinfo(dt)
    v = np.rint(v)
    v = np.where(np.isnan(v), 0, v)
    return np.clip(v, info.min, info.max).astype(dt)


def _split_operands(src1, src2, name):
    """-> (array, other array or None, scalar4 or None, scalar_first)."""
    s1_scalar = not isinstance(src1, np.ndarray) and _is_scalar_like(src1)
    s2_scalar = not isinstance(src2, np.ndarray) and _is_scalar_like(src2)
    if isinstance(src2, np.ndarray) and src2.ndim == 1 and src2.size <= 4 and isinstance(src1, np.ndarray) and src1.ndim >= 2:
        s2_scalar = True
    if s1_scalar and s2_scalar:
        raise error(f"{name}: (-215:Assertion failed) both operands are scalars")
    if s1_scalar or s2_scalar:
        a = _canon(_arr(src2 if s1_scalar else src1, "src"))
        return a, None, _scalar4(src1 if s1_scalar else src2, False), s1_scalar
    a, b = _pair(_arr(src1, "src1"), _arr(src2, "src2"), name)
    if a.dtype != b.dtype:
        raise error(f"{name}: (-215:Assertion failed) src1.type() == src2.type()")
    return a, b, None, False


def _bitwise_call(op, src1, src2, dst, mask, name):
    if op == 3:
        a, b, sc = _canon(_arr(src1)), None, None
    else:
        a, b, sc, _ = _split_operands(src1, src2, name)
    a = _contig(a)
    m = _mask_arr(mask, a.shape[0], a.shape[1])
    res, fin = _out(dst, a.shape, a.dtype, zero=m is not None)
    pat = None
    if sc is not None:
        pat = _sat_cast(list(sc)[:_cn(a)] + [0.0] * builtins.max(0, _cn(a) - 4), a.dtype)
        pat = np.ascontiguousarray(pat)
    b_c = _contig(b) if b is not None else None   # keep the contiguous copy alive for the whole call
    bm = _mat(b_c) if b_c is not None else None
    keep = (pat, b_c)
    _chk(_bitwise(op, _byref(_mat(a)), _byref(bm) if bm else None, pat.ctypes.data if pat is not None else None,
                  _byref(_mat(res)), _byref(_mat(m)) if m is not None else None), name)
    return fin()


def bitwise_and(src1, src2, dst=None, mask=None):
    return _bitwise_call(0, src1, src2, dst, mask, "bitwise_and")


def bitwise_or(src1, src2, dst=None, mask=None):
    return _bitwise_call(1, src1, src2, dst, mask, "bitwise_or")


def bitwise_xor(src1, src2, dst=None, mask=None):
    return _bitwise_call(2, src1, src2, dst, mask, "bitwise_xor")


def bitwise_not(src, dst=None, mask=None):
    return _bitwise_call(3, src, None, dst, mask, "bitwise_not")


_FLIP_CMP = {0: 0, 1: 3, 2: 4, 3: 1, 4: 2, 5: 5}


def compare(src1, src2, cmpop, dst=None):
    if cmpop not in _FLIP_CMP:
        raise error("compare: (-215:Assertion failed) op == CMP_LT || op == CMP_LE || op == CMP_EQ || op == CMP_NE || "
                    "op == CMP_GE || op == CMP_GT")
    a, b, sc, first = _split_operands(src1, src2, "compare")
    op = _FLIP_CMP[cmpop] if first else cmpop
    a = _contig(a)
    res, fin = _out(dst, a.shape, np.uint8)
    if b is not None:
        b = _contig(b)
    _chk(_compare(op, _byref(_mat(a)), _byref(_mat(b)) if b is not None else None, sc, _byref(_mat(res))), "compare")
    return fin()


def inRange(src, lowerb, upperb, dst=None):
    a = _contig(_canon(_arr(src)))
    lo_s = not isinstance(lowerb, np.ndarray) and _is_scalar_like(lowerb)
    hi_s = not isinstance(upperb, np.ndarray) and _is_scalar_like(upperb)
    res, fin = _out(dst, a.shape[:2], np.uint8)
    if lo_s and hi_s:
        _chk(_inrange(_byref(_mat(a)), None, None, _scalar4(lowerb, False), _scalar4(upperb, False), _byref(_mat(res))), "inRange")
    elif not lo_s and not hi_s:
        lo, hi = _contig(_canon(_arr(lowerb, "lowerb"))), _contig(_canon(_arr(upperb, "upperb")))
        if lo.shape != a.shape or hi.shape != a.shape or lo.dtype != a.dtype or hi.dtype != a.dtype:
            raise error("inRange: (-215:Assertion failed) lb.type() == src.type() && ub.type() == src.type()")
        _chk(_inrange(_byref(_mat(a)), _byref(_mat(lo)), _byref(_mat(hi)), None, None, _byref(_mat(res))), "inRange")
    else:
        raise error("inRange: (-215:Assertion failed) lowerb and upperb must both be scalars or both arrays")
    return fin()


def _minmax_call(is_max, src1, src2, dst, name):
    a, b, sc, _ = _split_operands(src1, src2, name)
    a = _contig(a)
    res, fin = _out(dst, a.shape, a.dtype)
    if b is not None:
        b = _contig(b)
    _chk(_minmax(is_max, _byref(_mat(a)), _byref(_mat(b)) if b is not None else None, sc, _byref(_mat(res))), name)
    return fin()


def max(src1, src2, dst=None):  # noqa: A001 (cv2.max)
    return _minmax_call(1, src1, src2, dst, "max")


def min(src1, src2, dst=None):  # noqa: A001 (cv2.min)
    return _minmax_call(0, src1, src2, dst, "min")



# ------------------------------------------------------------------------------------------ channels / geometry
_mix = _fn("sr_core_mixchannels", [_I32, _VP, _I32, _VP, _I32, _VP])
_flip = _fn("sr_core_flip", [_VP, _VP, _I32])
_rotate = _fn("sr_core_rotate", [_VP, _VP, _I32])
_transpose = _fn("sr_core_transpose", [_VP, _VP])
_border_interp = _fn("sr_core_border_interpolate", [_I32, _I32, _I32])
_copyborder = _fn("sr_core_copymakeborder", [_VP, _VP, _I32, _I32, _I32, _VP])
_lut = _fn("sr_core_lut", [_VP, _VP, _I32, _VP])


def _mat_array(arrs):
    return (_Mat * len(arrs))(*[_mat(a) for a in arrs])


def _mix_call(srcs, dsts, pairs, name):
    sa = _mat_array(srcs)
    da = _mat_array(dsts)
    ft = (ctypes.c_int32 * len(pairs))(*pairs)
    _chk(_mix(len(srcs), ctypes.addressof(sa), len(dsts), ctypes.addressof(da), len(pairs) // 2, ft), name)


def split(m, mv=None):
    a = _contig(_canon(_arr(m)))
    cn = _cn(a)
    if a.size == 0:
        return ()   # cv2 returns an empty tuple for an empty image
    planes = [np.empty(a.shape[:2], a.dtype) for _ in range(cn)]
    if a.shape[0] and a.shape[1]:
        _mix_call([a], planes, [i for c in range(cn) for i in (c, c)], "split")
    return tuple(planes)


def merge(mv, dst=None):
    if isinstance(mv, np.ndarray):
        mv = [mv]
    parts = [_contig(_arr(m)) for m in mv]
    if not parts:
        raise error("merge: (-215:Assertion failed) mv && n > 0")
    dt, hw = parts[0].dtype, parts[0].shape[:2]
    for p in parts:
        if p.dtype != dt or p.shape[:2] != hw:
            raise error("merge: (-215:Assertion failed) mv[i].size == mv[0].size && mv[i].depth() == depth")
    total = builtins.sum(_cn(p) for p in parts)
    res, fin = _out(dst, _shape_hwc(hw[0], hw[1], total), dt)
    if hw[0] and hw[1]:
        _mix_call(parts, [res], [i for i in range(total) for _ in (0,) for i in (i, i)], "merge")
    return fin()


def mixChannels(src, dst, fromTo):
    srcs = [_contig(_arr(x, "src")) for x in src]
    dsts = list(dst)
    work = []
    fins = []
    for d in dsts:
        if not isinstance(d, np.ndarray):
            raise error("mixChannels: dst must be a list of numpy arrays")
        d2, fin = _out(d, _canon(d).shape if d.ndim == 3 and d.shape[2] == 1 else d.shape, d.dtype)
        if d2 is not d:  # needs temp: seed with current contents
            np.copyto(d2, d)
        work.append(d2 if d2.ndim == 3 or d2.ndim == 2 else d2)
        fins.append(fin)
    ft = [int(x) for x in np.asarray(fromTo).ravel()]
    if len(ft) % 2:
        raise error("mixChannels: (-215:Assertion failed) fromTo.size() % 2 == 0")
    _mix_call(srcs, work, ft, "mixChannels")
    for f in fins:
        f()
    return dst


def extractChannel(src, coi, dst=None):
    a = _contig(_canon(_arr(src)))
    if not 0 <= coi < _cn(a):
        raise error("extractChannel: (-215:Assertion failed) 0 <= coi && coi < cn")
    res, fin = _out(dst, a.shape[:2], a.dtype)
    _mix_call([a], [res], [coi, 0], "extractChannel")
    return fin()


def insertChannel(src, dst, coi):
    a = _contig(_canon(_arr(src)))
    if not isinstance(dst, np.ndarray):
        raise error("insertChannel: dst must be a numpy array")
    if _cn(a) != 1 or a.dtype != dst.dtype or a.shape[:2] != dst.shape[:2] or not 0 <= coi < _cn(dst):
        raise error("insertChannel: (-215:Assertion failed) src.size == dst.size && src.depth == dst.depth && 0 <= coi < dcn")
    d2, fin = _out(dst, dst.shape, dst.dtype)
    if d2 is not dst:
        np.copyto(d2, dst)
    _mix_call([a], [d2], [0, coi], "insertChannel")
    return fin()


def flip(src, flipCode, dst=None):
    if isinstance(src, np.ndarray) and src.ndim == 1:   # cv2 treats a 1-D array as one row
        r = flip(src.reshape(1, -1), flipCode, None if dst is None else dst.reshape(1, -1))
        if dst is not None and np.shares_memory(r, dst):
            return dst
        return r.reshape(-1) if flipCode == 0 else r   # cv2 quirk: vertical flip keeps the 1-D shape, horizontal gives (1, N)
    a = _canon(_arr(src))
    inplace = dst is not None and isinstance(dst, np.ndarray) and dst is src and _usable(a) and a.flags.writeable
    if inplace:
        _chk(_flip(_byref(_mat(a)), _byref(_mat(a)), int(flipCode)), "flip")
        return dst
    a = _contig(a)
    res, fin = _out(dst, a.shape, a.dtype)
    _chk(_flip(_byref(_mat(a)), _byref(_mat(res)), int(flipCode)), "flip")
    return fin()


def rotate(src, rotateCode, dst=None):
    if rotateCode not in (0, 1, 2):
        raise error("rotate: (-215:Assertion failed) Unknown rotateCode")
    a = _contig(_canon(_arr(src)))
    shape = a.shape if rotateCode == 1 else _shape_hwc(a.shape[1], a.shape[0], _cn(a))
    res, fin = _out(dst, shape, a.dtype)
    if res is a or np.shares_memory(res, a):
        res = np.empty(shape, a.dtype)
        _chk(_rotate(_byref(_mat(a)), _byref(_mat(res)), int(rotateCode)), "rotate")
        if isinstance(dst, np.ndarray) and dst.shape == res.shape and dst.dtype == res.dtype:
            np.copyto(dst, res)
            return dst
        return res
    _chk(_rotate(_byref(_mat(a)), _byref(_mat(res)), int(rotateCode)), "rotate")
    return fin()


def transpose(src, dst=None):
    a = _contig(_canon(_arr(src)))
    if a.size == 0:
        return None   # cv2 returns None for an empty input
    shape = _shape_hwc(a.shape[1], a.shape[0], _cn(a))
    res, fin = _out(dst, shape, a.dtype)
    if np.shares_memory(res, a):
        tmp = np.empty(shape, a.dtype)
        _chk(_transpose(_byref(_mat(a)), _byref(_mat(tmp))), "transpose")
        np.copyto(res, tmp)
        return fin()
    _chk(_transpose(_byref(_mat(a)), _byref(_mat(res))), "transpose")
    return fin()


def repeat(src, ny, nx, dst=None):
    a = _canon(_arr(src))
    if ny < 1 or nx < 1:
        raise error("repeat: (-215:Assertion failed) ny > 0 && nx > 0")
    res = np.tile(a, (ny, nx) + ((1,) if a.ndim == 3 else ()))
    return _finish_copy(res, dst)


def _finish_copy(res, dst):
    if isinstance(dst, np.ndarray) and dst.shape == res.shape and dst.dtype == res.dtype and dst.flags.writeable:
        np.copyto(dst, res)
        return dst
    return np.ascontiguousarray(res)


def _concat(parts, axis, name, dst):
    arrs = [_canon(_arr(p, name)) for p in parts]
    if not arrs:
        raise error(f"{name}: (-215:Assertion failed) !src.empty()")
    first = arrs[0]
    for p in arrs:
        if p.dtype != first.dtype or p.ndim != first.ndim or any(
                p.shape[i] != first.shape[i] for i in range(first.ndim) if i != axis):
            raise error(f"{name}: (-215:Assertion failed) all inputs must have matching size/depth/channels")
    return _finish_copy(np.concatenate(arrs, axis=axis), dst)


def hconcat(src, dst=None):
    return _concat(src, 1, "hconcat", dst)


def vconcat(src, dst=None):
    return _concat(src, 0, "vconcat", dst)


def concat(src, axis, dst=None):
    first = _canon(_arr(src[0], "concat")) if len(src) else None
    nd = first.ndim if first is not None else 2
    if axis < 0:
        axis += nd
    if axis not in range(nd):
        raise error("concat: (-215:Assertion failed) axis out of range")
    return _concat(src, axis, "concat", dst)


def borderInterpolate(p, len, borderType):  # noqa: A002 (cv2 signature)
    r = _border_interp(int(p), int(len), int(borderType))
    if r == -2:
        raise error("borderInterpolate: (-5:Bad argument) Unknown/unsupported border type")
    return int(r)


def copyMakeBorder(src, top, bottom, left, right, borderType, dst=None, value=None):
    a = _contig(_canon(_arr(src)))
    if a.size == 0:
        raise error("copyMakeBorder: (-215:Assertion failed) !_src.empty()")
    if top < 0 or bottom < 0 or left < 0 or right < 0:
        raise error("copyMakeBorder: (-215:Assertion failed) top >= 0 && bottom >= 0 && left >= 0 && right >= 0")
    h, w = a.shape[0] + top + bottom, a.shape[1] + left + right
    res, fin = _out(dst, _shape_hwc(h, w, _cn(a)), a.dtype)
    val = _scalar4(value if value is not None else 0, False)
    bt = int(borderType)
    if (bt & ~C.BORDER_ISOLATED) == 0 and _cn(a) > 4 and not (val[0] == val[1] == val[2] == val[3]):
        raise error("copyMakeBorder: (-215:Assertion failed) value[0] == value[1] && value[0] == value[2] && value[0] == value[3]")
    if not (top or bottom or left or right):
        np.copyto(res, a)
        return fin()
    if (bt & ~C.BORDER_ISOLATED) not in (0, 1, 2, 3, 4):
        raise error("copyMakeBorder: (-5:Bad argument) Unknown/unsupported border type")
    _chk(_copyborder(_byref(_mat(a)), _byref(_mat(res)), int(top), int(left), bt, val), "copyMakeBorder")
    return fin()


def LUT(src, lut, dst=None):
    a = _contig(_canon(_arr(src)))
    if a.dtype not in (np.dtype(np.uint8), np.dtype(np.int8)):
        raise error("LUT: (-215:Assertion failed) _src.type() == CV_8UC1 || CV_8SC1 etc.")
    l = np.asarray(lut)
    if l.dtype not in _DEPTH:
        raise error("LUT: unsupported lut type")
    lcn = l.shape[2] if l.ndim == 3 else 1
    if l.size != 256 * lcn or (lcn != 1 and lcn != _cn(a)):
        raise error("LUT: (-215:Assertion failed) (lutcn == cn || lutcn == 1) && _lut.total() == 256 && _lut.isContinuous()")
    l = np.ascontiguousarray(l)
    res, fin = _out(dst, a.shape, l.dtype)
    _chk(_lut(_byref(_mat(a)), l.ctypes.data, lcn, _byref(_mat(res))), "LUT")
    return fin()



# ------------------------------------------------------------------------------------------ reductions
_reduce = _fn("sr_core_reduce", [_VP, _VP, _I32, _I32])
_norm = _fn("sr_core_norm", [_VP, _VP, _VP, _I32, _VP])
_sums = _fn("sr_core_sums", [_VP, _VP, _VP, _I32])
_mmloc = _fn("sr_core_minmaxloc", [_VP, _VP, _VP])
_cnz = _fn("sr_core_countnonzero", [_VP, _VP])
_fnz = _fn("sr_core_findnonzero", [_VP, _VP, ctypes.c_int64, _VP])

_SUM_OK = {0: {4, 5, 6}, 1: {4, 5, 6}, 2: {5, 6}, 3: {5, 6}, 4: {6}, 5: {5, 6}, 6: {6}}
_AVG_OK = {0: set(range(7)), 1: set(range(7)), 2: {5, 6}, 3: {5, 6}, 4: {6}, 5: {5, 6}, 6: {6}}


def reduce(src, dim, rtype, dst=None, dtype=-1):
    a = _contig(_canon(_arr(src)))
    if dim not in (0, 1):
        raise error("reduce: (-215:Assertion failed) dim == 0 || dim == 1")
    if rtype not in (0, 1, 2, 3):
        raise error("reduce: (-5:Bad argument) Unknown reduce operation")
    sd = _DEPTH[a.dtype]
    dd = sd if dtype is None or dtype < 0 else int(dtype)
    if dd >= len(_DT):
        raise error("reduce: unsupported dtype")
    ok = (_SUM_OK if rtype == 0 else _AVG_OK if rtype == 1 else {sd: {sd}} if True else {})
    allowed = ok.get(sd, set()) if rtype < 2 else {sd}
    if dd not in allowed:
        raise error("reduce: (-210:Unsupported format or combination of formats) Unsupported combination of input and "
                    "output array formats")
    shape = _shape_hwc(1, a.shape[1], _cn(a)) if dim == 0 else _shape_hwc(a.shape[0], 1, _cn(a))
    if not (a.shape[0] and a.shape[1]):   # cv2 returns an empty array of the input's shape
        return _finish_copy(np.empty(a.shape, _DT[dd]), dst)
    res, fin = _out(dst, shape, _DT[dd])
    if a.shape[0] and a.shape[1]:
        _chk(_reduce(_byref(_mat(a)), _byref(_mat(res)), int(dim), int(rtype)), "reduce")
    return fin()


def _arg_reduce(src, axis, dst, last, is_max, name):
    a = _canon(_arr(src))
    if _cn(a) != 1 or axis not in (0, 1):
        raise error(f"{name}: (-215:Assertion failed) srcMat.channels() == 1 && axis >= 0 && axis <= srcMat.dims")
    v = a[:, ::-1] if (last and axis == 1) else (a[::-1] if last and axis == 0 else a)
    idx = (np.argmax if is_max else np.argmin)(v, axis=axis).astype(np.int32)
    if last:
        n = a.shape[axis]
        idx = (n - 1 - idx).astype(np.int32)
    idx = idx.reshape(1, -1) if axis == 0 else idx.reshape(-1, 1)
    return _finish_copy(idx, dst)


def reduceArgMax(src, axis, dst=None, lastIndex=False):
    return _arg_reduce(src, axis, dst, lastIndex, True, "reduceArgMax")


def reduceArgMin(src, axis, dst=None, lastIndex=False):
    return _arg_reduce(src, axis, dst, lastIndex, False, "reduceArgMin")


def _mask_for(mask, a, name):
    return _mask_arr(mask, a.shape[0], a.shape[1], name)


def norm(src1, *args, **kw):
    """norm(src1[, normType[, mask]]) and norm(src1, src2[, normType[, mask]])."""
    args = list(args)
    src2 = kw.pop("src2", None)
    normType = kw.pop("normType", None)
    mask = kw.pop("mask", None)
    if kw:
        raise error(f"norm: unexpected keyword arguments {sorted(kw)}")
    if args and (src2 is not None or not isinstance(args[0], (int, np.integer))):
        src2 = args.pop(0)
    if args:
        normType = args.pop(0)
    if args:
        mask = args.pop(0)
    if args:
        raise error("norm: too many arguments")
    nt = C.NORM_L2 if normType is None else int(normType)
    a = _contig(_canon(_arr(src1, "src1")))
    base = nt & 7
    rel = bool(nt & C.NORM_RELATIVE) and src2 is not None   # cv2 ignores NORM_RELATIVE without a second array
    if base not in (1, 2, 4, 5, 6, 7):   # cv2 only looks at the low three bits (+ NORM_RELATIVE); NORM_MINMAX alone is invalid
        raise error("norm: (-215:Assertion failed) normType == NORM_INF || normType == NORM_L1 || normType == NORM_L2 || "
                    "normType == NORM_L2SQR || ((normType == NORM_HAMMING || normType == NORM_HAMMING2) && src.type() == CV_8U)")
    if base in (6, 7) and (a.dtype != np.uint8 or _cn(a) != 1):
        raise error("norm: (-215:Assertion failed) NORM_HAMMING requires CV_8UC1")
    m = _mask_for(mask, a, "mask")
    b = None
    if src2 is not None:
        b = _contig(_canon(_arr(src2, "src2")))
        if b.shape != a.shape or b.dtype != a.dtype:
            raise error("norm: (-209:Sizes of input arguments do not match) src1 and src2 must have the same size and type")
    out = (ctypes.c_double * 1)()
    mm = _byref(_mat(m)) if m is not None else None
    _chk(_norm(_byref(_mat(a)), _byref(_mat(b)) if b is not None else None, mm, base, out), "norm")
    val = out[0]
    if rel:
        out2 = (ctypes.c_double * 1)()
        _chk(_norm(_byref(_mat(b)), None, mm, base, out2), "norm")
        val = val / (out2[0] + 2.220446049250313e-16)
    return float(val)


try:
    _fma = _lib_.sr_core_fma
    _fma.argtypes = [_F64, _F64, _F64]
    _fma.restype = _F64
except AttributeError:  # stale dylib: unfused (differs from cv2 in the last bits of the standard deviation)
    def _fma(a, b, c):
        return a * b + c


def _sums_of(a, m, want_sq=True):
    out = (ctypes.c_double * 9)()
    _chk(_sums(_byref(_mat(a)), _byref(_mat(m)) if m is not None else None, out, int(want_sq)), "mean")
    return out


def mean(src, mask=None):
    a = _contig(_canon(_arr(src)))
    if _cn(a) > 4:
        raise error("mean: (-215:Assertion failed) cn <= 4")
    m = _mask_for(mask, a, "mask")
    o = _sums_of(a, m, False)
    nz = o[8]
    inv = 1.0 / nz if nz else 0.0
    return tuple(float(o[c] * inv) for c in range(4))


def meanStdDev(src, mean=None, stddev=None, mask=None):  # noqa: A002 (cv2 signature)
    a = _contig(_canon(_arr(src)))
    cn = _cn(a)
    if cn > 4:
        raise error("meanStdDev: (-215:Assertion failed) cn <= 4")
    m = _mask_for(mask, a, "mask")
    o = _sums_of(a, m)
    nz = o[8]
    inv = 1.0 / nz if nz else 0.0
    mu = np.array([o[c] * inv for c in range(cn)], dtype=np.float64)
    # cv2 evaluates sq * scale - mean * mean as one fused multiply-add (bit-exact for constant and random images)
    var = np.array([builtins.max(_fma(o[4 + c], inv, -(float(mu[c]) * float(mu[c]))), 0.0) for c in range(cn)], dtype=np.float64)
    return mu.reshape(cn, 1), np.sqrt(var).reshape(cn, 1)


def sumElems(src):
    a = _contig(_canon(_arr(src)))
    if _cn(a) > 4:
        raise error("sumElems: (-215:Assertion failed) cn <= 4")
    o = _sums_of(a, None, False)
    return tuple(float(o[c]) for c in range(4))


def minMaxLoc(src, mask=None):
    if isinstance(src, np.ndarray) and src.ndim == 1:
        src = src.reshape(1, -1)
        mask = mask.reshape(1, -1) if isinstance(mask, np.ndarray) and mask.ndim == 1 else mask
    a = _contig(_canon(_arr(src)))
    if _cn(a) != 1:
        raise error("minMaxLoc: (-215:Assertion failed) (cn == 1 && (_mask.empty() || _mask.type() == CV_8U)) || "
                    "(cn > 1 && _mask.empty() && !minIdx && !maxIdx)")
    m = _mask_for(mask, a, "mask")
    out = (ctypes.c_double * 7)()
    _chk(_mmloc(_byref(_mat(a)), _byref(_mat(m)) if m is not None else None, out), "minMaxLoc")
    return float(out[0]), float(out[1]), (int(out[2]), int(out[3])), (int(out[4]), int(out[5]))


def countNonZero(src):
    a = _contig(_canon(_arr(src)))
    if _cn(a) != 1:
        raise error("countNonZero: (-215:Assertion failed) cn == 1")
    out = (ctypes.c_int64 * 1)()
    _chk(_cnz(_byref(_mat(a)), out), "countNonZero")
    return int(out[0])


def hasNonZero(src):
    return countNonZero(src) > 0


def findNonZero(src, idx=None):
    a = _contig(_canon(_arr(src)))
    if _cn(a) != 1:
        raise error("findNonZero: (-215:Assertion failed) cn == 1")
    cnt = countNonZero(a)
    if cnt == 0:
        return None
    res = np.empty((cnt, 2), np.int32)
    out = (ctypes.c_int64 * 1)()
    _chk(_fnz(_byref(_mat(a)), res.ctypes.data, cnt, out), "findNonZero")
    return res


def normalize(src, dst, alpha=1.0, beta=0.0, norm_type=C.NORM_L2, dtype=-1, mask=None):
    a = _contig(_canon(_arr(src)))
    ddt = _DT[_DEPTH[a.dtype]] if dtype is None or dtype < 0 else _depth_dtype(dtype, a.dtype)
    m = _mask_for(mask, a, "mask")
    nt = int(norm_type)
    if nt == C.NORM_MINMAX:
        if _cn(a) != 1:
            if m is not None:
                raise error("normalize: (-215:Assertion failed) (cn == 1 && (_mask.empty() || _mask.type() == CV_8U)) || "
                            "(cn > 1 && _mask.empty() && !minIdx && !maxIdx)")
            lo, hi = _minmax_all_channels(a, m)
        else:
            lo, hi, _, _ = minMaxLoc(a, m)
        dmin, dmax = (alpha, beta) if alpha <= beta else (beta, alpha)
        rng = hi - lo
        scale = (dmax - dmin) * (1.0 / rng if rng > 2.220446049250313e-16 else 0.0)
        shift = dmin - lo * scale
        if _DEPTH[ddt] == 5:   # cv::normalize rounds both to float for a CV_32F result
            scale = float(np.float32(scale))
            shift = float(np.float32(dmin)) - float(np.float32(lo * scale))
    elif nt in (C.NORM_INF, C.NORM_L1, C.NORM_L2):
        n = norm(a, nt, m) if m is not None else norm(a, nt)
        scale = alpha / n if n > 2.220446049250313e-16 else 0.0
        shift = 0.0
    else:
        raise error("normalize: (-215:Assertion failed) norm_type == NORM_INF || NORM_L1 || NORM_L2 || NORM_MINMAX")
    res, fin = _out(dst, a.shape, ddt, zero=m is not None)
    if m is None:
        _chk(_convert(_byref(_mat(a)), _byref(_mat(res)), float(scale), float(shift), 0), "normalize")
    else:
        tmp = np.empty(a.shape, ddt)
        _chk(_convert(_byref(_mat(a)), _byref(_mat(tmp)), float(scale), float(shift), 0), "normalize")
        sel = m != 0
        res[sel] = tmp[sel]
    return fin()


def _minmax_all_channels(a, m):
    flat = a.reshape(a.shape[0], -1)
    if m is not None:
        sel = np.repeat(m != 0, _cn(a), axis=1)
        v = flat[sel]
    else:
        v = flat
    if v.size == 0:
        return 0.0, 0.0
    return float(v.min()), float(v.max())



# ------------------------------------------------------------------------------------------ math
_math = _fn("sr_core_math", [_I32, _VP, _VP])
_pow = _fn("sr_core_pow", [_VP, _VP, _F64])
_magnitude = _fn("sr_core_magnitude", [_VP, _VP, _VP])
_phase = _fn("sr_core_phase", [_VP, _VP, _VP, _I32])
_p2c = _fn("sr_core_polar2cart", [_VP, _VP, _VP, _VP, _I32])
try:
    _atan2 = _lib_.sr_core_fastatan2
    _atan2.argtypes = [_F64, _F64]
    _atan2.restype = _F64
except AttributeError:  # stale dylib
    _atan2 = None


def _math_call(op, src, dst, name):
    a = _contig(_canon(_arr(src)))
    if a.dtype.kind != "f":
        raise error(f"{name}: (-215:Assertion failed) depth == CV_16F || depth == CV_16BF || depth == CV_32F || depth == CV_64F")
    res, fin = _out(dst, a.shape, a.dtype)
    if a.size:
        _chk(_math(op, _byref(_mat(a)), _byref(_mat(res))), name)
    return fin()


def sqrt(src, dst=None):
    return _math_call(0, src, dst, "sqrt")


def exp(src, dst=None):
    return _math_call(1, src, dst, "exp")


def log(src, dst=None):
    return _math_call(2, src, dst, "log")


def pow(src, power, dst=None):  # noqa: A001 (cv2.pow)
    a = _contig(_canon(_arr(src)))
    res, fin = _out(dst, a.shape, a.dtype)
    if a.size:
        _chk(_pow(_byref(_mat(a)), _byref(_mat(res)), float(power)), "pow")
    return fin()


def _float_pair(x, y, name):
    a, b = _contig(_canon(_arr(x, "x"))), _contig(_canon(_arr(y, "y")))
    if a.shape != b.shape or a.dtype != b.dtype or a.dtype.kind != "f":
        raise error(f"{name}: (-215:Assertion failed) x.size() == y.size() && x.type() == y.type() && "
                    f"(depth == CV_32F || depth == CV_64F)")
    return a, b


def magnitude(x, y, magnitude=None):  # noqa: A002 (cv2 signature)
    a, b = _float_pair(x, y, "magnitude")
    res, fin = _out(magnitude, a.shape, a.dtype)
    if a.size:
        _chk(_magnitude(_byref(_mat(a)), _byref(_mat(b)), _byref(_mat(res))), "magnitude")
    return fin()


def phase(x, y, angle=None, angleInDegrees=False):
    a, b = _float_pair(x, y, "phase")
    res, fin = _out(angle, a.shape, a.dtype)
    if a.size:
        _chk(_phase(_byref(_mat(a)), _byref(_mat(b)), _byref(_mat(res)), int(bool(angleInDegrees))), "phase")
    return fin()


def cartToPolar(x, y, magnitude=None, angle=None, angleInDegrees=False):  # noqa: A002
    return (globals()["magnitude"](x, y, magnitude), phase(x, y, angle, angleInDegrees))


def polarToCart(magnitude, angle, x=None, y=None, angleInDegrees=False):  # noqa: A002
    ang = _contig(_canon(_arr(angle, "angle")))
    if ang.dtype.kind != "f":
        raise error("polarToCart: (-215:Assertion failed) angle depth == CV_32F || CV_64F")
    mg = None
    if magnitude is not None and not (isinstance(magnitude, np.ndarray) and magnitude.size == 0):
        mg = _contig(_canon(_arr(magnitude, "magnitude")))
        if mg.shape != ang.shape or mg.dtype != ang.dtype:
            raise error("polarToCart: (-215:Assertion failed) magnitude.size() == angle.size() && magnitude.type() == angle.type()")
    rx, fx = _out(x, ang.shape, ang.dtype)
    ry, fy = _out(y, ang.shape, ang.dtype)
    if ang.size:
        _chk(_p2c(_byref(_mat(mg)) if mg is not None else None, _byref(_mat(ang)), _byref(_mat(rx)), _byref(_mat(ry)),
                  int(bool(angleInDegrees))), "polarToCart")
    return fx(), fy()


def fastAtan2(y, x):
    if _atan2 is None:
        raise error("fastAtan2: libSafariumRaster is missing sr_core_fastatan2")
    return float(_atan2(float(y), float(x)))


def cubeRoot(val):
    v = float(val)
    r = abs(v) ** (1.0 / 3.0)
    if r:  # one Newton step restores the last bits lost by the fractional power
        r = r - (r * r * r - abs(v)) / (3.0 * r * r)
    return float(np.float32(-r if v < 0 else r))


def checkRange(a, quiet=True, minVal=-1.7976931348623157e308, maxVal=1.7976931348623157e308):
    x = _canon(_arr(a))
    v = x.astype(np.float64) if x.dtype.kind != "f" else x
    ok = (v >= minVal) & (v < maxVal)
    if x.dtype.kind == "f":
        ok &= np.isfinite(v)
    if ok.all():
        return True, (0, 0)
    bad = np.argwhere(~ok)[0]
    y, xx = int(bad[0]), int(bad[1])
    if not quiet:
        val = x[y, xx] if x.ndim == 2 else x[y, xx, int(bad[2])]
        raise error(f"checkRange: (-211:One of the arguments' values is out of range) the value at ({xx}, {y})="
                    f"{np.atleast_1d(val).tolist()} is out of range [{float(minVal):f}, {float(maxVal):f})")
    return False, (xx, y)


def patchNaNs(a, val=0.0):
    if not isinstance(a, np.ndarray) or a.dtype.kind != "f":
        raise error("patchNaNs: (-215:Assertion failed) a.depth() == CV_32F")
    if a.dtype == np.float32 or a.dtype == np.float64:
        a[np.isnan(a)] = val
    return a


def finiteMask(src, mask=None):
    x = _canon(_arr(src))
    if x.dtype.kind != "f":
        fin = np.ones(x.shape, bool)
    else:
        fin = np.isfinite(x)
    if fin.ndim == 3:
        fin = fin.all(axis=2)
    res = np.where(fin, np.uint8(255), np.uint8(0)).astype(np.uint8)
    return _finish_copy(res, mask)


# ------------------------------------------------------------------------------------------ sort / matrix helpers
def _sort_axis(flags, name):
    flags = int(flags)   # cv::sort only looks at the EVERY_COLUMN (1) and DESCENDING (16) bits
    return (0 if flags & C.SORT_EVERY_COLUMN else 1), bool(flags & C.SORT_DESCENDING)


def sort(src, flags, dst=None):
    a = _canon(_arr(src))
    axis, desc = _sort_axis(flags, "sort")
    if _cn(a) != 1:
        raise error("sort: (-215:Assertion failed) src.isContinuous() && src.channels() == 1")
    res = np.sort(a, axis=axis)   # values only: stability is unobservable, so the fastest kind is used
    if desc:
        res = np.flip(res, axis=axis)
    return _finish_copy(res, dst)


def sortIdx(src, flags, dst=None):
    a = _canon(_arr(src))
    axis, desc = _sort_axis(flags, "sortIdx")
    if _cn(a) != 1:
        raise error("sortIdx: (-215:Assertion failed) src.data != dst.data && src.channels() == 1")
    idx = np.argsort(a, axis=axis, kind="stable")
    if desc:
        idx = np.flip(idx, axis=axis)
    return _finish_copy(idx.astype(np.int32), dst)


def setIdentity(mtx, s=1):
    if not isinstance(mtx, np.ndarray):
        raise error("setIdentity: mtx must be a numpy array")
    m = _canon(mtx) if mtx.ndim == 3 and mtx.shape[2] == 1 else mtx
    val = _scalar4(s, False)
    if m.ndim == 2:
        m[...] = 0
        k = builtins.min(m.shape)
        m[np.arange(k), np.arange(k)] = _sat_cast([val[0]], m.dtype)[0]
    else:
        m[...] = 0
        k = builtins.min(m.shape[:2])
        for c in range(m.shape[2]):
            m[np.arange(k), np.arange(k), c] = _sat_cast([val[c] if c < 4 else 0.0], m.dtype)[0]
    return mtx


def completeSymm(m, lowerToUpper=False):
    if not isinstance(m, np.ndarray) or m.ndim not in (2, 3) or m.shape[0] != m.shape[1]:
        raise error("completeSymm: (-215:Assertion failed) m.dims <= 2 && m.rows == m.cols")
    n = m.shape[0]
    i, j = np.triu_indices(n, 1)
    if lowerToUpper:
        m[i, j] = m[j, i]
    else:
        m[j, i] = m[i, j]
    return m


def trace(mtx):
    a = _canon(_arr(mtx))
    k = builtins.min(a.shape[:2])
    d = a[np.arange(k), np.arange(k)].astype(np.float64)
    if a.ndim == 2:
        return (float(d.sum()), 0.0, 0.0, 0.0)
    sums = d.sum(axis=0)
    return tuple(float(sums[c]) if c < len(sums) else 0.0 for c in range(4))


def determinant(mtx):
    a = _arr(mtx)
    a = _canon(a)
    if a.ndim != 2 or a.shape[0] != a.shape[1] or a.dtype.kind != "f" or a.dtype.itemsize < 4:
        raise error("determinant: (-215:Assertion failed) mat.rows == mat.cols && (type == CV_32F || type == CV_64F)")
    n = a.shape[0]
    m = a.astype(np.float64)
    if n == 1:
        return float(m[0, 0])
    if n == 2:
        return float(m[0, 0] * m[1, 1] - m[0, 1] * m[1, 0])
    if n == 3:
        return float(m[0, 0] * (m[1, 1] * m[2, 2] - m[1, 2] * m[2, 1]) - m[0, 1] * (m[1, 0] * m[2, 2] - m[1, 2] * m[2, 0])
                     + m[0, 2] * (m[1, 0] * m[2, 1] - m[1, 1] * m[2, 0]))
    return float(np.linalg.det(m))


_DFT_SIZES = None


def getOptimalDFTSize(vecsize):
    global _DFT_SIZES
    if _DFT_SIZES is None:
        lim = 2146435072
        out = []
        p2 = 1
        while p2 <= lim:
            p3 = p2
            while p3 <= lim:
                p5 = p3
                while p5 <= lim:
                    out.append(p5)
                    p5 *= 5
                p3 *= 3
            p2 *= 2
        _DFT_SIZES = sorted(out)
    v = int(vecsize)
    if v < 0 or v > _DFT_SIZES[-1]:
        return -1
    import bisect
    return _DFT_SIZES[bisect.bisect_left(_DFT_SIZES, builtins.max(v, 1))]


# ------------------------------------------------------------------------------------------ 5.x N-d helpers (numpy-backed)
def copyTo(src, mask, dst=None):
    a = _arr(src)
    m = _mask_arr(mask, a.shape[0], a.shape[1]) if mask is not None else None
    if m is None:
        return _finish_copy(a.copy(), dst)
    if isinstance(dst, np.ndarray) and dst.shape == a.shape and dst.dtype == a.dtype:
        out = dst
    else:
        out = np.zeros_like(a)
    sel = m != 0
    out[sel] = a[sel]
    return out


def flatten(src, dst=None, startAxis=0, endAxis=-1):
    a = _arr(src)
    if startAxis != 0 or endAxis not in (-1,):
        raise error("flatten: only the default axes are supported by the Safarium shim")
    res = a.reshape(-1) if a.ndim == 2 else a.reshape(-1, a.shape[2])
    return _finish_copy(res, dst)


def reshape(src, newShape, dst=None, allowZero=False):
    """cv::reshape on a (rows, cols[, channels]) Mat: only the spatial dims are reshaped, channels ride along."""
    a = _canon(_arr(src))
    shp = [int(v) for v in newShape]
    if not allowZero:
        shp = [a.shape[i] if (v == 0 and i < 2) else v for i, v in enumerate(shp)]
    try:
        if a.ndim == 2:
            res = a.reshape(shp)
        else:
            res = a.reshape(-1, a.shape[2]).reshape(shp + [a.shape[2]])
    except ValueError as e:
        raise error(f"reshape: (-5:Bad argument) reshape: the number of elements does not match: {e}")
    return _finish_copy(res, dst)


def transposeND(src, order, dst=None):
    a = _arr(src)
    order = [int(v) for v in order]
    if len(order) != 2 or sorted(order) != [0, 1]:
        raise error("transposeND: (-215:Assertion failed) order.size() == static_cast<size_t>(ndims)")
    res = np.transpose(a, (order[0], order[1]) + ((2,) if a.ndim == 3 else ()))
    return _finish_copy(res, dst)


def flipND(src, axis, dst=None):
    a = _arr(src)
    if axis < 0:
        axis += 2
    if axis not in (0, 1):
        raise error("flipND: (-215:Assertion failed) axis out of range")
    return _finish_copy(np.flip(a, axis=axis), dst)


def squeeze(src, dst=None, axes=None):
    a = _canon(_arr(src)) if isinstance(src, np.ndarray) and src.ndim in (2, 3) else np.asarray(src)
    if a.ndim == 3:
        keep = [i for i in range(3) if not (i < 2 and a.shape[i] == 1)]
        return _finish_copy(a.reshape([a.shape[i] for i in keep]), dst)
    return _finish_copy(np.squeeze(a), dst)


def unsqueeze(src, axes, dst=None):
    a = np.asarray(src)
    return _finish_copy(np.expand_dims(a, tuple(int(v) for v in axes)), dst)


def broadcast(src, shape, dst=None):
    a = np.asarray(src)
    if not isinstance(shape, np.ndarray) or shape.dtype != np.int32:
        raise error("broadcast: (-215:Assertion failed) shape.type() == CV_32S")
    try:
        res = np.broadcast_to(a, tuple(int(v) for v in shape.ravel()))
    except ValueError as e:
        raise error(f"broadcast: (-215:Assertion failed) {e}")
    return _finish_copy(res, dst)


def slice(src, starts, ends, steps, dst=None):  # noqa: A001 (cv2.slice)
    a = _arr(src)
    idx = tuple(builtins.slice(int(b), int(e), int(st)) for b, e, st in zip(starts, ends, steps))
    return _finish_copy(a[idx], dst)


# ------------------------------------------------------------------------------------------ system / info
def getTickCount() -> int:
    return int(_time.monotonic_ns())


def getTickFrequency() -> float:
    return 1e9


def getCPUTickCount() -> int:
    return int(_time.perf_counter_ns())


def getNumberOfCPUs() -> int:
    import os
    return int(os.cpu_count() or 1)


def getThreadNum() -> int:
    return 0


def checkHardwareSupport(feature) -> bool:
    return False


_optimized = True


def useOptimized() -> bool:
    return _optimized


def setUseOptimized(onoff) -> None:
    global _optimized
    _optimized = bool(onoff)


def getVersionMajor() -> int:
    return 5


def getVersionMinor() -> int:
    return 1


def getVersionRevision() -> int:
    return 0


def getVersionString() -> str:
    return "5.1.0"


def getBuildInformation() -> str:
    return ("General configuration for OpenCV 5.1.0 (API-compatible) =====================================\n"
            "  Safarium: libSafariumRaster (Accelerate, vImage, CoreGraphics, ImageIO, AVFoundation); no OpenCV, no FFmpeg\n")



# ------------------------------------------------------------------------------------------ random (cv::RNG stream)
_set_seed = _lib_.sr_core_set_rng_seed if hasattr(_lib_, "sr_core_set_rng_seed") else None
if _set_seed is not None:
    _set_seed.argtypes = [ctypes.c_uint64]
    _set_seed.restype = _I32
_randu = _fn("sr_core_randu", [_VP, _VP, _VP])
_randn = _fn("sr_core_randn", [_VP, _VP, _VP])
_randshuffle = _fn("sr_core_randshuffle", [_VP, _F64])


def setRNGSeed(seed) -> None:
    if _set_seed is None:
        raise error("setRNGSeed: libSafariumRaster is missing sr_core_set_rng_seed")
    s = int(seed)
    # cv::setRNGSeed(int): a negative int widens to uint64 by sign extension
    _set_seed(s & 0xFFFFFFFFFFFFFFFF)


def _rng_target(dst, name):
    if not isinstance(dst, np.ndarray):
        raise error(f"{name}: dst must be a numpy array")
    if dst.ndim == 1:   # a 1-D array is one row; the view shares memory so the fill is in place
        view = dst.reshape(1, -1)
        if not np.shares_memory(view, dst):
            raise error(f"{name}: non-contiguous 1-D destination is not supported")
        dst = view
    d = _canon(dst) if dst.ndim == 3 and dst.shape[2] == 1 else dst
    if d.dtype not in _DEPTH or d.ndim not in (2, 3) or (d.ndim == 3 and d.shape[2] > 4):
        raise error(f"{name}: unsupported destination")
    if not _usable(d):
        raise error(f"{name}: non-contiguous destination is not supported")
    return d


def randu(dst, low, high):
    d = _rng_target(dst, "randu")
    _chk(_randu(_byref(_mat(d)), _scalar4(low, False), _scalar4(high, False)), "randu")
    return dst


def randn(dst, mean, stddev):
    d = _rng_target(dst, "randn")
    _chk(_randn(_byref(_mat(d)), _scalar4(mean, False), _scalar4(stddev, False)), "randn")
    return dst


def randShuffle(dst, iterFactor=1.0):
    d = _rng_target(dst, "randShuffle")
    if not _usable(d) or (d.shape[0] > 1 and d.strides[0] != d.shape[1] * (d.shape[2] if d.ndim == 3 else 1) * d.itemsize):
        raise error("randShuffle: non-contiguous destination is not supported")
    _chk(_randshuffle(_byref(_mat(d)), float(iterFactor)), "randShuffle")
    return dst


# ------------------------------------------------------------------------------------------ optional C bridge (_srcore)
# cv2/_srcore.c (built by sdk/python/safarium_cv2/build_core.sh) re-implements the argument handling of the hottest
# functions in C and hands anything unusual back to the Python versions above. Without the extension, or with
# SAFARIUM_NO_SRCORE=1, everything stays on the ctypes path.
_FAST_NAMES = ("add", "subtract", "absdiff", "multiply", "divide", "addWeighted", "convertScaleAbs", "bitwise_and", "bitwise_or",
               "bitwise_xor", "bitwise_not", "compare", "inRange", "min", "max", "sqrt", "exp", "log", "pow", "magnitude", "LUT",
               "reduce", "norm", "mean", "meanStdDev", "minMaxLoc", "countNonZero", "split", "merge", "flip", "rotate", "transpose",
               "copyMakeBorder", "hconcat", "vconcat")
_py_core = {_n: globals()[_n] for _n in _FAST_NAMES}
fast = None
if not os.environ.get("SAFARIUM_NO_SRCORE"):
    try:
        from . import _srcore  # built by sdk/python/safarium_cv2/build_core.sh

        _srcore.init(_lib_._name, error, _py_core)
        for _n in _FAST_NAMES:
            globals()[_n] = getattr(_srcore, _n)
        fast = _srcore
    except Exception:  # extension not built / dylib too old: stay on the ctypes path
        fast = None

__all__ = list(_EXTRA_CONSTANTS) + [
    "add", "subtract", "absdiff", "multiply", "divide", "addWeighted", "scaleAdd", "convertScaleAbs",
    "bitwise_and", "bitwise_or", "bitwise_xor", "bitwise_not", "compare", "inRange", "min", "max",
    "split", "merge", "mixChannels", "extractChannel", "insertChannel", "flip", "rotate", "transpose", "repeat",
    "hconcat", "vconcat", "concat", "borderInterpolate", "copyMakeBorder", "LUT",
    "reduce", "reduceArgMax", "reduceArgMin", "norm", "mean", "meanStdDev", "sumElems", "minMaxLoc", "countNonZero",
    "hasNonZero", "findNonZero", "normalize",
    "sqrt", "exp", "log", "pow", "magnitude", "phase", "cartToPolar", "polarToCart", "fastAtan2", "cubeRoot",
    "checkRange", "patchNaNs", "finiteMask", "sort", "sortIdx", "setIdentity", "completeSymm", "trace", "determinant",
    "getOptimalDFTSize", "copyTo", "flatten", "reshape", "transposeND", "flipND", "squeeze", "unsqueeze", "broadcast",
    "slice", "getTickCount", "getTickFrequency", "getCPUTickCount", "getNumberOfCPUs", "getThreadNum",
    "checkHardwareSupport", "useOptimized", "setUseOptimized", "getVersionMajor", "getVersionMinor",
    "getVersionRevision", "getVersionString", "getBuildInformation", "setRNGSeed", "randu", "randn", "randShuffle",
]
