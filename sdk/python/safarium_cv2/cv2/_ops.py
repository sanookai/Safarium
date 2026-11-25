"""Image ops (area B): resize, warpAffine, blur/filters, morphology, distance transform, components, contours.

Backed by libSafariumRaster (Swift/Accelerate); pure-math pieces (getRotationMatrix2D, getStructuringElement,
GaussianBlur kernels, arcLength, pointPolygonTest) are numpy. Signatures/defaults/return types follow OpenCV's Python API.
Contract: Projects/Safarium/docs/raster-plan.md
"""
from __future__ import annotations

import ctypes
import math

import numpy as np

from . import _core, _lib, _numpy_ops
from ._lib import CSTR, F64, I32, IMG_ARGS, PF64, PI32, VP, check, declare, img_args

_NAMES = [
    "resize", "warpAffine", "warpPerspective", "getPerspectiveTransform", "remap",
    "getRotationMatrix2D", "invertAffineTransform", "GaussianBlur", "getGaussianKernel",
    "sepFilter2D", "filter2D", "boxFilter", "Sobel", "Scharr", "Laplacian",
    "Canny", "bilateralFilter", "medianBlur", "integral", "integral2", "integral3",
    "pyrDown", "pyrUp", "CLAHE", "createCLAHE", "equalizeHist", "adaptiveThreshold",
    "applyColorMap", "cvtColor",
    "erode", "dilate", "morphologyEx", "getStructuringElement",
    "morphologyDefaultBorderValue", "distanceTransform", "connectedComponents", "connectedComponentsWithStats",
    "findContours", "approxPolyDP", "arcLength", "pointPolygonTest",
]

# Local copies of the OpenCV constant values used here (the public constants live in _constants.py).
_INTER_NEAREST, _INTER_LINEAR, _INTER_CUBIC, _INTER_AREA = 0, 1, 2, 3
_WARP_INVERSE_MAP = 16
_BORDER_CONSTANT, _BORDER_REPLICATE, _BORDER_REFLECT, _BORDER_WRAP, _BORDER_REFLECT_101 = 0, 1, 2, 3, 4
_BORDER_DEFAULT = _BORDER_REFLECT_101
_DBL_MAX = 1.7976931348623157e308

_PMAT = ctypes.POINTER(_core._Mat)
_c_resize = declare("sr_resize", IMG_ARGS + IMG_ARGS + [I32, F64, F64])
_c_warp = declare("sr_warp_affine", IMG_ARGS + IMG_ARGS + [PF64, I32, I32, PF64])
_c_warp_persp = declare("sr_warp_perspective", IMG_ARGS + IMG_ARGS + [PF64, I32, I32, PF64])
_c_get_persp = declare("sr_get_perspective", [PF64, PF64, I32, PF64])
_c_sep = declare("sr_sep_filter", IMG_ARGS + IMG_ARGS + [ctypes.POINTER(ctypes.c_float), I32,
                                                         ctypes.POINTER(ctypes.c_float), I32, I32, I32, F64, I32, PF64])
_c_sep2 = declare("sr_sep_filter2", [_PMAT, _PMAT, PF64, I32, PF64, I32, I32, I32, F64, I32])
_c_filter2d = declare("sr_filter2d", [_PMAT, _PMAT, PF64, I32, I32, I32, I32, F64, I32])
_c_box = declare("sr_box_filter", [_PMAT, _PMAT, I32, I32, I32, I32, I32, I32])
_c_sobel = declare("sr_sobel", [_PMAT, _PMAT, I32, I32, I32, F64, F64, I32])
_c_scharr = declare("sr_scharr", [_PMAT, _PMAT, I32, I32, F64, F64, I32])
_c_laplacian = declare("sr_laplacian", [_PMAT, _PMAT, I32, F64, F64, I32])
_c_canny = declare("sr_canny", [_PMAT, _PMAT, F64, F64, I32, I32])
_c_bilateral = declare("sr_bilateral", [_PMAT, _PMAT, I32, F64, F64, I32])
_c_median = declare("sr_median_blur", [_PMAT, _PMAT, I32])
_c_integral = declare("sr_integral", [_PMAT, _PMAT, _PMAT, _PMAT])
_c_pyr_up = declare("sr_pyr_up", [_PMAT, _PMAT, I32])
_c_adapt_thresh = declare("sr_adaptive_threshold", [_PMAT, _PMAT, F64, I32, I32, I32, F64])
_c_eq_hist = declare("sr_equalize_hist", [_PMAT, _PMAT])
_c_clahe = declare("sr_clahe_apply", [_PMAT, _PMAT, F64, I32, I32])
_c_colormap = declare("sr_apply_colormap", [_PMAT, _PMAT, I32, ctypes.POINTER(ctypes.c_uint8)])
_c_cvt = declare("sr_cvt_color", [_PMAT, _PMAT, I32])
_c_remap = declare("sr_remap", IMG_ARGS * 4 + [I32, I32, PF64])
_c_pyr = declare("sr_pyr_down", IMG_ARGS + IMG_ARGS + [I32])
_c_dist = declare("sr_distance_transform", IMG_ARGS + IMG_ARGS + [I32, I32])
_c_cc = declare("sr_connected_components", IMG_ARGS + IMG_ARGS + [I32, ctypes.POINTER(I32), ctypes.POINTER(VP)])
_c_cc_take = declare("sr_cc_take", [VP, PI32, PF64])
_c_find = declare("sr_find_contours", IMG_ARGS + [I32, I32, I32, I32, ctypes.POINTER(I32),
                                                  ctypes.POINTER(ctypes.c_int64), ctypes.POINTER(VP)])
