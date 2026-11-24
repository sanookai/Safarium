"""Opt-in Metal (GPU) paths for compute-bound core ops (Pick 2026-11-24, docs/raster-roadmap.md section 5).

Public API (re-exported by cv2/__init__.py):
    cv2.safarium_set_gpu(enabled: bool)   switch the GPU paths on or off (default: off, or SAFARIUM_GPU=1 in the environment)
    cv2.safarium_get_gpu() -> bool        the switch as last set (round-trips; says nothing about Metal being present)
    cv2.safarium_gpu_available() -> bool  True when a Metal device and the embedded shaders are usable

Contract:
  * OFF (the default): this module touches nothing. cv2.sqrt, cv2.exp ... stay the exact CPU functions from _core.py /
    _srcore, byte-identical to a build without this file. No wrapper sits in front of them.
  * ON: the ops below are replaced (in the cv2 package namespace only) by thin wrappers. A wrapper uses Metal only when
    every condition holds: float32 data, usable layout, element count >= the per-op threshold (calibrated crossover where
    the GPU is faster end-to-end, including dispatch and page mapping), no partial aliasing, and the dylib reports a
    working GPU. Anything else, and any GPU error, runs the unchanged CPU function. The CPU function also produces every
    cv2-style error, so error behaviour does not depend on the switch.
  * Results with the GPU on may differ slightly from OpenCV (tolerances per op: see TOLERANCE below and tests/test_gpu.py).
  * Single worker (SF-VIDEO-1): one Metal device, one command queue, one dispatch at a time, synchronous. No threads here.
  * `from cv2 import sqrt` taken while the GPU was on keeps the wrapper; the wrapper re-checks the switch on every call.

Ops covered: float32 sqrt, exp, log, pow (non-integer power), magnitude, phase, cartToPolar, polarToCart;
uint8 multiply (two arrays) and addWeighted. See _THRESHOLDS for which of them the GPU actually wins.
"""
from __future__ import annotations

import ctypes
import os
import sys

import numpy as np

from . import _core
from . import _lib

__all__ = ["safarium_set_gpu", "safarium_get_gpu", "safarium_gpu_available"]

# Documented accuracy of the GPU result against OpenCV (tests/test_gpu.py asserts these bounds on random data).
# Float32 distances are in ulps. Denormal inputs/intermediates may flush to zero on the GPU (e.g. magnitude of values
# below ~1e-19, where the squares are denormal); the CPU path keeps them.
TOLERANCE = {
    "sqrt": "0 ulp (IEEE, correctly rounded)",
    "exp": "<= 3 ulp (measured 2)",
    "log": "<= 4 ulp, plus 2e-7 absolute near log(x) = 0 (measured 2 ulp)",
    "pow": "non-integer powers: <= 8 ulp against float64 truth (measured 5 for |p| <= 3.3), rel. 2e-6 against OpenCV, "
           "whose own float32 pow is up to ~26 ulp off truth there (75 ulp at p = 10.5)",
    "magnitude": "<= 4 ulp",
    "phase": "<= 4 ulp (same polynomial as the CPU path); degrees and radians",
    "cartToPolar": "magnitude <= 4 ulp, angle <= 4 ulp (one fused dispatch)",
    "polarToCart": "|error| <= 4e-7 * max|magnitude| for |angle| <= 100 rad (float32 argument reduction beyond that)",
    "multiply": "uint8: exact for scale = 1; <= 1 LSB otherwise (measured: 0.02 % of pixels differ by 1)",
    "addWeighted": "uint8: <= 1 LSB (measured: identical)",
}

# Minimum element count (rows * cols * channels) per op for the GPU to be used. Calibrated from the interleaved A/B sweep
# (GPU wall time incl. dispatch and page mapping vs the one-thread CPU path and cv2; first size where the GPU is >= 10 %
# faster and stays faster). None = the GPU never wins by that margin, so the op stays on the CPU even with the switch on:
# sqrt and magnitude are memory-bandwidth bound and only tie.
_THRESHOLDS: dict[str, int | None] = {
    "sqrt": None,
    "exp": 1_200_000,
    "log": 550_000,
    "pow": 250_000,
    "magnitude": None,
    "phase": 1_000_000,
    "cartToPolar": 1_400_000,
    "polarToCart": 500_000,
    "multiply": 3_000_000,
    "addWeighted": 3_000_000,
}
_force_min: int | None = None  # tests / benchmarks: use this threshold for every op (0 = always try the GPU)

