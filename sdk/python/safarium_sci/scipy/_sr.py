"""Loader for libSafariumRaster (Area E: Sci* kernels). Same search order as safarium_cv2/cv2/_lib.py.

Env SAFARIUM_RASTER_LIB, else ~/.local/libexec/safarium/libSafariumRaster.dylib. Loaded lazily, on the first call
that needs a kernel, so `import scipy` stays cheap and file-only paths (wavfile, netcdf) never need the dylib.
"""
from __future__ import annotations

import ctypes
import os
from pathlib import Path

ABI_VERSION = 1
_lib = None


def lib() -> ctypes.CDLL:
    global _lib
    if _lib is not None:
        return _lib
    cands = [os.environ.get("SAFARIUM_RASTER_LIB", ""),
             str(Path.home() / ".local/libexec/safarium/libSafariumRaster.dylib")]
    for c in cands:
        if c and Path(c).is_file():
            lb = ctypes.CDLL(c)
            lb.sr_abi_version.restype = ctypes.c_int32
            if lb.sr_abi_version() != ABI_VERSION:
                raise ImportError(f"libSafariumRaster ABI mismatch at {c}")
            lb.sr_last_error.restype = ctypes.c_int32
            lb.sr_last_error.argtypes = [ctypes.c_char_p, ctypes.c_int32]
            V, I64, I32, D = ctypes.c_void_p, ctypes.c_int64, ctypes.c_int32, ctypes.c_double
            lb.sr_sci_sosfilt.argtypes = [V, I64, I64, I64, V, I32, V, I32]
            lb.sr_sci_sosfilt.restype = I32
            lb.sr_sci_lfilter.argtypes = [V, I64, I64, V, V, I32, V]
            lb.sr_sci_lfilter.restype = I32
            for nm in ("sr_sci_minfilt1d_f64", "sr_sci_minfilt1d_f32"):
                fn = getattr(lb, nm)
                fn.argtypes = [V, V, I64, I64, I64, I64, I64, I32, D]
                fn.restype = I32
            _lib = lb
            return lb
    raise ImportError("libSafariumRaster.dylib not found; tried: "
                      + ", ".join(c or "$SAFARIUM_RASTER_LIB (unset)" for c in cands))


def check(rc: int, what: str) -> None:
    if rc != 0:
        buf = ctypes.create_string_buffer(1024)
        lib().sr_last_error(buf, 1024)
        raise ValueError(f"{what}: {buf.value.decode('utf-8', 'replace')} (rc={rc})")
