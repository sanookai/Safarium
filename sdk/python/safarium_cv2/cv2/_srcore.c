/* _srcore: low-overhead CPython bridge from cv2 core calls to libSafariumRaster's C ABI (phase 1, core-numeric).
 *
 * Why: the ctypes path of _core.py pays 5-20 us per call (argument validation in Python, ctypes.Structure building,
 * argtypes conversion). This module parses arguments with METH_FASTCALL + the buffer protocol, builds the 40-byte CoreMat
 * descriptors on the C stack, allocates results with numpy.empty and calls the dylib function pointers directly.
 *
 * Contract: every exported function accepts exactly the cv2 Python signature. Whatever the fast path does not recognise
 * (numpy scalars, broadcasting, dtype/mask arguments, odd layouts, aliasing, read-only or non-ndarray inputs, empty
 * arrays, 1-D arrays, every error case, ...) is handed unchanged to the pure-Python implementation registered in
 * init(), which produces the cv2-compatible result or the cv2-style error. The fast path therefore never raises for bad
 * input; it only raises the library's own failures (same message format as _core._chk).
 *
 * Build: sdk/python/safarium_cv2/build_core.sh (clang, no setuptools). Not installed anywhere.
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t i32;
typedef int64_t i64;

/* Mirror of Swift CoreMat (CoreTypes.swift) and ctypes _Mat in _core.py: 40 bytes. */
typedef struct { void *data; i64 rows, cols, step; i32 cn, depth; } CoreMat;
typedef const CoreMat *MP;

typedef i32 (*arith_fn)(i32, MP, MP, const double *, i32, MP, MP, double);
typedef i32 (*addw_fn)(MP, double, MP, double, double, MP);
typedef i32 (*convert_fn)(MP, MP, double, double, i32);
typedef i32 (*bitwise_fn)(i32, MP, MP, const void *, MP, MP);
typedef i32 (*compare_fn)(i32, MP, MP, const double *, MP);
typedef i32 (*inrange_fn)(MP, MP, MP, const double *, const double *, MP);
typedef i32 (*minmax_fn)(i32, MP, MP, const double *, MP);
typedef i32 (*math_fn)(i32, MP, MP);
typedef i32 (*pow_fn)(MP, MP, double);
typedef i32 (*mag_fn)(MP, MP, MP);
typedef i32 (*mix_fn)(i32, const CoreMat *, i32, const CoreMat *, i32, const i32 *);
typedef i32 (*flip_fn)(MP, MP, i32);
typedef i32 (*trans_fn)(MP, MP);
typedef i32 (*border_fn)(MP, MP, i32, i32, i32, const double *);
typedef i32 (*lut_fn)(MP, const void *, i32, MP);
typedef i32 (*reduce_fn)(MP, MP, i32, i32);
typedef i32 (*norm_fn)(MP, MP, MP, i32, double *);
typedef i32 (*sums_fn)(MP, MP, double *, i32);
typedef i32 (*mmloc_fn)(MP, MP, double *);
typedef i32 (*cnz_fn)(MP, i64 *);
typedef i32 (*err_fn)(char *, i32);

/* Per-module state: the test harness (and any embedder) may import the shim twice (two cv2 package copies with their own
 * error class and Python fallbacks); each copy of this extension module therefore owns its own state. S is set on entry
 * of every exported function (GIL held, no re-entry between entry and use). */
enum { FB_ADD, FB_SUBTRACT, FB_ABSDIFF, FB_MULTIPLY, FB_DIVIDE, FB_ADDWEIGHTED, FB_CONVERTSCALEABS, FB_BAND, FB_BOR, FB_BXOR,
       FB_BNOT, FB_COMPARE, FB_INRANGE, FB_MIN, FB_MAX, FB_SQRT, FB_EXP, FB_LOG, FB_POW, FB_MAGNITUDE, FB_LUT, FB_REDUCE,
       FB_NORM, FB_MEAN, FB_MEANSTDDEV, FB_MINMAXLOC, FB_COUNTNONZERO, FB_SPLIT, FB_MERGE, FB_FLIP, FB_ROTATE, FB_TRANSPOSE,
       FB_COPYMAKEBORDER, FB_HCONCAT, FB_VCONCAT, FB_COUNT };
static const char *const fb_names[FB_COUNT] = {
    "add", "subtract", "absdiff", "multiply", "divide", "addWeighted", "convertScaleAbs", "bitwise_and", "bitwise_or",
    "bitwise_xor", "bitwise_not", "compare", "inRange", "min", "max", "sqrt", "exp", "log", "pow", "magnitude", "LUT", "reduce",
    "norm", "mean", "meanStdDev", "minMaxLoc", "countNonZero", "split", "merge", "flip", "rotate", "transpose",
    "copyMakeBorder", "hconcat", "vconcat" };

typedef struct {
    arith_fn f_arith; addw_fn f_addw; convert_fn f_convert; bitwise_fn f_bitwise; compare_fn f_compare; inrange_fn f_inrange;
    minmax_fn f_minmax; math_fn f_math; pow_fn f_pow; mag_fn f_mag; mix_fn f_mix; flip_fn f_flip, f_rotate; trans_fn f_trans;
    border_fn f_border; lut_fn f_lut; reduce_fn f_reduce; norm_fn f_norm; sums_fn f_sums; mmloc_fn f_mmloc; cnz_fn f_cnz;
    err_fn f_lasterr;
    PyObject *g_ndarray;               /* numpy.ndarray (exact type test) */
    PyObject *g_empty;                 /* numpy.empty */
    PyObject *g_dt[7];                 /* numpy.dtype for OpenCV depths 0..6 */
    PyObject *g_error;                 /* cv2.error */
    PyObject *g_fb[FB_COUNT];
} State;
static State *S;
#define ENTER() (S = (State *)PyModule_GetState(self))
#define f_arith (S->f_arith)
#define f_addw (S->f_addw)
#define f_convert (S->f_convert)
#define f_bitwise (S->f_bitwise)
#define f_compare (S->f_compare)
#define f_inrange (S->f_inrange)
#define f_minmax (S->f_minmax)
#define f_math (S->f_math)
#define f_pow (S->f_pow)
#define f_mag (S->f_mag)
#define f_mix (S->f_mix)
#define f_flip (S->f_flip)
#define f_rotate (S->f_rotate)
#define f_trans (S->f_trans)
#define f_border (S->f_border)
#define f_lut (S->f_lut)
#define f_reduce (S->f_reduce)
#define f_norm (S->f_norm)
#define f_sums (S->f_sums)
#define f_mmloc (S->f_mmloc)
#define f_cnz (S->f_cnz)
#define f_lasterr (S->f_lasterr)
#define g_ndarray (S->g_ndarray)
#define g_empty (S->g_empty)
#define g_dt (S->g_dt)
#define g_error (S->g_error)
#define g_fb (S->g_fb)

#define FALLBACK(id) return PyObject_Vectorcall(g_fb[id], args, nargs, kwnames)

