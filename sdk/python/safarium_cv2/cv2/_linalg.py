"""Phase 2: Linear algebra and spectral transforms backed by Accelerate (BLAS/LAPACK/vDSP)."""
from __future__ import annotations

import builtins
import ctypes

import numpy as np

from . import _lib
from ._core import (
    _arr,
    _canon,
    _mat,
    _Mat,
    _out,
    getOptimalDFTSize,
    trace,
)
from ._lib import F64, I32, declare

_P_MAT = ctypes.POINTER(_Mat)
_P_I32 = ctypes.POINTER(I32)
_P_F64 = ctypes.POINTER(F64)

_c_gemm = declare("sr_la_gemm", [_P_MAT, _P_MAT, F64, _P_MAT, F64, _P_MAT, I32], I32)
_c_solve = declare("sr_la_solve", [_P_MAT, _P_MAT, _P_MAT, I32, _P_I32], I32)
_c_invert = declare("sr_la_invert", [_P_MAT, _P_MAT, I32, _P_F64], I32)
_c_svd = declare("sr_la_svd", [_P_MAT, _P_MAT, _P_MAT, _P_MAT, I32], I32)
_c_sv_backsubst = declare("sr_la_sv_backsubst", [_P_MAT, _P_MAT, _P_MAT, _P_MAT, _P_MAT], I32)
_c_eigen = declare("sr_la_eigen", [_P_MAT, _P_MAT, _P_MAT], I32)
_c_eigen_ns = declare("sr_la_eigen_nonsym", [_P_MAT, _P_MAT, _P_MAT], I32)
_c_det = declare("sr_la_det", [_P_MAT, _P_F64], I32)
_c_covar = declare("sr_la_covar", [_P_MAT, _P_MAT, _P_MAT, I32], I32)
_c_maha = declare("sr_la_mahalanobis", [_P_MAT, _P_MAT, _P_MAT, _P_F64], I32)
_c_pca = declare("sr_la_pca", [_P_MAT, _P_MAT, _P_MAT, _P_MAT, I32, F64, I32, _P_I32], I32)
_c_pca_proj = declare("sr_la_pca_project", [_P_MAT, _P_MAT, _P_MAT, _P_MAT, I32], I32)
_c_kmeans = declare("sr_la_kmeans", [_P_MAT, I32, _P_MAT, _P_MAT, I32, F64, I32, I32, _P_F64], I32)
_c_solve_poly = declare("sr_la_solve_poly", [_P_F64, I32, _P_F64, _P_I32, _P_F64], I32)
_c_dft = declare("sr_la_dft", [_P_MAT, _P_MAT, I32], I32)
_c_dct = declare("sr_la_dct", [_P_MAT, _P_MAT, I32], I32)
_c_mul_spec = declare("sr_la_mul_spectrums", [_P_MAT, _P_MAT, _P_MAT, I32, I32], I32)

__all__ = [
    "gemm", "solve", "invert", "SVDecomp", "SVBackSubst",
    "eigen", "eigenNonSymmetric", "determinant", "trace",
    "PCACompute", "PCACompute2", "PCAProject", "PCABackProject",
    "dft", "idft", "dct", "idct", "mulSpectrums", "getOptimalDFTSize",
    "kmeans", "Mahalanobis", "calcCovarMatrix", "solvePoly",
]


def _fmat(a, name: str) -> np.ndarray:
    arr = _canon(_arr(a))
    if arr.size > 0 and (arr.dtype not in (np.float32, np.float64)):
        raise _lib.error(f"{name}: requires CV_32F or CV_64F")
    return np.ascontiguousarray(arr) if not arr.flags["C_CONTIGUOUS"] else arr


def gemm(src1, src2, alpha, src3, beta, dst=None, flags=0):
    a = _canon(_arr(src1))
    b = _canon(_arr(src2))
    if a.size == 0 or b.size == 0:
        return np.empty((0, 0), dtype=a.dtype) if dst is None else dst
    a = _fmat(a, "gemm")
    b = _fmat(b, "gemm")
    if a.dtype != b.dtype:
        raise _lib.error("gemm: src1 and src2 dtype mismatch")
    t1 = (int(flags) & 1) != 0
    t2 = (int(flags) & 2) != 0
    m = a.shape[1] if t1 else a.shape[0]
    n = b.shape[0] if t2 else b.shape[1]
    c = _fmat(src3, "gemm") if (src3 is not None and np.asarray(src3).size > 0) else None
    ch = a.shape[2] if a.ndim == 3 else 1
    out_shape = (m, n) if ch == 1 else (m, n, ch)
    d, fin = _out(dst, out_shape, a.dtype)
    mc = ctypes.byref(_mat(c)) if c is not None else None
    _lib.check(_c_gemm(ctypes.byref(_mat(a)), ctypes.byref(_mat(b)), float(alpha), mc, float(beta), ctypes.byref(_mat(d)), int(flags)), "gemm")
    return fin()


