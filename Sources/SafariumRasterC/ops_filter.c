// SafariumRasterC — Phase 3/4 C & NEON kernels: colormap, equalizeHist, CLAHE, median, bilateral, Canny, integral, sep/box/filter2d/pyrDown.
#include "include/sr_ops.h"
#include "include/sr_ops_perf.h"
#include <arm_neon.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static inline int32_t border_idx(int32_t p, int32_t len, int32_t mode) {
    if ((uint32_t)p < (uint32_t)len) return p;
    if (len <= 1) return (mode == 0) ? -1 : 0;
    if (mode == 0) return -1;
    if (mode == 1) return p < 0 ? 0 : len - 1;
    if (mode == 3) {
        int32_t r = p % len;
        return r < 0 ? r + len : r;
    }
    int32_t delta = (mode == 4) ? 1 : 0; // reflect101 = 4, reflect = 2
    int32_t period = (len - delta) * 2;
    if (period <= 0) return 0;
    if (mode == 2) { // BORDER_REFLECT
        while (p < 0 || p >= len) {
            if (p < 0) p = -p - 1;
            else p = 2 * len - 1 - p;
        }
        return p;
    }
    // BORDER_REFLECT_101 (default = 4)
    while (p < 0 || p >= len) {
        if (p < 0) p = -p;
        else p = 2 * len - 2 - p;
    }
    return p;
}

static inline uint8_t bgr_to_gray_u8(uint8_t b, uint8_t g, uint8_t r) {
    return (uint8_t)(((int32_t)b * 3735 + (int32_t)g * 19235 + (int32_t)r * 9798 + 16384) >> 15);
}

// MARK: - applyColorMap

int32_t sr_c_apply_colormap(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride, int32_t srcCh,
                            uint8_t *dst, int32_t dstStride, int32_t colormap, const uint8_t *customLut) {
    if (!src || !dst || w <= 0 || h <= 0) return -1;
    if (srcCh != 1 && srcCh != 3 && srcCh != 4) return -1;
    const uint8_t (*lut)[3] = NULL;
    if (customLut) {
        lut = (const uint8_t (*)[3])customLut;
    } else if (colormap >= 0 && colormap < 22) {
        lut = sr_colormap_luts[colormap];
    } else {
        return -1;
    }
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (size_t)y * (size_t)srcStride;
        uint8_t *d = dst + (size_t)y * (size_t)dstStride;
        if (srcCh == 1) {
            for (int32_t x = 0; x < w; x++) {
                const uint8_t *c = lut[s[x]];
                d[3 * x] = c[0]; d[3 * x + 1] = c[1]; d[3 * x + 2] = c[2];
            }
        } else {
            for (int32_t x = 0; x < w; x++) {
                uint8_t g = bgr_to_gray_u8(s[srcCh * x], s[srcCh * x + 1], s[srcCh * x + 2]);
                const uint8_t *c = lut[g];
                d[3 * x] = c[0]; d[3 * x + 1] = c[1]; d[3 * x + 2] = c[2];
            }
        }
    }
    return 0;
}

// MARK: - equalizeHist

int32_t sr_c_equalize_hist_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                              uint8_t *dst, int32_t dstStride) {
    if (!src || !dst || w <= 0 || h <= 0) return -1;
    uint64_t h0[256] = {0}, h1[256] = {0}, h2[256] = {0}, h3[256] = {0};
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (size_t)y * (size_t)srcStride;
        int32_t x = 0;
        for (; x + 4 <= w; x += 4) {
            h0[s[x]]++; h1[s[x + 1]]++; h2[s[x + 2]]++; h3[s[x + 3]]++;
        }
        for (; x < w; x++) h0[s[x]]++;
    }
    uint64_t hist[256];
    for (int i = 0; i < 256; i++) hist[i] = h0[i] + h1[i] + h2[i] + h3[i];
    uint64_t total = (uint64_t)w * (uint64_t)h;
    int first = 0;
    while (first < 256 && hist[first] == 0) first++;
    uint8_t lut[256];
    if (first == 256 || hist[first] == total) {
        for (int i = 0; i < 256; i++) lut[i] = (uint8_t)i;
    } else {
        double scale = 255.0 / (double)(total - hist[first]);
        uint64_t sum = 0;
        for (int i = 0; i < 256; i++) {
            if (i <= first) {
                lut[i] = 0;
            } else {
                sum += hist[i];
                int v = (int)llround((double)sum * scale);
                lut[i] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
            }
        }
    }
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (size_t)y * (size_t)srcStride;
        uint8_t *d = dst + (size_t)y * (size_t)dstStride;
        int32_t x = 0;
        for (; x + 8 <= w; x += 8) {
            d[x] = lut[s[x]]; d[x + 1] = lut[s[x + 1]]; d[x + 2] = lut[s[x + 2]]; d[x + 3] = lut[s[x + 3]];
            d[x + 4] = lut[s[x + 4]]; d[x + 5] = lut[s[x + 5]]; d[x + 6] = lut[s[x + 6]]; d[x + 7] = lut[s[x + 7]];
        }
        for (; x < w; x++) d[x] = lut[s[x]];
    }
    return 0;
}

// MARK: - CLAHE (u8 & u16)

static void clahe_build_lut(uint32_t *hist, int32_t histSize, int32_t tilePixels,
                            double clipLimit, void *lutOut, int isU16) {
    if (clipLimit > 0.0) {
        int32_t clip = (int32_t)(clipLimit * (double)tilePixels / (double)histSize);
        if (clip < 1) clip = 1;
        uint64_t clipped = 0;
        for (int32_t i = 0; i < histSize; i++) {
            if ((int32_t)hist[i] > clip) {
                clipped += hist[i] - (uint32_t)clip;
                hist[i] = (uint32_t)clip;
            }
        }
        uint32_t redistBatch = (uint32_t)(clipped / (uint64_t)histSize);
        int32_t residual = (int32_t)(clipped - (uint64_t)redistBatch * (uint64_t)histSize);
        for (int32_t i = 0; i < histSize; i++) hist[i] += redistBatch;
        if (residual > 0) {
            int32_t step = histSize / residual;
            if (step < 1) step = 1;
            int32_t i = 0;
            while (residual > 0 && i < histSize) {
                hist[i]++;
                residual--;
                i += step;
            }
        }
    }
    double scale = (double)(histSize - 1) / (double)(tilePixels > 0 ? tilePixels : 1);
    uint64_t acc = 0;
    if (isU16) {
        uint16_t *lut = (uint16_t *)lutOut;
        for (int32_t i = 0; i < histSize; i++) {
            acc += hist[i];
            int32_t v = (int32_t)llround((double)acc * scale);
            lut[i] = (uint16_t)(v < 0 ? 0 : (v > 65535 ? 65535 : v));
        }
    } else {
        uint8_t *lut = (uint8_t *)lutOut;
        for (int32_t i = 0; i < histSize; i++) {
            acc += hist[i];
            int32_t v = (int32_t)llround((double)acc * scale);
            lut[i] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
    }
}

int32_t sr_c_clahe_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                      uint8_t *dst, int32_t dstStride, double clipLimit, int32_t tilesX, int32_t tilesY) {
    if (!src || !dst || w <= 0 || h <= 0 || tilesX < 1 || tilesY < 1) return -1;
    int32_t nTiles = tilesX * tilesY;
    uint32_t *hist = (uint32_t *)malloc(sizeof(uint32_t) * 256u);
    uint8_t *luts = (uint8_t *)malloc((size_t)nTiles * 256u);
    if (!hist || !luts) { free(hist); free(luts); return -1; }

    for (int32_t ty = 0; ty < tilesY; ty++) {
        int32_t y0 = (ty * h) / tilesY, y1 = ((ty + 1) * h) / tilesY;
        if (y1 <= y0) y1 = y0 + 1;
        for (int32_t tx = 0; tx < tilesX; tx++) {
            int32_t x0 = (tx * w) / tilesX, x1 = ((tx + 1) * w) / tilesX;
            if (x1 <= x0) x1 = x0 + 1;
            memset(hist, 0, sizeof(uint32_t) * 256u);
            for (int32_t y = y0; y < y1; y++) {
                int32_t sy = y < h ? y : h - 1;
                const uint8_t *s = src + (size_t)sy * (size_t)srcStride;
                for (int32_t x = x0; x < x1; x++) hist[s[x < w ? x : w - 1]]++;
            }
            int32_t area = (x1 - x0) * (y1 - y0);
            clahe_build_lut(hist, 256, area, clipLimit, luts + (size_t)(ty * tilesX + tx) * 256u, 0);
        }
    }
    double tileW = (double)w / (double)tilesX, tileH = (double)h / (double)tilesY;
    for (int32_t y = 0; y < h; y++) {
        double tyf = (double)y / tileH - 0.5;
        int32_t ty1 = (int32_t)floor(tyf);
        double ya = tyf - (double)ty1;
        int32_t ty2 = ty1 + 1;
        if (ty1 < 0) { ty1 = 0; ty2 = 0; ya = 0.0; }
        else if (ty2 >= tilesY) { ty2 = tilesY - 1; ty1 = ty2; ya = 0.0; }
        const uint8_t *s = src + (size_t)y * (size_t)srcStride;
        uint8_t *d = dst + (size_t)y * (size_t)dstStride;
        for (int32_t x = 0; x < w; x++) {
            double txf = (double)x / tileW - 0.5;
            int32_t tx1 = (int32_t)floor(txf);
            double xa = txf - (double)tx1;
            int32_t tx2 = tx1 + 1;
            if (tx1 < 0) { tx1 = 0; tx2 = 0; xa = 0.0; }
            else if (tx2 >= tilesX) { tx2 = tilesX - 1; tx1 = tx2; xa = 0.0; }
            uint8_t v = s[x];
            double p00 = luts[(size_t)(ty1 * tilesX + tx1) * 256u + v];
            double p01 = luts[(size_t)(ty1 * tilesX + tx2) * 256u + v];
            double p10 = luts[(size_t)(ty2 * tilesX + tx1) * 256u + v];
            double p11 = luts[(size_t)(ty2 * tilesX + tx2) * 256u + v];
            double val = (1.0 - ya) * ((1.0 - xa) * p00 + xa * p01) + ya * ((1.0 - xa) * p10 + xa * p11);
            int32_t iv = (int32_t)llround(val);
            d[x] = (uint8_t)(iv < 0 ? 0 : (iv > 255 ? 255 : iv));
        }
    }
    free(hist); free(luts);
    return 0;
}

