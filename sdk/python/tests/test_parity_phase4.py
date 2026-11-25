"""Parity tests for SafariumRaster Phase 4: geometry + contours + Hough + LSD + segmentation + Subdiv2D.

Compares every Phase 4 function, class, constant, and edge case against reference cv2 5.1.0.95.
"""
from __future__ import annotations

import ctypes
import math
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import compare, load_pair  # noqa: E402

REF, SR = load_pair()
REF.setNumThreads(1)
SR.setNumThreads(1)

import cv2._geo as SR_GEO  # noqa: E402
from cv2 import _lib as SR_LIB  # noqa: E402

# Bind _geo exports onto SR if Coordinator hasn't wired cv2/__init__.py yet.
for _k in SR_GEO.__all__:
    if not hasattr(SR, _k):
        setattr(SR, _k, getattr(SR_GEO, _k))
for _k, _v in SR_GEO.CONSTANTS.items():
    if not hasattr(SR, _k):
        setattr(SR, _k, _v)


def _norm_cycle(pts: np.ndarray) -> np.ndarray:
    """Canonicalize cyclic polygon vertex order (start at lexicographically smallest (x, y))."""
    p = pts.reshape(-1, 2)
    if len(p) == 0:
        return p
    idx = int(np.lexsort((p[:, 1], p[:, 0]))[0])
    return np.roll(p, -idx, axis=0)


# ---------------------------------------------------------------------------
# Constants & fast C arcLength / pointPolygonTest
# ---------------------------------------------------------------------------

def test_constants_parity():
    assert len(SR_GEO.CONSTANTS) >= 30
    for k, v in SR_GEO.CONSTANTS.items():
        assert hasattr(REF, k), f"Missing constant in REF: {k}"
        assert getattr(REF, k) == v, f"Constant {k}: REF={getattr(REF, k)} vs SR={v}"
        assert k in SR_GEO.__all__


def test_fast_c_arc_length_and_point_polygon_test():
    c_arc = SR_LIB.declare("sr_p4_arc_length", [SR_LIB.VP, SR_LIB.I32, SR_LIB.I32, SR_LIB.I32, SR_LIB.PF64])
    c_ppt = SR_LIB.declare("sr_p4_point_polygon_test",
                           [SR_LIB.VP, SR_LIB.I32, SR_LIB.I32, SR_LIB.F64, SR_LIB.F64, SR_LIB.I32, SR_LIB.PF64])

    rng = np.random.default_rng(401)
    ang = np.sort(rng.random(40)) * 2.0 * np.pi
    poly_f = np.stack([50.0 + 25.0 * np.cos(ang), 60.0 + 18.0 * np.sin(ang)], axis=1).astype(np.float32)
    poly_i = np.round(poly_f * 2.0).astype(np.int32)

    for poly in (poly_f, poly_i):
        is_f32 = 1 if poly.dtype == np.float32 else 0
        for closed in (True, False):
            out = SR_LIB.F64(0.0)
            SR_LIB.check(c_arc(poly.ctypes.data, len(poly), is_f32, 1 if closed else 0, ctypes.byref(out)), "arc")
            assert abs(float(out.value) - REF.arcLength(poly, closed)) < 1e-3

        for pt in [(50.0, 60.0), (10.0, 10.0), tuple(float(v) for v in poly[0])]:
            for md in (True, False):
                out = SR_LIB.F64(0.0)
                SR_LIB.check(c_ppt(poly.ctypes.data, len(poly), is_f32, pt[0], pt[1], 1 if md else 0,
                                   ctypes.byref(out)), "ppt")
                ref_v = REF.pointPolygonTest(poly, pt, md)
                if md:
                    assert abs(float(out.value) - ref_v) < 1e-4 * max(1.0, abs(ref_v))
                else:
                    assert float(out.value) == ref_v


# ---------------------------------------------------------------------------
# Contours & Geometry
# ---------------------------------------------------------------------------

def test_convex_hull():
    empty_f = np.empty((0, 2), np.float32)
    assert SR.convexHull(empty_f) is None
    assert REF.convexHull(empty_f) is None

    degen_cases = [
        np.array([[5, 5]], np.int32),
        np.array([[5, 5], [10, 10]], np.int32),
        np.array([[0, 0], [5, 5], [10, 10], [2, 2]], np.int32),
        np.array([[0, 0], [10, 0], [10, 10], [10, 0], [0, 10], [0, 0]], np.int32),
    ]
    for arr in degen_cases:
        for cw in (False, True):
            r = REF.convexHull(arr, clockwise=cw, returnPoints=True)
            s = SR.convexHull(arr, clockwise=cw, returnPoints=True)
            assert s.shape == r.shape and s.dtype == r.dtype
            assert np.array_equal(_norm_cycle(s), _norm_cycle(r))
            ri = REF.convexHull(arr, clockwise=cw, returnPoints=False)
            si = SR.convexHull(arr, clockwise=cw, returnPoints=False)
            assert si.shape == ri.shape and si.dtype == np.int32
            assert np.array_equal(_norm_cycle(arr[si.ravel()]), _norm_cycle(arr[ri.ravel()]))

    rng = np.random.default_rng(402)
    for dt in (np.int32, np.float32):
        pts = (rng.uniform(-100, 100, (120, 2))).astype(dt)
        for cw in (False, True):
            r = REF.convexHull(pts, clockwise=cw, returnPoints=True)
            s = SR.convexHull(pts, clockwise=cw, returnPoints=True)
            assert s.shape == r.shape and s.dtype == r.dtype
            assert np.allclose(_norm_cycle(s), _norm_cycle(r), atol=1e-4)
            ri = REF.convexHull(pts, clockwise=cw, returnPoints=False)
            si = SR.convexHull(pts, clockwise=cw, returnPoints=False)
            assert si.shape == ri.shape and si.dtype == np.int32
            assert np.allclose(_norm_cycle(pts[si.ravel()]), _norm_cycle(pts[ri.ravel()]), atol=1e-4)

        # Verify in-place hull= out parameter & (N,1,2) shape
        buf = np.empty_like(REF.convexHull(pts))
        res = SR.convexHull(pts.reshape(-1, 1, 2), hull=buf)
        assert res is buf


