"""scipy.ndimage stand-in: minimum_filter1d (Swift monotone-deque kernel, O(n) for any window size)."""
from __future__ import annotations

import operator

import numpy as np

from .. import _sr

__all__ = ["minimum_filter1d"]

_MODES = {"nearest": "nearest", "constant": "constant", "reflect": "reflect", "mirror": "mirror", "wrap": "wrap",
          "grid-constant": "constant", "grid-mirror": "reflect", "grid-wrap": "wrap"}
_NP_PAD = {"reflect": "symmetric", "mirror": "reflect", "wrap": "wrap"}


def minimum_filter1d(input, size, axis=-1, output=None, mode="reflect", cval=0.0, origin=0):
    """Same signature/semantics as scipy.ndimage.minimum_filter1d: out[i] = min(in[i-size//2-origin ... +size-1])."""
    inp = np.asarray(input)
    if np.iscomplexobj(inp):
        raise TypeError("Complex type not supported")
    if inp.ndim == 0:
        raise RuntimeError("input must have at least one dimension")
    size = operator.index(size)  # TypeError for floats, like scipy
    if size < 1:
        raise RuntimeError("incorrect filter size")
    if size >= 2 ** 62:
        raise OverflowError("filter size too large")
    if mode not in _MODES:
        raise RuntimeError("boundary mode not supported")
    mode = _MODES[mode]
    if not -(size // 2) <= origin <= (size - 1) // 2:
        raise ValueError("invalid origin")
    axis = axis % inp.ndim
    in_dtype = inp.dtype
    work = np.float32 if in_dtype == np.float32 else np.float64
    x = np.moveaxis(inp, axis, -1)
    lead, n = x.shape[:-1], x.shape[-1]
    nl = int(np.prod(lead, dtype=np.int64))
    flat = np.ascontiguousarray(x.reshape(nl, n), dtype=work)
    shift = -(size // 2) - origin  # first window index relative to the output index
    lib = _sr.lib()
    fn = lib.sr_sci_minfilt1d_f32 if work is np.float32 else lib.sr_sci_minfilt1d_f64
    out = np.empty((nl, n), dtype=work)
    if n == 0 or nl == 0:  # nothing to filter: empty result of the input's shape (kernel not called)
        rc = 0
    elif mode in ("reflect", "mirror", "wrap") and size >= 2 * n and not np.isnan(flat).any():
        # the window always spans a whole period of the periodic border, so every output is the line minimum
        out[:] = flat.min(axis=1, keepdims=True)
        rc = 0
    elif mode in ("nearest", "constant"):
        rc = fn(flat.ctypes.data, out.ctypes.data, nl, n, n, size, shift, 0 if mode == "nearest" else 1, float(cval))
    else:  # other borders: pad with numpy so the window never leaves the line ("constant" is then never read)
        left, right = max(-shift, 0), max(shift + size - 1, 0)
        padded = np.ascontiguousarray(np.pad(flat, ((0, 0), (left, right)), mode=_NP_PAD[mode]))
        rc = fn(padded.ctypes.data, out.ctypes.data, nl, padded.shape[1], n, size, shift + left, 1, 0.0)
    _sr.check(rc, "minimum_filter1d")
    res = np.moveaxis(out.reshape(lead + (n,)), -1, axis)
    if output is None:
        return res.astype(in_dtype, copy=False)
    if isinstance(output, np.ndarray):
        output[...] = res
        return None
    return res.astype(output, copy=False)