_c_find_take = declare("sr_contours_take", [VP, PI32, PI32, PI32])
_c_approx = declare("sr_approx_poly_dp", [VP, I32, I32, F64, I32, VP, PI32])
_c_morph = declare("sr_morph", IMG_ARGS + IMG_ARGS + [ctypes.POINTER(ctypes.c_uint8), I32, I32, I32, I32, I32, I32, I32, PF64])


# ---------------------------------------------------------------- helpers

_OK_DTYPES = (np.dtype(np.uint8), np.dtype(np.uint16), np.dtype(np.float32))

def _usable(a: np.ndarray) -> bool:
    if a.ndim not in (2, 3) or a.dtype not in _OK_DTYPES:
        return False
    c = 1 if a.ndim == 2 else a.shape[2]
    if c < 1 or c > 4:
        return False
    item = a.itemsize
    h, w = a.shape[:2]
    if w > 1 and a.strides[1] != c * item:
        return False
    if a.ndim == 3 and c > 1 and a.strides[2] != item:
        return False
    return a.strides[0] >= 0 and (h <= 1 or a.strides[0] >= w * c * item)


def _src(a, who: str) -> np.ndarray:
    a = np.asarray(a)
    if a.dtype not in _OK_DTYPES:
        raise _lib.error(f"{who}: unsupported dtype {a.dtype} (SafariumRaster handles uint8, uint16 and float32)")
    if a.ndim not in (2, 3) or (a.ndim == 3 and not 1 <= a.shape[2] <= 4):
        raise _lib.error(f"{who}: unsupported shape {a.shape}")
    if a.size == 0:
        raise _lib.error(f"{who}: empty image")
    if not _usable(a):
        a = np.ascontiguousarray(a)
    return a


def _shape(h: int, w: int, c: int) -> tuple:
    return (h, w) if c == 1 else (h, w, c)


def _channels(a: np.ndarray) -> int:
    return 1 if a.ndim == 2 else a.shape[2]


def _dst(dst, shape: tuple, dtype) -> np.ndarray:
    """cv2 semantics: a matching `dst` is written in place and returned, otherwise a fresh array is returned."""
    if (isinstance(dst, np.ndarray) and dst.shape == shape and dst.dtype == dtype and dst.flags.writeable
            and _usable(dst)):
        return dst
    return np.empty(shape, dtype)


def _bval(value):
    if value is None:
        return _lib.color4((0, 0, 0, 0))
    return _lib.color4(value)


def _size(dsize, who):
    try:
        w, h = dsize
        return int(w), int(h)
    except Exception:
        raise _lib.error(f"{who}: dsize must be a (width, height) pair") from None


def _round(v: float) -> int:
    return int(np.rint(v))  # ties to even (cvRound)


# ---------------------------------------------------------------- resize / warp

def resize(src, dsize, dst=None, fx=0, fy=0, interpolation=_INTER_LINEAR):
    a = _src(src, "resize")
    h, w = a.shape[:2]
    c = _channels(a)
    dw = dh = 0
    if dsize is not None:
        dw, dh = _size(dsize, "resize")
    if dw <= 0 or dh <= 0:
        if fx <= 0 or fy <= 0:
            raise _lib.error("resize: either dsize or both fx and fy must be positive")
        dw, dh = max(1, _round(w * fx)), max(1, _round(h * fy))
        sx, sy = 1.0 / fx, 1.0 / fy
    else:
        sx, sy = w / dw, h / dh
    out = _dst(dst, _shape(dh, dw, c), a.dtype)
    check(_c_resize(*img_args(a), *img_args(out), int(interpolation), sx, sy), "resize")
    return out


def getRotationMatrix2D(center, angle, scale):
    cx, cy = float(center[0]), float(center[1])
    ang = angle * math.pi / 180.0
    alpha = math.cos(ang) * scale
    beta = math.sin(ang) * scale
    return np.array([[alpha, beta, (1 - alpha) * cx - beta * cy],
                     [-beta, alpha, beta * cx + (1 - alpha) * cy]], np.float64)


def invertAffineTransform(M, iM=None):
    m = np.asarray(M, np.float64).reshape(2, 3)
    d = m[0, 0] * m[1, 1] - m[0, 1] * m[1, 0]
    d = 1.0 / d if d != 0 else 0.0
    a11, a22, a12, a21 = m[1, 1] * d, m[0, 0] * d, -m[0, 1] * d, -m[1, 0] * d
    b1 = -a11 * m[0, 2] - a12 * m[1, 2]
    b2 = -a21 * m[0, 2] - a22 * m[1, 2]
    return np.array([[a11, a12, b1], [a21, a22, b2]], np.float64)


