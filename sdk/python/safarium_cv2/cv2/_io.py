"""Area C: image IO + video reading (cv2.imdecode / imread / imencode / imwrite / VideoCapture).

Codec work happens in libSafariumRaster (ImageIO / AVFoundation); file IO stays in Python so
non-ASCII paths work. Failure behaviour follows cv2: imread/imdecode return None for an undecodable
file, imwrite returns False, an empty buffer or unknown extension raises ``cv2.error``.
Contract: Projects/Safarium/docs/raster-plan.md
"""
from __future__ import annotations

import ctypes
import os
import struct
import zlib

import numpy as np

from . import _lib
from ._lib import CSTR, I32, VP, declare

__all__ = ["imdecode", "imread", "imencode", "imwrite", "VideoCapture",
           "imcount", "imdecodemulti", "imreadmulti", "imwritemulti", "imencodemulti",
           "Animation", "imreadanimation", "imdecodeanimation", "imwriteanimation", "imencodeanimation",
           "imreadWithMetadata", "imdecodeWithMetadata", "imwriteWithMetadata", "imencodeWithMetadata",
           "haveImageReader", "haveImageWriter",
           "IMAGE_METADATA_CICP",
           "IMAGE_METADATA_EXIF",
           "IMAGE_METADATA_ICCP",
           "IMAGE_METADATA_MAX",
           "IMAGE_METADATA_UNKNOWN",
           "IMAGE_METADATA_XMP",
           "IMREAD_ANYCOLOR",
           "IMREAD_ANYDEPTH",
           "IMREAD_COLOR",
           "IMREAD_COLOR_BGR",
           "IMREAD_COLOR_RGB",
           "IMREAD_GRAYSCALE",
           "IMREAD_IGNORE_ORIENTATION",
           "IMREAD_LOAD_GDAL",
           "IMREAD_REDUCED_COLOR_2",
           "IMREAD_REDUCED_COLOR_4",
           "IMREAD_REDUCED_COLOR_8",
           "IMREAD_REDUCED_GRAYSCALE_2",
           "IMREAD_REDUCED_GRAYSCALE_4",
           "IMREAD_REDUCED_GRAYSCALE_8",
           "IMREAD_UNCHANGED",
           "IMWRITE_AVIF_ALPHA_QUALITY",
           "IMWRITE_AVIF_DEPTH",
           "IMWRITE_AVIF_QUALITY",
           "IMWRITE_AVIF_SPEED",
           "IMWRITE_BMP_COMPRESSION",
           "IMWRITE_BMP_COMPRESSION_BITFIELDS",
           "IMWRITE_BMP_COMPRESSION_RGB",
           "IMWRITE_EXR_COMPRESSION",
           "IMWRITE_EXR_COMPRESSION_B44",
           "IMWRITE_EXR_COMPRESSION_B44A",
           "IMWRITE_EXR_COMPRESSION_DWAA",
           "IMWRITE_EXR_COMPRESSION_DWAB",
           "IMWRITE_EXR_COMPRESSION_NO",
           "IMWRITE_EXR_COMPRESSION_PIZ",
           "IMWRITE_EXR_COMPRESSION_PXR24",
           "IMWRITE_EXR_COMPRESSION_RLE",
           "IMWRITE_EXR_COMPRESSION_ZIP",
           "IMWRITE_EXR_COMPRESSION_ZIPS",
           "IMWRITE_EXR_DWA_COMPRESSION_LEVEL",
           "IMWRITE_EXR_TYPE",
           "IMWRITE_EXR_TYPE_FLOAT",
           "IMWRITE_EXR_TYPE_HALF",
           "IMWRITE_GIF_COLORTABLE",
           "IMWRITE_GIF_COLORTABLE_SIZE_128",
           "IMWRITE_GIF_COLORTABLE_SIZE_16",
           "IMWRITE_GIF_COLORTABLE_SIZE_256",
           "IMWRITE_GIF_COLORTABLE_SIZE_32",
           "IMWRITE_GIF_COLORTABLE_SIZE_64",
           "IMWRITE_GIF_COLORTABLE_SIZE_8",
           "IMWRITE_GIF_DITHER",
           "IMWRITE_GIF_FAST_FLOYD_DITHER",
           "IMWRITE_GIF_FAST_NO_DITHER",
           "IMWRITE_GIF_LOOP",
           "IMWRITE_GIF_QUALITY",
           "IMWRITE_GIF_SPEED",
           "IMWRITE_GIF_TRANSPARENCY",
           "IMWRITE_HDR_COMPRESSION",
           "IMWRITE_HDR_COMPRESSION_NONE",
           "IMWRITE_HDR_COMPRESSION_RLE",
           "IMWRITE_JPEG2000_COMPRESSION_X1000",
           "IMWRITE_JPEGXL_DECODING_SPEED",
           "IMWRITE_JPEGXL_DISTANCE",
           "IMWRITE_JPEGXL_EFFORT",
           "IMWRITE_JPEGXL_QUALITY",
           "IMWRITE_JPEG_CHROMA_QUALITY",
           "IMWRITE_JPEG_LUMA_QUALITY",
           "IMWRITE_JPEG_OPTIMIZE",
           "IMWRITE_JPEG_PROGRESSIVE",
           "IMWRITE_JPEG_QUALITY",
           "IMWRITE_JPEG_RST_INTERVAL",
           "IMWRITE_JPEG_SAMPLING_FACTOR",
           "IMWRITE_JPEG_SAMPLING_FACTOR_411",
           "IMWRITE_JPEG_SAMPLING_FACTOR_420",
           "IMWRITE_JPEG_SAMPLING_FACTOR_422",
           "IMWRITE_JPEG_SAMPLING_FACTOR_440",
           "IMWRITE_JPEG_SAMPLING_FACTOR_444",
           "IMWRITE_PAM_FORMAT_BLACKANDWHITE",
           "IMWRITE_PAM_FORMAT_GRAYSCALE",
           "IMWRITE_PAM_FORMAT_GRAYSCALE_ALPHA",
           "IMWRITE_PAM_FORMAT_NULL",
           "IMWRITE_PAM_FORMAT_RGB",
           "IMWRITE_PAM_FORMAT_RGB_ALPHA",
           "IMWRITE_PAM_TUPLETYPE",
           "IMWRITE_PNG_ALL_FILTERS",
           "IMWRITE_PNG_BILEVEL",
           "IMWRITE_PNG_COMPRESSION",
           "IMWRITE_PNG_FAST_FILTERS",
           "IMWRITE_PNG_FILTER",
           "IMWRITE_PNG_FILTER_AVG",
           "IMWRITE_PNG_FILTER_NONE",
           "IMWRITE_PNG_FILTER_PAETH",
           "IMWRITE_PNG_FILTER_SUB",
           "IMWRITE_PNG_FILTER_UP",
           "IMWRITE_PNG_STRATEGY",
           "IMWRITE_PNG_STRATEGY_DEFAULT",
           "IMWRITE_PNG_STRATEGY_FILTERED",
           "IMWRITE_PNG_STRATEGY_FIXED",
           "IMWRITE_PNG_STRATEGY_HUFFMAN_ONLY",
           "IMWRITE_PNG_STRATEGY_RLE",
           "IMWRITE_PNG_ZLIBBUFFER_SIZE",
           "IMWRITE_PXM_BINARY",
           "IMWRITE_TIFF_COMPRESSION",
           "IMWRITE_TIFF_COMPRESSION_ADOBE_DEFLATE",
           "IMWRITE_TIFF_COMPRESSION_CCITTFAX3",
           "IMWRITE_TIFF_COMPRESSION_CCITTFAX4",
           "IMWRITE_TIFF_COMPRESSION_CCITTRLE",
           "IMWRITE_TIFF_COMPRESSION_CCITTRLEW",
           "IMWRITE_TIFF_COMPRESSION_CCITT_T4",
           "IMWRITE_TIFF_COMPRESSION_CCITT_T6",
           "IMWRITE_TIFF_COMPRESSION_DCS",
           "IMWRITE_TIFF_COMPRESSION_DEFLATE",
           "IMWRITE_TIFF_COMPRESSION_IT8BL",
           "IMWRITE_TIFF_COMPRESSION_IT8CTPAD",
           "IMWRITE_TIFF_COMPRESSION_IT8LW",
           "IMWRITE_TIFF_COMPRESSION_IT8MP",
           "IMWRITE_TIFF_COMPRESSION_JBIG",
           "IMWRITE_TIFF_COMPRESSION_JP2000",
           "IMWRITE_TIFF_COMPRESSION_JPEG",
           "IMWRITE_TIFF_COMPRESSION_JXL",
           "IMWRITE_TIFF_COMPRESSION_LERC",
           "IMWRITE_TIFF_COMPRESSION_LEVEL",
           "IMWRITE_TIFF_COMPRESSION_LZMA",
           "IMWRITE_TIFF_COMPRESSION_LZW",
           "IMWRITE_TIFF_COMPRESSION_NEXT",
           "IMWRITE_TIFF_COMPRESSION_NONE",
           "IMWRITE_TIFF_COMPRESSION_OJPEG",
           "IMWRITE_TIFF_COMPRESSION_PACKBITS",
           "IMWRITE_TIFF_COMPRESSION_PIXARFILM",
           "IMWRITE_TIFF_COMPRESSION_PIXARLOG",
           "IMWRITE_TIFF_COMPRESSION_SGILOG",
           "IMWRITE_TIFF_COMPRESSION_SGILOG24",
           "IMWRITE_TIFF_COMPRESSION_T43",
           "IMWRITE_TIFF_COMPRESSION_T85",
           "IMWRITE_TIFF_COMPRESSION_THUNDERSCAN",
           "IMWRITE_TIFF_COMPRESSION_WEBP",
           "IMWRITE_TIFF_COMPRESSION_ZSTD",
           "IMWRITE_TIFF_PREDICTOR",
           "IMWRITE_TIFF_PREDICTOR_FLOATINGPOINT",
           "IMWRITE_TIFF_PREDICTOR_HORIZONTAL",
           "IMWRITE_TIFF_PREDICTOR_NONE",
           "IMWRITE_TIFF_RESOLUTION_UNIT_CENTIMETER",
           "IMWRITE_TIFF_RESOLUTION_UNIT_INCH",
           "IMWRITE_TIFF_RESOLUTION_UNIT_NONE",
           "IMWRITE_TIFF_RESUNIT",
           "IMWRITE_TIFF_ROWSPERSTRIP",
           "IMWRITE_TIFF_XDPI",
           "IMWRITE_TIFF_YDPI",
           "IMWRITE_WEBP_LOSSLESS_MODE",
           "IMWRITE_WEBP_LOSSLESS_OFF",
           "IMWRITE_WEBP_LOSSLESS_ON",
           "IMWRITE_WEBP_LOSSLESS_PRESERVE_COLOR",
           "IMWRITE_WEBP_QUALITY"]

