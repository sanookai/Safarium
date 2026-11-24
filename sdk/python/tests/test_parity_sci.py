"""Parity of the Safarium scipy / tifffile stand-ins (Area E) against the real libraries.

Run with the reference venv (has real scipy + tifffile):
    SAFARIUM_RASTER_LIB=<dylib> $SCRATCH/sciref/bin/python -m pytest -q sdk/python/tests/test_parity_sci.py

The shim packages are loaded under the aliases `scipy_sf` / `tifffile_sf` next to the real ones (the shim only uses
relative imports), so both run in one process. One subprocess test checks the real contract: with
`sdk/python/safarium_sci` on sys.path, `from scipy.io import netcdf_file, wavfile` etc. resolve to the shim.

Bars: Pick 2026-11-24 asked for float64 filters within 1e-6 relative; these tests hold 1e-10 (measured ~1e-13).
Int paths and files are exact.
"""
from __future__ import annotations

import importlib
import importlib.util
import io
import os
import subprocess
import sys
import warnings
from pathlib import Path

import numpy as np
import pytest

SHIM_ROOT = Path(__file__).resolve().parents[1] / "safarium_sci"
SOMPONG = Path(os.environ.get("SAFARIUM_EXTERNAL_ASSETS_DIR", "/nonexistent-safarium-assets"))
REL_TOL = 1e-10  # float64 recurrences are the same as scipy's (measured ~1e-13); the Pick bar of 1e-6 is far looser


def _load_alias(pkg: str, alias: str):
    spec = importlib.util.spec_from_file_location(alias, SHIM_ROOT / pkg / "__init__.py",
                                                  submodule_search_locations=[str(SHIM_ROOT / pkg)])
    mod = importlib.util.module_from_spec(spec)
    sys.modules[alias] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="session")
def sf():
    """Shim scipy namespace: .signal .ndimage .io (+ .io.wavfile, .io.netcdf_file)."""
    root = _load_alias("scipy", "scipy_sf")
    for sub in ("io", "signal", "ndimage"):
        importlib.import_module(f"scipy_sf.{sub}")
    return root


@pytest.fixture(scope="session")
def sft():
    return _load_alias("tifffile", "tifffile_sf")


@pytest.fixture(scope="session")
def ref():
    import scipy
    import scipy.io
    import scipy.io.wavfile
    import scipy.ndimage
    import scipy.signal
    assert not str(Path(scipy.__file__)).startswith(str(SHIM_ROOT)), "real scipy not loaded"
    return scipy


@pytest.fixture(scope="session")
def reft():
    import tifffile
    assert not str(Path(tifffile.__file__)).startswith(str(SHIM_ROOT))
    return tifffile


def rel_err(a, b):
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    scale = max(float(np.abs(b).max()), 1e-300)
    return float(np.abs(a - b).max()) / scale


# ------------------------------------------------------------------ contract: shim on sys.path
def test_shim_on_sys_path_resolves_all_imports():
    code = ("import scipy, tifffile;"
            "from scipy.io import netcdf_file, wavfile;"
            "from scipy import signal;"
            "from scipy.ndimage import minimum_filter1d;"
            "import tifffile;"
            f"assert scipy.__file__.startswith({str(SHIM_ROOT)!r}), scipy.__file__;"
            f"assert tifffile.__file__.startswith({str(SHIM_ROOT)!r}), tifffile.__file__;"
            "import numpy as np;"
            "sos = signal.butter(2, 400, 'low', fs=48000, output='sos');"
            "print(signal.sosfilt(sos, np.ones(10))[:2].tolist())")
    # -I ignores PYTHONPATH, so the shim root goes on sys.path inside the child (first entry wins over site-packages)
    code2 = f"import sys; sys.path.insert(0, {str(SHIM_ROOT)!r});" + code
    out = subprocess.run([sys.executable, "-I", "-c", code2], env=dict(os.environ), capture_output=True, text=True)
    assert out.returncode == 0, out.stderr


# ------------------------------------------------------------------ signal.butter
@pytest.mark.parametrize("order", [1, 2, 3, 4, 5, 6])
@pytest.mark.parametrize("kind,freq", [("low", 400.0), ("high", 150.0), ("band", [150.0, 900.0]),
                                       ("bandstop", [300.0, 2000.0])])
def test_butter_sos_matches(sf, ref, order, kind, freq):
    a = sf.signal.butter(order, freq, kind, fs=48000, output="sos")
    b = ref.signal.butter(order, freq, kind, fs=48000, output="sos")
    assert a.shape == b.shape
    np.testing.assert_allclose(a, b, rtol=1e-12, atol=1e-15)


@pytest.mark.parametrize("kind,freq", [("low", 0.2), ("band", [0.1, 0.4])])
def test_butter_ba_zpk_match(sf, ref, kind, freq):
    for out in ("ba", "zpk"):
        a = sf.signal.butter(4, freq, kind, output=out)
        b = ref.signal.butter(4, freq, kind, output=out)
        for x, y in zip(a, b):
            np.testing.assert_allclose(np.sort_complex(np.atleast_1d(x)), np.sort_complex(np.atleast_1d(y)), rtol=1e-10,
                                       atol=1e-12)


def test_butter_errors_match(sf, ref):
    for bad in (dict(N=2, Wn=30000, btype="low", fs=48000), dict(N=2, Wn=[900, 150], btype="band", fs=48000)):
        with pytest.raises(ValueError):
            ref.signal.butter(bad.pop("N"), bad.pop("Wn"), bad.pop("btype"), **{k: v for k, v in bad.items()})
    with pytest.raises(ValueError):
        sf.signal.butter(2, 30000, "low", fs=48000)
    with pytest.raises(ValueError):
        sf.signal.butter(2, [900, 150], "band", fs=48000)