def warpAffine(src, M, dsize, dst=None, flags=_INTER_LINEAR, borderMode=_BORDER_CONSTANT, borderValue=None):
    a = _src(src, "warpAffine")
    m = np.ascontiguousarray(np.asarray(M, np.float64).reshape(-1))
    if m.size != 6:
        raise _lib.error("warpAffine: M must be 2x3")
    dw, dh = _size(dsize, "warpAffine")
    if dw <= 0 or dh <= 0:
        raise _lib.error("warpAffine: empty dsize")
    c = _channels(a)
    out = _dst(dst, _shape(dh, dw, c), a.dtype)
    bv = _bval(borderValue)
    check(_c_warp(*img_args(a), *img_args(out), m.ctypes.data_as(PF64), int(flags), int(borderMode),
                  ctypes.cast(bv, PF64)), "warpAffine")
    return out


def remap(src, map1, map2, interpolation, dst=None, borderMode=_BORDER_CONSTANT, borderValue=None):
    a = _src(src, "remap")
    m1 = np.asarray(map1)
    m2 = None if map2 is None or (isinstance(map2, np.ndarray) and map2.size == 0) else np.asarray(map2)
    if m1.dtype != np.float32 or (m2 is not None and m2.dtype != np.float32):
        raise _lib.error("remap: maps must be float32 (CV_32FC1 pair or CV_32FC2)")
    if m2 is None:
        if m1.ndim != 3 or m1.shape[2] != 2:
            raise _lib.error("remap: a single map must be CV_32FC2 (H,W,2)")
    elif m1.ndim == 3 and m1.shape[2] == 1:
        m1 = m1[..., 0]
    if m2 is not None and m2.ndim == 3 and m2.shape[2] == 1:
        m2 = m2[..., 0]
    if m2 is not None and (m1.ndim != 2 or m2.shape != m1.shape):
        raise _lib.error("remap: map1 and map2 must be 1-channel maps of the same size")
    m1 = m1 if _usable(m1) else np.ascontiguousarray(m1)
    if m2 is not None:
        m2 = m2 if _usable(m2) else np.ascontiguousarray(m2)
    h, w = m1.shape[:2]
    c = _channels(a)
    out = _dst(dst, _shape(h, w, c), a.dtype)
    bv = _bval(borderValue)
    m2args = img_args(m2) if m2 is not None else [None, 0, 0, 0, 0, 0]
    check(_c_remap(*img_args(a), *img_args(out), *img_args(m1), *m2args, int(interpolation), int(borderMode),
                   ctypes.cast(bv, PF64)), "remap")
    return out


# ---------------------------------------------------------------- filtering

def getGaussianKernel(ksize, sigma, ktype=6):
    n = int(ksize)
    if n <= 0 or n % 2 == 0:
        raise _lib.error("getGaussianKernel: ksize must be odd and positive")
    small = {1: [1.0], 3: [0.25, 0.5, 0.25], 5: [0.0625, 0.25, 0.375, 0.25, 0.0625],
             7: [0.03125, 0.109375, 0.21875, 0.28125, 0.21875, 0.109375, 0.03125]}
    if n <= 7 and sigma <= 0:
        k = np.array(small[n], np.float64)
    else:
        s = sigma if sigma > 0 else ((n - 1) * 0.5 - 1) * 0.3 + 0.8
        x = np.arange(n, dtype=np.float64) - (n - 1) * 0.5
        k = np.exp(-0.5 / (s * s) * x * x)
        k /= k.sum()
    return k.reshape(n, 1).astype(np.float32 if ktype == 5 else np.float64)


def _check_border(border, who):
    if int(border) not in (0, 1, 2, 3, 4):
        raise _lib.error(f"{who}: unsupported border type {border}")


def _sep(a, dst, kx, ky, anchor, delta, border, who, out_dtype=None):
    c = _channels(a)
    dt = a.dtype if out_dtype is None else np.dtype(out_dtype)
    h, w = a.shape[:2]
    out = _dst(dst, _shape(h, w, c), dt)
    kx = np.ascontiguousarray(np.asarray(kx, np.float32).reshape(-1))
    ky = np.ascontiguousarray(np.asarray(ky, np.float32).reshape(-1))
    _check_border(border, who)
    bv = _lib.color4((0, 0, 0, 0))
    check(_c_sep(*img_args(a), *img_args(out), kx.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), kx.size,
                 ky.ctypes.data_as(ctypes.POINTER(ctypes.c_float)), ky.size, int(anchor[0]), int(anchor[1]),
                 float(delta), int(border), ctypes.cast(bv, PF64)), who)
    return out


def GaussianBlur(src, ksize, sigmaX, dst=None, sigmaY=0, borderType=_BORDER_DEFAULT):
    a = _src(src, "GaussianBlur")
    kw, kh = (int(ksize[0]), int(ksize[1])) if ksize is not None else (0, 0)
    s1, s2 = float(sigmaX), float(sigmaY)
    if s2 <= 0:
        s2 = s1
    mult = 3 if a.dtype == np.uint8 else 4
    if kw <= 0 and s1 > 0:
        kw = _round(s1 * mult * 2 + 1) | 1
    if kh <= 0 and s2 > 0:
        kh = _round(s2 * mult * 2 + 1) | 1
    if kw <= 0 or kh <= 0 or kw % 2 == 0 or kh % 2 == 0:
        raise _lib.error("GaussianBlur: ksize must be positive and odd (or zero with sigma > 0)")
    kx = getGaussianKernel(kw, s1, 5)
    ky = kx if (kh == kw and s2 == s1) else getGaussianKernel(kh, s2, 5)
    return _sep(a, dst, kx, ky, (-1, -1), 0.0, borderType, "GaussianBlur")


