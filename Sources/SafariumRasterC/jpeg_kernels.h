// SafariumRasterC — shared inline NEON JPEG kernels (YCbCr, s16 AAN FDCT + quant, Annex K Huffman).
#ifndef SR_JPEG_KERNELS_H
#define SR_JPEG_KERNELS_H

#include <arm_neon.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t *out;
    intptr_t pos;
    uint64_t acc;
    intptr_t n;
    intptr_t count;    // MCUs coded so far (restart bookkeeping)
    intptr_t rstNum;
    intptr_t pred[3];
} SRJState;

// MARK: - Color conversion (JFIF fixed-point, bit-exact to libjpeg jccolor.c)

static inline void sr_ycc16(uint8x8_t B, uint8x8_t G, uint8x8_t R,
                            uint8x8_t *y, uint8x8_t *cb, uint8x8_t *cr) {
    uint16x8_t ly = vmull_u8(R, vdup_n_u8(139));
    ly = vmlal_u8(ly, G, vdup_n_u8(70));
    ly = vmlal_u8(ly, B, vdup_n_u8(47));
    uint16x8_t yy = vmull_u8(R, vdup_n_u8(76));
    yy = vmlal_u8(yy, G, vdup_n_u8(150));
    yy = vmlal_u8(yy, B, vdup_n_u8(29));
    yy = vaddq_u16(vaddq_u16(yy, vshrq_n_u16(ly, 8)), vdupq_n_u16(128));
    *y = vshrn_n_u16(yy, 8);

    uint16x8_t lb = vmull_u8(R, vdup_n_u8(51));
    lb = vmlal_u8(lb, G, vdup_n_u8(205));
    uint16x8_t cc = vmlal_u8(vdupq_n_u16(32895), B, vdup_n_u8(128));
    cc = vmlsl_u8(cc, R, vdup_n_u8(43));
    cc = vmlsl_u8(cc, G, vdup_n_u8(84));
    *cb = vshrn_n_u16(vsubq_u16(cc, vshrq_n_u16(lb, 8)), 8);

    uint16x8_t lr = vmull_u8(G, vdup_n_u8(47));
    lr = vmlal_u8(lr, B, vdup_n_u8(209));
    uint16x8_t cr2 = vmlal_u8(vdupq_n_u16(32895), R, vdup_n_u8(128));
    cr2 = vmlsl_u8(cr2, G, vdup_n_u8(107));
    cr2 = vmlsl_u8(cr2, B, vdup_n_u8(20));
    *cr = vshrn_n_u16(vsubq_u16(cr2, vshrq_n_u16(lr, 8)), 8);
}

static inline void sr_load16_bgr(const uint8_t *row, int ch, int w, int x,
                                 uint8x16_t *B, uint8x16_t *G, uint8x16_t *R) {
    if (x + 16 <= w) {
        if (ch == 3) {
            uint8x16x3_t v = vld3q_u8(row + (size_t)x * 3);
            *B = v.val[0]; *G = v.val[1]; *R = v.val[2];
        } else {
            uint8x16x4_t v = vld4q_u8(row + (size_t)x * 4);
            *B = v.val[0]; *G = v.val[1]; *R = v.val[2];
        }
        return;
    }
    uint8_t tmp[64];
    int n = w - x;
    if (n > 0) {
        memcpy(tmp, row + (size_t)x * ch, (size_t)n * ch);
    } else {
        n = 0;
    }
    const uint8_t *last = row + (size_t)(w - 1) * ch;
    for (int i = n; i < 16; i++) memcpy(tmp + (size_t)i * ch, last, (size_t)ch);
    if (ch == 3) {
        uint8x16x3_t v = vld3q_u8(tmp);
        *B = v.val[0]; *G = v.val[1]; *R = v.val[2];
    } else {
        uint8x16x4_t v = vld4q_u8(tmp);
        *B = v.val[0]; *G = v.val[1]; *R = v.val[2];
    }
}