_NP_DEPTH = {0: np.uint8, 2: np.uint16, 4: np.int32, 5: np.float32}
_NOT_DECODABLE = -2  # SRStatus.unsupported

_decode = declare("sr_io_decode", [VP, ctypes.c_ssize_t, I32, ctypes.POINTER(VP)])
_decode_frame = declare("sr_io_decode_frame", [VP, ctypes.c_ssize_t, I32, I32, ctypes.POINTER(VP)])
_frame_info = declare("sr_io_frame_info", [VP, ctypes.c_ssize_t, ctypes.POINTER(I32)])
_frame_delay = declare("sr_io_frame_delay", [VP, ctypes.c_ssize_t, I32], restype=I32)
_encode_multi = declare("sr_io_encode_multi", [I32, ctypes.POINTER(VP), ctypes.POINTER(I32), ctypes.POINTER(I32), ctypes.POINTER(I32),
                                               ctypes.POINTER(I32), ctypes.POINTER(I32), ctypes.POINTER(I32), I32, CSTR,
                                               ctypes.POINTER(I32), I32, ctypes.POINTER(VP)])
_encode_gif = declare("sr_io_encode_gif", [I32, ctypes.POINTER(VP), ctypes.POINTER(I32), ctypes.POINTER(I32), ctypes.POINTER(I32),
                                           ctypes.POINTER(I32), ctypes.POINTER(I32), ctypes.POINTER(I32), I32,
                                           ctypes.POINTER(I32), I32, ctypes.POINTER(VP)])