/* ---------------------------------------------------------------- errors */

static PyObject *raise_rc(const char *what, i32 rc) {
    char buf[1024];
    buf[0] = 0;
    f_lasterr(buf, 1024);
    buf[1023] = 0;
    PyObject *text = PyUnicode_DecodeUTF8(buf, (Py_ssize_t)strlen(buf), "replace");
    PyObject *msg = text ? PyUnicode_FromFormat("%s: %U (rc=%d)", what, text, (int)rc) : NULL;
    Py_XDECREF(text);
    if (msg) {
        PyObject *exc = PyObject_CallOneArg(g_error, msg);
        Py_DECREF(msg);
        if (exc) { PyErr_SetObject((PyObject *)Py_TYPE(exc), exc); Py_DECREF(exc); }
    }
    return NULL;
}

/* ---------------------------------------------------------------- argument parsing */

/* Maps positional + keyword arguments onto `n` named slots. Returns 0 if the call shape is not understood. */
static int parse(PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames, const char *const *names, int n, int minreq, PyObject **out) {
    if (nargs > n) return 0;
    for (int i = 0; i < n; i++) out[i] = i < nargs ? args[i] : NULL;
    if (kwnames) {
        Py_ssize_t nk = PyTuple_GET_SIZE(kwnames);
        for (Py_ssize_t k = 0; k < nk; k++) {
            PyObject *key = PyTuple_GET_ITEM(kwnames, k);
            int j = -1;
            for (int i = 0; i < n; i++) if (PyUnicode_CompareWithASCIIString(key, names[i]) == 0) { j = i; break; }
            if (j < 0 || out[j]) return 0;
            out[j] = args[nargs + k];
        }
    }
    for (int i = 0; i < minreq; i++) if (!out[i]) return 0;
    return 1;
}

#define OPT(o) ((o) == Py_None ? NULL : (o))

static inline int geti(PyObject *o, i32 *out) {
    if (!o || !PyLong_CheckExact(o)) return 0;
    long v = PyLong_AsLong(o);
    if (v == -1 && PyErr_Occurred()) { PyErr_Clear(); return 0; }
    if (v < INT32_MIN || v > INT32_MAX) return 0;
    *out = (i32)v;
    return 1;
}

static inline int getd(PyObject *o, double *out) {
    if (!o) return 0;
    if (PyFloat_Check(o)) { *out = PyFloat_AS_DOUBLE(o); return 1; }     /* includes numpy.float64 (a float subclass) */
    if (PyLong_CheckExact(o)) { *out = PyLong_AsDouble(o); if (*out == -1.0 && PyErr_Occurred()) { PyErr_Clear(); return 0; } return 1; }
    return 0;
}

static inline int is_num(PyObject *o) { return PyFloat_CheckExact(o) || PyLong_CheckExact(o); }

/* cv::Scalar: exact int/float (fill = broadcast to all four slots, else slot 0 only) or a tuple of <= 4 exact numbers */
static int getscalar(PyObject *o, double v[4], int fill) {
    if (!o) return 0;
    if (is_num(o)) {
        double d;
        if (!getd(o, &d)) return 0;
        v[0] = d; v[1] = v[2] = v[3] = fill ? d : 0.0;
        return 1;
    }
    if (!PyTuple_CheckExact(o)) return 0;
    Py_ssize_t n = PyTuple_GET_SIZE(o);
    if (n > 4) return 0;
    v[0] = v[1] = v[2] = v[3] = 0.0;
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject *x = PyTuple_GET_ITEM(o, i);
        if (!is_num(x) || !getd(x, &v[i])) return 0;
    }
    return 1;
}

static inline int is_arr(PyObject *o) { return o && Py_TYPE(o) == (PyTypeObject *)g_ndarray; }

/* ---------------------------------------------------------------- matrices */

typedef struct { Py_buffer pb; CoreMat m; int ndim; Py_ssize_t shape[3]; int held; } MH;

static int depth_of(const Py_buffer *v) {
    const char *f = v->format;
    if (!f || !f[0] || f[1]) return -1;
    switch (f[0]) {
        case 'B': return 0;
        case 'b': return 1;
        case 'H': return 2;
        case 'h': return 3;
        case 'i': return v->itemsize == 4 ? 4 : -1;
        case 'f': return 5;
        case 'd': return 6;
        default: return -1;
    }
}

/* Acquire an exact ndarray as a CoreMat. 1 = ok (caller must mh_release), 0 = use the Python fallback. */
static int mh_get(PyObject *o, int writable, MH *h) {
    h->held = 0;
    if (!is_arr(o)) return 0;
    if (PyObject_GetBuffer(o, &h->pb, PyBUF_STRIDES | PyBUF_FORMAT | (writable ? PyBUF_WRITABLE : 0)) < 0) { PyErr_Clear(); return 0; }
    h->held = 1;
    Py_buffer *v = &h->pb;
    int depth = depth_of(v);
    if (depth < 0 || (v->ndim != 2 && v->ndim != 3) || !v->shape || !v->strides) goto bad;
    Py_ssize_t rows = v->shape[0], cols = v->shape[1], c = v->ndim == 3 ? v->shape[2] : 1, isz = v->itemsize;
    if (rows < 1 || cols < 1 || c < 1 || c > 4096 || (v->ndim == 3 && c == 1)) goto bad;   /* 3-D with c == 1: Python canonicalises */
    if ((cols > 1 && v->strides[1] != c * isz) || (v->ndim == 3 && c > 1 && v->strides[2] != isz)) goto bad;
    Py_ssize_t rowb = cols * c * isz, step = rows > 1 ? v->strides[0] : rowb;
    if (step < rowb) goto bad;                                   /* zero / negative / overlapping rows: Python path */
    h->m.data = v->buf; h->m.rows = rows; h->m.cols = cols; h->m.step = step; h->m.cn = (i32)c; h->m.depth = depth;
    h->ndim = v->ndim;
    for (int i = 0; i < v->ndim; i++) h->shape[i] = v->shape[i];
    return 1;
bad:
    PyBuffer_Release(v);
    h->held = 0;
    return 0;
}

static inline void mh_release(MH *h) { if (h->held) { PyBuffer_Release(&h->pb); h->held = 0; } }

static inline int same_shape(const MH *a, const MH *b) {
    return a->m.depth == b->m.depth && a->ndim == b->ndim && a->shape[0] == b->shape[0] && a->shape[1] == b->shape[1] &&
           (a->ndim == 2 || a->shape[2] == b->shape[2]);
}

static inline size_t span_end(const CoreMat *m) { return (size_t)((i64)(m->rows - 1) * m->step + m->cols * m->cn * (i64)((int[]){1,1,2,2,4,4,8}[m->depth])); }
static int overlaps(const CoreMat *a, const CoreMat *b) {
    uintptr_t a0 = (uintptr_t)a->data, a1 = a0 + span_end(a), b0 = (uintptr_t)b->data, b1 = b0 + span_end(b);
    return a0 < b1 && b0 < a1;
}

