"""Area A (draw): cv2.circle / rectangle / line / polylines / fillPoly / ellipse / putText / getTextSize.

Python signatures follow OpenCV 4/5; drawing happens in place in libSafariumRaster and the same ndarray is returned.
Contract: Projects/Safarium/docs/raster-plan.md
"""
from __future__ import annotations

import ctypes
import os
import types

import numpy as np

from ._lib import (CSTR, F64, I32, IMG_ARGS, PF64, PI32, check, color4, declare, error, img_args, lib)

__all__ = ["circle", "rectangle", "line", "polylines", "fillPoly", "fillConvexPoly", "ellipse", "putText", "getTextSize", "safarium_circles",
           "arrowedLine", "drawMarker", "drawContours", "ellipse2Poly", "clipLine", "getFontScaleFromHeight",
           "FontFace", "FontFace_setBuiltinFont", "PUT_TEXT_ALIGN_LEFT", "PUT_TEXT_ALIGN_CENTER", "PUT_TEXT_ALIGN_RIGHT", "PUT_TEXT_ALIGN_MASK",
           "PUT_TEXT_ORIGIN_TL", "PUT_TEXT_ORIGIN_BL", "PUT_TEXT_WRAP",
           "MARKER_CROSS", "MARKER_TILTED_CROSS", "MARKER_STAR", "MARKER_DIAMOND", "MARKER_SQUARE", "MARKER_TRIANGLE_UP", "MARKER_TRIANGLE_DOWN"]

MARKER_CROSS, MARKER_TILTED_CROSS, MARKER_STAR, MARKER_DIAMOND, MARKER_SQUARE, MARKER_TRIANGLE_UP, MARKER_TRIANGLE_DOWN = range(7)
PUT_TEXT_ALIGN_LEFT, PUT_TEXT_ALIGN_CENTER, PUT_TEXT_ALIGN_RIGHT, PUT_TEXT_ALIGN_MASK = 0, 1, 2, 3
PUT_TEXT_ORIGIN_TL, PUT_TEXT_ORIGIN_BL, PUT_TEXT_WRAP = 0, 32, 128

_circle = declare("sr_draw_circle", IMG_ARGS + [I32, I32, I32, PF64, I32, I32, I32])
_ellipse = declare("sr_draw_ellipse", IMG_ARGS + [I32, I32, I32, I32, F64, F64, F64, PF64, I32, I32, I32])
_line = declare("sr_draw_line", IMG_ARGS + [I32, I32, I32, I32, PF64, I32, I32, I32])
_rect = declare("sr_draw_rectangle", IMG_ARGS + [I32, I32, I32, I32, PF64, I32, I32, I32])
_polylines = declare("sr_draw_polylines", IMG_ARGS + [PI32, PI32, I32, I32, PF64, I32, I32, I32])
_fillpoly = declare("sr_draw_fillpoly", IMG_ARGS + [PI32, PI32, I32, PF64, I32, I32, I32, I32, I32])
_puttext = declare("sr_draw_puttext", IMG_ARGS + [CSTR, I32, I32, I32, I32, F64, PF64, I32, I32, I32])
_circles = declare("sr_draw_circles", IMG_ARGS + [PI32, I32, PF64, I32, I32, I32, I32])
_textsize = declare("sr_text_size", [CSTR, I32, I32, F64, I32, PI32])
_arrowed = declare("sr_draw_arrowedline", IMG_ARGS + [I32, I32, I32, I32, PF64, I32, I32, I32, F64])
_marker = declare("sr_draw_marker", IMG_ARGS + [I32, I32, PF64, I32, I32, I32, I32])
_contours_fn = declare("sr_draw_contours", IMG_ARGS + [PI32, PI32, I32, PI32, I32, PF64, I32, I32, I32, I32, I32])
_font_load = declare("sr_font_load", [CSTR, I32])
_font_free = declare("sr_font_free", [I32], None)
_font_axis = declare("sr_font_axis", [I32, PI32])
_font_weight = declare("sr_font_weight", [I32, I32, I32])
_puttext_face = declare("sr_draw_puttext_face", IMG_ARGS + [CSTR, I32, I32, I32, PF64, I32, I32, I32, I32, I32, I32, I32, PI32])
_rect_face = declare("sr_text_rect_face", [I32, CSTR, I32, I32, I32, I32, I32, I32, I32, I32, I32, I32, PI32])
_e2p = declare("sr_ellipse2poly", [I32, I32, I32, I32, I32, I32, I32, I32, PI32, I32])