def solve(src1, src2, dst=None, flags=0):
    a = _canon(_arr(src1))
    b = _canon(_arr(src2))
    if a.size == 0:
        d, fin = _out(dst, (0, 0), a.dtype)
        return True, fin()
    a = _fmat(a, "solve")
    b = _fmat(b, "solve")
    b2 = b.reshape(-1, 1) if b.ndim == 1 else b
    if a.dtype != b2.dtype or a.ndim != 2 or b2.ndim != 2:
        raise _lib.error("solve: requires 2-D float/double matrices of matching type")
    n = a.shape[1]
    nrhs = b2.shape[1]
    out_shape = (n,) if np.asarray(src2).ndim == 1 else (n, nrhs)
    d, fin = _out(dst, out_shape, a.dtype)
    d_view = d.reshape(n, nrhs)
    ok = I32(0)
    _lib.check(_c_solve(ctypes.byref(_mat(a)), ctypes.byref(_mat(b2)), ctypes.byref(_mat(d_view)), int(flags), ctypes.byref(ok)), "solve")
    return bool(ok.value), fin()


def invert(src, dst=None, flags=0):
    a = _fmat(src, "invert")
    if a.size == 0 or a.ndim != 2:
        raise _lib.error("invert: (-215:Assertion failed) !src.empty() && src.dims == 2")
    m, n = a.shape[:2]
    d, fin = _out(dst, (n, m), a.dtype)
    ret = F64(0.0)
    _lib.check(_c_invert(ctypes.byref(_mat(a)), ctypes.byref(_mat(d)), int(flags), ctypes.byref(ret)), "invert")
    return float(ret.value), fin()


def SVDecomp(src, w=None, u=None, vt=None, flags=0):
    a = _fmat(src, "SVDecomp")
    if a.ndim != 2 or a.size == 0:
        raise _lib.error("SVDecomp: requires non-empty 2-D float/double matrix")
    m, n = a.shape
    mn = builtins.min(m, n)
    no_uv = (int(flags) & 2) != 0
    full_uv = (int(flags) & 4) != 0
    w_out, w_fin = _out(w, (mn, 1), a.dtype)
    if no_uv:
        _lib.check(_c_svd(ctypes.byref(_mat(a)), ctypes.byref(_mat(w_out)), None, None, int(flags)), "SVDecomp")
        return w_fin(), None, None
    u_cols = m if full_uv else mn
    vt_rows = n if full_uv else mn
    u_out, u_fin = _out(u, (m, u_cols), a.dtype)
    vt_out, vt_fin = _out(vt, (vt_rows, n), a.dtype)
    _lib.check(_c_svd(ctypes.byref(_mat(a)), ctypes.byref(_mat(w_out)), ctypes.byref(_mat(u_out)), ctypes.byref(_mat(vt_out)), int(flags)), "SVDecomp")
    return w_fin(), u_fin(), vt_fin()


def SVBackSubst(w, u, vt, rhs, dst=None):
    wa = _fmat(w, "SVBackSubst")
    ua = _fmat(u, "SVBackSubst")
    vta = _fmat(vt, "SVBackSubst")
    ra = _fmat(rhs, "SVBackSubst")
    ra2 = ra.reshape(-1, 1) if ra.ndim == 1 else ra
    n = vta.shape[1]
    nrhs = ra2.shape[1]
    out_shape = (n,) if np.asarray(rhs).ndim == 1 else (n, nrhs)
    d, fin = _out(dst, out_shape, ua.dtype)
    d2 = d.reshape(n, nrhs)
    _lib.check(_c_sv_backsubst(ctypes.byref(_mat(wa)), ctypes.byref(_mat(ua)), ctypes.byref(_mat(vta)), ctypes.byref(_mat(ra2)), ctypes.byref(_mat(d2))), "SVBackSubst")
    return fin()


def eigen(src, eigenvalues=None, eigenvectors=None):
    a = _fmat(src, "eigen")
    if a.ndim != 2 or a.size == 0 or a.shape[0] != a.shape[1]:
        raise _lib.error("eigen: requires non-empty square CV_32FC1 or CV_64FC1 matrix")
    n = a.shape[0]
    vals, vals_fin = _out(eigenvalues, (n, 1), a.dtype)
    vecs, vecs_fin = _out(eigenvectors, (n, n), a.dtype)
    _lib.check(_c_eigen(ctypes.byref(_mat(a)), ctypes.byref(_mat(vals)), ctypes.byref(_mat(vecs))), "eigen")
    return True, vals_fin(), vecs_fin()


