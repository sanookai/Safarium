"""Shared input generators and float64 reference ("truth") implementations for the benchmark cases.
numpy only at import time (Pillow is imported lazily), so the parent can import the registry cheaply."""
from __future__ import annotations

import io
import os
from pathlib import Path

import numpy as np

# .../Projects/Safarium/sdk/python/tests/bench_cases/_common.py -> parents[5] is .../Projects
SOMPONG = Path(os.environ.get("BENCH_SOMPONG_DIR") or os.environ.get("SAFARIUM_BENCH_ASSETS_DIR", "/nonexistent-safarium-bench-assets"))
KODAK = Path(os.environ.get("SCRATCH", "/nonexistent")) / "kodak"
H, W = 1920, 1080          # Reels frame: 1080 wide x 1920 high (shape (1920, 1080, 3))
_CACHE: dict = {}


def pil_decode_bgr(buf):
    """Neutral decoder for encoder outputs: Pillow reads the bytes the engine produced."""
    from PIL import Image
    im = Image.open(io.BytesIO(np.asarray(buf, dtype=np.uint8).tobytes()))
    im.load()
    if im.mode in ("L", "I;16", "F"):
        return np.asarray(im)
    return np.ascontiguousarray(np.asarray(im.convert("RGB"))[..., ::-1])


