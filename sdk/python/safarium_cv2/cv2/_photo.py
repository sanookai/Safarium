"""Phase 8 (`photo` + HDR): inpainting, NLM/TV-L1 denoising, seamless cloning / Poisson editing,
NPR filters, decolorization, Bayer demosaicing, and HDR alignment/calibration/merge/tonemapping.
"""
from __future__ import annotations

import ctypes
import numpy as np

from . import _lib
from ._lib import F64, I32, IMG_ARGS, PF64, PI32, VP, check, declare, error, img_args

_F32 = ctypes.c_float
_PF32 = ctypes.POINTER(ctypes.c_float)
_PVP = ctypes.POINTER(VP)

# --------------------------------------------------------------------------- constants

INPAINT_NS = 0
INPAINT_TELEA = 1

NORMAL_CLONE = 1
MIXED_CLONE = 2
MONOCHROME_TRANSFER = 3
NORMAL_CLONE_WIDE = 9
MIXED_CLONE_WIDE = 10

RECURS_FILTER = 1
NORMCONV_FILTER = 2

LDR_SIZE = 256

_NORM_L1 = 2
_NORM_L2 = 4

# Bayer demosaicing codes (identical to OpenCV 5.1)
COLOR_BayerBG2BGR = 46
COLOR_BayerGB2BGR = 47
COLOR_BayerRG2BGR = 48
COLOR_BayerGR2BGR = 49
COLOR_BayerRGGB2BGR = 46
COLOR_BayerGRBG2BGR = 47
COLOR_BayerBGGR2BGR = 48
COLOR_BayerGBRG2BGR = 49

COLOR_BayerBG2RGB = 48
COLOR_BayerGB2RGB = 49
COLOR_BayerRG2RGB = 46
COLOR_BayerGR2RGB = 47
COLOR_BayerRGGB2RGB = 48
COLOR_BayerGRBG2RGB = 49
COLOR_BayerBGGR2RGB = 46
COLOR_BayerGBRG2RGB = 47

COLOR_BayerBG2BGR_VNG = 62
COLOR_BayerGB2BGR_VNG = 63
COLOR_BayerRG2BGR_VNG = 64
COLOR_BayerGR2BGR_VNG = 65
COLOR_BayerRGGB2BGR_VNG = 62
COLOR_BayerGRBG2BGR_VNG = 63
COLOR_BayerBGGR2BGR_VNG = 64
COLOR_BayerGBRG2BGR_VNG = 65

COLOR_BayerBG2RGB_VNG = 64
COLOR_BayerGB2RGB_VNG = 65
COLOR_BayerRG2RGB_VNG = 62
COLOR_BayerGR2RGB_VNG = 63
COLOR_BayerRGGB2RGB_VNG = 64
COLOR_BayerGRBG2RGB_VNG = 65
COLOR_BayerBGGR2RGB_VNG = 62
COLOR_BayerGBRG2RGB_VNG = 63

COLOR_BayerBG2GRAY = 86
COLOR_BayerGB2GRAY = 87
COLOR_BayerRG2GRAY = 88
COLOR_BayerGR2GRAY = 89
COLOR_BayerRGGB2GRAY = 86
COLOR_BayerGRBG2GRAY = 87
COLOR_BayerBGGR2GRAY = 88
COLOR_BayerGBRG2GRAY = 89

COLOR_BayerBG2BGR_EA = 135
COLOR_BayerGB2BGR_EA = 136
COLOR_BayerRG2BGR_EA = 137
COLOR_BayerGR2BGR_EA = 138
COLOR_BayerRGGB2BGR_EA = 135
COLOR_BayerGRBG2BGR_EA = 136
COLOR_BayerBGGR2BGR_EA = 137
COLOR_BayerGBRG2BGR_EA = 138

COLOR_BayerBG2RGB_EA = 137
COLOR_BayerGB2RGB_EA = 138
COLOR_BayerRG2RGB_EA = 135
COLOR_BayerGR2RGB_EA = 136
COLOR_BayerRGGB2RGB_EA = 137
COLOR_BayerGRBG2RGB_EA = 138
COLOR_BayerBGGR2RGB_EA = 135
COLOR_BayerGBRG2RGB_EA = 136

COLOR_BayerBG2BGRA = 139
COLOR_BayerGB2BGRA = 140
COLOR_BayerRG2BGRA = 141
COLOR_BayerGR2BGRA = 142
COLOR_BayerRGGB2BGRA = 139
COLOR_BayerGRBG2BGRA = 140
COLOR_BayerBGGR2BGRA = 141
COLOR_BayerGBRG2BGRA = 142

COLOR_BayerBG2RGBA = 141
COLOR_BayerGB2RGBA = 142
COLOR_BayerRG2RGBA = 139
COLOR_BayerGR2RGBA = 140
COLOR_BayerRGGB2RGBA = 141
COLOR_BayerGRBG2RGBA = 142
COLOR_BayerBGGR2RGBA = 139
COLOR_BayerGBRG2RGBA = 140

