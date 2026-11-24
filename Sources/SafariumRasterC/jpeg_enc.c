// SafariumRasterC — Whole-image baseline JPEG encoder (full-strip sequential YCbCr + s16 NEON FDCT + Huffman).
// Keeps SRJState in registers per strip row and eliminates per-block Swift FFI calls and register spill.

#include "include/sr_jpeg.h"
#include "jpeg_kernels.h"
#include <stdlib.h>

static int ensure_cap(SRJState *s, size_t *cap, size_t extra) {
    if (extra > (size_t)0x7FFFFFFFFFFFFFFFULL - (size_t)s->pos) return -1;
    size_t need = (size_t)s->pos + extra;
    if (need <= *cap) return 0;
    size_t ncap = *cap <= (size_t)0x3FFFFFFFFFFFFFFFULL ? (*cap * 2) : need;
    if (ncap < need) ncap = need;
    uint8_t *nb = (uint8_t *)realloc(s->out, ncap);
    if (!nb) return -1;
    s->out = nb;
    *cap = ncap;
    return 0;
}

static __attribute__((noinline)) void dct_row_420(
    const uint8_t * __restrict yStrip, const uint8_t * __restrict ccStrip,
    int pw, int cw, int mcuCols, int yb,
    const int32_t * __restrict recip32L, const int32_t * __restrict recip32C,
    int16_t * __restrict yCoef, uint64_t * __restrict yMask,
    int16_t * __restrict ccCoef, uint64_t * __restrict ccMask,
    const uint64_t * __restrict zzMask)
{
    for (int by = 0; by < 2; by++) {
        const uint8_t *yRow = yStrip + (size_t)by * 8 * pw;
        int16_t *cOut = yCoef + (size_t)by * yb * 64;
        uint64_t *mOut = yMask + by * yb;
        for (int bx = 0; bx < mcuCols * 2; bx++) {
            mOut[bx] = sr_jpeg_block_s16_inl(yRow + (size_t)bx * 8, pw, -1, recip32L, cOut + (size_t)bx * 64, zzMask);
        }
    }
    for (int mx = 0; mx < mcuCols; mx++) {
        ccMask[mx * 2] = sr_jpeg_block_s16_inl(ccStrip + (size_t)mx * 16, 2 * cw, 0, recip32C, ccCoef + (size_t)mx * 128, zzMask);
        ccMask[mx * 2 + 1] = sr_jpeg_block_s16_inl(ccStrip + (size_t)mx * 16, 2 * cw, 1, recip32C, ccCoef + (size_t)mx * 128 + 64, zzMask);
    }
}

static __attribute__((noinline)) void dct_row_444(
    const uint8_t * __restrict yBuf, const uint8_t * __restrict cbBuf, const uint8_t * __restrict crBuf,
    int pw, int mcuCols,
    const int32_t * __restrict recip32L, const int32_t * __restrict recip32C,
    int16_t * __restrict yCoef, uint64_t * __restrict yMask,
    int16_t * __restrict cbCoef, uint64_t * __restrict cbMask,
    int16_t * __restrict crCoef, uint64_t * __restrict crMask,
    const uint64_t * __restrict zzMask)
{
    for (int mx = 0; mx < mcuCols; mx++) {
        yMask[mx] = sr_jpeg_block_s16_inl(yBuf + (size_t)mx * 8, pw, -1, recip32L, yCoef + (size_t)mx * 64, zzMask);
        cbMask[mx] = sr_jpeg_block_s16_inl(cbBuf + (size_t)mx * 8, pw, -1, recip32C, cbCoef + (size_t)mx * 64, zzMask);
        crMask[mx] = sr_jpeg_block_s16_inl(crBuf + (size_t)mx * 8, pw, -1, recip32C, crCoef + (size_t)mx * 64, zzMask);
    }
}