_info = declare("sr_io_info", [VP, ctypes.POINTER(I32)])
_copy = declare("sr_io_copy", [VP, VP, I32])
_free = declare("sr_io_free", [VP], restype=None)
_encode = declare("sr_io_encode2", _lib.IMG_ARGS + [CSTR, ctypes.POINTER(I32), I32, ctypes.POINTER(VP)])

_IMREAD_COLOR_RGB = 256  # cv2 5.x: IMREAD_COLOR_RGB

# IMREAD_* / IMWRITE_* / IMAGE_METADATA_* (values identical to OpenCV 5.1.0)
IMAGE_METADATA_CICP = 3
IMAGE_METADATA_EXIF = 0
IMAGE_METADATA_ICCP = 2
IMAGE_METADATA_MAX = 3
IMAGE_METADATA_UNKNOWN = -1
IMAGE_METADATA_XMP = 1
IMREAD_ANYCOLOR = 4
IMREAD_ANYDEPTH = 2
IMREAD_COLOR = 1
IMREAD_COLOR_BGR = 1
IMREAD_COLOR_RGB = 256
IMREAD_GRAYSCALE = 0
IMREAD_IGNORE_ORIENTATION = 128
IMREAD_LOAD_GDAL = 8
IMREAD_REDUCED_COLOR_2 = 17
IMREAD_REDUCED_COLOR_4 = 33
IMREAD_REDUCED_COLOR_8 = 65
IMREAD_REDUCED_GRAYSCALE_2 = 16
IMREAD_REDUCED_GRAYSCALE_4 = 32
IMREAD_REDUCED_GRAYSCALE_8 = 64
IMREAD_UNCHANGED = -1
IMWRITE_AVIF_ALPHA_QUALITY = 515
IMWRITE_AVIF_DEPTH = 513
IMWRITE_AVIF_QUALITY = 512
IMWRITE_AVIF_SPEED = 514
IMWRITE_BMP_COMPRESSION = 768
IMWRITE_BMP_COMPRESSION_BITFIELDS = 3
IMWRITE_BMP_COMPRESSION_RGB = 0
IMWRITE_EXR_COMPRESSION = 49
IMWRITE_EXR_COMPRESSION_B44 = 6
IMWRITE_EXR_COMPRESSION_B44A = 7
IMWRITE_EXR_COMPRESSION_DWAA = 8
IMWRITE_EXR_COMPRESSION_DWAB = 9
IMWRITE_EXR_COMPRESSION_NO = 0
IMWRITE_EXR_COMPRESSION_PIZ = 4
IMWRITE_EXR_COMPRESSION_PXR24 = 5
IMWRITE_EXR_COMPRESSION_RLE = 1
IMWRITE_EXR_COMPRESSION_ZIP = 3
IMWRITE_EXR_COMPRESSION_ZIPS = 2
IMWRITE_EXR_DWA_COMPRESSION_LEVEL = 50
IMWRITE_EXR_TYPE = 48
IMWRITE_EXR_TYPE_FLOAT = 2
IMWRITE_EXR_TYPE_HALF = 1
IMWRITE_GIF_COLORTABLE = 1029
IMWRITE_GIF_COLORTABLE_SIZE_128 = 7
IMWRITE_GIF_COLORTABLE_SIZE_16 = 4
IMWRITE_GIF_COLORTABLE_SIZE_256 = 8
IMWRITE_GIF_COLORTABLE_SIZE_32 = 5
IMWRITE_GIF_COLORTABLE_SIZE_64 = 6
IMWRITE_GIF_COLORTABLE_SIZE_8 = 3
IMWRITE_GIF_DITHER = 1027
IMWRITE_GIF_FAST_FLOYD_DITHER = 2
IMWRITE_GIF_FAST_NO_DITHER = 1
IMWRITE_GIF_LOOP = 1024
IMWRITE_GIF_QUALITY = 1026
IMWRITE_GIF_SPEED = 1025
IMWRITE_GIF_TRANSPARENCY = 1028
IMWRITE_HDR_COMPRESSION = 80
IMWRITE_HDR_COMPRESSION_NONE = 0
IMWRITE_HDR_COMPRESSION_RLE = 1
IMWRITE_JPEG2000_COMPRESSION_X1000 = 272
IMWRITE_JPEGXL_DECODING_SPEED = 643
IMWRITE_JPEGXL_DISTANCE = 642
IMWRITE_JPEGXL_EFFORT = 641
IMWRITE_JPEGXL_QUALITY = 640
IMWRITE_JPEG_CHROMA_QUALITY = 6
IMWRITE_JPEG_LUMA_QUALITY = 5
IMWRITE_JPEG_OPTIMIZE = 3
IMWRITE_JPEG_PROGRESSIVE = 2
IMWRITE_JPEG_QUALITY = 1
IMWRITE_JPEG_RST_INTERVAL = 4
IMWRITE_JPEG_SAMPLING_FACTOR = 7
IMWRITE_JPEG_SAMPLING_FACTOR_411 = 4264209
IMWRITE_JPEG_SAMPLING_FACTOR_420 = 2232593
IMWRITE_JPEG_SAMPLING_FACTOR_422 = 2167057
IMWRITE_JPEG_SAMPLING_FACTOR_440 = 1184017
IMWRITE_JPEG_SAMPLING_FACTOR_444 = 1118481
IMWRITE_PAM_FORMAT_BLACKANDWHITE = 1
IMWRITE_PAM_FORMAT_GRAYSCALE = 2
IMWRITE_PAM_FORMAT_GRAYSCALE_ALPHA = 3
IMWRITE_PAM_FORMAT_NULL = 0
IMWRITE_PAM_FORMAT_RGB = 4
IMWRITE_PAM_FORMAT_RGB_ALPHA = 5
IMWRITE_PAM_TUPLETYPE = 128
IMWRITE_PNG_ALL_FILTERS = 248
IMWRITE_PNG_BILEVEL = 18
IMWRITE_PNG_COMPRESSION = 16
IMWRITE_PNG_FAST_FILTERS = 56
IMWRITE_PNG_FILTER = 19
IMWRITE_PNG_FILTER_AVG = 64
IMWRITE_PNG_FILTER_NONE = 8
IMWRITE_PNG_FILTER_PAETH = 128
IMWRITE_PNG_FILTER_SUB = 16
IMWRITE_PNG_FILTER_UP = 32
IMWRITE_PNG_STRATEGY = 17
IMWRITE_PNG_STRATEGY_DEFAULT = 0
IMWRITE_PNG_STRATEGY_FILTERED = 1
IMWRITE_PNG_STRATEGY_FIXED = 4
IMWRITE_PNG_STRATEGY_HUFFMAN_ONLY = 2
IMWRITE_PNG_STRATEGY_RLE = 3
IMWRITE_PNG_ZLIBBUFFER_SIZE = 20
IMWRITE_PXM_BINARY = 32
IMWRITE_TIFF_COMPRESSION = 259
IMWRITE_TIFF_COMPRESSION_ADOBE_DEFLATE = 8
IMWRITE_TIFF_COMPRESSION_CCITTFAX3 = 3
IMWRITE_TIFF_COMPRESSION_CCITTFAX4 = 4
IMWRITE_TIFF_COMPRESSION_CCITTRLE = 2
IMWRITE_TIFF_COMPRESSION_CCITTRLEW = 32771
IMWRITE_TIFF_COMPRESSION_CCITT_T4 = 3
IMWRITE_TIFF_COMPRESSION_CCITT_T6 = 4
IMWRITE_TIFF_COMPRESSION_DCS = 32947
IMWRITE_TIFF_COMPRESSION_DEFLATE = 32946
IMWRITE_TIFF_COMPRESSION_IT8BL = 32898
IMWRITE_TIFF_COMPRESSION_IT8CTPAD = 32895
IMWRITE_TIFF_COMPRESSION_IT8LW = 32896
IMWRITE_TIFF_COMPRESSION_IT8MP = 32897
IMWRITE_TIFF_COMPRESSION_JBIG = 34661
IMWRITE_TIFF_COMPRESSION_JP2000 = 34712
IMWRITE_TIFF_COMPRESSION_JPEG = 7
IMWRITE_TIFF_COMPRESSION_JXL = 50002
IMWRITE_TIFF_COMPRESSION_LERC = 34887
IMWRITE_TIFF_COMPRESSION_LEVEL = 260
IMWRITE_TIFF_COMPRESSION_LZMA = 34925
IMWRITE_TIFF_COMPRESSION_LZW = 5
IMWRITE_TIFF_COMPRESSION_NEXT = 32766
IMWRITE_TIFF_COMPRESSION_NONE = 1
IMWRITE_TIFF_COMPRESSION_OJPEG = 6
IMWRITE_TIFF_COMPRESSION_PACKBITS = 32773
IMWRITE_TIFF_COMPRESSION_PIXARFILM = 32908
IMWRITE_TIFF_COMPRESSION_PIXARLOG = 32909
IMWRITE_TIFF_COMPRESSION_SGILOG = 34676
IMWRITE_TIFF_COMPRESSION_SGILOG24 = 34677
IMWRITE_TIFF_COMPRESSION_T43 = 10
IMWRITE_TIFF_COMPRESSION_T85 = 9
IMWRITE_TIFF_COMPRESSION_THUNDERSCAN = 32809
IMWRITE_TIFF_COMPRESSION_WEBP = 50001
IMWRITE_TIFF_COMPRESSION_ZSTD = 50000
IMWRITE_TIFF_PREDICTOR = 317
IMWRITE_TIFF_PREDICTOR_FLOATINGPOINT = 3
IMWRITE_TIFF_PREDICTOR_HORIZONTAL = 2
IMWRITE_TIFF_PREDICTOR_NONE = 1
IMWRITE_TIFF_RESOLUTION_UNIT_CENTIMETER = 3
IMWRITE_TIFF_RESOLUTION_UNIT_INCH = 2
IMWRITE_TIFF_RESOLUTION_UNIT_NONE = 1
IMWRITE_TIFF_RESUNIT = 256
IMWRITE_TIFF_ROWSPERSTRIP = 278
IMWRITE_TIFF_XDPI = 257
IMWRITE_TIFF_YDPI = 258
IMWRITE_WEBP_LOSSLESS_MODE = 65
IMWRITE_WEBP_LOSSLESS_OFF = 0
IMWRITE_WEBP_LOSSLESS_ON = 1
IMWRITE_WEBP_LOSSLESS_PRESERVE_COLOR = 2
IMWRITE_WEBP_QUALITY = 64



