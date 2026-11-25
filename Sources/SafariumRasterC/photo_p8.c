// SafariumRasterC — Phase 8 (`photo` + HDR helper kernels): clean C11 + Accelerate vDSP + NEON.
// ASan/UBSan-safe: no VLAs, no signed overflow, explicit bounds checks, zero third-party deps.
#include <Accelerate/Accelerate.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// Forward prototypes for @_silgen_name bindings in Swift (no shared header edits).
int32_t sr_c_inpaint(const void *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes, int32_t depth,
                     const uint8_t *mask, int32_t maskStrideBytes, void *dst, int32_t dstStrideBytes,
                     double radius, int32_t flags);
int32_t sr_c_nlm(const void *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes, int32_t depth,
                 void *dst, int32_t dstStrideBytes, const float *hArr, int32_t hCount,
                 int32_t templateWindowSize, int32_t searchWindowSize, int32_t normType);
int32_t sr_c_nlm_multi(const void *const *srcs, const int32_t *srcStrides, int32_t nFrames, int32_t targetIdx,
                       int32_t w, int32_t h, int32_t ch, int32_t depth,
                       void *dst, int32_t dstStrideBytes, const float *hArr, int32_t hCount,
                       int32_t templateWindowSize, int32_t searchWindowSize, int32_t normType);
int32_t sr_c_denoise_tvl1(const uint8_t *const *obs, const int32_t *obsStrides, int32_t nObs,
                          int32_t w, int32_t h, uint8_t *dst, int32_t dstStrideBytes,
                          double lambdaVal, int32_t niters);
int32_t sr_c_poisson_solve_f64(double *rhsAndOut, int32_t w, int32_t h);
int32_t sr_c_neumann_poisson_f64(double *rhsAndOut, int32_t w, int32_t h);
int32_t sr_c_npr_filter_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                           uint8_t *dst1, int32_t dst1Stride, uint8_t *dst2, int32_t dst2Stride,
                           int32_t mode, int32_t flags, float sigmaS, float sigmaR, float shadeFactor);
int32_t sr_c_decolor_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                        uint8_t *gray, int32_t grayStride, uint8_t *boost, int32_t boostStride);
int32_t sr_c_demosaic(const void *src, int32_t w, int32_t h, int32_t srcStrideBytes, int32_t depth,
                      void *dst, int32_t dstStrideBytes, int32_t dstCh, int32_t pattern, int32_t algo);
int32_t sr_c_dgels(int32_t m, int32_t n, double *aColMajor, double *bVec);

// MARK: - Small helpers