static inline void sr_jpeg_ycc420_inl(const uint8_t * __restrict src, intptr_t stride, int ch, int w, int rows, int pw,
                                      uint8_t * __restrict yStrip, uint8_t * __restrict cc) {
    const uint16x8_t bias = vcombine_u16(vcreate_u16(0x0002000100020001ULL),
                                         vcreate_u16(0x0002000100020001ULL));
    for (int k = 0; k < 8; k++) {
        int r0 = 2 * k < rows ? 2 * k : rows - 1;
        int r1 = 2 * k + 1 < rows ? 2 * k + 1 : rows - 1;
        const uint8_t *p0 = src + (intptr_t)r0 * stride;
        const uint8_t *p1 = src + (intptr_t)r1 * stride;
        uint8_t *ys0 = yStrip + (size_t)(2 * k) * pw;
        uint8_t *ys1 = ys0 + pw;
        uint8_t *cco = cc + (size_t)k * pw;
        int x = 0;
        for (; x + 16 <= w; x += 16) {
            uint8x16_t B0, G0, R0, B1, G1, R1;
            if (ch == 3) {
                uint8x16x3_t v0 = vld3q_u8(p0 + (size_t)x * 3);
                uint8x16x3_t v1 = vld3q_u8(p1 + (size_t)x * 3);
                B0 = v0.val[0]; G0 = v0.val[1]; R0 = v0.val[2];
                B1 = v1.val[0]; G1 = v1.val[1]; R1 = v1.val[2];
            } else {
                uint8x16x4_t v0 = vld4q_u8(p0 + (size_t)x * 4);
                uint8x16x4_t v1 = vld4q_u8(p1 + (size_t)x * 4);
                B0 = v0.val[0]; G0 = v0.val[1]; R0 = v0.val[2];
                B1 = v1.val[0]; G1 = v1.val[1]; R1 = v1.val[2];
            }
            uint8x8_t y0l, y0h, c0bl, c0bh, c0rl, c0rh;
            uint8x8_t y1l, y1h, c1bl, c1bh, c1rl, c1rh;
            sr_ycc16(vget_low_u8(B0), vget_low_u8(G0), vget_low_u8(R0), &y0l, &c0bl, &c0rl);
            sr_ycc16(vget_high_u8(B0), vget_high_u8(G0), vget_high_u8(R0), &y0h, &c0bh, &c0rh);
            sr_ycc16(vget_low_u8(B1), vget_low_u8(G1), vget_low_u8(R1), &y1l, &c1bl, &c1rl);
            sr_ycc16(vget_high_u8(B1), vget_high_u8(G1), vget_high_u8(R1), &y1h, &c1bh, &c1rh);
            vst1q_u8(ys0 + x, vcombine_u8(y0l, y0h));
            vst1q_u8(ys1 + x, vcombine_u8(y1l, y1h));
            uint16x8_t sb = vaddq_u16(vpaddlq_u8(vcombine_u8(c0bl, c0bh)),
                                      vpaddlq_u8(vcombine_u8(c1bl, c1bh)));
            uint16x8_t sr = vaddq_u16(vpaddlq_u8(vcombine_u8(c0rl, c0rh)),
                                      vpaddlq_u8(vcombine_u8(c1rl, c1rh)));
            uint8x8x2_t o;
            o.val[0] = vshrn_n_u16(vaddq_u16(sb, bias), 2);
            o.val[1] = vshrn_n_u16(vaddq_u16(sr, bias), 2);
            vst2_u8(cco + x, o);
        }
        for (; x < pw; x += 16) {
            uint8x16_t B0, G0, R0, B1, G1, R1;
            sr_load16_bgr(p0, ch, w, x, &B0, &G0, &R0);
            sr_load16_bgr(p1, ch, w, x, &B1, &G1, &R1);
            uint8x8_t y0l, y0h, c0bl, c0bh, c0rl, c0rh;
            uint8x8_t y1l, y1h, c1bl, c1bh, c1rl, c1rh;
            sr_ycc16(vget_low_u8(B0), vget_low_u8(G0), vget_low_u8(R0), &y0l, &c0bl, &c0rl);
            sr_ycc16(vget_high_u8(B0), vget_high_u8(G0), vget_high_u8(R0), &y0h, &c0bh, &c0rh);
            sr_ycc16(vget_low_u8(B1), vget_low_u8(G1), vget_low_u8(R1), &y1l, &c1bl, &c1rl);
            sr_ycc16(vget_high_u8(B1), vget_high_u8(G1), vget_high_u8(R1), &y1h, &c1bh, &c1rh);
            vst1q_u8(ys0 + x, vcombine_u8(y0l, y0h));
            vst1q_u8(ys1 + x, vcombine_u8(y1l, y1h));
            uint16x8_t sb = vaddq_u16(vpaddlq_u8(vcombine_u8(c0bl, c0bh)),
                                      vpaddlq_u8(vcombine_u8(c1bl, c1bh)));
            uint16x8_t sr = vaddq_u16(vpaddlq_u8(vcombine_u8(c0rl, c0rh)),
                                      vpaddlq_u8(vcombine_u8(c1rl, c1rh)));
            uint8x8x2_t o;
            o.val[0] = vshrn_n_u16(vaddq_u16(sb, bias), 2);
            o.val[1] = vshrn_n_u16(vaddq_u16(sr, bias), 2);
            vst2_u8(cco + x, o);
        }
    }
}

