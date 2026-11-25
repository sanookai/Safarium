"""Phase 4: Geometry, Contours, Hough Transforms, LineSegmentDetector, Segmentation, and Subdiv2D.

Backed by libSafariumRaster (Swift + pure C11 geo_p4.c). Signatures, defaults, dtypes, and return
conventions follow OpenCV 5.1.0.
"""
from __future__ import annotations

import ctypes
import math

import numpy as np

from . import _lib
from ._lib import F64, I32, IMG_ARGS, PF64, PI32, VP, check, declare, img_args

_PF32 = ctypes.POINTER(ctypes.c_float)
_F32 = ctypes.c_float

CONSTANTS = {
    "CONTOURS_MATCH_I1": 1,
    "CONTOURS_MATCH_I2": 2,
    "CONTOURS_MATCH_I3": 3,
    "INTERSECT_NONE": 0,
    "INTERSECT_PARTIAL": 1,
    "INTERSECT_FULL": 2,
    "HOUGH_STANDARD": 0,
    "HOUGH_PROBABILISTIC": 1,
    "HOUGH_MULTI_SCALE": 2,
    "HOUGH_GRADIENT": 3,
    "HOUGH_GRADIENT_ALT": 4,
    "LSD_REFINE_NONE": 0,
    "LSD_REFINE_STD": 1,
    "LSD_REFINE_ADV": 2,
    "FLOODFILL_FIXED_RANGE": 65536,
    "FLOODFILL_MASK_ONLY": 131072,
    "GC_BGD": 0,
    "GC_FGD": 1,
    "GC_PR_BGD": 2,
    "GC_PR_FGD": 3,
    "GC_INIT_WITH_RECT": 0,
    "GC_INIT_WITH_MASK": 1,
    "GC_EVAL": 2,
    "GC_EVAL_FREEZE_MODEL": 3,
    "SUBDIV2D_PTLOC_ERROR": -2,
    "SUBDIV2D_PTLOC_OUTSIDE_RECT": -1,
    "SUBDIV2D_PTLOC_INSIDE": 0,
    "SUBDIV2D_PTLOC_VERTEX": 1,
    "SUBDIV2D_PTLOC_ON_EDGE": 2,
    "SUBDIV2D_NEXT_AROUND_ORG": 0,
    "SUBDIV2D_NEXT_AROUND_DST": 34,
    "SUBDIV2D_PREV_AROUND_ORG": 17,
    "SUBDIV2D_PREV_AROUND_DST": 51,
    "SUBDIV2D_NEXT_AROUND_LEFT": 19,
    "SUBDIV2D_NEXT_AROUND_RIGHT": 49,
    "SUBDIV2D_PREV_AROUND_LEFT": 32,
    "SUBDIV2D_PREV_AROUND_RIGHT": 2,
    "Subdiv2D_PTLOC_ERROR": -2,
    "Subdiv2D_PTLOC_OUTSIDE_RECT": -1,
    "Subdiv2D_PTLOC_INSIDE": 0,
    "Subdiv2D_PTLOC_VERTEX": 1,
    "Subdiv2D_PTLOC_ON_EDGE": 2,
    "Subdiv2D_NEXT_AROUND_ORG": 0,
    "Subdiv2D_NEXT_AROUND_DST": 34,
    "Subdiv2D_PREV_AROUND_ORG": 17,
    "Subdiv2D_PREV_AROUND_DST": 51,
    "Subdiv2D_NEXT_AROUND_LEFT": 19,
    "Subdiv2D_NEXT_AROUND_RIGHT": 49,
    "Subdiv2D_PREV_AROUND_LEFT": 32,
    "Subdiv2D_PREV_AROUND_RIGHT": 2,
}
globals().update(CONSTANTS)

__all__ = [
    "convexHull", "convexityDefects", "isContourConvex", "contourArea",
    "boundingRect", "minAreaRect", "boxPoints", "minEnclosingCircle", "minEnclosingTriangle",
    "fitEllipse", "fitEllipseAMS", "fitEllipseDirect", "fitLine",
    "moments", "HuMoments", "matchShapes",
    "intersectConvexConvex", "rotatedRectangleIntersection",
    "HoughLines", "HoughLinesP", "HoughCircles",
    "LineSegmentDetector", "createLineSegmentDetector",
    "floodFill", "watershed", "grabCut", "Subdiv2D",
] + list(CONSTANTS.keys())

# ---------------------------------------------------------------------------
# C-ABI declarations
# ---------------------------------------------------------------------------

_c_bounding_pts = declare("sr_p4_bounding_rect_pts", [VP, I32, I32, PI32])
_c_bounding_img = declare("sr_p4_bounding_rect_img", IMG_ARGS + [PI32])
_c_contour_area = declare("sr_p4_contour_area", [VP, I32, I32, I32, PF64])
_c_is_convex = declare("sr_p4_is_contour_convex", [VP, I32, I32, PI32])
_c_convex_hull = declare("sr_p4_convex_hull", [VP, I32, I32, I32, PI32, PI32])
_c_convexity_defects = declare("sr_p4_convexity_defects", [PI32, I32, PI32, I32, PI32, PI32])
_c_min_area_rect = declare("sr_p4_min_area_rect", [VP, I32, I32, _PF32])
_c_box_points = declare("sr_p4_box_points", [_F32, _F32, _F32, _F32, _F32, _PF32])
_c_min_circle = declare("sr_p4_min_enclosing_circle", [VP, I32, I32, _PF32])
_c_min_tri = declare("sr_p4_min_enclosing_triangle", [VP, I32, I32, PF64, _PF32])
_c_fit_ellipse = declare("sr_p4_fit_ellipse", [VP, I32, I32, I32, _PF32])
_c_fit_line = declare("sr_p4_fit_line", [VP, I32, I32, I32, I32, F64, F64, F64, _PF32])
_c_moments_pts = declare("sr_p4_moments_pts", [VP, I32, I32, PF64])
_c_moments_img = declare("sr_p4_moments_img", IMG_ARGS + [I32, PF64])
_c_hu_moments = declare("sr_p4_hu_moments", [PF64, PF64])
_c_match_shapes = declare("sr_p4_match_shapes", [PF64, PF64, I32, F64, PF64])
_c_intersect_cc = declare("sr_p4_intersect_convex_convex", [_PF32, I32, _PF32, I32, I32, _PF32, PI32, _PF32])
_c_rot_rect_int = declare("sr_p4_rot_rect_intersection", [_PF32, _PF32, _PF32, PI32, PI32])

