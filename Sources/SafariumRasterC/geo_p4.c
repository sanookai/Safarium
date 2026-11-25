// SafariumRasterC — Phase 4 C11 kernels: Geometry, Contours, Hough, LSD, FloodFill, Watershed, GrabCut, Subdiv2D.
// Clean C11, ASan/UBSan-safe, Apple frameworks / libc only (no OpenCV/FFmpeg/third-party deps).

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// ---------------------------------------------------------------------------
// Common helpers
// ---------------------------------------------------------------------------

typedef struct {
    double x;
    double y;
} sr_pt2d;

typedef struct {
    double x;
    double y;
    int32_t idx;
} sr_pt_idx;

static inline sr_pt2d sr_load_pt(const void *pts, int32_t i, int32_t is_f32) {
    sr_pt2d p;
    if (is_f32) {
        const float *fp = (const float *)pts;
        p.x = (double)fp[(size_t)i * 2];
        p.y = (double)fp[(size_t)i * 2 + 1];
    } else {
        const int32_t *ip = (const int32_t *)pts;
        p.x = (double)ip[(size_t)i * 2];
        p.y = (double)ip[(size_t)i * 2 + 1];
    }
    return p;
}

static inline double sr_cross3(sr_pt2d o, sr_pt2d a, sr_pt2d b) {
    return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
}

static inline int32_t sr_round_d(double v) {
    return (int32_t)llrint(v);
}

static inline uint8_t sr_sat_u8_d(double v) {
    if (v <= 0.0) return 0;
    if (v >= 255.0) return 255;
    return (uint8_t)llrint(v);
}

void sr_c_p4_free(void *ptr) {
    free(ptr);
}

// ---------------------------------------------------------------------------
// Fast arcLength & pointPolygonTest
// ---------------------------------------------------------------------------

int32_t sr_c_p4_arc_length(const void *pts, int32_t n, int32_t is_f32, int32_t closed, double *out_len) {
    if (!out_len || n < 0 || (n > 0 && !pts)) return -1;
    if (n < 2) {
        *out_len = 0.0;
        return 0;
    }
    double sum = 0.0;
    sr_pt2d prev = sr_load_pt(pts, 0, is_f32);
    sr_pt2d first = prev;
    for (int32_t i = 1; i < n; i++) {
        sr_pt2d cur = sr_load_pt(pts, i, is_f32);
        sum += hypot(cur.x - prev.x, cur.y - prev.y);
        prev = cur;
    }
    if (closed) {
        sum += hypot(first.x - prev.x, first.y - prev.y);
    }
    *out_len = sum;
    return 0;
}

int32_t sr_c_p4_point_polygon_test(const void *pts, int32_t n, int32_t is_f32,
                                   double px, double py, int32_t measure_dist, double *out_val) {
    if (!out_val || n < 0 || (n > 0 && !pts)) return -1;
    if (n == 0) {
        *out_val = -1.0;
        return 0;
    }
    double min_dist2 = DBL_MAX;
    int counter = 0;
    sr_pt2d v0 = sr_load_pt(pts, n - 1, is_f32);
    for (int32_t i = 0; i < n; i++) {
        sr_pt2d v = sr_load_pt(pts, i, is_f32);
        double dx = v.x - v0.x;
        double dy = v.y - v0.y;
        double dx1 = px - v0.x;
        double dy1 = py - v0.y;
        double dx2 = px - v.x;
        double dy2 = py - v.y;
        double dist2;
        if (dx1 * dx + dy1 * dy <= 0.0) {
            dist2 = dx1 * dx1 + dy1 * dy1;
        } else if (dx2 * dx + dy2 * dy >= 0.0) {
            dist2 = dx2 * dx2 + dy2 * dy2;
        } else {
            double num = dx1 * dy - dy1 * dx;
            double den = dx * dx + dy * dy;
            dist2 = (den > 0.0) ? (num * num / den) : (dx1 * dx1 + dy1 * dy1);
        }
        if (dist2 < min_dist2) min_dist2 = dist2;
        if (min_dist2 == 0.0) {
            *out_val = 0.0;
            return 0;
        }
        if ((v0.y <= py && v.y > py) || (v.y <= py && v0.y > py)) {
            double vt = (py - v0.y) / dy;
            if (px < v0.x + vt * dx) {
                counter++;
            }
        }
        v0 = v;
    }
    int inside = (counter & 1) != 0;
    if (measure_dist) {
        double d = sqrt(min_dist2);
        *out_val = inside ? d : -d;
    } else {
        *out_val = inside ? 1.0 : -1.0;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Basic Contour & Polygon Descriptors
// ---------------------------------------------------------------------------

int32_t sr_c_p4_bounding_rect_pts(const void *pts, int32_t n, int32_t is_f32, int32_t *out_xywh) {
    if (!out_xywh || n < 0 || (n > 0 && !pts)) return -1;
    if (n == 0) {
        out_xywh[0] = 0; out_xywh[1] = 0; out_xywh[2] = 0; out_xywh[3] = 0;
        return 0;
    }
    if (!is_f32) {
        const int32_t *ip = (const int32_t *)pts;
        int32_t xmin = ip[0], xmax = ip[0], ymin = ip[1], ymax = ip[1];
        for (int32_t i = 1; i < n; i++) {
            int32_t x = ip[(size_t)i * 2];
            int32_t y = ip[(size_t)i * 2 + 1];
            if (x < xmin) xmin = x;
            if (x > xmax) xmax = x;
            if (y < ymin) ymin = y;
            if (y > ymax) ymax = y;
        }
        out_xywh[0] = xmin;
        out_xywh[1] = ymin;
        int64_t w = (int64_t)xmax - (int64_t)xmin + 1;
        int64_t h = (int64_t)ymax - (int64_t)ymin + 1;
        out_xywh[2] = w > INT32_MAX ? INT32_MAX : (int32_t)w;
        out_xywh[3] = h > INT32_MAX ? INT32_MAX : (int32_t)h;
    } else {
        const float *fp = (const float *)pts;
        double xmin = (double)fp[0], xmax = xmin, ymin = (double)fp[1], ymax = ymin;
        for (int32_t i = 1; i < n; i++) {
            double x = (double)fp[(size_t)i * 2];
            double y = (double)fp[(size_t)i * 2 + 1];
            if (x < xmin) xmin = x;
            if (x > xmax) xmax = x;
            if (y < ymin) ymin = y;
            if (y > ymax) ymax = y;
        }
        int32_t ix0 = (int32_t)floor(xmin);
        int32_t iy0 = (int32_t)floor(ymin);
        int32_t ix1 = (int32_t)floor(xmax);
        int32_t iy1 = (int32_t)floor(ymax);
        out_xywh[0] = ix0;
        out_xywh[1] = iy0;
        out_xywh[2] = ix1 - ix0 + 1;
        out_xywh[3] = iy1 - iy0 + 1;
    }
    return 0;
}

int32_t sr_c_p4_bounding_rect_img(const uint8_t *img, int32_t w, int32_t h, int32_t stride, int32_t *out_xywh) {
    if (!out_xywh || w < 0 || h < 0 || (w > 0 && h > 0 && !img)) return -1;
    int32_t xmin = w, xmax = -1, ymin = h, ymax = -1;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *row = img + (size_t)y * (size_t)stride;
        for (int32_t x = 0; x < w; x++) {
            if (row[x] != 0) {
                if (x < xmin) xmin = x;
                if (x > xmax) xmax = x;
                if (y < ymin) ymin = y;
                if (y > ymax) ymax = y;
            }
        }
    }
    if (xmax < xmin) {
        out_xywh[0] = 0; out_xywh[1] = 0; out_xywh[2] = 0; out_xywh[3] = 0;
    } else {
        out_xywh[0] = xmin;
        out_xywh[1] = ymin;
        out_xywh[2] = xmax - xmin + 1;
        out_xywh[3] = ymax - ymin + 1;
    }
    return 0;
}

int32_t sr_c_p4_contour_area(const void *pts, int32_t n, int32_t is_f32, int32_t oriented, double *out_area) {
    if (!out_area || n < 0 || (n > 0 && !pts)) return -1;
    if (n < 3) {
        *out_area = 0.0;
        return 0;
    }
    double a00 = 0.0;
    sr_pt2d prev = sr_load_pt(pts, n - 1, is_f32);
    for (int32_t i = 0; i < n; i++) {
        sr_pt2d cur = sr_load_pt(pts, i, is_f32);
        a00 += prev.x * cur.y - prev.y * cur.x;
        prev = cur;
    }
    a00 *= 0.5;
    *out_area = oriented ? a00 : fabs(a00);
    return 0;
}

int32_t sr_c_p4_is_contour_convex(const void *pts, int32_t n, int32_t is_f32, int32_t *out_convex) {
    if (!out_convex || n < 0 || (n > 0 && !pts)) return -1;
    if (n < 3) {
        *out_convex = 0;
        return 0;
    }
    sr_pt2d prev_pt = sr_load_pt(pts, n - 2, is_f32);
    sr_pt2d cur_pt = sr_load_pt(pts, n - 1, is_f32);
    double dx0 = cur_pt.x - prev_pt.x;
    double dy0 = cur_pt.y - prev_pt.y;
    int orientation = 0;
    for (int32_t i = 0; i < n; i++) {
        sr_pt2d next_pt = sr_load_pt(pts, i, is_f32);
        double dx = next_pt.x - cur_pt.x;
        double dy = next_pt.y - cur_pt.y;
        double cross = dx0 * dy - dy0 * dx;
        if (cross == 0.0) {
            *out_convex = 0;
            return 0;
        }
        int s = (cross > 0.0) ? 1 : -1;
        if (orientation == 0) {
            orientation = s;
        } else if (orientation != s) {
            *out_convex = 0;
            return 0;
        }
        dx0 = dx;
        dy0 = dy;
        cur_pt = next_pt;
    }
    *out_convex = 1;
    return 0;
}

// ---------------------------------------------------------------------------
// Convex Hull (Monotone Chain with strict collinearity removal + winding parity)
// ---------------------------------------------------------------------------

static int cmp_pt_idx_xy(const void *a, const void *b) {
    const sr_pt_idx *pa = (const sr_pt_idx *)a;
    const sr_pt_idx *pb = (const sr_pt_idx *)b;
    if (pa->x < pb->x) return -1;
    if (pa->x > pb->x) return 1;
    if (pa->y < pb->y) return -1;
    if (pa->y > pb->y) return 1;
    return (pa->idx < pb->idx) ? -1 : ((pa->idx > pb->idx) ? 1 : 0);
}

static int32_t hull_compute(const void *pts, int32_t n, int32_t is_f32, int32_t clockwise, int32_t *out_idx, int32_t *out_k) {
    if (n <= 0) {
        *out_k = 0;
        return 0;
    }
    if (n == 1) {
        out_idx[0] = 0;
        *out_k = 1;
        return 0;
    }
    sr_pt_idx *arr = (sr_pt_idx *)malloc((size_t)n * sizeof(sr_pt_idx));
    int32_t *hull = (int32_t *)malloc((size_t)(n + 1) * 2 * sizeof(int32_t));
    if (!arr || !hull) {
        free(arr);
        free(hull);
        return -4;
    }
    for (int32_t i = 0; i < n; i++) {
        sr_pt2d p = sr_load_pt(pts, i, is_f32);
        arr[i].x = p.x;
        arr[i].y = p.y;
        arr[i].idx = i;
    }
    qsort(arr, (size_t)n, sizeof(sr_pt_idx), cmp_pt_idx_xy);
    // Deduplicate exact (x, y) keeping first index
    int32_t m = 0;
    for (int32_t i = 0; i < n; i++) {
        if (m == 0 || arr[i].x != arr[m - 1].x || arr[i].y != arr[m - 1].y) {
            arr[m++] = arr[i];
        }
    }
    if (m == 1) {
        out_idx[0] = arr[0].idx;
        *out_k = 1;
        free(arr);
        free(hull);
        return 0;
    }
    if (m == 2) {
        if (clockwise) {
            out_idx[0] = arr[0].idx;
            out_idx[1] = arr[1].idx;
        } else {
            out_idx[0] = arr[1].idx;
            out_idx[1] = arr[0].idx;
        }
        *out_k = 2;
        free(arr);
        free(hull);
        return 0;
    }

    int32_t k = 0;
    // Lower hull (CCW in standard xy, i.e., cross > 0)
    for (int32_t i = 0; i < m; i++) {
        while (k >= 2) {
            sr_pt2d a = {arr[hull[k - 2]].x, arr[hull[k - 2]].y};
            sr_pt2d b = {arr[hull[k - 1]].x, arr[hull[k - 1]].y};
            sr_pt2d c = {arr[i].x, arr[i].y};
            if (sr_cross3(a, b, c) <= 0.0) k--;
            else break;
        }
        hull[k++] = i;
    }
    // Upper hull
    int32_t t = k + 1;
    for (int32_t i = m - 2; i >= 0; i--) {
        while (k >= t) {
            sr_pt2d a = {arr[hull[k - 2]].x, arr[hull[k - 2]].y};
            sr_pt2d b = {arr[hull[k - 1]].x, arr[hull[k - 1]].y};
            sr_pt2d c = {arr[i].x, arr[i].y};
            if (sr_cross3(a, b, c) <= 0.0) k--;
            else break;
        }
        hull[k++] = i;
    }
    k--; // remove duplicate start/end point

    if (k == 2 && !clockwise) {
        // Match OpenCV 2-point collinear ordering [max, min]
        out_idx[0] = arr[hull[1]].idx;
        out_idx[1] = arr[hull[0]].idx;
    } else if (!clockwise) {
        for (int32_t i = 0; i < k; i++) out_idx[i] = arr[hull[i]].idx;
    } else {
        for (int32_t i = 0; i < k; i++) out_idx[i] = arr[hull[k - 1 - i]].idx;
    }
    *out_k = k;
    free(arr);
    free(hull);
    return 0;
}

int32_t sr_c_p4_convex_hull(const void *pts, int32_t n, int32_t is_f32, int32_t clockwise, int32_t *out_idx, int32_t *out_k) {
    if (!out_k || n < 0 || (n > 0 && (!pts || !out_idx))) return -1;
    return hull_compute(pts, n, is_f32, clockwise, out_idx, out_k);
}

// ---------------------------------------------------------------------------
// Convexity Defects
// ---------------------------------------------------------------------------

int32_t sr_c_p4_convexity_defects(const int32_t *pts, int32_t n, const int32_t *hull, int32_t h,
                                  int32_t *out_defects, int32_t *out_k) {
    if (!out_k || n < 0 || h < 0 || (n > 0 && !pts) || (h > 0 && !hull)) return -1;
    *out_k = 0;
    if (n <= 3 || h < 3) return 0;

    for (int32_t i = 0; i < h; i++) {
        if (hull[i] < 0 || hull[i] >= n) return -1;
    }

    int32_t rev_orientation = 0;
    int32_t inc_wraps = 0, dec_wraps = 0;
    for (int32_t i = 0; i < h; i++) {
        int32_t a = hull[i], b = hull[(i + 1) % h];
        if (a == b) return -1;
        if (a > b) inc_wraps++;
        if (a < b) dec_wraps++;
    }
    if (inc_wraps == 1) {
        rev_orientation = 0;
    } else if (dec_wraps == 1) {
        rev_orientation = 1;
    } else {
        return -1; // self-intersecting / non-monotonic hull indices
    }

    int32_t count = 0;
    int32_t h_idx = rev_orientation ? (h - 1) : 0;
    int32_t h_step = rev_orientation ? -1 : 1;
    int32_t start = hull[h_idx];

    for (int32_t i = 0; i < h; i++) {
        h_idx = (h_idx + h_step + h) % h;
        int32_t end = hull[h_idx];

        double sx = (double)pts[(size_t)start * 2];
        double sy = (double)pts[(size_t)start * 2 + 1];
        double ex = (double)pts[(size_t)end * 2];
        double ey = (double)pts[(size_t)end * 2 + 1];
        double dx = ex - sx;
        double dy = ey - sy;
        double len = hypot(dx, dy);
        double scale = (len > 0.0) ? (1.0 / len) : 0.0;

        double max_depth = 0.0;
        int32_t farthest = start;
        int32_t cur = (start + 1) % n;
        while (cur != end) {
            double px = (double)pts[(size_t)cur * 2];
            double py = (double)pts[(size_t)cur * 2 + 1];
            double depth;
            if (scale == 0.0) {
                depth = hypot(px - sx, py - sy);
            } else {
                depth = fabs((px - sx) * (-dy) + (py - sy) * dx) * scale;
            }
            if (depth > max_depth) {
                max_depth = depth;
                farthest = cur;
            }
            cur = (cur + 1) % n;
        }
        int32_t fixpt = sr_round_d(max_depth * 256.0);
        if (fixpt > 0) {
            out_defects[(size_t)count * 4 + 0] = start;
            out_defects[(size_t)count * 4 + 1] = end;
            out_defects[(size_t)count * 4 + 2] = farthest;
            out_defects[(size_t)count * 4 + 3] = fixpt;
            count++;
        }
        start = end;
    }
    *out_k = count;
    return 0;
}

// ---------------------------------------------------------------------------
// minAreaRect & boxPoints (OpenCV 5.1 convention: angle in [-90, 0))
// ---------------------------------------------------------------------------

static void normalize_rot_rect_cv51(double *w, double *h, double *angle) {
    while (*angle >= 0.0) {
        *angle -= 90.0;
        double tmp = *w; *w = *h; *h = tmp;
    }
    while (*angle < -90.0) {
        *angle += 90.0;
        double tmp = *w; *w = *h; *h = tmp;
    }
}

int32_t sr_c_p4_min_area_rect(const void *pts, int32_t n, int32_t is_f32, float *out5) {
    if (!out5 || n < 0 || (n > 0 && !pts)) return -1;
    if (n == 0) {
        out5[0] = 0.0f; out5[1] = 0.0f; out5[2] = 0.0f; out5[3] = 0.0f; out5[4] = -90.0f;
        return 0;
    }
    int32_t *hull_idx = (int32_t *)malloc((size_t)n * sizeof(int32_t));
    if (!hull_idx) return -4;
    int32_t k = 0;
    int32_t rc = hull_compute(pts, n, is_f32, 0, hull_idx, &k);
    if (rc != 0) { free(hull_idx); return rc; }

    if (k == 1) {
        sr_pt2d p = sr_load_pt(pts, hull_idx[0], is_f32);
        out5[0] = (float)p.x; out5[1] = (float)p.y;
        out5[2] = 0.0f; out5[3] = 0.0f; out5[4] = -90.0f;
        free(hull_idx);
        return 0;
    }
    if (k == 2) {
        sr_pt2d p0 = sr_load_pt(pts, hull_idx[0], is_f32);
        sr_pt2d p1 = sr_load_pt(pts, hull_idx[1], is_f32);
        double cx = 0.5 * (p0.x + p1.x);
        double cy = 0.5 * (p0.y + p1.y);
        double dx = p1.x - p0.x, dy = p1.y - p0.y;
        double w = hypot(dx, dy), h = 0.0;
        double ang = atan2(dy, dx) * (180.0 / M_PI);
        normalize_rot_rect_cv51(&w, &h, &ang);
        out5[0] = (float)cx; out5[1] = (float)cy;
        out5[2] = (float)w; out5[3] = (float)h; out5[4] = (float)ang;
        free(hull_idx);
        return 0;
    }

    sr_pt2d *hp = (sr_pt2d *)malloc((size_t)k * sizeof(sr_pt2d));
    if (!hp) { free(hull_idx); return -4; }
    for (int32_t i = 0; i < k; i++) hp[i] = sr_load_pt(pts, hull_idx[i], is_f32);
    free(hull_idx);

    // Rotating calipers on CCW convex polygon hp[0..k-1]
    double best_area = DBL_MAX;
    double best_cx = 0.0, best_cy = 0.0, best_w = 0.0, best_h = 0.0, best_ang = -90.0;

    // Initialize extreme indices: i_min_x, i_max_x, i_max_y (for edge 0 -> 1 we compute directly or track calipers)
    // Find initial projections along edge 0
    int32_t i_right = 0, i_top = 0, i_left = 0;
    {
        sr_pt2d e = {hp[1].x - hp[0].x, hp[1].y - hp[0].y};
        double len = hypot(e.x, e.y);
        double ux = e.x / len, uy = e.y / len;
        double vx = -uy, vy = ux;
        double min_u = DBL_MAX, max_u = -DBL_MAX, max_v = -DBL_MAX;
        for (int32_t j = 0; j < k; j++) {
            double u = hp[j].x * ux + hp[j].y * uy;
            double v = hp[j].x * vx + hp[j].y * vy;
            if (u >= max_u) { max_u = u; i_right = j; }
            if (u <= min_u) { min_u = u; i_left = j; }
            if (v >= max_v) { max_v = v; i_top = j; }
        }
    }

    for (int32_t i = 0; i < k; i++) {
        int32_t ni = (i + 1) % k;
        double ex = hp[ni].x - hp[i].x, ey = hp[ni].y - hp[i].y;
        double elen = hypot(ex, ey);
        if (elen == 0.0) continue;
        double ux = ex / elen, uy = ey / elen;
        double vx = -uy, vy = ux;

        while (1) {
            int32_t nxt = (i_right + 1) % k;
            double u0 = hp[i_right].x * ux + hp[i_right].y * uy;
            double u1 = hp[nxt].x * ux + hp[nxt].y * uy;
            if (u1 >= u0 - 1e-12 && nxt != i_left) {
                if (u1 > u0) i_right = nxt;
                else break;
            } else break;
        }
        // Safeguard with local advance if needed
        while ((hp[(i_right + 1) % k].x * ux + hp[(i_right + 1) % k].y * uy) >
               (hp[i_right].x * ux + hp[i_right].y * uy)) {
            i_right = (i_right + 1) % k;
        }
        while ((hp[(i_top + 1) % k].x * vx + hp[(i_top + 1) % k].y * vy) >
               (hp[i_top].x * vx + hp[i_top].y * vy)) {
            i_top = (i_top + 1) % k;
        }
        while ((hp[(i_left + 1) % k].x * ux + hp[(i_left + 1) % k].y * uy) <
               (hp[i_left].x * ux + hp[i_left].y * uy)) {
            i_left = (i_left + 1) % k;
        }

        double min_u = hp[i_left].x * ux + hp[i_left].y * uy;
        double max_u = hp[i_right].x * ux + hp[i_right].y * uy;
        double min_v = hp[i].x * vx + hp[i].y * vy;
        double max_v = hp[i_top].x * vx + hp[i_top].y * vy;
        double w = max_u - min_u;
        double h = max_v - min_v;
        if (w < 0.0) w = 0.0;
        if (h < 0.0) h = 0.0;
        double area = w * h;
        if (area < best_area) {
            best_area = area;
            double cu = 0.5 * (min_u + max_u);
            double cv = 0.5 * (min_v + max_v);
            best_cx = cu * ux + cv * vx;
            best_cy = cu * uy + cv * vy;
            best_w = w;
            best_h = h;
            best_ang = atan2(uy, ux) * (180.0 / M_PI);
        }
    }

    // If polygon had near-collinear quirks with calipers, verify exact O(k) sweep wasn't misaligned for k <= 128
    if (k <= 128) {
        for (int32_t i = 0; i < k; i++) {
            int32_t ni = (i + 1) % k;
            double ex = hp[ni].x - hp[i].x, ey = hp[ni].y - hp[i].y;
            double elen = hypot(ex, ey);
            if (elen == 0.0) continue;
            double ux = ex / elen, uy = ey / elen;
            double vx = -uy, vy = ux;
            double min_u = DBL_MAX, max_u = -DBL_MAX, min_v = DBL_MAX, max_v = -DBL_MAX;
            for (int32_t j = 0; j < k; j++) {
                double u = hp[j].x * ux + hp[j].y * uy;
                double v = hp[j].x * vx + hp[j].y * vy;
                if (u < min_u) min_u = u;
                if (u > max_u) max_u = u;
                if (v < min_v) min_v = v;
                if (v > max_v) max_v = v;
            }
            double w = max_u - min_u, h = max_v - min_v;
            double area = w * h;
            if (area < best_area) {
                best_area = area;
                double cu = 0.5 * (min_u + max_u), cv = 0.5 * (min_v + max_v);
                best_cx = cu * ux + cv * vx;
                best_cy = cu * uy + cv * vy;
                best_w = w; best_h = h;
                best_ang = atan2(uy, ux) * (180.0 / M_PI);
            }
        }
    }

    normalize_rot_rect_cv51(&best_w, &best_h, &best_ang);
    out5[0] = (float)best_cx;
    out5[1] = (float)best_cy;
    out5[2] = (float)best_w;
    out5[3] = (float)best_h;
    out5[4] = (float)best_ang;
    free(hp);
    return 0;
}

int32_t sr_c_p4_box_points(float cx, float cy, float w, float h, float angle, float *out_pts8) {
    if (!out_pts8) return -1;
    double rad = (double)angle * (M_PI / 180.0);
    double b = cos(rad) * 0.5;
    double a = sin(rad) * 0.5;
    double dw = (double)w, dh = (double)h, dcx = (double)cx, dcy = (double)cy;
    double p0x = dcx - a * dh - b * dw;
    double p0y = dcy + b * dh - a * dw;
    double p1x = dcx + a * dh - b * dw;
    double p1y = dcy - b * dh - a * dw;
    out_pts8[0] = (float)p0x;
    out_pts8[1] = (float)p0y;
    out_pts8[2] = (float)p1x;
    out_pts8[3] = (float)p1y;
    out_pts8[4] = (float)(2.0 * dcx - p0x);
    out_pts8[5] = (float)(2.0 * dcy - p0y);
    out_pts8[6] = (float)(2.0 * dcx - p1x);
    out_pts8[7] = (float)(2.0 * dcy - p1y);
    return 0;
}

// ---------------------------------------------------------------------------
// minEnclosingCircle (Iterative Welzl in double)
// ---------------------------------------------------------------------------

typedef struct {
    double cx, cy, r;
} sr_circle_d;

static inline int in_circle(sr_circle_d c, sr_pt2d p) {
    double dx = p.x - c.cx, dy = p.y - c.cy;
    return dx * dx + dy * dy <= c.r * c.r * (1.0 + 1e-11) + 1e-12;
}

static sr_circle_d circle_2(sr_pt2d a, sr_pt2d b) {
    sr_circle_d c;
    c.cx = 0.5 * (a.x + b.x);
    c.cy = 0.5 * (a.y + b.y);
    c.r = 0.5 * hypot(a.x - b.x, a.y - b.y);
    return c;
}

static sr_circle_d circle_3(sr_pt2d a, sr_pt2d b, sr_pt2d c) {
    double A = b.x - a.x, B = b.y - a.y;
    double C = c.x - a.x, D = c.y - a.y;
    double E = A * (a.x + b.x) + B * (a.y + b.y);
    double F = C * (a.x + c.x) + D * (a.y + c.y);
    double G = 2.0 * (A * (c.y - b.y) - B * (c.x - b.x));
    if (fabs(G) < 1e-14) {
        sr_circle_d c1 = circle_2(a, b);
        sr_circle_d c2 = circle_2(b, c);
        sr_circle_d c3 = circle_2(a, c);
        sr_circle_d best = c1;
        if (c2.r > best.r) best = c2;
        if (c3.r > best.r) best = c3;
        return best;
    }
    sr_circle_d res;
    res.cx = (D * E - B * F) / G;
    res.cy = (A * F - C * E) / G;
    res.r = hypot(a.x - res.cx, a.y - res.cy);
    return res;
}

int32_t sr_c_p4_min_enclosing_circle(const void *pts, int32_t n, int32_t is_f32, float *out3) {
    if (!out3 || n < 0 || (n > 0 && !pts)) return -1;
    if (n == 0) {
        out3[0] = 0.0f; out3[1] = 0.0f; out3[2] = 0.0f;
        return 0;
    }
    sr_pt2d *p = (sr_pt2d *)malloc((size_t)n * sizeof(sr_pt2d));
    if (!p) return -4;
    for (int32_t i = 0; i < n; i++) p[i] = sr_load_pt(pts, i, is_f32);

    // Deterministic Fisher-Yates shuffle
    uint64_t rng = 0x9E3779B97F4A7C15ULL;
    for (int32_t i = n - 1; i > 0; i--) {
        rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27;
        uint64_t z = rng * 0x2545F4914F6CDD1DULL;
        int32_t j = (int32_t)(z % (uint64_t)(i + 1));
        sr_pt2d tmp = p[i]; p[i] = p[j]; p[j] = tmp;
    }

    sr_circle_d c = {p[0].x, p[0].y, 0.0};
    for (int32_t i = 1; i < n; i++) {
        if (in_circle(c, p[i])) continue;
        c.cx = p[i].x; c.cy = p[i].y; c.r = 0.0;
        for (int32_t j = 0; j < i; j++) {
            if (in_circle(c, p[j])) continue;
            c = circle_2(p[i], p[j]);
            for (int32_t k = 0; k < j; k++) {
                if (in_circle(c, p[k])) continue;
                c = circle_3(p[i], p[j], p[k]);
            }
        }
    }
    // OpenCV adds ~1e-4f safety tolerance so all points are strictly enclosed in f32
    double max_d = 0.0;
    for (int32_t i = 0; i < n; i++) {
        double d = hypot(p[i].x - c.cx, p[i].y - c.cy);
        if (d > max_d) max_d = d;
    }
    double r_out = max_d + 1e-4;
    out3[0] = (float)c.cx;
    out3[1] = (float)c.cy;
    out3[2] = (float)r_out;
    free(p);
    return 0;
}

// ---------------------------------------------------------------------------
// minEnclosingTriangle (O'Rourke / Stern flush-side rotating calipers)
// ---------------------------------------------------------------------------

static int line_intersect_d(sr_pt2d a1, sr_pt2d a2, sr_pt2d b1, sr_pt2d b2, sr_pt2d *out) {
    double dax = a2.x - a1.x, day = a2.y - a1.y;
    double dbx = b2.x - b1.x, dby = b2.y - b1.y;
    double denom = dax * dby - day * dbx;
    if (fabs(denom) < 1e-14) return 0;
    double t = ((b1.x - a1.x) * dby - (b1.y - a1.y) * dbx) / denom;
    out->x = a1.x + t * dax;
    out->y = a1.y + t * day;
    return 1;
}

static inline double tri_height(sr_pt2d p, sr_pt2d c1, sr_pt2d c2, double clen) {
    return fabs((c2.x - c1.x) * (p.y - c1.y) - (c2.y - c1.y) * (p.x - c1.x)) / clen;
}

static int valid_enclosing_tri(const sr_pt2d *hp, int32_t k, sr_pt2d t0, sr_pt2d t1, sr_pt2d t2, double *out_area) {
    double area = 0.5 * fabs(sr_cross3(t0, t1, t2));
    if (!isfinite(area) || area <= 0.0) return 0;
    double sign_tri = (sr_cross3(t0, t1, t2) >= 0.0) ? 1.0 : -1.0;
    double tol = 1e-6 * sqrt(area) + 1e-7;
    sr_pt2d tv[3] = {t0, t1, t2};
    for (int e = 0; e < 3; e++) {
        sr_pt2d ea = tv[e], eb = tv[(e + 1) % 3];
        double elen = hypot(eb.x - ea.x, eb.y - ea.y);
        if (elen <= 1e-12) return 0;
        for (int32_t i = 0; i < k; i++) {
            double sd = sr_cross3(ea, eb, hp[i]) * sign_tri / elen;
            if (sd < -tol) return 0;
        }
    }
    *out_area = area;
    return 1;
}

int32_t sr_c_p4_min_enclosing_triangle(const void *pts, int32_t n, int32_t is_f32, double *out_area, float *out_tri6) {
    if (!out_area || !out_tri6 || n < 0 || (n > 0 && !pts)) return -1;
    if (n == 0) {
        *out_area = 0.0;
        memset(out_tri6, 0, 6 * sizeof(float));
        return 0;
    }
    int32_t *hull_idx = (int32_t *)malloc((size_t)n * sizeof(int32_t));
    if (!hull_idx) return -4;
    int32_t k = 0;
    int32_t rc = hull_compute(pts, n, is_f32, 0, hull_idx, &k);
    if (rc != 0) { free(hull_idx); return rc; }

    if (k == 1) {
        sr_pt2d p = sr_load_pt(pts, hull_idx[0], is_f32);
        for (int i = 0; i < 3; i++) { out_tri6[i * 2] = (float)p.x; out_tri6[i * 2 + 1] = (float)p.y; }
        *out_area = 0.0;
        free(hull_idx);
        return 0;
    }
    if (k == 2) {
        sr_pt2d p0 = sr_load_pt(pts, hull_idx[0], is_f32);
        sr_pt2d p1 = sr_load_pt(pts, hull_idx[1], is_f32);
        out_tri6[0] = (float)p1.x; out_tri6[1] = (float)p1.y;
        out_tri6[2] = (float)p0.x; out_tri6[3] = (float)p0.y;
        out_tri6[4] = (float)p1.x; out_tri6[5] = (float)p1.y;
        *out_area = 0.0;
        free(hull_idx);
        return 0;
    }

    sr_pt2d *hp = (sr_pt2d *)malloc((size_t)k * sizeof(sr_pt2d));
    if (!hp) { free(hull_idx); return -4; }
    for (int32_t i = 0; i < k; i++) hp[i] = sr_load_pt(pts, hull_idx[i], is_f32);
    free(hull_idx);

    if (k == 3) {
        *out_area = 0.5 * fabs(sr_cross3(hp[0], hp[1], hp[2]));
        for (int i = 0; i < 3; i++) { out_tri6[i * 2] = (float)hp[i].x; out_tri6[i * 2 + 1] = (float)hp[i].y; }
        free(hp);
        return 0;
    }

    // O'Rourke (1986) minimum enclosing triangle: every minimum enclosing triangle has at least 2 flush sides
    // OR 1 flush side C + side A & side B midpoint-tangent to vertices p[a], p[b].
    // Check flush-edge + vertex-midpoint candidates cleanly in O(k) via two pointers (or O(k^2) fallback for small k).
    double best_area = DBL_MAX;
    sr_pt2d best_tri[3] = {{0, 0}, {0, 0}, {0, 0}};

    // 1. Two-edge-flush + third-edge-tangent (all O(k) pairs where two edges enclose the polygon)
    // Using two pointers b_mid and a_mid advancing around the CCW hull per base edge c = (hp[c_prev], hp[c]):
    int32_t a = 2, b = 1;
    for (int32_t c = 0; c < k; c++) {
        int32_t c_prev = (c + k - 1) % k;
        sr_pt2d C1 = hp[c_prev], C2 = hp[c];
        double clen = hypot(C2.x - C1.x, C2.y - C1.y);
        if (clen < 1e-12) continue;

        // Advance b to maximize height along right chain before descending
        if (b == c || b == c_prev) b = (c + 1) % k;
        while (1) {
            int32_t nb = (b + 1) % k;
            if (nb == c_prev) break;
            if (tri_height(hp[nb], C1, C2, clen) >= tri_height(hp[b], C1, C2, clen)) {
                b = nb;
            } else {
                break;
            }
        }
        // Scan/advance a from b outward on the descending left chain:
        // Also find exact apex height vertex top_idx = b (maximum height from C).
        int32_t top = b;
        double h_top = tri_height(hp[top], C1, C2, clen);
        if (a == c_prev || a == c) a = (top + 1) % k;

        // Candidate family 1: side C flush, side A flush with edge (hp[ai-1], hp[ai]), side B tangent with midpoint at hp[bi] or flush!
        // With midpoint condition: for flush side A, Apex height = 2 * height(hp[bi]) OR for flush side B, Apex height = 2 * height(hp[ai]).
        // Find ai where height(hp[ai]) is near 0.5*h_top on left chain and bi on right chain.
        double half_h = 0.5 * h_top;
        // Walk local window around half_h on both chains (since height is unimodal, binary/local walk is O(log k) or O(k) total!)
        // Left chain: top -> c_prev (height decreases from h_top to 0)
        // Right chain: c -> top (height increases from 0 to h_top)
        int32_t left_steps = (c_prev - top + k) % k;
        int32_t right_steps = (top - c + k) % k;

        // Binary search on left chain for first vertex with height <= half_h
        int32_t lo = 0, hi = left_steps;
        while (lo < hi) {
            int32_t mid = (lo + hi) / 2;
            int32_t idx = (top + mid) % k;
            if (tri_height(hp[idx], C1, C2, clen) > half_h) lo = mid + 1;
            else hi = mid;
        }
        int32_t a_cand = (top + lo) % k;

        // Binary search on right chain for first vertex with height >= half_h
        lo = 0; hi = right_steps;
        while (lo < hi) {
            int32_t mid = (lo + hi) / 2;
            int32_t idx = (c + mid) % k;
            if (tri_height(hp[idx], C1, C2, clen) < half_h) lo = mid + 1;
            else hi = mid;
        }
        int32_t b_cand = (c + lo) % k;

        // Test local neighborhood of (a_cand, b_cand) for:
        //  (i) A flush + B midpoint at b_idx
        //  (ii) B flush + A midpoint at a_idx
        //  (iii) A flush + B flush
        double ux = (C2.x - C1.x) / clen, uy = (C2.y - C1.y) / clen;
        double nx = -uy, ny = ux;
        if (sr_cross3(C1, C2, hp[top]) < 0.0) { nx = -nx; ny = -ny; }

        for (int da = -2; da <= 2; da++) {
            int32_t ai = (a_cand + da + k) % k;
            int32_t ai_prev = (ai + k - 1) % k;
            sr_pt2d A1 = hp[ai_prev], A2 = hp[ai];
            double ha = tri_height(hp[ai], C1, C2, clen);

            for (int db = -2; db <= 2; db++) {
                int32_t bi = (b_cand + db + k) % k;
                int32_t bi_next = (bi + 1) % k;
                sr_pt2d B1 = hp[bi], B2 = hp[bi_next];
                double hb = tri_height(hp[bi], C1, C2, clen);

                sr_pt2d va, vb, vc;
                double area;

                // (i) A flush (line A1-A2), B midpoint at hp[bi] => apex on A at height 2*hb
                if (hb > 1e-12 && line_intersect_d(C1, C2, A1, A2, &vc)) {
                    sr_pt2d hline1 = {C1.x + 2.0 * hb * nx, C1.y + 2.0 * hb * ny};
                    sr_pt2d hline2 = {C2.x + 2.0 * hb * nx, C2.y + 2.0 * hb * ny};
                    if (line_intersect_d(A1, A2, hline1, hline2, &va)) {
                        if (line_intersect_d(C1, C2, va, hp[bi], &vb)) {
                            if (valid_enclosing_tri(hp, k, va, vb, vc, &area) && area < best_area) {
                                best_area = area; best_tri[0] = va; best_tri[1] = vb; best_tri[2] = vc;
                            }
                        }
                    }
                }
                // (ii) B flush (line B1-B2), A midpoint at hp[ai] => apex on B at height 2*ha
                if (ha > 1e-12 && line_intersect_d(C1, C2, B1, B2, &vb)) {
                    sr_pt2d hline1 = {C1.x + 2.0 * ha * nx, C1.y + 2.0 * ha * ny};
                    sr_pt2d hline2 = {C2.x + 2.0 * ha * nx, C2.y + 2.0 * ha * ny};
                    if (line_intersect_d(B1, B2, hline1, hline2, &va)) {
                        if (line_intersect_d(C1, C2, va, hp[ai], &vc)) {
                            if (valid_enclosing_tri(hp, k, va, vb, vc, &area) && area < best_area) {
                                best_area = area; best_tri[0] = va; best_tri[1] = vb; best_tri[2] = vc;
                            }
                        }
                    }
                }
                // (iii) Both A and B flush with edges
                if (line_intersect_d(C1, C2, A1, A2, &vc) &&
                    line_intersect_d(C1, C2, B1, B2, &vb) &&
                    line_intersect_d(A1, A2, B1, B2, &va)) {
                    if (valid_enclosing_tri(hp, k, va, vb, vc, &area) && area < best_area) {
                        best_area = area; best_tri[0] = va; best_tri[1] = vb; best_tri[2] = vc;
                    }
                }
            }
        }
    }

    // Fallback: if numeric degeneracy prevented finding a valid candidate, check all 3-edge triples for small k
    if (best_area == DBL_MAX) {
        for (int32_t i = 0; i < k; i++) {
            for (int32_t j = i + 1; j < k; j++) {
                for (int32_t l = j + 1; l < k; l++) {
                    sr_pt2d va, vb, vc;
                    sr_pt2d A1 = hp[(i + k - 1) % k], A2 = hp[i];
                    sr_pt2d B1 = hp[(j + k - 1) % k], B2 = hp[j];
                    sr_pt2d C1 = hp[(l + k - 1) % k], C2 = hp[l];
                    if (line_intersect_d(A1, A2, B1, B2, &va) &&
                        line_intersect_d(B1, B2, C1, C2, &vb) &&
                        line_intersect_d(C1, C2, A1, A2, &vc)) {
                        double area;
                        if (valid_enclosing_tri(hp, k, va, vb, vc, &area) && area < best_area) {
                            best_area = area; best_tri[0] = va; best_tri[1] = vb; best_tri[2] = vc;
                        }
                    }
                }
            }
        }
    }

    if (best_area == DBL_MAX) {
        *out_area = 0.0;
        memset(out_tri6, 0, 6 * sizeof(float));
    } else {
        *out_area = best_area;
        for (int i = 0; i < 3; i++) {
            out_tri6[i * 2] = (float)best_tri[i].x;
            out_tri6[i * 2 + 1] = (float)best_tri[i].y;
        }
    }
    free(hp);
    return 0;
}

// ---------------------------------------------------------------------------
// Linear Algebra helpers for fitEllipse* and fitLine (pure C11 Jacobi + Gauss)
// ---------------------------------------------------------------------------

// Jacobi symmetric eigensolver for N x N matrix A (row-major, N <= 8).
// Returns ascending eigenvalues evals[0..N-1] and eigenvectors as columns of V (row-major).
static void jacobi_sym(int32_t N, double *A, double *evals, double *V) {
    for (int32_t i = 0; i < N; i++) {
        for (int32_t j = 0; j < N; j++) V[i * N + j] = (i == j) ? 1.0 : 0.0;
    }
    for (int iter = 0; iter < 100; iter++) {
        double max_off = 0.0;
        int32_t p = 0, q = 1;
        for (int32_t i = 0; i < N; i++) {
            for (int32_t j = i + 1; j < N; j++) {
                double v = fabs(A[i * N + j]);
                if (v > max_off) { max_off = v; p = i; q = j; }
            }
        }
        if (max_off < 1e-15) break;
        double app = A[p * N + p], aqq = A[q * N + q], apq = A[p * N + q];
        double tau = (aqq - app) / (2.0 * apq);
        double t = (tau >= 0.0) ? (1.0 / (tau + sqrt(1.0 + tau * tau)))
                                : (-1.0 / (-tau + sqrt(1.0 + tau * tau)));
        double c = 1.0 / sqrt(1.0 + t * t);
        double s = t * c;
        A[p * N + p] = app - t * apq;
        A[q * N + q] = aqq + t * apq;
        A[p * N + q] = 0.0;
        A[q * N + p] = 0.0;
        for (int32_t r = 0; r < N; r++) {
            if (r == p || r == q) continue;
            double arp = A[r * N + p], arq = A[r * N + q];
            A[r * N + p] = A[p * N + r] = c * arp - s * arq;
            A[r * N + q] = A[q * N + r] = s * arp + c * arq;
        }
        for (int32_t r = 0; r < N; r++) {
            double vrp = V[r * N + p], vrq = V[r * N + q];
            V[r * N + p] = c * vrp - s * vrq;
            V[r * N + q] = s * vrp + c * vrq;
        }
    }
    for (int32_t i = 0; i < N; i++) evals[i] = A[i * N + i];
    // Sort ascending
    for (int32_t i = 0; i < N - 1; i++) {
        int32_t min_j = i;
        for (int32_t j = i + 1; j < N; j++) if (evals[j] < evals[min_j]) min_j = j;
        if (min_j != i) {
            double te = evals[i]; evals[i] = evals[min_j]; evals[min_j] = te;
            for (int32_t r = 0; r < N; r++) {
                double tv = V[r * N + i]; V[r * N + i] = V[r * N + min_j]; V[r * N + min_j] = tv;
            }
        }
    }
}

// Symmetric pseudoinverse least-squares solve for N x N (A x = b) via eigendecomposition
static void sym_pinv_solve(int32_t N, const double *A_in, const double *b, double *x) {
    double A[64], evals[8], V[64];
    memcpy(A, A_in, (size_t)(N * N) * sizeof(double));
    jacobi_sym(N, A, evals, V);
    double max_abs = 0.0;
    for (int32_t i = 0; i < N; i++) if (fabs(evals[i]) > max_abs) max_abs = fabs(evals[i]);
    double tol = max_abs * 1e-12;
    double vt_b[8];
    for (int32_t i = 0; i < N; i++) {
        double s = 0.0;
        for (int32_t r = 0; r < N; r++) s += V[r * N + i] * b[r];
        vt_b[i] = (fabs(evals[i]) > tol) ? (s / evals[i]) : 0.0;
    }
    for (int32_t r = 0; r < N; r++) {
        double s = 0.0;
        for (int32_t i = 0; i < N; i++) s += V[r * N + i] * vt_b[i];
        x[r] = s;
    }
}

// ---------------------------------------------------------------------------
// fitEllipse, fitEllipseAMS, fitEllipseDirect
// ---------------------------------------------------------------------------

static int conic_to_rotated_rect(double a, double b, double c, double d, double e, double f,
                                 double mx, double my, float *out5) {
    double disc = b * b - 4.0 * a * c;
    if (fabs(disc) < 1e-18) return 0;
    double cx_rel = (2.0 * c * d - b * e) / disc;
    double cy_rel = (2.0 * a * e - b * d) / disc;
    double theta = 0.5 * atan2(b, a - c); // radians
    double ct = cos(theta), st = sin(theta);
    double ap = a * ct * ct + b * ct * st + c * st * st;
    double cp = a * st * st - b * ct * st + c * ct * ct;
    double f_c = a * cx_rel * cx_rel + b * cx_rel * cy_rel + c * cy_rel * cy_rel +
                 d * cx_rel + e * cy_rel + f;
    double num = -f_c;
    double rx2 = (fabs(ap) > 1e-18) ? (num / ap) : 0.0;
    double ry2 = (fabs(cp) > 1e-18) ? (num / cp) : 0.0;
    if (rx2 <= 0.0 || ry2 <= 0.0) return 0;
    double rx = sqrt(rx2), ry = sqrt(ry2);
    double w, h, major_ang_deg;
    if (rx >= ry) {
        w = 2.0 * ry;
        h = 2.0 * rx;
        major_ang_deg = theta * (180.0 / M_PI) + 90.0;
    } else {
        w = 2.0 * rx;
        h = 2.0 * ry;
        major_ang_deg = (theta + M_PI * 0.5) * (180.0 / M_PI) + 90.0;
    }
    while (major_ang_deg < 0.0) major_ang_deg += 180.0;
    while (major_ang_deg >= 180.0) major_ang_deg -= 180.0;
    out5[0] = (float)(cx_rel + mx);
    out5[1] = (float)(cy_rel + my);
    out5[2] = (float)w;
    out5[3] = (float)h;
    out5[4] = (float)major_ang_deg;
    return 1;
}

static void solve_3x3_eigenvector(const double M[3][3], double lambda, double out[3]) {
    // Solve (M - lambda I) v = 0 using cross product of two rows
    double A[3][3];
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) A[i][j] = M[i][j] - (i == j ? lambda : 0.0);
    }
    double best_n = -1.0;
    for (int r0 = 0; r0 < 3; r0++) {
        int r1 = (r0 + 1) % 3;
        double c0 = A[r0][1] * A[r1][2] - A[r0][2] * A[r1][1];
        double c1 = A[r0][2] * A[r1][0] - A[r0][0] * A[r1][2];
        double c2 = A[r0][0] * A[r1][1] - A[r0][1] * A[r1][0];
        double n2 = c0 * c0 + c1 * c1 + c2 * c2;
        if (n2 > best_n) {
            best_n = n2;
            out[0] = c0; out[1] = c1; out[2] = c2;
        }
    }
    double norm = sqrt(best_n);
    if (norm > 1e-18) {
        out[0] /= norm; out[1] /= norm; out[2] /= norm;
    }
}

