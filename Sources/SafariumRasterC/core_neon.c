// SafariumRasterC — Phase 1 NEON kernels (see include/sr_core.h). Same numerics as the Swift reference paths.
#include "SafariumRasterC.h"
#include <arm_neon.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

// ------------------------------------------------------------------ transpose / rotate
#define TRANSP_KERNEL(PB)                                                                                           \
    static void transp_##PB(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint8_t *d, ptrdiff_t ds, int mode) { \
        const int B = 32;                                                                                           \
        for (int by = 0; by < rows; by += B) {                                                                      \
            int ye = by + B < rows ? by + B : rows;                                                                 \
            for (int bx = 0; bx < cols; bx += B) {                                                                  \
                int xe = bx + B < cols ? bx + B : cols;                                                             \
                for (int y = by; y < ye; y++) {                                                                     \
                    const uint8_t *sp = s + (ptrdiff_t)y * ss + (ptrdiff_t)bx * PB;                                 \
                    for (int x = bx; x < xe; x++, sp += PB) {                                                       \
                        int dy, dx;                                                                                 \
                        if (mode == 0) { dy = x; dx = y; }                                                          \
                        else if (mode == 1) { dy = x; dx = rows - 1 - y; }                                          \
                        else { dy = cols - 1 - x; dx = y; }                                                         \
                        memcpy(d + (ptrdiff_t)dy * ds + (ptrdiff_t)dx * PB, sp, PB);                                \
                    }                                                                                               \
                }                                                                                                   \
            }                                                                                                       \
        }                                                                                                           \
    }
TRANSP_KERNEL(2) TRANSP_KERNEL(3) TRANSP_KERNEL(4) TRANSP_KERNEL(6) TRANSP_KERNEL(8) TRANSP_KERNEL(12) TRANSP_KERNEL(16)

// 8-bit: 8x8 NEON tile transpose
static inline void tile8x8_u8(const uint8_t *s, ptrdiff_t ss, uint8_t *d, ptrdiff_t ds) {
    uint8x8_t r0 = vld1_u8(s), r1 = vld1_u8(s + ss), r2 = vld1_u8(s + 2 * ss), r3 = vld1_u8(s + 3 * ss);
    uint8x8_t r4 = vld1_u8(s + 4 * ss), r5 = vld1_u8(s + 5 * ss), r6 = vld1_u8(s + 6 * ss), r7 = vld1_u8(s + 7 * ss);
    uint8x8x2_t t0 = vtrn_u8(r0, r1), t1 = vtrn_u8(r2, r3), t2 = vtrn_u8(r4, r5), t3 = vtrn_u8(r6, r7);
    uint16x4x2_t u0 = vtrn_u16(vreinterpret_u16_u8(t0.val[0]), vreinterpret_u16_u8(t1.val[0]));
    uint16x4x2_t u1 = vtrn_u16(vreinterpret_u16_u8(t0.val[1]), vreinterpret_u16_u8(t1.val[1]));
    uint16x4x2_t u2 = vtrn_u16(vreinterpret_u16_u8(t2.val[0]), vreinterpret_u16_u8(t3.val[0]));
    uint16x4x2_t u3 = vtrn_u16(vreinterpret_u16_u8(t2.val[1]), vreinterpret_u16_u8(t3.val[1]));
    uint32x2x2_t v0 = vtrn_u32(vreinterpret_u32_u16(u0.val[0]), vreinterpret_u32_u16(u2.val[0]));
    uint32x2x2_t v1 = vtrn_u32(vreinterpret_u32_u16(u1.val[0]), vreinterpret_u32_u16(u3.val[0]));
    uint32x2x2_t v2 = vtrn_u32(vreinterpret_u32_u16(u0.val[1]), vreinterpret_u32_u16(u2.val[1]));
    uint32x2x2_t v3 = vtrn_u32(vreinterpret_u32_u16(u1.val[1]), vreinterpret_u32_u16(u3.val[1]));
    vst1_u8(d, vreinterpret_u8_u32(v0.val[0]));
    vst1_u8(d + ds, vreinterpret_u8_u32(v1.val[0]));
    vst1_u8(d + 2 * ds, vreinterpret_u8_u32(v2.val[0]));
    vst1_u8(d + 3 * ds, vreinterpret_u8_u32(v3.val[0]));
    vst1_u8(d + 4 * ds, vreinterpret_u8_u32(v0.val[1]));
    vst1_u8(d + 5 * ds, vreinterpret_u8_u32(v1.val[1]));
    vst1_u8(d + 6 * ds, vreinterpret_u8_u32(v2.val[1]));
    vst1_u8(d + 7 * ds, vreinterpret_u8_u32(v3.val[1]));
}

// 32-bit: 4x4 NEON tile transpose
static inline void tile4x4_u32(const uint8_t *s, ptrdiff_t ss, uint8_t *d, ptrdiff_t ds) {
    uint32x4_t r0 = vld1q_u32((const uint32_t *)s), r1 = vld1q_u32((const uint32_t *)(s + ss));
    uint32x4_t r2 = vld1q_u32((const uint32_t *)(s + 2 * ss)), r3 = vld1q_u32((const uint32_t *)(s + 3 * ss));
    uint32x4x2_t a = vtrnq_u32(r0, r1), b = vtrnq_u32(r2, r3);
    uint64x2_t c0 = vcombine_u64(vget_low_u64(vreinterpretq_u64_u32(a.val[0])), vget_low_u64(vreinterpretq_u64_u32(b.val[0])));
    uint64x2_t c1 = vcombine_u64(vget_low_u64(vreinterpretq_u64_u32(a.val[1])), vget_low_u64(vreinterpretq_u64_u32(b.val[1])));
    uint64x2_t c2 = vcombine_u64(vget_high_u64(vreinterpretq_u64_u32(a.val[0])), vget_high_u64(vreinterpretq_u64_u32(b.val[0])));
    uint64x2_t c3 = vcombine_u64(vget_high_u64(vreinterpretq_u64_u32(a.val[1])), vget_high_u64(vreinterpretq_u64_u32(b.val[1])));
    vst1q_u32((uint32_t *)d, vreinterpretq_u32_u64(c0));
    vst1q_u32((uint32_t *)(d + ds), vreinterpretq_u32_u64(c1));
    vst1q_u32((uint32_t *)(d + 2 * ds), vreinterpretq_u32_u64(c2));
    vst1q_u32((uint32_t *)(d + 3 * ds), vreinterpretq_u32_u64(c3));
}

// Plain transpose of full tiles with NEON, remainder with scalar copies.
static void transp_tiles(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint8_t *d, ptrdiff_t ds, int pb) {
    int T = pb == 1 ? 8 : 4;
    int ry = rows - rows % T, rx = cols - cols % T;
    const int SB = 64;   // super-blocks keep both the source and destination lines in L1 while a block is processed
    for (int by = 0; by < ry; by += SB) {
        int ye = by + SB < ry ? by + SB : ry;
        for (int bx = 0; bx < rx; bx += SB) {
            int xe = bx + SB < rx ? bx + SB : rx;
            for (int y = by; y < ye; y += T) for (int x = bx; x < xe; x += T) {
                if (pb == 1) tile8x8_u8(s + (ptrdiff_t)y * ss + x, ss, d + (ptrdiff_t)x * ds + y, ds);
                else tile4x4_u32(s + (ptrdiff_t)y * ss + (ptrdiff_t)x * 4, ss, d + (ptrdiff_t)x * ds + (ptrdiff_t)y * 4, ds);
            }
        }
    }
    for (int y = 0; y < rows; y++)
        for (int x = (y < ry ? rx : 0); x < cols; x++)
            memcpy(d + (ptrdiff_t)x * ds + (ptrdiff_t)y * pb, s + (ptrdiff_t)y * ss + (ptrdiff_t)x * pb, pb);
}

static inline void trn8x8(const uint8x8_t r[8], uint8x8_t o[8]) {
    uint8x8x2_t t0 = vtrn_u8(r[0], r[1]), t1 = vtrn_u8(r[2], r[3]), t2 = vtrn_u8(r[4], r[5]), t3 = vtrn_u8(r[6], r[7]);
    uint16x4x2_t u0 = vtrn_u16(vreinterpret_u16_u8(t0.val[0]), vreinterpret_u16_u8(t1.val[0]));
    uint16x4x2_t u1 = vtrn_u16(vreinterpret_u16_u8(t0.val[1]), vreinterpret_u16_u8(t1.val[1]));
    uint16x4x2_t u2 = vtrn_u16(vreinterpret_u16_u8(t2.val[0]), vreinterpret_u16_u8(t3.val[0]));
    uint16x4x2_t u3 = vtrn_u16(vreinterpret_u16_u8(t2.val[1]), vreinterpret_u16_u8(t3.val[1]));
    uint32x2x2_t v0 = vtrn_u32(vreinterpret_u32_u16(u0.val[0]), vreinterpret_u32_u16(u2.val[0]));
    uint32x2x2_t v1 = vtrn_u32(vreinterpret_u32_u16(u1.val[0]), vreinterpret_u32_u16(u3.val[0]));
    uint32x2x2_t v2 = vtrn_u32(vreinterpret_u32_u16(u0.val[1]), vreinterpret_u32_u16(u2.val[1]));
    uint32x2x2_t v3 = vtrn_u32(vreinterpret_u32_u16(u1.val[1]), vreinterpret_u32_u16(u3.val[1]));
    o[0] = vreinterpret_u8_u32(v0.val[0]); o[1] = vreinterpret_u8_u32(v1.val[0]);
    o[2] = vreinterpret_u8_u32(v2.val[0]); o[3] = vreinterpret_u8_u32(v3.val[0]);
    o[4] = vreinterpret_u8_u32(v0.val[1]); o[5] = vreinterpret_u8_u32(v1.val[1]);
    o[6] = vreinterpret_u8_u32(v2.val[1]); o[7] = vreinterpret_u8_u32(v3.val[1]);
}
// 8x8-pixel tiles of 1- or 3-byte pixels for all three modes; edges by scalar copies. Tiles are visited in 64x64-pixel
// super-blocks so that every cache line of source and destination is fully used while it is still in L1.
static inline void tile8_u8(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint8_t *d, ptrdiff_t ds, int pb, int mode, int y, int x) {
    uint8x8_t in[3][8], out[3][8];
    for (int r = 0; r < 8; r++) {
        const uint8_t *sp = s + (ptrdiff_t)(y + r) * ss + (ptrdiff_t)x * pb;
        if (pb == 3) { uint8x8x3_t v = vld3_u8(sp); in[0][r] = v.val[0]; in[1][r] = v.val[1]; in[2][r] = v.val[2]; }
        else in[0][r] = vld1_u8(sp);
    }
    for (int c = 0; c < pb; c++) trn8x8(in[c], out[c]);   // out[c][j] = column j of the tile (8 values over rows y..y+7)
    for (int j = 0; j < 8; j++) {
        int dy, dx; int rev = 0;
        if (mode == 0) { dy = x + j; dx = y; }
        else if (mode == 1) { dy = x + j; dx = rows - 8 - y; rev = 1; }
        else { dy = cols - 1 - (x + j); dx = y; }
        uint8_t *dp = d + (ptrdiff_t)dy * ds + (ptrdiff_t)dx * pb;
        if (pb == 3) {
            uint8x8x3_t v; for (int c = 0; c < 3; c++) v.val[c] = rev ? vrev64_u8(out[c][j]) : out[c][j];
            vst3_u8(dp, v);
        } else vst1_u8(dp, rev ? vrev64_u8(out[0][j]) : out[0][j]);
    }
}
static void transp_u8_tiles(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint8_t *d, ptrdiff_t ds, int pb, int mode) {
    int ry = rows - rows % 8, rx = cols - cols % 8;
#ifndef TSB
#define TSB 64
#endif
    const int SB = TSB;
    for (int by = 0; by < ry; by += SB) {
        int ye = by + SB < ry ? by + SB : ry;
        for (int bx = 0; bx < rx; bx += SB) {
            int xe = bx + SB < rx ? bx + SB : rx;
            for (int y = by; y < ye; y += 8) for (int x = bx; x < xe; x += 8) tile8_u8(s, ss, rows, cols, d, ds, pb, mode, y, x);
        }
    }
    // edge strips (right columns, bottom rows) scalar
    for (int y = 0; y < rows; y++) for (int x = (y < ry ? rx : 0); x < cols; x++) {
        int dy = mode == 2 ? cols - 1 - x : x, dx = mode == 1 ? rows - 1 - y : y;
        memcpy(d + (ptrdiff_t)dy * ds + (ptrdiff_t)dx * pb, s + (ptrdiff_t)y * ss + (ptrdiff_t)x * pb, pb);
    }
}

