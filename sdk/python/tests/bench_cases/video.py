"""videoio (roadmap phase 6). OPT-IN (--include-video): SF-VIDEO-1 says decoding goes through `safarium-render run --` and the
opencv wheel bundles FFmpeg, so the reference engine is forced onto the Apple AVFoundation backend (CAP_AVFOUNDATION = 1200).
The clip comes from $BENCH_VIDEO or the first Sompong episode video_noaudio.mp4."""
from __future__ import annotations

import os

import numpy as np

from . import register
from ._common import SOMPONG

CAP_AVFOUNDATION = 1200
FRAMES = 8


def _path():
    p = os.environ.get("BENCH_VIDEO")
    if p:
        return p
    cands = sorted(SOMPONG.glob("episodes/*/video_noaudio.mp4"))
    return str(cands[0]) if cands else "/nonexistent.mp4"


def _read(cv, x, api):
    cap = cv.VideoCapture(x["path"], api) if api is not None else cv.VideoCapture(x["path"])
    frames = []
    try:
        assert cap.isOpened(), "VideoCapture did not open " + x["path"]
        for _ in range(FRAMES):
            ok, f = cap.read()
            if not ok:
                break
            frames.append(f)
    finally:
        cap.release()
    return frames


register(area="video", op="VideoCapture.read", variant="first8frames_h264_sompong", phases=(0, 6), video=True, stream=True,
         make_input=lambda rng: {"path": _path()},
         ref=lambda cv, x: _read(cv, x, CAP_AVFOUNDATION), shim=lambda cv, x: _read(cv, x, None),
         norm=lambda frames: np.concatenate(frames, 0) if frames else np.zeros((1, 1, 3), np.uint8),
         note="reference forced onto AVFoundation (no bundled FFmpeg); run via safarium-render")