int32_t sr_c_p4_fit_ellipse(const void *pts, int32_t n, int32_t is_f32, int32_t method, float *out5) {
    if (!out5 || n < 5 || !pts) return -1;
    double mx = 0.0, my = 0.0;
    for (int32_t i = 0; i < n; i++) {
        sr_pt2d p = sr_load_pt(pts, i, is_f32);
        mx += p.x; my += p.y;
    }
    mx /= (double)n;
    my /= (double)n;

    if (method == 0) {
        // fitEllipse (least squares A x^2 + B x y + C y^2 + D x + E y = -1)
        //Wait: OpenCV fitEllipseNoDirect solves A*x + B*y + C*x^2 + D*x*y + E*y^2 = 10000 or 1 via SVD, then falls back if needed
        double ATA[25] = {0}, ATb[5] = {0};
        for (int32_t i = 0; i < n; i++) {
            sr_pt2d p = sr_load_pt(pts, i, is_f32);
            double x = p.x - mx, y = p.y - my;
            double r[5] = {x * x, x * y, y * y, x, y};
            for (int a = 0; a < 5; a++) {
                ATb[a] -= r[a];
                for (int b = 0; b < 5; b++) ATA[a * 5 + b] += r[a] * r[b];
            }
        }
        double g[5] = {0};
        sym_pinv_solve(5, ATA, ATb, g);
        if (conic_to_rotated_rect(g[0], g[1], g[2], g[3], g[4], 1.0, mx, my, out5)) return 0;
        // Fallback: minAreaRect if algebraic conic is non-elliptic (e.g. collinear / hyperbolic)
        if (sr_c_p4_min_area_rect(pts, n, is_f32, out5) == 0) {
            if (out5[2] > out5[3]) {
                float tmp = out5[2]; out5[2] = out5[3]; out5[3] = tmp;
                out5[4] += 90.0f;
            }
            while (out5[4] < 0.0f) out5[4] += 180.0f;
            while (out5[4] >= 180.0f) out5[4] -= 180.0f;
            return 0;
        }
        return -1;
    }

    // Build 6x6 scatter matrix S = D^T D for D = [x^2, x y, y^2, x, y, 1]
    double S[6][6] = {{0}};
    double M_ams[5][5] = {{0}};
    for (int32_t i = 0; i < n; i++) {
        sr_pt2d p = sr_load_pt(pts, i, is_f32);
        double x = p.x - mx, y = p.y - my;
        double d[6] = {x * x, x * y, y * y, x, y, 1.0};
        for (int r = 0; r < 6; r++) {
            for (int c = 0; c < 6; c++) S[r][c] += d[r] * d[c];
        }
        if (method == 1) {
            // Taubin AMS gradient scatter: grad_x = [2x, y, 0, 1, 0], grad_y = [0, x, 2y, 0, 1]
            double gx[5] = {2.0 * x, y, 0.0, 1.0, 0.0};
            double gy[5] = {0.0, x, 2.0 * y, 0.0, 1.0};
            for (int r = 0; r < 5; r++) {
                for (int c = 0; c < 5; c++) M_ams[r][c] += gx[r] * gx[c] + gy[r] * gy[c];
            }
        }
    }

    if (method == 1) {
        // fitEllipseAMS (Taubin 1991): eliminate intercept f via Schur complement S_5 = S11 - s12 s12^T / n
        double S5[25], M5[25];
        double inv_n = 1.0 / (double)n;
        for (int r = 0; r < 5; r++) {
            for (int c = 0; c < 5; c++) {
                S5[r * 5 + c] = S[r][c] - S[r][5] * S[5][c] * inv_n;
                M5[r * 5 + c] = M_ams[r][c] * inv_n;
            }
        }
        // Solve S5 v = lambda M5 v: whiten M5 = U diag(lam) U^T -> B = D^{-1/2} U^T S5 U D^{-1/2}
        double Mcpy[25], meval[5], U[25];
        memcpy(Mcpy, M5, sizeof(Mcpy));
        jacobi_sym(5, Mcpy, meval, U);
        double invsqrt[5];
        double mmax = fabs(meval[4]);
        for (int i = 0; i < 5; i++) invsqrt[i] = (meval[i] > mmax * 1e-12) ? (1.0 / sqrt(meval[i])) : 0.0;
        double B[25] = {0};
        for (int i = 0; i < 5; i++) {
            for (int j = 0; j < 5; j++) {
                double sum = 0.0;
                for (int p = 0; p < 5; p++) {
                    for (int q = 0; q < 5; q++) {
                        sum += U[p * 5 + i] * S5[p * 5 + q] * U[q * 5 + j];
                    }
                }
                B[i * 5 + j] = sum * invsqrt[i] * invsqrt[j];
            }
        }
        double beval[5], W[25];
        jacobi_sym(5, B, beval, W);
        // Find eigenvector with smallest positive generalized eigenvalue that gives an ellipse (4ac - b^2 > 0)
        for (int col = 0; col < 5; col++) {
            if (meval[col] <= mmax * 1e-12) continue;
            double v[5] = {0};
            for (int r = 0; r < 5; r++) {
                double s = 0.0;
                for (int i = 0; i < 5; i++) s += U[r * 5 + i] * invsqrt[i] * W[i * 5 + col];
                v[r] = s;
            }
            double f = 0.0;
            for (int r = 0; r < 5; r++) f -= S[5][r] * v[r] * inv_n;
            if (4.0 * v[0] * v[2] - v[1] * v[1] > 0.0 &&
                conic_to_rotated_rect(v[0], v[1], v[2], v[3], v[4], f, mx, my, out5)) {
                return 0;
            }
        }
        // Fallback to standard fitEllipse if degenerate
        return sr_c_p4_fit_ellipse(pts, n, is_f32, 0, out5);
    }

    // method == 2: fitEllipseDirect (Halir & Flusser 1998)
    double S1[3][3], S2[3][3], S3[9];
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
            S1[r][c] = S[r][c];
            S2[r][c] = S[r][c + 3];
            S3[r * 3 + c] = S[r + 3][c + 3];
        }
    }
    // T = -S3^{-1} S2^T (3 cols)
    double T[3][3] = {{0}};
    for (int col = 0; col < 3; col++) {
        double rhs[3] = {-S2[col][0], -S2[col][1], -S2[col][2]};
        double sol[3] = {0};
        sym_pinv_solve(3, S3, rhs, sol);
        for (int r = 0; r < 3; r++) T[r][col] = sol[r];
    }
    // M = S1 + S2 * T
    double M[3][3];
    for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
            M[r][c] = S1[r][c] + S2[r][0] * T[0][c] + S2[r][1] * T[1][c] + S2[r][2] * T[2][c];
        }
    }
    // C1^{-1} * M
    double Mr[3][3] = {
        {0.5 * M[2][0], 0.5 * M[2][1], 0.5 * M[2][2]},
        {-M[1][0],     -M[1][1],     -M[1][2]},
        {0.5 * M[0][0], 0.5 * M[0][1], 0.5 * M[0][2]}
    };
    // Characteristic polynomial of 3x3 matrix Mr: det(lambda I - Mr) = lambda^3 - c2 lambda^2 + c1 lambda - c0
    double c2 = Mr[0][0] + Mr[1][1] + Mr[2][2];
    double c1 = (Mr[0][0] * Mr[1][1] - Mr[0][1] * Mr[1][0]) +
                (Mr[0][0] * Mr[2][2] - Mr[0][2] * Mr[2][0]) +
                (Mr[1][1] * Mr[2][2] - Mr[1][2] * Mr[2][1]);
    double c0 = Mr[0][0] * (Mr[1][1] * Mr[2][2] - Mr[1][2] * Mr[2][1]) -
                Mr[0][1] * (Mr[1][0] * Mr[2][2] - Mr[1][2] * Mr[2][0]) +
                Mr[0][2] * (Mr[1][0] * Mr[2][1] - Mr[1][1] * Mr[2][0]);
    // Solve depressed cubic t^3 + p t + q = 0 where lambda = t + c2/3
    double p_c = c1 - c2 * c2 / 3.0;
    double q_c = -2.0 * c2 * c2 * c2 / 27.0 + c1 * c2 / 3.0 - c0;
    double disc_c = 0.25 * q_c * q_c + (p_c * p_c * p_c) / 27.0;
    double roots[3];
    int n_roots = 0;
    if (disc_c <= 1e-12) {
        double r_c = (p_c < 0.0) ? sqrt(-p_c / 3.0) : 0.0;
        double arg = (r_c > 0.0) ? (-q_c / (2.0 * r_c * r_c * r_c)) : 0.0;
        if (arg > 1.0) arg = 1.0;
        if (arg < -1.0) arg = -1.0;
        double phi = acos(arg) / 3.0;
        roots[0] = 2.0 * r_c * cos(phi) + c2 / 3.0;
        roots[1] = 2.0 * r_c * cos(phi + 2.0 * M_PI / 3.0) + c2 / 3.0;
        roots[2] = 2.0 * r_c * cos(phi + 4.0 * M_PI / 3.0) + c2 / 3.0;
        n_roots = 3;
    } else {
        double sd = sqrt(disc_c);
        roots[0] = cbrt(-0.5 * q_c + sd) + cbrt(-0.5 * q_c - sd) + c2 / 3.0;
        n_roots = 1;
    }

    for (int ri = 0; ri < n_roots; ri++) {
        double evec[3] = {0};
        solve_3x3_eigenvector(Mr, roots[ri], evec);
        double cond = 4.0 * evec[0] * evec[2] - evec[1] * evec[1];
        if (cond > 1e-14) {
            double def[3] = {
                T[0][0] * evec[0] + T[0][1] * evec[1] + T[0][2] * evec[2],
                T[1][0] * evec[0] + T[1][1] * evec[1] + T[1][2] * evec[2],
                T[2][0] * evec[0] + T[2][1] * evec[1] + T[2][2] * evec[2]
            };
            if (conic_to_rotated_rect(evec[0], evec[1], evec[2], def[0], def[1], def[2], mx, my, out5)) {
                return 0;
            }
        }
    }
    return sr_c_p4_fit_ellipse(pts, n, is_f32, 0, out5);
}

