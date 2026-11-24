"""Butterworth design (ported from scipy.signal._filter_design, BSD-3-Clause): zpk -> sos with SciPy's pairing."""
from __future__ import annotations

import numpy as np

_BANDS = {"band": "bandpass", "bandpass": "bandpass", "pass": "bandpass", "bp": "bandpass",
          "bs": "bandstop", "bandstop": "bandstop", "bands": "bandstop", "stop": "bandstop",
          "l": "lowpass", "low": "lowpass", "lowpass": "lowpass", "lp": "lowpass",
          "high": "highpass", "highpass": "highpass", "h": "highpass", "hp": "highpass"}


def buttap(N):
    if abs(int(N)) != N:
        raise ValueError("Filter order must be a nonnegative integer")
    z = np.array([], dtype=np.float64)
    m = np.arange(-N + 1, N, 2, dtype=np.float64)
    p = -np.exp(1j * np.pi * m / (2 * N))
    return z, p, 1.0


def _relative_degree(z, p):
    degree = len(p) - len(z)
    if degree < 0:
        raise ValueError("Improper transfer function. Must have at least as many poles as zeros.")
    return degree


def _lp2lp(z, p, k, wo):
    deg = _relative_degree(z, p)
    return wo * z, wo * p, k * wo ** deg


def _lp2hp(z, p, k, wo):
    deg = _relative_degree(z, p)
    z_hp = np.concatenate((wo / z, np.zeros(deg)))
    return z_hp, wo / p, k * np.real(np.prod(-z) / np.prod(-p))


def _lp2bp(z, p, k, wo, bw):
    deg = _relative_degree(z, p)
    z_lp = (z * bw / 2).astype(np.complex128)
    p_lp = (p * bw / 2).astype(np.complex128)
    z_bp = np.concatenate((z_lp + np.sqrt(z_lp ** 2 - wo ** 2), z_lp - np.sqrt(z_lp ** 2 - wo ** 2)))
    p_bp = np.concatenate((p_lp + np.sqrt(p_lp ** 2 - wo ** 2), p_lp - np.sqrt(p_lp ** 2 - wo ** 2)))
    z_bp = np.concatenate((z_bp, np.zeros(deg)))
    return z_bp, p_bp, k * bw ** deg


def _lp2bs(z, p, k, wo, bw):
    deg = _relative_degree(z, p)
    z_hp = ((bw / 2) / z).astype(np.complex128)
    p_hp = ((bw / 2) / p).astype(np.complex128)
    z_bs = np.concatenate((z_hp + np.sqrt(z_hp ** 2 - wo ** 2), z_hp - np.sqrt(z_hp ** 2 - wo ** 2)))
    p_bs = np.concatenate((p_hp + np.sqrt(p_hp ** 2 - wo ** 2), p_hp - np.sqrt(p_hp ** 2 - wo ** 2)))
    z_bs = np.concatenate((z_bs, np.full(deg, +1j * wo)))
    z_bs = np.concatenate((z_bs, np.full(deg, -1j * wo)))
    return z_bs, p_bs, k * np.real(np.prod(-z) / np.prod(-p))


def bilinear_zpk(z, p, k, fs):
    z, p = np.atleast_1d(z), np.atleast_1d(p)
    deg = _relative_degree(z, p)
    fs2 = 2.0 * fs
    z_z = (fs2 + z) / (fs2 - z)
    p_z = (fs2 + p) / (fs2 - p)
    z_z = np.concatenate((z_z, -np.ones(deg)))
    return z_z, p_z, k * np.real(np.prod(fs2 - z) / np.prod(fs2 - p))


def _poly(roots):
    """Real polynomial coefficients of prod(x - r); complex roots must come in conjugate pairs."""
    roots = np.atleast_1d(roots)
    c = np.poly(roots) if len(roots) else np.array([1.0])
    if np.iscomplexobj(c):
        c = c.real  # conjugate pairs: imaginary part is rounding noise
    return c


def zpk2tf(z, p, k):
    return k * _poly(z), _poly(p)