def _as_bytes_array(buf) -> np.ndarray:
    a = np.asarray(buf)
    if a.dtype != np.uint8:
        a = a.astype(np.uint8)
    return np.ascontiguousarray(a.reshape(-1))


def _decode_blob(data: np.ndarray, flags, index=None):
    h = VP()
    if index is None:
        rc = _decode(data.ctypes.data, data.size, int(flags), ctypes.byref(h))
    else:
        rc = _decode_frame(data.ctypes.data, data.size, int(flags), int(index), ctypes.byref(h))
    if rc == _NOT_DECODABLE:
        return None
    _lib.check(rc, "imdecode")
    try:
        meta = (I32 * 4)()
        _lib.check(_info(h, meta), "imdecode")
        w, ht, ch, depth = meta
        shape = (ht, w) if ch == 1 else (ht, w, ch)
        out = np.empty(shape, dtype=_NP_DEPTH[depth])
        _lib.check(_copy(h, out.ctypes.data, w * ch * out.dtype.itemsize), "imdecode")
    finally:
        _free(h)
    if int(flags) >= 0 and (int(flags) & _IMREAD_COLOR_RGB) and out.ndim == 3 and out.shape[2] >= 3:
        out = np.ascontiguousarray(out[..., [2, 1, 0] + list(range(3, out.shape[2]))])
    return out


