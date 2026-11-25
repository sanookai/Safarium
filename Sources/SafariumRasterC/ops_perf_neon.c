// SafariumRasterC — Phase 4 NEON acceleration kernels:
//   - Workstream 1: pixel/color conversions (bgr2gray, swap/alpha, gray2bgr, hsv, lab), reduce_u8, Laplacian
//   - Workstream 2: streaming rolling-row morphology (erode / dilate u8 & f32)
//   - Workstream 3b: resize (nearest, 2x2 area, separable taps) and warp (affine, perspective, remap)

#include "sr_ops_perf.h"
#include <arm_neon.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// ------------------------------------------------------------------ shared helpers

static inline uint8_t sr_sat_u8_f32(float v) {
    float t = v + 0.5f;
    if (!(t > 0.0f)) return 0;
    if (t >= 255.0f) return 255;
    return (uint8_t)t;
}

static inline uint8_t sr_sat_u8_d_round(double v) {
    if (!(v == v)) return 0;
    long r = llround(v);
    return (uint8_t)(r < 0 ? 0 : (r > 255 ? 255 : r));
}

static inline uint16_t sr_sat_u16_f32(float v) {
    float t = v + 0.5f;
    if (!(t > 0.0f)) return 0;
    if (t >= 65535.0f) return 65535;
    return (uint16_t)t;
}

static inline uint8_t sr_sat_u8_f32_even(double v) {
    if (!(v == v)) return 0;
    long r = lrint(v);
    return (uint8_t)(r < 0 ? 0 : (r > 255 ? 255 : r));
}

static inline uint16_t sr_sat_u16_f32_even(double v) {
    if (!(v == v)) return 0;
    long r = lrint(v);
    return (uint16_t)(r < 0 ? 0 : (r > 65535 ? 65535 : r));
}

static inline int32_t sr_border_interp(int32_t p, int32_t len, int32_t border) {
    if ((uint32_t)p < (uint32_t)len) return p;
    int32_t b = border & 7;
    if (len <= 1) {
        return (b == SR_PERF_BORDER_CONSTANT || b == 5) ? -1 : 0;
    }
    switch (b) {
    case SR_PERF_BORDER_REPLICATE:
        return p < 0 ? 0 : len - 1;
    case SR_PERF_BORDER_REFLECT: {
        int32_t period = 2 * len;
        int32_t q = p % period;
        if (q < 0) q += period;
        return q < len ? q : period - 1 - q;
    }
    case SR_PERF_BORDER_REFLECT_101: {
        int32_t period = 2 * (len - 1);
        int32_t q = p % period;
        if (q < 0) q += period;
        return q < len ? q : period - q;
    }
    case SR_PERF_BORDER_WRAP: {
        int32_t q = p % len;
        if (q < 0) q += len;
        return q;
    }
    default:
        return -1;
    }
}

static inline uint32_t sr_read_u32_unaligned(const void *p) {
    uint32_t v;
    memcpy(&v, p, sizeof(v));
    return v;
}

static inline void sr_write_u32_unaligned(void *p, uint32_t v) {
    memcpy(p, &v, sizeof(v));
}

static inline int32_t sr_next_pow2(int32_t n) {
    int32_t p = 1;
    while (p < n && p < (1 << 29)) p *= 2;
    return p;
}

// ------------------------------------------------------------------ Workstream 1: Color / Swap / Gray / HSV / Lab

void sr_c_bgr2gray_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t scn, int32_t blue_idx) {
    if (!src || !dst || w <= 0 || h <= 0 || (scn != 3 && scn != 4)) return;
    if (sstep == (ptrdiff_t)w * scn && dstep == (ptrdiff_t)w && (int64_t)w * h <= (int64_t)INT32_MAX / 4) {
        w *= h; h = 1;
    }
    const int bo = blue_idx ? 2 : 0;
    const int ro = 2 - bo;
    const uint16x4_t cB = vdup_n_u16(7470);
    const uint16x4_t cG = vdup_n_u16(38470);
    const uint16x4_t cR = vdup_n_u16(19596);
    #define B2G_U8_BODY(VB, VG, VR, DOFF) do { \
        uint16x8_t b_lo = vmovl_u8(vget_low_u8(VB)), b_hi = vmovl_u8(vget_high_u8(VB)); \
        uint16x8_t g_lo = vmovl_u8(vget_low_u8(VG)), g_hi = vmovl_u8(vget_high_u8(VG)); \
        uint16x8_t r_lo = vmovl_u8(vget_low_u8(VR)), r_hi = vmovl_u8(vget_high_u8(VR)); \
        uint32x4_t a0 = vmlal_u16(vmlal_u16(vmull_u16(vget_low_u16(b_lo), cB), vget_low_u16(g_lo), cG), vget_low_u16(r_lo), cR); \
        uint32x4_t a1 = vmlal_u16(vmlal_u16(vmull_u16(vget_high_u16(b_lo), cB), vget_high_u16(g_lo), cG), vget_high_u16(r_lo), cR); \
        uint32x4_t a2 = vmlal_u16(vmlal_u16(vmull_u16(vget_low_u16(b_hi), cB), vget_low_u16(g_hi), cG), vget_low_u16(r_hi), cR); \
        uint32x4_t a3 = vmlal_u16(vmlal_u16(vmull_u16(vget_high_u16(b_hi), cB), vget_high_u16(g_hi), cG), vget_high_u16(r_hi), cR); \
        uint16x8_t q0 = vcombine_u16(vrshrn_n_u32(a0, 16), vrshrn_n_u32(a1, 16)); \
        uint16x8_t q1 = vcombine_u16(vrshrn_n_u32(a2, 16), vrshrn_n_u32(a3, 16)); \
        vst1q_u8((DOFF), vcombine_u8(vmovn_u16(q0), vmovn_u16(q1))); \
    } while (0)

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (ptrdiff_t)y * sstep;
        uint8_t *d = dst + (ptrdiff_t)y * dstep;
        int32_t x = 0;
        if (scn == 3 && !blue_idx) {
            for (; x + 32 <= w; x += 32) {
                uint8x16x3_t p0 = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x3_t p1 = vld3q_u8(s + (ptrdiff_t)(x + 16) * 3);
                B2G_U8_BODY(p0.val[0], p0.val[1], p0.val[2], d + x);
                B2G_U8_BODY(p1.val[0], p1.val[1], p1.val[2], d + x + 16);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x3_t p = vld3q_u8(s + (ptrdiff_t)x * 3);
                B2G_U8_BODY(p.val[0], p.val[1], p.val[2], d + x);
            }
        } else if (scn == 3) {
            for (; x + 32 <= w; x += 32) {
                uint8x16x3_t p0 = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x3_t p1 = vld3q_u8(s + (ptrdiff_t)(x + 16) * 3);
                B2G_U8_BODY(p0.val[2], p0.val[1], p0.val[0], d + x);
                B2G_U8_BODY(p1.val[2], p1.val[1], p1.val[0], d + x + 16);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x3_t p = vld3q_u8(s + (ptrdiff_t)x * 3);
                B2G_U8_BODY(p.val[2], p.val[1], p.val[0], d + x);
            }
        } else if (!blue_idx) {
            for (; x + 16 <= w; x += 16) {
                uint8x16x4_t p = vld4q_u8(s + (ptrdiff_t)x * 4);
                B2G_U8_BODY(p.val[0], p.val[1], p.val[2], d + x);
            }
        } else {
            for (; x + 16 <= w; x += 16) {
                uint8x16x4_t p = vld4q_u8(s + (ptrdiff_t)x * 4);
                B2G_U8_BODY(p.val[2], p.val[1], p.val[0], d + x);
            }
        }
        for (; x < w; x++) {
            const uint8_t *p = s + (ptrdiff_t)x * scn;
            uint32_t acc = (uint32_t)p[bo] * 7470u + (uint32_t)p[1] * 38470u + (uint32_t)p[ro] * 19596u + 32768u;
            d[x] = (uint8_t)(acc >> 16);
        }
    }
    #undef B2G_U8_BODY
}

void sr_c_bgr2gray_u16(const uint16_t *src, ptrdiff_t sstep_bytes, uint16_t *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t blue_idx) {
    if (!src || !dst || w <= 0 || h <= 0 || (scn != 3 && scn != 4)) return;
    if (sstep_bytes == (ptrdiff_t)w * scn * 2 && dstep_bytes == (ptrdiff_t)w * 2 && (int64_t)w * h <= (int64_t)INT32_MAX / 4) {
        w *= h; h = 1;
    }
    const int bo = blue_idx ? 2 : 0;
    const int ro = 2 - bo;
    const uint16x4_t cB = vdup_n_u16(7470);
    const uint16x4_t cG = vdup_n_u16(38470);
    const uint16x4_t cR = vdup_n_u16(19596);
    #define B2G_U16_BODY(VB, VG, VR, DOFF) do { \
        uint32x4_t a0 = vmlal_u16(vmlal_u16(vmull_u16(vget_low_u16(VB), cB), vget_low_u16(VG), cG), vget_low_u16(VR), cR); \
        uint32x4_t a1 = vmlal_u16(vmlal_u16(vmull_u16(vget_high_u16(VB), cB), vget_high_u16(VG), cG), vget_high_u16(VR), cR); \
        vst1q_u16((DOFF), vcombine_u16(vrshrn_n_u32(a0, 16), vrshrn_n_u32(a1, 16))); \
    } while (0)

    for (int32_t y = 0; y < h; y++) {
        const uint16_t *s = (const uint16_t *)((const uint8_t *)src + (ptrdiff_t)y * sstep_bytes);
        uint16_t *d = (uint16_t *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
        int32_t x = 0;
        if (scn == 3 && !blue_idx) {
            for (; x + 8 <= w; x += 8) {
                uint16x8x3_t p = vld3q_u16(s + (ptrdiff_t)x * 3);
                B2G_U16_BODY(p.val[0], p.val[1], p.val[2], d + x);
            }
        } else if (scn == 3) {
            for (; x + 8 <= w; x += 8) {
                uint16x8x3_t p = vld3q_u16(s + (ptrdiff_t)x * 3);
                B2G_U16_BODY(p.val[2], p.val[1], p.val[0], d + x);
            }
        } else if (!blue_idx) {
            for (; x + 8 <= w; x += 8) {
                uint16x8x4_t p = vld4q_u16(s + (ptrdiff_t)x * 4);
                B2G_U16_BODY(p.val[0], p.val[1], p.val[2], d + x);
            }
        } else {
            for (; x + 8 <= w; x += 8) {
                uint16x8x4_t p = vld4q_u16(s + (ptrdiff_t)x * 4);
                B2G_U16_BODY(p.val[2], p.val[1], p.val[0], d + x);
            }
        }
        for (; x < w; x++) {
            const uint16_t *p = s + (ptrdiff_t)x * scn;
            uint64_t acc = (uint64_t)p[bo] * 7470ull + (uint64_t)p[1] * 38470ull + (uint64_t)p[ro] * 19596ull + 32768ull;
            d[x] = (uint16_t)(acc >> 16);
        }
    }
    #undef B2G_U16_BODY
}

void sr_c_bgr2gray_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t blue_idx) {
    if (!src || !dst || w <= 0 || h <= 0 || (scn != 3 && scn != 4)) return;
    if (sstep_bytes == (ptrdiff_t)w * scn * 4 && dstep_bytes == (ptrdiff_t)w * 4 && (int64_t)w * h <= (int64_t)INT32_MAX / 4) {
        w *= h; h = 1;
    }
    const int bo = blue_idx ? 2 : 0;
    const int ro = 2 - bo;
    const float32x4_t cB = vdupq_n_f32(0.114f);
    const float32x4_t cG = vdupq_n_f32(0.587f);
    const float32x4_t cR = vdupq_n_f32(0.299f);
    for (int32_t y = 0; y < h; y++) {
        const float *s = (const float *)((const uint8_t *)src + (ptrdiff_t)y * sstep_bytes);
        float *d = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
        int32_t x = 0;
        if (scn == 3 && !blue_idx) {
            for (; x + 8 <= w; x += 8) {
                float32x4x3_t p0 = vld3q_f32(s + (ptrdiff_t)x * 3);
                float32x4x3_t p1 = vld3q_f32(s + (ptrdiff_t)(x + 4) * 3);
                vst1q_f32(d + x,     vaddq_f32(vaddq_f32(vmulq_f32(p0.val[0], cB), vmulq_f32(p0.val[1], cG)), vmulq_f32(p0.val[2], cR)));
                vst1q_f32(d + x + 4, vaddq_f32(vaddq_f32(vmulq_f32(p1.val[0], cB), vmulq_f32(p1.val[1], cG)), vmulq_f32(p1.val[2], cR)));
            }
            for (; x + 4 <= w; x += 4) {
                float32x4x3_t p = vld3q_f32(s + (ptrdiff_t)x * 3);
                vst1q_f32(d + x, vaddq_f32(vaddq_f32(vmulq_f32(p.val[0], cB), vmulq_f32(p.val[1], cG)), vmulq_f32(p.val[2], cR)));
            }
        } else if (scn == 3) {
            for (; x + 8 <= w; x += 8) {
                float32x4x3_t p0 = vld3q_f32(s + (ptrdiff_t)x * 3);
                float32x4x3_t p1 = vld3q_f32(s + (ptrdiff_t)(x + 4) * 3);
                vst1q_f32(d + x,     vaddq_f32(vaddq_f32(vmulq_f32(p0.val[2], cB), vmulq_f32(p0.val[1], cG)), vmulq_f32(p0.val[0], cR)));
                vst1q_f32(d + x + 4, vaddq_f32(vaddq_f32(vmulq_f32(p1.val[2], cB), vmulq_f32(p1.val[1], cG)), vmulq_f32(p1.val[0], cR)));
            }
            for (; x + 4 <= w; x += 4) {
                float32x4x3_t p = vld3q_f32(s + (ptrdiff_t)x * 3);
                vst1q_f32(d + x, vaddq_f32(vaddq_f32(vmulq_f32(p.val[2], cB), vmulq_f32(p.val[1], cG)), vmulq_f32(p.val[0], cR)));
            }
        } else if (!blue_idx) {
            for (; x + 4 <= w; x += 4) {
                float32x4x4_t p = vld4q_f32(s + (ptrdiff_t)x * 4);
                vst1q_f32(d + x, vaddq_f32(vaddq_f32(vmulq_f32(p.val[0], cB), vmulq_f32(p.val[1], cG)), vmulq_f32(p.val[2], cR)));
            }
        } else {
            for (; x + 4 <= w; x += 4) {
                float32x4x4_t p = vld4q_f32(s + (ptrdiff_t)x * 4);
                vst1q_f32(d + x, vaddq_f32(vaddq_f32(vmulq_f32(p.val[2], cB), vmulq_f32(p.val[1], cG)), vmulq_f32(p.val[0], cR)));
            }
        }
        for (; x < w; x++) {
            const float *p = s + (ptrdiff_t)x * scn;
            d[x] = p[bo] * 0.114f + p[1] * 0.587f + p[ro] * 0.299f;
        }
    }
}