# ---- zpk -> sos (scipy.signal._filter_design.zpk2sos, pairing 'nearest') ----
def _cplxreal(z, tol=None):
    z = np.atleast_1d(z)
    if z.size == 0:
        return z, z
    if tol is None:
        tol = 100 * np.finfo((1.0 * z).dtype).eps
    z = z[np.lexsort((abs(z.imag), z.real))]
    real_indices = abs(z.imag) <= tol * abs(z)
    zr = z[real_indices].real
    if len(zr) == len(z):
        return np.array([]), zr
    z = z[~real_indices]
    zp = z[z.imag > 0]
    zn = z[z.imag < 0]
    if len(zp) != len(zn):
        raise ValueError("Array contains complex value with no matching conjugate.")
    same_real = np.diff(zp.real) <= tol * abs(zp[:-1])
    diffs = np.diff(np.concatenate(([0], same_real, [0])))
    run_starts = np.nonzero(diffs > 0)[0]
    run_stops = np.nonzero(diffs < 0)[0]
    for i in range(len(run_starts)):
        start, stop = run_starts[i], run_stops[i] + 1
        for chunk in (zp[start:stop], zn[start:stop]):
            chunk[...] = chunk[np.lexsort([abs(chunk.imag)])]
    if np.any(zp.real != zn.real) or np.any(abs(zp.imag) != abs(zn.imag)):
        raise ValueError("Array contains complex value with no matching conjugate.")
    return zp, zr


def _nearest_real_complex_idx(fro, to, which):
    order = np.argsort(np.abs(fro - to))
    if which == "any":
        return order[0]
    mask = np.isreal(fro[order])
    if which == "complex":
        mask = ~mask
    return order[np.nonzero(mask)[0][0]]


def _single_zpksos(z, p, k):
    sos = np.zeros(6)
    b, a = zpk2tf(z, p, k)
    sos[3 - len(b):3] = b
    sos[6 - len(a):6] = a
    return sos


def zpk2sos(z, p, k, pairing=None, *, analog=False):
    z, p, k = np.asarray(z), np.asarray(p), np.asarray(k)
    if pairing is None:
        pairing = "minimal" if analog else "nearest"
    if pairing not in ("nearest", "keep_odd", "minimal"):
        raise ValueError(f"pairing must be one of ['nearest', 'keep_odd', 'minimal'], not {pairing}")
    if analog and pairing != "minimal":
        raise ValueError('for analog zpk2sos conversion, pairing must be "minimal"')
    if len(z) == len(p) == 0:
        return np.asarray([[k, 0., 0., 1., 0., 0.]]) if not analog else np.asarray([[0., 0., k, 0., 0., 1.]])
    if pairing != "minimal":
        p = np.concatenate((p, np.zeros(max(len(z) - len(p), 0))))
        z = np.concatenate((z, np.zeros(max(len(p) - len(z), 0))))
        n_sections = (max(len(p), len(z)) + 1) // 2
        if len(p) % 2 == 1 and pairing == "nearest":
            p = np.concatenate((p, [0.]))
            z = np.concatenate((z, [0.]))
    else:
        if len(p) < len(z):
            raise ValueError("for analog zpk2sos conversion, must have len(p)>=len(z)")
        n_sections = (len(p) + 1) // 2
    z = np.concatenate(_cplxreal(z))
    p = np.concatenate(_cplxreal(p))
    if not np.isreal(k):
        raise ValueError("k must be real")
    k = k.real

    def idx_worst(pp):
        return np.argmin(np.abs(1 - np.abs(pp))) if not analog else np.argmin(np.abs(np.real(pp)))

    sos = np.zeros((n_sections, 6))
    for si in range(n_sections - 1, -1, -1):
        p1_idx = idx_worst(p)
        p1 = p[p1_idx]
        p = np.delete(p, p1_idx)
        if np.isreal(p1) and np.isreal(p).sum() == 0:
            if pairing != "minimal":
                z1_idx = _nearest_real_complex_idx(z, p1, "real")
                z1 = z[z1_idx]
                z = np.delete(z, z1_idx)
                sos[si] = _single_zpksos([z1, 0], [p1, 0], 1)
            elif len(z) > 0:
                z1_idx = _nearest_real_complex_idx(z, p1, "real")
                z1 = z[z1_idx]
                z = np.delete(z, z1_idx)
                sos[si] = _single_zpksos([z1], [p1], 1)
            else:
                sos[si] = _single_zpksos([], [p1], 1)
        elif (len(p) + 1 == len(z) and not np.isreal(p1) and np.isreal(p).sum() == 1 and np.isreal(z).sum() == 1):
            z1_idx = _nearest_real_complex_idx(z, p1, "complex")
            z1 = z[z1_idx]
            z = np.delete(z, z1_idx)
            sos[si] = _single_zpksos([z1, z1.conj()], [p1, p1.conj()], 1)
        else:
            if np.isreal(p1):
                prealidx = np.flatnonzero(np.isreal(p))
                p2_idx = prealidx[idx_worst(p[prealidx])]
                p2 = p[p2_idx]
                p = np.delete(p, p2_idx)
            else:
                p2 = p1.conj()
            if len(z) > 0:
                z1_idx = _nearest_real_complex_idx(z, p1, "any")
                z1 = z[z1_idx]
                z = np.delete(z, z1_idx)
                if not np.isreal(z1):
                    sos[si] = _single_zpksos([z1, z1.conj()], [p1, p2], 1)
                elif len(z) > 0:
                    z2_idx = _nearest_real_complex_idx(z, p1, "real")
                    z2 = z[z2_idx]
                    z = np.delete(z, z2_idx)
                    sos[si] = _single_zpksos([z1, z2], [p1, p2], 1)
                else:
                    sos[si] = _single_zpksos([z1], [p1, p2], 1)
            else:
                sos[si] = _single_zpksos([], [p1, p2], 1)
    sos[0][:3] *= k
    return sos


