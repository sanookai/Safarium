// SafariumRasterC — Performance NEON kernels (Workstreams 1-4: pixel/NumPy, morph, filter, resize, warp, JPEG decode).
#ifndef SR_OPS_PERF_H
#define SR_OPS_PERF_H

#include <stddef.h>
#include <stdint.h>

// Border modes matching SafariumRaster ABI / OpenCV
enum {
    SR_PERF_BORDER_CONSTANT    = 0,
    SR_PERF_BORDER_REPLICATE   = 1,
    SR_PERF_BORDER_REFLECT     = 2,
    SR_PERF_BORDER_WRAP        = 3,
    SR_PERF_BORDER_REFLECT_101 = 4,
};

// Depth codes matching CoreMat / SRDepth (OpenCV enum)
enum {
    SR_PERF_DEPTH_U8  = 0,
    SR_PERF_DEPTH_S8  = 1,
    SR_PERF_DEPTH_U16 = 2,
    SR_PERF_DEPTH_S16 = 3,
    SR_PERF_DEPTH_S32 = 4,
    SR_PERF_DEPTH_F32 = 5,
    SR_PERF_DEPTH_F64 = 6,
};

// Reduce ops matching cv::ReduceTypes
enum {
    SR_PERF_REDUCE_SUM = 0,
    SR_PERF_REDUCE_AVG = 1,
    SR_PERF_REDUCE_MAX = 2,
    SR_PERF_REDUCE_MIN = 3,
};

// ---- Workstream 1: Pixel / NumPy conversion, HSV, Lab, Reduce, Laplacian ----

void sr_c_bgr2gray_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t scn, int32_t blue_idx);
void sr_c_bgr2gray_u16(const uint16_t *src, ptrdiff_t sstep_bytes, uint16_t *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t blue_idx);
void sr_c_bgr2gray_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t blue_idx);

void sr_c_cvt_swap_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t swap_rb);
void sr_c_cvt_swap_u16(const uint16_t *src, ptrdiff_t sstep_bytes, uint16_t *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t swap_rb);
void sr_c_cvt_swap_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t swap_rb);

void sr_c_gray2bgr_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t dcn);
void sr_c_gray2bgr_u16(const uint16_t *src, ptrdiff_t sstep_bytes, uint16_t *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t dcn);
void sr_c_gray2bgr_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t dcn);

void sr_c_bgr2hsv_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                     int32_t w, int32_t h, int32_t scn, int32_t blue_idx,
                     const uint8_t *s_lut, const uint8_t *s_tail, const int32_t *hdiv180);

int32_t sr_c_bgr2lab_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                        int32_t w, int32_t h, int32_t scn, int32_t dcn, int32_t is_bgr, int32_t linear_in);

int32_t sr_c_reduce_u8(const uint8_t *src, ptrdiff_t sstep, void *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t cn, int32_t dim, int32_t rtype, int32_t ddepth);

int32_t sr_c_laplacian(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                       void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                       int32_t w, int32_t h, int32_t cn,
                       int32_t ksize, double scale, double delta, int32_t border);

// ---- Workstream 2: Streaming rolling-row Morphology ----

int32_t sr_c_morph_u8(const uint8_t *src, ptrdiff_t sstep, uint8_t *dst, ptrdiff_t dstep,
                      int32_t w, int32_t h, int32_t cn,
                      const uint8_t *kernel, int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                      int32_t is_max, int32_t iterations, int32_t border, const double *bval,
                      int32_t identity_border);

int32_t sr_c_morph_f32(const float *src, ptrdiff_t sstep_bytes, float *dst, ptrdiff_t dstep_bytes,
                       int32_t w, int32_t h, int32_t cn,
                       const uint8_t *kernel, int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                       int32_t is_max, int32_t iterations, int32_t border, const double *bval,
                       int32_t identity_border);

// ---- Workstream 3a: Streaming rolling-row Filters (ops_filter.c) ----

int32_t sr_c_sep_filter(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                        void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                        int32_t w, int32_t h, int32_t cn,
                        const double *kx, int32_t kw, const double *ky, int32_t kh,
                        int32_t ax, int32_t ay, double delta, int32_t border,
                        const double *bval_or_null, int32_t use_f32);

int32_t sr_c_box_filter(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                        void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                        int32_t w, int32_t h, int32_t cn,
                        int32_t kw, int32_t kh, int32_t ax, int32_t ay,
                        int32_t normalize, int32_t border);

int32_t sr_c_filter2d(const void *src, ptrdiff_t sstep_bytes, int32_t sdepth,
                      void *dst, ptrdiff_t dstep_bytes, int32_t ddepth,
                      int32_t w, int32_t h, int32_t cn,
                      const double *kernel, int32_t kw, int32_t kh,
                      int32_t ax, int32_t ay, double delta, int32_t border);

