"""core-numeric and colour (roadmap phases 1 and 3): arithmetic, channels, reduce, cvtColor, Laplacian."""
from __future__ import annotations

import numpy as np

from . import register
from ._common import gray_of, hsv_truth, second_frame, sompong_frame

P1 = (0, 1)
P3 = (0, 3)


def _two(rng):
    return {"a": sompong_frame(), "b": second_frame()}


def _bin(op, variant, call, truth=None, kind="u8bgr"):
    register(area="numpy", op=op, variant=variant, phases=P1, make_input=_two, ref=call, truth=truth)


_bin("add", "u8bgr_1080x1920_sompong", lambda cv, x: cv.add(x["a"], x["b"]),
     lambda cv, x: np.clip(x["a"].astype(np.float64) + x["b"], 0, 255))
_bin("subtract", "u8bgr_1080x1920_sompong", lambda cv, x: cv.subtract(x["a"], x["b"]),
     lambda cv, x: np.clip(x["a"].astype(np.float64) - x["b"], 0, 255))
_bin("absdiff", "u8bgr_1080x1920_sompong", lambda cv, x: cv.absdiff(x["a"], x["b"]),
     lambda cv, x: np.abs(x["a"].astype(np.float64) - x["b"]))
_bin("multiply", "u8bgr_scale0p5_1080x1920_sompong", lambda cv, x: cv.multiply(x["a"], x["b"], scale=1 / 255.0),
     lambda cv, x: x["a"].astype(np.float64) * x["b"] / 255.0)
_bin("addWeighted", "0p7_0p3_u8bgr_1080x1920_sompong", lambda cv, x: cv.addWeighted(x["a"], 0.7, x["b"], 0.3, 0),
     lambda cv, x: np.clip(0.7 * x["a"].astype(np.float64) + 0.3 * x["b"], 0, 255))
register(area="numpy", op="add", variant="scalar_u8bgr_1080x1920_sompong", phases=P1, make_input=_two,
         ref=lambda cv, x: cv.add(x["a"], (10, 20, 30, 0)),
         truth=lambda cv, x: np.clip(x["a"].astype(np.float64) + np.array([10, 20, 30]), 0, 255))
register(area="numpy", op="addWeighted", variant="f32gray_1080x1920", phases=P1,
         make_input=lambda rng: {"a": gray_of(sompong_frame()).astype(np.float32) / 255, "b": gray_of(second_frame()).astype(np.float32) / 255},
         ref=lambda cv, x: cv.addWeighted(x["a"], 0.6, x["b"], 0.4, 0.0),
         truth=lambda cv, x: 0.6 * x["a"].astype(np.float64) + 0.4 * x["b"].astype(np.float64))

register(area="numpy", op="split", variant="u8bgr_1080x1920_sompong", phases=P1, make_input=_two,
         ref=lambda cv, x: cv.split(x["a"]), norm=lambda out: np.concatenate(out, 0))
register(area="numpy", op="merge", variant="u8bgr_1080x1920_sompong", phases=P1,
         make_input=lambda rng: {"p": [np.ascontiguousarray(sompong_frame()[..., i]) for i in range(3)]},
         ref=lambda cv, x: cv.merge(x["p"]))
register(area="numpy", op="reduce", variant="max_axis0_gray_u8_1080x1920_sompong", phases=P1,
         make_input=lambda rng: {"g": gray_of(sompong_frame())}, metric="numeric", reps=5,
         ref=lambda cv, x: cv.reduce(x["g"], 0, cv.REDUCE_MAX))
register(area="numpy", op="reduce", variant="sum_axis1_gray_u8_1080x1920_sompong", phases=P1,
         make_input=lambda rng: {"g": gray_of(sompong_frame())}, metric="numeric", reps=5,
         ref=lambda cv, x: cv.reduce(x["g"], 1, cv.REDUCE_SUM, dtype=cv.CV_32S),
         truth=lambda cv, x: x["g"].astype(np.float64).sum(1, keepdims=True))