_TRUE = ("1", "true", "yes", "on")
_enabled = os.environ.get("SAFARIUM_GPU", "").strip().lower() in _TRUE
_probed = False
_ok = False  # Metal usable (probed lazily so importing the shim never creates a Metal device)

_pkg_name = __package__ or "cv2"
_lib_ = _lib.lib
_VP = ctypes.c_void_p
_I32 = ctypes.c_int32
_F64 = ctypes.c_double


def _declare(name, argtypes, restype=_I32):
    try:
        fn = getattr(_lib_, name)
    except AttributeError:  # stale dylib without GPU entry points
        return None
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


_g_avail = _declare("sr_gpu_available", [])
_g_unary = _declare("sr_gpu_unary_f32", [_I32, _VP, _VP, _F64])
_g_binary = _declare("sr_gpu_binary_f32", [_I32, _VP, _VP, _VP, _VP, _I32])
_g_polar = _declare("sr_gpu_polar2cart_f32", [_VP, _VP, _VP, _VP, _I32])
_g_u8 = _declare("sr_gpu_u8_arith", [_I32, _VP, _VP, _VP, _F64, _F64, _F64])
_g_count = _declare("sr_gpu_dispatch_count", [_I32], ctypes.c_int64)
_g_name = _declare("sr_gpu_device_name", [ctypes.c_char_p, _I32])
_g_last = _declare("sr_gpu_last_ns", [_I32], ctypes.c_int64)

_F32 = np.dtype(np.float32)
_mat, _byref, _usable, _canon, _out = _core._mat, _core._byref, _core._usable, _core._canon, _core._out


def _probe() -> bool:
    global _probed, _ok
    if not _probed:
        _probed = True
        _ok = bool(_g_avail is not None and _g_unary is not None and _g_binary is not None and _g_polar is not None
                   and _g_u8 is not None
                   and os.environ.get("SAFARIUM_GPU_DISABLE") != "1" and _g_avail() == 1)
    return _ok


def _gate(op: str, n: int) -> bool:
    """True when this call should try Metal: switch on, Metal present, and big enough to win."""
    if not _enabled:
        return False
    thr = _force_min if _force_min is not None else _THRESHOLDS[op]
    if thr is None or n < thr:
        return False
    return _probe()


def _f32_array(a):
    """The f32 ndarray the CPU functions would operate on (2-D, or 3-D with the 1-channel axis dropped), else None."""
    if type(a) is not np.ndarray or a.dtype != _F32 or a.ndim not in (2, 3) or a.size == 0:
        return None
    a = _canon(a)
    return a if _usable(a) else None


def _overlap(a: np.ndarray, b: np.ndarray) -> bool:
    """Partial aliasing (the same buffer seen through different layouts) is left to the CPU path."""
    return bool(np.may_share_memory(a, b))


def _same_view(a: np.ndarray, b: np.ndarray) -> bool:
    return a.ctypes.data == b.ctypes.data and a.strides == b.strides and a.shape == b.shape


def _clash(res: np.ndarray, *ins: np.ndarray) -> bool:
    """True when the output overlaps an input other than as the identical view (elementwise in-place is safe)."""
    return any(_overlap(res, s) and not _same_view(res, s) for s in ins)


# ------------------------------------------------------------------------------------------ wrappers
_CPU: dict[str, object] = {}  # the exact CPU functions, captured below; the wrappers fall back to these


def _unary(name, op):
    def fn(src, dst=None):
        a = _f32_array(src)
        if a is not None and _gate(name, a.size):
            res, fin = _out(dst, a.shape, _F32)
            if not _clash(res, a) and _g_unary(op, _byref(_mat(a)), _byref(_mat(res)), 0.0) == 0:
                return fin()
        return _CPU[name](src, dst)
    fn.__name__ = fn.__qualname__ = name
    return fn


