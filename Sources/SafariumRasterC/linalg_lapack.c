// SafariumRasterC — Apple Accelerate BLAS / LAPACK + k-means C kernels.
#include <Accelerate/Accelerate.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "include/sr_linalg.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#define SR_INT __CLPK_integer

static inline enum CBLAS_TRANSPOSE tr(int32_t t) { return t ? CblasTrans : CblasNoTrans; }

int32_t sr_c_gemm_f32(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      float alpha, const float *a, int32_t lda,
                      const float *b, int32_t ldb, float beta, float *c, int32_t ldc) {
    cblas_sgemm(CblasRowMajor, tr(tA), tr(tB), m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
    return 0;
}

int32_t sr_c_gemm_f64(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      double alpha, const double *a, int32_t lda,
                      const double *b, int32_t ldb, double beta, double *c, int32_t ldc) {
    cblas_dgemm(CblasRowMajor, tr(tA), tr(tB), m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
    return 0;
}

int32_t sr_c_gemm_c32(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      float alpha, const float *a, int32_t lda,
                      const float *b, int32_t ldb, float beta, float *c, int32_t ldc) {
    float al[2] = {alpha, 0.0f}, be[2] = {beta, 0.0f};
    cblas_cgemm(CblasRowMajor, tr(tA), tr(tB), m, n, k, al, a, lda, b, ldb, be, c, ldc);
    return 0;
}

int32_t sr_c_gemm_c64(int32_t tA, int32_t tB, int32_t m, int32_t n, int32_t k,
                      double alpha, const double *a, int32_t lda,
                      const double *b, int32_t ldb, double beta, double *c, int32_t ldc) {
    double al[2] = {alpha, 0.0}, be[2] = {beta, 0.0};
    cblas_zgemm(CblasRowMajor, tr(tA), tr(tB), m, n, k, al, a, lda, b, ldb, be, c, ldc);
    return 0;
}

int32_t sr_c_lu_f32(int32_t m, int32_t n, float *aCol, int32_t *ipiv) {
    SR_INT mm = m, nn = n, lda = m > 0 ? m : 1, info = 0;
    sgetrf_(&mm, &nn, aCol, &lda, (SR_INT *)ipiv, &info);
    return (int32_t)info;
}

int32_t sr_c_lu_f64(int32_t m, int32_t n, double *aCol, int32_t *ipiv) {
    SR_INT mm = m, nn = n, lda = m > 0 ? m : 1, info = 0;
    dgetrf_(&mm, &nn, aCol, &lda, (SR_INT *)ipiv, &info);
    return (int32_t)info;
}

static int singular_u_f32(int32_t n, const float *aCol) {
    float maxA = 0.0f;
    for (int32_t i = 0; i < n * n; i++) {
        float v = fabsf(aCol[i]);
        if (!isfinite(v)) return 1;
        if (v > maxA) maxA = v;
    }
    float eps = maxA * (float)n * FLT_EPSILON * 8.0f;
    for (int32_t i = 0; i < n; i++) {
        float d = fabsf(aCol[(size_t)i * n + i]);
        if (!isfinite(d) || d <= eps) return 1;
    }
    return 0;
}

static int singular_u_f64(int32_t n, const double *aCol) {
    double maxA = 0.0;
    for (int32_t i = 0; i < n * n; i++) {
        double v = fabs(aCol[i]);
        if (!isfinite(v)) return 1;
        if (v > maxA) maxA = v;
    }
    double eps = maxA * (double)n * DBL_EPSILON * 8.0;
    for (int32_t i = 0; i < n; i++) {
        double d = fabs(aCol[(size_t)i * n + i]);
        if (!isfinite(d) || d <= eps) return 1;
    }
    return 0;
}

int32_t sr_c_solve_lu_f32(int32_t n, int32_t nrhs, float *aCol, float *bCol) {
    SR_INT nn = n, nh = nrhs, lda = n, ldb = n, info = 0;
    SR_INT *ipiv = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)n);
    if (!ipiv) return -1;
    sgetrf_(&nn, &nn, aCol, &lda, ipiv, &info);
    if (info != 0 || singular_u_f32(n, aCol)) { free(ipiv); return 1; }
    sgetrs_("N", &nn, &nh, aCol, &lda, ipiv, bCol, &ldb, &info);
    free(ipiv);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_solve_lu_f64(int32_t n, int32_t nrhs, double *aCol, double *bCol) {
    SR_INT nn = n, nh = nrhs, lda = n, ldb = n, info = 0;
    SR_INT *ipiv = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)n);
    if (!ipiv) return -1;
    dgetrf_(&nn, &nn, aCol, &lda, ipiv, &info);
    if (info != 0 || singular_u_f64(n, aCol)) { free(ipiv); return 1; }
    dgetrs_("N", &nn, &nh, aCol, &lda, ipiv, bCol, &ldb, &info);
    free(ipiv);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_solve_chol_f32(int32_t n, int32_t nrhs, float *aCol, float *bCol) {
    SR_INT nn = n, nh = nrhs, lda = n, ldb = n, info = 0;
    spotrf_("L", &nn, aCol, &lda, &info);
    if (info != 0) return 1;
    spotrs_("L", &nn, &nh, aCol, &lda, bCol, &ldb, &info);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_solve_chol_f64(int32_t n, int32_t nrhs, double *aCol, double *bCol) {
    SR_INT nn = n, nh = nrhs, lda = n, ldb = n, info = 0;
    dpotrf_("L", &nn, aCol, &lda, &info);
    if (info != 0) return 1;
    dpotrs_("L", &nn, &nh, aCol, &lda, bCol, &ldb, &info);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_solve_qr_f32(int32_t m, int32_t n, int32_t nrhs, float *aCol, float *bCol) {
    SR_INT mm = m, nn = n, nh = nrhs, lda = m, ldb = m > n ? m : n, lwork = -1, info = 0;
    float wq = 0.0f;
    sgels_("N", &mm, &nn, &nh, aCol, &lda, bCol, &ldb, &wq, &lwork, &info);
    if (info != 0) return 1;
    lwork = (SR_INT)wq;
    if (lwork < 1) lwork = 1;
    float *work = (float *)malloc(sizeof(float) * (size_t)lwork);
    if (!work) return -1;
    sgels_("N", &mm, &nn, &nh, aCol, &lda, bCol, &ldb, work, &lwork, &info);
    free(work);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_solve_qr_f64(int32_t m, int32_t n, int32_t nrhs, double *aCol, double *bCol) {
    SR_INT mm = m, nn = n, nh = nrhs, lda = m, ldb = m > n ? m : n, lwork = -1, info = 0;
    double wq = 0.0;
    dgels_("N", &mm, &nn, &nh, aCol, &lda, bCol, &ldb, &wq, &lwork, &info);
    if (info != 0) return 1;
    lwork = (SR_INT)wq;
    if (lwork < 1) lwork = 1;
    double *work = (double *)malloc(sizeof(double) * (size_t)lwork);
    if (!work) return -1;
    dgels_("N", &mm, &nn, &nh, aCol, &lda, bCol, &ldb, work, &lwork, &info);
    free(work);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_invert_lu_f32(int32_t n, float *aCol) {
    SR_INT nn = n, lda = n, info = 0, lwork = -1;
    SR_INT *ipiv = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)n);
    if (!ipiv) return -1;
    sgetrf_(&nn, &nn, aCol, &lda, ipiv, &info);
    if (info != 0 || singular_u_f32(n, aCol)) { free(ipiv); return 1; }
    float wq = 0.0f;
    sgetri_(&nn, aCol, &lda, ipiv, &wq, &lwork, &info);
    if (info != 0) { free(ipiv); return 1; }
    lwork = (SR_INT)wq;
    if (lwork < 1) lwork = 1;
    float *work = (float *)malloc(sizeof(float) * (size_t)lwork);
    if (!work) { free(ipiv); return -1; }
    sgetri_(&nn, aCol, &lda, ipiv, work, &lwork, &info);
    free(work);
    free(ipiv);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_invert_lu_f64(int32_t n, double *aCol) {
    SR_INT nn = n, lda = n, info = 0, lwork = -1;
    SR_INT *ipiv = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)n);
    if (!ipiv) return -1;
    dgetrf_(&nn, &nn, aCol, &lda, ipiv, &info);
    if (info != 0 || singular_u_f64(n, aCol)) { free(ipiv); return 1; }
    double wq = 0.0;
    dgetri_(&nn, aCol, &lda, ipiv, &wq, &lwork, &info);
    if (info != 0) { free(ipiv); return 1; }
    lwork = (SR_INT)wq;
    if (lwork < 1) lwork = 1;
    double *work = (double *)malloc(sizeof(double) * (size_t)lwork);
    if (!work) { free(ipiv); return -1; }
    dgetri_(&nn, aCol, &lda, ipiv, work, &lwork, &info);
    free(work);
    free(ipiv);
    return info == 0 ? 0 : 1;
}

int32_t sr_c_invert_chol_f32(int32_t n, float *aCol) {
    SR_INT nn = n, lda = n, info = 0;
    spotrf_("L", &nn, aCol, &lda, &info);
    if (info != 0) return 1;
    spotri_("L", &nn, aCol, &lda, &info);
    if (info != 0) return 1;
    for (int32_t j = 0; j < n; j++)
        for (int32_t i = 0; i < j; i++)
            aCol[(size_t)j * n + i] = aCol[(size_t)i * n + j];
    return 0;
}

int32_t sr_c_invert_chol_f64(int32_t n, double *aCol) {
    SR_INT nn = n, lda = n, info = 0;
    dpotrf_("L", &nn, aCol, &lda, &info);
    if (info != 0) return 1;
    dpotri_("L", &nn, aCol, &lda, &info);
    if (info != 0) return 1;
    for (int32_t j = 0; j < n; j++)
        for (int32_t i = 0; i < j; i++)
            aCol[(size_t)j * n + i] = aCol[(size_t)i * n + j];
    return 0;
}

int32_t sr_c_svd_f32(int32_t m, int32_t n, char jobz, float *aCol, float *s, float *uCol, int32_t ldu, float *vtCol, int32_t ldvt) {
    SR_INT mm = m, nn = n, lda = m > 0 ? m : 1, lu = ldu > 0 ? ldu : 1, lvt = ldvt > 0 ? ldvt : 1, lwork = -1, info = 0;
    int32_t mn = m < n ? m : n;
    SR_INT *iwork = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)(8 * (mn > 1 ? mn : 1)));
    if (!iwork) return -1;
    char jbuf[2] = {jobz, 0};
    float wq = 0.0f;
    sgesdd_(jbuf, &mm, &nn, aCol, &lda, s, uCol, &lu, vtCol, &lvt, &wq, &lwork, iwork, &info);
    if (info != 0) { free(iwork); return (int32_t)info; }
    lwork = (SR_INT)wq;
    if (lwork < 1) lwork = 1;
    float *work = (float *)malloc(sizeof(float) * (size_t)lwork);
    if (!work) { free(iwork); return -1; }
    sgesdd_(jbuf, &mm, &nn, aCol, &lda, s, uCol, &lu, vtCol, &lvt, work, &lwork, iwork, &info);
    free(work);
    free(iwork);
    return (int32_t)info;
}