register(area="numpy", op="countNonZero", variant="gray_u8_1080x1920_sompong", phases=P1, metric="numeric", reps=5,
         make_input=lambda rng: {"g": (gray_of(sompong_frame()) > 100).astype(np.uint8)},
         ref=lambda cv, x: cv.countNonZero(x["g"]), norm=lambda o: np.array([o], np.int64),
         truth=lambda cv, x: np.array([float(np.count_nonzero(x["g"]))]))
register(area="numpy", op="convertScaleAbs", variant="f32gray_to_u8_1080x1920", phases=P1,
         make_input=lambda rng: {"g": (gray_of(sompong_frame()).astype(np.float32) - 128) * 0.9},
         ref=lambda cv, x: cv.convertScaleAbs(x["g"], alpha=2.0, beta=3.0),
         truth=lambda cv, x: np.clip(np.abs(x["g"].astype(np.float64) * 2.0 + 3.0), 0, 255))
register(area="numpy", op="Laplacian", variant="k3_f32gray_1080x1920", phases=P3,
         make_input=lambda rng: {"g": gray_of(sompong_frame()).astype(np.float32)},
         ref=lambda cv, x: cv.Laplacian(x["g"], cv.CV_32F, ksize=3),
         truth=lambda cv, x: _lap_truth(x["g"]))


def _lap_truth(g):
    a = g.astype(np.float64)
    p = np.pad(a, 1, mode="reflect")
    return p[:-2, 1:-1] + p[2:, 1:-1] + p[1:-1, :-2] + p[1:-1, 2:] - 4 * a


# ----------------------------------------------------------------------------- cvtColor
def _cvt(variant, code, kind, truth=None):
    def make(rng):
        f = sompong_frame()
        if kind == "u8bgr":
            img = f
        elif kind == "u8bgra":
            img = np.dstack([f, np.full(f.shape[:2], 255, np.uint8)])
        elif kind == "u8gray":
            img = gray_of(f)
        elif kind == "u16bgr":
            img = f.astype(np.uint16) * 257
        elif kind == "f32bgr":
            img = f.astype(np.float32) / 255.0
        else:
            raise ValueError(kind)
        return {"img": img}

    register(area="numpy", op="cvtColor", variant=variant, phases=P3, make_input=make, truth=truth,
             ref=lambda cv, x: cv.cvtColor(x["img"], getattr(cv, code)))


_GRAY_W = np.array([0.114, 0.587, 0.299])
_cvt("bgr2gray_u8_1080x1920_sompong", "COLOR_BGR2GRAY", "u8bgr", lambda cv, x: x["img"].astype(np.float64) @ _GRAY_W)
_cvt("rgb2gray_u8_1080x1920_sompong", "COLOR_RGB2GRAY", "u8bgr", lambda cv, x: x["img"].astype(np.float64) @ _GRAY_W[::-1])
_cvt("bgr2gray_f32_1080x1920", "COLOR_BGR2GRAY", "f32bgr", lambda cv, x: x["img"].astype(np.float64) @ _GRAY_W)
_cvt("bgr2gray_u16_1080x1920", "COLOR_BGR2GRAY", "u16bgr", lambda cv, x: x["img"].astype(np.float64) @ _GRAY_W)
_cvt("bgr2rgb_u8_1080x1920_sompong", "COLOR_BGR2RGB", "u8bgr", lambda cv, x: x["img"][..., ::-1].astype(np.float64))
_cvt("bgr2hsv_u8_1080x1920_sompong", "COLOR_BGR2HSV", "u8bgr", lambda cv, x: hsv_truth(x["img"]))
_cvt("bgra2bgr_u8_1080x1920_sompong", "COLOR_BGRA2BGR", "u8bgra", lambda cv, x: x["img"][..., :3].astype(np.float64))
_cvt("bgr2bgra_u8_1080x1920_sompong", "COLOR_BGR2BGRA", "u8bgr")
_cvt("gray2bgr_u8_1080x1920_sompong", "COLOR_GRAY2BGR", "u8gray")