int32_t sr_c_pyr_down(const void *src, ptrdiff_t sstep_bytes, int32_t depth,
                      void *dst, ptrdiff_t dstep_bytes,
                      int32_t sw, int32_t sh, int32_t dw, int32_t dh, int32_t cn, int32_t border);

// ---- Workstream 3b: Resize & Warp C/NEON kernels ----

void sr_c_resize_nearest(const uint8_t *src, ptrdiff_t sstep, int32_t sw, int32_t sh,
                         uint8_t *dst, ptrdiff_t dstep, int32_t dw, int32_t dh,
                         int32_t elem_bytes, double scale_x, double scale_y);

void sr_c_area_half_u8(const uint8_t *src, ptrdiff_t sstep, int32_t sw, int32_t sh,
                       uint8_t *dst, ptrdiff_t dstep, int32_t dw, int32_t dh, int32_t cn);

void sr_c_area_half_f32(const float *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                        float *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh, int32_t cn);

int32_t sr_c_resize_linear_fast(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                                void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                                int32_t cn, int32_t depth, double scale_x, double scale_y);

int32_t sr_c_resize_taps(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                         void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                         int32_t cn, int32_t depth,
                         const int32_t *x_off, const int32_t *x_idx, const float *x_w, int32_t x_fixed_k,
                         const int32_t *y_off, const int32_t *y_idx, const float *y_w);

int32_t sr_c_warp_affine(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                         void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                         int32_t cn, int32_t depth, const double *m6,
                         int32_t interp, int32_t border, const double *bval);

int32_t sr_c_warp_perspective(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                              void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                              int32_t cn, int32_t depth, const double *m9,
                              int32_t interp, int32_t border, const double *bval);

int32_t sr_c_remap(const void *src, ptrdiff_t sstep_bytes, int32_t sw, int32_t sh,
                   void *dst, ptrdiff_t dstep_bytes, int32_t dw, int32_t dh,
                   int32_t cn, int32_t depth,
                   const float *m1, ptrdiff_t m1_step_bytes, int32_t m1_cn,
                   const float *m2, ptrdiff_t m2_step_bytes,
                   int32_t interp, int32_t border, const double *bval);

// ---- Workstream 4: Baseline JPEG decoder (jpeg_dec.c) ----
// Return codes: 0 = decoded, 1 = unsupported/non-baseline (fall back to ImageIO), -1 = malformed/bad args.
int32_t sr_jpeg_decode_baseline(const uint8_t *data, size_t len,
                                int32_t *out_w, int32_t *out_h, int32_t *out_cn,
                                uint8_t *dst, ptrdiff_t dst_stride, int32_t want_cn);

// ---- Wave 10 Track B1: Connected Components, CoreArith/CoreStruct NEON, Contours ----

int32_t sr_c_connected_components(const uint8_t *src, ptrdiff_t sstep,
                                  int32_t *lab, ptrdiff_t lstep_bytes,
                                  int32_t w, int32_t h, int32_t connectivity,
                                  int32_t *out_n, void **out_handle);

int32_t sr_c_cc_take(void *handle, int32_t *stats, double *centroids);

void sr_c_add_weighted_f32(const float *a, const float *b, float *d, size_t n,
                           float alpha, float beta, float gamma);

void sr_c_add_weighted_u8(const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n,
                          float alpha, float beta, float gamma);

// op: 0 = add, 1 = sub, 2 = absdiff
void sr_c_add_u8(int32_t op, const uint8_t *a, const uint8_t *b, uint8_t *d, size_t n);

// op: 0 = add, 1 = sub, 2 = absdiff; cn in 1..4; sc[0..cn-1] in 0..255
void sr_c_add_scalar_u8(int32_t op, int32_t swap, const uint8_t *a, uint8_t *d,
                        size_t n, int32_t cn, const uint8_t *sc);

void sr_c_merge3_u8(const uint8_t *p0, ptrdiff_t s0,
                    const uint8_t *p1, ptrdiff_t s1,
                    const uint8_t *p2, ptrdiff_t s2,
                    uint8_t *dst, ptrdiff_t dstep,
                    int32_t w, int32_t h);

double sr_c_arc_length_f32(const float *pts, int32_t n, int32_t closed);
double sr_c_arc_length_s32(const int32_t *pts, int32_t n, int32_t closed);

double sr_c_point_polygon_test_f32(const float *pts, int32_t n, double px, double py, int32_t measure_dist);
double sr_c_point_polygon_test_s32(const int32_t *pts, int32_t n, double px, double py, int32_t measure_dist);

#endif
