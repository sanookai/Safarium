"""IIR filtering on libSafariumRaster (state explicit, float64 arithmetic). API/behaviour per scipy.signal."""
from __future__ import annotations

import numpy as np

from .. import _sr


def _validate_x(x):
    x = np.asarray(x)
    if x.ndim == 0:
        raise ValueError("x must be at least 1-D")
    return x


def _float_dtype(*arrays):
    dt = np.result_type(*arrays)
    if dt.char not in "fd":
        raise NotImplementedError(f"input type '{dt}' not supported")
    return dt


def _validate_sos(sos):
    sos = np.asarray(sos)
    sos = np.atleast_2d(sos)
    if sos.ndim != 2:
        raise ValueError("sos array must be 2D")
    n_sections, m = sos.shape
    if m != 6:
        raise ValueError("sos array must be shape (n_sections, 6)")
    if not (sos[:, 3] == 1).all():
        raise ValueError("sos[:, 3] should be all ones")
    return sos, n_sections


def _run_sos(buf, sos, zflat=None, reverse=False):
    """Filter the rows of the C-contiguous-by-row float64 2-D `buf` in place; zflat (rows, sections, 2) in/out."""
    sos64 = np.ascontiguousarray(sos, dtype=np.float64)
    zp = None if zflat is None else zflat.ctypes.data
    rc = _sr.lib().sr_sci_sosfilt(buf.ctypes.data, buf.shape[0], buf.shape[1], buf.strides[0] // 8, sos64.ctypes.data,
                                  sos64.shape[0], zp, 1 if reverse else 0)
    _sr.check(rc, "sosfilt")


def sosfilt(sos, x, axis=-1, zi=None):
    """Filter along `axis` with a cascade of biquads (direct form II transposed). zi: (n_sections, ..., 2, ...)."""
    x = _validate_x(x)
    sos, n_sections = _validate_sos(sos)
    x_zi_shape = list(x.shape)
    x_zi_shape[axis] = 2
    x_zi_shape = tuple([n_sections] + x_zi_shape)
    inputs = [sos, x] + ([np.asarray(zi)] if zi is not None else [])
    dtype = _float_dtype(*inputs)
    if zi is not None:
        zi = np.array(zi, dtype=np.float64)  # copy
        if zi.shape != x_zi_shape:
            raise ValueError(f"Invalid zi shape. With axis={axis!r}, an input with shape {x.shape!r}, and an sos array "
                             f"with {n_sections} sections, zi must have shape {x_zi_shape!r}, got {zi.shape!r}.")
        return_zi = True
    else:
        zi = np.zeros(x_zi_shape, dtype=np.float64)
        return_zi = False
    axis = axis % x.ndim
    xm = np.moveaxis(x, axis, -1)
    zm = np.moveaxis(zi, (0, axis + 1), (-2, -1))
    x_shape, z_shape = xm.shape, zm.shape
    nl = int(np.prod(x_shape[:-1], dtype=np.int64))
    flat = np.array(xm.reshape(nl, x_shape[-1]), dtype=np.float64, order="C")  # private working copy
    zflat = np.ascontiguousarray(zm.reshape(nl, n_sections, 2))
    if flat.size:
        _run_sos(flat, sos, zflat)
    y = np.moveaxis(flat.reshape(x_shape), -1, axis)
    if dtype != np.float64:
        y = y.astype(dtype)
    if return_zi:
        zout = np.moveaxis(zflat.reshape(z_shape), (-2, -1), (0, axis + 1))
        return y, zout.astype(dtype, copy=False) if dtype != np.float64 else zout
    return y