_c_hough_lines = declare("sr_p4_hough_lines", IMG_ARGS + [F64, F64, I32, F64, F64, F64, F64, I32, I32, PI32, ctypes.POINTER(VP)])
_c_hough_lines_take = declare("sr_p4_hough_lines_take", [VP, _PF32])
_c_hough_lines_p = declare("sr_p4_hough_lines_p", IMG_ARGS + [F64, F64, I32, F64, F64, I32, PI32, ctypes.POINTER(VP)])
_c_hough_lines_p_take = declare("sr_p4_hough_lines_p_take", [VP, PI32])
_c_hough_circles = declare("sr_p4_hough_circles", IMG_ARGS + [I32, F64, F64, F64, F64, I32, I32, I32, PI32, ctypes.POINTER(VP)])
_c_hough_circles_take = declare("sr_p4_hough_circles_take", [VP, _PF32])

_c_lsd_detect = declare("sr_p4_lsd_detect", IMG_ARGS + [I32, F64, F64, F64, F64, F64, F64, I32, PI32, PI32, ctypes.POINTER(VP)])
_c_lsd_take = declare("sr_p4_lsd_take", [VP, _PF32, PF64, PF64, PF64])
_c_lsd_draw = declare("sr_p4_lsd_draw", IMG_ARGS + [_PF32, I32])
_c_lsd_compare = declare("sr_p4_lsd_compare", [I32, I32, _PF32, I32, _PF32, I32] + IMG_ARGS + [PI32])

_c_flood_fill = declare("sr_p4_flood_fill", IMG_ARGS + IMG_ARGS + [I32, I32, PF64, PF64, PF64, I32, PI32, PI32])
_c_watershed = declare("sr_p4_watershed", IMG_ARGS + IMG_ARGS)
_c_grabcut = declare("sr_p4_grabcut", IMG_ARGS + IMG_ARGS + [I32, I32, I32, I32, PF64, PF64, I32, I32])

_c_subdiv_new = declare("sr_p4_subdiv_new", [], VP)
_c_subdiv_free = declare("sr_p4_subdiv_free", [VP], None)
_c_subdiv_init = declare("sr_p4_subdiv_init", [VP, _F32, _F32, _F32, _F32])
_c_subdiv_insert = declare("sr_p4_subdiv_insert", [VP, _F32, _F32, PI32])
_c_subdiv_locate = declare("sr_p4_subdiv_locate", [VP, _F32, _F32, PI32, PI32, PI32])
_c_subdiv_nearest = declare("sr_p4_subdiv_nearest", [VP, _F32, _F32, _PF32, PI32])
_c_subdiv_edges = declare("sr_p4_subdiv_edges", [VP, PI32, ctypes.POINTER(VP)])
_c_subdiv_edges_take = declare("sr_p4_subdiv_edges_take", [VP, _PF32])
_c_subdiv_tris = declare("sr_p4_subdiv_tris", [VP, PI32, ctypes.POINTER(VP)])
_c_subdiv_tris_take = declare("sr_p4_subdiv_tris_take", [VP, _PF32])
_c_subdiv_leading = declare("sr_p4_subdiv_leading_edges", [VP, PI32, ctypes.POINTER(VP)])
_c_subdiv_leading_take = declare("sr_p4_subdiv_leading_edges_take", [VP, PI32])
_c_subdiv_voronoi = declare("sr_p4_subdiv_voronoi", [VP, PI32, I32, PI32, PI32, ctypes.POINTER(VP)])
_c_subdiv_voronoi_take = declare("sr_p4_subdiv_voronoi_take", [VP, _PF32, PI32, _PF32])
_c_subdiv_vertex = declare("sr_p4_subdiv_vertex", [VP, I32, _PF32, PI32])
_c_subdiv_get_edge = declare("sr_p4_subdiv_get_edge", [VP, I32, I32], I32)
_c_subdiv_next_edge = declare("sr_p4_subdiv_next_edge", [VP, I32], I32)
_c_subdiv_rotate_edge = declare("sr_p4_subdiv_rotate_edge", [I32, I32], I32)
_c_subdiv_sym_edge = declare("sr_p4_subdiv_sym_edge", [I32], I32)
_c_subdiv_edge_org = declare("sr_p4_subdiv_edge_org", [VP, I32, _PF32, PI32])
_c_subdiv_edge_dst = declare("sr_p4_subdiv_edge_dst", [VP, I32, _PF32, PI32])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _pts(arr, who: str, dims: int = 2, allow_empty: bool = True) -> np.ndarray:
    if isinstance(arr, np.ndarray):
        a = arr
    else:
        a = np.asarray(arr)
        if a.dtype == np.int64:
            a = a.astype(np.int32)
        elif a.dtype == np.float64:
            a = a.astype(np.float32)
    if a.size == 0:
        if not allow_empty:
            raise _lib.error(f"{who}: empty point set")
        dt = np.float32 if a.dtype == np.float32 else np.int32
        return np.empty((0, dims), dtype=dt)
    if a.dtype not in (np.dtype(np.int32), np.dtype(np.float32)):
        raise _lib.error(f"{who}: points must be int32 or float32 (got {a.dtype})")
    if a.ndim == 2 and a.shape[1] == dims:
        flat = a
    elif a.ndim == 3 and a.shape[1] == 1 and a.shape[2] == dims:
        flat = a.reshape(-1, dims)
    elif a.ndim == 3 and a.shape[0] == 1 and a.shape[2] == dims:
        flat = a.reshape(-1, dims)
    else:
        raise _lib.error(f"{who}: expected (N,{dims}) or (N,1,{dims}) points (got {a.shape})")
    return np.ascontiguousarray(flat)


