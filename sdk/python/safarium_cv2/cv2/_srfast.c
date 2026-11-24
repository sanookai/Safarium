/* _srfast: low-overhead CPython bridge from cv2 draw calls to libSafariumRaster's C ABI.
 *
 * Why: ctypes costs ~2.5 us per call (argtypes conversion + GIL dance). This module parses the arguments with the
 * buffer protocol / vectorcall (METH_FASTCALL) and calls the dylib function pointers directly.
 *
 * Contract: every exported function accepts exactly the cv2 Python signature. Any input it does not recognise on its
 * fast path (numpy integer scalars, float coordinates, read-only or odd-layout arrays, rec/box forms, ...) is handed
 * unchanged to the pure-Python implementation registered in init(), which produces the cv2-compatible result or error.
 *
 * Build: sdk/python/safarium_cv2/build_fast.sh (clang, no setuptools). Not installed anywhere.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t i32;
#define IMGP void *, i32, i32, i32, i32, i32

typedef i32 (*circle_fn)(IMGP, i32, i32, i32, const double *, i32, i32, i32);
typedef i32 (*line_fn)(IMGP, i32, i32, i32, i32, const double *, i32, i32, i32);
typedef i32 (*poly_fn)(IMGP, const i32 *, const i32 *, i32, i32, const double *, i32, i32, i32);
typedef i32 (*fill_fn)(IMGP, const i32 *, const i32 *, i32, const double *, i32, i32, i32, i32, i32);
typedef i32 (*ellipse_fn)(IMGP, i32, i32, i32, i32, double, double, double, const double *, i32, i32, i32);
typedef i32 (*text_fn)(IMGP, const uint8_t *, i32, i32, i32, i32, double, const double *, i32, i32, i32);
typedef i32 (*arrow_fn)(IMGP, i32, i32, i32, i32, const double *, i32, i32, i32, double);
typedef i32 (*marker_fn)(IMGP, i32, i32, const double *, i32, i32, i32, i32);
typedef i32 (*contours_fn)(IMGP, const i32 *, const i32 *, i32, const i32 *, i32, const double *, i32, i32, i32, i32, i32);
typedef i32 (*e2p_fn)(i32, i32, i32, i32, i32, i32, i32, i32, i32 *, i32);
typedef i32 (*tsize_fn)(const uint8_t *, i32, i32, double, i32, i32 *);
typedef i32 (*putface_fn)(IMGP, const uint8_t *, i32, i32, i32, const double *, i32, i32, i32, i32, i32, i32, i32, i32 *);
typedef i32 (*rectface_fn)(i32, const uint8_t *, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32, i32 *);
typedef i32 (*err_fn)(char *, i32);

static circle_fn f_circle;
static line_fn f_line, f_rect;
static poly_fn f_polylines;
static fill_fn f_fillpoly;
static ellipse_fn f_ellipse;
static text_fn f_text;
static arrow_fn f_arrow;
static marker_fn f_marker;
static contours_fn f_contours;
static e2p_fn f_e2p;
static tsize_fn f_tsize;
static putface_fn f_putface;
static rectface_fn f_rectface;
static PyObject *g_facecls;                /* cv2.FontFace */
static err_fn f_lasterr;
static PyObject *g_ndarray, *g_int32dt;    /* numpy.ndarray, numpy.dtype('int32') */
static PyObject *g_error;                  /* cv2.error */
enum { FB_CIRCLE, FB_LINE, FB_RECT, FB_POLYLINES, FB_FILLPOLY, FB_ELLIPSE, FB_PUTTEXT, FB_ARROW, FB_MARKER, FB_CONTOURS, FB_CONVEX,
       FB_E2P, FB_CLIP, FB_FONTSCALE, FB_TSIZE, FB_COUNT };
static PyObject *g_fb[FB_COUNT];

/* ---------------------------------------------------------------- image / scalar parsing */

typedef struct { Py_buffer v; void *data; i32 w, h, stride, c, depth; } Img;

/* 1 = buffer acquired (caller must PyBuffer_Release), 0 = use the Python fallback */
static int get_img(PyObject *o, Img *im) {
    if (PyObject_GetBuffer(o, &im->v, PyBUF_WRITABLE | PyBUF_STRIDES | PyBUF_FORMAT) < 0) { PyErr_Clear(); return 0; }
    Py_buffer *v = &im->v;
    int ok = 0;
    const char *f = v->format;
    int depth = -1;
    if (f && f[0] && f[1] == 0) {
        switch (f[0]) {                    /* OpenCV depth codes of the element types cv2's drawing accepts */
            case 'B': depth = 0; break;
            case 'b': depth = 1; break;
            case 'H': depth = 2; break;
            case 'h': depth = 3; break;
            case 'i': depth = v->itemsize == 4 ? 4 : -1; break;
            case 'f': depth = 5; break;
            case 'd': depth = 6; break;
            case 'e': depth = 7; break;
            case '?': depth = 9; break;
            case 'L': case 'Q': depth = v->itemsize == 8 ? 10 : -1; break;
            case 'I': depth = v->itemsize == 4 ? 12 : -1; break;
            default: break;
        }
    }
    if (depth < 0 || (v->ndim != 2 && v->ndim != 3) || !v->shape || !v->strides) goto done;
    Py_ssize_t h = v->shape[0], w = v->shape[1], c = v->ndim == 3 ? v->shape[2] : 1, isz = v->itemsize;
    if (h < 1 || w < 1 || c < 1 || c > 4 || h > INT32_MAX || w > INT32_MAX) goto done;
    if ((w > 1 && v->strides[1] != c * isz) || (v->ndim == 3 && c > 1 && v->strides[2] != isz) || v->strides[0] <= 0) goto done;
    Py_ssize_t stride = h > 1 ? v->strides[0] : w * c * isz;
    if (stride > INT32_MAX || stride < w * c * isz) goto done;
    im->data = v->buf; im->w = (i32)w; im->h = (i32)h; im->stride = (i32)stride; im->c = (i32)c; im->depth = depth;
    ok = 1;
done:
    if (!ok) PyBuffer_Release(v);
    return ok;
}