def test_convexity_defects():
    star = np.array([
        [50, 0], [62, 35], [98, 35], [68, 57], [79, 91],
        [50, 70], [21, 91], [32, 57], [2, 35], [38, 35]
    ], dtype=np.int32).reshape(-1, 1, 2)
    hull_r = REF.convexHull(star, returnPoints=False)
    hull_s = SR.convexHull(star, returnPoints=False)
    dr = REF.convexityDefects(star, hull_r)
    ds = SR.convexityDefects(star, hull_s)
    assert ds.shape == dr.shape and ds.dtype == dr.dtype == np.int32
    # Sort by start index for cyclic comparison
    dr_s = dr[np.argsort(dr[:, 0])]
    ds_s = ds[np.argsort(ds[:, 0])]
    assert np.array_equal(ds_s, dr_s)

    # Reversed hull order
    ds_rev = SR.convexityDefects(star, hull_s[::-1])
    assert np.array_equal(ds_rev[np.argsort(ds_rev[:, 0])], dr_s)

    # Convex contour -> empty (0, 4)
    sq = np.array([[0, 0], [10, 0], [10, 10], [0, 10]], np.int32)
    assert SR.convexityDefects(sq, SR.convexHull(sq, returnPoints=False)).shape == (0, 4)

    # Rejects float32 contour like OpenCV
    with pytest.raises(SR.error):
        SR.convexityDefects(star.astype(np.float32), hull_s)


def test_is_contour_convex_area_and_bounding_rect():
    cases = [
        np.empty((0, 2), np.float32),
        np.array([[1, 2]], np.int32),
        np.array([[1, 2], [4, 5]], np.int32),
        np.array([[0, 0], [5, 0], [10, 0]], np.int32),
        np.array([[0, 0], [10, 10], [10, 0], [0, 10]], np.int32),
        np.array([[0, 0], [5, 0], [10, 0], [10, 10], [0, 10]], np.int32),
        np.array([[0, 0], [10, 0], [10, 10], [0, 10]], np.int32),
        np.array([[0.5, 0.5], [10.2, 1.1], [8.7, 11.3], [-1.2, 9.4]], np.float32),
        np.array([[0, 0], [10, 0], [5, 5], [10, 10], [0, 10]], np.float32),
    ]
    for c in cases:
        assert SR.isContourConvex(c) is REF.isContourConvex(c)
        for oriented in (False, True):
            assert abs(SR.contourArea(c, oriented=oriented) - REF.contourArea(c, oriented=oriented)) < 1e-4

    # boundingRect on point sets (int32 & negative float32) and uint8 images
    for pts in [
        np.empty((0, 2), np.int32),
        np.array([[10, 20], [30, 40]], np.int32),
        np.array([[-1.2, -1.8], [2.9, 2.9]], np.float32),
        np.array([[10.9, 10.9], [30.1, 20.1]], np.float32),
    ]:
        assert SR.boundingRect(pts) == REF.boundingRect(pts)

    mask_u8 = np.zeros((40, 50), np.uint8)
    assert SR.boundingRect(mask_u8) == REF.boundingRect(mask_u8) == (0, 0, 0, 0)
    mask_u8[12:27, 8:33] = 255
    assert SR.boundingRect(mask_u8) == REF.boundingRect(mask_u8) == (8, 12, 25, 15)
    small_u8 = np.array([[10, 20], [30, 40], [50, 60], [70, 80]], np.uint8)
    assert SR.boundingRect(small_u8) == REF.boundingRect(small_u8) == (0, 0, 2, 4)


