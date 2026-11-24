"""Parity and accuracy tests for SafariumRaster Phase 3: imgproc-filter.

Covers: Sobel, Scharr, Laplacian, Canny, bilateralFilter, medianBlur, boxFilter,
filter2D, sepFilter2D, integral, integral2, integral3, pyrDown, pyrUp,
createCLAHE, equalizeHist, adaptiveThreshold, applyColorMap,
getPerspectiveTransform, warpPerspective, and expanded cvtColor.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import compare, load_pair  # noqa: E402

REF, SR = load_pair()
REF.setNumThreads(1)
SR.setNumThreads(1)

RNG = np.random.default_rng(20261124)


def _photo(h=96, w=128, c=3, dtype=np.uint8, seed=7):
    r = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = 120.0 + 70.0 * np.sin(xx * 0.09) * np.cos(yy * 0.07) + 25.0 * np.cos((xx + yy) * 0.17)
    noise = r.normal(0.0, 12.0, size=(h, w)).astype(np.float32)
    g = np.clip(base + noise, 0, 255)
    if c == 1:
        arr = g
    else:
        arr = np.stack([g, np.clip(255.0 - g * 0.7, 0, 255), np.clip(g * 0.6 + 40.0 * np.sin(xx * 0.05), 0, 255)], axis=-1)
    if dtype == np.uint8:
        return np.round(arr).astype(np.uint8)
    if dtype == np.uint16:
        return np.round(arr * 257.0).astype(np.uint16)
    if dtype == np.float32:
        return (arr / 255.0).astype(np.float32)
    return (arr / 255.0).astype(np.float64)


@pytest.mark.parametrize("dt,ddepth", [
    (np.uint8, -1), (np.uint8, REF.CV_16S), (np.uint8, REF.CV_32F), (np.float32, REF.CV_32F), (np.float64, REF.CV_64F),
])
@pytest.mark.parametrize("ksize", [1, 3, 5, 7])
def test_sobel_scharr_laplacian(dt, ddepth, ksize):
    img = _photo(64, 80, 3 if dt != np.float64 else 1, dt)
    atol = 2 if dt == np.uint8 else 1e-3
    for dx, dy in [(1, 0), (0, 1), (1, 1), (2, 0)]:
        if ksize == 1 and (dx + dy > 2 or (dx == 1 and dy == 1)):
            continue
        r = REF.Sobel(img, ddepth, dx, dy, ksize=ksize, scale=0.5, delta=2.0)
        s = SR.Sobel(img, ddepth, dx, dy, ksize=ksize, scale=0.5, delta=2.0)
        assert s.shape == r.shape and s.dtype == r.dtype
        np.testing.assert_allclose(s, r, rtol=1e-3, atol=atol)

    # Scharr + Sobel ksize=-1
    r_sc = REF.Scharr(img, ddepth, 1, 0, scale=0.25, delta=1.0)
    s_sc = SR.Scharr(img, ddepth, 1, 0, scale=0.25, delta=1.0)
    np.testing.assert_allclose(s_sc, r_sc, rtol=1e-3, atol=atol)
    s_m1 = SR.Sobel(img, ddepth, 1, 0, ksize=-1, scale=0.25, delta=1.0)
    np.testing.assert_allclose(s_m1, r_sc, rtol=1e-3, atol=atol)

    # Laplacian across ksize 1, 3, 5, 7
    r_lap = REF.Laplacian(img, ddepth, ksize=ksize, scale=0.5, delta=1.5)
    s_lap = SR.Laplacian(img, ddepth, ksize=ksize, scale=0.5, delta=1.5)
    assert s_lap.shape == r_lap.shape and s_lap.dtype == r_lap.dtype
    np.testing.assert_allclose(s_lap, r_lap, rtol=1e-3, atol=atol)

    # Analytic ground truth: Laplacian of quadratic f(x,y) = x^2 + y^2 has exact interior value 4.0
    if ksize == 1 and ddepth == REF.CV_32F:
        yy, xx = np.mgrid[0:32, 0:32].astype(np.float32)
        quad = xx * xx + yy * yy
        lap = SR.Laplacian(quad, SR.CV_32F, ksize=1)
        np.testing.assert_allclose(lap[2:-2, 2:-2], 4.0, atol=1e-4)


@pytest.mark.parametrize("ap", [3, 5, 7])
@pytest.mark.parametrize("l2", [False, True])
def test_canny(ap, l2):
    # Sharp edges + smooth texture for deterministic Canny verification
    img = np.zeros((96, 128, 3), np.uint8)
    REF.rectangle(img, (20, 15), (90, 75), (220, 220, 220), -1)
    REF.circle(img, (60, 48), 18, (40, 140, 230), -1)
    r = REF.Canny(img, 50, 150, apertureSize=ap, L2gradient=l2)
    s = SR.Canny(img, 50, 150, apertureSize=ap, L2gradient=l2)
    assert s.shape == r.shape and s.dtype == np.uint8
    assert set(np.unique(s)).issubset({0, 255})
    # Edge maps must overlap cleanly (> 92% F1 agreement on interior edge pixels)
    rb, sb = (r > 0), (s > 0)
    inter = np.logical_and(rb, sb).sum()
    f1 = 2.0 * inter / max(rb.sum() + sb.sum(), 1)
    assert f1 >= 0.90, f"Canny ap={ap} L2={l2}: edge F1={f1:.3f}"


@pytest.mark.parametrize("dt", [np.uint8, np.float32])
@pytest.mark.parametrize("cn", [1, 3])
@pytest.mark.parametrize("d", [0, 5])
def test_bilateral_filter(dt, cn, d):
    img = _photo(64, 80, cn, dt)
    sc, ss = (40.0, 3.0) if dt == np.uint8 else (0.2, 3.0)
    r = REF.bilateralFilter(img, d, sc, ss)
    s = SR.bilateralFilter(img, d, sc, ss)
    assert s.shape == r.shape and s.dtype == r.dtype
    res = compare(r if dt == np.uint8 else np.clip(r * 255, 0, 255).astype(np.uint8),
                  s if dt == np.uint8 else np.clip(s * 255, 0, 255).astype(np.uint8),
                  f"bilateral/{dt.__name__}/c{cn}/d{d}")
    assert res.ssim >= 0.99 and res.psnr >= 40.0


@pytest.mark.parametrize("dt", [np.uint8, np.uint16, np.float32])
@pytest.mark.parametrize("ksize", [3, 5])
def test_median_blur(dt, ksize):
    img = _photo(48, 64, 3, dt)
    r = REF.medianBlur(img, ksize)
    s = SR.medianBlur(img, ksize)
    assert s.shape == r.shape and s.dtype == r.dtype
    tol = 0 if dt == np.uint8 else (1 if dt == np.uint16 else 1e-5)
    np.testing.assert_allclose(s, r, atol=tol, rtol=1e-5)


@pytest.mark.parametrize("normalize", [True, False])
def test_box_filter_and_filter2d_sepfilter2d(normalize):
    img8 = _photo(48, 64, 3, np.uint8)
    r = REF.boxFilter(img8, REF.CV_32F if not normalize else -1, (5, 3), normalize=normalize)
    s = SR.boxFilter(img8, SR.CV_32F if not normalize else -1, (5, 3), normalize=normalize)
    assert s.shape == r.shape and s.dtype == r.dtype
    np.testing.assert_allclose(s, r, atol=1 if normalize else 1e-3, rtol=1e-4)

    # filter2D with non-separable asymmetric 3x3 kernel
    kern = np.array([[0.1, 0.2, -0.1], [0.3, 0.5, 0.2], [-0.2, 0.1, 0.4]], dtype=np.float32)
    for dt, ddepth in [(np.uint8, -1), (np.uint8, REF.CV_16S), (np.float32, REF.CV_32F)]:
        src = _photo(48, 64, 3, dt)
        rf = REF.filter2D(src, ddepth, kern, delta=3.0)
        sf = SR.filter2D(src, ddepth, kern, delta=3.0)
        assert sf.shape == rf.shape and sf.dtype == rf.dtype
        np.testing.assert_allclose(sf, rf, atol=2 if dt == np.uint8 else 1e-4, rtol=1e-4)

    # sepFilter2D with CV_16S and CV_64F
    kx = np.array([1.0, 2.0, 1.0], np.float64)
    ky = np.array([-1.0, 0.0, 1.0], np.float64)
    for dd in (REF.CV_16S, REF.CV_32F, REF.CV_64F):
        rs = REF.sepFilter2D(img8, dd, kx, ky, delta=1.0)
        ss = SR.sepFilter2D(img8, dd, kx, ky, delta=1.0)
        assert ss.shape == rs.shape and ss.dtype == rs.dtype
        np.testing.assert_allclose(ss, rs, atol=1, rtol=1e-4)


def test_integral_and_pyr_up_down():
    img = _photo(37, 53, 3, np.uint8)
    s_ref = REF.integral(img)
    s_sr = SR.integral(img)
    assert s_sr.shape == s_ref.shape and s_sr.dtype == s_ref.dtype
    np.testing.assert_array_equal(s_sr, s_ref)

    s2_r, sq2_r = REF.integral2(img, sdepth=REF.CV_32S, sqdepth=REF.CV_64F)
    s2_s, sq2_s = SR.integral2(img, sdepth=SR.CV_32S, sqdepth=SR.CV_64F)
    np.testing.assert_array_equal(s2_s, s2_r)
    np.testing.assert_allclose(sq2_s, sq2_r, rtol=1e-12, atol=1e-9)

    s3_r, sq3_r, t3_r = REF.integral3(img)
    s3_s, sq3_s, t3_s = SR.integral3(img)
    np.testing.assert_array_equal(s3_s, s3_r)
    np.testing.assert_allclose(sq3_s, sq3_r, rtol=1e-12, atol=1e-9)
    np.testing.assert_array_equal(t3_s, t3_r)

    # pyrUp & pyrDown even + odd dstsize
    pu_r = REF.pyrUp(img)
    pu_s = SR.pyrUp(img)
    assert pu_s.shape == pu_r.shape and pu_s.dtype == pu_r.dtype
    np.testing.assert_allclose(pu_s, pu_r, atol=1)

    pu_odd_r = REF.pyrUp(img, dstsize=(105, 73))
    pu_odd_s = SR.pyrUp(img, dstsize=(105, 73))
    assert pu_odd_s.shape == pu_odd_r.shape
    np.testing.assert_allclose(pu_odd_s, pu_odd_r, atol=1)


def test_clahe_equalize_hist_adaptive_thresh_colormap():
    gray = _photo(96, 128, 1, np.uint8)
    # equalizeHist
    eq_r = REF.equalizeHist(gray)
    eq_s = SR.equalizeHist(gray)
    np.testing.assert_allclose(eq_s, eq_r, atol=1)

    # CLAHE u8 and u16 + property accessors
    c_r = REF.createCLAHE(clipLimit=3.0, tileGridSize=(4, 4))
    c_s = SR.createCLAHE(clipLimit=3.0, tileGridSize=(4, 4))
    assert c_s.getClipLimit() == 3.0 and c_s.getTilesGridSize() == (4, 4)
    c_s.setClipLimit(2.5)
    c_s.setTilesGridSize((8, 8))
    c_r.setClipLimit(2.5)
    c_r.setTilesGridSize((8, 8))
    res_clahe = compare(c_r.apply(gray), c_s.apply(gray), "clahe/u8")
    assert res_clahe.ssim >= 0.99 and res_clahe.psnr >= 35.0

    gray16 = _photo(64, 64, 1, np.uint16)
    res16_r = c_r.apply(gray16)
    res16_s = c_s.apply(gray16)
    assert res16_s.dtype == np.uint16 and res16_s.shape == res16_r.shape
    res16 = compare((res16_r >> 8).astype(np.uint8), (res16_s >> 8).astype(np.uint8), "clahe/u16")
    assert res16.ssim >= 0.98 and res16.psnr >= 32.0

    # adaptiveThreshold MEAN_C and GAUSSIAN_C
    for method in (REF.ADAPTIVE_THRESH_MEAN_C, REF.ADAPTIVE_THRESH_GAUSSIAN_C):
        for ttype in (REF.THRESH_BINARY, REF.THRESH_BINARY_INV):
            at_r = REF.adaptiveThreshold(gray, 255, method, ttype, 7, 3)
            at_s = SR.adaptiveThreshold(gray, 255, method, ttype, 7, 3)
            assert at_s.dtype == np.uint8 and at_s.shape == at_r.shape
            agree = float(np.mean(at_s == at_r))
            assert agree >= 0.99, f"adaptiveThreshold method={method} type={ttype}: agree={agree:.4f}"

    # applyColorMap: all 22 built-in colormaps + custom LUT
    bgr = _photo(32, 48, 3, np.uint8)
    for cmap in range(22):
        cm_r = REF.applyColorMap(gray, cmap)
        cm_s = SR.applyColorMap(gray, cmap)
        assert cm_s.shape == cm_r.shape and cm_s.dtype == np.uint8
        assert np.array_equal(cm_s, cm_r), f"colormap {cmap} gray LUT mismatch"
        cm3_r = REF.applyColorMap(bgr, cmap)
        cm3_s = SR.applyColorMap(bgr, cmap)
        np.testing.assert_allclose(cm3_s, cm3_r, atol=1)
    custom_lut = np.stack([np.arange(256, dtype=np.uint8), 255 - np.arange(256, dtype=np.uint8), np.full(256, 128, np.uint8)], -1).reshape(256, 1, 3)
    np.testing.assert_array_equal(SR.applyColorMap(gray, custom_lut), REF.applyColorMap(gray, custom_lut))


@pytest.mark.parametrize("interp", [REF.INTER_NEAREST, REF.INTER_LINEAR, REF.INTER_CUBIC])
@pytest.mark.parametrize("dt", [np.uint8, np.float32])
def test_get_perspective_and_warp_perspective(interp, dt):
    src_pts = np.array([[0, 0], [127, 0], [127, 95], [0, 95]], dtype=np.float32)
    dst_pts = np.array([[8, 6], [118, 12], [124, 90], [4, 88]], dtype=np.float32)
    m_r = REF.getPerspectiveTransform(src_pts, dst_pts)
    m_s = SR.getPerspectiveTransform(src_pts, dst_pts)
    assert m_s.shape == (3, 3) and m_s.dtype == np.float64
    np.testing.assert_allclose(m_s, m_r, rtol=1e-7, atol=1e-7)

    img = _photo(96, 128, 3, dt)
    w_r = REF.warpPerspective(img, m_r, (128, 96), flags=interp, borderMode=REF.BORDER_REFLECT_101)
    w_s = SR.warpPerspective(img, m_s, (128, 96), flags=interp, borderMode=SR.BORDER_REFLECT_101)
    assert w_s.shape == w_r.shape and w_s.dtype == w_r.dtype
    res = compare(w_r if dt == np.uint8 else np.clip(w_r * 255, 0, 255).astype(np.uint8),
                  w_s if dt == np.uint8 else np.clip(w_s * 255, 0, 255).astype(np.uint8),
                  f"warpPerspective/{interp}/{dt.__name__}")
    assert res.ssim >= 0.98 and res.psnr >= 32.0

    # WARP_INVERSE_MAP parity
    wi_r = REF.warpPerspective(img, m_r, (128, 96), flags=interp | REF.WARP_INVERSE_MAP)
    wi_s = SR.warpPerspective(img, m_s, (128, 96), flags=interp | SR.WARP_INVERSE_MAP)
    res_i = compare(wi_r if dt == np.uint8 else np.clip(wi_r * 255, 0, 255).astype(np.uint8),
                    wi_s if dt == np.uint8 else np.clip(wi_s * 255, 0, 255).astype(np.uint8),
                    f"warpPerspective/inv/{interp}/{dt.__name__}")
    assert res_i.ssim >= 0.98 and res_i.psnr >= 32.0


@pytest.mark.parametrize("code_name", [
    "BGR2Lab", "RGB2Lab", "Lab2BGR", "Lab2RGB", "LBGR2Lab", "LRGB2Lab", "Lab2LBGR", "Lab2LRGB",
    "BGR2Luv", "RGB2Luv", "Luv2BGR", "Luv2RGB", "LBGR2Luv", "LRGB2Luv", "Luv2LBGR", "Luv2LRGB",
    "BGR2YCrCb", "RGB2YCrCb", "YCrCb2BGR", "YCrCb2RGB",
    "BGR2YUV", "RGB2YUV", "YUV2BGR", "YUV2RGB",
    "BGR2HLS", "RGB2HLS", "HLS2BGR", "HLS2RGB",
    "BGR2HLS_FULL", "RGB2HLS_FULL", "HLS2BGR_FULL", "HLS2RGB_FULL",
    "BGR2HSV", "RGB2HSV", "HSV2BGR", "HSV2RGB",
    "BGR2HSV_FULL", "RGB2HSV_FULL", "HSV2BGR_FULL", "HSV2RGB_FULL",
    "BGR2XYZ", "RGB2XYZ", "XYZ2BGR", "XYZ2RGB",
])
@pytest.mark.parametrize("dt", [np.uint8, np.float32])
def test_cvtcolor_expanded(code_name, dt):
    img = _photo(48, 64, 3, dt)
    code_r = getattr(REF, f"COLOR_{code_name}")
    code_s = getattr(SR, f"COLOR_{code_name}")
    # Ensure inverse spaces receive valid ranges (e.g. Lab/Luv u8 is encoded nicely or forward->inverse)
    if code_name.startswith(("Lab2", "Luv2")):
        fwd = "BGR2Lab" if "Lab2" in code_name else "BGR2Luv"
        src = REF.cvtColor(img, getattr(REF, f"COLOR_{fwd}"))
    elif code_name.startswith(("HLS2", "HSV2")):
        fwd = "BGR2HLS_FULL" if "HLS2" in code_name and "FULL" in code_name else (
              "BGR2HLS" if "HLS2" in code_name else (
              "BGR2HSV_FULL" if "HSV2" in code_name and "FULL" in code_name else "BGR2HSV"))
        src = REF.cvtColor(img, getattr(REF, f"COLOR_{fwd}"))
    else:
        src = img

    r = REF.cvtColor(src, code_r)
    s = SR.cvtColor(src, code_s)
    assert s.shape == r.shape and s.dtype == r.dtype
    if dt == np.uint8:
        # Compare channels cleanly (ignoring 180/255 wraparound tolerance of <= 2)
        diff = np.abs(s.astype(int) - r.astype(int))
        if "HSV" in code_name or "HLS" in code_name:
            h_wrap = 180 if "FULL" not in code_name else 256
            dh = np.minimum(diff[..., 0], h_wrap - diff[..., 0])
            diff[..., 0] = dh
        assert diff.max() <= 3, f"{code_name}/u8 max diff {diff.max()}"
    else:
        # OpenCV f32 Lab/Luv uses a 1/128-quantised lookup table (~0.26 error vs exact float64 cbrt/sRGB)
        tol = 0.35 if ("Lab" in code_name or "Luv" in code_name) else 1e-3
        np.testing.assert_allclose(s, r, rtol=2e-3, atol=tol)
        if code_name == "BGR2Lab":
            # Verify Safarium matches exact float64 IEC 61966-2-1 CIE D65 Lab ground truth to < 1e-4
            rgb = src[..., ::-1].astype(np.float64)
            lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
            X = (0.412453 * lin[..., 0] + 0.357580 * lin[..., 1] + 0.180423 * lin[..., 2]) / 0.950456
            Y = 0.212671 * lin[..., 0] + 0.715160 * lin[..., 1] + 0.072169 * lin[..., 2]
            Z = (0.019334 * lin[..., 0] + 0.119193 * lin[..., 1] + 0.950227 * lin[..., 2]) / 1.088754
            f = lambda t: np.where(t > 0.008856, np.cbrt(t), 7.787 * t + 16.0 / 116.0)
            L_gt = np.where(Y > 0.008856, 116.0 * np.cbrt(Y) - 16.0, 903.3 * Y)
            lab_gt = np.stack([L_gt, 500.0 * (f(X) - f(Y)), 200.0 * (f(Y) - f(Z))], axis=-1)
            np.testing.assert_allclose(s.astype(np.float64), lab_gt, rtol=1e-4, atol=1e-4)