// MARK: - 16-bit NEON AAN FDCT + Fixed-Point Quantisation

static inline uint8x8_t sr_load_block_row(const uint8_t *p, int par) {
    return par < 0 ? vld1_u8(p) : vld2_u8(p).val[par];
}

static inline void sr_tr8_s16(int16x8_t r[8]) {
    int16x8x2_t a0 = vtrnq_s16(r[0], r[1]);
    int16x8x2_t a1 = vtrnq_s16(r[2], r[3]);
    int16x8x2_t a2 = vtrnq_s16(r[4], r[5]);
    int16x8x2_t a3 = vtrnq_s16(r[6], r[7]);
    int32x4x2_t b0 = vtrnq_s32(vreinterpretq_s32_s16(a0.val[0]), vreinterpretq_s32_s16(a1.val[0]));
    int32x4x2_t b1 = vtrnq_s32(vreinterpretq_s32_s16(a0.val[1]), vreinterpretq_s32_s16(a1.val[1]));
    int32x4x2_t b2 = vtrnq_s32(vreinterpretq_s32_s16(a2.val[0]), vreinterpretq_s32_s16(a3.val[0]));
    int32x4x2_t b3 = vtrnq_s32(vreinterpretq_s32_s16(a2.val[1]), vreinterpretq_s32_s16(a3.val[1]));
    r[0] = vreinterpretq_s16_s64(vcombine_s64(vget_low_s64(vreinterpretq_s64_s32(b0.val[0])),
                                              vget_low_s64(vreinterpretq_s64_s32(b2.val[0]))));
    r[4] = vreinterpretq_s16_s64(vcombine_s64(vget_high_s64(vreinterpretq_s64_s32(b0.val[0])),
                                              vget_high_s64(vreinterpretq_s64_s32(b2.val[0]))));
    r[1] = vreinterpretq_s16_s64(vcombine_s64(vget_low_s64(vreinterpretq_s64_s32(b1.val[0])),
                                              vget_low_s64(vreinterpretq_s64_s32(b3.val[0]))));
    r[5] = vreinterpretq_s16_s64(vcombine_s64(vget_high_s64(vreinterpretq_s64_s32(b1.val[0])),
                                              vget_high_s64(vreinterpretq_s64_s32(b3.val[0]))));
    r[2] = vreinterpretq_s16_s64(vcombine_s64(vget_low_s64(vreinterpretq_s64_s32(b0.val[1])),
                                              vget_low_s64(vreinterpretq_s64_s32(b2.val[1]))));
    r[6] = vreinterpretq_s16_s64(vcombine_s64(vget_high_s64(vreinterpretq_s64_s32(b0.val[1])),
                                              vget_high_s64(vreinterpretq_s64_s32(b2.val[1]))));
    r[3] = vreinterpretq_s16_s64(vcombine_s64(vget_low_s64(vreinterpretq_s64_s32(b1.val[1])),
                                              vget_low_s64(vreinterpretq_s64_s32(b3.val[1]))));
    r[7] = vreinterpretq_s16_s64(vcombine_s64(vget_high_s64(vreinterpretq_s64_s32(b1.val[1])),
                                              vget_high_s64(vreinterpretq_s64_s32(b3.val[1]))));
}

