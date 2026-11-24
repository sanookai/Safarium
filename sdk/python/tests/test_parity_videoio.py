"""Phase 6 parity: videoio (VideoCapture / VideoWriter / registry / constants) vs reference OpenCV 5.1.

Run (reference venv, which has real cv2 + Pillow):
    SAFARIUM_RASTER_LIB=<dylib> $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_parity_videoio.py
The reference's video backend is FFmpeg, so it is used ONLY to read files Safarium wrote (property values, decoded
frames of the same file); nothing here asks it to write. Written files are also checked with the SF-VIDEO-1 tool
(`safarium-render verify`).
The first part is the video tests ported (copied) from test_parity_io.py; they must keep passing unchanged.
"""
from __future__ import annotations

import ctypes
import os
import subprocess
import sys
import warnings
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import compare, load_pair  # noqa: E402

REF, SR = load_pair()

# ------------------------------------------------------------------------------------------ video
import os  # noqa: E402

os.environ.setdefault("SAFARIUM_RASTER_TESTING", "1")  # the test-only exports refuse to run without it
_lib = ctypes.CDLL(os.environ["SAFARIUM_RASTER_LIB"])
_lib.sr_video_write_test.argtypes = [ctypes.c_char_p] + [ctypes.c_int32] * 6
_lib.sr_video_test_fail_next_seek.argtypes = [ctypes.c_void_p]
_lib.sr_video_write_test.restype = ctypes.c_int32
_lib.sr_video_test_fail_next_seek.restype = ctypes.c_int32

VW, VH, VFPS, VN = 128, 96, 24, 40


@pytest.fixture(scope="module")
def video(tmp_path_factory):
    p = tmp_path_factory.mktemp("vid") / "สมพง test.mp4"
    assert _lib.sr_video_write_test(str(p).encode(), VW, VH, VFPS, VN, 0, 0) == 0
    return p