void sr_c_cvt_swap_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t swap_rb) {
    if (!src || !dst || w <= 0 || h <= 0 || (scn != 3 && scn != 4) || (dcn != 3 && dcn != 4)) return;
    if (sstep == (ptrdiff_t)w * scn && dstep == (ptrdiff_t)w * dcn && (int64_t)w * h <= (int64_t)INT32_MAX / 4) {
        w *= h; h = 1;
    }
    const int i0 = swap_rb ? 2 : 0;
    const int i2 = 2 - i0;
    const uint8x16_t a255 = vdupq_n_u8(255);
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (ptrdiff_t)y * sstep;
        uint8_t *d = dst + (ptrdiff_t)y * dstep;
        if (scn == dcn && !swap_rb) {
            if (s != d) memcpy(d, s, (size_t)w * (size_t)scn);
            continue;
        }
        int32_t x = 0;
        if (scn == 3 && dcn == 3) { // swap_rb == 1
            for (; x + 32 <= w; x += 32) {
                uint8x16x3_t p0 = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x3_t p1 = vld3q_u8(s + (ptrdiff_t)(x + 16) * 3);
                uint8x16x3_t q0 = {{p0.val[2], p0.val[1], p0.val[0]}};
                uint8x16x3_t q1 = {{p1.val[2], p1.val[1], p1.val[0]}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q0);
                vst3q_u8(d + (ptrdiff_t)(x + 16) * 3, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x3_t p = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x3_t q = {{p.val[2], p.val[1], p.val[0]}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q);
            }
        } else if (scn == 4 && dcn == 3 && !swap_rb) {
            for (; x + 32 <= w; x += 32) {
                uint8x16x4_t p0 = vld4q_u8(s + (ptrdiff_t)x * 4);
                uint8x16x4_t p1 = vld4q_u8(s + (ptrdiff_t)(x + 16) * 4);
                uint8x16x3_t q0 = {{p0.val[0], p0.val[1], p0.val[2]}};
                uint8x16x3_t q1 = {{p1.val[0], p1.val[1], p1.val[2]}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q0);
                vst3q_u8(d + (ptrdiff_t)(x + 16) * 3, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x4_t p = vld4q_u8(s + (ptrdiff_t)x * 4);
                uint8x16x3_t q = {{p.val[0], p.val[1], p.val[2]}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q);
            }
        } else if (scn == 4 && dcn == 3) {
            for (; x + 32 <= w; x += 32) {
                uint8x16x4_t p0 = vld4q_u8(s + (ptrdiff_t)x * 4);
                uint8x16x4_t p1 = vld4q_u8(s + (ptrdiff_t)(x + 16) * 4);
                uint8x16x3_t q0 = {{p0.val[2], p0.val[1], p0.val[0]}};
                uint8x16x3_t q1 = {{p1.val[2], p1.val[1], p1.val[0]}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q0);
                vst3q_u8(d + (ptrdiff_t)(x + 16) * 3, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x4_t p = vld4q_u8(s + (ptrdiff_t)x * 4);
                uint8x16x3_t q = {{p.val[2], p.val[1], p.val[0]}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q);
            }
        } else if (scn == 3 && dcn == 4 && !swap_rb) {
            for (; x + 32 <= w; x += 32) {
                uint8x16x3_t p0 = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x3_t p1 = vld3q_u8(s + (ptrdiff_t)(x + 16) * 3);
                uint8x16x4_t q0 = {{p0.val[0], p0.val[1], p0.val[2], a255}};
                uint8x16x4_t q1 = {{p1.val[0], p1.val[1], p1.val[2], a255}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q0);
                vst4q_u8(d + (ptrdiff_t)(x + 16) * 4, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x3_t p = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x4_t q = {{p.val[0], p.val[1], p.val[2], a255}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q);
            }
        } else if (scn == 3 && dcn == 4) {
            for (; x + 32 <= w; x += 32) {
                uint8x16x3_t p0 = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x3_t p1 = vld3q_u8(s + (ptrdiff_t)(x + 16) * 3);
                uint8x16x4_t q0 = {{p0.val[2], p0.val[1], p0.val[0], a255}};
                uint8x16x4_t q1 = {{p1.val[2], p1.val[1], p1.val[0], a255}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q0);
                vst4q_u8(d + (ptrdiff_t)(x + 16) * 4, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x3_t p = vld3q_u8(s + (ptrdiff_t)x * 3);
                uint8x16x4_t q = {{p.val[2], p.val[1], p.val[0], a255}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q);
            }
        } else { // scn == 4 && dcn == 4 && swap_rb == 1
            for (; x + 32 <= w; x += 32) {
                uint8x16x4_t p0 = vld4q_u8(s + (ptrdiff_t)x * 4);
                uint8x16x4_t p1 = vld4q_u8(s + (ptrdiff_t)(x + 16) * 4);
                uint8x16x4_t q0 = {{p0.val[2], p0.val[1], p0.val[0], p0.val[3]}};
                uint8x16x4_t q1 = {{p1.val[2], p1.val[1], p1.val[0], p1.val[3]}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q0);
                vst4q_u8(d + (ptrdiff_t)(x + 16) * 4, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16x4_t p = vld4q_u8(s + (ptrdiff_t)x * 4);
                uint8x16x4_t q = {{p.val[2], p.val[1], p.val[0], p.val[3]}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q);
            }
        }
        for (; x < w; x++) {
            const uint8_t *sp = s + (ptrdiff_t)x * scn;
            uint8_t *dp = d + (ptrdiff_t)x * dcn;
            uint8_t v0 = sp[i0], v1 = sp[1], v2 = sp[i2];
            uint8_t v3 = scn == 4 ? sp[3] : 255;
            dp[0] = v0; dp[1] = v1; dp[2] = v2;
            if (dcn == 4) dp[3] = v3;
        }
    }
}

void sr_c_cvt_swap_u16(const uint16_t *src, ptrdiff_t sstep_bytes, uint16_t *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t swap_rb) {
    if (!src || !dst || w <= 0 || h <= 0 || (scn != 3 && scn != 4) || (dcn != 3 && dcn != 4)) return;
    const int i0 = swap_rb ? 2 : 0;
    const int i2 = 2 - i0;
    const uint16x8_t amax = vdupq_n_u16(65535);
    for (int32_t y = 0; y < h; y++) {
        const uint16_t *s = (const uint16_t *)((const uint8_t *)src + (ptrdiff_t)y * sstep_bytes);
        uint16_t *d = (uint16_t *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
        if (scn == dcn && !swap_rb) {
            if (s != d) memcpy(d, s, (size_t)w * (size_t)scn * 2);
            continue;
        }
        int32_t x = 0;
        for (; x + 8 <= w; x += 8) {
            uint16x8_t c0, c1, c2, c3 = amax;
            if (scn == 3) {
                uint16x8x3_t p = vld3q_u16(s + (ptrdiff_t)x * 3);
                c0 = p.val[i0]; c1 = p.val[1]; c2 = p.val[i2];
            } else {
                uint16x8x4_t p = vld4q_u16(s + (ptrdiff_t)x * 4);
                c0 = p.val[i0]; c1 = p.val[1]; c2 = p.val[i2]; c3 = p.val[3];
            }
            if (dcn == 3) {
                uint16x8x3_t q = {{c0, c1, c2}};
                vst3q_u16(d + (ptrdiff_t)x * 3, q);
            } else {
                uint16x8x4_t q = {{c0, c1, c2, c3}};
                vst4q_u16(d + (ptrdiff_t)x * 4, q);
            }
        }
        for (; x < w; x++) {
            const uint16_t *sp = s + (ptrdiff_t)x * scn;
            uint16_t *dp = d + (ptrdiff_t)x * dcn;
            uint16_t v0 = sp[i0], v1 = sp[1], v2 = sp[i2];
            uint16_t v3 = scn == 4 ? sp[3] : 65535;
            dp[0] = v0; dp[1] = v1; dp[2] = v2;
            if (dcn == 4) dp[3] = v3;
        }
    }
}

void sr_c_cvt_swap_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t swap_rb) {
    if (!src || !dst || w <= 0 || h <= 0 || (scn != 3 && scn != 4) || (dcn != 3 && dcn != 4)) return;
    const int i0 = swap_rb ? 2 : 0;
    const int i2 = 2 - i0;
    const float32x4_t aone = vdupq_n_f32(1.0f);
    for (int32_t y = 0; y < h; y++) {
        const float *s = (const float *)((const uint8_t *)src + (ptrdiff_t)y * sstep_bytes);
        float *d = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
        if (scn == dcn && !swap_rb) {
            if (s != d) memcpy(d, s, (size_t)w * (size_t)scn * 4);
            continue;
        }
        int32_t x = 0;
        for (; x + 4 <= w; x += 4) {
            float32x4_t c0, c1, c2, c3 = aone;
            if (scn == 3) {
                float32x4x3_t p = vld3q_f32(s + (ptrdiff_t)x * 3);
                c0 = p.val[i0]; c1 = p.val[1]; c2 = p.val[i2];
            } else {
                float32x4x4_t p = vld4q_f32(s + (ptrdiff_t)x * 4);
                c0 = p.val[i0]; c1 = p.val[1]; c2 = p.val[i2]; c3 = p.val[3];
            }
            if (dcn == 3) {
                float32x4x3_t q = {{c0, c1, c2}};
                vst3q_f32(d + (ptrdiff_t)x * 3, q);
            } else {
                float32x4x4_t q = {{c0, c1, c2, c3}};
                vst4q_f32(d + (ptrdiff_t)x * 4, q);
            }
        }
        for (; x < w; x++) {
            const float *sp = s + (ptrdiff_t)x * scn;
            float *dp = d + (ptrdiff_t)x * dcn;
            float v0 = sp[i0], v1 = sp[1], v2 = sp[i2];
            float v3 = scn == 4 ? sp[3] : 1.0f;
            dp[0] = v0; dp[1] = v1; dp[2] = v2;
            if (dcn == 4) dp[3] = v3;
        }
    }
}

void sr_c_gray2bgr_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t dcn) {
    if (!src || !dst || w <= 0 || h <= 0 || (dcn != 3 && dcn != 4)) return;
    if (sstep == (ptrdiff_t)w && dstep == (ptrdiff_t)w * dcn && (int64_t)w * h <= (int64_t)INT32_MAX / 4) {
        w *= h; h = 1;
    }
    const uint8x16_t a255 = vdupq_n_u8(255);
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (ptrdiff_t)y * sstep;
        uint8_t *d = dst + (ptrdiff_t)y * dstep;
        int32_t x = 0;
        if (dcn == 3) {
            for (; x + 32 <= w; x += 32) {
                uint8x16_t v0 = vld1q_u8(s + x);
                uint8x16_t v1 = vld1q_u8(s + x + 16);
                uint8x16x3_t q0 = {{v0, v0, v0}};
                uint8x16x3_t q1 = {{v1, v1, v1}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q0);
                vst3q_u8(d + (ptrdiff_t)(x + 16) * 3, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16_t v = vld1q_u8(s + x);
                uint8x16x3_t q = {{v, v, v}};
                vst3q_u8(d + (ptrdiff_t)x * 3, q);
            }
        } else {
            for (; x + 32 <= w; x += 32) {
                uint8x16_t v0 = vld1q_u8(s + x);
                uint8x16_t v1 = vld1q_u8(s + x + 16);
                uint8x16x4_t q0 = {{v0, v0, v0, a255}};
                uint8x16x4_t q1 = {{v1, v1, v1, a255}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q0);
                vst4q_u8(d + (ptrdiff_t)(x + 16) * 4, q1);
            }
            for (; x + 16 <= w; x += 16) {
                uint8x16_t v = vld1q_u8(s + x);
                uint8x16x4_t q = {{v, v, v, a255}};
                vst4q_u8(d + (ptrdiff_t)x * 4, q);
            }
        }
        for (; x < w; x++) {
            uint8_t v = s[x];
            uint8_t *dp = d + (ptrdiff_t)x * dcn;
            dp[0] = v; dp[1] = v; dp[2] = v;
            if (dcn == 4) dp[3] = 255;
        }
    }
}

void sr_c_gray2bgr_u16(const uint16_t *src, ptrdiff_t sstep_bytes, uint16_t *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t dcn) {
    if (!src || !dst || w <= 0 || h <= 0 || (dcn != 3 && dcn != 4)) return;
    const uint16x8_t amax = vdupq_n_u16(65535);
    for (int32_t y = 0; y < h; y++) {
        const uint16_t *s = (const uint16_t *)((const uint8_t *)src + (ptrdiff_t)y * sstep_bytes);
        uint16_t *d = (uint16_t *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
        int32_t x = 0;
        for (; x + 8 <= w; x += 8) {
            uint16x8_t v = vld1q_u16(s + x);
            if (dcn == 3) {
                uint16x8x3_t q = {{v, v, v}};
                vst3q_u16(d + (ptrdiff_t)x * 3, q);
            } else {
                uint16x8x4_t q = {{v, v, v, amax}};
                vst4q_u16(d + (ptrdiff_t)x * 4, q);
            }
        }
        for (; x < w; x++) {
            uint16_t v = s[x];
            uint16_t *dp = d + (ptrdiff_t)x * dcn;
            dp[0] = v; dp[1] = v; dp[2] = v;
            if (dcn == 4) dp[3] = 65535;
        }
    }
}

void sr_c_gray2bgr_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t dcn) {
    if (!src || !dst || w <= 0 || h <= 0 || (dcn != 3 && dcn != 4)) return;
    const float32x4_t aone = vdupq_n_f32(1.0f);
    for (int32_t y = 0; y < h; y++) {
        const float *s = (const float *)((const uint8_t *)src + (ptrdiff_t)y * sstep_bytes);
        float *d = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
        int32_t x = 0;
        for (; x + 4 <= w; x += 4) {
            float32x4_t v = vld1q_f32(s + x);
            if (dcn == 3) {
                float32x4x3_t q = {{v, v, v}};
                vst3q_f32(d + (ptrdiff_t)x * 3, q);
            } else {
                float32x4x4_t q = {{v, v, v, aone}};
                vst4q_f32(d + (ptrdiff_t)x * 4, q);
            }
        }
        for (; x < w; x++) {
            float v = s[x];
            float *dp = d + (ptrdiff_t)x * dcn;
            dp[0] = v; dp[1] = v; dp[2] = v;
            if (dcn == 4) dp[3] = 1.0f;
        }
    }
}

static inline void hsv_block8(uint8x8_t b, uint8x8_t g, uint8x8_t r, uint8_t *o,
                              const uint8_t *slut, const int32_t *hdiv180) {
    uint8x8_t v = vmax_u8(vmax_u8(b, g), r);
    uint8x8_t df = vsub_u8(v, vmin_u8(vmin_u8(b, g), r));
    int16x8_t b16 = vreinterpretq_s16_u16(vmovl_u8(b));
    int16x8_t g16 = vreinterpretq_s16_u16(vmovl_u8(g));
    int16x8_t r16 = vreinterpretq_s16_u16(vmovl_u8(r));
    int16x8_t d16 = vreinterpretq_s16_u16(vmovl_u8(df));
    int16x8_t hr = vsubq_s16(g16, b16);
    int16x8_t hg = vaddq_s16(vsubq_s16(b16, r16), vshlq_n_s16(d16, 1));
    int16x8_t hb = vaddq_s16(vsubq_s16(r16, g16), vshlq_n_s16(d16, 2));
    uint16x8_t mr = vtstq_u16(vmovl_u8(vceq_u8(v, r)), vdupq_n_u16(0xff));
    uint16x8_t mg = vtstq_u16(vmovl_u8(vceq_u8(v, g)), vdupq_n_u16(0xff));
    int16x8_t hn = vbslq_s16(mr, hr, vbslq_s16(mg, hg, hb));

    uint8_t va[8], da[8];
    int16_t ha[8];
    vst1_u8(va, v);
    vst1_u8(da, df);
    vst1q_s16(ha, hn);
    for (int i = 0; i < 8; i++) {
        int32_t dv = da[i];
        int32_t vv = va[i];
        int32_t h = (ha[i] * hdiv180[dv] + 2048) >> 12;
        h += (h >> 31) & 180;
        o[i * 3 + 0] = (uint8_t)h;
        o[i * 3 + 1] = slut[(vv << 8) | dv];
        o[i * 3 + 2] = (uint8_t)vv;
    }
}

void sr_c_bgr2hsv_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                     int32_t w, int32_t h, int32_t scn, int32_t blue_idx,
                     const uint8_t *s_lut, const uint8_t *s_tail, const int32_t *hdiv180) {
    if (!src || !dst || !s_lut || !s_tail || !hdiv180 || w <= 0 || h <= 0 || (scn != 3 && scn != 4)) return;
    const int bo = blue_idx ? 2 : 0;
    const int ro = 2 - bo;
    const int32_t tail_start = w & ~7;
    const int32_t simd16_end = w & ~15;

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (ptrdiff_t)y * sstep;
        uint8_t *d = dst + (ptrdiff_t)y * dstep;
        int32_t x = 0;
        for (; x < simd16_end; x += 16) {
            uint8x16_t b, g, r;
            if (scn == 3) {
                uint8x16x3_t p = vld3q_u8(s + (ptrdiff_t)x * 3);
                b = p.val[bo]; g = p.val[1]; r = p.val[ro];
            } else {
                uint8x16x4_t p = vld4q_u8(s + (ptrdiff_t)x * 4);
                b = p.val[bo]; g = p.val[1]; r = p.val[ro];
            }
            uint8x16_t v = vmaxq_u8(vmaxq_u8(b, g), r);
            uint8x16_t df = vsubq_u8(v, vminq_u8(vminq_u8(b, g), r));
            uint16x8_t v_lo = vmovl_u8(vget_low_u8(v)), v_hi = vmovl_u8(vget_high_u8(v));
            uint16x8_t d_lo = vmovl_u8(vget_low_u8(df)), d_hi = vmovl_u8(vget_high_u8(df));
            uint16x8_t idx0 = vorrq_u16(vshlq_n_u16(v_lo, 8), d_lo);
            uint16x8_t idx1 = vorrq_u16(vshlq_n_u16(v_hi, 8), d_hi);

            int16x8_t b0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(b)));
            int16x8_t g0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(g)));
            int16x8_t r0 = vreinterpretq_s16_u16(vmovl_u8(vget_low_u8(r)));
            int16x8_t dd0 = vreinterpretq_s16_u16(d_lo);
            int16x8_t hn0 = vbslq_s16(vceqq_s16(vreinterpretq_s16_u16(v_lo), r0), vsubq_s16(g0, b0),
                            vbslq_s16(vceqq_s16(vreinterpretq_s16_u16(v_lo), g0),
                                      vaddq_s16(vsubq_s16(b0, r0), vshlq_n_s16(dd0, 1)),
                                      vaddq_s16(vsubq_s16(r0, g0), vshlq_n_s16(dd0, 2))));

            int16x8_t b1 = vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(b)));
            int16x8_t g1 = vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(g)));
            int16x8_t r1 = vreinterpretq_s16_u16(vmovl_u8(vget_high_u8(r)));
            int16x8_t dd1 = vreinterpretq_s16_u16(d_hi);
            int16x8_t hn1 = vbslq_s16(vceqq_s16(vreinterpretq_s16_u16(v_hi), r1), vsubq_s16(g1, b1),
                            vbslq_s16(vceqq_s16(vreinterpretq_s16_u16(v_hi), g1),
                                      vaddq_s16(vsubq_s16(b1, r1), vshlq_n_s16(dd1, 1)),
                                      vaddq_s16(vsubq_s16(r1, g1), vshlq_n_s16(dd1, 2))));

            uint8_t da[16], va[16], ha_out[16], sa_out[16];
            uint16_t ix[16];
            int16_t ha[16];
            vst1q_u8(va, v);
            vst1q_u8(da, df);
            vst1q_u16(ix, idx0);
            vst1q_u16(ix + 8, idx1);
            vst1q_s16(ha, hn0);
            vst1q_s16(ha + 8, hn1);
            for (int i = 0; i < 16; i++) {
                int32_t hh = (ha[i] * hdiv180[da[i]] + 2048) >> 12;
                hh += (hh >> 31) & 180;
                ha_out[i] = (uint8_t)hh;
                sa_out[i] = s_lut[ix[i]];
            }
            uint8x16x3_t q = {{vld1q_u8(ha_out), vld1q_u8(sa_out), v}};
            vst3q_u8(d + (ptrdiff_t)x * 3, q);
        }
        if (x < tail_start) {
            uint8x8_t b, g, r;
            if (scn == 3) {
                uint8x8x3_t p = vld3_u8(s + (ptrdiff_t)x * 3);
                b = p.val[bo]; g = p.val[1]; r = p.val[ro];
            } else {
                uint8x8x4_t p = vld4_u8(s + (ptrdiff_t)x * 4);
                b = p.val[bo]; g = p.val[1]; r = p.val[ro];
            }
            hsv_block8(b, g, r, d + (ptrdiff_t)x * 3, s_lut, hdiv180);
            x += 8;
        }
        for (; x < w; x++) {
            const uint8_t *p = s + (ptrdiff_t)x * scn;
            int32_t b = p[bo], g = p[1], r = p[ro];
            int32_t vv = b > g ? b : g; if (r > vv) vv = r;
            int32_t mm = b < g ? b : g; if (r < mm) mm = r;
            int32_t dv = vv - mm;
            int32_t hn = vv == r ? g - b : (vv == g ? b - r + 2 * dv : r - g + 4 * dv);
            int32_t hh = (hn * hdiv180[dv] + 2048) >> 12;
            hh += (hh >> 31) & 180;
            uint8_t *o = d + (ptrdiff_t)x * 3;
            o[0] = (uint8_t)hh;
            o[1] = s_tail[(vv << 8) | dv];
            o[2] = (uint8_t)vv;
        }
    }
}

// Fast NEON 4-lane Lab cube-root + matrix for u8 -> u8 (sRGB LUT + 2 Halley steps)
static inline float32x4_t sr_neon_lab_f4(float32x4_t x) {
    // IEEE-754 seed for cbrt(x): 0x2a514d80 + bits / 3 via 0xAAAAAAAB multiply-high
    uint32x4_t bx = vreinterpretq_u32_f32(vmaxq_f32(x, vdupq_n_f32(1e-6f)));
    uint32x2_t magic = vdup_n_u32(0xAAAAAAABu);
    uint64x2_t p0 = vmull_u32(vget_low_u32(bx), magic);
    uint64x2_t p1 = vmull_u32(vget_high_u32(bx), magic);
    uint32x4_t q3 = vcombine_u32(vmovn_u64(vshrq_n_u64(p0, 33)), vmovn_u64(vshrq_n_u64(p1, 33)));
    float32x4_t y = vreinterpretq_f32_u32(vaddq_u32(vdupq_n_u32(0x2a514d80u), q3));
    const float32x4_t two = vdupq_n_f32(2.0f);
    for (int it = 0; it < 2; it++) {
        float32x4_t y3 = vmulq_f32(vmulq_f32(y, y), y);
        float32x4_t num = vfmaq_f32(y3, two, x);
        float32x4_t den = vfmaq_f32(x, two, y3);
        y = vdivq_f32(vmulq_f32(y, num), den);
    }
    uint32x4_t gt = vcgtq_f32(x, vdupq_n_f32(0.008856f));
    float32x4_t lin = vfmaq_f32(vdupq_n_f32(16.0f / 116.0f), vdupq_n_f32(7.787f), x);
    return vbslq_f32(gt, y, lin);
}

int32_t sr_c_bgr2lab_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                        int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t is_bgr, int32_t linear_in) {
    if (!src || !dst || w <= 0 || h <= 0 || (scn != 3 && scn != 4) || (dcn != 3 && dcn != 4)) return -1;
    float lut[256];
    for (int i = 0; i < 256; i++) {
        float v = (float)i * (1.0f / 255.0f);
        lut[i] = linear_in ? v : (v <= 0.04045f ? v / 12.92f : powf((v + 0.055f) / 1.055f, 2.4f));
    }
    const int bo = is_bgr ? 0 : 2;
    const int ro = 2 - bo;
    const float mX_r = (float)(0.412453 / 0.950456), mX_g = (float)(0.357580 / 0.950456), mX_b = (float)(0.180423 / 0.950456);
    const float mY_r = 0.212671f, mY_g = 0.715160f, mY_b = 0.072169f;
    const float mZ_r = (float)(0.019334 / 1.088754), mZ_g = (float)(0.119193 / 1.088754), mZ_b = (float)(0.950227 / 1.088754);

    const float32x4_t vzero = vdupq_n_f32(0.0f), v255 = vdupq_n_f32(255.0f);
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (ptrdiff_t)y * sstep;
        uint8_t *d = dst + (ptrdiff_t)y * dstep;
        int32_t x = 0;
        for (; x + 4 <= w; x += 4) {
            const uint8_t *p = s + (ptrdiff_t)x * scn;
            float rr[4] = {lut[p[ro]], lut[p[scn + ro]], lut[p[2 * scn + ro]], lut[p[3 * scn + ro]]};
            float gg[4] = {lut[p[1]],  lut[p[scn + 1]],  lut[p[2 * scn + 1]],  lut[p[3 * scn + 1]]};
            float bb[4] = {lut[p[bo]], lut[p[scn + bo]], lut[p[2 * scn + bo]], lut[p[3 * scn + bo]]};
            float32x4_t vr = vld1q_f32(rr), vg = vld1q_f32(gg), vb = vld1q_f32(bb);

            float32x4_t X = vfmaq_f32(vfmaq_f32(vmulq_n_f32(vr, mX_r), vg, vdupq_n_f32(mX_g)), vb, vdupq_n_f32(mX_b));
            float32x4_t Y = vfmaq_f32(vfmaq_f32(vmulq_n_f32(vr, mY_r), vg, vdupq_n_f32(mY_g)), vb, vdupq_n_f32(mY_b));
            float32x4_t Z = vfmaq_f32(vfmaq_f32(vmulq_n_f32(vr, mZ_r), vg, vdupq_n_f32(mZ_g)), vb, vdupq_n_f32(mZ_b));

            float32x4_t fX = sr_neon_lab_f4(X);
            float32x4_t fY = sr_neon_lab_f4(Y);
            float32x4_t fZ = sr_neon_lab_f4(Z);

            float32x4_t L_hi = vsubq_f32(vmulq_n_f32(fY, 116.0f), vdupq_n_f32(16.0f));
            float32x4_t L_lo = vmulq_n_f32(Y, 903.3f);
            float32x4_t L = vbslq_f32(vcgtq_f32(Y, vdupq_n_f32(0.008856f)), L_hi, L_lo);
            float32x4_t o0 = vmulq_n_f32(L, 2.55f);
            float32x4_t o1 = vfmaq_f32(vdupq_n_f32(128.0f), vsubq_f32(fX, fY), vdupq_n_f32(500.0f));
            float32x4_t o2 = vfmaq_f32(vdupq_n_f32(128.0f), vsubq_f32(fY, fZ), vdupq_n_f32(200.0f));

            uint32x4_t u0 = vcvtnq_u32_f32(vminq_f32(vmaxq_f32(o0, vzero), v255));
            uint32x4_t u1 = vcvtnq_u32_f32(vminq_f32(vmaxq_f32(o1, vzero), v255));
            uint32x4_t u2 = vcvtnq_u32_f32(vminq_f32(vmaxq_f32(o2, vzero), v255));
            uint32_t a0[4], a1[4], a2[4];
            vst1q_u32(a0, u0); vst1q_u32(a1, u1); vst1q_u32(a2, u2);
            for (int k = 0; k < 4; k++) {
                uint8_t *dp = d + (ptrdiff_t)(x + k) * dcn;
                dp[0] = (uint8_t)a0[k]; dp[1] = (uint8_t)a1[k]; dp[2] = (uint8_t)a2[k];
                if (dcn == 4) dp[3] = scn == 4 ? p[k * 4 + 3] : 255;
            }
        }
        for (; x < w; x++) {
            const uint8_t *p = s + (ptrdiff_t)x * scn;
            double rl = lut[p[ro]], gl = lut[p[1]], bl = lut[p[bo]];
            double X = (0.412453 * rl + 0.357580 * gl + 0.180423 * bl) / 0.950456;
            double Y = 0.212671 * rl + 0.715160 * gl + 0.072169 * bl;
            double Z = (0.019334 * rl + 0.119193 * gl + 0.950227 * bl) / 1.088754;
            double fX = X > 0.008856 ? cbrt(X) : (7.787 * X + 16.0 / 116.0);
            double fY = Y > 0.008856 ? cbrt(Y) : (7.787 * Y + 16.0 / 116.0);
            double fZ = Z > 0.008856 ? cbrt(Z) : (7.787 * Z + 16.0 / 116.0);
            double L = Y > 0.008856 ? (116.0 * fY - 16.0) : (903.3 * Y);
            double a = 500.0 * (fX - fY), bb = 200.0 * (fY - fZ);
            uint8_t *dp = d + (ptrdiff_t)x * dcn;
            dp[0] = sr_sat_u8_d_round(L * 2.55);
            dp[1] = sr_sat_u8_d_round(a + 128.0);
            dp[2] = sr_sat_u8_d_round(bb + 128.0);
            if (dcn == 4) dp[3] = scn == 4 ? p[3] : 255;
        }
    }
    return 0;
}

// ------------------------------------------------------------------ reduce_u8

static inline uint32_t sum_row_u8_1ch(const uint8_t *p, int32_t n) {
    uint32x4_t acc = vdupq_n_u32(0);
    int32_t i = 0;
    while (i + 64 <= n) {
        uint16x8_t s0 = vaddl_u8(vld1_u8(p + i), vld1_u8(p + i + 8));
        uint16x8_t s1 = vaddl_u8(vld1_u8(p + i + 16), vld1_u8(p + i + 24));
        uint16x8_t s2 = vaddl_u8(vld1_u8(p + i + 32), vld1_u8(p + i + 40));
        uint16x8_t s3 = vaddl_u8(vld1_u8(p + i + 48), vld1_u8(p + i + 56));
        acc = vpadalq_u16(acc, vaddq_u16(vaddq_u16(s0, s1), vaddq_u16(s2, s3)));
        i += 64;
    }
    uint32_t sum = vaddvq_u32(acc);
    for (; i < n; i++) sum += p[i];
    return sum;
}

static void write_reduced_val(void *dst, int32_t idx, int32_t ddepth, uint64_t val, int32_t denom, int is_avg) {
    double dv = is_avg ? ((double)val / (double)denom) : (double)val;
    switch (ddepth) {
    case SR_PERF_DEPTH_U8:
        ((uint8_t *)dst)[idx] = sr_sat_u8_f32_even(dv);
        break;
    case SR_PERF_DEPTH_S32:
        ((int32_t *)dst)[idx] = is_avg ? (int32_t)llround(dv) : (val > (uint64_t)INT32_MAX ? INT32_MAX : (int32_t)val);
        break;
    case SR_PERF_DEPTH_F32:
        ((float *)dst)[idx] = (float)dv;
        break;
    case SR_PERF_DEPTH_F64:
        ((double *)dst)[idx] = dv;
        break;
    default:
        break;
    }
}

int32_t sr_c_reduce_u8(const uint8_t *src, ptrdiff_t sstep, void *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t cn, int32_t dim, int32_t rtype, int32_t ddepth) {
    if (!src || !dst || w <= 0 || h <= 0 || cn <= 0) return -1;
    if (rtype == SR_PERF_REDUCE_MAX || rtype == SR_PERF_REDUCE_MIN) {
        if (ddepth != SR_PERF_DEPTH_U8) return -1;
        int is_max = (rtype == SR_PERF_REDUCE_MAX);
        if (dim == 0) {
            uint8_t *d = (uint8_t *)dst;
            int32_t n = w * cn;
            memcpy(d, src, (size_t)n);
            for (int32_t y = 1; y < h; y++) {
                const uint8_t *s = src + (ptrdiff_t)y * sstep;
                int32_t i = 0;
                for (; i + 16 <= n; i += 16) {
                    uint8x16_t a = vld1q_u8(d + i), b = vld1q_u8(s + i);
                    vst1q_u8(d + i, is_max ? vmaxq_u8(a, b) : vminq_u8(a, b));
                }
                for (; i < n; i++) d[i] = is_max ? (d[i] > s[i] ? d[i] : s[i]) : (d[i] < s[i] ? d[i] : s[i]);
            }
        } else {
            for (int32_t y = 0; y < h; y++) {
                const uint8_t *s = src + (ptrdiff_t)y * sstep;
                uint8_t *d = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
                if (cn == 1) {
                    uint8_t cur = s[0];
                    int32_t x = 0;
                    uint8x16_t vacc = vdupq_n_u8(is_max ? 0 : 255);
                    for (; x + 16 <= w; x += 16) {
                        uint8x16_t v = vld1q_u8(s + x);
                        vacc = is_max ? vmaxq_u8(vacc, v) : vminq_u8(vacc, v);
                    }
                    uint8_t r = is_max ? vmaxvq_u8(vacc) : vminvq_u8(vacc);
                    if (w < 16) r = cur;
                    for (; x < w; x++) r = is_max ? (r > s[x] ? r : s[x]) : (r < s[x] ? r : s[x]);
                    d[0] = r;
                } else {
                    for (int32_t c = 0; c < cn; c++) d[c] = s[c];
                    for (int32_t x = 1; x < w; x++) {
                        for (int32_t c = 0; c < cn; c++) {
                            uint8_t v = s[(ptrdiff_t)x * cn + c];
                            d[c] = is_max ? (d[c] > v ? d[c] : v) : (d[c] < v ? d[c] : v);
                        }
                    }
                }
            }
        }
        return 0;
    }

    int is_avg = (rtype == SR_PERF_REDUCE_AVG);
    if (dim == 1) {
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *s = src + (ptrdiff_t)y * sstep;
            void *d = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
            if (cn == 1) {
                uint32_t tot = sum_row_u8_1ch(s, w);
                write_reduced_val(d, 0, ddepth, (uint64_t)tot, w, is_avg);
            } else {
                uint64_t acc[4] = {0, 0, 0, 0};
                uint64_t *ap = cn <= 4 ? acc : (uint64_t *)calloc((size_t)cn, sizeof(uint64_t));
                if (!ap) return -1;
                for (int32_t x = 0; x < w; x++) {
                    for (int32_t c = 0; c < cn; c++) ap[c] += s[(ptrdiff_t)x * cn + c];
                }
                for (int32_t c = 0; c < cn; c++) write_reduced_val(d, c, ddepth, ap[c], w, is_avg);
                if (ap != acc) free(ap);
            }
        }
    } else {
        int32_t n = w * cn;
        uint32_t *col = (uint32_t *)calloc((size_t)n, sizeof(uint32_t));
        if (!col) return -1;
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *s = src + (ptrdiff_t)y * sstep;
            int32_t i = 0;
            for (; i + 16 <= n; i += 16) {
                uint8x16_t v = vld1q_u8(s + i);
                uint16x8_t l = vmovl_u8(vget_low_u8(v)), r = vmovl_u8(vget_high_u8(v));
                vst1q_u32(col + i + 0, vaddw_u16(vld1q_u32(col + i + 0), vget_low_u16(l)));
                vst1q_u32(col + i + 4, vaddw_u16(vld1q_u32(col + i + 4), vget_high_u16(l)));
                vst1q_u32(col + i + 8, vaddw_u16(vld1q_u32(col + i + 8), vget_low_u16(r)));
                vst1q_u32(col + i + 12, vaddw_u16(vld1q_u32(col + i + 12), vget_high_u16(r)));
            }
            for (; i < n; i++) col[i] += s[i];
        }
        for (int32_t i = 0; i < n; i++) write_reduced_val(dst, i, ddepth, (uint64_t)col[i], h, is_avg);
        free(col);
    }
    return 0;
}

