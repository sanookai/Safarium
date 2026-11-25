// SafariumRasterC — Fast C99/NEON Connected Components (4-connected Run-Length + 8-connected BBDT).
// Matches OpenCV 5.1.0 EXACT label numbering:
//   - 4-connected: raster-scan order of each component's first pixel.
//   - 8-connected: 2x2 block (BBDT) scan order ((y >> 1) * ((w + 1) >> 1) + (x >> 1)).
// Background = label 0 (if empty: stats = (-1, INT32_MAX, 0, 0, 0), centroid = (NaN, NaN)).
// Stats/centroids are computed lazily in sr_c_cc_take only when requested (stats != NULL || centroids != NULL),
// so connectedComponents (without stats) does zero statistics work.

#include "sr_ops_perf.h"

#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__) || defined(__ARM_NEON)
#include <arm_neon.h>
#define SR_CC_NEON 1
#else
#define SR_CC_NEON 0
#endif

typedef struct {
    int32_t n;
    int32_t w;
    int32_t h;
    ptrdiff_t lstep_bytes;
    const int32_t *lab;
} sr_cc_result_t;

typedef struct {
    int32_t x0;
    int32_t x1;
    int32_t label;
} cc_run_t;

static inline int32_t cc_find(int32_t *parent, int32_t x) {
    int32_t r = x;
    while (parent[r] != r) r = parent[r];
    while (parent[x] != r) {
        int32_t nx = parent[x];
        parent[x] = r;
        x = nx;
    }
    return r;
}

static inline int32_t cc_union(int32_t *parent, int32_t a, int32_t b) {
    if (a == b) return a;
    int32_t ra = cc_find(parent, a);
    int32_t rb = cc_find(parent, b);
    if (ra == rb) return ra;
    if (ra < rb) {
        parent[rb] = ra;
        return ra;
    }
    parent[ra] = rb;
    return rb;
}

static int32_t *cc_grow_parent(int32_t *parent, int32_t *cap) {
    int32_t new_cap = (*cap < 4096) ? 4096 : (*cap * 2);
    int32_t *np = (int32_t *)realloc(parent, (size_t)new_cap * sizeof(int32_t));
    if (!np) return NULL;
    *cap = new_cap;
    return np;
}

static inline void cc_fill_i32(int32_t *dst, int32_t count, int32_t val) {
    int32_t i = 0;
#if SR_CC_NEON
    int32x4_t vv = vdupq_n_s32(val);
    for (; i + 16 <= count; i += 16) {
        vst1q_s32(dst + i, vv);
        vst1q_s32(dst + i + 4, vv);
        vst1q_s32(dst + i + 8, vv);
        vst1q_s32(dst + i + 12, vv);
    }
    for (; i + 4 <= count; i += 4) {
        vst1q_s32(dst + i, vv);
    }
#endif
    for (; i < count; i++) dst[i] = val;
}

static int32_t cc_make_handle(int32_t n, int32_t w, int32_t h, ptrdiff_t lstep_bytes,
                              const int32_t *lab, int32_t *out_n, void **out_handle) {
    *out_n = n;
    if (!out_handle) return 0;
    sr_cc_result_t *res = (sr_cc_result_t *)malloc(sizeof(sr_cc_result_t));
    if (!res) return -1;
    res->n = n;
    res->w = w;
    res->h = h;
    res->lstep_bytes = lstep_bytes;
    res->lab = lab;
    *out_handle = res;
    return 0;
}