# Uppercase aliases exported by OpenCV 5.1
COLOR_BAYER_BG2BGR = 46
COLOR_BAYER_GB2BGR = 47
COLOR_BAYER_RG2BGR = 48
COLOR_BAYER_GR2BGR = 49
COLOR_BAYER_RGGB2BGR = 46
COLOR_BAYER_GRBG2BGR = 47
COLOR_BAYER_BGGR2BGR = 48
COLOR_BAYER_GBRG2BGR = 49
COLOR_BAYER_BG2RGB = 48
COLOR_BAYER_GB2RGB = 49
COLOR_BAYER_RG2RGB = 46
COLOR_BAYER_GR2RGB = 47
COLOR_BAYER_RGGB2RGB = 48
COLOR_BAYER_GRBG2RGB = 49
COLOR_BAYER_BGGR2RGB = 46
COLOR_BAYER_GBRG2RGB = 47
COLOR_BAYER_BG2BGR_VNG = 62
COLOR_BAYER_GB2BGR_VNG = 63
COLOR_BAYER_RG2BGR_VNG = 64
COLOR_BAYER_GR2BGR_VNG = 65
COLOR_BAYER_RGGB2BGR_VNG = 62
COLOR_BAYER_GRBG2BGR_VNG = 63
COLOR_BAYER_BGGR2BGR_VNG = 64
COLOR_BAYER_GBRG2BGR_VNG = 65
COLOR_BAYER_BG2RGB_VNG = 64
COLOR_BAYER_GB2RGB_VNG = 65
COLOR_BAYER_RG2RGB_VNG = 62
COLOR_BAYER_GR2RGB_VNG = 63
COLOR_BAYER_RGGB2RGB_VNG = 64
COLOR_BAYER_GRBG2RGB_VNG = 65
COLOR_BAYER_BGGR2RGB_VNG = 62
COLOR_BAYER_GBRG2RGB_VNG = 63
COLOR_BAYER_BG2GRAY = 86
COLOR_BAYER_GB2GRAY = 87
COLOR_BAYER_RG2GRAY = 88
COLOR_BAYER_GR2GRAY = 89
COLOR_BAYER_RGGB2GRAY = 86
COLOR_BAYER_GRBG2GRAY = 87
COLOR_BAYER_BGGR2GRAY = 88
COLOR_BAYER_GBRG2GRAY = 89
COLOR_BAYER_BG2BGR_EA = 135
COLOR_BAYER_GB2BGR_EA = 136
COLOR_BAYER_RG2BGR_EA = 137
COLOR_BAYER_GR2BGR_EA = 138
COLOR_BAYER_RGGB2BGR_EA = 135
COLOR_BAYER_GRBG2BGR_EA = 136
COLOR_BAYER_BGGR2BGR_EA = 137
COLOR_BAYER_GBRG2BGR_EA = 138
COLOR_BAYER_BG2RGB_EA = 137
COLOR_BAYER_GB2RGB_EA = 138
COLOR_BAYER_RG2RGB_EA = 135
COLOR_BAYER_GR2RGB_EA = 136
COLOR_BAYER_RGGB2RGB_EA = 137
COLOR_BAYER_GRBG2RGB_EA = 138
COLOR_BAYER_BGGR2RGB_EA = 135
COLOR_BAYER_GBRG2RGB_EA = 136
COLOR_BAYER_BG2BGRA = 139
COLOR_BAYER_GB2BGRA = 140
COLOR_BAYER_RG2BGRA = 141
COLOR_BAYER_GR2BGRA = 142
COLOR_BAYER_RGGB2BGRA = 139
COLOR_BAYER_GRBG2BGRA = 140
COLOR_BAYER_BGGR2BGRA = 141
COLOR_BAYER_GBRG2BGRA = 142
COLOR_BAYER_BG2RGBA = 141
COLOR_BAYER_GB2RGBA = 142
COLOR_BAYER_RG2RGBA = 139
COLOR_BAYER_GR2RGBA = 140
COLOR_BAYER_RGGB2RGBA = 141
COLOR_BAYER_GRBG2RGBA = 142
COLOR_BAYER_BGGR2RGBA = 139
COLOR_BAYER_GBRG2RGBA = 140

CONSTANTS = {
    k: v for k, v in list(globals().items())
    if k.startswith(("INPAINT_", "COLOR_Bayer", "COLOR_BAYER_"))
    or k in (
        "NORMAL_CLONE", "MIXED_CLONE", "MONOCHROME_TRANSFER",
        "NORMAL_CLONE_WIDE", "MIXED_CLONE_WIDE",
        "RECURS_FILTER", "NORMCONV_FILTER", "LDR_SIZE",
    )
}

__all__ = [
    # Functions
    "inpaint",
    "fastNlMeansDenoising",
    "fastNlMeansDenoisingColored",
    "fastNlMeansDenoisingMulti",
    "fastNlMeansDenoisingColoredMulti",
    "denoise_TVL1",
    "seamlessClone",
    "colorChange",
    "illuminationChange",
    "textureFlattening",
    "edgePreservingFilter",
    "detailEnhance",
    "pencilSketch",
    "stylization",
    "decolor",
    "demosaicing",
    # HDR classes & factories
    "AlignMTB", "createAlignMTB",
    "CalibrateDebevec", "createCalibrateDebevec",
    "CalibrateRobertson", "createCalibrateRobertson",
    "MergeDebevec", "createMergeDebevec",
    "MergeRobertson", "createMergeRobertson",
    "MergeMertens", "createMergeMertens",
    "Tonemap", "createTonemap",
    "TonemapDrago", "createTonemapDrago",
    "TonemapReinhard", "createTonemapReinhard",
    "TonemapMantiuk", "createTonemapMantiuk",
] + sorted(CONSTANTS.keys())

# --------------------------------------------------------------------------- C declarations

_c_inpaint = declare("sr_photo_inpaint", IMG_ARGS * 3 + [F64, I32])
_c_nlm = declare("sr_photo_nlm", IMG_ARGS * 2 + [_PF32, I32, I32, I32, I32])
_c_nlm_colored = declare("sr_photo_nlm_colored", IMG_ARGS * 2 + [_F32, _F32, I32, I32])
_c_nlm_multi = declare("sr_photo_nlm_multi", [_PVP, PI32, I32, I32, I32, I32, I32, I32] + IMG_ARGS + [_PF32, I32, I32, I32, I32])
_c_nlm_colored_multi = declare("sr_photo_nlm_colored_multi", [_PVP, PI32, I32, I32, I32, I32] + IMG_ARGS + [_F32, _F32, I32, I32])
_c_tvl1 = declare("sr_photo_denoise_tvl1", [_PVP, PI32, I32, I32, I32] + IMG_ARGS + [F64, I32])