def _u8_gray(image, who: str) -> np.ndarray:
    a = np.asarray(image)
    if a.ndim == 3 and a.shape[2] == 1:
        a = a[..., 0]
    if a.ndim != 2 or a.dtype != np.uint8:
        raise _lib.error(f"{who}: requires single-channel uint8 image")
    if a.size == 0:
        raise _lib.error(f"{who}: empty image")
    if a.strides[1] != 1 or a.strides[0] < a.shape[1]:
        a = np.ascontiguousarray(a)
    return a


def _rot_rect_5f(box, who: str):
    try:
        (cx, cy), (w, h), ang = box
        return (ctypes.c_float * 5)(float(cx), float(cy), float(w), float(h), float(ang))
    except Exception:
        raise _lib.error(f"{who}: box must be ((cx, cy), (w, h), angle)") from None


def _write_or_return(dst, arr: np.ndarray):
    if isinstance(dst, np.ndarray) and dst.shape == arr.shape and dst.dtype == arr.dtype and dst.flags.writeable:
        dst[...] = arr
        return dst
    return arr


_MOMENT_KEYS = (
    "m00", "m10", "m01", "m20", "m11", "m02", "m30", "m21", "m12", "m03",
    "mu20", "mu11", "mu02", "mu30", "mu21", "mu12", "mu03",
    "nu20", "nu11", "nu02", "nu30", "nu21", "nu12", "nu03",
)


# ---------------------------------------------------------------------------
# Contours & Geometry
# ---------------------------------------------------------------------------

def convexHull(points, hull=None, clockwise=False, returnPoints=True):
    p = _pts(points, "convexHull")
    n = p.shape[0]
    if n == 0:
        return None
    idx = np.empty(n, dtype=np.int32)
    k = I32(0)
    check(_c_convex_hull(p.ctypes.data, n, 1 if p.dtype == np.float32 else 0,
                         1 if clockwise else 0, idx.ctypes.data_as(PI32), ctypes.byref(k)), "convexHull")
    kk = int(k.value)
    sel = idx[:kk]
    if returnPoints:
        out = p[sel].reshape(kk, 1, 2).copy()
    else:
        out = sel.reshape(kk, 1).copy()
    return _write_or_return(hull, out)


def convexityDefects(contour, convexhull, convexityDefects=None):
    c = _pts(contour, "convexityDefects")
    if c.dtype != np.int32:
        raise _lib.error("convexityDefects: contour must be int32 points")
    h = np.asarray(convexhull)
    if h.dtype != np.int32:
        raise _lib.error("convexityDefects: convexhull must be int32 indices")
    h_flat = np.ascontiguousarray(h.reshape(-1))
    n = c.shape[0]
    hn = h_flat.shape[0]
    if n <= 3 or hn < 3:
        out = np.empty((0, 4), dtype=np.int32)
        return _write_or_return(convexityDefects, out)
    buf = np.empty((hn, 4), dtype=np.int32)
    cnt = I32(0)
    check(_c_convexity_defects(c.ctypes.data_as(PI32), n, h_flat.ctypes.data_as(PI32), hn,
                               buf.ctypes.data_as(PI32), ctypes.byref(cnt)), "convexityDefects")
    out = buf[:int(cnt.value)].copy()
    return _write_or_return(convexityDefects, out)


def isContourConvex(contour) -> bool:
    p = _pts(contour, "isContourConvex")
    res = I32(0)
    check(_c_is_convex(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0,
                       ctypes.byref(res)), "isContourConvex")
    return bool(res.value)


def contourArea(contour, oriented=False) -> float:
    p = _pts(contour, "contourArea")
    out = F64(0.0)
    check(_c_contour_area(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0,
                          1 if oriented else 0, ctypes.byref(out)), "contourArea")
    return float(out.value)


def boundingRect(array):
    a = np.asarray(array)
    if a.ndim == 2 and a.dtype == np.uint8:
        if a.size == 0:
            return (0, 0, 0, 0)
        a = a if (a.strides[1] == 1 and a.strides[0] >= a.shape[1]) else np.ascontiguousarray(a)
        xywh = (ctypes.c_int32 * 4)()
        check(_c_bounding_img(*img_args(a), xywh), "boundingRect")
        return (int(xywh[0]), int(xywh[1]), int(xywh[2]), int(xywh[3]))
    if a.ndim == 3 and a.shape[2] == 1 and a.dtype == np.uint8:
        return boundingRect(a[..., 0])
    p = _pts(array, "boundingRect")
    xywh = (ctypes.c_int32 * 4)()
    check(_c_bounding_pts(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0, xywh), "boundingRect")
    return (int(xywh[0]), int(xywh[1]), int(xywh[2]), int(xywh[3]))


def minAreaRect(points):
    p = _pts(points, "minAreaRect")
    out5 = (ctypes.c_float * 5)()
    check(_c_min_area_rect(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0, out5), "minAreaRect")
    return ((float(out5[0]), float(out5[1])), (float(out5[2]), float(out5[3])), float(out5[4]))