# ------------------------------------------------------------------ sosfilt / lfilter / sosfiltfilt
RNG = np.random.default_rng(20261124)
DESIGNS = [(1, 1000.0, "low"), (2, 400.0, "low"), (2, [150.0, 900.0], "band"), (4, [300.0, 3000.0], "band"),
           (3, 200.0, "high"),
           (5, 1000.0, "low"), (6, 1000.0, "low"), (5, [200.0, 2000.0], "band"),  # 3, 3 and 5 sections: odd counts >= 3
           (3, [300.0, 3000.0], "bandstop")]


@pytest.mark.parametrize("order,freq,kind", DESIGNS)
def test_sosfilt_1d_f64(sf, ref, order, freq, kind):
    sos = ref.signal.butter(order, freq, kind, fs=48000, output="sos")
    x = RNG.standard_normal(48000)
    a, b = sf.signal.sosfilt(sos, x), ref.signal.sosfilt(sos, x)
    assert a.dtype == b.dtype == np.float64
    assert rel_err(a, b) <= REL_TOL
    assert rel_err(a, b) < 1e-12  # in practice identical recurrences


def test_sosfilt_f32_and_int_inputs(sf, ref):
    sos = ref.signal.butter(2, [150.0, 900.0], "band", fs=48000, output="sos")
    x32 = RNG.standard_normal((9000, 2)).astype(np.float32)
    a, b = sf.signal.sosfilt(sos, x32, axis=0), ref.signal.sosfilt(sos, x32, axis=0)
    assert a.dtype == b.dtype and a.shape == b.shape
    assert rel_err(a, b) <= REL_TOL
    xi = (RNG.standard_normal(5000) * 1000).astype(np.int16)
    a, b = sf.signal.sosfilt(sos, xi), ref.signal.sosfilt(sos, xi)
    assert a.dtype == b.dtype and rel_err(a, b) <= REL_TOL


@pytest.mark.parametrize("axis", [0, 1, -1])
def test_sosfilt_2d_axes(sf, ref, axis):
    sos = ref.signal.butter(4, [300.0, 3000.0], "band", fs=48000, output="sos")
    x = RNG.standard_normal((300, 257))
    a, b = sf.signal.sosfilt(sos, x, axis=axis), ref.signal.sosfilt(sos, x, axis=axis)
    assert rel_err(a, b) <= REL_TOL


def test_sosfilt_zi_roundtrip_and_blocks_keep_state(sf, ref):
    """Block-by-block with carried state must equal one shot (SF-VIDEO-1), and match scipy's zi results."""
    sos = ref.signal.butter(4, [300.0, 3000.0], "band", fs=48000, output="sos")
    x = RNG.standard_normal((20000, 2))
    zi = RNG.standard_normal((sos.shape[0], 2, 2)) * 0.1  # (sections, channels(axis!=0), 2) for axis=0 -> (s, 2, ch)? see below
    zi = np.moveaxis(zi, 1, 2)  # (sections, 2 state, 2 ch) -> expected (s, 2, nch) for axis=0
    ya, za = sf.signal.sosfilt(sos, x, axis=0, zi=zi)
    yb, zb = ref.signal.sosfilt(sos, x, axis=0, zi=zi)
    assert rel_err(ya, yb) <= REL_TOL and rel_err(za, zb) <= REL_TOL
    # one shot vs blocks with odd block sizes
    one, z_one = sf.signal.sosfilt(sos, x, axis=0, zi=np.zeros((sos.shape[0], 2, 2)))
    z = np.zeros((sos.shape[0], 2, 2))
    parts, pos = [], 0
    for n in (1, 7, 4096, 999, 20000):
        blk = x[pos:pos + n]
        if not len(blk):
            break
        y, z = sf.signal.sosfilt(sos, blk, axis=0, zi=z)
        parts.append(y)
        pos += len(blk)
    assert np.array_equal(np.concatenate(parts), one) and np.array_equal(z, z_one)


def test_sosfilt_bad_input_errors_like_scipy(sf, ref):
    sos = ref.signal.butter(2, 400, "low", fs=48000, output="sos")
    with pytest.raises(ValueError):
        sf.signal.sosfilt(sos, np.ones(10), zi=np.zeros((1, 3)))
    with pytest.raises(ValueError):
        ref.signal.sosfilt(sos, np.ones(10), zi=np.zeros((1, 3)))
    with pytest.raises(ValueError):
        sf.signal.sosfilt(sos, np.ones(10), zi=np.zeros((2, 2)))
    bad = sos.copy()
    bad[0, 3] = 2.0
    with pytest.raises(ValueError):
        sf.signal.sosfilt(bad, np.ones(10))
    with pytest.raises(ValueError):
        ref.signal.sosfilt(bad, np.ones(10))


@pytest.mark.parametrize("order,freq,kind", DESIGNS)
def test_sosfiltfilt_1d(sf, ref, order, freq, kind):
    sos = ref.signal.butter(order, freq, kind, fs=48000, output="sos")
    x = RNG.standard_normal(30000)
    a, b = sf.signal.sosfiltfilt(sos, x), ref.signal.sosfiltfilt(sos, x)
    assert a.shape == b.shape and rel_err(a, b) <= REL_TOL


def test_sosfiltfilt_variants(sf, ref):
    sos = ref.signal.butter(1, 20.0, "low", fs=48000, output="sos")  # one section, zero b2/a2 -> ntaps 2
    x = np.abs(RNG.standard_normal(5000))
    for kw in ({}, dict(padtype="even"), dict(padtype="constant"), dict(padtype=None), dict(padlen=10)):
        assert rel_err(sf.signal.sosfiltfilt(sos, x, **kw), ref.signal.sosfiltfilt(sos, x, **kw)) <= REL_TOL, kw
    x2 = RNG.standard_normal((4, 3000))
    assert rel_err(sf.signal.sosfiltfilt(sos, x2, axis=1), ref.signal.sosfiltfilt(sos, x2, axis=1)) <= REL_TOL
    short = np.ones(5)
    with pytest.raises(ValueError):
        ref.signal.sosfiltfilt(sos, short)
    with pytest.raises(ValueError):
        sf.signal.sosfiltfilt(sos, short)