def _ddepth_dtype(src_dtype, ddepth, who: str) -> np.dtype:
    if ddepth in (-1, None):
        return np.dtype(src_dtype)
    try:
        return np.dtype(_core._DT[int(ddepth)])
    except (IndexError, ValueError, TypeError):
        raise _lib.error(f"{who}: unsupported ddepth {ddepth}") from None


def _msrc(src, who: str) -> np.ndarray:
    a = np.asarray(src)
    if np.dtype(a.dtype) not in _core._DEPTH:
        raise _lib.error(f"{who}: unsupported dtype {a.dtype}")
    if a.ndim not in (2, 3) or (a.ndim == 3 and not 1 <= a.shape[2] <= 4):
        raise _lib.error(f"{who}: unsupported shape {a.shape}")
    if a.size == 0:
        raise _lib.error(f"{who}: empty image")
    if not _core._usable(a):
        a = np.ascontiguousarray(a)
    return a


def sepFilter2D(src, ddepth, kernelX, kernelY, dst=None, anchor=(-1, -1), delta=0, borderType=_BORDER_DEFAULT):
    a = _msrc(src, "sepFilter2D")
    dt = _ddepth_dtype(a.dtype, ddepth, "sepFilter2D")
    if a.dtype in (np.uint8, np.uint16, np.float32) and dt in (np.uint8, np.uint16, np.float32) and _usable(a):
        return _sep(a, dst, kernelX, kernelY, anchor, delta, borderType, "sepFilter2D", dt)
    _check_border(borderType, "sepFilter2D")
    kx = np.ascontiguousarray(np.asarray(kernelX, np.float64).reshape(-1))
    ky = np.ascontiguousarray(np.asarray(kernelY, np.float64).reshape(-1))
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), dt)
    check(_c_sep2(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                  kx.ctypes.data_as(PF64), kx.size, ky.ctypes.data_as(PF64), ky.size,
                  int(anchor[0]), int(anchor[1]), float(delta), int(borderType)), "sepFilter2D")
    return fin()


def filter2D(src, ddepth, kernel, dst=None, anchor=(-1, -1), delta=0, borderType=_BORDER_DEFAULT):
    a = _msrc(src, "filter2D")
    dt = _ddepth_dtype(a.dtype, ddepth, "filter2D")
    _check_border(borderType, "filter2D")
    k = np.ascontiguousarray(np.asarray(kernel, np.float64))
    if k.ndim == 1:
        k = k.reshape(1, -1)
    if k.ndim != 2 or k.size == 0:
        raise _lib.error("filter2D: kernel must be non-empty 2-D array")
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), dt)
    check(_c_filter2d(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                      k.ctypes.data_as(PF64), k.shape[1], k.shape[0],
                      int(anchor[0]), int(anchor[1]), float(delta), int(borderType)), "filter2D")
    return fin()


def boxFilter(src, ddepth, ksize, dst=None, anchor=(-1, -1), normalize=True, borderType=_BORDER_DEFAULT):
    a = _msrc(src, "boxFilter")
    dt = _ddepth_dtype(a.dtype, ddepth, "boxFilter")
    _check_border(borderType, "boxFilter")
    kw, kh = _size(ksize, "boxFilter")
    if kw <= 0 or kh <= 0:
        raise _lib.error("boxFilter: ksize must be positive")
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), dt)
    check(_c_box(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                 kw, kh, int(anchor[0]), int(anchor[1]), 1 if normalize else 0, int(borderType)), "boxFilter")
    return fin()


def Sobel(src, ddepth, dx, dy, dst=None, ksize=3, scale=1.0, delta=0.0, borderType=_BORDER_DEFAULT):
    a = _msrc(src, "Sobel")
    dt = _ddepth_dtype(a.dtype, ddepth, "Sobel")
    _check_border(borderType, "Sobel")
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), dt)
    check(_c_sobel(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                   int(dx), int(dy), int(ksize), float(scale), float(delta), int(borderType)), "Sobel")
    return fin()


def Scharr(src, ddepth, dx, dy, dst=None, scale=1.0, delta=0.0, borderType=_BORDER_DEFAULT):
    a = _msrc(src, "Scharr")
    dt = _ddepth_dtype(a.dtype, ddepth, "Scharr")
    _check_border(borderType, "Scharr")
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), dt)
    check(_c_scharr(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                    int(dx), int(dy), float(scale), float(delta), int(borderType)), "Scharr")
    return fin()


def Laplacian(src, ddepth, dst=None, ksize=1, scale=1.0, delta=0.0, borderType=_BORDER_DEFAULT):
    a = _msrc(src, "Laplacian")
    dt = _ddepth_dtype(a.dtype, ddepth, "Laplacian")
    _check_border(borderType, "Laplacian")
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), dt)
    check(_c_laplacian(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                       int(ksize), float(scale), float(delta), int(borderType)), "Laplacian")
    return fin()


def Canny(image, threshold1, threshold2, edges=None, apertureSize=3, L2gradient=False):
    a = _msrc(image, "Canny")
    if a.dtype != np.uint8:
        raise _lib.error("Canny: requires uint8 image")
    h, w = a.shape[:2]
    out, fin = _core._out(edges, (h, w), np.uint8)
    check(_c_canny(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                   float(threshold1), float(threshold2), int(apertureSize), 1 if L2gradient else 0), "Canny")
    return fin()