# OpenCV depth codes of the element types cv2's drawing accepts (int64 is rejected by OpenCV: "Bad argument")
_DEPTH_BY_CHAR = {"B": 0, "b": 1, "H": 2, "h": 3, "i": 4, "f": 5, "d": 6, "e": 7, "?": 9, "L": 10, "Q": 10, "I": 12}
_c_char = ctypes.c_char
_addressof = ctypes.addressof
_COLORS: dict = {}


_I32_MIN, _I32_MAX = -(2 ** 31), 2 ** 31 - 1


def _i(v):
    """cv2 integer parameter: ints and numpy integers only (floats raise TypeError like cv2), int32 range."""
    if type(v) is not int:
        if isinstance(v, (int, np.integer)) and not isinstance(v, (bool, np.bool_)):
            v = int(v)
        else:
            raise TypeError(f"expected an integer, got {type(v).__name__}")
    if v < _I32_MIN or v > _I32_MAX:
        raise OverflowError("integer does not fit in int32")
    return v


def _f(v):
    """cv2 double parameter: int / float / numpy real scalar."""
    if isinstance(v, (int, float, np.integer, np.floating)) and not isinstance(v, (bool, np.bool_)):
        return float(v)
    raise TypeError(f"expected a number, got {type(v).__name__}")


def _pt(p, what):
    try:
        x, y = p
    except Exception as exc:  # noqa: BLE001
        raise TypeError(f"{what} must be a sequence of two integers") from exc
    return _i(x), _i(y)


def _img(a):
    """Fast path of _lib.img_args for the hot drawing calls (u8/f32, 2-D or 3-D, pixel-contiguous rows).

    Returns None for images OpenCV treats as an empty Mat (2-D with zero width): the caller does nothing.
    Other zero-sized arrays raise like OpenCV ("Layout of the output array img is incompatible")."""
    if not isinstance(a, np.ndarray):
        raise TypeError("img must be a numpy.ndarray")
    depth = _DEPTH_BY_CHAR.get(a.dtype.char)
    nd = a.ndim
    if depth is None or nd < 2 or nd > 3:
        return img_args(a)
    if not a.flags.writeable:
        raise error("Layout of the output array img is incompatible with cv::Mat (read-only)")
    h, w = a.shape[0], a.shape[1]
    if h == 0 or w == 0:
        if nd == 2 and w == 0:
            return None
        raise error("Layout of the output array img is incompatible with cv::Mat (empty)")
    c = a.shape[2] if nd == 3 else 1
    st = a.strides
    isz = a.itemsize
    if (w > 1 and st[1] != c * isz) or (nd == 3 and c > 1 and st[2] != isz) or st[0] < 0:
        return img_args(a)  # raises the cv2-style layout error
    stride = st[0] if h > 1 else w * c * isz
    try:
        ptr = _addressof(_c_char.from_buffer(a))
    except (ValueError, TypeError):  # row-strided view
        ptr = a.ctypes.data
    return (ptr, w, h, stride, c, depth)


def _col_slow(color):
    """cv2 Scalar parsing: numbers (int/float, not numpy ints), sequences of <= 4 such numbers, or None."""
    if color is None:
        return color4(0)
    if isinstance(color, (list, tuple)):
        if len(color) > 4:
            raise error("Can't parse 'color': Scalar must have at most 4 elements")
        for v in color:
            if not isinstance(v, (int, float)):
                raise error("Can't parse 'color': Scalar elements must be numbers")
        return color4(color)
    if isinstance(color, (int, float)) and not isinstance(color, (np.integer, np.floating)) or isinstance(color, np.float64):
        return color4(color)
    raise error(f"Can't parse 'color': unsupported type {type(color).__name__}")