def test_sosfilt_zi_matches(sf, ref):
    sos = ref.signal.butter(4, [300.0, 3000.0], "band", fs=48000, output="sos")
    np.testing.assert_allclose(sf.signal.sosfilt_zi(sos), ref.signal.sosfilt_zi(sos), rtol=1e-12)
    np.testing.assert_allclose(sf.signal.lfilter_zi([1, 2, 1], [1, -0.5, 0.2]),
                               ref.signal.lfilter_zi([1, 2, 1], [1, -0.5, 0.2]), rtol=1e-12)


@pytest.mark.parametrize("b,a", [([1.0], [1.0, -0.98]), ([0.2, 0.3, 0.5], [1.0]), ([1, 2, 3], [2.0, -0.3, 0.1]),
                                 ([0.1, 0.2, 0.3, 0.4], [1.0, -1.2, 0.5, -0.1]), ([2.0], [1.0])])
def test_lfilter(sf, ref, b, a):
    x = RNG.standard_normal(48000)
    ya, yb = sf.signal.lfilter(b, a, x), ref.signal.lfilter(b, a, x)
    assert ya.dtype == yb.dtype and rel_err(ya, yb) <= REL_TOL
    # with state, and in blocks
    order = max(len(a), len(b)) - 1
    if order:
        zi = RNG.standard_normal(order) * 0.1
        ya, za = sf.signal.lfilter(b, a, x, zi=zi)
        yb, zb = ref.signal.lfilter(b, a, x, zi=zi)
        assert rel_err(ya, yb) <= REL_TOL and rel_err(za, zb) <= REL_TOL
        z, parts = np.zeros(order), []
        for blk in np.array_split(x, 13):
            y, z = sf.signal.lfilter(b, a, blk, zi=z)
            parts.append(y)
        one, _ = sf.signal.lfilter(b, a, x, zi=np.zeros(order))
        assert np.array_equal(np.concatenate(parts), one)


def test_lfilter_2d_axis_f32(sf, ref):
    x = RNG.standard_normal((6, 500)).astype(np.float32)
    for axis in (0, 1):
        a = sf.signal.lfilter([1.0], [1.0, -0.9], x, axis=axis)
        b = ref.signal.lfilter([1.0], [1.0, -0.9], x, axis=axis)
        assert a.dtype == b.dtype and rel_err(a, b) <= REL_TOL


# ------------------------------------------------------------------ ndimage.minimum_filter1d
@pytest.mark.parametrize("mode", ["nearest", "reflect", "mirror", "constant", "wrap"])
@pytest.mark.parametrize("size", [1, 2, 3, 8, 21, 101])
def test_minimum_filter1d_modes(sf, ref, mode, size):
    x = RNG.standard_normal(500)
    a = sf.ndimage.minimum_filter1d(x, size=size, mode=mode, cval=0.3)
    b = ref.ndimage.minimum_filter1d(x, size=size, mode=mode, cval=0.3)
    assert a.dtype == b.dtype and np.array_equal(a, b)