static inline int geti(PyObject *o, i32 *out) {
    if (!PyLong_CheckExact(o)) return 0;
    long v = PyLong_AsLong(o);
    if (v == -1 && PyErr_Occurred()) { PyErr_Clear(); return 0; }
    if (v < INT32_MIN || v > INT32_MAX) return 0;
    *out = (i32)v;
    return 1;
}

static inline int getd(PyObject *o, double *out) {
    if (PyFloat_Check(o)) { *out = PyFloat_AS_DOUBLE(o); return 1; }
    if (PyLong_CheckExact(o)) { *out = PyLong_AsDouble(o); if (*out == -1.0 && PyErr_Occurred()) { PyErr_Clear(); return 0; } return 1; }
    return 0;
}

static int getpt(PyObject *o, i32 *x, i32 *y) {
    PyObject *a, *b;
    if (PyTuple_CheckExact(o) && PyTuple_GET_SIZE(o) == 2) { a = PyTuple_GET_ITEM(o, 0); b = PyTuple_GET_ITEM(o, 1); }
    else if (PyList_CheckExact(o) && PyList_GET_SIZE(o) == 2) { a = PyList_GET_ITEM(o, 0); b = PyList_GET_ITEM(o, 1); }
    else return 0;
    return geti(a, x) && geti(b, y);
}

/* cv2 Scalar: number, or tuple/list of <= 4 numbers (exact int/float; numpy scalars take the Python path) */
static int getcolor(PyObject *o, double col[4]) {
    col[0] = col[1] = col[2] = col[3] = 0.0;
    if (PyLong_CheckExact(o) || PyFloat_Check(o)) return getd(o, &col[0]);
    PyObject **items; Py_ssize_t n;
    if (PyTuple_CheckExact(o)) { items = ((PyTupleObject *)o)->ob_item; n = PyTuple_GET_SIZE(o); }
    else if (PyList_CheckExact(o)) { items = ((PyListObject *)o)->ob_item; n = PyList_GET_SIZE(o); }
    else return 0;
    if (n > 4) return 0;
    for (Py_ssize_t i = 0; i < n; i++) {
        if (PyLong_CheckExact(items[i]) || PyFloat_Check(items[i])) { if (!getd(items[i], &col[i])) return 0; }
        else return 0;
    }
    return 1;
}

/* optional int slot with default */
static inline int opt_i(PyObject *o, i32 dflt, i32 *out) {
    if (!o) { *out = dflt; return 1; }
    return geti(o, out);
}

/* ---------------------------------------------------------------- argument binding */

static PyObject *kw_names[64];             /* interned keyword names, filled in init() */
static int kw_count;

static int kw_index(PyObject *name) {
    for (int i = 0; i < kw_count; i++) if (kw_names[i] == name) return i;
    for (int i = 0; i < kw_count; i++) if (PyUnicode_Compare(kw_names[i], name) == 0) return i;
    return -1;
}

/* names: array of parameter-name ids (indices into kw_names) after the image. Returns 0 -> fallback. */
static int bind(const int *ids, int nparams, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames, PyObject **slots) {
    if (nargs > nparams) return 0;
    for (Py_ssize_t i = 0; i < nargs; i++) slots[i] = args[i];
    for (int i = (int)nargs; i < nparams; i++) slots[i] = NULL;
    if (kwnames) {
        Py_ssize_t nk = PyTuple_GET_SIZE(kwnames);
        for (Py_ssize_t k = 0; k < nk; k++) {
            int id = kw_index(PyTuple_GET_ITEM(kwnames, k));
            int pos = -1;
            for (int i = 0; i < nparams; i++) if (ids[i] == id) { pos = i; break; }
            if (pos < 0 || slots[pos]) return 0;
            slots[pos] = args[nargs + k];
        }
    }
    return 1;
}

enum { K_img, K_center, K_radius, K_color, K_thickness, K_lineType, K_shift, K_pt1, K_pt2, K_pts, K_isClosed, K_offset,
       K_axes, K_angle, K_startAngle, K_endAngle, K_text, K_org, K_fontFace, K_fontScale, K_bottomLeftOrigin,
       K_line_type, K_tipLength, K_position, K_markerType, K_markerSize, K_image, K_contours, K_contourIdx, K_hierarchy, K_maxLevel,
       K_points, K_imgRect, K_pixelHeight, K_arcStart, K_arcEnd, K_delta, K_COUNT };
static const char *kw_str[K_COUNT] = { "img", "center", "radius", "color", "thickness", "lineType", "shift", "pt1", "pt2", "pts",
    "isClosed", "offset", "axes", "angle", "startAngle", "endAngle", "text", "org", "fontFace", "fontScale", "bottomLeftOrigin",
    "line_type", "tipLength", "position", "markerType", "markerSize", "image", "contours", "contourIdx", "hierarchy", "maxLevel",
    "points", "imgRect", "pixelHeight", "arcStart", "arcEnd", "delta" };