def _col(color):
    t = type(color)
    if t is int:
        arr = _COLORS.get(color)
        if arr is None:
            arr = _COLORS[color] = _col_slow(color)
        return arr
    if t is tuple:
        for v in color:                      # numpy scalars compare/hash equal to ints: keep them out of the cache
            tv = type(v)
            if tv is not int and tv is not float:
                return _col_slow(color)
        arr = _COLORS.get(color)
        if arr is None:
            arr = _col_slow(color)
            if len(_COLORS) < 512:
                _COLORS[color] = arr
        return arr
    return _col_slow(color)


def circle(img, center, radius, color, thickness=1, lineType=8, shift=0):
    a = _img(img)
    cx, cy = _pt(center, "center")
    args = (cx, cy, _i(radius), _col(color), _i(thickness), _i(lineType), _i(shift))
    if a is not None:
        check(_circle(*a, *args), "circle")
    return img


def line(img, pt1, pt2, color, thickness=1, lineType=8, shift=0):
    a = _img(img)
    x0, y0 = _pt(pt1, "pt1")
    x1, y1 = _pt(pt2, "pt2")
    args = (x0, y0, x1, y1, _col(color), _i(thickness), _i(lineType), _i(shift))
    if a is not None:
        check(_line(*a, *args), "line")
    return img


def rectangle(img, *args, **kwargs):
    """rectangle(img, pt1, pt2, color[, thickness[, lineType[, shift]]]) or rectangle(img, rec, color[, ...])."""
    a = _img(img)
    args = list(args)
    names_pt = ["pt1", "pt2", "color", "thickness", "lineType", "shift"]
    names_rec = ["rec", "color", "thickness", "lineType", "shift"]
    is_rec = "rec" in kwargs
    if not is_rec and args and "pt1" not in kwargs:
        try:
            is_rec = len(args[0]) == 4  # (x, y, w, h); a point has two entries
        except TypeError:
            is_rec = False
    names = names_rec if is_rec else names_pt
    vals = {n: v for n, v in zip(names, args)}
    for k, v in kwargs.items():
        if k not in names:
            raise TypeError(f"rectangle() got an unexpected keyword argument '{k}'")
        if k in vals:
            raise TypeError(f"rectangle() got multiple values for argument '{k}'")
        vals[k] = v
    if "color" not in vals:
        raise TypeError("rectangle() missing required argument 'color'")
    thickness, line_type, shift = _i(vals.get("thickness", 1)), _i(vals.get("lineType", 8)), _i(vals.get("shift", 0))
    if is_rec:
        x, y, w, h = (_i(v) for v in vals["rec"])
        if w <= 0 or h <= 0:
            return img
        x0, y0, x1, y1 = x, y, x + w - 1, y + h - 1
    else:
        if "pt1" not in vals or "pt2" not in vals:
            raise TypeError("rectangle() missing required argument 'pt1'/'pt2'")
        x0, y0 = _pt(vals["pt1"], "pt1")
        x1, y1 = _pt(vals["pt2"], "pt2")
    col = _col(vals["color"])
    if a is not None:
        check(_rect(*a, x0, y0, x1, y1, col, thickness, line_type, shift), "rectangle")
    return img


def _contours(pts):
    """List of (N,2)/(N,1,2) arrays (or one array) -> (flat int32 xy, counts int32)."""
    if isinstance(pts, np.ndarray):
        if pts.ndim == 3 and pts.shape[1] != 1 and pts.shape[-1] == 2:
            seq = [pts[i] for i in range(pts.shape[0])]
        else:
            seq = [pts]
    else:
        seq = list(pts)
        if seq and hasattr(seq[0], "__len__") and len(seq[0]) == 2 and np.isscalar(seq[0][0]):
            seq = [seq]  # a bare list of points
    arrs = []
    for s in seq:
        arr = np.asarray(s)
        if arr.size == 0:
            arr = arr.astype(np.int32)
        if arr.dtype.kind == "f":
            raise error("polygon points must be integer (int32); use np.round(...).astype(np.int32)")
        if arr.size % 2:
            raise error("polygon points must be (N, 2)")
        arrs.append(np.ascontiguousarray(arr.reshape(-1, 2), dtype=np.int32))
    counts = np.array([len(x) for x in arrs], dtype=np.int32)
    xy = np.ascontiguousarray(np.concatenate(arrs) if arrs else np.zeros((0, 2), np.int32), dtype=np.int32)
    return xy, counts