static __attribute__((noinline)) void dct_row_gray(
    const uint8_t * __restrict yBuf, int pw, int mcuCols,
    const int32_t * __restrict recip32L,
    int16_t * __restrict yCoef, uint64_t * __restrict yMask,
    const uint64_t * __restrict zzMask)
{
    for (int mx = 0; mx < mcuCols; mx++) {
        yMask[mx] = sr_jpeg_block_s16_inl(yBuf + (size_t)mx * 8, pw, -1, recip32L, yCoef + (size_t)mx * 64, zzMask);
    }
}

static __attribute__((noinline)) void huff_row_420(SRJState *sp, const int16_t *yCoef, const uint64_t *yMask,
                                                   const int16_t *ccCoef, const uint64_t *ccMask,
                                                   intptr_t nbx, intptr_t mcuCols, intptr_t rst,
                                                   const uint32_t *dcL, const uint32_t *acL,
                                                   const uint32_t *dcC, const uint32_t *acC, const intptr_t *zz) {
    SRJState L = *sp;
    SRJState *s = &L;
    if (rst <= 0) {
        for (intptr_t mx = 0; mx < mcuCols; mx++) {
            sr_huff_block_s16_inl(s, yCoef + mx * 128, yMask[mx * 2], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, yCoef + mx * 128 + 64, yMask[mx * 2 + 1], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, yCoef + (nbx + mx * 2) * 64, yMask[nbx + mx * 2], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, yCoef + (nbx + mx * 2 + 1) * 64, yMask[nbx + mx * 2 + 1], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, ccCoef + mx * 128, ccMask[mx * 2], &s->pred[1], dcC, acC, zz);
            sr_huff_block_s16_inl(s, ccCoef + mx * 128 + 64, ccMask[mx * 2 + 1], &s->pred[2], dcC, acC, zz);
        }
    } else {
        for (intptr_t mx = 0; mx < mcuCols; mx++) {
            if (s->count > 0 && s->count % rst == 0) {
                sr_huff_finish_inl(s);
                s->out[s->pos++] = 0xFF;
                s->out[s->pos++] = (uint8_t)(0xD0 + s->rstNum);
                s->rstNum = (s->rstNum + 1) & 7;
                s->pred[0] = s->pred[1] = s->pred[2] = 0;
            }
            s->count++;
            sr_huff_block_s16_inl(s, yCoef + mx * 128, yMask[mx * 2], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, yCoef + mx * 128 + 64, yMask[mx * 2 + 1], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, yCoef + (nbx + mx * 2) * 64, yMask[nbx + mx * 2], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, yCoef + (nbx + mx * 2 + 1) * 64, yMask[nbx + mx * 2 + 1], &s->pred[0], dcL, acL, zz);
            sr_huff_block_s16_inl(s, ccCoef + mx * 128, ccMask[mx * 2], &s->pred[1], dcC, acC, zz);
            sr_huff_block_s16_inl(s, ccCoef + mx * 128 + 64, ccMask[mx * 2 + 1], &s->pred[2], dcC, acC, zz);
        }
    }
    *sp = L;
}

static __attribute__((noinline)) void huff_row_444(SRJState *sp, const int16_t *yCoef, const uint64_t *yMask,
                                                   const int16_t *cbCoef, const uint64_t *cbMask,
                                                   const int16_t *crCoef, const uint64_t *crMask,
                                                   intptr_t mcuCols, intptr_t rst,
                                                   const uint32_t *dcL, const uint32_t *acL,
                                                   const uint32_t *dcC, const uint32_t *acC, const intptr_t *zz) {
    SRJState L = *sp;
    SRJState *s = &L;
    for (intptr_t mx = 0; mx < mcuCols; mx++) {
        if (rst > 0) {
            if (s->count > 0 && s->count % rst == 0) {
                sr_huff_finish_inl(s);
                s->out[s->pos++] = 0xFF;
                s->out[s->pos++] = (uint8_t)(0xD0 + s->rstNum);
                s->rstNum = (s->rstNum + 1) & 7;
                s->pred[0] = s->pred[1] = s->pred[2] = 0;
            }
            s->count++;
        }
        sr_huff_block_s16_inl(s, yCoef + mx * 64, yMask[mx], &s->pred[0], dcL, acL, zz);
        sr_huff_block_s16_inl(s, cbCoef + mx * 64, cbMask[mx], &s->pred[1], dcC, acC, zz);
        sr_huff_block_s16_inl(s, crCoef + mx * 64, crMask[mx], &s->pred[2], dcC, acC, zz);
    }
    *sp = L;
}