static inline void sr_aan_s16(int16x8_t d0, int16x8_t d1, int16x8_t d2, int16x8_t d3,
                              int16x8_t d4, int16x8_t d5, int16x8_t d6, int16x8_t d7,
                              int16x8_t *o0, int16x8_t *o1, int16x8_t *o2, int16x8_t *o3,
                              int16x8_t *o4, int16x8_t *o5, int16x8_t *o6, int16x8_t *o7) {
    int16x8_t t0 = vaddq_s16(d0, d7), t7 = vsubq_s16(d0, d7);
    int16x8_t t1 = vaddq_s16(d1, d6), t6 = vsubq_s16(d1, d6);
    int16x8_t t2 = vaddq_s16(d2, d5), t5 = vsubq_s16(d2, d5);
    int16x8_t t3 = vaddq_s16(d3, d4), t4 = vsubq_s16(d3, d4);
    int16x8_t t10 = vaddq_s16(t0, t3), t13 = vsubq_s16(t0, t3);
    int16x8_t t11 = vaddq_s16(t1, t2), t12 = vsubq_s16(t1, t2);
    *o0 = vaddq_s16(t10, t11); *o4 = vsubq_s16(t10, t11);
    const int16x8_t c707 = vdupq_n_s16(23170); // round(0.707106781 * 32768)
    const int16x8_t c382 = vdupq_n_s16(12540); // round(0.382683433 * 32768)
    const int16x8_t c541 = vdupq_n_s16(17734); // round(0.541196100 * 32768)
    const int16x8_t c306 = vdupq_n_s16(10045); // round(0.306562965 * 32768)
    int16x8_t z1 = vqrdmulhq_s16(vaddq_s16(t12, t13), c707);
    *o2 = vaddq_s16(t13, z1); *o6 = vsubq_s16(t13, z1);
    int16x8_t u10 = vaddq_s16(t4, t5), u11 = vaddq_s16(t5, t6), u12 = vaddq_s16(t6, t7);
    int16x8_t z5 = vqrdmulhq_s16(vsubq_s16(u10, u12), c382);
    int16x8_t z2 = vaddq_s16(z5, vqrdmulhq_s16(u10, c541));
    int16x8_t z4 = vaddq_s16(vaddq_s16(z5, u12), vqrdmulhq_s16(u12, c306));
    int16x8_t z3 = vqrdmulhq_s16(u11, c707);
    int16x8_t z11 = vaddq_s16(t7, z3), z13 = vsubq_s16(t7, z3);
    *o5 = vaddq_s16(z13, z2); *o3 = vsubq_s16(z13, z2);
    *o1 = vaddq_s16(z11, z4); *o7 = vsubq_s16(z11, z4);
}

static inline __attribute__((always_inline)) uint64_t sr_jpeg_block_s16_inl(
    const uint8_t * __restrict src, intptr_t stride, int par,
    const int32_t * __restrict recip32, int16_t * __restrict out, const uint64_t * __restrict zzmask) {
    uint8x8_t px[8];
    for (int k = 0; k < 8; k++) px[k] = sr_load_block_row(src + (intptr_t)k * stride, par);
    int16x8_t r[8];
    const int16x8_t c128 = vdupq_n_s16(128);
    for (int k = 0; k < 8; k++) {
        r[k] = vshlq_n_s16(vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(px[k])), c128), 2);
    }
    int16x8_t a[8], p[8];
    sr_aan_s16(r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], &a[0], &a[1], &a[2], &a[3], &a[4], &a[5], &a[6], &a[7]);
    sr_tr8_s16(a);
    for (int k = 0; k < 8; k++) a[k] = vrshrq_n_s16(a[k], 1);
    sr_aan_s16(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], &p[0], &p[1], &p[2], &p[3], &p[4], &p[5], &p[6], &p[7]);
    sr_tr8_s16(p);
    const uint8x8_t bit = vcreate_u8(0x8040201008040201ULL);
    uint64_t um = 0;
    for (int k = 0; k < 8; k++) {
        int32x4_t pl = vmovl_s16(vget_low_s16(p[k]));
        int32x4_t ph = vmovl_s16(vget_high_s16(p[k]));
        int32x4_t ql = vqrdmulhq_s32(pl, vld1q_s32(recip32 + k * 8));
        int32x4_t qh = vqrdmulhq_s32(ph, vld1q_s32(recip32 + k * 8 + 4));
        int16x8_t q = vcombine_s16(vmovn_s32(ql), vmovn_s32(qh));
        vst1q_s16(out + k * 8, q);
        uint16x8_t nz = vtstq_s16(q, q);
        uint8x8_t nb = vand_u8(vmovn_u16(nz), bit);
        um |= (uint64_t)vaddv_u8(nb) << (8 * k);
    }
    if ((um & ~1ULL) == 0) return 0;
    uint64_t m = 0;
    for (int k = 0; k < 8; k++) m |= zzmask[k * 256 + ((um >> (8 * k)) & 0xFF)];
    return m;
}

