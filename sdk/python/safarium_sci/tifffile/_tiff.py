"""TIFF reader/writer core for the tifffile stand-in. See package docstring for scope."""
from __future__ import annotations

import enum
import io
import os
import struct
import zlib

import numpy as np

__all__ = ["COMPRESSION", "PHOTOMETRIC", "TiffFile", "TiffFileError", "TiffPage", "TiffPages", "TiffTag", "TiffTags",
           "TiffWriter", "imread", "imwrite"]


class TiffFileError(Exception):
    pass


class COMPRESSION(enum.IntEnum):
    NONE = 1
    LZW = 5
    JPEG = 7
    ADOBE_DEFLATE = 8
    PACKBITS = 32773
    DEFLATE = 32946


class PHOTOMETRIC(enum.IntEnum):
    MINISWHITE = 0
    MINISBLACK = 1
    RGB = 2
    PALETTE = 3
    MASK = 4
    SEPARATED = 5
    YCBCR = 6


class PLANARCONFIG(enum.IntEnum):
    CONTIG = 1
    SEPARATE = 2


_ENUMS = {259: COMPRESSION, 262: PHOTOMETRIC, 284: PLANARCONFIG}

TAG_NAMES = {
    254: "NewSubfileType", 255: "SubfileType", 256: "ImageWidth", 257: "ImageLength", 258: "BitsPerSample",
    259: "Compression", 262: "PhotometricInterpretation", 266: "FillOrder", 269: "DocumentName",
    270: "ImageDescription", 271: "Make", 272: "Model", 273: "StripOffsets", 274: "Orientation",
    277: "SamplesPerPixel", 278: "RowsPerStrip", 279: "StripByteCounts", 282: "XResolution", 283: "YResolution",
    284: "PlanarConfiguration", 296: "ResolutionUnit", 305: "Software", 306: "DateTime", 317: "Predictor",
    320: "ColorMap", 322: "TileWidth", 323: "TileLength", 324: "TileOffsets", 325: "TileByteCounts",
    338: "ExtraSamples", 339: "SampleFormat", 347: "JPEGTables", 42112: "GDAL_METADATA", 42113: "GDAL_NODATA",
    33550: "ModelPixelScaleTag", 33922: "ModelTiepointTag", 34264: "ModelTransformationTag",
    34735: "GeoKeyDirectoryTag", 34736: "GeoDoubleParamsTag", 34737: "GeoAsciiParamsTag",
}
TAG_CODES = {v: k for k, v in TAG_NAMES.items()}

# TIFF type -> (struct format of one element, size)
_TYPES = {1: ("B", 1), 2: ("s", 1), 3: ("H", 2), 4: ("I", 4), 5: ("II", 8), 6: ("b", 1), 7: ("B", 1), 8: ("h", 2),
          9: ("i", 4), 10: ("ii", 8), 11: ("f", 4), 12: ("d", 8), 13: ("I", 4), 16: ("Q", 8), 17: ("q", 8),
          18: ("Q", 8)}
_STRUCT_TO_TYPE = {"B": 1, "s": 2, "H": 3, "I": 4, "2I": 5, "b": 6, "h": 8, "i": 9, "2i": 10, "f": 11, "d": 12,
                   "Q": 16, "q": 17}


class TiffTag:
    """One IFD entry: .code .name .dtype .count .value (scalar for count 1, tuple otherwise, str for ASCII)."""

    def __init__(self, code, dtype, count, value, offset=0):
        self.code, self.dtype, self.count, self.value, self.offset = code, dtype, count, value, offset

    @property
    def name(self):
        return TAG_NAMES.get(self.code, str(self.code))

    def __repr__(self):
        return f"TiffTag {self.code} {self.name} @{self.offset}"


