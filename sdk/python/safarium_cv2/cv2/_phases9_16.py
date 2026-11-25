"""Phases 9–16 & Popular Contrib for safarium_cv2:
- Phase 9  (features2d): Harris, Shi-Tomasi, GFTT, CornerSubPix, FAST, ORB, BFMatcher, drawKeypoints/Matches
- Phase 10 (video):      PyrLK, Farneback, PhaseCorrelate (vDSP 2D FFT), MOG2, MeanShift, CamShift, ECC
- Phase 11 (calib3d):    findHomography, perspectiveTransform, Rodrigues, projectPoints, solvePnP,
                         initUndistortRectifyMap, undistort, undistortPoints, StereoBM
- Phase 12 (objdetect):  QRCodeDetector & barcode.BarcodeDetector (Apple Vision), aruco
- Phase 13 (dnn):        blobFromImage(s), NMSBoxes, CoreML Net / readNet
- Phase 14 (3d):         readPLY, writePLY, computeNormals, voxelDownsample
- Phase 15 (stitching/flann/ccm): Stitcher_create, flann.Index, ccm.ColorCorrectionModel
- Phase 16 & contrib:    FileStorage (JSON/YAML/XML), TickMeter, ximgproc, xphoto, TrackerCSRT
"""
from __future__ import annotations

import ctypes
import json
import math
import os
import struct
import time
import types
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np

from . import _lib, _ops
from ._lib import CSTR, F64, I32, IMG_ARGS, PF64, PI32, PU8, VP, check, declare, error, img_args

_F32 = ctypes.c_float
_PF32 = ctypes.POINTER(ctypes.c_float)
_PI16 = ctypes.POINTER(ctypes.c_int16)
_PCHAR = ctypes.POINTER(ctypes.c_char)

# --------------------------------------------------------------------------- Constants

# Norms
NORM_L1 = 2
NORM_L2 = 4
NORM_HAMMING = 6
NORM_HAMMING2 = 7

# Termination criteria
TERM_CRITERIA_COUNT = 1
TERM_CRITERIA_MAX_ITER = 1
TERM_CRITERIA_EPS = 2

# Optical flow / ECC motion models
OPTFLOW_USE_INITIAL_FLOW = 4
MOTION_TRANSLATION = 0
MOTION_EUCLIDEAN = 1
MOTION_AFFINE = 2
MOTION_HOMOGRAPHY = 3

# Robust estimators
LMEDS = 4
RANSAC = 8
RHO = 16

# FileStorage modes
FILE_STORAGE_READ = 0
FILE_STORAGE_WRITE = 1
FILE_STORAGE_APPEND = 2
FILE_STORAGE_MEMORY = 4

# Stitcher status & modes
STITCHER_OK = 0
STITCHER_ERR_NEED_MORE_IMGS = 1
STITCHER_ERR_HOMOGRAPHY_EST_FAIL = 2
Stitcher_PANORAMA = 0
Stitcher_SCANS = 1

# --------------------------------------------------------------------------- C-ABI declarations

# Phase 9
_c_corner_harris = declare("sr_corner_harris", IMG_ARGS + IMG_ARGS + [I32, I32, F64, I32])
_c_corner_min_eig = declare("sr_corner_min_eigen_val", IMG_ARGS + IMG_ARGS + [I32, I32, I32])
_c_gftt = declare("sr_good_features_to_track", IMG_ARGS + IMG_ARGS + [I32, F64, F64, I32, I32, F64, _PF32, I32, PI32])
_c_corner_subpix = declare("sr_corner_sub_pix", IMG_ARGS + [_PF32, I32, I32, I32, I32, I32, I32, F64])
_c_fast = declare("sr_fast_detect", IMG_ARGS + [I32, I32, _PF32, I32, PI32])
_c_orb = declare("sr_orb_detect_compute", IMG_ARGS + [I32, _F32, I32, I32, I32, _PF32, PU8, I32, PI32])
_c_bf_match = declare("sr_bf_match", [VP, I32, VP, I32, I32, I32, I32, I32, PI32, PI32, _PF32, I32, PI32])

# Phase 10
_c_pyr_lk = declare(
    "sr_calc_optical_flow_pyr_lk",
    IMG_ARGS + IMG_ARGS + [_PF32, I32, _PF32, PU8, _PF32, I32, I32, I32, I32, F64, I32],
)
_c_farneback = declare(
    "sr_calc_optical_flow_farneback",
    IMG_ARGS * 3 + [F64, I32, I32, I32, I32, F64],
)
_c_phase_corr = declare("sr_phase_correlate", IMG_ARGS * 3 + [PF64, PF64, PF64])
_c_mog2_create = declare("sr_mog2_create", [I32, F64, I32], restype=VP)
_c_mog2_apply = declare("sr_mog2_apply", [VP] + IMG_ARGS + IMG_ARGS + [F64])
_c_mog2_free = declare("sr_mog2_free", [VP])
_c_mean_shift = declare(
    "sr_mean_shift",
    IMG_ARGS + [PI32, PI32, PI32, PI32, I32, F64, PI32, PF64, PF64, PF64, PF64, PF64, PF64],
)
_c_ecc = declare("sr_find_transform_ecc", IMG_ARGS + IMG_ARGS + [_PF32, I32, I32, F64, PF64])

# Phase 11
_c_find_homography = declare("sr_find_homography", [PF64, PF64, I32, I32, F64, I32, F64, PF64, PU8])
_c_rodrigues = declare("sr_rodrigues", [PF64, I32, PF64, PF64])
_c_project_points = declare("sr_project_points", [PF64, I32, PF64, PF64, PF64, PF64, I32, PF64])
_c_solve_pnp = declare("sr_solve_pnp", [PF64, PF64, I32, PF64, PF64, I32, I32, PF64, PF64])
_c_init_undistort_map = declare("sr_init_undistort_rectify_map", [PF64, PF64, I32, PF64, PF64, I32, I32, _PF32, _PF32])
_c_stereo_bm = declare("sr_stereo_bm", IMG_ARGS + IMG_ARGS + [_PI16, I32, I32, I32, I32])

# Phase 12
_c_qr_detect = declare("sr_qr_detect_decode", IMG_ARGS + [_PF32, _PCHAR, I32, PI32, PI32, I32, PI32])
_c_barcode_detect = declare(
    "sr_barcode_detect",
    IMG_ARGS + [_PF32, _PCHAR, I32, PI32, PI32, _PCHAR, I32, PI32, PI32, I32, PI32],
)
_c_aruco_gen = declare("sr_aruco_generate_marker", [I32, I32, I32, I32] + IMG_ARGS)
_c_aruco_det = declare("sr_aruco_detect_markers", IMG_ARGS + [I32, _PF32, PI32, I32, PI32])

# Phase 13
_c_nms_boxes = declare("sr_dnn_nms_boxes", [_PF32, _PF32, I32, _F32, _F32, PI32, PI32])
_c_coreml_load = declare("sr_coreml_load", [CSTR], restype=VP)
_c_coreml_infer = declare("sr_coreml_infer_f32", [VP, CSTR, _PF32, PI32, I32, CSTR, _PF32, I32, PI32, PI32, PI32])
_c_coreml_free = declare("sr_coreml_free", [VP])

# Phase 16 & contrib
_c_guided_filter = declare("sr_ximgproc_guided_filter", IMG_ARGS * 3 + [I32, F64])
_c_thinning = declare("sr_ximgproc_thinning", IMG_ARGS * 2 + [I32])
_c_simple_wb = declare("sr_xphoto_simple_wb", IMG_ARGS * 2 + [_F32, _F32, _F32, _F32, _F32])
_c_grayworld_wb = declare("sr_xphoto_grayworld_wb", IMG_ARGS * 2 + [_F32])
_c_oil_painting = declare("sr_xphoto_oil_painting", IMG_ARGS * 2 + [I32, I32])


# --------------------------------------------------------------------------- Helpers

_NULL_IMG = [None, 0, 0, 0, 0, 0]


def _as_img(a, dtype=None) -> np.ndarray:
    arr = np.asarray(a)
    if dtype is not None and arr.dtype != dtype:
        arr = arr.astype(dtype, copy=False)
    if arr.dtype not in (np.uint8, np.uint16, np.int32, np.float32):
        arr = arr.astype(np.float32)
    return np.ascontiguousarray(arr)


def _as_u8(a) -> np.ndarray:
    arr = np.asarray(a)
    if arr.dtype != np.uint8:
        arr = np.clip(np.rint(arr), 0, 255).astype(np.uint8)
    return np.ascontiguousarray(arr)


def _parse_criteria(criteria, default_iter=30, default_eps=0.01):
    if criteria is None:
        return default_iter, default_eps
    _, max_iter, eps = criteria
    return max(1, int(max_iter)), float(eps)


# ===========================================================================
# PHASE 9: Features2D
# ===========================================================================

class KeyPoint:
    __slots__ = ("pt", "size", "angle", "response", "octave", "class_id")

    def __init__(self, x: float = 0.0, y: float = 0.0, size: float = 0.0,
                 angle: float = -1.0, response: float = 0.0, octave: int = 0, class_id: int = -1):
        self.pt = (float(x), float(y))
        self.size = float(size)
        self.angle = float(angle)
        self.response = float(response)
        self.octave = int(octave)
        self.class_id = int(class_id)

    def __repr__(self) -> str:
        return f"KeyPoint(pt={self.pt}, size={self.size:.2f}, angle={self.angle:.1f}, response={self.response:.4g})"


class DMatch:
    __slots__ = ("queryIdx", "trainIdx", "imgIdx", "distance")

    def __init__(self, queryIdx: int = -1, trainIdx: int = -1, imgIdx: int = 0, distance: float = 0.0):
        self.queryIdx = int(queryIdx)
        self.trainIdx = int(trainIdx)
        self.imgIdx = int(imgIdx)
        self.distance = float(distance)

    def __repr__(self) -> str:
        return f"DMatch(queryIdx={self.queryIdx}, trainIdx={self.trainIdx}, distance={self.distance:.3f})"


def cornerHarris(src, blockSize: int, ksize: int, k: float, dst=None, borderType: int = 4) -> np.ndarray:
    s = _as_img(src)
    h, w = s.shape[:2]
    out = np.empty((h, w), dtype=np.float32) if dst is None else dst
    check(_c_corner_harris(*img_args(s), *img_args(out), int(blockSize), int(ksize), float(k), int(borderType)), "cornerHarris")
    return out


def cornerMinEigenVal(src, blockSize: int, ksize: int = 3, dst=None, borderType: int = 4) -> np.ndarray:
    s = _as_img(src)
    h, w = s.shape[:2]
    out = np.empty((h, w), dtype=np.float32) if dst is None else dst
    check(_c_corner_min_eig(*img_args(s), *img_args(out), int(blockSize), int(ksize), int(borderType)), "cornerMinEigenVal")
    return out