def polylines(img, pts, isClosed, color, thickness=1, lineType=8, shift=0):
    a = _img(img)
    xy, counts = _contours(pts)
    args = (_col(color), _i(thickness), _i(lineType), _i(shift))
    if a is None or len(counts) == 0:
        return img
    check(_polylines(*a, xy.ctypes.data_as(PI32), counts.ctypes.data_as(PI32), len(counts), int(bool(isClosed)), *args), "polylines")
    return img


def fillPoly(img, pts, color, lineType=8, shift=0, offset=(0, 0)):
    a = _img(img)
    xy, counts = _contours(pts)
    col, lt, sh, off = _col(color), _i(lineType), _i(shift), _pt(offset, "offset")
    if a is None or len(counts) == 0:
        return img
    check(_fillpoly(*a, xy.ctypes.data_as(PI32), counts.ctypes.data_as(PI32), len(counts), col, lt, sh, off[0], off[1], 0), "fillPoly")
    return img


def fillConvexPoly(img, points, color, lineType=8, shift=0):
    a = _img(img)
    xy, counts = _contours([points])
    col, lt, sh = _col(color), _i(lineType), _i(shift)
    if a is None:
        return img
    check(_fillpoly(*a, xy.ctypes.data_as(PI32), counts.ctypes.data_as(PI32), len(counts), col, lt, sh, 0, 0, 1), "fillConvexPoly")
    return img


def ellipse(img, *args, **kwargs):
    """ellipse(img, center, axes, angle, startAngle, endAngle, color[, thickness[, lineType[, shift]]])
    or ellipse(img, box, color[, thickness[, lineType]]) with box = ((cx, cy), (w, h), angle)."""
    a = _img(img)
    args = list(args)
    box_form = "box" in kwargs
    if not box_form and args and "center" not in kwargs:
        try:
            box_form = len(args[0]) == 3 and len(args[0][0]) == 2
        except TypeError:
            box_form = False
    names = ["box", "color", "thickness", "lineType"] if box_form else \
        ["center", "axes", "angle", "startAngle", "endAngle", "color", "thickness", "lineType", "shift"]
    vals = {n: v for n, v in zip(names, args)}
    for k, v in kwargs.items():
        if k not in names:
            raise TypeError(f"ellipse() got an unexpected keyword argument '{k}'")
        vals[k] = v
    if "color" not in vals:
        raise TypeError("ellipse() missing required argument 'color'")
    thickness, line_type = _i(vals.get("thickness", 1)), _i(vals.get("lineType", 8))
    shift = 0 if box_form else _i(vals.get("shift", 0))
    if box_form:
        (bx, by), (bw, bh), ang = vals["box"]
        cx, cy = int(round(bx)), int(round(by))
        ax, ay = int(round(bw * 0.5)), int(round(bh * 0.5))
        sa, ea = 0.0, 360.0
    else:
        cx, cy = _pt(vals["center"], "center")
        ax, ay = _pt(vals["axes"], "axes")
        ang = float(vals["angle"])
        sa, ea = float(vals["startAngle"]), float(vals["endAngle"])
    col = _col(vals["color"])
    if a is not None:
        check(_ellipse(*a, cx, cy, ax, ay, float(ang), sa, ea, col, thickness, line_type, shift), "ellipse")
    return img


def _putText_hershey(img, text, org, fontFace, fontScale, color, thickness=1, lineType=8, bottomLeftOrigin=False):
    a = _img(img)
    data = str(text).encode("utf-8")
    ox, oy = _pt(org, "org")
    args = (ox, oy, _i(fontFace), float(fontScale), _col(color), _i(thickness), _i(lineType), int(bool(bottomLeftOrigin)))
    if not data or a is None:
        return img
    check(_puttext(*a, data, len(data), *args), "putText")
    return img


def _getTextSize_hershey(text, fontFace, fontScale, thickness):
    data = str(text).encode("utf-8")
    out = (ctypes.c_int32 * 3)()
    check(_textsize(data, len(data), _i(fontFace), float(fontScale), _i(thickness), ctypes.cast(out, PI32)), "getTextSize")
    return (int(out[0]), int(out[1])), int(out[2])