// ---------------------------------------------------------------------------
// fitLine (2D and 3D; DIST_L2, L1, L12, FAIR, WELSCH, HUBER)
// ---------------------------------------------------------------------------

static double rho_dist(double r, int32_t dist_type, double param) {
    switch (dist_type) {
    case 1: return r; // DIST_L1
    case 4: return 2.0 * (sqrt(1.0 + 0.5 * r * r) - 1.0); // DIST_L12
    case 5: { double c = param; return c * c * (r / c - log(1.0 + r / c)); } // DIST_FAIR
    case 6: { double c = param; return 0.5 * c * c * (1.0 - exp(-(r * r) / (c * c))); } // DIST_WELSCH
    case 7: { double c = param; return (r <= c) ? (0.5 * r * r) : (c * (r - 0.5 * c)); } // DIST_HUBER
    default: return 0.5 * r * r; // DIST_L2
    }
}

static double weight_dist(double r, int32_t dist_type, double param) {
    switch (dist_type) {
    case 1: return 1.0 / (r > 1e-6 ? r : 1e-6);
    case 4: return 1.0 / sqrt(1.0 + 0.5 * r * r);
    case 5: return 1.0 / (1.0 + r / param);
    case 6: return exp(-(r * r) / (param * param));
    case 7: return (r <= param) ? 1.0 : (param / r);
    default: return 1.0;
    }
}

static void weighted_line_fit(const double *pts, int32_t n, int32_t dims, const double *w, double *line) {
    double sw = 0.0;
    double mean[3] = {0, 0, 0};
    for (int32_t i = 0; i < n; i++) {
        double wi = w ? w[i] : 1.0;
        sw += wi;
        for (int d = 0; d < dims; d++) mean[d] += wi * pts[(size_t)i * dims + d];
    }
    if (sw <= 1e-18) {
        sw = (double)n;
        mean[0] = mean[1] = mean[2] = 0.0;
        for (int32_t i = 0; i < n; i++) {
            for (int d = 0; d < dims; d++) mean[d] += pts[(size_t)i * dims + d];
        }
    }
    for (int d = 0; d < dims; d++) mean[d] /= sw;

    double cov[9] = {0};
    for (int32_t i = 0; i < n; i++) {
        double wi = w ? w[i] : 1.0;
        double dx[3] = {0, 0, 0};
        for (int d = 0; d < dims; d++) dx[d] = pts[(size_t)i * dims + d] - mean[d];
        for (int a = 0; a < dims; a++) {
            for (int b = 0; b < dims; b++) cov[a * dims + b] += wi * dx[a] * dx[b];
        }
    }
    double evals[3], V[9];
    jacobi_sym(dims, cov, evals, V);
    int top = dims - 1;
    double norm = 0.0;
    for (int d = 0; d < dims; d++) {
        line[d] = V[d * dims + top];
        norm += line[d] * line[d];
    }
    norm = sqrt(norm);
    if (norm > 1e-18) {
        for (int d = 0; d < dims; d++) line[d] /= norm;
    } else {
        line[0] = 1.0;
        for (int d = 1; d < dims; d++) line[d] = 0.0;
    }
    for (int d = 0; d < dims; d++) line[dims + d] = mean[d];
}

static double line_point_dist(const double *pt, int32_t dims, const double *line) {
    if (dims == 2) {
        return fabs((pt[0] - line[2]) * line[1] - (pt[1] - line[3]) * line[0]);
    }
    double dx = pt[0] - line[3], dy = pt[1] - line[4], dz = pt[2] - line[5];
    double dot = dx * line[0] + dy * line[1] + dz * line[2];
    double rx = dx - dot * line[0], ry = dy - dot * line[1], rz = dz - dot * line[2];
    return sqrt(rx * rx + ry * ry + rz * rz);
}

int32_t sr_c_p4_fit_line(const void *pts_in, int32_t n, int32_t dims, int32_t is_f32,
                         int32_t dist_type, double param, double reps, double aeps, float *out_line) {
    if (!pts_in || !out_line || n <= 0 || (dims != 2 && dims != 3)) return -1;
    if (dist_type != 2 && dist_type != 1 && dist_type != 4 &&
        dist_type != 5 && dist_type != 6 && dist_type != 7) return -2;

    if (param <= 0.0) {
        if (dist_type == 5) param = 1.3998;
        else if (dist_type == 6) param = 2.9846;
        else if (dist_type == 7) param = 1.345;
    }
    if (reps <= 0.0) reps = 1e-2;
    if (aeps <= 0.0) aeps = 1e-2;

    double *pts = (double *)malloc((size_t)n * (size_t)dims * sizeof(double));
    double *w = (double *)malloc((size_t)n * sizeof(double));
    if (!pts || !w) { free(pts); free(w); return -4; }

    if (is_f32) {
        const float *fp = (const float *)pts_in;
        for (size_t i = 0; i < (size_t)n * (size_t)dims; i++) pts[i] = (double)fp[i];
    } else {
        const int32_t *ip = (const int32_t *)pts_in;
        for (size_t i = 0; i < (size_t)n * (size_t)dims; i++) pts[i] = (double)ip[i];
    }

    double best_line[6] = {0};
    if (n == 1) {
        best_line[0] = 1.0;
        for (int d = 0; d < dims; d++) best_line[dims + d] = pts[d];
    } else if (dist_type == 2) {
        weighted_line_fit(pts, n, dims, NULL, best_line);
    } else {
        // Multi-start robust initialization (L2 + deterministic pairs) + IRLS
        double best_err = DBL_MAX;
        uint64_t rng = 0x123456789ABCDEF0ULL;
        int trials = (n <= 2) ? 1 : 20;
        for (int tr = 0; tr < trials; tr++) {
            double cur[6] = {0};
            if (tr == 0) {
                weighted_line_fit(pts, n, dims, NULL, cur);
            } else {
                rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27;
                int32_t i0 = (int32_t)((rng * 0x2545F4914F6CDD1DULL) % (uint64_t)n);
                rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27;
                int32_t i1 = (int32_t)((rng * 0x2545F4914F6CDD1DULL) % (uint64_t)n);
                if (i1 == i0) i1 = (i0 + 1) % n;
                double norm = 0.0;
                for (int d = 0; d < dims; d++) {
                    cur[d] = pts[(size_t)i1 * dims + d] - pts[(size_t)i0 * dims + d];
                    cur[dims + d] = 0.5 * (pts[(size_t)i0 * dims + d] + pts[(size_t)i1 * dims + d]);
                    norm += cur[d] * cur[d];
                }
                norm = sqrt(norm);
                if (norm < 1e-12) continue;
                for (int d = 0; d < dims; d++) cur[d] /= norm;
            }
            for (int it = 0; it < 30; it++) {
                double prev[6];
                memcpy(prev, cur, sizeof(prev));
                for (int32_t i = 0; i < n; i++) {
                    double r = line_point_dist(pts + (size_t)i * dims, dims, cur);
                    w[i] = weight_dist(r, dist_type, param);
                }
                weighted_line_fit(pts, n, dims, w, cur);
                double dot = 0.0;
                for (int d = 0; d < dims; d++) dot += cur[d] * prev[d];
                if (dot < 0.0) { for (int d = 0; d < dims; d++) cur[d] = -cur[d]; dot = -dot; }
                double ang_diff = (dot >= 1.0) ? 0.0 : acos(dot);
                double pos_diff = 0.0;
                for (int d = 0; d < dims; d++) {
                    double dd = cur[dims + d] - prev[dims + d];
                    pos_diff += dd * dd;
                }
                if (ang_diff < aeps && sqrt(pos_diff) < reps) break;
            }
            double err = 0.0;
            for (int32_t i = 0; i < n; i++) {
                err += rho_dist(line_point_dist(pts + (size_t)i * dims, dims, cur), dist_type, param);
            }
            if (err < best_err) {
                best_err = err;
                memcpy(best_line, cur, sizeof(best_line));
            }
        }
    }

    // Canonicalize direction sign (largest component or first non-zero > 0) for determinism
    if (best_line[0] < 0.0 || (best_line[0] == 0.0 && best_line[1] < 0.0)) {
        for (int d = 0; d < dims; d++) best_line[d] = -best_line[d];
    }
    for (int i = 0; i < 2 * dims; i++) out_line[i] = (float)best_line[i];
    free(pts);
    free(w);
    return 0;
}

// ---------------------------------------------------------------------------
// moments, HuMoments, matchShapes
// ---------------------------------------------------------------------------

static void finish_moments(double *m) {
    // m[0..9] = m00, m10, m01, m20, m11, m02, m30, m21, m12, m03
    // m[10..16] = mu20, mu11, mu02, mu30, mu21, mu12, mu03
    // m[17..23] = nu20, nu11, nu02, nu30, nu21, nu12, nu03
    double m00 = m[0];
    if (fabs(m00) <= DBL_EPSILON) {
        memset(m + 10, 0, 14 * sizeof(double));
        return;
    }
    double inv_m00 = 1.0 / m00;
    double cx = m[1] * inv_m00;
    double cy = m[2] * inv_m00;
    double cx2 = cx * cx, cy2 = cy * cy;

    double mu20 = m[3] - cx * m[1];
    double mu11 = m[4] - cx * m[2];
    double mu02 = m[5] - cy * m[2];

    double mu30 = m[6] - cx * (3.0 * mu20 + cx * m[1]);
    double mu03 = m[9] - cy * (3.0 * mu02 + cy * m[2]);
    double mu21 = m[7] - 2.0 * cx * m[4] - cy * m[3] + 2.0 * cx2 * m[2];
    double mu12 = m[8] - 2.0 * cy * m[4] - cx * m[5] + 2.0 * cy2 * m[1];

    m[10] = mu20; m[11] = mu11; m[12] = mu02;
    m[13] = mu30; m[14] = mu21; m[15] = mu12; m[16] = mu03;

    double inv_s2 = inv_m00 * inv_m00;
    double inv_s25 = inv_s2 * sqrt(fabs(inv_m00));
    m[17] = mu20 * inv_s2;
    m[18] = mu11 * inv_s2;
    m[19] = mu02 * inv_s2;
    m[20] = mu30 * inv_s25;
    m[21] = mu21 * inv_s25;
    m[22] = mu12 * inv_s25;
    m[23] = mu03 * inv_s25;
}

int32_t sr_c_p4_moments_pts(const void *pts, int32_t n, int32_t is_f32, double *out24) {
    if (!out24 || n < 0 || (n > 0 && !pts)) return -1;
    memset(out24, 0, 24 * sizeof(double));
    if (n < 3) return 0;

    double m00 = 0, m10 = 0, m01 = 0, m20 = 0, m11 = 0, m02 = 0, m30 = 0, m21 = 0, m12 = 0, m03 = 0;
    sr_pt2d p0 = sr_load_pt(pts, n - 1, is_f32);
    for (int32_t i = 0; i < n; i++) {
        sr_pt2d p1 = sr_load_pt(pts, i, is_f32);
        double x0 = p0.x, y0 = p0.y, x1 = p1.x, y1 = p1.y;
        double dxy = x0 * y1 - x1 * y0;
        m00 += dxy;
        m10 += (x0 + x1) * dxy;
        m01 += (y0 + y1) * dxy;
        m20 += (x0 * x0 + x0 * x1 + x1 * x1) * dxy;
        m11 += (x0 * y1 + 2.0 * (x0 * y0 + x1 * y1) + x1 * y0) * dxy;
        m02 += (y0 * y0 + y0 * y1 + y1 * y1) * dxy;
        double x0_2 = x0 * x0, x1_2 = x1 * x1, y0_2 = y0 * y0, y1_2 = y1 * y1;
        m30 += (x0 + x1) * (x0_2 + x1_2) * dxy;
        m03 += (y0 + y1) * (y0_2 + y1_2) * dxy;
        m21 += (3.0 * x0_2 * y0 + x1_2 * y0 + 2.0 * x0 * x1 * (y0 + y1) + x0_2 * y1 + 3.0 * x1_2 * y1) * dxy;
        m12 += (3.0 * x0 * y0_2 + x0 * y1_2 + 2.0 * y0 * y1 * (x0 + x1) + x1 * y0_2 + 3.0 * x1 * y1_2) * dxy;
        p0 = p1;
    }
    if (fabs(m00) < DBL_EPSILON) return 0;
    double sign = (m00 < 0.0) ? -1.0 : 1.0;
    out24[0] = m00 * (0.5 * sign);
    out24[1] = m10 * (sign / 6.0);
    out24[2] = m01 * (sign / 6.0);
    out24[3] = m20 * (sign / 12.0);
    out24[4] = m11 * (sign / 24.0);
    out24[5] = m02 * (sign / 12.0);
    out24[6] = m30 * (sign / 20.0);
    out24[7] = m21 * (sign / 60.0);
    out24[8] = m12 * (sign / 60.0);
    out24[9] = m03 * (sign / 20.0);
    finish_moments(out24);
    return 0;
}

// depth: 0=u8, 2=u16, 3=s16, 5=f32, 6=f64
int32_t sr_c_p4_moments_img(const void *img, int32_t w, int32_t h, int32_t stride,
                            int32_t depth, int32_t binary, double *out24) {
    if (!out24 || w < 0 || h < 0 || (w > 0 && h > 0 && !img)) return -1;
    memset(out24, 0, 24 * sizeof(double));
    if (w == 0 || h == 0) return 0;

    double m00 = 0, m10 = 0, m01 = 0, m20 = 0, m11 = 0, m02 = 0, m30 = 0, m21 = 0, m12 = 0, m03 = 0;
    const uint8_t *base = (const uint8_t *)img;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *row = base + (size_t)y * (size_t)stride;
        double xm0 = 0, xm1 = 0, xm2 = 0, xm3 = 0;
        for (int32_t x = 0; x < w; x++) {
            double v = 0.0;
            if (depth == 0) v = (double)row[x];
            else if (depth == 2) v = (double)((const uint16_t *)row)[x];
            else if (depth == 3) v = (double)((const int16_t *)row)[x];
            else if (depth == 5) v = (double)((const float *)row)[x];
            else if (depth == 6) v = ((const double *)row)[x];
            else return -2;
            if (binary) v = (v != 0.0) ? 1.0 : 0.0;
            if (v == 0.0) continue;
            double dx = (double)x;
            double x2 = dx * dx;
            xm0 += v;
            xm1 += v * dx;
            xm2 += v * x2;
            xm3 += v * x2 * dx;
        }
        double dy = (double)y;
        double y2 = dy * dy;
        m00 += xm0;
        m10 += xm1;
        m01 += dy * xm0;
        m20 += xm2;
        m11 += dy * xm1;
        m02 += y2 * xm0;
        m30 += xm3;
        m21 += dy * xm2;
        m12 += y2 * xm1;
        m03 += y2 * dy * xm0;
    }
    out24[0] = m00; out24[1] = m10; out24[2] = m01;
    out24[3] = m20; out24[4] = m11; out24[5] = m02;
    out24[6] = m30; out24[7] = m21; out24[8] = m12; out24[9] = m03;
    finish_moments(out24);
    return 0;
}

int32_t sr_c_p4_hu_moments(const double *m24, double *hu7) {
    if (!m24 || !hu7) return -1;
    double nu20 = m24[17], nu11 = m24[18], nu02 = m24[19];
    double nu30 = m24[20], nu21 = m24[21], nu12 = m24[22], nu03 = m24[23];
    double t0 = nu30 + nu12;
    double t1 = nu21 + nu03;
    double q0 = t0 * t0, q1 = t1 * t1;
    double n4 = 4.0 * nu11;
    double s = nu20 + nu02;
    double d = nu20 - nu02;
    hu7[0] = s;
    hu7[1] = d * d + n4 * nu11;
    hu7[3] = q0 + q1;
    hu7[5] = d * (q0 - q1) + n4 * t0 * t1;
    double t0_p = nu30 - 3.0 * nu12;
    double t1_p = 3.0 * nu21 - nu03;
    hu7[2] = t0_p * t0_p + t1_p * t1_p;
    double sq0 = (nu30 + nu12) * (nu30 + nu12) - 3.0 * (nu21 + nu03) * (nu21 + nu03);
    double sq1 = 3.0 * (nu30 + nu12) * (nu30 + nu12) - (nu21 + nu03) * (nu21 + nu03);
    hu7[4] = t0_p * t0 * sq0 + t1_p * t1 * sq1;
    hu7[6] = t1_p * t0 * sq0 - t0_p * t1 * sq1;
    return 0;
}

int32_t sr_c_p4_match_shapes(const double *m24_a, const double *m24_b, int32_t method, double param, double *out_val) {
    (void)param;
    if (!m24_a || !m24_b || !out_val) return -1;
    if (method < 1 || method > 3) return -2;
    double huA[7], huB[7];
    sr_c_p4_hu_moments(m24_a, huA);
    sr_c_p4_hu_moments(m24_b, huB);

    double result = 0.0;
    const double eps = 1e-5;
    int anyA = 0, anyB = 0;
    double ma[7], mb[7];
    for (int i = 0; i < 7; i++) {
        double a = fabs(huA[i]), b = fabs(huB[i]);
        if (a > 0.0) { anyA = 1; ma[i] = (huA[i] > 0.0 ? 1.0 : -1.0) * log10(a); }
        else ma[i] = 0.0;
        if (b > 0.0) { anyB = 1; mb[i] = (huB[i] > 0.0 ? 1.0 : -1.0) * log10(b); }
        else mb[i] = 0.0;
    }
    if (anyA != anyB) {
        *out_val = DBL_MAX;
        return 0;
    }
    if (!anyA && !anyB) {
        *out_val = 0.0;
        return 0;
    }
    for (int i = 0; i < 7; i++) {
        if (fabs(huA[i]) > eps && fabs(huB[i]) > eps && fabs(ma[i]) > 1e-12 && fabs(mb[i]) > 1e-12) {
            if (method == 1) {
                result += fabs(1.0 / ma[i] - 1.0 / mb[i]);
            } else if (method == 2) {
                result += fabs(ma[i] - mb[i]);
            } else {
                double d = fabs(ma[i] - mb[i]) / fabs(ma[i]);
                if (d > result) result = d;
            }
        }
    }
    *out_val = result;
    return 0;
}

// ---------------------------------------------------------------------------
// intersectConvexConvex & rotatedRectangleIntersection
// ---------------------------------------------------------------------------

static void ensure_ccw_f(sr_pt2d *p, int32_t n) {
    double a = 0.0;
    for (int32_t i = 0; i < n; i++) {
        int32_t j = (i + 1) % n;
        a += p[i].x * p[j].y - p[j].x * p[i].y;
    }
    if (a < 0.0) {
        for (int32_t i = 0; i < n / 2; i++) {
            sr_pt2d t = p[i]; p[i] = p[n - 1 - i]; p[n - 1 - i] = t;
        }
    }
}