def test_min_area_rect_and_box_points():
    # Degenerate + empty
    for arr in [
        np.empty((0, 2), np.float32),
        np.array([[5, 5]], np.float32),
        np.array([[5, 5], [15, 5]], np.float32),
        np.array([[0, 0], [5, 5], [10, 10]], np.float32),
    ]:
        rr = REF.minAreaRect(arr)
        sr = SR.minAreaRect(arr)
        assert np.allclose(sr[0], rr[0], atol=1e-4)
        assert np.allclose(sorted(sr[1]), sorted(rr[1]), atol=1e-4)
        assert -90.0 <= sr[2] < 0.0

    # Rotated rectangles across all orientations
    for deg in range(0, 180, 15):
        rad = np.deg2rad(deg)
        R = np.array([[np.cos(rad), -np.sin(rad)], [np.sin(rad), np.cos(rad)]])
        pts = (np.array([[-20, -10], [20, -10], [20, 10], [-20, 10]], np.float64) @ R.T + [100, 80]).astype(np.float32)
        rr = REF.minAreaRect(pts)
        sr = SR.minAreaRect(pts)
        assert -90.0 <= sr[2] < 0.0
        assert np.allclose(sr[0], rr[0], atol=1e-3)
        assert np.allclose(sr[1], rr[1], atol=1e-3)
        assert abs(sr[2] - rr[2]) < 1e-2

        br = REF.boxPoints(rr)
        bs = SR.boxPoints(sr)
        assert bs.shape == (4, 2) and bs.dtype == np.float32
        assert np.allclose(bs, br, atol=1e-2)

    # Random clouds
    rng = np.random.default_rng(403)
    for _ in range(10):
        pts = rng.uniform(-50, 150, (35, 2)).astype(np.float32)
        rr = REF.minAreaRect(pts)
        sr = SR.minAreaRect(pts)
        assert -90.0 <= sr[2] < 0.0
        assert abs(sr[1][0] * sr[1][1] - rr[1][0] * rr[1][1]) < 1e-2 * max(1.0, rr[1][0] * rr[1][1])
        assert np.allclose(sr[0], rr[0], atol=1e-1)


def test_min_enclosing_circle_and_triangle():
    rng = np.random.default_rng(404)
    for pts in [
        np.empty((0, 2), np.float32),
        np.array([[5, 5]], np.float32),
        np.array([[5, 5], [15, 5]], np.float32),
        np.array([[0, 0], [5, 5], [10, 10]], np.float32),
        rng.uniform(-40, 80, (50, 2)).astype(np.float32),
        rng.integers(-40, 80, (50, 2)).astype(np.int32),
    ]:
        rc, rr = REF.minEnclosingCircle(pts)
        sc, sr = SR.minEnclosingCircle(pts)
        assert np.allclose(sc, rc, atol=1e-2)
        assert abs(sr - rr) < 1e-2
        if len(pts) > 0:
            d = np.hypot(pts[:, 0] - sc[0], pts[:, 1] - sc[1])
            assert float(d.max()) <= sr + 1e-4

        ra, rt = REF.minEnclosingTriangle(pts)
        sa, st = SR.minEnclosingTriangle(pts)
        assert abs(sa - ra) < 1e-2 * max(1.0, ra)
        if rt is None:
            assert st is None
        else:
            assert st.shape == rt.shape == (3, 2) and st.dtype == np.float32

    # In-place triangle=(3,1,2) parameter
    tri_buf = np.empty((3, 1, 2), np.float32)
    pts3 = np.array([[0, 0], [20, 5], [8, 25], [3, 12]], np.float32)
    sa2, st2 = SR.minEnclosingTriangle(pts3, tri_buf)
    assert st2 is tri_buf and st2.shape == (3, 1, 2)
    ra2, _ = REF.minEnclosingTriangle(pts3)
    assert abs(sa2 - ra2) < 1e-2


def test_fit_ellipse_all_methods():
    with pytest.raises(SR.error):
        SR.fitEllipse(np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32))

    for ang in (0, 30, 90, 135):
        pts = REF.ellipse2Poly((80, 60), (35, 14), ang, 0, 360, 12).astype(np.float32)
        for fn in ("fitEllipse", "fitEllipseAMS", "fitEllipseDirect"):
            rr = getattr(REF, fn)(pts)
            sr = getattr(SR, fn)(pts)
            assert np.allclose(sr[0], rr[0], atol=0.5), (fn, ang, sr, rr)
            assert np.allclose(sorted(sr[1]), sorted(rr[1]), atol=1.0), (fn, ang, sr, rr)
            diff_ang = abs((sr[2] % 180.0) - (rr[2] % 180.0))
            diff_ang = min(diff_ang, 180.0 - diff_ang)
            assert diff_ang < 2.0, (fn, ang, sr, rr)

    # 5-point fit & int32 input
    pts5 = REF.ellipse2Poly((50, 60), (30, 15), 40, 0, 300, 60)[:5].astype(np.int32)
    for fn in ("fitEllipse", "fitEllipseAMS", "fitEllipseDirect"):
        rr = getattr(REF, fn)(pts5)
        sr = getattr(SR, fn)(pts5)
        assert np.allclose(sr[0], rr[0], atol=1.0)
        assert np.allclose(sorted(sr[1]), sorted(rr[1]), atol=2.0)