def _hierarchy(h, n):
    """cv2 hierarchy: an int32 ndarray whose last axis is 4 (next, prev, first child, parent) with >= ncontours entries; None/empty = none.

    OpenCV 5.1 reads the raw memory without checking dtype or length (garbage / hangs on bad input); here other dtypes,
    lists and too-short arrays raise instead."""
    if h is None:
        return None
    if not isinstance(h, np.ndarray):
        raise TypeError("hierarchy must be a numpy int32 array of shape (1, N, 4)")
    if h.size == 0:
        return None
    if h.dtype != np.int32 or h.ndim not in (2, 3) or h.shape[-1] != 4 or h.size < 4 * n:
        raise error("drawContours: hierarchy must be int32 with 4 values per contour for all contours")
    return np.ascontiguousarray(h)


def drawContours(image, contours, contourIdx, color, thickness=1, lineType=8, hierarchy=None, maxLevel=2147483647, offset=(0, 0)):
    a = _img(image)
    xy, counts = _contours(contours)
    idx, th, lt, ml = _i(contourIdx), _i(thickness), _i(lineType), _i(maxLevel)
    off = _pt(offset, "offset")
    col = _col(color)
    n = len(counts)
    h = _hierarchy(hierarchy, n) if (ml != 0) else None
    if a is None or n == 0:
        return image
    hp = h.ctypes.data_as(PI32) if h is not None else None
    check(_contours_fn(*a, xy.ctypes.data_as(PI32), counts.ctypes.data_as(PI32), n, hp, idx, col, th, lt, ml, off[0], off[1]), "drawContours")
    return image


def arrowedLine(img, pt1, pt2, color, thickness=1, line_type=8, shift=0, tipLength=0.1):
    a = _img(img)
    x0, y0 = _pt(pt1, "pt1")
    x1, y1 = _pt(pt2, "pt2")
    args = (x0, y0, x1, y1, _col(color), _i(thickness), _i(line_type), _i(shift), _f(tipLength))
    if a is not None:
        check(_arrowed(*a, *args), "arrowedLine")
    return img


def drawMarker(img, position, color, markerType=MARKER_CROSS, markerSize=20, thickness=1, line_type=8):
    a = _img(img)
    x, y = _pt(position, "position")
    args = (x, y, _col(color), _i(markerType), _i(markerSize), _i(thickness), _i(line_type))
    if a is not None:
        check(_marker(*a, *args), "drawMarker")
    return img


def ellipse2Poly(center, axes, angle, arcStart, arcEnd, delta):
    cx, cy = _pt(center, "center")
    ax, ay = _pt(axes, "axes")
    out = (ctypes.c_int32 * 2048)()
    n = _e2p(cx, cy, ax, ay, _i(angle), _i(arcStart), _i(arcEnd), _i(delta), ctypes.cast(out, PI32), 1024)
    if n < 0:
        check(n, "ellipse2Poly")
    return np.frombuffer(out, dtype=np.int32, count=2 * n).reshape(n, 2).copy()


def _wrap32(v):
    return (v + 2147483648) % 4294967296 - 2147483648


def _clip_size(w, h, x1, y1, x2, y2):
    """cv::clipLine(Size2l, Point2l&, Point2l&) on Python ints (int64 semantics are not needed: inputs come from int32)."""
    right, bottom = w - 1, h - 1
    if w <= 0 or h <= 0:
        return False, x1, y1, x2, y2

    def code(x, y):
        return (x < 0) + (x > right) * 2 + (y < 0) * 4 + (y > bottom) * 8

    def trunc(f):
        return int(f) if f == f and abs(f) != float("inf") else 0

    c1, c2 = code(x1, y1), code(x2, y2)
    if (c1 & c2) == 0 and (c1 | c2) != 0:
        if c1 & 12:
            a = 0 if c1 < 8 else bottom
            x1 += trunc((a - y1) * float(x2 - x1) / float(y2 - y1)) if y2 != y1 else 0
            y1 = a
            c1 = (x1 < 0) + (x1 > right) * 2
        if c2 & 12:
            a = 0 if c2 < 8 else bottom
            x2 += trunc((a - y2) * float(x2 - x1) / float(y2 - y1)) if y2 != y1 else 0
            y2 = a
            c2 = (x2 < 0) + (x2 > right) * 2
        if (c1 & c2) == 0 and (c1 | c2) != 0:
            if c1:
                a = 0 if c1 == 1 else right
                y1 += trunc((a - x1) * float(y2 - y1) / float(x2 - x1)) if x2 != x1 else 0
                x1 = a
                c1 = 0
            if c2:
                a = 0 if c2 == 1 else right
                y2 += trunc((a - x2) * float(y2 - y1) / float(x2 - x1)) if x2 != x1 else 0
                x2 = a
                c2 = 0
    return (c1 | c2) == 0, x1, y1, x2, y2