int32_t sr_c_svd_f64(int32_t m, int32_t n, char jobz, double *aCol, double *s, double *uCol, int32_t ldu, double *vtCol, int32_t ldvt) {
    SR_INT mm = m, nn = n, lda = m > 0 ? m : 1, lu = ldu > 0 ? ldu : 1, lvt = ldvt > 0 ? ldvt : 1, lwork = -1, info = 0;
    int32_t mn = m < n ? m : n;
    SR_INT *iwork = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)(8 * (mn > 1 ? mn : 1)));
    if (!iwork) return -1;
    char jbuf[2] = {jobz, 0};
    double wq = 0.0;
    dgesdd_(jbuf, &mm, &nn, aCol, &lda, s, uCol, &lu, vtCol, &lvt, &wq, &lwork, iwork, &info);
    if (info != 0) { free(iwork); return (int32_t)info; }
    lwork = (SR_INT)wq;
    if (lwork < 1) lwork = 1;
    double *work = (double *)malloc(sizeof(double) * (size_t)lwork);
    if (!work) { free(iwork); return -1; }
    dgesdd_(jbuf, &mm, &nn, aCol, &lda, s, uCol, &lu, vtCol, &lvt, work, &lwork, iwork, &info);
    free(work);
    free(iwork);
    return (int32_t)info;
}