@pytest.mark.parametrize("dist_name", ["DIST_L2", "DIST_L1", "DIST_L12", "DIST_FAIR", "DIST_WELSCH", "DIST_HUBER"])
def test_fit_line_2d_and_3d(dist_name):
    with pytest.raises(SR.error):
        SR.fitLine(np.empty((0, 2), np.float32), getattr(SR, dist_name), 0, 0.01, 0.01)

    rng = np.random.default_rng(405)
    xs = np.linspace(0, 100, 35)
    ys = 1.7 * xs + 15.0 + rng.normal(0, 0.8, 35)
    ys[7] += 45.0  # outlier
    pts2 = np.stack([xs, ys], axis=1).astype(np.float32)

    dt = getattr(SR, dist_name)
    r = REF.fitLine(pts2, dt, 0, 0.01, 0.01)
    s = SR.fitLine(pts2, dt, 0, 0.01, 0.01)
    assert s.shape == (4, 1) and s.dtype == np.float32
    dot = abs(float(r[0, 0] * s[0, 0] + r[1, 0] * s[1, 0]))
    assert dot > 0.995, (dist_name, r.ravel(), s.ravel())

    # 3D line fit
    zs = -0.6 * xs + 5.0 + rng.normal(0, 0.3, 35)
    pts3 = np.stack([xs, ys, zs], axis=1).astype(np.float32)
    r3 = REF.fitLine(pts3, dt, 0, 0.01, 0.01)
    s3 = SR.fitLine(pts3, dt, 0, 0.01, 0.01)
    assert s3.shape == (6, 1) and s3.dtype == np.float32
    dot3 = abs(float(np.dot(r3[:3, 0], s3[:3, 0])))
    assert dot3 > 0.99, (dist_name, r3.ravel(), s3.ravel())


def test_moments_hu_moments_and_match_shapes():
    # Empty
    assert SR.moments(np.empty((0, 2), np.float32)) == REF.moments(np.empty((0, 2), np.float32))
    assert SR.moments(np.empty((0, 0), np.uint8)) == REF.moments(np.empty((0, 0), np.uint8))

    # Contours
    poly = np.array([[10, 12], [45, 10], [50, 35], [22, 42], [8, 30]], np.float32)
    for c in (poly, poly[::-1], poly.astype(np.int32)):
        rm = REF.moments(c)
        sm = SR.moments(c)
        assert set(sm.keys()) == set(rm.keys())
        for k in rm:
            assert abs(sm[k] - rm[k]) <= 1e-6 * max(1.0, abs(rm[k])), (k, sm[k], rm[k])
        rhu = REF.HuMoments(rm)
        shu = SR.HuMoments(sm)
        assert shu.shape == (7, 1) and shu.dtype == np.float64
        np.testing.assert_allclose(shu, rhu, rtol=1e-6, atol=1e-12)

    # Raster images across dtypes and binaryImage
    img_base = np.zeros((48, 64), np.uint8)
    REF.circle(img_base, (28, 22), 14, 200, -1)
    REF.rectangle(img_base, (38, 12), (56, 38), 110, -1)
    for dt in (np.uint8, np.uint16, np.int16, np.float32, np.float64):
        im = img_base.astype(dt)
        for bin_flag in (False, True):
            rm = REF.moments(im, bin_flag)
            sm = SR.moments(im, bin_flag)
            for k in rm:
                assert abs(sm[k] - rm[k]) <= 1e-4 * max(1.0, abs(rm[k])), (dt, bin_flag, k)

    # matchShapes (I1, I2, I3) on contours and images
    poly2 = poly * 2.0 + np.array([15.0, -7.0], np.float32)
    poly3 = np.array([[0, 0], [40, 0], [40, 10], [0, 10]], np.float32)
    for m in (SR.CONTOURS_MATCH_I1, SR.CONTOURS_MATCH_I2, SR.CONTOURS_MATCH_I3):
        assert SR.matchShapes(poly, poly, m, 0) == 0.0
        assert abs(SR.matchShapes(poly, poly2, m, 0) - REF.matchShapes(poly, poly2, m, 0)) < 1e-5
        assert abs(SR.matchShapes(poly, poly3, m, 0) - REF.matchShapes(poly, poly3, m, 0)) < 1e-5
        assert abs(SR.matchShapes(img_base, img_base[::-1, :], m, 0) -
                   REF.matchShapes(img_base, img_base[::-1, :], m, 0)) < 1e-5