// 3-byte pixels: 4x4-pixel blocks. Four 16-byte row loads (12 bytes used), one four-register table lookup per destination row,
// 12-byte stores. Faster than LD3/ST3 + byte transposes, which are slow on Apple cores. Columns whose 16-byte load would leave the
// row (the last ~6) and rows beyond a multiple of 4 are copied pixel by pixel.
static void transp_u8x3(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint8_t *d, ptrdiff_t ds, int mode) {
    uint8_t fi[4][16], ri[4][16];
    for (int j = 0; j < 4; j++) {
        for (int r = 0; r < 4; r++) for (int b = 0; b < 3; b++) { fi[j][r * 3 + b] = (uint8_t)(r * 16 + j * 3 + b); ri[j][r * 3 + b] = (uint8_t)((3 - r) * 16 + j * 3 + b); }
        for (int k = 12; k < 16; k++) fi[j][k] = ri[j][k] = 255;
    }
    uint8x16_t ix[4], rx_[4];
    for (int j = 0; j < 4; j++) { ix[j] = vld1q_u8(fi[j]); rx_[j] = vld1q_u8(ri[j]); }
    const uint8x16_t *tb = mode == 1 ? rx_ : ix;
    int ry = rows - rows % 4, rx = ((cols - 6) / 4) * 4;
    if (rx < 0) rx = 0;
    const int SB = 64;
    for (int by = 0; by < ry; by += SB) {
        int ye = by + SB < ry ? by + SB : ry;
        for (int bx = 0; bx < rx; bx += SB) {
            int xe = bx + SB < rx ? bx + SB : rx;
            for (int y = by; y < ye; y += 4) for (int x = bx; x < xe; x += 4) {
                const uint8_t *sp = s + (ptrdiff_t)y * ss + (ptrdiff_t)x * 3;
                uint8x16x4_t t = { { vld1q_u8(sp), vld1q_u8(sp + ss), vld1q_u8(sp + 2 * ss), vld1q_u8(sp + 3 * ss) } };
                for (int j = 0; j < 4; j++) {
                    uint8x16_t o = vqtbl4q_u8(t, tb[j]);
                    int dy = mode == 2 ? cols - 1 - x - j : x + j, dx = mode == 1 ? rows - 4 - y : y;
                    uint8_t *dp = d + (ptrdiff_t)dy * ds + (ptrdiff_t)dx * 3;
                    vst1_u8(dp, vget_low_u8(o));
                    vst1q_lane_u32((uint32_t *)(dp + 8), vreinterpretq_u32_u8(o), 2);
                }
            }
        }
    }
    for (int y = 0; y < rows; y++) for (int x = (y < ry ? rx : 0); x < cols; x++) {
        int dy = mode == 2 ? cols - 1 - x : x, dx = mode == 1 ? rows - 1 - y : y;
        memcpy(d + (ptrdiff_t)dy * ds + (ptrdiff_t)dx * 3, s + (ptrdiff_t)y * ss + (ptrdiff_t)x * 3, 3);
    }
}

void src_transpose(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint8_t *d, ptrdiff_t ds, int pb, int mode) {
    if (pb == 3 && rows >= 4 && cols >= 10) { transp_u8x3(s, ss, rows, cols, d, ds, mode); return; }
    if ((pb == 1 || pb == 3) && rows >= 8 && cols >= 8) { transp_u8_tiles(s, ss, rows, cols, d, ds, pb, mode); return; }
    if (mode == 0 && pb == 4) { transp_tiles(s, ss, rows, cols, d, ds, pb); return; }
    switch (pb) {
    case 1: {   // 1-byte pixels, rotations: scalar blocked
        const int B = 64;
        for (int by = 0; by < rows; by += B) for (int bx = 0; bx < cols; bx += B) {
            int ye = by + B < rows ? by + B : rows, xe = bx + B < cols ? bx + B : cols;
            for (int y = by; y < ye; y++) for (int x = bx; x < xe; x++) {
                int dy = mode == 0 ? x : (mode == 1 ? x : cols - 1 - x), dx = mode == 0 ? y : (mode == 1 ? rows - 1 - y : y);
                d[(ptrdiff_t)dy * ds + dx] = s[(ptrdiff_t)y * ss + x];
            }
        }
        break; }
    case 2: transp_2(s, ss, rows, cols, d, ds, mode); break;
    case 3: transp_3(s, ss, rows, cols, d, ds, mode); break;
    case 4: transp_4(s, ss, rows, cols, d, ds, mode); break;
    case 6: transp_6(s, ss, rows, cols, d, ds, mode); break;
    case 8: transp_8(s, ss, rows, cols, d, ds, mode); break;
    case 12: transp_12(s, ss, rows, cols, d, ds, mode); break;
    case 16: transp_16(s, ss, rows, cols, d, ds, mode); break;
    default:
        for (int y = 0; y < rows; y++) for (int x = 0; x < cols; x++) {
            int dy = mode == 0 ? x : (mode == 1 ? x : cols - 1 - x), dx = mode == 0 ? y : (mode == 1 ? rows - 1 - y : y);
            memcpy(d + (ptrdiff_t)dy * ds + (ptrdiff_t)dx * pb, s + (ptrdiff_t)y * ss + (ptrdiff_t)x * pb, pb);
        }
    }
}

// ------------------------------------------------------------------ saturating add/sub/absdiff
#define ADDSUB_LOOP(T, V, LANES, LD, ST, QADD, QSUB, ABD, ABDCAST)                                                  \
    { const T *pa = (const T *)a, *pb = (const T *)b; T *pd = (T *)d; size_t i = 0;                                 \
      if (op == 0) for (; i + LANES <= n; i += LANES) ST(pd + i, QADD(LD(pa + i), LD(pb + i)));                    \
      else if (op == 1) for (; i + LANES <= n; i += LANES) ST(pd + i, QSUB(LD(pa + i), LD(pb + i)));               \
      else for (; i + LANES <= n; i += LANES) ST(pd + i, ABDCAST(ABD(LD(pa + i), LD(pb + i))));                    \
      for (; i < n; i++) { int64_t x = (int64_t)pa[i], y = (int64_t)pb[i];                                          \
          int64_t r = op == 0 ? x + y : (op == 1 ? x - y : (x > y ? x - y : y - x));                                \
          pd[i] = r < LO_##T ? (T)LO_##T : (r > HI_##T ? (T)HI_##T : (T)r); } }
#define LO_uint8_t 0
#define HI_uint8_t 255
#define LO_int8_t (-128)
#define HI_int8_t 127
#define LO_uint16_t 0
#define HI_uint16_t 65535
#define LO_int16_t (-32768)
#define HI_int16_t 32767
static inline uint8x16_t id_u8(uint8x16_t v) { return v; }
static inline int8x16_t id_s8(int8x16_t v) { return v; }
static inline uint16x8_t id_u16(uint16x8_t v) { return v; }
static inline int16x8_t id_s16(int16x8_t v) { return v; }
static inline uint8x16_t abd_s8_sat(uint8x16_t v) { return vminq_u8(v, vdupq_n_u8(127)); }
static inline int8x16_t abd_s8(int8x16_t x, int8x16_t y) { return vreinterpretq_s8_u8(abd_s8_sat(vreinterpretq_u8_s8(vabdq_s8(x, y)))); }
static inline int16x8_t abd_s16(int16x8_t x, int16x8_t y) {
    return vreinterpretq_s16_u16(vminq_u16(vreinterpretq_u16_s16(vabdq_s16(x, y)), vdupq_n_u16(32767)));
}
void src_addsub(int type, int op, const void *a, const void *b, void *d, size_t n) {
    switch (type) {
    case 0: ADDSUB_LOOP(uint8_t, , 16, vld1q_u8, vst1q_u8, vqaddq_u8, vqsubq_u8, vabdq_u8, id_u8) break;
    case 1: ADDSUB_LOOP(int8_t, , 16, vld1q_s8, vst1q_s8, vqaddq_s8, vqsubq_s8, abd_s8, id_s8) break;
    case 2: ADDSUB_LOOP(uint16_t, , 8, vld1q_u16, vst1q_u16, vqaddq_u16, vqsubq_u16, vabdq_u16, id_u16) break;
    default: ADDSUB_LOOP(int16_t, , 8, vld1q_s16, vst1q_s16, vqaddq_s16, vqsubq_s16, abd_s16, id_s16) break;
    }
}

// ------------------------------------------------------------------ float binary ops
void src_fbin32(int op, const float *a, const float *b, float *d, size_t n, float scale) {
    size_t i = 0;
    switch (op) {
    case 0: for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vaddq_f32(vld1q_f32(a + i), vld1q_f32(b + i))); for (; i < n; i++) d[i] = a[i] + b[i]; break;
    case 1: for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vsubq_f32(vld1q_f32(a + i), vld1q_f32(b + i))); for (; i < n; i++) d[i] = a[i] - b[i]; break;
    case 2: for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vabdq_f32(vld1q_f32(a + i), vld1q_f32(b + i))); for (; i < n; i++) { float t = a[i] - b[i]; d[i] = t < 0 ? -t : t; } break;
    case 3: { float32x4_t sc = vdupq_n_f32(scale);
        if (scale == 1.0f) { for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vmulq_f32(vld1q_f32(a + i), vld1q_f32(b + i))); for (; i < n; i++) d[i] = a[i] * b[i]; }
        else { for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vmulq_f32(vmulq_f32(sc, vld1q_f32(a + i)), vld1q_f32(b + i))); for (; i < n; i++) d[i] = (scale * a[i]) * b[i]; }
        break; }
    default: { float32x4_t sc = vdupq_n_f32(scale);
        if (scale == 1.0f) { for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vdivq_f32(vld1q_f32(a + i), vld1q_f32(b + i))); for (; i < n; i++) d[i] = a[i] / b[i]; }
        else { for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vdivq_f32(vmulq_f32(vld1q_f32(a + i), sc), vld1q_f32(b + i))); for (; i < n; i++) d[i] = (a[i] * scale) / b[i]; }
        break; }
    }
}
void src_fbin64(int op, const double *a, const double *b, double *d, size_t n, double scale) {
    size_t i = 0;
    switch (op) {
    case 0: for (; i + 2 <= n; i += 2) vst1q_f64(d + i, vaddq_f64(vld1q_f64(a + i), vld1q_f64(b + i))); for (; i < n; i++) d[i] = a[i] + b[i]; break;
    case 1: for (; i + 2 <= n; i += 2) vst1q_f64(d + i, vsubq_f64(vld1q_f64(a + i), vld1q_f64(b + i))); for (; i < n; i++) d[i] = a[i] - b[i]; break;
    case 2: for (; i + 2 <= n; i += 2) vst1q_f64(d + i, vabdq_f64(vld1q_f64(a + i), vld1q_f64(b + i))); for (; i < n; i++) { double t = a[i] - b[i]; d[i] = t < 0 ? -t : t; } break;
    case 3: { float64x2_t sc = vdupq_n_f64(scale);
        for (; i + 2 <= n; i += 2) vst1q_f64(d + i, vmulq_f64(vmulq_f64(sc, vld1q_f64(a + i)), vld1q_f64(b + i)));
        for (; i < n; i++) d[i] = (scale * a[i]) * b[i]; break; }
    default: { float64x2_t sc = vdupq_n_f64(scale);
        for (; i + 2 <= n; i += 2) vst1q_f64(d + i, vdivq_f64(vmulq_f64(vld1q_f64(a + i), sc), vld1q_f64(b + i)));
        for (; i < n; i++) d[i] = (a[i] * scale) / b[i]; break; }
    }
}
void src_sqrt32(const float *a, float *d, size_t n) {
    size_t i = 0;
    for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vsqrtq_f32(vld1q_f32(a + i)));
    for (; i < n; i++) d[i] = sqrtf(a[i]);
}