class TiffTags:
    """Tags of one page, lookup by code or name; iterates like a dict view over codes."""

    def __init__(self):
        self._d = {}      # first tag per code (what tags[code] / tags[name] return)
        self._all = []    # every tag in file order, duplicates included (e.g. two ImageDescription entries)

    def _key(self, key):
        return TAG_CODES.get(key, key) if isinstance(key, str) else key

    def __getitem__(self, key):
        if isinstance(key, str) and key not in TAG_CODES:  # "ImageDescription1": the 2nd entry with that code
            for t in self._all[1:]:
                if t is not self._d.get(t.code) and f"{t.name}{self._dup_no(t)}" == key:
                    return t
        return self._d[self._key(key)]

    def _dup_no(self, tag):
        return 1 + [u for u in self._all if u.code == tag.code and u is not self._d.get(u.code)].index(tag)

    def __contains__(self, key):
        return self._key(key) in self._d

    def get(self, key, default=None):
        return self._d.get(self._key(key), default)

    def keys(self):
        return self._d.keys()

    def values(self):
        return list(self._all)

    def items(self):
        return self._d.items()

    def __iter__(self):
        return iter(self._d)

    def __len__(self):
        return len(self._d)


def _unpack_value(bo, ttype, count, raw):
    fmt, size = _TYPES[ttype]
    if ttype == 2:
        s = raw[:count].split(b"\x00")[0] if raw[:count].count(b"\x00") <= 1 else raw[:count].rstrip(b"\x00")
        return s.decode("latin-1")
    if ttype == 7:
        return bytes(raw[:count])
    n = count * len(fmt)
    vals = struct.unpack(bo + fmt[0] * n if len(fmt) == 1 else bo + fmt * count, raw[:count * size])
    if len(fmt) == 2:
        vals = tuple((vals[i], vals[i + 1]) for i in range(0, len(vals), 2))
    return vals[0] if count == 1 else tuple(vals)