// ---------------------------------------------------------------------------
// 4-connected: Scanline Run-Length Union-Find (exact raster-scan label order)
// ---------------------------------------------------------------------------
static int32_t cc_4conn(const uint8_t *src, ptrdiff_t sstep,
                        int32_t *lab, ptrdiff_t lstep_bytes,
                        int32_t w, int32_t h,
                        int32_t *out_n, void **out_handle) {
    int32_t p_cap = 4096;
    int32_t *parent = (int32_t *)malloc((size_t)p_cap * sizeof(int32_t));
    int32_t *row_off = (int32_t *)malloc((size_t)(h + 1) * sizeof(int32_t));
    int32_t r_cap = (w * h) / 16 + 1024;
    if (r_cap < 1024) r_cap = 1024;
    cc_run_t *runs = (cc_run_t *)malloc((size_t)r_cap * sizeof(cc_run_t));
    if (!parent || !row_off || !runs) {
        free(parent); free(row_off); free(runs);
        return -1;
    }

    parent[0] = 0;
    int32_t next_lab = 1;
    int32_t nruns = 0;
    row_off[0] = 0;

    // Pass 1: extract foreground runs with NEON zero/non-zero skipping & union with previous row
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *sr = src + (ptrdiff_t)y * sstep;
        const int32_t prev_s = (y > 0) ? row_off[y - 1] : 0;
        const int32_t prev_e = row_off[y];
        int32_t p_idx = prev_s;
        int32_t x = 0;

        while (x < w) {
            int32_t lim0 = x + 4;
            if (lim0 > w) lim0 = w;
            while (x < lim0 && sr[x] == 0) x++;
            if (x == lim0 && x < w) {
#if SR_CC_NEON
                while (x + 16 <= w && vmaxvq_u8(vld1q_u8(sr + x)) == 0) x += 16;
#endif
                while (x < w && sr[x] == 0) x++;
            }
            if (x >= w) break;
            const int32_t x0 = x;
            x++;
            int32_t lim1 = x + 4;
            if (lim1 > w) lim1 = w;
            while (x < lim1 && sr[x] != 0) x++;
            if (x == lim1 && x < w) {
#if SR_CC_NEON
                while (x + 16 <= w && vminvq_u8(vld1q_u8(sr + x)) != 0) x += 16;
#endif
                while (x < w && sr[x] != 0) x++;
            }
            const int32_t x1 = x;

            if (nruns >= r_cap) {
                int32_t nc = r_cap * 2;
                cc_run_t *nr = (cc_run_t *)realloc(runs, (size_t)nc * sizeof(cc_run_t));
                if (!nr) { free(parent); free(row_off); free(runs); return -1; }
                runs = nr;
                r_cap = nc;
            }

            while (p_idx < prev_e && runs[p_idx].x1 <= x0) p_idx++;
            int32_t cur = 0;
            int32_t q = p_idx;
            while (q < prev_e && runs[q].x0 < x1) {
                int32_t pl = runs[q].label;
                cur = (cur == 0) ? pl : cc_union(parent, cur, pl);
                if (runs[q].x1 <= x1) p_idx = q + 1;
                q++;
            }
            if (cur == 0) {
                if (next_lab >= p_cap) {
                    int32_t *np = cc_grow_parent(parent, &p_cap);
                    if (!np) { free(parent); free(row_off); free(runs); return -1; }
                    parent = np;
                }
                cur = next_lab++;
                parent[cur] = cur;
            }
            runs[nruns].x0 = x0;
            runs[nruns].x1 = x1;
            runs[nruns].label = cur;
            nruns++;
        }
        row_off[y + 1] = nruns;
    }

    // Flatten parent in-place -> exact raster-scan consecutive labels 1 .. n - 1
    int32_t n = 1;
    for (int32_t i = 1; i < next_lab; i++) {
        int32_t p = parent[i];
        parent[i] = (p == i) ? (n++) : parent[p];
    }

    // Pass 2: pure sequential label fill (zero stats overhead, inline short spans)
    for (int32_t y = 0; y < h; y++) {
        int32_t *l = (int32_t *)((uint8_t *)lab + (ptrdiff_t)y * lstep_bytes);
        const int32_t rs = row_off[y], re = row_off[y + 1];
        int32_t pos = 0;
        for (int32_t r = rs; r < re; r++) {
            const int32_t x0 = runs[r].x0;
            const int32_t x1 = runs[r].x1;
            const int32_t zlen = x0 - pos;
            if (zlen > 0) {
                if (zlen <= 4) {
                    for (int32_t k = pos; k < x0; k++) l[k] = 0;
                } else {
                    cc_fill_i32(l + pos, zlen, 0);
                }
            }
            const int32_t flen = x1 - x0;
            const int32_t fl = parent[runs[r].label];
            if (flen == 1) {
                l[x0] = fl;
            } else if (flen <= 4) {
                for (int32_t k = x0; k < x1; k++) l[k] = fl;
            } else {
                cc_fill_i32(l + x0, flen, fl);
            }
            pos = x1;
        }
        if (pos < w) {
            cc_fill_i32(l + pos, w - pos, 0);
        }
    }

    free(parent);
    free(row_off);
    free(runs);
    return cc_make_handle(n, w, h, lstep_bytes, lab, out_n, out_handle);
}

