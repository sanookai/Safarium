// SafariumRasterC — Phase 1 (core-numeric) NEON kernels. Owner: core area (docs/raster-plan.md).
#ifndef SR_CORE_H
#define SR_CORE_H
#include <stdint.h>
#include <stddef.h>

// transpose / rotate of pb-byte pixels. mode: 0 transpose, 1 rotate 90 clockwise, 2 rotate 90 counter-clockwise.
void src_transpose(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint8_t *d, ptrdiff_t ds, int pb, int mode);

// saturating add / sub / absdiff over n elements. type: 0 u8, 1 s8, 2 u16, 3 s16. op: 0 add, 1 sub, 2 absdiff.
void src_addsub(int type, int op, const void *a, const void *b, void *d, size_t n);
// f32 / f64 binary ops: op 0 add, 1 sub, 2 absdiff, 3 mul ((scale*a)*b), 4 div ((a*scale)/b)
void src_fbin32(int op, const float *a, const float *b, float *d, size_t n, float scale);
void src_fbin64(int op, const double *a, const double *b, double *d, size_t n, double scale);
void src_sqrt32(const float *a, float *d, size_t n);

// dst = saturate(round_even(fma(x, alpha, beta))) (abs first when absf). Source/dest: 0 u8, 5 f32.
void src_cvt(int sdepth, int ddepth, const void *s, void *d, size_t n, float alpha, float beta, int absf);
// u8 pairs: d = sat(round(fma(a, alpha, fma(b, beta, gamma)))) ; f32 same without rounding
void src_addw_u8(const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n, float alpha, float beta, float gamma);
void src_addw_f32(const float *a, const float *b, float *d, size_t n, float alpha, float beta, float gamma);
void src_mul_u8(const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n, float scale);

// sums over u8 data
uint64_t src_sum_u8(const uint8_t *p, size_t n);
uint64_t src_sumsq_u8(const uint8_t *p, size_t n);
uint64_t src_sumsq_absdiff_u8(const uint8_t *a, const uint8_t *b, size_t n);
uint64_t src_sum_absdiff_u8(const uint8_t *a, const uint8_t *b, size_t n);
// per-channel sum and sum of squares of interleaved u8 pixels (cn 1..4); s, q: uint64[4] accumulators
void src_sums_u8_cn(const uint8_t *p, size_t cols, int cn, uint64_t *s, uint64_t *q, int want_sq);
void src_minmax_u8(const uint8_t *p, size_t n, uint8_t *mn, uint8_t *mx);
void src_minmax_f32(const float *p, size_t n, float *mn, float *mx);
uint8_t src_maxabsdiff_u8(const uint8_t *a, const uint8_t *b, size_t n);
size_t src_count_nz_u8(const uint8_t *p, size_t n);
size_t src_count_nz_f32(const float *p, size_t n);
// acc[i] += row[i] (u32), and row-wise max/min of u8
void src_acc_u8_u32(uint32_t *acc, const uint8_t *row, size_t n);
void src_max_u8_rows(uint8_t *acc, const uint8_t *row, size_t n, int is_max);

// OpenCV randu (integer destinations, fast path): fills n elements of `out` (u8..s32 by depth) from the MWC state.
// ia/idiff per channel, ch0 = channel of out[0]. mode: 0 general (t % d), 1 fast mask, 2 small (4 values per draw).
void src_randu_int(int depth, void *out, int n, uint64_t *state, const int32_t *ia, const int32_t *idiff, int cn, int ch0,
                   int mode);
void src_randn_f32(float *out, int n, uint64_t *state);
// in place over n float32 samples of channel pattern ch0, ch0+1, ... mod cn: out = fmaf(out, std[c], mean[c])
void src_randn_affine_f32(float *out, int n, const float *mean, const float *std, int cn, int ch0);
void src_fliph_row(const uint8_t *s, uint8_t *d, int cols, int pb);

// reduce kernels: column sums of a u8 plane (u32 out, overwritten); row sums of an f32 plane in OpenCV's reduceC order
void src_colsum_u8(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint32_t *out);
void src_rowsum_f32(const uint8_t *base, ptrdiff_t stride, int rows, int width, float *out);
// masked per-channel u8 sums (cn 1..4): s, q, count accumulate (uint64)
void src_sums_u8_mask(const uint8_t *p, const uint8_t *m, size_t cols, int cn, uint64_t *s, uint64_t *q, uint64_t *count, int want_sq);
// saturating add/sub/absdiff against a repeating pattern (48-byte stream, cn <= 4, 1- and 2-byte elements); swap: pattern - a
void src_addsub_pat(int type, int op, int swap, const void *a, const uint8_t *pat, void *d, size_t n);
// compare to 255/0. op: 0 EQ, 1 GT, 2 GE, 3 LT, 4 LE, 5 NE. src_cmp_f32: b == NULL compares against the scalar s
void src_cmp_u8(int op, const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n);
void src_cmp_f32(int op, const float *a, const float *b, float s, uint8_t *d, size_t n);
void src_exp32(const float *a, float *d, size_t n);
// d[i] = tab[s[i]] over n bytes (256-entry table); d == s allowed
void src_lut_u8(const uint8_t *s, uint8_t *d, size_t n, const uint8_t *tab);
// max |a| (b == NULL) or max |a - b| over n floats; NaN in the input gives NaN
float src_maxabs_f32(const float *a, const float *b, size_t n);
// atan2(y, x) in [0, 360) degrees times scale (OpenCV's float32 fastAtan2 operation order)
void src_phase32(const float *x, const float *y, float *o, size_t n, float scale);
// copyMakeBorder (types 0 constant, 1 replicate, 2 reflect, 3 wrap, 4 reflect101). Returns 0 or -1 (out of memory).
int src_copyborder(const uint8_t *s, ptrdiff_t ss, int srows, int scols, uint8_t *d, ptrdiff_t ds, int top, int bottom, int left, int right,
                   int pb, int type, const uint8_t *cpix);
// cvtColor BGR/RGB(A) -> HSV (hrange 180) for u8 rows. slut/slut_tail: 65536-byte [v << 8 | v - min] -> S tables for the
// 8-pixel blocks and for the last cols % 8 pixels of each row; hdiv: 256 entries round((180 << 12) / (6 * diff)).
void src_hsv_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep, int rows, int cols, int scn, int blue_idx,
                const uint8_t *slut, const uint8_t *slut_tail, const int32_t *hdiv);
#endif