// MARK: - Float AAN FDCT + Quantization (legacy ABI compatibility)

#define SR_AAN(d0, d1, d2, d3, d4, d5, d6, d7, o0, o1, o2, o3, o4, o5, o6, o7)            \
    do {                                                                                   \
        float32x4_t t0 = vaddq_f32(d0, d7), t7 = vsubq_f32(d0, d7);                       \
        float32x4_t t1 = vaddq_f32(d1, d6), t6 = vsubq_f32(d1, d6);                       \
        float32x4_t t2 = vaddq_f32(d2, d5), t5 = vsubq_f32(d2, d5);                       \
        float32x4_t t3 = vaddq_f32(d3, d4), t4 = vsubq_f32(d3, d4);                       \
        float32x4_t t10 = vaddq_f32(t0, t3), t13 = vsubq_f32(t0, t3);                     \
        float32x4_t t11 = vaddq_f32(t1, t2), t12 = vsubq_f32(t1, t2);                     \
        o0 = vaddq_f32(t10, t11); o4 = vsubq_f32(t10, t11);                               \
        float32x4_t z1 = vmulq_n_f32(vaddq_f32(t12, t13), 0.707106781f);                  \
        o2 = vaddq_f32(t13, z1); o6 = vsubq_f32(t13, z1);                                 \
        float32x4_t u10 = vaddq_f32(t4, t5), u11 = vaddq_f32(t5, t6), u12 = vaddq_f32(t6, t7); \
        float32x4_t z5 = vmulq_n_f32(vsubq_f32(u10, u12), 0.382683433f);                  \
        float32x4_t z2 = vfmaq_n_f32(z5, u10, 0.541196100f);                              \
        float32x4_t z4 = vfmaq_n_f32(z5, u12, 1.306562965f);                              \
        float32x4_t z3 = vmulq_n_f32(u11, 0.707106781f);                                  \
        float32x4_t z11 = vaddq_f32(t7, z3), z13 = vsubq_f32(t7, z3);                     \
        o5 = vaddq_f32(z13, z2); o3 = vsubq_f32(z13, z2);                                 \
        o1 = vaddq_f32(z11, z4); o7 = vsubq_f32(z11, z4);                                 \
    } while (0)

static inline void sr_tr4(float32x4_t a, float32x4_t b, float32x4_t c, float32x4_t d,
                          float32x4_t *r0, float32x4_t *r1, float32x4_t *r2, float32x4_t *r3) {
    float32x4x2_t ab = vtrnq_f32(a, b), cd = vtrnq_f32(c, d);
    *r0 = vcombine_f32(vget_low_f32(ab.val[0]), vget_low_f32(cd.val[0]));
    *r1 = vcombine_f32(vget_low_f32(ab.val[1]), vget_low_f32(cd.val[1]));
    *r2 = vcombine_f32(vget_high_f32(ab.val[0]), vget_high_f32(cd.val[0]));
    *r3 = vcombine_f32(vget_high_f32(ab.val[1]), vget_high_f32(cd.val[1]));
}

static inline void sr_tr8(float32x4_t lo[8], float32x4_t hi[8]) {
    float32x4_t a[4], b[4], c[4], d[4];
    sr_tr4(lo[0], lo[1], lo[2], lo[3], &a[0], &a[1], &a[2], &a[3]);
    sr_tr4(hi[0], hi[1], hi[2], hi[3], &b[0], &b[1], &b[2], &b[3]);
    sr_tr4(lo[4], lo[5], lo[6], lo[7], &c[0], &c[1], &c[2], &c[3]);
    sr_tr4(hi[4], hi[5], hi[6], hi[7], &d[0], &d[1], &d[2], &d[3]);
    for (int i = 0; i < 4; i++) { lo[i] = a[i]; hi[i] = c[i]; lo[4 + i] = b[i]; hi[4 + i] = d[i]; }
}

