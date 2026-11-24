// SafariumRasterC — BGR/BGRA -> YCbCr 4:2:0 for JPEG, NEON (Area C).
#include "jpeg_kernels.h"

void sr_jpeg_ycc420(const uint8_t *src, intptr_t stride, int ch, int w, int rows, int pw,
                    uint8_t *yStrip, uint8_t *cc) {
    sr_jpeg_ycc420_inl(src, stride, ch, w, rows, pw, yStrip, cc);
}