// ------------------------------------------------------------------ u8 / f32 convert + weighted
static inline uint8x16_t pack_f32_u8(float32x4_t a, float32x4_t b, float32x4_t c, float32x4_t d) {
    // round-half-even (vcvtn), saturating narrow; NaN -> 0 (fcvtns)
    int32x4_t ia = vcvtnq_s32_f32(a), ib = vcvtnq_s32_f32(b), ic = vcvtnq_s32_f32(c), id = vcvtnq_s32_f32(d);
    uint16x8_t lo = vcombine_u16(vqmovun_s32(ia), vqmovun_s32(ib)), hi = vcombine_u16(vqmovun_s32(ic), vqmovun_s32(id));
    return vcombine_u8(vqmovn_u16(lo), vqmovn_u16(hi));
}
static inline void unpack_u8_f32(uint8x16_t v, float32x4_t *o0, float32x4_t *o1, float32x4_t *o2, float32x4_t *o3) {
    uint16x8_t l = vmovl_u8(vget_low_u8(v)), h = vmovl_u8(vget_high_u8(v));
    *o0 = vcvtq_f32_u32(vmovl_u16(vget_low_u16(l))); *o1 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(l)));
    *o2 = vcvtq_f32_u32(vmovl_u16(vget_low_u16(h))); *o3 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(h)));
}
static inline uint8_t sat_u8_f(float v) {
    float r = nearbyintf(v);
    return r != r ? 0 : (r < 0 ? 0 : (r > 255 ? 255 : (uint8_t)r));
}
void src_cvt(int sd, int dd, const void *s, void *d, size_t n, float alpha, float beta, int absf) {
    size_t i = 0;
    float32x4_t al = vdupq_n_f32(alpha), be = vdupq_n_f32(beta);
    if (sd == 0 && dd == 0) {
        const uint8_t *p = s; uint8_t *q = d;
        for (; i + 16 <= n; i += 16) {
            float32x4_t x0, x1, x2, x3; unpack_u8_f32(vld1q_u8(p + i), &x0, &x1, &x2, &x3);
            x0 = vfmaq_f32(be, x0, al); x1 = vfmaq_f32(be, x1, al); x2 = vfmaq_f32(be, x2, al); x3 = vfmaq_f32(be, x3, al);
            if (absf) { x0 = vabsq_f32(x0); x1 = vabsq_f32(x1); x2 = vabsq_f32(x2); x3 = vabsq_f32(x3); }
            vst1q_u8(q + i, pack_f32_u8(x0, x1, x2, x3));
        }
        for (; i < n; i++) { float v = fmaf((float)p[i], alpha, beta); q[i] = sat_u8_f(absf ? fabsf(v) : v); }
    } else if (sd == 0 && dd == 5) {
        const uint8_t *p = s; float *q = d;
        for (; i + 16 <= n; i += 16) {
            float32x4_t x0, x1, x2, x3; unpack_u8_f32(vld1q_u8(p + i), &x0, &x1, &x2, &x3);
            vst1q_f32(q + i, vfmaq_f32(be, x0, al)); vst1q_f32(q + i + 4, vfmaq_f32(be, x1, al));
            vst1q_f32(q + i + 8, vfmaq_f32(be, x2, al)); vst1q_f32(q + i + 12, vfmaq_f32(be, x3, al));
        }
        for (; i < n; i++) q[i] = fmaf((float)p[i], alpha, beta);
    } else if (sd == 5 && dd == 5) {
        const float *p = s; float *q = d;
        for (; i + 4 <= n; i += 4) { float32x4_t x = vfmaq_f32(be, vld1q_f32(p + i), al); vst1q_f32(q + i, absf ? vabsq_f32(x) : x); }
        for (; i < n; i++) { float v = fmaf(p[i], alpha, beta); q[i] = absf ? fabsf(v) : v; }
    } else { // f32 -> u8
        const float *p = s; uint8_t *q = d;
        for (; i + 16 <= n; i += 16) {
            float32x4_t x0 = vfmaq_f32(be, vld1q_f32(p + i), al), x1 = vfmaq_f32(be, vld1q_f32(p + i + 4), al);
            float32x4_t x2 = vfmaq_f32(be, vld1q_f32(p + i + 8), al), x3 = vfmaq_f32(be, vld1q_f32(p + i + 12), al);
            if (absf) { x0 = vabsq_f32(x0); x1 = vabsq_f32(x1); x2 = vabsq_f32(x2); x3 = vabsq_f32(x3); }
            vst1q_u8(q + i, pack_f32_u8(x0, x1, x2, x3));
        }
        for (; i < n; i++) { float v = fmaf(p[i], alpha, beta); q[i] = sat_u8_f(absf ? fabsf(v) : v); }
    }
}
void src_addw_u8(const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n, float alpha, float beta, float gamma) {
    size_t i = 0;
    float32x4_t al = vdupq_n_f32(alpha), be = vdupq_n_f32(beta), ga = vdupq_n_f32(gamma);
    for (; i + 16 <= n; i += 16) {
        float32x4_t a0, a1, a2, a3, b0, b1, b2, b3;
        unpack_u8_f32(vld1q_u8(a + i), &a0, &a1, &a2, &a3); unpack_u8_f32(vld1q_u8(b + i), &b0, &b1, &b2, &b3);
        float32x4_t r0 = vfmaq_f32(vfmaq_f32(ga, b0, be), a0, al), r1 = vfmaq_f32(vfmaq_f32(ga, b1, be), a1, al);
        float32x4_t r2 = vfmaq_f32(vfmaq_f32(ga, b2, be), a2, al), r3 = vfmaq_f32(vfmaq_f32(ga, b3, be), a3, al);
        vst1q_u8(d + i, pack_f32_u8(r0, r1, r2, r3));
    }
    for (; i < n; i++) d[i] = sat_u8_f(fmaf((float)a[i], alpha, fmaf((float)b[i], beta, gamma)));
}
void src_addw_f32(const float *a, const float *b, float *d, size_t n, float alpha, float beta, float gamma) {
    size_t i = 0;
    float32x4_t al = vdupq_n_f32(alpha), be = vdupq_n_f32(beta), ga = vdupq_n_f32(gamma);
    for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vfmaq_f32(vfmaq_f32(ga, vld1q_f32(b + i), be), vld1q_f32(a + i), al));
    for (; i < n; i++) d[i] = fmaf(a[i], alpha, fmaf(b[i], beta, gamma));
}
void src_mul_u8(const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n, float scale) {
    size_t i = 0;
    float32x4_t sc = vdupq_n_f32(scale);
    for (; i + 16 <= n; i += 16) {
        float32x4_t a0, a1, a2, a3, b0, b1, b2, b3;
        unpack_u8_f32(vld1q_u8(a + i), &a0, &a1, &a2, &a3); unpack_u8_f32(vld1q_u8(b + i), &b0, &b1, &b2, &b3);
        vst1q_u8(d + i, pack_f32_u8(vmulq_f32(vmulq_f32(sc, a0), b0), vmulq_f32(vmulq_f32(sc, a1), b1),
                                    vmulq_f32(vmulq_f32(sc, a2), b2), vmulq_f32(vmulq_f32(sc, a3), b3)));
    }
    for (; i < n; i++) d[i] = sat_u8_f((scale * (float)a[i]) * (float)b[i]);
}