int32_t sr_c_clahe_u16(const uint16_t *src, int32_t w, int32_t h, int32_t srcStrideBytes,
                       uint16_t *dst, int32_t dstStrideBytes, double clipLimit, int32_t tilesX, int32_t tilesY) {
    if (!src || !dst || w <= 0 || h <= 0 || tilesX < 1 || tilesY < 1) return -1;
    int32_t nTiles = tilesX * tilesY;
    uint32_t *hist = (uint32_t *)malloc(sizeof(uint32_t) * 65536u);
    uint16_t *luts = (uint16_t *)malloc(sizeof(uint16_t) * (size_t)nTiles * 65536u);
    if (!hist || !luts) { free(hist); free(luts); return -1; }

    for (int32_t ty = 0; ty < tilesY; ty++) {
        int32_t y0 = (ty * h) / tilesY, y1 = ((ty + 1) * h) / tilesY;
        if (y1 <= y0) y1 = y0 + 1;
        for (int32_t tx = 0; tx < tilesX; tx++) {
            int32_t x0 = (tx * w) / tilesX, x1 = ((tx + 1) * w) / tilesX;
            if (x1 <= x0) x1 = x0 + 1;
            memset(hist, 0, sizeof(uint32_t) * 65536u);
            for (int32_t y = y0; y < y1; y++) {
                int32_t sy = y < h ? y : h - 1;
                const uint16_t *s = (const uint16_t *)((const uint8_t *)src + (size_t)sy * (size_t)srcStrideBytes);
                for (int32_t x = x0; x < x1; x++) hist[s[x < w ? x : w - 1]]++;
            }
            int32_t area = (x1 - x0) * (y1 - y0);
            clahe_build_lut(hist, 65536, area, clipLimit, luts + (size_t)(ty * tilesX + tx) * 65536u, 1);
        }
    }
    double tileW = (double)w / (double)tilesX, tileH = (double)h / (double)tilesY;
    for (int32_t y = 0; y < h; y++) {
        double tyf = (double)y / tileH - 0.5;
        int32_t ty1 = (int32_t)floor(tyf);
        double ya = tyf - (double)ty1;
        int32_t ty2 = ty1 + 1;
        if (ty1 < 0) { ty1 = 0; ty2 = 0; ya = 0.0; }
        else if (ty2 >= tilesY) { ty2 = tilesY - 1; ty1 = ty2; ya = 0.0; }
        const uint16_t *s = (const uint16_t *)((const uint8_t *)src + (size_t)y * (size_t)srcStrideBytes);
        uint16_t *d = (uint16_t *)((uint8_t *)dst + (size_t)y * (size_t)dstStrideBytes);
        for (int32_t x = 0; x < w; x++) {
            double txf = (double)x / tileW - 0.5;
            int32_t tx1 = (int32_t)floor(txf);
            double xa = txf - (double)tx1;
            int32_t tx2 = tx1 + 1;
            if (tx1 < 0) { tx1 = 0; tx2 = 0; xa = 0.0; }
            else if (tx2 >= tilesX) { tx2 = tilesX - 1; tx1 = tx2; xa = 0.0; }
            uint16_t v = s[x];
            double p00 = luts[(size_t)(ty1 * tilesX + tx1) * 65536u + v];
            double p01 = luts[(size_t)(ty1 * tilesX + tx2) * 65536u + v];
            double p10 = luts[(size_t)(ty2 * tilesX + tx1) * 65536u + v];
            double p11 = luts[(size_t)(ty2 * tilesX + tx2) * 65536u + v];
            double val = (1.0 - ya) * ((1.0 - xa) * p00 + xa * p01) + ya * ((1.0 - xa) * p10 + xa * p11);
            int32_t iv = (int32_t)llround(val);
            d[x] = (uint16_t)(iv < 0 ? 0 : (iv > 65535 ? 65535 : iv));
        }
    }
    free(hist); free(luts);
    return 0;
}

// MARK: - medianBlur (Huang sliding histogram for u8 + sort/9-net for u16/f32)

// Simpler completely verified 9-element median via exact partial network
static inline uint8_t m9_u8(uint8_t a[9]) {
    #define OP(i,j) if (a[i] > a[j]) { uint8_t t = a[i]; a[i] = a[j]; a[j] = t; }
    OP(0,1); OP(3,4); OP(6,7); OP(1,2); OP(4,5); OP(7,8); OP(0,1); OP(3,4); OP(6,7);
    OP(0,3); OP(3,6); OP(0,3); OP(1,4); OP(4,7); OP(1,4); OP(2,5); OP(5,8); OP(2,5);
    OP(1,3); OP(5,7); OP(2,6); OP(4,6); OP(2,4); OP(2,3); OP(4,5); OP(3,4);
    #undef OP
    return a[4];
}

static inline uint16_t m9_u16(uint16_t a[9]) {
    #define OP(i,j) if (a[i] > a[j]) { uint16_t t = a[i]; a[i] = a[j]; a[j] = t; }
    OP(0,1); OP(3,4); OP(6,7); OP(1,2); OP(4,5); OP(7,8); OP(0,1); OP(3,4); OP(6,7);
    OP(0,3); OP(3,6); OP(0,3); OP(1,4); OP(4,7); OP(1,4); OP(2,5); OP(5,8); OP(2,5);
    OP(1,3); OP(5,7); OP(2,6); OP(4,6); OP(2,4); OP(2,3); OP(4,5); OP(3,4);
    #undef OP
    return a[4];
}

static inline float m9_f32(float a[9]) {
    #define OP(i,j) if (a[i] > a[j]) { float t = a[i]; a[i] = a[j]; a[j] = t; }
    OP(0,1); OP(3,4); OP(6,7); OP(1,2); OP(4,5); OP(7,8); OP(0,1); OP(3,4); OP(6,7);
    OP(0,3); OP(3,6); OP(0,3); OP(1,4); OP(4,7); OP(1,4); OP(2,5); OP(5,8); OP(2,5);
    OP(1,3); OP(5,7); OP(2,6); OP(4,6); OP(2,4); OP(2,3); OP(4,5); OP(3,4);
    #undef OP
    return a[4];
}

static int cmp_u16(const void *a, const void *b) {
    uint16_t va = *(const uint16_t *)a, vb = *(const uint16_t *)b;
    return (va > vb) - (va < vb);
}
static int cmp_f32(const void *a, const void *b) {
    float va = *(const float *)a, vb = *(const float *)b;
    return (va > vb) - (va < vb);
}

static inline uint8x16_t m9_u8_x16(uint8x16_t p0, uint8x16_t p1, uint8x16_t p2,
                                   uint8x16_t p3, uint8x16_t p4, uint8x16_t p5,
                                   uint8x16_t p6, uint8x16_t p7, uint8x16_t p8) {
    #define VOP(a, b) do { uint8x16_t lo = vminq_u8(a, b), hi = vmaxq_u8(a, b); a = lo; b = hi; } while (0)
    VOP(p0, p1); VOP(p3, p4); VOP(p6, p7); VOP(p1, p2); VOP(p4, p5); VOP(p7, p8); VOP(p0, p1); VOP(p3, p4); VOP(p6, p7);
    VOP(p0, p3); VOP(p3, p6); VOP(p0, p3); VOP(p1, p4); VOP(p4, p7); VOP(p1, p4); VOP(p2, p5); VOP(p5, p8); VOP(p2, p5);
    VOP(p1, p3); VOP(p5, p7); VOP(p2, p6); VOP(p4, p6); VOP(p2, p4); VOP(p2, p3); VOP(p4, p5); VOP(p3, p4);
    #undef VOP
    return p4;
}

int32_t sr_c_median_u8(const uint8_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStride,
                       uint8_t *dst, int32_t dstStride, int32_t ksize) {
    if (!src || !dst || w <= 0 || h <= 0 || ksize < 1 || (ksize % 2) == 0) return -1;
    if (ksize == 1) {
        for (int32_t y = 0; y < h; y++) memcpy(dst + (size_t)y * dstStride, src + (size_t)y * srcStride, (size_t)w * ch);
        return 0;
    }
    if (ksize == 3) {
        const int32_t n = w * ch;
        for (int32_t y = 0; y < h; y++) {
            int32_t ym = y > 0 ? y - 1 : 0, yp = y + 1 < h ? y + 1 : h - 1;
            const uint8_t *r0 = src + (size_t)ym * srcStride;
            const uint8_t *r1 = src + (size_t)y * srcStride;
            const uint8_t *r2 = src + (size_t)yp * srcStride;
            uint8_t *d = dst + (size_t)y * dstStride;
            if (w >= 3) {
                // Left 1-px column border
                for (int32_t c = 0; c < ch; c++) {
                    uint8_t v[9] = {r0[c], r0[c], r0[ch+c], r1[c], r1[c], r1[ch+c], r2[c], r2[c], r2[ch+c]};
                    d[c] = m9_u8(v);
                }
                int32_t i = ch;
                int32_t end_i = n - ch;
                for (; i + 16 <= end_i; i += 16) {
                    uint8x16_t med = m9_u8_x16(
                        vld1q_u8(r0 + i - ch), vld1q_u8(r0 + i), vld1q_u8(r0 + i + ch),
                        vld1q_u8(r1 + i - ch), vld1q_u8(r1 + i), vld1q_u8(r1 + i + ch),
                        vld1q_u8(r2 + i - ch), vld1q_u8(r2 + i), vld1q_u8(r2 + i + ch));
                    vst1q_u8(d + i, med);
                }
                for (; i < end_i; i++) {
                    uint8_t v[9] = {r0[i-ch], r0[i], r0[i+ch], r1[i-ch], r1[i], r1[i+ch], r2[i-ch], r2[i], r2[i+ch]};
                    d[i] = m9_u8(v);
                }
                int32_t last = n - ch;
                for (int32_t c = 0; c < ch; c++) {
                    uint8_t v[9] = {
                        r0[last-ch+c], r0[last+c], r0[last+c],
                        r1[last-ch+c], r1[last+c], r1[last+c],
                        r2[last-ch+c], r2[last+c], r2[last+c]
                    };
                    d[last + c] = m9_u8(v);
                }
            } else {
                for (int32_t x = 0; x < w; x++) {
                    int32_t xm = x > 0 ? x - 1 : 0, xp = x + 1 < w ? x + 1 : w - 1;
                    for (int32_t c = 0; c < ch; c++) {
                        uint8_t v[9] = {
                            r0[xm*ch+c], r0[x*ch+c], r0[xp*ch+c],
                            r1[xm*ch+c], r1[x*ch+c], r1[xp*ch+c],
                            r2[xm*ch+c], r2[x*ch+c], r2[xp*ch+c]
                        };
                        d[x*ch+c] = m9_u8(v);
                    }
                }
            }
        }
        return 0;
    }
    int32_t rad = ksize / 2, halfN = (ksize * ksize) / 2;
    for (int32_t y = 0; y < h; y++) {
        uint8_t *d = dst + (size_t)y * dstStride;
        for (int32_t c = 0; c < ch; c++) {
            int32_t hist[256] = {0};
            for (int32_t dy = -rad; dy <= rad; dy++) {
                int32_t sy = y + dy < 0 ? 0 : (y + dy >= h ? h - 1 : y + dy);
                const uint8_t *row = src + (size_t)sy * srcStride;
                for (int32_t dx = -rad; dx <= rad; dx++) {
                    int32_t sx = dx < 0 ? 0 : (dx >= w ? w - 1 : dx);
                    hist[row[sx * ch + c]]++;
                }
            }
            int32_t med = 0, le_cnt = hist[0];
            while (med < 255 && le_cnt <= halfN) { med++; le_cnt += hist[med]; }
            for (int32_t x = 0; x < w; x++) {
                while (med < 255 && le_cnt <= halfN) { med++; le_cnt += hist[med]; }
                while (med > 0 && le_cnt - hist[med] > halfN) { le_cnt -= hist[med]; med--; }
                d[x * ch + c] = (uint8_t)med;
                if (x + 1 < w) {
                    int32_t xOut = x - rad < 0 ? 0 : x - rad;
                    int32_t xIn = x + rad + 1 >= w ? w - 1 : x + rad + 1;
                    for (int32_t dy = -rad; dy <= rad; dy++) {
                        int32_t sy = y + dy < 0 ? 0 : (y + dy >= h ? h - 1 : y + dy);
                        const uint8_t *row = src + (size_t)sy * srcStride;
                        uint8_t vOut = row[xOut * ch + c];
                        uint8_t vIn = row[xIn * ch + c];
                        hist[vOut]--; if (vOut <= med) le_cnt--;
                        hist[vIn]++;  if (vIn <= med) le_cnt++;
                    }
                }
            }
        }
    }
    return 0;
}