static int clip_convex_sutherland(const sr_pt2d *subj, int32_t ns, const sr_pt2d *clip, int32_t nc,
                                  sr_pt2d *out, int32_t *out_n) {
    int32_t max_buf = ns + nc * 2 + 16;
    sr_pt2d *cur = (sr_pt2d *)malloc((size_t)max_buf * sizeof(sr_pt2d));
    sr_pt2d *nxt = (sr_pt2d *)malloc((size_t)max_buf * sizeof(sr_pt2d));
    if (!cur || !nxt) { free(cur); free(nxt); return -4; }
    memcpy(cur, subj, (size_t)ns * sizeof(sr_pt2d));
    int32_t cur_n = ns;

    for (int32_t e = 0; e < nc && cur_n > 0; e++) {
        sr_pt2d c1 = clip[e], c2 = clip[(e + 1) % nc];
        double clen = hypot(c2.x - c1.x, c2.y - c1.y);
        if (clen < 1e-12) continue;
        double tol = -1e-7 * clen;
        int32_t nxt_n = 0;
        sr_pt2d prev = cur[cur_n - 1];
        double prev_d = sr_cross3(c1, c2, prev);
        int prev_in = prev_d >= tol;
        for (int32_t i = 0; i < cur_n; i++) {
            sr_pt2d pt = cur[i];
            double cur_d = sr_cross3(c1, c2, pt);
            int cur_in = cur_d >= tol;
            if (cur_in) {
                if (!prev_in) {
                    double denom = prev_d - cur_d;
                    double t = (fabs(denom) > 1e-15) ? (prev_d / denom) : 0.5;
                    nxt[nxt_n++] = (sr_pt2d){prev.x + t * (pt.x - prev.x), prev.y + t * (pt.y - prev.y)};
                }
                nxt[nxt_n++] = pt;
            } else if (prev_in) {
                double denom = prev_d - cur_d;
                double t = (fabs(denom) > 1e-15) ? (prev_d / denom) : 0.5;
                nxt[nxt_n++] = (sr_pt2d){prev.x + t * (pt.x - prev.x), prev.y + t * (pt.y - prev.y)};
            }
            prev = pt;
            prev_d = cur_d;
            prev_in = cur_in;
        }
        sr_pt2d *tmp = cur; cur = nxt; nxt = tmp;
        cur_n = nxt_n;
    }

    // Deduplicate consecutive near-identical vertices
    int32_t k = 0;
    for (int32_t i = 0; i < cur_n; i++) {
        if (k == 0 || hypot(cur[i].x - out[k - 1].x, cur[i].y - out[k - 1].y) > 1e-5) {
            out[k++] = cur[i];
        }
    }
    if (k > 1 && hypot(out[k - 1].x - out[0].x, out[k - 1].y - out[0].y) <= 1e-5) k--;
    *out_n = k;
    free(cur);
    free(nxt);
    return 0;
}

static int poly_strictly_inside(const sr_pt2d *inner, int32_t ni, const sr_pt2d *outer, int32_t no) {
    for (int32_t i = 0; i < ni; i++) {
        for (int32_t e = 0; e < no; e++) {
            sr_pt2d c1 = outer[e], c2 = outer[(e + 1) % no];
            double clen = hypot(c2.x - c1.x, c2.y - c1.y);
            if (clen < 1e-12) continue;
            if (sr_cross3(c1, c2, inner[i]) <= 1e-6 * clen) return 0;
        }
    }
    return 1;
}

int32_t sr_c_p4_intersect_convex_convex(const float *p1_in, int32_t n1, const float *p2_in, int32_t n2,
                                        int32_t handle_nested, float *out_pts, int32_t *out_k, float *out_area) {
    if (!out_k || !out_area || n1 < 0 || n2 < 0) return -1;
    *out_k = 0;
    *out_area = 0.0f;
    if (n1 < 3 || n2 < 3 || !p1_in || !p2_in || !out_pts) return 0;

    sr_pt2d *p1 = (sr_pt2d *)malloc((size_t)n1 * sizeof(sr_pt2d));
    sr_pt2d *p2 = (sr_pt2d *)malloc((size_t)n2 * sizeof(sr_pt2d));
    sr_pt2d *inter = (sr_pt2d *)malloc((size_t)(n1 + n2 * 2 + 16) * sizeof(sr_pt2d));
    if (!p1 || !p2 || !inter) { free(p1); free(p2); free(inter); return -4; }
    for (int32_t i = 0; i < n1; i++) p1[i] = (sr_pt2d){p1_in[i * 2], p1_in[i * 2 + 1]};
    for (int32_t i = 0; i < n2; i++) p2[i] = (sr_pt2d){p2_in[i * 2], p2_in[i * 2 + 1]};
    ensure_ccw_f(p1, n1);
    ensure_ccw_f(p2, n2);

    if (!handle_nested && (poly_strictly_inside(p1, n1, p2, n2) || poly_strictly_inside(p2, n2, p1, n1))) {
        free(p1); free(p2); free(inter);
        return 0;
    }

    int32_t k = 0;
    int32_t rc = clip_convex_sutherland(p1, n1, p2, n2, inter, &k);
    if (rc != 0) { free(p1); free(p2); free(inter); return rc; }

    double area = 0.0;
    if (k >= 3) {
        for (int32_t i = 0; i < k; i++) {
            int32_t j = (i + 1) % k;
            area += inter[i].x * inter[j].y - inter[j].x * inter[i].y;
        }
        area = 0.5 * fabs(area);
    }
    if (k == 0 || area <= 1e-12) {
        *out_k = 0;
        *out_area = 0.0f;
    } else {
        *out_k = k;
        *out_area = (float)area;
        for (int32_t i = 0; i < k; i++) {
            out_pts[i * 2] = (float)inter[i].x;
            out_pts[i * 2 + 1] = (float)inter[i].y;
        }
    }
    free(p1); free(p2); free(inter);
    return 0;
}

int32_t sr_c_p4_rot_rect_intersection(const float *r1, const float *r2, float *out_pts, int32_t *out_k, int32_t *out_type) {
    if (!r1 || !r2 || !out_pts || !out_k || !out_type) return -1;
    *out_k = 0;
    *out_type = 0; // INTERSECT_NONE
    if (r1[2] <= 0.0f || r1[3] <= 0.0f || r2[2] <= 0.0f || r2[3] <= 0.0f) return 0;

    float bp1[8], bp2[8];
    sr_c_p4_box_points(r1[0], r1[1], r1[2], r1[3], r1[4], bp1);
    sr_c_p4_box_points(r2[0], r2[1], r2[2], r2[3], r2[4], bp2);
    sr_pt2d p1[4], p2[4], inter[32];
    for (int i = 0; i < 4; i++) {
        p1[i] = (sr_pt2d){bp1[i * 2], bp1[i * 2 + 1]};
        p2[i] = (sr_pt2d){bp2[i * 2], bp2[i * 2 + 1]};
    }
    ensure_ccw_f(p1, 4);
    ensure_ccw_f(p2, 4);

    int32_t k = 0;
    clip_convex_sutherland(p1, 4, p2, 4, inter, &k);
    if (k == 0) {
        *out_k = 0;
        *out_type = 0;
        return 0;
    }

    // Check INTERSECT_FULL: one rectangle completely inside/equal to the other
    int all1_in_2 = 1, all2_in_1 = 1;
    for (int i = 0; i < 4; i++) {
        for (int e = 0; e < 4; e++) {
            double len2 = hypot(p2[(e + 1) % 4].x - p2[e].x, p2[(e + 1) % 4].y - p2[e].y);
            if (sr_cross3(p2[e], p2[(e + 1) % 4], p1[i]) < -1e-5 * len2) all1_in_2 = 0;
            double len1 = hypot(p1[(e + 1) % 4].x - p1[e].x, p1[(e + 1) % 4].y - p1[e].y);
            if (sr_cross3(p1[e], p1[(e + 1) % 4], p2[i]) < -1e-5 * len1) all2_in_1 = 0;
        }
    }
    *out_type = (all1_in_2 || all2_in_1) ? 2 : 1;
    *out_k = k;
    for (int32_t i = 0; i < k; i++) {
        out_pts[i * 2] = (float)inter[i].x;
        out_pts[i * 2 + 1] = (float)inter[i].y;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// HoughLines (Standard + Multi-Scale) & HoughLinesP & HoughCircles
// ---------------------------------------------------------------------------

typedef struct {
    int32_t idx;
    int32_t score;
} sr_hough_cand;

static int cmp_hough_desc(const void *a, const void *b) {
    const sr_hough_cand *ca = (const sr_hough_cand *)a;
    const sr_hough_cand *cb = (const sr_hough_cand *)b;
    if (cb->score > ca->score) return 1;
    if (cb->score < ca->score) return -1;
    return (ca->idx < cb->idx) ? -1 : ((ca->idx > cb->idx) ? 1 : 0);
}

int32_t sr_c_p4_hough_lines(const uint8_t *img, int32_t w, int32_t h, int32_t stride,
                            double rho, double theta, int32_t threshold,
                            double srn, double stn, double min_theta, double max_theta, int32_t use_edgeval,
                            int32_t lines_max, float **out_lines, int32_t *out_count) {
    if (!img || !out_lines || !out_count || w <= 0 || h <= 0 || rho <= 0.0 || theta <= 0.0 || threshold <= 0) return -1;
    *out_lines = NULL;
    *out_count = 0;
    if (max_theta < min_theta) return -1;

    int32_t numangle = (int32_t)floor((max_theta - min_theta) / theta) + 1;
    if (numangle > 1 && fabs(M_PI - (numangle - 1) * theta) < theta * 0.5 && max_theta >= M_PI - 1e-6 && min_theta == 0.0) {
        numangle--;
    }
    if (numangle <= 0) numangle = 1;
    double max_rho = (double)(w + h);
    int32_t numrho = sr_round_d((max_rho * 2.0 + 1.0) / rho);
    if (numrho < 1) numrho = 1;

    size_t acc_stride = (size_t)numrho + 2;
    int32_t *accum = (int32_t *)calloc((size_t)(numangle + 2) * acc_stride, sizeof(int32_t));
    double *tab_sin = (double *)malloc((size_t)numangle * sizeof(double));
    double *tab_cos = (double *)malloc((size_t)numangle * sizeof(double));
    if (!accum || !tab_sin || !tab_cos) { free(accum); free(tab_sin); free(tab_cos); return -4; }

    double irho = 1.0 / rho;
    for (int32_t n = 0; n < numangle; n++) {
        double ang = min_theta + n * theta;
        tab_sin[n] = sin(ang) * irho;
        tab_cos[n] = cos(ang) * irho;
    }

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *row = img + (size_t)y * (size_t)stride;
        for (int32_t x = 0; x < w; x++) {
            uint8_t val = row[x];
            if (val == 0) continue;
            int32_t weight = use_edgeval ? (int32_t)val : 1;
            for (int32_t n = 0; n < numangle; n++) {
                int32_t r = sr_round_d((double)x * tab_cos[n] + (double)y * tab_sin[n]);
                r += (numrho - 1) / 2;
                if (r >= 0 && r < numrho) {
                    accum[(size_t)(n + 1) * acc_stride + (size_t)(r + 1)] += weight;
                }
            }
        }
    }

    int32_t cap = 256, nc = 0;
    sr_hough_cand *cands = (sr_hough_cand *)malloc((size_t)cap * sizeof(sr_hough_cand));
    if (!cands) { free(accum); free(tab_sin); free(tab_cos); return -4; }

    for (int32_t n = 0; n < numangle; n++) {
        for (int32_t r = 0; r < numrho; r++) {
            int32_t base = (int32_t)((size_t)(n + 1) * acc_stride + (size_t)(r + 1));
            int32_t v = accum[base];
            if (v > threshold &&
                v > accum[base - 1] && v >= accum[base + 1] &&
                v > accum[base - (int32_t)acc_stride] && v >= accum[base + (int32_t)acc_stride]) {
                if (nc == cap) {
                    cap *= 2;
                    sr_hough_cand *ncands = (sr_hough_cand *)realloc(cands, (size_t)cap * sizeof(sr_hough_cand));
                    if (!ncands) { free(cands); free(accum); free(tab_sin); free(tab_cos); return -4; }
                    cands = ncands;
                }
                cands[nc].idx = base;
                cands[nc].score = v;
                nc++;
            }
        }
    }

    qsort(cands, (size_t)nc, sizeof(sr_hough_cand), cmp_hough_desc);
    int32_t out_n = (lines_max > 0 && nc > lines_max) ? lines_max : nc;
    if (out_n > 0) {
        float *res = (float *)malloc((size_t)out_n * 2 * sizeof(float));
        if (!res) { free(cands); free(accum); free(tab_sin); free(tab_cos); return -4; }
        double scale_r = 1.0 / ((double)numrho + 2.0);
        (void)scale_r;
        int32_t multi = (srn > 0.0 && stn > 0.0);
        for (int32_t i = 0; i < out_n; i++) {
            int32_t idx = cands[i].idx;
            int32_t n = idx / (int32_t)acc_stride - 1;
            int32_t r = idx % (int32_t)acc_stride - 1;
            double ang = min_theta + n * theta;
            double rr = (r - (numrho - 1) * 0.5) * rho;
            if (multi) {
                // Multi-scale local refinement around (rr, ang)
                double f_rho = rho / srn, f_theta = theta / stn;
                int32_t nr_sub = (int32_t)ceil(srn) * 2 + 1;
                int32_t nt_sub = (int32_t)ceil(stn) * 2 + 1;
                double best_rr = rr, best_ang = ang;
                int32_t best_v = -1;
                int32_t *sub = (int32_t *)calloc((size_t)nr_sub * (size_t)nt_sub, sizeof(int32_t));
                if (sub) {
                    double r0 = rr - (nr_sub / 2) * f_rho;
                    double t0 = ang - (nt_sub / 2) * f_theta;
                    for (int32_t ti = 0; ti < nt_sub; ti++) {
                        double ta = t0 + ti * f_theta;
                        double cs = cos(ta), sn = sin(ta);
                        for (int32_t y = 0; y < h; y++) {
                            const uint8_t *row = img + (size_t)y * (size_t)stride;
                            for (int32_t x = 0; x < w; x++) {
                                if (!row[x]) continue;
                                double rp = x * cs + y * sn;
                                int32_t ri = sr_round_d((rp - r0) / f_rho);
                                if (ri >= 0 && ri < nr_sub) {
                                    int32_t vv = ++sub[(size_t)ti * (size_t)nr_sub + (size_t)ri];
                                    if (vv > best_v) {
                                        best_v = vv;
                                        best_rr = r0 + ri * f_rho;
                                        best_ang = ta;
                                    }
                                }
                            }
                        }
                    }
                    free(sub);
                    rr = best_rr;
                    ang = best_ang;
                }
            }
            res[i * 2] = (float)rr;
            res[i * 2 + 1] = (float)ang;
        }
        *out_lines = res;
        *out_count = out_n;
    }

    free(cands);
    free(accum);
    free(tab_sin);
    free(tab_cos);
    return 0;
}

int32_t sr_c_p4_hough_lines_p(const uint8_t *img, int32_t w, int32_t h, int32_t stride,
                              double rho, double theta, int32_t threshold,
                              double min_len, double max_gap, int32_t lines_max,
                              int32_t **out_lines, int32_t *out_count) {
    if (!img || !out_lines || !out_count || w <= 0 || h <= 0 || rho <= 0.0 || theta <= 0.0 || threshold <= 0) return -1;
    *out_lines = NULL;
    *out_count = 0;

    int32_t numangle = sr_round_d(M_PI / theta);
    if (numangle < 1) numangle = 1;
    int32_t numrho = sr_round_d(((double)(w + h) * 2.0 + 1.0) / rho);
    if (numrho < 1) numrho = 1;

    uint8_t *mask = (uint8_t *)calloc((size_t)w * (size_t)h, 1);
    int32_t *nz = (int32_t *)malloc((size_t)w * (size_t)h * 2 * sizeof(int32_t));
    int32_t *accum = (int32_t *)calloc((size_t)numangle * (size_t)numrho, sizeof(int32_t));
    double *trig = (double *)malloc((size_t)numangle * 2 * sizeof(double));
    if (!mask || !nz || !accum || !trig) {
        free(mask); free(nz); free(accum); free(trig); return -4;
    }

    double irho = 1.0 / rho;
    for (int32_t n = 0; n < numangle; n++) {
        trig[n * 2] = cos((double)n * theta) * irho;
        trig[n * 2 + 1] = sin((double)n * theta) * irho;
    }

    int32_t count = 0;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *row = img + (size_t)y * (size_t)stride;
        for (int32_t x = 0; x < w; x++) {
            if (row[x] != 0) {
                mask[(size_t)y * (size_t)w + (size_t)x] = 1;
                nz[(size_t)count * 2] = x;
                nz[(size_t)count * 2 + 1] = y;
                count++;
            }
        }
    }

    int32_t line_cap = 128, nlines = 0;
    int32_t *lines = (int32_t *)malloc((size_t)line_cap * 4 * sizeof(int32_t));
    if (!lines) { free(mask); free(nz); free(accum); free(trig); return -4; }

    uint64_t rng = 0xFFFFFFFFULL;
    const int32_t shift = 16;
    const int32_t half_rho = (numrho - 1) / 2;

    for (; count > 0; count--) {
        rng = rng * 4164903690ULL + (rng >> 32);
        int32_t idx = (int32_t)(rng % (uint64_t)count);
        int32_t x = nz[(size_t)idx * 2];
        int32_t y = nz[(size_t)idx * 2 + 1];
        nz[(size_t)idx * 2] = nz[(size_t)(count - 1) * 2];
        nz[(size_t)idx * 2 + 1] = nz[(size_t)(count - 1) * 2 + 1];

        if (!mask[(size_t)y * (size_t)w + (size_t)x]) continue;

        int32_t max_val = threshold - 1, max_n = 0;
        for (int32_t n = 0; n < numangle; n++) {
            int32_t r = sr_round_d((double)x * trig[n * 2] + (double)y * trig[n * 2 + 1]) + half_rho;
            if (r >= 0 && r < numrho) {
                int32_t val = ++accum[(size_t)n * (size_t)numrho + (size_t)r];
                if (val > max_val) { max_val = val; max_n = n; }
            }
        }
        if (max_val < threshold) continue;

        double a = -trig[max_n * 2 + 1]; // -sin * irho
        double b = trig[max_n * 2];      //  cos * irho
        int32_t dx0, dy0, xflag;
        if (fabs(a) > fabs(b)) {
            xflag = 1;
            dx0 = (a > 0) ? 1 : -1;
            dy0 = sr_round_d(b * (double)(1 << shift) / fabs(a));
            y = (y << shift) + (1 << (shift - 1));
        } else {
            xflag = 0;
            dy0 = (b > 0) ? 1 : -1;
            dx0 = sr_round_d(a * (double)(1 << shift) / fabs(b));
            x = (x << shift) + (1 << (shift - 1));
        }

        int32_t x0 = x, y0 = y;
        int32_t end_x[2], end_y[2];
        int32_t line_gap = (int32_t)max_gap;
        for (int k = 0; k < 2; k++) {
            int32_t gap = 0;
            int32_t cx = x0, cy = y0;
            int32_t dx = dx0, dy = dy0;
            if (k > 0) { dx = -dx; dy = -dy; }
            end_x[k] = xflag ? x0 : (x0 >> shift);
            end_y[k] = xflag ? (y0 >> shift) : y0;
            for (;; cx += dx, cy += dy) {
                int32_t px = xflag ? cx : (cx >> shift);
                int32_t py = xflag ? (cy >> shift) : cy;
                if (px < 0 || px >= w || py < 0 || py >= h) break;
                if (mask[(size_t)py * (size_t)w + (size_t)px]) {
                    gap = 0;
                    end_x[k] = px;
                    end_y[k] = py;
                } else if (++gap > line_gap) {
                    break;
                }
            }
        }

        double seg_len = hypot((double)(end_x[1] - end_x[0]), (double)(end_y[1] - end_y[0]));
        int32_t good = (seg_len >= min_len) ||
                       (abs(end_x[1] - end_x[0]) >= (int32_t)min_len || abs(end_y[1] - end_y[0]) >= (int32_t)min_len);
        // Walk again to unvote & erase pixels
        for (int k = 0; k < 2; k++) {
            int32_t cx = x0, cy = y0;
            int32_t dx = dx0, dy = dy0;
            if (k > 0) { dx = -dx; dy = -dy; }
            for (;; cx += dx, cy += dy) {
                int32_t px = xflag ? cx : (cx >> shift);
                int32_t py = xflag ? (cy >> shift) : cy;
                if (px < 0 || px >= w || py < 0 || py >= h) break;
                if (mask[(size_t)py * (size_t)w + (size_t)px]) {
                    if (good) {
                        for (int32_t n = 0; n < numangle; n++) {
                            int32_t r = sr_round_d((double)px * trig[n * 2] + (double)py * trig[n * 2 + 1]) + half_rho;
                            if (r >= 0 && r < numrho) accum[(size_t)n * (size_t)numrho + (size_t)r]--;
                        }
                    }
                    mask[(size_t)py * (size_t)w + (size_t)px] = 0;
                }
                if (px == end_x[k] && py == end_y[k]) break;
            }
        }

        if (good) {
            if (nlines == line_cap) {
                line_cap *= 2;
                int32_t *nl = (int32_t *)realloc(lines, (size_t)line_cap * 4 * sizeof(int32_t));
                if (!nl) { free(lines); free(mask); free(nz); free(accum); free(trig); return -4; }
                lines = nl;
            }
            lines[(size_t)nlines * 4 + 0] = end_x[0];
            lines[(size_t)nlines * 4 + 1] = end_y[0];
            lines[(size_t)nlines * 4 + 2] = end_x[1];
            lines[(size_t)nlines * 4 + 3] = end_y[1];
            nlines++;
            if (lines_max > 0 && nlines >= lines_max) break;
        }
    }

    free(mask); free(nz); free(accum); free(trig);
    if (nlines == 0) {
        free(lines);
        *out_lines = NULL;
        *out_count = 0;
    } else {
        *out_lines = lines;
        *out_count = nlines;
    }
    return 0;
}

typedef struct {
    float x, y, r, votes;
} sr_circle_cand;

static int cmp_circle_desc(const void *a, const void *b) {
    const sr_circle_cand *ca = (const sr_circle_cand *)a;
    const sr_circle_cand *cb = (const sr_circle_cand *)b;
    if (cb->votes > ca->votes) return 1;
    if (cb->votes < ca->votes) return -1;
    return 0;
}

static int cmp_float_asc(const void *a, const void *b) {
    float fa = *(const float *)a, fb = *(const float *)b;
    return (fa < fb) ? -1 : ((fa > fb) ? 1 : 0);
}