def boxPoints(box, points=None):
    try:
        (cx, cy), (w, h), ang = box
    except Exception:
        raise _lib.error("boxPoints: box must be ((cx, cy), (w, h), angle)") from None
    out = np.empty((4, 2), dtype=np.float32)
    check(_c_box_points(float(cx), float(cy), float(w), float(h), float(ang),
                        out.ctypes.data_as(_PF32)), "boxPoints")
    return _write_or_return(points, out)


def minEnclosingCircle(points):
    p = _pts(points, "minEnclosingCircle")
    out3 = (ctypes.c_float * 3)()
    check(_c_min_circle(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0, out3), "minEnclosingCircle")
    return ((float(out3[0]), float(out3[1])), float(out3[2]))


def minEnclosingTriangle(points, triangle=None):
    p = _pts(points, "minEnclosingTriangle")
    if p.shape[0] == 0:
        return 0.0, None
    area = F64(0.0)
    buf = np.empty((3, 2), dtype=np.float32)
    check(_c_min_tri(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0,
                     ctypes.byref(area), buf.ctypes.data_as(_PF32)), "minEnclosingTriangle")
    if isinstance(triangle, np.ndarray) and triangle.dtype == np.float32 and triangle.flags.writeable:
        if triangle.shape == (3, 1, 2):
            triangle[...] = buf.reshape(3, 1, 2)
            return float(area.value), triangle
        if triangle.shape == (3, 2):
            triangle[...] = buf
            return float(area.value), triangle
    return float(area.value), buf


def _fit_ellipse_impl(points, method: int, who: str):
    p = _pts(points, who, allow_empty=False)
    out5 = (ctypes.c_float * 5)()
    check(_c_fit_ellipse(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0, method, out5), who)
    return ((float(out5[0]), float(out5[1])), (float(out5[2]), float(out5[3])), float(out5[4]))


def fitEllipse(points):
    return _fit_ellipse_impl(points, 0, "fitEllipse")


def fitEllipseAMS(points):
    return _fit_ellipse_impl(points, 1, "fitEllipseAMS")


def fitEllipseDirect(points):
    return _fit_ellipse_impl(points, 2, "fitEllipseDirect")


def fitLine(points, distType, param, reps, aeps, line=None):
    arr = np.asarray(points)
    dims = 3 if (arr.ndim >= 2 and arr.shape[-1] == 3) else 2
    p = _pts(points, "fitLine", dims=dims, allow_empty=False)
    out = np.empty((dims * 2, 1), dtype=np.float32)
    check(_c_fit_line(p.ctypes.data, p.shape[0], dims, 1 if p.dtype == np.float32 else 0,
                      int(distType), float(param), float(reps), float(aeps),
                      out.ctypes.data_as(_PF32)), "fitLine")
    return _write_or_return(line, out)


_MOMENTS_IMG_DEPTH = {
    np.dtype(np.uint8): 0,
    np.dtype(np.uint16): 2,
    np.dtype(np.int16): 3,
    np.dtype(np.float32): 5,
    np.dtype(np.float64): 6,
}


def _moments_vec(array, binaryImage: bool) -> np.ndarray:
    a = np.asarray(array)
    out = np.zeros(24, dtype=np.float64)
    if a.size == 0:
        return out
    is_pts = (
        (a.ndim == 3 and a.shape[2] == 2 and a.dtype in (np.int32, np.float32))
        or (a.ndim == 2 and a.shape[1] == 2 and a.dtype in (np.int32, np.float32))
    )
    if is_pts:
        p = _pts(a, "moments")
        check(_c_moments_pts(p.ctypes.data, p.shape[0], 1 if p.dtype == np.float32 else 0,
                             out.ctypes.data_as(PF64)), "moments")
        return out
    if a.ndim == 3 and a.shape[2] == 1:
        a = a[..., 0]
    if a.ndim != 2 or a.dtype not in _MOMENTS_IMG_DEPTH:
        raise _lib.error(f"moments: unsupported array shape/dtype {a.shape}/{a.dtype}")
    a = np.ascontiguousarray(a) if (a.strides[1] != a.itemsize or a.strides[0] < a.shape[1] * a.itemsize) else a
    h, w = a.shape
    stride = a.strides[0] if h > 1 else w * a.itemsize
    check(_c_moments_img(a.ctypes.data, w, h, stride, 1, _MOMENTS_IMG_DEPTH[a.dtype],
                         1 if binaryImage else 0, out.ctypes.data_as(PF64)), "moments")
    return out


def moments(array, binaryImage=False) -> dict[str, float]:
    vec = _moments_vec(array, bool(binaryImage))
    return {k: float(vec[i]) for i, k in enumerate(_MOMENT_KEYS)}


def HuMoments(m, hu=None):
    if isinstance(m, dict):
        vec = np.array([float(m.get(k, 0.0)) for k in _MOMENT_KEYS], dtype=np.float64)
    else:
        arr = np.asarray(m, dtype=np.float64).ravel()
        if arr.size != 24:
            raise _lib.error("HuMoments: m must be a moments dict or 24-element array")
        vec = np.ascontiguousarray(arr)
    out = np.empty((7, 1), dtype=np.float64)
    check(_c_hu_moments(vec.ctypes.data_as(PF64), out.ctypes.data_as(PF64)), "HuMoments")
    return _write_or_return(hu, out)


def matchShapes(contour1, contour2, method, parameter) -> float:
    m1 = _moments_vec(contour1, False)
    m2 = _moments_vec(contour2, False)
    out = F64(0.0)
    check(_c_match_shapes(m1.ctypes.data_as(PF64), m2.ctypes.data_as(PF64),
                          int(method), float(parameter), ctypes.byref(out)), "matchShapes")
    return float(out.value)