def _pow(src, power, dst=None):
    a = _f32_array(src)
    if a is not None and isinstance(power, (int, float)) and not isinstance(power, bool):
        p = float(power)
        # Integer powers (and 0.5, which is a sqrt) are cheap multiplies on the CPU: only true powers go to the GPU.
        if np.isfinite(p) and abs(p) < 1024 and p != int(p) and p != 0.5 and _gate("pow", a.size):
            res, fin = _out(dst, a.shape, _F32)
            if not _clash(res, a) and _g_unary(3, _byref(_mat(a)), _byref(_mat(res)), p) == 0:
                return fin()
    return _CPU["pow"](src, power, dst)


def _pair(x, y):
    a, b = _f32_array(x), _f32_array(y)
    if a is None or b is None or a.shape != b.shape:
        return None, None
    return a, b


def _magnitude(x, y, magnitude=None):  # noqa: A002 (cv2 signature)
    a, b = _pair(x, y)
    if a is not None and _gate("magnitude", a.size):
        res, fin = _out(magnitude, a.shape, _F32)
        if not _clash(res, a, b) and \
                _g_binary(0, _byref(_mat(a)), _byref(_mat(b)), _byref(_mat(res)), None, 0) == 0:
            return fin()
    return _CPU["magnitude"](x, y, magnitude)


def _phase(x, y, angle=None, angleInDegrees=False):
    a, b = _pair(x, y)
    if a is not None and _gate("phase", a.size):
        res, fin = _out(angle, a.shape, _F32)
        if not _clash(res, a, b) and \
                _g_binary(1, _byref(_mat(a)), _byref(_mat(b)), _byref(_mat(res)), None, int(bool(angleInDegrees))) == 0:
            return fin()
    return _CPU["phase"](x, y, angle, angleInDegrees)


def _cart_to_polar(x, y, magnitude=None, angle=None, angleInDegrees=False):  # noqa: A002
    a, b = _pair(x, y)
    if a is not None and _gate("cartToPolar", a.size):
        rm, fm = _out(magnitude, a.shape, _F32)
        ra, fa = _out(angle, a.shape, _F32)
        if not _clash(rm, a, b) and not _clash(ra, a, b) and not _overlap(rm, ra) and \
                _g_binary(2, _byref(_mat(a)), _byref(_mat(b)), _byref(_mat(rm)), _byref(_mat(ra)), int(bool(angleInDegrees))) == 0:
            return fm(), fa()
    return _CPU["cartToPolar"](x, y, magnitude, angle, angleInDegrees)


def _polar_to_cart(magnitude, angle, x=None, y=None, angleInDegrees=False):  # noqa: A002
    ang = _f32_array(angle)
    if ang is not None and _gate("polarToCart", ang.size):
        mg = None
        ok = True
        if magnitude is not None and not (isinstance(magnitude, np.ndarray) and magnitude.size == 0):
            mg = _f32_array(magnitude)
            ok = mg is not None and mg.shape == ang.shape
        if ok:
            rx, fx = _out(x, ang.shape, _F32)
            ry, fy = _out(y, ang.shape, _F32)
            ins = [ang] + ([mg] if mg is not None else [])
            if not _clash(rx, *ins) and not _clash(ry, *ins) and not _overlap(rx, ry) and \
                    _g_polar(_byref(_mat(mg)) if mg is not None else None, _byref(_mat(ang)), _byref(_mat(rx)),
                             _byref(_mat(ry)), int(bool(angleInDegrees))) == 0:
                return fx(), fy()
    return _CPU["polarToCart"](magnitude, angle, x, y, angleInDegrees)


_U8 = np.dtype(np.uint8)


def _u8_pair(x, y):
    """Two same-shape uint8 ndarrays (not (H, W, 1): the CPU path's squeeze rules stay in charge there)."""
    if type(x) is not np.ndarray or type(y) is not np.ndarray or x.dtype != _U8 or y.dtype != _U8:
        return None, None
    if x.ndim not in (2, 3) or x.shape != y.shape or x.size == 0 or (x.ndim == 3 and x.shape[2] == 1):
        return None, None
    return (x, y) if _usable(x) and _usable(y) else (None, None)


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and np.isfinite(v)


