// SafariumRasterC — baseline JPEG encoder entry points (Area C).
#ifndef SR_JPEG_H
#define SR_JPEG_H
#include <stdint.h>
#include <stddef.h>

uint64_t sr_jpeg_block_s16(const uint8_t *src, intptr_t stride, int par, const int32_t *recip32,
                           int16_t *out, const uint64_t *zzmask);

/// Encode a full baseline sequential JPEG (header + scan + EOI) into a newly malloc'd buffer.
/// Supports grayscale (ch=1, hs=1, vs=1), 4:2:0 color (ch=3/4, hs=2, vs=2), and 4:4:4 color (ch=3/4, hs=1, vs=1).
/// recip32L / recip32C hold round(0.5 / (q * aan_k * aan_u * 8) * 2^31).
/// Returns >= 0 byte length on success, -1 on error/OOM, -2 if sampling factor requires Swift fallback.
int64_t sr_jpeg_encode_baseline(
    const uint8_t *header, int32_t headerLen,
    const uint8_t *src, intptr_t stride, int32_t ch, int32_t w, int32_t h,
    int32_t hs, int32_t vs, intptr_t rst,
    const int32_t *recip32L, const int32_t *recip32C,
    const uint32_t *dcL, const uint32_t *acL,
    const uint32_t *dcC, const uint32_t *acC,
    const uint64_t *zzMask, const intptr_t *zzSrc,
    uint8_t **outBuf);

void sr_jpeg_free(uint8_t *p);

#endif