static inline uint64_t sr_jpeg_block_inl(const uint8_t *src, intptr_t stride, int par,
                                           const float *recip, int32_t *out, const uint64_t *zzmask) {
    uint8x8_t px[8];
    for (int k = 0; k < 8; k++) px[k] = sr_load_block_row(src + (intptr_t)k * stride, par);
    uint8x8_t f = vdup_lane_u8(px[0], 0);
    uint8x8_t diff = veor_u8(px[0], f);
    for (int k = 1; k < 8; k++) diff = vorr_u8(diff, veor_u8(px[k], f));
    if (vget_lane_u64(vreinterpret_u64_u8(diff), 0) == 0) {
        float dc = (float)(64 * ((int)vget_lane_u8(px[0], 0) - 128)) * recip[0];
        out[0] = vgetq_lane_s32(vcvtnq_s32_f32(vdupq_n_f32(dc)), 0);
        return 0;
    }
    float32x4_t lo[8], hi[8];
    const float32x4_t c128 = vdupq_n_f32(128.0f);
    for (int k = 0; k < 8; k++) {
        uint16x8_t w = vmovl_u8(px[k]);
        lo[k] = vsubq_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(w))), c128);
        hi[k] = vsubq_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(w))), c128);
    }
    float32x4_t a[8], b[8];
    SR_AAN(lo[0], lo[1], lo[2], lo[3], lo[4], lo[5], lo[6], lo[7], a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7]);
    SR_AAN(hi[0], hi[1], hi[2], hi[3], hi[4], hi[5], hi[6], hi[7], b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]);
    sr_tr8(a, b);
    float32x4_t p[8], q[8];
    SR_AAN(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    SR_AAN(b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7]);
    sr_tr8(p, q);
    const uint8x8_t bit = vcreate_u8(0x8040201008040201ULL);
    uint64_t um = 0;
    for (int k = 0; k < 8; k++) {
        int32x4_t ql = vcvtnq_s32_f32(vmulq_f32(p[k], vld1q_f32(recip + k * 8)));
        int32x4_t qh = vcvtnq_s32_f32(vmulq_f32(q[k], vld1q_f32(recip + k * 8 + 4)));
        vst1q_s32(out + k * 8, ql);
        vst1q_s32(out + k * 8 + 4, qh);
        uint16x8_t nz = vcombine_u16(vmovn_u32(vtstq_s32(ql, ql)), vmovn_u32(vtstq_s32(qh, qh)));
        uint8x8_t nb = vand_u8(vmovn_u16(nz), bit);
        um |= (uint64_t)vaddv_u8(nb) << (8 * k);
    }
    uint64_t m = 0;
    for (int k = 0; k < 8; k++) m |= zzmask[k * 256 + ((um >> (8 * k)) & 0xFF)];
    return m;
}

// MARK: - Huffman bit-packing

static inline __attribute__((always_inline)) void sr_huff_put(SRJState *s, uint32_t value, int len) {
    s->acc = (s->acc << len) | value;
    s->n += len;
    intptr_t f = s->n >= 32;
    uint32_t word = (uint32_t)(s->acc >> (f ? s->n - 32 : 0));
    uint32_t be = __builtin_bswap32(word);
    memcpy(s->out + s->pos, &be, 4);
    if (__builtin_expect(f && ((~word - 0x01010101u) & word & 0x80808080u) != 0, 0)) {
        intptr_t p = s->pos;
        for (int sh = 24; sh >= 0; sh -= 8) {
            uint8_t b = (uint8_t)(word >> sh);
            s->out[p++] = b;
            if (b == 0xFF) s->out[p++] = 0;
        }
        s->pos = p;
    } else {
        s->pos += 4 * f;
    }
    s->n -= 32 * f;
}

static inline __attribute__((always_inline)) void sr_huff_finish_inl(SRJState *s) {
    if (s->n % 8) {
        int pad = 8 - (int)(s->n % 8);
        s->acc = (s->acc << pad) | ((1u << pad) - 1);
        s->n += pad;
    }
    while (s->n >= 8) {
        uint8_t b = (uint8_t)(s->acc >> (s->n - 8));
        s->n -= 8;
        s->out[s->pos++] = b;
        if (b == 0xFF) s->out[s->pos++] = 0;
    }
    s->acc = 0;
    s->n = 0;
}