static __attribute__((noinline)) void huff_row_gray(SRJState *sp, const int16_t *yCoef, const uint64_t *yMask,
                                                    intptr_t mcuCols, intptr_t rst,
                                                    const uint32_t *dcL, const uint32_t *acL, const intptr_t *zz) {
    SRJState L = *sp;
    SRJState *s = &L;
    for (intptr_t mx = 0; mx < mcuCols; mx++) {
        if (rst > 0) {
            if (s->count > 0 && s->count % rst == 0) {
                sr_huff_finish_inl(s);
                s->out[s->pos++] = 0xFF;
                s->out[s->pos++] = (uint8_t)(0xD0 + s->rstNum);
                s->rstNum = (s->rstNum + 1) & 7;
                s->pred[0] = s->pred[1] = s->pred[2] = 0;
            }
            s->count++;
        }
        sr_huff_block_s16_inl(s, yCoef + mx * 64, yMask[mx], &s->pred[0], dcL, acL, zz);
    }
    *sp = L;
}

static void ycc444_row_strip(const uint8_t *src, intptr_t stride, int ch, int w, int rows, int pw,
                             uint8_t *yBuf, uint8_t *cbBuf, uint8_t *crBuf) {
    for (int r = 0; r < 8; r++) {
        int sr = r < rows ? r : rows - 1;
        const uint8_t *p = src + (intptr_t)sr * stride;
        for (int x = 0; x < pw; x += 16) {
            uint8x16_t B, G, R;
            sr_load16_bgr(p, ch, w, x, &B, &G, &R);
            uint8x8_t yl, yh, cbl, cbh, crl, crh;
            sr_ycc16(vget_low_u8(B), vget_low_u8(G), vget_low_u8(R), &yl, &cbl, &crl);
            sr_ycc16(vget_high_u8(B), vget_high_u8(G), vget_high_u8(R), &yh, &cbh, &crh);
            vst1q_u8(yBuf + (size_t)r * pw + x, vcombine_u8(yl, yh));
            vst1q_u8(cbBuf + (size_t)r * pw + x, vcombine_u8(cbl, cbh));
            vst1q_u8(crBuf + (size_t)r * pw + x, vcombine_u8(crl, crh));
        }
    }
}

