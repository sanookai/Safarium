"""Image ops (roadmap phases 3 and 4): geometry warps, resize, filters, morphology, distance transform, components, contours.
float64 / analytic ground truths where they exist; exact ops are parity-only (a bit-exact tie is the best possible)."""
from __future__ import annotations

import numpy as np

from . import register
from ._common import (analytic_f, analytic_image, blob_mask, edt_truth, gauss_kernel, gray_of, mask_from_frame, morph_truth,
                      pyrdown_truth, resize_truth, sep_conv_truth, sompong_frame, synth_frame)

P3 = (0, 3)
P4 = (0, 4)


def _src(kind, size="1080x1920"):
    if size == "256":
        f = synth_frame(256, 256, seed=11)
    elif size == "4096":
        f = synth_frame(4096, 4096, seed=12)
    else:
        f = sompong_frame()
    if kind == "u8bgr":
        return f
    if kind == "gray":
        return gray_of(f)
    if kind == "f32gray":
        return gray_of(f).astype(np.float32) / 255.0
    raise ValueError(kind)


# ----------------------------------------------------------------------------- resize
def _resize(variant, kind, size, dsize, interp, truth=True):
    kmap = {"INTER_LINEAR": "linear", "INTER_AREA": "area", "INTER_CUBIC": "cubic"}

    def make(rng):
        return {"img": _src(kind, size), "dsize": dsize, "interp": interp}

    def ref(cv, x):
        return cv.resize(x["img"], x["dsize"], interpolation=getattr(cv, x["interp"]))

    tr = (lambda cv, x: resize_truth(x["img"], x["dsize"], kmap[interp])) if truth and interp in kmap else None
    register(area="ops", op="resize", variant=variant, phases=P3, make_input=make, ref=ref, truth=tr)


_resize("down2x_area_u8bgr_1080x1920_sompong", "u8bgr", "1080x1920", (540, 960), "INTER_AREA")
_resize("down2x_linear_u8bgr_1080x1920_sompong", "u8bgr", "1080x1920", (540, 960), "INTER_LINEAR")
_resize("down2x_cubic_u8bgr_1080x1920_sompong", "u8bgr", "1080x1920", (540, 960), "INTER_CUBIC")
_resize("down2x_nearest_u8bgr_1080x1920_sompong", "u8bgr", "1080x1920", (540, 960), "INTER_NEAREST")
_resize("down2x_linear_f32gray_1080x1920", "f32gray", "1080x1920", (540, 960), "INTER_LINEAR")
_resize("up2x_linear_u8bgr_256", "u8bgr", "256", (512, 512), "INTER_LINEAR")
_resize("up2x_cubic_u8bgr_256", "u8bgr", "256", (512, 512), "INTER_CUBIC")
_resize("area_4096_to_1080_u8bgr", "u8bgr", "4096", (1080, 1080), "INTER_AREA")
_resize("up_to_1080x1920_linear_gray_256", "gray", "256", (1080, 1920), "INTER_LINEAR")


# ----------------------------------------------------------------------------- warpAffine / remap
def _rot(cx, cy, deg, scale):
    a, b = scale * np.cos(np.radians(deg)), scale * np.sin(np.radians(deg))
    return np.array([[a, b, (1 - a) * cx - b * cy], [-b, a, b * cx + (1 - a) * cy]], np.float64)


def _warp(variant, kind, interp, truth=False):
    def make(rng):
        return {"img": _src(kind), "M": _rot(540, 960, 5.0, 1.1), "dsize": (1080, 1920), "interp": interp}

    def ref(cv, x):
        return cv.warpAffine(x["img"], x["M"], x["dsize"], flags=getattr(cv, x["interp"]), borderMode=cv.BORDER_REPLICATE)

    register(area="ops", op="warpAffine", variant=variant, phases=P3, make_input=make, ref=ref)