def synth_frame(h, w, seed=7):
    """Smooth gradient + blobs + hard-edged rectangles + mild noise: stands in for a frame when no real one exists."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.stack([60 + 120 * yy / h, 90 + 100 * xx / w, 150 - 80 * yy / h], -1)
    for _ in range(12):
        cy, cx, r = rng.integers(0, h), rng.integers(0, w), rng.integers(min(h, w) // 12, min(h, w) // 4)
        m = (yy - cy) ** 2 + (xx - cx) ** 2 < r * r
        img[m] = rng.integers(20, 235, 3)
    for _ in range(8):
        y0, x0 = rng.integers(0, h - 8), rng.integers(0, w - 8)
        img[y0:y0 + rng.integers(4, h // 6), x0:x0 + rng.integers(4, w // 3)] = rng.integers(0, 255, 3)
    img += rng.normal(0, 2.0, img.shape).astype(np.float32)
    return np.clip(img, 0, 255).astype(np.uint8)


SYNTH_USED = False     # True once any case input fell back to a synthetic frame (reported per row as SYNTH)


def frame_is_real():
    """True when sompong_frame() returned a real Sompong episode frame rather than the synthetic fallback."""
    sompong_frame()
    return not SYNTH_USED


def sompong_frame():
    """A real Sompong frame (episode cover, 1080x1920 RGB -> BGR u8). If none can be loaded the synthetic fallback is
    used LOUDLY: SYNTH_USED is set, stderr gets a warning, and bench_raster marks every affected row SYNTH."""
    global SYNTH_USED
    if "sompong" in _CACHE:
        return _CACHE["sompong"].copy()
    candidates = [os.environ["BENCH_FRAME"]] if os.environ.get("BENCH_FRAME") else \
        [str(p) for p in sorted(SOMPONG.glob("episodes/*/cover.jpg"))]
    img = None
    for path in candidates:
        if os.path.exists(path):
            from PIL import Image
            im = Image.open(path).convert("RGB")
            if im.size == (W, H):
                img = np.ascontiguousarray(np.asarray(im)[..., ::-1])
                break
    if img is None:
        SYNTH_USED = True
        import sys
        print(f"WARNING: no real Sompong frame found under {SOMPONG} (set BENCH_FRAME / BENCH_SOMPONG_DIR); "
              "using a SYNTHETIC frame - *_sompong cases are NOT real-frame results", file=sys.stderr)
        img = synth_frame(H, W)
    _CACHE["sompong"] = img
    return img.copy()


def second_frame():
    return np.ascontiguousarray(sompong_frame()[::-1, ::-1])   # same statistics, different pixels


def kodak_frame():
    """Kodak24 image if downloaded in scratch (public dataset, scratch only), else a synthetic 768x512."""
    f = KODAK / "kodim15.png"
    if f.exists():
        from PIL import Image
        return np.ascontiguousarray(np.asarray(Image.open(f).convert("RGB"))[..., ::-1])
    return synth_frame(512, 768, seed=15)


def crop512(img):
    h, w = img.shape[:2]
    y, x = (h - 512) // 2, (w - 512) // 2
    return np.ascontiguousarray(img[y:y + 512, x:x + 512])


def gray_of(bgr):
    return np.ascontiguousarray(bgr[..., 1])


def blob_mask(h, w, seed=3, thresh=0.52, cell=16):
    """Small smooth binary mask (0/255), for exact distance-transform truth."""
    rng = np.random.default_rng(seed)
    small = rng.random((h // cell + 2, w // cell + 2)).astype(np.float32)
    up = np.kron(small, np.ones((cell, cell), np.float32))[:h, :w]
    k = np.ones(2 * cell // 2 + 1, np.float32)
    k /= k.sum()
    up = np.apply_along_axis(lambda r: np.convolve(r, k, "same"), 1, up)
    up = np.apply_along_axis(lambda c: np.convolve(c, k, "same"), 0, up)
    return np.where(up > np.median(up) * thresh / 0.5, 255, 0).astype(np.uint8)


def mask_from_frame(frame):
    """Binary mask of a real frame: 7x7 box-smoothed green channel above its mean (many realistic regions)."""
    g = frame[..., 1].astype(np.float64)
    c = np.cumsum(np.cumsum(np.pad(g, ((4, 3), (4, 3)), mode="edge"), 0), 1)
    box = (c[7:, 7:] - c[:-7, 7:] - c[7:, :-7] + c[:-7, :-7]) / 49.0
    return np.where(box > box.mean(), 255, 0).astype(np.uint8)


def analytic_f(x, y):
    """Band-limited analytic test signal (shortest wavelength ~53 px): exact truth for geometric warps."""
    return (110.0 + 60.0 * np.sin(2 * np.pi * (x / 97.0 + y / 131.0)) + 40.0 * np.cos(2 * np.pi * (x / 53.0 - y / 71.0)))


def analytic_image(h, w, dtype=np.float32):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    return analytic_f(xx, yy).astype(dtype)


# ----------------------------------------------------------------------------- float64 truths
def _tent(d):
    return np.maximum(0.0, 1.0 - np.abs(d))


def _keys_cubic(d, a=-0.75):
    d = np.abs(d)
    return np.where(d <= 1, ((a + 2) * d - (a + 3)) * d * d + 1, np.where(d < 2, (((d - 5) * d + 8) * d - 4) * a, 0.0))


def resize_matrix(n_in, n_out, kind):
    """Dense (n_out, n_in) float64 weights of the ideal 1-D resampler with pixel-centre convention + replicate border."""
    s = n_in / n_out
    M = np.zeros((n_out, n_in))
    i = np.arange(n_out)
    if kind == "area":
        lo, hi = i * s, (i + 1) * s
        for j in range(n_in):
            M[:, j] = np.clip(np.minimum(hi, j + 1) - np.maximum(lo, j), 0, None)
        return M / M.sum(1, keepdims=True)
    src = (i + 0.5) * s - 0.5
    taps, fn = (2, _tent) if kind == "linear" else (4, _keys_cubic)
    base = np.floor(src).astype(int) - (taps // 2 - 1)
    for t in range(taps):
        j = base + t
        w = fn(src - j)
        np.add.at(M, (i, np.clip(j, 0, n_in - 1)), w)
    return M / M.sum(1, keepdims=True)


def resize_truth(img, dsize, kind):
    out_w, out_h = dsize
    a = img.astype(np.float64)
    if a.ndim == 2:
        a = a[..., None]
    a = np.tensordot(resize_matrix(a.shape[0], out_h, kind), a, axes=(1, 0))
    a = np.tensordot(a, resize_matrix(a.shape[1], out_w, kind), axes=(1, 1)).transpose(0, 2, 1)
    return a[..., 0] if img.ndim == 2 else a


def sep_conv_truth(img, kx, ky):
    """float64 separable filter with BORDER_REFLECT_101 (cv2's default border)."""
    a = img.astype(np.float64)
    kx, ky = np.asarray(kx, np.float64).ravel(), np.asarray(ky, np.float64).ravel()
    rx, ry = len(kx) // 2, len(ky) // 2
    pad = [(ry, ry), (rx, rx)] + [(0, 0)] * (a.ndim - 2)
    p = np.pad(a, pad, mode="reflect")
    tmp = sum(kx[k] * p[:, k:k + a.shape[1]] for k in range(len(kx)))
    return sum(ky[k] * tmp[k:k + a.shape[0]] for k in range(len(ky)))


def gauss_kernel(ksize, sigma):
    x = np.arange(ksize) - (ksize - 1) / 2.0
    k = np.exp(-x * x / (2 * sigma * sigma))
    return k / k.sum()


def pyrdown_truth(img):
    k = np.array([1, 4, 6, 4, 1], np.float64) / 16
    full = sep_conv_truth(img, k, k)
    return full[::2, ::2]


def morph_truth(img, kernel, op):
    a = img.astype(np.float64)
    ky, kx = kernel.shape
    ay, ax = ky // 2, kx // 2
    fill = 1e9 if op == "erode" else -1e9
    pad = [(ay, ky - 1 - ay), (ax, kx - 1 - ax)] + [(0, 0)] * (a.ndim - 2)
    p = np.pad(a, pad, mode="constant", constant_values=fill)
    out = None
    for dy in range(ky):
        for dx in range(kx):
            if kernel[dy, dx]:
                v = p[dy:dy + a.shape[0], dx:dx + a.shape[1]]
                out = v if out is None else (np.minimum(out, v) if op == "erode" else np.maximum(out, v))
    return out


def edt_truth(mask):
    """Exact Euclidean distance of every non-zero pixel to the nearest zero pixel (Felzenszwalb-Huttenlocher)."""
    inf = 1e20

    def dt1d(f):
        n = len(f)
        d = np.empty(n)
        v = np.zeros(n, int)
        z = np.empty(n + 1)
        k = 0
        z[0], z[1] = -inf, inf
        for q in range(1, n):
            while True:
                s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0 * q - 2.0 * v[k])
                if s <= z[k]:
                    k -= 1
                else:
                    break
            k += 1
            v[k] = q
            z[k], z[k + 1] = s, inf
        k = 0
        for q in range(n):
            while z[k + 1] < q:
                k += 1
            d[q] = (q - v[k]) ** 2 + f[v[k]]
        return d

    f = np.where(mask == 0, 0.0, inf)
    f = np.apply_along_axis(dt1d, 0, f)
    f = np.apply_along_axis(dt1d, 1, f)
    return np.sqrt(f)