def lfilter_zi(b, a):
    """Initial state for a step response of steady-state (scipy.signal.lfilter_zi)."""
    b = np.atleast_1d(np.asarray(b, dtype=np.result_type(np.asarray(b), np.float64)))
    a = np.atleast_1d(np.asarray(a, dtype=np.result_type(np.asarray(a), np.float64)))
    if not (b.ndim == a.ndim == 1):
        raise ValueError("Numerator `b` and Denominator `a` must be 1-D arrays")
    if a[0] == 0:
        raise ValueError("First coefficient of parameter `a` must be non-zero!")
    if a[0] != 1:
        b, a = b / a[0], a / a[0]
    if (sum_a := a.sum()) == 0:
        raise ValueError("Filter not stable due to sum(a) == 0, i.e., having a pole at z = 1!")
    y_inf = b.sum() / sum_a
    n = max(len(a), len(b))
    b = np.pad(b, (0, n - len(b)))
    a = np.pad(a, (0, n - len(a)))
    return np.cumsum((b - y_inf * a)[::-1])[::-1][1:]


def sosfilt_zi(sos):
    sos = np.asarray(sos)
    if sos.ndim != 2 or sos.shape[1] != 6:
        raise ValueError("sos must be shape (n_sections, 6)")
    if sos.dtype.kind in "biu":
        sos = sos.astype(np.float64)
    zi = np.empty((sos.shape[0], 2), dtype=sos.dtype)
    scale = 1.0
    for s in range(sos.shape[0]):
        b, a = sos[s, :3], sos[s, 3:]
        zi[s] = scale * lfilter_zi(b, a)
        scale *= b.sum() / a.sum()
    return zi


def _ext(x, n, axis, kind):
    if n < 1:
        return x
    if n > x.shape[axis] - 1:
        raise ValueError(f"The extension length n ({n}) is too big. It must not exceed x.shape[axis]-1, which is "
                         f"{x.shape[axis] - 1}.")
    sl = [slice(None)] * x.ndim

    def s(a, b, c=None):
        sl2 = list(sl)
        sl2[axis] = slice(a, b, c)
        return x[tuple(sl2)]

    if kind == "odd":
        left = 2 * s(0, 1) - s(n, 0, -1)
        right = 2 * s(-1, None) - s(-2, -(n + 2), -1)
    elif kind == "even":
        left, right = s(n, 0, -1), s(-2, -(n + 2), -1)
    else:  # constant
        left = np.repeat(s(0, 1), n, axis=axis)
        right = np.repeat(s(-1, None), n, axis=axis)
    return np.concatenate((left, x, right), axis=axis)


def _validate_pad(padtype, padlen, x, axis, ntaps):
    if padtype not in ("even", "odd", "constant", None):
        raise ValueError(f"Unknown value '{padtype}' given to padtype.  padtype must be 'even', 'odd', "
                         "'constant', or None.")
    if padtype is None:
        padlen = 0
    if padlen is None:
        edge = ntaps * 3
    else:
        edge = padlen
    if x.shape[axis] <= edge:
        raise ValueError(f"The length of the input vector x must be greater than padlen, which is {edge}.")
    ext = _ext(x, edge, axis, padtype) if padtype is not None and edge > 0 else x
    return edge, ext