/* Result array: `dst` absent -> numpy.empty(shape, dtype); present -> must already have exactly that shape/dtype/layout.
 * c == 1 yields a 2-D array (cv2 convention). 1 = ok, 0 = fallback. *ret is a new reference. */
static int out_get(PyObject *dst, Py_ssize_t rows, Py_ssize_t cols, int c, int depth, MH *o, PyObject **ret) {
    if (dst) {
        if (!mh_get(dst, 1, o)) return 0;
        if (o->m.depth != depth || o->m.rows != rows || o->m.cols != cols || o->m.cn != c || o->ndim != (c == 1 ? 2 : 3)) { mh_release(o); return 0; }
        Py_INCREF(dst);
        *ret = dst;
        return 1;
    }
    PyObject *shape = c == 1 ? Py_BuildValue("(nn)", rows, cols) : Py_BuildValue("(nni)", rows, cols, c);
    if (!shape) { PyErr_Clear(); return 0; }
    PyObject *argv[2] = { shape, g_dt[depth] };
    PyObject *arr = PyObject_Vectorcall(g_empty, argv, 2, NULL);
    Py_DECREF(shape);
    if (!arr) { PyErr_Clear(); return 0; }
    if (PyObject_GetBuffer(arr, &o->pb, PyBUF_SIMPLE) < 0) { PyErr_Clear(); Py_DECREF(arr); return 0; }
    o->held = 1;
    static const int isz[7] = { 1, 1, 2, 2, 4, 4, 8 };
    o->m.data = o->pb.buf; o->m.rows = rows; o->m.cols = cols; o->m.cn = c; o->m.depth = depth;
    o->m.step = cols * c * isz[depth];
    *ret = arr;
    return 1;
}

#define CLEANUP2(a, b) do { mh_release(a); mh_release(b); } while (0)

/* ---------------------------------------------------------------- arithmetic */

static const char *const N_ADD[] = { "src1", "src2", "dst", "mask", "dtype" };
static const char *const N_MUL[] = { "src1", "src2", "dst", "scale", "dtype" };
static const char *const N_ABS[] = { "src1", "src2", "dst" };

/* Common shape of add/subtract/absdiff/multiply/divide/bitwise/compare/min/max: (array, array|scalar) -> same-shape result. */
typedef struct { MH a, b, o; double sc[4]; int has_sc, swap; PyObject *ret; } Bin;

/* classify the two operands; scalar_fill: broadcast bare numbers to every slot. 1 ok (holding buffers), 0 fallback */
static int bin_operands(PyObject *s1, PyObject *s2, int scalar_fill, Bin *x) {
    x->a.held = x->b.held = x->o.held = 0; x->has_sc = 0; x->swap = 0; x->ret = NULL;
    int a1 = is_arr(s1), a2 = is_arr(s2);
    if (a1 && a2) {
        if (!mh_get(s1, 0, &x->a)) return 0;
        if (!mh_get(s2, 0, &x->b) || !same_shape(&x->a, &x->b)) { CLEANUP2(&x->a, &x->b); return 0; }
        return 1;
    }
    if (a1 && getscalar(s2, x->sc, scalar_fill)) { x->has_sc = 1; return mh_get(s1, 0, &x->a); }
    if (a2 && getscalar(s1, x->sc, scalar_fill)) { x->has_sc = 1; x->swap = 1; return mh_get(s2, 0, &x->a); }
    return 0;
}
static inline void bin_release(Bin *x) { mh_release(&x->a); mh_release(&x->b); mh_release(&x->o); }
static inline int bin_out(Bin *x, PyObject *dst, int depth) {
    return out_get(dst, x->a.m.rows, x->a.m.cols, x->a.m.cn, depth, &x->o, &x->ret);
}

static PyObject *arith_impl(int op, int id, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    PyObject *v[5] = { 0 };
    int mulish = op == 3 || op == 4;
    if (!parse(args, nargs, kwnames, op == 2 ? N_ABS : (mulish ? N_MUL : N_ADD), op == 2 ? 3 : 5, 2, v)) FALLBACK(id);
    double scale = 1.0;
    if (op != 2) {
        if (v[4] && !(OPT(v[4]) == NULL || (PyLong_CheckExact(v[4]) && PyLong_AsLong(v[4]) == -1))) { PyErr_Clear(); FALLBACK(id); }
        if (v[3]) {
            if (mulish) { if (!getd(v[3], &scale)) FALLBACK(id); }
            else if (OPT(v[3])) FALLBACK(id);                       /* mask */
        }
    }
    Bin x;
    if (!bin_operands(v[0], v[1], 1, &x)) FALLBACK(id);
    if (!bin_out(&x, OPT(v[2]), x.a.m.depth)) { bin_release(&x); FALLBACK(id); }
    i32 rc = f_arith(op, &x.a.m, x.has_sc ? NULL : &x.b.m, x.has_sc ? x.sc : NULL, x.swap, &x.o.m, NULL, scale);
    bin_release(&x);
    if (rc != 0) { Py_DECREF(x.ret); return raise_rc(fb_names[id], rc); }
    return x.ret;
}
static PyObject *fast_add(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return arith_impl(0, FB_ADD, args, nargs, kwnames); }
static PyObject *fast_subtract(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return arith_impl(1, FB_SUBTRACT, args, nargs, kwnames); }
static PyObject *fast_absdiff(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return arith_impl(2, FB_ABSDIFF, args, nargs, kwnames); }
static PyObject *fast_multiply(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return arith_impl(3, FB_MULTIPLY, args, nargs, kwnames); }
static PyObject *fast_divide(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return arith_impl(4, FB_DIVIDE, args, nargs, kwnames); }

static PyObject *fast_addweighted(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src1", "alpha", "src2", "beta", "gamma", "dst", "dtype" };
    PyObject *v[7] = { 0 };
    double al, be, ga;
    if (!parse(args, nargs, kwnames, names, 7, 5, v) || !getd(v[1], &al) || !getd(v[3], &be) || !getd(v[4], &ga) ||
        (v[6] && !(OPT(v[6]) == NULL || (PyLong_CheckExact(v[6]) && PyLong_AsLong(v[6]) == -1)))) { PyErr_Clear(); FALLBACK(FB_ADDWEIGHTED); }
    if (!is_arr(v[0]) || !is_arr(v[2])) FALLBACK(FB_ADDWEIGHTED);
    Bin x;
    x.a.held = x.b.held = x.o.held = 0;
    if (!mh_get(v[0], 0, &x.a)) FALLBACK(FB_ADDWEIGHTED);
    if (!mh_get(v[2], 0, &x.b) || !same_shape(&x.a, &x.b)) { CLEANUP2(&x.a, &x.b); FALLBACK(FB_ADDWEIGHTED); }
    if (!bin_out(&x, OPT(v[5]), x.a.m.depth)) { bin_release(&x); FALLBACK(FB_ADDWEIGHTED); }
    i32 rc = f_addw(&x.a.m, al, &x.b.m, be, ga, &x.o.m);
    bin_release(&x);
    if (rc != 0) { Py_DECREF(x.ret); return raise_rc("addWeighted", rc); }
    return x.ret;
}

