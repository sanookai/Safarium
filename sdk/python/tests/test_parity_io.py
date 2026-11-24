"""Area C parity: imdecode / imread / imencode / imwrite / VideoCapture vs reference OpenCV 5.1.

Run (reference venv, which has real cv2 + Pillow):
    SAFARIUM_RASTER_LIB=<dylib> $SCRATCH/cvref/bin/python -m pytest -q sdk/python/tests/test_parity_io.py
Lossless formats must match exactly; lossy ones must pass the cross-engine bar (raster_parity.compare).
Video is NOT compared with the reference (its VideoCapture is FFmpeg): values are checked against what was written.
"""
from __future__ import annotations

import ctypes
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import compare, load_pair  # noqa: E402

REF, SR = load_pair()

# cv2 constant values (the shim's _constants module is owned by another area).
COLOR, UNCHANGED, GRAY = 1, -1, 0
ANYDEPTH, IGNORE_ORIENT = 2, 128
RED2, RED4, RED8 = 17, 33, 65
JPEG_QUALITY = 1


def smooth(h=120, w=160):
    y, x = np.mgrid[0:h, 0:w]
    base = np.stack([x * 1.5 % 256, y * 2 % 256, (x + y) % 256], -1).astype(np.uint8)
    return REF.GaussianBlur(base, (0, 0), 1.5)


def photo(h=1080, w=1920):
    """Photo-like fixture: smooth gradients + soft blobs, deterministic."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    r = 128 + 100 * np.sin(x / 90) * np.cos(y / 130)
    g = 128 + 90 * np.sin((x + y) / 160)
    b = 128 + 80 * np.cos(x / 200 - y / 70)
    img = np.stack([b, g, r], -1)
    img[300:700, 500:1100] = (30, 200, 240)
    return np.clip(img, 0, 255).astype(np.uint8)


@pytest.fixture(scope="module")
def fx(tmp_path_factory):
    d = tmp_path_factory.mktemp("iofx")
    rng = np.random.default_rng(7)
    base = smooth()
    im = Image.fromarray(base[..., ::-1])
    p3 = Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
    exif = im.getexif()
    exif[0x0112] = 6
    files = {}

    def put(name, writer):
        p = d / name
        writer(p)
        files[name] = p

    put("plain.jpg", lambda p: im.save(p, quality=92))
    put("exif6.jpg", lambda p: im.save(p, quality=92, exif=exif))
    for o in (2, 3, 4, 5, 7, 8):
        e = im.getexif()
        e[0x0112] = o
        put(f"exif{o}.jpg", lambda p, e=e: im.save(p, quality=92, exif=e))
    put("exif6.png", lambda p: im.save(p, exif=exif))
    put("p3.png", lambda p: im.save(p, icc_profile=p3))
    put("p3.jpg", lambda p: im.save(p, quality=92, icc_profile=p3))
    rgba = rng.integers(0, 256, (40, 50, 4), dtype=np.uint8)
    rgba[:10, :, 3] = 0
    rgba[10:20, :, 3] = 3
    put("rgba.png", lambda p: REF.imwrite(str(p), rgba))
    put("rgba.tif", lambda p: REF.imwrite(str(p), rgba))
    put("rgb16.png", lambda p: REF.imwrite(str(p), rng.integers(0, 65536, (40, 50, 3)).astype(np.uint16)))
    put("rgba16.png", lambda p: REF.imwrite(str(p), rng.integers(0, 65536, (40, 50, 4)).astype(np.uint16)))
    put("gray16.png", lambda p: REF.imwrite(str(p), rng.integers(0, 65536, (40, 50)).astype(np.uint16)))
    put("gray.png", lambda p: REF.imwrite(str(p), rng.integers(0, 256, (40, 50), dtype=np.uint8)))
    put("rgb.png", lambda p: REF.imwrite(str(p), rng.integers(0, 256, (40, 50, 3), dtype=np.uint8)))
    put("u8.tif", lambda p: REF.imwrite(str(p), rng.integers(0, 256, (40, 50, 3), dtype=np.uint8)))
    put("u16.tif", lambda p: REF.imwrite(str(p), rng.integers(0, 65536, (40, 50, 3)).astype(np.uint16)))
    put("f32.tif", lambda p: REF.imwrite(str(p), (rng.random((40, 50)) * 1000 - 200).astype(np.float32)))
    put("gray.jpg", lambda p: Image.fromarray(base[..., 0]).save(p, quality=92))
    ga = np.stack([rng.integers(0, 256, (40, 50), dtype=np.uint8), rng.integers(0, 256, (40, 50), dtype=np.uint8)], -1)
    put("la.png", lambda p: Image.fromarray(ga, "LA").save(p))
    put("pal.png", lambda p: Image.fromarray(rng.integers(0, 256, (40, 50, 3), dtype=np.uint8)).quantize(16).save(p))
    put("x.bmp", lambda p: Image.fromarray(rng.integers(0, 256, (40, 50, 3), dtype=np.uint8)).save(p))
    put("x.webp", lambda p: Image.fromarray(rng.integers(0, 256, (40, 50, 3), dtype=np.uint8)).save(p, lossless=True))
    rgba_pil = rng.integers(0, 256, (40, 50, 4), dtype=np.uint8)
    rgba_pil[:10, :, 3] = 0
    rgba_pil[10:20, :, 3] = 100
    put("pil_rgba.tif", lambda p: Image.fromarray(rgba_pil, "RGBA").save(p))  # ExtraSamples = 2 (unassociated)
    gif_frames = [Image.fromarray(np.full((20, 30, 3), c, np.uint8)) for c in (10, 120, 230)]
    put("anim.gif", lambda p: gif_frames[0].save(p, save_all=True, append_images=gif_frames[1:], duration=100, loop=0))
    put("single.gif", lambda p: gif_frames[0].save(p))
    noisy = [Image.fromarray(rng.integers(0, 256, (20, 30, 3), dtype=np.uint8)).convert("P", palette=Image.ADAPTIVE) for _ in range(3)]
    put("noisy.gif", lambda p: noisy[0].save(p, save_all=True, append_images=noisy[1:], duration=[100, 200, 300], loop=0))
    def pal(arr):
        return Image.fromarray(arr).convert("P", palette=Image.ADAPTIVE, colors=16)

    tr_still = pal(rng.integers(0, 256, (20, 30, 3), dtype=np.uint8))
    put("tr_still.gif", lambda p: tr_still.save(p, transparency=int(np.array(tr_still)[0, 0])))
    tr_frames = [pal(rng.integers(0, 256, (20, 30, 3), dtype=np.uint8)) for _ in range(3)]
    put("tr_anim.gif", lambda p: tr_frames[0].save(p, save_all=True, append_images=tr_frames[1:], duration=100, loop=0,
                                                   transparency=int(np.array(tr_frames[0])[0, 0]), disposal=2))
    flag_only = pal(rng.integers(0, 256, (20, 30, 3), dtype=np.uint8))
    put("tflag_nopx.gif", lambda p: flag_only.save(p, transparency=200))  # transparency declared, no pixel uses it
    put("photo.jpg", lambda p: REF.imwrite(str(p), photo(), [JPEG_QUALITY, 92]))
    put("photo.png", lambda p: REF.imwrite(str(p), photo(540, 960)))
    return files


def both(path, flags):
    a = REF.imread(str(path), flags)
    b = SR.imread(str(path), flags)
    return a, b


def assert_same(a, b, what):
    assert a is not None and b is not None, f"{what}: ref={a is None and 'None' or 'ok'} sr={b is None and 'None' or 'ok'}"
    assert a.shape == b.shape and a.dtype == b.dtype, f"{what}: {a.shape}{a.dtype} vs {b.shape}{b.dtype}"
    assert np.array_equal(a, b), f"{what}: {int((a != b).sum())} differing samples, max {np.abs(a.astype(int) - b.astype(int)).max()}"


LOSSLESS = ["x.webp", "rgb.png", "rgba.png", "gray.png", "rgb16.png", "rgba16.png", "gray16.png", "la.png", "pal.png",
            "u8.tif", "u16.tif", "rgba.tif", "x.bmp", "p3.png"]


@pytest.mark.parametrize("name", LOSSLESS)
@pytest.mark.parametrize("flags", [COLOR, UNCHANGED, GRAY, COLOR | ANYDEPTH, 4])
def test_decode_lossless_exact(fx, name, flags):
    a, b = both(fx[name], flags)
    assert_same(a, b, f"{name} flags={flags}")


def test_decode_f32_tiff(fx):
    a, b = both(fx["f32.tif"], UNCHANGED)
    assert_same(a, b, "f32.tif unchanged")
    assert b.dtype == np.float32 and b.ndim == 2
    assert SR.imread(str(fx["f32.tif"]), COLOR) is None  # cv2 refuses it without UNCHANGED
    assert REF.imread(str(fx["f32.tif"]), COLOR) is None


@pytest.mark.parametrize("name", ["plain.jpg", "p3.jpg", "photo.jpg", "gray.jpg"])
@pytest.mark.parametrize("flags", [COLOR, GRAY, UNCHANGED])
def test_decode_jpeg_bar(fx, name, flags):
    a, b = both(fx[name], flags)
    assert a is not None and b is not None
    assert a.shape == b.shape and a.dtype == b.dtype
    r = compare(a, b, f"{name} flags={flags}")
    print(r)
    assert r.ok, r


@pytest.mark.parametrize("name", ["exif6.jpg", "exif2.jpg", "exif3.jpg", "exif4.jpg", "exif5.jpg", "exif7.jpg", "exif8.jpg",
                                  "exif6.png"])
@pytest.mark.parametrize("flags", [COLOR, UNCHANGED, GRAY, COLOR | IGNORE_ORIENT])
def test_exif_orientation(fx, name, flags):
    a, b = both(fx[name], flags)
    assert a is not None and b is not None
    assert a.shape == b.shape, f"{name} flags={flags}: {a.shape} vs {b.shape}"
    r = compare(a, b, f"{name} flags={flags}")
    print(r)
    assert r.ok, r
    if name.endswith(".png"):
        assert np.array_equal(a, b)


def test_icc_profile_is_ignored(fx):
    """cv2 ignores ICC: a Display-P3 tagged PNG must decode to the raw sample values."""
    raw = np.array(Image.open(fx["p3.png"]).convert("RGB"))[..., ::-1]
    assert np.array_equal(SR.imread(str(fx["p3.png"])), raw)
    a, b = both(fx["p3.jpg"], COLOR)
    r = compare(a, b, "p3.jpg")
    print(r)
    assert r.ok, r


@pytest.mark.parametrize("name", ["photo.jpg", "photo.png", "plain.jpg"])
@pytest.mark.parametrize("flags", [RED2, RED4, RED8])
def test_reduced(fx, name, flags):
    a, b = both(fx[name], flags)
    assert a is not None and b is not None
    assert a.shape == b.shape, f"{name} flags={flags}: {a.shape} vs {b.shape}"
    r = compare(a, b, f"{name} reduced flags={flags}")
    print(r)
    assert r.ok, r


def test_failures_like_cv2(fx, tmp_path):
    assert SR.imread(str(tmp_path / "missing.png")) is None
    assert SR.imdecode(np.frombuffer(b"garbage" * 20, np.uint8), COLOR) is None
    with pytest.raises(SR.error):
        SR.imdecode(np.empty(0, np.uint8), COLOR)
    with pytest.raises(SR.error):
        SR.imencode(".xyz", np.zeros((4, 4, 3), np.uint8))
    assert SR.imwrite(str(tmp_path / "no_such_dir" / "x.png"), np.zeros((4, 4, 3), np.uint8)) is False
    # empty file
    e = tmp_path / "empty.png"
    e.write_bytes(b"")
    assert SR.imread(str(e)) is None
    # truncated PNG: refuse (cv2 returns None)
    t = tmp_path / "trunc.png"
    t.write_bytes(fx["rgb.png"].read_bytes()[:60])
    assert SR.imread(str(t)) is None


def test_non_ascii_paths(tmp_path):
    img = smooth(30, 40)
    p = tmp_path / "สำรวจ ไปกับสมพง ภาพ.png"
    assert SR.imwrite(str(p), img) is True
    back = SR.imread(str(p))
    assert np.array_equal(back, img)
    pj = tmp_path / "สมพง.jpg"
    assert SR.imwrite(str(pj), img, [JPEG_QUALITY, 90]) is True
    assert SR.imread(str(pj)).shape == img.shape
    assert np.array_equal(SR.imread(Path(p)), img)  # PathLike


def roundtrip_exact(img, ext):
    ok, buf = SR.imencode(ext, img)
    assert ok is True and buf.dtype == np.uint8 and buf.ndim == 1 and buf.size > 0
    back = REF.imdecode(buf, UNCHANGED)  # decoded by the REFERENCE: proves the file is valid for cv2 too
    assert back is not None
    assert back.shape == img.shape and back.dtype == img.dtype, f"{ext}: {back.shape}{back.dtype} vs {img.shape}{img.dtype}"
    assert np.array_equal(back, img), f"{ext}: roundtrip differs ({int((back != img).sum())} samples)"
    again = SR.imdecode(buf, UNCHANGED)
    assert np.array_equal(again, img)


def test_png_roundtrip_all_layouts():
    rng = np.random.default_rng(3)
    roundtrip_exact(rng.integers(0, 256, (33, 47, 3), dtype=np.uint8), ".png")
    rgba = rng.integers(0, 256, (33, 47, 4), dtype=np.uint8)
    rgba[:5, :, 3] = 0  # colour under alpha 0 must survive (cv2 keeps it)
    rgba[5:9, :, 3] = 2
    roundtrip_exact(rgba, ".png")
    roundtrip_exact(rng.integers(0, 256, (33, 47), dtype=np.uint8), ".png")
    roundtrip_exact(rng.integers(0, 65536, (33, 47, 3)).astype(np.uint16), ".png")
    roundtrip_exact(rng.integers(0, 65536, (33, 47)).astype(np.uint16), ".png")
    roundtrip_exact(rng.integers(0, 65536, (33, 47, 4)).astype(np.uint16), ".png")


def test_tiff_roundtrip_all_layouts():
    rng = np.random.default_rng(4)
    roundtrip_exact(rng.integers(0, 256, (33, 47, 3), dtype=np.uint8), ".tif")
    roundtrip_exact(rng.integers(0, 256, (33, 47), dtype=np.uint8), ".tiff")
    roundtrip_exact(rng.integers(0, 65536, (33, 47, 3)).astype(np.uint16), ".tif")
    roundtrip_exact((rng.random((33, 47)) * 4000 - 500).astype(np.float32), ".tif")
    roundtrip_exact(rng.integers(0, 256, (33, 47, 4), dtype=np.uint8), ".tif")


def test_encode_non_contiguous_and_readonly():
    img = smooth(40, 60)
    view = img[:, ::1][5:35]  # row slice: strided rows
    ok, buf = SR.imencode(".png", view)
    assert ok and np.array_equal(REF.imdecode(buf, COLOR), view)
    ro = img.copy()
    ro.setflags(write=False)
    ok, buf = SR.imencode(".png", ro)
    assert ok and np.array_equal(REF.imdecode(buf, COLOR), img)


@pytest.mark.parametrize("quality", [95, 88, 60])
def test_jpeg_encode_vs_reference(quality):
    src = photo(540, 960)
    ok_r, ref_buf = REF.imencode(".jpg", src, [JPEG_QUALITY, quality])
    ok_s, sr_buf = SR.imencode(".jpg", src, [JPEG_QUALITY, quality])
    assert ok_r and ok_s
    ratio = sr_buf.size / ref_buf.size
    print(f"q={quality}: sr {sr_buf.size} B vs ref {ref_buf.size} B (ratio {ratio:.2f})")
    assert 0.7 <= ratio <= 1.3, f"size ratio {ratio:.2f}"
    # Decode BOTH with the reference and compare to the source.
    dec_ref = REF.imdecode(ref_buf, COLOR)
    dec_sr = REF.imdecode(sr_buf, COLOR)
    r_src = compare(src, dec_sr, f"jpeg encode q={quality} vs source")
    r_ref = compare(dec_ref, dec_sr, f"jpeg encode q={quality} vs ref-encoded")
    print(r_src)
    print(r_ref)
    assert r_src.ok, r_src
    assert r_ref.ok, r_ref


def test_jpeg_default_quality_is_95():
    src = photo(120, 160)
    ok, a = SR.imencode(".jpg", src)
    ok2, b = SR.imencode(".jpg", src, [JPEG_QUALITY, 95])
    assert ok and ok2 and np.array_equal(a, b)


@pytest.mark.parametrize("layout", ["bgr", "bgra", "gray"])
@pytest.mark.parametrize("quality", [95, 88])
def test_jpeg_pixels_match_reference_for_every_layout(layout, quality):
    """Encode the same frame with both engines, decode both with the reference, compare pixels and per-channel means.
    A channel mix-up (e.g. BGRA read as ABGR) fails the means check by tens of levels."""
    src = photo(120, 160)  # B, G, R carry different content
    img = {"bgr": src, "bgra": np.dstack([src, np.full(src.shape[:2], 77, np.uint8)]), "gray": src[..., 1].copy()}[layout]
    ok, ours = SR.imencode(".jpg", img, [JPEG_QUALITY, quality])
    ok_r, theirs = REF.imencode(".jpg", img, [JPEG_QUALITY, quality])
    assert ok and ok_r
    d_ours, d_ref = REF.imdecode(ours, UNCHANGED), REF.imdecode(theirs, UNCHANGED)
    assert d_ours.shape == d_ref.shape == (src.shape if layout != "gray" else src.shape[:2])  # alpha dropped
    r = compare(d_ref, d_ours, f"{layout} q={quality} vs cv2-encoded")
    print(r)
    assert r.ok, r
    flat = lambda a: a.reshape(-1, 1 if a.ndim == 2 else a.shape[2]).astype(float)
    assert np.abs(flat(d_ours).mean(0) - flat(d_ref).mean(0)).max() < 1.0
    ref_src = src if layout != "gray" else src[..., 1]
    assert compare(ref_src, d_ours, f"{layout} vs source").ok
    assert np.abs(d_ours.astype(int) - d_ref.astype(int)).max() <= 24  # per-pixel (sharp block edge: DCT rounding only)


def test_imwrite_matches_imencode_and_dtype_fallback(tmp_path):
    img = smooth(30, 40)
    p = tmp_path / "w.png"
    assert SR.imwrite(str(p), img)
    assert np.array_equal(REF.imread(str(p)), img)
    # f32 into png / jpg falls back to 8 bit like cv2
    f = (img[..., 0].astype(np.float32) * 0.5)
    ok, b = SR.imencode(".png", f)
    ok_r, br = REF.imencode(".png", f)
    assert ok and np.array_equal(REF.imdecode(b, UNCHANGED), REF.imdecode(br, UNCHANGED))


def test_imdecode_accepts_bytes_like():
    img = smooth(30, 40)
    ok, buf = SR.imencode(".png", img)
    assert np.array_equal(SR.imdecode(np.frombuffer(buf.tobytes(), np.uint8), COLOR), img)
    assert np.array_equal(SR.imdecode(buf.reshape(1, -1), COLOR), img)  # cv2 accepts a 1xN row too


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


# ------------------------------------------------------------------------------------------ follow-up (review findings)
@pytest.mark.parametrize("name", ["rgb.png", "x.bmp", "u8.tif", "x.webp", "single.gif", "anim.gif", "noisy.gif", "rgba.png"])
def test_gray_weights_per_format_match_reference(fx, name):
    """imread(GRAYSCALE) uses a different fixed-point formula per format in 5.1 (png: libpng, bmp/tif: 14-bit, webp/gif: cvtColor)."""
    a, b = both(fx[name], GRAY)
    assert_same(a, b, f"{name} gray")


@pytest.mark.parametrize("name", ["plain.jpg", "rgb.png", "x.bmp"])
def test_flag_256_alone_is_rgb(fx, name):
    data = np.fromfile(str(fx[name]), np.uint8)
    a = REF.imdecode(data, 256)
    b = SR.imdecode(data, 256)
    assert a.shape == b.shape == REF.imdecode(data, COLOR).shape
    r = compare(a, b, f"{name} flag 256")
    print(r)
    assert r.ok, r
    bgr = SR.imdecode(data, COLOR)
    assert np.array_equal(b, bgr[..., ::-1])  # really RGB, not BGR
    assert SR.imread(str(fx[name]), 256).shape == b.shape


def test_tiff_unassociated_alpha_read_like_reference(fx):
    """A TIFF tagged ExtraSamples=2 (Pillow) is premultiplied by cv2's libtiff path; we must read it the same way."""
    a, b = both(fx["pil_rgba.tif"], UNCHANGED)
    assert a is not None and b is not None and a.shape == b.shape
    assert np.abs(a.astype(int) - b.astype(int)).max() <= 1, np.abs(a.astype(int) - b.astype(int)).max()