def sosfiltfilt(sos, x, axis=-1, padtype="odd", padlen=None):
    """Zero-phase forward-backward SOS filtering with scipy's padding and steady-state initial conditions.

    Runs on ONE float64 working buffer (padded signal in, result out): the backward pass walks the buffer from its end
    inside the kernel, so no reversed copies are made (scipy makes several full-length copies).
    """
    sos, n_sections = _validate_sos(sos)
    x = _validate_x(x)
    ntaps = 2 * n_sections + 1
    ntaps -= min((sos[:, 2] == 0).sum(), (sos[:, 5] == 0).sum())
    if padtype not in ("even", "odd", "constant", None):
        raise ValueError(f"Unknown value '{padtype}' given to padtype.  padtype must be 'even', 'odd', "
                         "'constant', or None.")
    axis = axis % x.ndim
    edge = 0 if padtype is None else (ntaps * 3 if padlen is None else padlen)
    if x.shape[axis] <= edge:
        raise ValueError(f"The length of the input vector x must be greater than padlen, which is {edge}.")
    dtype = _float_dtype(sos, x)
    xm = np.moveaxis(x, axis, -1)
    lead, n = xm.shape[:-1], xm.shape[-1]
    nl = int(np.prod(lead, dtype=np.int64)) if lead else 1
    src = xm.reshape(nl, n)
    buf = np.empty((nl, n + 2 * edge), dtype=np.float64)
    buf[:, edge:edge + n] = src
    if edge > 0:
        first = src[:, :1].astype(np.float64)
        last = src[:, -1:].astype(np.float64)
        if padtype == "odd":
            buf[:, :edge] = 2 * first - src[:, edge:0:-1]
            buf[:, edge + n:] = 2 * last - src[:, -2:-(edge + 2):-1]
        elif padtype == "even":
            buf[:, :edge] = src[:, edge:0:-1]
            buf[:, edge + n:] = src[:, -2:-(edge + 2):-1]
        else:
            buf[:, :edge] = first
            buf[:, edge + n:] = last
    zi0 = sosfilt_zi(sos).astype(np.float64)               # (sections, 2) unit-step steady state
    z = np.ascontiguousarray(np.broadcast_to(zi0, (nl, n_sections, 2)) * buf[:, :1, None])
    _run_sos(buf, sos, z)                                  # forward
    z = np.ascontiguousarray(np.broadcast_to(zi0, (nl, n_sections, 2)) * buf[:, -1:, None])
    _run_sos(buf, sos, z, reverse=True)                    # backward, in place
    y = np.moveaxis(buf[:, edge:edge + n].reshape(lead + (n,)), -1, axis)
    return y.astype(dtype, copy=False)


def lfilter(b, a, x, axis=-1, zi=None):
    """Filter `x` along `axis` with the IIR/FIR filter (b, a), direct form II transposed; (y) or (y, zf) with zi."""
    b = np.atleast_1d(b)
    a = np.atleast_1d(a)
    x = np.asarray(x)
    if not (b.ndim == 1 and b.size > 0):
        raise ValueError(f"Parameter b is not a non-empty 1d array, since b.shape={b.shape}!")
    if not (a.ndim == 1 and a.size > 0):
        raise ValueError(f"Parameter a is not a non-empty 1d array, since a.shape={a.shape}!")
    x = _validate_x(x)
    if a[0] == 0:
        raise ValueError("BUG: filter coefficient a[0] == 0 not supported yet")
    order = max(len(a), len(b)) - 1
    inputs = [b, a, x] + ([np.asarray(zi)] if zi is not None else [])
    dtype = _float_dtype(*inputs)
    axis = axis % x.ndim
    b64 = np.zeros(order + 1)
    a64 = np.zeros(order + 1)
    b64[:len(b)] = np.asarray(b, np.float64) / float(a[0])
    a64[:len(a)] = np.asarray(a, np.float64) / float(a[0])
    xm = np.moveaxis(x, axis, -1)
    xshape = xm.shape
    nl = int(np.prod(xshape[:-1], dtype=np.int64))
    flat = np.array(xm.reshape(nl, xshape[-1]), dtype=np.float64, order="C")
    zptr = None
    zflat = None
    if zi is not None:
        zi = np.asarray(zi)
        expected = list(x.shape)
        expected[axis] = order
        try:
            zi = np.broadcast_to(zi, tuple(expected))
        except ValueError:
            raise ValueError(f"Unexpected shape for parameter zi: expected {tuple(expected)}, found {zi.shape}.")
        zflat = np.array(np.moveaxis(zi, axis, -1).reshape(nl, order), dtype=np.float64, order="C")  # private copy: the kernel writes the final state here
        zptr = zflat.ctypes.data
    if flat.size:
        rc = _sr.lib().sr_sci_lfilter(flat.ctypes.data, nl, flat.shape[1], b64.ctypes.data, a64.ctypes.data, order, zptr)
        _sr.check(rc, "lfilter")
    y = np.moveaxis(flat.reshape(xshape), -1, axis)
    if dtype != np.float64:
        y = y.astype(dtype)
    if zi is None:
        return y
    zf = np.moveaxis(zflat.reshape(xshape[:-1] + (order,)), -1, axis)
    return y, (zf.astype(dtype) if dtype != np.float64 else zf)