static const int P_CIRCLE[] = { K_img, K_center, K_radius, K_color, K_thickness, K_lineType, K_shift };
static const int P_LINE[] = { K_img, K_pt1, K_pt2, K_color, K_thickness, K_lineType, K_shift };
static const int P_POLYLINES[] = { K_img, K_pts, K_isClosed, K_color, K_thickness, K_lineType, K_shift };
static const int P_FILLPOLY[] = { K_img, K_pts, K_color, K_lineType, K_shift, K_offset };
static const int P_ELLIPSE[] = { K_img, K_center, K_axes, K_angle, K_startAngle, K_endAngle, K_color, K_thickness, K_lineType, K_shift };
static const int P_ARROW[] = { K_img, K_pt1, K_pt2, K_color, K_thickness, K_line_type, K_shift, K_tipLength };
static const int P_MARKER[] = { K_img, K_position, K_color, K_markerType, K_markerSize, K_thickness, K_line_type };
static const int P_CONTOURS[] = { K_image, K_contours, K_contourIdx, K_color, K_thickness, K_lineType, K_hierarchy, K_maxLevel, K_offset };
static const int P_CONVEX[] = { K_img, K_points, K_color, K_lineType, K_shift };
static const int P_E2P[] = { K_center, K_axes, K_angle, K_arcStart, K_arcEnd, K_delta };
static const int P_CLIP[] = { K_imgRect, K_pt1, K_pt2 };
static const int P_FONTSCALE[] = { K_fontFace, K_pixelHeight, K_thickness };
static const int P_PUTTEXT[] = { K_img, K_text, K_org, K_fontFace, K_fontScale, K_color, K_thickness, K_lineType, K_bottomLeftOrigin };

static PyObject *raise_rc(const char *what, i32 rc) {
    char buf[1024];
    buf[0] = 0;
    f_lasterr(buf, sizeof buf);
    PyErr_Format(g_error, "%s: %s (rc=%d)", what, buf, (int)rc);
    return NULL;
}

#define FALLBACK(idx) return PyObject_Vectorcall(g_fb[idx], args, nargs, kwnames)
#define DONE(what, call)                                                                    \
    do {                                                                                    \
        i32 rc_ = (call);                                                                   \
        PyBuffer_Release(&im.v);                                                            \
        if (rc_ != 0) return raise_rc(what, rc_);                                           \
        Py_INCREF(s[0]);                                                                    \
        return s[0];                                                                        \
    } while (0)

/* ---------------------------------------------------------------- draw functions */

static PyObject *fast_circle(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[7];
    if (!bind(P_CIRCLE, 7, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3]) FALLBACK(FB_CIRCLE);
    i32 cx, cy, r, th, lt, sh; double col[4];
    if (!getpt(s[1], &cx, &cy) || !geti(s[2], &r) || !getcolor(s[3], col) || !opt_i(s[4], 1, &th) || !opt_i(s[5], 8, &lt) || !opt_i(s[6], 0, &sh))
        FALLBACK(FB_CIRCLE);
    Img im;
    if (!get_img(s[0], &im)) FALLBACK(FB_CIRCLE);
    DONE("circle", f_circle(im.data, im.w, im.h, im.stride, im.c, im.depth, cx, cy, r, col, th, lt, sh));
}

static PyObject *fast_line(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[7];
    if (!bind(P_LINE, 7, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3]) FALLBACK(FB_LINE);
    i32 x0, y0, x1, y1, th, lt, sh; double col[4];
    if (!getpt(s[1], &x0, &y0) || !getpt(s[2], &x1, &y1) || !getcolor(s[3], col) || !opt_i(s[4], 1, &th) || !opt_i(s[5], 8, &lt) || !opt_i(s[6], 0, &sh))
        FALLBACK(FB_LINE);
    Img im;
    if (!get_img(s[0], &im)) FALLBACK(FB_LINE);
    DONE("line", f_line(im.data, im.w, im.h, im.stride, im.c, im.depth, x0, y0, x1, y1, col, th, lt, sh));
}

static PyObject *fast_rectangle(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[7];
    i32 x0, y0, x1, y1, th, lt, sh; double col[4];
    if (!kwnames && nargs >= 3 && PyTuple_CheckExact(args[1]) && PyTuple_GET_SIZE(args[1]) == 4) {   /* rectangle(img, rec, color, ...) */
        PyObject *r = args[1];
        i32 x, y, w, h;
        if (nargs > 6 || !geti(PyTuple_GET_ITEM(r, 0), &x) || !geti(PyTuple_GET_ITEM(r, 1), &y) || !geti(PyTuple_GET_ITEM(r, 2), &w) ||
            !geti(PyTuple_GET_ITEM(r, 3), &h) || w <= 0 || h <= 0 || !getcolor(args[2], col) ||
            !opt_i(nargs > 3 ? args[3] : NULL, 1, &th) || !opt_i(nargs > 4 ? args[4] : NULL, 8, &lt) || !opt_i(nargs > 5 ? args[5] : NULL, 0, &sh))
            FALLBACK(FB_RECT);
        x0 = x; y0 = y; x1 = x + w - 1; y1 = y + h - 1;
        s[0] = args[0];
    } else {
        if (!bind(P_LINE, 7, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3]) FALLBACK(FB_RECT);
        if (!getpt(s[1], &x0, &y0) || !getpt(s[2], &x1, &y1) || !getcolor(s[3], col) || !opt_i(s[4], 1, &th) || !opt_i(s[5], 8, &lt) || !opt_i(s[6], 0, &sh))
            FALLBACK(FB_RECT);
    }
    Img im;
    if (!get_img(s[0], &im)) FALLBACK(FB_RECT);
    DONE("rectangle", f_rect(im.data, im.w, im.h, im.stride, im.c, im.depth, x0, y0, x1, y1, col, th, lt, sh));
}