// ---------------------------------------------------------------------------
// 8-connected: Native 2x2 Block (BBDT) Two-Pass Union-Find
// Provisional block labels stored in lab row (2*by) at [0 .. bw - 1] (zero extra buffer!).
// Because union always picks min(ra, rb), root order == EXACT BBDT 2x2 block scan order!
// ---------------------------------------------------------------------------
static int32_t cc_8conn_bbdt(const uint8_t *src, ptrdiff_t sstep,
                             int32_t *lab, ptrdiff_t lstep_bytes,
                             int32_t w, int32_t h,
                             int32_t *out_n, void **out_handle) {
    const int32_t bw = (w + 1) >> 1;
    const int32_t bh = (h + 1) >> 1;
    const int32_t bw_inner = (w >= 5) ? ((w - 3) >> 1) : 0; // blocks 1 .. bw_inner have x0-1 >= 0, x0+2 < w, and bx+1 < bw

    int32_t p_cap = 4096;
    int32_t *parent = (int32_t *)malloc((size_t)p_cap * sizeof(int32_t));
    if (!parent) return -1;
    parent[0] = 0;
    int32_t next_lab = 1;

#if SR_CC_NEON
    const int32x4_t vzero_s32 = vdupq_n_s32(0);
#endif

    // Pass 1: 2x2 block scan
    for (int32_t by = 0; by < bh; by++) {
        const int32_t y0 = by * 2;
        const int has_y1 = (y0 + 1 < h);
        const uint8_t *s0 = src + (ptrdiff_t)y0 * sstep;
        const uint8_t *s1 = has_y1 ? (s0 + sstep) : NULL;
        const uint8_t *sp = (by > 0) ? (s0 - sstep) : NULL;
        int32_t *bl_cur = (int32_t *)((uint8_t *)lab + (ptrdiff_t)y0 * lstep_bytes);
        const int32_t *bl_prev = (by > 0)
            ? (const int32_t *)((const uint8_t *)lab + (ptrdiff_t)(y0 - 2) * lstep_bytes)
            : NULL;

        int32_t prev_r_lab = 0; // label of left block iff its right column had foreground, else 0

        if (by > 0 && has_y1 && bw_inner >= 1) {
            // Block 0 (left boundary: bx == 0, x0 == 0, x0 + 1 < w guaranteed since w >= 4)
            {
                const uint8_t o = s0[0], p = s0[1], s = s1[0], t = s1[1];
                if ((o | p | s | t) == 0) {
                    bl_cur[0] = 0;
                    prev_r_lab = 0;
                } else {
                    int32_t cur = 0;
                    if (o | p) {
                        const uint8_t u_s = sp[0], u_t = sp[1];
                        if (u_s | u_t) cur = bl_prev[0];
                        if (p && !u_t && sp[2]) {
                            int32_t cand = bl_prev[1];
                            cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                        }
                    }
                    if (cur == 0) {
                        if (next_lab >= p_cap) {
                            int32_t *np = cc_grow_parent(parent, &p_cap);
                            if (!np) { free(parent); return -1; }
                            parent = np;
                        }
                        cur = next_lab++;
                        parent[cur] = cur;
                    }
                    bl_cur[0] = cur;
                    prev_r_lab = (p | t) ? cur : 0;
                }
            }

            // Interior blocks bx = 1 .. bw_inner: zero boundary checks!
            int32_t bx = 1;
            while (bx <= bw_inner) {
#if SR_CC_NEON
                while (bx + 8 <= bw_inner) {
                    const ptrdiff_t xoff = (ptrdiff_t)bx * 2;
                    uint8x16_t v0 = vld1q_u8(s0 + xoff);
                    uint8x16_t v1 = vld1q_u8(s1 + xoff);
                    if (vmaxvq_u8(vorrq_u8(v0, v1)) == 0) {
                        vst1q_s32(bl_cur + bx, vzero_s32);
                        vst1q_s32(bl_cur + bx + 4, vzero_s32);
                        prev_r_lab = 0;
                        bx += 8;
                        continue;
                    }
                    break;
                }
#endif
                const int32_t x0 = bx * 2;
                const uint8_t o = s0[x0], p = s0[x0 + 1], s = s1[x0], t = s1[x0 + 1];
                if ((o | p | s | t) == 0) {
                    bl_cur[bx] = 0;
                    prev_r_lab = 0;
                    bx++;
                    continue;
                }
                int32_t cur = (o | s) ? prev_r_lab : 0;
                if (o | p) {
                    const uint8_t u_s = sp[x0], u_t = sp[x0 + 1];
                    if (u_s | u_t) {
                        int32_t cand = bl_prev[bx];
                        cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                    }
                    if (o && !u_s && sp[x0 - 1]) {
                        int32_t cand = bl_prev[bx - 1];
                        cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                    }
                    if (p && !u_t && sp[x0 + 2]) {
                        int32_t cand = bl_prev[bx + 1];
                        cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                    }
                }
                if (cur == 0) {
                    if (next_lab >= p_cap) {
                        int32_t *np = cc_grow_parent(parent, &p_cap);
                        if (!np) { free(parent); return -1; }
                        parent = np;
                    }
                    cur = next_lab++;
                    parent[cur] = cur;
                }
                bl_cur[bx] = cur;
                prev_r_lab = (p | t) ? cur : 0;
                bx++;
            }

            // Right boundary blocks bx = bw_inner + 1 .. bw - 1
            for (; bx < bw; bx++) {
                const int32_t x0 = bx * 2;
                const int has_x1 = (x0 + 1 < w);
                const uint8_t o = s0[x0];
                const uint8_t p = has_x1 ? s0[x0 + 1] : 0;
                const uint8_t s = s1[x0];
                const uint8_t t = has_x1 ? s1[x0 + 1] : 0;
                if ((o | p | s | t) == 0) {
                    bl_cur[bx] = 0;
                    prev_r_lab = 0;
                    continue;
                }
                int32_t cur = (o | s) ? prev_r_lab : 0;
                if (o | p) {
                    const uint8_t u_s = sp[x0];
                    const uint8_t u_t = has_x1 ? sp[x0 + 1] : 0;
                    if (u_s | u_t) {
                        int32_t cand = bl_prev[bx];
                        cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                    }
                    if (o && !u_s && sp[x0 - 1]) {
                        int32_t cand = bl_prev[bx - 1];
                        cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                    }
                    if (p && (bx + 1 < bw) && !u_t && sp[x0 + 2]) {
                        int32_t cand = bl_prev[bx + 1];
                        cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                    }
                }
                if (cur == 0) {
                    if (next_lab >= p_cap) {
                        int32_t *np = cc_grow_parent(parent, &p_cap);
                        if (!np) { free(parent); return -1; }
                        parent = np;
                    }
                    cur = next_lab++;
                    parent[cur] = cur;
                }
                bl_cur[bx] = cur;
                prev_r_lab = (p | t) ? cur : 0;
            }
            continue;
        }

        // General row (by == 0, last odd row, or w < 4)
        for (int32_t bx = 0; bx < bw; bx++) {
            const int32_t x0 = bx * 2;
            const int has_x1 = (x0 + 1 < w);
            const uint8_t o = s0[x0];
            const uint8_t p = has_x1 ? s0[x0 + 1] : 0;
            const uint8_t s = has_y1 ? s1[x0] : 0;
            const uint8_t t = (has_y1 && has_x1) ? s1[x0 + 1] : 0;
            if ((o | p | s | t) == 0) {
                bl_cur[bx] = 0;
                prev_r_lab = 0;
                continue;
            }
            int32_t cur = (o | s) ? prev_r_lab : 0;
            if (sp && (o | p)) {
                const uint8_t u_s = sp[x0];
                const uint8_t u_t = has_x1 ? sp[x0 + 1] : 0;
                if (u_s | u_t) {
                    int32_t cand = bl_prev[bx];
                    cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                }
                if (o && bx > 0 && !u_s && sp[x0 - 1]) {
                    int32_t cand = bl_prev[bx - 1];
                    cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                }
                if (p && (bx + 1 < bw) && !u_t && sp[x0 + 2]) {
                    int32_t cand = bl_prev[bx + 1];
                    cur = (cur == 0) ? cand : cc_union(parent, cur, cand);
                }
            }
            if (cur == 0) {
                if (next_lab >= p_cap) {
                    int32_t *np = cc_grow_parent(parent, &p_cap);
                    if (!np) { free(parent); return -1; }
                    parent = np;
                }
                cur = next_lab++;
                parent[cur] = cur;
            }
            bl_cur[bx] = cur;
            prev_r_lab = (p | t) ? cur : 0;
        }
    }

    // Flatten parent in-place -> exact BBDT consecutive labels 1 .. n - 1
    int32_t n = 1;
    for (int32_t i = 1; i < next_lab; i++) {
        int32_t p = parent[i];
        parent[i] = (p == i) ? (n++) : parent[p];
    }

    // Pass 2: branchless right-to-left 2x2 block label expansion (2*bx >= bx => strictly alias-free!)
    for (int32_t by = 0; by < bh; by++) {
        const int32_t y0 = by * 2;
        const int has_y1 = (y0 + 1 < h);
        const uint8_t *s0 = src + (ptrdiff_t)y0 * sstep;
        const uint8_t *s1 = has_y1 ? (s0 + sstep) : NULL;
        int32_t *l0 = (int32_t *)((uint8_t *)lab + (ptrdiff_t)y0 * lstep_bytes);
        int32_t *l1 = has_y1 ? (int32_t *)((uint8_t *)lab + (ptrdiff_t)(y0 + 1) * lstep_bytes) : NULL;

        int32_t bx = bw - 1;
        if ((w & 1) != 0 && bx >= 0) {
            const int32_t x0 = bx * 2;
            const int32_t bl = l0[bx];
            if (bl == 0) {
                l0[x0] = 0;
                if (has_y1) l1[x0] = 0;
            } else {
                const int32_t f = parent[bl];
                l0[x0] = s0[x0] ? f : 0;
                if (has_y1) l1[x0] = s1[x0] ? f : 0;
            }
            bx--;
        }

        if (has_y1) {
            while (bx >= 0) {
#if SR_CC_NEON
                while (bx >= 7) {
                    uint32x4_t b0 = vreinterpretq_u32_s32(vld1q_s32(l0 + bx - 7));
                    uint32x4_t b1 = vreinterpretq_u32_s32(vld1q_s32(l0 + bx - 3));
                    if (vmaxvq_u32(vorrq_u32(b0, b1)) == 0) {
                        const int32_t xl = (bx - 7) * 2;
                        vst1q_s32(l0 + xl,      vzero_s32);
                        vst1q_s32(l0 + xl + 4,  vzero_s32);
                        vst1q_s32(l0 + xl + 8,  vzero_s32);
                        vst1q_s32(l0 + xl + 12, vzero_s32);
                        vst1q_s32(l1 + xl,      vzero_s32);
                        vst1q_s32(l1 + xl + 4,  vzero_s32);
                        vst1q_s32(l1 + xl + 8,  vzero_s32);
                        vst1q_s32(l1 + xl + 12, vzero_s32);
                        bx -= 8;
                        continue;
                    }
                    break;
                }
                if (bx < 0) break;
#endif
                const int32_t bl = l0[bx];
                const int32_t x0 = bx * 2;
                if (bl == 0) {
                    l0[x0] = 0; l0[x0 + 1] = 0;
                    l1[x0] = 0; l1[x0 + 1] = 0;
                } else {
                    const int32_t f = parent[bl];
                    l0[x0]     = s0[x0]     ? f : 0;
                    l0[x0 + 1] = s0[x0 + 1] ? f : 0;
                    l1[x0]     = s1[x0]     ? f : 0;
                    l1[x0 + 1] = s1[x0 + 1] ? f : 0;
                }
                bx--;
            }
        } else {
            while (bx >= 0) {
                const int32_t bl = l0[bx];
                const int32_t x0 = bx * 2;
                if (bl == 0) {
                    l0[x0] = 0; l0[x0 + 1] = 0;
                } else {
                    const int32_t f = parent[bl];
                    l0[x0]     = s0[x0]     ? f : 0;
                    l0[x0 + 1] = s0[x0 + 1] ? f : 0;
                }
                bx--;
            }
        }
    }

    free(parent);
    return cc_make_handle(n, w, h, lstep_bytes, lab, out_n, out_handle);
}