static PyObject *fast_convertscaleabs(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "dst", "alpha", "beta" };
    PyObject *v[4] = { 0 };
    double al = 1.0, be = 0.0;
    if (!parse(args, nargs, kwnames, names, 4, 1, v) || (v[2] && !getd(v[2], &al)) || (v[3] && !getd(v[3], &be))) FALLBACK(FB_CONVERTSCALEABS);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_CONVERTSCALEABS);
    if (!out_get(OPT(v[1]), a.m.rows, a.m.cols, a.m.cn, 0, &o, &ret)) { mh_release(&a); FALLBACK(FB_CONVERTSCALEABS); }
    i32 rc = f_convert(&a.m, &o.m, al, be, 1);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("convertScaleAbs", rc); }
    return ret;
}

/* ---------------------------------------------------------------- bitwise / compare / min / max / inRange */

static PyObject *bitwise_impl(int op, int id, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    static const char *const n2[] = { "src1", "src2", "dst", "mask" };
    static const char *const n1[] = { "src", "dst", "mask" };
    PyObject *v[4] = { 0 };
    Bin x;
    if (op == 3) {
        if (!parse(args, nargs, kwnames, n1, 3, 1, v) || OPT(v[2])) FALLBACK(id);
        x.a.held = x.b.held = x.o.held = 0;
        if (!mh_get(v[0], 0, &x.a)) FALLBACK(id);
        if (!bin_out(&x, OPT(v[1]), x.a.m.depth)) { bin_release(&x); FALLBACK(id); }
    } else {
        if (!parse(args, nargs, kwnames, n2, 4, 2, v) || OPT(v[3]) || !is_arr(v[0]) || !is_arr(v[1])) FALLBACK(id);
        if (!bin_operands(v[0], v[1], 0, &x)) FALLBACK(id);
        if (!bin_out(&x, OPT(v[2]), x.a.m.depth)) { bin_release(&x); FALLBACK(id); }
    }
    i32 rc = f_bitwise(op, &x.a.m, op == 3 ? NULL : &x.b.m, NULL, &x.o.m, NULL);
    bin_release(&x);
    if (rc != 0) { Py_DECREF(x.ret); return raise_rc(fb_names[id], rc); }
    return x.ret;
}
static PyObject *fast_band(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return bitwise_impl(0, FB_BAND, args, nargs, kwnames); }
static PyObject *fast_bor(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return bitwise_impl(1, FB_BOR, args, nargs, kwnames); }
static PyObject *fast_bxor(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return bitwise_impl(2, FB_BXOR, args, nargs, kwnames); }
static PyObject *fast_bnot(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return bitwise_impl(3, FB_BNOT, args, nargs, kwnames); }

static PyObject *fast_compare(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src1", "src2", "cmpop", "dst" };
    static const i32 flip_cmp[6] = { 0, 3, 4, 1, 2, 5 };
    PyObject *v[4] = { 0 };
    i32 cmpop;
    if (!parse(args, nargs, kwnames, names, 4, 3, v) || !geti(v[2], &cmpop) || cmpop < 0 || cmpop > 5) FALLBACK(FB_COMPARE);
    Bin x;
    if (!bin_operands(v[0], v[1], 0, &x)) FALLBACK(FB_COMPARE);
    if (!bin_out(&x, OPT(v[3]), 0)) { bin_release(&x); FALLBACK(FB_COMPARE); }
    i32 rc = f_compare(x.swap ? flip_cmp[cmpop] : cmpop, &x.a.m, x.has_sc ? NULL : &x.b.m, x.has_sc ? x.sc : NULL, &x.o.m);
    bin_release(&x);
    if (rc != 0) { Py_DECREF(x.ret); return raise_rc("compare", rc); }
    return x.ret;
}

static PyObject *minmax_impl(int is_max, int id, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    static const char *const names[] = { "src1", "src2", "dst" };
    PyObject *v[3] = { 0 };
    if (!parse(args, nargs, kwnames, names, 3, 2, v)) FALLBACK(id);
    Bin x;
    if (!bin_operands(v[0], v[1], 0, &x)) FALLBACK(id);
    if (!bin_out(&x, OPT(v[2]), x.a.m.depth)) { bin_release(&x); FALLBACK(id); }
    i32 rc = f_minmax(is_max, &x.a.m, x.has_sc ? NULL : &x.b.m, x.has_sc ? x.sc : NULL, &x.o.m);
    bin_release(&x);
    if (rc != 0) { Py_DECREF(x.ret); return raise_rc(fb_names[id], rc); }
    return x.ret;
}
static PyObject *fast_min(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return minmax_impl(0, FB_MIN, args, nargs, kwnames); }
static PyObject *fast_max(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return minmax_impl(1, FB_MAX, args, nargs, kwnames); }

static PyObject *fast_inrange(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "lowerb", "upperb", "dst" };
    PyObject *v[4] = { 0 };
    double lo[4], hi[4];
    if (!parse(args, nargs, kwnames, names, 4, 3, v) || !getscalar(v[1], lo, 0) || !getscalar(v[2], hi, 0)) FALLBACK(FB_INRANGE);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_INRANGE);
    if (!out_get(OPT(v[3]), a.m.rows, a.m.cols, 1, 0, &o, &ret)) { mh_release(&a); FALLBACK(FB_INRANGE); }
    i32 rc = f_inrange(&a.m, NULL, NULL, lo, hi, &o.m);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("inRange", rc); }
    return ret;
}

/* ---------------------------------------------------------------- element-wise math */

static PyObject *math_impl(int op, int id, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    static const char *const names[] = { "src", "dst" };
    PyObject *v[2] = { 0 };
    if (!parse(args, nargs, kwnames, names, 2, 1, v)) FALLBACK(id);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(id);
    if (a.m.depth < 5 || !out_get(OPT(v[1]), a.m.rows, a.m.cols, a.m.cn, a.m.depth, &o, &ret)) { mh_release(&a); FALLBACK(id); }
    i32 rc = f_math(op, &a.m, &o.m);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc(fb_names[id], rc); }
    return ret;
}
static PyObject *fast_sqrt(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return math_impl(0, FB_SQRT, args, nargs, kwnames); }
static PyObject *fast_exp(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return math_impl(1, FB_EXP, args, nargs, kwnames); }
static PyObject *fast_log(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return math_impl(2, FB_LOG, args, nargs, kwnames); }

static PyObject *fast_pow(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "power", "dst" };
    PyObject *v[3] = { 0 };
    double p;
    if (!parse(args, nargs, kwnames, names, 3, 2, v) || !getd(v[1], &p)) FALLBACK(FB_POW);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_POW);
    if (!out_get(OPT(v[2]), a.m.rows, a.m.cols, a.m.cn, a.m.depth, &o, &ret)) { mh_release(&a); FALLBACK(FB_POW); }
    i32 rc = f_pow(&a.m, &o.m, p);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("pow", rc); }
    return ret;
}

