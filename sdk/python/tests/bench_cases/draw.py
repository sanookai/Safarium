"""Draw family (roadmap phase 7; pipeline hot paths in phase 0). In-place on a fresh copy of the canvas per sample.
AA shapes carry an exact-coverage (16x16 supersampled) ground truth on the crop around the shape."""
from __future__ import annotations

import numpy as np

from . import register
from ._common import blend_truth, sompong_frame, supersample_coverage

COL = (30.0, 200.0, 250.0, 255.0)
PH = (0, 7)


def _fresh(inp):
    d = dict(inp)
    d["img"] = inp["base"].copy()
    return d


def _crop(box):
    y0, y1, x0, x1 = box
    return lambda out: np.ascontiguousarray(out[y0:y1, x0:x1])


def _base(rng, kind="u8bgr"):
    f = sompong_frame()
    if kind == "u8bgr":
        return f
    if kind == "bgra":
        return np.dstack([f, np.full(f.shape[:2], 255, np.uint8)])
    if kind == "gray":
        return np.ascontiguousarray(f[..., 1])
    if kind == "f32":
        return (f.astype(np.float32) / 255.0)
    raise ValueError(kind)


def _color(kind):
    if kind == "f32":
        return (0.12, 0.78, 0.98, 1.0)
    return COL


def _truth_crop(base, box, color, cov_fn, scale=1.0):
    y0, y1, x0, x1 = box
    crop = base[y0:y1, x0:x1].astype(np.float64)
    cov = supersample_coverage(y0, x0, y1 - y0, x1 - x0, cov_fn)
    c = np.asarray(color[:crop.shape[2] if crop.ndim == 3 else 1], np.float64)
    if crop.ndim == 2:
        return crop * (1 - cov) + c[0] * cov
    return blend_truth(crop, color, cov)


# ----------------------------------------------------------------------------- circles
def _circle_case(variant, kind="u8bgr", thickness=-1, r=100, cx=540, cy=900, shift=0, truth=True, reps=1, small=False):
    pad = 6 + max(thickness, 0)
    box = (cy - r - pad, cy + r + pad + 1, cx - r - pad, cx + r + pad + 1)

    def make(rng):
        return {"base": _base(rng, kind), "c": (cx, cy), "r": r, "t": thickness, "col": _color(kind), "shift": shift}

    def ref(cv, x):
        return cv.circle(x["img"], x["c"], x["r"], x["col"], x["t"], cv.LINE_AA, x["shift"])

    def tr(cv, x):
        base = x["base"]
        # pixel-inclusive disc: cv2 paints every pixel whose centre is within r, i.e. the geometric edge is at r + 0.5
        # (measured: RMS vs coverage truth 2.1 levels at r+0.5 against 9.4 at r)
        rr = r + 0.5
        inside = lambda px, py: ((px - cx) ** 2 + (py - cy) ** 2 <= rr * rr).astype(np.float64)
        return _truth_crop(base, box, _color(kind), inside)

    register(area="draw", op="circle", variant=variant, phases=PH, make_input=make, ref=ref, fresh=_fresh,
             norm=_crop(box), truth=tr if (truth and thickness < 0) else None, reps=reps,
             note="" if thickness < 0 else "ring: parity only (cv2 thick AA strokes fit no simple analytic model)")


_circle_case("filled_aa_r100_u8bgr_1080x1920_sompong")
_circle_case("ring_aa_t5_r100_u8bgr_1080x1920_sompong", thickness=5)
_circle_case("filled_aa_r100_f32_1080x1920", kind="f32", truth=False)
_circle_case("filled_aa_r100_bgra_1080x1920", kind="bgra", truth=False)
_circle_case("filled_aa_r100_gray_1080x1920", kind="gray", truth=False)
_circle_case("filled_aa_r5_u8bgr_small_x200", r=5, reps=200, truth=False)


# ----------------------------------------------------------------------------- dot grid (pipeline hot path: shift=4)
def _dots_input(rng):
    xs = np.arange(60, 1020, 32)
    ys = np.arange(100, 1800, 56)
    pts = [(int(x * 16 + 5), int(y * 16 + 9)) for y in ys for x in xs]
    return {"base": sompong_frame(), "pts": pts, "r16": 5 * 16, "col": COL}


def _dots_loop(cv, x):
    img, col, r = x["img"], x["col"], x["r16"]
    for p in x["pts"]:
        cv.circle(img, p, r, col, -1, cv.LINE_AA, 4)
    return img


def _dots_batch(cv, x):
    return cv.safarium_circles(x["img"], np.asarray(x["pts"], np.int32), x["r16"], x["col"], -1, cv.LINE_AA, 4)