static inline int32_t clamp_i32(int32_t v, int32_t lo, int32_t hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline float clamp_f32(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline double clamp_f64(double v, double lo, double hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static inline int32_t reflect101(int32_t p, int32_t len) {
    if (len <= 1) return 0;
    while (p < 0 || p >= len) {
        if (p < 0) p = -p;
        else p = 2 * len - 2 - p;
    }
    return p;
}

static inline uint8_t sat_u8_d(double v) {
    long r = lrint(v);
    return (uint8_t)(r < 0 ? 0 : (r > 255 ? 255 : r));
}

static inline uint16_t sat_u16_d(double v) {
    long r = lrint(v);
    return (uint16_t)(r < 0 ? 0 : (r > 65535 ? 65535 : r));
}

// ============================================================================
// 1. INPAINTING (Telea 2004 FMM & Bertalmio/Navier-Stokes FMM)
// ============================================================================

enum { INP_KNOWN = 0, INP_BAND = 1, INP_INSIDE = 2 };

typedef struct {
    int32_t *heap;
    int32_t *pos;
    float *t;
    int32_t size;
} InpHeap;

static inline void inp_swap(InpHeap *h, int32_t i, int32_t j) {
    int32_t ni = h->heap[i], nj = h->heap[j];
    h->heap[i] = nj;
    h->heap[j] = ni;
    h->pos[nj] = i;
    h->pos[ni] = j;
}

static void inp_sift_up(InpHeap *h, int32_t i) {
    while (i > 0) {
        int32_t p = (i - 1) >> 1;
        if (h->t[h->heap[p]] <= h->t[h->heap[i]]) break;
        inp_swap(h, i, p);
        i = p;
    }
}

static void inp_sift_down(InpHeap *h, int32_t i) {
    for (;;) {
        int32_t l = (i << 1) + 1;
        if (l >= h->size) break;
        int32_t r = l + 1;
        int32_t best = (r < h->size && h->t[h->heap[r]] < h->t[h->heap[l]]) ? r : l;
        if (h->t[h->heap[i]] <= h->t[h->heap[best]]) break;
        inp_swap(h, i, best);
        i = best;
    }
}

static void inp_push_or_update(InpHeap *h, int32_t node, float val) {
    if (val >= h->t[node] && h->pos[node] >= 0) return;
    h->t[node] = val;
    int32_t p = h->pos[node];
    if (p < 0) {
        p = h->size++;
        h->heap[p] = node;
        h->pos[node] = p;
    }
    inp_sift_up(h, p);
}

static int32_t inp_pop(InpHeap *h) {
    int32_t top = h->heap[0];
    h->pos[top] = -1;
    h->size--;
    if (h->size > 0) {
        int32_t last = h->heap[h->size];
        h->heap[0] = last;
        h->pos[last] = 0;
        inp_sift_down(h, 0);
    }
    return top;
}

static inline float solve_eikonal_pair(float t1, int32_t k1, float t2, int32_t k2) {
    if (k1 == INP_KNOWN && k2 == INP_KNOWN) {
        float d = t1 - t2;
        float disc = 2.0f - d * d;
        if (disc > 0.0f) {
            float s = 0.5f * (t1 + t2 + sqrtf(disc));
            if (s > t1 && s > t2) return s;
        }
        return (t1 < t2 ? t1 : t2) + 1.0f;
    }
    if (k1 == INP_KNOWN) return t1 + 1.0f;
    if (k2 == INP_KNOWN) return t2 + 1.0f;
    return 1e6f;
}

static inline float eikonal_update(const float *t, const uint8_t *f, int32_t idx, int32_t bw) {
    float a = solve_eikonal_pair(t[idx - bw], f[idx - bw], t[idx - 1], f[idx - 1]);
    float b = solve_eikonal_pair(t[idx + bw], f[idx + bw], t[idx - 1], f[idx - 1]);
    float c = solve_eikonal_pair(t[idx - bw], f[idx - bw], t[idx + 1], f[idx + 1]);
    float d = solve_eikonal_pair(t[idx + bw], f[idx + bw], t[idx + 1], f[idx + 1]);
    float m1 = a < b ? a : b;
    float m2 = c < d ? c : d;
    return m1 < m2 ? m1 : m2;
}

static void inpaint_grad_t(const float *t, const uint8_t *f, int32_t x, int32_t y, int32_t bw,
                           float *gx, float *gy) {
    int32_t idx = y * bw + x;
    float dx = 0.0f, dy = 0.0f;
    if (f[idx + 1] != INP_INSIDE && f[idx - 1] != INP_INSIDE) {
        dx = 0.5f * (t[idx + 1] - t[idx - 1]);
    } else if (f[idx + 1] != INP_INSIDE) {
        dx = t[idx + 1] - t[idx];
    } else if (f[idx - 1] != INP_INSIDE) {
        dx = t[idx] - t[idx - 1];
    }
    if (f[idx + bw] != INP_INSIDE && f[idx - bw] != INP_INSIDE) {
        dy = 0.5f * (t[idx + bw] - t[idx - bw]);
    } else if (f[idx + bw] != INP_INSIDE) {
        dy = t[idx + bw] - t[idx];
    } else if (f[idx - bw] != INP_INSIDE) {
        dy = t[idx] - t[idx - bw];
    }
    *gx = dx;
    *gy = dy;
}

static void inpaint_telea_point(float *img, const float *t, const uint8_t *f,
                                int32_t x, int32_t y, int32_t bw, int32_t bh, int32_t ch, int32_t r) {
    float gtx = 0.0f, gty = 0.0f;
    inpaint_grad_t(t, f, x, y, bw, &gtx, &gty);
    int32_t idx = y * bw + x;
    float tc = t[idx];
    int32_t r2 = r * r;
    int32_t y0 = clamp_i32(y - r, 1, bh - 2);
    int32_t y1 = clamp_i32(y + r, 1, bh - 2);
    int32_t x0 = clamp_i32(x - r, 1, bw - 2);
    int32_t x1 = clamp_i32(x + r, 1, bw - 2);

    double ia[4] = {0, 0, 0, 0}, jx[4] = {0, 0, 0, 0}, jy[4] = {0, 0, 0, 0};
    double s = 1e-20;

    for (int32_t ny = y0; ny <= y1; ny++) {
        int32_t dy = y - ny;
        for (int32_t nx = x0; nx <= x1; nx++) {
            int32_t dx = x - nx;
            int32_t d2 = dx * dx + dy * dy;
            if (d2 == 0 || d2 > r2) continue;
            int32_t nidx = ny * bw + nx;
            if (f[nidx] != INP_KNOWN) continue;

            double dist = sqrt((double)d2);
            double dir = fabs((double)dx * (double)gtx + (double)dy * (double)gty) / dist;
            if (dir < 1e-6) dir = 1e-6;
            double lev = 1.0 / (1.0 + fabs((double)t[nidx] - (double)tc));
            double dstW = 1.0 / ((double)d2 * dist);
            double w = dir * dstW * lev;

            int32_t okX = (f[nidx + 1] == INP_KNOWN && f[nidx - 1] == INP_KNOWN);
            int32_t okY = (f[nidx + bw] == INP_KNOWN && f[nidx - bw] == INP_KNOWN);
            for (int32_t c = 0; c < ch; c++) {
                float *p = img + (size_t)nidx * (size_t)ch + c;
                ia[c] += w * (double)(*p);
                if (okX) jx[c] -= w * (double)(p[ch] - p[-ch]) * 0.5;
                if (okY) jy[c] -= w * (double)(p[bw * ch] - p[-bw * ch]) * 0.5;
            }
            s += w;
        }
    }
    for (int32_t c = 0; c < ch; c++) {
        double gradTerm = (jx[c] * 1.0 + jy[c] * 1.0);
        // Telea gradient projection normalized by gradient weight norm
        double jn = sqrt(jx[c] * jx[c] + jy[c] * jy[c]);
        double val = ia[c] / s;
        if (jn > 1e-12) {
            // Directional step of size ~0.5 along gradI
            (void)gradTerm;
            val += (jx[c] + jy[c]) / s * 0.5;
        }
        img[(size_t)idx * (size_t)ch + c] = (float)val;
    }
}

static void inpaint_telea_point_v2(float *img, const float *t, const uint8_t *f,
                                   int32_t x, int32_t y, int32_t bw, int32_t bh, int32_t ch, int32_t r) {
    float gtx = 0.0f, gty = 0.0f;
    inpaint_grad_t(t, f, x, y, bw, &gtx, &gty);
    int32_t idx = y * bw + x;
    float tc = t[idx];
    int32_t r2 = r * r;
    int32_t y0 = clamp_i32(y - r, 1, bh - 2);
    int32_t y1 = clamp_i32(y + r, 1, bh - 2);
    int32_t x0 = clamp_i32(x - r, 1, bw - 2);
    int32_t x1 = clamp_i32(x + r, 1, bw - 2);

    double ia[4] = {0, 0, 0, 0}, ja[4] = {0, 0, 0, 0};
    double s = 1e-20;

    for (int32_t ny = y0; ny <= y1; ny++) {
        int32_t dy = y - ny;
        for (int32_t nx = x0; nx <= x1; nx++) {
            int32_t dx = x - nx;
            int32_t d2 = dx * dx + dy * dy;
            if (d2 == 0 || d2 > r2) continue;
            int32_t nidx = ny * bw + nx;
            if (f[nidx] != INP_KNOWN) continue;

            double dist = sqrt((double)d2);
            double dir = fabs((double)dx * (double)gtx + (double)dy * (double)gty) / dist;
            if (dir < 1e-6) dir = 1e-6;
            double lev = 1.0 / (1.0 + fabs((double)t[nidx] - (double)tc));
            double dstW = 1.0 / ((double)d2 * dist);
            double w = dir * dstW * lev;

            int32_t okX = (f[nidx + 1] == INP_KNOWN && f[nidx - 1] == INP_KNOWN);
            int32_t okY = (f[nidx + bw] == INP_KNOWN && f[nidx - bw] == INP_KNOWN);
            for (int32_t c = 0; c < ch; c++) {
                const float *p = img + (size_t)nidx * (size_t)ch + c;
                double gx = okX ? 0.5 * ((double)p[ch] - (double)p[-ch]) : 0.0;
                double gy = okY ? 0.5 * ((double)p[bw * ch] - (double)p[-bw * ch]) : 0.0;
                ia[c] += w * (double)(*p);
                ja[c] += w * (gx * (double)dx + gy * (double)dy);
            }
            s += w;
        }
    }
    for (int32_t c = 0; c < ch; c++) {
        img[(size_t)idx * (size_t)ch + c] = (float)((ia[c] + ja[c]) / s);
    }
}

static void inpaint_ns_point(float *img, const float *t, const uint8_t *f,
                             int32_t x, int32_t y, int32_t bw, int32_t bh, int32_t ch, int32_t r) {
    float gtx = 0.0f, gty = 0.0f;
    inpaint_grad_t(t, f, x, y, bw, &gtx, &gty);
    int32_t idx = y * bw + x;
    float tc = t[idx];
    int32_t r2 = r * r;
    int32_t y0 = clamp_i32(y - r, 1, bh - 2);
    int32_t y1 = clamp_i32(y + r, 1, bh - 2);
    int32_t x0 = clamp_i32(x - r, 1, bw - 2);
    int32_t x1 = clamp_i32(x + r, 1, bw - 2);

    double ia[4] = {0, 0, 0, 0};
    double s = 1e-20;

    for (int32_t ny = y0; ny <= y1; ny++) {
        int32_t dy = y - ny;
        for (int32_t nx = x0; nx <= x1; nx++) {
            int32_t dx = x - nx;
            int32_t d2 = dx * dx + dy * dy;
            if (d2 == 0 || d2 > r2) continue;
            int32_t nidx = ny * bw + nx;
            if (f[nidx] != INP_KNOWN) continue;

            double dist = sqrt((double)d2);
            double dir = fabs((double)dx * (double)gtx + (double)dy * (double)gty) / dist;
            if (dir < 1e-6) dir = 1e-6;
            double lev = 1.0 / (1.0 + fabs((double)t[nidx] - (double)tc));
            double dstW = 1.0 / ((double)d2 * dist);
            double w = dir * dstW * lev;

            // Navier-Stokes isophote smoothness: solve local Laplacian continuity along perpendicular to gradI
            int32_t okX = (f[nidx + 1] == INP_KNOWN && f[nidx - 1] == INP_KNOWN);
            int32_t okY = (f[nidx + bw] == INP_KNOWN && f[nidx - bw] == INP_KNOWN);
            int32_t okLap = okX && okY;
            for (int32_t c = 0; c < ch; c++) {
                const float *p = img + (size_t)nidx * (size_t)ch + c;
                double val = (double)(*p);
                if (okLap) {
                    double gx = 0.5 * ((double)p[ch] - (double)p[-ch]);
                    double gy = 0.5 * ((double)p[bw * ch] - (double)p[-bw * ch]);
                    double gnorm = hypot(gx, gy);
                    if (gnorm > 1e-6) {
                        // Isophote direction (-gy, gx) alignment
                        double iso = fabs((double)dx * (-gy) + (double)dy * gx) / (dist * gnorm);
                        double lap = 0.25 * ((double)p[ch] + (double)p[-ch] + (double)p[bw * ch] + (double)p[-bw * ch]) - val;
                        double pred = val + (gx * (double)dx + gy * (double)dy) * 0.5 + iso * lap * 0.25;
                        val = pred;
                    }
                }
                ia[c] += w * val;
            }
            s += w;
        }
    }
    for (int32_t c = 0; c < ch; c++) {
        img[(size_t)idx * (size_t)ch + c] = (float)(ia[c] / s);
    }
}

int32_t sr_c_inpaint(const void *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes, int32_t depth,
                     const uint8_t *mask, int32_t maskStrideBytes, void *dst, int32_t dstStrideBytes,
                     double radius, int32_t flags) {
    if (!src || !mask || !dst || w <= 0 || h <= 0 || (ch != 1 && ch != 3)) return -1;
    if (depth != 0 && depth != 2 && depth != 5) return -1;
    if (flags != 0 && flags != 1) return -1;

    (void)inpaint_telea_point;
    int32_t rad = (int32_t)lround(radius);
    if (rad < 1) rad = 1;

    int32_t bw = w + 2, bh = h + 2;
    size_t nPad = (size_t)bw * (size_t)bh;
    float *img = (float *)calloc(nPad * (size_t)ch, sizeof(float));
    float *t = (float *)malloc(nPad * sizeof(float));
    uint8_t *f = (uint8_t *)malloc(nPad);
    uint8_t *origMask = (uint8_t *)calloc(nPad, 1);
    int32_t *heapBuf = (int32_t *)malloc(nPad * sizeof(int32_t));
    int32_t *posBuf = (int32_t *)malloc(nPad * sizeof(int32_t));
    int32_t *order = (int32_t *)malloc(nPad * sizeof(int32_t));
    if (!img || !t || !f || !origMask || !heapBuf || !posBuf || !order) {
        free(img); free(t); free(f); free(origMask); free(heapBuf); free(posBuf); free(order);
        return -1;
    }

    for (size_t i = 0; i < nPad; i++) {
        t[i] = 1e6f;
        f[i] = INP_KNOWN;
        posBuf[i] = -1;
    }

    float maxRange = (depth == 0) ? 255.0f : ((depth == 2) ? 65535.0f : 1e30f);
    int32_t maskCount = 0;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *sr = (const uint8_t *)src + (size_t)y * (size_t)srcStrideBytes;
        const uint8_t *mr = mask + (size_t)y * (size_t)maskStrideBytes;
        for (int32_t x = 0; x < w; x++) {
            size_t idx = (size_t)(y + 1) * (size_t)bw + (size_t)(x + 1);
            for (int32_t c = 0; c < ch; c++) {
                float v = 0.0f;
                if (depth == 0) v = (float)sr[x * ch + c];
                else if (depth == 2) v = (float)((const uint16_t *)sr)[x * ch + c];
                else v = ((const float *)sr)[x * ch + c];
                img[idx * (size_t)ch + c] = v;
            }
            if (mr[x] != 0) {
                f[idx] = INP_INSIDE;
                origMask[idx] = 1;
                maskCount++;
            } else {
                t[idx] = 0.0f;
            }
        }
    }

    if (maskCount == 0) {
        // Nothing to inpaint: copy src -> dst directly.
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *sr = (const uint8_t *)src + (size_t)y * (size_t)srcStrideBytes;
            uint8_t *dr = (uint8_t *)dst + (size_t)y * (size_t)dstStrideBytes;
            size_t rowBytes = (size_t)w * (size_t)ch * (depth == 0 ? 1u : (depth == 2 ? 2u : 4u));
            memcpy(dr, sr, rowBytes);
        }
        free(img); free(t); free(f); free(origMask); free(heapBuf); free(posBuf); free(order);
        return 0;
    }

    // Replicate interior edges into 1-pixel border for clean gradient computations
    for (int32_t x = 1; x <= w; x++) {
        for (int32_t c = 0; c < ch; c++) {
            img[(size_t)x * ch + c] = img[((size_t)bw + x) * ch + c];
            img[((size_t)(bh - 1) * bw + x) * ch + c] = img[((size_t)h * bw + x) * ch + c];
        }
        t[x] = 0.0f;
        t[(size_t)(bh - 1) * bw + x] = 0.0f;
    }
    for (int32_t y = 0; y < bh; y++) {
        for (int32_t c = 0; c < ch; c++) {
            img[(size_t)y * bw * ch + c] = img[((size_t)y * bw + 1) * ch + c];
            img[((size_t)y * bw + (bw - 1)) * ch + c] = img[((size_t)y * bw + w) * ch + c];
        }
        t[(size_t)y * bw] = 0.0f;
        t[(size_t)y * bw + (bw - 1)] = 0.0f;
    }

    // Seed narrowband: INSIDE pixels 4-adjacent to KNOWN pixels
    InpHeap hp = {heapBuf, posBuf, t, 0};
    const int32_t nb4[4] = {-1, 1, -bw, bw};
    for (int32_t y = 1; y <= h; y++) {
        for (int32_t x = 1; x <= w; x++) {
            int32_t idx = y * bw + x;
            if (f[idx] != INP_INSIDE) continue;
            int nearKnown = 0;
            for (int k = 0; k < 4; k++) {
                int32_t nidx = idx + nb4[k];
                int32_t nx = nidx % bw, ny = nidx / bw;
                if (nx >= 1 && nx <= w && ny >= 1 && ny <= h && f[nidx] == INP_KNOWN) {
                    nearKnown = 1;
                    break;
                }
            }
            if (nearKnown) {
                f[idx] = INP_BAND;
                float tv = eikonal_update(t, f, idx, bw);
                inp_push_or_update(&hp, idx, tv);
            }
        }
    }

    int32_t nOrder = 0;
    while (hp.size > 0) {
        int32_t idx = inp_pop(&hp);
        int32_t x = idx % bw, y = idx / bw;
        f[idx] = INP_KNOWN;
        order[nOrder++] = idx;

        if (flags == 1) {
            inpaint_telea_point_v2(img, t, f, x, y, bw, bh, ch, rad);
        } else {
            inpaint_ns_point(img, t, f, x, y, bw, bh, ch, rad);
        }
        if (depth != 5) {
            for (int32_t c = 0; c < ch; c++) {
                float v = img[(size_t)idx * ch + c];
                img[(size_t)idx * ch + c] = clamp_f32(v, 0.0f, maxRange);
            }
        }

        for (int k = 0; k < 4; k++) {
            int32_t nidx = idx + nb4[k];
            int32_t nx = nidx % bw, ny = nidx / bw;
            if (nx < 1 || nx > w || ny < 1 || ny > h) continue;
            if (f[nidx] != INP_KNOWN) {
                if (f[nidx] == INP_INSIDE) f[nidx] = INP_BAND;
                float tv = eikonal_update(t, f, nidx, bw);
                inp_push_or_update(&hp, nidx, tv);
            }
        }
    }

    // For INPAINT_NS, refine inside the mask with anisotropic Laplacian-vorticity relaxation
    if (flags == 0 && nOrder > 0) {
        int32_t nSmooth = clamp_i32(rad * 2, 4, 16);
        float *tmp = (float *)malloc((size_t)nOrder * (size_t)ch * sizeof(float));
        if (tmp) {
            for (int32_t it = 0; it < nSmooth; it++) {
                for (int32_t i = 0; i < nOrder; i++) {
                    int32_t idx = order[i];
                    int32_t x = idx % bw, y = idx / bw;
                    for (int32_t c = 0; c < ch; c++) {
                        const float *p = img + (size_t)idx * ch + c;
                        double val = (double)(*p);
                        if (x >= 1 && x <= w && y >= 1 && y <= h) {
                            double gx = 0.5 * ((double)p[ch] - (double)p[-ch]);
                            double gy = 0.5 * ((double)p[bw * ch] - (double)p[-bw * ch]);
                            double nrm = hypot(gx, gy) + 1e-6;
                            // Diffuse primarily along isophote tangent (-gy, gx)/nrm while preserving edges
                            double tx = -gy / nrm, ty = gx / nrm;
                            double dxx = (double)p[ch] - 2.0 * val + (double)p[-ch];
                            double dyy = (double)p[bw * ch] - 2.0 * val + (double)p[-bw * ch];
                            double dxy = 0.25 * ((double)p[(bw + 1) * ch] - (double)p[(bw - 1) * ch]
                                               - (double)p[(-bw + 1) * ch] + (double)p[(-bw - 1) * ch]);
                            double dirLap = tx * tx * dxx + 2.0 * tx * ty * dxy + ty * ty * dyy;
                            double isoLap = 0.25 * ((double)p[ch] + (double)p[-ch] + (double)p[bw * ch] + (double)p[-bw * ch]) - val;
                            val += 0.2 * dirLap + 0.1 * isoLap;
                        }
                        if (depth != 5) val = clamp_f64(val, 0.0, (double)maxRange);
                        tmp[(size_t)i * ch + c] = (float)val;
                    }
                }
                for (int32_t i = 0; i < nOrder; i++) {
                    int32_t idx = order[i];
                    for (int32_t c = 0; c < ch; c++) {
                        img[(size_t)idx * ch + c] = tmp[(size_t)i * ch + c];
                    }
                }
            }
            free(tmp);
        }
    }

    for (int32_t y = 0; y < h; y++) {
        uint8_t *dr = (uint8_t *)dst + (size_t)y * (size_t)dstStrideBytes;
        for (int32_t x = 0; x < w; x++) {
            size_t idx = (size_t)(y + 1) * (size_t)bw + (size_t)(x + 1);
            for (int32_t c = 0; c < ch; c++) {
                float v = img[idx * (size_t)ch + c];
                if (depth == 0) dr[x * ch + c] = sat_u8_d((double)v);
                else if (depth == 2) ((uint16_t *)dr)[x * ch + c] = sat_u16_d((double)v);
                else ((float *)dr)[x * ch + c] = v;
            }
        }
    }

    free(img); free(t); free(f); free(origMask); free(heapBuf); free(posBuf); free(order);
    return 0;
}

// ============================================================================
// 2. NON-LOCAL MEANS DENOISING (Integral Patch SAD/SSD + LUT + NEON)
// ============================================================================

#define NLM_EXP_SIZE 4096
#define NLM_EXP_MAX 12.0f

static void build_exp_lut(float *lut) {
    for (int i = 0; i <= NLM_EXP_SIZE; i++) {
        float x = (float)i * (NLM_EXP_MAX / (float)NLM_EXP_SIZE);
        lut[i] = expf(-x);
    }
}

static inline float lookup_exp(const float *lut, float x) {
    if (x <= 0.0f) return 1.0f;
    if (x >= NLM_EXP_MAX) return 0.0f;
    float pos = x * ((float)NLM_EXP_SIZE / NLM_EXP_MAX);
    int idx = (int)pos;
    if (idx >= NLM_EXP_SIZE) return lut[NLM_EXP_SIZE];
    float frac = pos - (float)idx;
    return lut[idx] + frac * (lut[idx + 1] - lut[idx]);
}

// Compute per-pixel difference row between padded image rows `p1` and `p2`
static void nlm_row_diff_u8(const uint8_t *p1, const uint8_t *p2, int32_t len, int32_t ch,
                            int32_t normType, const float *invH, float *outDiff) {
    if (normType == 4) { // NORM_L2
        if (ch == 1) {
            float ih = invH[0];
            int32_t i = 0;
#ifdef __ARM_NEON
            float32x4_t vih = vdupq_n_f32(ih);
            for (; i + 8 <= len; i += 8) {
                uint8x8_t a = vld1_u8(p1 + i);
                uint8x8_t b = vld1_u8(p2 + i);
                uint16x8_t d = vabdl_u8(a, b);
                uint32x4_t d0 = vmovl_u16(vget_low_u16(d));
                uint32x4_t d1 = vmovl_u16(vget_high_u16(d));
                float32x4_t f0 = vcvtq_f32_u32(d0);
                float32x4_t f1 = vcvtq_f32_u32(d1);
                vst1q_f32(outDiff + i, vmulq_f32(vmulq_f32(f0, f0), vih));
                vst1q_f32(outDiff + i + 4, vmulq_f32(vmulq_f32(f1, f1), vih));
            }
#endif
            for (; i < len; i++) {
                float d = (float)p1[i] - (float)p2[i];
                outDiff[i] = d * d * ih;
            }
        } else {
            for (int32_t i = 0; i < len; i++) {
                double acc = 0.0;
                for (int32_t c = 0; c < ch; c++) {
                    float d = (float)p1[i * ch + c] - (float)p2[i * ch + c];
                    acc += (double)(d * d * invH[c]);
                }
                outDiff[i] = (float)acc;
            }
        }
    } else { // NORM_L1: accumulate sum(|a-b| * invH[c]) (later squared per OpenCV NORM_L1)
        if (ch == 1) {
            float ih = invH[0];
            int32_t i = 0;
#ifdef __ARM_NEON
            float32x4_t vih = vdupq_n_f32(ih);
            for (; i + 8 <= len; i += 8) {
                uint8x8_t a = vld1_u8(p1 + i);
                uint8x8_t b = vld1_u8(p2 + i);
                uint16x8_t d = vabdl_u8(a, b);
                float32x4_t f0 = vcvtq_f32_u32(vmovl_u16(vget_low_u16(d)));
                float32x4_t f1 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(d)));
                vst1q_f32(outDiff + i, vmulq_f32(f0, vih));
                vst1q_f32(outDiff + i + 4, vmulq_f32(f1, vih));
            }
#endif
            for (; i < len; i++) {
                float d = fabsf((float)p1[i] - (float)p2[i]);
                outDiff[i] = d * ih;
            }
        } else {
            for (int32_t i = 0; i < len; i++) {
                double acc = 0.0;
                for (int32_t c = 0; c < ch; c++) {
                    float d = fabsf((float)p1[i * ch + c] - (float)p2[i * ch + c]);
                    acc += (double)(d * invH[c]);
                }
                outDiff[i] = (float)acc;
            }
        }
    }
}