def eigenNonSymmetric(src, eigenvalues=None, eigenvectors=None):
    a = _fmat(src, "eigenNonSymmetric")
    if a.ndim != 2 or a.size == 0 or a.shape[0] != a.shape[1]:
        raise _lib.error("eigenNonSymmetric: requires non-empty square CV_32FC1 or CV_64FC1 matrix")
    n = a.shape[0]
    vals, vals_fin = _out(eigenvalues, (n, 1), a.dtype)
    vecs, vecs_fin = _out(eigenvectors, (n, n), a.dtype)
    _lib.check(_c_eigen_ns(ctypes.byref(_mat(a)), ctypes.byref(_mat(vals)), ctypes.byref(_mat(vecs))), "eigenNonSymmetric")
    return vals_fin(), vecs_fin()


def determinant(mtx):
    a = _canon(_arr(mtx))
    if a.ndim != 2 or a.size == 0 or a.shape[0] != a.shape[1] or a.dtype.kind != "f" or a.dtype.itemsize < 4:
        raise _lib.error("determinant: (-215:Assertion failed) !mat.empty() && mat.rows == mat.cols && (type == CV_32F || type == CV_64F)")
    n = a.shape[0]
    m = a.astype(np.float64)
    if n == 1:
        return float(m[0, 0])
    if n == 2:
        return float(m[0, 0] * m[1, 1] - m[0, 1] * m[1, 0])
    if n == 3:
        return float(m[0, 0] * (m[1, 1] * m[2, 2] - m[1, 2] * m[2, 1]) - m[0, 1] * (m[1, 0] * m[2, 2] - m[1, 2] * m[2, 0])
                     + m[0, 2] * (m[1, 0] * m[2, 1] - m[1, 1] * m[2, 0]))
    a_c = np.ascontiguousarray(a) if not a.flags["C_CONTIGUOUS"] else a
    out = F64(0.0)
    _lib.check(_c_det(ctypes.byref(_mat(a_c)), ctypes.byref(out)), "determinant")
    return float(out.value)


def calcCovarMatrix(samples, mean, flags, covar=None, ctype=6):
    s = _canon(_arr(samples))
    if s.ndim != 2 or s.size == 0:
        raise _lib.error("calcCovarMatrix: requires non-empty 2-D matrix")
    dt = np.float32 if int(ctype) == 5 else np.float64
    r, c = s.shape[:2]
    rows_as_samples = (int(flags) & 8) != 0 or (int(flags) & 16) == 0
    scrambled = (int(flags) & 1) == 0
    nsamples = r if rows_as_samples else c
    dim = c if rows_as_samples else r
    cov_dim = nsamples if scrambled else dim
    m_shape = (1, dim) if rows_as_samples else (dim, 1)
    use_avg = (int(flags) & 2) != 0
    if use_avg and mean is not None:
        mean_arr = np.ascontiguousarray(np.asarray(mean, dtype=dt).reshape(m_shape))
        mean_fin = lambda: mean_arr
    else:
        mean_arr, mean_fin = _out(mean, m_shape, dt)
    cov_arr, cov_fin = _out(covar, (cov_dim, cov_dim), dt)
    _lib.check(_c_covar(ctypes.byref(_mat(s)), ctypes.byref(_mat(mean_arr)), ctypes.byref(_mat(cov_arr)), int(flags)), "calcCovarMatrix")
    return cov_fin(), mean_fin()


def Mahalanobis(v1, v2, icovar):
    a1 = _fmat(v1, "Mahalanobis").reshape(-1, 1)
    a2 = _fmat(v2, "Mahalanobis").reshape(-1, 1)
    ic = _fmat(icovar, "Mahalanobis")
    out = F64(0.0)
    _lib.check(_c_maha(ctypes.byref(_mat(a1)), ctypes.byref(_mat(a2)), ctypes.byref(_mat(ic)), ctypes.byref(out)), "Mahalanobis")
    return float(out.value)