_c_seamless = declare("sr_photo_seamless_clone", IMG_ARGS * 4 + [I32, I32, I32])
_c_color_change = declare("sr_photo_color_change", IMG_ARGS * 3 + [F64, F64, F64])
_c_illum_change = declare("sr_photo_illumination_change", IMG_ARGS * 3 + [F64, F64])
_c_tex_flatten = declare("sr_photo_texture_flattening", IMG_ARGS * 3 + [F64, F64, I32])

_c_npr = declare("sr_photo_npr", IMG_ARGS * 3 + [I32, I32, F64, F64, F64])
_c_decolor = declare("sr_photo_decolor", IMG_ARGS * 3)
_c_demosaic = declare("sr_photo_demosaicing", IMG_ARGS * 2 + [I32, I32])

_c_align_bitmaps = declare("sr_hdr_align_compute_bitmaps", IMG_ARGS * 3 + [I32])
_c_align_shift = declare("sr_hdr_align_calc_shift", IMG_ARGS * 2 + [I32, I32, PI32, PI32])
_c_align_shift_mat = declare("sr_hdr_align_shift_mat", IMG_ARGS * 2 + [I32, I32])

_c_cal_debevec = declare("sr_hdr_calibrate_debevec", [_PVP, PI32, I32, I32, I32, I32, _PF32, I32, F64, I32, _PF32])
_c_cal_robertson = declare("sr_hdr_calibrate_robertson", [_PVP, PI32, I32, I32, I32, I32, _PF32, I32, F64, _PF32, _PF32])

_c_merge_debevec = declare("sr_hdr_merge_debevec", [_PVP, PI32, I32, I32, I32, I32, _PF32, _PF32] + IMG_ARGS)
_c_merge_robertson = declare("sr_hdr_merge_robertson", [_PVP, PI32, I32, I32, I32, I32, _PF32, _PF32] + IMG_ARGS)
_c_merge_mertens = declare("sr_hdr_merge_mertens", [_PVP, PI32, I32, I32, I32, I32, F64, F64, F64] + IMG_ARGS)

_c_tonemap = declare("sr_hdr_tonemap", IMG_ARGS * 2 + [F64])
_c_tonemap_drago = declare("sr_hdr_tonemap_drago", IMG_ARGS * 2 + [F64, F64, F64])
_c_tonemap_reinhard = declare("sr_hdr_tonemap_reinhard", IMG_ARGS * 2 + [F64, F64, F64, F64])
_c_tonemap_mantiuk = declare("sr_hdr_tonemap_mantiuk", IMG_ARGS * 2 + [F64, F64, F64])

# --------------------------------------------------------------------------- helpers

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


def _src(a, who: str, dtypes=_OK_DTYPES) -> np.ndarray:
    arr = np.asarray(a)
    if arr.dtype not in dtypes:
        raise error(f"{who}: unsupported dtype {arr.dtype}")
    if arr.ndim not in (2, 3) or (arr.ndim == 3 and not 1 <= arr.shape[2] <= 4):
        raise error(f"{who}: unsupported shape {arr.shape}")
    if arr.size == 0:
        raise error(f"{who}: empty image")
    if not _usable(arr):
        arr = np.ascontiguousarray(arr)
    return arr


def _dst(dst, shape: tuple, dtype) -> np.ndarray:
    dt = np.dtype(dtype)
    if isinstance(dst, np.ndarray) and dst.shape == shape and dst.dtype == dt and dst.flags.writeable and _usable(dst):
        return dst
    return np.empty(shape, dt)


def _ch(a: np.ndarray) -> int:
    return 1 if a.ndim == 2 else a.shape[2]


def _shape(h: int, w: int, c: int) -> tuple:
    return (h, w) if c == 1 else (h, w, c)


def _pack_frames(frames: list[np.ndarray], who: str, dtypes=(np.dtype(np.uint8),)):
    if not frames:
        raise error(f"{who}: empty image sequence")
    arrs = [_src(f, who, dtypes) for f in frames]
    h, w = arrs[0].shape[:2]
    c = _ch(arrs[0])
    dt = arrs[0].dtype
    for f in arrs[1:]:
        if f.shape[:2] != (h, w) or _ch(f) != c or f.dtype != dt:
            raise error(f"{who}: all frames must have matching shape and dtype")
    n = len(arrs)
    ptrs = (VP * n)(*[a.ctypes.data for a in arrs])
    strides = (I32 * n)(*[a.strides[0] if h > 1 else w * c * dt.itemsize for a in arrs])
    return arrs, ptrs, strides, h, w, c, dt


def _prepare_mask(mask, expected_hw: tuple[int, int], who: str) -> np.ndarray:
    if mask is None:
        return np.empty((0, 0), np.uint8)
    m = np.asarray(mask)
    if m.size == 0:
        return np.empty((0, 0), np.uint8)
    if m.dtype != np.uint8:
        raise error(f"{who}: mask must be uint8")
    if m.ndim == 3 and m.shape[2] in (3, 4):
        m = np.ascontiguousarray(m[..., 0])
    elif m.ndim == 3 and m.shape[2] == 1:
        m = np.ascontiguousarray(m[..., 0])
    elif m.ndim != 2:
        raise error(f"{who}: invalid mask dimensions {m.shape}")
    if m.shape[:2] != expected_hw:
        raise error(f"{who}: mask size {m.shape[:2]} != expected {expected_hw}")
    if not _usable(m):
        m = np.ascontiguousarray(m)
    return m


# --------------------------------------------------------------------------- 1. Inpainting

def inpaint(src, inpaintMask, inpaintRadius, flags, dst=None):
    a = _src(src, "inpaint", (np.dtype(np.uint8), np.dtype(np.uint16), np.dtype(np.float32)))
    m = _src(inpaintMask, "inpaint", (np.dtype(np.uint8),))
    if _ch(m) != 1:
        raise error("inpaint: mask must be single-channel uint8")
    if a.shape[:2] != m.shape[:2]:
        raise error("inpaint: src and mask size mismatch")
    if _ch(a) not in (1, 3):
        raise error("inpaint: src must have 1 or 3 channels")
    out = _dst(dst, a.shape, a.dtype)
    check(_c_inpaint(*img_args(a), *img_args(m), *img_args(out), float(inpaintRadius), int(flags)), "inpaint")
    return out


