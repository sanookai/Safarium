// SafariumRasterC — JPEG forward DCT + quantisation, NEON (Area C).
#include "jpeg_kernels.h"

uint64_t sr_jpeg_block(const uint8_t *src, intptr_t stride, int par, const float *recip,
                       int32_t *out, const uint64_t *zzmask) {
    return sr_jpeg_block_inl(src, stride, par, recip, out, zzmask);
}

uint64_t sr_jpeg_block_s16(const uint8_t *src, intptr_t stride, int par, const int32_t *recip32,
                           int16_t *out, const uint64_t *zzmask) {
    return sr_jpeg_block_s16_inl(src, stride, par, recip32, out, zzmask);
}