int32_t sr_c_syevd_f32(int32_t n, int32_t wantVecs, float *aCol, float *w) {
    SR_INT nn = n, lda = n > 0 ? n : 1, lwork = -1, liwork = -1, info = 0;
    char j[2] = {wantVecs ? 'V' : 'N', 0};
    float wq = 0.0f;
    SR_INT iwq = 0;
    ssyevd_(j, "U", &nn, aCol, &lda, w, &wq, &lwork, &iwq, &liwork, &info);
    if (info != 0) return (int32_t)info;
    lwork = (SR_INT)wq; if (lwork < 1) lwork = 1;
    liwork = iwq; if (liwork < 1) liwork = 1;
    float *work = (float *)malloc(sizeof(float) * (size_t)lwork);
    SR_INT *iwork = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)liwork);
    if (!work || !iwork) { free(work); free(iwork); return -1; }
    ssyevd_(j, "U", &nn, aCol, &lda, w, work, &lwork, iwork, &liwork, &info);
    free(work); free(iwork);
    return (int32_t)info;
}

int32_t sr_c_syevd_f64(int32_t n, int32_t wantVecs, double *aCol, double *w) {
    SR_INT nn = n, lda = n > 0 ? n : 1, lwork = -1, liwork = -1, info = 0;
    char j[2] = {wantVecs ? 'V' : 'N', 0};
    double wq = 0.0;
    SR_INT iwq = 0;
    dsyevd_(j, "U", &nn, aCol, &lda, w, &wq, &lwork, &iwq, &liwork, &info);
    if (info != 0) return (int32_t)info;
    lwork = (SR_INT)wq; if (lwork < 1) lwork = 1;
    liwork = iwq; if (liwork < 1) liwork = 1;
    double *work = (double *)malloc(sizeof(double) * (size_t)lwork);
    SR_INT *iwork = (SR_INT *)malloc(sizeof(SR_INT) * (size_t)liwork);
    if (!work || !iwork) { free(work); free(iwork); return -1; }
    dsyevd_(j, "U", &nn, aCol, &lda, w, work, &lwork, iwork, &liwork, &info);
    free(work); free(iwork);
    return (int32_t)info;
}