// ------------------------------------------------------------------ Laplacian (ksize 1 & 3, rolling row)

static inline double read_elem_d(const void *row, int32_t idx, int32_t depth) {
    switch (depth) {
    case SR_PERF_DEPTH_U8:  return (double)((const uint8_t *)row)[idx];
    case SR_PERF_DEPTH_S8:  return (double)((const int8_t *)row)[idx];
    case SR_PERF_DEPTH_U16: return (double)((const uint16_t *)row)[idx];
    case SR_PERF_DEPTH_S16: return (double)((const int16_t *)row)[idx];
    case SR_PERF_DEPTH_S32: return (double)((const int32_t *)row)[idx];
    case SR_PERF_DEPTH_F32: return (double)((const float *)row)[idx];
    default:                return ((const double *)row)[idx];
    }
}

static inline void write_elem_d(void *row, int32_t idx, int32_t depth, double v) {
    switch (depth) {
    case SR_PERF_DEPTH_U8:
        ((uint8_t *)row)[idx] = sr_sat_u8_f32_even(v);
        break;
    case SR_PERF_DEPTH_S8: {
        long r = lrint(v);
        ((int8_t *)row)[idx] = (int8_t)(r < -128 ? -128 : (r > 127 ? 127 : r));
        break;
    }
    case SR_PERF_DEPTH_U16:
        ((uint16_t *)row)[idx] = sr_sat_u16_f32_even(v);
        break;
    case SR_PERF_DEPTH_S16: {
        long r = lrint(v);
        ((int16_t *)row)[idx] = (int16_t)(r < -32768 ? -32768 : (r > 32767 ? 32767 : r));
        break;
    }
    case SR_PERF_DEPTH_S32: {
        long long r = llrint(v);
        ((int32_t *)row)[idx] = (int32_t)(r < INT32_MIN ? INT32_MIN : (r > INT32_MAX ? INT32_MAX : r));
        break;
    }
    case SR_PERF_DEPTH_F32:
        ((float *)row)[idx] = (float)v;
        break;
    default:
        ((double *)row)[idx] = v;
        break;
    }
}

int32_t sr_c_laplacian(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                       void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                       int32_t w, int32_t h, int32_t cn,
                       int32_t ksize, double scale, double delta, int32_t border) {
    #pragma STDC FP_CONTRACT OFF
    if (!src || !dst || w <= 0 || h <= 0 || cn <= 0 || (ksize != 1 && ksize != 3)) return -1;
    const int32_t n = w * cn;

    // Fast NEON 3-row path when sdepth == F32 && ddepth == F32 (handles in-place src == dst too via ring).
    if (sdepth == SR_PERF_DEPTH_F32 && ddepth == SR_PERF_DEPTH_F32) {
        const float sc1 = (float)((ksize == 1 ? 1.0 : 2.0) * scale);
        const float sc0 = (float)((ksize == 1 ? -4.0 : -8.0) * scale);
        const float dl = (float)delta;
        const float32x4_t v_sc1 = vdupq_n_f32(sc1);
        const float32x4_t v_sc0 = vdupq_n_f32(sc0);
        const float32x4_t v_dl  = vdupq_n_f32(dl);

        int in_place = (src == dst);
        float *ring = NULL;
        int32_t ring_keys[3] = {-1, -1, -1};
        if (in_place) {
            ring = (float *)malloc(sizeof(float) * 3u * (size_t)n);
            if (!ring) return -1;
        }
        for (int32_t y = 0; y < h; y++) {
            int32_t ym = sr_border_interp(y - 1, h, border);
            int32_t y0 = y;
            int32_t yp = sr_border_interp(y + 1, h, border);
            const float *r0 = NULL, *r1 = NULL, *r2 = NULL;
            if (in_place) {
                int32_t ys[3] = {ym, y0, yp};
                const float *ptrs[3] = {NULL, NULL, NULL};
                for (int k = 0; k < 3; k++) {
                    if (ys[k] < 0) continue;
                    int slot = ys[k] % 3;
                    if (ring_keys[slot] != ys[k]) {
                        memcpy(ring + (size_t)slot * (size_t)n,
                               (const uint8_t *)src + (ptrdiff_t)ys[k] * sstep_bytes, sizeof(float) * (size_t)n);
                        ring_keys[slot] = ys[k];
                    }
                    ptrs[k] = ring + (size_t)slot * (size_t)n;
                }
                r0 = ptrs[0]; r1 = ptrs[1]; r2 = ptrs[2];
            } else {
                r0 = ym >= 0 ? (const float *)((const uint8_t *)src + (ptrdiff_t)ym * sstep_bytes) : NULL;
                r1 = (const float *)((const uint8_t *)src + (ptrdiff_t)y0 * sstep_bytes);
                r2 = yp >= 0 ? (const float *)((const uint8_t *)src + (ptrdiff_t)yp * sstep_bytes) : NULL;
            }
            float *dr = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
            if (r0 && r2 && w >= 3) {
                // Left edge
                for (int32_t c = 0; c < cn; c++) {
                    int32_t xm = sr_border_interp(-1, w, border);
                    float lm0 = xm >= 0 ? r0[xm * cn + c] : 0.0f;
                    float lm1 = xm >= 0 ? r1[xm * cn + c] : 0.0f;
                    float lm2 = xm >= 0 ? r2[xm * cn + c] : 0.0f;
                    dr[c] = (ksize == 1)
                        ? dl + r0[c] * sc1 + lm1 * sc1 + r1[c] * sc0 + r1[cn + c] * sc1 + r2[c] * sc1
                        : dl + lm0 * sc1 + r0[cn + c] * sc1 + r1[c] * sc0 + lm2 * sc1 + r2[cn + c] * sc1;
                }
                int32_t i = cn;
                int32_t end_i = n - cn;
                if (ksize == 1) {
                    for (; i + 16 <= end_i; i += 16) {
                        for (int k = 0; k < 16; k += 4) {
                            float32x4_t a = vaddq_f32(v_dl, vmulq_f32(vld1q_f32(r0 + i + k), v_sc1));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i + k - cn), v_sc1));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i + k), v_sc0));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i + k + cn), v_sc1));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r2 + i + k), v_sc1));
                            vst1q_f32(dr + i + k, a);
                        }
                    }
                    for (; i + 4 <= end_i; i += 4) {
                        float32x4_t a = vaddq_f32(v_dl, vmulq_f32(vld1q_f32(r0 + i), v_sc1));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i - cn), v_sc1));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i), v_sc0));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i + cn), v_sc1));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r2 + i), v_sc1));
                        vst1q_f32(dr + i, a);
                    }
                    for (; i < end_i; i++) {
                        dr[i] = dl + r0[i] * sc1 + r1[i - cn] * sc1 + r1[i] * sc0 + r1[i + cn] * sc1 + r2[i] * sc1;
                    }
                } else {
                    for (; i + 16 <= end_i; i += 16) {
                        for (int k = 0; k < 16; k += 4) {
                            float32x4_t a = vaddq_f32(v_dl, vmulq_f32(vld1q_f32(r0 + i + k - cn), v_sc1));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r0 + i + k + cn), v_sc1));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i + k), v_sc0));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r2 + i + k - cn), v_sc1));
                            a = vaddq_f32(a, vmulq_f32(vld1q_f32(r2 + i + k + cn), v_sc1));
                            vst1q_f32(dr + i + k, a);
                        }
                    }
                    for (; i + 4 <= end_i; i += 4) {
                        float32x4_t a = vaddq_f32(v_dl, vmulq_f32(vld1q_f32(r0 + i - cn), v_sc1));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r0 + i + cn), v_sc1));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r1 + i), v_sc0));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r2 + i - cn), v_sc1));
                        a = vaddq_f32(a, vmulq_f32(vld1q_f32(r2 + i + cn), v_sc1));
                        vst1q_f32(dr + i, a);
                    }
                    for (; i < end_i; i++) {
                        dr[i] = dl + r0[i - cn] * sc1 + r0[i + cn] * sc1 + r1[i] * sc0 + r2[i - cn] * sc1 + r2[i + cn] * sc1;
                    }
                }
                // Right edge
                int32_t last = (w - 1) * cn;
                for (int32_t c = 0; c < cn; c++) {
                    int32_t xp = sr_border_interp(w, w, border);
                    float rp0 = xp >= 0 ? r0[xp * cn + c] : 0.0f;
                    float rp1 = xp >= 0 ? r1[xp * cn + c] : 0.0f;
                    float rp2 = xp >= 0 ? r2[xp * cn + c] : 0.0f;
                    dr[last + c] = (ksize == 1)
                        ? dl + r0[last + c] * sc1 + r1[last - cn + c] * sc1 + r1[last + c] * sc0 + rp1 * sc1 + r2[last + c] * sc1
                        : dl + r0[last - cn + c] * sc1 + rp0 * sc1 + r1[last + c] * sc0 + r2[last - cn + c] * sc1 + rp2 * sc1;
                }
            } else {
                for (int32_t x = 0; x < w; x++) {
                    int32_t xm = sr_border_interp(x - 1, w, border);
                    int32_t xp = sr_border_interp(x + 1, w, border);
                    for (int32_t c = 0; c < cn; c++) {
                        float v00 = (r0 && xm >= 0) ? r0[xm * cn + c] : 0.0f;
                        float v01 = r0 ? r0[x * cn + c] : 0.0f;
                        float v02 = (r0 && xp >= 0) ? r0[xp * cn + c] : 0.0f;
                        float v10 = xm >= 0 ? r1[xm * cn + c] : 0.0f;
                        float v11 = r1[x * cn + c];
                        float v12 = xp >= 0 ? r1[xp * cn + c] : 0.0f;
                        float v20 = (r2 && xm >= 0) ? r2[xm * cn + c] : 0.0f;
                        float v21 = r2 ? r2[x * cn + c] : 0.0f;
                        float v22 = (r2 && xp >= 0) ? r2[xp * cn + c] : 0.0f;
                        dr[x * cn + c] = (ksize == 1)
                            ? dl + v11 * sc0 + (v01 + v10 + v12 + v21) * sc1
                            : dl + v11 * sc0 + (v00 + v02 + v20 + v22) * sc1;
                    }
                }
            }
        }
        free(ring);
        return 0;
    }

    // Streaming 3-row ring for any depth combination (handles in-place src == dst safely).
    const double dsc1 = (ksize == 1 ? 1.0 : 2.0) * scale;
    const double dsc0 = (ksize == 1 ? -4.0 : -8.0) * scale;
    const int32_t pad_n = (w + 2) * cn;
    double *ring = (double *)calloc(3u * (size_t)pad_n, sizeof(double));
    if (!ring) return -1;
    int32_t keys[3] = {-1, -1, -1};
    double *zeros = (double *)calloc((size_t)pad_n, sizeof(double));
    if (!zeros) { free(ring); return -1; }

    for (int32_t y = 0; y < h; y++) {
        int32_t ys[3] = {sr_border_interp(y - 1, h, border), y, sr_border_interp(y + 1, h, border)};
        const double *ptrs[3];
        for (int k = 0; k < 3; k++) {
            int32_t sy = ys[k];
            if (sy < 0) { ptrs[k] = zeros; continue; }
            int slot = sy % 3;
            double *rp = ring + (size_t)slot * (size_t)pad_n;
            if (keys[slot] != sy) {
                const void *sr = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                for (int32_t i = 0; i < n; i++) rp[cn + i] = read_elem_d(sr, i, sdepth);
                int32_t xl = sr_border_interp(-1, w, border), xr = sr_border_interp(w, w, border);
                for (int32_t c = 0; c < cn; c++) {
                    rp[c] = xl >= 0 ? rp[(xl + 1) * cn + c] : 0.0;
                    rp[(w + 1) * cn + c] = xr >= 0 ? rp[(xr + 1) * cn + c] : 0.0;
                }
                keys[slot] = sy;
            }
            ptrs[k] = rp;
        }
        const double *r0 = ptrs[0] + cn, *r1 = ptrs[1] + cn, *r2 = ptrs[2] + cn;
        void *dr = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
        if (ksize == 1) {
            for (int32_t i = 0; i < n; i++) {
                double v = delta + r1[i] * dsc0 + (r0[i] + r1[i - cn] + r1[i + cn] + r2[i]) * dsc1;
                write_elem_d(dr, i, ddepth, v);
            }
        } else {
            for (int32_t i = 0; i < n; i++) {
                double v = delta + r1[i] * dsc0 + (r0[i - cn] + r0[i + cn] + r2[i - cn] + r2[i + cn]) * dsc1;
                write_elem_d(dr, i, ddepth, v);
            }
        }
    }
    free(ring);
    free(zeros);
    return 0;
}

// ------------------------------------------------------------------ Workstream 2: Streaming Rolling-Row Morphology

typedef struct {
    int32_t ki;
    int32_t kj;
    int32_t len;
} morph_run_t;

static inline void pad_morph_row_u8(const uint8_t *sr, int32_t w, int32_t cn, int32_t kw, int32_t ax,
                                    int32_t border, const uint8_t *bv, uint8_t *pad) {
    memcpy(pad + (ptrdiff_t)ax * cn, sr, (size_t)w * (size_t)cn);
    int32_t right = kw - 1 - ax;
    for (int32_t q = 0; q < ax; q++) {
        int32_t sx = sr_border_interp(q - ax, w, border);
        if (sx < 0) memcpy(pad + (ptrdiff_t)q * cn, bv, (size_t)cn);
        else memcpy(pad + (ptrdiff_t)q * cn, sr + (ptrdiff_t)sx * cn, (size_t)cn);
    }
    for (int32_t q = 0; q < right; q++) {
        int32_t sx = sr_border_interp(w + q, w, border);
        if (sx < 0) memcpy(pad + (ptrdiff_t)(ax + w + q) * cn, bv, (size_t)cn);
        else memcpy(pad + (ptrdiff_t)(ax + w + q) * cn, sr + (ptrdiff_t)sx * cn, (size_t)cn);
    }
}

static inline void pad_morph_row_f32(const float *sr, int32_t w, int32_t cn, int32_t kw, int32_t ax,
                                     int32_t border, const float *bv, float *pad) {
    memcpy(pad + (ptrdiff_t)ax * cn, sr, sizeof(float) * (size_t)w * (size_t)cn);
    int32_t right = kw - 1 - ax;
    for (int32_t q = 0; q < ax; q++) {
        int32_t sx = sr_border_interp(q - ax, w, border);
        if (sx < 0) memcpy(pad + (ptrdiff_t)q * cn, bv, sizeof(float) * (size_t)cn);
        else memcpy(pad + (ptrdiff_t)q * cn, sr + (ptrdiff_t)sx * cn, sizeof(float) * (size_t)cn);
    }
    for (int32_t q = 0; q < right; q++) {
        int32_t sx = sr_border_interp(w + q, w, border);
        if (sx < 0) memcpy(pad + (ptrdiff_t)(ax + w + q) * cn, bv, sizeof(float) * (size_t)cn);
        else memcpy(pad + (ptrdiff_t)(ax + w + q) * cn, sr + (ptrdiff_t)sx * cn, sizeof(float) * (size_t)cn);
    }
}

// 1D sliding horizontal min/max over pad[0 .. (w + len - 1)*cn) -> out[0 .. w*cn), len >= 1.
static void morph_horiz_u8(const uint8_t *pad, int32_t w, int32_t cn, int32_t len, int is_max, uint8_t *out) {
    int32_t n = w * cn;
    if (len == 1) { memcpy(out, pad, (size_t)n); return; }
    int32_t i = 0;
    if (is_max) {
        for (; i + 16 <= n; i += 16) {
            uint8x16_t acc = vld1q_u8(pad + i);
            for (int32_t k = 1; k < len; k++) acc = vmaxq_u8(acc, vld1q_u8(pad + i + (ptrdiff_t)k * cn));
            vst1q_u8(out + i, acc);
        }
        for (; i < n; i++) {
            uint8_t acc = pad[i];
            for (int32_t k = 1; k < len; k++) { uint8_t v = pad[i + k * cn]; if (v > acc) acc = v; }
            out[i] = acc;
        }
    } else {
        for (; i + 16 <= n; i += 16) {
            uint8x16_t acc = vld1q_u8(pad + i);
            for (int32_t k = 1; k < len; k++) acc = vminq_u8(acc, vld1q_u8(pad + i + (ptrdiff_t)k * cn));
            vst1q_u8(out + i, acc);
        }
        for (; i < n; i++) {
            uint8_t acc = pad[i];
            for (int32_t k = 1; k < len; k++) { uint8_t v = pad[i + k * cn]; if (v < acc) acc = v; }
            out[i] = acc;
        }
    }
}

// Wait: write Van Herk cleanly without overwriting vh_pre input:
static void morph_vh_1d_u8(const uint8_t *pad, int32_t w, int32_t cn, int32_t len, int is_max,
                           uint8_t *out, uint8_t *pre, uint8_t *suf) {
    int32_t plen = w + len - 1;
    int32_t blocks = (plen + len - 1) / len;
    uint8_t ident = is_max ? 0 : 255;
    for (int32_t c = 0; c < cn; c++) {
        for (int32_t b = 0; b < blocks; b++) {
            int32_t base = b * len;
            uint8_t pacc = ident, sacc = ident;
            for (int32_t k = 0; k < len; k++) {
                int32_t x0 = base + k;
                uint8_t v0 = x0 < plen ? pad[x0 * cn + c] : ident;
                pacc = is_max ? (v0 > pacc ? v0 : pacc) : (v0 < pacc ? v0 : pacc);
                pre[x0] = pacc;

                int32_t x1 = base + len - 1 - k;
                uint8_t v1 = x1 < plen ? pad[x1 * cn + c] : ident;
                sacc = is_max ? (v1 > sacc ? v1 : sacc) : (v1 < sacc ? v1 : sacc);
                suf[x1] = sacc;
            }
        }
        for (int32_t x = 0; x < w; x++) {
            uint8_t a = suf[x], b = pre[x + len - 1];
            out[x * cn + c] = is_max ? (a > b ? a : b) : (a < b ? a : b);
        }
    }
}

static void morph_vh_1d_f32(const float *pad, int32_t w, int32_t cn, int32_t len, int is_max,
                            float *out, float *pre, float *suf) {
    int32_t plen = w + len - 1;
    int32_t blocks = (plen + len - 1) / len;
    float ident = is_max ? -FLT_MAX : FLT_MAX;
    for (int32_t c = 0; c < cn; c++) {
        for (int32_t b = 0; b < blocks; b++) {
            int32_t base = b * len;
            float pacc = ident, sacc = ident;
            for (int32_t k = 0; k < len; k++) {
                int32_t x0 = base + k;
                float v0 = x0 < plen ? pad[x0 * cn + c] : ident;
                pacc = is_max ? (v0 > pacc ? v0 : pacc) : (v0 < pacc ? v0 : pacc);
                pre[x0] = pacc;

                int32_t x1 = base + len - 1 - k;
                float v1 = x1 < plen ? pad[x1 * cn + c] : ident;
                sacc = is_max ? (v1 > sacc ? v1 : sacc) : (v1 < sacc ? v1 : sacc);
                suf[x1] = sacc;
            }
        }
        for (int32_t x = 0; x < w; x++) {
            float a = suf[x], b = pre[x + len - 1];
            out[x * cn + c] = is_max ? (a > b ? a : b) : (a < b ? a : b);
        }
    }
}

static inline void fold_run_u8(uint8_t *dst, const uint8_t *p, int32_t n, int32_t cn, int32_t len, int is_max,
                               int first, int32_t w, uint8_t *pre, uint8_t *suf, uint8_t *hrow) {
    if (len <= 7) {
        int32_t i = 0;
        if (is_max) {
            for (; i + 16 <= n; i += 16) {
                uint8x16_t acc = first ? vld1q_u8(p + i) : vld1q_u8(dst + i);
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) acc = vmaxq_u8(acc, vld1q_u8(p + i + (ptrdiff_t)k * cn));
                vst1q_u8(dst + i, acc);
            }
            for (; i < n; i++) {
                uint8_t acc = first ? p[i] : dst[i];
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) { uint8_t v = p[i + k * cn]; if (v > acc) acc = v; }
                dst[i] = acc;
            }
        } else {
            for (; i + 16 <= n; i += 16) {
                uint8x16_t acc = first ? vld1q_u8(p + i) : vld1q_u8(dst + i);
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) acc = vminq_u8(acc, vld1q_u8(p + i + (ptrdiff_t)k * cn));
                vst1q_u8(dst + i, acc);
            }
            for (; i < n; i++) {
                uint8_t acc = first ? p[i] : dst[i];
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) { uint8_t v = p[i + k * cn]; if (v < acc) acc = v; }
                dst[i] = acc;
            }
        }
    } else {
        morph_vh_1d_u8(p, w, cn, len, is_max, hrow, pre, suf);
        if (first) {
            memcpy(dst, hrow, (size_t)n);
        } else {
            int32_t i = 0;
            for (; i + 16 <= n; i += 16) {
                uint8x16_t a = vld1q_u8(dst + i), b = vld1q_u8(hrow + i);
                vst1q_u8(dst + i, is_max ? vmaxq_u8(a, b) : vminq_u8(a, b));
            }
            for (; i < n; i++) dst[i] = is_max ? (hrow[i] > dst[i] ? hrow[i] : dst[i]) : (hrow[i] < dst[i] ? hrow[i] : dst[i]);
        }
    }
}

static inline void fold_run_f32(float *dst, const float *p, int32_t n, int32_t cn, int32_t len, int is_max,
                                int first, int32_t w, float *pre, float *suf, float *hrow) {
    if (len <= 7) {
        int32_t i = 0;
        if (is_max) {
            for (; i + 4 <= n; i += 4) {
                float32x4_t acc = first ? vld1q_f32(p + i) : vld1q_f32(dst + i);
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) acc = vmaxq_f32(acc, vld1q_f32(p + i + (ptrdiff_t)k * cn));
                vst1q_f32(dst + i, acc);
            }
            for (; i < n; i++) {
                float acc = first ? p[i] : dst[i];
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) { float v = p[i + k * cn]; if (v > acc) acc = v; }
                dst[i] = acc;
            }
        } else {
            for (; i + 4 <= n; i += 4) {
                float32x4_t acc = first ? vld1q_f32(p + i) : vld1q_f32(dst + i);
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) acc = vminq_f32(acc, vld1q_f32(p + i + (ptrdiff_t)k * cn));
                vst1q_f32(dst + i, acc);
            }
            for (; i < n; i++) {
                float acc = first ? p[i] : dst[i];
                int32_t k0 = first ? 1 : 0;
                for (int32_t k = k0; k < len; k++) { float v = p[i + k * cn]; if (v < acc) acc = v; }
                dst[i] = acc;
            }
        }
    } else {
        morph_vh_1d_f32(p, w, cn, len, is_max, hrow, pre, suf);
        if (first) {
            memcpy(dst, hrow, sizeof(float) * (size_t)n);
        } else {
            int32_t i = 0;
            for (; i + 4 <= n; i += 4) {
                float32x4_t a = vld1q_f32(dst + i), b = vld1q_f32(hrow + i);
                vst1q_f32(dst + i, is_max ? vmaxq_f32(a, b) : vminq_f32(a, b));
            }
            for (; i < n; i++) dst[i] = is_max ? (hrow[i] > dst[i] ? hrow[i] : dst[i]) : (hrow[i] < dst[i] ? hrow[i] : dst[i]);
        }
    }
}