int32_t sr_c_median_u16(const uint16_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes,
                        uint16_t *dst, int32_t dstStrideBytes, int32_t ksize) {
    if (!src || !dst || w <= 0 || h <= 0 || ksize < 1 || (ksize % 2) == 0) return -1;
    int32_t rad = ksize / 2, cnt = ksize * ksize;
    uint16_t *buf = cnt > 9 ? (uint16_t *)malloc(sizeof(uint16_t) * (size_t)cnt) : NULL;
    if (cnt > 9 && !buf) return -1;
    for (int32_t y = 0; y < h; y++) {
        uint16_t *d = (uint16_t *)((uint8_t *)dst + (size_t)y * dstStrideBytes);
        for (int32_t x = 0; x < w; x++) {
            for (int32_t c = 0; c < ch; c++) {
                if (ksize == 3) {
                    uint16_t a[9]; int k = 0;
                    for (int32_t dy = -1; dy <= 1; dy++) {
                        int32_t sy = y+dy < 0 ? 0 : (y+dy >= h ? h-1 : y+dy);
                        const uint16_t *r = (const uint16_t *)((const uint8_t *)src + (size_t)sy * srcStrideBytes);
                        for (int32_t dx = -1; dx <= 1; dx++) {
                            int32_t sx = x+dx < 0 ? 0 : (x+dx >= w ? w-1 : x+dx);
                            a[k++] = r[sx * ch + c];
                        }
                    }
                    d[x * ch + c] = m9_u16(a);
                } else {
                    int k = 0;
                    for (int32_t dy = -rad; dy <= rad; dy++) {
                        int32_t sy = y+dy < 0 ? 0 : (y+dy >= h ? h-1 : y+dy);
                        const uint16_t *r = (const uint16_t *)((const uint8_t *)src + (size_t)sy * srcStrideBytes);
                        for (int32_t dx = -rad; dx <= rad; dx++) {
                            int32_t sx = x+dx < 0 ? 0 : (x+dx >= w ? w-1 : x+dx);
                            buf[k++] = r[sx * ch + c];
                        }
                    }
                    qsort(buf, (size_t)cnt, sizeof(uint16_t), cmp_u16);
                    d[x * ch + c] = buf[cnt / 2];
                }
            }
        }
    }
    free(buf);
    return 0;
}

int32_t sr_c_median_f32(const float *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes,
                        float *dst, int32_t dstStrideBytes, int32_t ksize) {
    if (!src || !dst || w <= 0 || h <= 0 || ksize < 1 || (ksize % 2) == 0) return -1;
    int32_t rad = ksize / 2, cnt = ksize * ksize;
    float *buf = cnt > 9 ? (float *)malloc(sizeof(float) * (size_t)cnt) : NULL;
    if (cnt > 9 && !buf) return -1;
    for (int32_t y = 0; y < h; y++) {
        float *d = (float *)((uint8_t *)dst + (size_t)y * dstStrideBytes);
        for (int32_t x = 0; x < w; x++) {
            for (int32_t c = 0; c < ch; c++) {
                if (ksize == 3) {
                    float a[9]; int k = 0;
                    for (int32_t dy = -1; dy <= 1; dy++) {
                        int32_t sy = y+dy < 0 ? 0 : (y+dy >= h ? h-1 : y+dy);
                        const float *r = (const float *)((const uint8_t *)src + (size_t)sy * srcStrideBytes);
                        for (int32_t dx = -1; dx <= 1; dx++) {
                            int32_t sx = x+dx < 0 ? 0 : (x+dx >= w ? w-1 : x+dx);
                            a[k++] = r[sx * ch + c];
                        }
                    }
                    d[x * ch + c] = m9_f32(a);
                } else {
                    int k = 0;
                    for (int32_t dy = -rad; dy <= rad; dy++) {
                        int32_t sy = y+dy < 0 ? 0 : (y+dy >= h ? h-1 : y+dy);
                        const float *r = (const float *)((const uint8_t *)src + (size_t)sy * srcStrideBytes);
                        for (int32_t dx = -rad; dx <= rad; dx++) {
                            int32_t sx = x+dx < 0 ? 0 : (x+dx >= w ? w-1 : x+dx);
                            buf[k++] = r[sx * ch + c];
                        }
                    }
                    qsort(buf, (size_t)cnt, sizeof(float), cmp_f32);
                    d[x * ch + c] = buf[cnt / 2];
                }
            }
        }
    }
    free(buf);
    return 0;
}

// MARK: - bilateralFilter (u8 LUT + f32)

int32_t sr_c_bilateral_u8(const uint8_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStride,
                          uint8_t *dst, int32_t dstStride, int32_t radius,
                          double sigmaColor, double sigmaSpace, int32_t borderMode) {
    if (!src || !dst || w <= 0 || h <= 0 || (ch != 1 && ch != 3)) return -1;
    if (radius < 1) radius = 1;
    if (sigmaColor <= 0) sigmaColor = 1e-6;
    if (sigmaSpace <= 0) sigmaSpace = 1e-6;
    double gColor = -0.5 / (sigmaColor * sigmaColor);
    double gSpace = -0.5 / (sigmaSpace * sigmaSpace);

    float colorLUT[766];
    int lutMax = ch == 1 ? 256 : 766;
    for (int i = 0; i < lutMax; i++) colorLUT[i] = (float)exp((double)(i * i) * gColor);

    int maxPts = (2 * radius + 1) * (2 * radius + 1);
    int32_t *dxA = (int32_t *)malloc(sizeof(int32_t) * (size_t)maxPts);
    int32_t *dyA = (int32_t *)malloc(sizeof(int32_t) * (size_t)maxPts);
    float *swA = (float *)malloc(sizeof(float) * (size_t)maxPts);
    if (!dxA || !dyA || !swA) { free(dxA); free(dyA); free(swA); return -1; }
    int32_t nPts = 0;
    for (int32_t dy = -radius; dy <= radius; dy++) {
        for (int32_t dx = -radius; dx <= radius; dx++) {
            int32_t r2 = dx * dx + dy * dy;
            if (r2 <= radius * radius) {
                dxA[nPts] = dx; dyA[nPts] = dy; swA[nPts] = (float)exp((double)r2 * gSpace);
                nPts++;
            }
        }
    }
    ptrdiff_t *ofsA = (ptrdiff_t *)malloc(sizeof(ptrdiff_t) * (size_t)nPts);
    if (!ofsA) { free(dxA); free(dyA); free(swA); return -1; }
    for (int k = 0; k < nPts; k++) ofsA[k] = (ptrdiff_t)dyA[k] * srcStride + (ptrdiff_t)dxA[k] * ch;

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *sRow = src + (size_t)y * srcStride;
        uint8_t *dRow = dst + (size_t)y * dstStride;
        int interiorY = (y >= radius && y < h - radius);
        for (int32_t x = 0; x < w; x++) {
            int interior = interiorY && (x >= radius && x < w - radius);
            if (ch == 1) {
                int32_t c0 = sRow[x];
                float sum = 0.0f, wsum = 0.0f;
                if (interior) {
                    const uint8_t *ctr = sRow + x;
                    for (int k = 0; k < nPts; k++) {
                        int32_t v = ctr[ofsA[k]];
                        int32_t d = v - c0; if (d < 0) d = -d;
                        float wt = swA[k] * colorLUT[d];
                        sum += (float)v * wt;
                        wsum += wt;
                    }
                } else {
                    for (int k = 0; k < nPts; k++) {
                        int32_t sy = border_idx(y + dyA[k], h, borderMode);
                        int32_t sx = border_idx(x + dxA[k], w, borderMode);
                        int32_t v = (sy < 0 || sx < 0) ? 0 : src[(size_t)sy * srcStride + sx];
                        int32_t d = v - c0; if (d < 0) d = -d;
                        float wt = swA[k] * colorLUT[d];
                        sum += (float)v * wt;
                        wsum += wt;
                    }
                }
                int32_t out = (int32_t)lrintf(sum / wsum);
                dRow[x] = (uint8_t)(out < 0 ? 0 : (out > 255 ? 255 : out));
            } else {
                int32_t b0 = sRow[3*x], g0 = sRow[3*x+1], r0 = sRow[3*x+2];
                float sb = 0.0f, sg = 0.0f, sr = 0.0f, wsum = 0.0f;
                if (interior) {
                    const uint8_t *ctr = sRow + (size_t)x * 3;
                    for (int k = 0; k < nPts; k++) {
                        const uint8_t *p = ctr + ofsA[k];
                        int32_t b1 = p[0], g1 = p[1], r1 = p[2];
                        int32_t d = abs(b1 - b0) + abs(g1 - g0) + abs(r1 - r0);
                        float wt = swA[k] * colorLUT[d];
                        sb += (float)b1 * wt; sg += (float)g1 * wt; sr += (float)r1 * wt;
                        wsum += wt;
                    }
                } else {
                    for (int k = 0; k < nPts; k++) {
                        int32_t sy = border_idx(y + dyA[k], h, borderMode);
                        int32_t sx = border_idx(x + dxA[k], w, borderMode);
                        int32_t b1 = 0, g1 = 0, r1 = 0;
                        if (sy >= 0 && sx >= 0) {
                            const uint8_t *p = src + (size_t)sy * srcStride + (size_t)sx * 3;
                            b1 = p[0]; g1 = p[1]; r1 = p[2];
                        }
                        int32_t d = abs(b1 - b0) + abs(g1 - g0) + abs(r1 - r0);
                        float wt = swA[k] * colorLUT[d];
                        sb += (float)b1 * wt; sg += (float)g1 * wt; sr += (float)r1 * wt;
                        wsum += wt;
                    }
                }
                float inv = 1.0f / wsum;
                int32_t ob = (int32_t)lrintf(sb * inv), og = (int32_t)lrintf(sg * inv), or_ = (int32_t)lrintf(sr * inv);
                dRow[3*x]   = (uint8_t)(ob < 0 ? 0 : (ob > 255 ? 255 : ob));
                dRow[3*x+1] = (uint8_t)(og < 0 ? 0 : (og > 255 ? 255 : og));
                dRow[3*x+2] = (uint8_t)(or_ < 0 ? 0 : (or_ > 255 ? 255 : or_));
            }
        }
    }
    free(ofsA); free(dxA); free(dyA); free(swA);
    return 0;
}