/* list/tuple of C-contiguous int32 arrays shaped (N,2) or (N,1,2) -> malloc'd xy + counts. NULL xy with ok=1 -> empty. */
static int get_contours(PyObject *pts, i32 **xy_out, i32 **counts_out, i32 *n_out) {
    PyObject **items; Py_ssize_t n;
    if (PyList_CheckExact(pts)) { items = ((PyListObject *)pts)->ob_item; n = PyList_GET_SIZE(pts); }
    else if (PyTuple_CheckExact(pts)) { items = ((PyTupleObject *)pts)->ob_item; n = PyTuple_GET_SIZE(pts); }
    else return 0;
    if (n < 1 || n > 1 << 20) return 0;
    i32 *counts = (i32 *)malloc(sizeof(i32) * n);
    Py_buffer *views = (Py_buffer *)malloc(sizeof(Py_buffer) * n);
    Py_ssize_t total = 0, got = 0;
    int ok = counts && views;
    for (Py_ssize_t i = 0; ok && i < n; i++) {
        if (PyObject_GetBuffer(items[i], &views[i], PyBUF_C_CONTIGUOUS | PyBUF_FORMAT) < 0) { PyErr_Clear(); ok = 0; break; }
        got++;
        Py_buffer *v = &views[i];
        int good = v->itemsize == 4 && v->format && v->format[0] == 'i' && v->format[1] == 0 && v->shape &&
                   ((v->ndim == 2 && v->shape[1] == 2) || (v->ndim == 3 && v->shape[1] == 1 && v->shape[2] == 2));
        if (!good || v->shape[0] > INT32_MAX / 4) { ok = 0; break; }
        counts[i] = (i32)v->shape[0];
        total += v->shape[0];
    }
    i32 *xy = NULL;
    if (ok) {
        xy = (i32 *)malloc(sizeof(i32) * 2 * (total > 0 ? total : 1));
        if (!xy) ok = 0;
        else { i32 *p = xy; for (Py_ssize_t i = 0; i < n; i++) { memcpy(p, views[i].buf, sizeof(i32) * 2 * counts[i]); p += 2 * counts[i]; } }
    }
    for (Py_ssize_t i = 0; i < got; i++) PyBuffer_Release(&views[i]);
    free(views);
    if (!ok) { free(counts); free(xy); return 0; }
    *xy_out = xy; *counts_out = counts; *n_out = (i32)n;
    return 1;
}

static PyObject *fast_polylines(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[7];
    if (!bind(P_POLYLINES, 7, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3]) FALLBACK(FB_POLYLINES);
    i32 th, lt, sh, closed; double col[4];
    if (PyBool_Check(s[2])) closed = s[2] == Py_True; else if (!geti(s[2], &closed)) FALLBACK(FB_POLYLINES);
    if (!getcolor(s[3], col) || !opt_i(s[4], 1, &th) || !opt_i(s[5], 8, &lt) || !opt_i(s[6], 0, &sh)) FALLBACK(FB_POLYLINES);
    i32 *xy, *counts, n;
    if (!get_contours(s[1], &xy, &counts, &n)) FALLBACK(FB_POLYLINES);
    Img im;
    if (!get_img(s[0], &im)) { free(xy); free(counts); FALLBACK(FB_POLYLINES); }
    i32 rc = f_polylines(im.data, im.w, im.h, im.stride, im.c, im.depth, xy, counts, n, closed != 0, col, th, lt, sh);
    free(xy); free(counts);
    PyBuffer_Release(&im.v);
    if (rc != 0) return raise_rc("polylines", rc);
    Py_INCREF(s[0]);
    return s[0];
}

static PyObject *fast_fillpoly(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[6];
    if (!bind(P_FILLPOLY, 6, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2]) FALLBACK(FB_FILLPOLY);
    i32 lt, sh, ox = 0, oy = 0; double col[4];
    if (!getcolor(s[2], col) || !opt_i(s[3], 8, &lt) || !opt_i(s[4], 0, &sh) || (s[5] && !getpt(s[5], &ox, &oy))) FALLBACK(FB_FILLPOLY);
    i32 *xy, *counts, n;
    if (!get_contours(s[1], &xy, &counts, &n)) FALLBACK(FB_FILLPOLY);
    Img im;
    if (!get_img(s[0], &im)) { free(xy); free(counts); FALLBACK(FB_FILLPOLY); }
    i32 rc = f_fillpoly(im.data, im.w, im.h, im.stride, im.c, im.depth, xy, counts, n, col, lt, sh, ox, oy, 0);
    free(xy); free(counts);
    PyBuffer_Release(&im.v);
    if (rc != 0) return raise_rc("fillPoly", rc);
    Py_INCREF(s[0]);
    return s[0];
}

static PyObject *fast_ellipse(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[10];
    if (!bind(P_ELLIPSE, 10, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3] || !s[4] || !s[5] || !s[6]) FALLBACK(FB_ELLIPSE);
    i32 cx, cy, ax, ay, th, lt, sh; double ang, sa, ea, col[4];
    if (!getpt(s[1], &cx, &cy) || !getpt(s[2], &ax, &ay) || !getd(s[3], &ang) || !getd(s[4], &sa) || !getd(s[5], &ea) || !getcolor(s[6], col) ||
        !opt_i(s[7], 1, &th) || !opt_i(s[8], 8, &lt) || !opt_i(s[9], 0, &sh))
        FALLBACK(FB_ELLIPSE);
    Img im;
    if (!get_img(s[0], &im)) FALLBACK(FB_ELLIPSE);
    DONE("ellipse", f_ellipse(im.data, im.w, im.h, im.stride, im.c, im.depth, cx, cy, ax, ay, ang, sa, ea, col, th, lt, sh));
}

static PyObject *fast_puttext_face(PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames, PyObject *fb);