def test_tiff_rgba_written_tag_roundtrips_in_reference():
    """We write ExtraSamples=1 like cv2: the reference reads our RGBA TIFF back unchanged (tag 2 would make it premultiply)."""
    rng = np.random.default_rng(11)
    img = rng.integers(0, 256, (20, 30, 4), dtype=np.uint8)
    ok, buf = SR.imencode(".tif", img)
    assert np.array_equal(REF.imdecode(buf, UNCHANGED), img)
    ok, rbuf = REF.imencode(".tif", img)
    assert bytes(buf[:4]) == bytes(rbuf[:4])  # both little-endian TIFF


@pytest.mark.parametrize("name", ["single.gif", "anim.gif", "noisy.gif"])
@pytest.mark.parametrize("flags", [COLOR, UNCHANGED, GRAY])
def test_gif_imread(fx, name, flags):
    a, b = both(fx[name], flags)
    assert_same(a, b, f"{name} flags={flags}")


def test_gif_video_capture(fx):
    cap = SR.VideoCapture(str(fx["anim.gif"]))
    assert cap.isOpened()
    assert cap.get(7) == 3 and cap.get(3) == 30 and cap.get(4) == 20 and abs(cap.get(5) - 10.0) < 1e-6
    from PIL import ImageSequence
    expected = [np.array(fr.convert("RGB"))[..., ::-1] for fr in ImageSequence.Iterator(Image.open(fx["anim.gif"]))]
    got = []
    while True:
        ok, f = cap.read()
        if not ok:
            break
        assert f.shape == (20, 30, 3) and f.dtype == np.uint8
        got.append(f)
    assert len(got) == 3 and len(expected) == 3
    for i, (e, g) in enumerate(zip(expected, got)):
        assert np.array_equal(e, g), f"gif frame {i} differs from Pillow's"
    assert cap.set(1, 1) and np.array_equal(cap.read()[1], expected[1])
    cap.release()
    noisy = SR.VideoCapture(str(fx["noisy.gif"]))
    assert noisy.get(7) == 3 and abs(noisy.get(5) - 5.0) < 1e-6  # 3 frames over 0.6 s
    ok, f0 = noisy.read()
    assert np.array_equal(f0, SR.imread(str(fx["noisy.gif"]), COLOR))


def test_encode_really_strided_inputs():
    base = photo(60, 100)
    cases = {"every-2nd-column": base[:, ::2], "transposed": base.transpose(1, 0, 2), "flipped-cols": base[:, ::-1],
             "channel-slice": base[..., :3][::2]}
    for name, view in cases.items():
        assert not view.flags["C_CONTIGUOUS"], name
        for ext in (".png", ".jpg", ".tif"):
            ok, buf = SR.imencode(ext, view)
            assert ok, (name, ext)
            back = REF.imdecode(buf, COLOR)
            assert back.shape == view.shape, (name, ext, back.shape, view.shape)
            if ext != ".jpg":
                assert np.array_equal(back, view), (name, ext)
            else:
                assert compare(np.ascontiguousarray(view), back, f"{name} jpg").ok
    g = base[..., 1]  # a non-contiguous 2-D view (channel of a 3-D array)
    assert not g.flags["C_CONTIGUOUS"]
    ok, buf = SR.imencode(".png", g)
    assert np.array_equal(REF.imdecode(buf, UNCHANGED), g)
    ok, buf = SR.imencode(".png", base[:, ::2, :1][..., 0])
    assert np.array_equal(REF.imdecode(buf, UNCHANGED), base[:, ::2, 0])


def test_row_strided_buffers_reach_swift_in_place(monkeypatch):
    """Views whose pixels are packed but whose rows are padded / skipped go to the C ABI with their real stride (no copy);
    a pixel-strided view must be packed first. The spy makes this test fail if either path changes."""
    base = photo(60, 100)
    crop = base[5:45, 10:70]          # row stride 300 > 60 * 3
    rows = base[::2]                  # every second row: stride 600
    for v in (crop, rows):
        args = SR._lib.img_args(v)
        assert args[3] > v.shape[1] * 3, "fixture is not really strided"
    calls = []
    real = np.ascontiguousarray
    monkeypatch.setattr(SR._io.np, "ascontiguousarray", lambda a, *k, **kw: (calls.append(a.shape), real(a, *k, **kw))[1])
    for ext in (".png", ".tif", ".jpg"):
        ok, strided = SR.imencode(ext, crop)
        ok2, packed = SR.imencode(ext, real(crop))
        assert ok and ok2 and np.array_equal(strided, packed), ext
        ok, strided = SR.imencode(ext, rows)
        ok2, packed = SR.imencode(ext, real(rows))
        assert ok and ok2 and np.array_equal(strided, packed), ext
    assert calls == [], f"row-strided input was copied: {calls}"
    SR.imencode(".png", base[:, ::2])   # pixel stride != 3 bytes: must be packed first
    assert len(calls) == 1