int32_t sr_c_bilateral_f32(const float *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes,
                           float *dst, int32_t dstStrideBytes, int32_t radius,
                           double sigmaColor, double sigmaSpace, int32_t borderMode) {
    if (!src || !dst || w <= 0 || h <= 0 || (ch != 1 && ch != 3)) return -1;
    if (radius < 1) radius = 1;
    if (sigmaColor <= 0) sigmaColor = 1e-6;
    if (sigmaSpace <= 0) sigmaSpace = 1e-6;
    double gColor = -0.5 / (sigmaColor * sigmaColor);
    double gSpace = -0.5 / (sigmaSpace * sigmaSpace);

    int maxPts = (2 * radius + 1) * (2 * radius + 1);
    int32_t *dxA = (int32_t *)malloc(sizeof(int32_t) * (size_t)maxPts);
    int32_t *dyA = (int32_t *)malloc(sizeof(int32_t) * (size_t)maxPts);
    float *swA = (float *)malloc(sizeof(float) * (size_t)maxPts);
    if (!dxA || !dyA || !swA) { free(dxA); free(dyA); free(swA); return -1; }
    int nPts = 0;
    for (int32_t dy = -radius; dy <= radius; dy++) {
        for (int32_t dx = -radius; dx <= radius; dx++) {
            int32_t r2 = dx * dx + dy * dy;
            if (r2 <= radius * radius) {
                dxA[nPts] = dx; dyA[nPts] = dy; swA[nPts] = (float)exp((double)r2 * gSpace);
                nPts++;
            }
        }
    }

    for (int32_t y = 0; y < h; y++) {
        const float *sRow = (const float *)((const uint8_t *)src + (size_t)y * srcStrideBytes);
        float *dRow = (float *)((uint8_t *)dst + (size_t)y * dstStrideBytes);
        for (int32_t x = 0; x < w; x++) {
            if (ch == 1) {
                float c0 = sRow[x], sum = 0.0f, wsum = 0.0f;
                for (int k = 0; k < nPts; k++) {
                    int32_t sy = border_idx(y + dyA[k], h, borderMode);
                    int32_t sx = border_idx(x + dxA[k], w, borderMode);
                    float v = (sy < 0 || sx < 0) ? 0.0f : ((const float *)((const uint8_t *)src + (size_t)sy * srcStrideBytes))[sx];
                    float d = v - c0;
                    float wt = swA[k] * expf(d * d * (float)gColor);
                    sum += v * wt; wsum += wt;
                }
                dRow[x] = sum / wsum;
            } else {
                float b0 = sRow[3*x], g0 = sRow[3*x+1], r0 = sRow[3*x+2];
                float sb = 0.0f, sg = 0.0f, sr = 0.0f, wsum = 0.0f;
                for (int k = 0; k < nPts; k++) {
                    int32_t sy = border_idx(y + dyA[k], h, borderMode);
                    int32_t sx = border_idx(x + dxA[k], w, borderMode);
                    float b1 = 0.0f, g1 = 0.0f, r1 = 0.0f;
                    if (sy >= 0 && sx >= 0) {
                        const float *p = (const float *)((const uint8_t *)src + (size_t)sy * srcStrideBytes) + 3 * sx;
                        b1 = p[0]; g1 = p[1]; r1 = p[2];
                    }
                    float d = fabsf(b1 - b0) + fabsf(g1 - g0) + fabsf(r1 - r0);
                    float wt = swA[k] * expf(d * d * (float)gColor);
                    sb += b1 * wt; sg += g1 * wt; sr += r1 * wt; wsum += wt;
                }
                float inv = 1.0f / wsum;
                dRow[3*x] = sb * inv; dRow[3*x+1] = sg * inv; dRow[3*x+2] = sr * inv;
            }
        }
    }
    free(dxA); free(dyA); free(swA);
    return 0;
}

// MARK: - Canny (apertureSize = 3, 5, 7, L1 / L2, iterative DFS hysteresis)

static void canny_sobel_sep(const uint8_t *gray, int32_t w, int32_t h, int32_t ap,
                            int32_t *dxOut, int32_t *dyOut) {
    static const int32_t sm3[3] = {1, 2, 1}, df3[3] = {-1, 0, 1};
    static const int32_t sm5[5] = {1, 4, 6, 4, 1}, df5[5] = {-1, -2, 0, 2, 1};
    static const int32_t sm7[7] = {1, 6, 15, 20, 15, 6, 1}, df7[7] = {-1, -4, -5, 0, 5, 4, 1};
    const int32_t *sm = ap == 3 ? sm3 : (ap == 5 ? sm5 : sm7);
    const int32_t *df = ap == 3 ? df3 : (ap == 5 ? df5 : df7);
    int32_t rad = ap / 2;

    int32_t *tmpX = (int32_t *)malloc(sizeof(int32_t) * (size_t)w * (size_t)h);
    int32_t *tmpY = (int32_t *)malloc(sizeof(int32_t) * (size_t)w * (size_t)h);
    if (!tmpX || !tmpY) { free(tmpX); free(tmpY); return; }

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *row = gray + (size_t)y * w;
        for (int32_t x = 0; x < w; x++) {
            int32_t sx = 0, sy = 0;
            for (int32_t k = -rad; k <= rad; k++) {
                int32_t px = x + k < 0 ? 0 : (x + k >= w ? w - 1 : x + k);
                int32_t v = row[px];
                sx += v * df[k + rad];
                sy += v * sm[k + rad];
            }
            tmpX[(size_t)y * w + x] = sx;
            tmpY[(size_t)y * w + x] = sy;
        }
    }
    for (int32_t y = 0; y < h; y++) {
        for (int32_t x = 0; x < w; x++) {
            int32_t gx = 0, gy = 0;
            for (int32_t k = -rad; k <= rad; k++) {
                int32_t py = y + k < 0 ? 0 : (y + k >= h ? h - 1 : y + k);
                gx += tmpX[(size_t)py * w + x] * sm[k + rad];
                gy += tmpY[(size_t)py * w + x] * df[k + rad];
            }
            dxOut[(size_t)y * w + x] = gx;
            dyOut[(size_t)y * w + x] = gy;
        }
    }
    free(tmpX); free(tmpY);
}

int32_t sr_c_canny_u8(const uint8_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStride,
                      uint8_t *dst, int32_t dstStride, double thresh1, double thresh2,
                      int32_t apertureSize, int32_t l2gradient) {
    if (!src || !dst || w <= 0 || h <= 0) return -1;
    if (apertureSize != 3 && apertureSize != 5 && apertureSize != 7) return -1;
    if (ch != 1 && ch != 3 && ch != 4) return -1;
    double lowT = thresh1 < thresh2 ? thresh1 : thresh2;
    double highT = thresh1 > thresh2 ? thresh1 : thresh2;
    if (lowT < 0) lowT = 0;
    if (highT < 0) highT = 0;

    size_t npix = (size_t)w * (size_t)h;
    uint8_t *gray = (uint8_t *)malloc(npix);
    int32_t *gx = (int32_t *)malloc(sizeof(int32_t) * npix);
    int32_t *gy = (int32_t *)malloc(sizeof(int32_t) * npix);
    double *mag = (double *)malloc(sizeof(double) * npix);
    uint8_t *edge = (uint8_t *)calloc(npix, 1);
    int32_t *stack = (int32_t *)malloc(sizeof(int32_t) * npix);
    if (!gray || !gx || !gy || !mag || !edge || !stack) {
        free(gray); free(gx); free(gy); free(mag); free(edge); free(stack); return -1;
    }

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (size_t)y * srcStride;
        if (ch == 1) {
            memcpy(gray + (size_t)y * w, s, (size_t)w);
        } else {
            for (int32_t x = 0; x < w; x++) {
                gray[(size_t)y * w + x] = bgr_to_gray_u8(s[ch * x], s[ch * x + 1], s[ch * x + 2]);
            }
        }
    }

    canny_sobel_sep(gray, w, h, apertureSize, gx, gy);

    double lo = l2gradient ? lowT * lowT : lowT;
    double hi = l2gradient ? highT * highT : highT;
    for (size_t i = 0; i < npix; i++) {
        double ax = (double)gx[i], ay = (double)gy[i];
        mag[i] = l2gradient ? (ax * ax + ay * ay) : (fabs(ax) + fabs(ay));
    }

    int32_t sp = 0;
    const double tg22 = 0.41421356237309505; // tan(22.5 deg)
    const double tg67 = 2.414213562373095;   // tan(67.5 deg)
    for (int32_t y = 0; y < h; y++) {
        for (int32_t x = 0; x < w; x++) {
            size_t idx = (size_t)y * w + x;
            double m = mag[idx];
            if (m <= lo) continue;
            double vx = (double)gx[idx], vy = (double)gy[idx];
            double avx = fabs(vx), avy = fabs(vy);
            double m1 = 0.0, m2 = 0.0;
            if (avy < avx * tg22) {
                // Horizontal gradient -> check left & right
                m1 = x > 0 ? mag[idx - 1] : 0.0;
                m2 = x + 1 < w ? mag[idx + 1] : 0.0;
                if (m > m1 && m >= m2) edge[idx] = (m > hi) ? 2 : 1;
            } else if (avy > avx * tg67) {
                // Vertical gradient -> check up & down
                m1 = y > 0 ? mag[idx - w] : 0.0;
                m2 = y + 1 < h ? mag[idx + w] : 0.0;
                if (m > m1 && m >= m2) edge[idx] = (m > hi) ? 2 : 1;
            } else {
                int32_t sgn = (vx * vy) > 0.0 ? 1 : -1;
                if (sgn > 0) {
                    m1 = (y > 0 && x > 0) ? mag[idx - w - 1] : 0.0;
                    m2 = (y + 1 < h && x + 1 < w) ? mag[idx + w + 1] : 0.0;
                } else {
                    m1 = (y > 0 && x + 1 < w) ? mag[idx - w + 1] : 0.0;
                    m2 = (y + 1 < h && x > 0) ? mag[idx + w - 1] : 0.0;
                }
                if (m > m1 && m > m2) edge[idx] = (m > hi) ? 2 : 1;
            }
            if (edge[idx] == 2) stack[sp++] = (int32_t)idx;
        }
    }

    while (sp > 0) {
        int32_t idx = stack[--sp];
        int32_t cx = idx % w, cy = idx / w;
        for (int32_t dy = -1; dy <= 1; dy++) {
            int32_t ny = cy + dy;
            if ((uint32_t)ny >= (uint32_t)h) continue;
            for (int32_t dx = -1; dx <= 1; dx++) {
                int32_t nx = cx + dx;
                if ((uint32_t)nx >= (uint32_t)w) continue;
                size_t ni = (size_t)ny * w + nx;
                if (edge[ni] == 1) {
                    edge[ni] = 2;
                    stack[sp++] = (int32_t)ni;
                }
            }
        }
    }

    for (int32_t y = 0; y < h; y++) {
        uint8_t *d = dst + (size_t)y * dstStride;
        for (int32_t x = 0; x < w; x++) d[x] = (edge[(size_t)y * w + x] == 2) ? 255 : 0;
    }

    free(gray); free(gx); free(gy); free(mag); free(edge); free(stack);
    return 0;
}

// MARK: - Integral (sum, sqsum, tilted)

static inline double read_sample(const uint8_t *row, int32_t idx, int32_t depth) {
    switch (depth) {
    case 0: return (double)row[idx];
    case 1: return (double)((const int8_t *)row)[idx];
    case 2: return (double)((const uint16_t *)row)[idx];
    case 3: return (double)((const int16_t *)row)[idx];
    case 4: return (double)((const int32_t *)row)[idx];
    case 5: return (double)((const float *)row)[idx];
    default: return ((const double *)row)[idx];
    }
}

static inline void write_sum(uint8_t *row, int32_t idx, int32_t depth, double val) {
    switch (depth) {
    case 4: ((int32_t *)row)[idx] = (int32_t)llround(val); break;
    case 5: ((float *)row)[idx] = (float)val; break;
    default: ((double *)row)[idx] = val; break;
    }
}