static PyObject *fast_puttext(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[9];
    if (!kwnames && nargs >= 6 && g_facecls && Py_TYPE(args[4]) == (PyTypeObject *)g_facecls) return fast_puttext_face(args, nargs, kwnames, g_fb[FB_PUTTEXT]);
    if (!bind(P_PUTTEXT, 9, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3] || !s[4] || !s[5]) FALLBACK(FB_PUTTEXT);
    i32 ox, oy, font, th, lt, bl = 0; double scale, col[4];
    if (!PyUnicode_CheckExact(s[1]) || !getpt(s[2], &ox, &oy) || !geti(s[3], &font) || !getd(s[4], &scale) || !getcolor(s[5], col) ||
        !opt_i(s[6], 1, &th) || !opt_i(s[7], 8, &lt))
        FALLBACK(FB_PUTTEXT);
    if (s[8]) { if (PyBool_Check(s[8])) bl = s[8] == Py_True; else if (!geti(s[8], &bl)) FALLBACK(FB_PUTTEXT); }
    Py_ssize_t len;
    const char *utf8 = PyUnicode_AsUTF8AndSize(s[1], &len);
    if (!utf8) { PyErr_Clear(); FALLBACK(FB_PUTTEXT); }
    if (len == 0 || len > INT32_MAX) FALLBACK(FB_PUTTEXT);
    Img im;
    if (!get_img(s[0], &im)) FALLBACK(FB_PUTTEXT);
    DONE("putText", f_text(im.data, im.w, im.h, im.stride, im.c, im.depth, (const uint8_t *)utf8, (i32)len, ox, oy, font, scale, col, th, lt, bl != 0));
}


static PyObject *fast_arrowedline(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[8];
    if (!bind(P_ARROW, 8, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3]) FALLBACK(FB_ARROW);
    i32 x0, y0, x1, y1, th, lt, sh; double col[4], tip = 0.1;
    if (!getpt(s[1], &x0, &y0) || !getpt(s[2], &x1, &y1) || !getcolor(s[3], col) || !opt_i(s[4], 1, &th) || !opt_i(s[5], 8, &lt) ||
        !opt_i(s[6], 0, &sh) || (s[7] && !getd(s[7], &tip)))
        FALLBACK(FB_ARROW);
    Img im;
    if (!get_img(s[0], &im)) FALLBACK(FB_ARROW);
    DONE("arrowedLine", f_arrow(im.data, im.w, im.h, im.stride, im.c, im.depth, x0, y0, x1, y1, col, th, lt, sh, tip));
}

static PyObject *fast_drawmarker(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[7];
    if (!bind(P_MARKER, 7, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2]) FALLBACK(FB_MARKER);
    i32 x, y, mt, ms, th, lt; double col[4];
    if (!getpt(s[1], &x, &y) || !getcolor(s[2], col) || !opt_i(s[3], 0, &mt) || !opt_i(s[4], 20, &ms) || !opt_i(s[5], 1, &th) || !opt_i(s[6], 8, &lt))
        FALLBACK(FB_MARKER);
    Img im;
    if (!get_img(s[0], &im)) FALLBACK(FB_MARKER);
    DONE("drawMarker", f_marker(im.data, im.w, im.h, im.stride, im.c, im.depth, x, y, col, mt, ms, th, lt));
}

static PyObject *fast_fillconvex(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[5];
    if (!bind(P_CONVEX, 5, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2]) FALLBACK(FB_CONVEX);
    i32 lt, sh; double col[4];
    if (!getcolor(s[2], col) || !opt_i(s[3], 8, &lt) || !opt_i(s[4], 0, &sh)) FALLBACK(FB_CONVEX);
    PyObject *lst[1] = { s[1] };
    PyObject *one = PyList_New(1);                          /* reuse the contour parser: [points] */
    if (!one) return NULL;
    Py_INCREF(lst[0]); PyList_SET_ITEM(one, 0, lst[0]);
    i32 *xy, *counts, n;
    int okc = get_contours(one, &xy, &counts, &n);
    Py_DECREF(one);
    if (!okc) FALLBACK(FB_CONVEX);
    Img im;
    if (!get_img(s[0], &im)) { free(xy); free(counts); FALLBACK(FB_CONVEX); }
    i32 rc = f_fillpoly(im.data, im.w, im.h, im.stride, im.c, im.depth, xy, counts, n, col, lt, sh, 0, 0, 1);
    free(xy); free(counts);
    PyBuffer_Release(&im.v);
    if (rc != 0) return raise_rc("fillConvexPoly", rc);
    Py_INCREF(s[0]);
    return s[0];
}

static PyObject *fast_drawcontours(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[9];
    if (!bind(P_CONTOURS, 9, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3]) FALLBACK(FB_CONTOURS);
    i32 idx, th, lt, ml = INT32_MAX, ox = 0, oy = 0; double col[4];
    if (!geti(s[2], &idx) || !getcolor(s[3], col) || !opt_i(s[4], 1, &th) || !opt_i(s[5], 8, &lt) || !opt_i(s[7], INT32_MAX, &ml) ||
        (s[8] && !getpt(s[8], &ox, &oy)))
        FALLBACK(FB_CONTOURS);
    i32 *xy, *counts, n;
    if (!get_contours(s[1], &xy, &counts, &n)) FALLBACK(FB_CONTOURS);
    Py_buffer hv; int have_h = 0;
    const i32 *hp = NULL;
    if (s[6] && s[6] != Py_None) {
        if (PyObject_GetBuffer(s[6], &hv, PyBUF_C_CONTIGUOUS | PyBUF_FORMAT) < 0) { PyErr_Clear(); free(xy); free(counts); FALLBACK(FB_CONTOURS); }
        have_h = 1;
        if (hv.itemsize != 4 || !hv.format || hv.format[0] != 'i' || hv.format[1] != 0 || hv.ndim < 2 || hv.ndim > 3 || hv.shape[hv.ndim - 1] != 4 ||
            hv.len / 4 < (Py_ssize_t)n * 4) {
            PyBuffer_Release(&hv); free(xy); free(counts); FALLBACK(FB_CONTOURS);
        }
        hp = ml != 0 ? (const i32 *)hv.buf : NULL;
    }
    Img im;
    if (!get_img(s[0], &im)) { if (have_h) PyBuffer_Release(&hv); free(xy); free(counts); FALLBACK(FB_CONTOURS); }
    i32 rc = f_contours(im.data, im.w, im.h, im.stride, im.c, im.depth, xy, counts, n, hp, idx, col, th, lt, ml, ox, oy);
    free(xy); free(counts);
    if (have_h) PyBuffer_Release(&hv);
    PyBuffer_Release(&im.v);
    if (rc != 0) return raise_rc("drawContours", rc);
    Py_INCREF(s[0]);
    return s[0];
}

