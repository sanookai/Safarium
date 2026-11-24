"""scipy.io.wavfile stand-in: read/write PCM (8/16/24/32/64-bit) and IEEE-float WAV, RIFF/RIFX/RF64.

`write` emits the same bytes as SciPy (RIFF header, fmt chunk, fact chunk for float, data chunk); `read` returns the
same arrays (uint8 / int16 / int32 for 24-bit, left-justified / int32 / int64 / float32 / float64). Pure numpy: the
file is a straight byte copy, no DSP involved.
"""
from __future__ import annotations

import io
import struct
import sys
import warnings
from enum import IntEnum

import numpy as np

__all__ = ["WavFileWarning", "read", "write"]


class WavFileWarning(UserWarning):
    pass


class WAVE_FORMAT(IntEnum):
    PCM = 0x0001
    IEEE_FLOAT = 0x0003
    EXTENSIBLE = 0xFFFE


_KNOWN = (WAVE_FORMAT.PCM, WAVE_FORMAT.IEEE_FLOAT, WAVE_FORMAT.EXTENSIBLE)


def _bad_format(tag):
    try:
        name = WAVE_FORMAT(tag).name
    except ValueError:
        name = f"{tag:#06x}"
    raise ValueError(f"Unknown wave file format: {name}. Supported formats: " + ", ".join(x.name for x in _KNOWN))


def _pad(fid, size):
    if size % 2:
        fid.seek(1, 1)


def _read_fmt(fid, big):
    e = ">" if big else "<"
    size = struct.unpack(e + "I", fid.read(4))[0]
    if size < 16:
        raise ValueError("Binary structure of wave file is not compliant")
    tag, channels, fs, bps, block_align, bits = struct.unpack(e + "HHIIHH", fid.read(16))
    read_n = 16
    if tag == WAVE_FORMAT.EXTENSIBLE and size >= 18:
        ext = struct.unpack(e + "H", fid.read(2))[0]
        read_n += 2
        if ext >= 22:
            data = fid.read(22)
            read_n += 22
            guid = data[6:22]
            tail = (b"\x00\x00\x00\x10\x80\x00\x00\xAA\x00\x38\x9B\x71" if big
                    else b"\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71")
            if guid.endswith(tail):
                tag = struct.unpack(e + "I", guid[:4])[0]
        else:
            raise ValueError("Binary structure of wave file is not compliant")
    if tag not in _KNOWN:
        _bad_format(tag)
    if size > read_n:
        fid.read(size - read_n)
    _pad(fid, size)
    if tag == WAVE_FORMAT.PCM and bps != fs * block_align:
        raise ValueError("WAV header is invalid: nAvgBytesPerSec must equal product of nSamplesPerSec and nBlockAlign, "
                         f"but file has nSamplesPerSec = {fs}, nBlockAlign = {block_align}, and nAvgBytesPerSec = {bps}")
    return tag, channels, fs, block_align, bits