static PyObject *fast_magnitude(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "x", "y", "magnitude" };
    PyObject *v[3] = { 0 };
    if (!parse(args, nargs, kwnames, names, 3, 2, v) || !is_arr(v[0]) || !is_arr(v[1])) FALLBACK(FB_MAGNITUDE);
    Bin x;
    x.a.held = x.b.held = x.o.held = 0;
    if (!mh_get(v[0], 0, &x.a)) FALLBACK(FB_MAGNITUDE);
    if (!mh_get(v[1], 0, &x.b) || !same_shape(&x.a, &x.b) || x.a.m.depth < 5) { CLEANUP2(&x.a, &x.b); FALLBACK(FB_MAGNITUDE); }
    if (!bin_out(&x, OPT(v[2]), x.a.m.depth)) { bin_release(&x); FALLBACK(FB_MAGNITUDE); }
    i32 rc = f_mag(&x.a.m, &x.b.m, &x.o.m);
    bin_release(&x);
    if (rc != 0) { Py_DECREF(x.ret); return raise_rc("magnitude", rc); }
    return x.ret;
}

/* ---------------------------------------------------------------- LUT */

static PyObject *fast_lut(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "lut", "dst" };
    PyObject *v[3] = { 0 };
    if (!parse(args, nargs, kwnames, names, 3, 2, v) || !is_arr(v[1])) FALLBACK(FB_LUT);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_LUT);
    Py_buffer lb;
    if (a.m.depth > 1 || PyObject_GetBuffer(v[1], &lb, PyBUF_C_CONTIGUOUS | PyBUF_FORMAT | PyBUF_ND) < 0) { PyErr_Clear(); mh_release(&a); FALLBACK(FB_LUT); }
    int ld = depth_of(&lb);
    Py_ssize_t lcn = lb.ndim == 3 ? lb.shape[2] : 1;
    if (ld < 0 || lb.ndim < 1 || lb.ndim > 3 || lb.len != 256 * lcn * lb.itemsize || (lcn != 1 && lcn != a.m.cn)) {
        PyBuffer_Release(&lb); mh_release(&a); FALLBACK(FB_LUT);
    }
    if (!out_get(OPT(v[2]), a.m.rows, a.m.cols, a.m.cn, ld, &o, &ret)) { PyBuffer_Release(&lb); mh_release(&a); FALLBACK(FB_LUT); }
    i32 rc = f_lut(&a.m, lb.buf, (i32)lcn, &o.m);
    PyBuffer_Release(&lb);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("LUT", rc); }
    return ret;
}

/* ---------------------------------------------------------------- reductions */

static PyObject *fast_reduce(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "dim", "rtype", "dst", "dtype" };
    static const unsigned sum_ok[7] = { 0x70, 0x70, 0x60, 0x60, 0x40, 0x60, 0x40 };
    static const unsigned avg_ok[7] = { 0x7f, 0x7f, 0x60, 0x60, 0x40, 0x60, 0x40 };
    PyObject *v[5] = { 0 };
    i32 dim, rtype, dd = -1;
    if (!parse(args, nargs, kwnames, names, 5, 3, v) || !geti(v[1], &dim) || !geti(v[2], &rtype) || dim < 0 || dim > 1 || rtype < 0 || rtype > 3 ||
        (OPT(v[4]) && !geti(v[4], &dd))) FALLBACK(FB_REDUCE);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_REDUCE);
    int sd = a.m.depth;
    if (dd < 0) dd = sd;
    unsigned ok = rtype == 0 ? sum_ok[sd] : rtype == 1 ? avg_ok[sd] : (1u << sd);
    if (dd > 6 || !((ok >> dd) & 1)) { mh_release(&a); FALLBACK(FB_REDUCE); }
    Py_ssize_t orows = dim == 0 ? 1 : a.m.rows, ocols = dim == 0 ? a.m.cols : 1;
    if (!out_get(OPT(v[3]), orows, ocols, a.m.cn, dd, &o, &ret)) { mh_release(&a); FALLBACK(FB_REDUCE); }
    i32 rc = f_reduce(&a.m, &o.m, dim, rtype);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("reduce", rc); }
    return ret;
}

/* mask argument: absent/None -> none; else a (rows, cols) uint8/int8 array. 1 = ok (mh held iff *mp set), 0 = fallback */
static int mask_get(PyObject *mo, const MH *a, MH *m, MP *mp) {
    *mp = NULL; m->held = 0;
    mo = OPT(mo);
    if (!mo) return 1;
    if (!mh_get(mo, 0, m)) return 0;
    if (m->ndim != 2 || m->m.depth > 1 || m->m.rows != a->m.rows || m->m.cols != a->m.cols) { mh_release(m); return 0; }
    *mp = &m->m;
    return 1;
}

static PyObject *fast_norm(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    if (kwnames || nargs < 1 || nargs > 3) FALLBACK(FB_NORM);
    i32 nt = 4;
    PyObject *s2 = NULL;
    if (nargs >= 2) {
        if (PyLong_CheckExact(args[1])) { if (nargs != 2 || !geti(args[1], &nt)) FALLBACK(FB_NORM); }
        else if (is_arr(args[1])) { s2 = args[1]; if (nargs == 3 && !geti(args[2], &nt)) FALLBACK(FB_NORM); }
        else FALLBACK(FB_NORM);
    }
    if (nt != 1 && nt != 2 && nt != 4 && nt != 5) FALLBACK(FB_NORM);
    MH a, b;
    b.held = 0;
    if (!mh_get(args[0], 0, &a)) FALLBACK(FB_NORM);
    if (s2 && (!mh_get(s2, 0, &b) || !same_shape(&a, &b))) { CLEANUP2(&a, &b); FALLBACK(FB_NORM); }
    double out = 0.0;
    i32 rc = f_norm(&a.m, s2 ? &b.m : NULL, NULL, nt, &out);
    CLEANUP2(&a, &b);
    if (rc != 0) return raise_rc("norm", rc);
    return PyFloat_FromDouble(out);
}

static PyObject *fast_mean(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "mask" };
    PyObject *v[2] = { 0 };
    if (!parse(args, nargs, kwnames, names, 2, 1, v)) FALLBACK(FB_MEAN);
    MH a, m; MP mp;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_MEAN);
    if (a.m.cn > 4 || !mask_get(v[1], &a, &m, &mp)) { mh_release(&a); FALLBACK(FB_MEAN); }
    double o[9] = { 0 };
    i32 rc = f_sums(&a.m, mp, o, 0);
    CLEANUP2(&a, &m);
    if (rc != 0) return raise_rc("mean", rc);
    double inv = o[8] != 0.0 ? 1.0 / o[8] : 0.0;
    return Py_BuildValue("(dddd)", o[0] * inv, o[1] * inv, o[2] * inv, o[3] * inv);
}