# --------------------------------------------------------------------------- 2. NLM & TV-L1

def _parse_h_array(h_val, ch: int, who: str):
    if isinstance(h_val, (int, float, np.integer, np.floating)):
        arr = (ctypes.c_float * 1)(float(h_val))
        return arr, 1
    seq = [float(v) for v in np.asarray(h_val, np.float32).ravel()]
    if len(seq) not in (1, ch):
        raise error(f"{who}: h length {len(seq)} must be 1 or {ch}")
    arr = (ctypes.c_float * len(seq))(*seq)
    return arr, len(seq)


def fastNlMeansDenoising(src, dst=None, h=3, templateWindowSize=7, searchWindowSize=21, normType=_NORM_L2):
    a = _src(src, "fastNlMeansDenoising", (np.dtype(np.uint8), np.dtype(np.uint16)))
    # Support both OpenCV overloads:
    # 1) (src, dst=None, h=3, templateWindowSize=7, searchWindowSize=21)
    # 2) (src, h, dst=None, templateWindowSize=7, searchWindowSize=21, normType=NORM_L2)
    if dst is not None and not (isinstance(dst, np.ndarray) and dst.ndim in (2, 3) and dst.shape == a.shape):
        real_h = dst
        real_dst = h if (h is None or isinstance(h, np.ndarray)) else None
    else:
        real_dst = dst
        real_h = h

    ch = _ch(a)
    h_arr, h_cnt = _parse_h_array(real_h, ch, "fastNlMeansDenoising")
    out = _dst(real_dst, a.shape, a.dtype)
    check(
        _c_nlm(*img_args(a), *img_args(out), h_arr, h_cnt,
               int(templateWindowSize), int(searchWindowSize), int(normType)),
        "fastNlMeansDenoising",
    )
    return out


def fastNlMeansDenoisingColored(src, dst=None, h=3, hColor=3, templateWindowSize=7, searchWindowSize=21):
    a = _src(src, "fastNlMeansDenoisingColored", (np.dtype(np.uint8),))
    if _ch(a) != 3:
        raise error("fastNlMeansDenoisingColored: requires 3-channel uint8 image")
    out = _dst(dst, a.shape, a.dtype)
    check(
        _c_nlm_colored(*img_args(a), *img_args(out), float(h), float(hColor),
                       int(templateWindowSize), int(searchWindowSize)),
        "fastNlMeansDenoisingColored",
    )
    return out


def fastNlMeansDenoisingMulti(
    srcImgs, imgToDenoiseIndex, temporalWindowSize, dst=None, h=3,
    templateWindowSize=7, searchWindowSize=21, normType=_NORM_L2,
):
    if dst is not None and not (isinstance(dst, np.ndarray) and dst.ndim in (2, 3)):
        real_h = dst
        real_dst = h if (h is None or isinstance(h, np.ndarray)) else None
    else:
        real_dst = dst
        real_h = h

    tw = int(temporalWindowSize)
    idx = int(imgToDenoiseIndex)
    if tw < 1 or (tw & 1) == 0:
        raise error("fastNlMeansDenoisingMulti: temporalWindowSize must be positive odd")
    half = tw // 2
    if idx - half < 0 or idx + half >= len(srcImgs):
        raise error("fastNlMeansDenoisingMulti: temporal window out of range")

    window = list(srcImgs[idx - half: idx + half + 1])
    arrs, ptrs, strides, h_img, w_img, ch, dt = _pack_frames(
        window, "fastNlMeansDenoisingMulti", (np.dtype(np.uint8), np.dtype(np.uint16))
    )
    h_arr, h_cnt = _parse_h_array(real_h, ch, "fastNlMeansDenoisingMulti")
    out = _dst(real_dst, arrs[half].shape, dt)
    depth_code = 0 if dt == np.uint8 else 2
    check(
        _c_nlm_multi(ptrs, strides, len(arrs), half, w_img, h_img, ch, depth_code,
                     *img_args(out), h_arr, h_cnt,
                     int(templateWindowSize), int(searchWindowSize), int(normType)),
        "fastNlMeansDenoisingMulti",
    )
    return out


def fastNlMeansDenoisingColoredMulti(
    srcImgs, imgToDenoiseIndex, temporalWindowSize, dst=None, h=3, hColor=3,
    templateWindowSize=7, searchWindowSize=21,
):
    tw = int(temporalWindowSize)
    idx = int(imgToDenoiseIndex)
    if tw < 1 or (tw & 1) == 0:
        raise error("fastNlMeansDenoisingColoredMulti: temporalWindowSize must be positive odd")
    half = tw // 2
    if idx - half < 0 or idx + half >= len(srcImgs):
        raise error("fastNlMeansDenoisingColoredMulti: temporal window out of range")

    window = list(srcImgs[idx - half: idx + half + 1])
    arrs, ptrs, strides, h_img, w_img, ch, dt = _pack_frames(
        window, "fastNlMeansDenoisingColoredMulti", (np.dtype(np.uint8),)
    )
    if ch != 3:
        raise error("fastNlMeansDenoisingColoredMulti: requires 3-channel uint8 images")
    out = _dst(dst, arrs[half].shape, dt)
    check(
        _c_nlm_colored_multi(ptrs, strides, len(arrs), half, w_img, h_img,
                             *img_args(out), float(h), float(hColor),
                             int(templateWindowSize), int(searchWindowSize)),
        "fastNlMeansDenoisingColoredMulti",
    )
    return out