def _read_data(fid, tag, channels, bits, big, rf64, block_align, mmap, rf64_size):
    e = ">" if big else "<"
    if not rf64:
        size = struct.unpack(e + "I", fid.read(4))[0]
    else:
        size = rf64_size
        fid.read(4)
    bps = block_align // channels
    n_samples = size // bps
    if tag == WAVE_FORMAT.PCM:
        if 1 <= bits <= 8:
            dtype = "u1"
        elif bps in {3, 5, 6, 7}:
            dtype = "V1"
        elif bits <= 64:
            dtype = f"{e}i{bps}"
        else:
            raise ValueError(f"Unsupported bit depth: the WAV file has {bits}-bit integer data.")
    elif tag == WAVE_FORMAT.IEEE_FLOAT:
        if bits in {32, 64}:
            dtype = f"{e}f{bps}"
        else:
            raise ValueError(f"Unsupported bit depth: the WAV file has {bits}-bit floating-point data.")
    else:
        _bad_format(tag)
    start = fid.tell()
    if not mmap:
        count = size if dtype == "V1" else n_samples
        try:
            data = np.fromfile(fid, dtype=dtype, count=count)
        except (io.UnsupportedOperation, AttributeError, OSError):
            fid.seek(start, 0)
            data = np.frombuffer(fid.read(size), dtype=dtype)
        if dtype == "V1":
            dt = f"{e}i4" if bps == 3 else f"{e}i8"
            a = np.zeros((len(data) // bps, np.dtype(dt).itemsize), dtype="V1")
            if big:
                a[:, :bps] = data.reshape((-1, bps))
            else:
                a[:, -bps:] = data.reshape((-1, bps))
            data = a.view(dt).reshape(a.shape[:-1])
    else:
        if bps in {1, 2, 4, 8}:
            data = np.memmap(fid, dtype=dtype, mode="c", offset=start, shape=(n_samples,))
            fid.seek(start + size)
        else:
            raise ValueError(f"mmap=True not compatible with {bps}-byte container size.")
    _pad(fid, size)
    if channels > 1:
        data = data.reshape(-1, channels)
    return data


def _skip(fid, big):
    d = fid.read(4)
    if d:
        size = struct.unpack(">I" if big else "<I", d)[0]
        fid.seek(size, 1)
        _pad(fid, size)


def _riff(fid):
    sig = fid.read(4)
    if sig == b"RIFF":
        rf64, big, fmt = False, False, "<I"
    elif sig == b"RIFX":
        rf64, big, fmt = False, True, ">I"
    elif sig == b"RF64":
        rf64, big, fmt = True, False, "<Q"
    else:
        raise ValueError(f"File format {sig!r} not understood. Only 'RIFF', 'RIFX', and 'RF64' supported.")
    if not rf64:
        file_size = struct.unpack(fmt, fid.read(4))[0] + 8
        rf64_size = None
        form = fid.read(4)
    else:
        fid.read(4)
        form = fid.read(4)
        if fid.read(4) != b"ds64":
            raise ValueError("Invalid RF64 file: ds64 chunk not found.")
        ds64 = struct.unpack("<I", fid.read(4))[0]
        file_size = struct.unpack(fmt, fid.read(8))[0] + 8
        rf64_size = struct.unpack("<Q", fid.read(8))[0]
        fid.seek(ds64 - 16, 1)
    if form != b"WAVE":
        raise ValueError(f"Not a WAV file. RIFF form type is {form!r}.")
    return file_size, big, rf64, rf64_size


def read(filename, mmap=False):
    """Return (sample_rate, data). `filename` is a path or a seekable binary file object."""
    if hasattr(filename, "read"):
        fid, mmap = filename, False
    else:
        fid = open(filename, "rb")
    try:
        file_size, big, rf64, rf64_size = _riff(fid)
        fmt_seen = data_seen = False
        data = None
        while fid.tell() < file_size:
            cid = fid.read(4)
            if not cid:
                if data_seen:
                    warnings.warn(f"Reached EOF prematurely; finished at {fid.tell():d} bytes, expected "
                                  f"{file_size:d} bytes from header.", WavFileWarning, stacklevel=2)
                    break
                raise ValueError("Unexpected end of file.")
            if len(cid) < 4:
                msg = f"Incomplete chunk ID: {cid!r}"
                if fmt_seen and data_seen:
                    warnings.warn(msg + ", ignoring it.", WavFileWarning, stacklevel=2)
                else:
                    raise ValueError(msg)
            if cid == b"fmt ":
                fmt_seen = True
                tag, channels, fs, block_align, bits = _read_fmt(fid, big)
            elif cid == b"data":
                data_seen = True
                if not fmt_seen:
                    raise ValueError("No fmt chunk before data")
                data = _read_data(fid, tag, channels, bits, big, rf64, block_align, mmap, rf64_size)
            elif cid in (b"fact", b"LIST", b"JUNK", b"Fake"):
                _skip(fid, big)
            else:
                warnings.warn("Chunk (non-data) not understood, skipping it.", WavFileWarning, stacklevel=2)
                _skip(fid, big)
    finally:
        if not hasattr(filename, "read"):
            fid.close()
        else:
            fid.seek(0)
    return fs, data


def write(filename, rate, data):
    """Write `data` (1-D mono or (n, channels)) as WAV; dtypes float32/float64/uint8/int16/int32/int64."""
    if hasattr(filename, "write"):
        fid = filename
    else:
        fid = open(filename, "wb")
    fs = rate
    try:
        kind = data.dtype.kind
        if data.dtype.name not in ("float32", "float64", "uint8", "int16", "int32", "int64"):
            raise ValueError(f"Unsupported data type '{data.dtype}'")
        head = b"RIFF" + b"\x00\x00\x00\x00" + b"WAVE" + b"fmt "
        tag = WAVE_FORMAT.IEEE_FLOAT if kind == "f" else WAVE_FORMAT.PCM
        channels = 1 if data.ndim == 1 else data.shape[1]
        bits = data.dtype.itemsize * 8
        bps = fs * (bits // 8) * channels
        align = channels * (bits // 8)
        fmt = struct.pack("<HHIIHH", tag, channels, fs, bps, align, bits)
        if kind not in "iu":
            fmt += b"\x00\x00"
        head += struct.pack("<I", len(fmt)) + fmt
        is_rf64 = (len(head) + 4 + 4 + data.nbytes - 8) > 0xFFFFFFFF
        if is_rf64:
            head = (b"RF64" + b"\xFF\xFF\xFF\xFF" + b"WAVE" + b"ds64" + struct.pack("<I", 28) + struct.pack("<Q", 0)
                    + struct.pack("<Q", data.nbytes) + struct.pack("<Q", data.shape[0]) + struct.pack("<I", 0)
                    + b"fmt " + struct.pack("<I", len(fmt)) + fmt)
        if kind not in "iu":
            head += b"fact" + struct.pack("<II", 4, data.shape[0])
        fid.write(head)
        fid.write(b"data")
        fid.write(struct.pack("<I", min(data.nbytes, 4294967295)))
        if data.dtype.byteorder == ">" or (data.dtype.byteorder == "=" and sys.byteorder == "big"):
            data = data.byteswap()
        fid.write(np.ascontiguousarray(data).ravel().view("b").data)
        size = fid.tell()
        if not is_rf64:
            fid.seek(4)
            fid.write(struct.pack("<I", size - 8))
        else:
            fid.seek(20)
            fid.write(struct.pack("<Q", size - 8))
    finally:
        if not hasattr(filename, "write"):
            fid.close()
        else:
            fid.seek(0)