def imdecode(buf, flags=1):
    """Decode an image from a 1-D uint8 buffer. Returns None when it is not a decodable image."""
    data = _as_bytes_array(buf)
    if data.size == 0:
        raise _lib.error("OpenCV(safarium) imdecode_: !buf.empty() (empty input buffer)")
    return _decode_blob(data, flags)


def imread(filename, flags=1):
    """Read an image file (any str/PathLike, non-ASCII ok). None when missing or undecodable."""
    try:
        data = np.fromfile(os.fspath(filename), np.uint8)
    except (OSError, ValueError):
        return None
    if data.size == 0:
        return None
    return imdecode(data, flags)


def _param(params, key: int, default: int) -> int:
    value = default
    if params is not None:
        p = list(params)
        for i in range(0, len(p) - 1, 2):
            if int(p[i]) == key:
                value = int(p[i + 1])
    return value


def _param_array(params):
    """IMWRITE_* list -> ctypes int32 array (key, value, ...). cv2 ignores a trailing key without value."""
    if params is None:
        return None, 0
    p = [int(v) for v in params]
    p = p[: len(p) // 2 * 2]
    return ((I32 * len(p))(*p) if p else None), len(p)


def _rows_strided_ok(a: np.ndarray) -> bool:
    """True when the library can read ``a`` in place: packed pixels, positive row stride (rows may be padded or skipped)."""
    item = a.dtype.itemsize
    c = a.shape[2] if a.ndim == 3 else 1
    h, w = a.shape[:2]
    if w > 1 and a.strides[1] != c * item:
        return False
    if a.ndim == 3 and c > 1 and a.strides[2] != item:
        return False
    return h <= 1 or a.strides[0] >= w * c * item


def imencode(ext, img, params=None):
    """Encode ``img`` as ``ext`` (.jpg/.jpeg/.png/.tif/.tiff). Returns (True, 1-D uint8 array)."""
    a = np.asarray(img)
    if a.ndim == 3 and a.shape[2] == 2:
        raise _lib.error("imencode: unsupported 2-channel image")
    if a.dtype == np.float64:  # cv2 has no float64 writer; keep 32-bit float for tiff, 8-bit fallback otherwise
        a = a.astype(np.float32)
    elif a.dtype not in (np.uint8, np.uint16, np.int32, np.float32):
        a = np.clip(a, 0, 255).astype(np.uint8)
    if a.ndim == 3 and a.shape[2] == 1:
        a = a[..., 0]
    if a.ndim not in (2, 3) or a.size == 0:
        raise _lib.error("imencode: !image.empty() (empty or unsupported image)")
    if not _rows_strided_ok(a):
        a = np.ascontiguousarray(a)  # only when the pixels themselves are not packed
    h = VP()
    parr, pn = _param_array(params)
    rc = _encode(*_lib.img_args(a), os.fspath(ext).encode("utf-8"), parr, pn, ctypes.byref(h))
    if rc == _NOT_DECODABLE:
        raise _lib.error(f"imencode: could not find a writer for the specified extension '{ext}'")
    if rc != 0:
        return False, np.empty(0, np.uint8)
    try:
        meta = (I32 * 4)()
        _lib.check(_info(h, meta), "imencode")
        out = np.empty(meta[0], np.uint8)
        _lib.check(_copy(h, out.ctypes.data, 0), "imencode")
    finally:
        _free(h)
    return True, out


def imwrite(filename, img, params=None):
    """Write ``img`` to ``filename`` (format from the extension). Returns bool."""
    path = os.fspath(filename)
    ext = os.path.splitext(path)[1]
    ok, buf = imencode(ext, img, params)
    if not ok:
        return False
    try:
        buf.tofile(path)
    except OSError:
        return False
    return True


# ------------------------------------------------------------------------------------ multi-frame / animation

_INT_MAX = 2**31 - 1


def _read_file(filename):
    try:
        data = np.fromfile(os.fspath(filename), np.uint8)
    except (OSError, ValueError):
        return None
    return data if data.size else None


def _frames_of(data: np.ndarray):
    """(frame count, loop count, type code) or None when the buffer is not an image."""
    info = (I32 * 3)()
    if _frame_info(data.ctypes.data, data.size, info) != 0:
        return None
    return int(info[0]), int(info[1]), int(info[2])


def imcount(filename, flags=IMREAD_ANYCOLOR):
    """Number of pages / frames of an image file (0 when it cannot be read)."""
    data = _read_file(filename)
    if data is None:
        return 0
    info = _frames_of(data)
    return 0 if info is None else info[0]


def _decode_range(data, flags, start, count):
    info = _frames_of(data)
    if info is None:
        return False, ()
    mats = []
    last = min(info[0], start + count) if count < _INT_MAX else info[0]
    for i in range(max(0, start), last):
        m = _decode_blob(data, flags, i)
        if m is None:
            return False, tuple(mats)
        mats.append(m)
    return bool(mats), mats


def imdecodemulti(buf, flags, mats=None, range=None):
    """Decode every page/frame of a multi-image buffer. ``range`` = (start, end) selects a slice. Returns (bool, list)."""
    data = _as_bytes_array(buf)
    if data.size == 0:
        raise _lib.error("OpenCV(safarium) imdecodemulti_: !buf.empty() (empty input buffer)")
    start, count = 0, _INT_MAX
    if range is not None:
        start, count = int(range[0]), int(range[1]) - int(range[0])
    ok, out = _decode_range(data, flags, start, count)
    return ok, out


def imreadmulti(filename, *args, **kwargs):
    """imreadmulti(filename[, mats[, flags]]) or imreadmulti(filename, start, count[, mats[, flags]]) -> (bool, list)."""
    args = list(args)
    start, count = 0, _INT_MAX
    flags = kwargs.get("flags", IMREAD_ANYCOLOR)
    if len(args) >= 2 and isinstance(args[0], (int, np.integer)) and isinstance(args[1], (int, np.integer)):
        start, count = int(args[0]), int(args[1])
        args = args[2:]
    start = int(kwargs.get("start", start))
    count = int(kwargs.get("count", count))
    if len(args) >= 2:
        flags = args[1]
    elif len(args) == 1 and isinstance(args[0], (int, np.integer)) and not isinstance(args[0], bool):
        flags = args[0]
    data = _read_file(filename)
    if data is None:
        return False, ()
    return _decode_range(data, flags, start, count)


def _frame_arg(a):
    a = np.asarray(a)
    if a.dtype == np.float64:
        a = a.astype(np.float32)
    elif a.dtype not in (np.uint8, np.uint16, np.int32, np.float32):
        a = np.clip(a, 0, 255).astype(np.uint8)
    if a.ndim == 3 and a.shape[2] == 1:
        a = a[..., 0]
    if a.ndim not in (2, 3) or a.size == 0:
        raise _lib.error("imencodemulti: !image.empty() (empty or unsupported image)")
    return np.ascontiguousarray(a)


def _encode_frames(ext, frames, delays=None, loop=0, params=None):
    """-> (ok, bytes) for a multi-page TIFF or an animated GIF / APNG."""
    frames = [_frame_arg(f) for f in frames]
    n = len(frames)
    if n == 0:
        raise _lib.error("imencodemulti: !img_vec.empty() (no images)")
    datas = (VP * n)(*[f.ctypes.data for f in frames])
    ws = (I32 * n)(*[f.shape[1] for f in frames])
    hs = (I32 * n)(*[f.shape[0] for f in frames])
    strides = (I32 * n)(*[f.strides[0] for f in frames])
    chs = (I32 * n)(*[1 if f.ndim == 2 else f.shape[2] for f in frames])
    depths = (I32 * n)(*[{np.dtype(np.uint8): 0, np.dtype(np.uint16): 2, np.dtype(np.int32): 4, np.dtype(np.float32): 5}[f.dtype] for f in frames])
    dl = (I32 * n)(*[int(d) for d in delays]) if delays is not None else None
    parr, pn = _param_array(params)
    h = VP()
    rc = 1
    if os.fspath(ext).lower() == ".gif":   # own GIF writer for cv2's default settings; rc 1 = other settings, use ImageIO
        rc = _encode_gif(n, datas, ws, hs, strides, chs, depths, dl, int(loop), parr, pn, ctypes.byref(h))
    if rc == 1:
        rc = _encode_multi(n, datas, ws, hs, strides, chs, depths, dl, int(loop), os.fspath(ext).encode("utf-8"), parr, pn, ctypes.byref(h))
    if rc == _NOT_DECODABLE:
        raise _lib.error(f"imencodemulti: could not find a writer for the specified extension '{ext}'")
    if rc != 0:
        return False, np.empty(0, np.uint8)
    try:
        meta = (I32 * 4)()
        _lib.check(_info(h, meta), "imencodemulti")
        out = np.empty(meta[0], np.uint8)
        _lib.check(_copy(h, out.ctypes.data, 0), "imencodemulti")
    finally:
        _free(h)
    return True, out


def imencodemulti(ext, imgs, params=None):
    """Encode several images into one multi-page file (TIFF; GIF / APNG as an animation with 100 ms frames)."""
    return _encode_frames(ext, list(imgs), None, 0, params)


def imwritemulti(filename, img, params=None):
    path = os.fspath(filename)
    ok, buf = imencodemulti(os.path.splitext(path)[1], img, params)
    if not ok:
        return False
    try:
        buf.tofile(path)
    except OSError:
        return False
    return True


class Animation:
    """cv2.Animation: ``frames``, ``durations`` (ms), ``loop_count``, ``bgcolor``, ``still_image``."""

    def __init__(self, loopCount=0, bgColor=(0.0, 0.0, 0.0, 0.0)):
        self.loop_count = int(loopCount)
        self.bgcolor = tuple(float(v) for v in bgColor)
        self.durations = []
        self.frames = []
        self.still_image = None


def _decode_animation(data, start, count):
    info = _frames_of(data)
    if info is None:
        return False, Animation()
    anim = Animation(loopCount=info[1])
    last = min(info[0], start + count) if count < _INT_MAX else info[0]
    for i in range(max(0, start), last):
        m = _decode_blob(data, IMREAD_UNCHANGED, i)
        if m is None:
            return False, anim
        if m.ndim == 3 and m.shape[2] == 4 and m.dtype == np.uint8 and bool((m[..., 3] == 255).all()):
            m = np.ascontiguousarray(m[..., :3])   # fully opaque frames come back as BGR, like cv2
        anim.frames.append(m)
        anim.durations.append(max(0, int(_frame_delay(data.ctypes.data, data.size, i))))
    return bool(anim.frames), anim


def imdecodeanimation(buf, start=0, count=_INT_MAX):
    data = _as_bytes_array(buf)
    if data.size == 0:
        raise _lib.error("OpenCV(safarium) imdecodeanimation_: !buf.empty() (empty input buffer)")
    return _decode_animation(data, int(start), int(count))


def imreadanimation(filename, start=0, count=_INT_MAX):
    data = _read_file(filename)
    if data is None:
        return False, Animation()
    return _decode_animation(data, int(start), int(count))


def imencodeanimation(ext, animation, params=None):
    frames = list(animation.frames)
    durations = [int(d) for d in animation.durations]
    if len(frames) != len(durations):
        raise _lib.error("OpenCV(safarium) imencodeanimation: animation.frames.size() == animation.durations.size() "
                         "(-215:Assertion failed)")
    return _encode_frames(ext, frames, durations, animation.loop_count, params)


def imwriteanimation(filename, animation, params=None):
    path = os.fspath(filename)
    ok, buf = imencodeanimation(os.path.splitext(path)[1], animation, params)
    if not ok:
        return False
    try:
        buf.tofile(path)
    except OSError:
        return False
    return True


# --------------------------------------------------------------------------------------------------- metadata
# EXIF (TIFF blob), XMP packet and ICC profile bytes, parsed from / inserted into the container segments of JPEG
# and PNG (WebP is read only: there is no WebP writer yet). cv2 hands each item back as a (1, N) uint8 array.

_EXIF, _XMP, _ICCP = 0, 1, 2
_XMP_JPEG_ID = b"http://ns.adobe.com/xap/1.0/\x00"
_XMP_PNG_KEY = b"XML:com.adobe.xmp"


def _jpeg_segments(b: bytes):
    """Yield (marker, payload_start, payload_end) of the segments before the first scan."""
    i = 2
    n = len(b)
    while i + 4 <= n and b[i] == 0xFF:
        m = b[i + 1]
        if m == 0xFF:
            i += 1
            continue
        if m in (0xD8, 0x01) or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        ln = (b[i + 2] << 8) | b[i + 3]
        yield m, i + 4, i + 2 + ln
        if m == 0xDA:
            return
        i += 2 + ln


def _read_metadata(b: bytes):
    out = {}
    if b[:2] == b"\xff\xd8":
        icc = {}
        for m, a, e in _jpeg_segments(b):
            seg = b[a:e]
            if m == 0xE1 and seg[:6] == b"Exif\x00\x00" and _EXIF not in out:
                out[_EXIF] = seg[6:]
            elif m == 0xE1 and seg[: len(_XMP_JPEG_ID)] == _XMP_JPEG_ID and _XMP not in out:
                out[_XMP] = seg[len(_XMP_JPEG_ID):]
            elif m == 0xE2 and seg[:12] == b"ICC_PROFILE\x00" and len(seg) > 14:
                icc[seg[12]] = seg[14:]
        if icc:
            out[_ICCP] = b"".join(icc[k] for k in sorted(icc))
    elif b[:8] == b"\x89PNG\r\n\x1a\n":
        i = 8
        while i + 8 <= len(b):
            n = struct.unpack(">I", b[i:i + 4])[0]
            t = b[i + 4:i + 8]
            d = b[i + 8:i + 8 + n]
            if t == b"eXIf":
                out.setdefault(_EXIF, d)
            elif t == b"iTXt" and d.startswith(_XMP_PNG_KEY + b"\x00"):
                rest = d[len(_XMP_PNG_KEY) + 1:]
                comp, _meth = rest[0], rest[1]
                rest = rest[2:]
                rest = rest[rest.index(b"\x00") + 1:]      # language tag
                rest = rest[rest.index(b"\x00") + 1:]      # translated keyword
                out.setdefault(_XMP, zlib.decompress(rest) if comp else rest)
            elif t == b"iCCP":
                z = d[d.index(b"\x00") + 2:]
                try:
                    out.setdefault(_ICCP, zlib.decompress(z))
                except zlib.error:
                    pass
            elif t == b"IEND":
                break
            i += 12 + n
    elif b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        i = 12
        while i + 8 <= len(b):
            t = b[i:i + 4]
            n = struct.unpack("<I", b[i + 4:i + 8])[0]
            d = b[i + 8:i + 8 + n]
            if t == b"EXIF":
                out.setdefault(_EXIF, d[6:] if d[:6] == b"Exif\x00\x00" else d)
            elif t == b"XMP ":
                out.setdefault(_XMP, d)
            elif t == b"ICCP":
                out.setdefault(_ICCP, d)
            i += 8 + n + (n & 1)
    return out


def _metadata_result(b: bytes):
    meta = _read_metadata(b)
    types = np.array(sorted(meta), dtype=np.int32)
    return types, tuple(np.frombuffer(meta[t], np.uint8).reshape(1, -1).copy() for t in sorted(meta))


def _insert_metadata(encoded: bytes, types, metadata) -> bytes:
    items = {}
    for t, m in zip(types, metadata):
        items[int(t)] = bytes(np.asarray(m, np.uint8).tobytes())
    if not items:
        return encoded
    if encoded[:2] == b"\xff\xd8":
        segs = b""
        if _EXIF in items:
            body = b"Exif\x00\x00" + items[_EXIF]
            if len(body) + 2 > 0xFFFF:
                raise _lib.error("imencodeWithMetadata: EXIF data too large for a JPEG segment")
            segs += b"\xff\xe1" + struct.pack(">H", len(body) + 2) + body
        if _XMP in items:
            body = _XMP_JPEG_ID + items[_XMP]
            if len(body) + 2 > 0xFFFF:
                raise _lib.error("imencodeWithMetadata: XMP data too large for a JPEG segment")
            segs += b"\xff\xe1" + struct.pack(">H", len(body) + 2) + body
        if _ICCP in items:
            icc = items[_ICCP]
            chunk = 65519 - 14
            parts = [icc[k:k + chunk] for k in range(0, len(icc), chunk)] or [b""]
            for k, p in enumerate(parts):
                body = b"ICC_PROFILE\x00" + bytes([k + 1, len(parts)]) + p
                segs += b"\xff\xe2" + struct.pack(">H", len(body) + 2) + body
        # after SOI and the JFIF APP0 header
        pos = 2
        if encoded[2:4] == b"\xff\xe0":
            pos = 4 + struct.unpack(">H", encoded[4:6])[0]   # SOI + APP0 (marker + length-prefixed payload)
        return encoded[:pos] + segs + encoded[pos:]
    if encoded[:8] == b"\x89PNG\r\n\x1a\n":
        def chunk(t, d):
            return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
        extra = b""
        if _ICCP in items:
            extra += chunk(b"iCCP", b"ICC Profile\x00\x00" + zlib.compress(items[_ICCP]))
        if _EXIF in items:
            extra += chunk(b"eXIf", items[_EXIF])
        if _XMP in items:
            extra += chunk(b"iTXt", _XMP_PNG_KEY + b"\x00\x00\x00\x00\x00" + items[_XMP])
        pos = 8 + 12 + 13   # after IHDR
        return encoded[:pos] + extra + encoded[pos:]
    return encoded   # other containers carry no metadata here (same as cv2 for TIFF)


def imdecodeWithMetadata(buf, flags, metadata=None):
    data = _as_bytes_array(buf)
    img = imdecode(data, flags)
    if img is None:
        return None, np.empty(0, np.int32), ()
    types, meta = _metadata_result(data.tobytes())
    return img, types, meta


def imreadWithMetadata(filename, flags, metadata=None):
    data = _read_file(filename)
    if data is None:
        return None, np.empty(0, np.int32), ()
    return imdecodeWithMetadata(data, flags)


def imencodeWithMetadata(ext, img, metadataTypes, metadata, params=None):
    ok, buf = imencode(ext, img, params)
    if not ok:
        return False, buf
    return True, np.frombuffer(_insert_metadata(buf.tobytes(), list(metadataTypes), list(metadata)), np.uint8).copy()


def imwriteWithMetadata(filename, img, metadataTypes, metadata, params=None):
    path = os.fspath(filename)
    ok, buf = imencodeWithMetadata(os.path.splitext(path)[1], img, metadataTypes, metadata, params)
    if not ok:
        return False
    try:
        buf.tofile(path)
    except OSError:
        return False
    return True


# ----------------------------------------------------------------------------------------- reader / writer probes
_WRITE_EXT = {".jpg", ".jpeg", ".jpe", ".jfif", ".webp", ".png", ".apng", ".bmp", ".dib", ".pbm", ".pgm", ".ppm", ".pnm", ".pxm", ".pam",
              ".pfm", ".sr", ".ras", ".hdr", ".pic", ".tif", ".tiff", ".jp2", ".j2k", ".exr", ".avif", ".heic", ".heif", ".gif"}


def haveImageWriter(filename):
    """True when the extension of ``filename`` has an encoder in this build."""
    return os.path.splitext(os.fspath(filename))[1].lower() in _WRITE_EXT


def haveImageReader(filename):
    """True when ``filename`` exists and starts like an image one of the decoders handles (decided by content, like cv2)."""
    try:
        with open(os.fspath(filename), "rb") as fh:
            head = fh.read(4096)
    except OSError:
        return False
    if len(head) < 4:
        return False
    data = np.frombuffer(head, np.uint8)
    info = (I32 * 3)()
    if _frame_info(data.ctypes.data, data.size, info) == 0 and info[0] > 0:
        return True
    return head[:1] == b"P" and head[1:2] in b"1234567fF" or head[:4] == b"\x59\xa6\x6a\x95" or head[:2] == b"#?"


# ------------------------------------------------------------------------------------------ video

_vopen = declare("sr_video_open", [CSTR, ctypes.POINTER(VP)])
_vinfo = declare("sr_video_info", [VP, ctypes.POINTER(ctypes.c_double)])
_vread = declare("sr_video_read", [VP] + _lib.IMG_ARGS)
_vseek = declare("sr_video_seek", [VP, ctypes.c_int64])
_vclose = declare("sr_video_close", [VP], restype=None)

_CAP_POS_MSEC, _CAP_POS_FRAMES, _CAP_FRAME_WIDTH, _CAP_FRAME_HEIGHT = 0, 1, 3, 4
_CAP_FPS, _CAP_FRAME_COUNT = 5, 7
# sr_video_info slots
_V_WIDTH, _V_HEIGHT, _V_FPS, _V_COUNT, _V_POS_FRAMES, _V_POS_MSEC = range(6)


class VideoCapture:
    """cv2.VideoCapture subset: file paths only, BGR uint8 frames, via AVAssetReader (no FFmpeg)."""

    def __init__(self, filename=None, apiPreference=None, params=None):
        self._h = None
        self._grabbed = None
        if filename is not None:
            self.open(filename)

    def open(self, filename, apiPreference=None, params=None) -> bool:
        self.release()
        if not isinstance(filename, (str, bytes, os.PathLike)):
            return False  # camera indices are not supported
        path = os.fsdecode(os.fspath(filename))
        h = VP()
        if _vopen(path.encode("utf-8"), ctypes.byref(h)) != 0 or not h.value:
            return False
        self._h = h
        return True

    def isOpened(self) -> bool:
        return self._h is not None

    def _info(self):
        vals = (ctypes.c_double * 8)()
        _vinfo(self._h, vals)
        return vals

    def _frame(self):
        info = self._info()
        w, h = int(info[_V_WIDTH]), int(info[_V_HEIGHT])
        out = np.empty((h, w, 3), np.uint8)
        rc = _vread(self._h, *_lib.img_args(out))
        # 0 = frame; 1 = end of stream; 2 = an earlier seek failed; <0 = decode failure. cv2 reports all of them as
        # read() == (False, None), so none of them raises (the message stays available through _lib.last_error()).
        return out if rc == 0 else None

    def read(self, image=None):
        if self._h is None:
            return False, None
        self._grabbed = None
        frame = self._frame()
        return (False, None) if frame is None else (True, frame)

    def grab(self) -> bool:
        if self._h is None:
            return False
        self._grabbed = self._frame()
        return self._grabbed is not None

    def retrieve(self, image=None, flag=0):
        if self._grabbed is None:
            return False, None
        frame, self._grabbed = self._grabbed, None
        return True, frame

    def get(self, propId) -> float:
        if self._h is None:
            return 0.0
        info = self._info()
        p = int(propId)
        if p == _CAP_POS_MSEC:
            return float(info[_V_POS_MSEC])
        if p == _CAP_POS_FRAMES:
            return float(info[_V_POS_FRAMES])
        if p == _CAP_FRAME_WIDTH:
            return float(info[_V_WIDTH])
        if p == _CAP_FRAME_HEIGHT:
            return float(info[_V_HEIGHT])
        if p == _CAP_FPS:
            return float(info[_V_FPS])
        if p == _CAP_FRAME_COUNT:
            return float(info[_V_COUNT])
        return 0.0

    def set(self, propId, value) -> bool:
        if self._h is None:
            return False
        p = int(propId)
        info = self._info()
        fps = float(info[_V_FPS])
        if p == _CAP_POS_FRAMES:
            frame = int(round(float(value)))
        elif p == _CAP_POS_MSEC:
            frame = int(round(float(value) * fps / 1000.0))
        else:
            return False
        self._grabbed = None
        return _vseek(self._h, max(0, frame)) == 0

    def release(self) -> None:
        if self._h is not None:
            _vclose(self._h)
            self._h = None
        self._grabbed = None

    def __del__(self):
        try:
            self.release()
        except Exception:  # noqa: BLE001 - interpreter shutdown
            pass