_warp("rot5_linear_u8bgr_1080x1920_sompong", "u8bgr", "INTER_LINEAR")
_warp("rot5_cubic_u8bgr_1080x1920_sompong", "u8bgr", "INTER_CUBIC")
_warp("rot5_nearest_u8bgr_1080x1920_sompong", "u8bgr", "INTER_NEAREST")
_warp("rot5_linear_f32gray_1080x1920", "f32gray", "INTER_LINEAR")


def _warp_analytic(variant, interp, dtype):
    S, lo, hi = 512, 100, 412
    A = _rot(256, 256, 10.0, 1.0)       # dst -> src (used with WARP_INVERSE_MAP)

    def make(rng):
        return {"img": analytic_image(S, S, dtype), "M": A, "interp": interp}

    def ref(cv, x):
        return cv.warpAffine(x["img"], x["M"], (S, S), flags=getattr(cv, x["interp"]) | cv.WARP_INVERSE_MAP,
                             borderMode=cv.BORDER_REPLICATE)

    def truth(cv, x):
        yy, xx = np.mgrid[lo:hi, lo:hi].astype(np.float64)
        sx = A[0, 0] * xx + A[0, 1] * yy + A[0, 2]
        sy = A[1, 0] * xx + A[1, 1] * yy + A[1, 2]
        return analytic_f(sx, sy)

    register(area="ops", op="warpAffine", variant=variant, phases=P3, make_input=make, ref=ref,
             norm=lambda out: np.ascontiguousarray(out[lo:hi, lo:hi]), truth=truth)


_warp_analytic("analytic_rot10_linear_f32_512", "INTER_LINEAR", np.float32)
_warp_analytic("analytic_rot10_cubic_f32_512", "INTER_CUBIC", np.float32)


def _remap_input(kind):
    def make(rng):
        yy, xx = np.mgrid[0:1920, 0:1080].astype(np.float32)
        mx = (xx + 6 * np.sin(2 * np.pi * yy / 200)).astype(np.float32)
        my = (yy + 6 * np.cos(2 * np.pi * xx / 230)).astype(np.float32)
        return {"img": _src(kind), "mx": mx, "my": my}
    return make


register(area="ops", op="remap", variant="wave_linear_u8bgr_1080x1920_sompong", phases=P3, make_input=_remap_input("u8bgr"),
         ref=lambda cv, x: cv.remap(x["img"], x["mx"], x["my"], cv.INTER_LINEAR, borderMode=cv.BORDER_REPLICATE))
register(area="ops", op="remap", variant="wave_linear_f32gray_1080x1920", phases=P3, make_input=_remap_input("f32gray"),
         ref=lambda cv, x: cv.remap(x["img"], x["mx"], x["my"], cv.INTER_LINEAR, borderMode=cv.BORDER_REPLICATE))


def _remap_analytic():
    S, lo, hi = 512, 40, 472

    def make(rng):
        yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
        return {"img": analytic_image(S, S), "mx": (xx + 6 * np.sin(2 * np.pi * yy / 200)).astype(np.float32),
                "my": (yy + 6 * np.cos(2 * np.pi * xx / 230)).astype(np.float32)}

    def truth(cv, x):
        return analytic_f(x["mx"][lo:hi, lo:hi].astype(np.float64), x["my"][lo:hi, lo:hi].astype(np.float64))

    register(area="ops", op="remap", variant="analytic_wave_linear_f32_512", phases=P3, make_input=make,
             ref=lambda cv, x: cv.remap(x["img"], x["mx"], x["my"], cv.INTER_LINEAR, borderMode=cv.BORDER_REPLICATE),
             norm=lambda out: np.ascontiguousarray(out[lo:hi, lo:hi]), truth=truth)


_remap_analytic()


# ----------------------------------------------------------------------------- GaussianBlur / sepFilter2D / pyrDown
def _ksize(sigma, f32):
    k = int(round(sigma * (4 if f32 else 3) * 2 + 1)) | 1
    return max(k, 3)