int32_t sr_c_integral(const void *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes, int32_t srcDepth,
                      void *sumDst, int32_t sumStrideBytes, int32_t sumDepth,
                      double *sqDst, int32_t sqStrideBytes,
                      void *tiltedDst, int32_t tiltedStrideBytes, int32_t tiltedDepth) {
    if (!src || !sumDst || w <= 0 || h <= 0 || ch < 1 || ch > 4) return -1;
    int32_t sw = w + 1, sh = h + 1;
    size_t bufN = (size_t)sw * (size_t)sh * (size_t)ch;
    double *sumBuf = (double *)calloc(bufN, sizeof(double));
    double *tilBuf = tiltedDst ? (double *)calloc(bufN, sizeof(double)) : NULL;
    if (!sumBuf || (tiltedDst && !tilBuf)) { free(sumBuf); free(tilBuf); return -1; }

    if (sqDst) {
        memset(sqDst, 0, sizeof(double) * (size_t)sw * (size_t)ch);
        for (int32_t y = 1; y < sh; y++) {
            double *sqRow = (double *)((uint8_t *)sqDst + (size_t)y * sqStrideBytes);
            for (int32_t c = 0; c < ch; c++) sqRow[c] = 0.0;
        }
    }

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *sr = (const uint8_t *)src + (size_t)y * srcStrideBytes;
        for (int32_t c = 0; c < ch; c++) {
            double rowSum = 0.0, rowSq = 0.0;
            for (int32_t x = 0; x < w; x++) {
                double v = read_sample(sr, x * ch + c, srcDepth);
                rowSum += v;
                size_t cur = ((size_t)(y + 1) * sw + (x + 1)) * ch + c;
                size_t up = ((size_t)y * sw + (x + 1)) * ch + c;
                sumBuf[cur] = sumBuf[up] + rowSum;
                if (sqDst) {
                    rowSq += v * v;
                    double *sqRow = (double *)((uint8_t *)sqDst + (size_t)(y + 1) * sqStrideBytes);
                    const double *sqUp = (const double *)((const uint8_t *)sqDst + (size_t)y * sqStrideBytes);
                    sqRow[(x + 1) * ch + c] = sqUp[(x + 1) * ch + c] + rowSq;
                }
            }
        }
    }

    for (int32_t y = 0; y < sh; y++) {
        uint8_t *dr = (uint8_t *)sumDst + (size_t)y * sumStrideBytes;
        for (int32_t x = 0; x < sw * ch; x++) {
            write_sum(dr, x, sumDepth, sumBuf[(size_t)y * sw * ch + x]);
        }
    }

    if (tiltedDst && tilBuf) {
        // Compute tilted integral cleanly via rotated coordinates: T(y, x) = sum_{dy>=1, |dx|<dy} ... matching OpenCV integral
        // Exact recurrence: T(y, x) = src(y-1, x-1) + src(y-1, x)? Let's use OpenCV's direct formula for y=1..h:
        // Wait: at row y=1, x=0..w: T(1, x) = x==0 ? 0 : src(0, x-1).
        // For y >= 2:
        //   x=0: T(y, 0) = T(y-1, 1) (plus src(y-1, 0) if OpenCV includes col 0? Wait check!)
        // Exact geometric definition of OpenCV tilted sum at (y, x): sum over pixels (r, c) with 0<=r<y and |c - (x - 1)| <= (y - 1 - r) ...?
        // Actually in OpenCV: tilted(y, x) = sum of pixels inside the 45-degree wedge whose bottom vertex is (y-1, x-1)!
        // Specifically: for y >= 1, let r = y-1. Bottom pixel in wedge is (y-1, x-1) (for 1<=x<=w).
        // Let's sum left/right diagonal strips cleanly!
        for (int32_t y = 1; y <= h; y++) {
            const uint8_t *sr = (const uint8_t *)src + (size_t)(y - 1) * srcStrideBytes;
            const uint8_t *srPrev = y >= 2 ? ((const uint8_t *)src + (size_t)(y - 2) * srcStrideBytes) : NULL;
            for (int32_t c = 0; c < ch; c++) {
                // T[y, 0]: OpenCV computes T(y, 0) = sum over r < y-1? No: T(y, 0) = T(y-1, 1) (diagonal up-right starting at col 0)!
                for (int32_t x = 0; x <= w; x++) {
                    double cur = (x > 0) ? read_sample(sr, (x - 1) * ch + c, srcDepth) : 0.0;
                    double prevUp = (srPrev && x > 0 && x <= w) ? read_sample(sr, (x - 1) * ch + c, srcDepth) : 0.0;
                    (void)prevUp;
                    double tLeft = (x > 0) ? tilBuf[((size_t)(y - 1) * sw + (x - 1)) * ch + c] : 0.0;
                    double tRight = (x < w) ? tilBuf[((size_t)(y - 1) * sw + (x + 1)) * ch + c] : 0.0;
                    double tUp2 = (y >= 2) ? tilBuf[((size_t)(y - 2) * sw + x) * ch + c] : 0.0;
                    // OpenCV recurrence for x>=1: T(y,x) = src(y-1,x-1) + T(y-1,x-1) + T(y-1,x+1) - T(y-2,x) + src(y-1,x)?
                    // Wait: pixel (y-1, x-1) covers left/right wings; notice T(y-1, x-1) and T(y-1, x+1) leave gap at (y-1, x-1) AND (y-2, x-1)?
                    // Exact non-overlapping union of two shifted wedges!
                    // Wedge(y, x) = {(r, c) | 0 <= r < y, x - (y - r) <= c < x + (y - r)}! Wait: at r=y-1: x-1 <= c < x+1 => c in {x-1, x} -> NO!
                    // OpenCV's tilted wedge at (y, x) starts at SINGLE pixel (y-1, x-1) at r=y-1!
                    // If at r=y-1 it has c = x-1, then at r=y-2 it has c in {x-2, x-1, x}.
                    // Compare Wedge(y-1, x-1) [at r=y-2: x-2] union Wedge(y-1, x+1) [at r=y-2: x] -> overlap starts at r=y-3 (c=x-2? Wait Wedge(y-1, x-1) at r=y-3 has c in {x-3,x-2,x-1} and Wedge(y-1, x+1) at r=y-3 has c in {x-1,x,x+1} -> overlap at r=y-3 is ONLY c=x-1!).
                    // Overlap of Wedge(y-1, x-1) and Wedge(y-1, x+1) IS Wedge(y-2, x) EXCEPT missing (y-2, x-1)!!
                    // Wait check r=y-2: (y-2, x-1) is NOT in Wedge(y-1, x-1) (whose tip is (y-2, x-2)) and NOT in Wedge(y-1, x+1) (whose tip is (y-2, x))!!
                    // SO: Wedge(y, x) = {(y-1, x-1), (y-2, x-1)} U Wedge(y-1, x-1) U Wedge(y-1, x+1) - Wedge(y-2, x) (no overlap at y-2!)
                    // Wait at r=y-2, if x=1: (y-2, 0) IS included!
                    double topMid = (y >= 2 && x > 0) ? read_sample(srPrev, (x - 1) * ch + c, srcDepth) : 0.0;
                    // For x == 0: check Wedge(y, 0) -> bottom tip (y-1, -1) outside, so r=y-2 has c in {-2,-1,0}, i.e. (y-2, 0)! T(y, 0) = T(y-1, 1)!
                    if (x == 0) {
                        tilBuf[((size_t)y * sw + 0) * ch + c] = tRight;
                    } else if (x == w) {
                        tilBuf[((size_t)y * sw + x) * ch + c] = tLeft + cur + topMid;
                    } else {
                        tilBuf[((size_t)y * sw + x) * ch + c] = cur + topMid + tLeft + tRight - tUp2;
                    }
                }
            }
        }
        for (int32_t y = 0; y < sh; y++) {
            uint8_t *tr = (uint8_t *)tiltedDst + (size_t)y * tiltedStrideBytes;
            for (int32_t x = 0; x < sw * ch; x++) {
                write_sum(tr, x, tiltedDepth, tilBuf[(size_t)y * sw * ch + x]);
            }
        }
    }

    free(sumBuf); free(tilBuf);
    return 0;
}

// MARK: - Rolling-row NEON Separable, Box, Filter2D, and pyrDown (Workstream 3a)

static inline double f_read_d(const void *row, int32_t idx, int32_t depth) {
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

static inline void f_write_d(void *row, int32_t idx, int32_t depth, double v) {
    switch (depth) {
    case SR_PERF_DEPTH_U8: {
        long r = lrint(v);
        ((uint8_t *)row)[idx] = (uint8_t)(r < 0 ? 0 : (r > 255 ? 255 : r));
        break;
    }
    case SR_PERF_DEPTH_S8: {
        long r = lrint(v);
        ((int8_t *)row)[idx] = (int8_t)(r < -128 ? -128 : (r > 127 ? 127 : r));
        break;
    }
    case SR_PERF_DEPTH_U16: {
        long r = lrint(v);
        ((uint16_t *)row)[idx] = (uint16_t)(r < 0 ? 0 : (r > 65535 ? 65535 : r));
        break;
    }
    case SR_PERF_DEPTH_S16: {
        long r = lrint(v);
        ((int16_t *)row)[idx] = (int16_t)(r < -32768 ? -32768 : (r > 32767 ? 32767 : r));
        break;
    }
    case SR_PERF_DEPTH_S32: {
        long long r = llrint(v);
        ((int32_t *)row)[idx] = (int32_t)(r < -2147483648LL ? -2147483648LL : (r > 2147483647LL ? 2147483647LL : r));
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

static inline void load_row_f32(const void *src, int32_t n, int32_t depth, float *out) {
    if (depth == SR_PERF_DEPTH_F32) { memcpy(out, src, sizeof(float) * (size_t)n); return; }
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
    } else if (depth == SR_PERF_DEPTH_U16) {
        const uint16_t *s = (const uint16_t *)src;
        for (; i + 8 <= n; i += 8) {
            uint16x8_t v = vld1q_u16(s + i);
            vst1q_f32(out + i + 0, vcvtq_f32_u32(vmovl_u16(vget_low_u16(v))));
            vst1q_f32(out + i + 4, vcvtq_f32_u32(vmovl_u16(vget_high_u16(v))));
        }
        for (; i < n; i++) out[i] = (float)s[i];
    } else {
        for (; i < n; i++) out[i] = (float)f_read_d(src, i, depth);
    }
}

static inline void store_row_f32_halfup(const float *acc, float delta, void *dst, int32_t n, int32_t depth) {
    if (depth == SR_PERF_DEPTH_F32) {
        if (delta == 0.0f) { memcpy(dst, acc, sizeof(float) * (size_t)n); return; }
        float32x4_t vd = vdupq_n_f32(delta);
        int32_t i = 0;
        for (; i + 16 <= n; i += 16) {
            for (int k = 0; k < 16; k += 4) vst1q_f32((float *)dst + i + k, vaddq_f32(vld1q_f32(acc + i + k), vd));
        }
        for (; i < n; i++) ((float *)dst)[i] = acc[i] + delta;
        return;
    }
    const float32x4_t v0 = vdupq_n_f32(0.0f);
    const float32x4_t vadd = vdupq_n_f32(delta + 0.5f);
    int32_t i = 0;
    if (depth == SR_PERF_DEPTH_U8) {
        uint8_t *d = (uint8_t *)dst;
        const float32x4_t v255 = vdupq_n_f32(255.0f);
        for (; i + 16 <= n; i += 16) {
            uint32x4_t a0 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i), vadd), v0), v255));
            uint32x4_t a1 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 4), vadd), v0), v255));
            uint32x4_t a2 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 8), vadd), v0), v255));
            uint32x4_t a3 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 12), vadd), v0), v255));
            uint16x8_t q0 = vcombine_u16(vmovn_u32(a0), vmovn_u32(a1));
            uint16x8_t q1 = vcombine_u16(vmovn_u32(a2), vmovn_u32(a3));
            vst1q_u8(d + i, vcombine_u8(vmovn_u16(q0), vmovn_u16(q1)));
        }
        for (; i < n; i++) {
            float t = acc[i] + delta + 0.5f;
            d[i] = t <= 0.0f ? 0 : (t >= 255.0f ? 255 : (uint8_t)t);
        }
    } else if (depth == SR_PERF_DEPTH_U16) {
        uint16_t *d = (uint16_t *)dst;
        const float32x4_t v65535 = vdupq_n_f32(65535.0f);
        for (; i + 8 <= n; i += 8) {
            uint32x4_t a0 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i), vadd), v0), v65535));
            uint32x4_t a1 = vcvtq_u32_f32(vminq_f32(vmaxq_f32(vaddq_f32(vld1q_f32(acc + i + 4), vadd), v0), v65535));
            vst1q_u16(d + i, vcombine_u16(vmovn_u32(a0), vmovn_u32(a1)));
        }
        for (; i < n; i++) {
            float t = acc[i] + delta + 0.5f;
            d[i] = t <= 0.0f ? 0 : (t >= 65535.0f ? 65535 : (uint16_t)t);
        }
    } else {
        for (; i < n; i++) f_write_d(dst, i, depth, (double)(acc[i] + delta));
    }
}

