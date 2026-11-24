// SafariumRasterC — Phase 3 C kernels: colormap, equalizeHist, CLAHE, median, bilateral, Canny, integral.
#include "include/sr_ops.h"
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
    uint64_t hist[256] = {0};
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *s = src + (size_t)y * (size_t)srcStride;
        for (int32_t x = 0; x < w; x++) hist[s[x]]++;
    }
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
        for (int32_t x = 0; x < w; x++) d[x] = lut[s[x]];
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

#define SWAP(T, a, b) do { T _t = (a); (a) = (b); (b) = _t; } while(0)

static inline float median9_f32(float p[9]) {
    SWAP(float, p[1], p[2]); SWAP(float, p[4], p[5]); SWAP(float, p[7], p[8]);
    if (p[0] > p[1]) SWAP(float, p[0], p[1]); if (p[3] > p[4]) SWAP(float, p[3], p[4]); if (p[6] > p[7]) SWAP(float, p[6], p[7]);
    if (p[1] > p[2]) SWAP(float, p[1], p[2]); if (p[4] > p[5]) SWAP(float, p[4], p[5]); if (p[7] > p[8]) SWAP(float, p[7], p[8]);
    if (p[0] > p[3]) p[0] = p[3]; if (p[5] > p[8]) p[8] = p[5]; if (p[4] > p[7]) SWAP(float, p[4], p[7]);
    if (p[3] > p[6]) p[6] = p[3]; if (p[1] > p[4]) SWAP(float, p[1], p[4]); if (p[2] > p[5]) p[2] = p[5];
    if (p[4] > p[7]) SWAP(float, p[4], p[7]);
    if (p[4] < p[2]) { if (p[2] < p[6]) return p[2]; return p[4] < p[6] ? p[6] : p[4]; }
    if (p[4] < p[6]) return p[4]; return p[2] < p[6] ? p[6] : p[2];
}

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

int32_t sr_c_median_u8(const uint8_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStride,
                       uint8_t *dst, int32_t dstStride, int32_t ksize) {
    if (!src || !dst || w <= 0 || h <= 0 || ksize < 1 || (ksize % 2) == 0) return -1;
    if (ksize == 1) {
        for (int32_t y = 0; y < h; y++) memcpy(dst + (size_t)y * dstStride, src + (size_t)y * srcStride, (size_t)w * ch);
        return 0;
    }
    if (ksize == 3) {
        for (int32_t y = 0; y < h; y++) {
            int32_t ym = y > 0 ? y - 1 : 0, yp = y + 1 < h ? y + 1 : h - 1;
            const uint8_t *r0 = src + (size_t)ym * srcStride;
            const uint8_t *r1 = src + (size_t)y * srcStride;
            const uint8_t *r2 = src + (size_t)yp * srcStride;
            uint8_t *d = dst + (size_t)y * dstStride;
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
            for (int32_t x = 0; x < w; x++) {
                int32_t acc = 0, med = 0;
                while (med < 255) { acc += hist[med]; if (acc > halfN) break; med++; }
                d[x * ch + c] = (uint8_t)med;
                if (x + 1 < w) {
                    int32_t xOut = x - rad < 0 ? 0 : x - rad;
                    int32_t xIn = x + rad + 1 >= w ? w - 1 : x + rad + 1;
                    for (int32_t dy = -rad; dy <= rad; dy++) {
                        int32_t sy = y + dy < 0 ? 0 : (y + dy >= h ? h - 1 : y + dy);
                        const uint8_t *row = src + (size_t)sy * srcStride;
                        hist[row[xOut * ch + c]]--;
                        hist[row[xIn * ch + c]]++;
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
        const uint8_t *sRow = src + (size_t)y * srcStride;
        uint8_t *dRow = dst + (size_t)y * dstStride;
        for (int32_t x = 0; x < w; x++) {
            if (ch == 1) {
                int32_t c0 = sRow[x];
                float sum = 0.0f, wsum = 0.0f;
                for (int k = 0; k < nPts; k++) {
                    int32_t sy = border_idx(y + dyA[k], h, borderMode);
                    int32_t sx = border_idx(x + dxA[k], w, borderMode);
                    int32_t v = (sy < 0 || sx < 0) ? 0 : src[(size_t)sy * srcStride + sx];
                    int32_t d = v - c0; if (d < 0) d = -d;
                    float wt = swA[k] * colorLUT[d];
                    sum += (float)v * wt;
                    wsum += wt;
                }
                int32_t out = (int32_t)lrintf(sum / wsum);
                dRow[x] = (uint8_t)(out < 0 ? 0 : (out > 255 ? 255 : out));
            } else {
                int32_t b0 = sRow[3*x], g0 = sRow[3*x+1], r0 = sRow[3*x+2];
                float sb = 0.0f, sg = 0.0f, sr = 0.0f, wsum = 0.0f;
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
                float inv = 1.0f / wsum;
                int32_t ob = (int32_t)lrintf(sb * inv), og = (int32_t)lrintf(sg * inv), or_ = (int32_t)lrintf(sr * inv);
                dRow[3*x]   = (uint8_t)(ob < 0 ? 0 : (ob > 255 ? 255 : ob));
                dRow[3*x+1] = (uint8_t)(og < 0 ? 0 : (og > 255 ? 255 : og));
                dRow[3*x+2] = (uint8_t)(or_ < 0 ? 0 : (or_ > 255 ? 255 : or_));
            }
        }
    }
    free(dxA); free(dyA); free(swA);
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