def _gblur(variant, kind, size, sigma):
    def make(rng):
        return {"img": _src(kind, size), "sigma": sigma}

    def truth(cv, x):
        k = gauss_kernel(_ksize(sigma, kind.startswith("f32")), sigma)
        return sep_conv_truth(x["img"], k, k)

    register(area="ops", op="GaussianBlur", variant=variant, phases=P3, make_input=make, truth=truth,
             ref=lambda cv, x: cv.GaussianBlur(x["img"], (0, 0), x["sigma"]))


_gblur("sigma3_u8bgr_1080x1920_sompong", "u8bgr", "1080x1920", 3.0)
_gblur("sigma1p5_gray_1080x1920_sompong", "gray", "1080x1920", 1.5)
_gblur("sigma3_f32gray_1080x1920", "f32gray", "1080x1920", 3.0)
_gblur("sigma3_u8bgr_256", "u8bgr", "256", 3.0)
_gblur("sigma3_u8bgr_4096", "u8bgr", "4096", 3.0)

register(area="ops", op="GaussianBlur", variant="k7_sigma1p5_u8bgr_1080x1920_sompong", phases=P3,
         make_input=lambda rng: {"img": _src("u8bgr")},
         ref=lambda cv, x: cv.GaussianBlur(x["img"], (7, 7), 1.5),
         truth=lambda cv, x: sep_conv_truth(x["img"], gauss_kernel(7, 1.5), gauss_kernel(7, 1.5)))

register(area="ops", op="sepFilter2D", variant="gauss15_u8bgr_1080x1920_sompong", phases=P3,
         make_input=lambda rng: {"img": _src("u8bgr"), "k": gauss_kernel(15, 2.5).astype(np.float64).reshape(-1, 1)},
         ref=lambda cv, x: cv.sepFilter2D(x["img"], -1, x["k"], x["k"]),
         truth=lambda cv, x: sep_conv_truth(x["img"], x["k"], x["k"]))

register(area="ops", op="pyrDown", variant="u8bgr_1080x1920_sompong", phases=P3, make_input=lambda rng: {"img": _src("u8bgr")},
         ref=lambda cv, x: cv.pyrDown(x["img"]), truth=lambda cv, x: pyrdown_truth(x["img"]))
register(area="ops", op="pyrDown", variant="f32gray_1080x1920", phases=P3, make_input=lambda rng: {"img": _src("f32gray")},
         ref=lambda cv, x: cv.pyrDown(x["img"]), truth=lambda cv, x: pyrdown_truth(x["img"]))

# ----------------------------------------------------------------------------- morphology
_RECT3 = np.ones((3, 3), np.uint8)
_RECT5 = np.ones((5, 5), np.uint8)
_ELL5 = np.array([[0, 0, 1, 0, 0], [1, 1, 1, 1, 1], [1, 1, 1, 1, 1], [1, 1, 1, 1, 1], [0, 0, 1, 0, 0]], np.uint8)


def _morph(op, variant, kind, kernel):
    register(area="ops", op=op, variant=variant, phases=P3, make_input=lambda rng: {"img": _src(kind), "k": kernel},
             ref=lambda cv, x: getattr(cv, op)(x["img"], x["k"]),
             truth=lambda cv, x: morph_truth(x["img"], x["k"], op))


_morph("erode", "rect3_u8bgr_1080x1920_sompong", "u8bgr", _RECT3)
_morph("dilate", "ellipse5_gray_1080x1920_sompong", "gray", _ELL5)
_morph("erode", "rect3_f32gray_1080x1920", "f32gray", _RECT3)
_morph("dilate", "rect5_u8bgr_1080x1920_sompong", "u8bgr", _RECT5)
register(area="ops", op="morphologyEx", variant="open_rect5_u8bgr_1080x1920_sompong", phases=P3,
         make_input=lambda rng: {"img": _src("u8bgr"), "k": _RECT5},
         ref=lambda cv, x: cv.morphologyEx(x["img"], cv.MORPH_OPEN, x["k"]),
         truth=lambda cv, x: morph_truth(morph_truth(x["img"], x["k"], "erode"), x["k"], "dilate"))