def goodFeaturesToTrack(image, maxCorners: int, qualityLevel: float, minDistance: float,
                        corners=None, mask=None, blockSize: int = 3,
                        useHarrisDetector: bool = False, k: float = 0.04):
    s = _as_img(image)
    h, w = s.shape[:2]
    m_args = img_args(_as_u8(mask)) if mask is not None else _NULL_IMG
    cap = max(int(maxCorners), 4096) if int(maxCorners) > 0 else max(1024, (h * w) // 4)
    buf = np.empty((cap, 2), dtype=np.float32)
    cnt = ctypes.c_int32(0)
    check(
        _c_gftt(
            *img_args(s), *m_args,
            int(maxCorners), float(qualityLevel), float(minDistance),
            int(blockSize), 1 if useHarrisDetector else 0, float(k),
            buf.ctypes.data_as(_PF32), cap, ctypes.byref(cnt),
        ),
        "goodFeaturesToTrack",
    )
    n = cnt.value
    if n == 0:
        return None
    return buf[:n].reshape(n, 1, 2).copy()


def cornerSubPix(image, corners, winSize, zeroZone, criteria) -> np.ndarray:
    s = _as_img(image)
    orig = np.asarray(corners)
    pts = np.ascontiguousarray(orig.reshape(-1, 2), dtype=np.float32)
    max_iter, eps = _parse_criteria(criteria, 30, 0.01)
    check(
        _c_corner_subpix(
            *img_args(s), pts.ctypes.data_as(_PF32), pts.shape[0],
            int(winSize[0]), int(winSize[1]), int(zeroZone[0]), int(zeroZone[1]),
            max_iter, eps,
        ),
        "cornerSubPix",
    )
    refined = pts.reshape(orig.shape)
    if isinstance(corners, np.ndarray) and corners.dtype == np.float32 and corners.flags.writeable:
        corners[...] = refined
        return corners
    return refined


class FastFeatureDetector:
    def __init__(self, threshold: int = 10, nonmaxSuppression: bool = True, type: int = 2):
        self._threshold = int(threshold)
        self._nms = bool(nonmaxSuppression)
        self._type = int(type)

    def getThreshold(self) -> int:
        return self._threshold

    def setThreshold(self, threshold: int) -> None:
        self._threshold = int(threshold)

    def getNonmaxSuppression(self) -> bool:
        return self._nms

    def setNonmaxSuppression(self, f: bool) -> None:
        self._nms = bool(f)

    def detect(self, image, mask=None) -> list[KeyPoint]:
        s = _as_u8(image)
        h, w = s.shape[:2]
        cap = max(2048, (h * w) // 2)
        buf = np.empty((cap, 3), dtype=np.float32)
        cnt = ctypes.c_int32(0)
        check(
            _c_fast(*img_args(s), self._threshold, 1 if self._nms else 0, buf.ctypes.data_as(_PF32), cap, ctypes.byref(cnt)),
            "FastFeatureDetector.detect",
        )
        m = _as_u8(mask) if mask is not None else None
        kps = []
        for i in range(cnt.value):
            x, y, score = float(buf[i, 0]), float(buf[i, 1]), float(buf[i, 2])
            if m is not None and m[int(y), int(x)] == 0:
                continue
            kps.append(KeyPoint(x, y, size=7.0, angle=-1.0, response=score, octave=0))
        return kps


def FastFeatureDetector_create(threshold: int = 10, nonmaxSuppression: bool = True, type: int = 2) -> FastFeatureDetector:
    return FastFeatureDetector(threshold=threshold, nonmaxSuppression=nonmaxSuppression, type=type)


class ORB:
    def __init__(self, nfeatures: int = 500, scaleFactor: float = 1.2, nlevels: int = 8,
                 edgeThreshold: int = 31, firstLevel: int = 0, WTA_K: int = 2,
                 scoreType: int = 0, patchSize: int = 31, fastThreshold: int = 20):
        self._nfeatures = int(nfeatures)
        self._scaleFactor = float(scaleFactor)
        self._nlevels = int(nlevels)
        self._edgeThreshold = int(edgeThreshold)
        self._firstLevel = int(firstLevel)
        self._WTA_K = int(WTA_K)
        self._scoreType = int(scoreType)
        self._patchSize = int(patchSize)
        self._fastThreshold = int(fastThreshold)

    def detectAndCompute(self, image, mask=None):
        s = _as_u8(image)
        cap = max(16, self._nfeatures)
        kbuf = np.empty((cap, 6), dtype=np.float32)
        dbuf = np.empty((cap, 32), dtype=np.uint8)
        cnt = ctypes.c_int32(0)
        check(
            _c_orb(
                *img_args(s),
                self._nfeatures, self._scaleFactor, self._nlevels, self._edgeThreshold, self._fastThreshold,
                kbuf.ctypes.data_as(_PF32), dbuf.ctypes.data_as(PU8), cap, ctypes.byref(cnt),
            ),
            "ORB.detectAndCompute",
        )
        n = cnt.value
        if n == 0:
            return [], None
        m = _as_u8(mask) if mask is not None else None
        kps = []
        keep_idx = []
        for i in range(n):
            x, y = float(kbuf[i, 0]), float(kbuf[i, 1])
            if m is not None:
                iy = max(0, min(m.shape[0] - 1, int(round(y))))
                ix = max(0, min(m.shape[1] - 1, int(round(x))))
                if m[iy, ix] == 0:
                    continue
            kps.append(KeyPoint(x, y, float(kbuf[i, 2]), float(kbuf[i, 3]), float(kbuf[i, 4]), int(kbuf[i, 5])))
            keep_idx.append(i)
        if not kps:
            return [], None
        desc = np.ascontiguousarray(dbuf[keep_idx])
        return kps, desc

    def detect(self, image, mask=None) -> list[KeyPoint]:
        kps, _ = self.detectAndCompute(image, mask=mask)
        return kps


def ORB_create(nfeatures: int = 500, scaleFactor: float = 1.2, nlevels: int = 8,
               edgeThreshold: int = 31, firstLevel: int = 0, WTA_K: int = 2,
               scoreType: int = 0, patchSize: int = 31, fastThreshold: int = 20) -> ORB:
    return ORB(nfeatures, scaleFactor, nlevels, edgeThreshold, firstLevel, WTA_K, scoreType, patchSize, fastThreshold)


class BFMatcher:
    def __init__(self, normType: int = NORM_L2, crossCheck: bool = False):
        self._normType = int(normType)
        self._crossCheck = bool(crossCheck)

    def _prep(self, d1, d2):
        if d1 is None or d2 is None or len(d1) == 0 or len(d2) == 0:
            return None, None
        a1 = np.asarray(d1)
        a2 = np.asarray(d2)
        if a1.ndim == 1:
            a1 = a1.reshape(-1, 1)
        if a2.ndim == 1:
            a2 = a2.reshape(-1, 1)
        if self._normType in (NORM_HAMMING, NORM_HAMMING2):
            a1 = np.ascontiguousarray(a1, dtype=np.uint8)
            a2 = np.ascontiguousarray(a2, dtype=np.uint8)
        else:
            a1 = np.ascontiguousarray(a1, dtype=np.float32)
            a2 = np.ascontiguousarray(a2, dtype=np.float32)
        if a1.shape[1] != a2.shape[1]:
            raise error("BFMatcher: descriptor column counts do not match")
        return a1, a2

    def match(self, queryDescriptors, trainDescriptors) -> list[DMatch]:
        a1, a2 = self._prep(queryDescriptors, trainDescriptors)
        if a1 is None:
            return []
        cap = a1.shape[0]
        q_idx = np.empty(cap, dtype=np.int32)
        t_idx = np.empty(cap, dtype=np.int32)
        dists = np.empty(cap, dtype=np.float32)
        cnt = ctypes.c_int32(0)
        check(
            _c_bf_match(
                a1.ctypes.data, a1.shape[0], a2.ctypes.data, a2.shape[0], a1.shape[1],
                self._normType, 1, 1 if self._crossCheck else 0,
                q_idx.ctypes.data_as(PI32), t_idx.ctypes.data_as(PI32), dists.ctypes.data_as(_PF32),
                cap, ctypes.byref(cnt),
            ),
            "BFMatcher.match",
        )
        matches = [DMatch(int(q_idx[i]), int(t_idx[i]), 0, float(dists[i])) for i in range(cnt.value)]
        matches.sort(key=lambda m: m.distance)
        return matches

    def knnMatch(self, queryDescriptors, trainDescriptors, k: int = 2) -> list[list[DMatch]]:
        a1, a2 = self._prep(queryDescriptors, trainDescriptors)
        if a1 is None:
            return []
        k = max(1, int(k))
        actual_k = min(k, a2.shape[0])
        cap = a1.shape[0] * actual_k
        q_idx = np.empty(cap, dtype=np.int32)
        t_idx = np.empty(cap, dtype=np.int32)
        dists = np.empty(cap, dtype=np.float32)
        cnt = ctypes.c_int32(0)
        check(
            _c_bf_match(
                a1.ctypes.data, a1.shape[0], a2.ctypes.data, a2.shape[0], a1.shape[1],
                self._normType, actual_k, 0,
                q_idx.ctypes.data_as(PI32), t_idx.ctypes.data_as(PI32), dists.ctypes.data_as(_PF32),
                cap, ctypes.byref(cnt),
            ),
            "BFMatcher.knnMatch",
        )
        grouped: list[list[DMatch]] = [[] for _ in range(a1.shape[0])]
        for i in range(cnt.value):
            qi = int(q_idx[i])
            grouped[qi].append(DMatch(qi, int(t_idx[i]), 0, float(dists[i])))
        return grouped


def BFMatcher_create(normType: int = NORM_L2, crossCheck: bool = False) -> BFMatcher:
    return BFMatcher(normType=normType, crossCheck=crossCheck)


def _draw_circle_np(canvas: np.ndarray, cx: int, cy: int, radius: int, color: tuple[int, int, int]) -> None:
    h, w = canvas.shape[:2]
    r = max(1, int(radius))
    y0, y1 = max(0, cy - r), min(h - 1, cy + r)
    x0, x1 = max(0, cx - r), min(w - 1, cx + r)
    if x0 > x1 or y0 > y1:
        return
    yy, xx = np.ogrid[y0:y1 + 1, x0:x1 + 1]
    dist2 = (xx - cx) ** 2 + (yy - cy) ** 2
    ring = (dist2 <= r * r) & (dist2 >= max(0, (r - 1)) ** 2)
    canvas[y0:y1 + 1, x0:x1 + 1][ring] = color


def _draw_line_np(canvas: np.ndarray, x0: int, y0: int, x1: int, y1: int, color: tuple[int, int, int]) -> None:
    h, w = canvas.shape[:2]
    steps = max(abs(x1 - x0), abs(y1 - y0), 1)
    xs = np.rint(np.linspace(x0, x1, steps + 1)).astype(np.int32)
    ys = np.rint(np.linspace(y0, y1, steps + 1)).astype(np.int32)
    valid = (xs >= 0) & (xs < w) & (ys >= 0) & (ys < h)
    canvas[ys[valid], xs[valid]] = color


def drawKeypoints(image, keypoints, outImage=None, color=None, flags: int = 0) -> np.ndarray:
    src = _as_u8(image)
    if src.ndim == 2:
        canvas = np.stack([src, src, src], axis=-1)
    else:
        canvas = src[:, :, :3].copy()
    col = (0, 255, 0) if (color is None or color == (-1, -1, -1, -1)) else tuple(int(c) for c in color[:3])
    for kp in keypoints:
        cx, cy = int(round(kp.pt[0])), int(round(kp.pt[1]))
        rad = max(3, int(round(kp.size * 0.5))) if (flags & 4) else 3
        _draw_circle_np(canvas, cx, cy, rad, col)
        if (flags & 4) and kp.angle >= 0:
            ang = math.radians(kp.angle)
            _draw_line_np(canvas, cx, cy, int(round(cx + rad * math.cos(ang))), int(round(cy + rad * math.sin(ang))), col)
    if outImage is not None and isinstance(outImage, np.ndarray) and outImage.shape == canvas.shape:
        outImage[...] = canvas
        return outImage
    return canvas


def drawMatches(img1, keypoints1, img2, keypoints2, matches1to2, outImg=None,
                matchColor=None, singlePointColor=None, matchesMask=None, flags: int = 0) -> np.ndarray:
    a = _as_u8(img1)
    b = _as_u8(img2)
    if a.ndim == 2:
        a = np.stack([a, a, a], axis=-1)
    if b.ndim == 2:
        b = np.stack([b, b, b], axis=-1)
    h = max(a.shape[0], b.shape[0])
    w1, w2 = a.shape[1], b.shape[1]
    canvas = np.zeros((h, w1 + w2, 3), dtype=np.uint8)
    canvas[:a.shape[0], :w1] = a[:, :, :3]
    canvas[:b.shape[0], w1:w1 + w2] = b[:, :, :3]
    mcol = (0, 255, 0) if matchColor is None else tuple(int(c) for c in matchColor[:3])
    scol = (255, 0, 0) if singlePointColor is None else tuple(int(c) for c in singlePointColor[:3])
    if not (flags & 2):
        for kp in keypoints1:
            _draw_circle_np(canvas, int(round(kp.pt[0])), int(round(kp.pt[1])), 3, scol)
        for kp in keypoints2:
            _draw_circle_np(canvas, w1 + int(round(kp.pt[0])), int(round(kp.pt[1])), 3, scol)
    for i, m in enumerate(matches1to2):
        if matchesMask is not None and not matchesMask[i]:
            continue
        p1 = keypoints1[m.queryIdx].pt
        p2 = keypoints2[m.trainIdx].pt
        x0, y0 = int(round(p1[0])), int(round(p1[1]))
        x1, y1 = w1 + int(round(p2[0])), int(round(p2[1]))
        _draw_circle_np(canvas, x0, y0, 3, mcol)
        _draw_circle_np(canvas, x1, y1, 3, mcol)
        _draw_line_np(canvas, x0, y0, x1, y1, mcol)
    if outImg is not None and isinstance(outImg, np.ndarray) and outImg.shape == canvas.shape:
        outImg[...] = canvas
        return outImg
    return canvas


# ===========================================================================
# PHASE 10: Video Analysis
# ===========================================================================

def calcOpticalFlowPyrLK(prevImg, nextImg, prevPts, nextPts=None, status=None, err=None,
                         winSize=(21, 21), maxLevel: int = 3,
                         criteria=(TERM_CRITERIA_EPS | TERM_CRITERIA_COUNT, 30, 0.01),
                         flags: int = 0, minEigThreshold: float = 1e-4):
    p_img = _as_img(prevImg)
    n_img = _as_img(nextImg)
    orig_pts = np.asarray(prevPts, dtype=np.float32)
    pts_in = np.ascontiguousarray(orig_pts.reshape(-1, 2), dtype=np.float32)
    n = pts_in.shape[0]
    use_init = 1 if (flags & OPTFLOW_USE_INITIAL_FLOW) and nextPts is not None else 0
    if use_init:
        pts_out = np.ascontiguousarray(np.asarray(nextPts, dtype=np.float32).reshape(n, 2)).copy()
    else:
        pts_out = np.zeros((n, 2), dtype=np.float32)
    st_out = np.zeros(n, dtype=np.uint8)
    err_out = np.zeros(n, dtype=np.float32)
    max_iter, eps = _parse_criteria(criteria, 30, 0.01)
    check(
        _c_pyr_lk(
            *img_args(p_img), *img_args(n_img),
            pts_in.ctypes.data_as(_PF32), n,
            pts_out.ctypes.data_as(_PF32), st_out.ctypes.data_as(PU8), err_out.ctypes.data_as(_PF32),
            int(winSize[0]), int(winSize[1]), int(maxLevel), max_iter, eps, use_init,
        ),
        "calcOpticalFlowPyrLK",
    )
    return pts_out.reshape(orig_pts.shape), st_out.reshape(n, 1), err_out.reshape(n, 1)


def calcOpticalFlowFarneback(prev, next, flow, pyr_scale: float, levels: int, winsize: int,
                             iterations: int, poly_n: int, poly_sigma: float, flags: int = 0) -> np.ndarray:
    p = _as_img(prev)
    n = _as_img(next)
    h, w = p.shape[:2]
    out = np.zeros((h, w, 2), dtype=np.float32) if flow is None else np.ascontiguousarray(flow, dtype=np.float32)
    check(
        _c_farneback(
            *img_args(p), *img_args(n), *img_args(out),
            float(pyr_scale), int(levels), int(winsize), int(iterations), int(poly_n), float(poly_sigma),
        ),
        "calcOpticalFlowFarneback",
    )
    return out


def phaseCorrelate(src1, src2, window=None):
    s1 = _as_img(src1)
    s2 = _as_img(src2)
    w_args = img_args(_as_img(window, dtype=np.float32)) if window is not None else _NULL_IMG
    sx = ctypes.c_double(0.0)
    sy = ctypes.c_double(0.0)
    resp = ctypes.c_double(0.0)
    check(
        _c_phase_corr(*img_args(s1), *img_args(s2), *w_args, ctypes.byref(sx), ctypes.byref(sy), ctypes.byref(resp)),
        "phaseCorrelate",
    )
    return (float(sx.value), float(sy.value)), float(resp.value)


class BackgroundSubtractorMOG2:
    def __init__(self, history: int = 500, varThreshold: float = 16.0, detectShadows: bool = True):
        self._handle = _c_mog2_create(int(history), float(varThreshold), 1 if detectShadows else 0)
        if not self._handle:
            raise error("createBackgroundSubtractorMOG2: allocation failed")

    def apply(self, image, fgmask=None, learningRate: float = -1.0) -> np.ndarray:
        s = _as_u8(image)
        h, w = s.shape[:2]
        out = np.empty((h, w), dtype=np.uint8) if fgmask is None else fgmask
        check(_c_mog2_apply(self._handle, *img_args(s), *img_args(out), float(learningRate)), "BackgroundSubtractorMOG2.apply")
        return out

    def __del__(self):
        h = getattr(self, "_handle", None)
        if h:
            self._handle = None
            try:
                _c_mog2_free(h)
            except Exception:
                pass


def createBackgroundSubtractorMOG2(history: int = 500, varThreshold: float = 16.0,
                                   detectShadows: bool = True) -> BackgroundSubtractorMOG2:
    return BackgroundSubtractorMOG2(history=history, varThreshold=varThreshold, detectShadows=detectShadows)


def meanShift(probImage, window, criteria):
    prob = _as_img(probImage)
    wx = ctypes.c_int32(int(window[0]))
    wy = ctypes.c_int32(int(window[1]))
    ww = ctypes.c_int32(int(window[2]))
    wh = ctypes.c_int32(int(window[3]))
    iters = ctypes.c_int32(0)
    max_iter, eps = _parse_criteria(criteria, 10, 1.0)
    check(
        _c_mean_shift(
            *img_args(prob), ctypes.byref(wx), ctypes.byref(wy), ctypes.byref(ww), ctypes.byref(wh),
            max_iter, eps, ctypes.byref(iters), None, None, None, None, None, None,
        ),
        "meanShift",
    )
    return int(iters.value), (int(wx.value), int(wy.value), int(ww.value), int(wh.value))


def CamShift(probImage, window, criteria):
    prob = _as_img(probImage)
    wx = ctypes.c_int32(int(window[0]))
    wy = ctypes.c_int32(int(window[1]))
    ww = ctypes.c_int32(int(window[2]))
    wh = ctypes.c_int32(int(window[3]))
    iters = ctypes.c_int32(0)
    m00 = ctypes.c_double(0.0)
    m10 = ctypes.c_double(0.0)
    m01 = ctypes.c_double(0.0)
    m20 = ctypes.c_double(0.0)
    m11 = ctypes.c_double(0.0)
    m02 = ctypes.c_double(0.0)
    max_iter, eps = _parse_criteria(criteria, 10, 1.0)
    check(
        _c_mean_shift(
            *img_args(prob), ctypes.byref(wx), ctypes.byref(wy), ctypes.byref(ww), ctypes.byref(wh),
            max_iter, eps, ctypes.byref(iters),
            ctypes.byref(m00), ctypes.byref(m10), ctypes.byref(m01),
            ctypes.byref(m20), ctypes.byref(m11), ctypes.byref(m02),
        ),
        "CamShift",
    )
    rx, ry, rw, rh = int(wx.value), int(wy.value), int(ww.value), int(wh.value)
    if m00.value <= 1e-9:
        return ((float(rx + rw * 0.5), float(ry + rh * 0.5)), (float(rw), float(rh)), 0.0), (rx, ry, rw, rh)
    inv_m00 = 1.0 / m00.value
    xc = m10.value * inv_m00
    yc = m01.value * inv_m00
    mu20 = max(0.0, m20.value * inv_m00 - xc * xc)
    mu02 = max(0.0, m02.value * inv_m00 - yc * yc)
    mu11 = m11.value * inv_m00 - xc * yc
    disc = math.sqrt(max(0.0, (mu20 - mu02) ** 2 + 4.0 * mu11 * mu11))
    l1 = max(1.0, 2.0 * math.sqrt(max(0.0, 0.5 * (mu20 + mu02 + disc))))
    l2 = max(1.0, 2.0 * math.sqrt(max(0.0, 0.5 * (mu20 + mu02 - disc))))
    angle = 0.5 * math.degrees(math.atan2(2.0 * mu11, mu20 - mu02))
    cx = rx + xc
    cy = ry + yc
    new_w = max(4, min(prob.shape[1], int(round(max(l1, l2) * 1.2))))
    new_h = max(4, min(prob.shape[0], int(round(max(l1, l2) * 1.2))))
    new_x = max(0, min(prob.shape[1] - new_w, int(round(cx - new_w * 0.5))))
    new_y = max(0, min(prob.shape[0] - new_h, int(round(cy - new_h * 0.5))))
    return ((float(cx), float(cy)), (float(l2), float(l1)), float(angle)), (new_x, new_y, new_w, new_h)


def findTransformECC(templateImage, inputImage, warpMatrix, motionType: int = MOTION_AFFINE,
                     criteria=(TERM_CRITERIA_EPS | TERM_CRITERIA_COUNT, 50, 0.001),
                     inputMask=None, gaussFiltSize: int = 5):
    t = _as_img(templateImage)
    inp = _as_img(inputImage)
    wm = np.ascontiguousarray(np.asarray(warpMatrix, dtype=np.float32).reshape(2, 3)).copy()
    max_iter, eps = _parse_criteria(criteria, 50, 0.001)
    corr = ctypes.c_double(0.0)
    check(
        _c_ecc(*img_args(t), *img_args(inp), wm.ctypes.data_as(_PF32), int(motionType), max_iter, eps, ctypes.byref(corr)),
        "findTransformECC",
    )
    if isinstance(warpMatrix, np.ndarray) and warpMatrix.shape == (2, 3) and warpMatrix.dtype == np.float32 and warpMatrix.flags.writeable:
        warpMatrix[...] = wm
        return float(corr.value), warpMatrix
    return float(corr.value), wm


# ===========================================================================
# PHASE 11: Calib3D + Stereo
# ===========================================================================

def findHomography(srcPoints, dstPoints, method: int = 0, ransacReprojThreshold: float = 3.0,
                   mask=None, maxIters: int = 2000, confidence: float = 0.995):
    s = np.ascontiguousarray(np.asarray(srcPoints, dtype=np.float64).reshape(-1, 2))
    d = np.ascontiguousarray(np.asarray(dstPoints, dtype=np.float64).reshape(-1, 2))
    if s.shape[0] != d.shape[0] or s.shape[0] < 4:
        raise error("findHomography: need >= 4 matched point pairs")
    n = s.shape[0]
    H = np.empty((3, 3), dtype=np.float64)
    msk = np.empty((n, 1), dtype=np.uint8)
    check(
        _c_find_homography(
            s.ctypes.data_as(PF64), d.ctypes.data_as(PF64), n,
            int(method), float(ransacReprojThreshold), int(maxIters), float(confidence),
            H.ctypes.data_as(PF64), msk.ctypes.data_as(PU8),
        ),
        "findHomography",
    )
    return H, msk


def perspectiveTransform(src, m, dst=None) -> np.ndarray:
    pts = np.asarray(src, dtype=np.float64)
    M = np.asarray(m, dtype=np.float64)
    orig_shape = pts.shape
    dim = orig_shape[-1]
    flat = pts.reshape(-1, dim)
    hom = np.concatenate([flat, np.ones((flat.shape[0], 1), dtype=np.float64)], axis=1)
    out_h = hom @ M.T
    w = out_h[:, -1:]
    w = np.where(np.abs(w) < 1e-12, 1.0, w)
    out = (out_h[:, :-1] / w).reshape(orig_shape).astype(np.asarray(src).dtype if np.issubdtype(np.asarray(src).dtype, np.floating) else np.float64)
    if dst is not None and isinstance(dst, np.ndarray) and dst.shape == out.shape:
        dst[...] = out
        return dst
    return out


def Rodrigues(src, dst=None, jacobian=None):
    arr = np.ascontiguousarray(np.asarray(src, dtype=np.float64))
    flat = arr.reshape(-1)
    if flat.size == 3:
        out = np.empty((3, 3), dtype=np.float64)
        jac = np.empty((3, 9), dtype=np.float64)
        check(_c_rodrigues(flat.ctypes.data_as(PF64), 3, out.ctypes.data_as(PF64), jac.ctypes.data_as(PF64)), "Rodrigues")
    elif flat.size == 9:
        out = np.empty((3, 1), dtype=np.float64)
        jac = np.empty((9, 3), dtype=np.float64)
        check(_c_rodrigues(flat.ctypes.data_as(PF64), 9, out.ctypes.data_as(PF64), jac.ctypes.data_as(PF64)), "Rodrigues")
    else:
        raise error("Rodrigues: input must be 3-vector or 3x3 matrix")
    return out, jac


def projectPoints(objectPoints, rvec, tvec, cameraMatrix, distCoeffs, imagePoints=None, jacobian=None):
    obj = np.ascontiguousarray(np.asarray(objectPoints, dtype=np.float64).reshape(-1, 3))
    rv = np.ascontiguousarray(np.asarray(rvec, dtype=np.float64).reshape(3))
    tv = np.ascontiguousarray(np.asarray(tvec, dtype=np.float64).reshape(3))
    K = np.ascontiguousarray(np.asarray(cameraMatrix, dtype=np.float64).reshape(3, 3))
    if distCoeffs is None or np.asarray(distCoeffs).size == 0:
        dc = np.zeros(0, dtype=np.float64)
        dc_ptr = None
    else:
        dc = np.ascontiguousarray(np.asarray(distCoeffs, dtype=np.float64).reshape(-1))
        dc_ptr = dc.ctypes.data_as(PF64)
    n = obj.shape[0]
    out = np.empty((n, 2), dtype=np.float64)
    check(
        _c_project_points(
            obj.ctypes.data_as(PF64), n, rv.ctypes.data_as(PF64), tv.ctypes.data_as(PF64),
            K.ctypes.data_as(PF64), dc_ptr, dc.size, out.ctypes.data_as(PF64),
        ),
        "projectPoints",
    )
    return out.reshape(n, 1, 2), None


def solvePnP(objectPoints, imagePoints, cameraMatrix, distCoeffs, rvec=None, tvec=None,
             useExtrinsicGuess: bool = False, flags: int = 0):
    obj = np.ascontiguousarray(np.asarray(objectPoints, dtype=np.float64).reshape(-1, 3))
    img = np.ascontiguousarray(np.asarray(imagePoints, dtype=np.float64).reshape(-1, 2))
    K = np.ascontiguousarray(np.asarray(cameraMatrix, dtype=np.float64).reshape(3, 3))
    if obj.shape[0] != img.shape[0] or obj.shape[0] < 4:
        raise error("solvePnP: need >= 4 3D-2D correspondences")
    if distCoeffs is None or np.asarray(distCoeffs).size == 0:
        dc = np.zeros(0, dtype=np.float64)
        dc_ptr = None
    else:
        dc = np.ascontiguousarray(np.asarray(distCoeffs, dtype=np.float64).reshape(-1))
        dc_ptr = dc.ctypes.data_as(PF64)
    rv = np.ascontiguousarray(np.asarray(rvec, dtype=np.float64).reshape(3)).copy() if (useExtrinsicGuess and rvec is not None) else np.zeros(3, dtype=np.float64)
    tv = np.ascontiguousarray(np.asarray(tvec, dtype=np.float64).reshape(3)).copy() if (useExtrinsicGuess and tvec is not None) else np.zeros(3, dtype=np.float64)
    check(
        _c_solve_pnp(
            obj.ctypes.data_as(PF64), img.ctypes.data_as(PF64), obj.shape[0],
            K.ctypes.data_as(PF64), dc_ptr, dc.size, 1 if useExtrinsicGuess else 0,
            rv.ctypes.data_as(PF64), tv.ctypes.data_as(PF64),
        ),
        "solvePnP",
    )
    return True, rv.reshape(3, 1), tv.reshape(3, 1)


def initUndistortRectifyMap(cameraMatrix, distCoeffs, R, newCameraMatrix, size, m1type=5, map1=None, map2=None):
    w, h = int(size[0]), int(size[1])
    K = np.ascontiguousarray(np.asarray(cameraMatrix, dtype=np.float64).reshape(3, 3))
    if distCoeffs is None or np.asarray(distCoeffs).size == 0:
        dc = np.zeros(0, dtype=np.float64)
        dc_ptr = None
    else:
        dc = np.ascontiguousarray(np.asarray(distCoeffs, dtype=np.float64).reshape(-1))
        dc_ptr = dc.ctypes.data_as(PF64)
    R_arr = np.ascontiguousarray(np.asarray(R, dtype=np.float64).reshape(3, 3)) if R is not None else None
    nK_arr = np.ascontiguousarray(np.asarray(newCameraMatrix, dtype=np.float64).reshape(3, 3)) if newCameraMatrix is not None else None
    m1 = np.empty((h, w), dtype=np.float32)
    m2 = np.empty((h, w), dtype=np.float32)
    check(
        _c_init_undistort_map(
            K.ctypes.data_as(PF64), dc_ptr, dc.size,
            R_arr.ctypes.data_as(PF64) if R_arr is not None else None,
            nK_arr.ctypes.data_as(PF64) if nK_arr is not None else None,
            w, h, m1.ctypes.data_as(_PF32), m2.ctypes.data_as(_PF32),
        ),
        "initUndistortRectifyMap",
    )
    return m1, m2


def undistort(src, cameraMatrix, distCoeffs, dst=None, newCameraMatrix=None) -> np.ndarray:
    s = _as_img(src)
    h, w = s.shape[:2]
    m1, m2 = initUndistortRectifyMap(cameraMatrix, distCoeffs, None, newCameraMatrix, (w, h))
    return _ops.remap(s, m1, m2, 1, dst=dst)


def undistortPoints(src, cameraMatrix, distCoeffs, dst=None, R=None, P=None) -> np.ndarray:
    orig = np.asarray(src, dtype=np.float64)
    pts = orig.reshape(-1, 2)
    K = np.asarray(cameraMatrix, dtype=np.float64).reshape(3, 3)
    fx, skew, cx = K[0, 0], K[0, 1], K[0, 2]
    fy, cy = K[1, 1], K[1, 2]
    d = np.zeros(8, dtype=np.float64)
    if distCoeffs is not None:
        raw = np.asarray(distCoeffs, dtype=np.float64).reshape(-1)
        d[:min(8, raw.size)] = raw[:min(8, raw.size)]
    k1, k2, p1, p2, k3, k4, k5, k6 = d

    yd = (pts[:, 1] - cy) / fy
    xd = (pts[:, 0] - cx - skew * yd) / fx
    x = xd.copy()
    y = yd.copy()
    for _ in range(15):
        r2 = x * x + y * y
        r4 = r2 * r2
        r6 = r4 * r2
        icdist = (1.0 + k4 * r2 + k5 * r4 + k6 * r6) / np.maximum(1e-12, 1.0 + k1 * r2 + k2 * r4 + k3 * r6)
        dx = 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x)
        dy = p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y
        x = (xd - dx) * icdist
        y = (yd - dy) * icdist

    if R is not None:
        Rm = np.asarray(R, dtype=np.float64).reshape(3, 3)
        xyz = np.stack([x, y, np.ones_like(x)], axis=1) @ Rm.T
        x = xyz[:, 0] / xyz[:, 2]
        y = xyz[:, 1] / xyz[:, 2]
    if P is not None:
        Pm = np.asarray(P, dtype=np.float64)
        Pm3 = Pm[:3, :3]
        xyz = np.stack([x, y, np.ones_like(x)], axis=1) @ Pm3.T
        x = xyz[:, 0] / xyz[:, 2]
        y = xyz[:, 1] / xyz[:, 2]
    out = np.stack([x, y], axis=1).reshape(orig.shape).astype(np.asarray(src).dtype if np.issubdtype(np.asarray(src).dtype, np.floating) else np.float64)
    return out


class StereoBM:
    def __init__(self, numDisparities: int = 0, blockSize: int = 21):
        self._numDisparities = int(numDisparities) if numDisparities > 0 else 64
        self._blockSize = int(blockSize)
        self._minDisparity = 0
        self._uniquenessRatio = 10

    def setMinDisparity(self, v: int) -> None:
        self._minDisparity = int(v)

    def setNumDisparities(self, v: int) -> None:
        self._numDisparities = int(v)

    def setBlockSize(self, v: int) -> None:
        self._blockSize = int(v)

    def setUniquenessRatio(self, v: int) -> None:
        self._uniquenessRatio = int(v)

    def compute(self, left, right, disparity=None) -> np.ndarray:
        l_img = _as_u8(left)
        r_img = _as_u8(right)
        h, w = l_img.shape[:2]
        out = np.empty((h, w), dtype=np.int16) if disparity is None else np.ascontiguousarray(disparity, dtype=np.int16)
        check(
            _c_stereo_bm(
                *img_args(l_img), *img_args(r_img),
                out.ctypes.data_as(_PI16),
                self._numDisparities, self._blockSize, self._minDisparity, self._uniquenessRatio,
            ),
            "StereoBM.compute",
        )
        return out


def StereoBM_create(numDisparities: int = 0, blockSize: int = 21) -> StereoBM:
    return StereoBM(numDisparities=numDisparities, blockSize=blockSize)


# ===========================================================================
# PHASE 12: ObjDetect (Apple Vision QR & Barcode + ArUco)
# ===========================================================================

class QRCodeDetector:
    def detectAndDecodeMulti(self, img):
        s = _as_u8(img)
        cap = 64
        corners = np.empty((cap, 4, 2), dtype=np.float32)
        tcap = 16384
        tbuf = ctypes.create_string_buffer(tcap)
        toffs = np.empty(cap, dtype=np.int32)
        tlens = np.empty(cap, dtype=np.int32)
        cnt = ctypes.c_int32(0)
        check(
            _c_qr_detect(
                *img_args(s),
                corners.ctypes.data_as(_PF32),
                tbuf, tcap, toffs.ctypes.data_as(PI32), tlens.ctypes.data_as(PI32),
                cap, ctypes.byref(cnt),
            ),
            "QRCodeDetector.detectAndDecodeMulti",
        )
        n = cnt.value
        if n == 0:
            return False, (), None, ()
        raw = tbuf.raw
        texts = tuple(raw[int(toffs[i]):int(toffs[i]) + int(tlens[i])].decode("utf-8", "replace") for i in range(n))
        return True, texts, corners[:n].copy(), ()

    def detectAndDecode(self, img):
        ok, texts, pts, _ = self.detectAndDecodeMulti(img)
        if not ok:
            return "", None, None
        return texts[0], pts[0:1], None

    def detect(self, img):
        ok, _, pts, _ = self.detectAndDecodeMulti(img)
        return (True, pts[0:1]) if ok else (False, None)

    def decode(self, img, points):
        text, _, _ = self.detectAndDecode(img)
        return text, None


class BarcodeDetector:
    def detectAndDecodeWithType(self, img):
        s = _as_u8(img)
        cap = 64
        corners = np.empty((cap, 4, 2), dtype=np.float32)
        tcap = 16384
        tbuf = ctypes.create_string_buffer(tcap)
        toffs = np.empty(cap, dtype=np.int32)
        tlens = np.empty(cap, dtype=np.int32)
        scap = 4096
        sbuf = ctypes.create_string_buffer(scap)
        soffs = np.empty(cap, dtype=np.int32)
        slens = np.empty(cap, dtype=np.int32)
        cnt = ctypes.c_int32(0)
        check(
            _c_barcode_detect(
                *img_args(s),
                corners.ctypes.data_as(_PF32),
                tbuf, tcap, toffs.ctypes.data_as(PI32), tlens.ctypes.data_as(PI32),
                sbuf, scap, soffs.ctypes.data_as(PI32), slens.ctypes.data_as(PI32),
                cap, ctypes.byref(cnt),
            ),
            "BarcodeDetector.detectAndDecodeWithType",
        )
        n = cnt.value
        if n == 0:
            return False, (), (), None
        traw = tbuf.raw
        sraw = sbuf.raw
        texts = tuple(traw[int(toffs[i]):int(toffs[i]) + int(tlens[i])].decode("utf-8", "replace") for i in range(n))
        types_ = tuple(sraw[int(soffs[i]):int(soffs[i]) + int(slens[i])].decode("utf-8", "replace") for i in range(n))
        return True, texts, types_, corners[:n].copy()

    def detectAndDecode(self, img):
        ok, texts, _, pts = self.detectAndDecodeWithType(img)
        return ok, texts, pts

    def detect(self, img):
        ok, _, _, pts = self.detectAndDecodeWithType(img)
        return ok, pts


barcode = types.SimpleNamespace(BarcodeDetector=BarcodeDetector)


# ArUco namespace
class _ArucoDictionary:
    def __init__(self, dict_id: int):
        self.dict_id = int(dict_id)
        self.markerSize = 4 if dict_id < 4 else (5 if dict_id < 8 else 6)


class _ArucoDetectorParameters:
    def __init__(self):
        self.adaptiveThreshConstant = 8.0
        self.minMarkerPerimeterRate = 0.03
        self.maxMarkerPerimeterRate = 4.0


def _aruco_getPredefinedDictionary(dict_id: int) -> _ArucoDictionary:
    return _ArucoDictionary(dict_id)


def _aruco_generateImageMarker(dictionary, id: int, sidePixels: int, img=None, borderBits: int = 1) -> np.ndarray:
    dict_id = dictionary.dict_id if isinstance(dictionary, _ArucoDictionary) else int(dictionary)
    side = int(sidePixels)
    out = np.empty((side, side), dtype=np.uint8) if img is None else img
    check(_c_aruco_gen(dict_id, int(id), side, int(borderBits), *img_args(out)), "aruco.generateImageMarker")
    return out


class _ArucoDetector:
    def __init__(self, dictionary=None, detectorParams=None):
        self._dict = dictionary if dictionary is not None else _ArucoDictionary(0)
        self._params = detectorParams if detectorParams is not None else _ArucoDetectorParameters()

    def detectMarkers(self, image):
        s = _as_u8(image)
        cap = 128
        cbuf = np.empty((cap, 4, 2), dtype=np.float32)
        ibuf = np.empty(cap, dtype=np.int32)
        cnt = ctypes.c_int32(0)
        dict_id = self._dict.dict_id if isinstance(self._dict, _ArucoDictionary) else int(self._dict)
        check(
            _c_aruco_det(*img_args(s), dict_id, cbuf.ctypes.data_as(_PF32), ibuf.ctypes.data_as(PI32), cap, ctypes.byref(cnt)),
            "aruco.ArucoDetector.detectMarkers",
        )
        n = cnt.value
        if n == 0:
            return (), None, ()
        corners = tuple(cbuf[i].reshape(1, 4, 2).copy() for i in range(n))
        ids = ibuf[:n].reshape(n, 1).copy()
        return corners, ids, ()


aruco = types.SimpleNamespace(
    DICT_4X4_50=0,
    DICT_4X4_100=1,
    DICT_4X4_250=2,
    DICT_5X5_50=4,
    DICT_5X5_100=5,
    DICT_5X5_250=6,
    DICT_6X6_50=8,
    DICT_6X6_100=9,
    DICT_6X6_250=10,
    Dictionary=_ArucoDictionary,
    DetectorParameters=_ArucoDetectorParameters,
    getPredefinedDictionary=_aruco_getPredefinedDictionary,
    generateImageMarker=_aruco_generateImageMarker,
    ArucoDetector=_ArucoDetector,
)


# ===========================================================================
# PHASE 13: DNN (blobFromImage, NMSBoxes, Apple CoreML Net)
# ===========================================================================

def _dnn_blobFromImages(images, scalefactor: float = 1.0, size=(0, 0), mean=(0.0, 0.0, 0.0),
                        swapRB: bool = False, crop: bool = False, ddepth: int = 5) -> np.ndarray:
    tw, th = int(size[0]), int(size[1])
    mean_arr = np.asarray(mean, dtype=np.float32).reshape(-1)
    processed = []
    for img in images:
        arr = np.asarray(img)
        if arr.ndim == 2:
            arr = arr[:, :, None]
        h, w, c = arr.shape
        if tw > 0 and th > 0 and (w != tw or h != th):
            if crop:
                scale = max(tw / w, th / h)
                rw, rh = max(tw, int(round(w * scale))), max(th, int(round(h * scale)))
                resized = _ops.resize(arr if c > 1 else arr[:, :, 0], (rw, rh))
                if resized.ndim == 2:
                    resized = resized[:, :, None]
                y0 = (rh - th) // 2
                x0 = (rw - tw) // 2
                arr = resized[y0:y0 + th, x0:x0 + tw]
            else:
                resized = _ops.resize(arr if c > 1 else arr[:, :, 0], (tw, th))
                arr = resized[:, :, None] if resized.ndim == 2 else resized
        f = arr.astype(np.float32)
        if swapRB and f.shape[2] >= 3:
            f = f[:, :, [2, 1, 0] + list(range(3, f.shape[2]))]
        m_pad = np.zeros(f.shape[2], dtype=np.float32)
        m_pad[:min(mean_arr.size, f.shape[2])] = mean_arr[:min(mean_arr.size, f.shape[2])]
        if swapRB and f.shape[2] >= 3:
            m_pad[0], m_pad[2] = m_pad[2], m_pad[0]
        f = (f - m_pad[None, None, :]) * float(scalefactor)
        processed.append(np.transpose(f, (2, 0, 1)))
    return np.ascontiguousarray(np.stack(processed, axis=0), dtype=np.float32)


def _dnn_blobFromImage(image, scalefactor: float = 1.0, size=(0, 0), mean=(0.0, 0.0, 0.0),
                       swapRB: bool = False, crop: bool = False, ddepth: int = 5) -> np.ndarray:
    return _dnn_blobFromImages([image], scalefactor, size, mean, swapRB, crop, ddepth)


def _dnn_NMSBoxes(bboxes, scores, score_threshold: float, nms_threshold: float, eta: float = 1.0, top_k: int = 0) -> np.ndarray:
    if len(bboxes) == 0:
        return np.empty((0,), dtype=np.int32)
    b = np.ascontiguousarray(np.asarray(bboxes, dtype=np.float32).reshape(-1, 4))
    s = np.ascontiguousarray(np.asarray(scores, dtype=np.float32).reshape(-1))
    n = b.shape[0]
    out = np.empty(n, dtype=np.int32)
    cnt = ctypes.c_int32(0)
    check(
        _c_nms_boxes(
            b.ctypes.data_as(_PF32), s.ctypes.data_as(_PF32), n,
            float(score_threshold), float(nms_threshold),
            out.ctypes.data_as(PI32), ctypes.byref(cnt),
        ),
        "dnn.NMSBoxes",
    )
    kept = out[:cnt.value].copy()
    if top_k > 0 and kept.size > top_k:
        kept = kept[:int(top_k)]
    return kept


class _DNNNet:
    def __init__(self, model_path: str):
        self._path = str(model_path)
        self._handle = _c_coreml_load(self._path.encode("utf-8"))
        if not self._handle:
            raise error(f"dnn.readNet: failed to load CoreML model '{self._path}': {_lib.last_error()}")
        self._input = None
        self._input_name = None

    def setInput(self, blob, name: str = "") -> None:
        self._input = np.ascontiguousarray(np.asarray(blob, dtype=np.float32))
        self._input_name = name if name else None

    def forward(self, outputName: str | None = None) -> np.ndarray:
        if self._input is None:
            raise error("dnn.Net.forward: setInput must be called first")
        shape = np.array(self._input.shape, dtype=np.int32)
        in_name = self._input_name.encode("utf-8") if self._input_name else None
        out_name = outputName.encode("utf-8") if outputName else None
        cap = max(65536, self._input.size * 4)
        out_buf = np.empty(cap, dtype=np.float32)
        out_cnt = ctypes.c_int32(0)
        out_shape = np.zeros(8, dtype=np.int32)
        out_ndim = ctypes.c_int32(0)
        check(
            _c_coreml_infer(
                self._handle, in_name,
                self._input.ctypes.data_as(_PF32), shape.ctypes.data_as(PI32), shape.size,
                out_name, out_buf.ctypes.data_as(_PF32), cap,
                ctypes.byref(out_cnt), out_shape.ctypes.data_as(PI32), ctypes.byref(out_ndim),
            ),
            "dnn.Net.forward",
        )
        n = out_cnt.value
        if n > cap:
            out_buf = np.empty(n, dtype=np.float32)
            check(
                _c_coreml_infer(
                    self._handle, in_name,
                    self._input.ctypes.data_as(_PF32), shape.ctypes.data_as(PI32), shape.size,
                    out_name, out_buf.ctypes.data_as(_PF32), n,
                    ctypes.byref(out_cnt), out_shape.ctypes.data_as(PI32), ctypes.byref(out_ndim),
                ),
                "dnn.Net.forward",
            )
        dims = tuple(int(out_shape[i]) for i in range(out_ndim.value))
        return out_buf[:n].reshape(dims).copy() if dims else out_buf[:n].copy()

    def __del__(self):
        h = getattr(self, "_handle", None)
        if h:
            self._handle = None
            try:
                _c_coreml_free(h)
            except Exception:
                pass


def _dnn_readNet(model: str, config: str = "", framework: str = "") -> _DNNNet:
    return _DNNNet(model)


dnn = types.SimpleNamespace(
    blobFromImage=_dnn_blobFromImage,
    blobFromImages=_dnn_blobFromImages,
    NMSBoxes=_dnn_NMSBoxes,
    readNet=_dnn_readNet,
    Net=_DNNNet,
)


# ===========================================================================
# PHASE 14: 3D / Point Cloud (PLY I/O, Normals, Voxel Downsampling)
# ===========================================================================

def writePLY(filename: str, points, colors=None, normals=None) -> bool:
    pts = np.asarray(points, dtype=np.float32).reshape(-1, 3)
    n = pts.shape[0]
    has_n = normals is not None
    has_c = colors is not None
    nrm = np.asarray(normals, dtype=np.float32).reshape(n, 3) if has_n else None
    col = np.clip(np.rint(np.asarray(colors)), 0, 255).astype(np.uint8).reshape(n, 3) if has_c else None

    lines = [
        "ply",
        "format ascii 1.0",
        f"element vertex {n}",
        "property float x",
        "property float y",
        "property float z",
    ]
    if has_n:
        lines += ["property float nx", "property float ny", "property float nz"]
    if has_c:
        lines += ["property uchar red", "property uchar green", "property uchar blue"]
    lines.append("end_header")

    with open(filename, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
        for i in range(n):
            parts = [f"{pts[i, 0]:.6f}", f"{pts[i, 1]:.6f}", f"{pts[i, 2]:.6f}"]
            if has_n:
                parts += [f"{nrm[i, 0]:.6f}", f"{nrm[i, 1]:.6f}", f"{nrm[i, 2]:.6f}"]
            if has_c:
                parts += [str(int(col[i, 0])), str(int(col[i, 1])), str(int(col[i, 2]))]
            f.write(" ".join(parts) + "\n")
    return True


def readPLY(filename: str):
    with open(filename, "rb") as f:
        fmt = "ascii"
        n_verts = 0
        props: list[tuple[str, str]] = []
        in_vertex = False
        while True:
            raw_line = f.readline()
            if not raw_line:
                raise error("readPLY: unexpected EOF in header")
            line = raw_line.decode("ascii", "replace").strip()
            if line == "end_header":
                break
            toks = line.split()
            if not toks:
                continue
            if toks[0] == "format":
                fmt = toks[1]
            elif toks[0] == "element":
                in_vertex = (toks[1] == "vertex")
                if in_vertex:
                    n_verts = int(toks[2])
            elif toks[0] == "property" and in_vertex and toks[1] != "list":
                props.append((toks[1], toks[2]))

        prop_names = [name for _, name in props]
        ix, iy, iz = prop_names.index("x"), prop_names.index("y"), prop_names.index("z")
        has_n = all(k in prop_names for k in ("nx", "ny", "nz"))
        has_c = all(k in prop_names for k in ("red", "green", "blue"))
        inx = prop_names.index("nx") if has_n else -1
        iny = prop_names.index("ny") if has_n else -1
        inz = prop_names.index("nz") if has_n else -1
        ir = prop_names.index("red") if has_c else -1
        ig = prop_names.index("green") if has_c else -1
        ib = prop_names.index("blue") if has_c else -1

        pts = np.empty((n_verts, 3), dtype=np.float32)
        nrm = np.empty((n_verts, 3), dtype=np.float32) if has_n else None
        col = np.empty((n_verts, 3), dtype=np.uint8) if has_c else None

        if fmt == "ascii":
            for i in range(n_verts):
                vals = f.readline().decode("ascii").split()
                pts[i] = (float(vals[ix]), float(vals[iy]), float(vals[iz]))
                if has_n:
                    nrm[i] = (float(vals[inx]), float(vals[iny]), float(vals[inz]))
                if has_c:
                    col[i] = (int(float(vals[ir])), int(float(vals[ig])), int(float(vals[ib])))
        else:
            endian = "<" if "little" in fmt else ">"
            type_map = {
                "char": "b", "int8": "b", "uchar": "B", "uint8": "B",
                "short": "h", "int16": "h", "ushort": "H", "uint16": "H",
                "int": "i", "int32": "i", "uint": "I", "uint32": "I",
                "float": "f", "float32": "f", "double": "d", "float64": "d",
            }
            st = struct.Struct(endian + "".join(type_map[t] for t, _ in props))
            for i in range(n_verts):
                vals = st.unpack(f.read(st.size))
                pts[i] = (vals[ix], vals[iy], vals[iz])
                if has_n:
                    nrm[i] = (vals[inx], vals[iny], vals[inz])
                if has_c:
                    col[i] = (int(vals[ir]), int(vals[ig]), int(vals[ib]))
    return pts, col, nrm


def computeNormals(points, k: int = 10) -> np.ndarray:
    pts = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    n = pts.shape[0]
    if n < 3:
        return np.zeros((n, 3), dtype=np.float32)
    kk = max(3, min(int(k), n))
    # Pairwise squared distance matrix (chunked for memory efficiency)
    normals = np.zeros((n, 3), dtype=np.float64)
    p2 = np.sum(pts * pts, axis=1)
    chunk = 512
    for start in range(0, n, chunk):
        end = min(n, start + chunk)
        d2 = p2[start:end, None] + p2[None, :] - 2.0 * (pts[start:end] @ pts.T)
        idx = np.argpartition(d2, kth=kk - 1, axis=1)[:, :kk]
        for loc, i in enumerate(range(start, end)):
            nbrs = pts[idx[loc]]
            centered = nbrs - nbrs.mean(axis=0, keepdims=True)
            cov = centered.T @ centered
            _, vecs = np.linalg.eigh(cov)
            nvec = vecs[:, 0]
            norm = np.linalg.norm(nvec)
            if norm > 1e-12:
                nvec = nvec / norm
            normals[i] = nvec
    return normals.astype(np.float32)


def voxelDownsample(points, voxel_size: float, colors=None):
    pts = np.asarray(points, dtype=np.float64).reshape(-1, 3)
    vs = float(voxel_size)
    if vs <= 0:
        raise error("voxelDownsample: voxel_size must be > 0")
    if pts.shape[0] == 0:
        return (pts.astype(np.float32), None) if colors is not None else pts.astype(np.float32)
    keys = np.floor(pts / vs).astype(np.int64)
    _, inv, counts = np.unique(keys, axis=0, return_inverse=True, return_counts=True)
    n_vox = counts.shape[0]
    out_pts = np.zeros((n_vox, 3), dtype=np.float64)
    np.add.at(out_pts, inv, pts)
    out_pts = (out_pts / counts[:, None]).astype(np.float32)
    if colors is not None:
        col = np.asarray(colors, dtype=np.float64).reshape(pts.shape[0], -1)
        out_col = np.zeros((n_vox, col.shape[1]), dtype=np.float64)
        np.add.at(out_col, inv, col)
        out_col = np.clip(np.rint(out_col / counts[:, None]), 0, 255).astype(np.uint8)
        return out_pts, out_col
    return out_pts


# ===========================================================================
# PHASE 15: Stitcher + FLANN + Color Correction Model (CCM)
# ===========================================================================

class Stitcher:
    def __init__(self, mode: int = Stitcher_PANORAMA):
        self._mode = int(mode)

    def stitch(self, images):
        if len(images) < 2:
            return STITCHER_ERR_NEED_MORE_IMGS, None
        imgs = [_as_u8(im) for im in images]
        orb = ORB_create(nfeatures=1500, fastThreshold=12, edgeThreshold=16)
        matcher = BFMatcher(NORM_HAMMING, crossCheck=False)

        # Accumulate homographies into imgs[0] frame
        H_to_base = [np.eye(3, dtype=np.float64)]
        for idx in range(1, len(imgs)):
            kp_prev, desc_prev = orb.detectAndCompute(imgs[idx - 1])
            kp_cur, desc_cur = orb.detectAndCompute(imgs[idx])
            if desc_prev is None or desc_cur is None or len(kp_prev) < 4 or len(kp_cur) < 4:
                return STITCHER_ERR_NEED_MORE_IMGS, None
            knn = matcher.knnMatch(desc_cur, desc_prev, k=2)
            good = []
            for pair in knn:
                if len(pair) == 2 and pair[0].distance < 0.8 * pair[1].distance:
                    good.append(pair[0])
            if len(good) < 4:
                all_m = matcher.match(desc_cur, desc_prev)
                good = all_m[:max(4, min(50, len(all_m)))]
            if len(good) < 4:
                return STITCHER_ERR_NEED_MORE_IMGS, None
            src_pts = np.array([kp_cur[m.queryIdx].pt for m in good], dtype=np.float64)
            dst_pts = np.array([kp_prev[m.trainIdx].pt for m in good], dtype=np.float64)
            H_step, inliers = findHomography(src_pts, dst_pts, RANSAC, 4.0)
            if inliers is None or int(inliers.sum()) < 4:
                return STITCHER_ERR_HOMOGRAPHY_EST_FAIL, None
            H_to_base.append(H_to_base[-1] @ H_step)

        # Compute panorama canvas bounds
        all_corners = []
        for im, H in zip(imgs, H_to_base):
            hh, ww = im.shape[:2]
            c = np.array([[0, 0], [ww, 0], [ww, hh], [0, hh]], dtype=np.float64)
            all_corners.append(perspectiveTransform(c, H))
        cat = np.vstack(all_corners)
        min_x = int(math.floor(float(cat[:, 0].min())))
        min_y = int(math.floor(float(cat[:, 1].min())))
        max_x = int(math.ceil(float(cat[:, 0].max())))
        max_y = int(math.ceil(float(cat[:, 1].max())))
        out_w = max(1, min(8192, max_x - min_x))
        out_h = max(1, min(8192, max_y - min_y))

        T = np.array([[1.0, 0.0, -min_x], [0.0, 1.0, -min_y], [0.0, 0.0, 1.0]], dtype=np.float64)
        ch = 1 if imgs[0].ndim == 2 else imgs[0].shape[2]
        acc = np.zeros((out_h, out_w, ch), dtype=np.float32)
        wsum = np.zeros((out_h, out_w, 1), dtype=np.float32)

        for im, H in zip(imgs, H_to_base):
            hh, ww = im.shape[:2]
            # Smooth pyramid feather mask (higher weight near image center)
            yy = np.minimum(np.arange(hh), hh - 1 - np.arange(hh)).astype(np.float32) + 1.0
            xx = np.minimum(np.arange(ww), ww - 1 - np.arange(ww)).astype(np.float32) + 1.0
            wt = np.minimum(yy[:, None], xx[None, :])
            wt = wt / max(1.0, float(wt.max()))

            HT = T @ H
            warped_im = _ops.warpPerspective(im, HT, (out_w, out_h))
            warped_wt = _ops.warpPerspective(wt, HT, (out_w, out_h))
            if warped_im.ndim == 2:
                warped_im = warped_im[:, :, None]
            ww3 = warped_wt[:, :, None]
            acc += warped_im.astype(np.float32) * ww3
            wsum += ww3

        pano = np.where(wsum > 1e-6, acc / np.maximum(wsum, 1e-6), 0.0)
        pano = np.clip(np.rint(pano), 0, 255).astype(np.uint8)
        if imgs[0].ndim == 2:
            pano = pano[:, :, 0]
        return STITCHER_OK, pano


def Stitcher_create(mode: int = Stitcher_PANORAMA) -> Stitcher:
    return Stitcher(mode=mode)


class _FlannIndex:
    def __init__(self, features=None, params=None):
        self._data = None
        self._norms = None
        if features is not None:
            self.build(features, params)

    def build(self, features, params=None) -> None:
        self._data = np.ascontiguousarray(np.asarray(features, dtype=np.float32))
        if self._data.ndim == 1:
            self._data = self._data.reshape(-1, 1)
        self._norms = np.sum(self._data * self._data, axis=1)

    def knnSearch(self, query, knn: int, params=None):
        if self._data is None or self._data.shape[0] == 0:
            raise error("flann.Index.knnSearch: index is empty")
        q = np.asarray(query, dtype=np.float32)
        single = (q.ndim == 1)
        if single:
            q = q.reshape(1, -1)
        k = max(1, min(int(knn), self._data.shape[0]))
        q_norms = np.sum(q * q, axis=1, keepdims=True)
        d2 = np.maximum(0.0, q_norms + self._norms[None, :] - 2.0 * (q @ self._data.T))
        part = np.argpartition(d2, kth=k - 1, axis=1)[:, :k]
        row_idx = np.arange(q.shape[0])[:, None]
        part_d2 = d2[row_idx, part]
        order = np.argsort(part_d2, axis=1)
        indices = part[row_idx, order].astype(np.int32)
        dists = part_d2[row_idx, order].astype(np.float32)
        if single:
            return indices[0], dists[0]
        return indices, dists


flann = types.SimpleNamespace(Index=_FlannIndex)


class _ColorCorrectionModel:
    def __init__(self, src, constcolor):
        self._src = np.asarray(src, dtype=np.float64).reshape(-1, 3)
        self._ref = np.asarray(constcolor, dtype=np.float64).reshape(-1, 3)
        self._ccm = np.eye(3, dtype=np.float64)
        self._loss = 0.0

    def run(self) -> None:
        # Least-squares 3x3 CCM: src @ ccm ≈ ref
        ccm, _, _, _ = np.linalg.lstsq(self._src, self._ref, rcond=None)
        self._ccm = ccm
        pred = self._src @ self._ccm
        self._loss = float(np.sqrt(np.mean((pred - self._ref) ** 2)))

    def getCCM(self) -> np.ndarray:
        return self._ccm.copy()

    def getLoss(self) -> float:
        return self._loss

    def infer(self, img, islinear: bool = False) -> np.ndarray:
        arr = np.asarray(img, dtype=np.float64)
        is_u8 = (np.asarray(img).dtype == np.uint8)
        if is_u8:
            arr = arr / 255.0
        out = arr @ self._ccm
        if is_u8:
            return np.clip(np.rint(out * 255.0), 0, 255).astype(np.uint8)
        return out


ccm = types.SimpleNamespace(ColorCorrectionModel=_ColorCorrectionModel)


# ===========================================================================
# PHASE 16 & Contrib: FileStorage, TickMeter, ximgproc, xphoto, TrackerCSRT
# ===========================================================================

class FileNode:
    def __init__(self, val):
        self._val = val

    def isNone(self) -> bool:
        return self._val is None

    def empty(self) -> bool:
        return self._val is None

    def real(self) -> float:
        return float(self._val) if self._val is not None else 0.0

    def string(self) -> str:
        return str(self._val) if self._val is not None else ""

    def mat(self):
        if isinstance(self._val, np.ndarray):
            return self._val.copy()
        if isinstance(self._val, dict) and self._val.get("type_id") == "opencv-matrix":
            dt_map = {"u": np.uint8, "i": np.int32, "f": np.float32, "d": np.float64}
            dtype = dt_map.get(self._val.get("dt", "d"), np.float64)
            rows, cols = int(self._val["rows"]), int(self._val["cols"])
            ch = int(self._val.get("channels", 1))
            data = np.asarray(self._val["data"], dtype=dtype)
            return data.reshape((rows, cols) if ch == 1 else (rows, cols, ch))
        return np.asarray(self._val) if self._val is not None else None

    def size(self) -> int:
        return len(self._val) if hasattr(self._val, "__len__") else 0

    def at(self, i: int) -> "FileNode":
        return FileNode(self._val[i])


def _fs_encode_value(val):
    if isinstance(val, np.ndarray):
        dt_rev = {np.dtype(np.uint8): "u", np.dtype(np.int32): "i", np.dtype(np.float32): "f", np.dtype(np.float64): "d"}
        dt = dt_rev.get(val.dtype, "d")
        arr = val if val.dtype in dt_rev else val.astype(np.float64)
        if arr.ndim == 1:
            rows, cols, ch = arr.shape[0], 1, 1
        elif arr.ndim == 2:
            rows, cols, ch = arr.shape[0], arr.shape[1], 1
        else:
            rows, cols, ch = arr.shape[0], arr.shape[1], arr.shape[2]
        return {"type_id": "opencv-matrix", "rows": rows, "cols": cols, "channels": ch, "dt": dt, "data": arr.reshape(-1).tolist()}
    if isinstance(val, (np.integer,)):
        return int(val)
    if isinstance(val, (np.floating,)):
        return float(val)
    if isinstance(val, (list, tuple)):
        return [_fs_encode_value(v) for v in val]
    if isinstance(val, dict):
        return {str(k): _fs_encode_value(v) for k, v in val.items()}
    return val


def _yaml_dump(data: dict) -> str:
    lines = ["%YAML:1.0", "---"]
    for k, v in data.items():
        if isinstance(v, dict) and v.get("type_id") == "opencv-matrix":
            lines.append(f"{k}: !!opencv-matrix")
            lines.append(f"   rows: {v['rows']}")
            lines.append(f"   cols: {v['cols']}")
            if v.get("channels", 1) != 1:
                lines.append(f"   channels: {v['channels']}")
            lines.append(f"   dt: {v['dt']}")
            lines.append("   data: [ " + ", ".join(str(x) for x in v["data"]) + " ]")
        elif isinstance(v, str):
            lines.append(f'{k}: "{v}"')
        elif isinstance(v, list):
            lines.append(f"{k}: " + json.dumps(v))
        else:
            lines.append(f"{k}: {v}")
    return "\n".join(lines) + "\n"


def _yaml_load(text: str) -> dict:
    out: dict = {}
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip() and not ln.strip().startswith("%") and ln.strip() != "---"]
    i = 0
    while i < len(lines):
        ln = lines[i]
        if ":" not in ln:
            i += 1
            continue
        k, rest = ln.split(":", 1)
        k = k.strip()
        rest = rest.strip()
        if rest == "!!opencv-matrix":
            mat: dict = {"type_id": "opencv-matrix", "channels": 1}
            i += 1
            while i < len(lines) and (lines[i].startswith(" ") or lines[i].startswith("\t")):
                mk, mv = lines[i].strip().split(":", 1)
                mk, mv = mk.strip(), mv.strip()
                if mk in ("rows", "cols", "channels"):
                    mat[mk] = int(mv)
                elif mk == "dt":
                    mat[mk] = mv.strip('"')
                elif mk == "data":
                    mat[mk] = json.loads(mv)
                i += 1
            out[k] = mat
            continue
        if rest.startswith('"') and rest.endswith('"'):
            out[k] = rest[1:-1]
        elif rest.startswith("[") or rest.startswith("{"):
            out[k] = json.loads(rest)
        else:
            try:
                out[k] = int(rest)
            except ValueError:
                try:
                    out[k] = float(rest)
                except ValueError:
                    out[k] = rest
        i += 1
    return out


class FileStorage:
    def __init__(self, filename: str = "", flags: int = FILE_STORAGE_READ):
        self._filename = str(filename)
        self._flags = int(flags)
        self._opened = False
        self._data: dict = {}
        if self._filename:
            self.open(self._filename, self._flags)

    def open(self, filename: str, flags: int) -> bool:
        self._filename = str(filename)
        self._flags = int(flags)
        self._data = {}
        if flags == FILE_STORAGE_READ:
            if not os.path.isfile(self._filename):
                self._opened = False
                return False
            ext = Path(self._filename).suffix.lower()
            text = Path(self._filename).read_text(encoding="utf-8")
            if ext == ".json":
                self._data = json.loads(text)
            elif ext in (".yml", ".yaml"):
                self._data = _yaml_load(text)
            elif ext == ".xml":
                root = ET.fromstring(text)
                for child in root:
                    if child.attrib.get("type_id") == "opencv-matrix":
                        rows = int(child.findtext("rows", "0"))
                        cols = int(child.findtext("cols", "0"))
                        ch = int(child.findtext("channels", "1"))
                        dt = child.findtext("dt", "d").strip()
                        raw_nums = [float(x) for x in child.findtext("data", "").split()]
                        self._data[child.tag] = {"type_id": "opencv-matrix", "rows": rows, "cols": cols, "channels": ch, "dt": dt, "data": raw_nums}
                    else:
                        txt = (child.text or "").strip()
                        try:
                            self._data[child.tag] = int(txt)
                        except ValueError:
                            try:
                                self._data[child.tag] = float(txt)
                            except ValueError:
                                self._data[child.tag] = txt
            else:
                self._data = json.loads(text)
            self._opened = True
            return True
        else:
            if flags == FILE_STORAGE_APPEND and os.path.isfile(self._filename):
                self.open(self._filename, FILE_STORAGE_READ)
                self._flags = flags
            self._opened = True
            return True

    def isOpened(self) -> bool:
        return self._opened

    def write(self, name: str, val) -> None:
        self._data[str(name)] = _fs_encode_value(val)

    def getNode(self, name: str) -> FileNode:
        return FileNode(self._data.get(str(name), None))

    def release(self) -> None:
        if self._opened and self._flags in (FILE_STORAGE_WRITE, FILE_STORAGE_APPEND):
            ext = Path(self._filename).suffix.lower()
            if ext == ".json":
                Path(self._filename).write_text(json.dumps(self._data, indent=2), encoding="utf-8")
            elif ext in (".yml", ".yaml"):
                Path(self._filename).write_text(_yaml_dump(self._data), encoding="utf-8")
            elif ext == ".xml":
                root = ET.Element("opencv_storage")
                for k, v in self._data.items():
                    if isinstance(v, dict) and v.get("type_id") == "opencv-matrix":
                        el = ET.SubElement(root, k, {"type_id": "opencv-matrix"})
                        ET.SubElement(el, "rows").text = str(v["rows"])
                        ET.SubElement(el, "cols").text = str(v["cols"])
                        ET.SubElement(el, "channels").text = str(v.get("channels", 1))
                        ET.SubElement(el, "dt").text = str(v["dt"])
                        ET.SubElement(el, "data").text = " ".join(str(x) for x in v["data"])
                    else:
                        ET.SubElement(root, k).text = str(v)
                ET.ElementTree(root).write(self._filename, encoding="utf-8", xml_declaration=True)
            else:
                Path(self._filename).write_text(json.dumps(self._data, indent=2), encoding="utf-8")
        self._opened = False

    def __enter__(self) -> "FileStorage":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.release()


class TickMeter:
    def __init__(self):
        self._sum_ns = 0
        self._start_ns = 0
        self._counter = 0
        self._running = False

    def start(self) -> None:
        self._start_ns = time.perf_counter_ns()
        self._running = True

    def stop(self) -> None:
        if self._running:
            self._sum_ns += time.perf_counter_ns() - self._start_ns
            self._counter += 1
            self._running = False

    def reset(self) -> None:
        self._sum_ns = 0
        self._start_ns = 0
        self._counter = 0
        self._running = False

    def getTimeMicro(self) -> float:
        return self._sum_ns / 1e3

    def getTimeMilli(self) -> float:
        return self._sum_ns / 1e6

    def getTimeSec(self) -> float:
        return self._sum_ns / 1e9

    def getCounter(self) -> int:
        return self._counter

    def getAvgTimeSec(self) -> float:
        return (self.getTimeSec() / self._counter) if self._counter > 0 else 0.0

    def getAvgTimeMilli(self) -> float:
        return (self.getTimeMilli() / self._counter) if self._counter > 0 else 0.0

    def getFPS(self) -> float:
        t = self.getTimeSec()
        return (self._counter / t) if t > 0 else 0.0


# ximgproc namespace
def _ximgproc_guidedFilter(guide, src, radius: int, eps: float, dst=None, dDepth: int = -1) -> np.ndarray:
    g = _as_img(guide)
    s = _as_img(src)
    out = np.empty_like(s) if dst is None else dst
    check(_c_guided_filter(*img_args(g), *img_args(s), *img_args(out), int(radius), float(eps)), "ximgproc.guidedFilter")
    return out


def _ximgproc_thinning(src, dst=None, thinningType: int = 0) -> np.ndarray:
    s = _as_u8(src)
    if s.ndim == 3:
        s = s[:, :, 0]
    out = np.empty_like(s) if dst is None else dst
    check(_c_thinning(*img_args(s), *img_args(out), int(thinningType)), "ximgproc.thinning")
    return out


ximgproc = types.SimpleNamespace(
    THINNING_ZHANGSUEN=0,
    THINNING_GUOHALL=1,
    guidedFilter=_ximgproc_guidedFilter,
    thinning=_ximgproc_thinning,
)


# xphoto namespace
class _SimpleWB:
    def __init__(self):
        self._p = 2.0
        self._inputMin = 0.0
        self._inputMax = 255.0
        self._outputMin = 0.0
        self._outputMax = 255.0

    def getP(self) -> float:
        return self._p

    def setP(self, val: float) -> None:
        self._p = float(val)

    def balanceWhite(self, src, dst=None) -> np.ndarray:
        s = _as_u8(src)
        out = np.empty_like(s) if dst is None else dst
        check(
            _c_simple_wb(*img_args(s), *img_args(out), self._p, self._inputMin, self._inputMax, self._outputMin, self._outputMax),
            "xphoto.SimpleWB.balanceWhite",
        )
        return out


class _GrayworldWB:
    def __init__(self):
        self._sat = 0.9

    def getSaturationThreshold(self) -> float:
        return self._sat

    def setSaturationThreshold(self, val: float) -> None:
        self._sat = float(val)

    def balanceWhite(self, src, dst=None) -> np.ndarray:
        s = _as_u8(src)
        out = np.empty_like(s) if dst is None else dst
        check(_c_grayworld_wb(*img_args(s), *img_args(out), self._sat), "xphoto.GrayworldWB.balanceWhite")
        return out


def _xphoto_oilPainting(src, size: int, dynRatio: int, code=None, dst=None) -> np.ndarray:
    s = _as_u8(src)
    out = np.empty_like(s) if dst is None else dst
    check(_c_oil_painting(*img_args(s), *img_args(out), int(size), int(dynRatio)), "xphoto.oilPainting")
    return out


xphoto = types.SimpleNamespace(
    createSimpleWB=lambda: _SimpleWB(),
    createGrayworldWB=lambda: _GrayworldWB(),
    oilPainting=_xphoto_oilPainting,
)


# TrackerCSRT (Correlation-filter / cosine-window online visual object tracker)
class TrackerCSRT:
    def __init__(self):
        self._cx = 0.0
        self._cy = 0.0
        self._w = 0.0
        self._h = 0.0
        self._sw = 0
        self._sh = 0
        self._hann = None
        self._G = None
        self._A = None
        self._B = None
        self._initialized = False

    @staticmethod
    def _to_gray_f32(img) -> np.ndarray:
        a = np.asarray(img, dtype=np.float32)
        if a.ndim == 3:
            return 0.114 * a[:, :, 0] + 0.587 * a[:, :, 1] + 0.299 * a[:, :, 2]
        return a

    def _crop(self, gray: np.ndarray, cx: float, cy: float, w: int, h: int) -> np.ndarray:
        ih, iw = gray.shape
        xs = np.clip(np.rint(np.arange(w) - w * 0.5 + cx).astype(np.int32), 0, iw - 1)
        ys = np.clip(np.rint(np.arange(h) - h * 0.5 + cy).astype(np.int32), 0, ih - 1)
        patch = gray[np.ix_(ys, xs)]
        patch = patch - patch.mean()
        std = patch.std()
        if std > 1e-5:
            patch = patch / std
        return patch * self._hann

    def init(self, image, bbox) -> bool:
        gray = self._to_gray_f32(image)
        x, y, w, h = [float(v) for v in bbox]
        if w < 2 or h < 2:
            return False
        self._cx = x + w * 0.5
        self._cy = y + h * 0.5
        self._w = w
        self._h = h
        # Padded search window (2x target size)
        self._sw = max(16, int(round(w * 2.0)))
        self._sh = max(16, int(round(h * 2.0)))
        self._hann = np.outer(np.hanning(self._sh), np.hanning(self._sw)).astype(np.float32)

        # Target Gaussian response centered at (0, 0) in cyclic FFT coordinates
        yy, xx = np.mgrid[0:self._sh, 0:self._sw]
        dy = np.minimum(yy, self._sh - yy)
        dx = np.minimum(xx, self._sw - xx)
        sigma = max(2.0, math.sqrt(w * h) * 0.125)
        g = np.exp(-0.5 * (dx * dx + dy * dy) / (sigma * sigma)).astype(np.float32)
        self._G = np.fft.fft2(g)

        patch = self._crop(gray, self._cx, self._cy, self._sw, self._sh)
        F = np.fft.fft2(patch)
        self._A = self._G * np.conj(F)
        self._B = F * np.conj(F) + 1e-2
        self._initialized = True
        return True

    def update(self, image):
        if not self._initialized:
            return False, (0, 0, 0, 0)
        gray = self._to_gray_f32(image)
        patch = self._crop(gray, self._cx, self._cy, self._sw, self._sh)
        F = np.fft.fft2(patch)
        H = self._A / (self._B + 1e-4)
        resp = np.real(np.fft.ifft2(F * H))
        peak_flat = int(np.argmax(resp))
        py, px = divmod(peak_flat, self._sw)

        # Sub-pixel parabolic refinement
        def _sub(v_prev, v_cur, v_next):
            denom = v_prev - 2.0 * v_cur + v_next
            return max(-0.5, min(0.5, 0.5 * (v_prev - v_next) / denom)) if abs(denom) > 1e-9 else 0.0

        dx = float(px) + _sub(resp[py, (px - 1) % self._sw], resp[py, px], resp[py, (px + 1) % self._sw])
        dy = float(py) + _sub(resp[(py - 1) % self._sh, px], resp[py, px], resp[(py + 1) % self._sh, px])
        if dx > self._sw * 0.5:
            dx -= self._sw
        if dy > self._sh * 0.5:
            dy -= self._sh

        self._cx = max(0.0, min(float(gray.shape[1] - 1), self._cx + dx))
        self._cy = max(0.0, min(float(gray.shape[0] - 1), self._cy + dy))

        # Online filter update
        eta = 0.08
        new_patch = self._crop(gray, self._cx, self._cy, self._sw, self._sh)
        Fn = np.fft.fft2(new_patch)
        self._A = (1.0 - eta) * self._A + eta * (self._G * np.conj(Fn))
        self._B = (1.0 - eta) * self._B + eta * (Fn * np.conj(Fn) + 1e-2)

        bbox = (
            int(round(self._cx - self._w * 0.5)),
            int(round(self._cy - self._h * 0.5)),
            int(round(self._w)),
            int(round(self._h)),
        )
        return True, bbox


def TrackerCSRT_create() -> TrackerCSRT:
    return TrackerCSRT()


__all__ = [
    # Constants
    "NORM_L1", "NORM_L2", "NORM_HAMMING", "NORM_HAMMING2",
    "TERM_CRITERIA_COUNT", "TERM_CRITERIA_MAX_ITER", "TERM_CRITERIA_EPS",
    "OPTFLOW_USE_INITIAL_FLOW", "MOTION_TRANSLATION", "MOTION_EUCLIDEAN", "MOTION_AFFINE", "MOTION_HOMOGRAPHY",
    "LMEDS", "RANSAC", "RHO",
    "FILE_STORAGE_READ", "FILE_STORAGE_WRITE", "FILE_STORAGE_APPEND", "FILE_STORAGE_MEMORY",
    "STITCHER_OK", "STITCHER_ERR_NEED_MORE_IMGS", "STITCHER_ERR_HOMOGRAPHY_EST_FAIL",
    "Stitcher_PANORAMA", "Stitcher_SCANS",
    # Phase 9
    "KeyPoint", "DMatch", "cornerHarris", "cornerMinEigenVal", "goodFeaturesToTrack", "cornerSubPix",
    "FastFeatureDetector", "FastFeatureDetector_create", "ORB", "ORB_create",
    "BFMatcher", "BFMatcher_create", "drawKeypoints", "drawMatches",
    # Phase 10
    "calcOpticalFlowPyrLK", "calcOpticalFlowFarneback", "phaseCorrelate",
    "BackgroundSubtractorMOG2", "createBackgroundSubtractorMOG2",
    "meanShift", "CamShift", "findTransformECC",
    # Phase 11
    "findHomography", "perspectiveTransform", "Rodrigues", "solvePnP", "projectPoints",
    "undistort", "undistortPoints", "initUndistortRectifyMap", "StereoBM", "StereoBM_create",
    # Phase 12
    "QRCodeDetector", "barcode", "aruco",
    # Phase 13
    "dnn",
    # Phase 14
    "readPLY", "writePLY", "computeNormals", "voxelDownsample",
    # Phase 15
    "Stitcher", "Stitcher_create", "flann", "ccm",
    # Phase 16 & contrib
    "FileStorage", "FileNode", "TickMeter", "ximgproc", "xphoto", "TrackerCSRT", "TrackerCSRT_create",
]