def _pca_core(data, mean, arg3=None, arg4=None, maxComponents=0, retainedVariance=None, want_evals=False, arg5=None):
    x = _fmat(data, "PCACompute")
    if x.ndim != 2 or x.size == 0:
        raise _lib.error("PCACompute: requires non-empty 2-D float/double matrix")
    n, d = x.shape
    retained = float(retainedVariance) if retainedVariance is not None else -1.0
    max_comp = int(maxComponents) if maxComponents else 0
    evecs_dst = None
    evals_dst = None
    if want_evals:
        if retainedVariance is None and isinstance(arg3, (float, np.floating)) and not isinstance(arg3, (int, np.integer)):
            retained = float(arg3)
            evecs_dst = arg4
            evals_dst = arg5
        else:
            evecs_dst = arg3
            evals_dst = arg4
    else:
        if retainedVariance is None and isinstance(arg3, (float, np.floating)) and not isinstance(arg3, (int, np.integer)):
            retained = float(arg3)
            evecs_dst = arg4
        else:
            evecs_dst = arg3
            if arg4 is not None:
                max_comp = int(arg4)

    use_mean = 0
    if mean is not None and np.asarray(mean).size > 0:
        m_arr = _fmat(mean, "PCACompute").reshape(1, d)
        m_fin = lambda: m_arr
        use_mean = 1
    else:
        m_arr, m_fin = _out(mean if (mean is not None and np.asarray(mean).size == d) else None, (1, d), x.dtype)

    max_possible = builtins.min(n, d)
    vec_tmp = np.empty((max_possible, d), dtype=x.dtype)
    val_tmp = np.empty((max_possible, 1), dtype=x.dtype) if want_evals else None
    keep = I32(0)
    val_ptr = ctypes.byref(_mat(val_tmp)) if val_tmp is not None else None
    _lib.check(_c_pca(ctypes.byref(_mat(x)), ctypes.byref(_mat(m_arr)), ctypes.byref(_mat(vec_tmp)), val_ptr,
                      max_comp, retained, use_mean, ctypes.byref(keep)), "PCACompute")
    k = int(keep.value)
    evecs = vec_tmp[:k].copy()
    if evecs_dst is not None and hasattr(evecs_dst, "shape") and evecs_dst.shape == evecs.shape and evecs_dst.dtype == evecs.dtype:
        evecs_dst[...] = evecs
        evecs = evecs_dst
    if not want_evals:
        return m_fin(), evecs
    evals = val_tmp[:k].copy()
    if evals_dst is not None and hasattr(evals_dst, "shape") and evals_dst.shape == evals.shape and evals_dst.dtype == evals.dtype:
        evals_dst[...] = evals
        evals = evals_dst
    return m_fin(), evecs, evals


def PCACompute(data, mean, *args, maxComponents=0, retainedVariance=None):
    arg3 = args[0] if len(args) > 0 else None
    arg4 = args[1] if len(args) > 1 else None
    return _pca_core(data, mean, arg3, arg4, maxComponents=maxComponents, retainedVariance=retainedVariance, want_evals=False)


def PCACompute2(data, mean, *args, maxComponents=0, retainedVariance=None):
    arg3 = args[0] if len(args) > 0 else None
    arg4 = args[1] if len(args) > 1 else None
    arg5 = args[2] if len(args) > 2 else None
    return _pca_core(data, mean, arg3, arg4, maxComponents=maxComponents, retainedVariance=retainedVariance, want_evals=True, arg5=arg5)


def PCAProject(data, mean, eigenvectors, result=None):
    x = _fmat(data, "PCAProject")
    mu = _fmat(mean, "PCAProject").reshape(1, -1)
    ev = _fmat(eigenvectors, "PCAProject")
    out, fin = _out(result, (x.shape[0], ev.shape[0]), x.dtype)
    _lib.check(_c_pca_proj(ctypes.byref(_mat(x)), ctypes.byref(_mat(mu)), ctypes.byref(_mat(ev)), ctypes.byref(_mat(out)), 0), "PCAProject")
    return fin()


def PCABackProject(data, mean, eigenvectors, result=None):
    x = _fmat(data, "PCABackProject")
    mu = _fmat(mean, "PCABackProject").reshape(1, -1)
    ev = _fmat(eigenvectors, "PCABackProject")
    out, fin = _out(result, (x.shape[0], ev.shape[1]), x.dtype)
    _lib.check(_c_pca_proj(ctypes.byref(_mat(x)), ctypes.byref(_mat(mu)), ctypes.byref(_mat(ev)), ctypes.byref(_mat(out)), 1), "PCABackProject")
    return fin()