int32_t sr_c_p4_hough_circles(const uint8_t *img, int32_t w, int32_t h, int32_t stride,
                              int32_t method, double dp, double min_dist,
                              double param1, double param2, int32_t min_r, int32_t max_r,
                              int32_t circles_max, float **out_circles, int32_t *out_count) {
    if (!img || !out_circles || !out_count || w <= 0 || h <= 0 || dp <= 0.0 || min_dist <= 0.0 ||
        param1 <= 0.0 || param2 <= 0.0) return -1;
    if (method != 3 && method != 4) return -2; // HOUGH_GRADIENT=3, HOUGH_GRADIENT_ALT=4
    *out_circles = NULL;
    *out_count = 0;

    if (min_r < 0) min_r = 0;
    if (max_r <= 0) max_r = (w > h) ? w : h;
    if (max_r < min_r) return 0;

    // 1. Compute gradients (Sobel 3x3 for GRADIENT, Scharr 3x3 for GRADIENT_ALT) + Canny-like non-max edge map
    size_t npix = (size_t)w * (size_t)h;
    int16_t *dx_buf = (int16_t *)calloc(npix, sizeof(int16_t));
    int16_t *dy_buf = (int16_t *)calloc(npix, sizeof(int16_t));
    float *mag = (float *)calloc(npix, sizeof(float));
    uint8_t *edges = (uint8_t *)calloc(npix, 1);
    if (!dx_buf || !dy_buf || !mag || !edges) {
        free(dx_buf); free(dy_buf); free(mag); free(edges); return -4;
    }

    int32_t k_diag = (method == 4) ? 3 : 1;
    int32_t k_mid = (method == 4) ? 10 : 2;
    double scale_g = (method == 4) ? 0.25 : 1.0;

    for (int32_t y = 0; y < h; y++) {
        int32_t ym = (y > 0) ? y - 1 : 0;
        int32_t yp = (y + 1 < h) ? y + 1 : h - 1;
        const uint8_t *r0 = img + (size_t)ym * (size_t)stride;
        const uint8_t *r1 = img + (size_t)y * (size_t)stride;
        const uint8_t *r2 = img + (size_t)yp * (size_t)stride;
        for (int32_t x = 0; x < w; x++) {
            int32_t xm = (x > 0) ? x - 1 : 0;
            int32_t xp = (x + 1 < w) ? x + 1 : w - 1;
            int32_t gx = k_diag * ((int32_t)r0[xp] - (int32_t)r0[xm] + (int32_t)r2[xp] - (int32_t)r2[xm]) +
                         k_mid * ((int32_t)r1[xp] - (int32_t)r1[xm]);
            int32_t gy = k_diag * ((int32_t)r2[xm] - (int32_t)r0[xm] + (int32_t)r2[xp] - (int32_t)r0[xp]) +
                         k_mid * ((int32_t)r2[x] - (int32_t)r0[x]);
            size_t idx = (size_t)y * (size_t)w + (size_t)x;
            dx_buf[idx] = (int16_t)sr_round_d((double)gx * scale_g);
            dy_buf[idx] = (int16_t)sr_round_d((double)gy * scale_g);
            mag[idx] = (float)hypot((double)dx_buf[idx], (double)dy_buf[idx]);
        }
    }

    // Simple 2-threshold Canny edge extraction (low = param1 * 0.5, high = param1)
    float high_th = (float)param1;
    float low_th = (float)(param1 * 0.5);
    int32_t *stk = (int32_t *)malloc(npix * sizeof(int32_t));
    if (!stk) { free(dx_buf); free(dy_buf); free(mag); free(edges); return -4; }
    int32_t sp = 0;

    for (int32_t y = 1; y < h - 1; y++) {
        for (int32_t x = 1; x < w - 1; x++) {
            size_t idx = (size_t)y * (size_t)w + (size_t)x;
            float m = mag[idx];
            if (m <= low_th) continue;
            float gx = (float)dx_buf[idx], gy = (float)dy_buf[idx];
            float ax = fabsf(gx), ay = fabsf(gy);
            float m1, m2;
            if (ax > ay * 2.41421356f) {
                m1 = mag[idx - 1]; m2 = mag[idx + 1];
            } else if (ay > ax * 2.41421356f) {
                m1 = mag[idx - w]; m2 = mag[idx + w];
            } else {
                int32_t s = ((gx * gy) >= 0.0f) ? 1 : -1;
                m1 = mag[idx - w - s]; m2 = mag[idx + w + s];
            }
            if (m >= m1 && m >= m2) {
                if (m > high_th) {
                    edges[idx] = 2;
                    stk[sp++] = (int32_t)idx;
                } else {
                    edges[idx] = 1;
                }
            }
        }
    }
    while (sp > 0) {
        int32_t idx = stk[--sp];
        int32_t y = idx / w, x = idx % w;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                if (dx == 0 && dy == 0) continue;
                int32_t nx = x + dx, ny = y + dy;
                if (nx >= 0 && nx < w && ny >= 0 && ny < h) {
                    size_t nidx = (size_t)ny * (size_t)w + (size_t)nx;
                    if (edges[nidx] == 1) {
                        edges[nidx] = 2;
                        stk[sp++] = (int32_t)nidx;
                    }
                }
            }
        }
    }
    free(stk);

    // 2. Collect edge coordinates & vote into center accumulator
    int32_t aw = (int32_t)ceil((double)w / dp);
    int32_t ah = (int32_t)ceil((double)h / dp);
    if (aw < 1) aw = 1;
    if (ah < 1) ah = 1;
    int32_t *accum = (int32_t *)calloc((size_t)(ah + 2) * (size_t)(aw + 2), sizeof(int32_t));
    int32_t *nz_xy = (int32_t *)malloc(npix * 2 * sizeof(int32_t));
    if (!accum || !nz_xy) { free(accum); free(nz_xy); free(dx_buf); free(dy_buf); free(mag); free(edges); return -4; }

    int32_t nz_cnt = 0;
    double idp = 1.0 / dp;
    int32_t r_min = (min_r > 1) ? min_r : 1;
    int32_t r_max = max_r;
    size_t astr = (size_t)aw + 2;

    for (int32_t y = 0; y < h; y++) {
        for (int32_t x = 0; x < w; x++) {
            size_t idx = (size_t)y * (size_t)w + (size_t)x;
            if (edges[idx] != 2) continue;
            float gx = (float)dx_buf[idx], gy = (float)dy_buf[idx];
            float m = mag[idx];
            if (m < 1e-6f) continue;
            nz_xy[(size_t)nz_cnt * 2] = x;
            nz_xy[(size_t)nz_cnt * 2 + 1] = y;
            nz_cnt++;

            double sx = (double)gx / (double)m * idp;
            double sy = (double)gy / (double)m * idp;
            for (int dir = -1; dir <= 1; dir += 2) {
                double cx = ((double)x * idp) + dir * (double)r_min * sx;
                double cy = ((double)y * idp) + dir * (double)r_min * sy;
                int32_t prev_ax = -1, prev_ay = -1;
                for (int32_t r = r_min; r <= r_max; r++) {
                    int32_t ax = sr_round_d(cx), ay = sr_round_d(cy);
                    if (ax < 0 || ax >= aw || ay < 0 || ay >= ah) break;
                    if (ax != prev_ax || ay != prev_ay) {
                        accum[(size_t)(ay + 1) * astr + (size_t)(ax + 1)]++;
                        prev_ax = ax; prev_ay = ay;
                    }
                    cx += dir * sx;
                    cy += dir * sy;
                }
            }
        }
    }

    if (nz_cnt == 0) {
        free(accum); free(nz_xy); free(dx_buf); free(dy_buf); free(mag); free(edges);
        return 0;
    }

    // Smooth center accumulator with 3x3 binomial filter [1,2,1] to merge discrete ray quantization
    int32_t *acc_smooth = (int32_t *)calloc((size_t)(ah + 2) * astr, sizeof(int32_t));
    if (!acc_smooth) { free(accum); free(nz_xy); free(dx_buf); free(dy_buf); free(mag); free(edges); return -4; }
    for (int32_t y = 0; y < ah; y++) {
        for (int32_t x = 0; x < aw; x++) {
            size_t b = (size_t)(y + 1) * astr + (size_t)(x + 1);
            int32_t s = accum[b - astr - 1] + 2 * accum[b - astr] + accum[b - astr + 1] +
                        2 * accum[b - 1]    + 4 * accum[b]        + 2 * accum[b + 1] +
                        accum[b + astr - 1] + 2 * accum[b + astr] + accum[b + astr + 1];
            acc_smooth[b] = s;
        }
    }

    // 3. Find local maxima in center accumulator
    int32_t acc_th = (method == 4) ? 16 : (int32_t)floor(param2 * 12.0);
    if (acc_th < 12) acc_th = 12;
    int32_t cand_cap = 256, ncand = 0;
    sr_hough_cand *cands = (sr_hough_cand *)malloc((size_t)cand_cap * sizeof(sr_hough_cand));
    if (!cands) { free(acc_smooth); free(accum); free(nz_xy); free(dx_buf); free(dy_buf); free(mag); free(edges); return -4; }

    for (int32_t y = 0; y < ah; y++) {
        for (int32_t x = 0; x < aw; x++) {
            size_t base = (size_t)(y + 1) * astr + (size_t)(x + 1);
            int32_t v = acc_smooth[base];
            if (v > acc_th && v > acc_smooth[base - 1] && v >= acc_smooth[base + 1] &&
                v > acc_smooth[base - astr] && v >= acc_smooth[base + astr]) {
                if (ncand == cand_cap) {
                    cand_cap *= 2;
                    sr_hough_cand *nc = (sr_hough_cand *)realloc(cands, (size_t)cand_cap * sizeof(sr_hough_cand));
                    if (!nc) { free(cands); free(acc_smooth); free(accum); free(nz_xy); free(dx_buf); free(dy_buf); free(mag); free(edges); return -4; }
                    cands = nc;
                }
                cands[ncand].idx = (int32_t)(y * aw + x);
                cands[ncand].score = v;
                ncand++;
            }
        }
    }
    qsort(cands, (size_t)ncand, sizeof(sr_hough_cand), cmp_hough_desc);

    // 4. Radius estimation & verification for each candidate center
    float *dists = (float *)malloc((size_t)nz_cnt * sizeof(float));
    int32_t out_cap = 64, n_out = 0;
    sr_circle_cand *accepted = (sr_circle_cand *)malloc((size_t)out_cap * sizeof(sr_circle_cand));
    if (!dists || !accepted) {
        free(dists); free(accepted); free(cands); free(acc_smooth); free(accum); free(nz_xy); free(dx_buf); free(dy_buf); free(mag); free(edges);
        return -4;
    }

    double min_dist2 = min_dist * min_dist;
    double dr = (dp > 1.0) ? dp : 1.0;

    for (int32_t ci = 0; ci < ncand; ci++) {
        int32_t ax = cands[ci].idx % aw, ay = cands[ci].idx / aw;
        // Sub-pixel weighted centroid in 3x3 around (ax, ay)
        double wx = 0.0, wy = 0.0, ws = 0.0;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int32_t xx = ax + dx, yy = ay + dy;
                if (xx >= 0 && xx < aw && yy >= 0 && yy < ah) {
                    double wv = (double)accum[(size_t)(yy + 1) * astr + (size_t)(xx + 1)];
                    wx += (double)xx * wv;
                    wy += (double)yy * wv;
                    ws += wv;
                }
            }
        }
        float cx = (float)((ws > 0.0 ? (wx / ws) : (double)ax) * dp);
        float cy = (float)((ws > 0.0 ? (wy / ws) : (double)ay) * dp);

        int too_close = 0;
        for (int32_t k = 0; k < n_out; k++) {
            double ddx = (double)cx - (double)accepted[k].x;
            double ddy = (double)cy - (double)accepted[k].y;
            if (ddx * ddx + ddy * ddy < min_dist2) { too_close = 1; break; }
        }
        if (too_close) continue;

        int32_t dc = 0;
        for (int32_t k = 0; k < nz_cnt; k++) {
            float px = (float)nz_xy[(size_t)k * 2];
            float py = (float)nz_xy[(size_t)k * 2 + 1];
            float r = hypotf(px - cx, py - cy);
            if (r >= (float)r_min && r <= (float)r_max) {
                // For GRADIENT_ALT, check gradient alignment with radial vector
                if (method == 4) {
                    size_t pidx = (size_t)nz_xy[(size_t)k * 2 + 1] * (size_t)w + (size_t)nz_xy[(size_t)k * 2];
                    double gx = (double)dx_buf[pidx], gy = (double)dy_buf[pidx];
                    double m = (double)mag[pidx];
                    double dot = fabs((gx * (px - cx) + gy * (py - cy)) / (m * (double)r + 1e-9));
                    if (dot < 0.85) continue;
                }
                dists[dc++] = r;
            }
        }
        if (dc < 3) continue;
        qsort(dists, (size_t)dc, sizeof(float), cmp_float_asc);

        // Sliding window of width max(2*dr, 3.0) over sorted radii to find strongest radius cluster
        double win = (dr > 1.5) ? (2.0 * dr) : 3.0;
        int32_t best_cnt = 0;
        float best_r = 0.0f;
        int32_t left = 0;
        for (int32_t right = 0; right < dc; right++) {
            while ((double)(dists[right] - dists[left]) > win) left++;
            int32_t cnt = right - left + 1;
            if (cnt >= best_cnt) {
                best_cnt = cnt;
                best_r = dists[(left + right) / 2];
            }
        }
        if (best_r <= 0.0f) continue;

        if (method == 4) {
            // param2 in HOUGH_GRADIENT_ALT is perfection threshold in (0, 1] (coverage / completeness)
            double circum = 2.0 * M_PI * (double)best_r;
            double ratio = (double)best_cnt / (circum > 1.0 ? circum : 1.0);
            double thresh = (param2 <= 1.0) ? (param2 * 0.5) : 0.4;
            if (ratio < thresh) continue;
        } else {
            if ((double)best_cnt < (param2 * 0.5) && (double)cands[ci].score < param2) continue;
            if (best_cnt < 4) continue;
        }

        if (n_out == out_cap) {
            out_cap *= 2;
            sr_circle_cand *na = (sr_circle_cand *)realloc(accepted, (size_t)out_cap * sizeof(sr_circle_cand));
            if (!na) break;
            accepted = na;
        }
        accepted[n_out++] = (sr_circle_cand){cx, cy, best_r, (float)best_cnt};
        if (circles_max > 0 && n_out >= circles_max) break;
    }

    if (n_out > 0) {
        qsort(accepted, (size_t)n_out, sizeof(sr_circle_cand), cmp_circle_desc);
        float *res = (float *)malloc((size_t)n_out * 3 * sizeof(float));
        if (res) {
            for (int32_t i = 0; i < n_out; i++) {
                res[i * 3 + 0] = accepted[i].x;
                res[i * 3 + 1] = accepted[i].y;
                res[i * 3 + 2] = accepted[i].r;
            }
            *out_circles = res;
            *out_count = n_out;
        }
    }

    free(dists); free(accepted); free(cands); free(acc_smooth);
    free(accum); free(nz_xy); free(dx_buf); free(dy_buf); free(mag); free(edges);
    return 0;
}

// ---------------------------------------------------------------------------
// LineSegmentDetector (Grompone von Gioi et al. 2012) + drawSegments + compareSegments
// ---------------------------------------------------------------------------

#define LSD_NOTDEF -1024.0
#define LSD_NOTUSED 0
#define LSD_USED 1

typedef struct {
    int32_t x, y;
    double angle, modgrad;
} sr_lsd_pt;

typedef struct {
    double x1, y1, x2, y2, width, prec, p, log_nfa;
    double x, y, dx, dy;
} sr_lsd_rect;

static double angle_diff_d(double a, double b) {
    a -= b;
    while (a <= -M_PI) a += 2.0 * M_PI;
    while (a > M_PI) a -= 2.0 * M_PI;
    return fabs(a);
}

static int lsd_aligned(double a, double b, double prec) {
    return angle_diff_d(a, b) <= prec;
}

static double lsd_log_gamma(double x) {
    return lgamma(x);
}

static double lsd_nfa(int32_t n, int32_t k, double p, double log_nt) {
    if (n == 0 || k == 0) return -log_nt;
    if (n == k) return -log_nt - (double)n * log10(p);

    double log1term = lsd_log_gamma((double)n + 1.0) - lsd_log_gamma((double)k + 1.0) -
                      lsd_log_gamma((double)(n - k) + 1.0) +
                      (double)k * log(p) + (double)(n - k) * log(1.0 - p);
    double term = exp(log1term);
    if (term == 0.0) return (k > (double)n * p) ? 100.0 : -log_nt;

    double bin_tail = term;
    double p_term = p / (1.0 - p);
    for (int32_t i = k + 1; i <= n; i++) {
        double bin_term = (double)(n - i + 1) / (double)i;
        double mult_term = bin_term * p_term;
        term *= mult_term;
        bin_tail += term;
        if (bin_term < 1.0 && term * (1.0 / (1.0 - mult_term)) < 1e-10) break;
    }
    double nfa_val = -log10(bin_tail) - log_nt;
    return isfinite(nfa_val) ? nfa_val : -log_nt;
}

static void lsd_region2rect(const sr_lsd_pt *reg, int32_t reg_size, double reg_angle,
                            double prec, double p, sr_lsd_rect *rect) {
    double x = 0.0, y = 0.0, sum = 0.0;
    for (int32_t i = 0; i < reg_size; i++) {
        double w = reg[i].modgrad;
        x += (double)reg[i].x * w;
        y += (double)reg[i].y * w;
        sum += w;
    }
    if (sum <= 0.0) sum = 1.0;
    x /= sum;
    y /= sum;

    double cxx = 0.0, cyy = 0.0, cxy = 0.0;
    for (int32_t i = 0; i < reg_size; i++) {
        double w = reg[i].modgrad;
        double dx = (double)reg[i].x - x;
        double dy = (double)reg[i].y - y;
        cxx += dx * dx * w;
        cyy += dy * dy * w;
        cxy += dx * dy * w;
    }
    double theta = 0.5 * atan2(2.0 * cxy, cxx - cyy);
    double dx = cos(theta), dy = sin(theta);
    // Orient along reg_angle
    if (dx * cos(reg_angle) + dy * sin(reg_angle) < 0.0) {
        dx = -dx; dy = -dy;
    }

    double l_min = 0.0, l_max = 0.0, w_min = 0.0, w_max = 0.0;
    for (int32_t i = 0; i < reg_size; i++) {
        double px = (double)reg[i].x - x;
        double py = (double)reg[i].y - y;
        double l = px * dx + py * dy;
        double w = -px * dy + py * dx;
        if (l < l_min) l_min = l;
        if (l > l_max) l_max = l;
        if (w < w_min) w_min = w;
        if (w > w_max) w_max = w;
    }
    rect->x1 = x + l_min * dx;
    rect->y1 = y + l_min * dy;
    rect->x2 = x + l_max * dx;
    rect->y2 = y + l_max * dy;
    rect->width = w_max - w_min;
    if (rect->width < 1.0) rect->width = 1.0;
    rect->x = x;
    rect->y = y;
    rect->dx = dx;
    rect->dy = dy;
    rect->prec = prec;
    rect->p = p;
    rect->log_nfa = -1.0;
}

static double lsd_rect_nfa(const sr_lsd_rect *rect, const double *angles, int32_t sw, int32_t sh, double log_nt) {
    double dx = rect->x2 - rect->x1, dy = rect->y2 - rect->y1;
    double len = hypot(dx, dy);
    if (len < 1.0) return -log_nt;
    double ux = dx / len, uy = dy / len;
    double nx = -uy, ny = ux;
    double hw = rect->width * 0.5;
    double theta = atan2(uy, ux);

    double xs[4] = {
        rect->x1 - hw * nx, rect->x1 + hw * nx,
        rect->x2 + hw * nx, rect->x2 - hw * nx
    };
    double ys[4] = {
        rect->y1 - hw * ny, rect->y1 + hw * ny,
        rect->y2 + hw * ny, rect->y2 - hw * ny
    };
    int32_t x0 = (int32_t)floor(fmin(fmin(xs[0], xs[1]), fmin(xs[2], xs[3])));
    int32_t x1 = (int32_t)ceil(fmax(fmax(xs[0], xs[1]), fmax(xs[2], xs[3])));
    int32_t y0 = (int32_t)floor(fmin(fmin(ys[0], ys[1]), fmin(ys[2], ys[3])));
    int32_t y1 = (int32_t)ceil(fmax(fmax(ys[0], ys[1]), fmax(ys[2], ys[3])));
    if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0;
    if (x1 >= sw) x1 = sw - 1; if (y1 >= sh) y1 = sh - 1;

    int32_t total = 0, aligned = 0;
    for (int32_t py = y0; py <= y1; py++) {
        for (int32_t px = x0; px <= x1; px++) {
            double rx = (double)px - rect->x1;
            double ry = (double)py - rect->y1;
            double pl = rx * ux + ry * uy;
            double pw = fabs(rx * nx + ry * ny);
            if (pl >= -0.5 && pl <= len + 0.5 && pw <= hw + 0.5) {
                total++;
                double a = angles[(size_t)py * (size_t)sw + (size_t)px];
                if (a != LSD_NOTDEF && lsd_aligned(a, theta, rect->prec)) aligned++;
            }
        }
    }
    return lsd_nfa(total, aligned, rect->p, log_nt);
}

int32_t sr_c_p4_lsd_detect(const uint8_t *img, int32_t w, int32_t h, int32_t stride,
                           int32_t refine, double scale, double sigma_scale, double quant,
                           double ang_th, double log_eps, double density_th, int32_t n_bins,
                           float **out_lines, double **out_width, double **out_prec, double **out_nfa,
                           int32_t *out_count) {
    if (!img || !out_lines || !out_width || !out_prec || !out_nfa || !out_count ||
        w <= 0 || h <= 0 || scale <= 0.0 || scale > 1.0 || n_bins <= 0) return -1;
    *out_lines = NULL; *out_width = NULL; *out_prec = NULL; *out_nfa = NULL; *out_count = 0;
    if (w < 2 || h < 2) return 0;

    int32_t sw = (scale == 1.0) ? w : sr_round_d((double)w * scale);
    int32_t sh = (scale == 1.0) ? h : sr_round_d((double)h * scale);
    if (sw < 2 || sh < 2) return 0;

    double *scaled = (double *)malloc((size_t)sw * (size_t)sh * sizeof(double));
    if (!scaled) return -4;

    if (scale == 1.0) {
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *row = img + (size_t)y * (size_t)stride;
            for (int32_t x = 0; x < w; x++) scaled[(size_t)y * (size_t)sw + (size_t)x] = (double)row[x];
        }
    } else {
        double sigma = (scale < 1.0) ? (sigma_scale / scale) : sigma_scale;
        int32_t rad = (int32_t)ceil(sigma * 3.0);
        if (rad < 1) rad = 1;
        int32_t klen = 2 * rad + 1;
        double *kern = (double *)malloc((size_t)klen * sizeof(double));
        double *tmp = (double *)malloc((size_t)w * (size_t)h * sizeof(double));
        double *blurred = (double *)malloc((size_t)w * (size_t)h * sizeof(double));
        if (!kern || !tmp || !blurred) { free(kern); free(tmp); free(blurred); free(scaled); return -4; }
        double ksum = 0.0;
        for (int32_t i = -rad; i <= rad; i++) {
            double v = exp(-0.5 * ((double)i * (double)i) / (sigma * sigma));
            kern[i + rad] = v; ksum += v;
        }
        for (int32_t i = 0; i < klen; i++) kern[i] /= ksum;
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *row = img + (size_t)y * (size_t)stride;
            for (int32_t x = 0; x < w; x++) {
                double s = 0.0;
                for (int32_t k = -rad; k <= rad; k++) {
                    int32_t xx = x + k;
                    if (xx < 0) xx = -xx; if (xx >= w) xx = 2 * w - 2 - xx;
                    if (xx < 0) xx = 0; if (xx >= w) xx = w - 1;
                    s += (double)row[xx] * kern[k + rad];
                }
                tmp[(size_t)y * (size_t)w + (size_t)x] = s;
            }
        }
        for (int32_t y = 0; y < h; y++) {
            for (int32_t x = 0; x < w; x++) {
                double s = 0.0;
                for (int32_t k = -rad; k <= rad; k++) {
                    int32_t yy = y + k;
                    if (yy < 0) yy = -yy; if (yy >= h) yy = 2 * h - 2 - yy;
                    if (yy < 0) yy = 0; if (yy >= h) yy = h - 1;
                    s += tmp[(size_t)yy * (size_t)w + (size_t)x] * kern[k + rad];
                }
                blurred[(size_t)y * (size_t)w + (size_t)x] = s;
            }
        }
        for (int32_t y = 0; y < sh; y++) {
            double sy = ((double)y + 0.5) / scale - 0.5;
            int32_t iy = (int32_t)floor(sy);
            double fy = sy - iy;
            if (iy < 0) { iy = 0; fy = 0.0; }
            if (iy >= h - 1) { iy = h - 2; fy = 1.0; }
            for (int32_t x = 0; x < sw; x++) {
                double sx = ((double)x + 0.5) / scale - 0.5;
                int32_t ix = (int32_t)floor(sx);
                double fx = sx - ix;
                if (ix < 0) { ix = 0; fx = 0.0; }
                if (ix >= w - 1) { ix = w - 2; fx = 1.0; }
                double v00 = blurred[(size_t)iy * (size_t)w + (size_t)ix];
                double v10 = blurred[(size_t)iy * (size_t)w + (size_t)(ix + 1)];
                double v01 = blurred[(size_t)(iy + 1) * (size_t)w + (size_t)ix];
                double v11 = blurred[(size_t)(iy + 1) * (size_t)w + (size_t)(ix + 1)];
                scaled[(size_t)y * (size_t)sw + (size_t)x] =
                    (v00 * (1.0 - fx) + v10 * fx) * (1.0 - fy) + (v01 * (1.0 - fx) + v11 * fx) * fy;
            }
        }
        free(kern); free(tmp); free(blurred);
    }

    size_t snpix = (size_t)sw * (size_t)sh;
    double *angles = (double *)malloc(snpix * sizeof(double));
    double *modgrad = (double *)calloc(snpix, sizeof(double));
    uint8_t *used = (uint8_t *)calloc(snpix, 1);
    int32_t *bin_head = (int32_t *)malloc((size_t)n_bins * sizeof(int32_t));
    int32_t *bin_next = (int32_t *)malloc(snpix * sizeof(int32_t));
    sr_lsd_pt *reg = (sr_lsd_pt *)malloc(snpix * sizeof(sr_lsd_pt));
    if (!angles || !modgrad || !used || !bin_head || !bin_next || !reg) {
        free(scaled); free(angles); free(modgrad); free(used); free(bin_head); free(bin_next); free(reg);
        return -4;
    }

    double prec = ang_th * (M_PI / 180.0);
    double p = ang_th / 180.0;
    double threshold = quant / sin(prec);
    double max_grad = 0.0;

    for (size_t i = 0; i < snpix; i++) { angles[i] = LSD_NOTDEF; bin_next[i] = -1; }
    for (int32_t i = 0; i < n_bins; i++) bin_head[i] = -1;

    for (int32_t y = 0; y < sh - 1; y++) {
        for (int32_t x = 0; x < sw - 1; x++) {
            double i00 = scaled[(size_t)y * (size_t)sw + (size_t)x];
            double i10 = scaled[(size_t)y * (size_t)sw + (size_t)(x + 1)];
            double i01 = scaled[(size_t)(y + 1) * (size_t)sw + (size_t)x];
            double i11 = scaled[(size_t)(y + 1) * (size_t)sw + (size_t)(x + 1)];
            double com1 = i11 - i00;
            double com2 = i10 - i01;
            double gx = 0.5 * (com1 + com2);
            double gy = 0.5 * (com1 - com2);
            double norm = hypot(gx, gy);
            size_t idx = (size_t)y * (size_t)sw + (size_t)x;
            modgrad[idx] = norm;
            if (norm <= threshold) {
                used[idx] = LSD_USED;
            } else {
                angles[idx] = atan2(gx, -gy);
                if (norm > max_grad) max_grad = norm;
            }
        }
    }
    for (int32_t x = 0; x < sw; x++) used[(size_t)(sh - 1) * (size_t)sw + (size_t)x] = LSD_USED;
    for (int32_t y = 0; y < sh; y++) used[(size_t)y * (size_t)sw + (size_t)(sw - 1)] = LSD_USED;

    if (max_grad > threshold) {
        double bin_scale = (double)(n_bins - 1) / max_grad;
        for (int32_t y = 0; y < sh - 1; y++) {
            for (int32_t x = 0; x < sw - 1; x++) {
                size_t idx = (size_t)y * (size_t)sw + (size_t)x;
                if (used[idx]) continue;
                int32_t b = (int32_t)(modgrad[idx] * bin_scale);
                if (b < 0) b = 0; if (b >= n_bins) b = n_bins - 1;
                bin_next[idx] = bin_head[b];
                bin_head[b] = (int32_t)idx;
            }
        }
    }

    double log_nt = 5.0 * (log10((double)sw) + log10((double)sh)) * 0.5 + log10(11.0);
    int32_t min_reg_size = (int32_t)(-log_nt / log10(p));
    if (min_reg_size < 2) min_reg_size = 2;

    int32_t cap = 128, nlines = 0;
    sr_lsd_rect *rects = (sr_lsd_rect *)malloc((size_t)cap * sizeof(sr_lsd_rect));
    if (!rects) {
        free(scaled); free(angles); free(modgrad); free(used); free(bin_head); free(bin_next); free(reg);
        return -4;
    }

    for (int32_t b = n_bins - 1; b >= 0; b--) {
        for (int32_t seed = bin_head[b]; seed >= 0; seed = bin_next[seed]) {
            if (used[seed]) continue;
            int32_t sx = seed % sw, sy = seed / sw;
            double reg_angle = angles[seed];
            double sumdx = cos(reg_angle), sumdy = sin(reg_angle);
            used[seed] = LSD_USED;
            int32_t reg_size = 0;
            reg[reg_size++] = (sr_lsd_pt){sx, sy, reg_angle, modgrad[seed]};

            for (int32_t i = 0; i < reg_size; i++) {
                int32_t cx = reg[i].x, cy = reg[i].y;
                for (int dy = -1; dy <= 1; dy++) {
                    int32_t ny = cy + dy;
                    if (ny < 0 || ny >= sh) continue;
                    for (int dx = -1; dx <= 1; dx++) {
                        int32_t nx = cx + dx;
                        if (nx < 0 || nx >= sw) continue;
                        size_t nidx = (size_t)ny * (size_t)sw + (size_t)nx;
                        if (used[nidx] || angles[nidx] == LSD_NOTDEF) continue;
                        if (lsd_aligned(angles[nidx], reg_angle, prec)) {
                            used[nidx] = LSD_USED;
                            sumdx += cos(angles[nidx]);
                            sumdy += sin(angles[nidx]);
                            reg_angle = atan2(sumdy, sumdx);
                            reg[reg_size++] = (sr_lsd_pt){nx, ny, angles[nidx], modgrad[nidx]};
                        }
                    }
                }
            }

            if (reg_size < min_reg_size) continue;

            sr_lsd_rect rect;
            lsd_region2rect(reg, reg_size, reg_angle, prec, p, &rect);
            double rect_len = hypot(rect.x2 - rect.x1, rect.y2 - rect.y1);
            double density = (double)reg_size / (rect_len * rect.width + 1e-9);

            // If low density, try reducing radius around seed or refining angle
            if (density < density_th) {
                double xc = (double)reg[0].x, yc = (double)reg[0].y;
                double rad_lim = rect_len * 0.5;
                int32_t trimmed = reg_size;
                for (int tries = 0; tries < 4 && density < density_th && trimmed >= min_reg_size; tries++) {
                    rad_lim *= 0.75;
                    int32_t keep = 0;
                    for (int32_t i = 0; i < trimmed; i++) {
                        if (hypot((double)reg[i].x - xc, (double)reg[i].y - yc) <= rad_lim) {
                            reg[keep++] = reg[i];
                        } else {
                            used[(size_t)reg[i].y * (size_t)sw + (size_t)reg[i].x] = LSD_NOTUSED;
                        }
                    }
                    trimmed = keep;
                    if (trimmed < min_reg_size) break;
                    lsd_region2rect(reg, trimmed, reg_angle, prec, p, &rect);
                    rect_len = hypot(rect.x2 - rect.x1, rect.y2 - rect.y1);
                    density = (double)trimmed / (rect_len * rect.width + 1e-9);
                }
                if (trimmed < min_reg_size || density < density_th) continue;
            }

            double nfa = (refine == 0) ? 1.0 : lsd_rect_nfa(&rect, angles, sw, sh, log_nt);
            if (refine != 0 && nfa <= log_eps) {
                // Simple precision refinement
                sr_lsd_rect alt = rect;
                alt.prec *= 0.5;
                alt.p *= 0.5;
                double nfa2 = lsd_rect_nfa(&alt, angles, sw, sh, log_nt);
                if (nfa2 > nfa) { rect = alt; nfa = nfa2; }
                if (nfa <= log_eps) continue;
            }
            rect.log_nfa = nfa;
            if (rect_len < 1.0) continue;

            if (nlines == cap) {
                cap *= 2;
                sr_lsd_rect *nr = (sr_lsd_rect *)realloc(rects, (size_t)cap * sizeof(sr_lsd_rect));
                if (!nr) break;
                rects = nr;
            }
            rects[nlines++] = rect;
        }
    }

    if (nlines > 0) {
        float *ol = (float *)malloc((size_t)nlines * 4 * sizeof(float));
        double *ow = (double *)malloc((size_t)nlines * sizeof(double));
        double *op = (double *)malloc((size_t)nlines * sizeof(double));
        double *on = (refine == 2) ? (double *)malloc((size_t)nlines * sizeof(double)) : NULL;
        if (!ol || !ow || !op || (refine == 2 && !on)) {
            free(ol); free(ow); free(op); free(on);
        } else {
            double inv_s = 1.0 / scale;
            double corr = (scale == 1.0) ? 0.0 : (0.5 / scale - 0.5);
            for (int32_t i = 0; i < nlines; i++) {
                ol[i * 4 + 0] = (float)(rects[i].x1 * inv_s + corr);
                ol[i * 4 + 1] = (float)(rects[i].y1 * inv_s + corr);
                ol[i * 4 + 2] = (float)(rects[i].x2 * inv_s + corr);
                ol[i * 4 + 3] = (float)(rects[i].y2 * inv_s + corr);
                ow[i] = rects[i].width * inv_s;
                op[i] = rects[i].p;
                if (on) on[i] = rects[i].log_nfa;
            }
            *out_lines = ol;
            *out_width = ow;
            *out_prec = op;
            *out_nfa = on;
            *out_count = nlines;
        }
    }

    free(rects); free(scaled); free(angles); free(modgrad); free(used); free(bin_head); free(bin_next); free(reg);
    return 0;
}