static inline __attribute__((always_inline)) void sr_huff_block_s16_inl(
    SRJState *s, const int16_t *coef, uint64_t mask, intptr_t *pred,
    const uint32_t *dcT, const uint32_t *acT, const intptr_t *zz)
{
    intptr_t dc = coef[0], diff = dc - *pred;
    *pred = dc;
    uint32_t mag = diff < 0 ? (uint32_t)(-(int64_t)diff) : (uint32_t)diff;
    int nb = mag ? 32 - __builtin_clz(mag) : 0;
    if (nb > 11) nb = 11;
    uint32_t extra = (diff < 0 ? (uint32_t)diff - 1u : (uint32_t)diff) & ((1u << nb) - 1u);
    uint32_t e = dcT[nb];
    sr_huff_put(s, ((e >> 8) << nb) | extra, (int)(e & 0xFF) + nb);
    mask &= ~1ULL;
    if (!mask) {
        uint32_t z = acT[0];
        sr_huff_put(s, z >> 8, (int)(z & 0xFF));
        return;
    }
    int last = 0;
    do {
        int i = __builtin_ctzll(mask);
        mask &= mask - 1;
        int run = i - last - 1;
        while (__builtin_expect(run > 15, 0)) {
            uint32_t z = acT[0xF0];
            sr_huff_put(s, z >> 8, (int)(z & 0xFF));
            run -= 16;
        }
        int32_t v = coef[zz[i]];
        uint32_t av = v < 0 ? (uint32_t)(-v) : (uint32_t)v;
        int sz = av ? 32 - __builtin_clz(av) : 1;
        if (sz > 10) sz = 10;
        uint32_t ex = (v < 0 ? (uint32_t)v - 1u : (uint32_t)v) & ((1u << sz) - 1u);
        uint32_t ae = acT[(run << 4) | sz];
        sr_huff_put(s, ((ae >> 8) << sz) | ex, (int)(ae & 0xFF) + sz);
        last = i;
    } while (mask);
    if (last < 63) {
        uint32_t z = acT[0];
        sr_huff_put(s, z >> 8, (int)(z & 0xFF));
    }
}

static inline __attribute__((always_inline)) void sr_huff_block_inl(
    SRJState *s, const int32_t *coef, uint64_t mask, intptr_t *pred,
    const uint32_t *dcT, const uint32_t *acT, const intptr_t *zz)
{
    intptr_t dc = coef[0], diff = dc - *pred;
    *pred = dc;
    uint32_t mag = diff < 0 ? (uint32_t)(-(int64_t)diff) : (uint32_t)diff;
    int nb = mag ? 32 - __builtin_clz(mag) : 0;
    if (nb > 11) nb = 11;
    uint32_t extra = (diff < 0 ? (uint32_t)diff - 1u : (uint32_t)diff) & ((1u << nb) - 1u);
    uint32_t e = dcT[nb];
    sr_huff_put(s, ((e >> 8) << nb) | extra, (int)(e & 0xFF) + nb);
    mask &= ~1ULL;
    int last = 0;
    while (mask) {
        int i = __builtin_ctzll(mask);
        mask &= mask - 1;
        int run = i - last - 1;
        while (run > 15) {
            uint32_t z = acT[0xF0];
            sr_huff_put(s, z >> 8, (int)(z & 0xFF));
            run -= 16;
        }
        int32_t v = coef[zz[i]];
        uint32_t av = v < 0 ? (uint32_t)(-(int64_t)v) : (uint32_t)v;
        int sz = av ? 32 - __builtin_clz(av) : 1;
        if (sz > 10) sz = 10;
        uint32_t ex = (v < 0 ? (uint32_t)v - 1u : (uint32_t)v) & ((1u << sz) - 1u);
        uint32_t ae = acT[(run << 4) | sz];
        sr_huff_put(s, ((ae >> 8) << sz) | ex, (int)(ae & 0xFF) + sz);
        last = i;
    }
    if (last < 63) {
        uint32_t z = acT[0];
        sr_huff_put(s, z >> 8, (int)(z & 0xFF));
    }
}

#endif