int64_t sr_jpeg_encode_baseline(
    const uint8_t *header, int32_t headerLen,
    const uint8_t *src, intptr_t stride, int32_t ch, int32_t w, int32_t h,
    int32_t hs, int32_t vs, intptr_t rst,
    const int32_t *recip32L, const int32_t *recip32C,
    const uint32_t *dcL, const uint32_t *acL,
    const uint32_t *dcC, const uint32_t *acC,
    const uint64_t *zzMask, const intptr_t *zzSrc,
    uint8_t **outBuf)
{
    if (!outBuf) return -1;
    *outBuf = NULL;
    if (!header || headerLen < 2 || !src || w <= 0 || h <= 0 || w >= 65500 || h >= 65500) return -1;
    if (ch != 1 && ch != 3 && ch != 4) return -1;
    if (stride < (intptr_t)w * ch) return -1;
    if (!recip32L || !dcL || !acL || !zzMask || !zzSrc) return -1;
    if (ch >= 3 && (!recip32C || !dcC || !acC)) return -1;
    if (rst < 0) return -1;

    int colour = ch >= 3;
    if (!colour) {
        if (hs != 1 || vs != 1) return -2;
    } else if (!((hs == 2 && vs == 2) || (hs == 1 && vs == 1))) {
        return -2;
    }

    int blocksPerMCU = colour ? (hs * vs + 2) : 1;
    size_t perMCU = (size_t)blocksPerMCU * 440u + 8u;
    size_t mcuCols = (size_t)((w + 8 * hs - 1) / (8 * hs));
    size_t rowWorst = mcuCols * perMCU + 128u;
    size_t est = (size_t)headerLen + (size_t)w * (size_t)h / 2u + 8192u;
    size_t cap = est > (size_t)headerLen + rowWorst ? est : (size_t)headerLen + rowWorst;

    SRJState st = {0};
    st.out = (uint8_t *)malloc(cap);
    if (!st.out) return -1;
    memcpy(st.out, header, (size_t)headerLen);
    st.pos = headerLen;

    uint8_t stackBuf[24576] __attribute__((aligned(16)));
    uint8_t *heapScratch = NULL;

    if (colour && hs == 2 && vs == 2) {
        int pw = (w + 15) & ~15;
        int cw = pw / 2;
        int mcuRows = (h + 15) / 16;
        int yb = ((int)mcuCols * 2 + 1) & ~1;
        size_t yStripSz = (size_t)pw * 16u + 64u;
        size_t ccStripSz = (size_t)cw * 16u + 64u;
        size_t yCoefSz = sizeof(int16_t) * ((size_t)yb * 2u * 64u + 16u);
        size_t ccCoefSz = sizeof(int16_t) * (mcuCols * 2u * 64u + 16u);
        size_t yMaskSz = sizeof(uint64_t) * ((size_t)yb * 2u + 4u);
        size_t ccMaskSz = sizeof(uint64_t) * (mcuCols * 2u + 4u);
        size_t total = yStripSz + ccStripSz + yCoefSz + ccCoefSz + yMaskSz + ccMaskSz;
        uint8_t *scratch = total <= sizeof(stackBuf) ? stackBuf : (heapScratch = (uint8_t *)malloc(total));
        if (!scratch) { free(st.out); return -1; }
        uint8_t *yStrip = scratch;
        uint8_t *ccStrip = yStrip + yStripSz;
        int16_t *yCoef = (int16_t *)(ccStrip + ccStripSz);
        int16_t *ccCoef = (int16_t *)((uint8_t *)yCoef + yCoefSz);
        uint64_t *yMask = (uint64_t *)((uint8_t *)ccCoef + ccCoefSz);
        uint64_t *ccMask = (uint64_t *)((uint8_t *)yMask + yMaskSz);

        for (int my = 0; my < mcuRows; my++) {
            int y0 = my * 16;
            int rows = h - y0 < 16 ? h - y0 : 16;
            sr_jpeg_ycc420_inl(src + (intptr_t)y0 * stride, stride, ch, w, rows, pw, yStrip, ccStrip);
            dct_row_420(yStrip, ccStrip, pw, cw, (int)mcuCols, yb, recip32L, recip32C, yCoef, yMask, ccCoef, ccMask, zzMask);
            if (ensure_cap(&st, &cap, rowWorst) != 0) {
                free(heapScratch); free(st.out); return -1;
            }
            huff_row_420(&st, yCoef, yMask, ccCoef, ccMask, yb, (intptr_t)mcuCols, rst, dcL, acL, dcC, acC, zzSrc);
        }
    } else if (colour) { // 4:4:4 (hs == 1, vs == 1)
        int pw = (w + 15) & ~15;
        int mcuRows = (h + 7) / 8;
        size_t planeSz = (size_t)pw * 8u + 64u;
        size_t coefSz = sizeof(int16_t) * (mcuCols * 64u + 16u);
        size_t maskSz = sizeof(uint64_t) * (mcuCols + 4u);
        size_t total = planeSz * 3u + coefSz * 3u + maskSz * 3u;
        uint8_t *scratch = total <= sizeof(stackBuf) ? stackBuf : (heapScratch = (uint8_t *)malloc(total));
        if (!scratch) { free(st.out); return -1; }
        uint8_t *yBuf = scratch;
        uint8_t *cbBuf = yBuf + planeSz;
        uint8_t *crBuf = cbBuf + planeSz;
        int16_t *yCoef = (int16_t *)(crBuf + planeSz);
        int16_t *cbCoef = (int16_t *)((uint8_t *)yCoef + coefSz);
        int16_t *crCoef = (int16_t *)((uint8_t *)cbCoef + coefSz);
        uint64_t *yMask = (uint64_t *)((uint8_t *)crCoef + coefSz);
        uint64_t *cbMask = (uint64_t *)((uint8_t *)yMask + maskSz);
        uint64_t *crMask = (uint64_t *)((uint8_t *)cbMask + maskSz);

        for (int my = 0; my < mcuRows; my++) {
            int y0 = my * 8;
            int rows = h - y0 < 8 ? h - y0 : 8;
            ycc444_row_strip(src + (intptr_t)y0 * stride, stride, ch, w, rows, pw, yBuf, cbBuf, crBuf);
            dct_row_444(yBuf, cbBuf, crBuf, pw, (int)mcuCols, recip32L, recip32C, yCoef, yMask, cbCoef, cbMask, crCoef, crMask, zzMask);
            if (ensure_cap(&st, &cap, rowWorst) != 0) {
                free(heapScratch); free(st.out); return -1;
            }
            huff_row_444(&st, yCoef, yMask, cbCoef, cbMask, crCoef, crMask, (intptr_t)mcuCols, rst, dcL, acL, dcC, acC, zzSrc);
        }
    } else { // Grayscale (ch == 1, hs == 1, vs == 1)
        int pw = (w + 7) & ~7;
        int mcuRows = (h + 7) / 8;
        size_t ySz = (size_t)pw * 8u + 64u;
        size_t coefSz = sizeof(int16_t) * (mcuCols * 64u + 16u);
        size_t maskSz = sizeof(uint64_t) * (mcuCols + 4u);
        size_t total = ySz + coefSz + maskSz;
        uint8_t *scratch = total <= sizeof(stackBuf) ? stackBuf : (heapScratch = (uint8_t *)malloc(total));
        if (!scratch) { free(st.out); return -1; }
        uint8_t *yBuf = scratch;
        int16_t *yCoef = (int16_t *)(yBuf + ySz);
        uint64_t *yMask = (uint64_t *)((uint8_t *)yCoef + coefSz);

        for (int my = 0; my < mcuRows; my++) {
            int y0 = my * 8;
            int rows = h - y0 < 8 ? h - y0 : 8;
            for (int r = 0; r < 8; r++) {
                int sr = r < rows ? r : rows - 1;
                const uint8_t *p = src + (intptr_t)(y0 + sr) * stride;
                uint8_t *d = yBuf + (size_t)r * pw;
                memcpy(d, p, (size_t)w);
                if (pw > w) memset(d + w, p[w - 1], (size_t)(pw - w));
            }
            dct_row_gray(yBuf, pw, (int)mcuCols, recip32L, yCoef, yMask, zzMask);
            if (ensure_cap(&st, &cap, rowWorst) != 0) {
                free(heapScratch); free(st.out); return -1;
            }
            huff_row_gray(&st, yCoef, yMask, (intptr_t)mcuCols, rst, dcL, acL, zzSrc);
        }
    }

    free(heapScratch);
    if (ensure_cap(&st, &cap, 32u) != 0) {
        free(st.out);
        return -1;
    }
    sr_huff_finish_inl(&st);
    st.out[st.pos++] = 0xFF;
    st.out[st.pos++] = 0xD9;
    *outBuf = st.out;
    return (int64_t)st.pos;
}

void sr_jpeg_free(uint8_t *p) { free(p); }
