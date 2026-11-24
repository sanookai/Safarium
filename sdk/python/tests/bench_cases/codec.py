"""Codecs (roadmap phase 5): imencode / imdecode for JPEG, PNG, TIFF, GIF. Encoders are judged by decoding the bytes
with Pillow (a neutral decoder): speed/RAM on 1080x1920 frames, quality = parity of the decoded pixels, file size = bytes
at matched SSIM (lossy) or lossless bytes with exact round-trip on a 512x512 crop of a Sompong frame / a Kodak image."""
from __future__ import annotations

import io

import numpy as np

from . import SizeSpec, register
from ._common import crop512, gray_of, kodak_frame, pil_decode_bgr, sompong_frame

P5 = (0, 5)


def _enc_bytes(out):
    ok, buf = out
    assert ok
    return np.asarray(buf, np.uint8)


def _norm_decode(out):
    return pil_decode_bgr(_enc_bytes(out))


def _pil_bytes(arr_bgr, fmt, **kw):
    from PIL import Image
    im = Image.fromarray(np.ascontiguousarray(arr_bgr[..., ::-1])) if arr_bgr.ndim == 3 else Image.fromarray(arr_bgr)
    b = io.BytesIO()
    im.save(b, fmt, **kw)
    return np.frombuffer(b.getvalue(), np.uint8).copy()


def _frame_input(kind="u8bgr"):
    def make(rng):
        f = sompong_frame()
        return {"img": f if kind == "u8bgr" else (gray_of(f).astype(np.float32) / 255.0 if kind == "f32gray" else gray_of(f))}
    return make


_SIZE_IMAGES = {"sompong_crop512": lambda rng: crop512(sompong_frame()), "kodim15": lambda rng: kodak_frame()}

# ----------------------------------------------------------------------------- JPEG
for _name, _mk in _SIZE_IMAGES.items():
    register(area="codec", op="imencode_jpeg", variant=f"q90_1080x1920_sompong_size_on_{_name}", phases=P5,
             make_input=_frame_input(), norm=_norm_decode,
             ref=lambda cv, x: cv.imencode(".jpg", x["img"], [cv.IMWRITE_JPEG_QUALITY, 90]),
             size=SizeSpec("lossy", _mk, lambda cv, img, q: _enc_bytes(cv.imencode(".jpg", img, [cv.IMWRITE_JPEG_QUALITY, int(q)])),
                           (1, 100), (0.97, 0.99)))
register(area="codec", op="imencode_jpeg", variant="q90_gray_1080x1920_sompong", phases=P5, make_input=_frame_input("u8gray"),
         norm=_norm_decode, ref=lambda cv, x: cv.imencode(".jpg", x["img"], [cv.IMWRITE_JPEG_QUALITY, 90]))


def _dec_input(fmt, kind="u8bgr", **kw):
    def make(rng):
        f = sompong_frame()
        if kind == "f32gray":
            from PIL import Image
            im = Image.fromarray(gray_of(f).astype(np.float32) / 255.0, mode="F")
            b = io.BytesIO()
            im.save(b, "TIFF")
            return {"buf": np.frombuffer(b.getvalue(), np.uint8).copy()}
        return {"buf": _pil_bytes(f if kind == "u8bgr" else gray_of(f), fmt, **kw)}
    return make


register(area="codec", op="imdecode_jpeg", variant="q90_color_1080x1920_sompong", phases=P5, stream=True,
         make_input=_dec_input("JPEG", quality=90), ref=lambda cv, x: cv.imdecode(x["buf"], cv.IMREAD_COLOR))
register(area="codec", op="imdecode_jpeg", variant="q90_gray_1080x1920_sompong", phases=P5,
         make_input=_dec_input("JPEG", quality=90), ref=lambda cv, x: cv.imdecode(x["buf"], cv.IMREAD_GRAYSCALE))
register(area="codec", op="imdecode_png", variant="color_1080x1920_sompong", phases=P5,
         make_input=_dec_input("PNG", compress_level=6), ref=lambda cv, x: cv.imdecode(x["buf"], cv.IMREAD_COLOR))
register(area="codec", op="imdecode_tiff", variant="f32gray_unchanged_1080x1920", phases=P5,
         make_input=_dec_input("TIFF", kind="f32gray"), ref=lambda cv, x: cv.imdecode(x["buf"], cv.IMREAD_UNCHANGED))
register(area="codec", op="imdecode_gif", variant="color_1080x1920_sompong", phases=P5,
         make_input=lambda rng: {"buf": _pil_bytes(sompong_frame(), "GIF")}, ref=lambda cv, x: cv.imdecode(x["buf"], cv.IMREAD_COLOR))

# ----------------------------------------------------------------------------- PNG / TIFF (lossless bytes at identical pixels)
for _name, _mk in _SIZE_IMAGES.items():
    register(area="codec", op="imencode_png", variant=f"default_1080x1920_sompong_size_on_{_name}", phases=P5,
             make_input=_frame_input(), norm=_norm_decode, ref=lambda cv, x: cv.imencode(".png", x["img"]),
             size=SizeSpec("lossless", _mk, lambda cv, img, q: _enc_bytes(cv.imencode(".png", img)), ext=".png"))
    register(area="codec", op="imencode_png", variant=f"c9_1080x1920_sompong_size_on_{_name}", phases=P5,
             make_input=_frame_input(), norm=_norm_decode,
             ref=lambda cv, x: cv.imencode(".png", x["img"], [cv.IMWRITE_PNG_COMPRESSION, 9]),
             size=SizeSpec("lossless", _mk, lambda cv, img, q: _enc_bytes(cv.imencode(".png", img, [cv.IMWRITE_PNG_COMPRESSION, 9])),
                           ext=".png"))
register(area="codec", op="imencode_tiff", variant="u8bgr_1080x1920_sompong_size_on_sompong_crop512", phases=P5,
         make_input=_frame_input(), norm=_norm_decode, ref=lambda cv, x: cv.imencode(".tif", x["img"]),
         size=SizeSpec("lossless", _SIZE_IMAGES["sompong_crop512"], lambda cv, img, q: _enc_bytes(cv.imencode(".tif", img)), ext=".tif"))
register(area="codec", op="imencode_tiff", variant="f32gray_1080x1920", phases=P5, make_input=_frame_input("f32gray"),
         norm=_norm_decode, ref=lambda cv, x: cv.imencode(".tif", x["img"]))
register(area="codec", op="imencode_gif", variant="u8bgr_1080x1920_sompong_size_on_sompong_crop512", phases=P5,
         make_input=_frame_input(), norm=_norm_decode, ref=lambda cv, x: cv.imencode(".gif", x["img"]),
         size=SizeSpec("fixed", _SIZE_IMAGES["sompong_crop512"], lambda cv, img, q: _enc_bytes(cv.imencode(".gif", img)), ext=".gif"))