static void nlm_row_diff_u16(const uint16_t *p1, const uint16_t *p2, int32_t len, int32_t ch,
                             int32_t normType, const float *invH, float *outDiff) {
    if (normType == 4) {
        for (int32_t i = 0; i < len; i++) {
            double acc = 0.0;
            for (int32_t c = 0; c < ch; c++) {
                double d = (double)p1[i * ch + c] - (double)p2[i * ch + c];
                acc += d * d * (double)invH[c];
            }
            outDiff[i] = (float)acc;
        }
    } else {
        for (int32_t i = 0; i < len; i++) {
            double acc = 0.0;
            for (int32_t c = 0; c < ch; c++) {
                double d = fabs((double)p1[i * ch + c] - (double)p2[i * ch + c]);
                acc += d * (double)invH[c];
            }
            outDiff[i] = (float)acc;
        }
    }
}

int32_t sr_c_nlm_multi(const void *const *srcs, const int32_t *srcStrides, int32_t nFrames, int32_t targetIdx,
                       int32_t w, int32_t h, int32_t ch, int32_t depth,
                       void *dst, int32_t dstStrideBytes, const float *hArr, int32_t hCount,
                       int32_t templateWindowSize, int32_t searchWindowSize, int32_t normType) {
    if (!srcs || !srcStrides || !dst || !hArr || nFrames <= 0 || targetIdx < 0 || targetIdx >= nFrames) return -1;
    if (w <= 0 || h <= 0 || ch < 1 || ch > 4) return -1;
    if (depth != 0 && depth != 2) return -1;
    if (depth == 2 && normType != 2) return -1;
    if (normType != 2 && normType != 4) return -1;
    if (templateWindowSize < 1 || (templateWindowSize & 1) == 0) return -1;
    if (searchWindowSize < 1 || (searchWindowSize & 1) == 0) return -1;
    if (hCount != 1 && hCount != ch) return -1;

    int32_t tr = templateWindowSize >> 1;
    int32_t sr = searchWindowSize >> 1;
    int32_t pad = tr + sr;
    int32_t pw = w + 2 * pad;
    int32_t ph = h + 2 * pad;
    int32_t bw = w + 2 * tr; // active region for template box filter: [sr .. sr + bw)
    int32_t bh = h + 2 * tr;

    size_t elemSize = (depth == 0) ? 1u : 2u;
    size_t frameElems = (size_t)pw * (size_t)ph * (size_t)ch;
    uint8_t *padded = (uint8_t *)malloc((size_t)nFrames * frameElems * elemSize);
    size_t npix = (size_t)w * (size_t)h;
    float *wSum = (float *)calloc(npix, sizeof(float));
    float *vSum = (float *)calloc(npix * (size_t)ch, sizeof(float));
    float *rowDiff = (float *)malloc((size_t)bw * sizeof(float));
    float *ringH = (float *)calloc((size_t)templateWindowSize * (size_t)w, sizeof(float));
    float *colSum = (float *)calloc((size_t)w, sizeof(float));
    if (!padded || !wSum || !vSum || !rowDiff || !ringH || !colSum) {
        free(padded); free(wSum); free(vSum); free(rowDiff); free(ringH); free(colSum);
        return -1;
    }

    float expLut[NLM_EXP_SIZE + 1];
    build_exp_lut(expLut);

    // Pad all frames with BORDER_REFLECT_101
    for (int32_t f = 0; f < nFrames; f++) {
        const uint8_t *sBase = (const uint8_t *)srcs[f];
        int32_t ss = srcStrides[f];
        uint8_t *pBase = padded + (size_t)f * frameElems * elemSize;
        for (int32_t py = 0; py < ph; py++) {
            int32_t sy = reflect101(py - pad, h);
            const uint8_t *sRow = sBase + (size_t)sy * (size_t)ss;
            uint8_t *pRow = pBase + (size_t)py * (size_t)pw * (size_t)ch * elemSize;
            for (int32_t px = 0; px < pw; px++) {
                int32_t sx = reflect101(px - pad, w);
                if (depth == 0) {
                    for (int32_t c = 0; c < ch; c++) pRow[px * ch + c] = sRow[sx * ch + c];
                } else {
                    const uint16_t *s16 = (const uint16_t *)sRow;
                    uint16_t *p16 = (uint16_t *)pRow;
                    for (int32_t c = 0; c < ch; c++) p16[px * ch + c] = s16[sx * ch + c];
                }
            }
        }
    }

    float tArea = (float)(templateWindowSize * templateWindowSize);
    float invH[4] = {0, 0, 0, 0};
    int zeroH = 0;
    for (int32_t c = 0; c < ch; c++) {
        float hv = hArr[hCount == 1 ? 0 : c];
        if (hv <= 1e-6f) {
            zeroH = 1;
            invH[c] = 1e6f;
        } else if (normType == 4) {
            invH[c] = 1.0f / (hv * hv * tArea * (float)ch);
        } else {
            invH[c] = 1.0f / (hv * tArea);
        }
    }

    const uint8_t *tgtBase = padded + (size_t)targetIdx * frameElems * elemSize;

    // Initialize accumulators with center sample weight = 1.0 (handles h == 0 and ensures non-zero denominator)
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *tRow = tgtBase + ((size_t)(y + pad) * (size_t)pw + (size_t)pad) * (size_t)ch * elemSize;
        for (int32_t x = 0; x < w; x++) {
            size_t pidx = (size_t)y * (size_t)w + (size_t)x;
            wSum[pidx] = 1.0f;
            if (depth == 0) {
                for (int32_t c = 0; c < ch; c++) vSum[pidx * (size_t)ch + c] = (float)tRow[x * ch + c];
            } else {
                const uint16_t *t16 = (const uint16_t *)tRow;
                for (int32_t c = 0; c < ch; c++) vSum[pidx * (size_t)ch + c] = (float)t16[x * ch + c];
            }
        }
    }

    if (!zeroH) {
        for (int32_t f = 0; f < nFrames; f++) {
            const uint8_t *candBase = padded + (size_t)f * frameElems * elemSize;
            for (int32_t dy = -sr; dy <= sr; dy++) {
                for (int32_t dx = -sr; dx <= sr; dx++) {
                    if (f == targetIdx && dx == 0 && dy == 0) continue;

                    memset(colSum, 0, (size_t)w * sizeof(float));
                    for (int32_t by = 0; by < bh; by++) {
                        int32_t py1 = sr + by;
                        int32_t py2 = py1 + dy;
                        int32_t px1 = sr;
                        int32_t px2 = sr + dx;

                        if (depth == 0) {
                            const uint8_t *r1 = tgtBase + ((size_t)py1 * (size_t)pw + (size_t)px1) * (size_t)ch;
                            const uint8_t *r2 = candBase + ((size_t)py2 * (size_t)pw + (size_t)px2) * (size_t)ch;
                            nlm_row_diff_u8(r1, r2, bw, ch, normType, invH, rowDiff);
                        } else {
                            const uint16_t *r1 = (const uint16_t *)tgtBase + ((size_t)py1 * (size_t)pw + (size_t)px1) * (size_t)ch;
                            const uint16_t *r2 = (const uint16_t *)candBase + ((size_t)py2 * (size_t)pw + (size_t)px2) * (size_t)ch;
                            nlm_row_diff_u16(r1, r2, bw, ch, normType, invH, rowDiff);
                        }

                        // Horizontal sliding sum of width templateWindowSize
                        int32_t slot = by % templateWindowSize;
                        float *hOut = ringH + (size_t)slot * (size_t)w;
                        double acc = 0.0;
                        for (int32_t k = 0; k < templateWindowSize; k++) acc += (double)rowDiff[k];
                        float prev = hOut[0];
                        hOut[0] = (float)acc;
                        if (by >= templateWindowSize) colSum[0] += hOut[0] - prev;
                        else colSum[0] += hOut[0];

                        for (int32_t x = 1; x < w; x++) {
                            acc += (double)rowDiff[x + templateWindowSize - 1] - (double)rowDiff[x - 1];
                            float oldV = hOut[x];
                            float newV = (float)acc;
                            hOut[x] = newV;
                            if (by >= templateWindowSize) colSum[x] += newV - oldV;
                            else colSum[x] += newV;
                        }

                        int32_t y = by - (templateWindowSize - 1);
                        if (y >= 0) {
                            int32_t cy = y + pad + dy;
                            int32_t cx = pad + dx;
                            size_t rowOff = (size_t)y * (size_t)w;
                            if (depth == 0) {
                                const uint8_t *cRow = candBase + ((size_t)cy * (size_t)pw + (size_t)cx) * (size_t)ch;
                                for (int32_t x = 0; x < w; x++) {
                                    float arg = colSum[x];
                                    if (normType == 2) arg = (arg * arg) / (float)ch;
                                    float weight = lookup_exp(expLut, arg);
                                    if (weight > 1e-6f) {
                                        size_t pidx = rowOff + (size_t)x;
                                        wSum[pidx] += weight;
                                        for (int32_t c = 0; c < ch; c++) {
                                            vSum[pidx * (size_t)ch + c] += weight * (float)cRow[x * ch + c];
                                        }
                                    }
                                }
                            } else {
                                const uint16_t *cRow = (const uint16_t *)candBase + ((size_t)cy * (size_t)pw + (size_t)cx) * (size_t)ch;
                                for (int32_t x = 0; x < w; x++) {
                                    float arg = colSum[x];
                                    arg = (arg * arg) / (float)ch; // NORM_L1
                                    float weight = lookup_exp(expLut, arg);
                                    if (weight > 1e-6f) {
                                        size_t pidx = rowOff + (size_t)x;
                                        wSum[pidx] += weight;
                                        for (int32_t c = 0; c < ch; c++) {
                                            vSum[pidx * (size_t)ch + c] += weight * (float)cRow[x * ch + c];
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    for (int32_t y = 0; y < h; y++) {
        uint8_t *dRow = (uint8_t *)dst + (size_t)y * (size_t)dstStrideBytes;
        for (int32_t x = 0; x < w; x++) {
            size_t pidx = (size_t)y * (size_t)w + (size_t)x;
            float invW = 1.0f / wSum[pidx];
            if (depth == 0) {
                for (int32_t c = 0; c < ch; c++) {
                    dRow[x * ch + c] = sat_u8_d((double)(vSum[pidx * (size_t)ch + c] * invW));
                }
            } else {
                uint16_t *d16 = (uint16_t *)dRow;
                for (int32_t c = 0; c < ch; c++) {
                    d16[x * ch + c] = sat_u16_d((double)(vSum[pidx * (size_t)ch + c] * invW));
                }
            }
        }
    }

    free(padded); free(wSum); free(vSum); free(rowDiff); free(ringH); free(colSum);
    return 0;
}

int32_t sr_c_nlm(const void *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes, int32_t depth,
                 void *dst, int32_t dstStrideBytes, const float *hArr, int32_t hCount,
                 int32_t templateWindowSize, int32_t searchWindowSize, int32_t normType) {
    const void *srcs[1] = {src};
    int32_t strides[1] = {srcStrideBytes};
    return sr_c_nlm_multi(srcs, strides, 1, 0, w, h, ch, depth, dst, dstStrideBytes,
                          hArr, hCount, templateWindowSize, searchWindowSize, normType);
}

// ============================================================================
// 3. TV-L1 DENOISING (Chambolle-Pock Primal-Dual matching OpenCV)
// ============================================================================

int32_t sr_c_denoise_tvl1(const uint8_t *const *obs, const int32_t *obsStrides, int32_t nObs,
                          int32_t w, int32_t h, uint8_t *dst, int32_t dstStrideBytes,
                          double lambdaVal, int32_t niters) {
    if (!obs || !obsStrides || !dst || nObs <= 0 || w <= 0 || h <= 0 || lambdaVal <= 0.0 || niters < 0) return -1;
    size_t npix = (size_t)w * (size_t)h;
    float *u = (float *)malloc(npix * sizeof(float));
    float *uBar = (float *)malloc(npix * sizeof(float));
    float *px = (float *)calloc(npix, sizeof(float));
    float *py = (float *)calloc(npix, sizeof(float));
    float *r = (float *)calloc((size_t)nObs * npix, sizeof(float));
    float *f = (float *)malloc((size_t)nObs * npix * sizeof(float));
    if (!u || !uBar || !px || !py || !r || !f) {
        free(u); free(uBar); free(px); free(py); free(r); free(f);
        return -1;
    }

    for (int32_t k = 0; k < nObs; k++) {
        const uint8_t *src = obs[k];
        int32_t ss = obsStrides[k];
        float *fk = f + (size_t)k * npix;
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *sr = src + (size_t)y * (size_t)ss;
            for (int32_t x = 0; x < w; x++) fk[(size_t)y * (size_t)w + x] = (float)sr[x];
        }
    }
    memcpy(u, f, npix * sizeof(float));
    memcpy(uBar, f, npix * sizeof(float));

    const float tau = 10.0f;
    const float sigma = 0.025f;
    const float theta = 0.0f;
    const float lam = (float)lambdaVal;

    for (int32_t it = 0; it < niters; it++) {
        // Update dual p = proj_{||.||<=1}(p + sigma * grad(uBar))
        for (int32_t y = 0; y < h; y++) {
            for (int32_t x = 0; x < w; x++) {
                size_t idx = (size_t)y * (size_t)w + x;
                float ux = (x + 1 < w) ? (uBar[idx + 1] - uBar[idx]) : 0.0f;
                float uy = (y + 1 < h) ? (uBar[idx + (size_t)w] - uBar[idx]) : 0.0f;
                float nx = px[idx] + sigma * ux;
                float ny = py[idx] + sigma * uy;
                float norm = hypotf(nx, ny);
                float scale = norm > 1.0f ? (1.0f / norm) : 1.0f;
                px[idx] = nx * scale;
                py[idx] = ny * scale;
            }
        }
        // Update dual r_k = clip(r_k + sigma * (uBar - f_k), -lambda, lambda)
        for (int32_t k = 0; k < nObs; k++) {
            float *rk = r + (size_t)k * npix;
            const float *fk = f + (size_t)k * npix;
            for (size_t i = 0; i < npix; i++) {
                float val = rk[i] + sigma * (uBar[i] - fk[i]);
                rk[i] = clamp_f32(val, -lam, lam);
            }
        }
        // Update primal u and extrapolated uBar
        for (int32_t y = 0; y < h; y++) {
            for (int32_t x = 0; x < w; x++) {
                size_t idx = (size_t)y * (size_t)w + x;
                float divx = (x > 0) ? ((x + 1 < w ? px[idx] : 0.0f) - px[idx - 1]) : 0.0f;
                float divy = (y > 0) ? ((y + 1 < h ? py[idx] : 0.0f) - py[idx - (size_t)w]) : 0.0f;
                float rsum = 0.0f;
                for (int32_t k = 0; k < nObs; k++) rsum += r[(size_t)k * npix + idx];
                float uOld = u[idx];
                float uNew = uOld + tau * (divx + divy - rsum);
                u[idx] = uNew;
                uBar[idx] = uNew + theta * (uNew - uOld);
            }
        }
    }

    for (int32_t y = 0; y < h; y++) {
        uint8_t *dr = dst + (size_t)y * (size_t)dstStrideBytes;
        for (int32_t x = 0; x < w; x++) {
            dr[x] = sat_u8_d((double)u[(size_t)y * (size_t)w + x]);
        }
    }

    free(u); free(uBar); free(px); free(py); free(r); free(f);
    return 0;
}

// ============================================================================
// 4. ACCELERATE vDSP DST-I POISSON SOLVER
// ============================================================================

static int32_t next_pow2_i32(int32_t n) {
    int32_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

static void vdsp_fft_1d(FFTSetupD setup, int32_t log2n, double *re, double *im, int32_t m, int32_t dir) {
    if (m <= 1) return;
    if ((m & (m - 1)) == 0) {
        DSPDoubleSplitComplex sc = {re, im};
        vDSP_fft_zipD(setup, &sc, 1, (vDSP_Length)log2n, (FFTDirection)dir);
        return;
    }
    // Bluestein FFT via vDSP power-of-2 convolution
    int32_t L = next_pow2_i32(2 * m - 1);
    int32_t log2L = 0;
    while ((1 << log2L) < L) log2L++;
    FFTSetupD setupL = vDSP_create_fftsetupD((vDSP_Length)log2L, kFFTRadix2);
    if (!setupL) return;

    double *ar = (double *)calloc((size_t)L, sizeof(double));
    double *ai = (double *)calloc((size_t)L, sizeof(double));
    double *br = (double *)calloc((size_t)L, sizeof(double));
    double *bi = (double *)calloc((size_t)L, sizeof(double));
    double *wr = (double *)malloc((size_t)m * sizeof(double));
    double *wi = (double *)malloc((size_t)m * sizeof(double));
    if (ar && ai && br && bi && wr && wi) {
        double sign = (dir == FFT_INVERSE) ? 1.0 : -1.0;
        int64_t twoM = 2LL * m;
        for (int32_t k = 0; k < m; k++) {
            int64_t kk = ((int64_t)k * (int64_t)k) % twoM;
            double ang = sign * M_PI * (double)kk / (double)m;
            double cw = cos(ang), sw = sin(ang);
            wr[k] = cw;
            wi[k] = sw;
            ar[k] = re[k] * cw - im[k] * sw;
            ai[k] = re[k] * sw + im[k] * cw;
        }
        br[0] = wr[0];
        bi[0] = -wi[0];
        for (int32_t k = 1; k < m; k++) {
            br[k] = wr[k]; bi[k] = -wi[k];
            br[L - k] = wr[k]; bi[L - k] = -wi[k];
        }
        DSPDoubleSplitComplex sa = {ar, ai};
        DSPDoubleSplitComplex sb = {br, bi};
        vDSP_fft_zipD(setupL, &sa, 1, (vDSP_Length)log2L, kFFTDirection_Forward);
        vDSP_fft_zipD(setupL, &sb, 1, (vDSP_Length)log2L, kFFTDirection_Forward);
        for (int32_t k = 0; k < L; k++) {
            double tr = ar[k] * br[k] - ai[k] * bi[k];
            double ti = ar[k] * bi[k] + ai[k] * br[k];
            ar[k] = tr;
            ai[k] = ti;
        }
        vDSP_fft_zipD(setupL, &sa, 1, (vDSP_Length)log2L, kFFTDirection_Inverse);
        double invL = 1.0 / (double)L;
        for (int32_t k = 0; k < m; k++) {
            double vr = ar[k] * invL, vi = ai[k] * invL;
            re[k] = vr * wr[k] - vi * wi[k];
            im[k] = vr * wi[k] + vi * wr[k];
        }
    }
    free(ar); free(ai); free(br); free(bi); free(wr); free(wi);
    vDSP_destroy_fftsetupD(setupL);
}

// 1D DST-I on N elements (applied across M rows of stride 1, each of length N).
// DST-I is involutory up to factor 2/(N+1).
static int32_t dst1_rows(double *data, int32_t rows, int32_t n) {
    int32_t m = 2 * (n + 1);
    int32_t isPow2 = ((m & (m - 1)) == 0);
    int32_t log2m = 0;
    if (isPow2) {
        while ((1 << log2m) < m) log2m++;
    }
    FFTSetupD setup = isPow2 ? vDSP_create_fftsetupD((vDSP_Length)log2m, kFFTRadix2) : NULL;
    if (isPow2 && !setup) return -1;

    double *re = (double *)malloc((size_t)m * sizeof(double));
    double *im = (double *)malloc((size_t)m * sizeof(double));
    if (!re || !im) {
        free(re); free(im);
        if (setup) vDSP_destroy_fftsetupD(setup);
        return -1;
    }

    // For general odd/non-pow2 m, precompute Bluestein chirp once per dst1_rows call
    int32_t L = next_pow2_i32(2 * m - 1);
    int32_t log2L = 0;
    while ((1 << log2L) < L) log2L++;
    FFTSetupD setupL = isPow2 ? NULL : vDSP_create_fftsetupD((vDSP_Length)log2L, kFFTRadix2);
    double *br = NULL, *bi = NULL, *wr = NULL, *wi = NULL, *ar = NULL, *ai = NULL;
    if (!isPow2) {
        if (!setupL) { free(re); free(im); return -1; }
        ar = (double *)malloc((size_t)L * sizeof(double));
        ai = (double *)malloc((size_t)L * sizeof(double));
        br = (double *)calloc((size_t)L, sizeof(double));
        bi = (double *)calloc((size_t)L, sizeof(double));
        wr = (double *)malloc((size_t)m * sizeof(double));
        wi = (double *)malloc((size_t)m * sizeof(double));
        if (!ar || !ai || !br || !bi || !wr || !wi) {
            free(re); free(im); free(ar); free(ai); free(br); free(bi); free(wr); free(wi);
            vDSP_destroy_fftsetupD(setupL);
            return -1;
        }
        int64_t twoM = 2LL * m;
        for (int32_t k = 0; k < m; k++) {
            int64_t kk = ((int64_t)k * (int64_t)k) % twoM;
            double ang = -M_PI * (double)kk / (double)m;
            wr[k] = cos(ang);
            wi[k] = sin(ang);
        }
        br[0] = wr[0]; bi[0] = -wi[0];
        for (int32_t k = 1; k < m; k++) {
            br[k] = wr[k]; bi[k] = -wi[k];
            br[L - k] = wr[k]; bi[L - k] = -wi[k];
        }
        DSPDoubleSplitComplex sb = {br, bi};
        vDSP_fft_zipD(setupL, &sb, 1, (vDSP_Length)log2L, kFFTDirection_Forward);
    }

    (void)vdsp_fft_1d;
    for (int32_t r = 0; r < rows; r++) {
        double *row = data + (size_t)r * (size_t)n;
        re[0] = 0.0;
        re[n + 1] = 0.0;
        for (int32_t k = 0; k < n; k++) {
            double v = row[k];
            re[k + 1] = v;
            re[m - 1 - k] = -v;
        }
        memset(im, 0, (size_t)m * sizeof(double));
        if (isPow2) {
            DSPDoubleSplitComplex sc = {re, im};
            vDSP_fft_zipD(setup, &sc, 1, (vDSP_Length)log2m, kFFTDirection_Forward);
            for (int32_t k = 0; k < n; k++) row[k] = -0.5 * im[k + 1];
        } else {
            memset(ar, 0, (size_t)L * sizeof(double));
            memset(ai, 0, (size_t)L * sizeof(double));
            for (int32_t k = 0; k < m; k++) {
                ar[k] = re[k] * wr[k] - im[k] * wi[k];
                ai[k] = re[k] * wi[k] + im[k] * wr[k];
            }
            DSPDoubleSplitComplex sa = {ar, ai};
            vDSP_fft_zipD(setupL, &sa, 1, (vDSP_Length)log2L, kFFTDirection_Forward);
            for (int32_t k = 0; k < L; k++) {
                double tr = ar[k] * br[k] - ai[k] * bi[k];
                double ti = ar[k] * bi[k] + ai[k] * br[k];
                ar[k] = tr;
                ai[k] = ti;
            }
            vDSP_fft_zipD(setupL, &sa, 1, (vDSP_Length)log2L, kFFTDirection_Inverse);
            double invL = 1.0 / (double)L;
            for (int32_t k = 0; k < n; k++) {
                double vr = ar[k + 1] * invL, vi = ai[k + 1] * invL;
                double outIm = vr * wi[k + 1] + vi * wr[k + 1];
                row[k] = -0.5 * outIm;
            }
        }
    }

    free(re); free(im);
    if (setup) vDSP_destroy_fftsetupD(setup);
    if (setupL) {
        free(ar); free(ai); free(br); free(bi); free(wr); free(wi);
        vDSP_destroy_fftsetupD(setupL);
    }
    return 0;
}

int32_t sr_c_poisson_solve_f64(double *rhsAndOut, int32_t w, int32_t h) {
    if (!rhsAndOut || w <= 0 || h <= 0) return -1;
    size_t n = (size_t)w * (size_t)h;
    double *trans = (double *)malloc(n * sizeof(double));
    double *cosX = (double *)malloc((size_t)w * sizeof(double));
    double *cosY = (double *)malloc((size_t)h * sizeof(double));
    if (!trans || !cosX || !cosY) {
        free(trans); free(cosX); free(cosY);
        return -1;
    }

    if (dst1_rows(rhsAndOut, h, w) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(rhsAndOut, 1, trans, 1, (vDSP_Length)w, (vDSP_Length)h);
    if (dst1_rows(trans, w, h) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(trans, 1, rhsAndOut, 1, (vDSP_Length)h, (vDSP_Length)w);

    for (int32_t x = 0; x < w; x++) cosX[x] = 2.0 * cos(M_PI * (double)(x + 1) / (double)(w + 1));
    for (int32_t y = 0; y < h; y++) cosY[y] = 2.0 * cos(M_PI * (double)(y + 1) / (double)(h + 1));

    double norm = 4.0 / ((double)(w + 1) * (double)(h + 1));
    for (int32_t y = 0; y < h; y++) {
        double cy = cosY[y] - 4.0;
        double *row = rhsAndOut + (size_t)y * (size_t)w;
        for (int32_t x = 0; x < w; x++) {
            double denom = cy + cosX[x];
            row[x] = (fabs(denom) > 1e-14) ? (row[x] * norm / denom) : 0.0;
        }
    }

    if (dst1_rows(rhsAndOut, h, w) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(rhsAndOut, 1, trans, 1, (vDSP_Length)w, (vDSP_Length)h);
    if (dst1_rows(trans, w, h) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(trans, 1, rhsAndOut, 1, (vDSP_Length)h, (vDSP_Length)w);

    free(trans); free(cosX); free(cosY);
    return 0;
}

// 1D DCT-II (inverse == 0) / inverse DCT-III (inverse != 0) on N elements across `rows` rows.
static int32_t dct2_rows(double *data, int32_t rows, int32_t n, int32_t inverse) {
    if (n <= 1) return 0;
    if (n < 8) {
        double tmp[8];
        double scale = inverse ? (2.0 / (double)n) : 1.0;
        for (int32_t r = 0; r < rows; r++) {
            double *row = data + (size_t)r * (size_t)n;
            if (!inverse) {
                for (int32_t k = 0; k < n; k++) {
                    double sum = 0.0;
                    for (int32_t m = 0; m < n; m++) {
                        sum += row[m] * cos(M_PI * (double)k * ((double)m + 0.5) / (double)n);
                    }
                    tmp[k] = sum;
                }
            } else {
                for (int32_t m = 0; m < n; m++) {
                    double sum = 0.5 * row[0];
                    for (int32_t k = 1; k < n; k++) {
                        sum += row[k] * cos(M_PI * (double)k * ((double)m + 0.5) / (double)n);
                    }
                    tmp[m] = sum * scale;
                }
            }
            memcpy(row, tmp, (size_t)n * sizeof(double));
        }
        return 0;
    }

    int32_t isPow2 = ((n & (n - 1)) == 0);
    int32_t log2n = 0;
    if (isPow2) {
        while ((1 << log2n) < n) log2n++;
    }
    FFTSetupD setup = isPow2 ? vDSP_create_fftsetupD((vDSP_Length)log2n, kFFTRadix2) : NULL;
    if (isPow2 && !setup) return -1;

    double *re = (double *)malloc((size_t)n * sizeof(double));
    double *im = (double *)malloc((size_t)n * sizeof(double));
    double *twRe = (double *)malloc((size_t)n * sizeof(double));
    double *twIm = (double *)malloc((size_t)n * sizeof(double));
    if (!re || !im || !twRe || !twIm) {
        free(re); free(im); free(twRe); free(twIm);
        if (setup) vDSP_destroy_fftsetupD(setup);
        return -1;
    }
    for (int32_t k = 0; k < n; k++) {
        double ang = M_PI * (double)k / (2.0 * (double)n);
        twRe[k] = cos(ang);
        twIm[k] = sin(ang);
    }

    int32_t L = isPow2 ? 0 : next_pow2_i32(2 * n - 1);
    int32_t log2L = 0;
    while (!isPow2 && (1 << log2L) < L) log2L++;
    FFTSetupD setupL = isPow2 ? NULL : vDSP_create_fftsetupD((vDSP_Length)log2L, kFFTRadix2);
    double *ar = NULL, *ai = NULL, *br = NULL, *bi = NULL, *wr = NULL, *wi = NULL;
    if (!isPow2) {
        if (!setupL) {
            free(re); free(im); free(twRe); free(twIm);
            return -1;
        }
        ar = (double *)malloc((size_t)L * sizeof(double));
        ai = (double *)malloc((size_t)L * sizeof(double));
        br = (double *)calloc((size_t)L, sizeof(double));
        bi = (double *)calloc((size_t)L, sizeof(double));
        wr = (double *)malloc((size_t)n * sizeof(double));
        wi = (double *)malloc((size_t)n * sizeof(double));
        if (!ar || !ai || !br || !bi || !wr || !wi) {
            free(re); free(im); free(twRe); free(twIm);
            free(ar); free(ai); free(br); free(bi); free(wr); free(wi);
            vDSP_destroy_fftsetupD(setupL);
            return -1;
        }
        double sign = inverse ? 1.0 : -1.0;
        int64_t twoN = 2LL * n;
        for (int32_t k = 0; k < n; k++) {
            int64_t kk = ((int64_t)k * (int64_t)k) % twoN;
            double ang = sign * M_PI * (double)kk / (double)n;
            wr[k] = cos(ang);
            wi[k] = sin(ang);
        }
        br[0] = wr[0]; bi[0] = -wi[0];
        for (int32_t k = 1; k < n; k++) {
            br[k] = wr[k]; bi[k] = -wi[k];
            br[L - k] = wr[k]; bi[L - k] = -wi[k];
        }
        DSPDoubleSplitComplex sb = {br, bi};
        vDSP_fft_zipD(setupL, &sb, 1, (vDSP_Length)log2L, kFFTDirection_Forward);
    }

    int32_t halfEven = (n + 1) / 2;
    int32_t halfOdd = n / 2;
    double invScale = 2.0 / (double)n;
    double invL = (!isPow2 && L > 0) ? (1.0 / (double)L) : 0.0;

    for (int32_t r = 0; r < rows; r++) {
        double *row = data + (size_t)r * (size_t)n;
        if (!inverse) {
            for (int32_t j = 0; j < halfEven; j++) re[j] = row[2 * j];
            for (int32_t j = 0; j < halfOdd; j++) re[n - 1 - j] = row[2 * j + 1];
            memset(im, 0, (size_t)n * sizeof(double));
        } else {
            re[0] = 0.5 * row[0];
            im[0] = 0.0;
            for (int32_t k = 1; k < n; k++) {
                re[k] = row[k] * twRe[k];
                im[k] = row[k] * twIm[k];
            }
        }

        if (isPow2) {
            DSPDoubleSplitComplex sc = {re, im};
            vDSP_fft_zipD(setup, &sc, 1, (vDSP_Length)log2n,
                          inverse ? kFFTDirection_Inverse : kFFTDirection_Forward);
        } else {
            memset(ar, 0, (size_t)L * sizeof(double));
            memset(ai, 0, (size_t)L * sizeof(double));
            for (int32_t k = 0; k < n; k++) {
                ar[k] = re[k] * wr[k] - im[k] * wi[k];
                ai[k] = re[k] * wi[k] + im[k] * wr[k];
            }
            DSPDoubleSplitComplex sa = {ar, ai};
            vDSP_fft_zipD(setupL, &sa, 1, (vDSP_Length)log2L, kFFTDirection_Forward);
            for (int32_t k = 0; k < L; k++) {
                double tr = ar[k] * br[k] - ai[k] * bi[k];
                double ti = ar[k] * bi[k] + ai[k] * br[k];
                ar[k] = tr;
                ai[k] = ti;
            }
            vDSP_fft_zipD(setupL, &sa, 1, (vDSP_Length)log2L, kFFTDirection_Inverse);
            for (int32_t k = 0; k < n; k++) {
                double vr = ar[k] * invL, vi = ai[k] * invL;
                re[k] = vr * wr[k] - vi * wi[k];
                im[k] = vr * wi[k] + vi * wr[k];
            }
        }

        if (!inverse) {
            for (int32_t k = 0; k < n; k++) {
                row[k] = re[k] * twRe[k] + im[k] * twIm[k];
            }
        } else {
            for (int32_t j = 0; j < halfEven; j++) row[2 * j] = re[j] * invScale;
            for (int32_t j = 0; j < halfOdd; j++) row[2 * j + 1] = re[n - 1 - j] * invScale;
        }
    }

    free(re); free(im); free(twRe); free(twIm);
    if (setup) vDSP_destroy_fftsetupD(setup);
    if (setupL) {
        free(ar); free(ai); free(br); free(bi); free(wr); free(wi);
        vDSP_destroy_fftsetupD(setupL);
    }
    return 0;
}

int32_t sr_c_neumann_poisson_f64(double *rhsAndOut, int32_t w, int32_t h) {
    if (!rhsAndOut || w <= 0 || h <= 0) return -1;
    size_t n = (size_t)w * (size_t)h;
    double *trans = (double *)malloc(n * sizeof(double));
    double *cosX = (double *)malloc((size_t)w * sizeof(double));
    double *cosY = (double *)malloc((size_t)h * sizeof(double));
    if (!trans || !cosX || !cosY) {
        free(trans); free(cosX); free(cosY);
        return -1;
    }

    if (dct2_rows(rhsAndOut, h, w, 0) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(rhsAndOut, 1, trans, 1, (vDSP_Length)w, (vDSP_Length)h);
    if (dct2_rows(trans, w, h, 0) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(trans, 1, rhsAndOut, 1, (vDSP_Length)h, (vDSP_Length)w);

    for (int32_t x = 0; x < w; x++) cosX[x] = 2.0 * cos(M_PI * (double)x / (double)w);
    for (int32_t y = 0; y < h; y++) cosY[y] = 2.0 * cos(M_PI * (double)y / (double)h);

    for (int32_t y = 0; y < h; y++) {
        double cy = cosY[y] - 4.0;
        double *row = rhsAndOut + (size_t)y * (size_t)w;
        for (int32_t x = 0; x < w; x++) {
            double denom = cy + cosX[x];
            row[x] = (fabs(denom) > 1e-14) ? (row[x] / denom) : 0.0;
        }
    }

    if (dct2_rows(rhsAndOut, h, w, 1) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(rhsAndOut, 1, trans, 1, (vDSP_Length)w, (vDSP_Length)h);
    if (dct2_rows(trans, w, h, 1) != 0) { free(trans); free(cosX); free(cosY); return -1; }
    vDSP_mtransD(trans, 1, rhsAndOut, 1, (vDSP_Length)h, (vDSP_Length)w);

    free(trans); free(cosX); free(cosY);
    return 0;
}

// ============================================================================
// 5. NPR DOMAIN TRANSFORM & STYLIZATION / PENCIL SKETCH / DETAIL ENHANCE
// ============================================================================

static inline double lab_srgb_to_lin(double v) {
    return v <= 0.04045 ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4);
}
static inline double lab_lin_to_srgb(double v) {
    if (v <= 0.0) return 0.0;
    if (v >= 1.0) return 1.0;
    return v <= 0.0031308 ? (v * 12.92) : (1.055 * pow(v, 1.0 / 2.4) - 0.055);
}
static inline double lab_f(double t) {
    return t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0);
}
static inline double lab_finv(double t) {
    double t3 = t * t * t;
    return t3 > 0.008856 ? t3 : ((t - 16.0 / 116.0) / 7.787);
}
static inline void bgr_f_to_lab(double b, double g, double r, double *L, double *a, double *bLab) {
    double rl = lab_srgb_to_lin(r), gl = lab_srgb_to_lin(g), bl = lab_srgb_to_lin(b);
    double X = (0.412453 * rl + 0.357580 * gl + 0.180423 * bl) / 0.950456;
    double Y =  0.212671 * rl + 0.715160 * gl + 0.072169 * bl;
    double Z = (0.019334 * rl + 0.119193 * gl + 0.950227 * bl) / 1.088754;
    double fY = lab_f(Y);
    *L = Y > 0.008856 ? (116.0 * fY - 16.0) : (903.3 * Y);
    *a = 500.0 * (lab_f(X) - fY);
    *bLab = 200.0 * (fY - lab_f(Z));
}
static inline void lab_to_bgr_f(double L, double a, double bLab, double *b, double *g, double *r) {
    double fy = (L + 16.0) / 116.0;
    double Yn = L > 7.9996248 ? (fy * fy * fy) : (L / 903.3);
    double fyA = lab_f(Yn);
    double Xn = 0.950456 * lab_finv(fyA + a / 500.0);
    double Zn = 1.088754 * lab_finv(fyA - bLab / 200.0);
    *r = lab_lin_to_srgb( 3.240479 * Xn - 1.537150 * Yn - 0.498535 * Zn);
    *g = lab_lin_to_srgb(-0.969256 * Xn + 1.875992 * Yn + 0.041556 * Zn);
    *b = lab_lin_to_srgb( 0.055648 * Xn - 0.204043 * Yn + 1.057311 * Zn);
}

static void dt_compute_ct_h(const float *img, int32_t w, int32_t h, int32_t jCh, float sigmaS, float sigmaR, float *ctH) {
    float scale = sigmaS / sigmaR;
    for (int32_t y = 0; y < h; y++) {
        const float *r = img + (size_t)y * (size_t)w * (size_t)jCh;
        float *c = ctH + (size_t)y * (size_t)w;
        c[0] = 0.0f;
        for (int32_t x = 1; x < w; x++) {
            float d = 0.0f;
            for (int32_t k = 0; k < jCh; k++) {
                d += fabsf(r[x * jCh + k] - r[(x - 1) * jCh + k]);
            }
            c[x] = c[x - 1] + 1.0f + scale * d;
        }
    }
}

static void dt_compute_ct_v(const float *img, int32_t w, int32_t h, int32_t jCh, float sigmaS, float sigmaR, float *ctV) {
    float scale = sigmaS / sigmaR;
    // Transposed layout (w x h) so vertical pass runs contiguously
    for (int32_t x = 0; x < w; x++) {
        float *c = ctV + (size_t)x * (size_t)h;
        c[0] = 0.0f;
        for (int32_t y = 1; y < h; y++) {
            const float *p1 = img + ((size_t)y * (size_t)w + (size_t)x) * (size_t)jCh;
            const float *p0 = img + ((size_t)(y - 1) * (size_t)w + (size_t)x) * (size_t)jCh;
            float d = 0.0f;
            for (int32_t k = 0; k < jCh; k++) {
                d += fabsf(p1[k] - p0[k]);
            }
            c[y] = c[y - 1] + 1.0f + scale * d;
        }
    }
}

static void dt_rf_1d_pass(float *buf, const float *ct, int32_t len, int32_t ch, float sigmaH) {
    float a = expf(-sqrtf(2.0f) / sigmaH);
    // Forward pass
    for (int32_t i = 1; i < len; i++) {
        float d = ct[i] - ct[i - 1];
        float w = powf(a, d);
        float oneMinusW = 1.0f - w;
        for (int32_t c = 0; c < ch; c++) {
            buf[i * ch + c] = buf[i * ch + c] * oneMinusW + buf[(i - 1) * ch + c] * w;
        }
    }
    // Backward pass
    for (int32_t i = len - 2; i >= 0; i--) {
        float d = ct[i + 1] - ct[i];
        float w = powf(a, d);
        float oneMinusW = 1.0f - w;
        for (int32_t c = 0; c < ch; c++) {
            buf[i * ch + c] = buf[i * ch + c] * oneMinusW + buf[(i + 1) * ch + c] * w;
        }
    }
}

static void dt_nc_1d_pass(float *buf, const float *ct, int32_t len, int32_t ch, float rad, float *sat) {
    // sat has (len + 1) * ch entries
    for (int32_t c = 0; c < ch; c++) sat[c] = 0.0f;
    for (int32_t i = 0; i < len; i++) {
        for (int32_t c = 0; c < ch; c++) {
            sat[(i + 1) * ch + c] = sat[i * ch + c] + buf[i * ch + c];
        }
    }
    int32_t l = 0, u = 0;
    for (int32_t i = 0; i < len; i++) {
        float lo = ct[i] - rad;
        float hi = ct[i] + rad;
        while (l < i && ct[l] < lo) l++;
        while (u + 1 < len && ct[u + 1] <= hi) u++;
        float invCount = 1.0f / (float)(u - l + 1);
        for (int32_t c = 0; c < ch; c++) {
            buf[i * ch + c] = (sat[(u + 1) * ch + c] - sat[l * ch + c]) * invCount;
        }
    }
}

static int32_t dt_filter_float(const float *joint, int32_t jCh, float *img, int32_t w, int32_t h, int32_t ch,
                               int32_t flags, float sigmaS, float sigmaR) {
    if (sigmaS < 1e-3f) sigmaS = 1e-3f;
    if (sigmaR < 1e-4f) sigmaR = 1e-4f;
    size_t npix = (size_t)w * (size_t)h;
    float *ctH = (float *)malloc(npix * sizeof(float));
    float *ctV = (float *)malloc(npix * sizeof(float));
    int32_t maxDim = w > h ? w : h;
    float *colBuf = (float *)malloc((size_t)maxDim * (size_t)ch * sizeof(float));
    float *satBuf = (float *)malloc((size_t)(maxDim + 1) * (size_t)ch * sizeof(float));
    if (!ctH || !ctV || !colBuf || !satBuf) {
        free(ctH); free(ctV); free(colBuf); free(satBuf);
        return -1;
    }

    dt_compute_ct_h(joint, w, h, jCh, sigmaS, sigmaR, ctH);
    dt_compute_ct_v(joint, w, h, jCh, sigmaS, sigmaR, ctV);

    const int32_t nIter = 3;
    float denom = sqrtf((float)((1 << (2 * nIter)) - 1));
    for (int32_t it = 0; it < nIter; it++) {
        float sigmaH = sigmaS * sqrtf(3.0f) * (float)(1 << (nIter - 1 - it)) / denom;
        float rad = sqrtf(3.0f) * sigmaH;
        // Horizontal
        for (int32_t y = 0; y < h; y++) {
            float *row = img + (size_t)y * (size_t)w * (size_t)ch;
            const float *ct = ctH + (size_t)y * (size_t)w;
            if (flags == 1) dt_rf_1d_pass(row, ct, w, ch, sigmaH);
            else dt_nc_1d_pass(row, ct, w, ch, rad, satBuf);
        }
        // Vertical
        for (int32_t x = 0; x < w; x++) {
            for (int32_t y = 0; y < h; y++) {
                const float *p = img + ((size_t)y * (size_t)w + (size_t)x) * (size_t)ch;
                for (int32_t c = 0; c < ch; c++) colBuf[y * ch + c] = p[c];
            }
            const float *ct = ctV + (size_t)x * (size_t)h;
            if (flags == 1) dt_rf_1d_pass(colBuf, ct, h, ch, sigmaH);
            else dt_nc_1d_pass(colBuf, ct, h, ch, rad, satBuf);
            for (int32_t y = 0; y < h; y++) {
                float *p = img + ((size_t)y * (size_t)w + (size_t)x) * (size_t)ch;
                for (int32_t c = 0; c < ch; c++) p[c] = colBuf[y * ch + c];
            }
        }
    }

    free(ctH); free(ctV); free(colBuf); free(satBuf);
    return 0;
}

// mode: 0 = edgePreservingFilter, 1 = detailEnhance, 2 = pencilSketch, 3 = stylization
int32_t sr_c_npr_filter_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                           uint8_t *dst1, int32_t dst1Stride, uint8_t *dst2, int32_t dst2Stride,
                           int32_t mode, int32_t flags, float sigmaS, float sigmaR, float shadeFactor) {
    if (!src || !dst1 || w <= 0 || h <= 0) return -1;
    if (mode == 2 && !dst2) return -1;
    size_t npix = (size_t)w * (size_t)h;
    float *joint = (float *)malloc(npix * 3u * sizeof(float));
    float *work = (float *)malloc(npix * 3u * sizeof(float));
    if (!joint || !work) { free(joint); free(work); return -1; }

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *sr = src + (size_t)y * (size_t)srcStride;
        for (int32_t x = 0; x < w; x++) {
            size_t idx = ((size_t)y * (size_t)w + (size_t)x) * 3u;
            for (int32_t c = 0; c < 3; c++) {
                float v = (float)sr[x * 3 + c] * (1.0f / 255.0f);
                joint[idx + c] = v;
                work[idx + c] = v;
            }
        }
    }

    if (mode == 0) {
        if (dt_filter_float(joint, 3, work, w, h, 3, flags == 2 ? 2 : 1, sigmaS, sigmaR) != 0) {
            free(joint); free(work); return -1;
        }
        for (int32_t y = 0; y < h; y++) {
            uint8_t *dr = dst1 + (size_t)y * (size_t)dst1Stride;
            for (int32_t x = 0; x < w; x++) {
                size_t idx = ((size_t)y * (size_t)w + (size_t)x) * 3u;
                for (int32_t c = 0; c < 3; c++) dr[x * 3 + c] = sat_u8_d((double)(work[idx + c] * 255.0f));
            }
        }
    } else if (mode == 1) {
        // detailEnhance: 1-ch Domain Transform RECURS_FILTER on Lab L/100 with sigmaR * 2.55
        float *lJoint = (float *)malloc(npix * sizeof(float));
        float *lSm = (float *)malloc(npix * sizeof(float));
        double *abBuf = (double *)malloc(npix * 2u * sizeof(double));
        double *lOrig = (double *)malloc(npix * sizeof(double));
        if (!lJoint || !lSm || !abBuf || !lOrig) {
            free(lJoint); free(lSm); free(abBuf); free(lOrig);
            free(joint); free(work);
            return -1;
        }
        for (size_t i = 0; i < npix; i++) {
            double L = 0.0, a = 0.0, bLab = 0.0;
            bgr_f_to_lab((double)joint[i * 3u], (double)joint[i * 3u + 1u], (double)joint[i * 3u + 2u],
                         &L, &a, &bLab);
            lOrig[i] = L;
            abBuf[i * 2u + 0u] = a;
            abBuf[i * 2u + 1u] = bLab;
            float ln = (float)(L * 0.01);
            lJoint[i] = ln;
            lSm[i] = ln;
        }
        if (dt_filter_float(lJoint, 1, lSm, w, h, 1, 1, sigmaS, sigmaR * 2.55f) != 0) {
            free(lJoint); free(lSm); free(abBuf); free(lOrig);
            free(joint); free(work);
            return -1;
        }
        for (int32_t y = 0; y < h; y++) {
            uint8_t *dr = dst1 + (size_t)y * (size_t)dst1Stride;
            for (int32_t x = 0; x < w; x++) {
                size_t i = (size_t)y * (size_t)w + (size_t)x;
                double L = lOrig[i];
                double lEnh = L + 2.0 * (L - (double)lSm[i] * 100.0);
                double bo = 0.0, go = 0.0, ro = 0.0;
                lab_to_bgr_f(lEnh, abBuf[i * 2u + 0u], abBuf[i * 2u + 1u], &bo, &go, &ro);
                dr[x * 3 + 0] = sat_u8_d(bo * 255.0);
                dr[x * 3 + 1] = sat_u8_d(go * 255.0);
                dr[x * 3 + 2] = sat_u8_d(ro * 255.0);
            }
        }
        free(lJoint); free(lSm); free(abBuf); free(lOrig);
    } else if (mode == 2) {
        // pencilSketch: Domain Transform NC pixel-count sketch + YCrCb color transfer
        float sS = sigmaS > 1e-3f ? sigmaS : 1e-3f;
        float sR = sigmaR > 1e-4f ? sigmaR : 1e-4f;
        float *ctH = (float *)malloc(npix * sizeof(float));
        float *ctV = (float *)malloc(npix * sizeof(float));
        float *cH = (float *)malloc(npix * sizeof(float));
        float *cV = (float *)malloc(npix * sizeof(float));
        if (!ctH || !ctV || !cH || !cV) {
            free(ctH); free(ctV); free(cH); free(cV);
            free(joint); free(work);
            return -1;
        }
        dt_compute_ct_h(joint, w, h, 3, sS, sR, ctH);
        dt_compute_ct_v(joint, w, h, 3, sS, sR, ctV);

        float rad = sS * (12.0f / sqrtf(63.0f));
        for (int32_t y = 0; y < h; y++) {
            const float *ct = ctH + (size_t)y * (size_t)w;
            float *chRow = cH + (size_t)y * (size_t)w;
            int32_t l = 0, u = 0;
            for (int32_t x = 0; x < w; x++) {
                float lo = ct[x] - rad;
                float hi = ct[x] + rad;
                while (l < x && ct[l] < lo) l++;
                while (u + 1 < w && ct[u + 1] <= hi) u++;
                chRow[x] = (float)(u - l + 1);
            }
        }
        for (int32_t x = 0; x < w; x++) {
            const float *ct = ctV + (size_t)x * (size_t)h;
            int32_t l = 0, u = 0;
            for (int32_t y = 0; y < h; y++) {
                float lo = ct[y] - rad;
                float hi = ct[y] + rad;
                while (l < y && ct[l] < lo) l++;
                while (u + 1 < h && ct[u + 1] <= hi) u++;
                cV[(size_t)y * (size_t)w + (size_t)x] = (float)(u - l + 1);
            }
        }
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *sr = src + (size_t)y * (size_t)srcStride;
            uint8_t *d1 = dst1 + (size_t)y * (size_t)dst1Stride;
            uint8_t *d2 = dst2 + (size_t)y * (size_t)dst2Stride;
            for (int32_t x = 0; x < w; x++) {
                size_t i = (size_t)y * (size_t)w + (size_t)x;
                float g = clamp_f32((cH[i] + cV[i]) * shadeFactor * 255.0f, 0.0f, 255.0f);
                uint8_t gu8 = sat_u8_d((double)g);
                d1[x] = gu8;
                // Color sketch: replace Y in YCrCb with sketch luminance
                double b = (double)sr[x * 3], gr = (double)sr[x * 3 + 1], r = (double)sr[x * 3 + 2];
                double yy = 0.299 * r + 0.587 * gr + 0.114 * b;
                double cr = (r - yy) * 0.713;
                double cb = (b - yy) * 0.564;
                double ny = (double)gu8;
                double ro = ny + 1.403 * cr;
                double bo = ny + 1.773 * cb;
                double go = ny - 0.714 * cr - 0.344 * cb;
                d2[x * 3 + 0] = sat_u8_d(bo);
                d2[x * 3 + 1] = sat_u8_d(go);
                d2[x * 3 + 2] = sat_u8_d(ro);
            }
        }
        free(ctH); free(ctV); free(cH); free(cV);
    } else {
        // stylization: NORMCONV_FILTER smooth + Sobel edge attenuation
        if (dt_filter_float(joint, 3, work, w, h, 3, 2, sigmaS, sigmaR) != 0) {
            free(joint); free(work); return -1;
        }
        for (int32_t y = 0; y < h; y++) {
            uint8_t *dr = dst1 + (size_t)y * (size_t)dst1Stride;
            int32_t ym = reflect101(y - 1, h);
            int32_t yp = reflect101(y + 1, h);
            for (int32_t x = 0; x < w; x++) {
                int32_t xm = reflect101(x - 1, w);
                int32_t xp = reflect101(x + 1, w);
                size_t idx = ((size_t)y * (size_t)w + (size_t)x) * 3u;
                float gradSum = 0.0f;
                for (int32_t c = 0; c < 3; c++) {
                    float tl = work[((size_t)ym * (size_t)w + (size_t)xm) * 3u + c];
                    float tc = work[((size_t)ym * (size_t)w + (size_t)x) * 3u + c];
                    float tr = work[((size_t)ym * (size_t)w + (size_t)xp) * 3u + c];
                    float ml = work[((size_t)y * (size_t)w + (size_t)xm) * 3u + c];
                    float mr = work[((size_t)y * (size_t)w + (size_t)xp) * 3u + c];
                    float bl = work[((size_t)yp * (size_t)w + (size_t)xm) * 3u + c];
                    float bc = work[((size_t)yp * (size_t)w + (size_t)x) * 3u + c];
                    float br = work[((size_t)yp * (size_t)w + (size_t)xp) * 3u + c];
                    float gx = (tr + 2.0f * mr + br) - (tl + 2.0f * ml + bl);
                    float gy = (bl + 2.0f * bc + br) - (tl + 2.0f * tc + tr);
                    gradSum += hypotf(gx, gy);
                }
                float edge = clamp_f32(1.0f - gradSum, 0.0f, 1.0f);
                for (int32_t c = 0; c < 3; c++) {
                    dr[x * 3 + c] = sat_u8_d((double)(work[idx + c] * edge * 255.0f));
                }
            }
        }
    }

    free(joint); free(work);
    return 0;
}

// ============================================================================
// 6. DECOLORIZATION (Lu et al. 2012 + Lab color boost)
// ============================================================================

static void decolor_add_pair(const double *feats, const double *labL, const double *labA, const double *labB,
                             int32_t i1, int32_t i2, double *P, double *delta, int32_t *nPairs) {
    double dL = labL[i1] - labL[i2];
    double da = labA[i1] - labA[i2];
    double db = labB[i1] - labB[i2];
    double dlt = sqrt(dL * dL + da * da + db * db) * (1.4142135623730950488 * 0.01);
    if (dlt < 0.05) return;
    int32_t idx = *nPairs;
    const double *f1 = feats + (size_t)i1 * 9u;
    const double *f2 = feats + (size_t)i2 * 9u;
    double *prow = P + (size_t)idx * 9u;
    for (int j = 0; j < 9; j++) prow[j] = f1[j] - f2[j];
    delta[idx] = dlt;
    *nPairs = idx + 1;
}

int32_t sr_c_decolor_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                        uint8_t *gray, int32_t grayStride, uint8_t *boost, int32_t boostStride) {
    if (!src || !gray || w <= 0 || h <= 0) return -1;
    size_t npix = (size_t)w * (size_t)h;
    const double inv255 = 1.0 / 255.0;

    // Downsample to max_side <= 70 (Lu et al. 2012)
    int32_t maxSide = w > h ? w : h;
    int32_t sw = w, sh = h;
    if (maxSide > 70) {
        double scale = 70.0 / (double)maxSide;
        sw = (int32_t)llround((double)w * scale);
        sh = (int32_t)llround((double)h * scale);
        if (sw < 1) sw = 1;
        if (sh < 1) sh = 1;
    }
    int32_t nSmall = sw * sh;
    double *feats = (double *)malloc((size_t)nSmall * 9u * sizeof(double));
    double *labL = (double *)malloc((size_t)nSmall * sizeof(double));
    double *labA = (double *)malloc((size_t)nSmall * sizeof(double));
    double *labB = (double *)malloc((size_t)nSmall * sizeof(double));
    if (!feats || !labL || !labA || !labB) {
        free(feats); free(labL); free(labA); free(labB);
        return -1;
    }

    for (int32_t sy = 0; sy < sh; sy++) {
        double y0 = (double)sy * (double)h / (double)sh;
        double y1 = (double)(sy + 1) * (double)h / (double)sh;
        int32_t iy0 = (int32_t)floor(y0);
        int32_t iy1 = (int32_t)ceil(y1);
        if (iy0 < 0) iy0 = 0;
        if (iy1 > h) iy1 = h;
        for (int32_t sx = 0; sx < sw; sx++) {
            double x0 = (double)sx * (double)w / (double)sw;
            double x1 = (double)(sx + 1) * (double)w / (double)sw;
            int32_t ix0 = (int32_t)floor(x0);
            int32_t ix1 = (int32_t)ceil(x1);
            if (ix0 < 0) ix0 = 0;
            if (ix1 > w) ix1 = w;
            double sb = 0.0, sg = 0.0, srAcc = 0.0, wSum = 0.0;
            for (int32_t yy = iy0; yy < iy1; yy++) {
                double wy = fmin((double)(yy + 1), y1) - fmax((double)yy, y0);
                if (wy <= 0.0) continue;
                const uint8_t *row = src + (size_t)yy * (size_t)srcStride;
                for (int32_t xx = ix0; xx < ix1; xx++) {
                    double wx = fmin((double)(xx + 1), x1) - fmax((double)xx, x0);
                    if (wx <= 0.0) continue;
                    double weight = wx * wy;
                    sb += (double)row[xx * 3 + 0] * weight;
                    sg += (double)row[xx * 3 + 1] * weight;
                    srAcc += (double)row[xx * 3 + 2] * weight;
                    wSum += weight;
                }
            }
            double normW = (wSum > 0.0) ? (inv255 / wSum) : inv255;
            double b = sb * normW, g = sg * normW, r = srAcc * normW;
            int32_t idx = sy * sw + sx;
            double *f = feats + (size_t)idx * 9u;
            f[0] = r; f[1] = g; f[2] = b;
            f[3] = r * g; f[4] = r * b; f[5] = g * b;
            f[6] = r * r; f[7] = g * g; f[8] = b * b;
            bgr_f_to_lab(b, g, r, &labL[idx], &labA[idx], &labB[idx]);
        }
    }

    int32_t maxPairs = (sw > 1 ? sh * (sw - 1) : 0) + (sh > 1 ? (sh - 1) * sw : 0);
    double *P = maxPairs > 0 ? (double *)malloc((size_t)maxPairs * 9u * sizeof(double)) : NULL;
    double *delta = maxPairs > 0 ? (double *)malloc((size_t)maxPairs * sizeof(double)) : NULL;
    if (maxPairs > 0 && (!P || !delta)) {
        free(P); free(delta);
        free(feats); free(labL); free(labA); free(labB);
        return -1;
    }

    int32_t nPairs = 0;
    for (int32_t y = 0; y < sh; y++) {
        for (int32_t x = 0; x + 1 < sw; x++) {
            decolor_add_pair(feats, labL, labA, labB, y * sw + x, y * sw + x + 1, P, delta, &nPairs);
        }
    }
    for (int32_t y = 0; y + 1 < sh; y++) {
        for (int32_t x = 0; x < sw; x++) {
            decolor_add_pair(feats, labL, labA, labB, y * sw + x, (y + 1) * sw + x, P, delta, &nPairs);
        }
    }

    double wVec[9] = {0.299, 0.587, 0.114, 0, 0, 0, 0, 0, 0};
    if (nPairs >= 2) {
        double A[81];
        memset(A, 0, sizeof(A));
        for (int32_t i = 0; i < nPairs; i++) {
            const double *pi = P + (size_t)i * 9u;
            for (int r = 0; r < 9; r++) {
                for (int c = 0; c < 9; c++) A[r * 9 + c] += pi[r] * pi[c];
            }
        }
        double reg = 1e-6 * (double)nPairs;
        for (int d = 0; d < 9; d++) A[d * 9 + d] += reg;

        for (int iter = 0; iter < 15; iter++) {
            double bVec[9] = {0};
            for (int32_t i = 0; i < nPairs; i++) {
                const double *pi = P + (size_t)i * 9u;
                double dot = 0.0;
                for (int j = 0; j < 9; j++) dot += pi[j] * wVec[j];
                double dlt = delta[i];
                double target = tanh(dot * dlt / 0.0025) * dlt;
                for (int j = 0; j < 9; j++) bVec[j] += pi[j] * target;
            }
            bVec[0] += reg * 0.299;
            bVec[1] += reg * 0.587;
            bVec[2] += reg * 0.114;

            double M[81];
            memcpy(M, A, sizeof(A));
            double xSol[9];
            memcpy(xSol, bVec, sizeof(bVec));
            for (int col = 0; col < 9; col++) {
                int piv = col;
                for (int row = col + 1; row < 9; row++) {
                    if (fabs(M[row * 9 + col]) > fabs(M[piv * 9 + col])) piv = row;
                }
                if (piv != col) {
                    for (int k = col; k < 9; k++) {
                        double tmp = M[col * 9 + k]; M[col * 9 + k] = M[piv * 9 + k]; M[piv * 9 + k] = tmp;
                    }
                    double tmp = xSol[col]; xSol[col] = xSol[piv]; xSol[piv] = tmp;
                }
                double diag = M[col * 9 + col];
                if (fabs(diag) < 1e-14) continue;
                for (int row = col + 1; row < 9; row++) {
                    double fac = M[row * 9 + col] / diag;
                    for (int k = col; k < 9; k++) M[row * 9 + k] -= fac * M[col * 9 + k];
                    xSol[row] -= fac * xSol[col];
                }
            }
            for (int row = 8; row >= 0; row--) {
                double sum = xSol[row];
                for (int k = row + 1; k < 9; k++) sum -= M[row * 9 + k] * wVec[k];
                wVec[row] = fabs(M[row * 9 + row]) > 1e-14 ? (sum / M[row * 9 + row]) : 0.0;
            }
        }
    }

    double *rawG = (double *)malloc(npix * sizeof(double));
    if (!rawG) {
        free(P); free(delta); free(feats); free(labL); free(labA); free(labB);
        return -1;
    }
    double gMin = 1e30, gMax = -1e30;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *sr = src + (size_t)y * (size_t)srcStride;
        for (int32_t x = 0; x < w; x++) {
            double b = sr[x * 3] * inv255, g = sr[x * 3 + 1] * inv255, r = sr[x * 3 + 2] * inv255;
            double v = wVec[0] * r + wVec[1] * g + wVec[2] * b
                     + wVec[3] * r * g + wVec[4] * r * b + wVec[5] * g * b
                     + wVec[6] * r * r + wVec[7] * g * g + wVec[8] * b * b;
            rawG[(size_t)y * (size_t)w + (size_t)x] = v;
            if (v < gMin) gMin = v;
            if (v > gMax) gMax = v;
        }
    }

    double gSpan = gMax - gMin;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *sr = src + (size_t)y * (size_t)srcStride;
        uint8_t *gr = gray + (size_t)y * (size_t)grayStride;
        uint8_t *br = boost ? (boost + (size_t)y * (size_t)boostStride) : NULL;
        for (int32_t x = 0; x < w; x++) {
            double v = rawG[(size_t)y * (size_t)w + (size_t)x];
            double normG = (gSpan > 1e-9) ? ((v - gMin) / gSpan) : clamp_f64(v, 0.0, 1.0);
            uint8_t gv = sat_u8_d(normG * 255.0);
            gr[x] = gv;
            if (br) {
                double origL = 0.0, a = 0.0, bLab = 0.0;
                bgr_f_to_lab(sr[x * 3 + 0] * inv255, sr[x * 3 + 1] * inv255, sr[x * 3 + 2] * inv255,
                             &origL, &a, &bLab);
                double aq = (double)sat_u8_d(a + 128.0) - 128.0;
                double bq = (double)sat_u8_d(bLab + 128.0) - 128.0;
                double Lnew = (double)gv * (100.0 / 255.0);
                double bo = 0.0, go = 0.0, ro = 0.0;
                lab_to_bgr_f(Lnew, aq, bq, &bo, &go, &ro);
                br[x * 3 + 0] = sat_u8_d(bo * 255.0);
                br[x * 3 + 1] = sat_u8_d(go * 255.0);
                br[x * 3 + 2] = sat_u8_d(ro * 255.0);
            }
        }
    }

    free(P); free(delta); free(feats); free(labL); free(labA); free(labB); free(rawG);
    return 0;
}

// ============================================================================
// 7. BAYER DEMOSAICING (Bilinear, Edge-Aware EA, VNG)
// ============================================================================
// pattern: 0 = BG/RGGB, 1 = GB/GRBG, 2 = RG/BGGR, 3 = GR/GBRG
// At (r & 1, c & 1):
//   0 (BG): (0,0)=R, (0,1)=G, (1,0)=G, (1,1)=B
//   1 (GB): (0,0)=G, (0,1)=R, (1,0)=B, (1,1)=G
//   2 (RG): (0,0)=B, (0,1)=G, (1,0)=G, (1,1)=R
//   3 (GR): (0,0)=G, (0,1)=B, (1,0)=R, (1,1)=G
// algo: 0 = Bilinear, 1 = EA, 2 = VNG, 3 = Gray

static inline int bayer_color_at(int32_t y, int32_t x, int32_t pattern) {
    // Returns 0 = B, 1 = G, 2 = R
    static const int lut[4][2][2] = {
        {{2, 1}, {1, 0}}, // BG (RGGB)
        {{1, 2}, {0, 1}}, // GB (GRBG)
        {{0, 1}, {1, 2}}, // RG (BGGR)
        {{1, 0}, {2, 1}}, // GR (GBRG)
    };
    return lut[pattern & 3][y & 1][x & 1];
}

static void vng_gradients(const double *c, int32_t pw, int isGreen, double *g) {
    double vCenter = c[0];
    double vN = c[-pw], vS = c[pw], vW = c[-1], vE = c[1];
    double vNW = c[-pw - 1], vNE = c[-pw + 1], vSW = c[pw - 1], vSE = c[pw + 1];
    g[0] = fabs(vN - vS) + fabs(c[-2 * pw] - vCenter)
         + 0.5 * (fabs(vNW - vSW) + fabs(vNE - vSE))
         + 0.5 * (fabs(c[-2 * pw - 1] - c[-1]) + fabs(c[-2 * pw + 1] - c[1]));
    g[1] = fabs(vS - vN) + fabs(c[2 * pw] - vCenter)
         + 0.5 * (fabs(vSW - vNW) + fabs(vSE - vNE))
         + 0.5 * (fabs(c[2 * pw - 1] - c[-1]) + fabs(c[2 * pw + 1] - c[1]));
    g[2] = fabs(vE - vW) + fabs(c[2] - vCenter)
         + 0.5 * (fabs(vNE - vNW) + fabs(vSE - vSW))
         + 0.5 * (fabs(c[-pw + 2] - c[-pw]) + fabs(c[pw + 2] - c[pw]));
    g[3] = fabs(vW - vE) + fabs(c[-2] - vCenter)
         + 0.5 * (fabs(vNW - vNE) + fabs(vSW - vSE))
         + 0.5 * (fabs(c[-pw - 2] - c[-pw]) + fabs(c[pw - 2] - c[pw]));
    g[4] = fabs(vNE - vSW) + fabs(c[-2 * pw + 2] - vCenter)
         + 0.5 * (fabs(c[-2 * pw + 1] - c[-1]) + fabs(c[-pw + 2] - c[pw]))
         + (isGreen ? 0.5 * (fabs(vN - vE) + fabs(c[-2 * pw] - vNE)) : 0.0);
    g[5] = fabs(vSE - vNW) + fabs(c[2 * pw + 2] - vCenter)
         + 0.5 * (fabs(c[pw + 2] - c[-pw]) + fabs(c[2 * pw + 1] - c[-1]))
         + (isGreen ? 0.5 * (fabs(vS - vE) + fabs(c[2 * pw] - vSE)) : 0.0);
    g[6] = fabs(vNW - vSE) + fabs(c[-2 * pw - 2] - vCenter)
         + 0.5 * (fabs(c[-2 * pw - 1] - c[1]) + fabs(c[-pw - 2] - c[pw]))
         + (isGreen ? 0.5 * (fabs(vN - vW) + fabs(c[-2 * pw] - vNW)) : 0.0);
    g[7] = fabs(vSW - vNE) + fabs(c[2 * pw - 2] - vCenter)
         + 0.5 * (fabs(c[pw - 2] - c[-pw]) + fabs(c[2 * pw - 1] - c[1]))
         + (isGreen ? 0.5 * (fabs(vS - vW) + fabs(c[2 * pw] - vSW)) : 0.0);
}

int32_t sr_c_demosaic(const void *src, int32_t w, int32_t h, int32_t srcStrideBytes, int32_t depth,
                      void *dst, int32_t dstStrideBytes, int32_t dstCh, int32_t pattern, int32_t algo) {
    if (!src || !dst || w <= 0 || h <= 0) return -1;
    if (depth != 0 && depth != 2) return -1;
    if (dstCh != 1 && dstCh != 3 && dstCh != 4) return -1;

    // Padded border of 2 pixels around image with reflect101 for clean 5x5 VNG/EA stencils
    int32_t pad = 2;
    int32_t pw = w + 2 * pad, ph = h + 2 * pad;
    double *p = (double *)malloc((size_t)pw * (size_t)ph * sizeof(double));
    if (!p) return -1;

    for (int32_t py = 0; py < ph; py++) {
        int32_t sy = reflect101(py - pad, h);
        const uint8_t *sr = (const uint8_t *)src + (size_t)sy * (size_t)srcStrideBytes;
        for (int32_t px = 0; px < pw; px++) {
            int32_t sx = reflect101(px - pad, w);
            p[(size_t)py * (size_t)pw + (size_t)px] = (depth == 0)
                ? (double)sr[sx]
                : (double)((const uint16_t *)sr)[sx];
        }
    }

    double maxVal = (depth == 0) ? 255.0 : 65535.0;
    int32_t copyBorder = (algo != 2 && w > 2 && h > 2) ? 1 : 0;
    int32_t yStart = copyBorder ? 1 : 0;
    int32_t yEnd = copyBorder ? (h - 1) : h;
    int32_t xStart = copyBorder ? 1 : 0;
    int32_t xEnd = copyBorder ? (w - 1) : w;
    for (int32_t y = yStart; y < yEnd; y++) {
        uint8_t *dr = (uint8_t *)dst + (size_t)y * (size_t)dstStrideBytes;
        int32_t py = y + pad;
        for (int32_t x = xStart; x < xEnd; x++) {
            int32_t px = x + pad;
            const double *c = p + (size_t)py * (size_t)pw + (size_t)px;
            int col = bayer_color_at(y, x, pattern);
            double bgr[3] = {0.0, 0.0, 0.0};

            double vCenter = c[0];
            double vN = c[-pw], vS = c[pw], vW = c[-1], vE = c[1];
            double vNW = c[-pw - 1], vNE = c[-pw + 1], vSW = c[pw - 1], vSE = c[pw + 1];

            if (col == 1) {
                // At Green site
                bgr[1] = vCenter;
                int leftCol = bayer_color_at(y, x + 1, pattern); // 0=B or 2=R
                double hv, vv;
                if (algo == 2) {
                    double g[8];
                    vng_gradients(c, pw, 1, g);
                    double gmin = g[0], gmax = g[0];
                    for (int k = 1; k < 8; k++) {
                        if (g[k] < gmin) gmin = g[k];
                        if (g[k] > gmax) gmax = g[k];
                    }
                    double thresh = 1.5 * gmin + 0.5 * (gmax - gmin);
                    double gAvg[8] = {c[-2 * pw], c[2 * pw], c[2], c[-2], vNE, vSE, vNW, vSW};
                    double hE[8] = {
                        0.5 * (c[-2 * pw - 1] + c[-2 * pw + 1]),
                        0.5 * (c[2 * pw - 1] + c[2 * pw + 1]),
                        vE, vW, vE, vE, vW, vW,
                    };
                    double vE2[8] = {
                        vN, vS,
                        0.5 * (c[-pw + 2] + c[pw + 2]),
                        0.5 * (c[-pw - 2] + c[pw - 2]),
                        vN, vS, vN, vS,
                    };
                    double sumG = 0.0, sumH = 0.0, sumV = 0.0;
                    int cnt = 0;
                    for (int k = 0; k < 8; k++) {
                        if (g[k] <= thresh) {
                            sumG += gAvg[k];
                            sumH += hE[k];
                            sumV += vE2[k];
                            cnt++;
                        }
                    }
                    if (cnt > 0) {
                        double invC = 1.0 / (double)cnt;
                        hv = clamp_f64(vCenter + (sumH - sumG) * invC, 0.0, maxVal);
                        vv = clamp_f64(vCenter + (sumV - sumG) * invC, 0.0, maxVal);
                    } else {
                        hv = 0.5 * (vW + vE);
                        vv = 0.5 * (vN + vS);
                    }
                } else {
                    hv = 0.5 * (vW + vE);
                    vv = 0.5 * (vN + vS);
                }
                if (leftCol == 0) {
                    bgr[0] = hv;
                    bgr[2] = vv;
                } else {
                    bgr[2] = hv;
                    bgr[0] = vv;
                }
            } else {
                // At Red (col=2) or Blue (col=0) site
                int opp = 2 - col;
                bgr[col] = vCenter;
                if (algo == 1) {
                    // Edge-Aware directional green + bilinear opposite color
                    double dh = fabs(vW - vE);
                    double dv = fabs(vN - vS);
                    if (dh < dv) {
                        bgr[1] = 0.5 * (vW + vE);
                    } else if (dv < dh) {
                        bgr[1] = 0.5 * (vN + vS);
                    } else {
                        bgr[1] = 0.25 * (vN + vS + vW + vE);
                    }
                    bgr[opp] = 0.25 * (vNW + vNE + vSW + vSE);
                } else if (algo == 2) {
                    // VNG: 8-direction gradients in 5x5 neighborhood
                    double g[8];
                    vng_gradients(c, pw, 0, g);
                    double gmin = g[0], gmax = g[0];
                    for (int k = 1; k < 8; k++) {
                        if (g[k] < gmin) gmin = g[k];
                        if (g[k] > gmax) gmax = g[k];
                    }
                    double thresh = 1.5 * gmin + 0.5 * (gmax - gmin);
                    double gEst[8] = {
                        vN, vS, vE, vW,
                        0.5 * (vN + vE), 0.5 * (vS + vE), 0.5 * (vN + vW), 0.5 * (vS + vW),
                    };
                    double cD[8] = {
                        c[-2 * pw], c[2 * pw], c[2], c[-2],
                        c[-2 * pw + 2], c[2 * pw + 2], c[-2 * pw - 2], c[2 * pw - 2],
                    };
                    double oEst[8] = {
                        0.5 * (vNW + vNE), 0.5 * (vSW + vSE), 0.5 * (vNE + vSE), 0.5 * (vNW + vSW),
                        vNE, vSE, vNW, vSW,
                    };
                    double sumG = 0.0, sumO = 0.0, sumC = 0.0;
                    int cnt = 0;
                    for (int k = 0; k < 8; k++) {
                        if (g[k] <= thresh) {
                            sumG += gEst[k];
                            sumO += oEst[k];
                            sumC += cD[k];
                            cnt++;
                        }
                    }
                    if (cnt > 0) {
                        double invC = 1.0 / (double)cnt;
                        double corr = 0.5 * (vCenter - sumC * invC);
                        bgr[1] = clamp_f64(sumG * invC + corr, 0.0, maxVal);
                        bgr[opp] = clamp_f64(sumO * invC + corr, 0.0, maxVal);
                    } else {
                        bgr[1] = 0.25 * (vN + vS + vW + vE);
                        bgr[opp] = 0.25 * (vNW + vNE + vSW + vSE);
                    }
                } else {
                    // Bilinear / Gray
                    bgr[1] = 0.25 * (vN + vS + vW + vE);
                    bgr[opp] = 0.25 * (vNW + vNE + vSW + vSE);
                }
            }

            if (dstCh == 1) {
                double gray = 0.114 * bgr[0] + 0.587 * bgr[1] + 0.299 * bgr[2];
                if (depth == 0) dr[x] = sat_u8_d(gray);
                else ((uint16_t *)dr)[x] = sat_u16_d(gray);
            } else {
                if (depth == 0) {
                    dr[x * dstCh + 0] = sat_u8_d(bgr[0]);
                    dr[x * dstCh + 1] = sat_u8_d(bgr[1]);
                    dr[x * dstCh + 2] = sat_u8_d(bgr[2]);
                    if (dstCh == 4) dr[x * dstCh + 3] = 255;
                } else {
                    uint16_t *d16 = (uint16_t *)dr;
                    d16[x * dstCh + 0] = sat_u16_d(bgr[0]);
                    d16[x * dstCh + 1] = sat_u16_d(bgr[1]);
                    d16[x * dstCh + 2] = sat_u16_d(bgr[2]);
                    if (dstCh == 4) d16[x * dstCh + 3] = 65535;
                }
            }
        }
    }

    if (copyBorder) {
        size_t pixBytes = (size_t)dstCh * (depth == 0 ? sizeof(uint8_t) : sizeof(uint16_t));
        uint8_t *r0 = (uint8_t *)dst;
        uint8_t *r1 = r0 + (size_t)dstStrideBytes;
        uint8_t *rh1 = r0 + (size_t)(h - 1) * (size_t)dstStrideBytes;
        uint8_t *rh2 = r0 + (size_t)(h - 2) * (size_t)dstStrideBytes;
        memcpy(r0 + pixBytes, r1 + pixBytes, (size_t)(w - 2) * pixBytes);
        memcpy(rh1 + pixBytes, rh2 + pixBytes, (size_t)(w - 2) * pixBytes);
        for (int32_t y = 0; y < h; y++) {
            uint8_t *ry = r0 + (size_t)y * (size_t)dstStrideBytes;
            memcpy(ry, ry + pixBytes, pixBytes);
            memcpy(ry + (size_t)(w - 1) * pixBytes, ry + (size_t)(w - 2) * pixBytes, pixBytes);
        }
    }

    free(p);
    return 0;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int32_t sr_c_dgels(int32_t m, int32_t n, double *aColMajor, double *bVec) {
    if (!aColMajor || !bVec || m <= 0 || n <= 0) return -1;
    char trans = 'N';
    __CLPK_integer mm = (__CLPK_integer)m;
    __CLPK_integer nn = (__CLPK_integer)n;
    __CLPK_integer nrhs = 1;
    __CLPK_integer lda = mm;
    __CLPK_integer ldb = mm > nn ? mm : nn;
    __CLPK_integer lwork = -1;
    __CLPK_integer info = 0;
    double workQuery = 0.0;
    dgels_(&trans, &mm, &nn, &nrhs, aColMajor, &lda, bVec, &ldb, &workQuery, &lwork, &info);
    if (info != 0) return (int32_t)info;
    __CLPK_integer lw = (__CLPK_integer)(workQuery > 1.0 ? workQuery : 1.0);
    double *work = (double *)malloc((size_t)lw * sizeof(double));
    if (!work) return -1;
    dgels_(&trans, &mm, &nn, &nrhs, aColMajor, &lda, bVec, &ldb, work, &lw, &info);
    free(work);
    return (int32_t)info;
}

#pragma clang diagnostic pop

int32_t sr_c_canny_max_bgr3_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                               uint8_t *edges, int32_t edgeStride,
                               double lowThreshold, double highThreshold, int32_t apertureSize, int32_t l2Gradient);

int32_t sr_c_canny_max_bgr3_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                               uint8_t *edges, int32_t edgeStride,
                               double lowThreshold, double highThreshold, int32_t apertureSize, int32_t l2Gradient) {
    if (!src || !edges || w <= 0 || h <= 0) return -1;
    if (apertureSize != 3 && apertureSize != 5 && apertureSize != 7) return -1;
    if (lowThreshold > highThreshold) {
        double tmp = lowThreshold;
        lowThreshold = highThreshold;
        highThreshold = tmp;
    }

    static const int32_t s3[3] = {1, 2, 1}, d3[3] = {-1, 0, 1};
    static const int32_t s5[5] = {1, 4, 6, 4, 1}, d5[5] = {-1, -2, 0, 2, 1};
    static const int32_t s7[7] = {1, 6, 15, 20, 15, 6, 1}, d7[7] = {-1, -4, -5, 0, 5, 4, 1};
    const int32_t *sk = (apertureSize == 3) ? s3 : ((apertureSize == 5) ? s5 : s7);
    const int32_t *dk = (apertureSize == 3) ? d3 : ((apertureSize == 5) ? d5 : d7);
    int32_t rad = apertureSize / 2;

    size_t npix = (size_t)w * (size_t)h;
    int32_t *rowSmooth = (int32_t *)malloc(npix * sizeof(int32_t));
    int32_t *rowDiff = (int32_t *)malloc(npix * sizeof(int32_t));
    int32_t *gxArr = (int32_t *)malloc(npix * sizeof(int32_t));
    int32_t *gyArr = (int32_t *)malloc(npix * sizeof(int32_t));
    int64_t *mag = (int64_t *)malloc(npix * sizeof(int64_t));
    uint8_t *map = (uint8_t *)calloc(npix, sizeof(uint8_t));
    int32_t *stack = (int32_t *)malloc(npix * sizeof(int32_t));
    if (!rowSmooth || !rowDiff || !gxArr || !gyArr || !mag || !map || !stack) {
        free(rowSmooth); free(rowDiff); free(gxArr); free(gyArr);
        free(mag); free(map); free(stack);
        return -1;
    }

    for (int32_t c = 0; c < 3; c++) {
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *sr = src + (size_t)y * (size_t)srcStride;
            for (int32_t x = 0; x < w; x++) {
                int32_t ss = 0, dd = 0;
                for (int32_t k = -rad; k <= rad; k++) {
                    int32_t xx = clamp_i32(x + k, 0, w - 1);
                    int32_t pv = (int32_t)sr[xx * 3 + c];
                    ss += sk[k + rad] * pv;
                    dd += dk[k + rad] * pv;
                }
                size_t idx = (size_t)y * (size_t)w + (size_t)x;
                rowSmooth[idx] = ss;
                rowDiff[idx] = dd;
            }
        }
        for (int32_t y = 0; y < h; y++) {
            for (int32_t x = 0; x < w; x++) {
                int32_t dx = 0, dy = 0;
                for (int32_t k = -rad; k <= rad; k++) {
                    int32_t yy = clamp_i32(y + k, 0, h - 1);
                    size_t sidx = (size_t)yy * (size_t)w + (size_t)x;
                    dx += sk[k + rad] * rowDiff[sidx];
                    dy += dk[k + rad] * rowSmooth[sidx];
                }
                size_t idx = (size_t)y * (size_t)w + (size_t)x;
                int64_t mc = l2Gradient ? ((int64_t)dx * dx + (int64_t)dy * dy)
                                        : (llabs((long long)dx) + llabs((long long)dy));
                if (c == 0 || mc > mag[idx]) {
                    mag[idx] = mc;
                    gxArr[idx] = dx;
                    gyArr[idx] = dy;
                }
            }
        }
    }

    double lowT = l2Gradient ? (lowThreshold * lowThreshold) : lowThreshold;
    double highT = l2Gradient ? (highThreshold * highThreshold) : highThreshold;
    int32_t sp = 0;

    for (int32_t y = 0; y < h; y++) {
        for (int32_t x = 0; x < w; x++) {
            size_t idx = (size_t)y * (size_t)w + (size_t)x;
            int64_t m = mag[idx];
            if ((double)m <= lowT) continue;

            int32_t gx = gxArr[idx], gy = gyArr[idx];
            double ax = fabs((double)gx), ay = fabs((double)gy);
            int64_t m1 = 0, m2 = 0;
            int keep = 0;
            if (ay < ax * 0.4142135623730950488) {
                if (x > 0) m1 = mag[idx - 1];
                if (x + 1 < w) m2 = mag[idx + 1];
                keep = (m > m1 && m >= m2);
            } else if (ay > ax * 2.4142135623730950488) {
                if (y > 0) m1 = mag[idx - (size_t)w];
                if (y + 1 < h) m2 = mag[idx + (size_t)w];
                keep = (m > m1 && m >= m2);
            } else {
                int sameSign = ((gx >= 0) == (gy >= 0));
                int32_t dxStep = sameSign ? 1 : -1;
                if (y > 0 && x - dxStep >= 0 && x - dxStep < w) {
                    m1 = mag[(size_t)(y - 1) * (size_t)w + (size_t)(x - dxStep)];
                }
                if (y + 1 < h && x + dxStep >= 0 && x + dxStep < w) {
                    m2 = mag[(size_t)(y + 1) * (size_t)w + (size_t)(x + dxStep)];
                }
                keep = (m > m1 && m > m2);
            }
            if (keep) {
                if ((double)m > highT) {
                    map[idx] = 2;
                    stack[sp++] = (int32_t)idx;
                } else {
                    map[idx] = 1;
                }
            }
        }
    }

    while (sp > 0) {
        int32_t cur = stack[--sp];
        int32_t cy = cur / w;
        int32_t cx = cur - cy * w;
        for (int32_t dy = -1; dy <= 1; dy++) {
            int32_t ny = cy + dy;
            if (ny < 0 || ny >= h) continue;
            for (int32_t dx = -1; dx <= 1; dx++) {
                if (dy == 0 && dx == 0) continue;
                int32_t nx = cx + dx;
                if (nx < 0 || nx >= w) continue;
                size_t nIdx = (size_t)ny * (size_t)w + (size_t)nx;
                if (map[nIdx] == 1) {
                    map[nIdx] = 2;
                    stack[sp++] = (int32_t)nIdx;
                }
            }
        }
    }

    for (int32_t y = 0; y < h; y++) {
        uint8_t *er = edges + (size_t)y * (size_t)edgeStride;
        for (int32_t x = 0; x < w; x++) {
            er[x] = (map[(size_t)y * (size_t)w + (size_t)x] == 2) ? 255 : 0;
        }
    }

    free(rowSmooth); free(rowDiff); free(gxArr); free(gyArr);
    free(mag); free(map); free(stack);
    return 0;
}