def clipLine(imgRect, pt1, pt2):
    try:
        rx, ry, rw, rh = imgRect
    except Exception as exc:  # noqa: BLE001
        raise TypeError("Can't parse 'imgRect'. Expected sequence length 4") from exc
    rx, ry, rw, rh = _i(rx), _i(ry), _i(rw), _i(rh)
    x1, y1 = _pt(pt1, "pt1")
    x2, y2 = _pt(pt2, "pt2")
    ok, a, b, c, d = _clip_size(rw, rh, _wrap32(x1 - rx), _wrap32(y1 - ry), _wrap32(x2 - rx), _wrap32(y2 - ry))
    return ok, (_wrap32(a + rx), _wrap32(b + ry)), (_wrap32(c + rx), _wrap32(d + ry))


_FONT_HEIGHT_DIV = (27.0, 15.0, 27.0, 27.0, 27.0, 22.0, 25.0, 25.0)


def getFontScaleFromHeight(fontFace, pixelHeight, thickness=1):
    face = _i(fontFace)
    h = _i(pixelHeight)
    _i(thickness)
    if (face & ~16) not in range(8):
        raise error("getFontScaleFromHeight: unsupported font face")
    return h / _FONT_HEIGHT_DIV[face & ~16]


# ---------------------------------------------------------------- FontFace (cv::FontFace, OpenCV 5.1)

_SLOTS: dict = {}          # FontFace.setBuiltinFont overrides: "sans" / "italic" / "uni" -> font file path
_WGHT_TAG = 1952999287     # CV_FOURCC('w','g','h','t') as OpenCV reports it


class FontFace:
    """cv::FontFace. FontFace("sans") is the built-in Rubik (variable font, weight axis 300..900); FontFace(path) loads a
    TrueType / OpenType / collection file (first face). An invalid face (FontFace(), unknown name, unreadable file) has an empty
    name and still draws with the built-in font, like OpenCV."""

    def __init__(self, fontPathOrName=None):
        self._id = 0
        self._name = ""
        if fontPathOrName is not None:
            self.set(fontPathOrName)

    def __del__(self):
        try:
            self._release()
        except Exception:  # noqa: BLE001 - interpreter shutdown
            pass

    def _release(self):
        if getattr(self, "_id", 0) > 0:
            _font_free(self._id)
        self._id = 0

    def _load(self, path):
        data = os.fsencode(path)
        fid = _font_load(data, len(data))
        return fid if fid > 0 else 0

    def set(self, fontPathOrName):
        if not isinstance(fontPathOrName, str):
            raise TypeError("fontPathOrName must be a str")
        self._release()
        self._name = ""
        name = fontPathOrName
        if name in ("", "sans", "italic"):
            slot = _SLOTS.get("sans" if name != "italic" else "italic") or (_SLOTS.get("sans") if name == "italic" else None)
            if slot:
                fid = self._load(slot)
                if not fid:
                    return False
                self._id = fid
            self._name = "sans"
            return True
        if name == "uni":
            slot = _SLOTS.get("uni")
            fid = self._load(slot) if slot else 0
            if not fid:
                return False
            self._id, self._name = fid, "uni"
            return True
        fid = self._load(name)
        if not fid:
            return False
        self._id, self._name = fid, name
        return True

    def getName(self):
        return self._name

    def _axis(self):
        out = (ctypes.c_int32 * 3)()
        _font_axis(self._id, ctypes.cast(out, PI32))
        return (out[0] != 0, out[1], out[2])

    def getInstance(self):
        if not self._name or not self._axis()[0]:
            return False, ()
        return True, np.array([_WGHT_TAG, _font_weight(self._id, 0, 0) << 16], dtype=np.int32)

    def setInstance(self, params):
        if not self._name or not self._axis()[0]:
            return False
        vals = [int(v) for v in params]
        if len(vals) % 2:
            return False
        for k in range(0, len(vals), 2):
            if vals[k] == _WGHT_TAG:
                _font_weight(self._id, 1, vals[k + 1] >> 16)
        return True

    @staticmethod
    def setBuiltinFont(fontName, fontPath):
        return FontFace_setBuiltinFont(fontName, fontPath)

    def __repr__(self):
        return f"<cv2.FontFace {self._name!r}>"