static PyObject *fast_ellipse2poly(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[6];
    if (!bind(P_E2P, 6, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2] || !s[3] || !s[4] || !s[5]) FALLBACK(FB_E2P);
    i32 cx, cy, ax, ay, ang, a0, a1, delta;
    if (!getpt(s[0], &cx, &cy) || !getpt(s[1], &ax, &ay) || !geti(s[2], &ang) || !geti(s[3], &a0) || !geti(s[4], &a1) || !geti(s[5], &delta))
        FALLBACK(FB_E2P);
    i32 buf[2048];
    i32 n = f_e2p(cx, cy, ax, ay, ang, a0, a1, delta, buf, 1024);
    if (n < 0) return raise_rc("ellipse2Poly", n);
    PyObject *ba = PyByteArray_FromStringAndSize((const char *)buf, (Py_ssize_t)n * 8);   /* writable buffer, like cv2's result */
    if (!ba) return NULL;
    PyObject *shape = Py_BuildValue("(ii)", (int)n, 2);
    if (!shape) { Py_DECREF(ba); return NULL; }
    PyObject *out = PyObject_CallFunctionObjArgs(g_ndarray, shape, g_int32dt, ba, NULL);
    Py_DECREF(shape); Py_DECREF(ba);
    return out;
}

static PyObject *fast_clipline(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[3];
    if (!bind(P_CLIP, 3, args, nargs, kwnames, s) || !s[0] || !s[1] || !s[2]) FALLBACK(FB_CLIP);
    if (!PyTuple_CheckExact(s[0]) || PyTuple_GET_SIZE(s[0]) != 4) FALLBACK(FB_CLIP);
    i32 rx, ry, rw, rh, x1, y1, x2, y2;
    if (!geti(PyTuple_GET_ITEM(s[0], 0), &rx) || !geti(PyTuple_GET_ITEM(s[0], 1), &ry) || !geti(PyTuple_GET_ITEM(s[0], 2), &rw) ||
        !geti(PyTuple_GET_ITEM(s[0], 3), &rh) || !getpt(s[1], &x1, &y1) || !getpt(s[2], &x2, &y2))
        FALLBACK(FB_CLIP);
    /* cv::clipLine(Rect, Point&, Point&): int32 wraparound on the translation, Size2l clipping in int64 */
    int64_t X1 = (int32_t)((uint32_t)x1 - (uint32_t)rx), Y1 = (int32_t)((uint32_t)y1 - (uint32_t)ry);
    int64_t X2 = (int32_t)((uint32_t)x2 - (uint32_t)rx), Y2 = (int32_t)((uint32_t)y2 - (uint32_t)ry);
    int inside = 0;
    int64_t right = (int64_t)rw - 1, bottom = (int64_t)rh - 1;
    if (rw > 0 && rh > 0) {
        #define CODE(x, y) (((x) < 0) + ((x) > right) * 2 + ((y) < 0) * 4 + ((y) > bottom) * 8)
        int64_t c1 = CODE(X1, Y1), c2 = CODE(X2, Y2);
        if ((c1 & c2) == 0 && (c1 | c2) != 0) {
            int64_t a;
            if (c1 & 12) {
                a = c1 < 8 ? 0 : bottom;
                X1 += (int64_t)((double)(a - Y1) * (double)(X2 - X1) / (double)(Y2 - Y1));
                Y1 = a;
                c1 = (X1 < 0) + (X1 > right) * 2;
            }
            if (c2 & 12) {
                a = c2 < 8 ? 0 : bottom;
                X2 += (int64_t)((double)(a - Y2) * (double)(X2 - X1) / (double)(Y2 - Y1));
                Y2 = a;
                c2 = (X2 < 0) + (X2 > right) * 2;
            }
            if ((c1 & c2) == 0 && (c1 | c2) != 0) {
                if (c1) {
                    a = c1 == 1 ? 0 : right;
                    Y1 += (int64_t)((double)(a - X1) * (double)(Y2 - Y1) / (double)(X2 - X1));
                    X1 = a;
                    c1 = 0;
                }
                if (c2) {
                    a = c2 == 1 ? 0 : right;
                    Y2 += (int64_t)((double)(a - X2) * (double)(Y2 - Y1) / (double)(X2 - X1));
                    X2 = a;
                    c2 = 0;
                }
            }
        }
        inside = (c1 | c2) == 0;
        #undef CODE
    }
    return Py_BuildValue("O(ii)(ii)", inside ? Py_True : Py_False, (int)(int32_t)((uint32_t)X1 + (uint32_t)rx), (int)(int32_t)((uint32_t)Y1 + (uint32_t)ry),
                         (int)(int32_t)((uint32_t)X2 + (uint32_t)rx), (int)(int32_t)((uint32_t)Y2 + (uint32_t)ry));
}

static PyObject *fast_fontscale(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *s[3];
    if (!bind(P_FONTSCALE, 3, args, nargs, kwnames, s) || !s[0] || !s[1]) FALLBACK(FB_FONTSCALE);
    i32 face, h, th;
    if (!geti(s[0], &face) || !geti(s[1], &h) || !opt_i(s[2], 1, &th)) FALLBACK(FB_FONTSCALE);
    static const double div[8] = { 27.0, 15.0, 27.0, 27.0, 27.0, 22.0, 25.0, 25.0 };
    int f = face & ~16;
    if (f < 0 || f > 7) FALLBACK(FB_FONTSCALE);
    return PyFloat_FromDouble((double)h / div[f]);
}