// ------------------------------------------------------------------ u8 sums
#if defined(__ARM_FEATURE_DOTPROD)
#define DOT(acc, a, b) vdotq_u32((acc), (a), (b))
#else
static inline uint32x4_t DOT(uint32x4_t acc, uint8x16_t a, uint8x16_t b) {
    acc = vpadalq_u16(acc, vmull_u8(vget_low_u8(a), vget_low_u8(b)));
    return vpadalq_u16(acc, vmull_u8(vget_high_u8(a), vget_high_u8(b)));
}
#endif
// one generic 4-way unrolled byte reducer: mode 0 sum, 1 sum of squares; optional second operand (absdiff)
static uint64_t u8_reduce(const uint8_t *p, const uint8_t *q, size_t n, int sq) {
    uint64_t total = 0; size_t i = 0;
    const uint8x16_t one = vdupq_n_u8(1);
    while (i + 64 <= n) {
        uint32x4_t a0 = vdupq_n_u32(0), a1 = a0, a2 = a0, a3 = a0;
        size_t lim = i + 64 * (sq ? 2000 : 60000); if (lim > n) lim = n;
        for (; i + 64 <= lim; i += 64) {
            uint8x16_t v0, v1, v2, v3;
            if (q) {
                v0 = vabdq_u8(vld1q_u8(p + i), vld1q_u8(q + i)); v1 = vabdq_u8(vld1q_u8(p + i + 16), vld1q_u8(q + i + 16));
                v2 = vabdq_u8(vld1q_u8(p + i + 32), vld1q_u8(q + i + 32)); v3 = vabdq_u8(vld1q_u8(p + i + 48), vld1q_u8(q + i + 48));
            } else { v0 = vld1q_u8(p + i); v1 = vld1q_u8(p + i + 16); v2 = vld1q_u8(p + i + 32); v3 = vld1q_u8(p + i + 48); }
            if (sq) { a0 = DOT(a0, v0, v0); a1 = DOT(a1, v1, v1); a2 = DOT(a2, v2, v2); a3 = DOT(a3, v3, v3); }
            else { a0 = DOT(a0, v0, one); a1 = DOT(a1, v1, one); a2 = DOT(a2, v2, one); a3 = DOT(a3, v3, one); }
        }
        total += vaddvq_u32(vaddq_u32(vaddq_u32(a0, a1), vaddq_u32(a2, a3)));
    }
    for (; i < n; i++) {
        uint64_t v = q ? (p[i] > q[i] ? p[i] - q[i] : q[i] - p[i]) : p[i];
        total += sq ? v * v : v;
    }
    return total;
}
uint64_t src_sum_u8(const uint8_t *p, size_t n) { return u8_reduce(p, 0, n, 0); }
uint64_t src_sumsq_u8(const uint8_t *p, size_t n) { return u8_reduce(p, 0, n, 1); }
uint64_t src_sum_absdiff_u8(const uint8_t *a, const uint8_t *b, size_t n) { return u8_reduce(a, b, n, 0); }
uint64_t src_sumsq_absdiff_u8(const uint8_t *a, const uint8_t *b, size_t n) { return u8_reduce(a, b, n, 1); }
void src_sums_u8_cn(const uint8_t *p, size_t cols, int cn, uint64_t *s, uint64_t *q, int want_sq) {
    size_t x = 0;
    if (cn == 1) { s[0] += src_sum_u8(p, cols); if (want_sq) q[0] += src_sumsq_u8(p, cols); return; }
    if (cn == 3 || cn == 2 || cn == 4) {
        while (x + 16 <= cols) {
            uint32x4_t as[4], aq[4];
            for (int c = 0; c < 4; c++) { as[c] = vdupq_n_u32(0); aq[c] = vdupq_n_u32(0); }
            size_t lim = x + 16 * 8000; if (lim > cols) lim = cols;
            for (; x + 16 <= lim; x += 16) {
                uint8x16_t v[4];
                if (cn == 3) { uint8x16x3_t t = vld3q_u8(p + x * 3); v[0] = t.val[0]; v[1] = t.val[1]; v[2] = t.val[2]; }
                else if (cn == 2) { uint8x16x2_t t = vld2q_u8(p + x * 2); v[0] = t.val[0]; v[1] = t.val[1]; }
                else { uint8x16x4_t t = vld4q_u8(p + x * 4); v[0] = t.val[0]; v[1] = t.val[1]; v[2] = t.val[2]; v[3] = t.val[3]; }
                const uint8x16_t one = vdupq_n_u8(1);
                for (int c = 0; c < cn; c++) { as[c] = DOT(as[c], v[c], one); if (want_sq) aq[c] = DOT(aq[c], v[c], v[c]); }
            }
            for (int c = 0; c < cn; c++) { s[c] += vaddvq_u32(as[c]); q[c] += vaddvq_u32(aq[c]); }
        }
    }
    for (; x < cols; x++) for (int c = 0; c < cn; c++) { uint64_t v = p[x * cn + c]; s[c] += v; q[c] += v * v; }
}
void src_minmax_u8(const uint8_t *p, size_t n, uint8_t *mn, uint8_t *mx) {
    uint8x16_t lo = vdupq_n_u8(255), hi = vdupq_n_u8(0); size_t i = 0;
    for (; i + 16 <= n; i += 16) { uint8x16_t v = vld1q_u8(p + i); lo = vminq_u8(lo, v); hi = vmaxq_u8(hi, v); }
    uint8_t l = vminvq_u8(lo), h = vmaxvq_u8(hi);
    for (; i < n; i++) { if (p[i] < l) l = p[i]; if (p[i] > h) h = p[i]; }
    *mn = l; *mx = h;
}
void src_minmax_f32(const float *p, size_t n, float *mn, float *mx) {
    float32x4_t lo = vdupq_n_f32(INFINITY), hi = vdupq_n_f32(-INFINITY); size_t i = 0;
    for (; i + 4 <= n; i += 4) { float32x4_t v = vld1q_f32(p + i); lo = vminq_f32(lo, v); hi = vmaxq_f32(hi, v); }
    float l = vminvq_f32(lo), h = vmaxvq_f32(hi);
    for (; i < n; i++) { if (p[i] != p[i]) { l = h = NAN; break; } if (p[i] < l) l = p[i]; if (p[i] > h) h = p[i]; }
    *mn = l; *mx = h;
}
uint8_t src_maxabsdiff_u8(const uint8_t *a, const uint8_t *b, size_t n) {
    uint8x16_t hi = vdupq_n_u8(0); size_t i = 0;
    for (; i + 16 <= n; i += 16) hi = vmaxq_u8(hi, vabdq_u8(vld1q_u8(a + i), vld1q_u8(b + i)));
    uint8_t h = vmaxvq_u8(hi);
    for (; i < n; i++) { uint8_t d = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i]; if (d > h) h = d; }
    return h;
}
size_t src_count_nz_u8(const uint8_t *p, size_t n) {
    size_t total = 0, i = 0;
    while (i + 64 <= n) {
        uint8x16_t a0 = vdupq_n_u8(0), a1 = a0, a2 = a0, a3 = a0;
        size_t lim = i + 64 * 255; if (lim > n) lim = n;
        for (; i + 64 <= lim; i += 64) {
            uint8x16_t v0 = vld1q_u8(p + i), v1 = vld1q_u8(p + i + 16), v2 = vld1q_u8(p + i + 32), v3 = vld1q_u8(p + i + 48);
            a0 = vsubq_u8(a0, vtstq_u8(v0, v0)); a1 = vsubq_u8(a1, vtstq_u8(v1, v1));
            a2 = vsubq_u8(a2, vtstq_u8(v2, v2)); a3 = vsubq_u8(a3, vtstq_u8(v3, v3));
        }
        total += vaddlvq_u8(a0) + vaddlvq_u8(a1) + vaddlvq_u8(a2) + vaddlvq_u8(a3);
    }
    for (; i < n; i++) total += p[i] != 0;
    return total;
}
size_t src_count_nz_f32(const float *p, size_t n) {
    size_t total = 0, i = 0;
    while (i + 4 <= n) {
        uint32x4_t acc = vdupq_n_u32(0);
        size_t lim = i + 4 * 1000000; if (lim > n) lim = n;
        for (; i + 4 <= lim; i += 4) acc = vsubq_u32(acc, vmvnq_u32(vceqq_f32(vld1q_f32(p + i), vdupq_n_f32(0))));
        total += vaddvq_u32(acc);
    }
    for (; i < n; i++) total += p[i] != 0;
    return total;
}
void src_acc_u8_u32(uint32_t *acc, const uint8_t *row, size_t n) {
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        uint8x16_t v = vld1q_u8(row + i);
        uint16x8_t l = vmovl_u8(vget_low_u8(v)), h = vmovl_u8(vget_high_u8(v));
        vst1q_u32(acc + i, vaddw_u16(vld1q_u32(acc + i), vget_low_u16(l)));
        vst1q_u32(acc + i + 4, vaddw_u16(vld1q_u32(acc + i + 4), vget_high_u16(l)));
        vst1q_u32(acc + i + 8, vaddw_u16(vld1q_u32(acc + i + 8), vget_low_u16(h)));
        vst1q_u32(acc + i + 12, vaddw_u16(vld1q_u32(acc + i + 12), vget_high_u16(h)));
    }
    for (; i < n; i++) acc[i] += row[i];
}
void src_max_u8_rows(uint8_t *acc, const uint8_t *row, size_t n, int is_max) {
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        uint8x16_t a = vld1q_u8(acc + i), r = vld1q_u8(row + i);
        vst1q_u8(acc + i, is_max ? vmaxq_u8(a, r) : vminq_u8(a, r));
    }
    for (; i < n; i++) { if (is_max ? row[i] > acc[i] : row[i] < acc[i]) acc[i] = row[i]; }
}