static void draw_line_bgr_u8(uint8_t *img, int32_t w, int32_t h, int32_t stride,
                             int32_t x0, int32_t y0, int32_t x1, int32_t y1,
                             uint8_t b, uint8_t g, uint8_t r) {
    int32_t dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int32_t dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int32_t err = dx + dy;
    for (;;) {
        if (x0 >= 0 && x0 < w && y0 >= 0 && y0 < h) {
            uint8_t *px = img + (size_t)y0 * (size_t)stride + (size_t)x0 * 3;
            px[0] = b; px[1] = g; px[2] = r;
        }
        if (x0 == x1 && y0 == y1) break;
        int32_t e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

static void draw_line_mask_u8(uint8_t *mask, int32_t w, int32_t h,
                              int32_t x0, int32_t y0, int32_t x1, int32_t y1) {
    int32_t dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int32_t dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int32_t err = dx + dy;
    for (;;) {
        if (x0 >= 0 && x0 < w && y0 >= 0 && y0 < h) mask[(size_t)y0 * (size_t)w + (size_t)x0] = 1;
        if (x0 == x1 && y0 == y1) break;
        int32_t e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

int32_t sr_c_p4_lsd_draw(uint8_t *bgr, int32_t w, int32_t h, int32_t stride,
                         const float *lines, int32_t nlines) {
    if (!bgr || w <= 0 || h <= 0 || (nlines > 0 && !lines)) return -1;
    for (int32_t i = 0; i < nlines; i++) {
        int32_t x1 = sr_round_d((double)lines[i * 4 + 0]);
        int32_t y1 = sr_round_d((double)lines[i * 4 + 1]);
        int32_t x2 = sr_round_d((double)lines[i * 4 + 2]);
        int32_t y2 = sr_round_d((double)lines[i * 4 + 3]);
        draw_line_bgr_u8(bgr, w, h, stride, x1, y1, x2, y2, 0, 0, 255);
    }
    return 0;
}

int32_t sr_c_p4_lsd_compare(int32_t w, int32_t h,
                            const float *l1, int32_t n1, const float *l2, int32_t n2,
                            uint8_t *bgr, int32_t stride, int32_t *out_mismatch) {
    if (!out_mismatch || w <= 0 || h <= 0 || (n1 > 0 && !l1) || (n2 > 0 && !l2)) return -1;
    uint8_t *m1 = (uint8_t *)calloc((size_t)w * (size_t)h, 1);
    uint8_t *m2 = (uint8_t *)calloc((size_t)w * (size_t)h, 1);
    if (!m1 || !m2) { free(m1); free(m2); return -4; }

    for (int32_t i = 0; i < n1; i++) {
        int32_t x1 = sr_round_d((double)l1[i * 4 + 0]);
        int32_t y1 = sr_round_d((double)l1[i * 4 + 1]);
        int32_t x2 = sr_round_d((double)l1[i * 4 + 2]);
        int32_t y2 = sr_round_d((double)l1[i * 4 + 3]);
        draw_line_mask_u8(m1, w, h, x1, y1, x2, y2);
        if (bgr) draw_line_bgr_u8(bgr, w, h, stride, x1, y1, x2, y2, 255, 0, 0);
    }
    for (int32_t i = 0; i < n2; i++) {
        int32_t x1 = sr_round_d((double)l2[i * 4 + 0]);
        int32_t y1 = sr_round_d((double)l2[i * 4 + 1]);
        int32_t x2 = sr_round_d((double)l2[i * 4 + 2]);
        int32_t y2 = sr_round_d((double)l2[i * 4 + 3]);
        draw_line_mask_u8(m2, w, h, x1, y1, x2, y2);
        if (bgr) draw_line_bgr_u8(bgr, w, h, stride, x1, y1, x2, y2, 0, 0, 255);
    }
    int32_t diff = 0;
    size_t np = (size_t)w * (size_t)h;
    for (size_t i = 0; i < np; i++) {
        if (m1[i] != m2[i]) diff++;
    }
    *out_mismatch = diff;
    free(m1); free(m2);
    return 0;
}

// ---------------------------------------------------------------------------
// floodFill (4/8-conn, FIXED_RANGE, MASK_ONLY, u8/s32/f32, 1/3 channels)
// ---------------------------------------------------------------------------

static void read_pix(const uint8_t *base, int32_t stride, int32_t ch, int32_t depth,
                     int32_t x, int32_t y, double *out) {
    const uint8_t *row = base + (size_t)y * (size_t)stride;
    if (depth == 0) {
        for (int c = 0; c < ch; c++) out[c] = (double)row[(size_t)x * (size_t)ch + (size_t)c];
    } else if (depth == 4) {
        const int32_t *r = (const int32_t *)row;
        for (int c = 0; c < ch; c++) out[c] = (double)r[(size_t)x * (size_t)ch + (size_t)c];
    } else {
        const float *r = (const float *)row;
        for (int c = 0; c < ch; c++) out[c] = (double)r[(size_t)x * (size_t)ch + (size_t)c];
    }
}

static void write_pix(uint8_t *base, int32_t stride, int32_t ch, int32_t depth,
                      int32_t x, int32_t y, const double *val) {
    uint8_t *row = base + (size_t)y * (size_t)stride;
    if (depth == 0) {
        for (int c = 0; c < ch; c++) row[(size_t)x * (size_t)ch + (size_t)c] = sr_sat_u8_d(val[c]);
    } else if (depth == 4) {
        int32_t *r = (int32_t *)row;
        for (int c = 0; c < ch; c++) r[(size_t)x * (size_t)ch + (size_t)c] = sr_round_d(val[c]);
    } else {
        float *r = (float *)row;
        for (int c = 0; c < ch; c++) r[(size_t)x * (size_t)ch + (size_t)c] = (float)val[c];
    }
}

static int pix_in_range(const double *cand, const double *ref, const double *lo, const double *up, int32_t ch) {
    for (int c = 0; c < ch; c++) {
        if (cand[c] < ref[c] - lo[c] || cand[c] > ref[c] + up[c]) return 0;
    }
    return 1;
}

int32_t sr_c_p4_flood_fill(void *img, int32_t w, int32_t h, int32_t stride, int32_t ch, int32_t depth,
                           uint8_t *mask, int32_t mask_stride, int32_t sx, int32_t sy,
                           const double *new_val, const double *lo_diff, const double *up_diff,
                           int32_t flags, int32_t *out_area, int32_t *out_rect4) {
    if (!img || !mask || !new_val || !lo_diff || !up_diff || !out_area || !out_rect4) return -1;
    if (w <= 0 || h <= 0 || (ch != 1 && ch != 3)) return -1;
    if (depth != 0 && depth != 4 && depth != 5) return -2;
    if (sx < 0 || sx >= w || sy < 0 || sy >= h) return -1;

    int32_t conn = flags & 0xff;
    if (conn == 0) conn = 4;
    if (conn != 4 && conn != 8) return -1;

    uint8_t mask_val = (uint8_t)((flags >> 8) & 0xff);
    if (mask_val == 0) mask_val = 1;
    int32_t fixed_range = (flags & 65536) != 0;
    int32_t mask_only = (flags & 131072) != 0;

    // Set outer 1px border of (h+2)x(w+2) mask to 1 (OpenCV parity)
    for (int32_t x = 0; x < w + 2; x++) {
        mask[x] = 1;
        mask[(size_t)(h + 1) * (size_t)mask_stride + (size_t)x] = 1;
    }
    for (int32_t y = 0; y < h + 2; y++) {
        mask[(size_t)y * (size_t)mask_stride] = 1;
        mask[(size_t)y * (size_t)mask_stride + (size_t)(w + 1)] = 1;
    }

    if (mask[(size_t)(sy + 1) * (size_t)mask_stride + (size_t)(sx + 1)] != 0) {
        *out_area = 0;
        out_rect4[0] = 0; out_rect4[1] = 0; out_rect4[2] = 0; out_rect4[3] = 0;
        return 0;
    }

    typedef struct { int32_t x, y; double ref[3]; } ff_node;
    ff_node *queue = (ff_node *)malloc((size_t)w * (size_t)h * sizeof(ff_node));
    if (!queue) return -4;

    uint8_t *base = (uint8_t *)img;
    double seed_val[3] = {0, 0, 0};
    read_pix(base, stride, ch, depth, sx, sy, seed_val);

    size_t head = 0, tail = 0;
    mask[(size_t)(sy + 1) * (size_t)mask_stride + (size_t)(sx + 1)] = mask_val;
    queue[tail++] = (ff_node){sx, sy, {seed_val[0], seed_val[1], seed_val[2]}};
    if (!mask_only) write_pix(base, stride, ch, depth, sx, sy, new_val);

    int32_t xmin = sx, xmax = sx, ymin = sy, ymax = sy;
    int32_t area = 1;
    static const int dx8[8] = {1, -1, 0, 0, 1, -1, 1, -1};
    static const int dy8[8] = {0, 0, 1, -1, 1, 1, -1, -1};

    while (head < tail) {
        ff_node cur = queue[head++];
        const double *ref = fixed_range ? seed_val : cur.ref;
        for (int d = 0; d < conn; d++) {
            int32_t nx = cur.x + dx8[d];
            int32_t ny = cur.y + dy8[d];
            if (nx < 0 || nx >= w || ny < 0 || ny >= h) continue;
            uint8_t *mp = &mask[(size_t)(ny + 1) * (size_t)mask_stride + (size_t)(nx + 1)];
            if (*mp != 0) continue;
            double cand[3] = {0, 0, 0};
            read_pix(base, stride, ch, depth, nx, ny, cand);
            if (!pix_in_range(cand, ref, lo_diff, up_diff, ch)) continue;
            *mp = mask_val;
            if (!mask_only) write_pix(base, stride, ch, depth, nx, ny, new_val);
            if (nx < xmin) xmin = nx; if (nx > xmax) xmax = nx;
            if (ny < ymin) ymin = ny; if (ny > ymax) ymax = ny;
            area++;
            queue[tail++] = (ff_node){nx, ny, {cand[0], cand[1], cand[2]}};
        }
    }

    free(queue);
    *out_area = area;
    out_rect4[0] = xmin;
    out_rect4[1] = ymin;
    out_rect4[2] = xmax - xmin + 1;
    out_rect4[3] = ymax - ymin + 1;
    return 0;
}

// ---------------------------------------------------------------------------
// watershed (Meyer priority-queue, 256-bucket ring, -1 boundaries)
// ---------------------------------------------------------------------------

static inline int32_t ws_diff(const uint8_t *a, const uint8_t *b) {
    int32_t d0 = abs((int32_t)a[0] - (int32_t)b[0]);
    int32_t d1 = abs((int32_t)a[1] - (int32_t)b[1]);
    int32_t d2 = abs((int32_t)a[2] - (int32_t)b[2]);
    int32_t m = (d0 > d1) ? d0 : d1;
    return (d2 > m) ? d2 : m;
}

int32_t sr_c_p4_watershed(const uint8_t *img, int32_t w, int32_t h, int32_t img_stride,
                          int32_t *markers, int32_t m_stride_bytes) {
    if (!img || !markers || w <= 0 || h <= 0) return -1;
    int32_t ms = m_stride_bytes / 4;
    if (m_stride_bytes % 4 != 0 || ms < w) return -1;

    // Set outer 1px border to -1
    for (int32_t x = 0; x < w; x++) {
        markers[x] = -1;
        markers[(size_t)(h - 1) * (size_t)ms + (size_t)x] = -1;
    }
    for (int32_t y = 0; y < h; y++) {
        markers[(size_t)y * (size_t)ms] = -1;
        markers[(size_t)y * (size_t)ms + (size_t)(w - 1)] = -1;
    }
    if (w <= 2 || h <= 2) return 0;

    size_t npix = (size_t)w * (size_t)h;
    int32_t *qnext = (int32_t *)malloc(npix * sizeof(int32_t));
    uint8_t *inq = (uint8_t *)calloc(npix, 1);
    if (!qnext || !inq) { free(qnext); free(inq); return -4; }
    for (size_t i = 0; i < npix; i++) qnext[i] = -1;

    int32_t qhead[256], qtail[256];
    for (int i = 0; i < 256; i++) { qhead[i] = -1; qtail[i] = -1; }

    #define WS_PUSH(qidx, node) do { \
        int32_t _q = (qidx); int32_t _n = (node); \
        qnext[_n] = -1; \
        if (qtail[_q] >= 0) qnext[qtail[_q]] = _n; \
        else qhead[_q] = _n; \
        qtail[_q] = _n; \
    } while (0)

    // Normalize negative interior markers to 0 and push unlabeled pixels adjacent to markers
    for (int32_t y = 1; y < h - 1; y++) {
        for (int32_t x = 1; x < w - 1; x++) {
            if (markers[(size_t)y * (size_t)ms + (size_t)x] < 0) {
                markers[(size_t)y * (size_t)ms + (size_t)x] = 0;
            }
        }
    }

    int32_t active_q = 256;
    static const int dx4[4] = {-1, 1, 0, 0};
    static const int dy4[4] = {0, 0, -1, 1};

    for (int32_t y = 1; y < h - 1; y++) {
        const uint8_t *irow = img + (size_t)y * (size_t)img_stride;
        for (int32_t x = 1; x < w - 1; x++) {
            if (markers[(size_t)y * (size_t)ms + (size_t)x] != 0) continue;
            const uint8_t *p_rgb = irow + (size_t)x * 3;
            int32_t best_d = 256;
            for (int d = 0; d < 4; d++) {
                int32_t nx = x + dx4[d], ny = y + dy4[d];
                if (markers[(size_t)ny * (size_t)ms + (size_t)nx] > 0) {
                    const uint8_t *n_rgb = img + (size_t)ny * (size_t)img_stride + (size_t)nx * 3;
                    int32_t diff = ws_diff(p_rgb, n_rgb);
                    if (diff < best_d) best_d = diff;
                }
            }
            if (best_d < 256) {
                int32_t idx = y * w + x;
                inq[idx] = 1;
                WS_PUSH(best_d, idx);
                if (best_d < active_q) active_q = best_d;
            }
        }
    }

    while (active_q < 256) {
        if (qhead[active_q] < 0) { active_q++; continue; }
        int32_t idx = qhead[active_q];
        qhead[active_q] = qnext[idx];
        if (qhead[active_q] < 0) qtail[active_q] = -1;

        int32_t y = idx / w, x = idx % w;
        int32_t lab = 0;
        for (int d = 0; d < 4; d++) {
            int32_t nx = x + dx4[d], ny = y + dy4[d];
            int32_t nl = markers[(size_t)ny * (size_t)ms + (size_t)nx];
            if (nl > 0) {
                if (lab == 0) lab = nl;
                else if (lab != nl) { lab = -1; break; }
            }
        }
        if (lab == 0) continue;
        markers[(size_t)y * (size_t)ms + (size_t)x] = lab;
        if (lab < 0) continue; // watershed boundary: do not propagate further

        const uint8_t *p_rgb = img + (size_t)y * (size_t)img_stride + (size_t)x * 3;
        for (int d = 0; d < 4; d++) {
            int32_t nx = x + dx4[d], ny = y + dy4[d];
            if (nx <= 0 || nx >= w - 1 || ny <= 0 || ny >= h - 1) continue;
            if (markers[(size_t)ny * (size_t)ms + (size_t)nx] != 0) continue;
            int32_t nidx = ny * w + nx;
            if (inq[nidx]) continue;
            inq[nidx] = 1;
            const uint8_t *n_rgb = img + (size_t)ny * (size_t)img_stride + (size_t)nx * 3;
            int32_t diff = ws_diff(p_rgb, n_rgb);
            WS_PUSH(diff, nidx);
            if (diff < active_q) active_q = diff;
        }
    }

    #undef WS_PUSH
    free(qnext);
    free(inq);
    return 0;
}

// ---------------------------------------------------------------------------
// grabCut (5-component GMM + Boykov-Kolmogorov s-t min-cut)
// ---------------------------------------------------------------------------

typedef struct {
    double weight[5];
    double mean[5][3];
    double cov[5][9];
    double inv_cov[5][9];
    double det[5];
} sr_gmm;

static void gmm_calc_inv_det(sr_gmm *g, int k) {
    if (g->weight[k] <= 0.0) { g->det[k] = 0.0; return; }
    double c[9];
    memcpy(c, g->cov[k], sizeof(c));
    double d = c[0] * (c[4] * c[8] - c[5] * c[7]) -
               c[1] * (c[3] * c[8] - c[5] * c[6]) +
               c[2] * (c[3] * c[7] - c[4] * c[6]);
    if (d <= 1e-6) {
        c[0] += 0.01; c[4] += 0.01; c[8] += 0.01;
        d = c[0] * (c[4] * c[8] - c[5] * c[7]) -
            c[1] * (c[3] * c[8] - c[5] * c[6]) +
            c[2] * (c[3] * c[7] - c[4] * c[6]);
    }
    if (d <= 1e-12) { g->det[k] = 0.0; return; }
    g->det[k] = d;
    double inv_d = 1.0 / d;
    g->inv_cov[k][0] =  (c[4] * c[8] - c[5] * c[7]) * inv_d;
    g->inv_cov[k][1] = -(c[1] * c[8] - c[2] * c[7]) * inv_d;
    g->inv_cov[k][2] =  (c[1] * c[5] - c[2] * c[4]) * inv_d;
    g->inv_cov[k][3] = -(c[3] * c[8] - c[5] * c[6]) * inv_d;
    g->inv_cov[k][4] =  (c[0] * c[8] - c[2] * c[6]) * inv_d;
    g->inv_cov[k][5] = -(c[0] * c[5] - c[2] * c[3]) * inv_d;
    g->inv_cov[k][6] =  (c[3] * c[7] - c[4] * c[6]) * inv_d;
    g->inv_cov[k][7] = -(c[0] * c[7] - c[1] * c[6]) * inv_d;
    g->inv_cov[k][8] =  (c[0] * c[4] - c[1] * c[3]) * inv_d;
}

static void gmm_unpack(const double *model65, sr_gmm *g) {
    for (int k = 0; k < 5; k++) g->weight[k] = model65[k];
    for (int k = 0; k < 5; k++) {
        for (int c = 0; c < 3; c++) g->mean[k][c] = model65[5 + k * 3 + c];
    }
    for (int k = 0; k < 5; k++) {
        for (int j = 0; j < 9; j++) g->cov[k][j] = model65[20 + k * 9 + j];
        gmm_calc_inv_det(g, k);
    }
}

static void gmm_pack(const sr_gmm *g, double *model65) {
    for (int k = 0; k < 5; k++) model65[k] = g->weight[k];
    for (int k = 0; k < 5; k++) {
        for (int c = 0; c < 3; c++) model65[5 + k * 3 + c] = g->mean[k][c];
    }
    for (int k = 0; k < 5; k++) {
        for (int j = 0; j < 9; j++) model65[20 + k * 9 + j] = g->cov[k][j];
    }
}

static double gmm_comp_prob(const sr_gmm *g, int k, const double *rgb) {
    if (g->weight[k] <= 0.0 || g->det[k] <= 0.0) return 0.0;
    double d0 = rgb[0] - g->mean[k][0];
    double d1 = rgb[1] - g->mean[k][1];
    double d2 = rgb[2] - g->mean[k][2];
    const double *ic = g->inv_cov[k];
    double mult = d0 * (ic[0] * d0 + ic[1] * d1 + ic[2] * d2) +
                  d1 * (ic[3] * d0 + ic[4] * d1 + ic[5] * d2) +
                  d2 * (ic[6] * d0 + ic[7] * d1 + ic[8] * d2);
    return (1.0 / sqrt(g->det[k])) * exp(-0.5 * mult);
}

static double gmm_total_prob(const sr_gmm *g, const double *rgb) {
    double res = 0.0;
    for (int k = 0; k < 5; k++) res += g->weight[k] * gmm_comp_prob(g, k, rgb);
    return res;
}

static int gmm_which_comp(const sr_gmm *g, const double *rgb) {
    int best = 0;
    double max_p = -1.0;
    for (int k = 0; k < 5; k++) {
        double p = gmm_comp_prob(g, k, rgb);
        if (p > max_p) { max_p = p; best = k; }
    }
    return best;
}

static void gmm_learn_from_samples(const uint8_t *img, int32_t w, int32_t h, int32_t stride,
                                   const uint8_t *mask, int32_t mstride, int is_fgd,
                                   int32_t *comp_idx, sr_gmm *g, int init_kmeans) {
    if (init_kmeans) {
        // Collect indices of pixels belonging to class (BGD: 0 or 2; FGD: 1 or 3)
        int32_t total = 0;
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *mr = mask + (size_t)y * (size_t)mstride;
            for (int32_t x = 0; x < w; x++) {
                uint8_t m = mr[x];
                int belong = is_fgd ? (m == 1 || m == 3) : (m == 0 || m == 2);
                if (belong) total++;
            }
        }
        if (total > 0) {
            // Simple Orchard-Bouman / farthest-point deterministic K=5 seed + 5 Lloyd steps
            double centers[5][3];
            int32_t step = (total >= 5) ? (total / 5) : 1;
            int32_t seen = 0, ci = 0;
            for (int32_t y = 0; y < h && ci < 5; y++) {
                const uint8_t *ir = img + (size_t)y * (size_t)stride;
                const uint8_t *mr = mask + (size_t)y * (size_t)mstride;
                for (int32_t x = 0; x < w && ci < 5; x++) {
                    uint8_t m = mr[x];
                    int belong = is_fgd ? (m == 1 || m == 3) : (m == 0 || m == 2);
                    if (belong) {
                        if (seen % step == 0) {
                            centers[ci][0] = ir[x * 3];
                            centers[ci][1] = ir[x * 3 + 1];
                            centers[ci][2] = ir[x * 3 + 2];
                            ci++;
                        }
                        seen++;
                    }
                }
            }
            while (ci < 5) {
                centers[ci][0] = centers[0][0]; centers[ci][1] = centers[0][1]; centers[ci][2] = centers[0][2];
                ci++;
            }
            for (int it = 0; it < 5; it++) {
                double sum[5][3] = {{0}};
                int32_t cnt[5] = {0};
                for (int32_t y = 0; y < h; y++) {
                    const uint8_t *ir = img + (size_t)y * (size_t)stride;
                    const uint8_t *mr = mask + (size_t)y * (size_t)mstride;
                    for (int32_t x = 0; x < w; x++) {
                        uint8_t m = mr[x];
                        int belong = is_fgd ? (m == 1 || m == 3) : (m == 0 || m == 2);
                        if (!belong) continue;
                        double r0 = ir[x * 3], r1 = ir[x * 3 + 1], r2 = ir[x * 3 + 2];
                        int best = 0; double bd = DBL_MAX;
                        for (int k = 0; k < 5; k++) {
                            double d0 = r0 - centers[k][0], d1 = r1 - centers[k][1], d2 = r2 - centers[k][2];
                            double dd = d0 * d0 + d1 * d1 + d2 * d2;
                            if (dd < bd) { bd = dd; best = k; }
                        }
                        comp_idx[(size_t)y * (size_t)w + (size_t)x] = best;
                        sum[best][0] += r0; sum[best][1] += r1; sum[best][2] += r2;
                        cnt[best]++;
                    }
                }
                for (int k = 0; k < 5; k++) {
                    if (cnt[k] > 0) {
                        centers[k][0] = sum[k][0] / cnt[k];
                        centers[k][1] = sum[k][1] / cnt[k];
                        centers[k][2] = sum[k][2] / cnt[k];
                    }
                }
            }
        }
    }

    double sum[5][3] = {{0}};
    double prod[5][9] = {{0}};
    int32_t cnt[5] = {0};
    int32_t total = 0;

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *ir = img + (size_t)y * (size_t)stride;
        const uint8_t *mr = mask + (size_t)y * (size_t)mstride;
        for (int32_t x = 0; x < w; x++) {
            uint8_t m = mr[x];
            int belong = is_fgd ? (m == 1 || m == 3) : (m == 0 || m == 2);
            if (!belong) continue;
            int k = comp_idx[(size_t)y * (size_t)w + (size_t)x];
            if (k < 0 || k >= 5) k = 0;
            double c0 = ir[x * 3], c1 = ir[x * 3 + 1], c2 = ir[x * 3 + 2];
            sum[k][0] += c0; sum[k][1] += c1; sum[k][2] += c2;
            double cc[3] = {c0, c1, c2};
            for (int a = 0; a < 3; a++) {
                for (int b = 0; b < 3; b++) prod[k][a * 3 + b] += cc[a] * cc[b];
            }
            cnt[k]++;
            total++;
        }
    }

    for (int k = 0; k < 5; k++) {
        if (cnt[k] == 0 || total == 0) {
            g->weight[k] = 0.0;
            memset(g->mean[k], 0, 3 * sizeof(double));
            memset(g->cov[k], 0, 9 * sizeof(double));
            g->det[k] = 0.0;
        } else {
            double inv_c = 1.0 / (double)cnt[k];
            g->weight[k] = (double)cnt[k] / (double)total;
            for (int a = 0; a < 3; a++) g->mean[k][a] = sum[k][a] * inv_c;
            for (int a = 0; a < 3; a++) {
                for (int b = 0; b < 3; b++) {
                    g->cov[k][a * 3 + b] = prod[k][a * 3 + b] * inv_c - g->mean[k][a] * g->mean[k][b];
                }
            }
            gmm_calc_inv_det(g, k);
        }
    }
}

// Boykov-Kolmogorov s-t min-cut on 8-connected grid (nodes 0..N-1)
static int bk_mincut(int32_t w, int32_t h, double *t_cap, double *n_cap, uint8_t *out_fgd) {
    int32_t N = w * h;
    static const int dx[8] = { 1, -1,  0,  0,  1, -1,  1, -1};
    static const int dy[8] = { 0,  0,  1, -1,  1, -1, -1,  1};
    static const int opp[8]= { 1,  0,  3,  2,  5,  4,  7,  6};

    uint8_t *tree = (uint8_t *)calloc((size_t)N, 1); // 0=free, 1=S, 2=T
    int32_t *parent_dir = (int32_t *)malloc((size_t)N * sizeof(int32_t)); // -1=terminal, -2=none, 0..7=neighbor dir
    int32_t *active_q = (int32_t *)malloc((size_t)(N + 4) * sizeof(int32_t));
    uint8_t *in_active = (uint8_t *)calloc((size_t)N, 1);
    int32_t *orphan_stk = (int32_t *)malloc((size_t)(N + 4) * sizeof(int32_t));
    int32_t *ts = (int32_t *)calloc((size_t)N, sizeof(int32_t));
    int32_t *dist = (int32_t *)calloc((size_t)N, sizeof(int32_t));
    int32_t *path = (int32_t *)malloc((size_t)(N + 4) * sizeof(int32_t));
    int32_t *path_dir = (int32_t *)malloc((size_t)(N + 4) * sizeof(int32_t));
    if (!tree || !parent_dir || !active_q || !in_active || !orphan_stk || !ts || !dist || !path || !path_dir) {
        free(tree); free(parent_dir); free(active_q); free(in_active);
        free(orphan_stk); free(ts); free(dist); free(path); free(path_dir);
        return -4;
    }

    int32_t qh = 0, qt = 0, q_cnt = 0;
    #define BK_PUSH_ACTIVE(u) do { \
        int32_t _u = (u); \
        if (!in_active[_u]) { \
            in_active[_u] = 1; active_q[qt] = _u; qt = (qt + 1) % N; q_cnt++; \
        } \
    } while (0)

    for (int32_t i = 0; i < N; i++) {
        if (t_cap[i] > 1e-12) {
            tree[i] = 1; parent_dir[i] = -1; dist[i] = 1; ts[i] = 1;
            BK_PUSH_ACTIVE(i);
        } else if (t_cap[i] < -1e-12) {
            tree[i] = 2; parent_dir[i] = -1; dist[i] = 1; ts[i] = 1;
            BK_PUSH_ACTIVE(i);
        } else {
            tree[i] = 0; parent_dir[i] = -2;
        }
    }

    int32_t cur_ts = 1;
    int32_t orp_top = 0;

    while (q_cnt > 0) {
        int32_t u = active_q[qh];
        if (!tree[u]) {
            qh = (qh + 1) % N; q_cnt--; in_active[u] = 0;
            continue;
        }
        int32_t ux = u % w, uy = u / w;
        uint8_t tu = tree[u];
        int32_t meet_u = -1, meet_v = -1, meet_d = -1;

        for (int d = 0; d < 8; d++) {
            int32_t vx = ux + dx[d], vy = uy + dy[d];
            if (vx < 0 || vx >= w || vy < 0 || vy >= h) continue;
            int32_t v = vy * w + vx;
            double cap = (tu == 1) ? n_cap[(size_t)u * 8 + d] : n_cap[(size_t)v * 8 + opp[d]];
            if (cap <= 1e-12) continue;

            if (tree[v] == 0) {
                tree[v] = tu;
                parent_dir[v] = opp[d];
                ts[v] = ts[u];
                dist[v] = dist[u] + 1;
                BK_PUSH_ACTIVE(v);
            } else if (tree[v] != tu) {
                meet_u = u; meet_v = v; meet_d = d;
                break;
            } else if (ts[v] <= ts[u] && dist[v] > dist[u] + 1) {
                parent_dir[v] = opp[d];
                ts[v] = ts[u];
                dist[v] = dist[u] + 1;
            }
        }

        if (meet_u < 0) {
            qh = (qh + 1) % N; q_cnt--; in_active[u] = 0;
            continue;
        }

        // Augment along S-root -> ... -> meet_u -> meet_v -> ... -> T-root
        int32_t s_node = (tu == 1) ? meet_u : meet_v;
        int32_t t_node = (tu == 1) ? meet_v : meet_u;
        int32_t s_to_t_dir = (tu == 1) ? meet_d : opp[meet_d];

        // Trace back from s_node to S-root, find bottleneck
        double bneck = n_cap[(size_t)s_node * 8 + s_to_t_dir];
        int32_t sp_cnt = 0;
        int32_t p = s_node;
        while (parent_dir[p] >= 0) {
            int d = parent_dir[p];
            int32_t par = p + dy[d] * w + dx[d];
            double c = n_cap[(size_t)par * 8 + opp[d]];
            if (c < bneck) bneck = c;
            path[sp_cnt] = par;
            path_dir[sp_cnt] = opp[d];
            sp_cnt++;
            p = par;
        }
        if (t_cap[p] < bneck) bneck = t_cap[p];
        int32_t s_root = p;

        int32_t tp_cnt = 0;
        p = t_node;
        while (parent_dir[p] >= 0) {
            int d = parent_dir[p];
            int32_t par = p + dy[d] * w + dx[d];
            double c = n_cap[(size_t)p * 8 + d];
            if (c < bneck) bneck = c;
            path[sp_cnt + tp_cnt] = p;
            path_dir[sp_cnt + tp_cnt] = d;
            tp_cnt++;
            p = par;
        }
        if (-t_cap[p] < bneck) bneck = -t_cap[p];
        int32_t t_root = p;

        // Push bottleneck flow & record orphans
        t_cap[s_root] -= bneck;
        if (t_cap[s_root] <= 1e-12) {
            t_cap[s_root] = 0.0;
            parent_dir[s_root] = -2;
            orphan_stk[orp_top++] = s_root;
        }
        t_cap[t_root] += bneck;
        if (t_cap[t_root] >= -1e-12) {
            t_cap[t_root] = 0.0;
            parent_dir[t_root] = -2;
            orphan_stk[orp_top++] = t_root;
        }

        // Edge s_node -> t_node
        n_cap[(size_t)s_node * 8 + s_to_t_dir] -= bneck;
        n_cap[(size_t)t_node * 8 + opp[s_to_t_dir]] += bneck;

        for (int32_t i = 0; i < sp_cnt; i++) {
            int32_t par = path[i], d = path_dir[i];
            int32_t child = par + dy[d] * w + dx[d];
            n_cap[(size_t)par * 8 + d] -= bneck;
            n_cap[(size_t)child * 8 + opp[d]] += bneck;
            if (n_cap[(size_t)par * 8 + d] <= 1e-12) {
                n_cap[(size_t)par * 8 + d] = 0.0;
                if (parent_dir[child] == opp[d]) {
                    parent_dir[child] = -2;
                    orphan_stk[orp_top++] = child;
                }
            }
        }
        for (int32_t i = 0; i < tp_cnt; i++) {
            int32_t child = path[sp_cnt + i], d = path_dir[sp_cnt + i];
            int32_t par = child + dy[d] * w + dx[d];
            n_cap[(size_t)child * 8 + d] -= bneck;
            n_cap[(size_t)par * 8 + opp[d]] += bneck;
            if (n_cap[(size_t)child * 8 + d] <= 1e-12) {
                n_cap[(size_t)child * 8 + d] = 0.0;
                if (parent_dir[child] == d) {
                    parent_dir[child] = -2;
                    orphan_stk[orp_top++] = child;
                }
            }
        }

        // Adoption phase
        cur_ts++;
        while (orp_top > 0) {
            int32_t q = orphan_stk[--orp_top];
            int32_t qx = q % w, qy = q / w;
            uint8_t tq = tree[q];
            int32_t best_d = -1, best_dist = INT32_MAX;

            for (int d = 0; d < 8; d++) {
                int32_t vx = qx + dx[d], vy = qy + dy[d];
                if (vx < 0 || vx >= w || vy < 0 || vy >= h) continue;
                int32_t v = vy * w + vx;
                if (tree[v] != tq) continue;
                double cap = (tq == 1) ? n_cap[(size_t)v * 8 + opp[d]] : n_cap[(size_t)q * 8 + d];
                if (cap <= 1e-12) continue;

                // Check origin of v reaches terminal without hitting an orphan
                int32_t cur = v, dlen = 0, valid = 0;
                while (1) {
                    if (ts[cur] == cur_ts) { dlen += dist[cur]; valid = 1; break; }
                    int32_t pd = parent_dir[cur];
                    if (pd == -1) { valid = 1; ts[cur] = cur_ts; dist[cur] = 1; dlen += 1; break; }
                    if (pd == -2) { valid = 0; break; }
                    cur = cur + dy[pd] * w + dx[pd];
                    dlen++;
                }
                if (valid && dlen < best_dist) {
                    best_dist = dlen;
                    best_d = d;
                }
            }

            if (best_d >= 0) {
                parent_dir[q] = best_d;
                ts[q] = cur_ts;
                dist[q] = best_dist + 1;
            } else {
                // Free q and make its same-tree children orphans; make neighbors active
                for (int d = 0; d < 8; d++) {
                    int32_t vx = qx + dx[d], vy = qy + dy[d];
                    if (vx < 0 || vx >= w || vy < 0 || vy >= h) continue;
                    int32_t v = vy * w + vx;
                    if (tree[v] == tq) {
                        double cap = (tq == 1) ? n_cap[(size_t)v * 8 + opp[d]] : n_cap[(size_t)q * 8 + d];
                        if (cap > 1e-12) BK_PUSH_ACTIVE(v);
                        if (parent_dir[v] == opp[d]) {
                            parent_dir[v] = -2;
                            orphan_stk[orp_top++] = v;
                        }
                    }
                }
                tree[q] = 0;
                parent_dir[q] = -2;
            }
        }
    }

    for (int32_t i = 0; i < N; i++) out_fgd[i] = (tree[i] == 1) ? 1 : 0;

    #undef BK_PUSH_ACTIVE
    free(tree); free(parent_dir); free(active_q); free(in_active);
    free(orphan_stk); free(ts); free(dist); free(path); free(path_dir);
    return 0;
}