/* FontFace id of a cv2.FontFace instance (attribute _id), or -1 when `o` is not one */
static int face_id(PyObject *o, i32 *id) {
    if (!g_facecls || Py_TYPE(o) != (PyTypeObject *)g_facecls) return 0;
    PyObject *v = PyObject_GetAttrString(o, "_id");
    if (!v) { PyErr_Clear(); return 0; }
    long x = PyLong_AsLong(v);
    Py_DECREF(v);
    if (x == -1 && PyErr_Occurred()) { PyErr_Clear(); return 0; }
    *id = (i32)x;
    return 1;
}

/* optional wrap range: None / missing -> 0; (a, b) of ints -> 1 */
static int get_wrap(PyObject *o, i32 *has, i32 *a, i32 *b) {
    *has = 0; *a = 0; *b = 0;
    if (!o || o == Py_None) return 1;
    if (!PyTuple_CheckExact(o) || PyTuple_GET_SIZE(o) != 2) return 0;
    if (!geti(PyTuple_GET_ITEM(o, 0), a) || !geti(PyTuple_GET_ITEM(o, 1), b)) return 0;
    *has = 1;
    return 1;
}

static PyObject *fast_puttext_face(PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames, PyObject *fb) {
    /* putText(img, text, org, color, fface, size[, weight[, flags[, wrap]]]) positional only */
    i32 ox, oy, id, size, weight = 0, flags = 0, hw, wa, wb; double col[4];
    if (kwnames || nargs < 6 || nargs > 9 || !PyUnicode_CheckExact(args[1]) || !getpt(args[2], &ox, &oy) || !getcolor(args[3], col) ||
        !face_id(args[4], &id) || !geti(args[5], &size) || (nargs > 6 && !geti(args[6], &weight)) || (nargs > 7 && !geti(args[7], &flags)) ||
        !get_wrap(nargs > 8 ? args[8] : NULL, &hw, &wa, &wb))
        return PyObject_Vectorcall(fb, args, nargs, kwnames);
    Py_ssize_t len;
    const char *utf8 = PyUnicode_AsUTF8AndSize(args[1], &len);
    if (!utf8) { PyErr_Clear(); return PyObject_Vectorcall(fb, args, nargs, kwnames); }
    Img im;
    if (!get_img(args[0], &im)) return PyObject_Vectorcall(fb, args, nargs, kwnames);
    i32 out[2] = { ox, oy };
    i32 rc = f_putface(im.data, im.w, im.h, im.stride, im.c, im.depth, (const uint8_t *)utf8, (i32)len, ox, oy, col, id, size, weight, flags, hw, wa, wb, out);
    PyBuffer_Release(&im.v);
    if (rc != 0) return raise_rc("putText", rc);
    return Py_BuildValue("((ii)O)", out[0], out[1], args[0]);
}

static PyObject *fast_gettextsize(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *fb = g_fb[FB_TSIZE];
    if (!kwnames && nargs == 4 && PyUnicode_CheckExact(args[0])) {            /* getTextSize(text, fontFace, fontScale, thickness) */
        i32 face, th; double scale;
        if (geti(args[1], &face) && getd(args[2], &scale) && geti(args[3], &th)) {
            Py_ssize_t len;
            const char *utf8 = PyUnicode_AsUTF8AndSize(args[0], &len);
            if (utf8 && len <= INT32_MAX) {
                i32 out[3];
                i32 rc = f_tsize((const uint8_t *)utf8, (i32)len, face, scale, th, out);
                if (rc != 0) return raise_rc("getTextSize", rc);
                return Py_BuildValue("((ii)i)", out[0], out[1], out[2]);
            }
            PyErr_Clear();
        }
    } else if (!kwnames && nargs >= 5 && nargs <= 8 && PyTuple_CheckExact(args[0]) && PyTuple_GET_SIZE(args[0]) == 2 && PyUnicode_CheckExact(args[1])) {
        i32 iw, ih, ox, oy, id, size, weight = 0, flags = 0, hw, wa, wb;
        if (geti(PyTuple_GET_ITEM(args[0], 0), &iw) && geti(PyTuple_GET_ITEM(args[0], 1), &ih) && getpt(args[2], &ox, &oy) && face_id(args[3], &id) &&
            geti(args[4], &size) && (nargs <= 5 || geti(args[5], &weight)) && (nargs <= 6 || geti(args[6], &flags)) &&
            get_wrap(nargs > 7 ? args[7] : NULL, &hw, &wa, &wb)) {
            Py_ssize_t len;
            const char *utf8 = PyUnicode_AsUTF8AndSize(args[1], &len);
            if (utf8 && len <= INT32_MAX) {
                i32 out[4];
                i32 rc = f_rectface(iw, (const uint8_t *)utf8, (i32)len, ox, oy, id, size, weight, flags, hw, wa, wb, out);
                if (rc != 0) return raise_rc("getTextSize", rc);
                return Py_BuildValue("(iiii)", out[0], out[1], out[2], out[3]);
            }
            PyErr_Clear();
        }
    }
    return PyObject_Vectorcall(fb, args, nargs, kwnames);
}

static PyObject *srfast_set_face_class(PyObject *self, PyObject *cls) {
    Py_XDECREF(g_facecls);
    Py_INCREF(cls);
    g_facecls = cls;
    Py_RETURN_NONE;
}

/* ---------------------------------------------------------------- module */