// Fast single-pass zero-copy horizontal morph for kw <= 7, cn <= 4, w >= 2*kw
static void morph_horiz_rect_fast_u8(const uint8_t *sr, int32_t w, int32_t cn, int32_t kw, int32_t ax,
                                     int32_t border, const uint8_t *bv, int is_max, uint8_t *out) {
    int32_t right = kw - 1 - ax;
    int32_t n = w * cn;
    uint8_t lpad[128], rpad[128];
    int32_t lcnt = ax + kw - 1; // pixels [-ax .. kw - 2]
    for (int32_t q = 0; q < lcnt; q++) {
        int32_t sx = q - ax;
        if (sx < 0) sx = sr_border_interp(sx, w, border);
        const uint8_t *sp = sx < 0 ? bv : sr + (ptrdiff_t)sx * cn;
        for (int32_t c = 0; c < cn; c++) lpad[q * cn + c] = sp[c];
    }
    int32_t rstart = w - right - ax;
    int32_t rcnt = ax + right + right; // pixels [w - right - ax .. w + right - 1]
    for (int32_t q = 0; q < rcnt; q++) {
        int32_t sx = rstart + q;
        if (sx >= w) sx = sr_border_interp(sx, w, border);
        const uint8_t *sp = sx < 0 ? bv : sr + (ptrdiff_t)sx * cn;
        for (int32_t c = 0; c < cn; c++) rpad[q * cn + c] = sp[c];
    }
    for (int32_t x = 0; x < ax; x++) {
        for (int32_t c = 0; c < cn; c++) {
            uint8_t acc = lpad[x * cn + c];
            for (int32_t k = 1; k < kw; k++) {
                uint8_t v = lpad[(x + k) * cn + c];
                acc = is_max ? (v > acc ? v : acc) : (v < acc ? v : acc);
            }
            out[x * cn + c] = acc;
        }
    }
    int32_t i0 = ax * cn, i1 = (w - right) * cn;
    const uint8_t *base = sr - (ptrdiff_t)ax * cn;
    int32_t i = i0;
    if (is_max) {
        for (; i + 32 <= i1; i += 32) {
            uint8x16_t a0 = vld1q_u8(base + i), a1 = vld1q_u8(base + i + 16);
            for (int32_t k = 1; k < kw; k++) {
                a0 = vmaxq_u8(a0, vld1q_u8(base + i + (ptrdiff_t)k * cn));
                a1 = vmaxq_u8(a1, vld1q_u8(base + i + 16 + (ptrdiff_t)k * cn));
            }
            vst1q_u8(out + i, a0);
            vst1q_u8(out + i + 16, a1);
        }
        for (; i + 16 <= i1; i += 16) {
            uint8x16_t acc = vld1q_u8(base + i);
            for (int32_t k = 1; k < kw; k++) acc = vmaxq_u8(acc, vld1q_u8(base + i + (ptrdiff_t)k * cn));
            vst1q_u8(out + i, acc);
        }
        for (; i < i1; i++) {
            uint8_t acc = base[i];
            for (int32_t k = 1; k < kw; k++) { uint8_t v = base[i + k * cn]; if (v > acc) acc = v; }
            out[i] = acc;
        }
    } else {
        for (; i + 32 <= i1; i += 32) {
            uint8x16_t a0 = vld1q_u8(base + i), a1 = vld1q_u8(base + i + 16);
            for (int32_t k = 1; k < kw; k++) {
                a0 = vminq_u8(a0, vld1q_u8(base + i + (ptrdiff_t)k * cn));
                a1 = vminq_u8(a1, vld1q_u8(base + i + 16 + (ptrdiff_t)k * cn));
            }
            vst1q_u8(out + i, a0);
            vst1q_u8(out + i + 16, a1);
        }
        for (; i + 16 <= i1; i += 16) {
            uint8x16_t acc = vld1q_u8(base + i);
            for (int32_t k = 1; k < kw; k++) acc = vminq_u8(acc, vld1q_u8(base + i + (ptrdiff_t)k * cn));
            vst1q_u8(out + i, acc);
        }
        for (; i < i1; i++) {
            uint8_t acc = base[i];
            for (int32_t k = 1; k < kw; k++) { uint8_t v = base[i + k * cn]; if (v < acc) acc = v; }
            out[i] = acc;
        }
    }
    for (int32_t x = 0; x < right; x++) {
        int32_t ox = w - right + x;
        for (int32_t c = 0; c < cn; c++) {
            uint8_t acc = rpad[x * cn + c];
            for (int32_t k = 1; k < kw; k++) {
                uint8_t v = rpad[(x + k) * cn + c];
                acc = is_max ? (v > acc ? v : acc) : (v < acc ? v : acc);
            }
            out[ox * cn + c] = acc;
        }
    }
    (void)n;
}

static void morph_once_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                          int32_t w, int32_t h, int32_t cn,
                          const uint8_t *kernel, int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                          int is_max, int32_t border, const uint8_t *bv, int id_border) {
    const int32_t n = w * cn;
    const uint8_t ident = is_max ? 0 : 255;

    // Check if rectangular all-non-zero
    int is_rect = 1, any_nz = 0;
    for (int32_t i = 0; i < kw * kh; i++) {
        if (kernel[i]) any_nz = 1; else is_rect = 0;
    }
    if (!any_nz) {
        for (int32_t y = 0; y < h; y++) memset(dst + (ptrdiff_t)y * dstep, ident, (size_t)n);
        return;
    }
    if (kw == 1 && kh == 1) {
        for (int32_t y = 0; y < h; y++) memcpy(dst + (ptrdiff_t)y * dstep, src + (ptrdiff_t)y * sstep, (size_t)n);
        return;
    }

    if (is_rect) {
        // Streaming kh-row ring buffer of horizontally dilated/eroded rows
        int32_t slots = kh;
        int32_t fast_horiz = (kw <= 7 && cn <= 4 && w >= 2 * kw);
        int32_t pn = (w + kw - 1) * cn;
        uint8_t *pad = fast_horiz ? NULL : (uint8_t *)malloc((size_t)pn);
        uint8_t *ring = (uint8_t *)malloc((size_t)slots * (size_t)n);
        int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
        uint8_t *const_row = (uint8_t *)malloc((size_t)n);
        uint8_t *pre = kw > 7 ? (uint8_t *)malloc((size_t)(w + kw * 2)) : NULL;
        uint8_t *suf = kw > 7 ? (uint8_t *)malloc((size_t)(w + kw * 2)) : NULL;
        const uint8_t **rpts = (const uint8_t **)malloc(sizeof(uint8_t *) * (size_t)kh);
        if ((!fast_horiz && !pad) || !ring || !keys || !const_row || !rpts || (kw > 7 && (!pre || !suf))) {
            free(pad); free(ring); free(keys); free(const_row); free(pre); free(suf); free(rpts);
            return;
        }
        for (int32_t i = 0; i < slots; i++) keys[i] = -1;
        for (int32_t x = 0; x < w; x++) memcpy(const_row + (ptrdiff_t)x * cn, bv, (size_t)cn);

        for (int32_t y = 0; y < h; y++) {
            int32_t nactive = 0;
            for (int32_t k = 0; k < kh; k++) {
                int32_t sy = sr_border_interp(y + k - ay, h, border);
                if (sy < 0) {
                    if (!id_border) rpts[nactive++] = const_row;
                    continue;
                }
                int32_t slot = sy % slots;
                uint8_t *rr = ring + (ptrdiff_t)slot * n;
                if (keys[slot] != sy) {
                    const uint8_t *sr = src + (ptrdiff_t)sy * sstep;
                    if (fast_horiz) {
                        morph_horiz_rect_fast_u8(sr, w, cn, kw, ax, border, bv, is_max, rr);
                    } else {
                        pad_morph_row_u8(sr, w, cn, kw, ax, border, bv, pad);
                        if (kw <= 7) morph_horiz_u8(pad, w, cn, kw, is_max, rr);
                        else morph_vh_1d_u8(pad, w, cn, kw, is_max, rr, pre, suf);
                    }
                    keys[slot] = sy;
                }
                rpts[nactive++] = rr;
            }
            uint8_t *dr = dst + (ptrdiff_t)y * dstep;
            if (nactive == 0) {
                memset(dr, ident, (size_t)n);
            } else if (nactive == 1) {
                memcpy(dr, rpts[0], (size_t)n);
            } else if (nactive == 5) {
                const uint8_t *r0 = rpts[0], *r1 = rpts[1], *r2 = rpts[2], *r3 = rpts[3], *r4 = rpts[4];
                int32_t i = 0;
                if (is_max) {
                    for (; i + 32 <= n; i += 32) {
                        uint8x16_t a0 = vmaxq_u8(vmaxq_u8(vmaxq_u8(vld1q_u8(r0+i), vld1q_u8(r1+i)), vmaxq_u8(vld1q_u8(r2+i), vld1q_u8(r3+i))), vld1q_u8(r4+i));
                        uint8x16_t a1 = vmaxq_u8(vmaxq_u8(vmaxq_u8(vld1q_u8(r0+i+16), vld1q_u8(r1+i+16)), vmaxq_u8(vld1q_u8(r2+i+16), vld1q_u8(r3+i+16))), vld1q_u8(r4+i+16));
                        vst1q_u8(dr + i, a0); vst1q_u8(dr + i + 16, a1);
                    }
                    for (; i + 16 <= n; i += 16)
                        vst1q_u8(dr + i, vmaxq_u8(vmaxq_u8(vmaxq_u8(vld1q_u8(r0+i), vld1q_u8(r1+i)), vmaxq_u8(vld1q_u8(r2+i), vld1q_u8(r3+i))), vld1q_u8(r4+i)));
                    for (; i < n; i++) {
                        uint8_t m = r0[i]; if (r1[i]>m) m=r1[i]; if (r2[i]>m) m=r2[i]; if (r3[i]>m) m=r3[i]; if (r4[i]>m) m=r4[i]; dr[i]=m;
                    }
                } else {
                    for (; i + 32 <= n; i += 32) {
                        uint8x16_t a0 = vminq_u8(vminq_u8(vminq_u8(vld1q_u8(r0+i), vld1q_u8(r1+i)), vminq_u8(vld1q_u8(r2+i), vld1q_u8(r3+i))), vld1q_u8(r4+i));
                        uint8x16_t a1 = vminq_u8(vminq_u8(vminq_u8(vld1q_u8(r0+i+16), vld1q_u8(r1+i+16)), vminq_u8(vld1q_u8(r2+i+16), vld1q_u8(r3+i+16))), vld1q_u8(r4+i+16));
                        vst1q_u8(dr + i, a0); vst1q_u8(dr + i + 16, a1);
                    }
                    for (; i + 16 <= n; i += 16)
                        vst1q_u8(dr + i, vminq_u8(vminq_u8(vminq_u8(vld1q_u8(r0+i), vld1q_u8(r1+i)), vminq_u8(vld1q_u8(r2+i), vld1q_u8(r3+i))), vld1q_u8(r4+i)));
                    for (; i < n; i++) {
                        uint8_t m = r0[i]; if (r1[i]<m) m=r1[i]; if (r2[i]<m) m=r2[i]; if (r3[i]<m) m=r3[i]; if (r4[i]<m) m=r4[i]; dr[i]=m;
                    }
                }
            } else {
                int32_t i = 0;
                if (is_max) {
                    for (; i + 16 <= n; i += 16) {
                        uint8x16_t acc = vld1q_u8(rpts[0] + i);
                        for (int32_t k = 1; k < nactive; k++) acc = vmaxq_u8(acc, vld1q_u8(rpts[k] + i));
                        vst1q_u8(dr + i, acc);
                    }
                    for (; i < n; i++) {
                        uint8_t acc = rpts[0][i];
                        for (int32_t k = 1; k < nactive; k++) { uint8_t v = rpts[k][i]; if (v > acc) acc = v; }
                        dr[i] = acc;
                    }
                } else {
                    for (; i + 16 <= n; i += 16) {
                        uint8x16_t acc = vld1q_u8(rpts[0] + i);
                        for (int32_t k = 1; k < nactive; k++) acc = vminq_u8(acc, vld1q_u8(rpts[k] + i));
                        vst1q_u8(dr + i, acc);
                    }
                    for (; i < n; i++) {
                        uint8_t acc = rpts[0][i];
                        for (int32_t k = 1; k < nactive; k++) { uint8_t v = rpts[k][i]; if (v < acc) acc = v; }
                        dr[i] = acc;
                    }
                }
            }
        }
        free(pad); free(ring); free(keys); free(const_row); free(pre); free(suf); free(rpts);
        return;
    }

    // General kernel: decompose into runs
    int32_t max_runs = kh * ((kw + 1) / 2);
    morph_run_t *runs = (morph_run_t *)malloc(sizeof(morph_run_t) * (size_t)max_runs);
    int32_t nruns = 0, max_run_len = 0;
    for (int32_t ki = 0; ki < kh; ki++) {
        int32_t kj = 0;
        while (kj < kw) {
            if (kernel[ki * kw + kj]) {
                int32_t e = kj;
                while (e < kw && kernel[ki * kw + e]) e++;
                int32_t len = e - kj;
                runs[nruns++] = (morph_run_t){ki, kj, len};
                if (len > max_run_len) max_run_len = len;
                kj = e;
            } else kj++;
        }
    }

    // Fused single-pass general kernel for small arbitrary shapes (ellipse5, cross3, cross5, etc.): zero ring buffer!
    if (kh <= 9 && kw <= 9 && max_run_len <= 9 && cn <= 4 && w >= 2 * kw && nruns <= 27) {
        const int32_t right = kw - 1 - ax;
        const int32_t i0 = ax * cn, i1 = (w - right) * cn;
        uint8_t *const_row = !id_border ? (uint8_t *)malloc((size_t)n) : NULL;
        if (const_row) for (int32_t x = 0; x < w; x++) memcpy(const_row + (ptrdiff_t)x * cn, bv, (size_t)cn);
        typedef struct { const uint8_t *ptr; int32_t len; } active_run_t;
        active_run_t aruns[32];
        const uint8x16_t v_ident = vdupq_n_u8(ident);

        for (int32_t y = 0; y < h; y++) {
            const uint8_t *srows[9];
            for (int32_t ki = 0; ki < kh; ki++) {
                int32_t sy = sr_border_interp(y + ki - ay, h, border);
                srows[ki] = sy >= 0 ? (src + (ptrdiff_t)sy * sstep) : const_row;
            }
            int32_t na = 0;
            for (int32_t r = 0; r < nruns; r++) {
                const uint8_t *sr = srows[runs[r].ki];
                if (!sr) continue;
                aruns[na++] = (active_run_t){sr + (ptrdiff_t)(runs[r].kj - ax) * cn, runs[r].len};
            }
            uint8_t *dr = dst + (ptrdiff_t)y * dstep;
            // Left edge [0 .. ax)
            for (int32_t x = 0; x < ax; x++) {
                for (int32_t c = 0; c < cn; c++) {
                    uint8_t acc = ident;
                    for (int32_t r = 0; r < nruns; r++) {
                        const uint8_t *sr = srows[runs[r].ki];
                        if (!sr) continue;
                        if (sr == const_row) { uint8_t v = bv[c]; acc = is_max ? (v > acc ? v : acc) : (v < acc ? v : acc); continue; }
                        for (int32_t k = 0; k < runs[r].len; k++) {
                            int32_t sx = sr_border_interp(x + runs[r].kj - ax + k, w, border);
                            uint8_t v = sx < 0 ? bv[c] : sr[(ptrdiff_t)sx * cn + c];
                            acc = is_max ? (v > acc ? v : acc) : (v < acc ? v : acc);
                        }
                    }
                    dr[x * cn + c] = acc;
                }
            }
            // Interior [i0 .. i1) in single pass (all runs folded in registers!)
            int32_t i = i0;
            if (is_max) {
                for (; i + 32 <= i1; i += 32) {
                    uint8x16_t a0 = v_ident, a1 = v_ident;
                    for (int32_t r = 0; r < na; r++) {
                        const uint8_t *p = aruns[r].ptr + i;
                        int32_t len = aruns[r].len;
                        for (int32_t k = 0; k < len; k++) {
                            a0 = vmaxq_u8(a0, vld1q_u8(p + (ptrdiff_t)k * cn));
                            a1 = vmaxq_u8(a1, vld1q_u8(p + 16 + (ptrdiff_t)k * cn));
                        }
                    }
                    vst1q_u8(dr + i, a0);
                    vst1q_u8(dr + i + 16, a1);
                }
                for (; i + 16 <= i1; i += 16) {
                    uint8x16_t acc = v_ident;
                    for (int32_t r = 0; r < na; r++) {
                        const uint8_t *p = aruns[r].ptr + i;
                        int32_t len = aruns[r].len;
                        for (int32_t k = 0; k < len; k++) acc = vmaxq_u8(acc, vld1q_u8(p + (ptrdiff_t)k * cn));
                    }
                    vst1q_u8(dr + i, acc);
                }
                for (; i < i1; i++) {
                    uint8_t acc = ident;
                    for (int32_t r = 0; r < na; r++) {
                        const uint8_t *p = aruns[r].ptr + i;
                        for (int32_t k = 0; k < aruns[r].len; k++) { uint8_t v = p[k * cn]; if (v > acc) acc = v; }
                    }
                    dr[i] = acc;
                }
            } else {
                for (; i + 32 <= i1; i += 32) {
                    uint8x16_t a0 = v_ident, a1 = v_ident;
                    for (int32_t r = 0; r < na; r++) {
                        const uint8_t *p = aruns[r].ptr + i;
                        int32_t len = aruns[r].len;
                        for (int32_t k = 0; k < len; k++) {
                            a0 = vminq_u8(a0, vld1q_u8(p + (ptrdiff_t)k * cn));
                            a1 = vminq_u8(a1, vld1q_u8(p + 16 + (ptrdiff_t)k * cn));
                        }
                    }
                    vst1q_u8(dr + i, a0);
                    vst1q_u8(dr + i + 16, a1);
                }
                for (; i + 16 <= i1; i += 16) {
                    uint8x16_t acc = v_ident;
                    for (int32_t r = 0; r < na; r++) {
                        const uint8_t *p = aruns[r].ptr + i;
                        int32_t len = aruns[r].len;
                        for (int32_t k = 0; k < len; k++) acc = vminq_u8(acc, vld1q_u8(p + (ptrdiff_t)k * cn));
                    }
                    vst1q_u8(dr + i, acc);
                }
                for (; i < i1; i++) {
                    uint8_t acc = ident;
                    for (int32_t r = 0; r < na; r++) {
                        const uint8_t *p = aruns[r].ptr + i;
                        for (int32_t k = 0; k < aruns[r].len; k++) { uint8_t v = p[k * cn]; if (v < acc) acc = v; }
                    }
                    dr[i] = acc;
                }
            }
            // Right edge [w - right .. w)
            for (int32_t x = w - right; x < w; x++) {
                for (int32_t c = 0; c < cn; c++) {
                    uint8_t acc = ident;
                    for (int32_t r = 0; r < nruns; r++) {
                        const uint8_t *sr = srows[runs[r].ki];
                        if (!sr) continue;
                        if (sr == const_row) { uint8_t v = bv[c]; acc = is_max ? (v > acc ? v : acc) : (v < acc ? v : acc); continue; }
                        for (int32_t k = 0; k < runs[r].len; k++) {
                            int32_t sx = sr_border_interp(x + runs[r].kj - ax + k, w, border);
                            uint8_t v = sx < 0 ? bv[c] : sr[(ptrdiff_t)sx * cn + c];
                            acc = is_max ? (v > acc ? v : acc) : (v < acc ? v : acc);
                        }
                    }
                    dr[x * cn + c] = acc;
                }
            }
        }
        free(runs); free(const_row);
        return;
    }

    int32_t slots = kh;
    int32_t pn = (w + kw - 1) * cn;
    uint8_t *ring = (uint8_t *)malloc((size_t)slots * (size_t)pn);
    int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
    uint8_t *const_row = !id_border ? (uint8_t *)malloc((size_t)n) : NULL;
    uint8_t *pre = max_run_len > 7 ? (uint8_t *)malloc((size_t)(w + max_run_len * 2)) : NULL;
    uint8_t *suf = max_run_len > 7 ? (uint8_t *)malloc((size_t)(w + max_run_len * 2)) : NULL;
    uint8_t *hrow = max_run_len > 7 ? (uint8_t *)malloc((size_t)n) : NULL;
    for (int32_t i = 0; i < slots; i++) keys[i] = -1;
    if (const_row) for (int32_t x = 0; x < w; x++) memcpy(const_row + (ptrdiff_t)x * cn, bv, (size_t)cn);

    for (int32_t y = 0; y < h; y++) {
        uint8_t *dr = dst + (ptrdiff_t)y * dstep;
        int first = 1;
        for (int32_t r = 0; r < nruns; r++) {
            int32_t sy = sr_border_interp(y + runs[r].ki - ay, h, border);
            if (sy < 0) {
                if (!id_border) {
                    if (first) { memcpy(dr, const_row, (size_t)n); first = 0; }
                    else {
                        for (int32_t i = 0; i < n; i++)
                            dr[i] = is_max ? (const_row[i] > dr[i] ? const_row[i] : dr[i]) : (const_row[i] < dr[i] ? const_row[i] : dr[i]);
                    }
                }
                continue;
            }
            int32_t slot = sy % slots;
            uint8_t *pad = ring + (ptrdiff_t)slot * pn;
            if (keys[slot] != sy) {
                pad_morph_row_u8(src + (ptrdiff_t)sy * sstep, w, cn, kw, ax, border, bv, pad);
                keys[slot] = sy;
            }
            fold_run_u8(dr, pad + (ptrdiff_t)runs[r].kj * cn, n, cn, runs[r].len, is_max, first, w, pre, suf, hrow);
            first = 0;
        }
        if (first) memset(dr, ident, (size_t)n);
    }
    free(runs); free(ring); free(keys); free(const_row); free(pre); free(suf); free(hrow);
}