int32_t sr_c_geev_f32(int32_t n, int32_t wantVecs, float *aCol, float *wr, float *wi, float *vrCol) {
    SR_INT nn = n, lda = n > 0 ? n : 1, ldvl = 1, ldvr = wantVecs && n > 0 ? n : 1, lwork = -1, info = 0;
    char jvr[2] = {wantVecs ? 'V' : 'N', 0};
    float dummy = 0.0f, wq = 0.0f;
    sgeev_("N", jvr, &nn, aCol, &lda, wr, wi, &dummy, &ldvl, vrCol ? vrCol : &dummy, &ldvr, &wq, &lwork, &info);
    if (info != 0) return (int32_t)info;
    lwork = (SR_INT)wq; if (lwork < 1) lwork = 1;
    float *work = (float *)malloc(sizeof(float) * (size_t)lwork);
    if (!work) return -1;
    sgeev_("N", jvr, &nn, aCol, &lda, wr, wi, &dummy, &ldvl, vrCol ? vrCol : &dummy, &ldvr, work, &lwork, &info);
    free(work);
    return (int32_t)info;
}

int32_t sr_c_geev_f64(int32_t n, int32_t wantVecs, double *aCol, double *wr, double *wi, double *vrCol) {
    SR_INT nn = n, lda = n > 0 ? n : 1, ldvl = 1, ldvr = wantVecs && n > 0 ? n : 1, lwork = -1, info = 0;
    char jvr[2] = {wantVecs ? 'V' : 'N', 0};
    double dummy = 0.0, wq = 0.0;
    dgeev_("N", jvr, &nn, aCol, &lda, wr, wi, &dummy, &ldvl, vrCol ? vrCol : &dummy, &ldvr, &wq, &lwork, &info);
    if (info != 0) return (int32_t)info;
    lwork = (SR_INT)wq; if (lwork < 1) lwork = 1;
    double *work = (double *)malloc(sizeof(double) * (size_t)lwork);
    if (!work) return -1;
    dgeev_("N", jvr, &nn, aCol, &lda, wr, wi, &dummy, &ldvl, vrCol ? vrCol : &dummy, &ldvr, work, &lwork, &info);
    free(work);
    return (int32_t)info;
}

// MARK: - Deterministic k-means (Lloyd + k-means++ / random / initial labels)