# ----------------------------------------------------------------------------- distance transform / components / contours
register(area="ops", op="distanceTransform", variant="l2_3_u8mask_256_truth", phases=P3,
         make_input=lambda rng: {"m": blob_mask(256, 256)},
         ref=lambda cv, x: cv.distanceTransform(x["m"], cv.DIST_L2, 3),
         truth=lambda cv, x: edt_truth(x["m"]))
register(area="ops", op="distanceTransform", variant="l2_precise_u8mask_256_truth", phases=P3,
         make_input=lambda rng: {"m": blob_mask(256, 256)},
         ref=lambda cv, x: cv.distanceTransform(x["m"], cv.DIST_L2, cv.DIST_MASK_PRECISE),
         truth=lambda cv, x: edt_truth(x["m"]))
register(area="ops", op="distanceTransform", variant="l2_3_u8mask_1080x1920_sompong", phases=P3,
         make_input=lambda rng: {"m": mask_from_frame(sompong_frame())},
         ref=lambda cv, x: cv.distanceTransform(x["m"], cv.DIST_L2, 3))

register(area="ops", op="connectedComponents", variant="c8_u8mask_1080x1920_sompong", phases=P4,
         make_input=lambda rng: {"m": mask_from_frame(sompong_frame())},
         ref=lambda cv, x: cv.connectedComponents(x["m"], connectivity=8), norm=lambda out: np.asarray(out[1]), metric="numeric")
register(area="ops", op="connectedComponentsWithStats", variant="c8_u8mask_1080x1920_sompong", phases=P4,
         make_input=lambda rng: {"m": mask_from_frame(sompong_frame())},
         ref=lambda cv, x: cv.connectedComponentsWithStats(x["m"], connectivity=8),
         norm=lambda out: np.asarray(out[2]), metric="numeric")


def _contour_points(out):
    cs = out[0]
    return np.concatenate([np.asarray(c).reshape(-1, 2) for c in cs]).astype(np.int32) if len(cs) else np.zeros((0, 2), np.int32)


register(area="ops", op="findContours", variant="external_simple_u8mask_1080x1920_sompong", phases=P4,
         make_input=lambda rng: {"m": mask_from_frame(sompong_frame())},
         ref=lambda cv, x: cv.findContours(x["m"].copy(), cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE),
         norm=_contour_points, metric="numeric")
register(area="ops", op="findContours", variant="list_none_u8mask_1080x1920_sompong", phases=P4,
         make_input=lambda rng: {"m": mask_from_frame(sompong_frame())},
         ref=lambda cv, x: cv.findContours(x["m"].copy(), cv.RETR_LIST, cv.CHAIN_APPROX_NONE),
         norm=_contour_points, metric="numeric")


def _poly_input(rng):
    n = 20000
    t = np.linspace(0, 2 * np.pi, n, endpoint=False)
    r = 400 + 25 * np.sin(7 * t) + rng.normal(0, 0.8, n)
    pts = np.stack([540 + r * np.cos(t), 960 + r * np.sin(t)], 1)
    return {"c": np.rint(pts).astype(np.int32).reshape(-1, 1, 2)}


register(area="ops", op="approxPolyDP", variant="eps2_20000pts", phases=P4, make_input=_poly_input,
         ref=lambda cv, x: cv.approxPolyDP(x["c"], 2.0, True), norm=lambda o: np.asarray(o).reshape(-1, 2), metric="numeric")
register(area="ops", op="arcLength", variant="closed_20000pts", phases=P4, make_input=_poly_input, reps=20,
         ref=lambda cv, x: cv.arcLength(x["c"], True), norm=lambda o: np.array([o], np.float64), metric="numeric")
register(area="ops", op="pointPolygonTest", variant="inside_dist_20000pts", phases=P4, make_input=_poly_input, reps=20,
         ref=lambda cv, x: cv.pointPolygonTest(x["c"], (540.0, 960.0), True), norm=lambda o: np.array([o], np.float64),
         metric="numeric")