int32_t sr_c_p4_grabcut(const uint8_t *img, int32_t w, int32_t h, int32_t img_stride,
                        uint8_t *mask, int32_t m_stride,
                        int32_t rx, int32_t ry, int32_t rw, int32_t rh,
                        double *bgd_model, double *fgd_model, int32_t iter_count, int32_t mode) {
    if (!img || !mask || !bgd_model || !fgd_model || w <= 0 || h <= 0) return -1;
    if (mode < 0 || mode > 3) return -1;

    if (mode == 0) { // GC_INIT_WITH_RECT
        for (int32_t y = 0; y < h; y++) {
            uint8_t *mr = mask + (size_t)y * (size_t)m_stride;
            for (int32_t x = 0; x < w; x++) {
                if (x >= rx && x < rx + rw && y >= ry && y < ry + rh) mr[x] = 3; // GC_PR_FGD
                else mr[x] = 0; // GC_BGD
            }
        }
    }

    size_t npix = (size_t)w * (size_t)h;
    int32_t *comp_idx = (int32_t *)calloc(npix, sizeof(int32_t));
    double *edge_base = (double *)calloc(npix * 4, sizeof(double)); // left, upleft, up, upright
    double *t_cap = (double *)malloc(npix * sizeof(double));
    double *n_cap = (double *)malloc(npix * 8 * sizeof(double));
    uint8_t *fgd_cut = (uint8_t *)malloc(npix);
    if (!comp_idx || !edge_base || !t_cap || !n_cap || !fgd_cut) {
        free(comp_idx); free(edge_base); free(t_cap); free(n_cap); free(fgd_cut);
        return -4;
    }

    // Compute beta and pairwise edge weights (gamma = 50.0, lambda = 450.0)
    double beta_sum = 0.0;
    int64_t beta_cnt = 0;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t *ir = img + (size_t)y * (size_t)img_stride;
        for (int32_t x = 0; x < w; x++) {
            double r0 = ir[x * 3], g0 = ir[x * 3 + 1], b0 = ir[x * 3 + 2];
            if (x > 0) {
                double dr = r0 - ir[(x - 1) * 3], dg = g0 - ir[(x - 1) * 3 + 1], db = b0 - ir[(x - 1) * 3 + 2];
                beta_sum += dr * dr + dg * dg + db * db; beta_cnt++;
            }
            if (y > 0 && x > 0) {
                const uint8_t *pr = img + (size_t)(y - 1) * (size_t)img_stride;
                double dr = r0 - pr[(x - 1) * 3], dg = g0 - pr[(x - 1) * 3 + 1], db = b0 - pr[(x - 1) * 3 + 2];
                beta_sum += dr * dr + dg * dg + db * db; beta_cnt++;
            }
            if (y > 0) {
                const uint8_t *pr = img + (size_t)(y - 1) * (size_t)img_stride;
                double dr = r0 - pr[x * 3], dg = g0 - pr[x * 3 + 1], db = b0 - pr[x * 3 + 2];
                beta_sum += dr * dr + dg * dg + db * db; beta_cnt++;
            }
            if (y > 0 && x < w - 1) {
                const uint8_t *pr = img + (size_t)(y - 1) * (size_t)img_stride;
                double dr = r0 - pr[(x + 1) * 3], dg = g0 - pr[(x + 1) * 3 + 1], db = b0 - pr[(x + 1) * 3 + 2];
                beta_sum += dr * dr + dg * dg + db * db; beta_cnt++;
            }
        }
    }
    double beta = (beta_sum <= 1e-12 || beta_cnt == 0) ? 0.0 : (1.0 / (2.0 * beta_sum / (double)beta_cnt));
    const double gamma = 50.0;
    const double gamma_diag = gamma / sqrt(2.0);
    const double lambda = 9.0 * gamma;

    for (int32_t y = 0; y < h; y++) {
        const uint8_t *ir = img + (size_t)y * (size_t)img_stride;
        for (int32_t x = 0; x < w; x++) {
            size_t idx = ((size_t)y * (size_t)w + (size_t)x) * 4;
            double r0 = ir[x * 3], g0 = ir[x * 3 + 1], b0 = ir[x * 3 + 2];
            if (x > 0) {
                double dr = r0 - ir[(x - 1) * 3], dg = g0 - ir[(x - 1) * 3 + 1], db = b0 - ir[(x - 1) * 3 + 2];
                edge_base[idx + 0] = gamma * exp(-beta * (dr * dr + dg * dg + db * db));
            }
            if (y > 0 && x > 0) {
                const uint8_t *pr = img + (size_t)(y - 1) * (size_t)img_stride;
                double dr = r0 - pr[(x - 1) * 3], dg = g0 - pr[(x - 1) * 3 + 1], db = b0 - pr[(x - 1) * 3 + 2];
                edge_base[idx + 1] = gamma_diag * exp(-beta * (dr * dr + dg * dg + db * db));
            }
            if (y > 0) {
                const uint8_t *pr = img + (size_t)(y - 1) * (size_t)img_stride;
                double dr = r0 - pr[x * 3], dg = g0 - pr[x * 3 + 1], db = b0 - pr[x * 3 + 2];
                edge_base[idx + 2] = gamma * exp(-beta * (dr * dr + dg * dg + db * db));
            }
            if (y > 0 && x < w - 1) {
                const uint8_t *pr = img + (size_t)(y - 1) * (size_t)img_stride;
                double dr = r0 - pr[(x + 1) * 3], dg = g0 - pr[(x + 1) * 3 + 1], db = b0 - pr[(x + 1) * 3 + 2];
                edge_base[idx + 3] = gamma_diag * exp(-beta * (dr * dr + dg * dg + db * db));
            }
        }
    }

    sr_gmm bgd_gmm, fgd_gmm;
    if (mode == 0 || mode == 1) {
        gmm_learn_from_samples(img, w, h, img_stride, mask, m_stride, 0, comp_idx, &bgd_gmm, 1);
        gmm_learn_from_samples(img, w, h, img_stride, mask, m_stride, 1, comp_idx, &fgd_gmm, 1);
        gmm_pack(&bgd_gmm, bgd_model);
        gmm_pack(&fgd_gmm, fgd_model);
    } else {
        gmm_unpack(bgd_model, &bgd_gmm);
        gmm_unpack(fgd_model, &fgd_gmm);
    }

    for (int32_t iter = 0; iter < iter_count; iter++) {
        if (mode != 3) { // not GC_EVAL_FREEZE_MODEL
            for (int32_t y = 0; y < h; y++) {
                const uint8_t *ir = img + (size_t)y * (size_t)img_stride;
                const uint8_t *mr = mask + (size_t)y * (size_t)m_stride;
                for (int32_t x = 0; x < w; x++) {
                    double rgb[3] = {ir[x * 3], ir[x * 3 + 1], ir[x * 3 + 2]};
                    uint8_t m = mr[x];
                    comp_idx[(size_t)y * (size_t)w + (size_t)x] =
                        (m == 0 || m == 2) ? gmm_which_comp(&bgd_gmm, rgb) : gmm_which_comp(&fgd_gmm, rgb);
                }
            }
            gmm_learn_from_samples(img, w, h, img_stride, mask, m_stride, 0, comp_idx, &bgd_gmm, 0);
            gmm_learn_from_samples(img, w, h, img_stride, mask, m_stride, 1, comp_idx, &fgd_gmm, 0);
        }

        // Build s-t graph: dx = {1,-1,0,0,1,-1,1,-1}, dy = {0,0,1,-1,1,-1,-1,1}
        memset(n_cap, 0, npix * 8 * sizeof(double));
        for (int32_t y = 0; y < h; y++) {
            const uint8_t *ir = img + (size_t)y * (size_t)img_stride;
            const uint8_t *mr = mask + (size_t)y * (size_t)m_stride;
            for (int32_t x = 0; x < w; x++) {
                size_t p = (size_t)y * (size_t)w + (size_t)x;
                uint8_t m = mr[x];
                if (m == 0) {
                    t_cap[p] = -lambda;
                } else if (m == 1) {
                    t_cap[p] = lambda;
                } else {
                    double rgb[3] = {ir[x * 3], ir[x * 3 + 1], ir[x * 3 + 2]};
                    double pb = gmm_total_prob(&bgd_gmm, rgb);
                    double pf = gmm_total_prob(&fgd_gmm, rgb);
                    double from_src = -log(pb > 1e-300 ? pb : 1e-300); // source = FGD cost of BGD
                    double to_sink = -log(pf > 1e-300 ? pf : 1e-300);  // sink = BGD cost of FGD
                    t_cap[p] = from_src - to_sink;
                }

                // Populate symmetric n-links from precomputed left(0), upleft(1), up(2), upright(3)
                double *eb = edge_base + p * 4;
                if (x > 0) {
                    size_t q = p - 1;
                    n_cap[p * 8 + 1] = eb[0]; // p -> left (-1, 0)
                    n_cap[q * 8 + 0] = eb[0]; // q -> right (1, 0)
                }
                if (y > 0 && x > 0) {
                    size_t q = p - (size_t)w - 1;
                    n_cap[p * 8 + 5] = eb[1]; // p -> upleft (-1, -1)
                    n_cap[q * 8 + 4] = eb[1]; // q -> downright (1, 1)
                }
                if (y > 0) {
                    size_t q = p - (size_t)w;
                    n_cap[p * 8 + 3] = eb[2]; // p -> up (0, -1)
                    n_cap[q * 8 + 2] = eb[2]; // q -> down (0, 1)
                }
                if (y > 0 && x < w - 1) {
                    size_t q = p - (size_t)w + 1;
                    n_cap[p * 8 + 6] = eb[3]; // p -> upright (1, -1)
                    n_cap[q * 8 + 7] = eb[3]; // q -> downleft (-1, 1)
                }
            }
        }

        if (bk_mincut(w, h, t_cap, n_cap, fgd_cut) != 0) break;

        for (int32_t y = 0; y < h; y++) {
            uint8_t *mr = mask + (size_t)y * (size_t)m_stride;
            for (int32_t x = 0; x < w; x++) {
                uint8_t m = mr[x];
                if (m == 2 || m == 3) {
                    mr[x] = fgd_cut[(size_t)y * (size_t)w + (size_t)x] ? 3 : 2;
                }
            }
        }
    }

    if (mode != 3) {
        gmm_pack(&bgd_gmm, bgd_model);
        gmm_pack(&fgd_gmm, fgd_model);
    }

    free(comp_idx); free(edge_base); free(t_cap); free(n_cap); free(fgd_cut);
    return 0;
}

// ---------------------------------------------------------------------------
// Subdiv2D (Guibas-Stolfi Quad-Edge Delaunay Triangulation + Voronoi)
// ---------------------------------------------------------------------------

typedef struct {
    int32_t first_edge;
    int32_t type; // 0 = normal, 1 = virtual
    float x, y;
} sr_subdiv_vtx;

typedef struct {
    int32_t next[4];
    int32_t pt[4];
} sr_subdiv_qedge;

typedef struct {
    sr_subdiv_vtx *vtx;
    int32_t vtx_cnt, vtx_cap;
    sr_subdiv_qedge *qedges;
    int32_t q_cnt, q_cap;
    int32_t recent_edge;
    int32_t valid_geom;
    float rx, ry, rw, rh;
    sr_pt2d top_left, bottom_right;
} sr_subdiv2d;

void *sr_c_p4_subdiv_new(void) {
    sr_subdiv2d *s = (sr_subdiv2d *)calloc(1, sizeof(sr_subdiv2d));
    return s;
}

void sr_c_p4_subdiv_free(void *ptr) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s) return;
    free(s->vtx);
    free(s->qedges);
    free(s);
}

static inline int32_t sd_rotate(int32_t edge, int32_t r) {
    return (edge & ~3) + ((edge + r) & 3);
}

static inline int32_t sd_sym(int32_t edge) {
    return edge ^ 2;
}

static inline int32_t sd_next(const sr_subdiv2d *s, int32_t edge) {
    return s->qedges[edge >> 2].next[edge & 3];
}

static inline int32_t sd_get_edge(const sr_subdiv2d *s, int32_t edge, int32_t type) {
    if (edge <= 0 || (edge >> 2) >= s->q_cnt) return 0;
    int32_t e = sd_rotate(edge, type & 3);
    e = sd_next(s, e);
    return sd_rotate(e, (type >> 4) & 3);
}