static inline uint64_t splitmix64(uint64_t *state) {
    uint64_t z = (*state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

static inline double rand_unit(uint64_t *state) {
    return (double)(splitmix64(state) >> 11) * (1.0 / 9007199254740992.0);
}

static inline double sqdist_f32(const float *a, const float *b, int32_t dims) {
    float s = 0.0f;
    vDSP_distancesq(a, 1, b, 1, &s, (vDSP_Length)dims);
    return (double)s;
}

double sr_c_kmeans_f32(const float *pts, int32_t n, int32_t dims, int32_t k,
                       int32_t maxIter, double eps, int32_t attempts, int32_t flags,
                       int32_t *labels, float *centers) {
    if (!pts || !labels || !centers || n <= 0 || dims <= 0 || k <= 0 || k > n) return -1.0;
    if (attempts < 1) attempts = 1;
    if (maxIter < 0) maxIter = 0;

    int32_t *curLbl = (int32_t *)malloc(sizeof(int32_t) * (size_t)n);
    float *curCtr = (float *)malloc(sizeof(float) * (size_t)k * (size_t)dims);
    double *sums = (double *)malloc(sizeof(double) * (size_t)k * (size_t)dims);
    int32_t *counts = (int32_t *)malloc(sizeof(int32_t) * (size_t)k);
    double *minD2 = (double *)malloc(sizeof(double) * (size_t)n);
    if (!curLbl || !curCtr || !sums || !counts || !minD2) {
        free(curLbl); free(curCtr); free(sums); free(counts); free(minD2);
        return -1.0;
    }

    double bestCompact = HUGE_VAL;
    double eps2 = eps * eps;
    int32_t useInitial = (flags & 1) != 0;   // KMEANS_USE_INITIAL_LABELS
    int32_t usePP = (flags & 2) != 0;        // KMEANS_PP_CENTERS

    for (int32_t a = 0; a < attempts; a++) {
        uint64_t rng = 0x534146415249554DULL ^ ((uint64_t)(a + 1) * 0x9E3779B97F4A7C15ULL);
        if (a == 0 && useInitial) {
            memcpy(curLbl, labels, sizeof(int32_t) * (size_t)n);
            memset(sums, 0, sizeof(double) * (size_t)k * (size_t)dims);
            memset(counts, 0, sizeof(int32_t) * (size_t)k);
            for (int32_t i = 0; i < n; i++) {
                int32_t c = curLbl[i];
                if (c < 0 || c >= k) c = i % k;
                curLbl[i] = c;
                counts[c]++;
                for (int32_t d = 0; d < dims; d++) sums[(size_t)c * dims + d] += pts[(size_t)i * dims + d];
            }
            for (int32_t c = 0; c < k; c++) {
                if (counts[c] > 0) {
                    double inv = 1.0 / counts[c];
                    for (int32_t d = 0; d < dims; d++) curCtr[(size_t)c * dims + d] = (float)(sums[(size_t)c * dims + d] * inv);
                } else {
                    int32_t idx = (int32_t)(splitmix64(&rng) % (uint64_t)n);
                    memcpy(curCtr + (size_t)c * dims, pts + (size_t)idx * dims, sizeof(float) * (size_t)dims);
                }
            }
        } else if (usePP) {
            int32_t first = (int32_t)(splitmix64(&rng) % (uint64_t)n);
            memcpy(curCtr, pts + (size_t)first * dims, sizeof(float) * (size_t)dims);
            double sumD2 = 0.0;
            for (int32_t i = 0; i < n; i++) {
                minD2[i] = sqdist_f32(pts + (size_t)i * dims, curCtr, dims);
                sumD2 += minD2[i];
            }
            for (int32_t c = 1; c < k; c++) {
                int32_t chosen = (int32_t)(splitmix64(&rng) % (uint64_t)n);
                if (sumD2 > 0.0) {
                    double target = rand_unit(&rng) * sumD2, acc = 0.0;
                    for (int32_t i = 0; i < n; i++) {
                        acc += minD2[i];
                        if (acc >= target) { chosen = i; break; }
                    }
                }
                memcpy(curCtr + (size_t)c * dims, pts + (size_t)chosen * dims, sizeof(float) * (size_t)dims);
                sumD2 = 0.0;
                for (int32_t i = 0; i < n; i++) {
                    double d2 = sqdist_f32(pts + (size_t)i * dims, curCtr + (size_t)c * dims, dims);
                    if (d2 < minD2[i]) minD2[i] = d2;
                    sumD2 += minD2[i];
                }
            }
        } else {
            // Random bounding-box uniform centers (matching OpenCV generateRandomCenter)
            for (int32_t d = 0; d < dims; d++) {
                float lo = pts[d], hi = pts[d];
                for (int32_t i = 1; i < n; i++) {
                    float v = pts[(size_t)i * dims + d];
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                }
                for (int32_t c = 0; c < k; c++) {
                    curCtr[(size_t)c * dims + d] = lo + (float)(rand_unit(&rng) * (double)(hi - lo));
                }
            }
        }

        double compact = HUGE_VAL;
        for (int32_t iter = 0; iter < maxIter || iter == 0; iter++) {
            compact = 0.0;
            memset(sums, 0, sizeof(double) * (size_t)k * (size_t)dims);
            memset(counts, 0, sizeof(int32_t) * (size_t)k);
            for (int32_t i = 0; i < n; i++) {
                const float *p = pts + (size_t)i * dims;
                int32_t bestC = 0;
                double bestD = sqdist_f32(p, curCtr, dims);
                for (int32_t c = 1; c < k; c++) {
                    double d2 = sqdist_f32(p, curCtr + (size_t)c * dims, dims);
                    if (d2 < bestD) { bestD = d2; bestC = c; }
                }
                curLbl[i] = bestC;
                compact += bestD;
                counts[bestC]++;
                for (int32_t d = 0; d < dims; d++) sums[(size_t)bestC * dims + d] += p[d];
            }
            if (iter >= maxIter) break;
            // Handle empty clusters by splitting largest cluster / farthest point
            for (int32_t c = 0; c < k; c++) {
                if (counts[c] == 0) {
                    int32_t big = 0;
                    for (int32_t j = 1; j < k; j++) if (counts[j] > counts[big]) big = j;
                    int32_t farI = -1;
                    double farD = -1.0;
                    for (int32_t i = 0; i < n; i++) {
                        if (curLbl[i] == big) {
                            double d2 = sqdist_f32(pts + (size_t)i * dims, curCtr + (size_t)big * dims, dims);
                            if (d2 > farD) { farD = d2; farI = i; }
                        }
                    }
                    if (farI >= 0) {
                        curLbl[farI] = c;
                        counts[big]--;
                        counts[c]++;
                        for (int32_t d = 0; d < dims; d++) {
                            sums[(size_t)big * dims + d] -= pts[(size_t)farI * dims + d];
                            sums[(size_t)c * dims + d] += pts[(size_t)farI * dims + d];
                        }
                    }
                }
            }
            double maxMove2 = 0.0;
            for (int32_t c = 0; c < k; c++) {
                if (counts[c] > 0) {
                    double inv = 1.0 / counts[c], mv = 0.0;
                    for (int32_t d = 0; d < dims; d++) {
                        float nc = (float)(sums[(size_t)c * dims + d] * inv);
                        double diff = (double)nc - (double)curCtr[(size_t)c * dims + d];
                        mv += diff * diff;
                        curCtr[(size_t)c * dims + d] = nc;
                    }
                    if (mv > maxMove2) maxMove2 = mv;
                }
            }
            if (maxMove2 <= eps2) {
                compact = 0.0;
                for (int32_t i = 0; i < n; i++) {
                    const float *p = pts + (size_t)i * dims;
                    int32_t bestC = 0;
                    double bestD = sqdist_f32(p, curCtr, dims);
                    for (int32_t c = 1; c < k; c++) {
                        double d2 = sqdist_f32(p, curCtr + (size_t)c * dims, dims);
                        if (d2 < bestD) { bestD = d2; bestC = c; }
                    }
                    curLbl[i] = bestC;
                    compact += bestD;
                }
                break;
            }
        }
        if (compact < bestCompact) {
            bestCompact = compact;
            memcpy(labels, curLbl, sizeof(int32_t) * (size_t)n);
            memcpy(centers, curCtr, sizeof(float) * (size_t)k * (size_t)dims);
        }
    }

    free(curLbl); free(curCtr); free(sums); free(counts); free(minD2);
    return bestCompact;
}

#pragma clang diagnostic pop