class TiffPage:
    """One image (IFD). Attributes follow tifffile.TiffPage for what the pipeline needs."""

    def __init__(self, parent, index, tags):
        self.parent, self.index, self.tags = parent, index, tags
        v = lambda name, d=None: (tags[name].value if name in tags else d)  # noqa: E731
        self.imagewidth = int(v("ImageWidth", 0))
        self.imagelength = int(v("ImageLength", 0))
        spp = int(v("SamplesPerPixel", 1))
        self.samplesperpixel = spp
        bps = v("BitsPerSample", 1)
        self.bitspersample = int(bps[0] if isinstance(bps, tuple) else bps)
        sf = v("SampleFormat", 1)
        self.sampleformat = int(sf[0] if isinstance(sf, tuple) else sf)
        self.compression = _enum(259, int(v("Compression", 1)))
        self.photometric = _enum(262, int(v("PhotometricInterpretation", 1)))
        self.planarconfig = _enum(284, int(v("PlanarConfiguration", 1)))
        self.predictor = int(v("Predictor", 1))
        self.tilewidth = int(v("TileWidth", 0))
        self.tilelength = int(v("TileLength", 0))
        self.is_tiled = self.tilewidth > 0
        rps = int(v("RowsPerStrip", self.imagelength)) if "RowsPerStrip" in tags else self.imagelength
        self.rowsperstrip = min(rps, self.imagelength) if rps else self.imagelength
        offs = tags.get("TileOffsets") or tags.get("StripOffsets")
        cnts = tags.get("TileByteCounts") or tags.get("StripByteCounts")
        self.dataoffsets = _tuple(offs.value if offs else ())
        self.databytecounts = _tuple(cnts.value if cnts else ())
        self.jpegtables = v("JPEGTables")
        self.dtype = self._dtype()
        self.shape = ((self.imagelength, self.imagewidth) if spp == 1
                      else (self.imagelength, self.imagewidth, spp))
        if self.planarconfig == 2 and spp > 1:
            self.shape = (spp, self.imagelength, self.imagewidth)
        self.ndim = len(self.shape)

    def _dtype(self):
        b = self.bitspersample
        kind = {1: "u", 2: "i", 3: "f"}.get(self.sampleformat)
        if kind is None or b not in (8, 16, 32, 64) or (kind == "f" and b not in (32, 64)):
            raise NotImplementedError(f"unsupported sample layout: {b}-bit, SampleFormat {self.sampleformat}")
        return np.dtype(f"{self.parent.byteorder}{kind}{b // 8}")

    def _segment_shape(self, index):
        spp = self.samplesperpixel
        if self.is_tiled:
            return (1, self.tilelength, self.tilewidth, spp)
        n = -(-self.imagelength // self.rowsperstrip)
        rows = self.rowsperstrip if index < n - 1 else self.imagelength - self.rowsperstrip * (n - 1)
        return (1, rows, self.imagewidth, spp)

    def decode(self, data, index, jpegtables=None, **_):
        """Decode one tile/strip -> (segment ndarray (1, h, w, samples), (sample, depth, row, col, 0), shape)."""
        if self.planarconfig == 2 and self.samplesperpixel > 1:
            raise NotImplementedError("planar-separate TIFF is not supported")
        shape = self._segment_shape(index)
        comp = int(self.compression)
        if comp == 1:
            raw = bytes(data)
        elif comp in (8, 32946):
            raw = zlib.decompress(bytes(data))
        elif comp == 32773:
            raw = _unpackbits(bytes(data))
        else:
            raise NotImplementedError(f"TIFF compression {comp} is not supported")
        dt = self.dtype
        need = int(np.prod(shape)) * dt.itemsize
        if len(raw) < need:
            raw = raw + b"\x00" * (need - len(raw))
        raw = raw[:need]
        h, w, spp = shape[1], shape[2], shape[3]
        if self.predictor == 2:
            seg = np.frombuffer(raw, dtype=dt).reshape(h, w, spp).copy()
            np.cumsum(seg, axis=1, dtype=seg.dtype, out=seg)
        elif self.predictor == 3:
            seg = _float_predictor_decode(raw, dt, h, w, spp)
        elif self.predictor == 1:
            seg = np.frombuffer(raw, dtype=dt).reshape(h, w, spp).copy()
        else:
            raise NotImplementedError(f"TIFF predictor {self.predictor} is not supported")
        seg = seg.reshape(shape)
        if self.is_tiled:
            tpr = -(-self.imagewidth // self.tilewidth)
            row, col = (index // tpr) * self.tilelength, (index % tpr) * self.tilewidth
        else:
            row, col = index * self.rowsperstrip, 0
        return seg, (0, 0, row, col, 0), shape

    def asarray(self):
        """Whole image (reads every segment from the parent file)."""
        fh = self.parent._fh
        out = np.zeros((self.imagelength, self.imagewidth, self.samplesperpixel), dtype=self.dtype)
        for i, (off, cnt) in enumerate(zip(self.dataoffsets, self.databytecounts)):
            if not cnt:
                continue
            fh.seek(off)
            data = fh.read(cnt)
            if len(data) < cnt:
                raise TiffFileError(f"segment {i} lies outside the file")
            seg, (_, _, r, c, _), shape = self.decode(data, i)
            hh = min(shape[1], self.imagelength - r)
            ww = min(shape[2], self.imagewidth - c)
            out[r:r + hh, c:c + ww] = seg[0, :hh, :ww]
        return out.reshape(self.shape) if self.samplesperpixel == 1 or self.ndim == 3 else out


def _enum(code, value):
    try:
        return _ENUMS[code](value)
    except ValueError:
        return value


def _tuple(v):
    return tuple(v) if isinstance(v, (tuple, list)) else (v,)


def _unpackbits(data):
    out = bytearray()
    i, n = 0, len(data)
    while i < n:
        c = data[i] if data[i] < 128 else data[i] - 256
        i += 1
        if c >= 0:
            out += data[i:i + c + 1]
            i += c + 1
        elif c != -128:
            out += data[i:i + 1] * (1 - c)
            i += 1
    return bytes(out)


def _float_predictor_decode(raw, dt, h, w, spp):
    """TIFF predictor 3 (floating point): per row, undo byte-wise differencing, then reassemble big-endian bytes."""
    isz = dt.itemsize
    rowbytes = w * spp * isz
    a = np.frombuffer(raw, dtype=np.uint8).reshape(h, rowbytes).copy()
    v = a.reshape(h, -1, spp)                     # byte differencing runs with a lag of one pixel (spp bytes)
    np.cumsum(v, axis=1, dtype=np.uint8, out=v)
    planes = a.reshape(h, isz, w * spp)           # byte plane 0 = most significant
    be = np.ascontiguousarray(planes.transpose(0, 2, 1))  # (h, w*spp, isz) big-endian per sample
    out = be.reshape(h, w * spp * isz).view(dt.newbyteorder(">"))
    return out.astype(dt, copy=False).reshape(h, w, spp)


class TiffPages:
    """Sequence of the pages of a file (list-like: len, [i], iteration)."""

    def __init__(self, pages):
        self._pages = pages

    def __len__(self):
        return len(self._pages)

    def __getitem__(self, i):
        return self._pages[i]

    def __iter__(self):
        return iter(self._pages)


class TiffFile:
    """Open a TIFF (path, Path, file object or bytes). Reads the IFD chain; pixel data is read on demand."""

    def __init__(self, arg, *, mode="rb", **_):
        if isinstance(arg, (bytes, bytearray, memoryview)):
            self._fh, self._own = io.BytesIO(bytes(arg)), True
        elif hasattr(arg, "read"):
            self._fh, self._own = arg, False
        else:
            self._fh, self._own = open(os.fspath(arg), "rb"), True
        try:
            self._parse()
        except Exception:
            self.close()
            raise

    def _parse(self):
        fh = self._fh
        head = fh.read(16)
        if head[:2] == b"II":
            bo = "<"
        elif head[:2] == b"MM":
            bo = ">"
        else:
            raise TiffFileError("not a TIFF file")
        version = struct.unpack(bo + "H", head[2:4])[0]
        if version == 42:
            self.is_bigtiff, off_fmt, osz, cnt_fmt, csz, esz = False, "I", 4, "H", 2, 12
            first = struct.unpack(bo + "I", head[4:8])[0]
        elif version == 43:
            self.is_bigtiff, off_fmt, osz, cnt_fmt, csz, esz = True, "Q", 8, "Q", 8, 20
            first = struct.unpack(bo + "Q", head[8:16])[0]
        else:
            raise TiffFileError(f"invalid TIFF version {version}")
        self.byteorder = bo
        pages, seen, off = [], set(), first
        while off and off not in seen:
            seen.add(off)
            fh.seek(off)
            raw = fh.read(csz)
            if len(raw) < csz:
                break
            n = struct.unpack(bo + cnt_fmt, raw)[0]
            body = fh.read(n * esz + osz)
            if len(body) < n * esz:
                raise TiffFileError("IFD is cut off by the end of the file")
            tags = TiffTags()
            for k in range(n):
                e = body[k * esz:(k + 1) * esz]
                code, ttype = struct.unpack(bo + "HH", e[:4])
                count = struct.unpack(bo + off_fmt, e[4:4 + osz])[0]
                if ttype not in _TYPES:
                    continue
                size = _TYPES[ttype][1] * count
                slot = e[4 + osz:4 + 2 * osz]
                voff = off + csz + k * esz + 4 + osz
                if size <= osz:
                    raw_v = slot[:size]
                else:
                    ptr = struct.unpack(bo + off_fmt, slot)[0]
                    pos = fh.tell()
                    fh.seek(ptr)
                    raw_v = fh.read(size)
                    fh.seek(pos)
                    voff = ptr
                    if len(raw_v) < size:
                        raise TiffFileError(f"tag {code} value lies outside the file")
                val = _unpack_value(bo, ttype, count, raw_v)
                tag = TiffTag(code, ttype, count, val, voff)
                tags._d.setdefault(code, tag)
                tags._all.append(tag)
            pages.append(TiffPage(self, len(pages), tags))
            nxt = body[n * esz:n * esz + osz]
            off = struct.unpack(bo + off_fmt, nxt)[0] if len(nxt) == osz else 0
        self.pages = TiffPages(pages)

    @property
    def filehandle(self):
        return self._fh

    def asarray(self, key=0, **_):
        return self.pages[key].asarray()

    def close(self):
        if getattr(self, "_own", False) and not self._fh.closed:
            self._fh.close()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass


def imread(files, *, key=None, **_):
    """Image data of page `key` (default: first page) as a numpy array."""
    with TiffFile(files) as tf:
        return tf.pages[0 if key is None else key].asarray()


# ---------------------------------------------------------------- writer
_PHOTO = {"miniswhite": 0, "minisblack": 1, "rgb": 2, "palette": 3, "separated": 5, "ycbcr": 6}


class TiffWriter:
    """Write classic little-endian TIFF pages: `with TiffWriter(path) as tw: tw.write(array, tile=(h, w), ...)`."""

    def __init__(self, file, *, bigtiff=False, byteorder=None, **_):
        if bigtiff:
            raise NotImplementedError("BigTIFF writing is not supported")
        self._own = not hasattr(file, "write")
        self._fh = open(os.fspath(file), "wb") if self._own else file
        self._fh.write(b"II*\x00\x00\x00\x00\x00")
        self._prev_next = 4  # file position of the "next IFD" pointer to patch
        self._pages = 0

    def write(self, data, *, photometric=None, tile=None, rowsperstrip=None, compression=None, predictor=None,
              extratags=(), description=None, extrasamples=None, software=None, resolution=None, metadata=None,
              contiguous=False, **_):
        if resolution is not None or contiguous:
            raise NotImplementedError("resolution / contiguous are not supported by this writer")
        data = np.asarray(data)
        if data.dtype.kind not in "uif" or data.dtype.itemsize not in (1, 2, 4, 8):
            raise ValueError(f"unsupported dtype {data.dtype}")
        if data.ndim == 2:
            h, w, spp = data.shape[0], data.shape[1], 1
            data = data.reshape(h, w, 1)
        elif data.ndim == 3:
            h, w, spp = data.shape
        else:
            raise ValueError("only 2-D (H, W) or 3-D (H, W, samples) arrays are supported")
        if photometric is None:
            photometric = "rgb" if (spp in (3, 4) and data.ndim == 3 and data.shape[2] in (3, 4)) else "minisblack"
        photo = _PHOTO[photometric.lower()] if isinstance(photometric, str) else int(photometric)
        comp = {None: 1, False: 1, "none": 1, 1: 1, "deflate": 8, "zlib": 8, 8: 8, 32946: 8,
                "adobe_deflate": 8}.get(compression.lower() if isinstance(compression, str) else compression)
        if comp is None:
            raise NotImplementedError(f"compression {compression!r} is not supported by this writer")
        pred = 1
        if predictor in (True, 2):
            if data.dtype.kind == "f":
                raise NotImplementedError("predictor on float data is not supported by this writer")
            pred = 2
        elif predictor not in (None, False, 1):
            raise NotImplementedError(f"predictor {predictor!r} is not supported by this writer")
        if pred == 2 and comp == 1:
            pred = 1
        dt = data.dtype.newbyteorder("<")
        arr = np.ascontiguousarray(data, dtype=dt)
        # ---- cut into segments
        segs = []
        if tile is not None:
            th, tw = tile
            for ty in range(-(-h // th)):
                for tx in range(-(-w // tw)):
                    t = np.zeros((th, tw, spp), dtype=dt)
                    blk = arr[ty * th:(ty + 1) * th, tx * tw:(tx + 1) * tw]
                    t[:blk.shape[0], :blk.shape[1]] = blk
                    segs.append(t)
        else:
            rps = rowsperstrip or max(1, min(h, 65536 // max(1, w * spp * dt.itemsize)))
            for r in range(0, h, rps):
                segs.append(arr[r:r + rps])
        blobs = []
        for s in segs:
            if pred == 2:
                s = s.copy()
                s[:, 1:] = np.diff(s, axis=1)  # wraps modulo dtype, as TIFF predictor 2 requires
            b = s.tobytes()
            blobs.append(zlib.compress(b, 6) if comp == 8 else b)
        # ---- tags
        tags = {}

        def put(code, ttype, vals):
            tags[code] = (ttype, tuple(vals) if not isinstance(vals, (bytes, str)) else vals)

        put(256, 4, [w])
        put(257, 4, [h])
        put(258, 3, [dt.itemsize * 8] * spp)
        put(259, 3, [comp])
        put(262, 3, [photo])
        if description is not None:
            put(270, 2, description)
        put(277, 3, [spp])
        put(284, 3, [1])
        if pred != 1:
            put(317, 3, [pred])
        if spp > 3 and photo == 2:
            put(338, 3, list(extrasamples) if extrasamples else [2] * (spp - 3))
        if dt.kind != "u":
            put(339, 3, [{"i": 2, "f": 3}[dt.kind]] * spp)
        if tile is not None:
            put(322, 4, [tile[1]])
            put(323, 4, [tile[0]])
        else:
            put(278, 4, [rps])
        tags[324 if tile is not None else 273] = (4, [0] * len(blobs))     # offsets, patched below
        tags[325 if tile is not None else 279] = (4, [len(b) for b in blobs])
        for code, dtype, count, value, writeonce in (_norm_extra(e) for e in extratags):
            if writeonce and self._pages > 0:
                continue
            ttype = dtype if isinstance(dtype, int) else _STRUCT_TO_TYPE[dtype]
            if ttype == 2:
                value = value if isinstance(value, (bytes, str)) else str(value)
            tags[code] = (ttype, value if isinstance(value, (bytes, str)) else _tuple(value))
        # ---- layout: IFD, out-of-line values, data
        fh = self._fh
        base = fh.seek(0, 2)
        if base % 2:
            fh.write(b"\x00")
            base += 1
        codes = sorted(tags)
        ifd_size = 2 + 12 * len(codes) + 4
        enc = {}
        for c in codes:
            ttype, vals = tags[c]
            enc[c] = (ttype, _encode(ttype, vals))
        extra_pos = base + ifd_size
        ool, ptrs = bytearray(), {}
        for c in codes:
            ttype, (count, raw) = enc[c]
            if len(raw) > 4:
                ptrs[c] = extra_pos + len(ool)
                ool += raw + (b"\x00" if len(raw) % 2 else b"")
        data_pos = extra_pos + len(ool)
        offs, p = [], data_pos
        for b in blobs:
            offs.append(p)
            p += len(b)
        ocode = 324 if tile is not None else 273
        enc[ocode] = (4, _encode(4, offs))
        # offsets array size is unchanged (same count), so ptrs stay valid; rebuild the out-of-line blob for it
        raw_off = enc[ocode][1][1]
        if ocode in ptrs:
            start = ptrs[ocode] - extra_pos
            ool[start:start + len(raw_off)] = raw_off
        ifd = bytearray(struct.pack("<H", len(codes)))
        for c in codes:
            ttype, (count, raw) = enc[c]
            if c in ptrs:
                slot = struct.pack("<I", ptrs[c])
            else:
                slot = raw.ljust(4, b"\x00")
            ifd += struct.pack("<HHI", c, ttype, count) + slot
        ifd += b"\x00\x00\x00\x00"
        fh.seek(self._prev_next)
        fh.write(struct.pack("<I", base))
        fh.seek(base)
        fh.write(bytes(ifd))
        fh.write(bytes(ool))
        for b in blobs:
            fh.write(b)
        self._prev_next = base + 2 + 12 * len(codes)
        self._pages += 1

    def close(self):
        if self._own and not self._fh.closed:
            self._fh.close()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def _norm_extra(e):
    code, dtype, count, value, writeonce = e
    return code, dtype, count, value, writeonce


def _encode(ttype, vals):
    """-> (count, little-endian bytes)."""
    fmt, size = _TYPES[ttype]
    if ttype == 2:
        b = vals.encode("latin-1") if isinstance(vals, str) else bytes(vals)
        b += b"\x00"
        return len(b), b
    if ttype == 7 and isinstance(vals, (bytes, bytearray)):
        return len(vals), bytes(vals)
    vals = _tuple(vals)
    if len(fmt) == 2:
        flat = [x for pair in vals for x in (pair if isinstance(pair, (tuple, list)) else (pair, 1))]
        return len(flat) // 2, struct.pack("<" + fmt[0] * len(flat), *flat)
    return len(vals), struct.pack("<" + fmt * len(vals), *vals)


def imwrite(file, data, **kwargs):
    """Write one image as a TIFF file (see TiffWriter.write for the options)."""
    with TiffWriter(file) as tw:
        tw.write(data, **kwargs)