static void morph_once_f32(const float *src, ptrdiff_t sstep_b, float *dst, ptrdiff_t dstep_b,
                           int32_t w, int32_t h, int32_t cn,
                           const uint8_t *kernel, int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                           int is_max, int32_t border, const float *bv, int id_border) {
    const int32_t n = w * cn;
    const float ident = is_max ? -FLT_MAX : FLT_MAX;
    int is_rect = 1, any_nz = 0;
    for (int32_t i = 0; i < kw * kh; i++) {
        if (kernel[i]) any_nz = 1; else is_rect = 0;
    }
    if (!any_nz) {
        for (int32_t y = 0; y < h; y++) {
            float *dr = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_b);
            for (int32_t i = 0; i < n; i++) dr[i] = ident;
        }
        return;
    }
    if (kw == 1 && kh == 1) {
        for (int32_t y = 0; y < h; y++)
            memcpy((uint8_t *)dst + (ptrdiff_t)y * dstep_b, (const uint8_t *)src + (ptrdiff_t)y * sstep_b, sizeof(float) * (size_t)n);
        return;
    }
    if (is_rect) {
        int32_t slots = kh, pn = (w + kw - 1) * cn;
        float *pad = (float *)malloc(sizeof(float) * (size_t)pn);
        float *ring = (float *)malloc(sizeof(float) * (size_t)slots * (size_t)n);
        int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
        float *const_row = (float *)malloc(sizeof(float) * (size_t)n);
        float *pre = kw > 7 ? (float *)malloc(sizeof(float) * (size_t)(w + kw * 2)) : NULL;
        float *suf = kw > 7 ? (float *)malloc(sizeof(float) * (size_t)(w + kw * 2)) : NULL;
        const float **rpts = (const float **)malloc(sizeof(float *) * (size_t)kh);
        for (int32_t i = 0; i < slots; i++) keys[i] = -1;
        for (int32_t x = 0; x < w; x++) memcpy(const_row + (ptrdiff_t)x * cn, bv, sizeof(float) * (size_t)cn);

        for (int32_t y = 0; y < h; y++) {
            int32_t nactive = 0;
            for (int32_t k = 0; k < kh; k++) {
                int32_t sy = sr_border_interp(y + k - ay, h, border);
                if (sy < 0) {
                    if (!id_border) rpts[nactive++] = const_row;
                    continue;
                }
                int32_t slot = sy % slots;
                float *rr = ring + (ptrdiff_t)slot * n;
                if (keys[slot] != sy) {
                    const float *sr = (const float *)((const uint8_t *)src + (ptrdiff_t)sy * sstep_b);
                    pad_morph_row_f32(sr, w, cn, kw, ax, border, bv, pad);
                    if (kw <= 7) fold_run_f32(rr, pad, n, cn, kw, is_max, 1, w, NULL, NULL, NULL);
                    else morph_vh_1d_f32(pad, w, cn, kw, is_max, rr, pre, suf);
                    keys[slot] = sy;
                }
                rpts[nactive++] = rr;
            }
            float *dr = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_b);
            if (nactive == 0) {
                for (int32_t i = 0; i < n; i++) dr[i] = ident;
            } else if (nactive == 1) {
                memcpy(dr, rpts[0], sizeof(float) * (size_t)n);
            } else {
                int32_t i = 0;
                for (; i + 4 <= n; i += 4) {
                    float32x4_t acc = vld1q_f32(rpts[0] + i);
                    for (int32_t k = 1; k < nactive; k++) {
                        float32x4_t b = vld1q_f32(rpts[k] + i);
                        acc = is_max ? vmaxq_f32(acc, b) : vminq_f32(acc, b);
                    }
                    vst1q_f32(dr + i, acc);
                }
                for (; i < n; i++) {
                    float acc = rpts[0][i];
                    for (int32_t k = 1; k < nactive; k++) {
                        float v = rpts[k][i];
                        acc = is_max ? (v > acc ? v : acc) : (v < acc ? v : acc);
                    }
                    dr[i] = acc;
                }
            }
        }
        free(pad); free(ring); free(keys); free(const_row); free(pre); free(suf); free(rpts);
        return;
    }

    int32_t max_runs = kh * ((kw + 1) / 2);
    morph_run_t *runs = (morph_run_t *)malloc(sizeof(morph_run_t) * (size_t)max_runs);
    int32_t nruns = 0, max_run_len = 0;
    for (int32_t ki = 0; ki < kh; ki++) {
        int32_t kj = 0;
        while (kj < kw) {
            if (kernel[ki * kw + kj]) {
                int32_t e = kj;
                while (e < kw && kernel[ki * kw + e]) e++;
                int32_t len = e - kj;
                runs[nruns++] = (morph_run_t){ki, kj, len};
                if (len > max_run_len) max_run_len = len;
                kj = e;
            } else kj++;
        }
    }
    int32_t slots = kh, pn = (w + kw - 1) * cn;
    float *ring = (float *)malloc(sizeof(float) * (size_t)slots * (size_t)pn);
    int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
    float *const_row = !id_border ? (float *)malloc(sizeof(float) * (size_t)n) : NULL;
    float *pre = max_run_len > 7 ? (float *)malloc(sizeof(float) * (size_t)(w + max_run_len * 2)) : NULL;
    float *suf = max_run_len > 7 ? (float *)malloc(sizeof(float) * (size_t)(w + max_run_len * 2)) : NULL;
    float *hrow = max_run_len > 7 ? (float *)malloc(sizeof(float) * (size_t)n) : NULL;
    for (int32_t i = 0; i < slots; i++) keys[i] = -1;
    if (const_row) for (int32_t x = 0; x < w; x++) memcpy(const_row + (ptrdiff_t)x * cn, bv, sizeof(float) * (size_t)cn);

    for (int32_t y = 0; y < h; y++) {
        float *dr = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_b);
        int first = 1;
        for (int32_t r = 0; r < nruns; r++) {
            int32_t sy = sr_border_interp(y + runs[r].ki - ay, h, border);
            if (sy < 0) {
                if (!id_border) {
                    if (first) { memcpy(dr, const_row, sizeof(float) * (size_t)n); first = 0; }
                    else for (int32_t i = 0; i < n; i++)
                        dr[i] = is_max ? (const_row[i] > dr[i] ? const_row[i] : dr[i]) : (const_row[i] < dr[i] ? const_row[i] : dr[i]);
                }
                continue;
            }
            int32_t slot = sy % slots;
            float *pad = ring + (ptrdiff_t)slot * pn;
            if (keys[slot] != sy) {
                pad_morph_row_f32((const float *)((const uint8_t *)src + (ptrdiff_t)sy * sstep_b), w, cn, kw, ax, border, bv, pad);
                keys[slot] = sy;
            }
            fold_run_f32(dr, pad + (ptrdiff_t)runs[r].kj * cn, n, cn, runs[r].len, is_max, first, w, pre, suf, hrow);
            first = 0;
        }
        if (first) for (int32_t i = 0; i < n; i++) dr[i] = ident;
    }
    free(runs); free(ring); free(keys); free(const_row); free(pre); free(suf); free(hrow);
}

int32_t sr_c_morph_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t cn,
                      const uint8_t *kernel, int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                      int32_t is_max, int32_t iterations, int32_t border, const double *bval,
                      int32_t identity_border) {
    if (!src || !dst || !kernel || !bval || w <= 0 || h <= 0 || cn <= 0 || kw <= 0 || kh <= 0) return -1;
    uint8_t bv[16];
    uint8_t ident = is_max ? 0 : 255;
    for (int32_t c = 0; c < cn && c < 16; c++) bv[c] = identity_border ? ident : sr_sat_u8_f32((float)bval[c < 4 ? c : 0]);
    if (iterations <= 0) {
        if (src != dst) {
            for (int32_t y = 0; y < h; y++) memcpy(dst + (ptrdiff_t)y * dstep, src + (ptrdiff_t)y * sstep, (size_t)w * (size_t)cn);
        }
        return 0;
    }
    if (iterations == 1 && src != dst) {
        morph_once_u8(src, sstep, dst, dstep, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
        return 0;
    }
    size_t rbytes = (size_t)w * (size_t)cn;
    uint8_t *tmp = (uint8_t *)malloc(rbytes * (size_t)h);
    if (!tmp) return -1;
    if (iterations == 1) {
        for (int32_t y = 0; y < h; y++) memcpy(tmp + (size_t)y * rbytes, src + (ptrdiff_t)y * sstep, rbytes);
        morph_once_u8(tmp, (ptrdiff_t)rbytes, dst, dstep, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
        free(tmp);
        return 0;
    }
    if (src == dst) {
        for (int32_t y = 0; y < h; y++) memcpy(tmp + (size_t)y * rbytes, src + (ptrdiff_t)y * sstep, rbytes);
        const uint8_t *cur_s = tmp;
        ptrdiff_t cur_ss = (ptrdiff_t)rbytes;
        for (int32_t it = 0; it < iterations; it++) {
            uint8_t *cur_d = (it & 1) == 0 ? dst : tmp;
            ptrdiff_t cur_ds = (it & 1) == 0 ? dstep : (ptrdiff_t)rbytes;
            morph_once_u8(cur_s, cur_ss, cur_d, cur_ds, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
            cur_s = cur_d;
            cur_ss = cur_ds;
        }
        if ((iterations & 1) == 0) {
            for (int32_t y = 0; y < h; y++) memcpy(dst + (ptrdiff_t)y * dstep, tmp + (size_t)y * rbytes, rbytes);
        }
    } else {
        int start_in_dst = (iterations & 1);
        uint8_t *buf = start_in_dst ? dst : tmp;
        ptrdiff_t bstep = start_in_dst ? dstep : (ptrdiff_t)rbytes;
        morph_once_u8(src, sstep, buf, bstep, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
        for (int32_t it = 1; it < iterations; it++) {
            int write_dst = ((iterations - it) & 1);
            const uint8_t *sptr = write_dst ? tmp : dst;
            ptrdiff_t sst = write_dst ? (ptrdiff_t)rbytes : dstep;
            uint8_t *dptr = write_dst ? dst : tmp;
            ptrdiff_t dstp = write_dst ? dstep : (ptrdiff_t)rbytes;
            morph_once_u8(sptr, sst, dptr, dstp, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
        }
    }
    free(tmp);
    return 0;
}

int32_t sr_c_morph_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t cn,
                       const uint8_t *kernel, int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                       int32_t is_max, int32_t iterations, int32_t border, const double *bval,
                       int32_t identity_border) {
    if (!src || !dst || !kernel || !bval || w <= 0 || h <= 0 || cn <= 0 || kw <= 0 || kh <= 0) return -1;
    float bv[16];
    float ident = is_max ? -FLT_MAX : FLT_MAX;
    for (int32_t c = 0; c < cn && c < 16; c++) bv[c] = identity_border ? ident : (float)bval[c < 4 ? c : 0];
    if (iterations <= 0) {
        if (src != dst) {
            for (int32_t y = 0; y < h; y++)
                memcpy((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes, (const uint8_t *)src + (ptrdiff_t)y * sstep_bytes, sizeof(float) * (size_t)w * (size_t)cn);
        }
        return 0;
    }
    if (iterations == 1 && src != dst) {
        morph_once_f32(src, sstep_bytes, dst, dstep_bytes, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
        return 0;
    }
    ptrdiff_t rbytes = (ptrdiff_t)sizeof(float) * (ptrdiff_t)w * cn;
    float *tmp = (float *)malloc((size_t)rbytes * (size_t)h);
    if (!tmp) return -1;
    if (src == dst) {
        for (int32_t y = 0; y < h; y++) memcpy((uint8_t *)tmp + (ptrdiff_t)y * rbytes, (const uint8_t *)src + (ptrdiff_t)y * sstep_bytes, (size_t)rbytes);
        if ((iterations & 1) == 0) {
            // even: tmp -> dst -> tmp? Needs tmp!=out: copy to dst? Actually wait: for even & src==dst, do pass 0 tmp -> dst, pass 1 dst -> tmp, ...
            // Notice if iterations==2: pass 0 writes dst (wrong at end because pass 1 writes tmp!). Need one extra copy OR allocate 2nd or run:
            // pass 0: tmp -> dst; ... if ends in tmp, memcpy tmp -> dst! Simple & zero aliasing!
            const float *cur_s = tmp; ptrdiff_t cur_ss = rbytes;
            for (int32_t it = 0; it < iterations; it++) {
                float *cur_d = (it & 1) == 0 ? dst : tmp;
                ptrdiff_t cur_ds = (it & 1) == 0 ? dstep_bytes : rbytes;
                morph_once_f32(cur_s, cur_ss, cur_d, cur_ds, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
                cur_s = cur_d; cur_ss = cur_ds;
            }
            if ((iterations & 1) == 0) {
                for (int32_t y = 0; y < h; y++)
                    memcpy((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes, (const uint8_t *)tmp + (ptrdiff_t)y * rbytes, (size_t)rbytes);
            }
        } else {
            // odd >= 1: pass 0 tmp -> dst, pass 1 dst -> tmp, pass 2 tmp -> dst ... always lands in dst!
            const float *cur_s = tmp; ptrdiff_t cur_ss = rbytes;
            for (int32_t it = 0; it < iterations; it++) {
                float *cur_d = (it & 1) == 0 ? dst : tmp;
                ptrdiff_t cur_ds = (it & 1) == 0 ? dstep_bytes : rbytes;
                morph_once_f32(cur_s, cur_ss, cur_d, cur_ds, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
                cur_s = cur_d; cur_ss = cur_ds;
            }
        }
    } else {
        int start_in_dst = (iterations & 1);
        float *d0 = start_in_dst ? dst : tmp;
        ptrdiff_t ds0 = start_in_dst ? dstep_bytes : rbytes;
        morph_once_f32(src, sstep_bytes, d0, ds0, w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
        for (int32_t it = 1; it < iterations; it++) {
            int write_dst = ((iterations - it) & 1);
            morph_once_f32(write_dst ? tmp : dst, write_dst ? rbytes : dstep_bytes,
                           write_dst ? dst : tmp, write_dst ? dstep_bytes : rbytes,
                           w, h, cn, kernel, kw, kh, ax, ay, is_max, border, bv, identity_border);
        }
    }
    free(tmp);
    return 0;
}

// Note: fix the identical subtle src==dst even-iteration bug in sr_c_morph_u8 cleanly right below via a post-check? No, fix sr_c_morph_u8 directly!
// Let's make sure we don't leave that bug in sr_c_morph_u8! Wait — we are writing the whole file now, so write the clean cur_s/cur_d loop directly in sr_c_morph_u8 before closing!

// ------------------------------------------------------------------ Workstream 3b: Resize kernels

void sr_c_resize_nearest(const uint8_t *src, ptrdiff_t sstep, int32_t sw, int32_t sh,
                         uint8_t *dst, ptrdiff_t dstep, int32_t dw, int32_t dh,
                         int32_t elem_bytes, double scale_x, double scale_y) {
    if (!src || !dst || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || elem_bytes <= 0) return;
    ptrdiff_t *xofs = (ptrdiff_t *)malloc(sizeof(ptrdiff_t) * (size_t)dw);
    if (!xofs) return;
    for (int32_t x = 0; x < dw; x++) {
        int32_t sx = (int32_t)floor((double)x * scale_x);
        if (sx < 0) sx = 0; else if (sx >= sw) sx = sw - 1;
        xofs[x] = (ptrdiff_t)sx * elem_bytes;
    }
    int32_t prev_sy = -1;
    const uint8_t *prev_dst = NULL;
    size_t row_bytes = (size_t)dw * (size_t)elem_bytes;
    for (int32_t y = 0; y < dh; y++) {
        int32_t sy = (int32_t)floor((double)y * scale_y);
        if (sy < 0) sy = 0; else if (sy >= sh) sy = sh - 1;
        uint8_t *o = dst + (ptrdiff_t)y * dstep;
        if (sy == prev_sy && prev_dst) {
            memcpy(o, prev_dst, row_bytes);
            continue;
        }
        const uint8_t *s = src + (ptrdiff_t)sy * sstep;
        switch (elem_bytes) {
        case 1:
            for (int32_t x = 0; x < dw; x++) o[x] = s[xofs[x]];
            break;
        case 2:
            for (int32_t x = 0; x < dw; x++) memcpy(o + (ptrdiff_t)x * 2, s + xofs[x], 2);
            break;
        case 3:
            for (int32_t x = 0; x < dw; x++) {
                const uint8_t *sp = s + xofs[x];
                uint8_t *dp = o + (ptrdiff_t)x * 3;
                dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2];
            }
            break;
        case 4:
            for (int32_t x = 0; x < dw; x++) sr_write_u32_unaligned(o + (ptrdiff_t)x * 4, sr_read_u32_unaligned(s + xofs[x]));
            break;
        default:
            for (int32_t x = 0; x < dw; x++) memcpy(o + (ptrdiff_t)x * elem_bytes, s + xofs[x], (size_t)elem_bytes);
            break;
        }
        prev_sy = sy;
        prev_dst = o;
    }
    free(xofs);
}

void sr_c_area_half_u8(const uint8_t *src, ptrdiff_t sstep, int32_t sw, int32_t sh,
                       uint8_t *dst, ptrdiff_t dstep, int32_t dw, int32_t dh, int32_t cn) {
    (void)sw; (void)sh;
    for (int32_t y = 0; y < dh; y++) {
        const uint8_t *a = src + (ptrdiff_t)(2 * y) * sstep;
        const uint8_t *b = src + (ptrdiff_t)(2 * y + 1) * sstep;
        uint8_t *o = dst + (ptrdiff_t)y * dstep;
        int32_t x = 0;
        if (cn == 1) {
            for (; x + 16 <= dw; x += 16) {
                uint8x16_t a0 = vld1q_u8(a + x * 2), a1 = vld1q_u8(a + x * 2 + 16);
                uint8x16_t b0 = vld1q_u8(b + x * 2), b1 = vld1q_u8(b + x * 2 + 16);
                uint16x8_t s0 = vaddq_u16(vpaddlq_u8(a0), vpaddlq_u8(b0));
                uint16x8_t s1 = vaddq_u16(vpaddlq_u8(a1), vpaddlq_u8(b1));
                vst1q_u8(o + x, vcombine_u8(vrshrn_n_u16(s0, 2), vrshrn_n_u16(s1, 2)));
            }
        } else if (cn == 3) {
            for (; x + 8 <= dw; x += 8) {
                uint8x16x3_t pa = vld3q_u8(a + (ptrdiff_t)x * 6);
                uint8x16x3_t pb = vld3q_u8(b + (ptrdiff_t)x * 6);
                uint8x8_t r0 = vrshrn_n_u16(vaddq_u16(vpaddlq_u8(pa.val[0]), vpaddlq_u8(pb.val[0])), 2);
                uint8x8_t r1 = vrshrn_n_u16(vaddq_u16(vpaddlq_u8(pa.val[1]), vpaddlq_u8(pb.val[1])), 2);
                uint8x8_t r2 = vrshrn_n_u16(vaddq_u16(vpaddlq_u8(pa.val[2]), vpaddlq_u8(pb.val[2])), 2);
                uint8x8x3_t out = {{r0, r1, r2}};
                vst3_u8(o + (ptrdiff_t)x * 3, out);
            }
        } else if (cn == 4) {
            for (; x + 8 <= dw; x += 8) {
                uint8x16x4_t pa = vld4q_u8(a + (ptrdiff_t)x * 8);
                uint8x16x4_t pb = vld4q_u8(b + (ptrdiff_t)x * 8);
                uint8x8_t r0 = vrshrn_n_u16(vaddq_u16(vpaddlq_u8(pa.val[0]), vpaddlq_u8(pb.val[0])), 2);
                uint8x8_t r1 = vrshrn_n_u16(vaddq_u16(vpaddlq_u8(pa.val[1]), vpaddlq_u8(pb.val[1])), 2);
                uint8x8_t r2 = vrshrn_n_u16(vaddq_u16(vpaddlq_u8(pa.val[2]), vpaddlq_u8(pb.val[2])), 2);
                uint8x8_t r3 = vrshrn_n_u16(vaddq_u16(vpaddlq_u8(pa.val[3]), vpaddlq_u8(pb.val[3])), 2);
                uint8x8x4_t out = {{r0, r1, r2, r3}};
                vst4_u8(o + (ptrdiff_t)x * 4, out);
            }
        }
        for (; x < dw; x++) {
            for (int32_t c = 0; c < cn; c++) {
                int32_t i = x * 2 * cn + c;
                o[x * cn + c] = (uint8_t)((a[i] + a[i + cn] + b[i] + b[i + cn] + 2) >> 2);
            }
        }
    }
}

static inline void store_float_row_neon(const float *acc, void *dst, int32_t n, int32_t depth) {
    if (depth == SR_PERF_DEPTH_F32) {
        memcpy(dst, acc, sizeof(float) * (size_t)n);
        return;
    }
    const float32x4_t v0 = vdupq_n_f32(0.0f);
    const float32x4_t vh = vdupq_n_f32(0.5f);
    int32_t i = 0;
    if (depth == SR_PERF_DEPTH_U8) {
        uint8_t *d = (uint8_t *)dst;
        const float32x4_t v255 = vdupq_n_f32(255.0f);
        for (; i + 16 <= n; i += 16) {
            uint32x4_t a0 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i), vh), v0), v255));
            uint32x4_t a1 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 4), vh), v0), v255));
            uint32x4_t a2 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 8), vh), v0), v255));
            uint32x4_t a3 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 12), vh), v0), v255));
            uint16x8_t q0 = vcombine_u16(vmovn_u32(a0), vmovn_u32(a1));
            uint16x8_t q1 = vcombine_u16(vmovn_u32(a2), vmovn_u32(a3));
            vst1q_u8(d + i, vcombine_u8(vmovn_u16(q0), vmovn_u16(q1)));
        }
        for (; i < n; i++) d[i] = sr_sat_u8_f32(acc[i]);
    } else {
        uint16_t *d = (uint16_t *)dst;
        const float32x4_t v65535 = vdupq_n_f32(65535.0f);
        for (; i + 8 <= n; i += 8) {
            uint32x4_t a0 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i), vh), v0), v65535));
            uint32x4_t a1 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 4), vh), v0), v65535));
            vst1q_u16(d + i, vcombine_u16(vmovn_u32(a0), vmovn_u32(a1)));
        }
        for (; i < n; i++) d[i] = sr_sat_u16_f32(acc[i]);
    }
}

static inline void load_row_to_float_neon(const void *src, int32_t n, int32_t depth, float *out) {
    if (depth == SR_PERF_DEPTH_F32) {
        memcpy(out, src, sizeof(float) * (size_t)n);
        return;
    }
    int32_t i = 0;
    if (depth == SR_PERF_DEPTH_U8) {
        const uint8_t *s = (const uint8_t *)src;
        for (; i + 16 <= n; i += 16) {
            uint8x16_t v = vld1q_u8(s + i);
            uint16x8_t l = vmovl_u8(vget_low_u8(v)), h = vmovl_u8(vget_high_u8(v));
            vst1q_f32(out + i + 0,  vcvtq_f32_u32(vmovl_u16(vget_low_u16(l))));
            vst1q_f32(out + i + 4,  vcvtq_f32_u32(vmovl_u16(vget_high_u16(l))));
            vst1q_f32(out + i + 8,  vcvtq_f32_u32(vmovl_u16(vget_low_u16(h))));
            vst1q_f32(out + i + 12, vcvtq_f32_u32(vmovl_u16(vget_high_u16(h))));
        }
        for (; i < n; i++) out[i] = (float)s[i];
    } else {
        const uint16_t *s = (const uint16_t *)src;
        for (; i + 8 <= n; i += 8) {
            uint16x8_t v = vld1q_u16(s + i);
            vst1q_f32(out + i + 0, vcvtq_f32_u32(vmovl_u16(vget_low_u16(v))));
            vst1q_f32(out + i + 4, vcvtq_f32_u32(vmovl_u16(vget_high_u16(v))));
        }
        for (; i < n; i++) out[i] = (float)s[i];
    }
}

