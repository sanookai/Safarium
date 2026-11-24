// SafariumRasterC — Accelerate BLAS/LAPACK + k-means C kernels (Phase 2).
#ifndef SR_LINALG_H
#define SR_LINALG_H

#include <stdint.h>

int32_t sr_c_gemm_f32(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      float alpha, const float *a, int32_t lda,
                      const float *b, int32_t ldb, float beta, float *c, int32_t ldc);
int32_t sr_c_gemm_f64(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      double alpha, const double *a, int32_t lda,
                      const double *b, int32_t ldb, double beta, double *c, int32_t ldc);
int32_t sr_c_gemm_c32(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      float alpha, const float *a, int32_t lda,
                      const float *b, int32_t ldb, float beta, float *c, int32_t ldc);
int32_t sr_c_gemm_c64(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      double alpha, const double *a, int32_t lda,
                      const double *b, int32_t ldb, double beta, double *c, int32_t ldc);

int32_t sr_c_lu_f32(int32_t m, int32_t n, float *aCol, int32_t *ipiv);
int32_t sr_c_lu_f64(int32_t m, int32_t n, double *aCol, int32_t *ipiv);

int32_t sr_c_solve_lu_f32(int32_t n, int32_t nrhs, float *aCol, float *bCol);
int32_t sr_c_solve_lu_f64(int32_t n, int32_t nrhs, double *aCol, double *bCol);
int32_t sr_c_solve_chol_f32(int32_t n, int32_t nrhs, float *aCol, float *bCol);
int32_t sr_c_solve_chol_f64(int32_t n, int32_t nrhs, double *aCol, double *bCol);
int32_t sr_c_solve_qr_f32(int32_t m, int32_t n, int32_t nrhs, float *aCol, float *bCol);
int32_t sr_c_solve_qr_f64(int32_t m, int32_t n, int32_t nrhs, double *aCol, double *bCol);

int32_t sr_c_invert_lu_f32(int32_t n, float *aCol);
int32_t sr_c_invert_lu_f64(int32_t n, double *aCol);
int32_t sr_c_invert_chol_f32(int32_t n, float *aCol);
int32_t sr_c_invert_chol_f64(int32_t n, double *aCol);

int32_t sr_c_svd_f32(int32_t m, int32_t n, char jobz, float *aCol, float *s, float *uCol, int32_t ldu, float *vtCol, int32_t ldvt);
int32_t sr_c_svd_f64(int32_t m, int32_t n, char jobz, double *aCol, double *s, double *uCol, int32_t ldu, double *vtCol, int32_t ldvt);

int32_t sr_c_syevd_f32(int32_t n, int32_t wantVecs, float *aCol, float *w);
int32_t sr_c_syevd_f64(int32_t n, int32_t wantVecs, double *aCol, double *w);

int32_t sr_c_geev_f32(int32_t n, int32_t wantVecs, float *aCol, float *wr, float *wi, float *vrCol);
int32_t sr_c_geev_f64(int32_t n, int32_t wantVecs, double *aCol, double *wr, double *wi, double *vrCol);

double sr_c_kmeans_f32(const float *pts, int32_t n, int32_t dims, int32_t k,
                       int32_t maxIter, double eps, int32_t attempts, int32_t flags,
                       int32_t *labels, float *centers);

#endif
