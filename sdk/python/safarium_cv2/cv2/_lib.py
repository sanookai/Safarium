"""Loader + buffer helpers for libSafariumRaster (shared by every area module).

Owned by the orchestrator. Area modules (_draw.py, _ops.py, _io.py, _numpy_ops.py) import from here.
Contract: Projects/Safarium/docs/raster-plan.md
"""
from __future__ import annotations

import ctypes
import os
from pathlib import Path

import numpy as np

ABI_VERSION = 1

_SEARCH = [
    os.environ.get("SAFARIUM_RASTER_LIB", ""),
    str(Path.home() / ".local/libexec/safarium/libSafariumRaster.dylib"),
]


class error(Exception):
    """Stand-in for cv2.error (constructible with a message)."""

    def __init__(self, *args):
        super().__init__(*args)
        self.msg = args[0] if args else ""
        self.err = self.msg


def _load() -> ctypes.CDLL:
    tried = []
    for cand in _SEARCH:
        if cand and Path(cand).is_file():
            lib = ctypes.CDLL(cand)
            lib.sr_abi_version.restype = ctypes.c_int32
            got = lib.sr_abi_version()
            if got != ABI_VERSION:
                raise ImportError(f"libSafariumRaster ABI {got} at {cand}, expected {ABI_VERSION}")
            return lib
        tried.append(cand or "$SAFARIUM_RASTER_LIB (unset)")
    raise ImportError("libSafariumRaster.dylib not found; tried: " + ", ".join(tried))


lib = _load()
lib.sr_last_error.restype = ctypes.c_int32
lib.sr_last_error.argtypes = [ctypes.c_char_p, ctypes.c_int32]

# ctypes argtype shorthands
VP = ctypes.c_void_p
I32 = ctypes.c_int32
F64 = ctypes.c_double
PI32 = ctypes.POINTER(ctypes.c_int32)
PF64 = ctypes.POINTER(ctypes.c_double)
PU8 = ctypes.POINTER(ctypes.c_uint8)
CSTR = ctypes.c_char_p
IMG_ARGS = [VP, I32, I32, I32, I32, I32]  # data, width, height, strideBytes, channels, depth

_DEPTH = {np.dtype(np.uint8): 0, np.dtype(np.uint16): 2, np.dtype(np.int32): 4, np.dtype(np.float32): 5}


def declare(name: str, argtypes: list, restype=I32):
    fn = getattr(lib, name)
    fn.argtypes = argtypes
    fn.restype = restype
    return fn


def last_error() -> str:
    buf = ctypes.create_string_buffer(1024)
    lib.sr_last_error(buf, 1024)
    return buf.value.decode("utf-8", "replace")


def check(rc: int, what: str) -> None:
    if rc != 0:
        raise error(f"{what}: {last_error()} (rc={rc})")


def img_args(a: np.ndarray) -> list:
    """Six ABI scalars for a 2-D (H,W) or 3-D (H,W,C) numpy array whose rows may be strided.

    The pixel dimension must be contiguous (a.strides[1] == C*itemsize). Raises cv2-style error otherwise.
    """
    if a.dtype not in _DEPTH:
        raise error(f"unsupported dtype {a.dtype}")
    if a.ndim == 2:
        h, w = a.shape
        c = 1
    elif a.ndim == 3:
        h, w, c = a.shape
    else:
        raise error(f"unsupported ndim {a.ndim}")
    item = a.dtype.itemsize
    if w > 1 and a.strides[1] != c * item:
        raise error("pixel layout not contiguous")
    if a.ndim == 3 and c > 1 and a.strides[2] != item:
        raise error("channel layout not contiguous")
    stride = a.strides[0] if h > 1 else w * c * item
    if stride < 0:
        raise error("negative strides unsupported")
    return [a.ctypes.data, w, h, stride, c, _DEPTH[a.dtype]]


def color4(color) -> ctypes.Array:
    """cv2 Scalar -> double[4] (scalars broadcast to channel 0, as cv2 does)."""
    if isinstance(color, (int, float, np.integer, np.floating)):
        vals = [float(color), 0.0, 0.0, 0.0]
    else:
        vals = [float(v) for v in list(color)[:4]]
        vals += [0.0] * (4 - len(vals))
    return (ctypes.c_double * 4)(*vals)