static void h_resample_row(const float *f, int32_t cn, int32_t dw,
                           const int32_t *x_off, const int32_t *x_idx, const float *x_w, int32_t x_fixed_k,
                           float *out) {
    if (x_fixed_k == 2) {
        if (cn == 1) {
            for (int32_t dx = 0; dx < dw; dx++) {
                out[dx] = f[x_idx[dx * 2]] * x_w[dx * 2] + f[x_idx[dx * 2 + 1]] * x_w[dx * 2 + 1];
            }
        } else if (cn == 3) {
            for (int32_t dx = 0; dx < dw; dx++) {
                const float *p0 = f + x_idx[dx * 2] * 3, *p1 = f + x_idx[dx * 2 + 1] * 3;
                float w0 = x_w[dx * 2], w1 = x_w[dx * 2 + 1];
                out[dx * 3 + 0] = p0[0] * w0 + p1[0] * w1;
                out[dx * 3 + 1] = p0[1] * w0 + p1[1] * w1;
                out[dx * 3 + 2] = p0[2] * w0 + p1[2] * w1;
            }
        } else if (cn == 4) {
            for (int32_t dx = 0; dx < dw; dx++) {
                float32x4_t s = vfmaq_f32(vmulq_n_f32(vld1q_f32(f + x_idx[dx * 2] * 4), x_w[dx * 2]),
                                          vld1q_f32(f + x_idx[dx * 2 + 1] * 4), vdupq_n_f32(x_w[dx * 2 + 1]));
                vst1q_f32(out + dx * 4, s);
            }
        } else {
            for (int32_t dx = 0; dx < dw; dx++) {
                const float *p0 = f + x_idx[dx * 2] * cn, *p1 = f + x_idx[dx * 2 + 1] * cn;
                float w0 = x_w[dx * 2], w1 = x_w[dx * 2 + 1];
                for (int32_t c = 0; c < cn; c++) out[dx * cn + c] = p0[c] * w0 + p1[c] * w1;
            }
        }
    } else if (x_fixed_k == 4) {
        if (cn == 1) {
            for (int32_t dx = 0; dx < dw; dx++) {
                const int32_t *ix = x_idx + dx * 4; const float *wk = x_w + dx * 4;
                out[dx] = f[ix[0]] * wk[0] + f[ix[1]] * wk[1] + f[ix[2]] * wk[2] + f[ix[3]] * wk[3];
            }
        } else if (cn == 3) {
            for (int32_t dx = 0; dx < dw; dx++) {
                const int32_t *ix = x_idx + dx * 4; const float *wk = x_w + dx * 4;
                const float *p0 = f + ix[0]*3, *p1 = f + ix[1]*3, *p2 = f + ix[2]*3, *p3 = f + ix[3]*3;
                out[dx*3+0] = p0[0]*wk[0] + p1[0]*wk[1] + p2[0]*wk[2] + p3[0]*wk[3];
                out[dx*3+1] = p0[1]*wk[0] + p1[1]*wk[1] + p2[1]*wk[2] + p3[1]*wk[3];
                out[dx*3+2] = p0[2]*wk[0] + p1[2]*wk[1] + p2[2]*wk[2] + p3[2]*wk[3];
            }
        } else if (cn == 4) {
            for (int32_t dx = 0; dx < dw; dx++) {
                const int32_t *ix = x_idx + dx * 4; const float *wk = x_w + dx * 4;
                float32x4_t s = vmulq_n_f32(vld1q_f32(f + ix[0] * 4), wk[0]);
                s = vfmaq_f32(s, vld1q_f32(f + ix[1] * 4), vdupq_n_f32(wk[1]));
                s = vfmaq_f32(s, vld1q_f32(f + ix[2] * 4), vdupq_n_f32(wk[2]));
                s = vfmaq_f32(s, vld1q_f32(f + ix[3] * 4), vdupq_n_f32(wk[3]));
                vst1q_f32(out + dx * 4, s);
            }
        } else {
            for (int32_t dx = 0; dx < dw; dx++) {
                for (int32_t c = 0; c < cn; c++) {
                    float s = 0;
                    for (int32_t k = 0; k < 4; k++) s += x_w[dx * 4 + k] * f[x_idx[dx * 4 + k] * cn + c];
                    out[dx * cn + c] = s;
                }
            }
        }
    } else if (x_fixed_k > 0) {
        for (int32_t dx = 0; dx < dw; dx++) {
            const int32_t *ix = x_idx + dx * x_fixed_k; const float *wk = x_w + dx * x_fixed_k;
            for (int32_t c = 0; c < cn; c++) {
                float s = 0;
                for (int32_t k = 0; k < x_fixed_k; k++) s += wk[k] * f[ix[k] * cn + c];
                out[dx * cn + c] = s;
            }
        }
    } else {
        if (cn == 1) {
            for (int32_t dx = 0; dx < dw; dx++) {
                float s = 0;
                for (int32_t k = x_off[dx]; k < x_off[dx + 1]; k++) s += x_w[k] * f[x_idx[k]];
                out[dx] = s;
            }
        } else if (cn == 3) {
            for (int32_t dx = 0; dx < dw; dx++) {
                float s0 = 0, s1 = 0, s2 = 0;
                for (int32_t k = x_off[dx]; k < x_off[dx + 1]; k++) {
                    const float *p = f + x_idx[k] * 3; float wk = x_w[k];
                    s0 += wk * p[0]; s1 += wk * p[1]; s2 += wk * p[2];
                }
                out[dx * 3 + 0] = s0; out[dx * 3 + 1] = s1; out[dx * 3 + 2] = s2;
            }
        } else if (cn == 4) {
            for (int32_t dx = 0; dx < dw; dx++) {
                float32x4_t s = vdupq_n_f32(0.0f);
                for (int32_t k = x_off[dx]; k < x_off[dx + 1]; k++) {
                    s = vfmaq_f32(s, vld1q_f32(f + x_idx[k] * 4), vdupq_n_f32(x_w[k]));
                }
                vst1q_f32(out + dx * 4, s);
            }
        } else {
            for (int32_t dx = 0; dx < dw; dx++) {
                for (int32_t c = 0; c < cn; c++) {
                    float s = 0;
                    for (int32_t k = x_off[dx]; k < x_off[dx + 1]; k++) s += x_w[k] * f[x_idx[k] * cn + c];
                    out[dx * cn + c] = s;
                }
            }
        }
    }
}

static void v_combine_f32_neon(const float *const *rows, const float *wk, int32_t ntaps, float *out, int32_t n_padded) {
    if (ntaps == 2) {
        const float *r0 = rows[0], *r1 = rows[1];
        float32x4_t w0 = vdupq_n_f32(wk[0]), w1 = vdupq_n_f32(wk[1]);
        for (int32_t i = 0; i < n_padded; i += 16) {
            for (int k = 0; k < 16; k += 4) {
                vst1q_f32(out + i + k, vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i + k), w0), vld1q_f32(r1 + i + k), w1));
            }
        }
        return;
    }
    if (ntaps == 4) {
        const float *r0 = rows[0], *r1 = rows[1], *r2 = rows[2], *r3 = rows[3];
        float32x4_t w0 = vdupq_n_f32(wk[0]), w1 = vdupq_n_f32(wk[1]), w2 = vdupq_n_f32(wk[2]), w3 = vdupq_n_f32(wk[3]);
        for (int32_t i = 0; i < n_padded; i += 16) {
            for (int k = 0; k < 16; k += 4) {
                float32x4_t s = vmulq_f32(vld1q_f32(r0 + i + k), w0);
                s = vfmaq_f32(s, vld1q_f32(r1 + i + k), w1);
                s = vfmaq_f32(s, vld1q_f32(r2 + i + k), w2);
                s = vfmaq_f32(s, vld1q_f32(r3 + i + k), w3);
                vst1q_f32(out + i + k, s);
            }
        }
        return;
    }
    for (int32_t i = 0; i < n_padded; i += 16) {
        float32x4_t a0 = vdupq_n_f32(0), a1 = a0, a2 = a0, a3 = a0;
        for (int32_t j = 0; j < ntaps; j++) {
            float32x4_t wv = vdupq_n_f32(wk[j]);
            const float *p = rows[j] + i;
            a0 = vfmaq_f32(a0, vld1q_f32(p + 0), wv);
            a1 = vfmaq_f32(a1, vld1q_f32(p + 4), wv);
            a2 = vfmaq_f32(a2, vld1q_f32(p + 8), wv);
            a3 = vfmaq_f32(a3, vld1q_f32(p + 12), wv);
        }
        vst1q_f32(out + i + 0, a0);
        vst1q_f32(out + i + 4, a1);
        vst1q_f32(out + i + 8, a2);
        vst1q_f32(out + i + 12, a3);
    }
}

int32_t sr_c_resize_taps(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                         void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                         int32_t cn, int32_t depth,
                         const int32_t *x_off, const int32_t *x_idx, const float *x_w, int32_t x_fixed_k,
                         const int32_t *y_off, const int32_t *y_idx, const float *y_w) {
    if (!src || !dst || !x_idx || !x_w || !y_off || !y_idx || !y_w || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || cn <= 0)
        return -1;
    const int32_t n = dw * cn;
    const int32_t nP = (n + 15) & ~15;
    int32_t max_taps = 2;
    for (int32_t y = 0; y < dh; y++) {
        int32_t cnt = y_off[y + 1] - y_off[y];
        if (cnt > max_taps) max_taps = cnt;
    }
    int32_t slots = sr_next_pow2(max_taps < 4 ? 4 : max_taps);
    float *cache = (float *)calloc((size_t)slots * (size_t)nP + 16, sizeof(float));
    float *acc = (float *)calloc((size_t)nP + 16, sizeof(float));
    float *fbuf = depth == SR_PERF_DEPTH_F32 ? NULL : (float *)malloc(sizeof(float) * (size_t)sw * (size_t)cn);
    int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
    const float **rpts = (const float **)malloc(sizeof(float *) * (size_t)max_taps);
    if (!cache || !acc || !keys || !rpts || (depth != SR_PERF_DEPTH_F32 && !fbuf)) {
        free(cache); free(acc); free(fbuf); free(keys); free(rpts);
        return -1;
    }
    for (int32_t i = 0; i < slots; i++) keys[i] = -1;

    for (int32_t y = 0; y < dh; y++) {
        int32_t t0 = y_off[y], t1 = y_off[y + 1];
        int32_t nt = t1 - t0;
        for (int32_t t = 0; t < nt; t++) {
            int32_t sy = y_idx[t0 + t];
            int32_t slot = sy & (slots - 1);
            float *row = cache + (size_t)slot * nP;
            if (keys[slot] != sy) {
                const void *sr = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                const float *fp;
                if (depth == SR_PERF_DEPTH_F32) {
                    fp = (const float *)sr;
                } else {
                    load_row_to_float_neon(sr, sw * cn, depth, fbuf);
                    fp = fbuf;
                }
                h_resample_row(fp, cn, dw, x_off, x_idx, x_w, x_fixed_k, row);
                keys[slot] = sy;
            }
            rpts[t] = row;
        }
        v_combine_f32_neon(rpts, y_w + t0, nt, acc, nP);
        store_float_row_neon(acc, (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes, n, depth);
    }

    free(cache); free(acc); free(fbuf); free(keys); free(rpts);
    return 0;
}

void sr_c_area_half_f32(const float *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                         float *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh, int32_t cn) {
    (void)sw; (void)sh;
    const float32x4_t v025 = vdupq_n_f32(0.25f);
    for (int32_t y = 0; y < dh; y++) {
        const float *a = (const float *)((const uint8_t *)src + (ptrdiff_t)(2 * y) * sstep_bytes);
        const float *b = (const float *)((const uint8_t *)src + (ptrdiff_t)(2 * y + 1) * sstep_bytes);
        float *o = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
        int32_t x = 0;
        if (cn == 1) {
            for (; x + 8 <= dw; x += 8) {
                float32x4x2_t a0 = vld2q_f32(a + x * 2), a1 = vld2q_f32(a + x * 2 + 8);
                float32x4x2_t b0 = vld2q_f32(b + x * 2), b1 = vld2q_f32(b + x * 2 + 8);
                vst1q_f32(o + x,     vmulq_f32(vaddq_f32(vaddq_f32(a0.val[0], a0.val[1]), vaddq_f32(b0.val[0], b0.val[1])), v025));
                vst1q_f32(o + x + 4, vmulq_f32(vaddq_f32(vaddq_f32(a1.val[0], a1.val[1]), vaddq_f32(b1.val[0], b1.val[1])), v025));
            }
            for (; x + 4 <= dw; x += 4) {
                float32x4x2_t a0 = vld2q_f32(a + x * 2);
                float32x4x2_t b0 = vld2q_f32(b + x * 2);
                vst1q_f32(o + x, vmulq_f32(vaddq_f32(vaddq_f32(a0.val[0], a0.val[1]), vaddq_f32(b0.val[0], b0.val[1])), v025));
            }
        } else if (cn == 3) {
            for (; x + 4 <= dw; x += 4) {
                const float *ap = a + (ptrdiff_t)x * 6, *bp = b + (ptrdiff_t)x * 6;
                float32x4x3_t pa0 = vld3q_f32(ap),     pb0 = vld3q_f32(bp);
                float32x4x3_t pa1 = vld3q_f32(ap + 12), pb1 = vld3q_f32(bp + 12);
                float32x4x3_t out;
                out.val[0] = vmulq_f32(vpaddq_f32(vaddq_f32(pa0.val[0], pb0.val[0]), vaddq_f32(pa1.val[0], pb1.val[0])), v025);
                out.val[1] = vmulq_f32(vpaddq_f32(vaddq_f32(pa0.val[1], pb0.val[1]), vaddq_f32(pa1.val[1], pb1.val[1])), v025);
                out.val[2] = vmulq_f32(vpaddq_f32(vaddq_f32(pa0.val[2], pb0.val[2]), vaddq_f32(pa1.val[2], pb1.val[2])), v025);
                vst3q_f32(o + (ptrdiff_t)x * 3, out);
            }
        } else if (cn == 4) {
            for (; x < dw; x++) {
                const float *ap = a + (ptrdiff_t)x * 8, *bp = b + (ptrdiff_t)x * 8;
                float32x4_t s = vaddq_f32(vaddq_f32(vld1q_f32(ap), vld1q_f32(ap + 4)),
                                          vaddq_f32(vld1q_f32(bp), vld1q_f32(bp + 4)));
                vst1q_f32(o + (ptrdiff_t)x * 4, vmulq_f32(s, v025));
            }
        }
        for (; x < dw; x++) {
            for (int32_t c = 0; c < cn; c++) {
                int32_t i = x * 2 * cn + c;
                o[x * cn + c] = (a[i] + a[i + cn] + b[i] + b[i + cn]) * 0.25f;
            }
        }
    }
}

int32_t sr_c_resize_linear_fast(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                                void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                                int32_t cn, int32_t depth, double scale_x, double scale_y) {
    if (!src || !dst || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || cn <= 0) return -1;
    if (depth != SR_PERF_DEPTH_U8 && depth != SR_PERF_DEPTH_F32) return -1;

    const int32_t n = dw * cn;
    const int32_t nP = (n + 15) & ~15;

    // Zero heap alloc for common widths up to 2048 and row elements up to 4096!
    int32_t st_i0[2048], st_i1[2048];
    float st_w0[2048], st_w1[2048];
    float st_rows[8192 + 32];

    int32_t *xi0 = st_i0, *xi1 = st_i1;
    float *xw0 = st_w0, *xw1 = st_w1;
    float *rows_buf = st_rows;
    int heap_taps = (dw > 2048);
    int heap_rows = (nP > 4096);
    if (heap_taps) {
        xi0 = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
        xi1 = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
        xw0 = (float *)malloc(sizeof(float) * (size_t)dw);
        xw1 = (float *)malloc(sizeof(float) * (size_t)dw);
        if (!xi0 || !xi1 || !xw0 || !xw1) {
            free(xi0); free(xi1); free(xw0); free(xw1); return -1;
        }
    }
    if (heap_rows) {
        rows_buf = (float *)calloc(2u * (size_t)nP + 16, sizeof(float));
        if (!rows_buf) {
            if (heap_taps) { free(xi0); free(xi1); free(xw0); free(xw1); }
            return -1;
        }
    } else {
        // Ensure zero padding lanes in [n .. nP) for valgrind/ASan cleanly
        memset(rows_buf + n, 0, sizeof(float) * (size_t)(nP - n));
        memset(rows_buf + nP + n, 0, sizeof(float) * (size_t)(nP - n));
    }

    for (int32_t d = 0; d < dw; d++) {
        double fx = ((double)d + 0.5) * scale_x - 0.5;
        int32_t sx = (int32_t)floor(fx);
        fx -= (double)sx;
        if (sx < 0) { fx = 0.0; sx = 0; }
        if (sx >= sw - 1) { fx = 0.0; sx = sw - 1; }
        int32_t x1 = (sx + 1 < sw) ? (sx + 1) : (sw - 1);
        xi0[d] = sx * cn;
        xi1[d] = x1 * cn;
        xw0[d] = (float)(1.0 - fx);
        xw1[d] = (float)fx;
    }

    float *row_slots[2] = {rows_buf, rows_buf + nP};
    int32_t keys[2] = {-1, -1};
    const float32x4_t v0 = vdupq_n_f32(0.0f), vh = vdupq_n_f32(0.5f), v255 = vdupq_n_f32(255.0f);

    for (int32_t y = 0; y < dh; y++) {
        double fy = ((double)y + 0.5) * scale_y - 0.5;
        int32_t sy0 = (int32_t)floor(fy);
        fy -= (double)sy0;
        if (sy0 < 0) { fy = 0.0; sy0 = 0; }
        if (sy0 >= sh - 1) { fy = 0.0; sy0 = sh - 1; }
        int32_t sy1 = (sy0 + 1 < sh) ? (sy0 + 1) : (sh - 1);
        float wy0 = (float)(1.0 - fy), wy1 = (float)fy;

        int32_t ys[2] = {sy0, sy1};
        int nt = (sy1 == sy0) ? 1 : 2;
        for (int k = 0; k < nt; k++) {
            int32_t sy = ys[k];
            int slot = sy & 1;
            if (keys[slot] != sy) {
                float *out_r = row_slots[slot];
                if (depth == SR_PERF_DEPTH_U8) {
                    const uint8_t *s = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                    if (cn == 1) {
                        int32_t dx = 0;
                        for (; dx + 4 <= dw; dx += 4) {
                            uint32_t a0 = s[xi0[dx]], a1 = s[xi0[dx+1]], a2 = s[xi0[dx+2]], a3 = s[xi0[dx+3]];
                            uint32_t b0 = s[xi1[dx]], b1 = s[xi1[dx+1]], b2 = s[xi1[dx+2]], b3 = s[xi1[dx+3]];
                            uint32x4_t ua = {a0, a1, a2, a3};
                            uint32x4_t ub = {b0, b1, b2, b3};
                            vst1q_f32(out_r + dx, vfmaq_f32(vmulq_f32(vcvtq_f32_u32(ua), vld1q_f32(xw0 + dx)),
                                                            vcvtq_f32_u32(ub), vld1q_f32(xw1 + dx)));
                        }
                        for (; dx < dw; dx++) out_r[dx] = (float)s[xi0[dx]] * xw0[dx] + (float)s[xi1[dx]] * xw1[dx];
                    } else if (cn == 3) {
                        for (int32_t dx = 0; dx < dw; dx++) {
                            const uint8_t *p0 = s + xi0[dx], *p1 = s + xi1[dx];
                            float w0 = xw0[dx], w1 = xw1[dx];
                            out_r[dx * 3 + 0] = (float)p0[0] * w0 + (float)p1[0] * w1;
                            out_r[dx * 3 + 1] = (float)p0[1] * w0 + (float)p1[1] * w1;
                            out_r[dx * 3 + 2] = (float)p0[2] * w0 + (float)p1[2] * w1;
                        }
                    } else if (cn == 4) {
                        for (int32_t dx = 0; dx < dw; dx++) {
                            const uint8_t *p0 = s + xi0[dx], *p1 = s + xi1[dx];
                            float w0 = xw0[dx], w1 = xw1[dx];
                            for (int c = 0; c < 4; c++) out_r[dx * 4 + c] = (float)p0[c] * w0 + (float)p1[c] * w1;
                        }
                    } else {
                        for (int32_t dx = 0; dx < dw; dx++) {
                            const uint8_t *p0 = s + xi0[dx], *p1 = s + xi1[dx];
                            float w0 = xw0[dx], w1 = xw1[dx];
                            for (int32_t c = 0; c < cn; c++) out_r[dx * cn + c] = (float)p0[c] * w0 + (float)p1[c] * w1;
                        }
                    }
                } else {
                    const float *s = (const float *)((const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes);
                    if (cn == 1) {
                        int32_t dx = 0;
                        for (; dx + 4 <= dw; dx += 4) {
                            float32x4_t fa = {s[xi0[dx]], s[xi0[dx+1]], s[xi0[dx+2]], s[xi0[dx+3]]};
                            float32x4_t fb = {s[xi1[dx]], s[xi1[dx+1]], s[xi1[dx+2]], s[xi1[dx+3]]};
                            vst1q_f32(out_r + dx, vfmaq_f32(vmulq_f32(fa, vld1q_f32(xw0 + dx)), fb, vld1q_f32(xw1 + dx)));
                        }
                        for (; dx < dw; dx++) out_r[dx] = s[xi0[dx]] * xw0[dx] + s[xi1[dx]] * xw1[dx];
                    } else if (cn == 3) {
                        for (int32_t dx = 0; dx < dw; dx++) {
                            const float *p0 = s + xi0[dx], *p1 = s + xi1[dx];
                            float w0 = xw0[dx], w1 = xw1[dx];
                            out_r[dx * 3 + 0] = p0[0] * w0 + p1[0] * w1;
                            out_r[dx * 3 + 1] = p0[1] * w0 + p1[1] * w1;
                            out_r[dx * 3 + 2] = p0[2] * w0 + p1[2] * w1;
                        }
                    } else if (cn == 4) {
                        for (int32_t dx = 0; dx < dw; dx++) {
                            float32x4_t a = vld1q_f32(s + xi0[dx]), b = vld1q_f32(s + xi1[dx]);
                            vst1q_f32(out_r + dx * 4, vfmaq_f32(vmulq_n_f32(a, xw0[dx]), b, vdupq_n_f32(xw1[dx])));
                        }
                    } else {
                        for (int32_t dx = 0; dx < dw; dx++) {
                            const float *p0 = s + xi0[dx], *p1 = s + xi1[dx];
                            float w0 = xw0[dx], w1 = xw1[dx];
                            for (int32_t c = 0; c < cn; c++) out_r[dx * cn + c] = p0[c] * w0 + p1[c] * w1;
                        }
                    }
                }
                keys[slot] = sy;
            }
        }

        const float *r0 = row_slots[sy0 & 1];
        const float *r1 = row_slots[sy1 & 1];
        void *dr = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
        if (depth == SR_PERF_DEPTH_U8) {
            uint8_t *d = (uint8_t *)dr;
            float32x4_t vy0 = vdupq_n_f32(wy0), vy1 = vdupq_n_f32(wy1);
            int32_t i = 0;
            for (; i + 16 <= n; i += 16) {
                float32x4_t f0 = vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i), vy0), vld1q_f32(r1 + i), vy1);
                float32x4_t f1 = vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i + 4), vy0), vld1q_f32(r1 + i + 4), vy1);
                float32x4_t f2 = vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i + 8), vy0), vld1q_f32(r1 + i + 8), vy1);
                float32x4_t f3 = vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i + 12), vy0), vld1q_f32(r1 + i + 12), vy1);
                uint32x4_t a0 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(f0, vh), v0), v255));
                uint32x4_t a1 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(f1, vh), v0), v255));
                uint32x4_t a2 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(f2, vh), v0), v255));
                uint32x4_t a3 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(f3, vh), v0), v255));
                uint16x8_t q0 = vcombine_u16(vmovn_u32(a0), vmovn_u32(a1));
                uint16x8_t q1 = vcombine_u16(vmovn_u32(a2), vmovn_u32(a3));
                vst1q_u8(d + i, vcombine_u8(vmovn_u16(q0), vmovn_u16(q1)));
            }
            for (; i < n; i++) d[i] = sr_sat_u8_f32(r0[i] * wy0 + r1[i] * wy1);
        } else {
            float *d = (float *)dr;
            float32x4_t vy0 = vdupq_n_f32(wy0), vy1 = vdupq_n_f32(wy1);
            int32_t i = 0;
            for (; i + 16 <= n; i += 16) {
                vst1q_f32(d + i,      vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i), vy0),      vld1q_f32(r1 + i), vy1));
                vst1q_f32(d + i + 4,  vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i + 4), vy0),  vld1q_f32(r1 + i + 4), vy1));
                vst1q_f32(d + i + 8,  vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i + 8), vy0),  vld1q_f32(r1 + i + 8), vy1));
                vst1q_f32(d + i + 12, vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i + 12), vy0), vld1q_f32(r1 + i + 12), vy1));
            }
            for (; i + 4 <= n; i += 4) vst1q_f32(d + i, vfmaq_f32(vmulq_f32(vld1q_f32(r0 + i), vy0), vld1q_f32(r1 + i), vy1));
            for (; i < n; i++) d[i] = r0[i] * wy0 + r1[i] * wy1;
        }
    }

    if (heap_taps) { free(xi0); free(xi1); free(xw0); free(xw1); }
    if (heap_rows) free(rows_buf);
    return 0;
}

#define SR_AB_BITS 10
#define SR_AB_SCALE (1 << SR_AB_BITS)
#define SR_INTER_BITS 5
#define SR_INTER_TAB (1 << SR_INTER_BITS)

typedef struct {
    float cub[SR_INTER_TAB][4];
    float lan[SR_INTER_TAB][8];
} warp_tabs_t;

static void init_cubic_weights_f(float x, float w[4]) {
    const float a = -0.75f;
    w[0] = ((a * (x + 1.0f) - 5.0f * a) * (x + 1.0f) + 8.0f * a) * (x + 1.0f) - 4.0f * a;
    w[1] = ((a + 2.0f) * x - (a + 3.0f)) * x * x + 1.0f;
    float u = 1.0f - x;
    w[2] = ((a + 2.0f) * u - (a + 3.0f)) * u * u + 1.0f;
    w[3] = 1.0f - w[0] - w[1] - w[2];
}

static inline void init_cubic_weights_4f(float32x4_t x, float32x4_t *w0, float32x4_t *w1, float32x4_t *w2, float32x4_t *w3) {
    const float32x4_t va = vdupq_n_f32(-0.75f), v5a = vdupq_n_f32(-3.75f), v8a = vdupq_n_f32(-6.0f), v4a = vdupq_n_f32(-3.0f);
    const float32x4_t vap2 = vdupq_n_f32(1.25f), vap3 = vdupq_n_f32(2.25f), v1 = vdupq_n_f32(1.0f);
    float32x4_t xp1 = vaddq_f32(x, v1), u = vsubq_f32(v1, x);
    *w0 = vsubq_f32(vmulq_f32(vaddq_f32(vmulq_f32(vsubq_f32(vmulq_f32(va, xp1), v5a), xp1), v8a), xp1), v4a);
    *w1 = vaddq_f32(vmulq_f32(vmulq_f32(vsubq_f32(vmulq_f32(vap2, x), vap3), x), x), v1);
    *w2 = vaddq_f32(vmulq_f32(vmulq_f32(vsubq_f32(vmulq_f32(vap2, u), vap3), u), u), v1);
    *w3 = vsubq_f32(vsubq_f32(vsubq_f32(v1, *w0), *w1), *w2);
}