def bilateralFilter(src, d, sigmaColor, sigmaSpace, dst=None, borderType=_BORDER_DEFAULT):
    a = _src(src, "bilateralFilter")
    _check_border(borderType, "bilateralFilter")
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), a.dtype)
    check(_c_bilateral(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                       int(d), float(sigmaColor), float(sigmaSpace), int(borderType)), "bilateralFilter")
    return fin()


def medianBlur(src, ksize, dst=None):
    a = _src(src, "medianBlur")
    h, w = a.shape[:2]
    c = _channels(a)
    out, fin = _core._out(dst, _shape(h, w, c), a.dtype)
    check(_c_median(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)), int(ksize)), "medianBlur")
    return fin()


def _integral_core(src, sum_dst, sqsum_dst, tilted_dst, sdepth, sqdepth, want_sq, want_til):
    a = _msrc(src, "integral")
    h, w = a.shape[:2]
    c = _channels(a)
    sdt = np.int32 if sdepth in (-1, None) and a.dtype in (np.uint8, np.uint16, np.int16) else (
        np.float64 if sdepth in (-1, None) else _ddepth_dtype(a.dtype, sdepth, "integral"))
    sh = _shape(h + 1, w + 1, c)
    s_out, s_fin = _core._out(sum_dst, sh, sdt)
    sq_out, sq_fin = _core._out(sqsum_dst, sh, np.float64) if want_sq else (None, None)
    t_out, t_fin = _core._out(tilted_dst, sh, sdt) if want_til else (None, None)
    check(_c_integral(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(s_out)),
                      ctypes.byref(_core._mat(sq_out)) if sq_out is not None else None,
                      ctypes.byref(_core._mat(t_out)) if t_out is not None else None), "integral")
    return s_fin(), (sq_fin() if sq_fin else None), (t_fin() if t_fin else None)


def integral(src, sum=None, sdepth=-1):
    return _integral_core(src, sum, None, None, sdepth, -1, False, False)[0]


def integral2(src, sum=None, sqsum=None, sdepth=-1, sqdepth=-1):
    s, sq, _ = _integral_core(src, sum, sqsum, None, sdepth, sqdepth, True, False)
    return s, sq


def integral3(src, sum=None, sqsum=None, tilted=None, sdepth=-1, sqdepth=-1):
    return _integral_core(src, sum, sqsum, tilted, sdepth, sqdepth, True, True)


def pyrUp(src, dst=None, dstsize=None, borderType=_BORDER_DEFAULT):
    a = _src(src, "pyrUp")
    _check_border(borderType, "pyrUp")
    h, w = a.shape[:2]
    c = _channels(a)
    if dstsize is None or tuple(int(v) for v in dstsize) == (0, 0):
        ow, oh = w * 2, h * 2
    else:
        ow, oh = _size(dstsize, "pyrUp")
    out, fin = _core._out(dst, _shape(oh, ow, c), a.dtype)
    check(_c_pyr_up(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)), int(borderType)), "pyrUp")
    return fin()


class CLAHE:
    def __init__(self, clipLimit=40.0, tileGridSize=(8, 8)):
        self._clip = float(clipLimit)
        self._grid = (int(tileGridSize[0]), int(tileGridSize[1]))

    def setClipLimit(self, clipLimit):
        self._clip = float(clipLimit)

    def getClipLimit(self):
        return self._clip

    def setTilesGridSize(self, tileGridSize):
        self._grid = (int(tileGridSize[0]), int(tileGridSize[1]))

    def getTilesGridSize(self):
        return self._grid

    def apply(self, src, dst=None):
        a = _msrc(src, "CLAHE.apply")
        if a.dtype not in (np.uint8, np.uint16) or _channels(a) != 1:
            raise _lib.error("CLAHE: requires single-channel uint8 or uint16 image")
        h, w = a.shape[:2]
        out, fin = _core._out(dst, (h, w), a.dtype)
        check(_c_clahe(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                       self._clip, self._grid[0], self._grid[1]), "CLAHE.apply")
        return fin()


def createCLAHE(clipLimit=40.0, tileGridSize=(8, 8)):
    return CLAHE(clipLimit, tileGridSize)


def equalizeHist(src, dst=None):
    a = _msrc(src, "equalizeHist")
    if a.dtype != np.uint8 or _channels(a) != 1:
        raise _lib.error("equalizeHist: requires single-channel uint8 image")
    h, w = a.shape[:2]
    out, fin = _core._out(dst, (h, w), np.uint8)
    check(_c_eq_hist(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out))), "equalizeHist")
    return fin()


def adaptiveThreshold(src, maxValue, adaptiveMethod, thresholdType, blockSize, C, dst=None):
    a = _msrc(src, "adaptiveThreshold")
    if a.dtype != np.uint8 or _channels(a) != 1:
        raise _lib.error("adaptiveThreshold: requires single-channel uint8 image")
    h, w = a.shape[:2]
    out, fin = _core._out(dst, (h, w), np.uint8)
    check(_c_adapt_thresh(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)),
                          float(maxValue), int(adaptiveMethod), int(thresholdType),
                          int(blockSize), float(C)), "adaptiveThreshold")
    return fin()


