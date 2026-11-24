"""Declarative case registry for bench_raster.py.

A Case says WHAT to measure; bench_raster.py decides HOW (fresh subprocesses, warmup, medians, RAM sampling, verdicts).

    Case(area="ops", op="resize", variant="down2x_area_u8bgr_1080x1920", phases=(0, 3),
         make_input=<rng -> dict of arrays/params, deterministic>,
         ref=<(cv2_module, inp) -> output>,          # runs under reference OpenCV 5.1
         shim=None,                                   # (module, inp) -> output under the Safarium shim; defaults to ref
         fresh=None,                                  # inp -> inp, per-call untimed setup (e.g. copy the canvas for draw ops)
         norm=None,                                   # raw output -> ndarray that is compared (crop, decode bytes, ...)
         truth=None,                                  # (ref_module, inp) -> float64 ground truth, same shape as norm(out)
         size=None,                                   # SizeSpec for encoders (bytes at equal SSIM / lossless bytes)
         requires=(), reps=1, stream=False, metric=None, hidden=False, video=False, family="cv2")

`family`: "cv2" (reference python = $SCRATCH/cvref), "sci" (= $SCRATCH/sciref, real scipy/tifffile), "py" (plain python,
only the hidden self-test cases). `requires` = attribute names the SHIM module must expose; missing -> UNSUPPORTED.
Every module in this package appends cases at import time through `register`.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Optional

CASES: list["Case"] = []


@dataclass
class SizeSpec:
    """Encoder file-size spec. kind: 'lossy' (bisect `knob` to equal SSIM), 'lossless' (bytes, exact round-trip),
    'fixed' (one setting; bytes reported, compared only if SSIM to the original is equal within 0.002)."""
    kind: str
    make_image: Callable[[Any], Any]                 # rng -> u8 BGR/gray image used for size measurements
    encode: Callable[[Any, Any, int], Any]           # (module, image, knob) -> bytes/ndarray (module encode call)
    knob_range: tuple = (1, 100)
    targets: tuple = (0.97, 0.99)
    ext: str = ".jpg"


@dataclass
class Case:
    area: str
    op: str
    variant: str
    ref: Callable
    make_input: Callable
    phases: tuple = (0,)
    shim: Optional[Callable] = None
    fresh: Optional[Callable] = None
    norm: Optional[Callable] = None
    truth: Optional[Callable] = None
    size: Optional[SizeSpec] = None
    requires: tuple = ()
    reps: int = 1
    stream: bool = False
    metric: Optional[str] = None                      # None = auto, "image" or "numeric"
    hidden: bool = False
    video: bool = False
    family: str = "cv2"
    seed: int = 1234
    note: str = ""

    @property
    def name(self) -> str:
        return f"{self.area}.{self.op}" + (f".{self.variant}" if self.variant else "")

    def callable_for(self, engine: str) -> Callable:
        return self.shim if (engine == "shim" and self.shim is not None) else self.ref


def register(**kw) -> Case:
    c = Case(**kw)
    CASES.append(c)
    return c


from . import selftest  # noqa: E402,F401
from . import draw, ops, numpy_ops, codec, video, sci  # noqa: E402,F401