def denoise_TVL1(observations, result=None, lambda_=1.0, niters=30):
    arrs, ptrs, strides, h_img, w_img, ch, _ = _pack_frames(
        list(observations), "denoise_TVL1", (np.dtype(np.uint8),)
    )
    if ch != 1:
        raise error("denoise_TVL1: observations must be 1-channel uint8")
    if result is None:
        return None
    if not (isinstance(result, np.ndarray) and result.shape == (h_img, w_img) and result.dtype == np.uint8 and result.flags.writeable):
        out = np.empty((h_img, w_img), np.uint8)
        check(_c_tvl1(ptrs, strides, len(arrs), w_img, h_img, *img_args(out), float(lambda_), int(niters)), "denoise_TVL1")
        if isinstance(result, np.ndarray) and result.shape == out.shape and result.dtype == np.uint8 and result.flags.writeable:
            np.copyto(result, out)
        return None
    out = result if _usable(result) else np.empty((h_img, w_img), np.uint8)
    check(_c_tvl1(ptrs, strides, len(arrs), w_img, h_img, *img_args(out), float(lambda_), int(niters)), "denoise_TVL1")
    if out is not result:
        np.copyto(result, out)
    return None


# --------------------------------------------------------------------------- 3. Seamless Cloning & Poisson Editing

def seamlessClone(src, dst, mask, p, flags, blend=None):
    s = _src(src, "seamlessClone", (np.dtype(np.uint8),))
    d = _src(dst, "seamlessClone", (np.dtype(np.uint8),))
    if _ch(s) != 3 or _ch(d) != 3:
        raise error("seamlessClone: src and dst must be 3-channel uint8")
    m = _prepare_mask(mask, s.shape[:2], "seamlessClone")
    px, py = int(p[0]), int(p[1])
    out = _dst(blend, d.shape, np.uint8)
    m_args = img_args(m) if m.size > 0 else [None, 0, 0, 0, 1, 0]
    check(_c_seamless(*img_args(s), *img_args(d), *m_args, *img_args(out), px, py, int(flags)), "seamlessClone")
    return out