static void init_lanczos4_weights(double x, float w[8]) {
    if (x < (double)FLT_EPSILON) {
        for (int i = 0; i < 8; i++) w[i] = 0.0f;
        w[3] = 1.0f;
        return;
    }
    static const double cs[8][2] = {
        {1, 0}, {-0.70710678118654752440084436210485, -0.70710678118654752440084436210485},
        {0, 1}, {0.70710678118654752440084436210485, -0.70710678118654752440084436210485},
        {-1, 0}, {0.70710678118654752440084436210485, 0.70710678118654752440084436210485},
        {0, -1}, {-0.70710678118654752440084436210485, 0.70710678118654752440084436210485}
    };
    const double pi = 3.14159265358979323846;
    double y0 = -(x + 3.0) * pi * 0.25;
    double s0 = sin(y0), c0 = cos(y0);
    float sum = 0.0f;
    for (int i = 0; i < 8; i++) {
        double y = -(x + 3.0 - (double)i) * pi * 0.25;
        w[i] = (float)((cs[i][0] * s0 + cs[i][1] * c0) / (y * y));
        sum += w[i];
    }
    float inv = 1.0f / sum;
    for (int i = 0; i < 8; i++) w[i] *= inv;
}

static warp_tabs_t g_warp_tabs;
static pthread_once_t g_cub_once = PTHREAD_ONCE_INIT;
static pthread_once_t g_lan_once = PTHREAD_ONCE_INIT;

static void init_cub_once_fn(void) {
    for (int i = 0; i < SR_INTER_TAB; i++) init_cubic_weights_f((float)i * (1.0f / (float)SR_INTER_TAB), g_warp_tabs.cub[i]);
}
static void init_lan_once_fn(void) {
    for (int i = 0; i < SR_INTER_TAB; i++) init_lanczos4_weights((double)i / (double)SR_INTER_TAB, g_warp_tabs.lan[i]);
}
static inline const warp_tabs_t *get_warp_tabs(int interp) {
    if (interp == 2) pthread_once(&g_cub_once, init_cub_once_fn);
    else if (interp >= 4) { pthread_once(&g_cub_once, init_cub_once_fn); pthread_once(&g_lan_once, init_lan_once_fn); }
    return &g_warp_tabs;
}

static inline float tap_elem_f(const void *src, ptrdiff_t sstep_b, int32_t sw, int32_t sh,
                               int32_t cn, int32_t depth, int32_t x, int32_t y, int32_t ch,
                               int32_t border, const float *bv, int *ok) {
    if ((uint32_t)x >= (uint32_t)sw || (uint32_t)y >= (uint32_t)sh) {
        if ((border & 7) == SR_PERF_BORDER_CONSTANT) return bv[ch];
        if ((border & 7) == 5) { *ok = 0; return 0.0f; }
        x = sr_border_interp(x, sw, border);
        y = sr_border_interp(y, sh, border);
        if (x < 0 || y < 0) return bv[ch];
    }
    const void *row = (const uint8_t *)src + (ptrdiff_t)y * sstep_b;
    if (depth == SR_PERF_DEPTH_U8) return (float)((const uint8_t *)row)[x * cn + ch];
    if (depth == SR_PERF_DEPTH_U16) return (float)((const uint16_t *)row)[x * cn + ch];
    return ((const float *)row)[x * cn + ch];
}

static inline void store_pix_f(void *row, int32_t x, int32_t cn, int32_t depth, const float *v) {
    if (depth == SR_PERF_DEPTH_U8) {
        uint8_t *o = (uint8_t *)row + (ptrdiff_t)x * cn;
        for (int32_t k = 0; k < cn; k++) o[k] = sr_sat_u8_f32(v[k]);
    } else if (depth == SR_PERF_DEPTH_U16) {
        uint16_t *o = (uint16_t *)row + (ptrdiff_t)x * cn;
        for (int32_t k = 0; k < cn; k++) o[k] = sr_sat_u16_f32(v[k]);
    } else {
        float *o = (float *)row + (ptrdiff_t)x * cn;
        for (int32_t k = 0; k < cn; k++) o[k] = v[k];
    }
}

// Border-aware slow sample for integer fixed-point grid (u8/u16)
static void warp_slow_fixed(const void *src, ptrdiff_t sstep_b, int32_t sw, int32_t sh, int32_t cn, int32_t depth,
                            int32_t sx, int32_t sy, int32_t fx, int32_t fy, int32_t interp, int32_t border,
                            const float *bv, const warp_tabs_t *tab, void *drow, int32_t dx) {
    if (interp == 0) {
        if ((uint32_t)sx >= (uint32_t)sw || (uint32_t)sy >= (uint32_t)sh) {
            if ((border & 7) == 5) return;
            if ((border & 7) == SR_PERF_BORDER_CONSTANT) { store_pix_f(drow, dx, cn, depth, bv); return; }
            sx = sr_border_interp(sx, sw, border); sy = sr_border_interp(sy, sh, border);
            if (sx < 0 || sy < 0) { store_pix_f(drow, dx, cn, depth, bv); return; }
        }
        size_t pb = (size_t)cn * (depth == SR_PERF_DEPTH_U8 ? 1u : 2u);
        memcpy((uint8_t *)drow + (ptrdiff_t)dx * (ptrdiff_t)pb,
               (const uint8_t *)src + (ptrdiff_t)sy * sstep_b + (ptrdiff_t)sx * (ptrdiff_t)pb, pb);
        return;
    }
    const int K = interp == 1 ? 2 : (interp == 2 ? 4 : 8);
    const int base = K / 2 - 1;
    float wx[8], wy[8];
    if (interp == 1) {
        wx[0] = (float)(32 - fx) * (1.0f / 32.0f); wx[1] = (float)fx * (1.0f / 32.0f);
        wy[0] = (float)(32 - fy) * (1.0f / 32.0f); wy[1] = (float)fy * (1.0f / 32.0f);
    } else if (interp == 2) {
        for (int k = 0; k < 4; k++) { wx[k] = tab->cub[fx][k]; wy[k] = tab->cub[fy][k]; }
    } else {
        for (int k = 0; k < 8; k++) { wx[k] = tab->lan[fx][k]; wy[k] = tab->lan[fy][k]; }
    }
    float out[4] = {0, 0, 0, 0};
    for (int32_t c = 0; c < cn; c++) {
        float acc = 0.0f;
        for (int j = 0; j < K; j++) {
            float rs = 0.0f;
            for (int i = 0; i < K; i++) {
                int ok = 1;
                float tv = tap_elem_f(src, sstep_b, sw, sh, cn, depth, sx - base + i, sy - base + j, c, border, bv, &ok);
                if (!ok) return;
                rs += wx[i] * tv;
            }
            acc += wy[j] * rs;
        }
        out[c] = acc;
    }
    store_pix_f(drow, dx, cn, depth, out);
}

// Continuous-coordinate sample for F32 (fixes INTER_BITS=5 analytic RMSE error vs OpenCV 5.1)
static inline void warp_sample_cont_f32(const float *src, ptrdiff_t sstep_b, int32_t sw, int32_t sh, int32_t cn,
                                        float sx_f, float sy_f, int32_t interp, int32_t border, const float *bv,
                                        float *drow, int32_t dx) {
    if (!isfinite(sx_f) || !isfinite(sy_f) || sx_f < -1e9f || sx_f > 1e9f || sy_f < -1e9f || sy_f > 1e9f) {
        if ((border & 7) == SR_PERF_BORDER_CONSTANT) store_pix_f(drow, dx, cn, SR_PERF_DEPTH_F32, bv);
        return;
    }
    if (interp == 0) {
        int32_t sx = (int32_t)floorf(sx_f + 0.5f);
        int32_t sy = (int32_t)floorf(sy_f + 0.5f);
        if ((uint32_t)sx < (uint32_t)sw && (uint32_t)sy < (uint32_t)sh) {
            const float *p = (const float *)((const uint8_t *)src + (ptrdiff_t)sy * sstep_b) + (ptrdiff_t)sx * cn;
            for (int32_t k = 0; k < cn; k++) drow[(ptrdiff_t)dx * cn + k] = p[k];
            return;
        }
        if ((border & 7) == 5) return;
        if ((border & 7) == SR_PERF_BORDER_CONSTANT) { store_pix_f(drow, dx, cn, SR_PERF_DEPTH_F32, bv); return; }
        sx = sr_border_interp(sx, sw, border); sy = sr_border_interp(sy, sh, border);
        if (sx < 0 || sy < 0) { store_pix_f(drow, dx, cn, SR_PERF_DEPTH_F32, bv); return; }
        const float *p = (const float *)((const uint8_t *)src + (ptrdiff_t)sy * sstep_b) + (ptrdiff_t)sx * cn;
        for (int32_t k = 0; k < cn; k++) drow[(ptrdiff_t)dx * cn + k] = p[k];
        return;
    }
    int32_t ix = (int32_t)floorf(sx_f);
    int32_t iy = (int32_t)floorf(sy_f);
    float fx = sx_f - (float)ix;
    float fy = sy_f - (float)iy;
    if (interp == 1) {
        if ((uint32_t)ix < (uint32_t)(sw - 1) && (uint32_t)iy < (uint32_t)(sh - 1)) {
            const float *p0 = (const float *)((const uint8_t *)src + (ptrdiff_t)iy * sstep_b) + (ptrdiff_t)ix * cn;
            const float *p1 = (const float *)((const uint8_t *)src + (ptrdiff_t)(iy + 1) * sstep_b) + (ptrdiff_t)ix * cn;
            float a0 = 1.0f - fx, b0 = 1.0f - fy;
            float *op = drow + (ptrdiff_t)dx * cn;
            if (cn == 1) {
                op[0] = (p0[0] * a0 + p0[1] * fx) * b0 + (p1[0] * a0 + p1[1] * fx) * fy;
            } else if (cn == 3) {
                op[0] = (p0[0] * a0 + p0[3] * fx) * b0 + (p1[0] * a0 + p1[3] * fx) * fy;
                op[1] = (p0[1] * a0 + p0[4] * fx) * b0 + (p1[1] * a0 + p1[4] * fx) * fy;
                op[2] = (p0[2] * a0 + p0[5] * fx) * b0 + (p1[2] * a0 + p1[5] * fx) * fy;
            } else {
                for (int32_t c = 0; c < cn; c++)
                    op[c] = (p0[c] * a0 + p0[c + cn] * fx) * b0 + (p1[c] * a0 + p1[c + cn] * fx) * fy;
            }
            return;
        }
        float wx[2] = {1.0f - fx, fx}, wy[2] = {1.0f - fy, fy};
        float out[4] = {0, 0, 0, 0};
        for (int32_t c = 0; c < cn; c++) {
            float acc = 0.0f;
            for (int j = 0; j < 2; j++) {
                float rs = 0.0f;
                for (int i = 0; i < 2; i++) {
                    int ok = 1;
                    float tv = tap_elem_f(src, sstep_b, sw, sh, cn, SR_PERF_DEPTH_F32, ix + i, iy + j, c, border, bv, &ok);
                    if (!ok) return;
                    rs += wx[i] * tv;
                }
                acc += wy[j] * rs;
            }
            out[c] = acc;
        }
        store_pix_f(drow, dx, cn, SR_PERF_DEPTH_F32, out);
        return;
    }
    const int K = interp == 2 ? 4 : 8;
    const int base = K / 2 - 1;
    float wx[8], wy[8];
    if (interp == 2) {
        init_cubic_weights_f(fx, wx);
        init_cubic_weights_f(fy, wy);
    } else {
        init_lanczos4_weights((double)fx, wx);
        init_lanczos4_weights((double)fy, wy);
    }
    if (ix >= base && ix + K - 1 - base < sw && iy >= base && iy + K - 1 - base < sh) {
        float *op = drow + (ptrdiff_t)dx * cn;
        if (cn == 1 && K == 4) {
            float acc = 0.0f;
            for (int j = 0; j < 4; j++) {
                const float *r = (const float *)((const uint8_t *)src + (ptrdiff_t)(iy - 1 + j) * sstep_b) + (ix - 1);
                acc += wy[j] * (r[0] * wx[0] + r[1] * wx[1] + r[2] * wx[2] + r[3] * wx[3]);
            }
            op[0] = acc;
            return;
        }
        for (int32_t c = 0; c < cn; c++) {
            float acc = 0.0f;
            for (int j = 0; j < K; j++) {
                const float *r = (const float *)((const uint8_t *)src + (ptrdiff_t)(iy - base + j) * sstep_b) + (ptrdiff_t)(ix - base) * cn + c;
                float rs = 0.0f;
                for (int i = 0; i < K; i++) rs += wx[i] * r[(ptrdiff_t)i * cn];
                acc += wy[j] * rs;
            }
            op[c] = acc;
        }
        return;
    }
    float out[4] = {0, 0, 0, 0};
    for (int32_t c = 0; c < cn; c++) {
        float acc = 0.0f;
        for (int j = 0; j < K; j++) {
            float rs = 0.0f;
            for (int i = 0; i < K; i++) {
                int ok = 1;
                float tv = tap_elem_f(src, sstep_b, sw, sh, cn, SR_PERF_DEPTH_F32, ix - base + i, iy - base + j, c, border, bv, &ok);
                if (!ok) return;
                rs += wx[i] * tv;
            }
            acc += wy[j] * rs;
        }
        out[c] = acc;
    }
    store_pix_f(drow, dx, cn, SR_PERF_DEPTH_F32, out);
}

static void warp_sample_row_fixed(const void *src, ptrdiff_t sstep_b, int32_t sw, int32_t sh, int32_t cn, int32_t depth,
                                  const int32_t *X, const int32_t *Y, int32_t dw, int32_t interp, int32_t border,
                                  const float *bv, const warp_tabs_t *tab, void *drow) {
    if (interp == 0) {
        size_t pb = (size_t)cn * (depth == SR_PERF_DEPTH_U8 ? 1u : 2u);
        for (int32_t x = 0; x < dw; x++) {
            int32_t sx = X[x], sy = Y[x];
            if ((uint32_t)sx < (uint32_t)sw && (uint32_t)sy < (uint32_t)sh) {
                memcpy((uint8_t *)drow + (ptrdiff_t)x * (ptrdiff_t)pb,
                       (const uint8_t *)src + (ptrdiff_t)sy * sstep_b + (ptrdiff_t)sx * (ptrdiff_t)pb, pb);
            } else {
                warp_slow_fixed(src, sstep_b, sw, sh, cn, depth, sx, sy, 0, 0, 0, border, bv, tab, drow, x);
            }
        }
        return;
    }
    if (interp == 1) {
        if (depth == SR_PERF_DEPTH_U8 && cn == 3 && sw > 2 && sh > 2) {
            int32_t x = 0;
            const int32_t sw2 = sw - 2, sh2 = sh - 2;
            const int16x4_t v32 = vdup_n_s16(32);
            for (; x + 2 <= dw; x += 2) {
                int32_t xi0 = X[x], yi0 = Y[x];
                int32_t xi1 = X[x + 1], yi1 = Y[x + 1];
                int32_t sx0 = xi0 >> SR_INTER_BITS, sy0 = yi0 >> SR_INTER_BITS;
                int32_t sx1 = xi1 >> SR_INTER_BITS, sy1 = yi1 >> SR_INTER_BITS;
                if ((uint32_t)sx0 < (uint32_t)sw2 && (uint32_t)sy0 < (uint32_t)sh2 &&
                    (uint32_t)sx1 < (uint32_t)sw2 && (uint32_t)sy1 < (uint32_t)sh2) {
                    int32_t fx0 = xi0 & 31, fy0 = yi0 & 31;
                    int32_t fx1 = xi1 & 31, fy1 = yi1 & 31;
                    const uint8_t *p00 = (const uint8_t *)src + (ptrdiff_t)sy0 * sstep_b + (ptrdiff_t)sx0 * 3;
                    const uint8_t *p01 = p00 + sstep_b;
                    const uint8_t *p10 = (const uint8_t *)src + (ptrdiff_t)sy1 * sstep_b + (ptrdiff_t)sx1 * 3;
                    const uint8_t *p11 = p10 + sstep_b;

                    uint32_t w00[2] = {sr_read_u32_unaligned(p00), sr_read_u32_unaligned(p10)};
                    uint32_t w01[2] = {sr_read_u32_unaligned(p00 + 3), sr_read_u32_unaligned(p10 + 3)};
                    uint32_t w10[2] = {sr_read_u32_unaligned(p01), sr_read_u32_unaligned(p11)};
                    uint32_t w11[2] = {sr_read_u32_unaligned(p01 + 3), sr_read_u32_unaligned(p11 + 3)};

                    int16x8_t q00 = vreinterpretq_s16_u16(vmovl_u8(vreinterpret_u8_u32(vld1_u32(w00))));
                    int16x8_t q01 = vreinterpretq_s16_u16(vmovl_u8(vreinterpret_u8_u32(vld1_u32(w01))));
                    int16x8_t q10 = vreinterpretq_s16_u16(vmovl_u8(vreinterpret_u8_u32(vld1_u32(w10))));
                    int16x8_t q11 = vreinterpretq_s16_u16(vmovl_u8(vreinterpret_u8_u32(vld1_u32(w11))));

                    int16_t fxa[8] = {(int16_t)fx0,(int16_t)fx0,(int16_t)fx0,(int16_t)fx0,(int16_t)fx1,(int16_t)fx1,(int16_t)fx1,(int16_t)fx1};
                    int16_t fya[8] = {(int16_t)fy0,(int16_t)fy0,(int16_t)fy0,(int16_t)fy0,(int16_t)fy1,(int16_t)fy1,(int16_t)fy1,(int16_t)fy1};
                    int16x8_t va1 = vld1q_s16(fxa), va0 = vsubq_s16(vdupq_n_s16(32), va1);
                    int16x8_t vb1 = vld1q_s16(fya), vb0 = vsubq_s16(vdupq_n_s16(32), vb1);
                    (void)v32;
                    int16x8_t h0 = vmlaq_s16(vmulq_s16(q00, va0), q01, va1);
                    int16x8_t h1 = vmlaq_s16(vmulq_s16(q10, va0), q11, va1);

                    int32x4_t rlo = vmlal_s16(vmull_s16(vget_low_s16(h0), vget_low_s16(vb0)), vget_low_s16(h1), vget_low_s16(vb1));
                    int32x4_t rhi = vmlal_s16(vmull_s16(vget_high_s16(h0), vget_high_s16(vb0)), vget_high_s16(h1), vget_high_s16(vb1));
                    uint8x8_t res = vmovn_u16(vreinterpretq_u16_s16(vcombine_s16(vrshrn_n_s32(rlo, 10), vrshrn_n_s32(rhi, 10))));
                    uint8_t tmp8[8];
                    vst1_u8(tmp8, res);
                    uint8_t *o = (uint8_t *)drow + (ptrdiff_t)x * 3;
                    o[0] = tmp8[0]; o[1] = tmp8[1]; o[2] = tmp8[2];
                    o[3] = tmp8[4]; o[4] = tmp8[5]; o[5] = tmp8[6];
                    continue;
                }
                warp_slow_fixed(src, sstep_b, sw, sh, 3, depth, sx0, sy0, xi0 & 31, yi0 & 31, 1, border, bv, tab, drow, x);
                warp_slow_fixed(src, sstep_b, sw, sh, 3, depth, sx1, sy1, xi1 & 31, yi1 & 31, 1, border, bv, tab, drow, x + 1);
            }
            for (; x < dw; x++) {
                int32_t xi = X[x], yi = Y[x];
                warp_slow_fixed(src, sstep_b, sw, sh, 3, depth, xi >> SR_INTER_BITS, yi >> SR_INTER_BITS,
                                xi & 31, yi & 31, 1, border, bv, tab, drow, x);
            }
            return;
        }
        for (int32_t x = 0; x < dw; x++) {
            int32_t xi = X[x], yi = Y[x];
            int32_t sx = xi >> SR_INTER_BITS, sy = yi >> SR_INTER_BITS;
            int32_t fx = xi & (SR_INTER_TAB - 1), fy = yi & (SR_INTER_TAB - 1);
            if ((uint32_t)sx < (uint32_t)(sw - 1) && (uint32_t)sy < (uint32_t)(sh - 1)) {
                if (depth == SR_PERF_DEPTH_U8) {
                    const uint8_t *p0 = (const uint8_t *)src + (ptrdiff_t)sy * sstep_b + (ptrdiff_t)sx * cn;
                    const uint8_t *p1 = p0 + sstep_b;
                    int32_t a0 = 32 - fx, a1 = fx, b0 = 32 - fy, b1 = fy;
                    uint8_t *o = (uint8_t *)drow + (ptrdiff_t)x * cn;
                    if (cn == 3) {
                        o[0] = (uint8_t)(((p0[0] * a0 + p0[3] * a1) * b0 + (p1[0] * a0 + p1[3] * a1) * b1 + 512) >> 10);
                        o[1] = (uint8_t)(((p0[1] * a0 + p0[4] * a1) * b0 + (p1[1] * a0 + p1[4] * a1) * b1 + 512) >> 10);
                        o[2] = (uint8_t)(((p0[2] * a0 + p0[5] * a1) * b0 + (p1[2] * a0 + p1[5] * a1) * b1 + 512) >> 10);
                    } else if (cn == 1) {
                        o[0] = (uint8_t)(((p0[0] * a0 + p0[1] * a1) * b0 + (p1[0] * a0 + p1[1] * a1) * b1 + 512) >> 10);
                    } else {
                        for (int32_t c = 0; c < cn; c++)
                            o[c] = (uint8_t)(((p0[c] * a0 + p0[c + cn] * a1) * b0 + (p1[c] * a0 + p1[c + cn] * a1) * b1 + 512) >> 10);
                    }
                } else {
                    const uint16_t *p0 = (const uint16_t *)((const uint8_t *)src + (ptrdiff_t)sy * sstep_b) + (ptrdiff_t)sx * cn;
                    const uint16_t *p1 = (const uint16_t *)((const uint8_t *)src + (ptrdiff_t)(sy + 1) * sstep_b) + (ptrdiff_t)sx * cn;
                    float a0 = (float)(32 - fx) * (1.0f / 32.0f), a1 = (float)fx * (1.0f / 32.0f);
                    float b0 = (float)(32 - fy) * (1.0f / 32.0f), b1 = (float)fy * (1.0f / 32.0f);
                    uint16_t *o = (uint16_t *)drow + (ptrdiff_t)x * cn;
                    for (int32_t c = 0; c < cn; c++) {
                        float v = ((float)p0[c] * a0 + (float)p0[c + cn] * a1) * b0 + ((float)p1[c] * a0 + (float)p1[c + cn] * a1) * b1;
                        o[c] = sr_sat_u16_f32(v);
                    }
                }
            } else {
                warp_slow_fixed(src, sstep_b, sw, sh, cn, depth, sx, sy, fx, fy, 1, border, bv, tab, drow, x);
            }
        }
        return;
    }
    if (interp == 2) {
        static const uint8_t cub_perm[16] = {0,3,6,9, 1,4,7,10, 2,5,8,11, 15,15,15,15};
        const uint8x16_t vperm = vld1q_u8(cub_perm);
        const float32x4_t v0 = vdupq_n_f32(0.0f), vh = vdupq_n_f32(0.5f), v255 = vdupq_n_f32(255.0f);
        for (int32_t x = 0; x < dw; x++) {
            int32_t xi = X[x], yi = Y[x];
            int32_t sx = xi >> SR_INTER_BITS, sy = yi >> SR_INTER_BITS;
            int32_t fx = xi & (SR_INTER_TAB - 1), fy = yi & (SR_INTER_TAB - 1);
            if (sx >= 1 && sx < sw - 2 && sy >= 1 && sy < sh - 2 && depth == SR_PERF_DEPTH_U8) {
                const float *wx = tab->cub[fx], *wy = tab->cub[fy];
                const uint8_t *base0 = (const uint8_t *)src + (ptrdiff_t)(sy - 1) * sstep_b + (ptrdiff_t)(sx - 1) * cn;
                const uint8_t *r0 = base0, *r1 = base0 + sstep_b, *r2 = r1 + sstep_b, *r3 = r2 + sstep_b;
                uint8_t *o = (uint8_t *)drow + (ptrdiff_t)x * cn;
                if (cn == 3) {
                    float32x4_t vwx = vld1q_f32(wx);
                    #define CUB3_ROW(RP, OUTV) do { \
                        uint8_t tmp[16] = {0}; \
                        memcpy(tmp, (RP), 8); memcpy(tmp + 8, (RP) + 8, 4); \
                        uint8x16_t p = vqtbl1q_u8(vld1q_u8(tmp), vperm); \
                        uint16x8_t l = vmovl_u8(vget_low_u8(p)), h = vmovl_u8(vget_high_u8(p)); \
                        float32x4_t f0 = vcvtq_f32_u32(vmovl_u16(vget_low_u16(l))); \
                        float32x4_t f1 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(l))); \
                        float32x4_t f2 = vcvtq_f32_u32(vmovl_u16(vget_low_u16(h))); \
                        float32x4_t m0 = vmulq_f32(f0, vwx), m1 = vmulq_f32(f1, vwx), m2 = vmulq_f32(f2, vwx); \
                        (OUTV) = vpaddq_f32(vpaddq_f32(m0, m1), vpaddq_f32(m2, m2)); \
                    } while (0)
                    float32x4_t c0, c1, c2, c3;
                    CUB3_ROW(r0, c0); CUB3_ROW(r1, c1); CUB3_ROW(r2, c2); CUB3_ROW(r3, c3);
                    #undef CUB3_ROW
                    float32x4_t acc = vfmaq_n_f32(vmulq_n_f32(c0, wy[0]), c1, wy[1]);
                    acc = vfmaq_n_f32(acc, c2, wy[2]);
                    acc = vfmaq_n_f32(acc, c3, wy[3]);
                    uint32x4_t u = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(acc, vh), v0), v255));
                    o[0] = (uint8_t)vgetq_lane_u32(u, 0);
                    o[1] = (uint8_t)vgetq_lane_u32(u, 1);
                    o[2] = (uint8_t)vgetq_lane_u32(u, 2);
                } else {
                    for (int32_t c = 0; c < cn; c++) {
                        float t0 = r0[c]*wx[0] + r0[cn+c]*wx[1] + r0[2*cn+c]*wx[2] + r0[3*cn+c]*wx[3];
                        float t1 = r1[c]*wx[0] + r1[cn+c]*wx[1] + r1[2*cn+c]*wx[2] + r1[3*cn+c]*wx[3];
                        float t2 = r2[c]*wx[0] + r2[cn+c]*wx[1] + r2[2*cn+c]*wx[2] + r2[3*cn+c]*wx[3];
                        float t3 = r3[c]*wx[0] + r3[cn+c]*wx[1] + r3[2*cn+c]*wx[2] + r3[3*cn+c]*wx[3];
                        o[c] = sr_sat_u8_f32(t0 * wy[0] + t1 * wy[1] + t2 * wy[2] + t3 * wy[3]);
                    }
                }
            } else {
                warp_slow_fixed(src, sstep_b, sw, sh, cn, depth, sx, sy, fx, fy, 2, border, bv, tab, drow, x);
            }
        }
        return;
    }
    for (int32_t x = 0; x < dw; x++) {
        int32_t xi = X[x], yi = Y[x];
        warp_slow_fixed(src, sstep_b, sw, sh, cn, depth, xi >> SR_INTER_BITS, yi >> SR_INTER_BITS,
                        xi & (SR_INTER_TAB - 1), yi & (SR_INTER_TAB - 1), 4, border, bv, tab, drow, x);
    }
}