// ------------------------------------------------------------------ randu (MWC, exact cv2 stream)
#define MWC_NEXT(s) ((s) = (uint64_t)(uint32_t)(s) * 4164903690u + ((s) >> 32))
static inline int32_t clamp_depth(int depth, int64_t v) {
    switch (depth) {
    case 0: return v < 0 ? 0 : (v > 255 ? 255 : (int32_t)v);
    case 1: return v < -128 ? -128 : (v > 127 ? 127 : (int32_t)v);
    case 2: return v < 0 ? 0 : (v > 65535 ? 65535 : (int32_t)v);
    case 3: return v < -32768 ? -32768 : (v > 32767 ? 32767 : (int32_t)v);
    default: return v < INT32_MIN ? INT32_MIN : (v > INT32_MAX ? INT32_MAX : (int32_t)v);
    }
}
static inline void put_depth(int depth, void *out, int i, int32_t v) {
    switch (depth) {
    case 0: ((uint8_t *)out)[i] = (uint8_t)v; break;
    case 1: ((int8_t *)out)[i] = (int8_t)v; break;
    case 2: ((uint16_t *)out)[i] = (uint16_t)v; break;
    case 3: ((int16_t *)out)[i] = (int16_t)v; break;
    default: ((int32_t *)out)[i] = v; break;
    }
}
void src_randu_int(int depth, void *out, int n, uint64_t *state, const int32_t *ia, const int32_t *idiff, int cn, int ch0,
                   int mode) {
    uint64_t s = *state;
    int i = 0;
    // u8, small mode, every channel range within one byte: four draws -> 16 bytes, masked and offset with per-phase constants
    // (mask byte = idiff or 0 for an empty range, offset = ia clamped to +-300, which cannot change the saturated result)
    int simd8 = mode == 2 && depth == 0 && cn >= 1 && cn <= 4;
    for (int c = 0; simd8 && c < cn; c++) if (idiff[c] > 255 || idiff[c] < -1) simd8 = 0;
    if (simd8 && n >= 16) {
        uint8_t maskv[4][16]; int16_t addv[4][16];
        for (int ph = 0; ph < cn; ph++) for (int k = 0; k < 16; k++) {
            int c = (ph + k) % cn;
            maskv[ph][k] = idiff[c] < 0 ? 0 : (uint8_t)idiff[c];
            addv[ph][k] = (int16_t)(ia[c] < -300 ? -300 : (ia[c] > 300 ? 300 : ia[c]));
        }
        int ph = ch0 % cn;
        for (; i + 16 <= n; i += 16) {
            uint32_t w[4];
            for (int k = 0; k < 4; k++) { s = (uint64_t)(uint32_t)s * 4164903690u + (s >> 32); w[k] = (uint32_t)s; }
            uint8x16_t b = vandq_u8(vreinterpretq_u8_u32(vld1q_u32(w)), vld1q_u8(maskv[ph]));
            int16x8_t lo = vaddq_s16(vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(b))), vld1q_s16(addv[ph]));
            int16x8_t hi = vaddq_s16(vreinterpretq_s16_u16(vmovl_high_u8(b)), vld1q_s16(addv[ph] + 8));
            vst1q_u8((uint8_t *)out + i, vcombine_u8(vqmovun_s16(lo), vqmovun_s16(hi)));
            ph = (ph + 16) % cn;
        }
    }
    // per-position parameters repeat with period cn
    if (mode == 2) {
        for (; i <= n - 4; i += 4) {
            uint64_t t = MWC_NEXT(s);   // shifts read the whole 64-bit state (carry bits included), as cv2 does
            for (int k = 0; k < 4; k++) {
                int c = (ch0 + i + k) % cn; int32_t df = idiff[c];
                int64_t v = (int64_t)((t >> (8 * k)) & (uint64_t)(uint32_t)(df < 0 ? 0 : df)) + ia[c];
                put_depth(depth, out, i + k, clamp_depth(depth, v));
            }
        }
    }
    for (; i < n; i++) {
        uint32_t t = (uint32_t)MWC_NEXT(s);
        int c = (ch0 + i) % cn; int32_t df = idiff[c];
        uint32_t dd = (uint32_t)df + 1u;
        int64_t v;
        if (dd == 0) v = ia[c];
        else if (mode == 1 || mode == 2) v = (int64_t)(t & (uint32_t)df) + ia[c];
        else v = (int64_t)(t % dd) + ia[c];
        put_depth(depth, out, i, clamp_depth(depth, v));
    }
    *state = s;
}

// ------------------------------------------------------------------ randn: ziggurat N(0,1), OpenCV flow
static uint32_t zk[128]; static float zw[128], zf[128]; static int zinit = 0;
static void zig_init(void) {
    double dn = 3.442619855899, tn = dn, vn = 9.91256303526217e-3, m1 = 2147483648.0;
    double kn[128], wn[128], fn[128];
    double q = vn / exp(-0.5 * dn * dn);
    kn[0] = (dn / q) * m1; kn[1] = 0; wn[0] = q / m1; wn[127] = dn / m1; fn[0] = 1.0; fn[127] = exp(-0.5 * dn * dn);
    for (int i = 126; i >= 1; i--) {
        dn = sqrt(-2.0 * log(vn / dn + exp(-0.5 * dn * dn)));
        kn[i + 1] = (dn / tn) * m1; tn = dn; fn[i] = exp(-0.5 * dn * dn); wn[i] = dn / m1;
    }
    for (int j = 0; j < 128; j++) { zk[j] = (uint32_t)kn[j]; zw[j] = (float)wn[j]; zf[j] = (float)fn[j]; }
    zinit = 1;
}
void src_randn_f32(float *out, int n, uint64_t *state) {
    if (!zinit) zig_init();
    uint64_t s = *state;
    const float rngflt = 2.3283064365386962890625e-10f;
    for (int i = 0; i < n; i++) {
        float x;
        for (;;) {
            int32_t hz = (int32_t)(uint32_t)s;
            int iz = hz & 127;
            x = (float)hz * zw[iz];
            uint32_t ah = hz < 0 ? (uint32_t)(-(int64_t)hz) : (uint32_t)hz;
            if (ah < zk[iz]) break;
            if (iz == 0) {
                for (;;) {
                    float xx = (float)(uint32_t)MWC_NEXT(s) * rngflt;
                    float yy = (float)(uint32_t)MWC_NEXT(s) * rngflt;
                    xx = -(float)log((double)xx + 1.1754943508222875e-38) * 0.2904764f;
                    yy = -(float)log((double)yy + 1.1754943508222875e-38);
                    if (yy + yy >= xx * xx) { x = xx; break; }
                }
                x = hz > 0 ? 3.442620f + x : -3.442620f - x;
                break;
            }
            float u = (float)(uint32_t)MWC_NEXT(s) * rngflt;
            if (u * (zf[iz - 1] - zf[iz]) + zf[iz] < (float)exp(-0.5 * (double)x * (double)x)) break;
            (void)MWC_NEXT(s);
        }
        (void)MWC_NEXT(s);
        out[i] = x;
    }
    *state = s;
}

// ------------------------------------------------------------------ horizontal flip of one row (non in-place), pb in {1,3,4}
void src_fliph_row(const uint8_t *s, uint8_t *d, int cols, int pb) {
    int x = 0;
    if (pb == 3) {
        // 16 pixels (48 bytes) per step: reverse the pixel order with three three-register table lookups (faster than LD3/ST3)
        uint8_t idx[3][16];
        for (int k = 0; k < 3; k++) for (int j = 0; j < 16; j++) { int i = 16 * k + j; idx[k][j] = (uint8_t)(45 - 3 * (i / 3) + i % 3); }
        uint8x16_t i0 = vld1q_u8(idx[0]), i1 = vld1q_u8(idx[1]), i2 = vld1q_u8(idx[2]);
        for (; x + 16 <= cols; x += 16) {
            const uint8_t *sp = s + (size_t)(cols - 16 - x) * 3;
            uint8x16x3_t t = { { vld1q_u8(sp), vld1q_u8(sp + 16), vld1q_u8(sp + 32) } };
            uint8_t *dp = d + (size_t)x * 3;
            vst1q_u8(dp, vqtbl3q_u8(t, i0)); vst1q_u8(dp + 16, vqtbl3q_u8(t, i1)); vst1q_u8(dp + 32, vqtbl3q_u8(t, i2));
        }
    } else if (pb == 4) {
        for (; x + 4 <= cols; x += 4) {
            uint32x4_t v = vld1q_u32((const uint32_t *)(s + (size_t)(cols - 4 - x) * 4));
            v = vrev64q_u32(v); v = vcombine_u32(vget_high_u32(v), vget_low_u32(v));
            vst1q_u32((uint32_t *)(d + (size_t)x * 4), v);
        }
    } else {
        for (; x + 16 <= cols; x += 16) {
            uint8x16_t r = vrev64q_u8(vld1q_u8(s + cols - 16 - x));
            vst1q_u8(d + x, vcombine_u8(vget_high_u8(r), vget_low_u8(r)));
        }
    }
    for (; x < cols; x++) memcpy(d + (size_t)x * pb, s + (size_t)(cols - 1 - x) * pb, pb);
}

// ------------------------------------------------------------------ column sums of a u8 plane (reduce dim 0)
// out[x] = sum over rows of s[y][x] (u32, overwritten). Register-blocked: 64 columns x up to 256 rows live in u16 lanes
// (256 * 255 < 65536), then widen into the u32 totals, so the image is read once with no accumulator traffic.
void src_colsum_u8(const uint8_t *s, ptrdiff_t ss, int rows, int cols, uint32_t *out) {
    int x = 0;
    for (int i = 0; i < cols; i++) out[i] = 0;
    for (; x + 64 <= cols; x += 64) {
        const uint8_t *p = s + x;
        int y = 0;
        while (y < rows) {
            int ye = y + 256 < rows ? y + 256 : rows;
            uint16x8_t a0 = vdupq_n_u16(0), a1 = a0, a2 = a0, a3 = a0, a4 = a0, a5 = a0, a6 = a0, a7 = a0;
            for (; y < ye; y++, p += ss) {
                uint8x16_t v0 = vld1q_u8(p), v1 = vld1q_u8(p + 16), v2 = vld1q_u8(p + 32), v3 = vld1q_u8(p + 48);
                a0 = vaddw_u8(a0, vget_low_u8(v0)); a1 = vaddw_high_u8(a1, v0);
                a2 = vaddw_u8(a2, vget_low_u8(v1)); a3 = vaddw_high_u8(a3, v1);
                a4 = vaddw_u8(a4, vget_low_u8(v2)); a5 = vaddw_high_u8(a5, v2);
                a6 = vaddw_u8(a6, vget_low_u8(v3)); a7 = vaddw_high_u8(a7, v3);
            }
            uint16x8_t a[8] = { a0, a1, a2, a3, a4, a5, a6, a7 };
            for (int k = 0; k < 8; k++) {
                vst1q_u32(out + x + 8 * k, vaddw_u16(vld1q_u32(out + x + 8 * k), vget_low_u16(a[k])));
                vst1q_u32(out + x + 8 * k + 4, vaddw_high_u16(vld1q_u32(out + x + 8 * k + 4), a[k]));
            }
            p = s + x + (ptrdiff_t)y * ss;
        }
    }
    for (; x + 16 <= cols; x += 16) {
        const uint8_t *p = s + x;
        int y = 0;
        while (y < rows) {
            int ye = y + 256 < rows ? y + 256 : rows;
            uint16x8_t a0 = vdupq_n_u16(0), a1 = a0;
            for (; y < ye; y++, p += ss) { uint8x16_t v = vld1q_u8(p); a0 = vaddw_u8(a0, vget_low_u8(v)); a1 = vaddw_high_u8(a1, v); }
            vst1q_u32(out + x, vaddw_u16(vld1q_u32(out + x), vget_low_u16(a0)));
            vst1q_u32(out + x + 4, vaddw_high_u16(vld1q_u32(out + x + 4), a0));
            vst1q_u32(out + x + 8, vaddw_u16(vld1q_u32(out + x + 8), vget_low_u16(a1)));
            vst1q_u32(out + x + 12, vaddw_high_u16(vld1q_u32(out + x + 12), a1));
            p = s + x + (ptrdiff_t)y * ss;
        }
    }
    for (; x < cols; x++) { uint32_t t = 0; for (int y = 0; y < rows; y++) t += s[(ptrdiff_t)y * ss + x]; out[x] += t; }
}

