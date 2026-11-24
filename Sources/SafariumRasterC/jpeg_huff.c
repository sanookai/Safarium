// SafariumRasterC — baseline JPEG Huffman coding of one MCU row (Area C).
#include "jpeg_kernels.h"

void sr_jpeg_finish(SRJState *s) { sr_huff_finish_inl(s); }

void sr_jpeg_huff_row(SRJState *sp, const int32_t *yCoef, const uint64_t *yMask,
                      const int32_t *ccCoef, const uint64_t *ccMask,
                      intptr_t nbx, intptr_t mcuCols, int hs, int vs, int colour, intptr_t rst,
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
        for (int by = 0; by < vs; by++) {
            for (int bx = 0; bx < hs; bx++) {
                intptr_t idx = by * nbx + mx * hs + bx;
                sr_huff_block_inl(s, yCoef + idx * 64, yMask[idx], &s->pred[0], dcL, acL, zz);
            }
        }
        if (colour) {
            sr_huff_block_inl(s, ccCoef + mx * 128, ccMask[mx * 2], &s->pred[1], dcC, acC, zz);
            sr_huff_block_inl(s, ccCoef + mx * 128 + 64, ccMask[mx * 2 + 1], &s->pred[2], dcC, acC, zz);
        }
    }
    *sp = L;
}

void sr_jpeg_huff_row_s16(SRJState *sp, const int16_t *yCoef, const uint64_t *yMask,
                          const int16_t *ccCoef, const uint64_t *ccMask,
                          intptr_t nbx, intptr_t mcuCols, int hs, int vs, int colour, intptr_t rst,
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
        for (int by = 0; by < vs; by++) {
            for (int bx = 0; bx < hs; bx++) {
                intptr_t idx = by * nbx + mx * hs + bx;
                sr_huff_block_s16_inl(s, yCoef + idx * 64, yMask[idx], &s->pred[0], dcL, acL, zz);
            }
        }
        if (colour) {
            sr_huff_block_s16_inl(s, ccCoef + mx * 128, ccMask[mx * 2], &s->pred[1], dcC, acC, zz);
            sr_huff_block_s16_inl(s, ccCoef + mx * 128 + 64, ccMask[mx * 2 + 1], &s->pred[2], dcC, acC, zz);
        }
    }
    *sp = L;
}