int32_t sr_c_sep_filter(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                        void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                        int32_t w, int32_t h, int32_t cn,
                        const double *kx, int32_t kw, const double *ky, int32_t kh,
                        int32_t ax, int32_t ay, double delta, int32_t border,
                        const double *bval_or_null, int32_t use_f32) {
    if (!src || !dst || !kx || !ky || w <= 0 || h <= 0 || cn <= 0 || kw <= 0 || kh <= 0) return -1;
    if (ax < 0) ax = kw / 2;
    if (ay < 0) ay = kh / 2;
    const int32_t n = w * cn;
    const int32_t nP = (n + 15) & ~15;
    double bv[4] = {0, 0, 0, 0};
    if (bval_or_null) for (int i = 0; i < 4; i++) bv[i] = bval_or_null[i];

    // If src == dst and border wraps/reflects past ring capacity, stage src safely.
    void *src_copy = NULL;
    if (src == dst && h > kh) {
        size_t rb = (size_t)n * (size_t)(sdepth == SR_PERF_DEPTH_U8 ? 1 : (sdepth <= SR_PERF_DEPTH_S16 ? 2 : (sdepth == SR_PERF_DEPTH_F64 ? 8 : 4)));
        src_copy = malloc(rb * (size_t)h);
        if (!src_copy) return -1;
        for (int32_t y = 0; y < h; y++) memcpy((uint8_t *)src_copy + (size_t)y * rb, (const uint8_t *)src + (ptrdiff_t)y * sstep_bytes, rb);
        src = src_copy;
        sstep_bytes = (ptrdiff_t)rb;
    }

    if (use_f32) {
        float *kxf = (float *)malloc(sizeof(float) * (size_t)kw);
        float *kyf = (float *)malloc(sizeof(float) * (size_t)kh);
        int32_t slots = kh < 4 ? 4 : kh;
        float *pad = (float *)calloc((size_t)(w + kw - 1) * (size_t)cn + 16, sizeof(float));
        float *ring = (float *)calloc((size_t)slots * (size_t)nP + 16, sizeof(float));
        float *const_row = (float *)calloc((size_t)nP + 16, sizeof(float));
        float *acc = (float *)calloc((size_t)nP + 16, sizeof(float));
        int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
        const float **rpts = (const float **)malloc(sizeof(float *) * (size_t)kh);
        if (!kxf || !kyf || !pad || !ring || !const_row || !acc || !keys || !rpts) {
            free(kxf); free(kyf); free(pad); free(ring); free(const_row); free(acc); free(keys); free(rpts); free(src_copy);
            return -1;
        }
        float sum_kx = 0.0f;
        for (int32_t k = 0; k < kw; k++) { kxf[k] = (float)kx[k]; sum_kx += kxf[k]; }
        for (int32_t k = 0; k < kh; k++) kyf[k] = (float)ky[k];
        for (int32_t i = 0; i < slots; i++) keys[i] = -1;
        for (int32_t x = 0; x < w; x++) for (int32_t c = 0; c < cn; c++) const_row[x * cn + c] = (float)bv[c < 4 ? c : 0] * sum_kx;

        int32_t left = ax, right = kw - 1 - ax;
        for (int32_t y = 0; y < h; y++) {
            for (int32_t j = 0; j < kh; j++) {
                int32_t sy = border_idx(y + j - ay, h, border);
                if (sy < 0) { rpts[j] = const_row; continue; }
                int32_t slot = sy % slots;
                float *rr = ring + (size_t)slot * (size_t)nP;
                if (keys[slot] != sy) {
                    const void *sr = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                    load_row_f32(sr, n, sdepth, pad + (size_t)left * (size_t)cn);
                    for (int32_t q = 0; q < left; q++) {
                        int32_t sx = border_idx(q - left, w, border);
                        for (int32_t c = 0; c < cn; c++)
                            pad[q * cn + c] = sx < 0 ? (float)bv[c < 4 ? c : 0] : pad[(left + sx) * cn + c];
                    }
                    for (int32_t q = 0; q < right; q++) {
                        int32_t sx = border_idx(w + q, w, border);
                        for (int32_t c = 0; c < cn; c++)
                            pad[(left + w + q) * cn + c] = sx < 0 ? (float)bv[c < 4 ? c : 0] : pad[(left + sx) * cn + c];
                    }
                    for (int32_t i = 0; i < nP; i += 16) {
                        float32x4_t a0 = vdupq_n_f32(0), a1 = a0, a2 = a0, a3 = a0;
                        const float *p = pad + i;
                        for (int32_t k = 0; k < kw; k++, p += cn) {
                            float32x4_t kv = vdupq_n_f32(kxf[k]);
                            a0 = vfmaq_f32(a0, vld1q_f32(p + 0), kv);
                            a1 = vfmaq_f32(a1, vld1q_f32(p + 4), kv);
                            a2 = vfmaq_f32(a2, vld1q_f32(p + 8), kv);
                            a3 = vfmaq_f32(a3, vld1q_f32(p + 12), kv);
                        }
                        vst1q_f32(rr + i + 0, a0);
                        vst1q_f32(rr + i + 4, a1);
                        vst1q_f32(rr + i + 8, a2);
                        vst1q_f32(rr + i + 12, a3);
                    }
                    keys[slot] = sy;
                }
                rpts[j] = rr;
            }
            for (int32_t i = 0; i < nP; i += 16) {
                float32x4_t a0 = vdupq_n_f32(0), a1 = a0, a2 = a0, a3 = a0;
                for (int32_t j = 0; j < kh; j++) {
                    float32x4_t kv = vdupq_n_f32(kyf[j]);
                    const float *p = rpts[j] + i;
                    a0 = vfmaq_f32(a0, vld1q_f32(p + 0), kv);
                    a1 = vfmaq_f32(a1, vld1q_f32(p + 4), kv);
                    a2 = vfmaq_f32(a2, vld1q_f32(p + 8), kv);
                    a3 = vfmaq_f32(a3, vld1q_f32(p + 12), kv);
                }
                vst1q_f32(acc + i + 0, a0);
                vst1q_f32(acc + i + 4, a1);
                vst1q_f32(acc + i + 8, a2);
                vst1q_f32(acc + i + 12, a3);
            }
            store_row_f32_halfup(acc, (float)delta, (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes, n, ddepth);
        }
        free(kxf); free(kyf); free(pad); free(ring); free(const_row); free(acc); free(keys); free(rpts); free(src_copy);
        return 0;
    }

    // Full-precision double streaming kh-row ring (for Sobel / Scharr / sepFilter2D full-depth)
    const int32_t nD = (n + 7) & ~7;
    int32_t slots = kh < 4 ? 4 : kh;
    double *pad = (double *)calloc((size_t)(w + kw - 1) * (size_t)cn + 8, sizeof(double));
    double *ring = (double *)calloc((size_t)slots * (size_t)nD + 8, sizeof(double));
    double *acc = (double *)calloc((size_t)nD + 8, sizeof(double));
    int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
    const double **rpts = (const double **)malloc(sizeof(double *) * (size_t)kh);
    if (!pad || !ring || !acc || !keys || !rpts) {
        free(pad); free(ring); free(acc); free(keys); free(rpts); free(src_copy);
        return -1;
    }
    for (int32_t i = 0; i < slots; i++) keys[i] = -1;
    int32_t left = ax, right = kw - 1 - ax;

    for (int32_t y = 0; y < h; y++) {
        int32_t nact = 0;
        double ky_act[64];
        double *ky_dyn = kh > 64 ? (double *)malloc(sizeof(double) * (size_t)kh) : ky_act;
        if (!ky_dyn) { free(pad); free(ring); free(acc); free(keys); free(rpts); free(src_copy); return -1; }
        for (int32_t j = 0; j < kh; j++) {
            int32_t sy = border_idx(y + j - ay, h, border);
            if (sy < 0) continue;
            int32_t slot = sy % slots;
            double *rr = ring + (size_t)slot * (size_t)nD;
            if (keys[slot] != sy) {
                const void *sr = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                for (int32_t i = 0; i < n; i++) pad[left * cn + i] = f_read_d(sr, i, sdepth);
                for (int32_t q = 0; q < left; q++) {
                    int32_t sx = border_idx(q - left, w, border);
                    for (int32_t c = 0; c < cn; c++) pad[q * cn + c] = sx < 0 ? 0.0 : pad[(left + sx) * cn + c];
                }
                for (int32_t q = 0; q < right; q++) {
                    int32_t sx = border_idx(w + q, w, border);
                    for (int32_t c = 0; c < cn; c++) pad[(left + w + q) * cn + c] = sx < 0 ? 0.0 : pad[(left + sx) * cn + c];
                }
                for (int32_t i = 0; i < nD; i += 8) {
                    float64x2_t a0 = vdupq_n_f64(0), a1 = a0, a2 = a0, a3 = a0;
                    const double *p = pad + i;
                    for (int32_t k = 0; k < kw; k++, p += cn) {
                        float64x2_t kv = vdupq_n_f64(kx[k]);
                        a0 = vfmaq_f64(a0, vld1q_f64(p + 0), kv);
                        a1 = vfmaq_f64(a1, vld1q_f64(p + 2), kv);
                        a2 = vfmaq_f64(a2, vld1q_f64(p + 4), kv);
                        a3 = vfmaq_f64(a3, vld1q_f64(p + 6), kv);
                    }
                    vst1q_f64(rr + i + 0, a0); vst1q_f64(rr + i + 2, a1);
                    vst1q_f64(rr + i + 4, a2); vst1q_f64(rr + i + 6, a3);
                }
                keys[slot] = sy;
            }
            rpts[nact] = rr;
            ky_dyn[nact] = ky[j];
            nact++;
        }
        for (int32_t i = 0; i < nD; i += 8) {
            float64x2_t a0 = vdupq_n_f64(delta), a1 = a0, a2 = a0, a3 = a0;
            for (int32_t j = 0; j < nact; j++) {
                float64x2_t kv = vdupq_n_f64(ky_dyn[j]);
                const double *p = rpts[j] + i;
                a0 = vfmaq_f64(a0, vld1q_f64(p + 0), kv);
                a1 = vfmaq_f64(a1, vld1q_f64(p + 2), kv);
                a2 = vfmaq_f64(a2, vld1q_f64(p + 4), kv);
                a3 = vfmaq_f64(a3, vld1q_f64(p + 6), kv);
            }
            vst1q_f64(acc + i + 0, a0); vst1q_f64(acc + i + 2, a1);
            vst1q_f64(acc + i + 4, a2); vst1q_f64(acc + i + 6, a3);
        }
        if (ky_dyn != ky_act) free(ky_dyn);
        void *dr = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
        for (int32_t i = 0; i < n; i++) f_write_d(dr, i, ddepth, acc[i]);
    }
    free(pad); free(ring); free(acc); free(keys); free(rpts); free(src_copy);
    return 0;
}

int32_t sr_c_box_filter(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                        void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                        int32_t w, int32_t h, int32_t cn,
                        int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                        int32_t normalize, int32_t border) {
    if (!src || !dst || w <= 0 || h <= 0 || cn <= 0 || kw <= 0 || kh <= 0) return -1;
    if (ax < 0) ax = kw / 2;
    if (ay < 0) ay = kh / 2;
    const int32_t n = w * cn;
    const double scale = normalize ? (1.0 / ((double)kw * (double)kh)) : 1.0;

    // Rolling ring of kh+1 horizontal-summed rows + O(1) vertical colAcc (zero full-frame allocation!)
    int32_t slots = kh + 2;
    double *rowD = (double *)malloc(sizeof(double) * (size_t)n);
    double *ring = (double *)calloc((size_t)slots * (size_t)n, sizeof(double));
    int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
    double *colAcc = (double *)calloc((size_t)n, sizeof(double));
    double *zeros = (double *)calloc((size_t)n, sizeof(double));
    if (!rowD || !ring || !keys || !colAcc || !zeros) {
        free(rowD); free(ring); free(keys); free(colAcc); free(zeros);
        return -1;
    }
    for (int32_t i = 0; i < slots; i++) keys[i] = -1;

    // Helper macro to get horizontal-summed row for source index sy
    #define GET_HROW(sy_expr, out_ptr) do { \
        int32_t _sy = (sy_expr); \
        if (_sy < 0) { (out_ptr) = zeros; } \
        else { \
            int32_t _slot = _sy % slots; \
            double *_tr = ring + (size_t)_slot * (size_t)n; \
            if (keys[_slot] != _sy) { \
                const void *_sr = (const uint8_t *)src + (ptrdiff_t)_sy * sstep_bytes; \
                for (int32_t _i = 0; _i < n; _i++) rowD[_i] = f_read_d(_sr, _i, sdepth); \
                for (int32_t _c = 0; _c < cn; _c++) { \
                    double _acc = 0.0; \
                    for (int32_t _k = 0; _k < kw; _k++) { \
                        int32_t _rx = border_idx(_k - ax, w, border); \
                        if (_rx >= 0) _acc += rowD[_rx * cn + _c]; \
                    } \
                    _tr[_c] = _acc; \
                    for (int32_t _x = 1; _x < w; _x++) { \
                        int32_t _rOut = border_idx(_x - 1 - ax, w, border); \
                        int32_t _rIn = border_idx(_x + kw - 1 - ax, w, border); \
                        if (_rOut >= 0) _acc -= rowD[_rOut * cn + _c]; \
                        if (_rIn >= 0) _acc += rowD[_rIn * cn + _c]; \
                        _tr[_x * cn + _c] = _acc; \
                    } \
                } \
                keys[_slot] = _sy; \
            } \
            (out_ptr) = _tr; \
        } \
    } while (0)

    for (int32_t k = 0; k < kh; k++) {
        const double *hr;
        GET_HROW(border_idx(k - ay, h, border), hr);
        if (hr != zeros) for (int32_t i = 0; i < n; i++) colAcc[i] += hr[i];
    }
    for (int32_t y = 0; y < h; y++) {
        void *dr = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
        if (ddepth == SR_PERF_DEPTH_U8 && scale != 1.0) {
            for (int32_t i = 0; i < n; i++) f_write_d(dr, i, ddepth, colAcc[i] * scale);
        } else {
            for (int32_t i = 0; i < n; i++) f_write_d(dr, i, ddepth, colAcc[i] * scale);
        }
        if (y + 1 < h) {
            const double *hOut, *hIn;
            GET_HROW(border_idx(y - ay, h, border), hOut);
            GET_HROW(border_idx(y + kh - ay, h, border), hIn);
            int32_t i = 0;
            if (hOut != zeros && hIn != zeros) {
                for (; i + 2 <= n; i += 2) {
                    float64x2_t c = vld1q_f64(colAcc + i);
                    c = vaddq_f64(vsubq_f64(c, vld1q_f64(hOut + i)), vld1q_f64(hIn + i));
                    vst1q_f64(colAcc + i, c);
                }
                for (; i < n; i++) colAcc[i] += hIn[i] - hOut[i];
            } else if (hOut != zeros) {
                for (; i < n; i++) colAcc[i] -= hOut[i];
            } else if (hIn != zeros) {
                for (; i < n; i++) colAcc[i] += hIn[i];
            }
        }
    }
    #undef GET_HROW
    free(rowD); free(ring); free(keys); free(colAcc); free(zeros);
    return 0;
}