// ------------------------------------------------------------------ row sums of an f32 plane in OpenCV's reduceC order
// out[y] = sum of row y: four 4-lane accumulators over 16-wide blocks folded (v0+v1)+(v2+v3), then 4-wide blocks, then
// (l0+l1)+(l2+l3), then a sequential tail. Four rows are interleaved so the add latency is hidden; every row still
// performs exactly the same additions in the same order (bit-identical to the single-row version).
static inline float rowsum1_f32(const float *t, int width) {
    float32x4_t v0 = vdupq_n_f32(0), v1 = v0, v2 = v0, v3 = v0;
    int i = 0;
    for (; i + 16 <= width; i += 16) {
        v0 = vaddq_f32(v0, vld1q_f32(t + i)); v1 = vaddq_f32(v1, vld1q_f32(t + i + 4));
        v2 = vaddq_f32(v2, vld1q_f32(t + i + 8)); v3 = vaddq_f32(v3, vld1q_f32(t + i + 12));
    }
    float32x4_t v = vaddq_f32(vaddq_f32(v0, v1), vaddq_f32(v2, v3));
    for (; i + 4 <= width; i += 4) v = vaddq_f32(v, vld1q_f32(t + i));
    float acc = (vgetq_lane_f32(v, 0) + vgetq_lane_f32(v, 1)) + (vgetq_lane_f32(v, 2) + vgetq_lane_f32(v, 3));
    for (; i < width; i++) acc += t[i];
    return acc;
}
void src_rowsum_f32(const uint8_t *base, ptrdiff_t stride, int rows, int width, float *out) {
    int y = 0;
    for (; y + 4 <= rows; y += 4) {
        const float *t0 = (const float *)(base + (ptrdiff_t)y * stride), *t1 = (const float *)(base + (ptrdiff_t)(y + 1) * stride);
        const float *t2 = (const float *)(base + (ptrdiff_t)(y + 2) * stride), *t3 = (const float *)(base + (ptrdiff_t)(y + 3) * stride);
        float32x4_t a0 = vdupq_n_f32(0), a1 = a0, a2 = a0, a3 = a0, b0 = a0, b1 = a0, b2 = a0, b3 = a0;
        float32x4_t c0 = a0, c1 = a0, c2 = a0, c3 = a0, d0 = a0, d1 = a0, d2 = a0, d3 = a0;
        int i = 0;
        for (; i + 16 <= width; i += 16) {
            a0 = vaddq_f32(a0, vld1q_f32(t0 + i)); a1 = vaddq_f32(a1, vld1q_f32(t0 + i + 4));
            a2 = vaddq_f32(a2, vld1q_f32(t0 + i + 8)); a3 = vaddq_f32(a3, vld1q_f32(t0 + i + 12));
            b0 = vaddq_f32(b0, vld1q_f32(t1 + i)); b1 = vaddq_f32(b1, vld1q_f32(t1 + i + 4));
            b2 = vaddq_f32(b2, vld1q_f32(t1 + i + 8)); b3 = vaddq_f32(b3, vld1q_f32(t1 + i + 12));
            c0 = vaddq_f32(c0, vld1q_f32(t2 + i)); c1 = vaddq_f32(c1, vld1q_f32(t2 + i + 4));
            c2 = vaddq_f32(c2, vld1q_f32(t2 + i + 8)); c3 = vaddq_f32(c3, vld1q_f32(t2 + i + 12));
            d0 = vaddq_f32(d0, vld1q_f32(t3 + i)); d1 = vaddq_f32(d1, vld1q_f32(t3 + i + 4));
            d2 = vaddq_f32(d2, vld1q_f32(t3 + i + 8)); d3 = vaddq_f32(d3, vld1q_f32(t3 + i + 12));
        }
        float32x4_t va = vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3)), vb = vaddq_f32(vaddq_f32(b0, b1), vaddq_f32(b2, b3));
        float32x4_t vc = vaddq_f32(vaddq_f32(c0, c1), vaddq_f32(c2, c3)), vd = vaddq_f32(vaddq_f32(d0, d1), vaddq_f32(d2, d3));
        for (; i + 4 <= width; i += 4) {
            va = vaddq_f32(va, vld1q_f32(t0 + i)); vb = vaddq_f32(vb, vld1q_f32(t1 + i));
            vc = vaddq_f32(vc, vld1q_f32(t2 + i)); vd = vaddq_f32(vd, vld1q_f32(t3 + i));
        }
        float ra = (vgetq_lane_f32(va, 0) + vgetq_lane_f32(va, 1)) + (vgetq_lane_f32(va, 2) + vgetq_lane_f32(va, 3));
        float rb = (vgetq_lane_f32(vb, 0) + vgetq_lane_f32(vb, 1)) + (vgetq_lane_f32(vb, 2) + vgetq_lane_f32(vb, 3));
        float rc = (vgetq_lane_f32(vc, 0) + vgetq_lane_f32(vc, 1)) + (vgetq_lane_f32(vc, 2) + vgetq_lane_f32(vc, 3));
        float rd = (vgetq_lane_f32(vd, 0) + vgetq_lane_f32(vd, 1)) + (vgetq_lane_f32(vd, 2) + vgetq_lane_f32(vd, 3));
        for (int k = i; k < width; k++) { ra += t0[k]; rb += t1[k]; rc += t2[k]; rd += t3[k]; }
        out[y] = ra; out[y + 1] = rb; out[y + 2] = rc; out[y + 3] = rd;
    }
    for (; y < rows; y++) out[y] = rowsum1_f32((const float *)(base + (ptrdiff_t)y * stride), width);
}

// ------------------------------------------------------------------ masked per-channel sums of u8 pixels
// Zeroing the unselected pixels leaves both the sum and the sum of squares unchanged, so the masked statistics are the
// unmasked kernels run on (pixel & mask); the selected count is the popcount of the mask. cn 1..4, mask nonzero = selected.
void src_sums_u8_mask(const uint8_t *p, const uint8_t *m, size_t cols, int cn, uint64_t *s, uint64_t *q, uint64_t *count, int want_sq) {
    size_t x = 0;
    const uint8x16_t one = vdupq_n_u8(1);
    uint64_t cnt = 0;
    while (x + 16 <= cols) {
        uint32x4_t as[4], aq[4];
        for (int c = 0; c < 4; c++) { as[c] = vdupq_n_u32(0); aq[c] = vdupq_n_u32(0); }
        uint8x16_t cacc = vdupq_n_u8(0);
        size_t lim = x + 16 * 250; if (lim > cols) lim = cols;
        for (; x + 16 <= lim; x += 16) {
            uint8x16_t sel = vtstq_u8(vld1q_u8(m + x), vld1q_u8(m + x));
            cacc = vsubq_u8(cacc, sel);
            uint8x16_t v[4];
            if (cn == 1) v[0] = vld1q_u8(p + x);
            else if (cn == 2) { uint8x16x2_t t = vld2q_u8(p + x * 2); v[0] = t.val[0]; v[1] = t.val[1]; }
            else if (cn == 3) { uint8x16x3_t t = vld3q_u8(p + x * 3); v[0] = t.val[0]; v[1] = t.val[1]; v[2] = t.val[2]; }
            else { uint8x16x4_t t = vld4q_u8(p + x * 4); v[0] = t.val[0]; v[1] = t.val[1]; v[2] = t.val[2]; v[3] = t.val[3]; }
            for (int c = 0; c < cn; c++) {
                uint8x16_t w = vandq_u8(v[c], sel);
                as[c] = DOT(as[c], w, one);
                if (want_sq) aq[c] = DOT(aq[c], w, w);
            }
        }
        cnt += vaddlvq_u8(cacc);
        for (int c = 0; c < cn; c++) { s[c] += vaddvq_u32(as[c]); q[c] += vaddvq_u32(aq[c]); }
    }
    for (; x < cols; x++) {
        if (!m[x]) continue;
        cnt++;
        for (int c = 0; c < cn; c++) { uint64_t v = p[x * cn + c]; s[c] += v; q[c] += v * v; }
    }
    *count += cnt;
}

// ------------------------------------------------------------------ saturating add / sub / absdiff of a repeating pixel pattern
// pat: 48 bytes of the scalar pattern stream (element period cn <= 4 divides 48 bytes for 1- and 2-byte elements).
// n elements of `type` (0 u8, 1 s8, 2 u16, 3 s16). op 0 add, 1 sub (swap: pattern - a), 2 absdiff. The constants stay in registers.
#define PATFN(NAME, T, V, LANES, LD, ST, QADD, QSUB, ABD, RE_IN, RE_OUT)                                              \
    static void NAME(int op, int swap, const T *a, const uint8_t *pat, T *d, size_t n) {                               \
        const size_t VB = 16 / sizeof(T);                                                                              \
        V p0 = RE_IN(vld1q_u8(pat)), p1 = RE_IN(vld1q_u8(pat + 16)), p2 = RE_IN(vld1q_u8(pat + 32));                    \
        const T *pt = (const T *)pat;                                                                                  \
        size_t i = 0;                                                                                                  \
        for (; i + 3 * VB <= n; i += 3 * VB) {                                                                         \
            V x0 = LD(a + i), x1 = LD(a + i + VB), x2 = LD(a + i + 2 * VB);                                            \
            V r0, r1, r2;                                                                                              \
            if (op == 0) { r0 = QADD(x0, p0); r1 = QADD(x1, p1); r2 = QADD(x2, p2); }                                  \
            else if (op == 1) {                                                                                        \
                if (swap) { r0 = QSUB(p0, x0); r1 = QSUB(p1, x1); r2 = QSUB(p2, x2); }                                 \
                else { r0 = QSUB(x0, p0); r1 = QSUB(x1, p1); r2 = QSUB(x2, p2); }                                      \
            } else { r0 = ABD(x0, p0); r1 = ABD(x1, p1); r2 = ABD(x2, p2); }                                           \
            ST(d + i, r0); ST(d + i + VB, r1); ST(d + i + 2 * VB, r2);                                                 \
        }                                                                                                              \
        for (; i < n; i++) {                                                                                           \
            int64_t x = (int64_t)a[i], y = (int64_t)pt[i % (48 / sizeof(T))];                                          \
            int64_t r = op == 0 ? x + y : (op == 1 ? (swap ? y - x : x - y) : (x > y ? x - y : y - x));                \
            d[i] = r < LO_##T ? (T)LO_##T : (r > HI_##T ? (T)HI_##T : (T)r);                                           \
        }                                                                                                              \
    }
