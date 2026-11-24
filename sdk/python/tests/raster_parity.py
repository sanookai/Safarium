"""Parity metrics for SafariumRaster vs reference OpenCV (Pick 2026-11-24: Safarium's cross-engine bar).

PASS = SSIM >= 0.97 and PSNR >= 30 dB and DeltaE00 p95 <= 2 (colour images), per op / fixture.
Never lower these silently: report real numbers to Pick.

Usage inside a parity test (run with the reference venv python, which has real cv2 as `cv2_ref`):
    from raster_parity import compare, load_pair
    ref_cv2, sr_cv2 = load_pair()
    r = compare(ref_img, sr_img, "circle_aa")
    assert r.ok, r
"""
from __future__ import annotations

import importlib
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

SSIM_MIN = 0.97
PSNR_MIN = 30.0
DE00_P95_MAX = 2.0

SHIM_ROOT = Path(__file__).resolve().parents[1] / "safarium_cv2"


def load_pair():
    """Return (reference cv2 from site-packages, Safarium shim cv2) loaded side by side."""
    saved = sys.modules.pop("cv2", None)
    ref = importlib.import_module("cv2")
    sys.modules["cv2_ref"] = ref
    del sys.modules["cv2"]
    for k in [k for k in sys.modules if k.startswith("cv2.")]:
        sys.modules["cv2_ref" + k[3:]] = sys.modules.pop(k)
    sys.path.insert(0, str(SHIM_ROOT))
    try:
        shim = importlib.import_module("cv2")
    finally:
        sys.path.remove(str(SHIM_ROOT))
    if saved is not None and saved is not ref:
        pass
    assert getattr(shim, "__version__", "").startswith("safarium"), "shim not loaded"
    return ref, shim


@dataclass
class Result:
    name: str
    ssim: float
    psnr: float
    de00_p95: float | None
    max_abs: float

    @property
    def ok(self) -> bool:
        de_ok = self.de00_p95 is None or self.de00_p95 <= DE00_P95_MAX
        return self.ssim >= SSIM_MIN and self.psnr >= PSNR_MIN and de_ok

    def __str__(self) -> str:
        de = "n/a" if self.de00_p95 is None else f"{self.de00_p95:.3f}"
        return (f"{'PASS' if self.ok else 'FAIL'} {self.name}: SSIM={self.ssim:.4f} "
                f"PSNR={self.psnr:.2f}dB dE00p95={de} maxabs={self.max_abs:g}")


def _to_float(a: np.ndarray) -> tuple[np.ndarray, float]:
    if a.dtype == np.uint8:
        return a.astype(np.float64), 255.0
    if a.dtype == np.uint16:
        return a.astype(np.float64), 65535.0
    f = a.astype(np.float64)
    rng = float(max(1e-12, np.nanmax(np.abs(f)))) if f.size else 1.0
    return f, max(rng, 1.0)


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    fa, peak = _to_float(a)
    fb, _ = _to_float(b)
    mse = float(np.mean((fa - fb) ** 2))
    if mse == 0:
        return float("inf")
    return 10.0 * np.log10(peak * peak / mse)


def _gauss_filter(x: np.ndarray, sigma: float = 1.5, radius: int = 5) -> np.ndarray:
    t = np.arange(-radius, radius + 1, dtype=np.float64)
    k = np.exp(-(t * t) / (2 * sigma * sigma))
    k /= k.sum()
    pad = np.pad(x, radius, mode="reflect")
    y = np.apply_along_axis(lambda r: np.convolve(r, k, mode="valid"), 1, pad)
    y = np.apply_along_axis(lambda c: np.convolve(c, k, mode="valid"), 0, y)
    return y


def ssim(a: np.ndarray, b: np.ndarray) -> float:
    """Mean SSIM (Wang et al. 2004, Gaussian 11x11 sigma 1.5), averaged over channels."""
    fa, peak = _to_float(a)
    fb, _ = _to_float(b)
    if fa.ndim == 2:
        fa, fb = fa[..., None], fb[..., None]
    c1, c2 = (0.01 * peak) ** 2, (0.03 * peak) ** 2
    vals = []
    for ch in range(fa.shape[2]):
        x, y = fa[..., ch], fb[..., ch]
        if min(x.shape) < 11:
            vals.append(1.0 if np.array_equal(x, y) else float(1 - np.mean(np.abs(x - y)) / peak))
            continue
        mx, my = _gauss_filter(x), _gauss_filter(y)
        sxx = _gauss_filter(x * x) - mx * mx
        syy = _gauss_filter(y * y) - my * my
        sxy = _gauss_filter(x * y) - mx * my
        m = ((2 * mx * my + c1) * (2 * sxy + c2)) / ((mx * mx + my * my + c1) * (sxx + syy + c2))
        vals.append(float(m.mean()))
    return float(np.mean(vals))


def _srgb_to_lab(bgr_u8: np.ndarray) -> np.ndarray:
    rgb = bgr_u8[..., 2::-1].astype(np.float64) / 255.0
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124564, 0.3575761, 0.1804375],
                  [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    xyz = lin @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    L = 116 * f[..., 1] - 16
    A = 500 * (f[..., 0] - f[..., 1])
    B = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, A, B], -1)


def delta_e00(lab1: np.ndarray, lab2: np.ndarray) -> np.ndarray:
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1
    dCp = C2p - C1p
    dh = h2p - h1p
    dh = np.where(C1p * C2p == 0, 0, np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh)))
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2))
    Lbp = (L1 + L2) / 2
    Cbp = (C1p + C2p) / 2
    hsum = h1p + h2p
    hbp = np.where(C1p * C2p == 0, hsum,
                   np.where(np.abs(h1p - h2p) <= 180, hsum / 2,
                            np.where(hsum < 360, (hsum + 360) / 2, (hsum - 360) / 2)))
    T = (1 - 0.17 * np.cos(np.radians(hbp - 30)) + 0.24 * np.cos(np.radians(2 * hbp))
         + 0.32 * np.cos(np.radians(3 * hbp + 6)) - 0.20 * np.cos(np.radians(4 * hbp - 63)))
    dtheta = 30 * np.exp(-(((hbp - 275) / 25) ** 2))
    Rc = 2 * np.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / np.sqrt(20 + (Lbp - 50) ** 2)
    Sc = 1 + 0.045 * Cbp
    Sh = 1 + 0.015 * Cbp * T
    Rt = -np.sin(np.radians(2 * dtheta)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))


def compare(ref: np.ndarray, got: np.ndarray, name: str) -> Result:
    if ref.shape != got.shape or ref.dtype != got.dtype:
        return Result(f"{name} [shape/dtype {ref.shape}{ref.dtype} vs {got.shape}{got.dtype}]", 0.0, 0.0, None, float("inf"))
    de = None
    if ref.dtype == np.uint8 and ref.ndim == 3 and ref.shape[2] >= 3:
        de = float(np.percentile(delta_e00(_srgb_to_lab(ref[..., :3]), _srgb_to_lab(got[..., :3])), 95))
    max_abs = float(np.max(np.abs(ref.astype(np.float64) - got.astype(np.float64)))) if ref.size else 0.0
    return Result(name, ssim(ref, got), psnr(ref, got), de, max_abs)


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    r = compare(np.zeros((32, 32, 3), np.uint8), np.zeros((32, 32, 3), np.uint8), "self-check")
    print(r)
    assert r.ok