def test_intersect_convex_convex_and_rotated_rectangle_intersection():
    p1 = np.array([[0, 0], [10, 0], [10, 10], [0, 10]], np.float32)
    p2 = np.array([[5, 5], [15, 5], [15, 15], [5, 15]], np.float32)
    p_in = np.array([[2, 2], [8, 2], [8, 8], [2, 8]], np.float32)
    p_disj = np.array([[30, 30], [40, 30], [40, 40], [30, 40]], np.float32)

    ra, rp = REF.intersectConvexConvex(p1, p2)
    sa, sp = SR.intersectConvexConvex(p1, p2)
    assert abs(sa - ra) < 1e-4
    assert sp.dtype == np.float32 and sp.shape[1:] == (1, 2)
    assert np.allclose(_norm_cycle(sp), _norm_cycle(rp), atol=1e-4)

    # Nested True vs False
    sa_t, sp_t = SR.intersectConvexConvex(p1, p_in, handleNested=True)
    ra_t, _ = REF.intersectConvexConvex(p1, p_in, handleNested=True)
    assert abs(sa_t - ra_t) < 1e-4 and sp_t.shape[0] == 4
    assert SR.intersectConvexConvex(p1, p_in, handleNested=False) == REF.intersectConvexConvex(p1, p_in, handleNested=False)
    assert SR.intersectConvexConvex(p1, p_disj)[0] == 0.0

    # rotatedRectangleIntersection
    r1 = ((5.0, 5.0), (10.0, 10.0), 0.0)
    r_part = ((10.0, 5.0), (4.0, 4.0), 0.0)
    r_in = ((5.0, 5.0), (4.0, 4.0), 15.0)
    r_disj = ((50.0, 50.0), (4.0, 4.0), 0.0)
    r_zero = ((5.0, 5.0), (0.0, 0.0), 0.0)

    for b in (r_part, r_in, r_disj, r_zero):
        rt, rpts = REF.rotatedRectangleIntersection(r1, b)
        st, spts = SR.rotatedRectangleIntersection(r1, b)
        assert st == rt
        if rpts is None:
            assert spts is None
        else:
            assert spts.dtype == np.float32 and spts.ndim == 2 and spts.shape[1] == 2
            assert np.allclose(_norm_cycle(spts), _norm_cycle(rpts), atol=1e-4)


# ---------------------------------------------------------------------------
# Hough & LineSegmentDetector
# ---------------------------------------------------------------------------

def test_hough_lines_and_hough_lines_p():
    blank = np.zeros((64, 64), np.uint8)
    hl0 = SR.HoughLines(blank, 1, np.pi / 180, 10)
    assert hl0.shape == (0, 1, 2) and hl0.dtype == np.float32
    hlp0 = SR.HoughLinesP(blank, 1, np.pi / 180, 10)
    assert hlp0.shape == (0, 4) and hlp0.dtype == np.int32

    img = np.zeros((160, 200), np.uint8)
    REF.line(img, (15, 25), (185, 25), 255, 1)
    REF.line(img, (20, 140), (180, 40), 255, 1)
    REF.line(img, (60, 10), (60, 150), 255, 1)

    rl = REF.HoughLines(img, 1, np.pi / 180, 50)
    sl = SR.HoughLines(img, 1, np.pi / 180, 50)
    assert sl.ndim == 3 and sl.shape[1:] == (1, 2) and sl.dtype == np.float32
    assert len(sl) >= 3
    # Verify each reference line has a close match in SR lines
    for rho_r, th_r in rl[:, 0, :]:
        dists = [min(abs(rho_s - rho_r) + 50.0 * abs(th_s - th_r),
                     abs(rho_s + rho_r) + 50.0 * abs(abs(th_s - th_r) - np.pi))
                 for rho_s, th_s in sl[:, 0, :]]
        assert min(dists) < 4.0

    # Multi-scale srn/stn
    sl_ms = SR.HoughLines(img, 1, np.pi / 180, 50, srn=2, stn=2)
    assert sl_ms.ndim == 3 and sl_ms.shape[1:] == (1, 2) and len(sl_ms) >= 3

    # HoughLinesP
    slp = SR.HoughLinesP(img, 1, np.pi / 180, 30, minLineLength=30, maxLineGap=5)
    assert slp.ndim == 2 and slp.shape[1] == 4 and slp.dtype == np.int32 and len(slp) >= 3
    for x1, y1, x2, y2 in slp:
        assert math.hypot(x2 - x1, y2 - y1) >= 29.0


def test_hough_circles():
    blank = np.zeros((64, 64), np.uint8)
    assert SR.HoughCircles(blank, SR.HOUGH_GRADIENT, 1, 20, param1=50, param2=15) is None

    img = np.zeros((180, 220), np.uint8)
    true_circles = [(55, 60, 26), (150, 110, 34)]
    for cx, cy, r in true_circles:
        REF.circle(img, (cx, cy), r, 255, 2)

    for method, p2 in [(SR.HOUGH_GRADIENT, 18), (SR.HOUGH_GRADIENT_ALT, 0.7)]:
        sc = SR.HoughCircles(img, method, 1.0, 40, param1=60, param2=p2, minRadius=15, maxRadius=45)
        assert sc is not None and sc.ndim == 3 and sc.shape[0] == 1 and sc.shape[2] == 3
        assert sc.dtype == np.float32 and sc.shape[1] >= 2
        for tx, ty, tr in true_circles:
            best = min(math.hypot(x - tx, y - ty) + abs(r - tr) for x, y, r in sc[0])
            assert best < 6.0, (method, (tx, ty, tr), sc)

    # Also test blurred/filled circles (real edge gradients)
    blur = REF.GaussianBlur(img, (5, 5), 1.2)
    sc_b = SR.HoughCircles(blur, SR.HOUGH_GRADIENT, 1.2, 40, param1=50, param2=16, minRadius=15, maxRadius=45)
    assert sc_b is not None and sc_b.shape[1] >= 2


