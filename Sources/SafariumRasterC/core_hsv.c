// SafariumRasterC — BGR/RGB(A) -> HSV for 8-bit rows (OpenCV 5.1 RGB2HSV_b, hrange 180). See include/sr_core.h.
// NEON computes V, V - min and the hue numerator for 8 pixels at a time; the S and H table lookups are scalar.
#include "SafariumRasterC.h"
#include <arm_neon.h>

static inline void hsv_px(int v, int diff, int hnum, uint8_t *o, const uint8_t *lut, const int32_t *hdiv) {
    int h = (hnum * hdiv[diff] + 2048) >> 12;
    if (h < 0) h += 180;
    o[0] = (uint8_t)(h < 0 ? 0 : (h > 255 ? 255 : h));
    o[1] = lut[(v << 8) | diff];
    o[2] = (uint8_t)v;
}

void src_hsv_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep, int rows, int cols, int scn, int blue_idx,
                const uint8_t *slut, const uint8_t *slut_tail, const int32_t *hdiv) {
    const int bo = blue_idx, ro = 2 - blue_idx;
    const int simd_end = cols & ~7;
    for (int y = 0; y < rows; y++) {
        const uint8_t *s = src + (ptrdiff_t)y * sstep;
        uint8_t *d = dst + (ptrdiff_t)y * dstep;
        int x = 0;
        for (; x < simd_end; x += 8) {
            uint8x8_t b, g, r;
            if (scn == 3) {
                uint8x8x3_t p = vld3_u8(s + x * 3);
                b = p.val[bo]; g = p.val[1]; r = p.val[ro];
            } else {
                uint8x8x4_t p = vld4_u8(s + x * 4);
                b = p.val[bo]; g = p.val[1]; r = p.val[ro];
            }
            uint8x8_t v = vmax_u8(vmax_u8(b, g), r);
            uint8x8_t df = vsub_u8(v, vmin_u8(vmin_u8(b, g), r));
            int16x8_t b16 = vreinterpretq_s16_u16(vmovl_u8(b)), g16 = vreinterpretq_s16_u16(vmovl_u8(g)), r16 = vreinterpretq_s16_u16(vmovl_u8(r));
            int16x8_t d16 = vreinterpretq_s16_u16(vmovl_u8(df));
            int16x8_t hr = vsubq_s16(g16, b16);
            int16x8_t hg = vaddq_s16(vsubq_s16(b16, r16), vshlq_n_s16(d16, 1));
            int16x8_t hb = vaddq_s16(vsubq_s16(r16, g16), vshlq_n_s16(d16, 2));
            int16x8_t mr = vreinterpretq_s16_u16(vmovl_u8(vceq_u8(v, r)));
            int16x8_t mg = vreinterpretq_s16_u16(vmovl_u8(vceq_u8(v, g)));
            mr = vshrq_n_s16(vshlq_n_s16(mr, 8), 8);   // 0x00ff -> 0xffff
            mg = vshrq_n_s16(vshlq_n_s16(mg, 8), 8);
            int16x8_t hn = vbslq_s16(vreinterpretq_u16_s16(mr), hr, vbslq_s16(vreinterpretq_u16_s16(mg), hg, hb));
            uint8_t va[8], da[8];
            int16_t ha[8];
            vst1_u8(va, v); vst1_u8(da, df); vst1q_s16(ha, hn);
            uint8_t *o = d + x * 3;
            for (int i = 0; i < 8; i++) hsv_px(va[i], da[i], ha[i], o + i * 3, slut, hdiv);
        }
        for (; x < cols; x++) {
            const uint8_t *p = s + x * scn;
            int b = p[bo], g = p[1], r = p[ro];
            int v = b > g ? b : g; v = v > r ? v : r;
            int m = b < g ? b : g; m = m < r ? m : r;
            int diff = v - m;
            int hn = v == r ? g - b : (v == g ? b - r + 2 * diff : r - g + 4 * diff);
            hsv_px(v, diff, hn, d + x * 3, slut_tail, hdiv);
        }
    }
}
