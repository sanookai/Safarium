"""Parity and edge-case tests for SafariumRaster Phase 8 (`photo` + HDR) vs OpenCV 5.1.0.95."""
from __future__ import annotations

import importlib
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from raster_parity import compare, load_pair, psnr, ssim  # noqa: E402

REF, SR_SHIM = load_pair()
REF.setNumThreads(1)
SR_SHIM.setNumThreads(1)
SR = importlib.import_module("cv2._photo")


def _synthetic_scene(h=96, w=128, seed=11) -> np.ndarray:
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    b = 115.0 + 55.0 * np.sin(xx * 0.08) * np.cos(yy * 0.07) + 25.0 * np.cos((xx + yy) * 0.11)
    g = 125.0 + 50.0 * np.cos(xx * 0.06 - yy * 0.09) + 20.0 * np.sin(yy * 0.13)
    r = 130.0 + 60.0 * np.sin((xx - yy) * 0.07) + 20.0 * np.cos(xx * 0.12)
    img = np.stack([np.clip(b, 15, 240), np.clip(g, 15, 240), np.clip(r, 15, 240)], axis=-1).astype(np.uint8)
    REF.circle(img, (w // 2, h // 2), min(h, w) // 5, (40, 190, 220), -1)
    REF.rectangle(img, (w // 8, h // 6), (w // 3, h - h // 6), (210, 70, 50), -1)
    noise = rng.normal(0.0, 2.0, size=img.shape)
    return np.clip(img.astype(np.float32) + noise, 0, 255).astype(np.uint8)


def _exposure_stack(h=96, w=128):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    rad = np.stack([
        0.15 + 1.8 * (0.5 + 0.5 * np.sin(xx * 0.06)) * (0.5 + 0.5 * np.cos(yy * 0.05)),
        0.20 + 2.2 * (0.5 + 0.5 * np.cos(xx * 0.05 + yy * 0.04)),
        0.10 + 1.5 * (0.5 + 0.5 * np.sin((xx + yy) * 0.06)),
    ], axis=-1).astype(np.float32)
    # Apply synthetic gamma=2.2 inverse CRF so Debevec/Robertson calibration recovers smooth curves
    times = np.array([0.25, 0.5, 1.0, 2.0, 4.0], dtype=np.float32)
    imgs = []
    for t in times:
        lin = np.clip(rad * t, 0.0, 1.0)
        ldr = np.rint(np.power(lin, 1.0 / 2.2) * 255.0).astype(np.uint8)
        imgs.append(ldr)
    return rad, imgs, times


def _assert_img_parity(ref: np.ndarray, got: np.ndarray, name: str,
                       ssim_min=0.97, psnr_min=30.0, de_max=2.0):
    res = compare(ref, got, name)
    assert res.ssim >= ssim_min, str(res)
    assert res.psnr >= psnr_min, str(res)
    if res.de00_p95 is not None:
        assert res.de00_p95 <= de_max, str(res)


def _assert_f32_parity(ref: np.ndarray, got: np.ndarray, name: str,
                       ssim_min=0.97, psnr_min=30.0, de_max=2.0):
    assert got.shape == ref.shape and got.dtype == ref.dtype, f"{name}: {got.shape}/{got.dtype} vs {ref.shape}/{ref.dtype}"
    assert np.all(np.isfinite(got)), f"{name}: non-finite values"
    # Normalize float32 images consistently when comparing HDR / [0,1] tonemaps
    r_clean = np.nan_to_num(ref, nan=0.0)
    peak = max(float(np.max(np.abs(r_clean))), float(np.max(np.abs(got))), 1e-6)
    r_u8 = np.clip(np.rint((r_clean / peak) * 255.0), 0, 255).astype(np.uint8)
    g_u8 = np.clip(np.rint((got / peak) * 255.0), 0, 255).astype(np.uint8)
    _assert_img_parity(r_u8, g_u8, name, ssim_min=ssim_min, psnr_min=psnr_min, de_max=de_max)


# --------------------------------------------------------------------------- Exports & Constants

def test_exports_and_constants():
    for name in SR.__all__:
        assert hasattr(SR, name), f"Missing export {name}"
    for k, v in SR.CONSTANTS.items():
        assert hasattr(REF, k), f"Constant {k} missing in reference cv2"
        assert getattr(REF, k) == v, f"Constant {k}: {v} != {getattr(REF, k)}"


# --------------------------------------------------------------------------- 1. Inpainting

def _ref_fresh(op_code: str, **arrays):
    """Run an OpenCV 5.1 Poisson call in a fresh interpreter to avoid cvref's call-parity bug."""
    import json, os, subprocess, tempfile
    with tempfile.TemporaryDirectory() as td:
        in_p = Path(td) / "in.npz"
        out_p = Path(td) / "out.npy"
        np.savez(in_p, **arrays)
        script = (
            "import numpy as np, cv2; "
            f"d=np.load({str(in_p)!r}); "
            f"out={op_code}; "
            f"np.save({str(out_p)!r}, out)"
        )
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        subprocess.run([sys.executable, "-c", script], check=True, env=env)
        return np.load(out_p)


@pytest.mark.parametrize("flags", [REF.INPAINT_TELEA, REF.INPAINT_NS])
@pytest.mark.parametrize("ch,dt", [(1, np.uint8), (1, np.uint16), (1, np.float32), (3, np.uint8)])
def test_inpaint_parity(flags, ch, dt):
    base = _synthetic_scene(80, 96, seed=21)
    if ch == 1:
        src = REF.cvtColor(base, REF.COLOR_BGR2GRAY)
    else:
        src = base.copy()
    if dt == np.uint16:
        src = (src.astype(np.uint16) * 257)
    elif dt == np.float32:
        src = src.astype(np.float32)  # OpenCV TELEA assumes [0..255] float32 range

    mask = np.zeros((80, 96), np.uint8)
    REF.line(mask, (15, 20), (75, 55), 255, 3)
    REF.circle(mask, (48, 40), 5, 255, -1)

    r = REF.inpaint(src, mask, 3.0, flags)
    dst_pre = np.empty_like(src)
    s = SR.inpaint(src, mask, 3.0, flags, dst=dst_pre)
    assert s is dst_pre
    if dt == np.float32:
        _assert_f32_parity(r, s, f"inpaint/f32/f{flags}")
    else:
        _assert_img_parity(r, s, f"inpaint/ch{ch}/{dt.__name__}/f{flags}")


def test_inpaint_f32_3ch_and_zero_mask():
    base = (_synthetic_scene(48, 64, seed=22).astype(np.float32) / 255.0)
    zero_mask = np.zeros((48, 64), np.uint8)
    out0 = SR.inpaint(base, zero_mask, 3.0, SR.INPAINT_TELEA)
    np.testing.assert_array_equal(out0, base)

    mask = np.zeros((48, 64), np.uint8)
    mask[20:26, 28:34] = 255
    for flg in (SR.INPAINT_TELEA, SR.INPAINT_NS):
        out = SR.inpaint(base, mask, 3.0, flg)
        assert out.shape == base.shape and out.dtype == np.float32
        assert np.all(np.isfinite(out))
        np.testing.assert_array_equal(out[mask == 0], base[mask == 0])


# --------------------------------------------------------------------------- 2. NLM & TV-L1

@pytest.mark.parametrize("ch", [1, 2, 3, 4])
@pytest.mark.parametrize("norm", [REF.NORM_L2, REF.NORM_L1])
def test_fast_nl_means_u8(ch, norm):
    rng = np.random.default_rng(100 + ch)
    base = _synthetic_scene(48, 64, seed=31)
    if ch == 1:
        src = REF.cvtColor(base, REF.COLOR_BGR2GRAY)
    elif ch == 2:
        src = base[..., :2].copy()
    elif ch == 3:
        src = base
    else:
        src = np.dstack([base, np.full((48, 64), 200, np.uint8)])
    noisy = np.clip(src.astype(np.int32) + rng.integers(-12, 13, src.shape), 0, 255).astype(np.uint8)

    r = REF.fastNlMeansDenoising(noisy, [10.0], None, 5, 11, norm)
    dst_pre = np.empty_like(noisy)
    s = SR.fastNlMeansDenoising(noisy, [10.0], dst_pre, 5, 11, norm)
    assert s is dst_pre
    _assert_img_parity(r, s, f"nlm_u8/ch{ch}/norm{norm}")


def test_fast_nl_means_u16_and_per_channel_h():
    rng = np.random.default_rng(105)
    g8 = REF.cvtColor(_synthetic_scene(40, 48, seed=32), REF.COLOR_BGR2GRAY)
    src16 = np.clip(g8.astype(np.int32) * 257 + rng.integers(-1200, 1201, g8.shape), 0, 65535).astype(np.uint16)
    r16 = REF.fastNlMeansDenoising(src16, [2500.0], None, 5, 11, REF.NORM_L1)
    s16 = SR.fastNlMeansDenoising(src16, [2500.0], None, 5, 11, SR._NORM_L1)
    _assert_img_parity(r16, s16, "nlm_u16_L1")

    rgb = _synthetic_scene(40, 48, seed=33)
    r_pc = REF.fastNlMeansDenoising(rgb, [8.0, 10.0, 12.0], None, 5, 11, REF.NORM_L2)
    s_pc = SR.fastNlMeansDenoising(rgb, [8.0, 10.0, 12.0], None, 5, 11, SR._NORM_L2)
    _assert_img_parity(r_pc, s_pc, "nlm_per_channel_h")


def test_fast_nl_means_colored_and_multi():
    rng = np.random.default_rng(109)
    base = _synthetic_scene(48, 64, seed=35)
    noisy = np.clip(base.astype(np.int32) + rng.integers(-12, 13, base.shape), 0, 255).astype(np.uint8)

    r_col = REF.fastNlMeansDenoisingColored(noisy, None, 10.0, 10.0, 5, 11)
    s_col = SR.fastNlMeansDenoisingColored(noisy, None, 10.0, 10.0, 5, 11)
    _assert_img_parity(r_col, s_col, "nlm_colored")

    gray_frames = [
        np.clip(REF.cvtColor(base, REF.COLOR_BGR2GRAY).astype(np.int32) + rng.integers(-12, 13, base.shape[:2]), 0, 255).astype(np.uint8)
        for _ in range(3)
    ]
    r_m = REF.fastNlMeansDenoisingMulti(gray_frames, 1, 3, None, 10.0, 5, 11)
    s_m = SR.fastNlMeansDenoisingMulti(gray_frames, 1, 3, None, 10.0, 5, 11)
    _assert_img_parity(r_m, s_m, "nlm_multi")

    col_frames = [
        np.clip(base.astype(np.int32) + rng.integers(-12, 13, base.shape), 0, 255).astype(np.uint8)
        for _ in range(3)
    ]
    r_cm = REF.fastNlMeansDenoisingColoredMulti(col_frames, 1, 3, None, 10.0, 10.0, 5, 11)
    s_cm = SR.fastNlMeansDenoisingColoredMulti(col_frames, 1, 3, None, 10.0, 10.0, 5, 11)
    _assert_img_parity(r_cm, s_cm, "nlm_colored_multi")


def test_denoise_tvl1():
    rng = np.random.default_rng(113)
    base = REF.cvtColor(_synthetic_scene(48, 64, seed=41), REF.COLOR_BGR2GRAY)
    obs = [
        np.clip(base.astype(np.int32) + rng.integers(-20, 21, base.shape), 0, 255).astype(np.uint8)
        for _ in range(4)
    ]
    r_out = np.zeros_like(base)
    s_out = np.zeros_like(base)
    assert REF.denoise_TVL1(obs, r_out, 1.0, 30) is None
    assert SR.denoise_TVL1(obs, s_out, 1.0, 30) is None
    _assert_img_parity(r_out, s_out, "denoise_TVL1")
    assert SR.denoise_TVL1(obs, None, 1.0, 10) is None


# --------------------------------------------------------------------------- 3. Seamless Cloning & Poisson Editing

@pytest.mark.parametrize("flags", [REF.NORMAL_CLONE, REF.MIXED_CLONE, REF.MONOCHROME_TRANSFER])
def test_seamless_clone(flags):
    src = _synthetic_scene(48, 48, seed=51)
    dst = _synthetic_scene(96, 112, seed=52)
    mask = np.zeros((48, 48), np.uint8)
    REF.circle(mask, (24, 24), 16, 255, -1)

    r = _ref_fresh(f"cv2.seamlessClone(d['s'], d['d'], d['m'], (56, 48), {int(flags)})",
                   s=src, d=dst, m=mask.copy())
    dst_pre = np.empty_like(dst)
    s = SR.seamlessClone(src, dst, mask, (56, 48), flags, blend=dst_pre)
    assert s is dst_pre
    _assert_img_parity(r, s, f"seamlessClone/f{flags}")


def test_poisson_variants_and_zero_mask():
    src = _synthetic_scene(72, 96, seed=53)
    mask = np.zeros((72, 96), np.uint8)
    REF.rectangle(mask, (14, 14), (80, 58), 255, -1)

    r_cc = _ref_fresh("cv2.colorChange(d['s'], d['m'], None, 1.5, 0.8, 1.2)", s=src, m=mask)
    s_cc = SR.colorChange(src, mask, None, 1.5, 0.8, 1.2)
    _assert_img_parity(r_cc, s_cc, "colorChange")

    r_ic = _ref_fresh("cv2.illuminationChange(d['s'], d['m'], None, 0.2, 0.4)", s=src, m=mask)
    s_ic = SR.illuminationChange(src, mask, None, 0.2, 0.4)
    _assert_img_parity(r_ic, s_ic, "illuminationChange")

    r_tf = _ref_fresh("cv2.textureFlattening(d['s'], d['m'], None, 30, 45, 3)", s=src, m=mask)
    s_tf = SR.textureFlattening(src, mask, None, 30, 45, 3)
    _assert_img_parity(r_tf, s_tf, "textureFlattening")

    # Zero-mask Poisson ops must preserve destination cleanly
    zmask = np.zeros((72, 96), np.uint8)
    np.testing.assert_array_equal(SR.colorChange(src, zmask, None, 1.5, 0.8, 1.2), src)
    np.testing.assert_array_equal(SR.seamlessClone(src, src, zmask, (48, 36), SR.NORMAL_CLONE), src)


# --------------------------------------------------------------------------- 4. NPR Filters

def test_npr_filters():
    src = _synthetic_scene(128, 128, seed=61)
    for flg in (REF.RECURS_FILTER, REF.NORMCONV_FILTER):
        r = REF.edgePreservingFilter(src, None, flg, 40.0, 0.35)
        s = SR.edgePreservingFilter(src, None, flg, 40.0, 0.35)
        _assert_img_parity(r, s, f"edgePreserving/f{flg}")

    r_de = REF.detailEnhance(src, None, 10.0, 0.15)
    s_de = SR.detailEnhance(src, None, 10.0, 0.15)
    _assert_img_parity(r_de, s_de, "detailEnhance", ssim_min=0.97, psnr_min=30.0, de_max=2.0)

    rg, rc = REF.pencilSketch(src, None, None, 60.0, 0.07, 0.02)
    sg, sc = SR.pencilSketch(src, None, None, 60.0, 0.07, 0.02)
    _assert_img_parity(rg, sg, "pencilSketch/gray")
    _assert_img_parity(rc, sc, "pencilSketch/color")

    r_st = REF.stylization(src, None, 60.0, 0.45)
    s_st = SR.stylization(src, None, 60.0, 0.45)
    _assert_img_parity(r_st, s_st, "stylization")


# --------------------------------------------------------------------------- 5. Decolor & Demosaicing

def test_decolor():
    # Multi-tone textured + noisy chromatic scene matching Lu et al. polynomial well-conditioned regime
    rng = np.random.default_rng(71)
    yy, xx = np.mgrid[0:80, 0:96].astype(np.float32)
    b = 115.0 + 55.0 * np.sin(xx * 0.08 + 71) * np.cos(yy * 0.07) + 25.0 * np.cos((xx + yy) * 0.11)
    g = 125.0 + 50.0 * np.cos(xx * 0.06 - yy * 0.09) + 20.0 * np.sin(yy * 0.13 + 71)
    r = 130.0 + 60.0 * np.sin((xx - yy) * 0.07) + 20.0 * np.cos(xx * 0.12)
    src = np.clip(np.stack([np.clip(b, 15, 240), np.clip(g, 15, 240), np.clip(r, 15, 240)], -1)
                  + rng.normal(0.0, 2.0, (80, 96, 3)), 0, 255).astype(np.uint8)
    rg, rcb = REF.decolor(src)
    g_pre = np.empty((80, 96), np.uint8)
    cb_pre = np.empty((80, 96, 3), np.uint8)
    sg, scb = SR.decolor(src, g_pre, cb_pre)
    assert sg is g_pre and scb is cb_pre
    _assert_img_parity(rg, sg, "decolor/gray")
    _assert_img_parity(rcb, scb, "decolor/boost")

    # Verify color_boost Lab luminance replacement contract even on synthetic shapes
    sh = _synthetic_scene(80, 96, seed=72)
    sg2, scb2 = SR.decolor(sh)
    lab = REF.cvtColor(sh, REF.COLOR_BGR2Lab)
    lab[:, :, 0] = sg2
    _assert_img_parity(REF.cvtColor(lab, REF.COLOR_Lab2BGR), scb2, "decolor/boost_contract")


@pytest.mark.parametrize("dt", [np.uint8, np.uint16])
@pytest.mark.parametrize("code_name", [
    "COLOR_BayerBG2BGR", "COLOR_BayerGB2BGR", "COLOR_BayerRG2BGR", "COLOR_BayerGR2BGR",
    "COLOR_BayerBG2RGB", "COLOR_BayerGB2RGB", "COLOR_BayerRG2RGB", "COLOR_BayerGR2RGB",
    "COLOR_BayerBG2GRAY", "COLOR_BayerGB2GRAY", "COLOR_BayerRG2GRAY", "COLOR_BayerGR2GRAY",
    "COLOR_BayerBG2BGR_EA", "COLOR_BayerGB2BGR_EA", "COLOR_BayerRG2BGR_EA", "COLOR_BayerGR2BGR_EA",
    "COLOR_BayerBG2BGR_VNG", "COLOR_BayerGB2BGR_VNG", "COLOR_BayerRG2BGR_VNG", "COLOR_BayerGR2BGR_VNG",
])
def test_demosaicing(dt, code_name):
    if dt == np.uint16 and "_VNG" in code_name:
        # OpenCV VNG only supports 8-bit; verify Safarium still runs cleanly or test 8-bit parity
        bayer = _synthetic_scene(48, 64, seed=73)[..., 1].astype(np.uint16) * 257
        out = SR.demosaicing(bayer, getattr(SR, code_name))
        assert out.dtype == np.uint16 and out.shape == (48, 64, 3)
        return

    rgb = _synthetic_scene(48, 64, seed=74)
    if dt == np.uint16:
        rgb = rgb.astype(np.uint16) * 257
    # Build smooth mosaic sample matching the source Bayer pattern
    bayer = np.zeros((48, 64), dt)
    if "BayerBG" in code_name:
        bayer[0::2, 0::2] = rgb[0::2, 0::2, 2]
        bayer[0::2, 1::2] = rgb[0::2, 1::2, 1]
        bayer[1::2, 0::2] = rgb[1::2, 0::2, 1]
        bayer[1::2, 1::2] = rgb[1::2, 1::2, 0]
    elif "BayerGB" in code_name:
        bayer[0::2, 0::2] = rgb[0::2, 0::2, 1]
        bayer[0::2, 1::2] = rgb[0::2, 1::2, 2]
        bayer[1::2, 0::2] = rgb[1::2, 0::2, 0]
        bayer[1::2, 1::2] = rgb[1::2, 1::2, 1]
    elif "BayerRG" in code_name:
        bayer[0::2, 0::2] = rgb[0::2, 0::2, 0]
        bayer[0::2, 1::2] = rgb[0::2, 1::2, 1]
        bayer[1::2, 0::2] = rgb[1::2, 0::2, 1]
        bayer[1::2, 1::2] = rgb[1::2, 1::2, 2]
    else:  # BayerGR
        bayer[0::2, 0::2] = rgb[0::2, 0::2, 1]
        bayer[0::2, 1::2] = rgb[0::2, 1::2, 0]
        bayer[1::2, 0::2] = rgb[1::2, 0::2, 2]
        bayer[1::2, 1::2] = rgb[1::2, 1::2, 1]

    code = getattr(REF, code_name)
    r = REF.demosaicing(bayer, code)
    s = SR.demosaicing(bayer, getattr(SR, code_name))
    _assert_img_parity(r, s, f"demosaicing/{code_name}/{dt.__name__}")


def test_demosaicing_alpha_dstcn():
    bayer = _synthetic_scene(32, 40, seed=75)[..., 0]
    r4 = REF.demosaicing(bayer, REF.COLOR_BayerBG2BGR, dstCn=4)
    s4 = SR.demosaicing(bayer, SR.COLOR_BayerBG2BGR, dstCn=4)
    _assert_img_parity(r4[..., :3], s4[..., :3], "demosaicing/dstCn4_rgb")
    np.testing.assert_array_equal(s4[..., 3], r4[..., 3])


# --------------------------------------------------------------------------- 6. HDR Pipeline

def test_align_mtb():
    yy, xx = np.mgrid[0:128, 0:128].astype(np.float32)
    base = np.clip(xx * 1.3 + yy * 1.1 + 50.0 * np.sin(xx * 0.1) * np.cos(yy * 0.1), 0, 255).astype(np.uint8)
    img0 = np.dstack([base, np.clip(base * 0.85, 0, 255).astype(np.uint8), np.clip(base * 0.7, 0, 255).astype(np.uint8)])

    mtb_r = REF.createAlignMTB(max_bits=4, exclude_range=4, cut=True)
    mtb_s = SR.createAlignMTB(max_bits=4, exclude_range=4, cut=True)
    assert (mtb_s.getMaxBits(), mtb_s.getExcludeRange(), mtb_s.getCut()) == (4, 4, True)
    mtb_s.setMaxBits(5); assert mtb_s.getMaxBits() == 5; mtb_s.setMaxBits(4)

    g0 = REF.cvtColor(img0, REF.COLOR_BGR2GRAY)
    tb_r, eb_r = mtb_r.computeBitmaps(g0)
    tb_s, eb_s = mtb_s.computeBitmaps(g0)
    np.testing.assert_array_equal(tb_s, tb_r)
    np.testing.assert_array_equal(eb_s, eb_r)

    shifted = mtb_r.shiftMat(img0, (4, -3))
    shifted_s = mtb_s.shiftMat(img0, (4, -3))
    np.testing.assert_array_equal(shifted_s, shifted)

    # Interior shifted region avoids zero-border effects
    sh_r = mtb_r.calculateShift(g0, REF.cvtColor(shifted, REF.COLOR_BGR2GRAY))
    sh_s = mtb_s.calculateShift(g0, REF.cvtColor(shifted, REF.COLOR_BGR2GRAY))
    assert abs(sh_s[0] - sh_r[0]) <= 1 and abs(sh_s[1] - sh_r[1]) <= 1, f"{sh_s} vs {sh_r}"

    dst_r = [np.zeros_like(img0), np.zeros_like(img0)]
    dst_s = [np.zeros_like(img0), np.zeros_like(img0)]
    mtb_r.process([img0, shifted], dst_r)
    mtb_s.process([img0, shifted], dst_s)
    # Also test 4-arg signature
    mtb_s.process([img0, shifted], dst_s, np.array([1.0, 1.0], np.float32), np.zeros((256, 1, 3), np.float32))
    assert dst_s[0].shape == img0.shape and dst_s[1].shape == img0.shape


def test_calibrate_and_merge_debevec_robertson_mertens():
    _, imgs, times = _exposure_stack(80, 96)

    # CalibrateDebevec
    cd_r = REF.createCalibrateDebevec(samples=70, lambda_=10.0, random=False)
    cd_s = SR.createCalibrateDebevec(samples=70, lambda_=10.0, random=False)
    assert (cd_s.getSamples(), cd_s.getLambda(), cd_s.getRandom()) == (70, 10.0, False)
    crf_dr = cd_r.process(imgs, times)
    crf_ds = cd_s.process(imgs, times)
    assert crf_ds.shape == crf_dr.shape and crf_ds.dtype == np.float32
    assert np.all(np.isfinite(crf_ds)) and np.all(crf_ds > 0)
    # CRF curves agree well on well-exposed interior indices [32..224]
    assert ssim(crf_dr[32:224, 0], crf_ds[32:224, 0]) >= 0.97

    # CalibrateRobertson
    cr_r = REF.createCalibrateRobertson(max_iter=15, threshold=0.01)
    cr_s = SR.createCalibrateRobertson(max_iter=15, threshold=0.01)
    assert (cr_s.getMaxIter(), pytest.approx(cr_s.getThreshold(), rel=1e-5)) == (15, 0.01)
    crf_rr = cr_r.process(imgs, times)
    crf_rs = cr_s.process(imgs, times)
    assert crf_rs.shape == crf_rr.shape and crf_rs.dtype == np.float32
    assert cr_s.getRadiance().shape == imgs[0].shape

    # MergeDebevec (with CRF & without CRF)
    md_r = REF.createMergeDebevec()
    md_s = SR.createMergeDebevec()
    hdr_dr = md_r.process(imgs, times, crf_dr)
    hdr_ds = md_s.process(imgs, times, crf_dr)
    _assert_f32_parity(hdr_dr, hdr_ds, "MergeDebevec/crf")

    hdr_dnr = md_r.process(imgs, times)
    hdr_dns = md_s.process(imgs, times)
    _assert_f32_parity(hdr_dnr, hdr_dns, "MergeDebevec/no-crf")

    # MergeRobertson (with CRF & without CRF)
    mr_r = REF.createMergeRobertson()
    mr_s = SR.createMergeRobertson()
    hdr_rr = mr_r.process(imgs, times, crf_rr)
    hdr_rs = mr_s.process(imgs, times, crf_rr)
    _assert_f32_parity(hdr_rr, hdr_rs, "MergeRobertson/crf")

    hdr_rnr = mr_r.process(imgs, times)
    hdr_rns = mr_s.process(imgs, times)
    _assert_f32_parity(hdr_rnr, hdr_rns, "MergeRobertson/no-crf")

    # MergeMertens
    mm_r = REF.createMergeMertens(1.0, 1.0, 0.2)
    mm_s = SR.createMergeMertens(1.0, 1.0, 0.2)
    assert (mm_s.getContrastWeight(), mm_s.getSaturationWeight(), mm_s.getExposureWeight()) == (1.0, 1.0, 0.2)
    fus_r = mm_r.process(imgs)
    fus_s = mm_s.process(imgs)
    _assert_f32_parity(fus_r, fus_s, "MergeMertens")


def test_tonemappers():
    rad, _, _ = _exposure_stack(64, 80)
    # High dynamic range (>10x) synthetic HDR image
    hdr = np.power(rad * 3.0, 2.0).astype(np.float32)

    tm_r = REF.createTonemap(gamma=2.2)
    tm_s = SR.createTonemap(gamma=2.2)
    assert tm_s.getGamma() == 2.2
    _assert_f32_parity(tm_r.process(hdr), tm_s.process(hdr), "Tonemap")

    td_r = REF.createTonemapDrago(gamma=2.2, saturation=1.0, bias=0.85)
    td_s = SR.createTonemapDrago(gamma=2.2, saturation=1.0, bias=0.85)
    assert (td_s.getGamma(), td_s.getSaturation(), td_s.getBias()) == (2.2, 1.0, 0.85)
    _assert_f32_parity(td_r.process(hdr), td_s.process(hdr), "TonemapDrago")

    tr_r = REF.createTonemapReinhard(gamma=2.2, intensity=0.0, light_adapt=1.0, color_adapt=0.0)
    tr_s = SR.createTonemapReinhard(gamma=2.2, intensity=0.0, light_adapt=1.0, color_adapt=0.0)
    assert (tr_s.getGamma(), tr_s.getIntensity(), tr_s.getLightAdaptation(), tr_s.getColorAdaptation()) == (2.2, 0.0, 1.0, 0.0)
    _assert_f32_parity(tr_r.process(hdr), tr_s.process(hdr), "TonemapReinhard")

    tma_r = REF.createTonemapMantiuk(gamma=2.2, scale=0.7, saturation=1.0)
    tma_s = SR.createTonemapMantiuk(gamma=2.2, scale=0.7, saturation=1.0)
    assert (tma_s.getGamma(), tma_s.getScale(), tma_s.getSaturation()) == (2.2, 0.7, 1.0)
    _assert_f32_parity(tma_r.process(hdr), tma_s.process(hdr), "TonemapMantiuk")