def applyColorMap(src, colormap, dst=None):
    a = _msrc(src, "applyColorMap")
    if a.dtype != np.uint8 or _channels(a) not in (1, 3, 4):
        raise _lib.error("applyColorMap: requires 1-, 3-, or 4-channel uint8 image")
    h, w = a.shape[:2]
    out, fin = _core._out(dst, (h, w, 3), np.uint8)
    if isinstance(colormap, (int, np.integer)):
        check(_c_colormap(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)), int(colormap), None), "applyColorMap")
    else:
        lut = np.ascontiguousarray(np.asarray(colormap, np.uint8).reshape(256, 3))
        check(_c_colormap(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)), -1,
                          lut.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))), "applyColorMap")
    return fin()


def getPerspectiveTransform(src, dst, solveMethod=0):
    s = np.ascontiguousarray(np.asarray(src, np.float64).reshape(4, 2))
    d = np.ascontiguousarray(np.asarray(dst, np.float64).reshape(4, 2))
    out = np.empty((3, 3), dtype=np.float64)
    check(_c_get_persp(s.ctypes.data_as(PF64), d.ctypes.data_as(PF64), int(solveMethod),
                       out.ctypes.data_as(PF64)), "getPerspectiveTransform")
    return out


def warpPerspective(src, M, dsize, dst=None, flags=_INTER_LINEAR, borderMode=_BORDER_CONSTANT, borderValue=0):
    a = _src(src, "warpPerspective")
    dw, dh = _size(dsize, "warpPerspective")
    m = np.ascontiguousarray(np.asarray(M, np.float64).reshape(3, 3))
    c = _channels(a)
    _check_border(borderMode, "warpPerspective")
    out = _dst(dst, _shape(dh, dw, c), a.dtype)
    bv = _bval(borderValue)
    check(_c_warp_persp(*img_args(a), *img_args(out), m.ctypes.data_as(PF64), int(flags),
                        int(borderMode), ctypes.cast(bv, PF64)), "warpPerspective")
    return out


_LEGACY_CVT_CODES = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 40, 41}
_BAYER_CVT_CODES = {46, 47, 48, 49, 62, 63, 64, 65, 86, 87, 88, 89, 135, 136, 137, 138, 139, 140, 141, 142}


def cvtColor(src, code, dst=None, dstCn=0):
    c = int(code)
    if c in _LEGACY_CVT_CODES:
        return _numpy_ops.cvtColor(src, c, dst=dst, dstCn=dstCn)
    if c in _BAYER_CVT_CODES:
        from . import _photo
        return _photo.demosaicing(src, c, dst=dst, dstCn=dstCn)
    a = _msrc(src, "cvtColor")
    if a.dtype not in (np.uint8, np.uint16, np.float32):
        raise _lib.error(f"cvtColor: unsupported dtype {a.dtype}")
    h, w = a.shape[:2]
    sc = _channels(a)
    dc = int(dstCn) if dstCn else (sc if sc == 4 and c < 30 else 3)
    out, fin = _core._out(dst, _shape(h, w, dc), a.dtype)
    check(_c_cvt(ctypes.byref(_core._mat(a)), ctypes.byref(_core._mat(out)), c), "cvtColor")
    return fin()


def pyrDown(src, dst=None, dstsize=None, borderType=_BORDER_DEFAULT):
    a = _src(src, "pyrDown")
    h, w = a.shape[:2]
    c = _channels(a)
    oh, ow = (h + 1) // 2, (w + 1) // 2
    if dstsize is not None and tuple(int(v) for v in dstsize) not in ((0, 0), (ow, oh)):
        raise _lib.error("pyrDown: only the default destination size ((w+1)/2, (h+1)/2) is supported")
    _check_border(borderType, "pyrDown")
    out = _dst(dst, _shape(oh, ow, c), a.dtype)
    check(_c_pyr(*img_args(a), *img_args(out), int(borderType)), "pyrDown")
    return out


# ---------------------------------------------------------------- morphology

def morphologyDefaultBorderValue():
    return (_DBL_MAX, _DBL_MAX, _DBL_MAX, _DBL_MAX)


def getStructuringElement(shape, ksize, anchor=(-1, -1)):
    kw, kh = int(ksize[0]), int(ksize[1])
    ax = kw // 2 if anchor[0] == -1 else int(anchor[0])
    ay = kh // 2 if anchor[1] == -1 else int(anchor[1])
    if shape == 0 or (kh == 1 and kw == 1):  # MORPH_RECT
        return np.ones((kh, kw), np.uint8)
    out = np.zeros((kh, kw), np.uint8)
    if shape == 1:  # MORPH_CROSS
        out[ay, :] = 1
        out[:, ax] = 1
        return out
    if shape == 2:  # MORPH_ELLIPSE
        r, c = kh // 2, kw // 2
        inv_r2 = 1.0 / (r * r) if r else 0.0
        for i in range(kh):
            dy = i - r
            j1 = j2 = 0
            if abs(dy) <= r:
                dx = _round(c * math.sqrt((r * r - dy * dy) * inv_r2))
                j1 = max(c - dx, 0)
                j2 = min(c + dx + 1, kw)
            out[i, j1:j2] = 1
        return out
    raise _lib.error("getStructuringElement: unknown shape")