def _multiply(src1, src2, dst=None, scale=1.0, dtype=-1):
    a, b = _u8_pair(src1, src2)
    if a is not None and dtype == -1 and _num(scale) and _gate("multiply", a.size):
        res, fin = _out(dst, a.shape, _U8)
        if not _clash(res, a, b) and \
                _g_u8(1, _byref(_mat(a)), _byref(_mat(b)), _byref(_mat(res)), float(scale), 0.0, 0.0) == 0:
            return fin()
    return _CPU["multiply"](src1, src2, dst, scale, dtype)


def _add_weighted(src1, alpha, src2, beta, gamma, dst=None, dtype=-1):
    a, b = _u8_pair(src1, src2)
    if a is not None and dtype == -1 and _num(alpha) and _num(beta) and _num(gamma) and _gate("addWeighted", a.size):
        res, fin = _out(dst, a.shape, _U8)
        if not _clash(res, a, b) and \
                _g_u8(0, _byref(_mat(a)), _byref(_mat(b)), _byref(_mat(res)), float(alpha), float(beta), float(gamma)) == 0:
            return fin()
    return _CPU["addWeighted"](src1, alpha, src2, beta, gamma, dst, dtype)


_WRAPPERS = {
    "sqrt": _unary("sqrt", 0),
    "exp": _unary("exp", 1),
    "log": _unary("log", 2),
    "pow": _pow,
    "magnitude": _magnitude,
    "phase": _phase,
    "cartToPolar": _cart_to_polar,
    "polarToCart": _polar_to_cart,
    "multiply": _multiply,
    "addWeighted": _add_weighted,
}
for _n, _f in _WRAPPERS.items():
    _f.__name__ = _f.__qualname__ = _n


# ------------------------------------------------------------------------------------------ switch
def _capture() -> None:
    pkg = sys.modules.get(_pkg_name)
    for name in _WRAPPERS:
        _CPU[name] = getattr(pkg, name, None) or getattr(_core, name)


def _install(on: bool) -> None:
    """Swap the wrappers into (or the CPU functions back into) the cv2 package namespace."""
    pkg = sys.modules.get(_pkg_name)
    if pkg is None:
        return
    for name, wrapper in _WRAPPERS.items():
        setattr(pkg, name, wrapper if on else _CPU[name])


def safarium_set_gpu(enabled) -> None:
    """Turn the opt-in Metal paths on or off (off by default; env SAFARIUM_GPU=1 starts with them on)."""
    global _enabled
    _enabled = bool(enabled)
    _install(_enabled)


def safarium_get_gpu() -> bool:
    """The switch as last set. True does not guarantee Metal is present: see safarium_gpu_available()."""
    return _enabled


def safarium_gpu_available() -> bool:
    """True when a Metal device and the embedded shaders are usable (creates the device on first call)."""
    return _probe()


# ------------------------------------------------------------------------------------------ introspection (tests, bench)
def dispatch_count(copies: bool = False) -> int:
    """Successful GPU dispatches so far (copies=True: those that needed the one-copy fallback)."""
    return int(_g_count(int(copies))) if _g_count is not None and _probed and _ok else 0


def device_name() -> str:
    if not _probe() or _g_name is None:
        return ""
    buf = ctypes.create_string_buffer(256)
    _g_name(buf, 256)
    return buf.value.decode("utf-8", "replace")


def last_ns() -> tuple[int, int, int]:
    """(buffer wrap, encode+commit+wait, GPU kernel) nanoseconds of the most recent dispatch."""
    if _g_last is None or not _probe():
        return (0, 0, 0)
    return tuple(int(_g_last(i)) for i in range(3))


def force_min_elems(n: int | None) -> None:
    """Use `n` as the size threshold of every op (0 = always try the GPU); None restores the calibrated table."""
    global _force_min
    _force_min = n


_capture()
if _enabled:
    _install(True)