def test_end_to_end_real_mask_contour_geometry():
    mask = np.zeros((160, 200), np.uint8)
    REF.circle(mask, (70, 80), 40, 255, -1)
    REF.circle(mask, (95, 80), 22, 0, -1) # creates concave C-shape
    contours_r, _ = REF.findContours(mask, REF.RETR_EXTERNAL, REF.CHAIN_APPROX_SIMPLE)
    contours_s, _ = SR.findContours(mask, SR.RETR_EXTERNAL, SR.CHAIN_APPROX_SIMPLE)
    assert len(contours_r) == len(contours_s) == 1
    cr, cs = contours_r[0], contours_s[0]
    assert abs(SR.contourArea(cs) - REF.contourArea(cr)) < 1e-3
    assert SR.boundingRect(cs) == REF.boundingRect(cr)
    assert SR.isContourConvex(cs) is REF.isContourConvex(cr) is False
    dr = REF.convexityDefects(cr, REF.convexHull(cr, returnPoints=False))
    ds = SR.convexityDefects(cs, SR.convexHull(cs, returnPoints=False))
    assert ds.shape == dr.shape
    assert np.array_equal(ds[np.argsort(ds[:, 0])], dr[np.argsort(dr[:, 0])])
    assert SR.matchShapes(cr, cs, SR.CONTOURS_MATCH_I1, 0) < 1e-6


def test_line_segment_detector():
    blank = np.zeros((64, 64), np.uint8)
    lsd = SR.createLineSegmentDetector(SR.LSD_REFINE_STD)
    l0, w0, p0, nfa0 = lsd.detect(blank)
    assert l0.shape == (0, 4) and w0.shape == (0,) and p0.shape == (0,) and nfa0 is None

    img = np.zeros((160, 200), np.uint8)
    REF.rectangle(img, (30, 30), (150, 120), 220, -1)
    REF.line(img, (10, 140), (190, 20), 255, 2)

    for ref_mode in (SR.LSD_REFINE_NONE, SR.LSD_REFINE_STD, SR.LSD_REFINE_ADV):
        lsd_r = REF.createLineSegmentDetector(ref_mode)
        lsd_s = SR.createLineSegmentDetector(ref_mode)
        rl, rw, rp, rnfa = lsd_r.detect(img)
        sl, sw, sp, snfa = lsd_s.detect(img)
        assert sl.ndim == 2 and sl.shape[1] == 4 and sl.dtype == np.float32 and len(sl) >= 4
        assert sw.shape == (len(sl),) and sw.dtype == np.float64
        assert sp.shape == (len(sl),) and sp.dtype == np.float64
        if ref_mode == SR.LSD_REFINE_ADV:
            assert snfa is not None and snfa.shape == (len(sl),) and snfa.dtype == np.float64
        else:
            assert snfa is None

    # drawSegments & compareSegments
    rl, _, _, _ = REF.createLineSegmentDetector().detect(img)
    sl, _, _, _ = SR.createLineSegmentDetector().detect(img)
    drawn_r = REF.createLineSegmentDetector().drawSegments(img.copy(), sl)
    drawn_s = SR.createLineSegmentDetector().drawSegments(img.copy(), sl)
    assert drawn_s.shape == (160, 200, 3) and drawn_s.dtype == np.uint8
    assert compare(drawn_r, drawn_s, "lsd_draw").ok

    # Check SR segments overlap strongly with REF segments
    cnt_same, ov_img = SR.createLineSegmentDetector().compareSegments((200, 160), sl, sl)
    assert cnt_same == 0 and ov_img.shape == (160, 200, 3)
    cnt_cmp, cmp_s = SR.createLineSegmentDetector().compareSegments((200, 160), rl, sl, np.zeros((160, 200, 3), np.uint8))
    cnt_cmp_r, cmp_r = REF.createLineSegmentDetector().compareSegments((200, 160), rl, sl, np.zeros((160, 200, 3), np.uint8))
    assert abs(cnt_cmp - cnt_cmp_r) <= 10


# ---------------------------------------------------------------------------
# floodFill, watershed, grabCut, Subdiv2D
# ---------------------------------------------------------------------------