def butter(N, Wn, btype="low", analog=False, output="ba", fs=None):
    """Butterworth filter design, scipy.signal.butter signature (output 'ba' | 'zpk' | 'sos')."""
    btype, output = str(btype).lower(), str(output).lower()
    Wn = np.asarray(Wn, dtype=np.float64)
    if fs is not None:
        if analog:
            raise ValueError("fs cannot be specified for an analog filter")
        Wn = Wn / (fs / 2)
    if np.any(Wn <= 0):
        raise ValueError("filter critical frequencies must be greater than 0")
    if Wn.size > 1 and not Wn[0] < Wn[1]:
        raise ValueError("Wn[0] must be less than Wn[1]")
    try:
        band = _BANDS[btype]
    except KeyError as e:
        raise ValueError(f"'{btype}' is an invalid bandtype for filter.") from e
    if output not in ("ba", "zpk", "sos"):
        raise ValueError(f"'{output}' is not a valid output form.")
    z, p, k = buttap(N)
    if not analog:
        if np.any(Wn <= 0) or np.any(Wn >= 1):
            if fs is not None:
                raise ValueError(f"Digital filter critical frequencies must be 0 < Wn < fs/2 (fs={fs} -> fs/2={fs / 2})")
            raise ValueError("Digital filter critical frequencies must be 0 < Wn < 1")
        fs_ = 2.0
        warped = 2 * fs_ * np.tan(np.pi * Wn / fs_)
    else:
        warped = Wn
    if band in ("lowpass", "highpass"):
        if Wn.size != 1:
            raise ValueError("Must specify a single critical frequency Wn for lowpass or highpass filter")
        z, p, k = (_lp2lp if band == "lowpass" else _lp2hp)(z, p, k, float(warped))
    else:
        if Wn.size != 2:
            raise ValueError("Wn must specify start and stop frequencies for bandpass or bandstop filter")
        bw = float(warped[1] - warped[0])
        wo = float(np.sqrt(warped[0] * warped[1]))
        z, p, k = (_lp2bp if band == "bandpass" else _lp2bs)(z, p, k, wo, bw)
    if not analog:
        z, p, k = bilinear_zpk(z, p, k, fs=fs_)
    if output == "zpk":
        return z, p, k
    if output == "ba":
        return zpk2tf(z, p, k)
    return zpk2sos(z, p, k, analog=analog)