static PyObject *srfast_init(PyObject *self, PyObject *args) {
    const char *path;
    PyObject *err, *fbs;
    if (!PyArg_ParseTuple(args, "sOO", &path, &err, &fbs)) return NULL;
    if (!PyTuple_Check(fbs) || PyTuple_GET_SIZE(fbs) != FB_COUNT) { PyErr_SetString(PyExc_ValueError, "need 15 fallbacks"); return NULL; }
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { PyErr_Format(PyExc_ImportError, "dlopen failed: %s", dlerror()); return NULL; }
    f_circle = (circle_fn)dlsym(h, "sr_draw_circle");
    f_line = (line_fn)dlsym(h, "sr_draw_line");
    f_rect = (line_fn)dlsym(h, "sr_draw_rectangle");
    f_polylines = (poly_fn)dlsym(h, "sr_draw_polylines");
    f_fillpoly = (fill_fn)dlsym(h, "sr_draw_fillpoly");
    f_ellipse = (ellipse_fn)dlsym(h, "sr_draw_ellipse");
    f_text = (text_fn)dlsym(h, "sr_draw_puttext");
    f_arrow = (arrow_fn)dlsym(h, "sr_draw_arrowedline");
    f_marker = (marker_fn)dlsym(h, "sr_draw_marker");
    f_contours = (contours_fn)dlsym(h, "sr_draw_contours");
    f_e2p = (e2p_fn)dlsym(h, "sr_ellipse2poly");
    f_tsize = (tsize_fn)dlsym(h, "sr_text_size");
    f_putface = (putface_fn)dlsym(h, "sr_draw_puttext_face");
    f_rectface = (rectface_fn)dlsym(h, "sr_text_rect_face");
    f_lasterr = (err_fn)dlsym(h, "sr_last_error");
    if (!f_putface || !f_rectface || !f_arrow || !f_marker || !f_contours || !f_e2p || !f_tsize || !f_circle || !f_line || !f_rect || !f_polylines || !f_fillpoly || !f_ellipse || !f_text || !f_lasterr) {
        PyErr_SetString(PyExc_ImportError, "libSafariumRaster is missing draw symbols");
        return NULL;
    }
    PyObject *np = PyImport_ImportModule("numpy");
    if (!np) return NULL;
    Py_XDECREF(g_ndarray); Py_XDECREF(g_int32dt);
    g_ndarray = PyObject_GetAttrString(np, "ndarray");
    g_int32dt = PyObject_CallMethod(np, "dtype", "s", "int32");
    Py_DECREF(np);
    if (!g_ndarray || !g_int32dt) return NULL;
    Py_XDECREF(g_error); Py_INCREF(err); g_error = err;
    for (int i = 0; i < FB_COUNT; i++) { Py_XDECREF(g_fb[i]); g_fb[i] = PyTuple_GET_ITEM(fbs, i); Py_INCREF(g_fb[i]); }
    Py_RETURN_TRUE;
}

static PyMethodDef methods[] = {
    { "init", srfast_init, METH_VARARGS, "init(dylib_path, error_class, (fallback_circle, line, rectangle, polylines, fillPoly, ellipse, putText))" },
    { "circle", (PyCFunction)(void (*)(void))fast_circle, METH_FASTCALL | METH_KEYWORDS, "cv2.circle" },
    { "line", (PyCFunction)(void (*)(void))fast_line, METH_FASTCALL | METH_KEYWORDS, "cv2.line" },
    { "rectangle", (PyCFunction)(void (*)(void))fast_rectangle, METH_FASTCALL | METH_KEYWORDS, "cv2.rectangle" },
    { "polylines", (PyCFunction)(void (*)(void))fast_polylines, METH_FASTCALL | METH_KEYWORDS, "cv2.polylines" },
    { "fillPoly", (PyCFunction)(void (*)(void))fast_fillpoly, METH_FASTCALL | METH_KEYWORDS, "cv2.fillPoly" },
    { "ellipse", (PyCFunction)(void (*)(void))fast_ellipse, METH_FASTCALL | METH_KEYWORDS, "cv2.ellipse" },
    { "putText", (PyCFunction)(void (*)(void))fast_puttext, METH_FASTCALL | METH_KEYWORDS, "cv2.putText" },
    { "getTextSize", (PyCFunction)(void (*)(void))fast_gettextsize, METH_FASTCALL | METH_KEYWORDS, "cv2.getTextSize" },
    { "set_face_class", srfast_set_face_class, METH_O, "register cv2.FontFace" },
    { "arrowedLine", (PyCFunction)(void (*)(void))fast_arrowedline, METH_FASTCALL | METH_KEYWORDS, "cv2.arrowedLine" },
    { "drawMarker", (PyCFunction)(void (*)(void))fast_drawmarker, METH_FASTCALL | METH_KEYWORDS, "cv2.drawMarker" },
    { "drawContours", (PyCFunction)(void (*)(void))fast_drawcontours, METH_FASTCALL | METH_KEYWORDS, "cv2.drawContours" },
    { "fillConvexPoly", (PyCFunction)(void (*)(void))fast_fillconvex, METH_FASTCALL | METH_KEYWORDS, "cv2.fillConvexPoly" },
    { "ellipse2Poly", (PyCFunction)(void (*)(void))fast_ellipse2poly, METH_FASTCALL | METH_KEYWORDS, "cv2.ellipse2Poly" },
    { "clipLine", (PyCFunction)(void (*)(void))fast_clipline, METH_FASTCALL | METH_KEYWORDS, "cv2.clipLine" },
    { "getFontScaleFromHeight", (PyCFunction)(void (*)(void))fast_fontscale, METH_FASTCALL | METH_KEYWORDS, "cv2.getFontScaleFromHeight" },
    { NULL, NULL, 0, NULL },
};

static struct PyModuleDef moddef = { PyModuleDef_HEAD_INIT, "_srfast", "low-overhead bridge to libSafariumRaster", -1, methods };

PyMODINIT_FUNC PyInit__srfast(void) {
    PyObject *m = PyModule_Create(&moddef);
    if (!m) return NULL;
    kw_count = K_COUNT;
    for (int i = 0; i < K_COUNT; i++) {
        kw_names[i] = PyUnicode_InternFromString(kw_str[i]);
        if (!kw_names[i]) return NULL;
    }
    return m;
}