def FontFace_setBuiltinFont(fontName, fontPath):
    """Replace (or, with an empty path, restore) one of the built-in font slots "sans" / "italic" / "uni"."""
    if fontName not in ("sans", "italic", "uni"):
        return False
    if not fontPath:
        _SLOTS.pop(fontName, None)
        return True
    data = os.fsencode(fontPath)
    fid = _font_load(data, len(data))
    if fid <= 0:
        return False
    _font_free(fid)
    _SLOTS[fontName] = fontPath
    return True


def _wrap_args(wrap):
    if wrap is None:
        return 0, 0, 0
    try:
        a, b = wrap
    except Exception as exc:  # noqa: BLE001
        raise TypeError("wrap must be a (start, end) range") from exc
    return 1, _i(a), _i(b)


def _putText_face(img, text, org, color, fface, size, weight=0, flags=0, wrap=None):
    a = _img(img)
    if not isinstance(fface, FontFace):
        raise TypeError("fface must be a cv2.FontFace")
    data = str(text).encode("utf-8")
    ox, oy = _pt(org, "org")
    hw, wa, wb = _wrap_args(wrap)
    out = (ctypes.c_int32 * 2)(ox, oy)
    if a is not None:
        check(_puttext_face(*a, data, len(data), ox, oy, _col(color), fface._id, _i(size), _i(weight), _i(flags), hw, wa, wb, ctypes.cast(out, PI32)),
              "putText")
    return (int(out[0]), int(out[1])), img


def putText(img, text, org, *args, **kwargs):
    """putText(img, text, org, fontFace, fontScale, color[, thickness[, lineType[, bottomLeftOrigin]]]) -> img
    putText(img, text, org, color, fface, size[, weight[, flags[, wrap]]]) -> retval, img"""
    if (len(args) >= 2 and isinstance(args[1], FontFace)) or "fface" in kwargs or "size" in kwargs:
        names = ("color", "fface", "size", "weight", "flags", "wrap")
        vals = dict(zip(names, args))
        for k, v in kwargs.items():
            if k not in names:
                raise TypeError(f"putText() got an unexpected keyword argument '{k}'")
            vals[k] = v
        for need in ("color", "fface", "size"):
            if need not in vals:
                raise TypeError(f"putText() missing required argument '{need}'")
        return _putText_face(img, text, org, **vals)
    return _putText_hershey(img, text, org, *args, **kwargs)


def _getTextSize_face(imgsize, text, org, fface, size, weight=0, flags=0, wrap=None):
    if not isinstance(fface, FontFace):
        raise TypeError("fface must be a cv2.FontFace")
    try:
        iw, _ih = imgsize
    except Exception as exc:  # noqa: BLE001
        raise TypeError("imgsize must be a (width, height) pair") from exc
    data = str(text).encode("utf-8")
    ox, oy = _pt(org, "org")
    hw, wa, wb = _wrap_args(wrap)
    out = (ctypes.c_int32 * 4)()
    check(_rect_face(_i(iw), data, len(data), ox, oy, fface._id, _i(size), _i(weight), _i(flags), hw, wa, wb, ctypes.cast(out, PI32)), "getTextSize")
    return int(out[0]), int(out[1]), int(out[2]), int(out[3])


def getTextSize(*args, **kwargs):
    """getTextSize(text, fontFace, fontScale, thickness) -> (width, height), baseLine
    getTextSize(imgsize, text, org, fface, size[, weight[, flags[, wrap]]]) -> (x, y, width, height)"""
    first = args[0] if args else kwargs.get("text", kwargs.get("imgsize"))
    if "imgsize" in kwargs or (args and not isinstance(first, str)) or "fface" in kwargs:
        return _getTextSize_face(*args, **kwargs)
    return _getTextSize_hershey(*args, **kwargs)