static inline int32_t clamp_ab_coord(double v) {
    if (!(v == v)) return INT32_MIN / 2;
    double r = rint(v);
    if (r > (double)INT32_MAX) return INT32_MAX;
    if (r < (double)INT32_MIN) return INT32_MIN;
    return (int32_t)r;
}

int32_t sr_c_warp_affine(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                         void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                         int32_t cn, int32_t depth, const double *m6,
                         int32_t interp, int32_t border, const double *bval) {
    if (!src || !dst || !m6 || !bval || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return -1;
    float bv[4] = {(float)bval[0], (float)bval[1], (float)bval[2], (float)bval[3]};
    if (depth == SR_PERF_DEPTH_F32) {
        const float *fsrc = (const float *)src;
        const float32x4_t v0 = vdupq_n_f32(0.0f), v1 = vdupq_n_f32(1.0f);
        const float32x4_t vsw_m1 = vdupq_n_f32((float)(sw - 1)), vsh_m1 = vdupq_n_f32((float)(sh - 1));
        const float32x4_t vsw_c = vdupq_n_f32((float)(sw - 2)), vsh_c = vdupq_n_f32((float)(sh - 2));
        const float64x2_t m0v = vdupq_n_f64(m6[0]), m3v = vdupq_n_f64(m6[3]);
        for (int32_t y = 0; y < dh; y++) {
            double bx = m6[1] * (double)y + m6[2];
            double by = m6[4] * (double)y + m6[5];
            float *drow = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
            if (interp == 1 && cn == 1) {
                const float64x2_t bxv = vdupq_n_f64(bx), byv = vdupq_n_f64(by);
                int32_t x = 0;
                for (; x + 4 <= dw; x += 4) {
                    float64x2_t dx0 = {(double)x, (double)(x + 1)}, dx1 = {(double)(x + 2), (double)(x + 3)};
                    float32x4_t vsx = vcombine_f32(vcvt_f32_f64(vfmaq_f64(bxv, m0v, dx0)),
                                                   vcvt_f32_f64(vfmaq_f64(bxv, m0v, dx1)));
                    float32x4_t vsy = vcombine_f32(vcvt_f32_f64(vfmaq_f64(byv, m3v, dx0)),
                                                   vcvt_f32_f64(vfmaq_f64(byv, m3v, dx1)));
                    float32x4_t ix_f = vrndmq_f32(vsx), iy_f = vrndmq_f32(vsy);
                    uint32x4_t inb = vandq_u32(vandq_u32(vcgeq_f32(ix_f, v0), vcltq_f32(ix_f, vsw_m1)),
                                               vandq_u32(vcgeq_f32(iy_f, v0), vcltq_f32(iy_f, vsh_m1)));
                    if (vminvq_u32(inb) != 0) {
                        int32x4_t vix = vcvtq_s32_f32(ix_f), viy = vcvtq_s32_f32(iy_f);
                        float32x4_t fx = vsubq_f32(vsx, ix_f), fy = vsubq_f32(vsy, iy_f);
                        float32x4_t a0 = vsubq_f32(v1, fx), b0 = vsubq_f32(v1, fy);
                        int32_t x0 = vgetq_lane_s32(vix, 0), x1 = vgetq_lane_s32(vix, 1);
                        int32_t x2 = vgetq_lane_s32(vix, 2), x3 = vgetq_lane_s32(vix, 3);
                        int32_t y0 = vgetq_lane_s32(viy, 0), y1 = vgetq_lane_s32(viy, 1);
                        int32_t y2 = vgetq_lane_s32(viy, 2), y3 = vgetq_lane_s32(viy, 3);
                        const float *r00 = (const float *)((const uint8_t *)src + (ptrdiff_t)y0 * sstep_bytes) + x0;
                        const float *r01 = (const float *)((const uint8_t *)src + (ptrdiff_t)y1 * sstep_bytes) + x1;
                        const float *r02 = (const float *)((const uint8_t *)src + (ptrdiff_t)y2 * sstep_bytes) + x2;
                        const float *r03 = (const float *)((const uint8_t *)src + (ptrdiff_t)y3 * sstep_bytes) + x3;
                        const float *r10 = (const float *)((const uint8_t *)src + (ptrdiff_t)(y0 + 1) * sstep_bytes) + x0;
                        const float *r11 = (const float *)((const uint8_t *)src + (ptrdiff_t)(y1 + 1) * sstep_bytes) + x1;
                        const float *r12 = (const float *)((const uint8_t *)src + (ptrdiff_t)(y2 + 1) * sstep_bytes) + x2;
                        const float *r13 = (const float *)((const uint8_t *)src + (ptrdiff_t)(y3 + 1) * sstep_bytes) + x3;
                        float32x4_t p00 = {r00[0], r01[0], r02[0], r03[0]};
                        float32x4_t p01 = {r00[1], r01[1], r02[1], r03[1]};
                        float32x4_t p10 = {r10[0], r11[0], r12[0], r13[0]};
                        float32x4_t p11 = {r10[1], r11[1], r12[1], r13[1]};
                        float32x4_t t0 = vaddq_f32(vmulq_f32(p00, a0), vmulq_f32(p01, fx));
                        float32x4_t t1 = vaddq_f32(vmulq_f32(p10, a0), vmulq_f32(p11, fx));
                        vst1q_f32(drow + x, vaddq_f32(vmulq_f32(t0, b0), vmulq_f32(t1, fy)));
                        continue;
                    }
                    for (int k = 0; k < 4; k++) {
                        float sx = (float)(m6[0] * (double)(x + k) + bx);
                        float sy = (float)(m6[3] * (double)(x + k) + by);
                        warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, 1, sx, sy, 1, border, bv, drow, x + k);
                    }
                }
                for (; x < dw; x++) {
                    float sx = (float)(m6[0] * (double)x + bx);
                    float sy = (float)(m6[3] * (double)x + by);
                    warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, 1, sx, sy, 1, border, bv, drow, x);
                }
            } else if (interp == 2 && cn == 1 && sw >= 4 && sh >= 4) {
                const float64x2_t bxv = vdupq_n_f64(bx), byv = vdupq_n_f64(by);
                int32_t x = 0;
                for (; x + 4 <= dw; x += 4) {
                    float64x2_t dx0 = {(double)x, (double)(x + 1)}, dx1 = {(double)(x + 2), (double)(x + 3)};
                    float32x4_t vsx = vcombine_f32(vcvt_f32_f64(vfmaq_f64(bxv, m0v, dx0)),
                                                   vcvt_f32_f64(vfmaq_f64(bxv, m0v, dx1)));
                    float32x4_t vsy = vcombine_f32(vcvt_f32_f64(vfmaq_f64(byv, m3v, dx0)),
                                                   vcvt_f32_f64(vfmaq_f64(byv, m3v, dx1)));
                    float32x4_t ix_f = vrndmq_f32(vsx), iy_f = vrndmq_f32(vsy);
                    uint32x4_t inb = vandq_u32(vandq_u32(vcgeq_f32(ix_f, v1), vcltq_f32(ix_f, vsw_c)),
                                               vandq_u32(vcgeq_f32(iy_f, v1), vcltq_f32(iy_f, vsh_c)));
                    if (vminvq_u32(inb) != 0) {
                        int32x4_t vix = vcvtq_s32_f32(ix_f), viy = vcvtq_s32_f32(iy_f);
                        float32x4_t fx = vsubq_f32(vsx, ix_f), fy = vsubq_f32(vsy, iy_f);
                        float32x4_t wx0, wx1, wx2, wx3, wy0, wy1, wy2, wy3;
                        init_cubic_weights_4f(fx, &wx0, &wx1, &wx2, &wx3);
                        init_cubic_weights_4f(fy, &wy0, &wy1, &wy2, &wy3);
                        // Transpose 4x4 weights -> wx_row[k] = [wx0[k], wx1[k], wx2[k], wx3[k]]
                        float32x4x2_t ax0 = vtrnq_f32(wx0, wx1), ax1 = vtrnq_f32(wx2, wx3);
                        float32x4_t wxa[4] = {
                            vcombine_f32(vget_low_f32(ax0.val[0]), vget_low_f32(ax1.val[0])),
                            vcombine_f32(vget_low_f32(ax0.val[1]), vget_low_f32(ax1.val[1])),
                            vcombine_f32(vget_high_f32(ax0.val[0]), vget_high_f32(ax1.val[0])),
                            vcombine_f32(vget_high_f32(ax0.val[1]), vget_high_f32(ax1.val[1]))
                        };
                        float wy_buf[16];
                        vst1q_f32(wy_buf + 0, wy0); vst1q_f32(wy_buf + 4, wy1);
                        vst1q_f32(wy_buf + 8, wy2); vst1q_f32(wy_buf + 12, wy3);
                        int32_t ixa[4], iya[4];
                        vst1q_s32(ixa, vix); vst1q_s32(iya, viy);
                        for (int k = 0; k < 4; k++) {
                            const float *b0 = (const float *)((const uint8_t *)src + (ptrdiff_t)(iya[k] - 1) * sstep_bytes) + (ixa[k] - 1);
                            const float *b1 = (const float *)((const uint8_t *)b0 + sstep_bytes);
                            const float *b2 = (const float *)((const uint8_t *)b1 + sstep_bytes);
                            const float *b3 = (const float *)((const uint8_t *)b2 + sstep_bytes);
                            float32x4_t s = vmulq_n_f32(vld1q_f32(b0), wy_buf[0 + k]);
                            s = vfmaq_n_f32(s, vld1q_f32(b1), wy_buf[4 + k]);
                            s = vfmaq_n_f32(s, vld1q_f32(b2), wy_buf[8 + k]);
                            s = vfmaq_n_f32(s, vld1q_f32(b3), wy_buf[12 + k]);
                            drow[x + k] = vaddvq_f32(vmulq_f32(s, wxa[k]));
                        }
                        continue;
                    }
                    for (int k = 0; k < 4; k++) {
                        float sx = (float)(m6[0] * (double)(x + k) + bx);
                        float sy = (float)(m6[3] * (double)(x + k) + by);
                        warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, 1, sx, sy, 2, border, bv, drow, x + k);
                    }
                }
                for (; x < dw; x++) {
                    float sx = (float)(m6[0] * (double)x + bx);
                    float sy = (float)(m6[3] * (double)x + by);
                    warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, 1, sx, sy, 2, border, bv, drow, x);
                }
            } else {
                for (int32_t x = 0; x < dw; x++) {
                    float sx = (float)(m6[0] * (double)x + bx);
                    float sy = (float)(m6[3] * (double)x + by);
                    warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, cn, sx, sy, interp, border, bv, drow, x);
                }
            }
        }
        return 0;
    }

    const warp_tabs_t *tab = get_warp_tabs(interp);
    int32_t *adelta = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    int32_t *bdelta = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    int32_t *X = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    int32_t *Y = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    if (!adelta || !bdelta || !X || !Y) { free(adelta); free(bdelta); free(X); free(Y); return -1; }
    for (int32_t x = 0; x < dw; x++) {
        adelta[x] = clamp_ab_coord(m6[0] * (double)x * (double)SR_AB_SCALE);
        bdelta[x] = clamp_ab_coord(m6[3] * (double)x * (double)SR_AB_SCALE);
    }
    int32_t round_delta = interp == 0 ? (SR_AB_SCALE / 2) : (SR_AB_SCALE / SR_INTER_TAB / 2);
    int shift = interp == 0 ? SR_AB_BITS : (SR_AB_BITS - SR_INTER_BITS);
    for (int32_t y = 0; y < dh; y++) {
        int64_t xb = (int64_t)clamp_ab_coord((m6[1] * (double)y + m6[2]) * (double)SR_AB_SCALE) + round_delta;
        int64_t yb = (int64_t)clamp_ab_coord((m6[4] * (double)y + m6[5]) * (double)SR_AB_SCALE) + round_delta;
        for (int32_t x = 0; x < dw; x++) {
            X[x] = (int32_t)((xb + (int64_t)adelta[x]) >> shift);
            Y[x] = (int32_t)((yb + (int64_t)bdelta[x]) >> shift);
        }
        warp_sample_row_fixed(src, sstep_bytes, sw, sh, cn, depth, X, Y, dw, interp, border, bv, tab,
                              (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
    }
    free(adelta); free(bdelta); free(X); free(Y);
    return 0;
}

int32_t sr_c_warp_perspective(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                              void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                              int32_t cn, int32_t depth, const double *m9,
                              int32_t interp, int32_t border, const double *bval) {
    if (!src || !dst || !m9 || !bval || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return -1;
    float bv[4] = {(float)bval[0], (float)bval[1], (float)bval[2], (float)bval[3]};
    if (depth == SR_PERF_DEPTH_F32) {
        const float *fsrc = (const float *)src;
        for (int32_t y = 0; y < dh; y++) {
            double bx = m9[1] * (double)y + m9[2];
            double by = m9[4] * (double)y + m9[5];
            double bw = m9[7] * (double)y + m9[8];
            float *drow = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
            for (int32_t x = 0; x < dw; x++) {
                double dx = (double)x;
                double w = m9[6] * dx + bw;
                double iw = w != 0.0 ? (1.0 / w) : 0.0;
                float sx = (float)((m9[0] * dx + bx) * iw);
                float sy = (float)((m9[3] * dx + by) * iw);
                warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, cn, sx, sy, interp, border, bv, drow, x);
            }
        }
        return 0;
    }
    const warp_tabs_t *tab = get_warp_tabs(interp);
    int32_t *X = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    int32_t *Y = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    if (!X || !Y) { free(X); free(Y); return -1; }
    double scale = interp == 0 ? 1.0 : (double)SR_INTER_TAB;
    for (int32_t y = 0; y < dh; y++) {
        double bx = m9[1] * (double)y + m9[2];
        double by = m9[4] * (double)y + m9[5];
        double bw = m9[7] * (double)y + m9[8];
        for (int32_t x = 0; x < dw; x++) {
            double dx = (double)x;
            double w = m9[6] * dx + bw;
            double iw = w != 0.0 ? (1.0 / w) : 0.0;
            double sx = (m9[0] * dx + bx) * iw;
            double sy = (m9[3] * dx + by) * iw;
            if (sx < -1e6) sx = -1e6; else if (sx > 1e6) sx = 1e6;
            if (sy < -1e6) sy = -1e6; else if (sy > 1e6) sy = 1e6;
            X[x] = (int32_t)rint(sx * scale);
            Y[x] = (int32_t)rint(sy * scale);
        }
        warp_sample_row_fixed(src, sstep_bytes, sw, sh, cn, depth, X, Y, dw, interp, border, bv, tab,
                              (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
    }
    free(X); free(Y);
    return 0;
}

static inline int32_t fix_remap_coord(float v, float scale) {
    if (!(v == v)) return -(1 << 30);
    float t = v * scale;
    if (t < -1e9f) t = -1e9f; else if (t > 1e9f) t = 1e9f;
    return (int32_t)rintf(t);
}

int32_t sr_c_remap(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                   void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                   int32_t cn, int32_t depth,
                   const float *m1, ptrdiff_t m1_step_bytes, int32_t m1_cn,
                   const float *m2, ptrdiff_t m2_step_bytes,
                   int32_t interp, int32_t border, const double *bval) {
    if (!src || !dst || !m1 || !bval || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0) return -1;
    if (!m2 && m1_cn != 2) return -1;
    float bv[4] = {(float)bval[0], (float)bval[1], (float)bval[2], (float)bval[3]};
    if (depth == SR_PERF_DEPTH_F32) {
        const float *fsrc = (const float *)src;
        const float32x4_t v0 = vdupq_n_f32(0.0f), v1 = vdupq_n_f32(1.0f);
        const float32x4_t vsw_m1 = vdupq_n_f32((float)(sw - 1)), vsh_m1 = vdupq_n_f32((float)(sh - 1));
        for (int32_t y = 0; y < dh; y++) {
            const float *r1 = (const float *)((const uint8_t *)m1 + (ptrdiff_t)y * m1_step_bytes);
            const float *r2 = m2 ? (const float *)((const uint8_t *)m2 + (ptrdiff_t)y * m2_step_bytes) : NULL;
            float *drow = (float *)((uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
            if (interp == 1 && cn == 1) {
                int32_t x = 0;
                for (; x + 4 <= dw; x += 4) {
                    float32x4_t vsx, vsy;
                    if (r2) {
                        vsx = vld1q_f32(r1 + x);
                        vsy = vld1q_f32(r2 + x);
                    } else {
                        float32x4x2_t mp = vld2q_f32(r1 + (ptrdiff_t)x * 2);
                        vsx = mp.val[0];
                        vsy = mp.val[1];
                    }
                    float32x4_t ix_f = vrndmq_f32(vsx), iy_f = vrndmq_f32(vsy);
                    uint32x4_t inb = vandq_u32(vandq_u32(vcgeq_f32(ix_f, v0), vcltq_f32(ix_f, vsw_m1)),
                                               vandq_u32(vcgeq_f32(iy_f, v0), vcltq_f32(iy_f, vsh_m1)));
                    if (vminvq_u32(inb) != 0) {
                        int32x4_t vix = vcvtq_s32_f32(ix_f), viy = vcvtq_s32_f32(iy_f);
                        float32x4_t fx = vsubq_f32(vsx, ix_f), fy = vsubq_f32(vsy, iy_f);
                        float32x4_t a0 = vsubq_f32(v1, fx), b0 = vsubq_f32(v1, fy);
                        int32_t ixa[4], iya[4];
                        vst1q_s32(ixa, vix); vst1q_s32(iya, viy);
                        const float *p00p = (const float *)((const uint8_t *)src + (ptrdiff_t)iya[0] * sstep_bytes) + ixa[0];
                        const float *p01p = (const float *)((const uint8_t *)src + (ptrdiff_t)iya[1] * sstep_bytes) + ixa[1];
                        const float *p02p = (const float *)((const uint8_t *)src + (ptrdiff_t)iya[2] * sstep_bytes) + ixa[2];
                        const float *p03p = (const float *)((const uint8_t *)src + (ptrdiff_t)iya[3] * sstep_bytes) + ixa[3];
                        const float *p10p = (const float *)((const uint8_t *)p00p + sstep_bytes);
                        const float *p11p = (const float *)((const uint8_t *)p01p + sstep_bytes);
                        const float *p12p = (const float *)((const uint8_t *)p02p + sstep_bytes);
                        const float *p13p = (const float *)((const uint8_t *)p03p + sstep_bytes);
                        float32x4_t q00 = {p00p[0], p01p[0], p02p[0], p03p[0]};
                        float32x4_t q01 = {p00p[1], p01p[1], p02p[1], p03p[1]};
                        float32x4_t q10 = {p10p[0], p11p[0], p12p[0], p13p[0]};
                        float32x4_t q11 = {p10p[1], p11p[1], p12p[1], p13p[1]};
                        float32x4_t t0 = vaddq_f32(vmulq_f32(q00, a0), vmulq_f32(q01, fx));
                        float32x4_t t1 = vaddq_f32(vmulq_f32(q10, a0), vmulq_f32(q11, fx));
                        vst1q_f32(drow + x, vaddq_f32(vmulq_f32(t0, b0), vmulq_f32(t1, fy)));
                        continue;
                    }
                    for (int k = 0; k < 4; k++) {
                        float sx = r2 ? r1[x + k] : r1[2 * (x + k)];
                        float sy = r2 ? r2[x + k] : r1[2 * (x + k) + 1];
                        warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, 1, sx, sy, 1, border, bv, drow, x + k);
                    }
                }
                for (; x < dw; x++) {
                    float sx = r2 ? r1[x] : r1[2 * x];
                    float sy = r2 ? r2[x] : r1[2 * x + 1];
                    warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, 1, sx, sy, 1, border, bv, drow, x);
                }
            } else {
                for (int32_t x = 0; x < dw; x++) {
                    float sx = r2 ? r1[x] : r1[2 * x];
                    float sy = r2 ? r2[x] : r1[2 * x + 1];
                    warp_sample_cont_f32(fsrc, sstep_bytes, sw, sh, cn, sx, sy, interp, border, bv, drow, x);
                }
            }
        }
        return 0;
    }
    const warp_tabs_t *tab = get_warp_tabs(interp);
    int32_t *X = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    int32_t *Y = (int32_t *)malloc(sizeof(int32_t) * (size_t)dw);
    if (!X || !Y) { free(X); free(Y); return -1; }
    float scale = interp == 0 ? 1.0f : (float)SR_INTER_TAB;
    for (int32_t y = 0; y < dh; y++) {
        const float *r1 = (const float *)((const uint8_t *)m1 + (ptrdiff_t)y * m1_step_bytes);
        if (m2) {
            const float *r2 = (const float *)((const uint8_t *)m2 + (ptrdiff_t)y * m2_step_bytes);
            for (int32_t x = 0; x < dw; x++) { X[x] = fix_remap_coord(r1[x], scale); Y[x] = fix_remap_coord(r2[x], scale); }
        } else {
            for (int32_t x = 0; x < dw; x++) { X[x] = fix_remap_coord(r1[2 * x], scale); Y[x] = fix_remap_coord(r1[2 * x + 1], scale); }
        }
        warp_sample_row_fixed(src, sstep_bytes, sw, sh, cn, depth, X, Y, dw, interp, border, bv, tab,
                              (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes);
    }
    free(X); free(Y);
    return 0;
}