def intersectConvexConvex(p1, p2, p12=None, handleNested=True):
    a1 = _pts(p1, "intersectConvexConvex").astype(np.float32, copy=False)
    a2 = _pts(p2, "intersectConvexConvex").astype(np.float32, copy=False)
    n1, n2 = a1.shape[0], a2.shape[0]
    if n1 < 3 or n2 < 3:
        return 0.0, None
    max_k = n1 + n2 * 2 + 16
    buf = np.empty((max_k, 2), dtype=np.float32)
    k = I32(0)
    area = _F32(0.0)
    check(_c_intersect_cc(a1.ctypes.data_as(_PF32), n1, a2.ctypes.data_as(_PF32), n2,
                          1 if handleNested else 0, buf.ctypes.data_as(_PF32),
                          ctypes.byref(k), ctypes.byref(area)), "intersectConvexConvex")
    kk = int(k.value)
    if kk == 0:
        return 0.0, None
    out = buf[:kk].reshape(kk, 1, 2).copy()
    if isinstance(p12, np.ndarray) and p12.shape == out.shape and p12.dtype == np.float32 and p12.flags.writeable:
        p12[...] = out
        return float(area.value), p12
    return float(area.value), out


def rotatedRectangleIntersection(rect1, rect2, intersectingRegion=None):
    r1 = _rot_rect_5f(rect1, "rotatedRectangleIntersection")
    r2 = _rot_rect_5f(rect2, "rotatedRectangleIntersection")
    buf = np.empty((32, 2), dtype=np.float32)
    k = I32(0)
    rtype = I32(0)
    check(_c_rot_rect_int(r1, r2, buf.ctypes.data_as(_PF32), ctypes.byref(k), ctypes.byref(rtype)),
          "rotatedRectangleIntersection")
    kk = int(k.value)
    tp = int(rtype.value)
    if tp == 0 or kk == 0:
        return 0, None
    out = buf[:kk].copy()
    return tp, _write_or_return(intersectingRegion, out)


# ---------------------------------------------------------------------------
# Hough & LineSegmentDetector
# ---------------------------------------------------------------------------

def HoughLines(image, rho, theta, threshold, lines=None, srn=0, stn=0, min_theta=0, max_theta=math.pi, use_edgeval=False):
    a = _u8_gray(image, "HoughLines")
    cnt = I32(0)
    handle = VP()
    check(_c_hough_lines(*img_args(a), float(rho), float(theta), int(threshold),
                         float(srn), float(stn), float(min_theta), float(max_theta),
                         1 if use_edgeval else 0, 0, ctypes.byref(cnt), ctypes.byref(handle)), "HoughLines")
    n = int(cnt.value)
    if n == 0:
        out = np.empty((0, 1, 2), dtype=np.float32)
        return _write_or_return(lines, out)
    out = np.empty((n, 1, 2), dtype=np.float32)
    check(_c_hough_lines_take(handle, out.ctypes.data_as(_PF32)), "HoughLines")
    return _write_or_return(lines, out)


def HoughLinesP(image, rho, theta, threshold, lines=None, minLineLength=0, maxLineGap=0):
    a = _u8_gray(image, "HoughLinesP")
    cnt = I32(0)
    handle = VP()
    check(_c_hough_lines_p(*img_args(a), float(rho), float(theta), int(threshold),
                           float(minLineLength), float(maxLineGap), 0,
                           ctypes.byref(cnt), ctypes.byref(handle)), "HoughLinesP")
    n = int(cnt.value)
    if n == 0:
        out = np.empty((0, 4), dtype=np.int32)
        return _write_or_return(lines, out)
    out = np.empty((n, 4), dtype=np.int32)
    check(_c_hough_lines_p_take(handle, out.ctypes.data_as(PI32)), "HoughLinesP")
    return _write_or_return(lines, out)


def HoughCircles(image, method, dp, minDist, circles=None, param1=100, param2=100, minRadius=0, maxRadius=0):
    a = _u8_gray(image, "HoughCircles")
    cnt = I32(0)
    handle = VP()
    check(_c_hough_circles(*img_args(a), int(method), float(dp), float(minDist),
                           float(param1), float(param2), int(minRadius), int(maxRadius), 0,
                           ctypes.byref(cnt), ctypes.byref(handle)), "HoughCircles")
    n = int(cnt.value)
    if n == 0:
        return None
    out = np.empty((1, n, 3), dtype=np.float32)
    check(_c_hough_circles_take(handle, out.ctypes.data_as(_PF32)), "HoughCircles")
    return _write_or_return(circles, out)