static inline int32_t sd_org(const sr_subdiv2d *s, int32_t edge) {
    return (edge > 0 && (edge >> 2) < s->q_cnt) ? s->qedges[edge >> 2].pt[edge & 3] : 0;
}

static inline int32_t sd_dst(const sr_subdiv2d *s, int32_t edge) {
    return (edge > 0 && (edge >> 2) < s->q_cnt) ? s->qedges[edge >> 2].pt[(edge + 2) & 3] : 0;
}

static int32_t sd_new_edge(sr_subdiv2d *s) {
    if (s->q_cnt == s->q_cap) {
        int32_t ncap = (s->q_cap == 0) ? 32 : s->q_cap * 2;
        sr_subdiv_qedge *nq = (sr_subdiv_qedge *)realloc(s->qedges, (size_t)ncap * sizeof(sr_subdiv_qedge));
        if (!nq) return 0;
        s->qedges = nq;
        s->q_cap = ncap;
    }
    int32_t id = s->q_cnt++;
    int32_t base = id << 2;
    s->qedges[id].next[0] = base;
    s->qedges[id].next[1] = base + 3;
    s->qedges[id].next[2] = base + 2;
    s->qedges[id].next[3] = base + 1;
    s->qedges[id].pt[0] = s->qedges[id].pt[1] = s->qedges[id].pt[2] = s->qedges[id].pt[3] = 0;
    return base;
}

static int32_t sd_new_point(sr_subdiv2d *s, float x, float y, int32_t is_virtual, int32_t first_edge) {
    if (s->vtx_cnt == s->vtx_cap) {
        int32_t ncap = (s->vtx_cap == 0) ? 32 : s->vtx_cap * 2;
        sr_subdiv_vtx *nv = (sr_subdiv_vtx *)realloc(s->vtx, (size_t)ncap * sizeof(sr_subdiv_vtx));
        if (!nv) return 0;
        s->vtx = nv;
        s->vtx_cap = ncap;
    }
    int32_t id = s->vtx_cnt++;
    s->vtx[id] = (sr_subdiv_vtx){first_edge, is_virtual, x, y};
    return id;
}

static void sd_set_edge_points(sr_subdiv2d *s, int32_t edge, int32_t org_pt, int32_t dst_pt) {
    s->qedges[edge >> 2].pt[edge & 3] = org_pt;
    s->qedges[edge >> 2].pt[(edge + 2) & 3] = dst_pt;
    s->vtx[org_pt].first_edge = edge;
    s->vtx[dst_pt].first_edge = edge ^ 2;
}

static void sd_splice(sr_subdiv2d *s, int32_t edgeA, int32_t edgeB) {
    int32_t *a_next = &s->qedges[edgeA >> 2].next[edgeA & 3];
    int32_t *b_next = &s->qedges[edgeB >> 2].next[edgeB & 3];
    int32_t a_rot = sd_rotate(*a_next, 1);
    int32_t b_rot = sd_rotate(*b_next, 1);
    int32_t *a_rot_next = &s->qedges[a_rot >> 2].next[a_rot & 3];
    int32_t *b_rot_next = &s->qedges[b_rot >> 2].next[b_rot & 3];
    int32_t t1 = *a_next; *a_next = *b_next; *b_next = t1;
    int32_t t2 = *a_rot_next; *a_rot_next = *b_rot_next; *b_rot_next = t2;
}

static int32_t sd_connect_edges(sr_subdiv2d *s, int32_t edgeA, int32_t edgeB) {
    int32_t edge = sd_new_edge(s);
    if (!edge) return 0;
    sd_splice(s, edge, sd_get_edge(s, edgeA, 19)); // NEXT_AROUND_LEFT = 19
    sd_splice(s, sd_sym(edge), edgeB);
    sd_set_edge_points(s, edge, sd_dst(s, edgeA), sd_org(s, edgeB));
    return edge;
}

static void sd_swap_edges(sr_subdiv2d *s, int32_t edge) {
    int32_t sedge = sd_sym(edge);
    int32_t a = sd_get_edge(s, edge, 17);  // PREV_AROUND_ORG = 17
    int32_t b = sd_get_edge(s, sedge, 17); // PREV_AROUND_ORG = 17
    sd_splice(s, edge, a);
    sd_splice(s, sedge, b);
    sd_set_edge_points(s, edge, sd_dst(s, a), sd_dst(s, b));
    sd_splice(s, edge, sd_get_edge(s, a, 19)); // NEXT_AROUND_LEFT = 19
    sd_splice(s, sedge, sd_get_edge(s, b, 19));
}

static double sd_tri_area(sr_pt2d a, sr_pt2d b, sr_pt2d c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

static int sd_is_right_of(const sr_subdiv2d *s, sr_pt2d pt, int32_t edge) {
    int32_t o = sd_org(s, edge), d = sd_dst(s, edge);
    return sd_tri_area(pt, (sr_pt2d){s->vtx[d].x, s->vtx[d].y}, (sr_pt2d){s->vtx[o].x, s->vtx[o].y}) > 0.0;
}

static int sd_is_pt_in_circle3(sr_pt2d pt, sr_pt2d a, sr_pt2d b, sr_pt2d c) {
    const double eps = 1e-6;
    double adx = a.x - pt.x, ady = a.y - pt.y;
    double bdx = b.x - pt.x, bdy = b.y - pt.y;
    double cdx = c.x - pt.x, cdy = c.y - pt.y;
    double abdet = adx * bdy - bdx * ady;
    double bcdet = bdx * cdy - cdx * bdy;
    double cadet = cdx * ady - adx * cdy;
    double alift = adx * adx + ady * ady;
    double blift = bdx * bdx + bdy * bdy;
    double clift = cdx * cdx + cdy * cdy;
    double disc = alift * bcdet + blift * cadet + clift * abdet;
    return disc > eps * (fabs(alift * bcdet) + fabs(blift * cadet) + fabs(clift * abdet));
}

int32_t sr_c_p4_subdiv_init(void *ptr, float rx, float ry, float rw, float rh) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || rw <= 0.0f || rh <= 0.0f) return -1;

    s->vtx_cnt = 0;
    s->q_cnt = 0;
    s->rx = rx; s->ry = ry; s->rw = rw; s->rh = rh;
    s->top_left = (sr_pt2d){rx, ry};
    s->bottom_right = (sr_pt2d){rx + rw, ry + rh};
    s->valid_geom = 0;

    float big_coord = 6.0f * (rw > rh ? rw : rh);
    sd_new_point(s, 0.0f, 0.0f, 0, 0); // vertex 0 (null)
    sd_new_edge(s); // qedge 0 (null)

    int32_t pA = sd_new_point(s, rx + big_coord, ry, 1, 0);
    int32_t pB = sd_new_point(s, rx, ry + big_coord, 1, 0);
    int32_t pC = sd_new_point(s, rx - big_coord, ry - big_coord, 1, 0);

    int32_t eAB = sd_new_edge(s); // edge 4
    sd_set_edge_points(s, eAB, pA, pB);

    int32_t eBC = sd_new_edge(s); // edge 8
    sd_set_edge_points(s, eBC, pB, pC);

    int32_t eCA = sd_new_edge(s); // edge 12
    sd_set_edge_points(s, eCA, pC, pA);

    sd_splice(s, sd_sym(eAB), eBC);
    sd_splice(s, sd_sym(eBC), eCA);
    sd_splice(s, sd_sym(eCA), eAB);

    s->recent_edge = eAB;
    return 0;
}

int32_t sr_c_p4_subdiv_locate(void *ptr, float fx, float fy, int32_t *out_loc, int32_t *out_edge, int32_t *out_vtx) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_loc || !out_edge || !out_vtx || s->vtx_cnt < 4) return -1;
    if (fx < s->rx || fy < s->ry || fx >= s->rx + s->rw || fy >= s->ry + s->rh) {
        *out_loc = -1; // PTLOC_OUTSIDE_RECT
        *out_edge = 0;
        *out_vtx = 0;
        return -1;
    }

    sr_pt2d pt = {(double)fx, (double)fy};
    int32_t edge = s->recent_edge;
    if (edge <= 0) edge = 4;
    if (sd_is_right_of(s, pt, edge)) edge = sd_sym(edge);

    int32_t max_steps = s->q_cnt * 4 + 32;
    int32_t status = -2;
    int32_t vertex = 0;

    for (int32_t i = 0; i < max_steps; i++) {
        int32_t org_pt = sd_org(s, edge), dst_pt = sd_dst(s, edge);
        if (hypot(pt.x - s->vtx[org_pt].x, pt.y - s->vtx[org_pt].y) < 1e-6) {
            status = 1; vertex = org_pt; edge = 0;
            break;
        }
        if (hypot(pt.x - s->vtx[dst_pt].x, pt.y - s->vtx[dst_pt].y) < 1e-6) {
            status = 1; vertex = dst_pt; edge = 0;
            break;
        }
        int32_t e1 = sd_get_edge(s, edge, 19); // NEXT_AROUND_LEFT
        int32_t e2 = sd_get_edge(s, e1, 19);   // NEXT_AROUND_LEFT
        int32_t third_pt = sd_dst(s, e1);
        if (third_pt > 0 && hypot(pt.x - s->vtx[third_pt].x, pt.y - s->vtx[third_pt].y) < 1e-6) {
            status = 1; vertex = third_pt; edge = 0;
            break;
        }
        if (sd_is_right_of(s, pt, e1)) {
            edge = sd_sym(e1);
        } else if (sd_is_right_of(s, pt, e2)) {
            edge = sd_sym(e2);
        } else {
            sr_pt2d o_p = {s->vtx[org_pt].x, s->vtx[org_pt].y};
            sr_pt2d d_p = {s->vtx[dst_pt].x, s->vtx[dst_pt].y};
            double len = hypot(d_p.x - o_p.x, d_p.y - o_p.y);
            double area = fabs(sd_tri_area(o_p, d_p, pt));
            if (area <= 1e-5 * len) {
                status = 2; // PTLOC_ON_EDGE
            } else {
                // Check e1 and e2 as well in case pt lies on another edge of the triangle
                int32_t v1o = sd_org(s, e1), v1d = sd_dst(s, e1);
                double l1 = hypot(s->vtx[v1d].x - s->vtx[v1o].x, s->vtx[v1d].y - s->vtx[v1o].y);
                double a1 = fabs(sd_tri_area((sr_pt2d){s->vtx[v1o].x, s->vtx[v1o].y}, (sr_pt2d){s->vtx[v1d].x, s->vtx[v1d].y}, pt));
                int32_t v2o = sd_org(s, e2), v2d = sd_dst(s, e2);
                double l2 = hypot(s->vtx[v2d].x - s->vtx[v2o].x, s->vtx[v2d].y - s->vtx[v2o].y);
                double a2 = fabs(sd_tri_area((sr_pt2d){s->vtx[v2o].x, s->vtx[v2o].y}, (sr_pt2d){s->vtx[v2d].x, s->vtx[v2d].y}, pt));
                if (a1 <= 1e-5 * l1) { status = 2; edge = e1; }
                else if (a2 <= 1e-5 * l2) { status = 2; edge = e2; }
                else status = 0; // PTLOC_INSIDE
            }
            s->recent_edge = edge;
            break;
        }
    }

    *out_loc = status;
    *out_edge = edge;
    *out_vtx = vertex;
    return (status < 0) ? -1 : 0;
}

int32_t sr_c_p4_subdiv_insert(void *ptr, float fx, float fy, int32_t *out_id) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_id || s->vtx_cnt < 4) return -1;

    int32_t loc = 0, curr_edge = 0, curr_vtx = 0;
    if (sr_c_p4_subdiv_locate(s, fx, fy, &loc, &curr_edge, &curr_vtx) != 0) return -1;
    if (loc == 1) {
        *out_id = curr_vtx;
        return 0;
    }

    int32_t suspect[256];
    int32_t n_sus = 0;

    if (loc == 2) {
        // Point lies on curr_edge: save both side faces' boundary edges before removing curr_edge
        int32_t sym = sd_sym(curr_edge);
        int32_t ln1 = sd_get_edge(s, curr_edge, 19);
        int32_t lp1 = sd_get_edge(s, curr_edge, 32);
        int32_t ln2 = sd_get_edge(s, sym, 19);
        int32_t lp2 = sd_get_edge(s, sym, 32);
        // Delete curr_edge by splicing out both endpoints
        sd_splice(s, curr_edge, sd_get_edge(s, curr_edge, 17));
        sd_splice(s, sym, sd_get_edge(s, sym, 17));
        if (s->vtx[sd_org(s, curr_edge)].first_edge == curr_edge) s->vtx[sd_org(s, curr_edge)].first_edge = lp2;
        if (s->vtx[sd_dst(s, curr_edge)].first_edge == sym) s->vtx[sd_dst(s, curr_edge)].first_edge = lp1;
        s->recent_edge = ln1;
        curr_edge = ln1;
        suspect[n_sus++] = ln1;
        suspect[n_sus++] = lp1;
        suspect[n_sus++] = ln2;
        suspect[n_sus++] = lp2;
    } else {
        int32_t e0 = curr_edge;
        int32_t e1 = sd_get_edge(s, e0, 19);
        int32_t e2 = sd_get_edge(s, e1, 19);
        suspect[n_sus++] = e0;
        suspect[n_sus++] = e1;
        suspect[n_sus++] = e2;
    }

    int32_t curr_point = sd_new_point(s, fx, fy, 0, 0);
    if (!curr_point) return -4;

    int32_t base = sd_new_edge(s);
    if (!base) return -4;
    int32_t first = sd_org(s, curr_edge);
    sd_set_edge_points(s, base, first, curr_point);
    sd_splice(s, base, curr_edge);

    int32_t guard = 0;
    do {
        base = sd_connect_edges(s, curr_edge, sd_sym(base));
        curr_edge = sd_get_edge(s, base, 17); // PREV_AROUND_ORG -> next boundary edge
        if (++guard > 16) break;
    } while (sd_dst(s, curr_edge) != first);

    // Lawson edge flipping on suspect stack
    sr_pt2d pt = {(double)fx, (double)fy};
    int32_t *stk = suspect;
    int32_t stk_cap = 256;
    int32_t *dyn_stk = NULL;
    int32_t flips = 0, max_flips = s->q_cnt * 4 + 64;

    while (n_sus > 0 && flips < max_flips) {
        int32_t e = stk[--n_sus];
        int32_t se = sd_sym(e);
        int32_t e_right_prev = sd_get_edge(s, se, 19); // NEXT_AROUND_LEFT(sym(e)): edge (org(e) -> opp)
        int32_t opp_v = sd_dst(s, e_right_prev);
        int32_t org_e = sd_org(s, e), dst_e = sd_dst(s, e);
        if (opp_v <= 0 || org_e <= 0 || dst_e <= 0) continue;

        sr_pt2d po = {s->vtx[org_e].x, s->vtx[org_e].y};
        sr_pt2d pd = {s->vtx[dst_e].x, s->vtx[dst_e].y};
        sr_pt2d popp = {s->vtx[opp_v].x, s->vtx[opp_v].y};

        if (sd_tri_area(po, popp, pd) > 0.0 && sd_is_pt_in_circle3(pt, po, popp, pd)) {
            int32_t s1 = sd_get_edge(s, se, 19); // org_e -> opp_v
            int32_t s2 = sd_get_edge(s, s1, 19); // opp_v -> dst_e
            sd_swap_edges(s, e);
            flips++;
            if (n_sus + 2 >= stk_cap) {
                int32_t ncap = stk_cap * 2;
                int32_t *ns = (int32_t *)malloc((size_t)ncap * sizeof(int32_t));
                if (!ns) break;
                memcpy(ns, stk, (size_t)n_sus * sizeof(int32_t));
                free(dyn_stk);
                dyn_stk = ns;
                stk = ns;
                stk_cap = ncap;
            }
            stk[n_sus++] = s1;
            stk[n_sus++] = s2;
        }
    }
    free(dyn_stk);

    s->recent_edge = base;
    s->valid_geom = 0;
    *out_id = curr_point;
    return 0;
}

int32_t sr_c_p4_subdiv_nearest(void *ptr, float fx, float fy, float *out_pt2, int32_t *out_vtx) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_pt2 || !out_vtx || s->vtx_cnt <= 4) return -1;
    int32_t best = 0;
    double best_d2 = DBL_MAX;
    for (int32_t i = 4; i < s->vtx_cnt; i++) {
        if (s->vtx[i].type) continue;
        double dx = (double)s->vtx[i].x - (double)fx;
        double dy = (double)s->vtx[i].y - (double)fy;
        double d2 = dx * dx + dy * dy;
        if (d2 < best_d2) { best_d2 = d2; best = i; }
    }
    if (best <= 0) return -1;
    *out_vtx = best;
    out_pt2[0] = s->vtx[best].x;
    out_pt2[1] = s->vtx[best].y;
    return 0;
}

int32_t sr_c_p4_subdiv_edges(void *ptr, float **out_edges, int32_t *out_count) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_edges || !out_count) return -1;
    *out_edges = NULL;
    *out_count = 0;
    if (s->q_cnt <= 4) return 0;

    int32_t n = s->q_cnt - 4;
    float *res = (float *)malloc((size_t)n * 4 * sizeof(float));
    if (!res) return -4;
    int32_t k = 0;
    for (int32_t i = 4; i < s->q_cnt; i++) {
        int32_t e = i << 2;
        int32_t o = sd_org(s, e), d = sd_dst(s, e);
        if (o > 0 && d > 0) {
            res[k * 4 + 0] = s->vtx[o].x;
            res[k * 4 + 1] = s->vtx[o].y;
            res[k * 4 + 2] = s->vtx[d].x;
            res[k * 4 + 3] = s->vtx[d].y;
            k++;
        }
    }
    *out_edges = res;
    *out_count = k;
    return 0;
}

int32_t sr_c_p4_subdiv_tris(void *ptr, float **out_tris, int32_t *out_count) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_tris || !out_count) return -1;
    *out_tris = NULL;
    *out_count = 0;
    if (s->q_cnt <= 4) return 0;

    int32_t total_e = s->q_cnt * 4;
    uint8_t *done = (uint8_t *)calloc((size_t)total_e, 1);
    float *res = (float *)malloc((size_t)total_e * 6 * sizeof(float));
    if (!done || !res) { free(done); free(res); return -4; }

    int32_t nt = 0;
    for (int32_t i = 4; i < s->q_cnt; i++) {
        for (int r = 0; r <= 2; r += 2) {
            int32_t edge = (i << 2) + r;
            if (done[edge]) continue;
            int32_t e0 = edge;
            int32_t e1 = sd_get_edge(s, e0, 19); // NEXT_AROUND_LEFT
            int32_t e2 = sd_get_edge(s, e1, 19);
            done[e0] = done[e1] = done[e2] = 1;
            int32_t v0 = sd_org(s, e0), v1 = sd_org(s, e1), v2 = sd_org(s, e2);
            if (v0 >= 4 && v1 >= 4 && v2 >= 4 &&
                sd_get_edge(s, e2, 19) == e0) {
                res[nt * 6 + 0] = s->vtx[v0].x; res[nt * 6 + 1] = s->vtx[v0].y;
                res[nt * 6 + 2] = s->vtx[v1].x; res[nt * 6 + 3] = s->vtx[v1].y;
                res[nt * 6 + 4] = s->vtx[v2].x; res[nt * 6 + 5] = s->vtx[v2].y;
                nt++;
            }
        }
    }
    free(done);
    if (nt == 0) { free(res); *out_tris = NULL; }
    else { *out_tris = res; }
    *out_count = nt;
    return 0;
}

static sr_pt2d tri_circumcenter(sr_pt2d a, sr_pt2d b, sr_pt2d c) {
    double D = 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    if (fabs(D) < 1e-12) {
        return (sr_pt2d){(a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0};
    }
    double a2 = a.x * a.x + a.y * a.y;
    double b2 = b.x * b.x + b.y * b.y;
    double c2 = c.x * c.x + c.y * c.y;
    return (sr_pt2d){
        (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / D,
        (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / D
    };
}

int32_t sr_c_p4_subdiv_voronoi(void *ptr, const int32_t *idx, int32_t nidx,
                               float **out_pts, int32_t **out_counts, float **out_centers, int32_t *out_nfacets) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_pts || !out_counts || !out_centers || !out_nfacets) return -1;
    *out_pts = NULL; *out_counts = NULL; *out_centers = NULL; *out_nfacets = 0;
    if (s->vtx_cnt <= 4) return 0;

    int32_t nf = (nidx > 0 && idx) ? nidx : (s->vtx_cnt - 4);
    int32_t *counts = (int32_t *)calloc((size_t)nf, sizeof(int32_t));
    float *centers = (float *)malloc((size_t)nf * 2 * sizeof(float));
    int32_t pt_cap = nf * 8 + 16, pt_cnt = 0;
    float *pts = (float *)malloc((size_t)pt_cap * 2 * sizeof(float));
    if (!counts || !centers || !pts) { free(counts); free(centers); free(pts); return -4; }

    for (int32_t fi = 0; fi < nf; fi++) {
        int32_t vid = (nidx > 0 && idx) ? idx[fi] : (4 + fi);
        if (vid < 4 || vid >= s->vtx_cnt || s->vtx[vid].first_edge <= 0) {
            centers[fi * 2] = 0.0f; centers[fi * 2 + 1] = 0.0f;
            counts[fi] = 0;
            continue;
        }
        centers[fi * 2] = s->vtx[vid].x;
        centers[fi * 2 + 1] = s->vtx[vid].y;
        sr_pt2d pv = {s->vtx[vid].x, s->vtx[vid].y};

        int32_t e0 = s->vtx[vid].first_edge;
        if (sd_org(s, e0) != vid) e0 = sd_sym(e0);
        int32_t e = e0;
        int32_t k = 0;
        int32_t guard = 0;
        do {
            int32_t enext = sd_get_edge(s, e, 0); // NEXT_AROUND_ORG
            int32_t v1 = sd_dst(s, e);
            int32_t v2 = sd_dst(s, enext);
            if (v1 > 0 && v2 > 0) {
                sr_pt2d cc = tri_circumcenter(pv,
                                              (sr_pt2d){s->vtx[v1].x, s->vtx[v1].y},
                                              (sr_pt2d){s->vtx[v2].x, s->vtx[v2].y});
                if (pt_cnt == pt_cap) {
                    pt_cap *= 2;
                    float *npts = (float *)realloc(pts, (size_t)pt_cap * 2 * sizeof(float));
                    if (!npts) break;
                    pts = npts;
                }
                pts[pt_cnt * 2] = (float)cc.x;
                pts[pt_cnt * 2 + 1] = (float)cc.y;
                pt_cnt++;
                k++;
            }
            e = enext;
        } while (e != e0 && ++guard < 256);
        counts[fi] = k;
    }

    *out_pts = pts;
    *out_counts = counts;
    *out_centers = centers;
    *out_nfacets = nf;
    return 0;
}

int32_t sr_c_p4_subdiv_vertex(void *ptr, int32_t vid, float *out_pt2, int32_t *out_edge) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_pt2 || !out_edge) return -1;
    if (vid <= 0 || vid >= s->vtx_cnt) {
        out_pt2[0] = 0.0f; out_pt2[1] = 0.0f; *out_edge = 0;
        return 0;
    }
    out_pt2[0] = s->vtx[vid].x;
    out_pt2[1] = s->vtx[vid].y;
    *out_edge = s->vtx[vid].first_edge;
    return 0;
}

int32_t sr_c_p4_subdiv_get_edge(void *ptr, int32_t edge, int32_t next_type) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s) return 0;
    return sd_get_edge(s, edge, next_type);
}

int32_t sr_c_p4_subdiv_next_edge(void *ptr, int32_t edge) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || edge <= 0 || (edge >> 2) >= s->q_cnt) return 0;
    return sd_next(s, edge);
}

int32_t sr_c_p4_subdiv_rotate_edge(int32_t edge, int32_t rot) {
    return sd_rotate(edge, rot);
}

int32_t sr_c_p4_subdiv_sym_edge(int32_t edge) {
    return sd_sym(edge);
}

int32_t sr_c_p4_subdiv_edge_org(void *ptr, int32_t edge, float *out_pt2, int32_t *out_vtx) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_pt2 || !out_vtx) return -1;
    int32_t v = sd_org(s, edge);
    *out_vtx = v;
    if (v > 0 && v < s->vtx_cnt) {
        out_pt2[0] = s->vtx[v].x; out_pt2[1] = s->vtx[v].y;
    } else {
        out_pt2[0] = 0.0f; out_pt2[1] = 0.0f;
    }
    return 0;
}

int32_t sr_c_p4_subdiv_leading_edges(void *ptr, int32_t **out_edges, int32_t *out_count) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_edges || !out_count) return -1;
    *out_edges = NULL;
    *out_count = 0;
    if (s->q_cnt <= 4) return 0;

    int32_t total_e = s->q_cnt * 4;
    uint8_t *done = (uint8_t *)calloc((size_t)total_e, 1);
    int32_t *res = (int32_t *)malloc((size_t)total_e * sizeof(int32_t));
    if (!done || !res) { free(done); free(res); return -4; }

    int32_t k = 0;
    for (int32_t i = 4; i < total_e; i += 2) {
        if (done[i]) continue;
        int32_t e = i;
        res[k++] = e;
        int32_t guard = 0;
        do {
            done[e] = 1;
            e = sd_get_edge(s, e, 19); // NEXT_AROUND_LEFT
        } while (e > 0 && e < total_e && !done[e] && ++guard < 8);
    }
    free(done);
    if (k == 0) { free(res); *out_edges = NULL; }
    else { *out_edges = res; }
    *out_count = k;
    return 0;
}

int32_t sr_c_p4_subdiv_edge_dst(void *ptr, int32_t edge, float *out_pt2, int32_t *out_vtx) {
    sr_subdiv2d *s = (sr_subdiv2d *)ptr;
    if (!s || !out_pt2 || !out_vtx) return -1;
    int32_t v = sd_dst(s, edge);
    *out_vtx = v;
    if (v > 0 && v < s->vtx_cnt) {
        out_pt2[0] = s->vtx[v].x; out_pt2[1] = s->vtx[v].y;
    } else {
        out_pt2[0] = 0.0f; out_pt2[1] = 0.0f;
    }
    return 0;
}
