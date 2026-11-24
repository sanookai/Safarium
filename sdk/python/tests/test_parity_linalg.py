"""Parity and accuracy tests for SafariumRaster Phase 2: linalg + transforms.

Covers: gemm, solve, invert, SVDecomp, SVBackSubst, eigen, eigenNonSymmetric,
determinant, trace, PCACompute, PCACompute2, PCAProject, PCABackProject,
dft, idft, dct, idct, mulSpectrums, getOptimalDFTSize, kmeans,
Mahalanobis, calcCovarMatrix, solvePoly.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import load_pair  # noqa: E402

REF, SR = load_pair()
REF.setNumThreads(1)
SR.setNumThreads(1)

RNG = np.random.default_rng(20261124)


def _tol(dtype):
    return (1e-4, 1e-4) if np.dtype(dtype) == np.float32 else (1e-10, 1e-10)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("flags", [0, 1, 2, 3, 7])
def test_gemm(dt, flags):
    # Test all transpose flag combinations (GEMM_1_T=1, GEMM_2_T=2, GEMM_3_T=4)
    a = RNG.normal(size=(5, 4) if (flags & 1) else (4, 5)).astype(dt)
    b = RNG.normal(size=(6, 5) if (flags & 2) else (5, 6)).astype(dt)
    c = RNG.normal(size=(6, 4) if (flags & 4) else (4, 6)).astype(dt)
    alpha, beta = 1.7, -0.45
    r_ref = REF.gemm(a, b, alpha, c, beta, flags=flags)
    r_sr = SR.gemm(a, b, alpha, c, beta, flags=flags)
    rtol, atol = _tol(dt)
    assert r_sr.dtype == r_ref.dtype == a.dtype
    assert r_sr.shape == r_ref.shape
    np.testing.assert_allclose(r_sr, r_ref, rtol=rtol, atol=atol)

    # Verify against float64 ground truth
    a64 = a.astype(np.float64).T if (flags & 1) else a.astype(np.float64)
    b64 = b.astype(np.float64).T if (flags & 2) else b.astype(np.float64)
    c64 = c.astype(np.float64).T if (flags & 4) else c.astype(np.float64)
    gt = alpha * (a64 @ b64) + beta * c64
    np.testing.assert_allclose(r_sr.astype(np.float64), gt, rtol=1e-4 if dt == np.float32 else 1e-12, atol=1e-5 if dt == np.float32 else 1e-12)

    # src3=None and preallocated dst
    r_ref_nc = REF.gemm(a, b, alpha, None, 0.0, flags=flags)
    dst = np.empty_like(r_ref_nc)
    r_sr_nc = SR.gemm(a, b, alpha, None, 0.0, dst=dst, flags=flags)
    assert r_sr_nc is dst
    np.testing.assert_allclose(r_sr_nc, r_ref_nc, rtol=rtol, atol=atol)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
def test_gemm_complex_and_empty(dt):
    a = RNG.normal(size=(4, 5, 2)).astype(dt)
    b = RNG.normal(size=(5, 3, 2)).astype(dt)
    c = RNG.normal(size=(4, 3, 2)).astype(dt)
    r_ref = REF.gemm(a, b, 1.2, c, 0.5)
    r_sr = SR.gemm(a, b, 1.2, c, 0.5)
    rtol, atol = _tol(dt)
    np.testing.assert_allclose(r_sr, r_ref, rtol=rtol, atol=atol)
    e = np.empty((0, 0), dt)
    assert SR.gemm(e, e, 1.0, None, 0.0).size == 0


@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("method", ["LU", "SVD", "EIG", "CHOLESKY", "QR", "NORMAL"])
def test_solve(dt, method):
    flag = getattr(REF, f"DECOMP_{method}")
    n = 6
    raw = RNG.normal(size=(n, n))
    if method in ("CHOLESKY", "EIG"):
        a = (raw @ raw.T + np.eye(n) * 2.0).astype(dt)
    else:
        a = (raw + np.eye(n) * 3.0).astype(dt)
    b = RNG.normal(size=(n, 3)).astype(dt)
    ok_ref, x_ref = REF.solve(a, b, flags=flag)
    ok_sr, x_sr = SR.solve(a, b, flags=flag)
    assert ok_ref and ok_sr
    rtol, atol = (1e-3, 1e-3) if dt == np.float32 else (1e-9, 1e-9)
    np.testing.assert_allclose(x_sr, x_ref, rtol=rtol, atol=atol)
    gt = np.linalg.solve(a.astype(np.float64), b.astype(np.float64))
    np.testing.assert_allclose(x_sr.astype(np.float64), gt, rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
def test_solve_overdetermined_and_singular_and_empty(dt):
    # Least squares on tall matrix with DECOMP_QR / DECOMP_SVD / DECOMP_NORMAL
    a = RNG.normal(size=(10, 4)).astype(dt)
    b = RNG.normal(size=(10, 2)).astype(dt)
    gt, _, _, _ = np.linalg.lstsq(a.astype(np.float64), b.astype(np.float64), rcond=None)
    rtol, atol = (1e-3, 1e-3) if dt == np.float32 else (1e-9, 1e-9)
    for flag in (REF.DECOMP_SVD, REF.DECOMP_QR, REF.DECOMP_NORMAL):
        ok_r, x_r = REF.solve(a, b, flags=flag)
        ok_s, x_s = SR.solve(a, b, flags=flag)
        assert ok_r and ok_s
        np.testing.assert_allclose(x_s, x_r, rtol=rtol, atol=atol)
        np.testing.assert_allclose(x_s.astype(np.float64), gt, rtol=1e-3 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)

    # Singular matrix: DECOMP_LU must return (False, zeros) without crashing
    sing = np.array([[1.0, 2.0], [2.0, 4.0]], dtype=dt)
    rhs = np.array([[1.0], [2.0]], dtype=dt)
    ok_s, x_s = SR.solve(sing, rhs, flags=REF.DECOMP_LU)
    assert ok_s is False
    assert x_s.shape == (2, 1) and x_s.dtype == sing.dtype
    np.testing.assert_array_equal(x_s, np.zeros((2, 1), dtype=dt))

    # DECOMP_SVD finds min-norm pseudoinverse solution on singular matrix
    ok_r_svd, x_r_svd = REF.solve(sing, rhs, flags=REF.DECOMP_SVD)
    ok_s_svd, x_s_svd = SR.solve(sing, rhs, flags=REF.DECOMP_SVD)
    assert ok_r_svd and ok_s_svd
    np.testing.assert_allclose(x_s_svd, x_r_svd, rtol=rtol, atol=atol)

    # Empty 0x0
    e = np.empty((0, 0), dt)
    ok_e, x_e = SR.solve(e, e)
    assert ok_e and x_e.size == 0


@pytest.mark.parametrize("dt", [np.float32, np.float64])
def test_invert(dt):
    rtol, atol = (1e-3, 1e-3) if dt == np.float32 else (1e-9, 1e-9)
    raw = RNG.normal(size=(5, 5))
    spd = (raw @ raw.T + np.eye(5) * 3.0).astype(dt)
    for flag in (REF.DECOMP_LU, REF.DECOMP_CHOLESKY, REF.DECOMP_SVD):
        r_ref, inv_ref = REF.invert(spd, flags=flag)
        r_sr, inv_sr = SR.invert(spd, flags=flag)
        assert r_ref > 0 and r_sr > 0
        np.testing.assert_allclose(r_sr, r_ref, rtol=1e-4, atol=1e-4)
        np.testing.assert_allclose(inv_sr, inv_ref, rtol=rtol, atol=atol)
        np.testing.assert_allclose(inv_sr.astype(np.float64), np.linalg.inv(spd.astype(np.float64)),
                                   rtol=1e-3 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)

    # Non-square pseudoinverse with DECOMP_SVD (tall m >= n checks retval vs cv2 too; wide checks exact float64 s_min/s_max)
    tall = RNG.normal(size=(6, 4)).astype(dt)
    rt_ref, pinvt_ref = REF.invert(tall, flags=REF.DECOMP_SVD)
    rt_sr, pinvt_sr = SR.invert(tall, flags=REF.DECOMP_SVD)
    assert pinvt_sr.shape == (4, 6)
    np.testing.assert_allclose(rt_sr, rt_ref, rtol=1e-3, atol=1e-4)
    np.testing.assert_allclose(pinvt_sr, pinvt_ref, rtol=rtol, atol=atol)

    rect = RNG.normal(size=(4, 6)).astype(dt)
    r_ref, pinv_ref = REF.invert(rect, flags=REF.DECOMP_SVD)
    r_sr, pinv_sr = SR.invert(rect, flags=REF.DECOMP_SVD)
    assert pinv_sr.shape == (6, 4)
    s_gt = np.linalg.svd(rect.astype(np.float64), compute_uv=False)
    np.testing.assert_allclose(r_sr, s_gt[-1] / s_gt[0], rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-5)
    np.testing.assert_allclose(pinv_sr, pinv_ref, rtol=rtol, atol=atol)
    np.testing.assert_allclose(pinv_sr.astype(np.float64), np.linalg.pinv(rect.astype(np.float64)),
                               rtol=1e-3 if dt == np.float32 else 1e-9, atol=1e-4 if dt == np.float32 else 1e-9)

    # Singular LU -> (0.0, zeros)
    sing = np.array([[1.0, 2.0], [2.0, 4.0]], dtype=dt)
    r_sing, inv_sing = SR.invert(sing, flags=REF.DECOMP_LU)
    assert r_sing == 0.0
    np.testing.assert_array_equal(inv_sing, np.zeros((2, 2), dtype=dt))


@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("shape", [(5, 5), (7, 4), (4, 7)])
def test_svd_and_backsubst(dt, shape):
    m = RNG.normal(size=shape).astype(dt)
    rtol, atol = (1e-3, 1e-4) if dt == np.float32 else (1e-9, 1e-10)
    for flag in (0, REF.SVD_NO_UV, REF.SVD_FULL_UV):
        w_r, u_r, vt_r = REF.SVDecomp(m, flags=flag)
        w_s, u_s, vt_s = SR.SVDecomp(m, flags=flag)
        assert w_s.shape == w_r.shape and w_s.dtype == w_r.dtype
        np.testing.assert_allclose(w_s, w_r, rtol=rtol, atol=atol)
        s_gt = np.linalg.svd(m.astype(np.float64), compute_uv=False)
        np.testing.assert_allclose(w_s.ravel().astype(np.float64), s_gt, rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)
        if flag == REF.SVD_NO_UV:
            assert u_s is None and vt_s is None
        else:
            assert u_s.shape == u_r.shape and vt_s.shape == vt_r.shape
            k = min(shape)
            recon = (u_s[:, :k].astype(np.float64) * w_s.ravel().astype(np.float64)) @ vt_s[:k, :].astype(np.float64)
            np.testing.assert_allclose(recon, m.astype(np.float64), rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)

    w_s, u_s, vt_s = SR.SVDecomp(m)
    w_r, u_r, vt_r = REF.SVDecomp(m)
    rhs = RNG.normal(size=(shape[0], 2)).astype(dt)
    x_r = REF.SVBackSubst(w_r, u_r, vt_r, rhs)
    x_s = SR.SVBackSubst(w_s, u_s, vt_s, rhs)
    assert x_s.shape == x_r.shape and x_s.dtype == x_r.dtype
    np.testing.assert_allclose(x_s, x_r, rtol=rtol, atol=atol)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
def test_eigen_and_eigen_nonsymmetric(dt):
    raw = RNG.normal(size=(6, 6))
    sym = ((raw + raw.T) * 0.5).astype(dt)
    ok_r, vals_r, vecs_r = REF.eigen(sym)
    ok_s, vals_s, vecs_s = SR.eigen(sym)
    assert ok_r and ok_s
    rtol, atol = (1e-3, 1e-4) if dt == np.float32 else (1e-9, 1e-10)
    np.testing.assert_allclose(vals_s, vals_r, rtol=rtol, atol=atol)
    gt_vals = np.linalg.eigvalsh(sym.astype(np.float64))[::-1]
    np.testing.assert_allclose(vals_s.ravel().astype(np.float64), gt_vals, rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)
    # Check A * v^T == lambda * v^T for every eigenpair
    sym64 = sym.astype(np.float64)
    for i in range(6):
        lhs = sym64 @ vecs_s[i].astype(np.float64)
        rhs = float(vals_s[i, 0]) * vecs_s[i].astype(np.float64)
        np.testing.assert_allclose(lhs, rhs, rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)

    # Non-symmetric matrix constructed with known distinct real eigenvalues
    q, _ = np.linalg.qr(RNG.normal(size=(5, 5)))
    diag = np.diag([9.0, 4.0, 1.5, -2.0, -7.0])
    nonsym = (q @ diag @ np.linalg.inv(q)).astype(dt)
    ev_r, vec_r = REF.eigenNonSymmetric(nonsym)
    ev_s, vec_s = SR.eigenNonSymmetric(nonsym)
    assert ev_s.shape == ev_r.shape == (5, 1)
    assert vec_s.shape == vec_r.shape == (5, 5)
    np.testing.assert_allclose(ev_s, ev_r, rtol=rtol, atol=atol)
    ns64 = nonsym.astype(np.float64)
    for i in range(5):
        v = vec_s[i].astype(np.float64)
        assert np.linalg.norm(v) > 0.5
        np.testing.assert_allclose(ns64 @ v, float(ev_s[i, 0]) * v, rtol=1e-3 if dt == np.float32 else 1e-9, atol=1e-4 if dt == np.float32 else 1e-9)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
def test_det_trace_pca_covar_mahalanobis(dt):
    m = RNG.normal(size=(6, 6)).astype(dt)
    rtol, atol = (1e-4, 1e-4) if dt == np.float32 else (1e-10, 1e-10)
    np.testing.assert_allclose(SR.determinant(m), REF.determinant(m), rtol=rtol, atol=atol)
    np.testing.assert_allclose(SR.trace(m), REF.trace(m), rtol=rtol, atol=atol)

    X = RNG.normal(size=(30, 5)).astype(dt)
    m_r, ev_r = REF.PCACompute(X, None, maxComponents=3)
    m_s, ev_s = SR.PCACompute(X, None, maxComponents=3)
    assert m_s.shape == m_r.shape and ev_s.shape == ev_r.shape and ev_s.dtype == ev_r.dtype
    np.testing.assert_allclose(m_s, m_r, rtol=rtol, atol=atol)
    # Eigenvector signs may flip; compare projection subspaces via outer product ev^T @ ev
    np.testing.assert_allclose(ev_s.T @ ev_s, ev_r.T @ ev_r, rtol=1e-3 if dt == np.float32 else 1e-9, atol=1e-4 if dt == np.float32 else 1e-9)

    p_r = REF.PCAProject(X, m_r, ev_r)
    p_s = SR.PCAProject(X, m_s, ev_s)
    # Round-trip reconstruction must match regardless of eigenvector sign
    b_r = REF.PCABackProject(p_r, m_r, ev_r)
    b_s = SR.PCABackProject(p_s, m_s, ev_s)
    np.testing.assert_allclose(b_s, b_r, rtol=1e-3 if dt == np.float32 else 1e-9, atol=1e-4 if dt == np.float32 else 1e-9)

    m2_r, ev2_r, eval2_r = REF.PCACompute2(X, None, maxComponents=3)
    m2_s, ev2_s, eval2_s = SR.PCACompute2(X, None, maxComponents=3)
    np.testing.assert_allclose(eval2_s, eval2_r, rtol=1e-3 if dt == np.float32 else 1e-9, atol=1e-4 if dt == np.float32 else 1e-9)

    # Retained variance overload: verify kept components actually reach >= 0.85 variance against float64 SVD
    _, ev_all, eval_all = SR.PCACompute2(X, None)
    mr_s, evr_s = SR.PCACompute(X, None, retainedVariance=0.85)
    frac_kept = float(eval_all[:evr_s.shape[0]].sum() / eval_all.sum())
    assert frac_kept >= 0.85
    if evr_s.shape[0] > 1:
        assert float(eval_all[:evr_s.shape[0] - 1].sum() / eval_all.sum()) < 0.85
    np.testing.assert_allclose(evr_s.T @ evr_s, ev_all[:evr_s.shape[0]].T @ ev_all[:evr_s.shape[0]], rtol=1e-3, atol=1e-4)

    # calcCovarMatrix
    for fl in (
        REF.COVAR_NORMAL | REF.COVAR_ROWS,
        REF.COVAR_NORMAL | REF.COVAR_ROWS | REF.COVAR_SCALE,
        REF.COVAR_SCRAMBLED | REF.COVAR_ROWS | REF.COVAR_SCALE,
        REF.COVAR_NORMAL | REF.COVAR_COLS | REF.COVAR_SCALE,
    ):
        c_r, mn_r = REF.calcCovarMatrix(X, None, fl)
        c_s, mn_s = SR.calcCovarMatrix(X, None, fl)
        np.testing.assert_allclose(mn_s, mn_r, rtol=rtol, atol=atol)
        np.testing.assert_allclose(c_s, c_r, rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)

    cov, _ = SR.calcCovarMatrix(X, None, REF.COVAR_NORMAL | REF.COVAR_ROWS | REF.COVAR_SCALE)
    _, icov = SR.invert(cov.astype(dt), flags=REF.DECOMP_SVD)
    d_r = REF.Mahalanobis(X[0], X[1], icov)
    d_s = SR.Mahalanobis(X[0], X[1], icov)
    np.testing.assert_allclose(d_s, d_r, rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-5 if dt == np.float32 else 1e-10)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("shape", [(1, 8), (8, 1), (1, 7), (8, 8), (6, 10), (7, 11), (13, 17)])
def test_dft_idft_mulspectrums(dt, shape):
    x = RNG.normal(size=shape).astype(dt)
    rtol, atol = (1e-3, 1e-3) if dt == np.float32 else (1e-9, 1e-9)

    # 1) CCS forward + inverse roundtrip and parity vs cv2
    ccs_r = REF.dft(x)
    ccs_s = SR.dft(x)
    assert ccs_s.shape == ccs_r.shape and ccs_s.dtype == ccs_r.dtype
    np.testing.assert_allclose(ccs_s, ccs_r, rtol=rtol, atol=atol)

    rec_r = REF.idft(ccs_r, flags=REF.DFT_SCALE | REF.DFT_REAL_OUTPUT)
    rec_s = SR.idft(ccs_s, flags=REF.DFT_SCALE | REF.DFT_REAL_OUTPUT)
    np.testing.assert_allclose(rec_s, rec_r, rtol=rtol, atol=atol)
    np.testing.assert_allclose(rec_s, x, rtol=rtol, atol=atol)

    # 2) Complex output vs cv2 and numpy.fft float64 ground truth
    cplx_r = REF.dft(x, flags=REF.DFT_COMPLEX_OUTPUT)
    cplx_s = SR.dft(x, flags=REF.DFT_COMPLEX_OUTPUT)
    assert cplx_s.shape == cplx_r.shape == shape + (2,)
    np.testing.assert_allclose(cplx_s, cplx_r, rtol=rtol, atol=atol)
    gt = np.fft.fft(x.astype(np.float64).ravel()) if 1 in shape else np.fft.fft2(x.astype(np.float64))
    if 1 in shape:
        gt = gt.reshape(shape)
    gt_2ch = np.stack([gt.real, gt.imag], axis=-1)
    np.testing.assert_allclose(cplx_s.astype(np.float64), gt_2ch, rtol=1e-4 if dt == np.float32 else 1e-10, atol=1e-4 if dt == np.float32 else 1e-10)

    # 3) DFT_ROWS + mulSpectrums (CCS & complex, conjB False/True)
    if shape[0] > 1 and shape[1] > 1:
        y = RNG.normal(size=shape).astype(dt)
        for fl_mul in (0, REF.DFT_ROWS):
            da_r = REF.dft(x, flags=fl_mul)
            db_r = REF.dft(y, flags=fl_mul)
            da_s = SR.dft(x, flags=fl_mul)
            db_s = SR.dft(y, flags=fl_mul)
            np.testing.assert_allclose(da_s, da_r, rtol=rtol, atol=atol)
            for conj in (False, True):
                mr = REF.mulSpectrums(da_r, db_r, fl_mul, conjB=conj)
                ms = SR.mulSpectrums(da_s, db_s, fl_mul, conjB=conj)
                np.testing.assert_allclose(ms, mr, rtol=rtol, atol=atol)

                ca_r = REF.dft(x, flags=fl_mul | REF.DFT_COMPLEX_OUTPUT)
                cb_r = REF.dft(y, flags=fl_mul | REF.DFT_COMPLEX_OUTPUT)
                mcr = REF.mulSpectrums(ca_r, cb_r, fl_mul, conjB=conj)
                mcs = SR.mulSpectrums(ca_r, cb_r, fl_mul, conjB=conj)
                np.testing.assert_allclose(mcs, mcr, rtol=rtol, atol=atol)


@pytest.mark.parametrize("dt", [np.float32, np.float64])
@pytest.mark.parametrize("shape", [(1, 8), (8, 1), (4, 6), (8, 8), (6, 10)])
def test_dct_idct(dt, shape):
    x = RNG.normal(size=shape).astype(dt)
    rtol, atol = (1e-4, 1e-4) if dt == np.float32 else (1e-10, 1e-10)
    for fl in (0, REF.DCT_ROWS):
        d_r = REF.dct(x, flags=fl)
        d_s = SR.dct(x, flags=fl)
        assert d_s.shape == d_r.shape and d_s.dtype == d_r.dtype
        np.testing.assert_allclose(d_s, d_r, rtol=rtol, atol=atol)
        inv_r = REF.idct(d_r, flags=fl)
        inv_s = SR.idct(d_s, flags=fl)
        np.testing.assert_allclose(inv_s, inv_r, rtol=rtol, atol=atol)
        np.testing.assert_allclose(inv_s, x, rtol=rtol, atol=atol)


def test_kmeans_and_solvepoly():
    c0 = RNG.normal(loc=[0.0, 0.0], scale=0.3, size=(40, 2)).astype(np.float32)
    c1 = RNG.normal(loc=[10.0, 0.0], scale=0.3, size=(40, 2)).astype(np.float32)
    c2 = RNG.normal(loc=[0.0, 10.0], scale=0.3, size=(40, 2)).astype(np.float32)
    pts = np.vstack([c0, c1, c2])
    crit = (REF.TERM_CRITERIA_EPS + REF.TERM_CRITERIA_MAX_ITER, 20, 1e-4)
    for fl in (REF.KMEANS_PP_CENTERS, REF.KMEANS_RANDOM_CENTERS):
        comp_r, _, _ = REF.kmeans(pts, 3, None, crit, 3, fl)
        comp_s1, lbl1, ctr1 = SR.kmeans(pts, 3, None, crit, 3, fl)
        comp_s2, lbl2, ctr2 = SR.kmeans(pts, 3, None, crit, 3, fl)
        # Deterministic RNG seed: identical calls produce identical outputs
        assert comp_s1 == comp_s2
        np.testing.assert_array_equal(lbl1, lbl2)
        np.testing.assert_array_equal(ctr1, ctr2)
        assert lbl1.shape == (120, 1) and lbl1.dtype == np.int32
        assert ctr1.shape == (3, 2) and ctr1.dtype == np.float32
        assert comp_s1 <= comp_r * 1.05 + 1e-4

    # solvePoly: quadratic, cubic repeated, complex conjugate, higher degree
    for coeffs in ([2.0, -3.0, 1.0], [1.0, 0.0, 1.0], [-6.0, 11.0, -6.0, 1.0], [1.0, -10.0, 35.0, -50.0, 24.0]):
        c_arr = np.array(coeffs, np.float64)
        _, roots_r = REF.solvePoly(c_arr)
        _, roots_s = SR.solvePoly(c_arr)
        assert roots_s.shape == roots_r.shape and roots_s.dtype == np.float64
        cr = np.sort_complex(roots_r.reshape(-1, 2) @ np.array([1.0, 1j]))
        cs = np.sort_complex(roots_s.reshape(-1, 2) @ np.array([1.0, 1j]))
        np.testing.assert_allclose(cs, cr, rtol=1e-6, atol=1e-6)
        # Polynomial residual check in float64
        vals = np.polynomial.polynomial.polyval(cs, c_arr)
        assert np.max(np.abs(vals)) < 1e-8


def test_linalg_1thread_speed():
    a = RNG.normal(size=(256, 256)).astype(np.float32)
    b = RNG.normal(size=(256, 256)).astype(np.float32)
    img = RNG.normal(size=(256, 256)).astype(np.float32)
    REF.gemm(a, b, 1.0, None, 0.0)
    SR.gemm(a, b, 1.0, None, 0.0)
    t0 = time.perf_counter()
    for _ in range(10):
        REF.gemm(a, b, 1.0, None, 0.0)
    t_ref = time.perf_counter() - t0
    t0 = time.perf_counter()
    for _ in range(10):
        SR.gemm(a, b, 1.0, None, 0.0)
    t_sr = time.perf_counter() - t0
    assert SR.dft(img).shape == (256, 256)
    assert t_sr < max(t_ref * 2.5, 0.1)