static inline uint8x16_t abdq_u8(uint8x16_t a, uint8x16_t b) { return vabdq_u8(a, b); }
static inline uint16x8_t abdq_u16(uint16x8_t a, uint16x8_t b) { return vabdq_u16(a, b); }
#define RE_U8(v) (v)
#define RE_S8(v) vreinterpretq_s8_u8(v)
#define RE_U16(v) vreinterpretq_u16_u8(v)
#define RE_S16(v) vreinterpretq_s16_u8(v)
PATFN(pat_u8, uint8_t, uint8x16_t, 16, vld1q_u8, vst1q_u8, vqaddq_u8, vqsubq_u8, abdq_u8, RE_U8, RE_U8)
PATFN(pat_s8, int8_t, int8x16_t, 16, vld1q_s8, vst1q_s8, vqaddq_s8, vqsubq_s8, abd_s8, RE_S8, RE_S8)
PATFN(pat_u16, uint16_t, uint16x8_t, 8, vld1q_u16, vst1q_u16, vqaddq_u16, vqsubq_u16, abdq_u16, RE_U16, RE_U16)
PATFN(pat_s16, int16_t, int16x8_t, 8, vld1q_s16, vst1q_s16, vqaddq_s16, vqsubq_s16, abd_s16, RE_S16, RE_S16)
void src_addsub_pat(int type, int op, int swap, const void *a, const uint8_t *pat, void *d, size_t n) {
    switch (type) {
    case 0: pat_u8(op, swap, a, pat, d, n); break;
    case 1: pat_s8(op, swap, a, pat, d, n); break;
    case 2: pat_u16(op, swap, a, pat, d, n); break;
    default: pat_s16(op, swap, a, pat, d, n); break;
    }
}

// ------------------------------------------------------------------ compare (mask 255 / 0)
// op: 0 EQ, 1 GT, 2 GE, 3 LT, 4 LE, 5 NE (cv::CmpTypes mapped by the caller as in sr_core_compare)
void src_cmp_u8(int op, const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n) {
    size_t i = 0;
#define CMPU8(CMP, EXPR_NOT)                                                                                          \
    for (; i + 16 <= n; i += 16) { uint8x16_t r = CMP(vld1q_u8(a + i), vld1q_u8(b + i)); vst1q_u8(d + i, EXPR_NOT(r)); }
#define ID8(r) (r)
#define NOT8(r) vmvnq_u8(r)
    switch (op) {
    case 0: CMPU8(vceqq_u8, ID8) break;
    case 1: CMPU8(vcgtq_u8, ID8) break;
    case 2: CMPU8(vcgeq_u8, ID8) break;
    case 3: CMPU8(vcltq_u8, ID8) break;
    case 4: CMPU8(vcleq_u8, ID8) break;
    default: CMPU8(vceqq_u8, NOT8) break;
    }
    for (; i < n; i++) {
        uint8_t x = a[i], y = b[i];
        int r = op == 0 ? x == y : op == 1 ? x > y : op == 2 ? x >= y : op == 3 ? x < y : op == 4 ? x <= y : x != y;
        d[i] = r ? 255 : 0;
    }
}
static inline uint8x16_t narrow4_f32_mask(uint32x4_t m0, uint32x4_t m1, uint32x4_t m2, uint32x4_t m3) {
    // all-ones / all-zero lanes: keep the low half of each 32-bit lane, then the low byte of each 16-bit lane (2 + 1 shuffles)
    uint16x8_t a = vuzp1q_u16(vreinterpretq_u16_u32(m0), vreinterpretq_u16_u32(m1)), b = vuzp1q_u16(vreinterpretq_u16_u32(m2), vreinterpretq_u16_u32(m3));
    return vuzp1q_u8(vreinterpretq_u8_u16(a), vreinterpretq_u8_u16(b));
}
// b == NULL: compare against the scalar s. NaN: every comparison is false except NE (as for C float compares).
#define CMPF_LOOP(CMP, NOTF, L0, L1, L2, L3)                                                                            \
    for (; i + 16 <= n; i += 16) {                                                                                      \
        uint32x4_t m0 = CMP(vld1q_f32(a + i), L0), m1 = CMP(vld1q_f32(a + i + 4), L1);                                  \
        uint32x4_t m2 = CMP(vld1q_f32(a + i + 8), L2), m3 = CMP(vld1q_f32(a + i + 12), L3);                             \
        uint8x16_t r = narrow4_f32_mask(m0, m1, m2, m3);                                                                \
        vst1q_u8(d + i, NOTF ? vmvnq_u8(r) : r);                                                                        \
    }
#define CMPF_SC(CMP, NOTF) CMPF_LOOP(CMP, NOTF, sv, sv, sv, sv)
#define CMPF_AR(CMP, NOTF) CMPF_LOOP(CMP, NOTF, vld1q_f32(b + i), vld1q_f32(b + i + 4), vld1q_f32(b + i + 8), vld1q_f32(b + i + 12))
void src_cmp_f32(int op, const float *a, const float *b, float s, uint8_t *d, size_t n) {
    size_t i = 0;
    float32x4_t sv = vdupq_n_f32(s);
    if (b) {
        switch (op) {
        case 0: CMPF_AR(vceqq_f32, 0) break;
        case 1: CMPF_AR(vcgtq_f32, 0) break;
        case 2: CMPF_AR(vcgeq_f32, 0) break;
        case 3: CMPF_AR(vcltq_f32, 0) break;
        case 4: CMPF_AR(vcleq_f32, 0) break;
        default: CMPF_AR(vceqq_f32, 1) break;
        }
    } else {
        switch (op) {
        case 0: CMPF_SC(vceqq_f32, 0) break;
        case 1: CMPF_SC(vcgtq_f32, 0) break;
        case 2: CMPF_SC(vcgeq_f32, 0) break;
        case 3: CMPF_SC(vcltq_f32, 0) break;
        case 4: CMPF_SC(vcleq_f32, 0) break;
        default: CMPF_SC(vceqq_f32, 1) break;
        }
    }
    for (; i < n; i++) {
        float x = a[i], y = b ? b[i] : s;
        int r = op == 0 ? x == y : op == 1 ? x > y : op == 2 ? x >= y : op == 3 ? x < y : op == 4 ? x <= y : x != y;
        d[i] = r ? 255 : 0;
    }
}

// ------------------------------------------------------------------ exp (f32)
// x = n ln2 + r (|r| <= ln2/2, Cody-Waite split of ln2), exp(r) by a degree-7 polynomial with fused multiply-adds, scaled by 2^n
// through the exponent field. n comes from the "magic number" rounding (x*log2e + 1.5*2^23 leaves n in the low mantissa bits, so
// the 2^n scale is two integer ops). Groups of 16 lanes outside [-86, 86] (or NaN) are redone with libm expf. Max error ~1.1 ulp.
static inline float32x4_t exp4(float32x4_t x) {
    const float32x4_t log2e = vdupq_n_f32(1.44269504088896341f), magic = vdupq_n_f32(12582912.0f);
    const float32x4_t ln2hi = vdupq_n_f32(0.693145751953125f), ln2lo = vdupq_n_f32(1.42860677e-06f);
    const float32x4_t c2 = vdupq_n_f32(0.5f), c3 = vdupq_n_f32(1.0f / 6.0f), c4 = vdupq_n_f32(1.0f / 24.0f), c5 = vdupq_n_f32(1.0f / 120.0f);
    const float32x4_t c6 = vdupq_n_f32(1.0f / 720.0f), c7 = vdupq_n_f32(1.0f / 5040.0f), one = vdupq_n_f32(1.0f);
    float32x4_t t = vfmaq_f32(magic, x, log2e);               // rounded to an integer n in the low mantissa bits
    float32x4_t nf = vsubq_f32(t, magic);
    float32x4_t r = vfmsq_f32(x, nf, ln2hi);
    r = vfmsq_f32(r, nf, ln2lo);
    float32x4_t q = vfmaq_f32(c6, c7, r);                     // Horner: exp(r) = 1 + r (1 + r (c2 + r (c3 + ... + c7 r)))
    q = vfmaq_f32(c5, q, r); q = vfmaq_f32(c4, q, r); q = vfmaq_f32(c3, q, r); q = vfmaq_f32(c2, q, r);
    q = vfmaq_f32(one, q, r);
    float32x4_t p = vfmaq_f32(one, q, r);
    // 2^n by adding n to the exponent field of p (p in [0.70, 1.42] so |n| <= 124 keeps the result a normal number)
    return vreinterpretq_f32_s32(vaddq_s32(vreinterpretq_s32_f32(p), vshlq_n_s32(vreinterpretq_s32_f32(t), 23)));
}
void src_exp32(const float *a, float *d, size_t n) {
    const float32x4_t lim = vdupq_n_f32(86.0f);
    size_t i = 0;
    for (; i + 16 <= n; i += 16) {
        float32x4_t x0 = vld1q_f32(a + i), x1 = vld1q_f32(a + i + 4), x2 = vld1q_f32(a + i + 8), x3 = vld1q_f32(a + i + 12);
        uint32x4_t ok = vandq_u32(vandq_u32(vcaltq_f32(x0, lim), vcaltq_f32(x1, lim)), vandq_u32(vcaltq_f32(x2, lim), vcaltq_f32(x3, lim)));
        if (vminvq_u32(ok) == 0) { for (int k = 0; k < 16; k++) d[i + k] = expf(a[i + k]); continue; }
        vst1q_f32(d + i, exp4(x0)); vst1q_f32(d + i + 4, exp4(x1)); vst1q_f32(d + i + 8, exp4(x2)); vst1q_f32(d + i + 12, exp4(x3));
    }
    for (; i < n; i++) d[i] = expf(a[i]);
}

// ------------------------------------------------------------------ copyMakeBorder
// cv::borderInterpolate for types 1 (replicate), 2 (reflect), 3 (wrap), 4 (reflect 101); -1 = constant.
static int border_idx(int p, int len, int type) {
    if (p >= 0 && p < len) return p;
    switch (type) {
    case 1: return p < 0 ? 0 : len - 1;
    case 2: case 4: {
        if (len == 1) return 0;
        int delta = type == 4 ? 1 : 0;
        do { if (p < 0) p = -p - 1 + delta; else p = len - 1 - (p - len) - delta; } while (p < 0 || p >= len);
        return p;
    }
    case 3:
        if (p < 0) p -= ((p - len + 1) / len) * len;
        if (p >= len) p %= len;
        return p;
    default: return -1;
    }
}
// Copies cnt pixels of PB bytes: out[k] = row[map[k]] (map < 0: constant pixel). PB is a compile-time constant so every
// copy is a plain load/store.
#define STRIP(PB) static void strip_##PB(uint8_t *out, const uint8_t *row, const int32_t *map, int cnt, const uint8_t *cpix) { \
        for (int k = 0; k < cnt; k++) memcpy(out + (size_t)k * PB, map[k] < 0 ? cpix : row + (size_t)map[k] * PB, PB); }