class LineSegmentDetector:
    def __init__(self, refine=1, scale=0.8, sigma_scale=0.6, quant=2.0,
                 ang_th=22.5, log_eps=0.0, density_th=0.7, n_bins=1024):
        self._refine = int(refine)
        self._scale = float(scale)
        self._sigma_scale = float(sigma_scale)
        self._quant = float(quant)
        self._ang_th = float(ang_th)
        self._log_eps = float(log_eps)
        self._density_th = float(density_th)
        self._n_bins = int(n_bins)

    def detect(self, image, lines=None, width=None, prec=None, nfa=None):
        a = _u8_gray(image, "LineSegmentDetector.detect")
        cnt = I32(0)
        has_nfa = I32(0)
        handle = VP()
        check(_c_lsd_detect(*img_args(a), self._refine, self._scale, self._sigma_scale, self._quant,
                            self._ang_th, self._log_eps, self._density_th, self._n_bins,
                            ctypes.byref(cnt), ctypes.byref(has_nfa), ctypes.byref(handle)),
              "LineSegmentDetector.detect")
        n = int(cnt.value)
        if n == 0:
            ol = np.empty((0, 4), dtype=np.float32)
            ow = np.empty((0,), dtype=np.float64)
            op = np.empty((0,), dtype=np.float64)
            on = np.empty((0,), dtype=np.float64) if self._refine == 2 else None
            return ol, ow, op, on
        ol = np.empty((n, 4), dtype=np.float32)
        ow = np.empty((n,), dtype=np.float64)
        op = np.empty((n,), dtype=np.float64)
        on = np.empty((n,), dtype=np.float64) if has_nfa.value else None
        check(_c_lsd_take(handle, ol.ctypes.data_as(_PF32), ow.ctypes.data_as(PF64),
                          op.ctypes.data_as(PF64), on.ctypes.data_as(PF64) if on is not None else None),
              "LineSegmentDetector.detect")
        return (
            _write_or_return(lines, ol),
            _write_or_return(width, ow),
            _write_or_return(prec, op),
            _write_or_return(nfa, on) if on is not None else None,
        )

    def drawSegments(self, image, lines):
        im = np.asarray(image)
        if im.dtype != np.uint8:
            raise _lib.error("LineSegmentDetector.drawSegments: image must be uint8")
        if im.ndim == 2:
            out = np.repeat(im[..., None], 3, axis=2).copy()
        elif im.ndim == 3 and im.shape[2] == 1:
            out = np.repeat(im, 3, axis=2).copy()
        elif im.ndim == 3 and im.shape[2] == 3:
            out = im if im.flags.writeable else im.copy()
        else:
            raise _lib.error("LineSegmentDetector.drawSegments: image must be 1- or 3-channel uint8")
        if not out.flags.c_contiguous:
            out_work = np.ascontiguousarray(out)
        else:
            out_work = out
        l_arr = np.ascontiguousarray(np.asarray(lines, dtype=np.float32).reshape(-1, 4)) if (lines is not None and np.asarray(lines).size > 0) else np.empty((0, 4), dtype=np.float32)
        check(_c_lsd_draw(*img_args(out_work), l_arr.ctypes.data_as(_PF32) if l_arr.size else None, l_arr.shape[0]),
              "LineSegmentDetector.drawSegments")
        if out_work is not out:
            out[...] = out_work
        return out

    def compareSegments(self, size, lines1, lines2, image=None):
        try:
            w, h = int(size[0]), int(size[1])
        except Exception:
            raise _lib.error("LineSegmentDetector.compareSegments: size must be (w, h)") from None
        if w <= 0 or h <= 0:
            raise _lib.error("LineSegmentDetector.compareSegments: size must be positive")
        l1 = np.ascontiguousarray(np.asarray(lines1, dtype=np.float32).reshape(-1, 4)) if (lines1 is not None and np.asarray(lines1).size > 0) else np.empty((0, 4), dtype=np.float32)
        l2 = np.ascontiguousarray(np.asarray(lines2, dtype=np.float32).reshape(-1, 4)) if (lines2 is not None and np.asarray(lines2).size > 0) else np.empty((0, 4), dtype=np.float32)
        if image is None:
            out = np.zeros((h, w, 3), dtype=np.uint8)
        else:
            out = np.asarray(image)
            if out.dtype != np.uint8 or out.shape != (h, w, 3):
                raise _lib.error("LineSegmentDetector.compareSegments: image must be (h, w, 3) uint8")
        work = out if (out.flags.writeable and out.flags.c_contiguous) else np.ascontiguousarray(out)
        mismatch = I32(0)
        check(_c_lsd_compare(w, h,
                             l1.ctypes.data_as(_PF32) if l1.size else None, l1.shape[0],
                             l2.ctypes.data_as(_PF32) if l2.size else None, l2.shape[0],
                             *img_args(work), ctypes.byref(mismatch)),
              "LineSegmentDetector.compareSegments")
        if work is not out and isinstance(image, np.ndarray) and image.flags.writeable:
            image[...] = work
            out = image
        else:
            out = work
        return int(mismatch.value), out


def createLineSegmentDetector(refine=1, scale=0.8, sigma_scale=0.6, quant=2.0,
                              ang_th=22.5, log_eps=0.0, density_th=0.7, n_bins=1024):
    return LineSegmentDetector(refine=refine, scale=scale, sigma_scale=sigma_scale, quant=quant,
                               ang_th=ang_th, log_eps=log_eps, density_th=density_th, n_bins=n_bins)


# ---------------------------------------------------------------------------
# Segmentation: floodFill, watershed, grabCut
# ---------------------------------------------------------------------------

def floodFill(image, mask, seedPoint, newVal, loDiff=None, upDiff=None, flags=4):
    if not isinstance(image, np.ndarray) or not image.flags.writeable:
        raise _lib.error("floodFill: image must be a writeable numpy.ndarray")
    if image.dtype not in (np.uint8, np.int32, np.float32):
        raise _lib.error(f"floodFill: unsupported image dtype {image.dtype}")
    if image.ndim not in (2, 3) or (image.ndim == 3 and image.shape[2] not in (1, 3)):
        raise _lib.error(f"floodFill: requires 1- or 3-channel image (got {image.shape})")
    h, w = image.shape[:2]
    if mask is None:
        m = np.zeros((h + 2, w + 2), dtype=np.uint8)
    else:
        if not isinstance(mask, np.ndarray) or mask.dtype != np.uint8 or mask.shape != (h + 2, w + 2) or not mask.flags.writeable:
            raise _lib.error(f"floodFill: mask must be writeable uint8 of shape {(h + 2, w + 2)}")
        m = mask
    try:
        sx, sy = int(seedPoint[0]), int(seedPoint[1])
    except Exception:
        raise _lib.error("floodFill: seedPoint must be (x, y)") from None
    nv = _lib.color4(newVal)
    lo = _lib.color4(0 if loDiff is None else loDiff)
    up = _lib.color4(0 if upDiff is None else upDiff)
    area = I32(0)
    rect4 = (ctypes.c_int32 * 4)()

    img_work = image if (image.flags.c_contiguous) else np.ascontiguousarray(image)
    m_work = m if (m.flags.c_contiguous) else np.ascontiguousarray(m)
    check(_c_flood_fill(*img_args(img_work), *img_args(m_work), sx, sy,
                        ctypes.cast(nv, PF64), ctypes.cast(lo, PF64), ctypes.cast(up, PF64),
                        int(flags), ctypes.byref(area), rect4), "floodFill")
    if img_work is not image:
        image[...] = img_work
    if m_work is not m:
        m[...] = m_work
    return int(area.value), image, m, (int(rect4[0]), int(rect4[1]), int(rect4[2]), int(rect4[3]))