static PyObject *fast_meanstddev(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "mean", "stddev", "mask" };
    PyObject *v[4] = { 0 };
    if (!parse(args, nargs, kwnames, names, 4, 1, v) || OPT(v[1]) || OPT(v[2])) FALLBACK(FB_MEANSTDDEV);
    MH a, m, mu, sd; MP mp; PyObject *rmu, *rsd;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_MEANSTDDEV);
    if (a.m.cn > 4 || !mask_get(v[3], &a, &m, &mp)) { mh_release(&a); FALLBACK(FB_MEANSTDDEV); }
    int cn = a.m.cn;
    double o[9] = { 0 };
    i32 rc = f_sums(&a.m, mp, o, 1);
    CLEANUP2(&a, &m);
    if (rc != 0) return raise_rc("meanStdDev", rc);
    if (!out_get(NULL, cn, 1, 1, 6, &mu, &rmu)) FALLBACK(FB_MEANSTDDEV);
    if (!out_get(NULL, cn, 1, 1, 6, &sd, &rsd)) { mh_release(&mu); Py_DECREF(rmu); FALLBACK(FB_MEANSTDDEV); }
    double inv = o[8] != 0.0 ? 1.0 / o[8] : 0.0;
    double *pm = (double *)mu.m.data, *ps = (double *)sd.m.data;
    for (int c = 0; c < cn; c++) {
        double mc = o[c] * inv, var = fma(o[4 + c], inv, -(mc * mc));   /* cv2: sq * scale - mean * mean as one fma */
        if (0.0 > var) var = 0.0;                               /* Python max(var, 0.0): keeps NaN and -0.0 */
        pm[c] = mc; ps[c] = sqrt(var);
    }
    CLEANUP2(&mu, &sd);
    PyObject *r = PyTuple_Pack(2, rmu, rsd);
    Py_DECREF(rmu); Py_DECREF(rsd);
    return r;
}

static PyObject *fast_minmaxloc(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "mask" };
    PyObject *v[2] = { 0 };
    if (!parse(args, nargs, kwnames, names, 2, 1, v)) FALLBACK(FB_MINMAXLOC);
    MH a, m; MP mp;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_MINMAXLOC);
    if (a.m.cn != 1 || !mask_get(v[1], &a, &m, &mp)) { mh_release(&a); FALLBACK(FB_MINMAXLOC); }
    double o[7] = { 0 };
    i32 rc = f_mmloc(&a.m, mp, o);
    CLEANUP2(&a, &m);
    if (rc != 0) return raise_rc("minMaxLoc", rc);
    return Py_BuildValue("(dd(ii)(ii))", o[0], o[1], (int)o[2], (int)o[3], (int)o[4], (int)o[5]);
}

static PyObject *fast_countnonzero(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src" };
    PyObject *v[1] = { 0 };
    if (!parse(args, nargs, kwnames, names, 1, 1, v)) FALLBACK(FB_COUNTNONZERO);
    MH a;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_COUNTNONZERO);
    if (a.m.cn != 1) { mh_release(&a); FALLBACK(FB_COUNTNONZERO); }
    i64 out = 0;
    i32 rc = f_cnz(&a.m, &out);
    mh_release(&a);
    if (rc != 0) return raise_rc("countNonZero", rc);
    return PyLong_FromLongLong(out);
}

/* ---------------------------------------------------------------- channels / geometry */

#define MAXCH 8

static PyObject *fast_split(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "m", "mv" };
    PyObject *v[2] = { 0 };
    if (!parse(args, nargs, kwnames, names, 2, 1, v) || OPT(v[1])) FALLBACK(FB_SPLIT);
    MH a;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_SPLIT);
    int cn = a.m.cn;
    if (a.ndim != 3 || cn < 2 || cn > MAXCH) { mh_release(&a); FALLBACK(FB_SPLIT); }
    MH o[MAXCH]; PyObject *rets[MAXCH]; CoreMat dm[MAXCH]; i32 ft[2 * MAXCH];
    int got = 0;
    for (; got < cn; got++) {
        if (!out_get(NULL, a.m.rows, a.m.cols, 1, a.m.depth, &o[got], &rets[got])) break;
        dm[got] = o[got].m; ft[2 * got] = got; ft[2 * got + 1] = got;
    }
    i32 rc = got == cn ? f_mix(1, &a.m, cn, dm, cn, ft) : -1;
    mh_release(&a);
    for (int i = 0; i < got; i++) mh_release(&o[i]);
    if (got != cn || rc != 0) {
        for (int i = 0; i < got; i++) Py_DECREF(rets[i]);
        if (got != cn) FALLBACK(FB_SPLIT);
        return raise_rc("split", rc);
    }
    PyObject *t = PyTuple_New(cn);
    if (!t) { for (int i = 0; i < cn; i++) Py_DECREF(rets[i]); return NULL; }
    for (int i = 0; i < cn; i++) PyTuple_SET_ITEM(t, i, rets[i]);
    return t;
}

static PyObject *fast_merge(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "mv", "dst" };
    PyObject *v[2] = { 0 };
    if (!parse(args, nargs, kwnames, names, 2, 1, v)) FALLBACK(FB_MERGE);
    PyObject *seq = v[0];
    PyObject **items; Py_ssize_t n;
    if (PyList_CheckExact(seq)) { items = ((PyListObject *)seq)->ob_item; n = PyList_GET_SIZE(seq); }
    else if (PyTuple_CheckExact(seq)) { items = ((PyTupleObject *)seq)->ob_item; n = PyTuple_GET_SIZE(seq); }
    else FALLBACK(FB_MERGE);
    if (n < 2 || n > MAXCH) FALLBACK(FB_MERGE);
    MH p[MAXCH]; CoreMat sm[MAXCH]; i32 ft[2 * MAXCH];
    int got = 0, ok = 1;
    for (; got < n; got++) {
        if (!mh_get(items[got], 0, &p[got])) { ok = 0; break; }
        if (p[got].ndim != 2 || (got && !same_shape(&p[0], &p[got]))) { got++; ok = 0; break; }
        sm[got] = p[got].m; ft[2 * got] = got; ft[2 * got + 1] = got;
    }
    MH o; PyObject *ret = NULL;
    if (ok && !out_get(OPT(v[1]), p[0].m.rows, p[0].m.cols, (int)n, p[0].m.depth, &o, &ret)) ok = 0;
    i32 rc = ok ? f_mix((i32)n, sm, 1, &o.m, (i32)n, ft) : 0;
    for (int i = 0; i < got; i++) mh_release(&p[i]);
    if (!ok) FALLBACK(FB_MERGE);
    mh_release(&o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("merge", rc); }
    return ret;
}