def _kernel(kernel):
    if kernel is None:
        return np.ones((3, 3), np.uint8)
    k = np.asarray(kernel)
    if k.ndim == 1:
        k = k.reshape(1, -1)
    if k.size == 0:
        return np.ones((3, 3), np.uint8)
    return np.ascontiguousarray((k != 0).astype(np.uint8))


def _morph(a, kernel, dst, anchor, iterations, border, bval, op, who):
    c = _channels(a)
    h, w = a.shape[:2]
    out = _dst(dst, _shape(h, w, c), a.dtype)
    k = _kernel(kernel)
    bv = _lib.color4(bval if bval is not None else morphologyDefaultBorderValue())
    check(_c_morph(*img_args(a), *img_args(out), k.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8)), k.shape[1],
                   k.shape[0], int(anchor[0]), int(anchor[1]), op, int(iterations), int(border),
                   ctypes.cast(bv, PF64)), who)
    return out


def erode(src, kernel, dst=None, anchor=(-1, -1), iterations=1, borderType=_BORDER_CONSTANT, borderValue=None):
    return _morph(_src(src, "erode"), kernel, dst, anchor, iterations, borderType, borderValue, 0, "erode")


def dilate(src, kernel, dst=None, anchor=(-1, -1), iterations=1, borderType=_BORDER_CONSTANT, borderValue=None):
    return _morph(_src(src, "dilate"), kernel, dst, anchor, iterations, borderType, borderValue, 1, "dilate")


def morphologyEx(src, op, kernel, dst=None, anchor=(-1, -1), iterations=1, borderType=_BORDER_CONSTANT,
                 borderValue=None):
    a = _src(src, "morphologyEx")
    args = (kernel, None, anchor, iterations, borderType, borderValue)

    def er(x):
        return _morph(x, args[0], None, args[2], args[3], args[4], args[5], 0, "morphologyEx")

    def di(x):
        return _morph(x, args[0], None, args[2], args[3], args[4], args[5], 1, "morphologyEx")

    def sub(x, y):  # saturating x - y
        if x.dtype == np.uint8:
            return np.clip(x.astype(np.int16) - y.astype(np.int16), 0, 255).astype(np.uint8)
        return x - y

    if op == 0:
        res = er(a)
    elif op == 1:
        res = di(a)
    elif op == 2:  # OPEN
        res = di(er(a))
    elif op == 3:  # CLOSE
        res = er(di(a))
    elif op == 4:  # GRADIENT
        res = sub(di(a), er(a))
    elif op == 5:  # TOPHAT
        res = sub(a, di(er(a)))
    elif op == 6:  # BLACKHAT
        res = sub(er(di(a)), a)
    else:
        raise _lib.error(f"morphologyEx: unsupported op {op}")
    if isinstance(dst, np.ndarray) and dst.shape == res.shape and dst.dtype == res.dtype and dst.flags.writeable:
        dst[...] = res
        return dst
    return res


# ---------------------------------------------------------------- distance transform / components

def distanceTransform(src, distanceType, maskSize, dst=None, dstType=5):
    a = np.asarray(src)
    if a.dtype != np.uint8 or a.ndim != 2:
        raise _lib.error("distanceTransform: source must be a single-channel uint8 image")
    if dstType not in (5, -1):
        raise _lib.error("distanceTransform: only dstType CV_32F is supported")
    a = a if _usable(a) else np.ascontiguousarray(a)
    out = _dst(dst, a.shape, np.float32)
    check(_c_dist(*img_args(a), *img_args(out), int(distanceType), int(maskSize)), "distanceTransform")
    return out


def _cc(image, labels, connectivity, ltype, who):
    a = np.asarray(image)
    if a.dtype != np.uint8 or a.ndim != 2:
        raise _lib.error(f"{who}: image must be a single-channel uint8 array")
    if int(connectivity) not in (4, 8):
        raise _lib.error(f"{who}: connectivity must be 4 or 8")
    if ltype not in (4, 2):
        raise _lib.error(f"{who}: ltype must be CV_32S or CV_16U")
    a = a if _usable(a) else np.ascontiguousarray(a)
    lab = _dst(labels if ltype == 4 else None, a.shape, np.int32)
    n = I32(0)
    handle = VP()
    check(_c_cc(*img_args(a), *img_args(lab), int(connectivity), ctypes.byref(n), ctypes.byref(handle)), who)
    return int(n.value), lab, handle


def connectedComponents(image, labels=None, connectivity=8, ltype=4):
    n, lab, handle = _cc(image, labels, connectivity, ltype, "connectedComponents")
    check(_c_cc_take(handle, None, None), "connectedComponents")
    if ltype == 2:
        if n > 65535:
            raise _lib.error("connectedComponents: too many labels for CV_16U")
        lab = lab.astype(np.uint16)
    return n, lab


def connectedComponentsWithStats(image, labels=None, stats=None, centroids=None, connectivity=8, ltype=4):
    n, lab, handle = _cc(image, labels, connectivity, ltype, "connectedComponentsWithStats")
    st = np.empty((n, 5), np.int32)
    ce = np.empty((n, 2), np.float64)
    check(_c_cc_take(handle, st.ctypes.data_as(PI32), ce.ctypes.data_as(PF64)), "connectedComponentsWithStats")
    if ltype == 2:
        if n > 65535:
            raise _lib.error("connectedComponentsWithStats: too many labels for CV_16U")
        lab = lab.astype(np.uint16)
    return n, lab, st, ce