int32_t sr_c_connected_components(const uint8_t *src, ptrdiff_t sstep,
                                  int32_t *lab, ptrdiff_t lstep_bytes,
                                  int32_t w, int32_t h, int32_t connectivity,
                                  int32_t *out_n, void **out_handle) {
    if (!out_n || w < 0 || h < 0 || (connectivity != 4 && connectivity != 8)) return -1;
    if (w == 0 || h == 0) {
        return cc_make_handle(1, 0, 0, lstep_bytes, lab, out_n, out_handle);
    }
    if (!src || !lab) return -1;
    if (connectivity == 4) {
        return cc_4conn(src, sstep, lab, lstep_bytes, w, h, out_n, out_handle);
    }
    return cc_8conn_bbdt(src, sstep, lab, lstep_bytes, w, h, out_n, out_handle);
}

int32_t sr_c_cc_take(void *handle, int32_t *stats, double *centroids) {
    if (!handle) return -1;
    sr_cc_result_t *res = (sr_cc_result_t *)handle;
    const int32_t n = res->n;
    const int32_t w = res->w;
    const int32_t h = res->h;
    const ptrdiff_t lstep = res->lstep_bytes;
    const int32_t *lab = res->lab;
    free(res);

    if (!stats && !centroids) return 0;
    if (n <= 0) return 0;

    if (w == 0 || h == 0 || !lab) {
        if (stats) {
            stats[0] = -1; stats[1] = INT32_MAX; stats[2] = 0; stats[3] = 0; stats[4] = 0;
        }
        if (centroids) {
            centroids[0] = NAN; centroids[1] = NAN;
        }
        return 0;
    }

    int32_t *st_buf = stats;
    int32_t *st_tmp = NULL;
    if (!st_buf) {
        st_tmp = (int32_t *)malloc((size_t)n * 5u * sizeof(int32_t));
        if (!st_tmp) return -1;
        st_buf = st_tmp;
    }
    for (int32_t i = 0; i < n; i++) {
        int32_t *s = st_buf + (ptrdiff_t)i * 5;
        s[0] = INT32_MAX; // left
        s[1] = INT32_MAX; // top
        s[2] = -1;        // right
        s[3] = -1;        // bottom
        s[4] = 0;         // area
    }
    if (centroids) {
        memset(centroids, 0, (size_t)n * 2u * sizeof(double));
    }

    int32_t bg_left = INT32_MAX, bg_top = INT32_MAX, bg_right = -1, bg_bottom = -1;

    // Run-length coalesced scan of lab: one stats update per horizontal run!
    for (int32_t y = 0; y < h; y++) {
        const int32_t *lr = (const int32_t *)((const uint8_t *)lab + (ptrdiff_t)y * lstep);
        int32_t x = 0;
        while (x < w) {
            const int32_t l = lr[x];
            if (l == 0) {
                const int32_t x0 = x;
                x++;
#if SR_CC_NEON
                while (x + 8 <= w) {
                    uint32x4_t v0 = vreinterpretq_u32_s32(vld1q_s32(lr + x));
                    uint32x4_t v1 = vreinterpretq_u32_s32(vld1q_s32(lr + x + 4));
                    if (vmaxvq_u32(vorrq_u32(v0, v1)) == 0) {
                        x += 8;
                        continue;
                    }
                    break;
                }
#endif
                while (x < w && lr[x] == 0) x++;
                if (x0 < bg_left) bg_left = x0;
                if (x - 1 > bg_right) bg_right = x - 1;
                if (y < bg_top) bg_top = y;
                bg_bottom = y;
            } else {
                const int32_t x0 = x;
                x++;
                while (x < w && lr[x] == l) x++;
                const int32_t len = x - x0;
                int32_t *st = st_buf + (ptrdiff_t)l * 5;
                if (x0 < st[0]) st[0] = x0;
                if (y < st[1]) st[1] = y;
                if (x - 1 > st[2]) st[2] = x - 1;
                st[3] = y;
                st[4] += len;
                if (centroids) {
                    double *oc = centroids + (ptrdiff_t)l * 2;
                    oc[0] += (double)(((int64_t)len * (int64_t)(x0 + x - 1)) >> 1);
                    oc[1] += (double)((int64_t)len * (int64_t)y);
                }
            }
        }
    }

    int64_t fg_area = 0;
    double fg_sx = 0.0, fg_sy = 0.0;
    for (int32_t i = 1; i < n; i++) {
        int32_t *st = st_buf + (ptrdiff_t)i * 5;
        const int32_t area = st[4];
        if (area > 0) {
            st[2] = st[2] - st[0] + 1;
            st[3] = st[3] - st[1] + 1;
            fg_area += (int64_t)area;
            if (centroids) {
                double *oc = centroids + (ptrdiff_t)i * 2;
                fg_sx += oc[0];
                fg_sy += oc[1];
                oc[0] /= (double)area;
                oc[1] /= (double)area;
            }
        } else {
            st[0] = -1; st[1] = INT32_MAX; st[2] = 0; st[3] = 0; st[4] = 0;
            if (centroids) {
                centroids[(ptrdiff_t)i * 2]     = NAN;
                centroids[(ptrdiff_t)i * 2 + 1] = NAN;
            }
        }
    }

    const int64_t total_area = (int64_t)w * (int64_t)h;
    const int64_t bg_area = total_area - fg_area;
    if (bg_area > 0) {
        st_buf[0] = bg_left;
        st_buf[1] = bg_top;
        st_buf[2] = bg_right - bg_left + 1;
        st_buf[3] = bg_bottom - bg_top + 1;
        st_buf[4] = (int32_t)bg_area;
        if (centroids) {
            const double total_sx = (double)h * (double)w * (double)(w - 1) * 0.5;
            const double total_sy = (double)w * (double)h * (double)(h - 1) * 0.5;
            centroids[0] = (total_sx - fg_sx) / (double)bg_area;
            centroids[1] = (total_sy - fg_sy) / (double)bg_area;
        }
    } else {
        st_buf[0] = -1; st_buf[1] = INT32_MAX; st_buf[2] = 0; st_buf[3] = 0; st_buf[4] = 0;
        if (centroids) {
            centroids[0] = NAN;
            centroids[1] = NAN;
        }
    }

    free(st_tmp);
    return 0;
}