static PyObject *fast_flip(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "flipCode", "dst" };
    PyObject *v[3] = { 0 };
    i32 code;
    if (!parse(args, nargs, kwnames, names, 3, 2, v) || !geti(v[1], &code)) FALLBACK(FB_FLIP);
    PyObject *dst = OPT(v[2]);
    MH a, o; PyObject *ret;
    if (dst && dst == v[0]) {                                   /* in place */
        if (!mh_get(dst, 1, &a)) FALLBACK(FB_FLIP);
        i32 rc = f_flip(&a.m, &a.m, code);
        mh_release(&a);
        if (rc != 0) return raise_rc("flip", rc);
        Py_INCREF(dst);
        return dst;
    }
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_FLIP);
    if (!out_get(dst, a.m.rows, a.m.cols, a.m.cn, a.m.depth, &o, &ret)) { mh_release(&a); FALLBACK(FB_FLIP); }
    if (dst && overlaps(&a.m, &o.m)) { CLEANUP2(&a, &o); Py_DECREF(ret); FALLBACK(FB_FLIP); }
    i32 rc = f_flip(&a.m, &o.m, code);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("flip", rc); }
    return ret;
}

static PyObject *fast_rotate(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "rotateCode", "dst" };
    PyObject *v[3] = { 0 };
    i32 code;
    if (!parse(args, nargs, kwnames, names, 3, 2, v) || !geti(v[1], &code) || code < 0 || code > 2) FALLBACK(FB_ROTATE);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_ROTATE);
    Py_ssize_t orows = code == 1 ? a.m.rows : a.m.cols, ocols = code == 1 ? a.m.cols : a.m.rows;
    if (!out_get(OPT(v[2]), orows, ocols, a.m.cn, a.m.depth, &o, &ret)) { mh_release(&a); FALLBACK(FB_ROTATE); }
    if (OPT(v[2]) && overlaps(&a.m, &o.m)) { CLEANUP2(&a, &o); Py_DECREF(ret); FALLBACK(FB_ROTATE); }
    i32 rc = f_rotate(&a.m, &o.m, code);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("rotate", rc); }
    return ret;
}

static PyObject *fast_transpose(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "dst" };
    PyObject *v[2] = { 0 };
    if (!parse(args, nargs, kwnames, names, 2, 1, v)) FALLBACK(FB_TRANSPOSE);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_TRANSPOSE);
    if (!out_get(OPT(v[1]), a.m.cols, a.m.rows, a.m.cn, a.m.depth, &o, &ret)) { mh_release(&a); FALLBACK(FB_TRANSPOSE); }
    if (OPT(v[1]) && overlaps(&a.m, &o.m)) { CLEANUP2(&a, &o); Py_DECREF(ret); FALLBACK(FB_TRANSPOSE); }
    i32 rc = f_trans(&a.m, &o.m);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("transpose", rc); }
    return ret;
}

static PyObject *fast_copymakeborder(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    ENTER();
    static const char *const names[] = { "src", "top", "bottom", "left", "right", "borderType", "dst", "value" };
    PyObject *v[8] = { 0 };
    i32 top, bottom, left, right, bt;
    double val[4] = { 0, 0, 0, 0 };
    if (!parse(args, nargs, kwnames, names, 8, 6, v) || !geti(v[1], &top) || !geti(v[2], &bottom) || !geti(v[3], &left) || !geti(v[4], &right) ||
        !geti(v[5], &bt) || top < 0 || bottom < 0 || left < 0 || right < 0 || (!top && !bottom && !left && !right) ||
        (bt & ~16) < 0 || (bt & ~16) > 4 || (OPT(v[7]) && !getscalar(v[7], val, 0))) FALLBACK(FB_COPYMAKEBORDER);
    MH a, o; PyObject *ret;
    if (!mh_get(v[0], 0, &a)) FALLBACK(FB_COPYMAKEBORDER);
    Py_ssize_t orows = a.m.rows + (Py_ssize_t)top + bottom, ocols = a.m.cols + (Py_ssize_t)left + right;
    if (a.m.cn > 4 && (bt & ~16) == 0) { mh_release(&a); FALLBACK(FB_COPYMAKEBORDER); }   /* uniform-value rule for > 4 channels */
    if (orows > INT32_MAX || ocols > INT32_MAX || !out_get(OPT(v[6]), orows, ocols, a.m.cn, a.m.depth, &o, &ret)) { mh_release(&a); FALLBACK(FB_COPYMAKEBORDER); }
    i32 rc = f_border(&a.m, &o.m, top, left, bt, val);
    CLEANUP2(&a, &o);
    if (rc != 0) { Py_DECREF(ret); return raise_rc("copyMakeBorder", rc); }
    return ret;
}


/* hconcat / vconcat of 2..16 same-type arrays (row / column counts equal): memcpy of rows into numpy.empty or a matching dst */
static PyObject *concat_impl(int vertical, int id, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) {
    static const char *const names[] = { "src", "dst" };
    PyObject *v[2] = { 0 };
    if (!parse(args, nargs, kwnames, names, 2, 1, v)) FALLBACK(id);
    PyObject **items; Py_ssize_t n;
    if (PyList_CheckExact(v[0])) { items = ((PyListObject *)v[0])->ob_item; n = PyList_GET_SIZE(v[0]); }
    else if (PyTuple_CheckExact(v[0])) { items = ((PyTupleObject *)v[0])->ob_item; n = PyTuple_GET_SIZE(v[0]); }
    else FALLBACK(id);
    if (n < 2 || n > 16) FALLBACK(id);
    MH p[16];
    int got = 0, ok = 1;
    Py_ssize_t total = 0;
    for (; got < n; got++) {
        if (!mh_get(items[got], 0, &p[got])) { ok = 0; break; }
        const MH *f = &p[0];
        int same = got == 0 || (p[got].m.depth == f->m.depth && p[got].ndim == f->ndim && p[got].m.cn == f->m.cn &&
                                (vertical ? p[got].m.cols == f->m.cols : p[got].m.rows == f->m.rows));
        total += vertical ? p[got].m.rows : p[got].m.cols;
        if (!same) { got++; ok = 0; break; }
    }
    MH o; PyObject *ret = NULL;
    PyObject *dst = OPT(v[1]);
    if (ok && !out_get(dst, vertical ? total : p[0].m.rows, vertical ? p[0].m.cols : total, p[0].m.cn, p[0].m.depth, &o, &ret)) ok = 0;
    if (ok && dst) for (int i = 0; i < got; i++) if (overlaps(&p[i].m, &o.m)) { mh_release(&o); Py_DECREF(ret); ok = 0; break; }
    if (ok) {
        static const int isz[7] = { 1, 1, 2, 2, 4, 4, 8 };
        size_t pb = (size_t)p[0].m.cn * isz[p[0].m.depth];
        size_t off = 0;
        for (int i = 0; i < got; i++) {
            size_t rb = (size_t)p[i].m.cols * pb;
            for (Py_ssize_t y = 0; y < p[i].m.rows; y++) {
                uint8_t *dp = (uint8_t *)o.m.data + (vertical ? (size_t)(off + y) * o.m.step : (size_t)y * o.m.step + off);
                memcpy(dp, (const uint8_t *)p[i].m.data + (size_t)y * p[i].m.step, rb);
            }
            off += vertical ? (size_t)p[i].m.rows : rb;
        }
        mh_release(&o);
    }
    for (int i = 0; i < got; i++) mh_release(&p[i]);
    if (!ok) FALLBACK(id);
    return ret;
}
static PyObject *fast_hconcat(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return concat_impl(0, FB_HCONCAT, args, nargs, kwnames); }
static PyObject *fast_vconcat(PyObject *self, PyObject *const *args, Py_ssize_t nargs, PyObject *kwnames) { ENTER(); return concat_impl(1, FB_VCONCAT, args, nargs, kwnames); }