# ---------------------------------------------------------------- contours

def findContours(image, mode, method, contours=None, hierarchy=None, offset=None):
    a = np.asarray(image)
    if a.dtype != np.uint8 or a.ndim != 2:
        raise _lib.error("findContours: image must be a single-channel uint8 array (CV_8UC1)")
    a = a if _usable(a) else np.ascontiguousarray(a)
    ox, oy = (0, 0) if offset is None else (int(offset[0]), int(offset[1]))
    n = I32(0)
    total = ctypes.c_int64(0)
    handle = VP()
    check(_c_find(*img_args(a), int(mode), int(method), ox, oy, ctypes.byref(n), ctypes.byref(total),
                  ctypes.byref(handle)), "findContours")
    if n.value == 0:
        return (), None
    counts = np.empty(n.value, np.int32)
    pts = np.empty((total.value, 2), np.int32)
    hier = np.empty((1, n.value, 4), np.int32)
    check(_c_find_take(handle, counts.ctypes.data_as(PI32), pts.ctypes.data_as(PI32), hier.ctypes.data_as(PI32)),
          "findContours")
    ends = np.cumsum(counts)
    starts = ends - counts
    out = tuple(pts[s:e].reshape(-1, 1, 2) for s, e in zip(starts.tolist(), ends.tolist()))
    return out, hier


def _curve(curve, who):
    c = np.asarray(curve)
    if c.dtype not in (np.dtype(np.int32), np.dtype(np.float32)):
        if c.dtype in (np.dtype(np.float64), np.dtype(np.int64), np.dtype(np.int16), np.dtype(np.uint8),
                       np.dtype(np.uint16)):
            raise _lib.error(f"{who}: curve must be int32 or float32 points (got {c.dtype})")
        raise _lib.error(f"{who}: unsupported curve dtype {c.dtype}")
    if c.ndim == 3 and c.shape[1] == 1 and c.shape[2] == 2:
        flat = c.reshape(-1, 2)
    elif c.ndim == 2 and c.shape[1] == 2:
        flat = c
    elif c.ndim == 3 and c.shape[0] == 1 and c.shape[2] == 2:
        flat = c.reshape(-1, 2)
    else:
        raise _lib.error(f"{who}: curve must be (N,1,2) or (N,2) points")
    return c, np.ascontiguousarray(flat)


def approxPolyDP(curve, epsilon, closed):
    c, flat = _curve(curve, "approxPolyDP")
    n = flat.shape[0]
    out = np.empty_like(flat)
    cnt = I32(0)
    check(_c_approx(flat.ctypes.data, n, 1 if flat.dtype == np.float32 else 0, float(epsilon), 1 if closed else 0,
                    out.ctypes.data, ctypes.byref(cnt)), "approxPolyDP")
    res = out[:cnt.value]
    return res.reshape(-1, 1, 2).copy() if c.ndim == 3 else res.copy().reshape(-1, 1, 2)


def arcLength(curve, closed):
    _, flat = _curve(curve, "arcLength")
    p = flat.astype(np.float32)
    if len(p) < 2:
        return 0.0
    d = np.diff(p, axis=0)
    seg = np.sqrt(d[:, 0] * d[:, 0] + d[:, 1] * d[:, 1])
    total = float(seg.sum(dtype=np.float64))
    if closed:
        e = p[0] - p[-1]
        total += float(np.sqrt(e[0] * e[0] + e[1] * e[1]))
    return total


def pointPolygonTest(contour, pt, measureDist):
    c, flat = _curve(contour, "pointPolygonTest")
    p = flat.astype(np.float64)
    px, py = float(pt[0]), float(pt[1])
    if flat.dtype == np.float32:
        px, py = float(np.float32(px)), float(np.float32(py))
    n = len(p)
    if n == 0:
        return -1.0 if measureDist else -1
    x0, y0 = p[:, 0], p[:, 1]
    x1, y1 = np.roll(x0, -1), np.roll(y0, -1)
    dx, dy = x1 - x0, y1 - y0
    dx1, dy1 = px - x0, py - y0
    seg2 = dx * dx + dy * dy
    with np.errstate(divide="ignore", invalid="ignore"):
        t = np.where(seg2 > 0, (dx1 * dx + dy1 * dy) / seg2, 0.0)
    t = np.clip(t, 0.0, 1.0)
    dist2 = (px - (x0 + t * dx)) ** 2 + (py - (y0 + t * dy)) ** 2
    min2 = float(dist2.min())
    if min2 == 0.0:
        return 0.0 if measureDist else 0
    # even-odd crossing test
    cond = ((y0 > py) != (y1 > py))
    with np.errstate(divide="ignore", invalid="ignore"):
        xin = np.where(cond, (x1 - x0) * (py - y0) / np.where(cond, (y1 - y0), 1.0) + x0, 0.0)
    inside = int(np.count_nonzero(cond & (px < xin))) % 2 == 1
    if measureDist:
        d = math.sqrt(min2)
        return d if inside else -d
    return 1 if inside else -1


__all__ = [n for n in _NAMES if n in globals()]
