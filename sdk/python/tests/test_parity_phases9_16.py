"""Automated verification & parity test suite for SafariumRaster Phases 9–16 & popular contrib.

Works both under pytest and standalone:
    SAFARIUM_RASTER_LIB=/path/to/libSafariumRaster.dylib \
    PYTHONPATH=sdk/python/safarium_cv2 \
    /opt/homebrew/bin/python3.12 sdk/python/tests/test_parity_phases9_16.py
"""
from __future__ import annotations

import math
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import numpy as np

# Ensure safarium_cv2 is importable when run standalone
_REPO_ROOT = Path(__file__).resolve().parents[3]
_SDK_DIR = str(_REPO_ROOT / "sdk" / "python" / "safarium_cv2")
if _SDK_DIR not in sys.path:
    sys.path.insert(0, _SDK_DIR)

from cv2 import _ops  # noqa: E402
from cv2 import _phases9_16 as p  # noqa: E402


# --------------------------------------------------------------------------- Synthetic Test Generators

def _make_checkerboard(h: int = 128, w: int = 128, sq: int = 16) -> np.ndarray:
    yy, xx = np.mgrid[0:h, 0:w]
    board = (((xx // sq) + (yy // sq)) % 2).astype(np.uint8) * 220 + 20
    return np.ascontiguousarray(board, dtype=np.uint8)


def _make_rich_texture(h: int = 160, w: int = 160, seed: int = 42) -> np.ndarray:
    rng = np.random.default_rng(seed)
    img = np.full((h, w), 120.0, dtype=np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    # Multi-frequency sinusoidal pattern + sharp high-contrast blobs/squares for strong corners
    img += 35.0 * np.sin(2.0 * np.pi * xx / 23.0) * np.cos(2.0 * np.pi * yy / 19.0)
    img += 25.0 * np.sin(2.0 * np.pi * (xx + yy) / 13.0)
    for _ in range(45):
        cx = int(rng.integers(10, w - 10))
        cy = int(rng.integers(10, h - 10))
        rad = int(rng.integers(3, 8))
        val = float(rng.choice([15.0, 240.0]))
        img[cy - rad:cy + rad, cx - rad:cx + rad] = val
    return np.clip(np.rint(img), 0, 255).astype(np.uint8)


def _shift_image_subpixel(img: np.ndarray, dx: float, dy: float) -> np.ndarray:
    """Shifts img so output(x, y) = img(x - dx, y - dy), i.e. features move by (+dx, +dy)."""
    h, w = img.shape[:2]
    M = np.array([[1.0, 0.0, float(dx)], [0.0, 1.0, float(dy)]], dtype=np.float64)
    return _ops.warpAffine(img, M, (w, h), flags=1, borderMode=1)


def _make_code128_barcode(payload: str = "123456") -> np.ndarray:
    """Generates a valid Code 128B barcode image (pure Python, zero external deps)."""
    # Code 128 patterns (indices 0..106)
    _PATTERNS = {
        " ": "212222", "!": "222122", "\"": "222221", "#": "121223", "$": "121322",
        "%": "131222", "&": "122213", "'": "122312", "(": "132212", ")": "221213",
        "*": "221312", "+": "231212", ",": "112232", "-": "122132", ".": "122231",
        "/": "113222", "0": "123122", "1": "123221", "2": "223211", "3": "221132",
        "4": "221231", "5": "213212", "6": "223112", "7": "312131", "8": "311222",
        "9": "321122", ":": "321221", ";": "312212", "<": "322112", "=": "322211",
        ">": "212123", "?": "212321", "@": "232121", "A": "111323", "B": "131123",
        "C": "131321", "D": "112313", "E": "132113", "F": "132311", "G": "211313",
        "H": "231113", "I": "231311", "J": "112133", "K": "112331", "L": "132131",
        "M": "113123", "N": "113321", "O": "133121", "P": "313121", "Q": "211331",
        "R": "231131", "S": "213113", "T": "213311", "U": "213131", "V": "311123",
        "W": "311321", "X": "331121", "Y": "312113", "Z": "312311",
    }
    _CHARS = list(_PATTERNS.keys())
    _VAL_TO_PAT = {i: _PATTERNS[ch] for i, ch in enumerate(_CHARS)}
    _START_B = (104, "211214")
    _STOP = "2331112"

    codes = [_START_B[0]]
    bars = [_START_B[1]]
    checksum = _START_B[0]
    for pos, ch in enumerate(payload, start=1):
        val = ord(ch) - 32
        codes.append(val)
        bars.append(_VAL_TO_PAT[val])
        checksum += pos * val
    check_val = checksum % 103
    if check_val in _VAL_TO_PAT:
        bars.append(_VAL_TO_PAT[check_val])
    else:
        # Fallback payload if checksum >= len(_VAL_TO_PAT)
        return _make_code128_barcode("12345")
    bars.append(_STOP)

    modules = [0] * 14  # quiet zone
    for pat in bars:
        is_bar = True
        for d in pat:
            modules.extend([1 if is_bar else 0] * int(d))
            is_bar = not is_bar
    modules.extend([0] * 14)

    scale = 3
    w = len(modules) * scale
    h = 120
    img = np.full((h, w), 255, dtype=np.uint8)
    for i, m in enumerate(modules):
        if m:
            img[20:h - 20, i * scale:(i + 1) * scale] = 0
    return img


def _make_qr_via_swift_coreimage(text: str = "SAFARIUM_QR_OK") -> np.ndarray | None:
    """Renders a crisp real QR code using macOS native CoreImage CIQRCodeGenerator."""
    swift_code = f'''
import CoreImage
import AppKit
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue("{text}".data(using: .utf8)!, forKey: "inputMessage")
filter.setValue("M", forKey: "inputCorrectionLevel")
let img = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
let ctx = CIContext()
let cg = ctx.createCGImage(img, from: img.extent)!
let rep = NSBitmapImageRep(cgImage: cg)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
'''
    with tempfile.TemporaryDirectory() as td:
        out_png = os.path.join(td, "qr.png")
        try:
            subprocess.run(["xcrun", "swift", "-e", swift_code, out_png], check=True, timeout=30, capture_output=True)
            from cv2 import _io
            qr = _io.imread(out_png, 0)
            if qr is not None:
                # Pad with generous white quiet zone
                padded = np.full((qr.shape[0] + 40, qr.shape[1] + 40), 255, dtype=np.uint8)
                padded[20:20 + qr.shape[0], 20:20 + qr.shape[1]] = qr
                return padded
        except Exception:
            return None
    return None


# ===========================================================================
# TEST CASES
# ===========================================================================

class TestPhase9Features2D(unittest.TestCase):
    def test_corner_harris_and_min_eigen_val(self):
        board = _make_checkerboard(96, 96, sq=16)
        harris = p.cornerHarris(board, blockSize=3, ksize=3, k=0.04)
        mineig = p.cornerMinEigenVal(board, blockSize=3, ksize=3)
        self.assertEqual(harris.shape, (96, 96))
        self.assertEqual(harris.dtype, np.float32)
        self.assertEqual(mineig.shape, (96, 96))
        # Corner at (32, 32) vs flat interior at (40, 40) vs edge at (32, 40)
        corner_h = float(harris[30:35, 30:35].max())
        flat_h = float(np.abs(harris[38:43, 38:43]).max())
        edge_h = float(harris[38:43, 31:33].min())
        self.assertGreater(corner_h, flat_h * 50.0 + 1e-4)
        self.assertLess(edge_h, corner_h * 0.1)
        corner_m = float(mineig[30:35, 30:35].max())
        flat_m = float(np.abs(mineig[38:43, 38:43]).max())
        self.assertGreater(corner_m, flat_m * 50.0 + 1e-4)

    def test_gftt_and_corner_subpix(self):
        board = _make_checkerboard(112, 112, sq=16)
        corners = p.goodFeaturesToTrack(board, maxCorners=50, qualityLevel=0.05, minDistance=10.0)
        self.assertIsNotNone(corners)
        self.assertEqual(corners.ndim, 3)
        self.assertEqual(corners.shape[2], 2)
        self.assertGreaterEqual(corners.shape[0], 20)

        # Verify every detected corner is close to a true 16px grid intersection
        pts = corners.reshape(-1, 2)
        for x, y in pts:
            dx = abs(x - round(x / 16.0) * 16.0)
            dy = abs(y - round(y / 16.0) * 16.0)
            self.assertLess(max(dx, dy), 2.0)

        # Verify minDistance constraint
        dmat = np.sqrt(((pts[:, None, :] - pts[None, :, :]) ** 2).sum(axis=-1))
        np.fill_diagonal(dmat, 1e9)
        self.assertGreaterEqual(float(dmat.min()), 9.5)

        # Perturb true intersection (47.5, 47.5) and refine via cornerSubPix
        perturbed = np.array([[[48.6, 46.6]], [[32.9, 62.9]]], dtype=np.float32)
        refined = p.cornerSubPix(board, perturbed.copy(), (5, 5), (-1, -1), (p.TERM_CRITERIA_EPS | p.TERM_CRITERIA_MAX_ITER, 40, 1e-4))
        for rx, ry in refined.reshape(-1, 2):
            # In integer grid checkerboard [0..15]=0, [16..31]=1, saddle center is at 15.5, 31.5, 47.5, 63.5
            err_x = min(abs(rx - (round((rx + 0.5) / 16.0) * 16.0 - 0.5)), abs(rx - round(rx / 16.0) * 16.0))
            err_y = min(abs(ry - (round((ry + 0.5) / 16.0) * 16.0 - 0.5)), abs(ry - round(ry / 16.0) * 16.0))
            self.assertLess(max(err_x, err_y), 0.6)

    def test_fast_orb_bfmatcher_and_draw(self):
        img1 = _make_rich_texture(160, 160, seed=7)
        dx_true, dy_true = 8.0, -5.0
        img2 = _shift_image_subpixel(img1, dx_true, dy_true)

        fast = p.FastFeatureDetector_create(threshold=25, nonmaxSuppression=True)
        fkps = fast.detect(img1)
        self.assertGreater(len(fkps), 20)

        orb = p.ORB_create(nfeatures=400, fastThreshold=15, edgeThreshold=16)
        kp1, des1 = orb.detectAndCompute(img1)
        kp2, des2 = orb.detectAndCompute(img2)
        self.assertGreater(len(kp1), 30)
        self.assertEqual(des1.dtype, np.uint8)
        self.assertEqual(des1.shape, (len(kp1), 32))

        bf = p.BFMatcher_create(p.NORM_HAMMING, crossCheck=True)
        matches = bf.match(des1, des2)
        self.assertGreater(len(matches), 15)
        # Check median displacement of top matches matches true shift
        top = matches[:min(25, len(matches))]
        dxs = [kp2[m.trainIdx].pt[0] - kp1[m.queryIdx].pt[0] for m in top]
        dys = [kp2[m.trainIdx].pt[1] - kp1[m.queryIdx].pt[1] for m in top]
        self.assertAlmostEqual(float(np.median(dxs)), dx_true, delta=1.5)
        self.assertAlmostEqual(float(np.median(dys)), dy_true, delta=1.5)

        # BFMatcher L2 + knnMatch(k=2) on synthetic f32 descriptors
        rng = np.random.default_rng(1)
        q_f32 = rng.standard_normal((20, 16)).astype(np.float32)
        t_f32 = np.vstack([q_f32 + 0.01, rng.standard_normal((30, 16)).astype(np.float32)])
        bf_l2 = p.BFMatcher(p.NORM_L2, crossCheck=False)
        knn = bf_l2.knnMatch(q_f32, t_f32, k=2)
        self.assertEqual(len(knn), 20)
        for i, pair in enumerate(knn):
            self.assertEqual(pair[0].trainIdx, i)
            self.assertLess(pair[0].distance, pair[1].distance)

        # drawKeypoints & drawMatches
        vis_kp = p.drawKeypoints(img1, kp1[:20], None, color=(0, 255, 0), flags=4)
        self.assertEqual(vis_kp.shape, (160, 160, 3))
        vis_m = p.drawMatches(img1, kp1, img2, kp2, matches[:10])
        self.assertEqual(vis_m.shape, (160, 320, 3))


class TestPhase10VideoAnalysis(unittest.TestCase):
    def test_phase_correlate_subpixel(self):
        img1 = _make_rich_texture(128, 160, seed=11)
        dx_true, dy_true = 7.3, -4.6
        img2 = _shift_image_subpixel(img1, dx_true, dy_true)
        (sx, sy), resp = p.phaseCorrelate(img1.astype(np.float32), img2.astype(np.float32))
        self.assertLess(abs(sx - dx_true), 0.5, f"sx={sx}, expected {dx_true}")
        self.assertLess(abs(sy - dy_true), 0.5, f"sy={sy}, expected {dy_true}")
        self.assertGreater(resp, 0.1)

    def test_calc_optical_flow_pyr_lk(self):
        img1 = _make_rich_texture(160, 160, seed=13)
        dx_true, dy_true = 5.2, -3.4
        img2 = _shift_image_subpixel(img1, dx_true, dy_true)
        pts0 = p.goodFeaturesToTrack(img1, maxCorners=40, qualityLevel=0.05, minDistance=8.0)
        # Keep interior points well away from border
        p0 = pts0.reshape(-1, 2)
        keep = (p0[:, 0] > 25) & (p0[:, 0] < 135) & (p0[:, 1] > 25) & (p0[:, 1] < 135)
        pts0 = p0[keep].reshape(-1, 1, 2)
        pts1, status, err = p.calcOpticalFlowPyrLK(img1, img2, pts0, winSize=(21, 21), maxLevel=3)
        valid = status.reshape(-1) == 1
        self.assertGreater(int(valid.sum()), 10)
        disp = pts1.reshape(-1, 2)[valid] - pts0.reshape(-1, 2)[valid]
        med_dx, med_dy = float(np.median(disp[:, 0])), float(np.median(disp[:, 1]))
        self.assertLess(abs(med_dx - dx_true), 0.5, f"LK dx={med_dx}")
        self.assertLess(abs(med_dy - dy_true), 0.5, f"LK dy={med_dy}")

    def test_calc_optical_flow_farneback(self):
        img1 = _make_rich_texture(128, 128, seed=17)
        dx_true, dy_true = 3.0, -2.0
        img2 = _shift_image_subpixel(img1, dx_true, dy_true)
        flow = p.calcOpticalFlowFarneback(img1, img2, None, 0.5, 3, 15, 3, 5, 1.2, 0)
        self.assertEqual(flow.shape, (128, 128, 2))
        self.assertEqual(flow.dtype, np.float32)
        crop = flow[24:104, 24:104]
        med_dx = float(np.median(crop[:, :, 0]))
        med_dy = float(np.median(crop[:, :, 1]))
        self.assertLess(abs(med_dx - dx_true), 0.5, f"Farneback dx={med_dx}")
        self.assertLess(abs(med_dy - dy_true), 0.5, f"Farneback dy={med_dy}")

    def test_mog2_background_subtractor(self):
        rng = np.random.default_rng(21)
        bg = np.full((64, 64, 3), 80, dtype=np.uint8)
        mog2 = p.createBackgroundSubtractorMOG2(history=50, varThreshold=16.0, detectShadows=True)
        for _ in range(25):
            noise = rng.integers(-2, 3, size=bg.shape, dtype=np.int16)
            frame = np.clip(bg.astype(np.int16) + noise, 0, 255).astype(np.uint8)
            _ = mog2.apply(frame)
        # Introduce bright foreground square
        fg_frame = bg.copy()
        fg_frame[20:40, 25:45] = [230, 230, 230]
        mask = mog2.apply(fg_frame, learningRate=0.0)
        self.assertEqual(mask.shape, (64, 64))
        self.assertGreater(float((mask[22:38, 27:43] == 255).mean()), 0.95)
        self.assertGreater(float((mask[:15, :15] == 0).mean()), 0.95)

    def test_mean_shift_and_camshift(self):
        yy, xx = np.mgrid[0:100, 0:100].astype(np.float32)
        tx, ty = 62.0, 48.0
        prob = (255.0 * np.exp(-((xx - tx) ** 2 / 70.0 + (yy - ty) ** 2 / 30.0))).astype(np.uint8)
        crit = (p.TERM_CRITERIA_EPS | p.TERM_CRITERIA_COUNT, 20, 1.0)
        iters, win = p.meanShift(prob, (45, 35, 24, 24), crit)
        self.assertGreaterEqual(iters, 1)
        cx = win[0] + win[2] * 0.5
        cy = win[1] + win[3] * 0.5
        self.assertLess(math.hypot(cx - tx, cy - ty), 2.5)

        rot_rect, cam_win = p.CamShift(prob, (45, 35, 24, 24), crit)
        (rcx, rcy), (rw, rh), angle = rot_rect
        self.assertLess(math.hypot(rcx - tx, rcy - ty), 2.5)
        self.assertGreater(rw, 1.0)
        self.assertGreater(rh, 1.0)

    def test_find_transform_ecc(self):
        tmpl = _make_rich_texture(128, 128, seed=29)
        dx_true, dy_true = 4.5, -3.2
        # For ECC: input(x + tx, y + ty) = tmpl(x, y) => input is tmpl shifted by (+dx, +dy)
        inp = _shift_image_subpixel(tmpl, dx_true, dy_true)
        warp = np.eye(2, 3, dtype=np.float32)
        cc, warp_out = p.findTransformECC(tmpl, inp, warp, p.MOTION_TRANSLATION, (3, 60, 1e-4))
        self.assertGreater(cc, 0.95)
        self.assertLess(abs(float(warp_out[0, 2]) - dx_true), 0.5)
        self.assertLess(abs(float(warp_out[1, 2]) - dy_true), 0.5)

        # Euclidean & Affine (small 3-deg rotation + translation)
        ang = math.radians(3.0)
        c, s = math.cos(ang), math.sin(ang)
        W_fwd = np.array([[c, -s, 2.0], [s, c, -1.0]], dtype=np.float64)
        inp_rot = _ops.warpAffine(tmpl, W_fwd, (128, 128), flags=1, borderMode=1)
        cc_e, W_e = p.findTransformECC(tmpl, inp_rot, np.eye(2, 3, dtype=np.float32), p.MOTION_EUCLIDEAN, (3, 80, 1e-4))
        self.assertGreater(cc_e, 0.95)
        self.assertLess(abs(float(W_e[1, 0]) - s), 0.01)
        cc_a, W_a = p.findTransformECC(tmpl, inp_rot, np.eye(2, 3, dtype=np.float32), p.MOTION_AFFINE, (3, 80, 1e-4))
        self.assertGreater(cc_a, 0.95)
        self.assertLess(abs(float(W_a[0, 2]) - 2.0), 0.5)


class TestPhase11CalibStereo(unittest.TestCase):
    def test_find_homography_ransac_and_lmeds(self):
        H_true = np.array([
            [1.08, -0.12, 24.0],
            [0.09, 0.95, -14.0],
            [0.0004, -0.0003, 1.0],
        ], dtype=np.float64)
        rng = np.random.default_rng(31)
        src = rng.uniform(10, 200, size=(40, 2))
        dst = p.perspectiveTransform(src.reshape(-1, 1, 2), H_true).reshape(-1, 2)

        # Clean DLT
        H_dlt, _ = p.findHomography(src, dst, method=0)
        self.assertLess(float(np.abs(H_dlt - H_true).max()), 1e-5)

        # RANSAC with 10 gross outliers (25%)
        dst_noisy = dst.copy()
        dst_noisy[:10] += rng.uniform(50, 120, size=(10, 2))
        H_ran, mask = p.findHomography(src, dst_noisy, method=p.RANSAC, ransacReprojThreshold=2.0)
        self.assertLess(float(np.abs(H_ran - H_true).max()), 1e-3)
        self.assertEqual(int(mask[:10].sum()), 0)
        self.assertEqual(int(mask[10:].sum()), 30)

        # LMEDS
        H_lmeds, _ = p.findHomography(src, dst_noisy, method=p.LMEDS)
        self.assertLess(float(np.abs(H_lmeds - H_true).max()), 1e-3)

    def test_rodrigues_roundtrip(self):
        for vec in [
            np.array([0.0, 0.0, 0.0]),
            np.array([0.3, -0.5, 0.8]),
            np.array([math.pi, 0.0, 0.0]),
            np.array([0.0, 0.0, math.pi * 0.99999]),
        ]:
            R, jac1 = p.Rodrigues(vec)
            self.assertEqual(R.shape, (3, 3))
            self.assertLess(float(np.abs(R.T @ R - np.eye(3)).max()), 1e-10)
            self.assertAlmostEqual(float(np.linalg.det(R)), 1.0, places=10)
            vec2, jac2 = p.Rodrigues(R)
            R2, _ = p.Rodrigues(vec2)
            self.assertLess(float(np.abs(R2 - R).max()), 1e-6)
            if np.linalg.norm(vec) < math.pi - 1e-3:
                self.assertLess(float(np.linalg.norm(vec2.reshape(3) - vec)), 1e-6)

    def test_solve_pnp_and_project_points(self):
        K = np.array([[600.0, 0.0, 320.0], [0.0, 600.0, 240.0], [0.0, 0.0, 1.0]], dtype=np.float64)
        dist = np.array([-0.15, 0.05, 0.002, -0.001, 0.01], dtype=np.float64)
        rvec_true = np.array([0.25, -0.35, 0.15], dtype=np.float64)
        tvec_true = np.array([0.4, -0.2, 5.5], dtype=np.float64)

        # Non-planar 3D points
        rng = np.random.default_rng(37)
        obj3d = rng.uniform(-1.5, 1.5, size=(16, 3))
        img2d, _ = p.projectPoints(obj3d, rvec_true, tvec_true, K, dist)
        ok, r_est, t_est = p.solvePnP(obj3d, img2d, K, dist)
        self.assertTrue(ok)
        reproj, _ = p.projectPoints(obj3d, r_est, t_est, K, dist)
        rms = float(np.sqrt(np.mean((reproj - img2d) ** 2)))
        self.assertLess(rms, 0.05, f"3D PnP RMS={rms}")
        self.assertLess(float(np.linalg.norm(r_est.reshape(3) - rvec_true)), 1e-3)
        self.assertLess(float(np.linalg.norm(t_est.reshape(3) - tvec_true)), 1e-3)

        # Planar Z=0 points (chessboard calibration case)
        gx, gy = np.meshgrid(np.linspace(-1.0, 1.0, 4), np.linspace(-1.0, 1.0, 4))
        obj_plane = np.stack([gx.ravel(), gy.ravel(), np.zeros(16)], axis=1)
        img_plane, _ = p.projectPoints(obj_plane, rvec_true, tvec_true, K, dist)
        ok_p, rp_est, tp_est = p.solvePnP(obj_plane, img_plane, K, dist)
        self.assertTrue(ok_p)
        reproj_p, _ = p.projectPoints(obj_plane, rp_est, tp_est, K, dist)
        rms_p = float(np.sqrt(np.mean((reproj_p - img_plane) ** 2)))
        self.assertLess(rms_p, 0.05, f"Planar PnP RMS={rms_p}")

    def test_undistort_and_undistort_points(self):
        K = np.array([[200.0, 0.0, 64.0], [0.0, 200.0, 64.0], [0.0, 0.0, 1.0]], dtype=np.float64)
        dist = np.array([-0.2, 0.05, 0.001, -0.001, 0.0], dtype=np.float64)
        obj = np.array([[0.1, 0.2, 1.0], [-0.25, 0.15, 1.0], [0.3, -0.2, 1.0]], dtype=np.float64)
        dist_pts, _ = p.projectPoints(obj, np.zeros(3), np.zeros(3), K, dist)
        undist_norm = p.undistortPoints(dist_pts, K, dist).reshape(-1, 2)
        self.assertLess(float(np.abs(undist_norm - obj[:, :2]).max()), 1e-6)

        m1, m2 = p.initUndistortRectifyMap(K, dist, None, K, (128, 128))
        self.assertEqual(m1.shape, (128, 128))
        self.assertEqual(m2.shape, (128, 128))
        # Center optical axis (64, 64) should map to itself
        self.assertAlmostEqual(float(m1[64, 64]), 64.0, delta=1e-4)
        self.assertAlmostEqual(float(m2[64, 64]), 64.0, delta=1e-4)

        img = _make_checkerboard(128, 128, sq=16)
        und = p.undistort(img, K, dist)
        self.assertEqual(und.shape, img.shape)

    def test_stereo_bm_known_disparity(self):
        # Create textured left image, and right image shifted left by d=12 px so left(x) == right(x - 12)
        left = _make_rich_texture(96, 160, seed=41)
        d_true = 12
        right = np.zeros_like(left)
        right[:, :160 - d_true] = left[:, d_true:]
        stereo = p.StereoBM_create(numDisparities=32, blockSize=11)
        disp16 = stereo.compute(left, right)
        self.assertEqual(disp16.dtype, np.int16)
        self.assertEqual(disp16.shape, left.shape)
        # Interior region where overlap is full
        roi = disp16[16:80, 40:140].astype(np.float32) / 16.0
        valid = roi[roi >= 0]
        self.assertGreater(valid.size, 1000)
        med = float(np.median(valid))
        self.assertLess(abs(med - d_true), 0.5, f"StereoBM median disp={med}, expected {d_true}")


class TestPhase12ObjDetect(unittest.TestCase):
    def test_aruco_generate_and_detect_roundtrip(self):
        for dict_id, marker_ids in [
            (p.aruco.DICT_4X4_50, [3, 17]),
            (p.aruco.DICT_5X5_100, [42]),
            (p.aruco.DICT_6X6_250, [123]),
        ]:
            d = p.aruco.getPredefinedDictionary(dict_id)
            canvas = np.full((220, 320), 245, dtype=np.uint8)
            for idx, mid in enumerate(marker_ids):
                m = p.aruco.generateImageMarker(d, mid, 80, borderBits=1)
                self.assertEqual(m.shape, (80, 80))
                if idx == 1:
                    m = np.rot90(m, k=1)  # verify 90-deg rotation invariance!
                x0 = 35 + idx * 140
                y0 = 60
                canvas[y0:y0 + 80, x0:x0 + 80] = m

            det = p.aruco.ArucoDetector(d, p.aruco.DetectorParameters())
            corners, ids, _ = det.detectMarkers(canvas)
            self.assertIsNotNone(ids, f"Failed to detect markers for dict {dict_id}")
            found = sorted(int(v) for v in ids.ravel())
            self.assertEqual(found, sorted(marker_ids))
            self.assertEqual(len(corners), len(marker_ids))

    def test_vision_barcode_and_qr(self):
        # 1. Code 128 barcode via Apple Vision VNDetectBarcodesRequest
        bc_img = _make_code128_barcode("123456")
        bc_det = p.barcode.BarcodeDetector()
        ok, texts, types_, pts = bc_det.detectAndDecodeWithType(bc_img)
        self.assertTrue(ok, "Vision BarcodeDetector failed to detect generated Code-128")
        self.assertIn("123456", texts)
        self.assertEqual(pts.shape[1:], (4, 2))

        # 2. QR Code via Apple Vision VNDetectBarcodesRequest
        qr_img = _make_qr_via_swift_coreimage("SAFARIUM_QR_OK")
        if qr_img is not None:
            qr_det = p.QRCodeDetector()
            decoded, qpts, _ = qr_det.detectAndDecode(qr_img)
            self.assertEqual(decoded, "SAFARIUM_QR_OK")
            self.assertIsNotNone(qpts)
            self.assertEqual(qpts.shape, (1, 4, 2))
        else:
            # Verify clean empty behavior if CoreImage helper unavailable
            qr_det = p.QRCodeDetector()
            decoded, qpts, _ = qr_det.detectAndDecode(np.full((64, 64), 255, dtype=np.uint8))
            self.assertEqual(decoded, "")


class TestPhase13DNN(unittest.TestCase):
    def test_blob_from_image_and_images(self):
        img = np.zeros((40, 60, 3), dtype=np.uint8)
        img[:, :, 0] = 10   # B
        img[:, :, 1] = 50   # G
        img[:, :, 2] = 200  # R
        blob = p.dnn.blobFromImage(img, scalefactor=1.0 / 255.0, size=(32, 24), mean=(10, 50, 100), swapRB=True)
        self.assertEqual(blob.shape, (1, 3, 24, 32))
        self.assertEqual(blob.dtype, np.float32)
        # Channel 0 is R (200 - 100) / 255
        self.assertAlmostEqual(float(blob[0, 0].mean()), 100.0 / 255.0, places=3)
        self.assertAlmostEqual(float(blob[0, 1].mean()), 0.0, places=3)
        self.assertAlmostEqual(float(blob[0, 2].mean()), 0.0, places=3)

        blobs = p.dnn.blobFromImages([img, img], size=(16, 16))
        self.assertEqual(blobs.shape, (2, 3, 16, 16))

    def test_nms_boxes_and_coreml_error_handling(self):
        boxes = [
            [10, 10, 50, 50],  # score 0.9 -> keep
            [12, 12, 50, 50],  # heavy overlap with 0, score 0.8 -> suppress
            [100, 100, 40, 40],  # disjoint, score 0.7 -> keep
            [200, 200, 30, 30],  # score 0.2 < threshold 0.5 -> filter
        ]
        scores = [0.9, 0.8, 0.7, 0.2]
        kept = p.dnn.NMSBoxes(boxes, scores, score_threshold=0.5, nms_threshold=0.4)
        self.assertEqual(kept.tolist(), [0, 2])

        with self.assertRaises(p.error):
            p.dnn.readNet("/nonexistent/path/model.mlmodelc")


class TestPhase14PointCloud3D(unittest.TestCase):
    def test_ply_roundtrip_normals_and_voxel(self):
        # Points on tilted plane z = 0.3*x - 0.5*y + 2.0
        gx, gy = np.meshgrid(np.linspace(-2.0, 2.0, 15), np.linspace(-2.0, 2.0, 15))
        x = gx.ravel()
        y = gy.ravel()
        z = 0.3 * x - 0.5 * y + 2.0
        pts = np.stack([x, y, z], axis=1).astype(np.float32)
        cols = np.tile(np.array([[100, 150, 200]], dtype=np.uint8), (pts.shape[0], 1))

        nrms = p.computeNormals(pts, k=12)
        self.assertEqual(nrms.shape, pts.shape)
        true_n = np.array([-0.3, 0.5, 1.0], dtype=np.float32)
        true_n /= np.linalg.norm(true_n)
        dots = np.abs(nrms @ true_n)
        self.assertGreater(float(dots.min()), 0.999)

        with tempfile.TemporaryDirectory() as td:
            ply_path = os.path.join(td, "cloud.ply")
            self.assertTrue(p.writePLY(ply_path, pts, colors=cols, normals=nrms))
            pts2, cols2, nrms2 = p.readPLY(ply_path)
            self.assertLess(float(np.abs(pts2 - pts).max()), 1e-4)
            self.assertTrue(np.array_equal(cols2, cols))
            self.assertLess(float(np.abs(nrms2 - nrms).max()), 1e-4)

        ds_pts, ds_cols = p.voxelDownsample(pts, voxel_size=0.8, colors=cols)
        self.assertLess(ds_pts.shape[0], pts.shape[0])
        self.assertGreater(ds_pts.shape[0], 10)
        self.assertEqual(ds_cols.shape, (ds_pts.shape[0], 3))


class TestPhase15StitchingFlannCCM(unittest.TestCase):
    def test_stitcher_two_overlapping_images(self):
        # Full panoramic scene split into 2 overlapping crops
        scene = _make_rich_texture(140, 240, seed=53)
        img1 = scene[:, :160].copy()
        img2 = scene[:, 80:].copy()  # 80px horizontal overlap
        stitcher = p.Stitcher_create()
        status, pano = stitcher.stitch([img1, img2])
        self.assertEqual(status, p.STITCHER_OK)
        self.assertIsNotNone(pano)
        self.assertGreaterEqual(pano.shape[1], 220)
        self.assertGreaterEqual(pano.shape[0], 130)

    def test_flann_index_knn_accuracy(self):
        rng = np.random.default_rng(59)
        db = rng.standard_normal((400, 16)).astype(np.float32)
        queries = rng.standard_normal((25, 16)).astype(np.float32)
        idx = p.flann.Index(db)
        found_idx, found_d2 = idx.knnSearch(queries, knn=5)
        self.assertEqual(found_idx.shape, (25, 5))
        # Compare against exact brute force
        bf_d2 = ((queries[:, None, :] - db[None, :, :]) ** 2).sum(axis=-1)
        bf_idx = np.argsort(bf_d2, axis=1)[:, :5]
        self.assertTrue(np.array_equal(found_idx, bf_idx))

    def test_ccm_color_correction(self):
        rng = np.random.default_rng(61)
        ref = rng.uniform(0.1, 0.9, size=(24, 3))
        M_true = np.array([
            [1.15, -0.05, 0.02],
            [0.04, 0.92, -0.03],
            [-0.02, 0.06, 1.08],
        ], dtype=np.float64)
        src = ref @ np.linalg.inv(M_true)
        model = p.ccm.ColorCorrectionModel(src, ref)
        model.run()
        M_est = model.getCCM()
        self.assertLess(float(np.abs(M_est - M_true).max()), 1e-6)
        corrected = model.infer(src)
        self.assertLess(float(np.abs(corrected - ref).max()), 1e-6)


class TestPhase16AndContrib(unittest.TestCase):
    def test_file_storage_json_yaml_xml(self):
        mat = np.array([[1.5, 2.5, 3.5], [4.5, 5.5, 6.5]], dtype=np.float64)
        with tempfile.TemporaryDirectory() as td:
            for ext in (".json", ".yml", ".xml"):
                fpath = os.path.join(td, f"calib{ext}")
                with p.FileStorage(fpath, p.FILE_STORAGE_WRITE) as fs:
                    self.assertTrue(fs.isOpened())
                    fs.write("camera_matrix", mat)
                    fs.write("width", 1920)
                    fs.write("label", "safarium")
                with p.FileStorage(fpath, p.FILE_STORAGE_READ) as fs:
                    self.assertTrue(fs.isOpened())
                    mat_out = fs.getNode("camera_matrix").mat()
                    self.assertTrue(np.allclose(mat_out, mat))
                    self.assertEqual(int(fs.getNode("width").real()), 1920)
                    self.assertEqual(fs.getNode("label").string(), "safarium")

    def test_tick_meter(self):
        tm = p.TickMeter()
        tm.start()
        time.sleep(0.01)
        tm.stop()
        self.assertEqual(tm.getCounter(), 1)
        self.assertGreater(tm.getTimeMilli(), 5.0)
        self.assertGreater(tm.getFPS(), 0.0)
        tm.reset()
        self.assertEqual(tm.getCounter(), 0)

    def test_ximgproc_guided_filter_and_thinning(self):
        # Step edge + noise: guided filter should smooth flat regions while keeping edge sharp
        rng = np.random.default_rng(67)
        guide = np.zeros((64, 64), dtype=np.uint8)
        guide[:, 32:] = 200
        noisy = np.clip(guide.astype(np.int16) + rng.integers(-20, 21, size=guide.shape), 0, 255).astype(np.uint8)
        filtered = p.ximgproc.guidedFilter(guide, noisy, radius=4, eps=100.0)
        self.assertEqual(filtered.shape, guide.shape)
        self.assertLess(float(filtered[:, :24].std()), float(noisy[:, :24].std()) * 0.4)
        self.assertGreater(float(filtered[:, 40:].mean() - filtered[:, :24].mean()), 180.0)

        # 3-channel color guide
        guide_rgb = np.stack([guide, guide, guide], axis=-1)
        noisy_rgb = np.stack([noisy, noisy, noisy], axis=-1)
        filt_rgb = p.ximgproc.guidedFilter(guide_rgb, noisy_rgb, radius=3, eps=100.0)
        self.assertEqual(filt_rgb.shape, guide_rgb.shape)

        # Thinning a thick binary cross
        cross = np.zeros((64, 64), dtype=np.uint8)
        cross[26:38, 10:54] = 255
        cross[10:54, 26:38] = 255
        skel_zs = p.ximgproc.thinning(cross, thinningType=p.ximgproc.THINNING_ZHANGSUEN)
        skel_gh = p.ximgproc.thinning(cross, thinningType=p.ximgproc.THINNING_GUOHALL)
        for skel in (skel_zs, skel_gh):
            fg = int((skel == 255).sum())
            self.assertGreater(fg, 40)
            self.assertLess(fg, 200)  # significantly thinned from ~912 foreground pixels

    def test_xphoto_wb_and_oil_painting(self):
        # Color-cast image (strong blue/red imbalance around neutral gray)
        rng = np.random.default_rng(71)
        base = rng.integers(60, 140, size=(64, 64), dtype=np.uint8)
        cast = np.stack([
            np.clip(base * 0.6, 0, 255).astype(np.uint8),
            base,
            np.clip(base * 1.4, 0, 255).astype(np.uint8),
        ], axis=-1)

        gw = p.xphoto.createGrayworldWB()
        bal_gw = gw.balanceWhite(cast)
        means = bal_gw.reshape(-1, 3).mean(axis=0)
        self.assertLess(float(means.max() - means.min()), 8.0)

        swb = p.xphoto.createSimpleWB()
        bal_swb = swb.balanceWhite(cast)
        self.assertEqual(bal_swb.shape, cast.shape)
        self.assertGreater(int(bal_swb.max()), 240)
        self.assertLess(int(bal_swb.min()), 15)

        oil = p.xphoto.oilPainting(cast, size=3, dynRatio=16)
        self.assertEqual(oil.shape, cast.shape)
        self.assertEqual(oil.dtype, np.uint8)

    def test_tracker_csrt(self):
        # Textured moving object on dark background across 6 frames
        base = np.full((140, 160), 30, dtype=np.uint8)
        patch = _make_rich_texture(32, 32, seed=79)
        x0, y0 = 30, 30
        frame0 = base.copy()
        frame0[y0:y0 + 32, x0:x0 + 32] = patch

        tracker = p.TrackerCSRT_create()
        self.assertTrue(tracker.init(frame0, (x0, y0, 32, 32)))

        for step in range(1, 7):
            tx = x0 + step * 3
            ty = y0 + step * 2
            fr = base.copy()
            fr[ty:ty + 32, tx:tx + 32] = patch
            ok, bbox = tracker.update(fr)
            self.assertTrue(ok)
        bx, by, bw, bh = bbox
        self.assertLess(abs(bx - (x0 + 18)), 3, f"Tracker x={bx}, expected {x0 + 18}")
        self.assertLess(abs(by - (y0 + 12)), 3, f"Tracker y={by}, expected {y0 + 12}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
