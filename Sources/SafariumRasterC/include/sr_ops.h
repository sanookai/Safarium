// SafariumRasterC — Phase 3 C kernels (bilateral, median, canny, CLAHE, equalizeHist, box, integral, colormaps).
#ifndef SR_OPS_H
#define SR_OPS_H

#include <stdint.h>
#include <stddef.h>

extern const uint8_t sr_colormap_luts[22][256][3];

int32_t sr_c_apply_colormap(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride, int32_t srcCh,
                            uint8_t *dst, int32_t dstStride, int32_t colormap, const uint8_t *customLut);

int32_t sr_c_equalize_hist_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                              uint8_t *dst, int32_t dstStride);

int32_t sr_c_clahe_u8(const uint8_t *src, int32_t w, int32_t h, int32_t srcStride,
                      uint8_t *dst, int32_t dstStride, double clipLimit, int32_t tilesX, int32_t tilesY);

int32_t sr_c_clahe_u16(const uint16_t *src, int32_t w, int32_t h, int32_t srcStrideBytes,
                       uint16_t *dst, int32_t dstStrideBytes, double clipLimit, int32_t tilesX, int32_t tilesY);

int32_t sr_c_median_u8(const uint8_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStride,
                       uint8_t *dst, int32_t dstStride, int32_t ksize);
int32_t sr_c_median_u16(const uint16_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes,
                        uint16_t *dst, int32_t dstStrideBytes, int32_t ksize);
int32_t sr_c_median_f32(const float *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes,
                        float *dst, int32_t dstStrideBytes, int32_t ksize);

int32_t sr_c_bilateral_u8(const uint8_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStride,
                          uint8_t *dst, int32_t dstStride, int32_t radius,
                          double sigmaColor, double sigmaSpace, int32_t borderMode);

int32_t sr_c_bilateral_f32(const float *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes,
                           float *dst, int32_t dstStrideBytes, int32_t radius,
                           double sigmaColor, double sigmaSpace, int32_t borderMode);

int32_t sr_c_canny_u8(const uint8_t *src, int32_t w, int32_t h, int32_t ch, int32_t srcStride,
                      uint8_t *dst, int32_t dstStride, double thresh1, double thresh2,
                      int32_t apertureSize, int32_t l2gradient);

int32_t sr_c_integral(const void *src, int32_t w, int32_t h, int32_t ch, int32_t srcStrideBytes, int32_t srcDepth,
                      void *sumDst, int32_t sumStrideBytes, int32_t sumDepth,
                      double *sqDst, int32_t sqStrideBytes,
                      void *tiltedDst, int32_t tiltedStrideBytes, int32_t tiltedDepth);

#endif