def colorChange(src, mask, dst=None, red_mul=1.0, green_mul=1.0, blue_mul=1.0):
    s = _src(src, "colorChange", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("colorChange: src must be 3-channel uint8")
    m = _prepare_mask(mask, s.shape[:2], "colorChange")
    out = _dst(dst, s.shape, np.uint8)
    m_args = img_args(m) if m.size > 0 else [None, 0, 0, 0, 1, 0]
    check(_c_color_change(*img_args(s), *m_args, *img_args(out), float(red_mul), float(green_mul), float(blue_mul)), "colorChange")
    return out


def illuminationChange(src, mask, dst=None, alpha=0.2, beta=0.4):
    s = _src(src, "illuminationChange", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("illuminationChange: src must be 3-channel uint8")
    m = _prepare_mask(mask, s.shape[:2], "illuminationChange")
    out = _dst(dst, s.shape, np.uint8)
    m_args = img_args(m) if m.size > 0 else [None, 0, 0, 0, 1, 0]
    check(_c_illum_change(*img_args(s), *m_args, *img_args(out), float(alpha), float(beta)), "illuminationChange")
    return out


def textureFlattening(src, mask, dst=None, low_threshold=30, high_threshold=45, kernel_size=3):
    s = _src(src, "textureFlattening", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("textureFlattening: src must be 3-channel uint8")
    m = _prepare_mask(mask, s.shape[:2], "textureFlattening")
    out = _dst(dst, s.shape, np.uint8)
    m_args = img_args(m) if m.size > 0 else [None, 0, 0, 0, 1, 0]
    check(
        _c_tex_flatten(*img_args(s), *m_args, *img_args(out),
                       float(low_threshold), float(high_threshold), int(kernel_size)),
        "textureFlattening",
    )
    return out


# --------------------------------------------------------------------------- 4. NPR Filters

def edgePreservingFilter(src, dst=None, flags=RECURS_FILTER, sigma_s=60, sigma_r=0.4):
    s = _src(src, "edgePreservingFilter", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("edgePreservingFilter: requires 3-channel uint8")
    out = _dst(dst, s.shape, np.uint8)
    dummy = np.empty((1, 1), np.uint8)
    check(_c_npr(*img_args(s), *img_args(out), *img_args(dummy), 0, int(flags), float(sigma_s), float(sigma_r), 0.0), "edgePreservingFilter")
    return out


def detailEnhance(src, dst=None, sigma_s=10, sigma_r=0.15):
    s = _src(src, "detailEnhance", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("detailEnhance: requires 3-channel uint8")
    out = _dst(dst, s.shape, np.uint8)
    dummy = np.empty((1, 1), np.uint8)
    check(_c_npr(*img_args(s), *img_args(out), *img_args(dummy), 1, 1, float(sigma_s), float(sigma_r), 0.0), "detailEnhance")
    return out


def pencilSketch(src, dst1=None, dst2=None, sigma_s=60, sigma_r=0.07, shade_factor=0.02):
    s = _src(src, "pencilSketch", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("pencilSketch: requires 3-channel uint8")
    h, w = s.shape[:2]
    o1 = _dst(dst1, (h, w), np.uint8)
    o2 = _dst(dst2, (h, w, 3), np.uint8)
    check(_c_npr(*img_args(s), *img_args(o1), *img_args(o2), 2, 2, float(sigma_s), float(sigma_r), float(shade_factor)), "pencilSketch")
    return o1, o2


def stylization(src, dst=None, sigma_s=60, sigma_r=0.45):
    s = _src(src, "stylization", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("stylization: requires 3-channel uint8")
    out = _dst(dst, s.shape, np.uint8)
    dummy = np.empty((1, 1), np.uint8)
    check(_c_npr(*img_args(s), *img_args(out), *img_args(dummy), 3, 2, float(sigma_s), float(sigma_r), 0.0), "stylization")
    return out


# --------------------------------------------------------------------------- 5. Decolor & Demosaicing

def decolor(src, grayscale=None, color_boost=None):
    s = _src(src, "decolor", (np.dtype(np.uint8),))
    if _ch(s) != 3:
        raise error("decolor: requires 3-channel uint8")
    h, w = s.shape[:2]
    g = _dst(grayscale, (h, w), np.uint8)
    cb = _dst(color_boost, (h, w, 3), np.uint8)
    check(_c_decolor(*img_args(s), *img_args(g), *img_args(cb)), "decolor")
    return g, cb


_DEMOSAIC_MAP = {
    46: (0, 0, 3), 47: (1, 0, 3), 48: (2, 0, 3), 49: (3, 0, 3),      # Bilinear BGR/RGB
    62: (0, 2, 3), 63: (1, 2, 3), 64: (2, 2, 3), 65: (3, 2, 3),      # VNG BGR/RGB
    86: (0, 3, 1), 87: (1, 3, 1), 88: (2, 3, 1), 89: (3, 3, 1),      # GRAY
    135: (0, 1, 3), 136: (1, 1, 3), 137: (2, 1, 3), 138: (3, 1, 3),  # EA BGR/RGB
    139: (0, 0, 4), 140: (1, 0, 4), 141: (2, 0, 4), 142: (3, 0, 4),  # BGRA/RGBA
}


def demosaicing(src, code, dst=None, dstCn=0):
    s = _src(src, "demosaicing", (np.dtype(np.uint8), np.dtype(np.uint16)))
    if _ch(s) != 1:
        raise error("demosaicing: src must be single-channel")
    info = _DEMOSAIC_MAP.get(int(code))
    if info is None:
        raise error(f"demosaicing: unsupported Bayer conversion code {code}")
    pattern, algo, default_cn = info
    cn = int(dstCn) if int(dstCn) > 0 else default_cn
    if cn not in (1, 3, 4):
        raise error(f"demosaicing: invalid dstCn {cn}")
    h, w = s.shape[:2]
    out = _dst(dst, _shape(h, w, cn), s.dtype)
    check(_c_demosaic(*img_args(s), *img_args(out), pattern, algo), "demosaicing")
    return out


# --------------------------------------------------------------------------- 6. HDR Pipeline Classes & Factories

class AlignMTB:
    def __init__(self, max_bits: int = 6, exclude_range: int = 4, cut: bool = True):
        self._max_bits = int(max_bits)
        self._exclude_range = int(exclude_range)
        self._cut = bool(cut)

    def getMaxBits(self) -> int: return self._max_bits
    def setMaxBits(self, max_bits: int) -> None: self._max_bits = int(max_bits)
    def getExcludeRange(self) -> int: return self._exclude_range
    def setExcludeRange(self, exclude_range: int) -> None: self._exclude_range = int(exclude_range)
    def getCut(self) -> bool: return self._cut
    def setCut(self, value: bool) -> None: self._cut = bool(value)

    def computeBitmaps(self, img, tb=None, eb=None):
        a = _src(img, "AlignMTB.computeBitmaps", (np.dtype(np.uint8),))
        if _ch(a) != 1:
            raise error("AlignMTB.computeBitmaps: requires 1-channel uint8 image")
        tb_out = _dst(tb, a.shape, np.uint8)
        eb_out = _dst(eb, a.shape, np.uint8)
        check(_c_align_bitmaps(*img_args(a), *img_args(tb_out), *img_args(eb_out), self._exclude_range), "AlignMTB.computeBitmaps")
        return tb_out, eb_out

    def calculateShift(self, img0, img1) -> tuple[int, int]:
        a0 = _src(img0, "AlignMTB.calculateShift", (np.dtype(np.uint8),))
        a1 = _src(img1, "AlignMTB.calculateShift", (np.dtype(np.uint8),))
        if _ch(a0) != 1 or _ch(a1) != 1 or a0.shape != a1.shape:
            raise error("AlignMTB.calculateShift: requires matching 1-channel uint8 images")
        dx, dy = I32(0), I32(0)
        check(
            _c_align_shift(*img_args(a0), *img_args(a1), self._max_bits, self._exclude_range,
                           ctypes.byref(dx), ctypes.byref(dy)),
            "AlignMTB.calculateShift",
        )
        return int(dx.value), int(dy.value)

    def shiftMat(self, src, shift, dst=None):
        a = _src(src, "AlignMTB.shiftMat")
        dx, dy = int(shift[0]), int(shift[1])
        out = _dst(dst, a.shape, a.dtype)
        check(_c_align_shift_mat(*img_args(a), *img_args(out), dx, dy), "AlignMTB.shiftMat")
        return out

    def process(self, src, dst, times=None, response=None):
        frames = [_src(f, "AlignMTB.process", (np.dtype(np.uint8),)) for f in src]
        if not frames:
            return None
        grays = []
        for f in frames:
            if _ch(f) == 1:
                grays.append(f)
            else:
                g = np.rint(0.114 * f[..., 0] + 0.587 * f[..., 1] + 0.299 * f[..., 2]).astype(np.uint8)
                grays.append(g)

        shifts = [(0, 0)]
        cum_x, cum_y = 0, 0
        for i in range(1, len(grays)):
            dx, dy = self.calculateShift(grays[i - 1], grays[i])
            cum_x += dx
            cum_y += dy
            shifts.append((cum_x, cum_y))

        aligned = [self.shiftMat(f, sh) for f, sh in zip(frames, shifts)]
        if self._cut and len(aligned) > 0:
            h, w = aligned[0].shape[:2]
            left = max(0, *(max(0, dx) for dx, _ in shifts))
            right = max(0, *(max(0, -dx) for dx, _ in shifts))
            top = max(0, *(max(0, dy) for _, dy in shifts))
            bottom = max(0, *(max(0, -dy) for _, dy in shifts))
            for img in aligned:
                if top > 0:
                    img[:top, ...] = 0
                if bottom > 0:
                    img[max(0, h - bottom):, ...] = 0
                if left > 0:
                    img[:, :left, ...] = 0
                if right > 0:
                    img[:, max(0, w - right):, ...] = 0

        if isinstance(dst, list):
            if len(dst) == len(aligned):
                for i, im in enumerate(aligned):
                    if isinstance(dst[i], np.ndarray) and dst[i].shape == im.shape and dst[i].dtype == im.dtype and dst[i].flags.writeable:
                        np.copyto(dst[i], im)
                    else:
                        dst[i] = im
            else:
                dst.clear()
                dst.extend(aligned)
        return None


def createAlignMTB(max_bits: int = 6, exclude_range: int = 4, cut: bool = True) -> AlignMTB:
    return AlignMTB(max_bits=max_bits, exclude_range=exclude_range, cut=cut)


class CalibrateDebevec:
    def __init__(self, samples: int = 70, lambda_: float = 10.0, random: bool = False):
        self._samples = int(samples)
        self._lambda = float(lambda_)
        self._random = bool(random)

    def getSamples(self) -> int: return self._samples
    def setSamples(self, samples: int) -> None: self._samples = int(samples)
    def getLambda(self) -> float: return self._lambda
    def setLambda(self, lambda_: float) -> None: self._lambda = float(lambda_)
    def getRandom(self) -> bool: return self._random
    def setRandom(self, random: bool) -> None: self._random = bool(random)

    def process(self, src, times, dst=None):
        arrs, ptrs, strides, h, w, ch, _ = _pack_frames(list(src), "CalibrateDebevec.process", (np.dtype(np.uint8),))
        t_arr = np.ascontiguousarray(np.asarray(times, np.float32).ravel())
        if t_arr.size != len(arrs):
            raise error("CalibrateDebevec.process: times length must match src length")
        out_shape = (256, 1) if ch == 1 else (256, 1, ch)
        out = _dst(dst, out_shape, np.float32)
        check(
            _c_cal_debevec(ptrs, strides, len(arrs), w, h, ch,
                           t_arr.ctypes.data_as(_PF32), self._samples, self._lambda,
                           1 if self._random else 0, out.ctypes.data_as(_PF32)),
            "CalibrateDebevec.process",
        )
        return out


def createCalibrateDebevec(samples: int = 70, lambda_: float = 10.0, random: bool = False) -> CalibrateDebevec:
    return CalibrateDebevec(samples=samples, lambda_=lambda_, random=random)


class CalibrateRobertson:
    def __init__(self, max_iter: int = 30, threshold: float = 0.01):
        self._max_iter = int(max_iter)
        self._threshold = float(threshold)
        self._radiance = np.empty((0, 0), np.float32)

    def getMaxIter(self) -> int: return self._max_iter
    def setMaxIter(self, max_iter: int) -> None: self._max_iter = int(max_iter)
    def getThreshold(self) -> float: return self._threshold
    def setThreshold(self, threshold: float) -> None: self._threshold = float(threshold)
    def getRadiance(self) -> np.ndarray: return self._radiance

    def process(self, src, times, dst=None):
        arrs, ptrs, strides, h, w, ch, _ = _pack_frames(list(src), "CalibrateRobertson.process", (np.dtype(np.uint8),))
        t_arr = np.ascontiguousarray(np.asarray(times, np.float32).ravel())
        if t_arr.size != len(arrs):
            raise error("CalibrateRobertson.process: times length must match src length")
        out_shape = (256, 1) if ch == 1 else (256, 1, ch)
        out = _dst(dst, out_shape, np.float32)
        rad = np.empty(_shape(h, w, ch), np.float32)
        check(
            _c_cal_robertson(ptrs, strides, len(arrs), w, h, ch,
                             t_arr.ctypes.data_as(_PF32), self._max_iter, self._threshold,
                             out.ctypes.data_as(_PF32), rad.ctypes.data_as(_PF32)),
            "CalibrateRobertson.process",
        )
        self._radiance = rad
        return out


def createCalibrateRobertson(max_iter: int = 30, threshold: float = 0.01) -> CalibrateRobertson:
    return CalibrateRobertson(max_iter=max_iter, threshold=threshold)


def _merge_crf_helper(fn, who: str, src, times, response=None, dst=None):
    arrs, ptrs, strides, h, w, ch, _ = _pack_frames(list(src), who, (np.dtype(np.uint8),))
    t_arr = np.ascontiguousarray(np.asarray(times, np.float32).ravel())
    if t_arr.size != len(arrs):
        raise error(f"{who}: times length must match src length")
    resp_ptr = None
    if response is not None:
        r = np.ascontiguousarray(np.asarray(response, np.float32))
        if r.size == 0:
            r = None
        elif r.shape[0] != 256 or (r.size != 256 * ch):
            raise error(f"{who}: response must have 256 x 1 x {ch} entries")
        if r is not None:
            resp_ptr = r.ctypes.data_as(_PF32)
    out = _dst(dst, _shape(h, w, ch), np.float32)
    check(fn(ptrs, strides, len(arrs), w, h, ch, t_arr.ctypes.data_as(_PF32), resp_ptr, *img_args(out)), who)
    return out


class MergeDebevec:
    def process(self, src, times, response=None, dst=None):
        if response is not None and dst is None and isinstance(response, np.ndarray) and response.shape[0] != 256:
            return _merge_crf_helper(_c_merge_debevec, "MergeDebevec.process", src, times, None, response)
        return _merge_crf_helper(_c_merge_debevec, "MergeDebevec.process", src, times, response, dst)


def createMergeDebevec() -> MergeDebevec:
    return MergeDebevec()


class MergeRobertson:
    def process(self, src, times, response=None, dst=None):
        if response is not None and dst is None and isinstance(response, np.ndarray) and response.shape[0] != 256:
            return _merge_crf_helper(_c_merge_robertson, "MergeRobertson.process", src, times, None, response)
        return _merge_crf_helper(_c_merge_robertson, "MergeRobertson.process", src, times, response, dst)


def createMergeRobertson() -> MergeRobertson:
    return MergeRobertson()


class MergeMertens:
    def __init__(self, contrast_weight: float = 1.0, saturation_weight: float = 1.0, exposure_weight: float = 0.0):
        self._cw = float(contrast_weight)
        self._sw = float(saturation_weight)
        self._ew = float(exposure_weight)

    def getContrastWeight(self) -> float: return self._cw
    def setContrastWeight(self, contrast_weight: float) -> None: self._cw = float(contrast_weight)
    def getSaturationWeight(self) -> float: return self._sw
    def setSaturationWeight(self, saturation_weight: float) -> None: self._sw = float(saturation_weight)
    def getExposureWeight(self) -> float: return self._ew
    def setExposureWeight(self, exposure_weight: float) -> None: self._ew = float(exposure_weight)

    def process(self, src, times=None, response=None, dst=None):
        arrs, ptrs, strides, h, w, ch, _ = _pack_frames(list(src), "MergeMertens.process", (np.dtype(np.uint8),))
        real_dst = dst
        if times is not None and response is None and dst is None and isinstance(times, np.ndarray) and times.ndim >= 2:
            real_dst = times
        out = _dst(real_dst, _shape(h, w, ch), np.float32)
        check(_c_merge_mertens(ptrs, strides, len(arrs), w, h, ch, self._cw, self._sw, self._ew, *img_args(out)), "MergeMertens.process")
        return out


def createMergeMertens(contrast_weight: float = 1.0, saturation_weight: float = 1.0, exposure_weight: float = 0.0) -> MergeMertens:
    return MergeMertens(contrast_weight=contrast_weight, saturation_weight=saturation_weight, exposure_weight=exposure_weight)


class Tonemap:
    def __init__(self, gamma: float = 1.0):
        self._gamma = float(gamma)

    def getGamma(self) -> float: return self._gamma
    def setGamma(self, gamma: float) -> None: self._gamma = float(gamma)

    def process(self, src, dst=None):
        a = _src(src, "Tonemap.process", (np.dtype(np.float32),))
        if _ch(a) != 3:
            raise error("Tonemap.process: requires 3-channel float32 image")
        out = _dst(dst, a.shape, np.float32)
        check(_c_tonemap(*img_args(a), *img_args(out), self._gamma), "Tonemap.process")
        return out


def createTonemap(gamma: float = 1.0) -> Tonemap:
    return Tonemap(gamma=gamma)


class TonemapDrago(Tonemap):
    def __init__(self, gamma: float = 1.0, saturation: float = 1.0, bias: float = 0.85):
        super().__init__(gamma)
        self._saturation = float(saturation)
        self._bias = float(bias)

    def getSaturation(self) -> float: return self._saturation
    def setSaturation(self, saturation: float) -> None: self._saturation = float(saturation)
    def getBias(self) -> float: return self._bias
    def setBias(self, bias: float) -> None: self._bias = float(bias)

    def process(self, src, dst=None):
        a = _src(src, "TonemapDrago.process", (np.dtype(np.float32),))
        if _ch(a) != 3:
            raise error("TonemapDrago.process: requires 3-channel float32 image")
        out = _dst(dst, a.shape, np.float32)
        check(_c_tonemap_drago(*img_args(a), *img_args(out), self._gamma, self._saturation, self._bias), "TonemapDrago.process")
        return out


def createTonemapDrago(gamma: float = 1.0, saturation: float = 1.0, bias: float = 0.85) -> TonemapDrago:
    return TonemapDrago(gamma=gamma, saturation=saturation, bias=bias)


class TonemapReinhard(Tonemap):
    def __init__(self, gamma: float = 1.0, intensity: float = 0.0, light_adapt: float = 1.0, color_adapt: float = 0.0):
        super().__init__(gamma)
        self._intensity = float(intensity)
        self._light_adapt = float(light_adapt)
        self._color_adapt = float(color_adapt)

    def getIntensity(self) -> float: return self._intensity
    def setIntensity(self, intensity: float) -> None: self._intensity = float(intensity)
    def getLightAdaptation(self) -> float: return self._light_adapt
    def setLightAdaptation(self, light_adapt: float) -> None: self._light_adapt = float(light_adapt)
    def getColorAdaptation(self) -> float: return self._color_adapt
    def setColorAdaptation(self, color_adapt: float) -> None: self._color_adapt = float(color_adapt)

    def process(self, src, dst=None):
        a = _src(src, "TonemapReinhard.process", (np.dtype(np.float32),))
        if _ch(a) != 3:
            raise error("TonemapReinhard.process: requires 3-channel float32 image")
        out = _dst(dst, a.shape, np.float32)
        check(
            _c_tonemap_reinhard(*img_args(a), *img_args(out), self._gamma, self._intensity, self._light_adapt, self._color_adapt),
            "TonemapReinhard.process",
        )
        return out


def createTonemapReinhard(gamma: float = 1.0, intensity: float = 0.0, light_adapt: float = 1.0, color_adapt: float = 0.0) -> TonemapReinhard:
    return TonemapReinhard(gamma=gamma, intensity=intensity, light_adapt=light_adapt, color_adapt=color_adapt)


class TonemapMantiuk(Tonemap):
    def __init__(self, gamma: float = 1.0, scale: float = 0.7, saturation: float = 1.0):
        super().__init__(gamma)
        self._scale = float(scale)
        self._saturation = float(saturation)

    def getScale(self) -> float: return self._scale
    def setScale(self, scale: float) -> None: self._scale = float(scale)
    def getSaturation(self) -> float: return self._saturation
    def setSaturation(self, saturation: float) -> None: self._saturation = float(saturation)

    def process(self, src, dst=None):
        a = _src(src, "TonemapMantiuk.process", (np.dtype(np.float32),))
        if _ch(a) != 3:
            raise error("TonemapMantiuk.process: requires 3-channel float32 image")
        out = _dst(dst, a.shape, np.float32)
        check(_c_tonemap_mantiuk(*img_args(a), *img_args(out), self._gamma, self._scale, self._saturation), "TonemapMantiuk.process")
        return out


def createTonemapMantiuk(gamma: float = 1.0, scale: float = 0.7, saturation: float = 1.0) -> TonemapMantiuk:
    return TonemapMantiuk(gamma=gamma, scale=scale, saturation=saturation)