register(area="draw", op="circle", variant="dotgrid_aa_shift4_loop_u8bgr_1080x1920_sompong", phases=PH, make_input=_dots_input,
         ref=_dots_loop, fresh=_fresh, note="930 AA dots per frame, Python loop on both engines")
register(area="draw", op="circle", variant="dotgrid_aa_shift4_batch_u8bgr_1080x1920_sompong", phases=PH, make_input=_dots_input,
         ref=_dots_loop, shim=_dots_batch, fresh=_fresh, requires=("safarium_circles",),
         note="shim uses its safarium_circles batch call (what the pipeline does); cv2 loops")


# ----------------------------------------------------------------------------- line (capsule truth)
def _line_case(variant, thickness):
    p1, p2 = (150, 300), (850, 1500)
    pad = 8 + thickness
    box = (p1[1] - pad, p2[1] + pad, p1[0] - pad, p2[0] + pad)

    def make(rng):
        return {"base": sompong_frame(), "p1": p1, "p2": p2, "t": thickness, "col": COL}

    def ref(cv, x):
        return cv.line(x["img"], x["p1"], x["p2"], x["col"], x["t"], cv.LINE_AA)

    def tr(cv, x):
        a, b = np.array(p1, np.float64), np.array(p2, np.float64)
        ab = b - a
        L2 = float(ab @ ab)

        def inside(px, py):
            t = np.clip(((px - a[0]) * ab[0] + (py - a[1]) * ab[1]) / L2, 0, 1)
            d2 = (px - (a[0] + t * ab[0])) ** 2 + (py - (a[1] + t * ab[1])) ** 2
            return (d2 <= (thickness / 2.0 + 0.5) ** 2).astype(np.float64)   # pixel-inclusive stroke radius

        return _truth_crop(x["base"], box, COL, inside)

    register(area="draw", op="line", variant=variant, phases=PH, make_input=make, ref=ref, fresh=_fresh, norm=_crop(box),
             truth=tr if thickness > 1 else None, reps=1)


_line_case("aa_t5_u8bgr_1080x1920_sompong", 5)
_line_case("aa_t1_u8bgr_1080x1920_sompong", 1)


# ----------------------------------------------------------------------------- other shapes (parity only)
def _shape(op, variant, box, call, extra=None, kind="u8bgr", **kw):
    def make(rng):
        d = {"base": _base(rng, kind), "col": _color(kind)}
        if extra:
            d.update(extra)
        return d

    register(area="draw", op=op, variant=variant, phases=PH, make_input=make, ref=call, fresh=_fresh, norm=_crop(box), **kw)


_HEX = np.array([[540 + 300 * np.cos(a), 960 + 300 * np.sin(a)] for a in np.linspace(0, 2 * np.pi, 7)[:-1]], np.int32)
_shape("rectangle", "filled_u8bgr_1080x1920_sompong", (90, 1710, 90, 910),
       lambda cv, x: cv.rectangle(x["img"], (100, 100), (900, 1700), x["col"], -1))
_shape("rectangle", "t4_aa_u8bgr_1080x1920_sompong", (90, 1710, 90, 910),
       lambda cv, x: cv.rectangle(x["img"], (100, 100), (900, 1700), x["col"], 4, cv.LINE_AA))
_shape("fillPoly", "hexagon_aa_u8bgr_1080x1920_sompong", (640, 1280, 220, 860),
       lambda cv, x: cv.fillPoly(x["img"], [_HEX.reshape(-1, 1, 2)], x["col"], cv.LINE_AA))
_shape("polylines", "hexagon_t3_aa_u8bgr_1080x1920_sompong", (640, 1280, 220, 860),
       lambda cv, x: cv.polylines(x["img"], [_HEX.reshape(-1, 1, 2)], True, x["col"], 3, cv.LINE_AA))
_shape("ellipse", "filled_aa_u8bgr_1080x1920_sompong", (620, 1300, 200, 880),
       lambda cv, x: cv.ellipse(x["img"], (540, 960), (300, 180), 30, 0, 360, x["col"], -1, cv.LINE_AA))
_shape("putText", "simplex_aa_u8bgr_1080x1920_sompong", (300, 470, 30, 1060),
       lambda cv, x: cv.putText(x["img"], "Sompong 2026 AB", (60, 400), cv.FONT_HERSHEY_SIMPLEX, 3.0, x["col"], 4, cv.LINE_AA))

register(area="draw", op="getTextSize", variant="simplex", phases=PH, make_input=lambda rng: {}, metric="numeric", reps=500,
         ref=lambda cv, x: cv.getTextSize("Sompong 2026 AB", cv.FONT_HERSHEY_SIMPLEX, 3.0, 4),
         norm=lambda out: np.array([out[0][0], out[0][1], out[1]], np.int64))