STRIP(1) STRIP(2) STRIP(3) STRIP(4) STRIP(6) STRIP(8) STRIP(12) STRIP(16)
static void strip_any(uint8_t *out, const uint8_t *row, const int32_t *map, int cnt, const uint8_t *cpix, int pb) {
    for (int k = 0; k < cnt; k++) memcpy(out + (size_t)k * pb, map[k] < 0 ? cpix : row + (size_t)map[k] * pb, pb);
}
static void strip_fill(int pb, uint8_t *out, const uint8_t *row, const int32_t *map, int cnt, const uint8_t *cpix) {
    switch (pb) {
    case 1: strip_1(out, row, map, cnt, cpix); break;
    case 2: strip_2(out, row, map, cnt, cpix); break;
    case 3: strip_3(out, row, map, cnt, cpix); break;
    case 4: strip_4(out, row, map, cnt, cpix); break;
    case 6: strip_6(out, row, map, cnt, cpix); break;
    case 8: strip_8(out, row, map, cnt, cpix); break;
    case 12: strip_12(out, row, map, cnt, cpix); break;
    case 16: strip_16(out, row, map, cnt, cpix); break;
    default: strip_any(out, row, map, cnt, cpix, pb);
    }
}
// Returns 0, or -1 when the scratch maps cannot be allocated. d is (srows+top+bottom) x (scols+left+right); cpix = one constant pixel (type 0).
int src_copyborder(const uint8_t *s, ptrdiff_t ss, int srows, int scols, uint8_t *d, ptrdiff_t ds, int top, int bottom, int left, int right,
                   int pb, int type, const uint8_t *cpix) {
    int drows = srows + top + bottom;
    int32_t *lmap = malloc((size_t)(left + right + 1) * sizeof(int32_t));
    if (!lmap) return -1;
    int32_t *rmap = lmap + left;
    for (int x = 0; x < left; x++) lmap[x] = type == 0 ? -1 : border_idx(x - left, scols, type);
    for (int j = 0; j < right; j++) rmap[j] = type == 0 ? -1 : border_idx(scols + j, scols, type);
    size_t rowb = (size_t)(scols + left + right) * pb;
    const uint8_t *cconst = NULL;
    for (int y = 0; y < drows; y++) {
        uint8_t *dr = d + (ptrdiff_t)y * ds;
        int sy = y - top;
        if (type == 0 && (sy < 0 || sy >= srows)) {          // constant row: build once, then copy
            if (cconst) memcpy(dr, cconst, rowb);
            else { for (size_t k = 0; k < rowb; k += pb) memcpy(dr + k, cpix, pb); cconst = dr; }
            continue;
        }
        const uint8_t *sr = s + (ptrdiff_t)(type == 0 ? sy : border_idx(sy, srows, type)) * ss;
        memcpy(dr + (size_t)left * pb, sr, (size_t)scols * pb);
        strip_fill(pb, dr, sr, lmap, left, cpix);
        strip_fill(pb, dr + (size_t)(left + scols) * pb, sr, rmap, right, cpix);
    }
    free(lmap);
    return 0;
}

// ------------------------------------------------------------------ randn affine step (float32): out = fma(out, std[c], mean[c])
// In place over n generated samples; element i belongs to channel (ch0 + i) % cn. fmaf(sample, std, mean) == cv2's float32 flow.
void src_randn_affine_f32(float *out, int n, const float *mean, const float *std, int cn, int ch0) {
    int i = 0;
    if (cn == 1) {
        float32x4_t m = vdupq_n_f32(mean[0]), sd = vdupq_n_f32(std[0]);
        for (; i + 4 <= n; i += 4) vst1q_f32(out + i, vfmaq_f32(m, vld1q_f32(out + i), sd));
        for (; i < n; i++) out[i] = fmaf(out[i], std[0], mean[0]);
        return;
    }
    int c = ch0 % cn;
    for (; i < n; i++) { out[i] = fmaf(out[i], std[c], mean[c]); if (++c == cn) c = 0; }
}

// ------------------------------------------------------------------ phase (cv::fastAtan2 float32 kernel, degrees, optional scale)
// Same operations in the same order as OpenCV's fused-multiply-add float32 kernel: c = min/(max + eps), polynomial in c^2 with
// three fused steps, quadrant fix-ups 90 - a, 180 - a, 360 - a. out = angle * scale (scale == 1: plain degrees).
void src_phase32(const float *x, const float *y, float *o, size_t n, float scale) {
    const float rad2deg = (float)(180.0 / 3.14159265358979323846);
    const float32x4_t P1 = vdupq_n_f32((float)0.9997878412794807 * rad2deg), P3 = vdupq_n_f32((float)-0.3258083974640975 * rad2deg);
    const float32x4_t P5 = vdupq_n_f32((float)0.1555786518463281 * rad2deg), P7 = vdupq_n_f32((float)-0.04432655554792128 * rad2deg);
    const float32x4_t eps = vdupq_n_f32(2.220446049250313e-16f), c90 = vdupq_n_f32(90.0f), c180 = vdupq_n_f32(180.0f), c360 = vdupq_n_f32(360.0f);
    const float32x4_t zero = vdupq_n_f32(0.0f), sc = vdupq_n_f32(scale);
    size_t i = 0;
    for (; i + 4 <= n; i += 4) {
        float32x4_t vx = vld1q_f32(x + i), vy = vld1q_f32(y + i);
        float32x4_t ax = vabsq_f32(vx), ay = vabsq_f32(vy);
        uint32x4_t big = vcgeq_f32(ax, ay);                        // |x| >= |y|
        float32x4_t num = vbslq_f32(big, ay, ax), den = vbslq_f32(big, ax, ay);
        float32x4_t c = vdivq_f32(num, vaddq_f32(den, eps)), c2 = vmulq_f32(c, c);
        float32x4_t t = vfmaq_f32(P5, P7, c2);
        float32x4_t u = vfmaq_f32(P3, t, c2);
        float32x4_t a = vmulq_f32(vfmaq_f32(P1, u, c2), c);
        a = vbslq_f32(big, a, vsubq_f32(c90, a));
        a = vbslq_f32(vcltq_f32(vx, zero), vsubq_f32(c180, a), a);
        a = vbslq_f32(vcltq_f32(vy, zero), vsubq_f32(c360, a), a);
        vst1q_f32(o + i, scale == 1.0f ? a : vmulq_f32(a, sc));
    }
    const float P1s = (float)0.9997878412794807 * rad2deg, P3s = (float)-0.3258083974640975 * rad2deg, P5s = (float)0.1555786518463281 * rad2deg, P7s = (float)-0.04432655554792128 * rad2deg;
    for (; i < n; i++) {
        float xx = x[i], yy = y[i], ax = fabsf(xx), ay = fabsf(yy), a;
        float num = ax >= ay ? ay : ax, den = ax >= ay ? ax : ay;
        float c = num / (den + 2.220446049250313e-16f), c2 = c * c;
        float t = fmaf(P7s, c2, P5s), u = fmaf(t, c2, P3s);
        a = fmaf(u, c2, P1s) * c;
        if (!(ax >= ay)) a = 90.0f - a;
        if (xx < 0) a = 180.0f - a;
        if (yy < 0) a = 360.0f - a;
        o[i] = scale == 1.0f ? a : a * scale;
    }
}

// ------------------------------------------------------------------ max |a - b| (or max |a|) over f32; NaN in the input gives NaN
float src_maxabs_f32(const float *a, const float *b, size_t n) {
    float32x4_t m0 = vdupq_n_f32(0), m1 = m0, m2 = m0, m3 = m0;
    size_t i = 0;
    if (b) {
        for (; i + 16 <= n; i += 16) {
            m0 = vmaxq_f32(m0, vabdq_f32(vld1q_f32(a + i), vld1q_f32(b + i))); m1 = vmaxq_f32(m1, vabdq_f32(vld1q_f32(a + i + 4), vld1q_f32(b + i + 4)));
            m2 = vmaxq_f32(m2, vabdq_f32(vld1q_f32(a + i + 8), vld1q_f32(b + i + 8))); m3 = vmaxq_f32(m3, vabdq_f32(vld1q_f32(a + i + 12), vld1q_f32(b + i + 12)));
        }
    } else {
        for (; i + 16 <= n; i += 16) {
            m0 = vmaxq_f32(m0, vabsq_f32(vld1q_f32(a + i))); m1 = vmaxq_f32(m1, vabsq_f32(vld1q_f32(a + i + 4)));
            m2 = vmaxq_f32(m2, vabsq_f32(vld1q_f32(a + i + 8))); m3 = vmaxq_f32(m3, vabsq_f32(vld1q_f32(a + i + 12)));
        }
    }
    float r = vmaxvq_f32(vmaxq_f32(vmaxq_f32(m0, m1), vmaxq_f32(m2, m3)));   // fmaxv propagates NaN
    for (; i < n; i++) {
        float v = b ? fabsf(a[i] - b[i]) : fabsf(a[i]);
        if (v != v) return v;
        if (v > r) r = v;
    }
    return r;
}

// ------------------------------------------------------------------ 256-entry byte table lookup
// Four-register table lookups (TBL/TBX over the four 64-byte quarters of the table); in place (d == s) is allowed.
void src_lut_u8(const uint8_t *s, uint8_t *d, size_t n, const uint8_t *tab) {
    uint8x16x4_t t0 = vld1q_u8_x4(tab), t1 = vld1q_u8_x4(tab + 64), t2 = vld1q_u8_x4(tab + 128), t3 = vld1q_u8_x4(tab + 192);
    const uint8x16_t c64 = vdupq_n_u8(64), c128 = vdupq_n_u8(128), c192 = vdupq_n_u8(192);
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        uint8x16_t i0 = vld1q_u8(s + i), i1 = vld1q_u8(s + i + 16);
        uint8x16_t r0 = vqtbl4q_u8(t0, i0), r1 = vqtbl4q_u8(t0, i1);
        r0 = vqtbx4q_u8(r0, t1, vsubq_u8(i0, c64)); r1 = vqtbx4q_u8(r1, t1, vsubq_u8(i1, c64));
        r0 = vqtbx4q_u8(r0, t2, vsubq_u8(i0, c128)); r1 = vqtbx4q_u8(r1, t2, vsubq_u8(i1, c128));
        r0 = vqtbx4q_u8(r0, t3, vsubq_u8(i0, c192)); r1 = vqtbx4q_u8(r1, t3, vsubq_u8(i1, c192));
        vst1q_u8(d + i, r0); vst1q_u8(d + i + 16, r1);
    }
    for (; i < n; i++) d[i] = tab[s[i]];
}