def hsv_truth(bgr):
    """float64 BGR->HSV, H in [0,180), S,V in [0,255] (cv2 u8 convention, unrounded)."""
    b, g, r = [bgr[..., i].astype(np.float64) for i in range(3)]
    v = np.maximum(np.maximum(b, g), r)
    mn = np.minimum(np.minimum(b, g), r)
    d = v - mn
    s = np.where(v > 0, 255.0 * d / np.where(v > 0, v, 1), 0.0)
    dd = np.where(d > 0, d, 1)
    h = np.where(v == r, (g - b) / dd, np.where(v == g, 2 + (b - r) / dd, 4 + (r - g) / dd)) * 30.0
    h = np.where(d > 0, h, 0.0)
    h = np.where(h < 0, h + 180.0, h)
    return np.stack([h, s, v], -1)


def supersample_coverage(shape_y0, shape_x0, hh, ww, inside, ss=16):
    """Exact-ish coverage of each pixel square by `inside(x, y)` using ss x ss supersampling. Pixel (px,py) covers
    [px-0.5, px+0.5] (OpenCV's integer pixel-centre convention)."""
    yy, xx = np.mgrid[0:hh, 0:ww].astype(np.float64)
    yy += shape_y0
    xx += shape_x0
    cov = np.zeros((hh, ww))
    for oy in range(ss):
        for ox in range(ss):
            cov += inside(xx + (ox + 0.5) / ss - 0.5, yy + (oy + 0.5) / ss - 0.5)
    return cov / (ss * ss)


def blend_truth(base_crop, color, cov):
    c = np.asarray(color[:base_crop.shape[2]], np.float64)
    return base_crop.astype(np.float64) * (1 - cov[..., None]) + c * cov[..., None]