def watershed(image, markers):
    im = np.asarray(image)
    if im.dtype != np.uint8 or im.ndim != 3 or im.shape[2] != 3 or im.size == 0:
        raise _lib.error("watershed: image must be non-empty 3-channel uint8")
    if not isinstance(markers, np.ndarray) or markers.dtype != np.int32 or markers.ndim != 2 or not markers.flags.writeable:
        raise _lib.error("watershed: markers must be writeable 2-D int32 array")
    if markers.shape != im.shape[:2]:
        raise _lib.error("watershed: image and markers size mismatch")
    im_work = im if im.flags.c_contiguous else np.ascontiguousarray(im)
    mk_work = markers if markers.flags.c_contiguous else np.ascontiguousarray(markers)
    check(_c_watershed(*img_args(im_work), *img_args(mk_work)), "watershed")
    if mk_work is not markers:
        markers[...] = mk_work
    return markers


def grabCut(img, mask, rect, bgdModel, fgdModel, iterCount, mode=2):
    im = np.asarray(img)
    if im.dtype != np.uint8 or im.ndim != 3 or im.shape[2] != 3 or im.size == 0:
        raise _lib.error("grabCut: img must be non-empty 3-channel uint8")
    if not isinstance(mask, np.ndarray) or mask.dtype != np.uint8 or mask.shape != im.shape[:2] or not mask.flags.writeable:
        raise _lib.error("grabCut: mask must be writeable uint8 matching image size")
    if not isinstance(bgdModel, np.ndarray) or bgdModel.dtype != np.float64 or bgdModel.size != 65 or not bgdModel.flags.writeable:
        raise _lib.error("grabCut: bgdModel must be writeable float64 with 65 elements")
    if not isinstance(fgdModel, np.ndarray) or fgdModel.dtype != np.float64 or fgdModel.size != 65 or not fgdModel.flags.writeable:
        raise _lib.error("grabCut: fgdModel must be writeable float64 with 65 elements")
    if rect is None:
        rx, ry, rw, rh = 0, 0, 0, 0
    else:
        try:
            rx, ry, rw, rh = int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3])
        except Exception:
            raise _lib.error("grabCut: rect must be (x, y, w, h)") from None

    im_work = im if im.flags.c_contiguous else np.ascontiguousarray(im)
    m_work = mask if mask.flags.c_contiguous else np.ascontiguousarray(mask)
    bg_work = bgdModel if bgdModel.flags.c_contiguous else np.ascontiguousarray(bgdModel)
    fg_work = fgdModel if fgdModel.flags.c_contiguous else np.ascontiguousarray(fgdModel)

    check(_c_grabcut(*img_args(im_work), *img_args(m_work), rx, ry, rw, rh,
                     bg_work.ctypes.data_as(PF64), fg_work.ctypes.data_as(PF64),
                     int(iterCount), int(mode)), "grabCut")
    if m_work is not mask:
        mask[...] = m_work
    if bg_work is not bgdModel:
        bgdModel[...] = bg_work
    if fg_work is not fgdModel:
        fgdModel[...] = fg_work
    return mask, bgdModel, fgdModel


# ---------------------------------------------------------------------------
# Subdiv2D
# ---------------------------------------------------------------------------