def test_flood_fill():
    # 1-ch u8 + mask=None (checks border=1 parity)
    img = np.zeros((32, 40), np.uint8)
    REF.rectangle(img, (6, 6), (28, 22), 120, -1)
    img[12:16, 14:18] = 123

    for conn in (4, 8):
        for fixed in (0, SR.FLOODFILL_FIXED_RANGE):
            flags = conn | fixed
            r_area, r_im, r_m, r_rect = REF.floodFill(img.copy(), None, (10, 10), 200, 4, 4, flags)
            s_area, s_im, s_m, s_rect = SR.floodFill(img.copy(), None, (10, 10), 200, 4, 4, flags)
            assert s_area == r_area and s_rect == r_rect
            assert np.array_equal(s_im, r_im)
            assert np.array_equal(s_m, r_m)

    # User mask + FLOODFILL_MASK_ONLY + flag value (42 << 8) + boundary seed
    um_r = np.zeros((34, 42), np.uint8)
    um_s = np.zeros((34, 42), np.uint8)
    flags_mo = 4 | (42 << 8) | SR.FLOODFILL_MASK_ONLY
    r_area, r_im, r_m, r_rect = REF.floodFill(img.copy(), um_r, (0, 0), 255, 0, 0, flags_mo)
    s_area, s_im, s_m, s_rect = SR.floodFill(img.copy(), um_s, (0, 0), 255, 0, 0, flags_mo)
    assert s_area == r_area and s_rect == r_rect
    assert np.array_equal(s_im, r_im) and np.array_equal(s_m, r_m)

    # 3-ch u8 + f32
    im3 = np.full((24, 24, 3), (50, 80, 110), np.uint8)
    im3[6:18, 6:18] = (200, 150, 90)
    r3 = REF.floodFill(im3.copy(), None, (12, 12), (10, 20, 30), (5, 5, 5), (5, 5, 5), 8)
    s3 = SR.floodFill(im3.copy(), None, (12, 12), (10, 20, 30), (5, 5, 5), (5, 5, 5), 8)
    assert s3[0] == r3[0] and s3[3] == r3[3] and np.array_equal(s3[1], r3[1]) and np.array_equal(s3[2], r3[2])

    imf = im3.astype(np.float32) / 255.0
    rf = REF.floodFill(imf.copy(), None, (12, 12), (0.1, 0.2, 0.3), (0.05, 0.05, 0.05), (0.05, 0.05, 0.05), 4)
    sf = SR.floodFill(imf.copy(), None, (12, 12), (0.1, 0.2, 0.3), (0.05, 0.05, 0.05), (0.05, 0.05, 0.05), 4)
    assert sf[0] == rf[0] and sf[3] == rf[3] and np.allclose(sf[1], rf[1], atol=1e-6) and np.array_equal(sf[2], rf[2])

    # Already masked seed -> 0, (0,0,0,0)
    um_s[10, 10] = 1
    assert SR.floodFill(img.copy(), um_s, (9, 9), 200)[0] == 0
    with pytest.raises(SR.error):
        SR.floodFill(img.copy(), None, (-1, 0), 200)


def test_watershed():
    img = np.zeros((60, 80, 3), np.uint8)
    img[:, :40] = (30, 60, 200)
    img[:, 40:] = (210, 190, 40)
    # Smooth central ridge
    img[:, 39:41] = (120, 125, 120)
    m_base = np.zeros((60, 80), np.int32)
    m_base[20:30, 10:20] = 1
    m_base[20:30, 60:70] = 2

    mr = REF.watershed(img, m_base.copy())
    ms = SR.watershed(img, m_base.copy())
    assert ms.shape == mr.shape and ms.dtype == np.int32
    assert np.all(ms[0, :] == -1) and np.all(ms[-1, :] == -1)
    assert np.all(ms[:, 0] == -1) and np.all(ms[:, -1] == -1)
    assert np.any(ms[1:-1, 1:-1] == -1)
    agree = float(np.mean(ms == mr))
    assert agree >= 0.96, f"watershed agreement={agree:.4f}"


def test_grabcut():
    img = np.zeros((80, 100, 3), np.uint8)
    img[:] = (30, 40, 200) # red background
    img[18:62, 24:76] = (40, 200, 50) # green foreground object
    rng = np.random.default_rng(406)
    noise = rng.integers(-10, 11, img.shape, dtype=np.int16)
    img = np.clip(img.astype(np.int16) + noise, 0, 255).astype(np.uint8)

    rect = (20, 14, 60, 52)
    bg_r, fg_r = np.zeros((1, 65), np.float64), np.zeros((1, 65), np.float64)
    bg_s, fg_s = np.zeros((1, 65), np.float64), np.zeros((1, 65), np.float64)
    mr = np.zeros(img.shape[:2], np.uint8)
    ms = np.zeros(img.shape[:2], np.uint8)

    mr, bg_r, fg_r = REF.grabCut(img, mr, rect, bg_r, fg_r, 3, REF.GC_INIT_WITH_RECT)
    ms, bg_s, fg_s = SR.grabCut(img, ms, rect, bg_s, fg_s, 3, SR.GC_INIT_WITH_RECT)
    assert ms.shape == img.shape[:2] and ms.dtype == np.uint8
    assert set(np.unique(ms)).issubset({0, 1, 2, 3})

    fg_ref = (mr == 1) | (mr == 3)
    fg_sr = (ms == 1) | (ms == 3)
    iou = float(np.logical_and(fg_ref, fg_sr).sum()) / max(1, int(np.logical_or(fg_ref, fg_sr).sum()))
    assert iou >= 0.92, f"grabCut RECT IoU={iou:.4f}"

    # Continue with GC_EVAL + GC_INIT_WITH_MASK
    ms, bg_s, fg_s = SR.grabCut(img, ms, None, bg_s, fg_s, 1, SR.GC_EVAL)
    ms2 = np.full(img.shape[:2], SR.GC_PR_BGD, np.uint8)
    ms2[25:55, 32:68] = SR.GC_FGD
    ms2[:8, :] = SR.GC_BGD
    bg2, fg2 = np.zeros((1, 65), np.float64), np.zeros((1, 65), np.float64)
    ms2, bg2, fg2 = SR.grabCut(img, ms2, None, bg2, fg2, 2, SR.GC_INIT_WITH_MASK)
    assert np.all(ms2[25:55, 32:68] == SR.GC_FGD) and np.all(ms2[:8, :] == SR.GC_BGD)