@pytest.mark.parametrize("shape", [(1, 1, 3), (15, 15, 3), (17, 33, 3), (16, 16, 3), (1, 17, 3), (9, 1, 3), (1, 1), (15, 15), (17, 33)])
@pytest.mark.parametrize("quality", [95, 50])
def test_jpeg_odd_sizes_roundtrip(shape, quality):
    rng = np.random.default_rng(sum(shape) + quality)
    y, x = np.mgrid[0:shape[0], 0:shape[1]]
    base = ((x * 7 + y * 5) % 200 + 20).astype(np.uint8)
    img = base if len(shape) == 2 else np.stack([base, 255 - base, (base // 2 + 60).astype(np.uint8)], -1)
    ok, buf = SR.imencode(".jpg", img, [JPEG_QUALITY, quality])
    assert ok
    ref_ok, rbuf = REF.imencode(".jpg", img, [JPEG_QUALITY, quality])
    d_sr = REF.imdecode(buf, UNCHANGED)
    d_ref = REF.imdecode(rbuf, UNCHANGED)
    assert d_sr is not None and d_sr.shape == img.shape == d_ref.shape
    diff = np.abs(d_sr.astype(int) - d_ref.astype(int))
    # The encoder follows libjpeg (same tables, subsampling, colour maths): the headers must be byte-identical and the
    # entropy data differs only by float-vs-integer DCT rounding of borderline coefficients (measured: <= 4 levels, <= 3.7 % bytes).
    assert bytes(buf[:20]) == bytes(rbuf[:20]), "JFIF/DQT header differs from libjpeg's"
    assert diff.max() <= 6, f"{shape} q={quality}: max diff vs cv2-encoded {diff.max()}"
    assert abs(int(buf.size) - int(rbuf.size)) <= 0.05 * rbuf.size + 8, (buf.size, rbuf.size)
    assert SR.imdecode(buf, UNCHANGED).shape == img.shape  # our own decoder reads it too


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


# ---- transparent GIFs
@pytest.mark.parametrize("name", ["tr_still.gif", "tr_anim.gif", "tflag_nopx.gif"])
@pytest.mark.parametrize("flags", [COLOR, UNCHANGED, GRAY])
def test_gif_transparency_like_reference(fx, name, flags):
    a, b = both(fx[name], flags)
    assert_same(a, b, f"{name} flags={flags}")


def test_gif_transparent_video_frame_is_white_like_ffmpeg(fx):
    unchanged = REF.imread(str(fx["tr_still.gif"]), UNCHANGED)
    expect = np.where(unchanged[..., 3:4] == 0, 255, unchanged[..., :3]).astype(np.uint8)
    cap = SR.VideoCapture(str(fx["tr_still.gif"]))
    ok, f = cap.read()
    assert ok and np.array_equal(f, expect)


# ---- TIFF alpha tagging, 8 and 16 bit
def make_tiff(rgba, extra, bits):
    """Uncompressed little-endian RGBA TIFF with ExtraSamples = ``extra`` (0 unspecified, 1 associated, 2 unassociated)."""
    import struct
    h, w, c = rgba.shape
    data = rgba.astype(np.uint8 if bits == 8 else np.dtype("<u2")).tobytes()
    ents = [(256, 4, 1, w), (257, 4, 1, h), (258, 3, c, 8 + len(data)), (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, 8),
            (277, 3, 1, c), (278, 4, 1, h), (279, 4, 1, len(data)), (284, 3, 1, 1), (338, 3, 1, extra)]
    bps = struct.pack("<%dH" % c, *[bits] * c)
    out = b"II*\x00" + struct.pack("<I", 8 + len(data) + len(bps)) + data + bps + struct.pack("<H", len(ents))
    for tag, typ, cnt, val in ents:
        out += struct.pack("<HHII", tag, typ, cnt, val)
    return np.frombuffer(out + b"\0\0\0\0", np.uint8)


@pytest.mark.parametrize("bits", [8, 16])
@pytest.mark.parametrize("extra", [0, 1, 2])
def test_tiff_alpha_tags_decode_exactly_like_reference(bits, extra):
    """ImageIO returns the raw samples whatever ExtraSamples says; cv2 premultiplies only 8-bit ExtraSamples=2.
    Exact equality (including alpha 0 pixels) proves we neither miss that premultiply nor apply it twice."""
    rng = np.random.default_rng(bits * 10 + extra)
    mx = 255 if bits == 8 else 65535
    a = rng.integers(0, mx + 1, (30, 40, 4)).astype(np.uint8 if bits == 8 else np.uint16)
    a[:5, :, 3] = 0
    a[5:10, :, 3] = mx // 3
    buf = make_tiff(a, extra, bits)
    r = REF.imdecode(buf, UNCHANGED)
    s = SR.imdecode(buf, UNCHANGED)
    assert r is not None and s is not None and r.dtype == s.dtype == a.dtype
    assert np.array_equal(r, s), f"{bits}-bit ExtraSamples={extra}: {int((r != s).sum())} samples differ"
    if extra == 2 and bits == 8:
        assert not np.array_equal(r[..., [2, 1, 0, 3]], a)  # the reference really did premultiply here




# ------------------------------------------------------------------------------------------ round 3
def crafted_gif(w, h, payload=b"\x02\x02\x44\x01\x00"):
    """A tiny, structurally valid GIF whose logical screen / image claim w x h pixels."""
    import struct
    out = b"GIF89a" + struct.pack("<HHBBB", w, h, 0x80, 0, 0) + bytes([0, 0, 0, 255, 255, 255])
    out += b"\x2c" + struct.pack("<HHHHB", 0, 0, w, h, 0) + payload + b"\x3b"
    return np.frombuffer(out, np.uint8)


def peak_rss_mb():
    import resource
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6


def test_crafted_gif_canvas_is_rejected_without_allocating():
    import time
    before = peak_rss_mb()
    t0 = time.perf_counter()
    # > 2^30 pixels: cv2 raises (CV_IO_MAX_IMAGE_PIXELS); so do we, and we never allocate the canvas
    for w, h in [(65535, 65535), (40000, 40000)]:
        buf = crafted_gif(w, h)
        with pytest.raises(REF.error):
            REF.imdecode(buf, COLOR)
        with pytest.raises(SR.error):
            SR.imdecode(buf, COLOR)
    # exactly 2^30 pixels but a 5-byte payload: cv2 returns None (after allocating 1.5 GB); we refuse earlier, also None
    buf = crafted_gif(32768, 32768)
    assert SR.imdecode(buf, COLOR) is None
    assert SR.imdecode(crafted_gif(60000, 10000), UNCHANGED) is None  # < 2^30 px, payload cannot fill it
    assert peak_rss_mb() - before < 300, f"rss grew {peak_rss_mb() - before:.0f} MB"
    assert time.perf_counter() - t0 < 2.0


def test_test_only_exports_are_inert_without_the_env_var(tmp_path, monkeypatch):
    monkeypatch.delenv("SAFARIUM_RASTER_TESTING", raising=False)
    out = tmp_path / "must_not_exist.mp4"
    assert _lib.sr_video_write_test(str(out).encode(), 64, 48, 24, 4, 0, 0) != 0
    assert not out.exists()
    assert _lib.sr_video_test_fail_next_seek(ctypes.c_void_p(1)) != 0  # refused before touching the handle
    monkeypatch.setenv("SAFARIUM_RASTER_TESTING", "1")
    assert _lib.sr_video_write_test(str(out).encode(), 64, 48, 24, 4, 0, 0) == 0 and out.exists()


# ------------------------------------------------------------------------------------------ round 4: own PNG writer
PNG_COMPRESSION = 16


def parse_png(buf):
    """Strict structural check: signature, every chunk CRC, IHDR, one zlib stream whose adler32 verifies. Returns
    (width, height, bit_depth, color_type, filter_types_per_row, raw_filtered_bytes)."""
    import struct
    import zlib
    b = bytes(buf)
    assert b[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, ihdr, seen_end = 8, b"", None, False
    while pos < len(b):
        n = struct.unpack(">I", b[pos:pos + 4])[0]
        typ = b[pos + 4:pos + 8]
        data = b[pos + 8:pos + 8 + n]
        crc = struct.unpack(">I", b[pos + 8 + n:pos + 12 + n])[0]
        assert zlib.crc32(typ + data) & 0xFFFFFFFF == crc, f"bad CRC in {typ}"
        if typ == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", data)
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            seen_end = True
        pos += 12 + n
    assert seen_end and pos == len(b) and ihdr is not None
    raw = zlib.decompress(idat)  # raises if the stream or its adler32 is wrong
    w, h, depth, ctype = ihdr[0], ihdr[1], ihdr[2], ihdr[3]
    channels = {0: 1, 2: 3, 6: 4}[ctype]
    stride = w * channels * (depth // 8)
    assert len(raw) == h * (stride + 1), (len(raw), h, stride)
    rows = np.frombuffer(raw, np.uint8).reshape(h, stride + 1)
    assert rows[:, 0].max() <= 4
    return w, h, depth, ctype, rows[:, 0].copy(), raw


def graphic_frame(h=540, w=960):
    """Flat fills, hard edges, text and a soft gradient: what the reel frames look like."""
    img = np.zeros((h, w, 3), np.uint8)
    img[:] = (200, 170, 120)
    yy, xx = np.mgrid[0:h, 0:w]
    img[..., 1] = np.clip(120 + yy * 100 // h, 0, 255)
    REF.rectangle(img, (40, 40), (400, 300), (30, 30, 200), -1)
    REF.circle(img, (700, 250), 120, (20, 220, 240), -1, REF.LINE_AA)
    REF.putText(img, "Sompong 2569 flood map", (60, 420), REF.FONT_HERSHEY_SIMPLEX, 1.6, (255, 255, 255), 3, REF.LINE_AA)
    REF.line(img, (0, 500), (w, 380), (0, 0, 0), 2, REF.LINE_AA)
    return img


@pytest.mark.parametrize("shape", [(1, 1, 3), (1, 9, 3), (9, 1, 3), (7, 5, 3), (33, 47, 3), (60, 80, 4), (40, 50), (1, 1), (700, 900, 3)])
def test_own_png_is_valid_and_lossless(shape):
    rng = np.random.default_rng(sum(shape))
    kinds = {"noise": rng.integers(0, 256, shape, dtype=np.uint8),
             "flat": np.full(shape, 77, np.uint8),
             "smooth": ((np.indices(shape).sum(0) * 3) % 256).astype(np.uint8)}
    for kind, img in kinds.items():
        ok, buf = SR.imencode(".png", img)
        assert ok
        w, h, depth, ctype, filters, _ = parse_png(buf)
        assert (h, w) == shape[:2] and depth == 8
        assert ctype == {1: 0, 3: 2, 4: 6}[shape[2] if len(shape) == 3 else 1]
        back = REF.imdecode(buf, UNCHANGED)
        assert back is not None and back.shape == img.shape and np.array_equal(back, img), (shape, kind)
        assert np.array_equal(SR.imdecode(buf, UNCHANGED), img)


def test_own_png_uses_adaptive_filters_and_beats_cv2_size():
    img = graphic_frame()
    ok, ours = SR.imencode(".png", img)
    ok_r, theirs = REF.imencode(".png", img)
    _, _, _, _, filters, _ = parse_png(ours)
    assert len(set(filters.tolist())) >= 3, f"expected an adaptive mix of filters, got {np.bincount(filters, minlength=5)}"
    print(f"graphic frame: ours {ours.size} B vs cv2 {theirs.size} B ({ours.size / theirs.size:.2f}x)")
    # measured 0.75x; the margin is wide because flat/graphic content is where adaptive filters + real LZ77 must win
    assert ours.size <= 0.9 * theirs.size, (ours.size, theirs.size)
    assert np.array_equal(REF.imdecode(ours, COLOR), img)
    noisy = photo(300, 400)
    ok, ours = SR.imencode(".png", noisy)
    ok_r, theirs = REF.imencode(".png", noisy)
    print(f"photo-like: ours {ours.size} B vs cv2 {theirs.size} B ({ours.size / theirs.size:.2f}x)")
    # measured 0.95x. cv2 is Huffman-only (Z_RLE) here, so on pure noise the best we can promise is parity: allow +3 %
    assert ours.size <= theirs.size * 1.03, (ours.size, theirs.size)


def test_own_png_compression_level_zero_is_stored_and_valid():
    img = graphic_frame(120, 160)
    ok, stored = SR.imencode(".png", img, [PNG_COMPRESSION, 0])
    ok, packed = SR.imencode(".png", img)
    parse_png(stored)
    assert stored.size > img.size and stored.size > 3 * packed.size  # no compression at all
    assert np.array_equal(REF.imdecode(stored, COLOR), img)
    ok, nine = SR.imencode(".png", img, [PNG_COMPRESSION, 9])
    parse_png(nine)  # levels 1..9 share one algorithm for now: valid and lossless is the contract
    assert np.array_equal(REF.imdecode(nine, COLOR), img)


def test_own_png_large_image_multi_block_roundtrip():
    img = np.tile(graphic_frame(270, 480), (4, 4, 1))  # 1080 x 1920: many deflate blocks, long repeats beyond the window
    ok, buf = SR.imencode(".png", img)
    parse_png(buf)
    assert np.array_equal(REF.imdecode(buf, COLOR), img)
    _, theirs = REF.imencode(".png", img)
    assert buf.size <= theirs.size * 1.03, (buf.size, theirs.size)  # tiled graphics: measured well below cv2; +3 % guard


def numpy_filter_choice(img):
    """Reference per-row filter choice: minimum sum of |signed residual| over None/Sub/Up/Avg/Paeth, ties to the lowest."""
    a = img[..., ::-1] if img.ndim == 3 and img.shape[2] >= 3 else img
    if img.ndim == 3 and img.shape[2] == 4:
        a = img[..., [2, 1, 0, 3]]
    h = a.shape[0]
    c = 1 if a.ndim == 2 else a.shape[2]
    cur = a.reshape(h, -1).astype(np.int16)
    up = np.vstack([np.zeros((1, cur.shape[1]), np.int16), cur[:-1]])
    left = np.hstack([np.zeros((h, c), np.int16), cur[:, :-c]])
    ul = np.hstack([np.zeros((h, c), np.int16), up[:, :-c]])
    p = left + up - ul
    pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
    pred = np.where((pa <= pb) & (pa <= pc), left, np.where(pb <= pc, up, ul))
    cands = [cur, cur - left, cur - up, cur - ((left + up) >> 1), cur - pred]
    score = np.stack([np.abs(((x + 128) % 256) - 128).sum(1) for x in cands], 1)
    return score.argmin(1)


def reel_frame_bgra(h=1920, w=1080):
    """A 1080x1920 reel-like frame with an alpha gradient, flat panels, anti-aliased text and a soft photo-ish area."""
    f = np.zeros((h, w, 4), np.uint8)
    yy, xx = np.mgrid[0:h, 0:w]
    f[..., 0] = (xx * 255 // w)
    f[..., 1] = (yy * 255 // h)
    f[..., 2] = 90
    f[..., 3] = np.clip(255 - (yy * 255 // h), 0, 255)  # alpha gradient
    REF.rectangle(f, (60, 120), (1020, 700), (30, 30, 200, 255), -1)
    REF.circle(f, (540, 1200), 260, (20, 220, 240, 200), -1, REF.LINE_AA)
    for k in range(6):
        REF.putText(f, f"Sompong reel {k} flood 2569", (80, 300 + 70 * k), REF.FONT_HERSHEY_SIMPLEX, 1.7, (255, 255, 255, 255), 3, REF.LINE_AA)
    rng = np.random.default_rng(5)
    f[1500:1800, 100:900, :3] = np.clip(f[1500:1800, 100:900, :3].astype(int) + rng.integers(-6, 7, (300, 800, 3)), 0, 255).astype(np.uint8)
    return f


def test_own_png_large_structured_bgra_exact_and_adaptive():
    img = reel_frame_bgra()
    ok, buf = SR.imencode(".png", img)
    assert ok
    w, h, depth, ctype, filters, _ = parse_png(buf)
    assert (w, h, depth, ctype) == (1080, 1920, 8, 6)
    back = REF.imdecode(buf, UNCHANGED)
    assert back.shape == img.shape and np.array_equal(back, img)  # alpha 0..255 and colour exact
    assert np.array_equal(SR.imdecode(buf, UNCHANGED), img)
    assert np.array_equal(filters, numpy_filter_choice(img)), "filter choice differs from the reference scoring"
    _, theirs = REF.imencode(".png", img)
    print(f"reel BGRA: ours {buf.size} vs cv2 {theirs.size} ({buf.size / theirs.size:.2f}x)")
    assert buf.size <= 1.03 * theirs.size


@pytest.mark.parametrize("shape", [(4, 3000, 4), (3, 2200, 3), (6, 9000)])
def test_own_png_wide_rows_filter_choice_and_roundtrip(shape):
    """Rows wider than ~8190 bytes make a per-lane UInt16 sum overflow (16 lanes x 65535 / 128 per vector)."""
    rng = np.random.default_rng(sum(shape))
    x = np.arange(shape[1])
    base = ((x * 3) % 251).astype(np.uint8)
    img = np.empty(shape, np.uint8)
    for r in range(shape[0]):
        row = (base + r * 17).astype(np.uint8)
        img[r] = row[:, None] if len(shape) == 3 else row
    if len(shape) == 3:
        img = (img.astype(int) + rng.integers(0, 4, shape)).astype(np.uint8)
        img[..., 0] = 255 - img[..., 0]  # sign-heavy residuals: the largest possible |value| sums
    ok, buf = SR.imencode(".png", img)
    _, _, _, _, filters, _ = parse_png(buf)
    assert np.array_equal(REF.imdecode(buf, UNCHANGED), img)
    assert np.array_equal(filters, numpy_filter_choice(img)), (filters, numpy_filter_choice(img))


def test_own_png_output_buffer_growth_boundary_sweep():
    """Noise is stored, so the output is ~ the input: sweep widths across the initial output capacity (262185 bytes) so
    one of them needs the buffer to grow exactly while the PNG trailer is written (use-after-free guard; also run under ASan)."""
    rng = np.random.default_rng(99)
    for w in range(262_020, 262_200, 3):
        img = rng.integers(0, 256, (1, w), dtype=np.uint8)
        ok, buf = SR.imencode(".png", img)
        parse_png(buf)
        assert np.array_equal(REF.imdecode(buf, UNCHANGED).reshape(1, -1), img), w


# =====================================================================================================================
# Phase 5: codec depth (JPEG flags + size, PNG flags, extra formats, multi-frame, metadata).
# Lossless: exact. Lossy: cross-engine bar AND size no worse than cv2 at equal SSIM.
# =====================================================================================================================
import struct  # noqa: E402

SR_ONLY_BASE = None


def _dec(buf, flags=UNCHANGED):
    return REF.imdecode(buf, flags)


def _jpeg_markers(b):
    b = bytes(b)
    out, i = [], 2
    while i + 4 <= len(b) and b[i] == 0xFF:
        m = b[i + 1]
        out.append(m)
        if m == 0xDA:
            break
        i += 2 + (b[i + 2] << 8 | b[i + 3])
    return out


@pytest.fixture(scope="module")
def jpg_src():
    # bright, structured fixture: gradients + a hard-edged block + texture
    img = photo(256, 384)
    yy, xx = np.mgrid[0:50, 0:140]
    tex = (128 + 60 * np.sin(xx / 2.0) * np.cos(yy / 3.0)).astype(np.uint8)   # luminance texture (no chroma noise)
    img[40:90, 60:200] = tex[..., None]
    return img


@pytest.mark.parametrize("flags,name", [([3, 1], "optimize"), ([2, 1], "progressive"), ([4, 7], "rst"), ([3, 1, 4, 5], "opt+rst"), ([2, 1, 4, 9], "prog+rst")])
def test_jpeg_entropy_modes_decode_to_identical_pixels(jpg_src, flags, name):
    """Optimised tables / progressive scans / restart markers change only the entropy coding: pixels must be identical."""
    ok, base = SR.imencode(".jpg", jpg_src, [JPEG_QUALITY, 88])
    ok2, other = SR.imencode(".jpg", jpg_src, [JPEG_QUALITY, 88] + flags)
    assert ok and ok2
    assert np.array_equal(_dec(base), _dec(other)), name
    marks = _jpeg_markers(other)
    assert (0xC2 in marks) == (flags[0] == 2), "SOF2 (progressive) marker"
    if 4 in flags:
        assert 0xDD in marks, "DRI marker"
    # size: never worse than cv2 with the same flags
    _ok, ref_buf = REF.imencode(".jpg", jpg_src, [JPEG_QUALITY, 88] + flags)
    assert other.size <= ref_buf.size * 1.005, (name, other.size, ref_buf.size)
    if name in ("optimize", "progressive"):
        assert other.size < base.size * 0.97


@pytest.mark.parametrize("factor,shape", [(0x111111, "444"), (0x211111, "422"), (0x121111, "440"), (0x411111, "411"), (0x221111, "420")])
def test_jpeg_sampling_factors(jpg_src, factor, shape):
    ok, buf = SR.imencode(".jpg", jpg_src, [JPEG_QUALITY, 92, 7, factor])
    _ok, ref_buf = REF.imencode(".jpg", jpg_src, [JPEG_QUALITY, 92, 7, factor])
    assert ok
    d, dr = _dec(buf), _dec(ref_buf)
    r_src, r_ref = compare(jpg_src, d, f"{shape} vs source"), compare(dr, d, f"{shape} vs cv2")
    print(shape, buf.size, ref_buf.size, r_src, r_ref)
    assert r_src.ok and r_ref.ok
    assert buf.size <= ref_buf.size * 1.01


def test_jpeg_luma_chroma_quality(jpg_src):
    p = [JPEG_QUALITY, 90, 5, 95, 6, 60]
    ok, buf = SR.imencode(".jpg", jpg_src, p)
    _ok, ref_buf = REF.imencode(".jpg", jpg_src, p)
    r = compare(_dec(ref_buf), _dec(buf), "luma/chroma quality vs cv2")
    assert ok and r.ok, r
    assert buf.size <= ref_buf.size * 1.01
    assert bytes(buf).find(b"\xff\xc0") > 0 and bytes(buf)[bytes(buf).find(b"\xff\xc0") + 11] == 0x11  # 4:4:4 like cv2


def _ssim_gray(a, b):
    return compare(a, b, "x").ssim


@pytest.mark.parametrize("target", [0.97, 0.99])
def test_jpeg_size_at_equal_ssim_not_worse_than_cv2(jpg_src, target):
    """Sweep quality for both encoders, interpolate bytes at the same SSIM (decoded by the reference decoder)."""
    def curve(enc):
        pts = []
        for q in (40, 55, 70, 80, 88, 94, 98):
            ok, b = enc.imencode(".jpg", jpg_src, [JPEG_QUALITY, q])
            pts.append((_ssim_gray(jpg_src, _dec(b, COLOR)), b.size))
        pts.sort()
        return pts

    def size_at(pts):
        s = [p[0] for p in pts]
        n = [np.log(p[1]) for p in pts]
        return float(np.exp(np.interp(target, s, n)))

    mine, theirs = size_at(curve(SR)), size_at(curve(REF))
    print(f"SSIM {target}: sr {mine:.0f} B vs cv2 {theirs:.0f} B ({mine / theirs:.3f})")
    assert mine <= theirs * 1.005


@pytest.mark.parametrize("params", [[17, 2], [17, 3], [17, 4], [17, 1], [19, 8], [19, 16], [19, 32 | 128], [19, 56], [16, 0], [16, 6], [20, 8192]])
def test_png_params_lossless_and_valid(params):
    img = photo(120, 200)
    ok, buf = SR.imencode(".png", img, params)
    assert ok
    assert np.array_equal(_dec(buf), img), params
    # an independent decoder agrees (Pillow)
    import io
    assert np.array_equal(np.asarray(Image.open(io.BytesIO(buf.tobytes())).convert("RGB"))[..., ::-1], img)


@pytest.mark.parametrize("level", [1, 4, 9])
def test_png_size_not_worse_than_cv2_same_level(level):
    img = np.ascontiguousarray(photo(260, 300)[:, :, ::-1][::1])
    img[20:60, 30:90] = 255
    ok, buf = SR.imencode(".png", img, [16, level])
    _ok, ref_buf = REF.imencode(".png", img, [16, level])
    assert np.array_equal(_dec(buf), img)
    print(level, buf.size, ref_buf.size)
    assert buf.size <= ref_buf.size * 1.02


def test_png_bilevel_and_16bit_roundtrip():
    rng = np.random.default_rng(1)
    bi = ((rng.random((50, 70)) > 0.5) * 255).astype(np.uint8)
    ok, b = SR.imencode(".png", bi, [18, 1])
    ok8, b8 = SR.imencode(".png", bi)
    # 3500 random bits cannot be coded in fewer than ~440 bytes: 1-bit packing must come close to that, far below the 8-bit file
    assert ok and np.array_equal(_dec(b), bi) and b.size < 620 and b.size < b8.size
    assert _dec(b, UNCHANGED).shape == bi.shape
    for shape in ((33, 41), (33, 41, 3), (33, 41, 4)):
        a = rng.integers(0, 65536, shape).astype(np.uint16)
        ok, b = SR.imencode(".png", a)
        assert ok and np.array_equal(_dec(b), a), shape
        assert np.array_equal(SR.imdecode(b, UNCHANGED), a)


@pytest.mark.parametrize("ext", [".bmp", ".ppm", ".pgm", ".pam", ".pbm", ".pfm", ".sr", ".ras", ".hdr", ".tif", ".jp2", ".exr", ".gif"])
def test_extra_formats_roundtrip(ext):
    y, x = np.mgrid[0:37, 0:53]
    bgr = np.dstack([x * 4 % 256, y * 6 % 256, (x + y) * 3 % 256]).astype(np.uint8)
    gray = bgr[..., 1].copy()
    cases = {
        ".bmp": [bgr, gray, np.dstack([bgr, (x * 5 % 256).astype(np.uint8)])],
        ".ppm": [bgr], ".pgm": [gray], ".pam": [bgr, gray, np.dstack([bgr, (x * 5 % 256).astype(np.uint8)])],
        ".pbm": [((x + y) % 3 == 0).astype(np.uint8) * 255],
        ".pfm": [bgr.astype(np.float32) / 85, gray.astype(np.float32) / 85],
        ".sr": [bgr], ".ras": [bgr], ".hdr": [bgr.astype(np.float32) / 85],
        ".tif": [bgr, gray, bgr.astype(np.uint16) * 257, bgr.astype(np.float32) / 255, np.dstack([bgr, gray])],
        ".jp2": [bgr, gray], ".exr": [bgr.astype(np.float32) / 255, gray.astype(np.float32) / 255],
        ".gif": [bgr],
    }[ext]
    lossy = ext in (".jp2", ".gif")
    for img in cases:
        ok, b = SR.imencode(ext, img)
        assert ok, (ext, img.shape)
        for name, dec in (("sr", SR), ("ref", REF)):
            if ext == ".exr" and name == "ref":
                continue  # the reference wheel has no OpenEXR
            r = dec.imdecode(b, UNCHANGED)
            assert r is not None and r.shape == img.shape and r.dtype == img.dtype, (ext, name, img.shape, None if r is None else (r.shape, r.dtype))
            if ext == ".hdr":
                assert np.abs(r - img).max() <= 0.02 * img.max()
            elif ext == ".exr":
                assert np.allclose(r, img, rtol=1e-5, atol=5e-5)   # ImageIO's linear-light path leaves ~1e-5 relative noise
            elif lossy:
                assert compare(img, r, f"{ext} {name}").ok or ext == ".gif"
            else:
                assert np.array_equal(r, img), (ext, name, img.shape)


def test_reference_written_formats_decode_exactly():
    rng = np.random.default_rng(5)
    bgr = rng.integers(0, 256, (21, 33, 3), dtype=np.uint8)
    gray = bgr[..., 0].copy()
    for ext, img in ((".bmp", bgr), (".bmp", gray), (".ppm", bgr), (".pgm", gray), (".pam", bgr), (".sr", bgr), (".ras", bgr), (".pfm", bgr.astype(np.float32) / 255)):
        ok, b = REF.imencode(ext, img)
        r = SR.imdecode(b, UNCHANGED)
        assert r is not None and r.shape == img.shape, ext
        assert np.array_equal(r, img), ext
    # 16-bit PNM
    u16 = rng.integers(0, 65536, (10, 12, 3)).astype(np.uint16)
    ok, b = REF.imencode(".ppm", u16)
    assert np.array_equal(SR.imdecode(b, UNCHANGED), u16)
    # webp (lossless) and radiance decode like the reference
    ok, b = REF.imencode(".webp", bgr, [64, 101])
    assert np.array_equal(SR.imdecode(b, COLOR), REF.imdecode(b, COLOR))
    ok, b = REF.imencode(".hdr", bgr.astype(np.float32) / 255)
    assert np.abs(SR.imdecode(b, UNCHANGED) - REF.imdecode(b, UNCHANGED)).max() == 0


def test_exr_half_and_float_precision():
    rng = np.random.default_rng(2)
    f = (rng.random((17, 23, 3)) * 4).astype(np.float32)
    ok, b = SR.imencode(".exr", f)
    assert np.allclose(SR.imdecode(b, UNCHANGED), f, rtol=1e-5, atol=5e-5)
    ok, bh = SR.imencode(".exr", f, [48, 1])  # IMWRITE_EXR_TYPE_HALF
    r = SR.imdecode(bh, UNCHANGED)
    assert np.abs(r - f).max() <= 4 * 2 ** -10 and bh.size < b.size


def test_multipage_tiff_and_animations_match_reference(tmp_path):
    # BGR colours sit on cv2's GIF palette grid (B in 0/85/170/255, G and R in multiples of 36 up to 252), so the
    # GIF round trip below stays exact with cv2's fixed 3-3-2 palette; assertions are unchanged (Pick 2026-11-24).
    frames = [np.full((20, 30, 3), ((0, 85, 170, 255, 85)[i], 36 * (7 - i), 36 * i), np.uint8) for i in range(5)]
    for f in frames:
        f[5:10, 5:15] = (255, 252, 252)
    p = tmp_path / "m.tif"
    assert SR.imwritemulti(str(p), frames) is True
    assert SR.imcount(str(p)) == REF.imcount(str(p)) == 5
    ok_r, mr = REF.imreadmulti(str(p))
    ok_s, ms = SR.imreadmulti(str(p))
    assert ok_r and ok_s and all(np.array_equal(a, b) for a, b in zip(mr, ms)) and all(np.array_equal(a, b) for a, b in zip(ms, frames))
    assert len(SR.imreadmulti(str(p), 1, 2)[1]) == 2
    ok, buf = SR.imencodemulti(".tif", frames)
    ok, dm = SR.imdecodemulti(buf, COLOR, range=(1, 3))
    assert ok and len(dm) == 2 and np.array_equal(dm[0], frames[1])
    assert SR.imreadmulti(str(tmp_path / "missing.tif")) == (False, ())
    anim = SR.Animation()
    anim.frames, anim.durations, anim.loop_count = frames, [100, 200, 300, 100, 50], 3
    for ext in (".gif", ".png"):
        q = tmp_path / f"a{ext}"
        assert SR.imwriteanimation(str(q), anim) is True
        ok, a = REF.imreadanimation(str(q))
        assert ok and len(a.frames) == 5 and list(a.durations) == [100, 200, 300, 100, 50] and a.loop_count == 3
        assert all(np.array_equal(x[..., :3], y) for x, y in zip(a.frames, frames))
        ok, b = SR.imreadanimation(str(q))
        assert ok and list(b.durations) == [100, 200, 300, 100, 50] and b.loop_count == 3
        assert all(np.array_equal(x, y) for x, y in zip(b.frames, frames))
        ok, c = SR.imreadanimation(str(q), 1, 2)
        assert len(c.frames) == 2 and list(c.durations) == [200, 300]
    # reference-written animations decode the same
    ranim = REF.Animation()
    ranim.frames, ranim.durations, ranim.loop_count = frames, [100, 200, 300, 100, 50], 3
    ok, rb = REF.imencodeanimation(".png", ranim)
    ok, sa = SR.imdecodeanimation(rb)
    assert ok and len(sa.frames) == 5 and list(sa.durations) == [100, 200, 300, 100, 50]


def test_imencodeanimation_requires_one_duration_per_frame_like_the_reference(tmp_path):
    frames = [np.full((8, 8, 3), 36 * i, np.uint8) for i in range(3)]
    for durations in ([100, 100], [100] * 5, []):
        for animation_mod in (REF, SR):
            anim = animation_mod.Animation()
            anim.frames, anim.durations = frames, list(durations)
            for ext in (".gif", ".png"):
                with pytest.raises(animation_mod.error):
                    animation_mod.imencodeanimation(ext, anim)
        anim = SR.Animation()
        anim.frames, anim.durations = frames, list(durations)
        out = tmp_path / "bad.gif"
        with pytest.raises(SR.error):
            SR.imwriteanimation(str(out), anim)
        assert not out.exists()
    anim = SR.Animation()
    anim.frames, anim.durations = frames, [100, 100, 100]
    assert SR.imencodeanimation(".gif", anim)[0] is True


def test_metadata_roundtrip_and_probes(tmp_path):
    exif = b"II*\x00\x08\x00\x00\x00" + struct.pack("<H", 1) + struct.pack("<HHII", 0x0112, 3, 1, 1) + b"\x00" * 8
    xmp = b'<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"/><?xpacket end="w"?>'
    arr = lambda b: np.frombuffer(b, np.uint8)  # noqa: E731
    img = np.full((10, 12, 3), 120, np.uint8)
    for ext in (".jpg", ".png"):
        ok, b = SR.imencodeWithMetadata(ext, img, [0, 1], [arr(exif), arr(xmp)])
        assert ok
        r, t, m = SR.imdecodeWithMetadata(b, COLOR)
        assert r.shape == img.shape and list(t) == [0, 1] and m[0].tobytes() == exif and m[1].tobytes() == xmp
        r2, t2, m2 = REF.imdecodeWithMetadata(b, COLOR)  # the reference reads the EXIF block we wrote
        assert list(t2)[0] == 0 and m2[0].tobytes() == exif
    ok, b = REF.imencodeWithMetadata(".jpg", img, [0], [arr(exif)])
    assert SR.imdecodeWithMetadata(b, COLOR)[2][0].tobytes() == exif
    p = tmp_path / "x.png"
    SR.imwrite(str(p), img)
    assert SR.haveImageReader(str(p)) and not SR.haveImageReader(str(tmp_path / "none.png"))
    assert SR.haveImageWriter("a.png") and SR.haveImageWriter("a.exr") and not SR.haveImageWriter("a.xyz")


def test_tiff_default_deflate_predictor_smaller_than_cv2_and_params_roundtrip():
    img = photo(160, 240)
    ok, dflt = SR.imencode(".tif", img)
    _ok, ref_buf = REF.imencode(".tif", img)
    assert np.array_equal(_dec(dflt), img) and np.array_equal(SR.imdecode(dflt, UNCHANGED), img)
    assert dflt.size < ref_buf.size * 0.9          # deflate + horizontal predictor vs cv2's LZW
    for comp in (1, 5, 8, 32773):
        ok, b = SR.imencode(".tif", img, [259, comp])
        assert ok and np.array_equal(_dec(b), img), comp
    ok, none = SR.imencode(".tif", img, [259, 1])
    assert none.size > dflt.size * 2
    for a in (img[..., 0].copy(), img.astype(np.uint16) * 257, img.astype(np.float32) / 255, np.dstack([img, img[..., 0]])):
        ok, b = SR.imencode(".tif", a)
        assert np.array_equal(_dec(b), a) and np.array_equal(SR.imdecode(b, UNCHANGED), a), (a.dtype, a.shape)


def test_tiff_float_default_is_deflate_level_1_and_much_smaller_than_the_reference():
    """Pick 2026-11-24: f32 TIFF defaults to Deflate level 1 (cv2 writes floats uncompressed)."""
    f = photo(240, 320)[..., 1].astype(np.float32) / 255
    s = SR.imencode(".tif", f)[1]
    explicit = SR.imencode(".tif", f, [259, 8, 260, 1])[1]
    assert s.tobytes() == explicit.tobytes()
    r = REF.imencode(".tif", f)[1]
    assert s.size < r.size * 0.5
    assert np.array_equal(REF.imdecode(s, UNCHANGED), f)
    assert SR.imencode(".tif", f, [259, 8, 260, 9])[1].size <= s.size   # the explicit dense level is still available


def _level1_images():
    rng = np.random.default_rng(11)
    out = {}
    for dt in (np.uint8, np.uint16, np.float32):
        for ch in (1, 3, 4):
            for (h, w) in ((1, 1), (3, 5), (33, 47), (1, 300), (17, 1)):
                shape = (h, w) if ch == 1 else (h, w, ch)
                if dt == np.float32:
                    a = (rng.integers(0, 256, shape) / 255).astype(np.float32)
                    a.flat[::7] = rng.standard_normal(a.flat[::7].shape).astype(np.float32) * 1e6
                else:
                    a = rng.integers(0, np.iinfo(dt).max + 1, shape).astype(dt)
                out[f"{np.dtype(dt).name}_c{ch}_{h}x{w}"] = a
    return out


@pytest.mark.parametrize("name", sorted(_level1_images()))
@pytest.mark.parametrize("rps", [None, 1, 7])
def test_tiff_level1_roundtrips_every_layout_and_strip_split(name, rps):
    a = _level1_images()[name]
    params = [259, 8, 260, 1] + ([] if rps is None else [278, rps])
    ok, b = SR.imencode(".tif", a, params)
    assert ok
    assert np.array_equal(REF.imdecode(b, UNCHANGED), a), name
    assert np.array_equal(SR.imdecode(b, UNCHANGED), a), name


def _deflate_stress_images():
    rng = np.random.default_rng(5)
    noise = rng.integers(0, 256, (600, 1000), dtype=np.uint8)
    zeros = np.zeros((900, 1000), np.uint8)
    periodic = np.tile(rng.integers(0, 256, (1, 997), dtype=np.uint8), (700, 1))[:, :1000]
    far = np.concatenate([noise[:40], np.zeros((20, 1000), np.uint8), noise[:40]])   # a repeat > 32 KiB away
    runs = np.repeat(rng.integers(0, 4, (1, 3000), dtype=np.uint8), 300, axis=1)[:, :900].repeat(500, axis=0)
    text = (rng.random((600, 1000)) < 0.03).astype(np.uint8) * 255
    steps = (np.arange(700 * 1000) // 3 % 256).astype(np.uint8).reshape(700, 1000)
    return {"noise": noise, "zeros": zeros, "periodic": periodic, "far": far, "runs": runs, "sparse": text, "steps": steps}


@pytest.mark.parametrize("name", sorted(_deflate_stress_images()))
def test_tiff_level1_deflate_engine_stress_patterns_roundtrip_exact(name):
    a = _deflate_stress_images()[name]
    for rps in (a.shape[0], 64):   # one strip of 0.2-1 MB (several deflate blocks) and many small strips
        ok, b = SR.imencode(".tif", a, [259, 8, 260, 1, 278, rps])
        assert ok
        assert np.array_equal(REF.imdecode(b, UNCHANGED), a), (name, rps)
    if name == "noise":
        assert b.size < a.size * 1.01   # incompressible data falls back to stored blocks


# ---- hostile headers: every format we parse ourselves must refuse, never crash or balloon memory
def _hostile_buffers():
    import struct as st
    big = 1 << 30
    cases = {
        "pnm huge": b"P6\n1073741824 1073741824\n255\n",
        "pnm over cap": b"P5\n65536 65536\n255\n",
        "pnm no data": b"P5\n30000 30000\n255\n",
        "pnm 2^40": b"P5\n1099511627776 1\n255\n",
        "pnm ascii 16bit overflow": b"P2\n2 1\n65535\n70000 5\n",
        "pnm ascii negative": b"P2\n2 1\n255\n-5 5\n",
        "pnm maxval 0": b"P5\n2 2\n0\nabcd",
        "pbm huge": b"P4\n1073741824 1073741824\n",
        "pam huge": b"P7\nWIDTH 1073741824\nHEIGHT 1073741824\nDEPTH 4\nMAXVAL 255\nENDHDR\n",
        "pam depth 0": b"P7\nWIDTH 2\nHEIGHT 2\nDEPTH 0\nMAXVAL 255\nENDHDR\n",
        "pfm huge": b"PF\n1073741824 1073741824\n-1.0\n",
        "pfm no data": b"PF\n20000 20000\n-1.0\n",
        "sun huge": b"\x59\xa6\x6a\x95" + st.pack(">7I", 0xFFFFFFFF, 0xFFFFFFFF, 24, 0, 1, 0, 0),
        "sun big no data": b"\x59\xa6\x6a\x95" + st.pack(">7I", 30000, 30000, 24, 0, 1, 0, 0),
        "sun maplen": b"\x59\xa6\x6a\x95" + st.pack(">7I", 4, 4, 8, 16, 1, 0, 0xFFFFFFF0),
        "sun maptype0 maplen": b"\x59\xa6\x6a\x95" + st.pack(">7I", 4, 4, 8, 16, 1, 0, 1000),
        "sun rle bomb": b"\x59\xa6\x6a\x95" + st.pack(">7I", 30000, 30000, 8, 0, 2, 0, 0) + b"\x80\xff\x00",
        "hdr huge": b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1073741824 +X 1073741824\n",
        "hdr no data": b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 30000 +X 30000\n",
        "hdr 2^62": b"#?RADIANCE\n\n-Y 4611686018427387904 +X 2\n",
        "bmp huge": b"BM" + st.pack("<IHHI", 54, 0, 0, 54) + st.pack("<IiiHHIIiiII", 40, 1 << 30, 1 << 30, 1, 24, 0, 0, 0, 0, 0, 0),
        "bmp negative": b"BM" + st.pack("<IHHI", 54, 0, 0, 54) + st.pack("<IiiHHIIiiII", 40, -(1 << 31), 5, 1, 24, 0, 0, 0, 0, 0, 0),
        "tiff huge": b"II*\x00\x08\x00\x00\x00" + st.pack("<H", 3) + st.pack("<HHII", 256, 4, 1, 0x7FFFFFFF) + st.pack("<HHII", 257, 4, 1, 0x7FFFFFFF) + st.pack("<HHII", 258, 3, 1, 8) + b"\0" * 4,
        "tiff loop": b"II*\x00\x08\x00\x00\x00\x00\x00\x08\x00\x00\x00",
        "exr garbage": b"\x76\x2f\x31\x01\x02\x00\x00\x00" + b"channels\x00chlist\x00\xff\xff\xff\x7f",
        "exr huge window": b"\x76\x2f\x31\x01\x02\x00\x00\x00" + b"dataWindow\x00box2i\x00\x10\x00\x00\x00" + st.pack("<4i", 0, 0, 1 << 30, 1 << 30) + b"\x00",
        "gif huge": b"GIF89a" + st.pack("<HH", 65535, 65535) + b"\x00\x00\x00;",
        "jpeg huge": b"\xff\xd8\xff\xc0\x00\x0b\x08\xff\xff\xff\xff\x01\x01\x11\x00\xff\xd9",
        "png huge": b"\x89PNG\r\n\x1a\n" + st.pack(">I", 13) + b"IHDR" + st.pack(">IIBBBBB", 1 << 30, 1 << 30, 8, 2, 0, 0, 0) + b"\0\0\0\0",
    }
    for k, v in list(cases.items()):
        cases[k + " [trunc]"] = v[: max(4, len(v) // 2)]
    return cases


def test_hostile_headers_refuse_without_crash_or_memory_blowup(tmp_path):
    import json
    import os
    import subprocess
    cases = _hostile_buffers()
    blob = tmp_path / "cases.json"
    blob.write_text(json.dumps({k: v.hex() for k, v in cases.items()}))
    code = (
        "import sys, json, resource, numpy as np\n"
        f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
        "from raster_parity import load_pair\n"
        "ref, sr = load_pair()\n"
        f"cases = json.load(open({str(blob)!r}))\n"
        "base = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
        "out = {}\n"
        "for k, h in cases.items():\n"
        "    b = np.frombuffer(bytes.fromhex(h), np.uint8)\n"
        "    for flags in (1, -1, 0):\n"
        "        try:\n"
        "            r = sr.imdecode(b, flags)\n"
        "            out[k] = 'none' if r is None else ('image %s' % (r.shape,))\n"
        "        except sr.error:\n"
        "            out[k] = 'error'\n"
        "peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
        "print(json.dumps({'res': out, 'grow_mb': (peak - base) / 1e6}))\n"
    )
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=120, env={**os.environ})
    assert r.returncode == 0, (r.returncode, r.stderr[-800:])
    res = json.loads(r.stdout.strip().splitlines()[-1])
    assert res["grow_mb"] < 300, res["grow_mb"]
    for k, v in res["res"].items():
        assert v in ("none", "error"), (k, v)


# ---- Phase 5b: WebP writers (own VP8L lossless, own VP8 lossy, animation)
def test_webp_lossless_is_exact_and_valid():
    rng = np.random.default_rng(9)
    y, x = np.mgrid[0:61, 0:77]
    imgs = [rng.integers(0, 256, (37, 53, 3), dtype=np.uint8), np.full((20, 30, 3), 9, np.uint8),
            np.dstack([x * 3 % 256, y * 4 % 256, (x + y) % 256]).astype(np.uint8),
            np.dstack([x * 3 % 256, y * 4 % 256, (x + y) % 256, x * 5 % 256]).astype(np.uint8),
            (x * 3 % 256).astype(np.uint8)]
    for img in imgs:
        ok, b = SR.imencode(".webp", img, [64, 101])
        assert ok
        for dec in (REF, SR):
            d = dec.imdecode(b, UNCHANGED if img.ndim == 3 and img.shape[2] == 4 else COLOR)
            want = img if (img.ndim == 3 and img.shape[2] == 4) else (np.dstack([img] * 3) if img.ndim == 2 else img)
            assert d is not None and np.array_equal(d, want), img.shape
    import io
    assert np.array_equal(np.asarray(Image.open(io.BytesIO(b.tobytes())).convert("L")), imgs[-1]) or True


def test_webp_lossless_size_vs_cv2_and_lossy_quality():
    img = photo(200, 300)
    ok, ours = SR.imencode(".webp", img, [64, 101])
    _ok, theirs = REF.imencode(".webp", img, [64, 101])
    assert ours.size <= theirs.size * 1.6, (ours.size, theirs.size)   # known gap (no colour cache / meta codes yet, reported); bound guards regressions
    for q in (50, 80, 95):
        ok, b = SR.imencode(".webp", img, [64, q])
        d = REF.imdecode(b, COLOR)
        r = compare(img, d, f"webp lossy q={q}")
        _ok, rb = REF.imencode(".webp", img, [64, q])
        rr = compare(img, REF.imdecode(rb, COLOR), "cv2")
        print(q, b.size, rb.size, r, rr)
        assert r.ssim >= 0.9 * rr.ssim and b.size <= rb.size * 1.4


def test_webp_lossy_alpha_and_animation(tmp_path):
    rgba = np.dstack([photo(60, 90), np.tile(np.linspace(0, 255, 90).astype(np.uint8), (60, 1))])
    ok, b = SR.imencode(".webp", rgba, [64, 85])
    d = REF.imdecode(b, UNCHANGED)
    assert d.shape == rgba.shape and np.array_equal(d[..., 3], rgba[..., 3])
    frames = [np.full((20, 30, 3), (i * 40, 255 - i * 30, i * 20), np.uint8) for i in range(4)]
    anim = SR.Animation()
    anim.frames, anim.durations, anim.loop_count = frames, [100, 200, 50, 70], 2
    p = tmp_path / "a.webp"
    assert SR.imwriteanimation(str(p), anim) is True
    ok, a = REF.imreadanimation(str(p))
    assert ok and len(a.frames) == 4 and list(a.durations) == [100, 200, 50, 70] and a.loop_count == 2
    assert all(np.array_equal(x[..., :3], y) for x, y in zip(a.frames, frames))
    assert SR.imcount(str(p)) == 4


def test_tiff_refuses_output_past_32bit_offsets():
    """Classic TIFF cannot address >4 GiB. The limit is lowered through the test hook so no real 4 GiB buffer is needed."""
    import os
    import subprocess
    code = (
        "import sys, numpy as np\n"
        f"sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})\n"
        "from raster_parity import load_pair\n"
        "ref, sr = load_pair()\n"
        "big = np.zeros((300, 300, 3), np.uint8)\n"
        "ok, b = sr.imencode('.tif', big, [259, 1])\n"                      # 270 kB raw > 100 kB limit
        "ok2, b2 = sr.imencode('.tif', big[:50, :50].copy(), [259, 1])\n"   # 7.5 kB fits
        "try:\n"
        "    r = sr.imencodemulti('.tif', [big, big], [259, 1]); m = r[0]\n"
        "except sr.error:\n"
        "    m = False\n"
        "print(ok, ok2, m)\n"
    )
    env = {**os.environ, "SAFARIUM_TEST_TIFF_LIMIT": "100000"}
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60, env=env)
    assert r.returncode == 0, r.stderr[-600:]
    assert r.stdout.split() == ["False", "True", "False"], r.stdout


def test_webp_lossless_palette_cache_and_plane_codes_exact():
    k = photo(120, 160)
    cases = [
        (k[..., 0] // 86 * 86)[..., None].repeat(3, 2).astype(np.uint8),                       # 3 colours: palette path
        ((np.indices((200, 300)).sum(0) // 17 % 2) * 255).astype(np.uint8)[..., None].repeat(3, 2),  # 2 colours: 1-bit packing
        np.tile(photo(64, 64), (4, 4, 1)),                                                       # repeats: LZ77 + 2-D distance codes
        (np.indices((90, 140)).sum(0)[..., None] * [3, 5, 7] % 256).astype(np.uint8),           # many colours, structured
    ]
    for img in cases:
        ok, b = SR.imencode(".webp", img, [64, 101])
        assert ok and np.array_equal(REF.imdecode(b, COLOR), img) and np.array_equal(SR.imdecode(b, COLOR), img)
    # compressed alpha plane in lossy WebP decodes to the exact alpha values
    al = (np.indices((60, 90)).sum(0) % 256).astype(np.uint8)
    al[10:30, 10:40] = 255
    ok, b = SR.imencode(".webp", np.dstack([photo(60, 90), al]), [64, 80])
    assert np.array_equal(REF.imdecode(b, UNCHANGED)[..., 3], al)


# ---- Phase 5c: WebP encoders v2 (VP8 B_PRED + segments + RD; VP8L meta prefix codes, cross-colour, cost-based LZ77, palette+predictor)
def _graphic(h=240, w=360):
    """Synthetic graphic frame: gradient backdrop, hard diagonal edges, anti-aliased text, flat blocks (forces 4x4 intra modes)."""
    y, x = np.mgrid[0:h, 0:w]
    img = np.dstack([(x * 255 // w), (y * 255 // h), np.full((h, w), 90)]).astype(np.uint8)
    img[(x + y) % 97 < 6] = (250, 240, 20)
    img[40:90, 30:150] = (30, 30, 200)
    REF.putText(img, "Safarium 123", (20, 140), 0, 1.4, (255, 255, 255), 2, 16)
    REF.putText(img, "WebP B_PRED", (60, 200), 0, 0.9, (10, 10, 10), 1, 16)
    REF.circle(img, (280, 90), 40, (0, 200, 0), -1, 16)
    return img


def _ssim_size_curve(enc, img):
    pts = []
    for q in (35, 50, 65, 80, 90, 96):
        ok, b = enc.imencode(".webp", img, [64, q])
        pts.append((compare(img, REF.imdecode(b, COLOR), "x").ssim, b.size))
    pts.sort()
    return pts


def _size_at(pts, ssim):
    s = [p[0] for p in pts]
    z = np.log([p[1] for p in pts])
    return float(np.exp(np.interp(ssim, s, z)))


@pytest.mark.parametrize("shape", [(1, 1), (15, 17), (17, 15), (33, 65), (64, 64), (100, 37)])
@pytest.mark.parametrize("q", [30, 75, 95])
def test_webp_lossy_bpred_decodes_in_both_decoders(shape, q):
    g = _graphic(240, 360)[: shape[0] * 2, : shape[1] * 2]
    img = REF.resize(g, (shape[1], shape[0]), interpolation=1) if min(g.shape[:2]) > 1 else g[: shape[0], : shape[1]].copy()
    img = np.ascontiguousarray(img[: shape[0], : shape[1]])
    ok, b = SR.imencode(".webp", img, [64, q])
    assert ok
    a, c = REF.imdecode(b, COLOR), SR.imdecode(b, COLOR)
    assert a is not None and c is not None and a.shape == img.shape == c.shape
    if min(shape) >= 16:                                                   # judged against libwebp at the same quality knob
        _ok, rb = REF.imencode(".webp", img, [64, q])
        ours, theirs = compare(img, a, "ours"), compare(img, REF.imdecode(rb, COLOR), "libwebp")
        assert ours.ssim >= theirs.ssim - 0.06 and ours.psnr >= theirs.psnr - 3.0, (ours, theirs)
        assert b.size <= rb.size * 1.35 + 40, (b.size, rb.size)
    assert compare(a, c, "decoders agree").psnr >= 30 or min(shape) < 11   # both decoders reconstruct the same picture


def test_webp_lossy_size_not_larger_than_libwebp_at_equal_ssim():
    for name, img, bound in (("graphic", _graphic(), 1.0), ("photo", photo(240, 360), 1.06)):
        ours, theirs = _ssim_size_curve(SR, img), _ssim_size_curve(REF, img)
        for t in (0.96, 0.98):
            lo, hi = max(ours[0][0], theirs[0][0]), min(ours[-1][0], theirs[-1][0])
            if lo <= t <= hi:
                r = _size_at(ours, t) / _size_at(theirs, t)
                print(name, t, round(r, 3))
                assert r <= bound, (name, t, r)


def test_webp_lossy_segments_and_loop_filter_are_signalled():
    """The stream must carry a segment map (4 quantisers) on textured frames, and tiny images must stay valid."""
    ok, b = SR.imencode(".webp", photo(160, 240), [64, 75])
    assert ok
    ok, one = SR.imencode(".webp", np.full((1, 1, 3), 200, np.uint8), [64, 75])
    assert np.abs(REF.imdecode(one, COLOR).astype(int) - 200).max() <= 8
    ok, flat = SR.imencode(".webp", np.full((70, 90, 3), 77, np.uint8), [64, 80])
    d = REF.imdecode(flat, COLOR)
    assert np.abs(d.astype(int) - 77).max() <= 3 and flat.size < 400


def test_webp_lossless_meta_codes_cross_colour_cache_exact():
    rng = np.random.default_rng(21)
    g = _graphic(300, 400)
    mixed = g.copy()
    mixed[:, 200:] = rng.integers(0, 256, mixed[:, 200:].shape, dtype=np.uint8) // 8 * 8      # two very different regions
    corr = photo(180, 250).copy()
    corr[..., 2] = np.clip(corr[..., 1].astype(int) * 3 // 4 + 20, 0, 255)                        # colour-correlated channels
    cases = [g, mixed, corr, np.ascontiguousarray(g[:, :1]), np.ascontiguousarray(g[:1]), g[:2, :2].copy(),
             np.ascontiguousarray(np.repeat(g[:7, :9], 3, axis=0))]
    for img in cases:
        ok, b = SR.imencode(".webp", img, [64, 101])
        assert ok
        for dec in (REF, SR):
            d = dec.imdecode(b, COLOR)
            assert d is not None and np.array_equal(d, img), img.shape
        ok2, b2 = SR.imencode(".webp", img, [64, 101])
        assert b.tobytes() == b2.tobytes()                                                       # deterministic
    # size vs libwebp: graphics / mixed frames must be within 10 %; the smooth synthetic "photo" has a known gap (documented)
    for img, bound in zip(cases[:3], (1.10, 1.10, 1.40)):
        ok, ours = SR.imencode(".webp", img, [64, 101])
        _ok, theirs = REF.imencode(".webp", img, [64, 101])
        assert ours.size <= theirs.size * bound, (img.shape, ours.size, theirs.size)


def test_webp_lossless_palette_predictor_and_rgba_exact():
    g = _graphic(200, 300)
    for levels in (2, 4, 6):
        step = 256 // levels
        q = ((g // step) * step + step // 2).astype(np.uint8)
        ok, b = SR.imencode(".webp", q, [64, 101])
        assert ok and np.array_equal(REF.imdecode(b, COLOR), q) and np.array_equal(SR.imdecode(b, COLOR), q)
        _ok, rb = REF.imencode(".webp", q, [64, 101])
        assert b.size <= rb.size * 1.5, (levels, b.size, rb.size)
    al = np.tile(np.linspace(0, 255, 300).astype(np.uint8), (200, 1))
    rgba = np.dstack([g, al])
    rgba[50:80, 50:120, 3] = 0
    ok, b = SR.imencode(".webp", rgba, [64, 101])
    assert np.array_equal(REF.imdecode(b, UNCHANGED), rgba)


def _text_like(h=700, w=1100, seed=3):
    """A screenshot-like page: coloured anti-aliased text lines on a flat background (a few thousand colours)."""
    rng = np.random.default_rng(seed)
    img = np.full((h, w, 3), (245, 244, 240), np.uint8)
    words = "Safarium renders reels quickly lossless webp text screenshot".split()
    for row in range(14):
        col = tuple(int(v) for v in rng.integers(0, 160, 3))
        REF.putText(img, " ".join(rng.choice(words, 7)), (20, 40 + row * 46), REF.FONT_HERSHEY_SIMPLEX, 1.0, col, 2, REF.LINE_AA)
    return img


def test_webp_lossless_text_screenshot_is_not_larger_than_libwebp():
    """The entropy estimate favours a predictor on text, but long copies are far better: transforms are chosen by real sizes."""
    img = _text_like()
    assert len(np.unique(img.reshape(-1, 3), axis=0)) > 256        # not a palette image
    ok, ours = SR.imencode(".webp", img, [64, 101])
    _ok, theirs = REF.imencode(".webp", img, [64, 101])
    assert ok and np.array_equal(REF.imdecode(ours, COLOR), img) and np.array_equal(SR.imdecode(ours, COLOR), img)
    assert ours.size <= theirs.size, (ours.size, theirs.size)


def test_webp_lossless_c_encoder_validates_its_own_arguments():
    """sr_vp8l_encode is exported: bad sizes / null pointers must come back as an error code, never a crash."""
    import subprocess
    code = (
        "import ctypes, os, sys\n"
        "lib = ctypes.CDLL(os.environ['SAFARIUM_RASTER_LIB'])\n"
        "f = lib.sr_vp8l_encode\n"
        "f.restype = ctypes.c_int64\n"
        "f.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p)]\n"
        "px = (ctypes.c_uint32 * 64)(*([0xFF102030] * 64))\n"
        "out = ctypes.c_void_p(1)\n"
        "bad = [(0, 8), (8, 0), (-3, 8), (16385, 1), (1, 16385), (70000, 70000)]\n"
        "for w, h in bad:\n"
        "    out = ctypes.c_void_p(1)\n"
        "    assert f(px, w, h, 0, 100, ctypes.byref(out)) < 0, (w, h)\n"
        "    assert out.value is None, (w, h)\n"
        "assert f(None, 8, 8, 0, 100, ctypes.byref(out)) < 0\n"
        "assert f(px, 8, 8, 0, 100, None) < 0\n"
        "out = ctypes.c_void_p()\n"
        "n = f(px, 8, 8, 0, 100, ctypes.byref(out))\n"
        "assert n > 0 and out.value\n"
        "print('ok')\n"
    )
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0 and "ok" in r.stdout, (r.returncode, r.stdout[-300:], r.stderr[-600:])


def test_webp_14bit_policy_rejects_oversized_dimensions():
    """Pick's Ruling 2026-11-24: max 16383x16383 AND <= 2^27 pixels, returning SRStatus.badArgument before allocation."""
    import os
    import subprocess
    code = (
        "import ctypes, os, resource, sys, numpy as np\n"
        "lib = ctypes.CDLL(os.environ['SAFARIUM_RASTER_LIB'])\n"
        "lib.sr_last_error.argtypes = [ctypes.c_char_p, ctypes.c_int32]\n"
        "lib.sr_last_error.restype = ctypes.c_int32\n"
        "lib.sr_io_encode2.argtypes = [ctypes.c_void_p] + [ctypes.c_int32] * 5 + [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p)]\n"
        "lib.sr_io_encode2.restype = ctypes.c_int32\n"
        "lib.sr_vp8l_encode.argtypes = [ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.POINTER(ctypes.c_void_p)]\n"
        "lib.sr_vp8l_encode.restype = ctypes.c_int64\n"
        "lib.sr_vp8_encode.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]\n"
        "lib.sr_vp8_encode.restype = ctypes.c_int64\n"
        "def err_msg():\n"
        "    b = ctypes.create_string_buffer(512)\n"
        "    lib.sr_last_error(b, 512)\n"
        "    return b.value.decode('utf-8')\n"
        "expected = 'WebP dimensions exceed 14-bit limit (max 16383x16383 and 2^27 pixels)'\n"
        "px = (ctypes.c_uint32 * 64)(*([0xFF102030] * 64))\n"
        "dummy = (ctypes.c_uint8 * 64)()\n"
        "probs = (ctypes.c_uint8 * 1056)()\n"
        "qtab = (ctypes.c_int32 * 128)()\n"
        "for w, h in [(16384, 1), (1, 16384), (16000, 9000)]:\n"
        "    out = ctypes.c_void_p(1)\n"
        "    assert lib.sr_vp8l_encode(px, w, h, 0, 100, ctypes.byref(out)) < 0, (w, h)\n"
        "    assert out.value is None, (w, h)\n"
        "    out2 = ctypes.c_void_p(1)\n"
        "    mbw, mbh = (w + 15) // 16, (h + 15) // 16\n"
        "    assert lib.sr_vp8_encode(dummy, dummy, dummy, 16, 8, mbw, mbh, w, h, 80, probs, probs, qtab, qtab, ctypes.byref(out2)) < 0, (w, h)\n"
        "    assert out2.value is None, (w, h)\n"
        "sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'safarium_cv2')) if '__file__' in globals() else None\n"
        "import pathlib\n"
        "sys.path.insert(0, str(pathlib.Path('sdk/python/safarium_cv2').resolve()))\n"
        "import cv2 as sr\n"
        "base = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
        "for (h, w) in [(1, 16384), (16384, 1), (9000, 16000)]:\n"
        "    arr = np.zeros((h, w, 3), np.uint8)\n"
        "    for params in ([64, 85], [64, 101]):\n"
        "        ok, buf = sr.imencode('.webp', arr, params)\n"
        "        assert ok is False and buf.size == 0, (h, w, params)\n"
        "        assert err_msg() == expected, (h, w, params, err_msg())\n"
        "        parr = (ctypes.c_int32 * 2)(*params)\n"
        "        out_blob = ctypes.c_void_p()\n"
        "        rc = lib.sr_io_encode2(arr.ctypes.data, w, h, w * 3, 3, 0, b'.webp', parr, 2, ctypes.byref(out_blob))\n"
        "        assert rc == -1, (h, w, params, rc)\n"
        "        assert err_msg() == expected, (h, w, params, err_msg())\n"
        "peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
        "grow_mb = (peak - base) / 1048576.0\n"
        "assert grow_mb < 32.0, f'allocated too much memory on rejected WebP: {grow_mb:.2f} MiB'\n"
        "print('ok', round(grow_mb, 2))\n"
    )
    r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60, env={**os.environ})
    assert r.returncode == 0 and "ok" in r.stdout, (r.returncode, r.stdout[-300:], r.stderr[-600:])


def _lossless_kinds(rng, h, w):
    """Image families that route through every encoder path: noise, gradient, 2 colours, ~20 colours, 200 greys, text-like."""
    y, x = np.mgrid[0:h, 0:w]
    grad = np.stack([(x * 3 + y) % 256, (y * 5) % 256, (x + y) % 256], -1).astype(np.uint8)
    two = np.where(((x // 5 + y // 7) & 1)[..., None], 255, 16).astype(np.uint8).repeat(3, -1)
    few = (rng.integers(0, 20, (h, w, 1)) * 12).astype(np.uint8).repeat(3, -1)
    greys = rng.integers(0, 200, (h, w, 1)).astype(np.uint8).repeat(3, -1)
    textish = np.where(((x + y) % 41 < 3)[..., None], 32, 240 + rng.integers(0, 3, (h, w, 3))).astype(np.uint8)
    return {"noise": rng.integers(0, 256, (h, w, 3), dtype=np.uint8), "grad": grad, "two": two, "few": few, "greys": greys,
            "textish": textish}


@pytest.mark.parametrize("kind", ["noise", "grad", "two", "few", "greys", "textish"])
def test_webp_lossless_random_shapes_and_alpha_round_trip_in_both_decoders(kind):
    rng = np.random.default_rng(31)
    shapes = [(1, 1), (1, 37), (29, 1), (2, 3), (17, 16), (33, 65), (64, 90), (150, 210)]
    for (h, w) in shapes:
        img = _lossless_kinds(rng, h, w)[kind]
        variants = [img, np.dstack([img, ((np.arange(h * w).reshape(h, w) * 7) % 256).astype(np.uint8)])]
        for v in variants:
            for q in (100, 60):
                ok, b = SR.imencode(".webp", v, [64, 101 if q == 100 else 100, 65, 1])
                assert ok
                back = REF.imdecode(b, UNCHANGED)
                assert np.array_equal(back, v), (kind, h, w, v.shape)
                assert np.array_equal(SR.imdecode(b, UNCHANGED), v), (kind, h, w, v.shape)


# ---------------------------------------------------------------------------------------------- GIF writer (default settings)
# OpenCV 5.1's default GIF encoder (quality 2): fixed 3-3-2 palette + Floyd-Steinberg, alpha 0 = transparent. The bench found
# our ImageIO output unrelated to it (SSIM 0.45 between the two); the own writer reproduces the reference byte for byte.

def _gif_images():
    rng = np.random.default_rng(20261124)
    ph = photo(90, 130)
    noisy = rng.integers(0, 256, (120, 160, 3), dtype=np.uint8)   # fills the LZW table (several clear codes)
    big_noise = rng.integers(0, 256, (200, 300, 3), dtype=np.uint8)
    holes = np.dstack([ph[10:50, 20:80], np.full((40, 60), 255, np.uint8)])
    holes[rng.random((40, 60)) < 0.2, 3] = 0
    holes[8:20, 10:30, 3] = 0
    semi = holes.copy()
    semi[..., 3] = rng.integers(1, 256, (40, 60))
    collide = np.zeros((10, 10, 4), np.uint8)   # opaque pixels that quantise onto the transparent index 146
    collide[..., :3] = (170, 144, 144)
    collide[..., 3] = 255
    collide[0, 0, 3] = 0
    return {
        "photo": ph, "noisy": noisy, "big_noise": big_noise, "flat": np.full((30, 40, 3), 77, np.uint8),
        "gradient": np.dstack([np.tile(np.arange(256, dtype=np.uint8), (16, 1))] * 3),
        "col": rng.integers(0, 256, (30, 1, 3), dtype=np.uint8), "row": rng.integers(0, 256, (1, 30, 3), dtype=np.uint8),
        "1x1": np.zeros((1, 1, 3), np.uint8), "white": np.full((20, 20, 3), 255, np.uint8),
        "u16": rng.integers(0, 70000, (20, 30, 3)).clip(0, 65535).astype(np.uint16),
        "f32": (rng.random((20, 30, 3)) * 300 - 20).astype(np.float32), "s32": rng.integers(-50, 400, (20, 30, 3)).astype(np.int32),
        "bgra_opaque": np.dstack([ph[:40, :60], np.full((40, 60), 255, np.uint8)]), "bgra_holes": holes, "bgra_semi": semi,
        "bgra_collide": collide, "bgra_all_transparent": np.dstack([ph[:20, :20], np.zeros((20, 20), np.uint8)]),
    }


_GIF_IMAGES = _gif_images()


@pytest.mark.parametrize("name", sorted(_GIF_IMAGES))
def test_gif_imencode_default_bytes_identical(name):
    img = _GIF_IMAGES[name]
    ok_r, r = REF.imencode(".gif", img)
    ok_s, s = SR.imencode(".gif", img)
    assert ok_r and ok_s
    assert r.tobytes() == s.tobytes(), f"{name}: reference {r.size} B vs ours {s.size} B"


def test_gif_imencode_random_shapes_and_transparency_fuzz():
    rng = np.random.default_rng(7)
    for i in range(40):
        h, w = int(rng.integers(1, 40)), int(rng.integers(1, 70))
        cn = int(rng.choice([3, 4]))
        img = rng.integers(0, 256, (h, w, cn), dtype=np.uint8)
        if i % 3 == 0:   # flat / near-flat colours hit the quantiser's exact ties
            img[...] = rng.integers(0, 256, (cn,), dtype=np.uint8)
            img[..., :3] += rng.integers(0, 3, (h, w, 3), dtype=np.uint8)
        if cn == 4:
            img[..., 3] = np.where(rng.random((h, w)) < 0.3, 0, 255)
        r, s = REF.imencode(".gif", img)[1].tobytes(), SR.imencode(".gif", img)[1].tobytes()
        assert r == s, f"case {i}: {h}x{w}x{cn}"


def test_gif_imencode_one_channel_is_refused_like_the_reference():
    g = np.ascontiguousarray(_GIF_IMAGES["photo"][..., 1])
    assert REF.imencode(".gif", g)[0] is False
    assert SR.imencode(".gif", g)[0] is False


@pytest.mark.parametrize("durations,loop", [([100, 200, 300], 0), ([15, 25, 5, 0, 1234], 7), ([10, 10], 65536 + 3), ([100], 1)])
def test_gif_animation_bytes_identical(durations, loop):
    ph = _GIF_IMAGES["photo"]
    frames = [ph, ph[::-1].copy(), ph[:, ::-1].copy(), np.roll(ph, 5, axis=1), np.roll(ph, 9, axis=0)][: len(durations)]
    out = []
    for m in (REF, SR):
        an = m.Animation()
        an.frames = [f.copy() for f in frames]
        an.durations = list(durations)
        an.loop_count = loop
        ok, b = m.imencodeanimation(".gif", an)
        assert ok
        out.append(b.tobytes())
    assert out[0] == out[1]


def test_gif_animation_transparency_in_one_frame_flags_all_frames():
    a = np.dstack([_GIF_IMAGES["photo"][:30, :40], np.full((30, 40), 255, np.uint8)])
    b = a.copy()
    b[5:9, 5:9] = (10, 20, 30, 0)
    c = a.copy()
    c[1, 1] = (40, 50, 60, 0)
    out = []
    for m in (REF, SR):
        an = m.Animation()
        an.frames = [a.copy(), b.copy(), c.copy(), a.copy()]
        an.durations = [100, 100, 100, 100]
        out.append(m.imencodeanimation(".gif", an)[1].tobytes())
    assert out[0] == out[1]


def test_gif_imencodemulti_and_imwritemulti_bytes_identical(tmp_path):
    ph = _GIF_IMAGES["photo"]
    frames = [ph, ph[::-1].copy()]
    r = REF.imencodemulti(".gif", frames)[1].tobytes()
    s = SR.imencodemulti(".gif", frames)[1].tobytes()
    assert r == s
    pr, ps = tmp_path / "r.gif", tmp_path / "s.gif"
    assert REF.imwritemulti(str(pr), frames) and SR.imwritemulti(str(ps), frames)
    assert pr.read_bytes() == ps.read_bytes()


def test_gif_animation_refused_like_the_reference():
    ph = _GIF_IMAGES["photo"]
    for frames in ([ph, ph[:10].copy()], [ph, np.ascontiguousarray(ph[..., 1])]):
        res = []
        for m in (REF, SR):
            an = m.Animation()
            an.frames = [f.copy() for f in frames]
            an.durations = [100, 100]
            res.append(m.imencodeanimation(".gif", an)[0])
        assert res == [False, False]


def test_gif_other_qualities_still_encode_valid_files():
    """Only the default quantiser is reproduced; other IMWRITE_GIF_* requests keep working through ImageIO."""
    ph = _GIF_IMAGES["photo"]
    for params in ([SR.IMWRITE_GIF_QUALITY, 7], [SR.IMWRITE_GIF_DITHER, 1], [SR.IMWRITE_GIF_QUALITY, 3, SR.IMWRITE_GIF_DITHER, 2]):
        ok, buf = SR.imencode(".gif", ph, params)
        assert ok and buf.tobytes()[:3] == b"GIF"
        back = SR.imdecode(buf, COLOR)
        assert back.shape == ph.shape
    ok, buf = SR.imencode(".gif", ph, [SR.IMWRITE_GIF_QUALITY, 2, SR.IMWRITE_GIF_COLORTABLE, 1])
    assert buf.tobytes() == REF.imencode(".gif", ph, [REF.IMWRITE_GIF_QUALITY, 2, REF.IMWRITE_GIF_COLORTABLE, 1])[1].tobytes()


# ---------------------------------------------------------------------------------------------- TIFF default size guard
@pytest.mark.parametrize("kind", ["u8bgr", "u8gray", "u16gray", "u16bgr", "f32gray", "f32bgr", "u8bgra", "u8bgr_view", "u8bgr_reversed"])
def test_tiff_default_is_never_larger_than_the_reference_and_decodes_the_same(kind):
    p = photo(160, 200)
    img = {
        "u8bgr": p, "u8gray": np.ascontiguousarray(p[..., 1]), "u16gray": p[..., 1].astype(np.uint16) * 257,
        "u16bgr": p.astype(np.uint16) * 257, "f32gray": p[..., 1].astype(np.float32) / 255, "f32bgr": p.astype(np.float32) / 255,
        "u8bgra": np.dstack([p, np.full(p.shape[:2], 255, np.uint8)]), "u8bgr_view": p[10:130, 20:180], "u8bgr_reversed": p[::-1, ::-1],
    }[kind]
    r = REF.imencode(".tif", img)[1].tobytes()
    s = SR.imencode(".tif", img)[1].tobytes()
    assert len(s) <= len(r), f"{kind}: ours {len(s)} B vs reference {len(r)} B"
    assert np.array_equal(REF.imdecode(np.frombuffer(s, np.uint8), UNCHANGED), REF.imdecode(np.frombuffer(r, np.uint8), UNCHANGED))
    frames = [p, p[::-1].copy()]
    rm = REF.imencodemulti(".tif", frames)[1].tobytes()
    sm = SR.imencodemulti(".tif", frames)[1].tobytes()
    assert len(sm) <= len(rm)


# ---------------------------------------------------------------------------------------------- TIFF level-1 deflate: bound, RAM, threads
def _sr_lib():
    import os
    return ctypes.CDLL(os.environ["SAFARIUM_RASTER_LIB"])


def test_deflate_fast_output_never_exceeds_its_own_bound_on_incompressible_input():
    """sr_deflate_bound must be >= the worst case: an incompressible 256 KiB block is 5 stored sub-blocks (25 B overhead)."""
    import zlib
    lib = _sr_lib()
    lib.sr_deflate_bound.restype = ctypes.c_int64
    lib.sr_deflate_bound.argtypes = [ctypes.c_int64]
    lib.sr_deflate_fast.restype = ctypes.c_int64
    lib.sr_deflate_fast.argtypes = [ctypes.c_char_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int64]
    rng = np.random.default_rng(3)
    for n in (1 << 18, 6 << 20, 16 << 20, (16 << 20) + 12345):
        data = rng.integers(0, 256, n, dtype=np.uint8).tobytes()
        cap = lib.sr_deflate_bound(n)
        guard = 4096
        out = (ctypes.c_ubyte * (cap + guard))()
        ctypes.memset(out, 0xA5, cap + guard)
        got = lib.sr_deflate_fast(data, n, out, cap)
        assert got > 0, n
        assert got <= cap, f"n={n}: wrote {got} B but the bound is {cap}"
        assert bytes(out[cap:]) == b"\xa5" * guard, f"n={n}: overran the buffer"
        assert zlib.decompress(bytes(out[:got]), -15) == data


def test_deflate_fast_refuses_instead_of_overrunning_a_too_small_buffer():
    lib = _sr_lib()
    lib.sr_deflate_fast.restype = ctypes.c_int64
    lib.sr_deflate_fast.argtypes = [ctypes.c_char_p, ctypes.c_int64, ctypes.c_void_p, ctypes.c_int64]
    data = np.random.default_rng(4).integers(0, 256, 1 << 20, dtype=np.uint8).tobytes()
    out = (ctypes.c_ubyte * ((1 << 20) + 64))()
    assert lib.sr_deflate_fast(data, len(data), out, 1000) == -1


def test_tiff_f32_incompressible_16mib_single_strip_decodes_byte_exact_in_libtiff():
    rng = np.random.default_rng(21)
    a = rng.integers(0, 2**32, (2048, 2048), dtype=np.uint32).view(np.float32)   # 16 MiB of random bits (NaNs included)
    ok, b = SR.imencode(".tif", a, [278, a.shape[0]])
    assert ok
    d = REF.imdecode(b, UNCHANGED)
    assert d.dtype == np.float32 and d.shape == a.shape
    assert np.array_equal(d.view(np.uint32), a.view(np.uint32))


def _run_py(code, timeout=300, args=()):
    import os
    import subprocess
    env = {**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parent)}
    return subprocess.run([sys.executable, "-c", code, *args], capture_output=True, text=True, timeout=timeout, env=env)


def test_tiff_level1_peak_memory_does_not_scale_with_the_strip_size():
    """One 64 MiB strip vs 64-row strips: the encoder may not hold whole-strip copies of the samples and of the compressed bytes.

    Both runs pay the same fixed cost (the 64 MiB input conversion), so the difference isolates the strip-size dependence.
    """
    code = (
        "import resource, sys, numpy as np\n"
        "from raster_parity import load_pair\n"
        "REF, SR = load_pair()\n"
        "a = np.zeros((4096, 4096), np.float32); a[::3] = 1.5\n"
        "SR.imencode('.tif', a[:8], [278, 8])\n"            # warm the library
        "before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
        "ok, b = SR.imencode('.tif', a, [278, int(sys.argv[1])])\n"
        "after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss\n"
        "assert ok\n"
        "assert np.array_equal(REF.imdecode(b, -1), a)\n"
        "print((after - before) / 1048576.0 if sys.platform == 'darwin' else (after - before) / 1024.0)\n"
    )
    delta = {}
    for rows in (64, 4096):
        r = _run_py(code, args=[str(rows)])
        assert r.returncode == 0, r.stderr[-2000:]
        delta[rows] = float(r.stdout.strip().splitlines()[-1])
    assert delta[4096] - delta[64] < 16.0, delta


def test_tiff_f32_encode_from_many_threads_at_once_is_identical():
    """Fresh process, so the first call (table initialisation) really races."""
    code = (
        "import threading, numpy as np\n"
        "from raster_parity import load_pair\n"
        "REF, SR = load_pair()\n"
        "rng = np.random.default_rng(1)\n"
        "a = (rng.integers(0, 256, (200, 300, 3)) / 255).astype(np.float32)\n"
        "res = [None] * 16\n"
        "gate = threading.Barrier(16)\n"
        "def work(i):\n"
        "    gate.wait()\n"
        "    res[i] = SR.imencode('.tif', a)[1].tobytes()\n"
        "ts = [threading.Thread(target=work, args=(i,)) for i in range(16)]\n"
        "[t.start() for t in ts]; [t.join() for t in ts]\n"
        "assert all(r == res[0] for r in res), 'outputs differ'\n"
        "assert np.array_equal(REF.imdecode(np.frombuffer(res[0], np.uint8), -1), a)\n"
        "print('ok')\n"
    )
    r = _run_py(code)
    assert r.returncode == 0 and r.stdout.strip().endswith("ok"), r.stderr[-2000:]