int32_t sr_c_filter2d(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                      void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                      int32_t w, int32_t h, int32_t cn,
                      const double *kernel, int32_t kw, int32_t kh,
                      int32_t ax, int32_t ay, double delta, int32_t border) {
    if (!src || !dst || !kernel || w <= 0 || h <= 0 || cn <= 0 || kw <= 0 || kh <= 0) return -1;
    if (ax < 0) ax = kw / 2;
    if (ay < 0) ay = kh / 2;
    const int32_t n = w * cn;
    const int32_t pn = (w + kw - 1) * cn;
    const int32_t nD = (n + 7) & ~7;
    int32_t left = ax, right = kw - 1 - ax;

    void *src_copy = NULL;
    if (src == dst && h > kh) {
        size_t rb = (size_t)n * (size_t)(sdepth == SR_PERF_DEPTH_U8 ? 1 : (sdepth <= SR_PERF_DEPTH_S16 ? 2 : (sdepth == SR_PERF_DEPTH_F64 ? 8 : 4)));
        src_copy = malloc(rb * (size_t)h);
        if (!src_copy) return -1;
        for (int32_t y = 0; y < h; y++) memcpy((uint8_t *)src_copy + (size_t)y * rb, (const uint8_t *)src + (ptrdiff_t)y * sstep_bytes, rb);
        src = src_copy;
        sstep_bytes = (ptrdiff_t)rb;
    }

    int32_t slots = kh < 4 ? 4 : kh;
    double *ring = (double *)calloc((size_t)slots * (size_t)(pn + 8), sizeof(double));
    double *zeros = (double *)calloc((size_t)(pn + 8), sizeof(double));
    double *acc = (double *)calloc((size_t)nD + 8, sizeof(double));
    int32_t *keys = (int32_t *)malloc(sizeof(int32_t) * (size_t)slots);
    const double **rpts = (const double **)malloc(sizeof(double *) * (size_t)kh);
    if (!ring || !zeros || !acc || !keys || !rpts) {
        free(ring); free(zeros); free(acc); free(keys); free(rpts); free(src_copy);
        return -1;
    }
    for (int32_t i = 0; i < slots; i++) keys[i] = -1;
    const int32_t pstride = pn + 8;

    for (int32_t y = 0; y < h; y++) {
        for (int32_t ky = 0; ky < kh; ky++) {
            int32_t sy = border_idx(y + ky - ay, h, border);
            if (sy < 0) { rpts[ky] = zeros; continue; }
            int32_t slot = sy % slots;
            double *pad = ring + (size_t)slot * (size_t)pstride;
            if (keys[slot] != sy) {
                const void *sr = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                for (int32_t i = 0; i < n; i++) pad[left * cn + i] = f_read_d(sr, i, sdepth);
                for (int32_t q = 0; q < left; q++) {
                    int32_t sx = border_idx(q - left, w, border);
                    for (int32_t c = 0; c < cn; c++) pad[q * cn + c] = sx < 0 ? 0.0 : pad[(left + sx) * cn + c];
                }
                for (int32_t q = 0; q < right; q++) {
                    int32_t sx = border_idx(w + q, w, border);
                    for (int32_t c = 0; c < cn; c++) pad[(left + w + q) * cn + c] = sx < 0 ? 0.0 : pad[(left + sx) * cn + c];
                }
                keys[slot] = sy;
            }
            rpts[ky] = pad;
        }
        int32_t i = 0;
        for (; i + 8 <= n; i += 8) {
            float64x2_t a0 = vdupq_n_f64(delta), a1 = a0, a2 = a0, a3 = a0;
            for (int32_t ky = 0; ky < kh; ky++) {
                const double *rp = rpts[ky] + i;
                const double *kr = kernel + ky * kw;
                for (int32_t kx = 0; kx < kw; kx++, rp += cn) {
                    double kv_s = kr[kx];
                    if (kv_s == 0.0) continue;
                    float64x2_t kv = vdupq_n_f64(kv_s);
                    a0 = vfmaq_f64(a0, vld1q_f64(rp + 0), kv);
                    a1 = vfmaq_f64(a1, vld1q_f64(rp + 2), kv);
                    a2 = vfmaq_f64(a2, vld1q_f64(rp + 4), kv);
                    a3 = vfmaq_f64(a3, vld1q_f64(rp + 6), kv);
                }
            }
            vst1q_f64(acc + i + 0, a0); vst1q_f64(acc + i + 2, a1);
            vst1q_f64(acc + i + 4, a2); vst1q_f64(acc + i + 6, a3);
        }
        for (; i < n; i++) {
            double s = delta;
            for (int32_t ky = 0; ky < kh; ky++) {
                const double *rp = rpts[ky] + i;
                const double *kr = kernel + ky * kw;
                for (int32_t kx = 0; kx < kw; kx++) s += kr[kx] * rp[kx * cn];
            }
            acc[i] = s;
        }
        void *dr = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
        for (int32_t j = 0; j < n; j++) f_write_d(dr, j, ddepth, acc[j]);
    }
    free(ring); free(zeros); free(acc); free(keys); free(rpts); free(src_copy);
    return 0;
}