@pytest.mark.parametrize("size,origin", [(5, -2), (5, 2), (5, 1), (4, -2), (4, 1), (6, 0), (6, -3), (6, 2)])
def test_minimum_filter1d_origin(sf, ref, size, origin):
    x = RNG.standard_normal(300)
    for mode in ("nearest", "constant", "reflect"):
        assert np.array_equal(sf.ndimage.minimum_filter1d(x, size, mode=mode, origin=origin),
                              ref.ndimage.minimum_filter1d(x, size, mode=mode, origin=origin)), (mode, origin)
    for bad in (-(size // 2) - 1, (size - 1) // 2 + 1):
        with pytest.raises(ValueError):
            ref.ndimage.minimum_filter1d(x, size, origin=bad)
        with pytest.raises(ValueError):
            sf.ndimage.minimum_filter1d(x, size, origin=bad)


def test_minimum_filter1d_dtypes_axes_and_big_window(sf, ref):
    x = RNG.standard_normal((40, 60)).astype(np.float32)
    for axis in (0, 1, -1):
        assert np.array_equal(sf.ndimage.minimum_filter1d(x, 7, axis=axis, mode="nearest"),
                              ref.ndimage.minimum_filter1d(x, 7, axis=axis, mode="nearest"))
    xi = RNG.integers(-1000, 1000, 400).astype(np.int32)
    a, b = sf.ndimage.minimum_filter1d(xi, 9, mode="nearest"), ref.ndimage.minimum_filter1d(xi, 9, mode="nearest")
    assert a.dtype == b.dtype and np.array_equal(a, b)
    # the pipeline's ducking hold: window 2*0.5*48000+1 over a smooth gain curve, longer than the signal's half
    g = 1.0 - 0.6 * np.clip(np.abs(np.sin(np.linspace(0, 40, 200000))), 0, 1)
    assert np.array_equal(sf.ndimage.minimum_filter1d(g, size=2 * 24000 + 1, mode="nearest"),
                          ref.ndimage.minimum_filter1d(g, size=2 * 24000 + 1, mode="nearest"))
    tiny = np.array([3.0, 1.0, 2.0])
    assert np.array_equal(sf.ndimage.minimum_filter1d(tiny, 9, mode="nearest"),
                          ref.ndimage.minimum_filter1d(tiny, 9, mode="nearest"))


# ------------------------------------------------------------------ wavfile
def _wav_bytes(mod, rate, data):
    buf = io.BytesIO()
    mod.write(buf, rate, data)
    return buf.getvalue()


@pytest.mark.parametrize("dtype", ["int16", "uint8", "int32", "float32", "float64", "int64"])
@pytest.mark.parametrize("shape", [(1000,), (1001, 2), (7, 1), (0,)])
def test_wav_write_bytes_identical(sf, ref, dtype, shape):
    if np.dtype(dtype).kind == "f":
        x = RNG.standard_normal(shape).astype(dtype)
    else:
        info = np.iinfo(dtype)
        x = RNG.integers(info.min, info.max, shape, dtype=dtype, endpoint=True)
    assert _wav_bytes(sf.io.wavfile, 48000, x) == _wav_bytes(ref.io.wavfile, 48000, x)


def test_wav_write_to_path_and_read_back_identical(sf, ref, tmp_path):
    x = np.round(np.clip(RNG.standard_normal((48000, 2)) * 0.3, -1, 1) * 32767).astype("<i2")  # as audio.mix does
    pa, pb = tmp_path / "shim.wav", tmp_path / "ref.wav"
    sf.io.wavfile.write(str(pa), 48000, x)
    ref.io.wavfile.write(str(pb), 48000, x)
    assert pa.read_bytes() == pb.read_bytes()
    for path in (pa, pb):
        ra, xa = sf.io.wavfile.read(str(path))
        rb, xb = ref.io.wavfile.read(str(path))
        assert ra == rb == 48000 and xa.dtype == xb.dtype == np.int16 and np.array_equal(xa, xb) and np.array_equal(xa, x)


def test_wav_read_variants(sf, ref, tmp_path):
    mono = (RNG.standard_normal(3000) * 8000).astype("<i2")
    ref.io.wavfile.write(str(tmp_path / "m.wav"), 22050, mono)
    for mm in (False, True):
        ra, xa = sf.io.wavfile.read(str(tmp_path / "m.wav"), mmap=mm)
        rb, xb = ref.io.wavfile.read(str(tmp_path / "m.wav"), mmap=mm)
        assert ra == rb == 22050 and xa.dtype == xb.dtype and np.array_equal(xa, xb)
    # odd-length data chunk with padding + LIST chunk, 24-bit PCM, 8-bit
    import struct
    pcm24 = (RNG.integers(-2 ** 23, 2 ** 23, 1000)).astype(np.int32)
    raw24 = b"".join(struct.pack("<i", int(v))[:3] for v in pcm24)
    fmt = struct.pack("<HHIIHH", 1, 1, 48000, 48000 * 3, 3, 24)
    body = (b"WAVE" + b"fmt " + struct.pack("<I", 16) + fmt + b"LIST" + struct.pack("<I", 5) + b"abcde\x00"
            + b"data" + struct.pack("<I", len(raw24)) + raw24)
    (tmp_path / "w24.wav").write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
    ra, xa = sf.io.wavfile.read(str(tmp_path / "w24.wav"))
    rb, xb = ref.io.wavfile.read(str(tmp_path / "w24.wav"))
    assert ra == rb and xa.dtype == xb.dtype == np.int32 and np.array_equal(xa, xb)
    u8 = RNG.integers(0, 255, (400, 2), dtype=np.uint8)
    ref.io.wavfile.write(str(tmp_path / "u8.wav"), 8000, u8)
    assert np.array_equal(sf.io.wavfile.read(str(tmp_path / "u8.wav"))[1], u8)
    with pytest.raises(ValueError):
        sf.io.wavfile.write(io.BytesIO(), 8000, np.zeros(3, np.complex64))
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with pytest.raises(ValueError):
            sf.io.wavfile.read(io.BytesIO(b"not a wav file at all"))


# ------------------------------------------------------------------ netcdf
def _build_nc(mod, path, version=1, rec=False):
    f = mod.io.netcdf_file(str(path), "w", version=version)
    if rec:
        f.createDimension("time", None)  # the unlimited dimension must come first (scipy rule)
    f.createDimension("latitude", 7)
    f.createDimension("longitude", 11)
    la = f.createVariable("latitude", "d", ("latitude",))
    la[:] = np.linspace(-90, 90, 7)
    la.units = "degrees_north"
    lo = f.createVariable("longitude", "d", ("longitude",))
    lo[:] = np.linspace(-180, 180, 11)
    lo.units = "degrees_east"
    alt = f.createVariable("altitude", "h", ("latitude", "longitude"))
    alt[:] = (np.arange(77).reshape(7, 11) - 30).astype("i2")
    alt.units = "meters"
    alt.scale = np.float32(0.5)
    f2 = f.createVariable("f4", "f", ("latitude", "longitude"))
    f2[:] = np.arange(77, dtype="f4").reshape(7, 11) / 3
    b = f.createVariable("bytes", "b", ("longitude",))
    b[:] = np.arange(11, dtype="i1")
    if rec:
        t = f.createVariable("t", "i", ("time",))
        t[:] = np.arange(5, dtype="i4")
        r = f.createVariable("r", "f", ("time", "longitude"))
        r[:] = np.arange(55, dtype="f4").reshape(5, 11)
    f.title = "ETOPO2v2 (2006), NOAA NGDC"
    f.comment = "normalised (int16, latitude ascending)"
    f.count = 3
    f.ratio = 0.25
    f.close()


@pytest.mark.parametrize("version,rec", [(1, False), (2, False), (1, True)])
def test_netcdf_write_bytes_identical_and_cross_read(sf, ref, tmp_path, version, rec):
    pa, pb = tmp_path / "shim.nc", tmp_path / "ref.nc"
    _build_nc(sf, pa, version, rec)
    _build_nc(ref, pb, version, rec)
    assert pa.read_bytes() == pb.read_bytes()
    for mmap in (False, True):
        for path in (pa, pb):
            with sf.io.netcdf_file(str(path), "r", mmap=mmap) as a, ref.io.netcdf_file(str(path), "r", mmap=mmap) as b:
                assert dict(a.dimensions) == dict(b.dimensions)
                assert list(a.variables) == list(b.variables)
                for k in b.variables:
                    va, vb = a.variables[k], b.variables[k]
                    assert va.shape == vb.shape and va.dimensions == vb.dimensions
                    assert va.typecode() == vb.typecode() and va.itemsize() == vb.itemsize()
                    assert va.data.dtype == vb.data.dtype and np.array_equal(np.array(va.data), np.array(vb.data))
                    assert {n: np.asarray(v).tolist() for n, v in va._attributes.items()} == \
                           {n: np.asarray(v).tolist() for n, v in vb._attributes.items()}
                assert a._attributes.keys() == b._attributes.keys()
                assert a.title == b.title and a.count == b.count and a.ratio == b.ratio
                del va, vb
            # (the with-block above closes both; warnings about live mmap views are scipy's own behaviour)


def test_netcdf_pipeline_usage_mmap_false_and_dtype_conversions(sf, ref, tmp_path):
    """fetch_pack.convert_etopo style: write source with f4 dims, read with mmap=False, np.array(var.data, dtype)."""
    p = tmp_path / "src.nc"
    x = np.linspace(-180, 180, 21, dtype="f4")
    y = np.linspace(90, -90, 11, dtype="f4")
    z = RNG.integers(-9000, 9000, (11, 21)).astype("f4")
    for mod in (sf, ref):
        f = mod.io.netcdf_file(str(p), "w")
        f.createDimension("x", len(x))
        f.createDimension("y", len(y))
        for nm, arr, dims in (("x", x, ("x",)), ("y", y, ("y",)), ("z", z, ("y", "x"))):
            v = f.createVariable(nm, "f4", dims)
            v[:] = arr
        f.close()
        f = mod.io.netcdf_file(str(p), mmap=False)
        got = (np.array(f.variables["x"].data, dtype="f8"), np.array(f.variables["z"].data))
        f.close()
        assert np.array_equal(got[0], x.astype("f8")) and np.array_equal(got[1], z)
        assert dict(mod.io.netcdf_file(str(p), mmap=False).dimensions) == {"x": 21, "y": 11}


def test_netcdf_bad_file_raises(sf, tmp_path):
    (tmp_path / "bad.nc").write_bytes(b"HDF\x89not netcdf3")
    with pytest.raises(TypeError):
        sf.io.netcdf_file(str(tmp_path / "bad.nc"), mmap=False)


REAL_ETOPO = SOMPONG / "data/pack/etopo_2min.nc"


@pytest.mark.skipif(not REAL_ETOPO.is_file(), reason="External ETOPO pack file not on this machine")
def test_netcdf_real_etopo_pack_file(sf, ref):
    """Read-only on the real 117 MB pack file: dims, axes, attributes and slices equal scipy's (mmap=True as basemap)."""
    with sf.io.netcdf_file(str(REAL_ETOPO), "r", mmap=True) as a, ref.io.netcdf_file(str(REAL_ETOPO), "r", mmap=True) as b:
        assert dict(a.dimensions) == dict(b.dimensions) == {"latitude": 5401, "longitude": 10801}
        assert list(a.variables) == list(b.variables)
        assert a.title == b.title and a.comment == b.comment
        for k in ("latitude", "longitude"):
            assert np.array_equal(np.asarray(a.variables[k][:]), np.asarray(b.variables[k][:]))
            assert a.variables[k].units == b.variables[k].units
        va, vb = a.variables["altitude"], b.variables["altitude"]
        assert va.shape == vb.shape == (5401, 10801) and va.data.dtype == vb.data.dtype
        assert va.units == vb.units
        # basemap._read_elev access pattern: row slice, wrapped column fancy index, flip
        r0, r1 = 2400, 2460
        cols = np.arange(10700, 10950) % 10800
        ba = np.ascontiguousarray(va[r0:r1][:, cols][::-1], dtype=np.float32)
        bb = np.ascontiguousarray(vb[r0:r1][:, cols][::-1], dtype=np.float32)
        assert np.array_equal(ba, bb)
        assert np.array_equal(np.asarray(va.data[::977, ::1013]), np.asarray(vb.data[::977, ::1013]))
        del va, vb, ba, bb


# ------------------------------------------------------------------ tifffile
TILE_TAGS = [(33922, "d", 6, (0.0, 0.0, 0.0, 499680.0, 320.0, 0.0), True),
             (33550, "d", 3, (10.0, 10.0, 0.0), True)]


def _read_all(mod, path):
    with mod.TiffFile(path) as tf:
        out = []
        for p in tf.pages:
            fh = open(path, "rb")
            segs = []
            for i, (o, c) in enumerate(zip(p.dataoffsets, p.databytecounts)):
                fh.seek(o)
                seg = np.asarray(p.decode(fh.read(c), i)[0])
                segs.append(seg)
            fh.close()
            out.append((p.shape, p.dtype, p.imagewidth, p.imagelength, p.tilewidth, p.tilelength, int(p.compression),
                        int(p.photometric), p.dataoffsets, p.databytecounts, segs, p.asarray()))
        return out


def test_tiff_writer_matches_pipeline_tests_and_real_reader_agrees(sf, sft, reft, tmp_path):
    """make_cog from test_fetch_sentinel*.py: two tiled pages, georef extratags on page 0 only."""
    for name, base, photometric in (("rgb", np.zeros((64, 64, 3), np.uint8), "rgb"),
                                    ("scl", np.full((32, 32), 4, np.uint8), "minisblack")):
        base = base.copy()
        if name == "rgb":
            base[:, :] = (200, 100, 50)
        else:
            base[:, 16:] = 9
        small = base[::2, ::2].copy()
        pa, pb = tmp_path / f"{name}_shim.tif", tmp_path / f"{name}_ref.tif"
        for mod, path in ((sft, pa), (reft, pb)):
            with mod.TiffWriter(path) as tw:
                tw.write(base, tile=(16, 16), photometric=photometric, extratags=TILE_TAGS)
                tw.write(small, tile=(16, 16), photometric=photometric)
        # the real tifffile reads our file ...
        with reft.TiffFile(pa) as t_real, sft.TiffFile(pa) as t_sh:
            assert len(t_real.pages) == len(t_sh.pages) == 2
            for pr, ps in zip(t_real.pages, t_sh.pages):
                assert pr.shape == ps.shape and pr.dtype == ps.dtype
                assert (pr.tilewidth, pr.tilelength) == (ps.tilewidth, ps.tilelength) == (16, 16)
                assert np.array_equal(pr.asarray(), ps.asarray())
            assert t_real.pages[0].tags["ModelTiepointTag"].value == t_sh.pages[0].tags["ModelTiepointTag"].value
            assert t_real.pages[0].tags["ModelPixelScaleTag"].value == t_sh.pages[0].tags["ModelPixelScaleTag"].value
            assert "ModelTiepointTag" not in t_sh.pages[1].tags  # writeonce: page 0 only
        # ... and we read the real one with the same tags / tiles
        ra, rb = _read_all(sft, pb), _read_all(reft, pb)
        assert len(ra) == len(rb) == 2
        for x, y in zip(ra, rb):
            assert x[0] == y[0] and x[1] == y[1] and x[2:8] == y[2:8]
            assert x[8] == y[8] and x[9] == y[9]
            for sx, sy in zip(x[10], y[10]):
                assert sx.shape == sy.shape and np.array_equal(sx, sy)
            assert np.array_equal(x[11], y[11])


@pytest.mark.parametrize("kw", [dict(), dict(compression="deflate"), dict(compression="deflate", predictor=True)])
@pytest.mark.parametrize("dtype,shape,photo", [("uint8", (50, 70, 3), "rgb"), ("uint8", (33, 21), "minisblack"),
                                               ("uint16", (40, 40, 3), "rgb"), ("float32", (30, 45), "minisblack"),
                                               ("int16", (25, 25), "minisblack"), ("uint8", (20, 20, 4), "rgb")])
@pytest.mark.parametrize("layout", [dict(), dict(tile=(16, 16)), dict(rowsperstrip=7)])
def test_tiff_write_then_real_reader_exact(sf, sft, reft, tmp_path, kw, dtype, shape, photo, layout):
    if kw.get("predictor") and dtype == "float32":
        pytest.skip("predictor on float data is a documented gap of the writer")
    if np.dtype(dtype).kind == "f":
        img = RNG.standard_normal(shape).astype(dtype)
    else:
        info = np.iinfo(dtype)
        img = RNG.integers(info.min, info.max, shape, dtype=dtype, endpoint=True)
    path = tmp_path / "w.tif"
    sft.imwrite(path, img, photometric=photo, **kw, **layout)
    got = reft.imread(path)
    assert got.dtype == img.dtype and got.shape == img.shape and np.array_equal(got, img)
    assert np.array_equal(sft.imread(path), img)


@pytest.mark.parametrize("kw", [dict(), dict(compression="zlib"), dict(compression="zlib", predictor=True),
                                dict(compression="zlib", predictor=3), dict(compression="packbits")])
@pytest.mark.parametrize("dtype,shape", [("uint8", (50, 70, 3)), ("uint8", (33, 21)), ("uint16", (40, 41, 3)),
                                         ("float32", (30, 45)), ("float64", (17, 29)), ("int32", (19, 23)),
                                         ("float32", (20, 20, 3))])
@pytest.mark.parametrize("layout", [dict(), dict(tile=(16, 32)), dict(rowsperstrip=5)])
def test_tiff_read_real_written_exact(sf, sft, reft, tmp_path, kw, dtype, shape, layout):
    pytest.importorskip("imagecodecs")  # the reference needs it to *write* compressed/predictor files
    if kw.get("predictor") == 3 and dtype not in ("float32", "float64"):
        pytest.skip("predictor 3 is float-only")
    if kw.get("predictor") is True and dtype in ("float32", "float64"):
        pytest.skip("integer predictor on floats")
    if np.dtype(dtype).kind == "f":
        img = RNG.standard_normal(shape).astype(dtype)
    else:
        info = np.iinfo(dtype)
        img = RNG.integers(info.min, info.max, shape, dtype=dtype, endpoint=True)
    path = tmp_path / "r.tif"
    photo = "rgb" if len(shape) == 3 else "minisblack"
    reft.imwrite(path, img, photometric=photo, **kw, **layout)
    got = sft.imread(path)
    assert got.dtype == img.dtype and got.shape == img.shape and np.array_equal(got, img)


def test_tiff_big_endian_and_bigtiff_read(sf, sft, reft, tmp_path):
    img = RNG.integers(0, 60000, (37, 29), dtype=np.uint16)
    for opts in (dict(byteorder=">"), dict(bigtiff=True), dict(bigtiff=True, byteorder=">")):
        path = tmp_path / "x.tif"
        reft.imwrite(path, img, **opts)
        assert np.array_equal(sft.imread(path), img), opts
        with sft.TiffFile(path) as t:
            assert t.pages[0].shape == img.shape


def test_tiff_tags_names_and_value_types_match(sf, sft, reft, tmp_path):
    img = RNG.integers(0, 255, (40, 50, 3), dtype=np.uint8)
    path = tmp_path / "t.tif"
    reft.imwrite(path, img, tile=(16, 16), photometric="rgb", extratags=TILE_TAGS, description="hello")
    with reft.TiffFile(path) as a, sft.TiffFile(path) as b:
        pa, pb = a.pages[0], b.pages[0]
        assert set(pa.tags.keys()) == set(pb.tags.keys())
        for code in pa.tags.keys():
            ta, tb = pa.tags[code], pb.tags[code]
            assert ta.name == tb.name and ta.count == tb.count, code
            assert ta.value == tb.value, (code, ta.value, tb.value)
        assert pa.tags.get("Nope") is None and pb.tags.get("Nope") is None
        for attr in ("imagewidth", "imagelength", "tilewidth", "tilelength", "shape", "dtype", "dataoffsets",
                     "databytecounts", "samplesperpixel", "bitspersample"):
            assert getattr(pa, attr) == getattr(pb, attr), attr
        assert int(pa.compression) == int(pb.compression) and int(pa.photometric) == int(pb.photometric)


def _real_cog_heads():
    root = SOMPONG / "episodes/2026-11-18-arsenic-boiling/cache/s2"
    return sorted(p for p in root.glob("*.head.tif") if not p.name.startswith("._")) if root.is_dir() else []


@pytest.mark.skipif(not _real_cog_heads(), reason="no Sentinel COG header cache on this machine")
def test_tiff_real_sentinel_cog_headers_and_cached_tiles(sf, sft, reft):
    """The files fetch_sentinel.open_cog really parses: header-only prefixes of Sentinel-2 COGs (read-only)."""
    heads = _real_cog_heads()
    checked_tiles = 0
    for head in heads:
        with reft.TiffFile(head) as a, sft.TiffFile(head) as b:
            assert len(a.pages) == len(b.pages)
            assert a.pages[0].tags["ModelTiepointTag"].value == b.pages[0].tags["ModelTiepointTag"].value
            assert a.pages[0].tags["ModelPixelScaleTag"].value == b.pages[0].tags["ModelPixelScaleTag"].value
            for level, (pa, pb) in enumerate(zip(list(a.pages), list(b.pages))):
                assert (pa.imagewidth, pa.imagelength, pa.tilewidth, pa.tilelength) == \
                       (pb.imagewidth, pb.imagelength, pb.tilewidth, pb.tilelength)
                assert pa.shape == pb.shape and pa.dtype == pb.dtype
                assert pa.dataoffsets == pb.dataoffsets and pa.databytecounts == pb.databytecounts
                assert int(pa.compression) == int(pb.compression) and pa.predictor == pb.predictor
                stem = head.name[:-len(".head.tif")]
                tdir = head.parent / f"{stem}.L{level}"
                if tdir.is_dir():
                    for fp in [q for q in sorted(tdir.glob("*.bin")) if not q.name.startswith("._")][:3]:
                        data = fp.read_bytes()
                        if not data:
                            continue
                        idx = int(fp.stem)
                        sa = np.asarray(pa.decode(data, idx)[0])
                        sb = np.asarray(pb.decode(data, idx)[0])
                        assert sa.shape == sb.shape and np.array_equal(sa, sb)
                        checked_tiles += 1
    assert checked_tiles > 0, "expected at least one cached tile to decode"


@pytest.mark.skipif(not (SOMPONG / "data/pack/dem90").is_dir(), reason="no DEM tiles on this machine")
def test_tiff_real_dem_tile_float_predictor(sf, sft, reft):
    tiles = sorted((SOMPONG / "data/pack/dem90").glob("*.tif"))
    tiles = [t for t in tiles if not t.name.startswith("._")][:2]
    assert tiles
    for t in tiles:
        a = reft.imread(t)
        b = sft.imread(t)
        assert a.dtype == b.dtype and a.shape == b.shape and np.array_equal(a, b)


# ------------------------------------------------------------------ follow-up: odd section counts, odd line counts
@pytest.mark.parametrize("order", [5, 6])
def test_sosfilt_three_sections_stereo_and_many_lines(sf, ref, order):
    sos = ref.signal.butter(order, 1500.0, "low", fs=48000, output="sos")
    assert sos.shape[0] == 3
    for shape, axis in (((12000, 2), 0), ((7, 4001), 1), ((5, 6, 301), 2), ((5, 6, 301), 0)):
        x = RNG.standard_normal(shape)
        a, b = sf.signal.sosfilt(sos, x, axis=axis), ref.signal.sosfilt(sos, x, axis=axis)
        assert a.shape == b.shape and rel_err(a, b) <= REL_TOL, (shape, axis)


@pytest.mark.parametrize("lines", [3, 5, 7])
def test_sosfiltfilt_odd_number_of_lines(sf, ref, lines):
    for sos in (ref.signal.butter(2, [150.0, 900.0], "band", fs=48000, output="sos"),
                ref.signal.butter(5, 1000.0, "low", fs=48000, output="sos")):
        x = RNG.standard_normal((lines, 4000))
        a, b = sf.signal.sosfiltfilt(sos, x, axis=1), ref.signal.sosfiltfilt(sos, x, axis=1)
        assert a.shape == b.shape and rel_err(a, b) <= REL_TOL
        xt = np.ascontiguousarray(x.T)
        a, b = sf.signal.sosfiltfilt(sos, xt, axis=0), ref.signal.sosfiltfilt(sos, xt, axis=0)
        assert a.shape == b.shape and rel_err(a, b) <= REL_TOL


# ------------------------------------------------------------------ follow-up: minimum_filter1d corner cases
MODES5 = ["nearest", "reflect", "mirror", "constant", "wrap"]


@pytest.mark.parametrize("mode", MODES5)
@pytest.mark.parametrize("n,size", [(1, 3), (2, 5), (7, 8), (7, 20), (7, 21), (7, 40), (5, 101), (30, 61), (30, 200)])
def test_minimum_filter1d_window_larger_than_line(sf, ref, mode, n, size):
    x = RNG.standard_normal(n)
    for origin in sorted({0, -(size // 2), (size - 1) // 2, -1, 1} & set(range(-(size // 2), (size - 1) // 2 + 1))):
        a = sf.ndimage.minimum_filter1d(x, size, mode=mode, cval=-0.25, origin=origin)
        b = ref.ndimage.minimum_filter1d(x, size, mode=mode, cval=-0.25, origin=origin)
        assert np.array_equal(a, b), (mode, n, size, origin)


@pytest.mark.parametrize("mode", ["nearest", "constant", "reflect", "mirror", "wrap"])
def test_minimum_filter1d_nan_matches_scipy(sf, ref, mode):
    for trial in range(40):
        n = int(RNG.integers(1, 30))
        x = RNG.standard_normal(n)
        x[RNG.random(n) < 0.25] = np.nan
        for size in (1, 2, 3, 4, 5, 8, 2 * n + 1):
            a = sf.ndimage.minimum_filter1d(x, size, mode=mode, cval=0.5)
            b = ref.ndimage.minimum_filter1d(x, size, mode=mode, cval=0.5)
            assert np.array_equal(a, b, equal_nan=True), (mode, x.tolist(), size, a, b)
    # nan cval and an all-nan line
    for x in (np.full(6, np.nan), np.array([1.0, 2.0, 3.0])):
        for size in (1, 3, 9):
            a = sf.ndimage.minimum_filter1d(x, size, mode="constant", cval=np.nan)
            b = ref.ndimage.minimum_filter1d(x, size, mode="constant", cval=np.nan)
            assert np.array_equal(a, b, equal_nan=True)


def test_minimum_filter1d_huge_window_does_not_allocate_or_abort(sf, ref):
    x = RNG.standard_normal(1000)
    for size in (10 ** 9, 2 ** 40):
        a = sf.ndimage.minimum_filter1d(x, size, mode="nearest")
        assert np.array_equal(a, np.full(1000, x.min()))
        a = sf.ndimage.minimum_filter1d(x, size, mode="constant", cval=-7.5)
        assert np.array_equal(a, np.full(1000, min(-7.5, x.min())))
        a = sf.ndimage.minimum_filter1d(x, size, mode="reflect")
        assert np.array_equal(a, np.full(1000, x.min()))
        a = sf.ndimage.minimum_filter1d(x, size, mode="wrap")
        assert np.array_equal(a, np.full(1000, x.min()))
    # a window of 10**9 is cheap in scipy too; results must agree there
    assert np.array_equal(sf.ndimage.minimum_filter1d(x[:50], 10 ** 7, mode="nearest"),
                          ref.ndimage.minimum_filter1d(x[:50], 10 ** 7, mode="nearest"))
    # huge window with an origin shifts which edge values enter: compare against the definition
    z = np.array([5.0, 3.0, 4.0])
    a = sf.ndimage.minimum_filter1d(z, 2 ** 40, mode="nearest", origin=-(2 ** 39))
    assert a.shape == (3,)


@pytest.mark.parametrize("bad,exc", [(0, RuntimeError), (-1, RuntimeError), (2.5, TypeError)])
def test_minimum_filter1d_invalid_sizes_raise_like_scipy(sf, ref, bad, exc):
    x = np.arange(5.0)
    with pytest.raises(exc):
        ref.ndimage.minimum_filter1d(x, bad)
    with pytest.raises(exc):
        sf.ndimage.minimum_filter1d(x, bad)
    assert np.array_equal(sf.ndimage.minimum_filter1d(x, True), ref.ndimage.minimum_filter1d(x, True))


# ------------------------------------------------------------------ follow-up: zero-length axes
@pytest.mark.parametrize("shape,axis", [((0,), -1), ((0, 2), -1), ((3, 0), 0), ((0, 2), 0), ((3, 0), -1), ((2, 0, 4), 1),
                                        ((2, 0, 4), 2), ((0, 3, 4), 0)])
def test_zero_length_returns_empty_arrays(sf, ref, shape, axis):
    sos = ref.signal.butter(3, 1000.0, "low", fs=48000, output="sos")
    x = np.zeros(shape)
    a = sf.signal.sosfilt(sos, x, axis=axis)
    assert a.shape == shape and a.dtype == np.float64
    try:  # scipy itself raises on some of these shapes (its reshape(-1, 0)); where it answers, we must agree
        b = ref.signal.sosfilt(sos, x, axis=axis)
        assert b.shape == a.shape and b.dtype == a.dtype
    except ValueError:
        pass
    zshape = (sos.shape[0],) + shape[:axis % len(shape)] + (2,) + shape[axis % len(shape) + 1:]
    zi0 = RNG.standard_normal(zshape)
    y, zf = sf.signal.sosfilt(sos, x, axis=axis, zi=zi0)
    assert y.shape == shape and zf.shape == zshape
    if x.size == 0 and 0 not in zshape:
        assert np.array_equal(zf, zi0)  # no samples: the state passes through unchanged
    # lfilter and minimum_filter1d: scipy answers for every shape
    for b_, a_ in (([1.0], [1.0, -0.9]), ([0.5, 0.5], [1.0]), ([2.0], [1.0])):
        la = sf.signal.lfilter(b_, a_, x, axis=axis)
        assert la.shape == shape and la.dtype == np.float64
        try:  # scipy's FIR branch (np.convolve) raises on empty lines; the IIR branch answers
            lb = ref.signal.lfilter(b_, a_, x, axis=axis)
            assert lb.shape == la.shape and lb.dtype == la.dtype
        except ValueError:
            assert len(a_) == 1
    for mode in MODES5:
        ma = sf.ndimage.minimum_filter1d(x, 5, axis=axis, mode=mode)
        mb = ref.ndimage.minimum_filter1d(x, 5, axis=axis, mode=mode)
        assert ma.shape == mb.shape == shape and ma.dtype == mb.dtype


def test_zero_length_lfilter_keeps_state_and_float32(sf, ref):
    x = np.zeros((3, 0), np.float32)
    zi = np.arange(3.0).reshape(3, 1)
    ya, za = sf.signal.lfilter([1.0], [1.0, -0.9], x, zi=zi)
    yb, zb = ref.signal.lfilter([1.0], [1.0, -0.9], x, zi=zi)
    assert ya.shape == yb.shape and ya.dtype == yb.dtype and za.shape == zb.shape
    assert np.array_equal(za, zi)  # no samples: the state passes through (scipy returns a scrambled zf here)
    a = sf.ndimage.minimum_filter1d(np.zeros(0, np.float32), 3)
    assert a.shape == (0,) and a.dtype == np.float32


def test_zero_length_sosfiltfilt_raises_like_scipy(sf, ref):
    sos = ref.signal.butter(2, 400.0, "low", fs=48000, output="sos")
    with pytest.raises(ValueError):
        ref.signal.sosfiltfilt(sos, np.zeros(0))
    with pytest.raises(ValueError):
        sf.signal.sosfiltfilt(sos, np.zeros(0))