class Subdiv2D:
    def __init__(self, rect=None):
        self._ptr = _c_subdiv_new()
        if not self._ptr:
            raise _lib.error("Subdiv2D: failed to allocate")
        if rect is not None:
            self.initDelaunay(rect)

    def __del__(self):
        ptr = getattr(self, "_ptr", None)
        if ptr:
            _c_subdiv_free(ptr)
            self._ptr = None

    def initDelaunay(self, rect):
        try:
            rx, ry, rw, rh = float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3])
        except Exception:
            raise _lib.error("Subdiv2D.initDelaunay: rect must be (x, y, w, h)") from None
        check(_c_subdiv_init(self._ptr, rx, ry, rw, rh), "Subdiv2D.initDelaunay")

    def initDelaunay2f(self, rect):
        self.initDelaunay(rect)

    def insert(self, pt):
        if isinstance(pt, np.ndarray):
            arr = pt
            if arr.size == 0:
                return None
            if arr.ndim == 1 and arr.shape[0] == 2:
                vid = I32(0)
                check(_c_subdiv_insert(self._ptr, float(arr[0]), float(arr[1]), ctypes.byref(vid)), "Subdiv2D.insert")
                return int(vid.value)
            pts = _pts(arr, "Subdiv2D.insert")
            vid = I32(0)
            for row in pts:
                check(_c_subdiv_insert(self._ptr, float(row[0]), float(row[1]), ctypes.byref(vid)), "Subdiv2D.insert")
            return None
        if isinstance(pt, (list, tuple)):
            if len(pt) == 0:
                return None
            if len(pt) == 2 and not isinstance(pt[0], (list, tuple, np.ndarray)):
                vid = I32(0)
                check(_c_subdiv_insert(self._ptr, float(pt[0]), float(pt[1]), ctypes.byref(vid)), "Subdiv2D.insert")
                return int(vid.value)
            vid = I32(0)
            for item in pt:
                check(_c_subdiv_insert(self._ptr, float(item[0]), float(item[1]), ctypes.byref(vid)), "Subdiv2D.insert")
            return None
        raise _lib.error("Subdiv2D.insert: expected point (x, y) or sequence of points")

    def locate(self, pt):
        loc = I32(0)
        edge = I32(0)
        vtx = I32(0)
        check(_c_subdiv_locate(self._ptr, float(pt[0]), float(pt[1]),
                               ctypes.byref(loc), ctypes.byref(edge), ctypes.byref(vtx)), "Subdiv2D.locate")
        return int(loc.value), int(edge.value), int(vtx.value)

    def findNearest(self, pt):
        out_pt = (ctypes.c_float * 2)()
        vtx = I32(0)
        check(_c_subdiv_nearest(self._ptr, float(pt[0]), float(pt[1]), out_pt, ctypes.byref(vtx)),
              "Subdiv2D.findNearest")
        return int(vtx.value), (float(out_pt[0]), float(out_pt[1]))

    def getEdgeList(self):
        cnt = I32(0)
        handle = VP()
        check(_c_subdiv_edges(self._ptr, ctypes.byref(cnt), ctypes.byref(handle)), "Subdiv2D.getEdgeList")
        n = int(cnt.value)
        if n == 0:
            return ()
        out = np.empty((n, 4), dtype=np.float32)
        check(_c_subdiv_edges_take(handle, out.ctypes.data_as(_PF32)), "Subdiv2D.getEdgeList")
        return out

    def getTriangleList(self):
        cnt = I32(0)
        handle = VP()
        check(_c_subdiv_tris(self._ptr, ctypes.byref(cnt), ctypes.byref(handle)), "Subdiv2D.getTriangleList")
        n = int(cnt.value)
        if n == 0:
            return ()
        out = np.empty((n, 6), dtype=np.float32)
        check(_c_subdiv_tris_take(handle, out.ctypes.data_as(_PF32)), "Subdiv2D.getTriangleList")
        return out

    def getLeadingEdgeList(self):
        cnt = I32(0)
        handle = VP()
        check(_c_subdiv_leading(self._ptr, ctypes.byref(cnt), ctypes.byref(handle)), "Subdiv2D.getLeadingEdgeList")
        n = int(cnt.value)
        if n == 0:
            return ()
        out = np.empty((n,), dtype=np.int32)
        check(_c_subdiv_leading_take(handle, out.ctypes.data_as(PI32)), "Subdiv2D.getLeadingEdgeList")
        return out

    def getVoronoiFacetList(self, idx):
        idx_arr = np.ascontiguousarray(np.asarray(idx, dtype=np.int32).reshape(-1)) if (idx is not None and len(idx) > 0) else np.empty((0,), dtype=np.int32)
        nf = I32(0)
        total_pts = I32(0)
        handle = VP()
        check(_c_subdiv_voronoi(self._ptr, idx_arr.ctypes.data_as(PI32) if idx_arr.size else None,
                                idx_arr.size, ctypes.byref(nf), ctypes.byref(total_pts), ctypes.byref(handle)),
              "Subdiv2D.getVoronoiFacetList")
        n = int(nf.value)
        tp = int(total_pts.value)
        if n == 0:
            return (), ()
        pts = np.empty((max(tp, 1), 2), dtype=np.float32)
        counts = np.empty((n,), dtype=np.int32)
        centers = np.empty((n, 2), dtype=np.float32)
        check(_c_subdiv_voronoi_take(handle, pts.ctypes.data_as(_PF32), counts.ctypes.data_as(PI32),
                                     centers.ctypes.data_as(_PF32)), "Subdiv2D.getVoronoiFacetList")
        facets = []
        pos = 0
        for c in counts.tolist():
            facets.append(pts[pos:pos + c].copy())
            pos += c
        return facets, centers

    def getVertex(self, vertex):
        out_pt = (ctypes.c_float * 2)()
        first_edge = I32(0)
        check(_c_subdiv_vertex(self._ptr, int(vertex), out_pt, ctypes.byref(first_edge)), "Subdiv2D.getVertex")
        return (float(out_pt[0]), float(out_pt[1])), int(first_edge.value)

    def getEdge(self, edge, nextEdgeType):
        return int(_c_subdiv_get_edge(self._ptr, int(edge), int(nextEdgeType)))

    def nextEdge(self, edge):
        return int(_c_subdiv_next_edge(self._ptr, int(edge)))

    def rotateEdge(self, edge, rotate):
        return int(_c_subdiv_rotate_edge(int(edge), int(rotate)))

    def symEdge(self, edge):
        return int(_c_subdiv_sym_edge(int(edge)))

    def edgeOrg(self, edge):
        out_pt = (ctypes.c_float * 2)()
        vtx = I32(0)
        check(_c_subdiv_edge_org(self._ptr, int(edge), out_pt, ctypes.byref(vtx)), "Subdiv2D.edgeOrg")
        return int(vtx.value), (float(out_pt[0]), float(out_pt[1]))

    def edgeDst(self, edge):
        out_pt = (ctypes.c_float * 2)()
        vtx = I32(0)
        check(_c_subdiv_edge_dst(self._ptr, int(edge), out_pt, ctypes.byref(vtx)), "Subdiv2D.edgeDst")
        return int(vtx.value), (float(out_pt[0]), float(out_pt[1]))
