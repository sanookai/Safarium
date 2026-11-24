"""scipy / tifffile stand-ins (Area E) vs the real libraries (reference python = $SCRATCH/sciref). The shim directory
sdk/python/safarium_sci is put first on sys.path for the shim engine. Truth = the real scipy run in float64."""
from __future__ import annotations

import io

import numpy as np

from . import register

# sos designed once with real scipy.signal.butter(..., fs=48000, output="sos") and frozen so both engines get the same input
SOS_BAND2 = np.array([[0.002251582656846632, 0.004503165313693264, 0.002251582656846632, 1.0, -1.881189876625421, 0.8916032560580421],
                      [1.0, -2.0, 1.0, 1.0, -1.975702513172533, 0.9761824797551086]])
SOS_BAND4 = np.array([[0.0006390282088877578, 0.0012780564177755156, 0.0006390282088877578, 1.0, -1.4765539405623136, 0.5598052385040955],
                      [1.0, 2.0, 1.0, 1.0, -1.655319567155438, 0.7859394650222887],
                      [1.0, -2.0, 1.0, 1.0, -1.9185676790251471, 0.9207041942086085],
                      [1.0, -2.0, 1.0, 1.0, -1.9731411623179922, 0.9747281215652033]])
SOS_LOW1 = np.array([[0.0013072864516988417, 0.0013072864516988417, 0.0, 1.0, -0.9973854270966024, 0.0]])
SR = 48000


def _sig():
    import scipy.signal as signal   # submodules are not auto-imported by the shim's top-level package
    return signal


def _nd():
    import scipy.ndimage as ndimage
    return ndimage

SECONDS = 20


def _stereo(rng):
    return rng.standard_normal((SECONDS * SR, 2), dtype=np.float32)


def _mono_abs(rng):
    return np.abs(rng.standard_normal(SECONDS * SR))


register(area="sci", op="sosfilt", variant="band2_stereo_f32_20s", phases=(0,), family="sci", metric="numeric",
         make_input=lambda rng: {"x": _stereo(rng)},
         ref=lambda m, x: _sig().sosfilt(SOS_BAND2, x["x"], axis=0),
         truth=lambda m, x: _sig().sosfilt(SOS_BAND2, x["x"].astype(np.float64), axis=0))
register(area="sci", op="sosfilt", variant="band4_stereo_f32_20s", phases=(0,), family="sci", metric="numeric",
         make_input=lambda rng: {"x": _stereo(rng)},
         ref=lambda m, x: _sig().sosfilt(SOS_BAND4, x["x"], axis=0),
         truth=lambda m, x: _sig().sosfilt(SOS_BAND4, x["x"].astype(np.float64), axis=0))
register(area="sci", op="sosfilt", variant="low1_mono_f64_20s", phases=(0,), family="sci", metric="numeric",
         make_input=lambda rng: {"x": _mono_abs(rng)}, ref=lambda m, x: _sig().sosfilt(SOS_LOW1, x["x"]))
register(area="sci", op="sosfiltfilt", variant="low1_mono_f64_20s", phases=(0,), family="sci", metric="numeric",
         make_input=lambda rng: {"x": _mono_abs(rng)}, ref=lambda m, x: _sig().sosfiltfilt(SOS_LOW1, x["x"]))
register(area="sci", op="sosfiltfilt", variant="band2_stereo_f32_20s", phases=(0,), family="sci", metric="numeric",
         make_input=lambda rng: {"x": _stereo(rng)}, ref=lambda m, x: _sig().sosfiltfilt(SOS_BAND2, x["x"], axis=0),
         truth=lambda m, x: _sig().sosfiltfilt(SOS_BAND2, x["x"].astype(np.float64), axis=0))
register(area="sci", op="lfilter", variant="brown_mono_f64_20s", phases=(0,), family="sci", metric="numeric",
         make_input=lambda rng: {"x": _mono_abs(rng)}, ref=lambda m, x: _sig().lfilter([1.0], [1.0, -0.98], x["x"]))
register(area="sci", op="minimum_filter1d", variant="size48001_mono_f64_20s", phases=(0,), family="sci", metric="numeric",
         make_input=lambda rng: {"x": _mono_abs(rng)},
         ref=lambda m, x: _nd().minimum_filter1d(x["x"], size=48001, mode="nearest"))


def _wav_bytes(rng):
    import struct
    pcm = (rng.standard_normal((10 * SR, 2)) * 3000).astype("<i2")
    data = pcm.tobytes()
    hdr = (b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 2, SR, SR * 4, 4, 16)
           + b"data" + struct.pack("<I", len(data)))
    return {"wav": np.frombuffer(hdr + data, np.uint8).copy(), "pcm": pcm}


def _wav_read(m, x):
    from scipy.io import wavfile
    rate, data = wavfile.read(io.BytesIO(x["wav"].tobytes()))
    return data


def _wav_write(m, x):
    from scipy.io import wavfile
    b = io.BytesIO()
    wavfile.write(b, SR, x["pcm"])
    return np.frombuffer(b.getvalue(), np.uint8)


register(area="sci", op="wavfile.read", variant="pcm16_stereo_10s", phases=(0,), family="sci", metric="numeric",
         make_input=_wav_bytes, ref=_wav_read, stream=True)
register(area="sci", op="wavfile.write", variant="pcm16_stereo_10s", phases=(0,), family="sci", metric="numeric",
         make_input=_wav_bytes, ref=_wav_write)


def _tiff_f32_bytes(a):
    """Minimal baseline little-endian TIFF, one uncompressed float32 strip (numpy-only: the sci python has no Pillow)."""
    import struct
    h, w = a.shape
    data = np.ascontiguousarray(a, "<f4").tobytes()
    tags = [(256, 4, 1, w), (257, 4, 1, h), (258, 3, 1, 32), (259, 3, 1, 1), (262, 3, 1, 1), (273, 4, 1, 8 + 2 + 12 * 10 + 4),
            (277, 3, 1, 1), (278, 4, 1, h), (279, 4, 1, len(data)), (339, 3, 1, 3)]
    ifd = struct.pack("<H", len(tags)) + b"".join(struct.pack("<HHII", *t) for t in tags) + struct.pack("<I", 0)
    return struct.pack("<2sHI", b"II", 42, 8) + ifd + data


def _tif_input(rng):
    a = rng.random((1920, 1080), dtype=np.float32)
    return {"buf": np.frombuffer(_tiff_f32_bytes(a), np.uint8).copy(), "arr": a}


def _tif_read(m, x):
    import tifffile
    return tifffile.imread(io.BytesIO(x["buf"].tobytes()))


def _tif_write(m, x):
    import tifffile
    b = io.BytesIO()
    tifffile.imwrite(b, x["arr"])
    return np.array([len(b.getvalue())], np.int64)


register(area="sci", op="tifffile.imread", variant="f32_1080x1920", phases=(0,), family="sci", metric="numeric",
         make_input=_tif_input, ref=_tif_read)
register(area="sci", op="tifffile.imwrite", variant="f32_1080x1920", phases=(0,), family="sci", metric="numeric",
         make_input=_tif_input, ref=_tif_write, note="quality cell compares the written file length (layout differences count), not pixels")