def red_index(frame):
    """Which written frame is this? The writer draws the frame number as 8 black/white stripes (MSB left)."""
    h, w = frame.shape[:2]
    row = frame[h // 4, :, :].astype(float).mean(axis=1)
    sw = w // 8
    bits = [1 if row[k * sw + sw // 2] > 127 else 0 for k in range(8)]
    return int("".join(map(str, bits)), 2)


BAND_BGR = [(40, 40, 200), (40, 200, 40), (200, 40, 40), (40, 200, 200)]  # left -> right, bottom quarter


def pattern(i, w=VW, h=VH):
    """The stored frame the writer draws for frame ``i``, derived analytically (NOT from anything the shim read):
    top 3/4 = frame number as 8 black/white stripes (MSB left); bottom 1/4 = four flat colour segments."""
    f = np.zeros((h, w, 3), np.uint8)
    split = h * 3 // 4
    sw = max(1, w // 8)
    for x in range(w):
        bit = (i >> (7 - x // sw)) & 1 if x // sw < 8 else 0
        f[:split, x] = 255 if bit else 0
        f[split:, x] = BAND_BGR[min(3, x * 4 // w)]
    return f


def test_video_properties(video):
    cap = SR.VideoCapture(str(video))
    assert cap.isOpened()
    assert cap.get(3) == VW and cap.get(4) == VH
    assert cap.get(5) == VFPS  # exact, not 23.999998
    assert cap.get(7) == VN
    assert cap.get(1) == 0 and cap.get(0) == 0
    cap.release()
    assert not cap.isOpened()


def test_video_read_all_frames(video):
    cap = SR.VideoCapture(str(video))
    seen = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        assert f.shape == (VH, VW, 3) and f.dtype == np.uint8 and f.flags["C_CONTIGUOUS"]
        seen.append(red_index(f))
    assert len(seen) == VN
    assert seen == list(range(VN)), seen
    assert cap.get(1) == VN
    ok, f = cap.read()
    assert ok is False and f is None
    cap.release()


def test_video_frame_colours_are_bgr(video):
    cap = SR.VideoCapture(str(video))
    ok, f = cap.read()
    assert ok
    exp = pattern(0)
    for seg in range(4):  # the four flat BGR segments: tolerance covers H.264 + colour matrix
        px = f[VH * 7 // 8, int((seg + 0.5) * VW / 4)].astype(int)
        assert np.abs(px - BAND_BGR[seg]).max() < 20, (seg, px, BAND_BGR[seg])
    assert np.abs(f.astype(int) - exp.astype(int)).mean() < 5
    cap.release()


def test_video_seek_frames_and_msec(video):
    cap = SR.VideoCapture(str(video))
    for n in (25, 3, 39, 0, 10, 11, 14, 12):
        assert cap.set(1, n) is True
        ok, f = cap.read()
        assert ok, n
        assert red_index(f) == n, (n, red_index(f))
        assert cap.get(1) == n + 1
    for t in (0.0, 0.5, 1.25, 1.6):
        n = int(round(t * VFPS))
        assert cap.set(0, t * 1000.0)
        ok, f = cap.read()
        assert ok and red_index(f) == n, (t, n, red_index(f))
        assert abs(cap.get(0) - n * 1000.0 / VFPS) < 1.0
    # seeking and then past the end: qa.py falls back to FRAME_COUNT - 1
    cap.set(0, 9999 * 1000.0)
    ok, f = cap.read()
    assert not ok
    cap.set(1, max(0, int(cap.get(7)) - 1))
    ok, f = cap.read()
    assert ok and red_index(f) == VN - 1
    cap.release()


def test_video_grab_retrieve_and_reopen(video):
    cap = SR.VideoCapture()
    assert not cap.isOpened()
    assert cap.open(str(video))
    assert cap.grab() is True
    ok, f = cap.retrieve()
    assert ok and red_index(f) == 0
    ok, f = cap.read()
    assert ok and red_index(f) == 1
    cap.release()
    assert cap.read() == (False, None)


def test_video_bad_inputs(tmp_path):
    assert not SR.VideoCapture(str(tmp_path / "nope.mp4")).isOpened()
    junk = tmp_path / "junk.mp4"
    junk.write_bytes(b"not a video" * 100)
    assert not SR.VideoCapture(str(junk)).isOpened()
    assert not SR.VideoCapture(0).isOpened()



# ---- video: rotated / mirrored tracks, seek semantics
TRANSFORMS = {  # code -> (name, numpy transform of the stored frame -> what a player shows)
    1: ("mirror-x", lambda f: f[:, ::-1]),
    2: ("mirror-y", lambda f: f[::-1]),
    3: ("rot90cw", lambda f: np.rot90(f, -1)),
    4: ("rot180", lambda f: f[::-1, ::-1]),
    5: ("rot270cw", lambda f: np.rot90(f, 1)),
    6: ("transpose", lambda f: f.transpose(1, 0, 2)),
    7: ("anti-transpose", lambda f: f.transpose(1, 0, 2)[::-1, ::-1]),
}


@pytest.fixture(scope="module")
def video_tf(tmp_path_factory):
    d = tmp_path_factory.mktemp("vidtf")
    out = {}
    for code in range(0, 8):
        p = d / f"tf{code}.mp4"
        assert _lib.sr_video_write_test(str(p).encode(), VW, VH, VFPS, 6, code, 0) == 0
        out[code] = p
    return out


@pytest.mark.parametrize("code", sorted(TRANSFORMS))
def test_video_preferred_transform(video_tf, code):
    """Expected pixels come from pattern() (analytic) pushed through the textbook geometry, not from the shim."""
    name, fn = TRANSFORMS[code]
    cap = SR.VideoCapture(str(video_tf[code]))
    assert cap.isOpened()
    for k in (0, 3):
        expect = np.ascontiguousarray(fn(pattern(k)))
        if k:
            assert cap.set(1, k)
        else:
            assert (cap.get(3), cap.get(4)) == (expect.shape[1], expect.shape[0]), name
        ok, f = cap.read()
        assert ok and f.shape == expect.shape, (name, k, f.shape, expect.shape)
        assert np.abs(f.astype(int) - expect.astype(int)).mean() < 5, (name, k)
        # the four colour segments: locate each one through the same geometry and look at its centre pixel
        for seg in range(4):
            probe = np.zeros(pattern(0).shape[:2], bool)
            probe[VH * 7 // 8, int((seg + 0.5) * VW / 4)] = True
            where = np.argwhere(np.ascontiguousarray(fn(probe[..., None]))[..., 0])
            assert len(where) == 1
            y, x = where[0]
            assert np.abs(f[y, x].astype(int) - BAND_BGR[seg]).max() < 25, (name, k, seg, f[y, x])
        # and the frame number survives (stripe row of the stored frame, mapped through the geometry)
        marks = np.zeros(pattern(0).shape[:2], np.uint8)
        marks[VH // 4, :] = np.arange(VW) % 255 + 1
        moved = np.ascontiguousarray(fn(marks[..., None]))[..., 0]
        ys, xs = np.nonzero(moved)
        order = np.argsort(moved[ys, xs])
        line = f[ys[order], xs[order]].astype(float).mean(axis=1)  # the stored row, in stored x order
        sw = VW // 8
        bits = [1 if line[q * sw + sw // 2] > 127 else 0 for q in range(8)]
        assert int("".join(map(str, bits)), 2) == k, (name, k, bits)
    cap.release()


def test_video_seek_past_end_and_negative_like_cv2(video):
    """cv2: set() past the end returns True, read() is False, POS_FRAMES = FRAME_COUNT; negative clamps to 0."""
    cap = SR.VideoCapture(str(video))
    assert cap.set(1, 9999) is True
    assert cap.read() == (False, None)
    assert cap.read() == (False, None)  # stays failed, no frame appears
    assert cap.get(1) == VN
    assert cap.set(1, -5) is True
    ok, f = cap.read()
    assert ok and red_index(f) == 0 and cap.get(1) == 1
    assert cap.set(1, 3) and red_index(cap.read()[1]) == 3
    assert cap.set(1, 1e9) is True and cap.read()[0] is False
    assert cap.set(1, 2) and red_index(cap.read()[1]) == 2  # recovers
    assert cap.set(0, -100) is True and red_index(cap.read()[1]) == 0
    assert cap.set(5, 10) is False  # unsupported property


def test_video_failed_reposition_reports_failure_consistently(video):
    """Deterministic: the test hook makes the next reader re-creation fail (a real decoder error looks the same)."""
    cap = SR.VideoCapture(str(video))
    assert cap.read()[0]
    _lib.sr_video_test_fail_next_seek(cap._h)
    assert cap.set(1, 30) is False
    for _ in range(3):
        assert cap.read() == (False, None)  # never a stale frame, never an exception, never a quiet EOF-and-continue
    assert cap.grab() is False
    assert cap.set(1, 30) is True  # a good seek recovers
    ok, f = cap.read()
    assert ok and red_index(f) == 30


@pytest.fixture(scope="module")
def video_short(tmp_path_factory):
    """40 frames written, but the session is ended 2 frames late: duration * fps = 42 > the 40 real samples."""
    p = tmp_path_factory.mktemp("vidshort") / "short.mp4"
    assert _lib.sr_video_write_test(str(p).encode(), VW, VH, VFPS, VN, 0, 2) == 0
    return p


def test_video_last_real_frame_reachable_when_track_is_short(video_short):
    cap = SR.VideoCapture(str(video_short))
    assert cap.get(7) == VN, cap.get(7)  # real sample count, not round(duration * fps) = 42
    assert cap.set(1, VN - 1)
    ok, f = cap.read()
    assert ok and red_index(f) == VN - 1
    assert cap.read() == (False, None)
    assert cap.set(1, VN) and cap.read() == (False, None)  # past the real end: nothing there
    assert cap.set(1, int(cap.get(7)) - 1) and red_index(cap.read()[1]) == VN - 1  # qa.py's fallback lands on a real frame
    cap.release()
    cap = SR.VideoCapture(str(video_short))
    n = 0
    while cap.read()[0]:
        n += 1
    assert n == VN



def test_test_only_exports_are_inert_without_the_env_var(tmp_path, monkeypatch):
    monkeypatch.delenv("SAFARIUM_RASTER_TESTING", raising=False)
    out = tmp_path / "must_not_exist.mp4"
    assert _lib.sr_video_write_test(str(out).encode(), 64, 48, 24, 4, 0, 0) != 0
    assert not out.exists()
    assert _lib.sr_video_test_fail_next_seek(ctypes.c_void_p(1)) != 0  # refused before touching the handle
    monkeypatch.setenv("SAFARIUM_RASTER_TESTING", "1")
    assert _lib.sr_video_write_test(str(out).encode(), 64, 48, 24, 4, 0, 0) == 0 and out.exists()




# ====================================================================================== phase 6: new surface
import resource  # noqa: E402
import struct  # noqa: E402
import json  # noqa: E402
import time  # noqa: E402

RENDER = os.path.expanduser("~/.local/bin/safarium-render")


def verify(path, timeout=900):
    """SF-VIDEO-1 tool: inspect one file (waits for the shared render queue). Returns the parsed JSON."""
    r = subprocess.run([RENDER, "verify", str(path)], capture_output=True, text=True, timeout=timeout)
    assert r.returncode == 0, (r.returncode, r.stdout[-300:], r.stderr[-300:])
    return json.loads(r.stdout)


def source_frame(i, w=256, h=144):
    """Smooth synthetic frame i: gradients + a moving box + the frame number as 8 stripes along the top (MSB left)."""
    f = np.zeros((h, w, 3), np.uint8)
    f[..., 0] = np.linspace(0, 255, w, dtype=np.uint8)[None, :]
    f[..., 1] = np.linspace(0, 255, h, dtype=np.uint8)[:, None]
    f[..., 2] = (i * 7) % 256
    x0 = (10 + i * 3) % max(1, w - 60)
    f[40:80, x0:x0 + 40] = 255
    sw = w // 8
    for k in range(8):
        f[:16, k * sw:(k + 1) * sw] = 255 if (i >> (7 - k)) & 1 else 0
    return f


def stripe_index(f):
    h, w = f.shape[:2]
    sw = w // 8
    return int("".join("1" if f[8, k * sw + sw // 2].astype(int).mean() > 127 else "0" for k in range(8)), 2)


def write_clip(path, fourcc, n=30, fps=30, size=(256, 144), params=None, color=True, frames=None):
    w, h = size
    wr = SR.VideoWriter(str(path), SR.VideoWriter_fourcc(*fourcc), fps, (w, h), **({"params": params} if params else {}))
    assert wr.isOpened(), SR._lib.last_error() if hasattr(SR, "_lib") else "not opened"
    for i in range(n):
        wr.write(frames[i] if frames is not None else source_frame(i, w, h))
    wr.release()
    assert not wr.isOpened()
    return path


def read_all(path, **kw):
    cap = SR.VideoCapture(str(path))
    out = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        out.append(f)
    cap.release()
    return out


def check_roundtrip(frames_in, frames_out, what, min_ssim=0.97, min_psnr=30.0):
    assert len(frames_out) == len(frames_in), (what, len(frames_out), len(frames_in))
    worst = None
    for i, (a, b) in enumerate(zip(frames_in, frames_out)):
        r = compare(a, b, f"{what}#{i}")
        if worst is None or r.ssim < worst.ssim:
            worst = r
        assert r.ok, r
    return worst


CODECS = [("avc1", "mp4", "H.264"), ("hvc1", "mp4", "HEVC"), ("apcn", "mov", "ProRes422"), ("MJPG", "mov", "MJPG"),
          ("H264", "mov", "H264 alias in mov"), ("ap4h", "mov", "ProRes4444")]


@pytest.fixture(scope="module")
def clips(tmp_path_factory):
    d = tmp_path_factory.mktemp("vw")
    out = {}
    for fc, ext, name in CODECS:
        out[fc] = write_clip(d / f"c_{fc}.{ext}", fc)
    return out


# ---- constants / registry / fourcc
def test_constants_match_reference():
    names = [n for n in dir(REF) if n.startswith(("CAP_", "VIDEOWRITER_", "VIDEO_ACCELERATION")) and isinstance(getattr(REF, n), int)]
    assert len(names) > 400
    missing = [n for n in names if getattr(SR, n, None) != getattr(REF, n)]
    assert not missing, missing[:10]


@pytest.mark.parametrize("code", ["avc1", "H264", "hvc1", "HEVC", "apcn", "ap4h", "MJPG", "mp4v", "XVID", "DIVX", "    "])
def test_fourcc_matches_reference(code):
    assert SR.VideoWriter_fourcc(*code) == REF.VideoWriter_fourcc(*code)
    assert SR.VideoWriter.fourcc(*code) == REF.VideoWriter_fourcc(*code)


def test_registry():
    import cv2.videoio_registry as imported  # the shim registers the submodule name, so a plain import works
    assert imported.getBackends() == [SR.CAP_SAFARIUM]
    sreg = SR.videoio_registry  # (other test modules load the shim again, so compare through this module's own copy)
    assert sreg.getBackends() == [SR.CAP_SAFARIUM] and sreg.getBackendName(SR.CAP_SAFARIUM) == "SAFARIUM"
    assert sreg.getStreamBackends() == [SR.CAP_SAFARIUM] and sreg.getWriterBackends() == [SR.CAP_SAFARIUM]
    assert sreg.getCameraBackends() == []
    for api in (SR.CAP_ANY, SR.CAP_FFMPEG, SR.CAP_AVFOUNDATION, SR.CAP_IMAGES):
        assert sreg.hasBackend(api) and sreg.isBackendBuiltIn(api)
        assert sreg.getBackendName(api) == REF.videoio_registry.getBackendName(api)
    for api in (SR.CAP_GSTREAMER, SR.CAP_V4L2, SR.CAP_DSHOW, 12345):
        assert not sreg.hasBackend(api)
    assert sreg.getBackendName(9999) == REF.videoio_registry.getBackendName(9999)
    assert sreg.getBackendName(SR.CAP_GSTREAMER) == "GSTREAMER"
    with pytest.raises(SR.error):
        sreg.getStreamBackendPluginVersion(SR.CAP_FFMPEG)


# ---- reading: properties (ref reads the same files)
def ref_props(path):
    c = REF.VideoCapture(str(path))
    assert c.isOpened()
    return c


@pytest.mark.parametrize("fc", [c[0] for c in CODECS])
def test_properties_match_reference_on_written_files(clips, fc):
    cap = SR.VideoCapture(str(clips[fc]))
    ref = ref_props(clips[fc])
    for prop in ("FRAME_WIDTH", "FRAME_HEIGHT", "FPS", "FRAME_COUNT", "FOURCC", "BITRATE", "CODEC_PIXEL_FORMAT", "FORMAT",
                 "ORIENTATION_META", "ORIENTATION_AUTO", "SAR_NUM", "SAR_DEN", "POS_FRAMES", "POS_MSEC", "CONVERT_RGB",
                 "DTS_DELAY", "HW_ACCELERATION_USE_OPENCL", "HW_DEVICE", "BRIGHTNESS", "AUDIO_STREAM", "VIDEO_STREAM"):
        pid = getattr(SR, "CAP_PROP_" + prop)
        assert cap.get(pid) == ref.get(pid), (prop, cap.get(pid), ref.get(pid))
    assert cap.get(SR.CAP_PROP_BACKEND) == SR.CAP_SAFARIUM
    assert cap.getBackendName() == "SAFARIUM"
    assert cap.get(SR.CAP_PROP_HW_ACCELERATION) == SR.VIDEO_ACCELERATION_ANY  # VideoToolbox decode
    assert cap.get(SR.CAP_PROP_STREAM_OPEN_TIME_USEC) > 0
    assert cap.get(9999) == -1.0 == ref.get(9999)
    assert cap.get(SR.CAP_PROP_FRAME_TYPE) == 63.0  # '?' before the first frame
    cap.read()
    assert cap.get(SR.CAP_PROP_FRAME_TYPE) == ord("I")  # first frame is a sync frame
    assert cap.get(SR.CAP_PROP_PTS) == 0.0


def test_unopened_capture_like_reference(tmp_path):
    cap = SR.VideoCapture()
    ref = REF.VideoCapture()
    for p in (3, 4, 5, 7, 0, 1):
        assert cap.get(p) == ref.get(p) == -1.0
    assert (cap.grab(), cap.read(), cap.retrieve(), cap.set(1, 2)) == (ref.grab(), ref.read(), ref.retrieve(), ref.set(1, 2))
    with pytest.raises(SR.error):
        cap.getBackendName()


@pytest.mark.parametrize("code", range(8))
def test_orientation_meta_and_auto_match_reference(video_tf, code):
    path = video_tf[code]
    cap, ref = SR.VideoCapture(str(path)), REF.VideoCapture(str(path))
    assert cap.get(SR.CAP_PROP_ORIENTATION_META) == ref.get(SR.CAP_PROP_ORIENTATION_META)
    assert (cap.get(3), cap.get(4)) == (ref.get(3), ref.get(4))
    # auto-orientation off: frames and sizes as stored
    assert cap.set(SR.CAP_PROP_ORIENTATION_AUTO, 0) is True and ref.set(SR.CAP_PROP_ORIENTATION_AUTO, 0) is True
    assert cap.get(SR.CAP_PROP_ORIENTATION_AUTO) == ref.get(SR.CAP_PROP_ORIENTATION_AUTO) == 0.0
    assert (cap.get(3), cap.get(4)) == (ref.get(3), ref.get(4)) == (VW, VH)
    ok, f = cap.read()
    ok2, g = ref.read()
    assert ok and ok2 and f.shape == g.shape == (VH, VW, 3)
    assert np.abs(f.astype(int) - g.astype(int)).mean() < 3
    assert cap.set(SR.CAP_PROP_ORIENTATION_AUTO, 1) is True
    assert (cap.get(3), cap.get(4)) == (REF.VideoCapture(str(path)).get(3), REF.VideoCapture(str(path)).get(4))


def test_open_params_orientation_and_unsupported(video_tf, recwarn):
    cap = SR.VideoCapture(str(video_tf[3]), SR.CAP_ANY, [SR.CAP_PROP_ORIENTATION_AUTO, 0])
    assert cap.isOpened() and (cap.get(3), cap.get(4)) == (VW, VH)
    assert not SR.VideoCapture(str(video_tf[3]), SR.CAP_ANY, [SR.CAP_PROP_HW_ACCELERATION, SR.VIDEO_ACCELERATION_NONE]).isOpened()
    assert SR.VideoCapture(str(video_tf[3]), SR.CAP_ANY, [SR.CAP_PROP_HW_ACCELERATION, SR.VIDEO_ACCELERATION_ANY]).isOpened()
    c = SR.VideoCapture(str(video_tf[3]))
    assert c.set(SR.CAP_PROP_HW_ACCELERATION, SR.VIDEO_ACCELERATION_NONE) is False
    assert c.set(SR.CAP_PROP_CONVERT_RGB, 0) is True and c.get(SR.CAP_PROP_CONVERT_RGB) == 0.0
    assert c.set(SR.CAP_PROP_FPS, 10) is False and c.set(SR.CAP_PROP_BRIGHTNESS, 3) is False


def test_backend_selection_and_unavailable_sources(video, tmp_path):
    for api in (SR.CAP_ANY, SR.CAP_FFMPEG, SR.CAP_AVFOUNDATION, SR.CAP_SAFARIUM):
        assert SR.VideoCapture(str(video), api).isOpened(), api
    for api in (SR.CAP_GSTREAMER, SR.CAP_V4L2, SR.CAP_DSHOW):
        assert not SR.VideoCapture(str(video), api).isOpened(), api
    assert not SR.VideoCapture(0).isOpened() and not SR.VideoCapture(index=1).isOpened()
    assert not SR.VideoCapture("rtsp://127.0.0.1/none").isOpened()
    assert not SR.VideoCapture("http://127.0.0.1:9/none.mp4").isOpened()
    assert not SR.VideoCapture(str(tmp_path)).isOpened()  # a directory
    cap = SR.VideoCapture()
    cap.setExceptionMode(True)
    assert cap.getExceptionMode() is True
    with pytest.raises(SR.error):
        cap.open(str(tmp_path / "missing.mp4"))
    cap = SR.VideoCapture(str(video))
    assert cap.open(str(video), SR.CAP_ANY) is True  # re-open on a live object


# ---- reading: pixels and positions
def test_read_into_destination_and_retrieve_into(video):
    cap = SR.VideoCapture(str(video))
    dst = np.zeros((VH, VW, 3), np.uint8)
    ok, f = cap.read(dst)
    assert ok and f is dst and red_index(dst) == 0
    assert cap.grab() and cap.retrieve(dst)[1] is dst and red_index(dst) == 1
    padded = np.zeros((VH, VW + 10, 3), np.uint8)[:, 5:5 + VW]  # row-strided view
    ok, f = cap.read(padded)
    assert ok and f is padded and red_index(padded) == 2
    wrong = np.zeros((VH, VW, 4), np.uint8)
    ok, f = cap.read(wrong)  # a destination of the wrong shape is replaced, like cv2
    assert ok and f is not wrong and f.shape == (VH, VW, 3)


def test_decoded_frames_match_reference_decoder(clips):
    for fc in ("avc1", "hvc1", "apcn", "MJPG"):
        mine, ref = read_all(clips[fc]), []
        rc = REF.VideoCapture(str(clips[fc]))
        while True:
            ok, f = rc.read()
            if not ok:
                break
            ref.append(f)
        assert len(mine) == len(ref) == 30, (fc, len(mine), len(ref))
        for i in (0, 7, 29):
            r = compare(ref[i], mine[i], f"{fc}#{i} vs reference decoder")
            assert r.ok, r


def test_pos_avi_ratio_and_set_roundtrip(video):
    cap = SR.VideoCapture(str(video))
    assert cap.set(SR.CAP_PROP_POS_AVI_RATIO, 0.5) is True
    assert cap.get(1) == VN // 2 and abs(cap.get(SR.CAP_PROP_POS_AVI_RATIO) - 0.5) < 1e-9
    assert red_index(cap.read()[1]) == VN // 2
    assert cap.set(SR.CAP_PROP_POS_AVI_RATIO, 1.0) is True and cap.read() == (False, None)
    assert cap.set(SR.CAP_PROP_POS_AVI_RATIO, 0.0) is True and red_index(cap.read()[1]) == 0


def test_every_frame_seekable_in_any_order(video):
    cap = SR.VideoCapture(str(video))
    order = list(range(VN))
    rng = np.random.default_rng(3)
    rng.shuffle(order)
    for n in order:
        assert cap.set(1, n)
        assert red_index(cap.read()[1]) == n, n
        assert cap.get(1) == n + 1


# ---- variable frame rate: exact PTS per frame
VFR_TS = 600


@pytest.fixture(scope="module")
def vfr(tmp_path_factory):
    p = tmp_path_factory.mktemp("vfr") / "vfr.mp4"
    gaps = [20, 20, 20, 60, 20, 100, 20, 20, 40, 20, 20, 80, 20, 20, 20, 20, 160, 20, 20, 20, 40, 40, 20, 20, 20, 20, 120, 20, 20, 20]
    pts = np.concatenate([[0], np.cumsum(gaps)[:-1]]).astype(np.int64)  # ticks of 1/600 s
    arr = (ctypes.c_int64 * len(pts))(*pts)
    lib = ctypes.CDLL(os.environ["SAFARIUM_RASTER_LIB"])
    lib.sr_video_write_test_pts.argtypes = [ctypes.c_char_p, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32,
                                            ctypes.POINTER(ctypes.c_int64), ctypes.c_int64]
    lib.sr_video_write_test_pts.restype = ctypes.c_int32
    end = int(pts[-1]) + 20
    os.environ["SAFARIUM_RASTER_TESTING"] = "1"
    assert lib.sr_video_write_test_pts(str(p).encode(), 128, 96, len(pts), VFR_TS, arr, end) == 0
    return p, pts, end


def test_vfr_frames_in_order_with_true_timestamps(vfr):
    p, pts, end = vfr
    n = len(pts)
    cap = SR.VideoCapture(str(p))
    assert cap.get(7) == n
    got = []
    for i in range(n):
        ok, f = cap.read()
        assert ok, i
        got.append((red_index(f), cap.get(SR.CAP_PROP_POS_MSEC)))
    assert [g[0] for g in got] == list(range(n))
    for i, (_, ms) in enumerate(got):  # POS_MSEC follows the real PTS, not frame/fps
        assert abs(ms - pts[i] * 1000 / VFR_TS) < 0.01, (i, ms, pts[i] * 1000 / VFR_TS)
    assert cap.read() == (False, None)


def test_vfr_seek_by_frame_and_by_time_is_exact(vfr):
    p, pts, end = vfr
    n = len(pts)
    cap = SR.VideoCapture(str(p))
    rng = np.random.default_rng(5)
    for k in rng.permutation(n):
        assert cap.set(1, int(k))
        assert red_index(cap.read()[1]) == k, k
    for k in rng.permutation(n):  # a time inside frame k's interval (pts_k + 0.4 * duration) lands on frame k
        nxt = pts[k + 1] if k + 1 < n else end
        t_ms = (pts[k] + 0.4 * (nxt - pts[k])) * 1000 / VFR_TS
        assert cap.set(SR.CAP_PROP_POS_MSEC, float(t_ms))
        f = cap.read()[1]
        assert red_index(f) == k, (k, t_ms)
    assert cap.set(SR.CAP_PROP_POS_MSEC, 1e9) and cap.read() == (False, None)


def test_vfr_frames_match_reference_decoder_order(vfr):
    p, pts, end = vfr
    rc = REF.VideoCapture(str(p))
    ref = []
    while True:
        ok, f = rc.read()
        if not ok:
            break
        ref.append(red_index(f))
    mine = [red_index(f) for f in read_all(p)]
    assert mine == list(range(len(pts)))
    # the reference duplicates/drops frames on VFR (it resamples to a constant rate): ours is the true frame list
    assert len(mine) == len(pts)


# ---- image sequences (reference reads the same PNGs; lossless so exact)
@pytest.fixture(scope="module")
def seq_dir(tmp_path_factory):
    d = tmp_path_factory.mktemp("seq")
    rng = np.random.default_rng(1)

    def put(name, img):
        ok, buf = REF.imencode(".png", img)
        assert ok
        (d / name).write_bytes(buf.tobytes())

    base = rng.integers(0, 255, (20, 30, 3), dtype=np.uint8)
    for i in range(5):
        put(f"img_{i:04d}.png", np.roll(base, i * 3, axis=1))
    for i in range(1, 4):
        put(f"one_{i}.png", np.roll(base, i, axis=0))
    put("gap_0000.png", base)
    put("gap_0001.png", base // 2)
    put("gap_0003.png", base // 3)
    put("sz_0000.png", base)
    put("sz_0001.png", rng.integers(0, 255, (10, 10, 3), dtype=np.uint8))
    put("gray_0000.png", base[..., 0])
    put("single.png", base)
    smooth = np.zeros((120, 160, 3), np.uint8)  # lossy decoders only agree on realistic (smooth) content, not on pixel noise
    smooth[..., 0] = np.linspace(20, 230, 160, dtype=np.uint8)[None, :]
    smooth[..., 1] = np.linspace(40, 200, 120, dtype=np.uint8)[:, None]
    smooth[..., 2] = 90
    smooth[30:60, 40:100] = (200, 120, 60)
    REF.imwrite(str(d / "e_0000.jpg"), smooth, [REF.IMWRITE_JPEG_QUALITY, 95])
    REF.imwrite(str(d / "e_0001.jpg"), smooth[::-1].copy(), [REF.IMWRITE_JPEG_QUALITY, 95])
    return d


def seq_frames(mod, name, *api):
    cap = mod.VideoCapture(name, *api)
    out = []
    while cap.isOpened():
        ok, f = cap.read()
        if not ok:
            break
        out.append(f)
    return cap, out


@pytest.mark.parametrize("name", ["img_%04d.png", "one_%d.png", "gap_%04d.png", "gray_%04d.png", "e_%04d.jpg"])
def test_image_sequence_matches_reference(seq_dir, name):
    mine_cap, mine = seq_frames(SR, str(seq_dir / name))
    ref_cap, ref = seq_frames(REF, str(seq_dir / name))
    assert mine_cap.isOpened() and ref_cap.isOpened()
    assert len(mine) == len(ref) > 0
    for a, b in zip(mine, ref):
        assert a.shape == b.shape and a.dtype == np.uint8
        if name.endswith("png"):
            assert np.array_equal(a, b)
        else:  # lossy decode: the cross-engine bar, not bit equality
            r = compare(b, a, name)
            assert r.ok, r
    for p in ("FRAME_WIDTH", "FRAME_HEIGHT", "FPS", "FRAME_COUNT", "FOURCC", "FORMAT"):
        pid = getattr(SR, "CAP_PROP_" + p)
        assert mine_cap.get(pid) == ref_cap.get(pid), (name, p)
    assert mine_cap.get(SR.CAP_PROP_POS_FRAMES) == ref_cap.get(SR.CAP_PROP_POS_FRAMES) == len(ref)


def test_image_sequence_rules(seq_dir):
    assert not SR.VideoCapture(str(seq_dir / "nothere_%04d.png")).isOpened()
    assert not SR.VideoCapture(str(seq_dir / "img_%3d.png")).isOpened()
    # a lone file name (no pattern) is one frame, like cv2
    cap, fr = seq_frames(SR, str(seq_dir / "img_0002.png"))
    _, rf = seq_frames(REF, str(seq_dir / "img_0002.png"))
    assert len(fr) == len(rf) == 1 and np.array_equal(fr[0], rf[0])
    # frames of another size are brought to the first frame's size (FFmpeg image2 does the same)
    cap, fr = seq_frames(SR, str(seq_dir / "sz_%04d.png"))
    assert [f.shape for f in fr] == [(20, 30, 3)] * 2
    # seeking
    cap = SR.VideoCapture(str(seq_dir / "img_%04d.png"))
    assert cap.set(1, 3) and cap.get(1) == 3
    assert np.array_equal(cap.read()[1], REF.imread(str(seq_dir / "img_0003.png")))
    assert cap.set(1, 99) and cap.read() == (False, None) and cap.get(1) == 5
    assert cap.set(0, 1000) and cap.get(1) == 5
    assert cap.set(1, -3) and cap.get(1) == 0
    assert cap.get(SR.CAP_PROP_FRAME_COUNT) == 5
    # CAP_IMAGES: cv2's own images backend reports -1 for fps / fourcc
    cap = SR.VideoCapture(str(seq_dir / "img_%04d.png"), SR.CAP_IMAGES)
    rcap = REF.VideoCapture(str(seq_dir / "img_%04d.png"), REF.CAP_IMAGES)
    for p in (3, 4, 5, 6, 7, 8):
        assert cap.get(p) == rcap.get(p), p
    dst = np.zeros((20, 30, 3), np.uint8)
    ok, f = cap.read(dst)
    assert ok and f is dst
    # waitAny
    a, b = SR.VideoCapture(str(seq_dir / "img_%04d.png")), SR.VideoCapture(str(seq_dir / "gap_%04d.png"))
    for _ in range(2):
        ok, ready = SR.VideoCapture.waitAny([a, b])
        assert ok and ready == [0, 1]
        assert a.retrieve()[0] and b.retrieve()[0]
    ok, ready = SR.VideoCapture_waitAny([a, b])
    assert ok and ready == [0]


def test_gif_video_capture_still_works(tmp_path):
    from PIL import Image
    frames = [Image.fromarray(np.full((20, 30, 3), v, np.uint8)) for v in (0, 120, 240)]
    p = tmp_path / "a.gif"
    frames[0].save(p, save_all=True, append_images=frames[1:], duration=100, loop=0)
    cap = SR.VideoCapture(str(p))
    assert cap.isOpened() and cap.get(7) == 3 and abs(cap.get(5) - 10.0) < 1e-6
    assert [int(f.mean()) for f in read_all(p)] == [0, 120, 240]
    assert cap.get(SR.CAP_PROP_ORIENTATION_META) == 0.0 and cap.get(SR.CAP_PROP_FORMAT) == 64.0


# ---- writing: every codec, read back with our reader, SF-VIDEO-1 verify
@pytest.mark.parametrize("fc,ext,name", CODECS)
def test_written_clip_roundtrip(clips, fc, ext, name):
    frames_out = read_all(clips[fc])
    src = [source_frame(i) for i in range(30)]
    worst = check_roundtrip(src, frames_out, name)
    assert worst.ssim > 0.97 and worst.psnr > 30
    cap = SR.VideoCapture(str(clips[fc]))
    assert (cap.get(3), cap.get(4), cap.get(5), cap.get(7)) == (256, 144, 30, 30)
    for i in range(30):  # CFR timestamps, exact
        cap.read()
        assert abs(cap.get(SR.CAP_PROP_POS_MSEC) - i * 1000 / 30) < 1e-6, i
    assert [stripe_index(f) for f in frames_out] == list(range(30))


@pytest.mark.parametrize("fc", ["avc1", "hvc1", "apcn", "ap4h"])
def test_written_clip_passes_render_verify(clips, fc):
    v = verify(clips[fc])["reference"]
    vid = v["video"]
    assert v["duration"] == "1/1", v["duration"]
    text = json.dumps(vid)
    assert "256" in text and "144" in text
    if fc == "ap4h":
        assert "activeBGRASHA256" in vid  # alpha-capable decode path


def test_codec_identity_in_file(clips):
    for fc, tag in (("avc1", b"avc1"), ("hvc1", b"hvc1"), ("apcn", b"apcn"), ("ap4h", b"ap4h"), ("MJPG", b"jpeg")):
        assert tag in clips[fc].read_bytes(), fc
    assert SR.VideoCapture(str(clips["avc1"])).get(6) == REF.VideoCapture(str(clips["avc1"])).get(6)


def test_h264_uses_bt709_tags(clips):
    data = clips["avc1"].read_bytes()
    i = data.find(b"colr")
    # mp4 carries ISO 'nclx': colour primaries / transfer / matrix 1 = BT.709
    assert i > 0 and data[i + 4:i + 8] == b"nclx" and struct.unpack(">3H", data[i + 8:i + 14]) == (1, 1, 1), data[i:i + 16]


def test_alpha_prores4444_keeps_alpha(tmp_path):
    p = tmp_path / "alpha.mov"
    frames = []
    for i in range(10):
        f = np.zeros((72, 128, 4), np.uint8)
        f[..., 0] = 30
        f[..., 1] = 160
        f[..., 2] = 220
        f[..., 3] = np.linspace(0, 255, 128, dtype=np.uint8)[None, :]
        frames.append(f)
    wr = SR.VideoWriter(str(p), SR.VideoWriter_fourcc(*"ap4h"), 24, (128, 72))
    assert wr.isOpened()
    for f in frames:
        wr.write(f)
    wr.release()
    v = verify(p)["reference"]["video"]
    assert "activeBGRASHA256" in v
    cap = SR.VideoCapture(str(p))
    ok, f = cap.read()
    assert ok and f.shape == (72, 128, 3)
    # fully opaque column on the right keeps its colour; BGR is what the file stores
    assert np.abs(f[:, -4:].astype(int).mean(axis=(0, 1)) - [30, 160, 220]).max() < 6, f[:, -4:].mean(axis=(0, 1))


def test_gray_frames(tmp_path):
    p = tmp_path / "gray.mp4"
    g = [np.full((72, 128), v, np.uint8) for v in (16, 60, 128, 200, 235)]
    wr = SR.VideoWriter(str(p), SR.VideoWriter_fourcc(*"avc1"), 24, (128, 72), False)
    assert wr.isOpened() and wr.get(SR.VIDEOWRITER_PROP_IS_COLOR) == 0.0
    for f in g:
        wr.write(f)
    wr.release()
    out = read_all(p)
    assert len(out) == 5
    for a, b in zip(g, out):
        assert abs(int(b.astype(int).mean()) - int(a[0, 0])) <= 4
        assert np.abs(b[..., 0].astype(int) - b[..., 2].astype(int)).max() <= 2  # neutral: no colour cast
    # 3-channel frame into a gray writer is refused, and vice versa
    wr = SR.VideoWriter(str(tmp_path / "g2.mp4"), SR.VideoWriter_fourcc(*"avc1"), 24, (128, 72), isColor=False)
    with pytest.raises(SR.error):
        wr.write(np.zeros((72, 128, 3), np.uint8))
    wr.release()


@pytest.mark.parametrize("fps", [24, 25, 29.97, 30000 / 1001, 23.976, 59.94, 60, 12.5])
def test_fractional_fps_timestamps_are_exact(tmp_path, fps):
    p = tmp_path / "f.mp4"
    write_clip(p, "avc1", n=20, fps=fps, size=(64, 48), frames=[source_frame(i, 64, 48) for i in range(20)])
    cap = SR.VideoCapture(str(p))
    assert cap.get(7) == 20
    assert abs(cap.get(5) - fps) < 5e-3, (cap.get(5), fps)
    for i in range(20):
        ok, f = cap.read()
        assert ok
        assert abs(cap.get(SR.CAP_PROP_POS_MSEC) - i * 1000 / fps) < 0.01, (fps, i, cap.get(SR.CAP_PROP_POS_MSEC))
    assert cap.read() == (False, None)
    d = verify(p)["reference"]["duration"] if fps in (24, 25, 60) else None
    if d:
        num, den = d.split("/")
        assert abs(int(num) / int(den) - 20 / fps) < 1e-9, d


def test_rate_params_control_size(tmp_path):
    yy, xx = np.mgrid[0:360, 0:640]
    src = []
    for i in range(40):  # textured but structured content (a smooth gradient looks fine at any bit rate; pure noise at none)
        tex = 45 * np.sin(xx * 0.9 + i * 0.5) * np.sin(yy * 0.7 - i * 0.3) + 25 * np.sin((xx + yy) * 0.31 + i)
        src.append(np.clip(source_frame(i, 640, 360).astype(float) + tex[..., None], 0, 255).astype(np.uint8))
    sizes = {}
    for key, params in (("lo", [SR.VIDEOWRITER_PROP_BITRATE, 300_000]), ("hi", [SR.VIDEOWRITER_PROP_BITRATE, 6_000_000]),
                        ("q10", [SR.VIDEOWRITER_PROP_QUALITY, 10]), ("q95", [SR.VIDEOWRITER_PROP_QUALITY, 95]),
                        ("crf40", [SR.VIDEOWRITER_PROP_CRF, 40]), ("crf10", [SR.VIDEOWRITER_PROP_CRF, 10])):
        p = tmp_path / f"{key}.mp4"
        write_clip(p, "hvc1" if key.startswith("crf") else "avc1", n=40, fps=30, size=(640, 360), params=params, frames=src)
        sizes[key] = p.stat().st_size
    assert sizes["lo"] < sizes["hi"], sizes
    assert sizes["q10"] < sizes["q95"], sizes
    assert sizes["crf40"] < sizes["crf10"], sizes
    # lower bitrate/quality is visibly worse, higher is better (so the knob does steer quality, not just bytes)
    lo = np.mean([compare(a, b, "x").psnr for a, b in zip(src[::8], read_all(tmp_path / "lo.mp4")[::8])])
    hi = np.mean([compare(a, b, "x").psnr for a, b in zip(src[::8], read_all(tmp_path / "hi.mp4")[::8])])
    assert hi > lo + 1.0, (lo, hi)
    cap = SR.VideoCapture(str(tmp_path / "hi.mp4"))
    assert 2000 < cap.get(SR.CAP_PROP_BITRATE) < 12000


def test_keyframe_interval_param(tmp_path):
    p = tmp_path / "gop.mp4"
    write_clip(p, "avc1", n=40, fps=30, size=(128, 72), params=[SR.VIDEOWRITER_PROP_KEY_INTERVAL, 5],
               frames=[source_frame(i, 128, 72) for i in range(40)])
    cap = SR.VideoCapture(str(p))
    types = []
    for _ in range(40):
        cap.read()
        types.append(cap.get(SR.CAP_PROP_FRAME_TYPE))
    syncs = [i for i, t in enumerate(types) if t == ord("I")]
    assert syncs[0] == 0 and max(b - a for a, b in zip(syncs, syncs[1:])) <= 5, syncs


# ---- writer overloads, refusals, lifecycle
def test_writer_signatures(tmp_path):
    fc = SR.VideoWriter_fourcc(*"avc1")
    forms = [
        ((str(tmp_path / "a.mp4"), fc, 24, (64, 48)), {}),
        ((str(tmp_path / "b.mp4"), fc, 24, (64, 48), True), {}),
        ((str(tmp_path / "c.mp4"), SR.CAP_ANY, fc, 24, (64, 48)), {}),
        ((str(tmp_path / "d.mp4"), SR.CAP_FFMPEG, fc, 24, (64, 48), True), {}),
        ((str(tmp_path / "e.mp4"), fc, 24, (64, 48), [SR.VIDEOWRITER_PROP_QUALITY, 80]), {}),
        ((str(tmp_path / "f.mp4"), SR.CAP_AVFOUNDATION, fc, 24, (64, 48), [SR.VIDEOWRITER_PROP_IS_COLOR, 1]), {}),
        ((), dict(filename=str(tmp_path / "g.mp4"), fourcc=fc, fps=24.0, frameSize=(64, 48), isColor=True)),
        ((), dict(filename=str(tmp_path / "h.mp4"), apiPreference=SR.CAP_ANY, fourcc=fc, fps=24.0, frameSize=(64, 48), params=[])),
    ]
    for args, kw in forms:
        w = SR.VideoWriter(*args, **kw)
        assert w.isOpened(), (args, kw)
        assert w.getBackendName() == "SAFARIUM"
        w.write(source_frame(0, 64, 48))
        w.release()
    for n in "abcdefgh":
        assert len(read_all(tmp_path / f"{n}.mp4")) == 1, n
    w = SR.VideoWriter()
    assert not w.isOpened()
    assert w.open(str(tmp_path / "late.mp4"), fc, 24, (64, 48)) is True and w.isOpened()
    w.release()
    with pytest.raises(SR.error):
        SR.VideoWriter().getBackendName()


def test_writer_refusals_are_explicit(tmp_path):
    ok_fc = SR.VideoWriter_fourcc(*"avc1")
    cases = [
        (str(tmp_path / "x.mp4"), SR.VideoWriter_fourcc(*"mp4v"), "mp4v"),
        (str(tmp_path / "x.mp4"), SR.VideoWriter_fourcc(*"XVID"), "XVID"),
        (str(tmp_path / "x.avi"), ok_fc, "avi container"),
        (str(tmp_path / "x.mkv"), ok_fc, "mkv container"),
        (str(tmp_path / "x.webm"), SR.VideoWriter_fourcc(*"VP80"), "webm"),
        (str(tmp_path / "x.mp4"), SR.VideoWriter_fourcc(*"apcn"), "ProRes in mp4"),
        (str(tmp_path / "x.mp4"), SR.VideoWriter_fourcc(*"MJPG"), "MJPG in mp4"),
        (str(tmp_path / "x"), ok_fc, "no extension"),
        (str(tmp_path / "x.mp4"), SR.VideoWriter_fourcc(*"zzzz"), "unknown fourcc"),
    ]
    for path, fc, why in cases:
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            wr = SR.VideoWriter(path, fc, 24, (64, 48))
        assert not wr.isOpened(), why
        assert any("VideoWriter" in str(x.message) for x in w), (why, [str(x.message) for x in w])
        assert not os.path.exists(path), why
    for bad in ((0, 48), (64, 0), (-1, 48)):
        assert not SR.VideoWriter(str(tmp_path / "y.mp4"), ok_fc, 24, bad).isOpened()
    assert not SR.VideoWriter(str(tmp_path / "y.mp4"), ok_fc, 0, (64, 48)).isOpened()
    assert not SR.VideoWriter(str(tmp_path / "y.mp4"), SR.CAP_GSTREAMER, ok_fc, 24, (64, 48)).isOpened()
    with pytest.raises(SR.error):
        SR.VideoWriter(str(tmp_path / "z.mp4"), ok_fc, 24)  # no frame size
    # H.264 has no alpha
    w = SR.VideoWriter(str(tmp_path / "z.mp4"), ok_fc, 24, (64, 48), params=[SR.VIDEOWRITER_PROP_ENABLE_ALPHA, 1])
    assert not w.isOpened()


def test_writer_frame_validation_and_lifecycle(tmp_path):
    p = tmp_path / "v.mp4"
    w = SR.VideoWriter(str(p), SR.VideoWriter_fourcc(*"avc1"), 24, (64, 48))
    for bad in (np.zeros((48, 65, 3), np.uint8), np.zeros((47, 64, 3), np.uint8), np.zeros((48, 64, 3), np.float32),
                np.zeros((48, 64, 4), np.uint8), np.zeros((48, 64), np.uint8), np.zeros((0, 0, 3), np.uint8)):
        with pytest.raises(SR.error):
            w.write(bad)
    # a non-contiguous and a read-only frame are fine
    base = np.zeros((48, 128, 3), np.uint8)
    base[:, :64] = source_frame(0, 64, 48)
    w.write(base[:, :64])
    ro = source_frame(1, 64, 48)
    ro.flags.writeable = False
    w.write(ro)
    w.write(np.ascontiguousarray(source_frame(2, 64, 48)[..., ::-1])[..., ::-1])  # negative channel stride view
    w.release()
    w.release()  # double release is harmless
    assert not w.isOpened()
    w.write(source_frame(0, 64, 48))  # after release: ignored, like cv2
    assert len(read_all(p)) == 3
    # released by garbage collection still finishes a valid file
    q = tmp_path / "gc.mp4"
    w2 = SR.VideoWriter(str(q), SR.VideoWriter_fourcc(*"avc1"), 24, (64, 48))
    for i in range(5):
        w2.write(source_frame(i, 64, 48))
    del w2
    assert len(read_all(q)) == 5
    # a writer that never got a frame fails loudly on release, not silently
    e = tmp_path / "empty.mp4"
    w3 = SR.VideoWriter(str(e), SR.VideoWriter_fourcc(*"avc1"), 24, (64, 48))
    with pytest.warns(RuntimeWarning, match="no frames"):
        w3.release()


def test_writer_props_like_cv2(tmp_path):
    w = SR.VideoWriter(str(tmp_path / "p.mp4"), SR.VideoWriter_fourcc(*"avc1"), 24, (64, 48),
                       params=[SR.VIDEOWRITER_PROP_QUALITY, 70])
    assert w.get(SR.VIDEOWRITER_PROP_QUALITY) == 70.0 and w.get(SR.VIDEOWRITER_PROP_IS_COLOR) == 1.0
    assert w.get(SR.VIDEOWRITER_PROP_DEPTH) == 0.0
    assert w.set(SR.VIDEOWRITER_PROP_QUALITY, 50) is False  # open-only here
    w.write(source_frame(0, 64, 48))
    w.release()


def test_image_sequence_writer(tmp_path):
    pat = str(tmp_path / "out_%04d.png")
    w = SR.VideoWriter(pat, 0, 25, (64, 48))
    assert w.isOpened()
    src = [source_frame(i, 64, 48) for i in range(4)]
    for f in src:
        w.write(f)
    w.release()
    for i, f in enumerate(src):
        assert np.array_equal(REF.imread(pat % i), f)
    cap = SR.VideoCapture(pat)
    assert cap.get(7) == 4
    assert all(np.array_equal(a, b) for a, b in zip(read_all(pat), src))


def test_odd_frame_sizes(tmp_path):
    """4:2:0 codecs refuse odd sides (AVAssetWriter would silently crop); the others keep the exact resolution."""
    for fc, ext in (("avc1", "mp4"), ("hvc1", "mp4")):
        for size in ((65, 48), (64, 49), (65, 49)):
            with pytest.warns(RuntimeWarning, match="even"):
                w = SR.VideoWriter(str(tmp_path / f"o.{ext}"), SR.VideoWriter_fourcc(*fc), 24, size)
            assert not w.isOpened() and not (tmp_path / f"o.{ext}").exists()
    for fc, ext in (("apcn", "mov"), ("ap4h", "mov"), ("MJPG", "mov")):
        for size in ((65, 48), (64, 49), (63, 47)):
            p = tmp_path / f"o_{fc}.{ext}"
            w = SR.VideoWriter(str(p), SR.VideoWriter_fourcc(*fc), 24, size)
            assert w.isOpened(), (fc, size)
            src = [source_frame(i, size[0], size[1]) for i in range(3)]
            for f in src:
                w.write(f)
            w.release()
            out = read_all(p)
            assert [f.shape[:2] for f in out] == [(size[1], size[0])] * 3, (fc, size)
            for a_, b_ in zip(src, out):
                # MJPG: AVFoundation's JPEG decoder upsamples chroma differently from the encoder's own decoder, so the
                # mean bound is a little wider; the exact-bytes check below is what proves the encoder.
                assert np.abs(a_.astype(int) - b_.astype(int)).mean() < (8 if fc == "MJPG" else 6), (fc, size)
            if fc == "MJPG":
                data = p.read_bytes()
                want = bytes(SR.imencode(".jpg", src[0], [1, 95])[1])
                assert want in data, "the file does not contain Safarium's own JPEG of frame 0"


def test_nonfinite_and_huge_numbers_are_refused_not_trapped(tmp_path):
    fc = SR.VideoWriter_fourcc(*"avc1")
    nan, inf = float("nan"), float("inf")
    for fps in (nan, inf, -inf, 0, -5, 1e6, 1e12, 2.0 ** 31, 2.0 ** 40, 1e308):
        with warnings.catch_warnings(record=True) as w:
            warnings.simplefilter("always")
            wr = SR.VideoWriter(str(tmp_path / "f.mp4"), fc, fps, (64, 48))
        assert not wr.isOpened(), fps
        assert any("VideoWriter" in str(x.message) for x in w), fps
        assert not (tmp_path / "f.mp4").exists()
    for size in ((2 ** 31, 48), (64, 2 ** 31), (40000, 48), (2 ** 40, 2 ** 40)):
        with warnings.catch_warnings(record=True):
            warnings.simplefilter("always")
            assert not SR.VideoWriter(str(tmp_path / "s.mp4"), fc, 24, size).isOpened(), size
    for size in ((nan, 48), (64, inf)):
        with pytest.raises(SR.error):
            SR.VideoWriter(str(tmp_path / "s.mp4"), fc, 24, size)
    for key in (SR.VIDEOWRITER_PROP_BITRATE, SR.VIDEOWRITER_PROP_QUALITY, SR.VIDEOWRITER_PROP_CRF, SR.VIDEOWRITER_PROP_GOP_SIZE,
                SR.VIDEOWRITER_PROP_KEY_INTERVAL):
        for bad in (nan, inf, -inf, 1e300, -1e300, -1):
            with warnings.catch_warnings(record=True) as w:
                warnings.simplefilter("always")
                wr = SR.VideoWriter(str(tmp_path / "p.mp4"), fc, 24, (64, 48), params=[key, bad])
            assert not wr.isOpened(), (key, bad)
            assert any("out of range" in str(x.message) for x in w), (key, bad, [str(x.message) for x in w])
    # a valid extreme still works: huge-but-legal fps and bitrate
    for params, fps in (([SR.VIDEOWRITER_PROP_BITRATE, 2_000_000_000], 24), ([], 1000), ([], 0.5)):
        wr = SR.VideoWriter(str(tmp_path / "ok.mp4"), fc, fps, (64, 48), params=params)
        assert wr.isOpened(), (params, fps)
        wr.write(source_frame(0, 64, 48))
        wr.release()
    assert len(read_all(tmp_path / "ok.mp4")) == 1
    # a bogus parameter id is refused by the library
    arr = (ctypes.c_double * 2)(nan, 1.0)
    h = ctypes.c_void_p()
    rc = SR._lib.lib.sr_vw_open(str(tmp_path / "q.mp4").encode(), 0x31637661, 24.0, 64, 48, 1, arr, 1, ctypes.byref(h))
    assert rc != 0 and not h.value


@pytest.mark.parametrize("fc,ext", [("avc1", "mp4"), ("MJPG", "mov"), ("apcn", "mov")])
def test_forced_writer_failure_then_close(tmp_path, fc, ext):
    """The writer is cancelled under the caller: later writes raise, close returns without hanging, no half file stays."""
    p = tmp_path / f"fail.{ext}"
    w = SR.VideoWriter(str(p), SR.VideoWriter_fourcc(*fc), 24, (64, 48))
    for i in range(3):
        w.write(source_frame(i, 64, 48))
    os.environ["SAFARIUM_RASTER_TESTING"] = "1"
    fn = SR._lib.lib.sr_vw_test_force_failure
    fn.argtypes, fn.restype = [ctypes.c_void_p], ctypes.c_int32
    assert fn(w._h) == 0
    t0 = time.perf_counter()
    with pytest.raises(SR.error):
        for i in range(50):  # the failure is seen within a few frames, never a hang
            w.write(source_frame(i, 64, 48))
    with pytest.warns(RuntimeWarning, match="VideoWriter"):
        w.release()
    assert time.perf_counter() - t0 < 10
    assert not w.isOpened()
    assert not p.exists()
    w.release()
    # the process is still healthy: a new writer works
    write_clip(tmp_path / f"after.{ext}", fc, n=3, size=(64, 48), frames=[source_frame(i, 64, 48) for i in range(3)])
    assert len(read_all(tmp_path / f"after.{ext}")) == 3


def test_release_without_waiting_does_not_touch_freed_writer(tmp_path):
    """Open/close many writers back to back (the encoder callback must never fire into a freed box)."""
    for i in range(40):
        w = SR.VideoWriter(str(tmp_path / f"r{i % 3}.mp4"), SR.VideoWriter_fourcc(*"avc1"), 30, (64, 48))
        for k in range(i % 4):
            w.write(source_frame(k, 64, 48))
        w.release() if i % 2 else None
        del w


# ---- streaming memory: RSS stays flat (bounded queue, no clip in memory)
def rss_mb():
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return r / (1024 * 1024) if sys.platform == "darwin" else r / 1024


def test_streaming_write_and_read_memory_is_bounded(tmp_path):
    w_, h_ = 1080, 1920
    frame = (np.arange(h_ * w_ * 3, dtype=np.uint32) * 7 % 251).astype(np.uint8).reshape(h_, w_, 3)
    p = tmp_path / "big.mp4"
    wr = SR.VideoWriter(str(p), SR.VideoWriter_fourcc(*"avc1"), 30, (w_, h_))
    assert wr.isOpened()
    for i in range(12):  # warm the encoder, pools and Python
        frame[0, 0, 0] = i
        wr.write(frame)
    base = rss_mb()
    for i in range(12, 150):
        frame[0, 0, 0] = i % 250
        wr.write(frame)
    peak_w = rss_mb()
    wr.release()
    assert peak_w - base < 150, (base, peak_w)  # 138 more 6 MB frames would be 830 MB if they were held
    cap = SR.VideoCapture(str(p))
    dst = np.empty((h_, w_, 3), np.uint8)
    for i in range(10):
        assert cap.read(dst)[0]
    base = rss_mb()
    n = 10
    while cap.read(dst)[0]:
        n += 1
    assert n == 150
    assert rss_mb() - base < 100, (base, rss_mb())