def safarium_circles(img, centers, radii, color, thickness=-1, lineType=8, shift=0):
    """Safarium-only batch extension (not in OpenCV): draw many circles with one call.

    Identical output to ``for c, r, col in ...: cv2.circle(img, c, r, col, thickness, lineType, shift)`` in order.
    ``centers``: integer array-like (N, 2); ``radii``: int or integer array-like (N,); ``color``: one cv2 Scalar for all
    circles (number / tuple of up to 4 numbers) or a 2-D array-like (N, <=4) with one colour per circle. Coordinates and
    radii use ``shift`` fractional bits exactly like cv2.circle. Returns ``img``.
    """
    a = _img(img)
    c = np.asarray(centers)
    if c.size == 0:
        return img
    if c.dtype.kind not in "iu" or c.ndim != 2 or c.shape[1] != 2:
        raise TypeError("centers must be an integer array of shape (N, 2)")
    n = c.shape[0]
    r = np.asarray(radii)
    if r.dtype.kind not in "iu" or r.ndim > 1 or (r.ndim == 1 and r.shape[0] != n):
        raise TypeError("radii must be an int or an integer array of shape (N,)")
    xyr = np.empty((n, 3), np.int64)
    xyr[:, :2] = c
    xyr[:, 2] = r
    if n and (xyr.min() < _I32_MIN or xyr.max() > _I32_MAX):
        raise OverflowError("integer does not fit in int32")
    xyr = np.ascontiguousarray(xyr, dtype=np.int32)
    col = np.asarray(color, dtype=np.float64) if not isinstance(color, (int, float)) else np.array([float(color)])
    if col.ndim == 2 and col.shape[0] == n and n != 1:
        if col.shape[1] > 4:
            raise TypeError("colour rows must have at most 4 components")
        cols = np.zeros((n, 4), np.float64)
        cols[:, : col.shape[1]] = col
    else:
        if col.ndim == 2 and col.shape[0] == 1:
            col = col[0]
        if col.ndim > 1 or col.size > 4:
            raise TypeError("color must be a Scalar or an (N, <=4) array")
        cols = np.zeros((1, 4), np.float64)
        cols[0, : col.size] = col.ravel()
    t, lt, sh = _i(thickness), _i(lineType), _i(shift)
    if a is None or n == 0:
        return img
    check(_circles(*a, xyr.ctypes.data_as(PI32), n, cols.ctypes.data_as(PF64), cols.shape[0], t, lt, sh), "circles")
    return img


# ---------------------------------------------------------------- optional C bridge (_srfast)

_py = types.SimpleNamespace(circle=circle, line=line, rectangle=rectangle, polylines=polylines, fillPoly=fillPoly,
                            fillConvexPoly=fillConvexPoly, ellipse=ellipse, putText=putText, getTextSize=getTextSize,
                            arrowedLine=arrowedLine, drawMarker=drawMarker, ellipse2Poly=ellipse2Poly, clipLine=clipLine, drawContours=drawContours,
                            getFontScaleFromHeight=getFontScaleFromHeight)
fast = None
if not os.environ.get("SAFARIUM_NO_FAST"):
    try:
        from . import _srfast  # built by sdk/python/safarium_cv2/build_fast.sh

        _srfast.init(lib._name, error, (circle, line, rectangle, polylines, fillPoly, ellipse, putText, arrowedLine, drawMarker, drawContours,
                                        fillConvexPoly, ellipse2Poly, clipLine, getFontScaleFromHeight, getTextSize))
        fast = types.SimpleNamespace(**vars(_py))     # functions the bridge does not cover keep their ctypes implementation
        _srfast.set_face_class(FontFace)
        for _name in ("circle", "line", "rectangle", "polylines", "fillPoly", "ellipse", "putText", "arrowedLine", "drawMarker",
                      "drawContours", "fillConvexPoly", "ellipse2Poly", "clipLine", "getFontScaleFromHeight", "getTextSize"):
            setattr(fast, _name, getattr(_srfast, _name))
            globals()[_name] = getattr(_srfast, _name)
    except Exception:  # extension not built / ABI mismatch: stay on the ctypes path
        fast = None