/* ---------------------------------------------------------------- module */

static PyObject *srcore_init(PyObject *self, PyObject *args) {
    ENTER();
    const char *path;
    PyObject *err, *fbs;
    if (!PyArg_ParseTuple(args, "sOO", &path, &err, &fbs)) return NULL;
    if (!PyDict_Check(fbs)) { PyErr_SetString(PyExc_TypeError, "fallbacks must be a dict"); return NULL; }
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { PyErr_Format(PyExc_ImportError, "dlopen failed: %s", dlerror()); return NULL; }
#define SYM(var, type, name) do { var = (type)dlsym(h, name); if (!var) { PyErr_Format(PyExc_ImportError, "libSafariumRaster is missing %s", name); return NULL; } } while (0)
    SYM(f_arith, arith_fn, "sr_core_arith"); SYM(f_addw, addw_fn, "sr_core_addweighted"); SYM(f_convert, convert_fn, "sr_core_convert");
    SYM(f_bitwise, bitwise_fn, "sr_core_bitwise"); SYM(f_compare, compare_fn, "sr_core_compare"); SYM(f_inrange, inrange_fn, "sr_core_inrange");
    SYM(f_minmax, minmax_fn, "sr_core_minmax"); SYM(f_math, math_fn, "sr_core_math"); SYM(f_pow, pow_fn, "sr_core_pow");
    SYM(f_mag, mag_fn, "sr_core_magnitude"); SYM(f_mix, mix_fn, "sr_core_mixchannels"); SYM(f_flip, flip_fn, "sr_core_flip");
    SYM(f_rotate, flip_fn, "sr_core_rotate"); SYM(f_trans, trans_fn, "sr_core_transpose"); SYM(f_border, border_fn, "sr_core_copymakeborder");
    SYM(f_lut, lut_fn, "sr_core_lut"); SYM(f_reduce, reduce_fn, "sr_core_reduce"); SYM(f_norm, norm_fn, "sr_core_norm");
    SYM(f_sums, sums_fn, "sr_core_sums"); SYM(f_mmloc, mmloc_fn, "sr_core_minmaxloc"); SYM(f_cnz, cnz_fn, "sr_core_countnonzero");
    SYM(f_lasterr, err_fn, "sr_last_error");
#undef SYM
    PyObject *np = PyImport_ImportModule("numpy");
    if (!np) return NULL;
    Py_XDECREF(g_ndarray); Py_XDECREF(g_empty);
    g_ndarray = PyObject_GetAttrString(np, "ndarray");
    g_empty = PyObject_GetAttrString(np, "empty");
    static const char *const dtn[7] = { "uint8", "int8", "uint16", "int16", "int32", "float32", "float64" };
    for (int i = 0; i < 7; i++) { Py_XDECREF(g_dt[i]); g_dt[i] = PyObject_CallMethod(np, "dtype", "s", dtn[i]); if (!g_dt[i]) { Py_DECREF(np); return NULL; } }
    Py_DECREF(np);
    if (!g_ndarray || !g_empty) return NULL;
    Py_XDECREF(g_error); Py_INCREF(err); g_error = err;
    for (int i = 0; i < FB_COUNT; i++) {
        PyObject *f = PyDict_GetItemString(fbs, fb_names[i]);
        if (!f) { PyErr_Format(PyExc_ValueError, "missing fallback for %s", fb_names[i]); return NULL; }
        Py_XDECREF(g_fb[i]); Py_INCREF(f); g_fb[i] = f;
    }
    Py_RETURN_TRUE;
}

#define FAST(pyname, fn) { pyname, (PyCFunction)(void (*)(void))fn, METH_FASTCALL | METH_KEYWORDS, "cv2." pyname }
static PyMethodDef methods[] = {
    { "init", srcore_init, METH_VARARGS, "init(dylib_path, error_class, {name: python fallback})" },
    FAST("add", fast_add), FAST("subtract", fast_subtract), FAST("absdiff", fast_absdiff), FAST("multiply", fast_multiply),
    FAST("divide", fast_divide), FAST("addWeighted", fast_addweighted), FAST("convertScaleAbs", fast_convertscaleabs),
    FAST("bitwise_and", fast_band), FAST("bitwise_or", fast_bor), FAST("bitwise_xor", fast_bxor), FAST("bitwise_not", fast_bnot),
    FAST("compare", fast_compare), FAST("inRange", fast_inrange), FAST("min", fast_min), FAST("max", fast_max),
    FAST("sqrt", fast_sqrt), FAST("exp", fast_exp), FAST("log", fast_log), FAST("pow", fast_pow), FAST("magnitude", fast_magnitude),
    FAST("LUT", fast_lut), FAST("reduce", fast_reduce), FAST("norm", fast_norm), FAST("mean", fast_mean),
    FAST("meanStdDev", fast_meanstddev), FAST("minMaxLoc", fast_minmaxloc), FAST("countNonZero", fast_countnonzero),
    FAST("split", fast_split), FAST("merge", fast_merge), FAST("flip", fast_flip), FAST("rotate", fast_rotate),
    FAST("transpose", fast_transpose), FAST("copyMakeBorder", fast_copymakeborder), FAST("hconcat", fast_hconcat), FAST("vconcat", fast_vconcat),
    { NULL, NULL, 0, NULL },
};

#undef g_ndarray
#undef g_empty
#undef g_dt
#undef g_error
#undef g_fb
static void srcore_free(void *m) {
    State *st = (State *)PyModule_GetState((PyObject *)m);
    if (!st) return;
    Py_CLEAR(st->g_ndarray); Py_CLEAR(st->g_empty); Py_CLEAR(st->g_error);
    for (int i = 0; i < 7; i++) Py_CLEAR(st->g_dt[i]);
    for (int i = 0; i < FB_COUNT; i++) Py_CLEAR(st->g_fb[i]);
}

static struct PyModuleDef moddef = { PyModuleDef_HEAD_INIT, "_srcore", "low-overhead core bridge to libSafariumRaster",
                                     (Py_ssize_t)sizeof(State), methods, NULL, NULL, NULL, srcore_free };

PyMODINIT_FUNC PyInit__srcore(void) { return PyModule_Create(&moddef); }