def dft(src, dst=None, flags=0, nonzeroRows=0):
    raw = np.asarray(src)
    if raw.size == 0:
        return None
    was_1d = raw.ndim == 1
    a = _fmat(raw.reshape(1, -1) if was_1d else raw, "dft")
    fl = int(flags)
    cplx_out = (fl & 16) != 0
    real_out = (fl & 32) != 0
    in_cplx = a.ndim == 3 and a.shape[2] == 2
    out_cplx = (cplx_out and not real_out) or (in_cplx and not real_out)
    m, n = a.shape[:2]
    out_shape = (m, n, 2) if out_cplx else (m, n)
    if was_1d and dst is None:
        out = np.empty(out_shape, dtype=a.dtype)
        _lib.check(_c_dft(ctypes.byref(_mat(a)), ctypes.byref(_mat(out)), fl), "dft")
        return out[0] if not out_cplx else out.reshape(n, 2)
    d, fin = _out(dst, out_shape, a.dtype)
    _lib.check(_c_dft(ctypes.byref(_mat(a)), ctypes.byref(_mat(d)), fl), "dft")
    return fin()


def idft(src, dst=None, flags=0, nonzeroRows=0):
    return dft(src, dst=dst, flags=int(flags) | 1, nonzeroRows=nonzeroRows)


def mulSpectrums(a, b, flags, c=None, conjB=False):
    ma = _fmat(a, "mulSpectrums")
    mb = _fmat(b, "mulSpectrums")
    out, fin = _out(c, ma.shape, ma.dtype)
    _lib.check(_c_mul_spec(ctypes.byref(_mat(ma)), ctypes.byref(_mat(mb)), ctypes.byref(_mat(out)), int(flags), 1 if conjB else 0), "mulSpectrums")
    return fin()


def dct(src, dst=None, flags=0):
    raw = np.asarray(src)
    if raw.size == 0:
        return None
    a = _fmat(raw.reshape(1, -1) if raw.ndim == 1 else raw, "dct")
    if a.ndim != 2:
        raise _lib.error("dct: requires 2-D float/double single-channel matrix")
    d, fin = _out(dst, a.shape, a.dtype)
    _lib.check(_c_dct(ctypes.byref(_mat(a)), ctypes.byref(_mat(d)), int(flags)), "dct")
    return fin()


def idct(src, dst=None, flags=0):
    return dct(src, dst=dst, flags=int(flags) | 1)


def kmeans(data, K, bestLabels, criteria, attempts, flags, centers=None):
    raw = np.asarray(data, dtype=np.float32)
    if raw.ndim == 3 and (raw.shape[0] == 1 or raw.shape[1] == 1):
        pts = np.ascontiguousarray(raw.reshape(-1, raw.shape[2]))
    elif raw.ndim == 2:
        pts = np.ascontiguousarray(raw)
    else:
        raise _lib.error("kmeans: data must be 2-D or 1xN/Nx1 multi-channel float32")
    n, dims = pts.shape
    k = int(K)
    if bestLabels is not None and np.asarray(bestLabels).size == n:
        lbl = np.ascontiguousarray(np.asarray(bestLabels, dtype=np.int32).reshape(n, 1))
    else:
        lbl = np.zeros((n, 1), dtype=np.int32)
    ctr, ctr_fin = _out(centers, (k, dims), np.float32)
    ctype, max_iter, eps = criteria
    eff_iter = int(max_iter) if (int(ctype) & 1) else 100
    eff_eps = float(eps) if (int(ctype) & 2) else 0.0
    compact = F64(0.0)
    _lib.check(_c_kmeans(ctypes.byref(_mat(pts)), k, ctypes.byref(_mat(lbl)), ctypes.byref(_mat(ctr)),
                         eff_iter, eff_eps, int(attempts), int(flags), ctypes.byref(compact)), "kmeans")
    return float(compact.value), lbl, ctr_fin()


def solvePoly(coeffs, roots=None, maxIters=300):
    c = np.ascontiguousarray(np.asarray(coeffs, dtype=np.float64).reshape(-1))
    if c.size < 2:
        raise _lib.error("solvePoly: requires >= 2 coefficients")
    deg_max = int(c.size) - 1
    out_buf = np.empty((deg_max, 1, 2), dtype=np.float64)
    out_deg = I32(0)
    resid = F64(0.0)
    _lib.check(_c_solve_poly(c.ctypes.data_as(_P_F64), int(c.size), out_buf.ctypes.data_as(_P_F64),
                             ctypes.byref(out_deg), ctypes.byref(resid)), "solvePoly")
    d = int(out_deg.value)
    res_arr = out_buf[:d].copy()
    if roots is not None and hasattr(roots, "shape") and roots.shape == res_arr.shape and roots.dtype == np.float64:
        roots[...] = res_arr
        res_arr = roots
    return float(resid.value), res_arr