def test_subdiv2d():
    # Empty Subdiv2D & deferred initDelaunay
    s0 = SR.Subdiv2D()
    r0 = REF.Subdiv2D()
    with pytest.raises(SR.error):
        s0.insert((10, 10))
    s0.initDelaunay((0, 0, 100, 100))
    r0.initDelaunay((0, 0, 100, 100))
    assert s0.getEdgeList() == r0.getEdgeList() == ()
    assert s0.getTriangleList() == r0.getTriangleList() == ()
    assert s0.getVoronoiFacetList([]) == r0.getVoronoiFacetList([]) == ((), ())
    assert s0.locate((50, 50))[0] == REF.SUBDIV2D_PTLOC_INSIDE

    # Insert points & compare Delaunay / Voronoi / navigation
    pts = [(20.0, 20.0), (80.0, 25.0), (85.0, 80.0), (25.0, 75.0), (50.0, 48.0), (35.0, 40.0)]
    sub_r = REF.Subdiv2D((0, 0, 100, 100))
    sub_s = SR.Subdiv2D((0, 0, 100, 100))

    v1_r = sub_r.insert(pts[0])
    v1_s = sub_s.insert(pts[0])
    assert v1_s == v1_r == 4
    assert sub_r.insert(pts[1:]) is None and sub_s.insert(pts[1:]) is None

    # Duplicate point returns existing vertex id
    assert sub_s.insert(pts[0]) == 4
    # Out-of-bounds raises
    with pytest.raises(SR.error):
        sub_s.locate((100, 50))

    # Locate vertex / inside
    loc_v = sub_s.locate((50.0, 48.0))
    assert loc_v[0] == SR.SUBDIV2D_PTLOC_VERTEX and loc_v[2] == 8
    loc_in = sub_s.locate((40.0, 30.0))
    assert loc_in[0] in (SR.SUBDIV2D_PTLOC_INSIDE, SR.SUBDIV2D_PTLOC_ON_EDGE)

    # findNearest
    assert sub_s.findNearest((22.0, 21.0)) == sub_r.findNearest((22.0, 21.0))

    # Triangle list & Delaunay empty-circumcircle invariant
    tl_r = sub_r.getTriangleList()
    tl_s = sub_s.getTriangleList()
    assert tl_s.shape == tl_r.shape and tl_s.dtype == np.float32
    pts_arr = np.array(pts, np.float64)
    for t in tl_s:
        ax, ay, bx, by, cx, cy = [float(v) for v in t]
        # Verify no input point lies strictly inside circumcircle
        D = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        assert abs(D) > 1e-6
        ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / D
        uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / D
        rad = math.hypot(ax - ux, ay - uy)
        dists = np.hypot(pts_arr[:, 0] - ux, pts_arr[:, 1] - uy)
        assert float(dists.min()) >= rad - 1e-3

    # Edge list & Leading edge list
    el_r = sub_r.getEdgeList()
    el_s = sub_s.getEdgeList()
    assert el_s.shape == el_r.shape and el_s.dtype == np.float32
    le_s = sub_s.getLeadingEdgeList()
    assert le_s.dtype == np.int32 and len(le_s) > 0

    # Voronoi facets
    fl_r, fc_r = sub_r.getVoronoiFacetList([])
    fl_s, fc_s = sub_s.getVoronoiFacetList([])
    assert len(fl_s) == len(fl_r) == len(pts)
    assert fc_s.shape == fc_r.shape and np.allclose(fc_s, fc_r, atol=1e-4)

    # Vertex & Edge navigation
    vpt_s, fe_s = sub_s.getVertex(4)
    assert vpt_s == (20.0, 20.0) and fe_s > 0
    for et in (
        SR.SUBDIV2D_NEXT_AROUND_ORG, SR.SUBDIV2D_NEXT_AROUND_DST,
        SR.SUBDIV2D_PREV_AROUND_ORG, SR.SUBDIV2D_PREV_AROUND_DST,
        SR.SUBDIV2D_NEXT_AROUND_LEFT, SR.SUBDIV2D_NEXT_AROUND_RIGHT,
        SR.SUBDIV2D_PREV_AROUND_LEFT, SR.SUBDIV2D_PREV_AROUND_RIGHT,
    ):
        assert sub_s.getEdge(fe_s, et) > 0
    assert sub_s.symEdge(sub_s.symEdge(fe_s)) == fe_s
    assert sub_s.rotateEdge(fe_s, 4) == fe_s
    assert sub_s.nextEdge(fe_s) > 0
    assert sub_s.edgeOrg(fe_s)[0] > 0 and sub_s.edgeDst(fe_s)[0] > 0