int32_t sr_c_pyr_down(const void *src, ptrdiff_t sstep_bytes, int32_t depth,
                      void *dst, ptrdiff_t dstep_bytes,
                      int32_t sw, int32_t sh, int32_t dw, int32_t dh, int32_t cn, int32_t border) {
    if (!src || !dst || sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || cn <= 0) return -1;
    const int32_t n = dw * cn;

    if (depth == SR_PERF_DEPTH_U8) {
        // Exact integer [1, 4, 6, 4, 1] 16-bit NEON rolling 5-row ring (max value 16*16*255 = 65280 <= UINT16_MAX!)
        int32_t pn = (sw + 4) * cn;
        uint8_t *pad = (uint8_t *)calloc((size_t)pn + 64, 1);
        int32_t nP = (n + 15) & ~15;
        uint16_t *ring = (uint16_t *)calloc(8u * (size_t)nP, sizeof(uint16_t));
        int32_t keys[8] = {-1,-1,-1,-1,-1,-1,-1,-1};
        if (!pad || !ring) { free(pad); free(ring); return -1; }
        for (int32_t y = 0; y < dh; y++) {
            const uint16_t *rows[5];
            for (int32_t j = 0; j < 5; j++) {
                int32_t sy = border_idx(2 * y + j - 2, sh, border);
                if (sy < 0) sy = 0;
                int32_t slot = sy & 7;
                uint16_t *rr = ring + (size_t)slot * (size_t)nP;
                if (keys[slot] != sy) {
                    const uint8_t *sr = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                    memcpy(pad + (ptrdiff_t)2 * cn, sr, (size_t)sw * (size_t)cn);
                    for (int32_t q = 0; q < 2; q++) {
                        int32_t l = border_idx(q - 2, sw, border), r = border_idx(sw + q, sw, border);
                        for (int32_t c = 0; c < cn; c++) {
                            pad[q * cn + c] = l < 0 ? 0 : pad[(l + 2) * cn + c];
                            pad[(sw + 2 + q) * cn + c] = r < 0 ? 0 : pad[(r + 2) * cn + c];
                        }
                    }
                    if (cn == 1) {
                        int32_t x = 0;
                        for (; x + 16 <= dw && 2 * (x + 16) + 2 < sw + 4; x += 16) {
                            uint8x16x2_t a0 = vld2q_u8(pad + 2 * x);
                            uint8x16x2_t a1 = vld2q_u8(pad + 2 * x + 2);
                            uint8x16x2_t a2 = vld2q_u8(pad + 2 * x + 4);
                            uint16x8_t e0l = vmovl_u8(vget_low_u8(a0.val[0])), e0h = vmovl_u8(vget_high_u8(a0.val[0]));
                            uint16x8_t o0l = vmovl_u8(vget_low_u8(a0.val[1])), o0h = vmovl_u8(vget_high_u8(a0.val[1]));
                            uint16x8_t e1l = vmovl_u8(vget_low_u8(a1.val[0])), e1h = vmovl_u8(vget_high_u8(a1.val[0]));
                            uint16x8_t o1l = vmovl_u8(vget_low_u8(a1.val[1])), o1h = vmovl_u8(vget_high_u8(a1.val[1]));
                            uint16x8_t e2l = vmovl_u8(vget_low_u8(a2.val[0])), e2h = vmovl_u8(vget_high_u8(a2.val[0]));
                            uint16x8_t sl = vaddq_u16(vaddq_u16(vaddq_u16(e0l, e2l), vshlq_n_u16(vaddq_u16(o0l, o1l), 2)),
                                                      vaddq_u16(vshlq_n_u16(e1l, 2), vshlq_n_u16(e1l, 1)));
                            uint16x8_t sh = vaddq_u16(vaddq_u16(vaddq_u16(e0h, e2h), vshlq_n_u16(vaddq_u16(o0h, o1h), 2)),
                                                      vaddq_u16(vshlq_n_u16(e1h, 2), vshlq_n_u16(e1h, 1)));
                            vst1q_u16(rr + x, sl);
                            vst1q_u16(rr + x + 8, sh);
                        }
                        for (; x < dw; x++) {
                            const uint8_t *p = pad + 2 * x;
                            rr[x] = (uint16_t)(p[0] + 4 * p[1] + 6 * p[2] + 4 * p[3] + p[4]);
                        }
                    } else if (cn == 3) {
                        int32_t x = 0;
                        for (; x + 8 <= dw && 2 * x + 23 < sw + 4; x += 8) {
                            uint8x16x3_t p0 = vld3q_u8(pad + (ptrdiff_t)6 * x);
                            uint8x8x3_t  p1 = vld3_u8(pad + (ptrdiff_t)6 * x + 48);
                            #define PYR_U8_CH(c, dstv) do { \
                                uint8x16_t v16 = p0.val[c]; \
                                uint8x8_t lo = vget_low_u8(v16), hi = vget_high_u8(v16); \
                                uint8x8_t h8 = p1.val[c], z = vdup_n_u8(0); \
                                uint8x8_t e0 = vuzp1_u8(lo, hi); \
                                uint8x8_t o0 = vuzp2_u8(lo, hi); \
                                uint8x8_t eh = vuzp1_u8(h8, z); \
                                uint8x8_t oh = vuzp2_u8(h8, z); \
                                uint16x8_t we0 = vmovl_u8(e0); \
                                uint16x8_t wo0 = vmovl_u8(o0); \
                                uint16x8_t we1 = vmovl_u8(vext_u8(e0, eh, 1)); \
                                uint16x8_t wo1 = vmovl_u8(vext_u8(o0, oh, 1)); \
                                uint16x8_t we2 = vmovl_u8(vext_u8(e0, eh, 2)); \
                                (dstv) = vaddq_u16(vaddq_u16(vaddq_u16(we0, we2), vshlq_n_u16(vaddq_u16(wo0, wo1), 2)), \
                                                   vaddq_u16(vshlq_n_u16(we1, 2), vshlq_n_u16(we1, 1))); \
                            } while (0)
                            uint16x8x3_t out;
                            PYR_U8_CH(0, out.val[0]);
                            PYR_U8_CH(1, out.val[1]);
                            PYR_U8_CH(2, out.val[2]);
                            #undef PYR_U8_CH
                            vst3q_u16(rr + (ptrdiff_t)x * 3, out);
                        }
                        for (; x < dw; x++) {
                            const uint8_t *p = pad + (ptrdiff_t)2 * x * 3;
                            rr[x * 3 + 0] = (uint16_t)(p[0] + 4 * p[3] + 6 * p[6] + 4 * p[9]  + p[12]);
                            rr[x * 3 + 1] = (uint16_t)(p[1] + 4 * p[4] + 6 * p[7] + 4 * p[10] + p[13]);
                            rr[x * 3 + 2] = (uint16_t)(p[2] + 4 * p[5] + 6 * p[8] + 4 * p[11] + p[14]);
                        }
                    } else {
                        for (int32_t x = 0; x < dw; x++) {
                            const uint8_t *p = pad + (ptrdiff_t)2 * x * cn;
                            for (int32_t c = 0; c < cn; c++)
                                rr[x * cn + c] = (uint16_t)(p[c] + 4 * p[cn + c] + 6 * p[2 * cn + c] + 4 * p[3 * cn + c] + p[4 * cn + c]);
                        }
                    }
                    keys[slot] = sy;
                }
                rows[j] = rr;
            }
            uint8_t *dr = (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes;
            const uint16_t *r0 = rows[0], *r1 = rows[1], *r2 = rows[2], *r3 = rows[3], *r4 = rows[4];
            int32_t i = 0;
            for (; i + 8 <= n; i += 8) {
                uint16x8_t v0 = vld1q_u16(r0 + i), v4 = vld1q_u16(r4 + i);
                uint16x8_t v1 = vld1q_u16(r1 + i), v3 = vld1q_u16(r3 + i);
                uint16x8_t v2 = vld1q_u16(r2 + i);
                uint16x8_t s04 = vaddq_u16(v0, v4);
                uint16x8_t s13 = vshlq_n_u16(vaddq_u16(v1, v3), 2);
                uint16x8_t s2  = vaddq_u16(vshlq_n_u16(v2, 2), vshlq_n_u16(v2, 1));
                uint16x8_t sum = vaddq_u16(vaddq_u16(s04, s13), s2);
                vst1_u8(dr + i, vrshrn_n_u16(sum, 8));
            }
            for (; i < n; i++) {
                uint32_t s = (uint32_t)r0[i] + 4u * r1[i] + 6u * r2[i] + 4u * r3[i] + r4[i];
                dr[i] = (uint8_t)((s + 128u) >> 8);
            }
        }
        free(pad); free(ring);
        return 0;
    }

    // Float / U16 5-row rolling ring
    const int32_t nP = (n + 15) & ~15;
    float *pad = (float *)calloc((size_t)(sw + 4) * (size_t)cn + 32, sizeof(float));
    float *ring = (float *)calloc(8u * (size_t)nP + 16, sizeof(float));
    float *acc = (float *)calloc((size_t)nP + 16, sizeof(float));
    int32_t keys[8] = {-1,-1,-1,-1,-1,-1,-1,-1};
    if (!pad || !ring || !acc) { free(pad); free(ring); free(acc); return -1; }
    const float wv = 1.0f / 256.0f, w4 = 4.0f / 256.0f, w6 = 6.0f / 256.0f;

    for (int32_t y = 0; y < dh; y++) {
        const float *rows[5];
        for (int32_t j = 0; j < 5; j++) {
            int32_t sy = border_idx(2 * y + j - 2, sh, border);
            if (sy < 0) sy = 0;
            int32_t slot = sy & 7;
            float *rr = ring + (size_t)slot * (size_t)nP;
            if (keys[slot] != sy) {
                const void *sr = (const uint8_t *)src + (ptrdiff_t)sy * sstep_bytes;
                load_row_f32(sr, sw * cn, depth, pad + (ptrdiff_t)2 * cn);
                for (int32_t q = 0; q < 2; q++) {
                    int32_t l = border_idx(q - 2, sw, border), r = border_idx(sw + q, sw, border);
                    for (int32_t c = 0; c < cn; c++) {
                        pad[q * cn + c] = l < 0 ? 0.0f : pad[(l + 2) * cn + c];
                        pad[(sw + 2 + q) * cn + c] = r < 0 ? 0.0f : pad[(r + 2) * cn + c];
                    }
                }
                if (cn == 1) {
                    int32_t x = 0;
                    const float32x4_t f4 = vdupq_n_f32(4.0f), f6 = vdupq_n_f32(6.0f);
                    for (; x + 4 <= dw && 2 * x + 12 <= sw + 4; x += 4) {
                        float32x4x2_t a = vld2q_f32(pad + 2 * x);
                        float32x2x2_t b = vld2_f32(pad + 2 * x + 8);
                        float32x4_t eb = vcombine_f32(b.val[0], vdup_n_f32(0.0f));
                        float32x4_t ob = vcombine_f32(b.val[1], vdup_n_f32(0.0f));
                        float32x4_t e0 = a.val[0], o0 = a.val[1];
                        float32x4_t e1 = vextq_f32(e0, eb, 1), o1 = vextq_f32(o0, ob, 1);
                        float32x4_t e2 = vextq_f32(e0, eb, 2);
                        float32x4_t s = vaddq_f32(vaddq_f32(e0, e2), vmulq_f32(vaddq_f32(o0, o1), f4));
                        s = vfmaq_f32(s, e1, f6);
                        vst1q_f32(rr + x, s);
                    }
                    for (; x < dw; x++) {
                        const float *p = pad + 2 * x;
                        rr[x] = p[0] + 4.0f * p[1] + 6.0f * p[2] + 4.0f * p[3] + p[4];
                    }
                } else {
                    for (int32_t x = 0; x < dw; x++) {
                        const float *p = pad + (ptrdiff_t)2 * x * cn;
                        for (int32_t c = 0; c < cn; c++)
                            rr[x * cn + c] = p[c] + 4.0f * p[cn + c] + 6.0f * p[2 * cn + c] + 4.0f * p[3 * cn + c] + p[4 * cn + c];
                    }
                }
                keys[slot] = sy;
            }
            rows[j] = rr;
        }
        const float *r0 = rows[0], *r1 = rows[1], *r2 = rows[2], *r3 = rows[3], *r4 = rows[4];
        float32x4_t vw1 = vdupq_n_f32(wv), vw4 = vdupq_n_f32(w4), vw6 = vdupq_n_f32(w6);
        for (int32_t i = 0; i < nP; i += 4) {
            float32x4_t s = vmulq_f32(vaddq_f32(vld1q_f32(r0 + i), vld1q_f32(r4 + i)), vw1);
            s = vfmaq_f32(s, vaddq_f32(vld1q_f32(r1 + i), vld1q_f32(r3 + i)), vw4);
            s = vfmaq_f32(s, vld1q_f32(r2 + i), vw6);
            vst1q_f32(acc + i, s);
        }
        store_row_f32_halfup(acc, 0.0f, (uint8_t *)dst + (ptrdiff_t)y * dstep_bytes, n, depth);
    }
    free(pad); free(ring); free(acc);
    return 0;
}
