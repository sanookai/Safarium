// SafariumRasterC — own VP8 key-frame encoder core for lossy WebP (Area C). Written from RFC 6386 (the VP8 Data Format and
// Decoding Guide): intra 16x16 / 4x4 (B_PRED, ten sub-modes) / 8x8 chroma prediction, integer DCT + WHT, segment map with
// per-segment quantiser and loop-filter level, rate-distortion mode decision (SSE + lambda * estimated bits from the token
// probabilities), optimal token probabilities, boolean arithmetic coder. The encoder search (activity-driven segments, RD
// choice, pruning) is our own design; no libwebp / libvpx code is used.
#include <arm_neon.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------------------------------
// Constants (RFC 6386)

static const int ZZ[16] = {0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15};
static const int BANDS[17] = {0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0};
static const uint8_t CATP[6][11] = {{159}, {165, 145}, {173, 148, 140}, {176, 155, 140, 135}, {180, 157, 141, 134, 130},
                                    {254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129}};
static const int CATN[6] = {1, 2, 3, 4, 5, 11};

enum { B_DC, B_TM, B_VE, B_HE, B_LD, B_RD, B_VR, B_VL, B_HD, B_HU };
static const int8_t BMODE_TREE[18] = {-B_DC, 2, -B_TM, 4, -B_VE, 6, 8, 12, -B_HE, 10, -B_RD, -B_VR, -B_LD, 14, -B_VL, 16, -B_HD, -B_HU};

static const uint8_t KF_BMODE_PROB[10][10][9] = {
    {{231,120,48,89,115,113,120,152,112},{152,179,64,126,170,118,46,70,95},{175,69,143,80,85,82,72,155,103},{56,58,10,171,218,189,17,13,152},{144,71,10,38,171,213,144,34,26},{114,26,17,163,44,195,21,10,173},{121,24,80,195,26,62,44,64,85},{170,46,55,19,136,160,33,206,71},{63,20,8,114,114,208,12,9,226},{81,40,11,96,182,84,29,16,36}},
    {{134,183,89,137,98,101,106,165,148},{72,187,100,130,157,111,32,75,80},{66,102,167,99,74,62,40,234,128},{41,53,9,178,241,141,26,8,107},{104,79,12,27,217,255,87,17,7},{74,43,26,146,73,166,49,23,157},{65,38,105,160,51,52,31,115,128},{87,68,71,44,114,51,15,186,23},{47,41,14,110,182,183,21,17,194},{66,45,25,102,197,189,23,18,22}},
    {{88,88,147,150,42,46,45,196,205},{43,97,183,117,85,38,35,179,61},{39,53,200,87,26,21,43,232,171},{56,34,51,104,114,102,29,93,77},{107,54,32,26,51,1,81,43,31},{39,28,85,171,58,165,90,98,64},{34,22,116,206,23,34,43,166,73},{68,25,106,22,64,171,36,225,114},{34,19,21,102,132,188,16,76,124},{62,18,78,95,85,57,50,48,51}},
    {{193,101,35,159,215,111,89,46,111},{60,148,31,172,219,228,21,18,111},{112,113,77,85,179,255,38,120,114},{40,42,1,196,245,209,10,25,109},{100,80,8,43,154,1,51,26,71},{88,43,29,140,166,213,37,43,154},{61,63,30,155,67,45,68,1,209},{142,78,78,16,255,128,34,197,171},{41,40,5,102,211,183,4,1,221},{51,50,17,168,209,192,23,25,82}},
    {{125,98,42,88,104,85,117,175,82},{95,84,53,89,128,100,113,101,45},{75,79,123,47,51,128,81,171,1},{57,17,5,71,102,57,53,41,49},{115,21,2,10,102,255,166,23,6},{38,33,13,121,57,73,26,1,85},{41,10,67,138,77,110,90,47,114},{101,29,16,10,85,128,101,196,26},{57,18,10,102,102,213,34,20,43},{117,20,15,36,163,128,68,1,26}},
    {{138,31,36,171,27,166,38,44,229},{67,87,58,169,82,115,26,59,179},{63,59,90,180,59,166,93,73,154},{40,40,21,116,143,209,34,39,175},{57,46,22,24,128,1,54,17,37},{47,15,16,183,34,223,49,45,183},{46,17,33,183,6,98,15,32,183},{65,32,73,115,28,128,23,128,205},{40,3,9,115,51,192,18,6,223},{87,37,9,115,59,77,64,21,47}},
    {{104,55,44,218,9,54,53,130,226},{64,90,70,205,40,41,23,26,57},{54,57,112,184,5,41,38,166,213},{30,34,26,133,152,116,10,32,134},{75,32,12,51,192,255,160,43,51},{39,19,53,221,26,114,32,73,255},{31,9,65,234,2,15,1,118,73},{88,31,35,67,102,85,55,186,85},{56,21,23,111,59,205,45,37,192},{55,38,70,124,73,102,1,34,98}},
    {{102,61,71,37,34,53,31,243,192},{69,60,71,38,73,119,28,222,37},{68,45,128,34,1,47,11,245,171},{62,17,19,70,146,85,55,62,70},{75,15,9,9,64,255,184,119,16},{37,43,37,154,100,163,85,160,1},{63,9,92,136,28,64,32,201,85},{86,6,28,5,64,255,25,248,1},{56,8,17,132,137,255,55,116,128},{58,15,20,82,135,57,26,121,40}},
    {{164,50,31,137,154,133,25,35,218},{51,103,44,131,131,123,31,6,158},{86,40,64,135,148,224,45,183,128},{22,26,17,131,240,154,14,1,209},{83,12,13,54,192,255,68,47,28},{45,16,21,91,64,222,7,1,197},{56,21,39,155,60,138,23,102,213},{85,26,85,85,128,128,32,146,171},{18,11,7,63,144,171,4,4,246},{35,27,10,146,174,171,12,26,128}},
    {{190,80,35,99,180,80,126,54,45},{85,126,47,87,176,51,41,20,32},{101,75,128,139,118,146,116,128,85},{56,41,15,176,236,85,37,9,62},{146,36,19,30,171,255,97,27,20},{71,30,17,119,118,255,17,18,138},{101,38,60,138,55,70,43,26,142},{138,45,61,62,219,1,81,188,64},{32,41,20,117,151,142,20,21,163},{112,19,12,61,195,128,48,4,24}}
};

// ---------------------------------------------------------------------------------------------------------------------
// Bit cost tables (1/256 bit)

static uint16_t BC0[256], BC1[256];
static int bmode_cost[10][10][10];       // [above][left][mode], 1/256 bit
static int8_t bm_path_node[10][8], bm_path_bit[10][8];
static int bm_path_len[10];

static void walk_tree(int idx, int depth, int8_t *pn, int8_t *pb) {
    for (int bit = 0; bit < 2; bit++) {
        pn[depth] = (int8_t)(idx >> 1); pb[depth] = (int8_t)bit;
        int nx = BMODE_TREE[idx + bit];
        if (nx <= 0) {
            int m = -nx;
            bm_path_len[m] = depth + 1;
            for (int k = 0; k <= depth; k++) { bm_path_node[m][k] = pn[k]; bm_path_bit[m][k] = pb[k]; }
        } else walk_tree(nx, depth + 1, pn, pb);
    }
}

__attribute__((constructor)) static void tables_init(void) {
    for (int p = 1; p < 256; p++) {
        BC0[p] = (uint16_t)lrint(-log2(p / 256.0) * 256.0);
        BC1[p] = (uint16_t)lrint(-log2((256 - p) / 256.0) * 256.0);
    }
    BC0[0] = BC1[0] = 2048;
    int8_t pn[8], pb[8];
    walk_tree(0, 0, pn, pb);
    for (int a = 0; a < 10; a++) for (int l = 0; l < 10; l++) for (int m = 0; m < 10; m++) {
        int c = 0;
        for (int k = 0; k < bm_path_len[m]; k++) {
            int p = KF_BMODE_PROB[a][l][(int)bm_path_node[m][k]];
            c += bm_path_bit[m][k] ? BC1[p] : BC0[p];
        }
        bmode_cost[a][l][m] = c;
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Boolean arithmetic coder

typedef struct { uint8_t *p; size_t n, cap; uint32_t range, bottom; int bitcount; int oom; } BoolEnc;

static void be_init(BoolEnc *e, size_t cap) {
    e->p = (uint8_t *)malloc(cap ? cap : 64); e->cap = cap ? cap : 64; e->n = 0; e->range = 255; e->bottom = 0; e->bitcount = 24; e->oom = e->p == NULL;
}
static inline void be_byte(BoolEnc *e, uint8_t b) {
    if (e->n == e->cap) {
        if (e->oom) return;
        uint8_t *np = (uint8_t *)realloc(e->p, e->cap * 2);
        if (!np) { e->oom = 1; return; }
        e->p = np; e->cap *= 2;
    }
    e->p[e->n++] = b;
}
static inline void be_carry(BoolEnc *e) {
    long i = (long)e->n - 1;
    while (i >= 0 && e->p[i] == 255) { e->p[i] = 0; i--; }
    if (i >= 0) e->p[i]++;
}
static inline void be_put(BoolEnc *e, int prob, int bit) {
    uint32_t split = 1 + (((e->range - 1) * (uint32_t)prob) >> 8);
    if (bit) { e->bottom += split; e->range -= split; } else e->range = split;
    while (e->range < 128) {
        e->range <<= 1;
        if (e->bottom & (1u << 31)) be_carry(e);
        e->bottom <<= 1;
        if (--e->bitcount == 0) { be_byte(e, (uint8_t)(e->bottom >> 24)); e->bottom &= (1u << 24) - 1; e->bitcount = 8; }
    }
}
static void be_lit(BoolEnc *e, int v, int n) { for (int b = n - 1; b >= 0; b--) be_put(e, 128, (v >> b) & 1); }
static void be_finish(BoolEnc *e) {
    int c = e->bitcount;
    uint32_t v = e->bottom;
    if (v & (1u << (32 - c))) be_carry(e);
    v <<= (c & 7);
    c >>= 3;
    while (c > 0) { v <<= 8; c--; }
    for (int i = 0; i < 4; i++) { be_byte(e, (uint8_t)(v >> 24)); v <<= 8; }
}

// ---------------------------------------------------------------------------------------------------------------------
// Transforms

static inline uint8_t clip255(int v) { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); }

/// Forward DCT of (src - pred) 4x4 -> out natural order (libvpx-compatible scaling so the RFC inverse is its inverse).
static void fdct4(const uint8_t *src, int ss, const uint8_t *pred, int ps, int16_t *out) {
    int tmp[16];
    for (int i = 0; i < 4; i++) {
        int x0 = src[i * ss] - pred[i * ps], x1 = src[i * ss + 1] - pred[i * ps + 1];
        int x2 = src[i * ss + 2] - pred[i * ps + 2], x3 = src[i * ss + 3] - pred[i * ps + 3];
        int a1 = (x0 + x3) * 8, b1 = (x1 + x2) * 8, c1 = (x1 - x2) * 8, d1 = (x0 - x3) * 8;
        tmp[i * 4] = a1 + b1; tmp[i * 4 + 2] = a1 - b1;
        tmp[i * 4 + 1] = (c1 * 2217 + d1 * 5352 + 14500) >> 12;
        tmp[i * 4 + 3] = (d1 * 2217 - c1 * 5352 + 7500) >> 12;
    }
    for (int i = 0; i < 4; i++) {
        int a1 = tmp[i] + tmp[12 + i], b1 = tmp[4 + i] + tmp[8 + i], c1 = tmp[4 + i] - tmp[8 + i], d1 = tmp[i] - tmp[12 + i];
        out[i] = (int16_t)((a1 + b1 + 7) >> 4); out[8 + i] = (int16_t)((a1 - b1 + 7) >> 4);
        out[4 + i] = (int16_t)(((c1 * 2217 + d1 * 5352 + 12000) >> 16) + (d1 != 0));
        out[12 + i] = (int16_t)((d1 * 2217 - c1 * 5352 + 51000) >> 16);
    }
}

static void fwht(const int *in, int *out) {
    int tmp[16];
    for (int i = 0; i < 4; i++) {
        int a1 = (in[i * 4] + in[i * 4 + 2]) * 4, d1 = (in[i * 4 + 1] + in[i * 4 + 3]) * 4;
        int c1 = (in[i * 4 + 1] - in[i * 4 + 3]) * 4, b1 = (in[i * 4] - in[i * 4 + 2]) * 4;
        tmp[i * 4] = a1 + d1 + (a1 != 0); tmp[i * 4 + 1] = b1 + c1; tmp[i * 4 + 2] = b1 - c1; tmp[i * 4 + 3] = a1 - d1;
    }
    for (int i = 0; i < 4; i++) {
        int a1 = tmp[i] + tmp[8 + i], d1 = tmp[4 + i] + tmp[12 + i], c1 = tmp[4 + i] - tmp[12 + i], b1 = tmp[i] - tmp[8 + i];
        int a2 = a1 + d1, b2 = b1 + c1, c2 = b1 - c1, d2 = a1 - d1;
        a2 += a2 < 0; b2 += b2 < 0; c2 += c2 < 0; d2 += d2 < 0;
        out[i] = (a2 + 3) >> 3; out[4 + i] = (b2 + 3) >> 3; out[8 + i] = (c2 + 3) >> 3; out[12 + i] = (d2 + 3) >> 3;
    }
}

static void iwht(const int *in, int *r) {
    int o[16];
    for (int i = 0; i < 4; i++) {
        int a1 = in[i] + in[12 + i], b1 = in[4 + i] + in[8 + i], c1 = in[4 + i] - in[8 + i], d1 = in[i] - in[12 + i];
        o[i] = a1 + b1; o[4 + i] = c1 + d1; o[8 + i] = a1 - b1; o[12 + i] = d1 - c1;
    }
    for (int i = 0; i < 4; i++) {
        int a1 = o[i * 4] + o[i * 4 + 3], b1 = o[i * 4 + 1] + o[i * 4 + 2], c1 = o[i * 4 + 1] - o[i * 4 + 2], d1 = o[i * 4] - o[i * 4 + 3];
        r[i * 4] = (a1 + b1 + 3) >> 3; r[i * 4 + 1] = (c1 + d1 + 3) >> 3; r[i * 4 + 2] = (a1 - b1 + 3) >> 3; r[i * 4 + 3] = (d1 - c1 + 3) >> 3;
    }
}

/// Inverse DCT (RFC 6386 14.4) of natural-order coefficients, added to pred -> dst (4x4).
static void idct_add(const int16_t *ip, const uint8_t *pred, int ps, uint8_t *dst, int ds) {
    int t[16];
    for (int i = 0; i < 4; i++) {
        int a1 = ip[i] + ip[8 + i], b1 = ip[i] - ip[8 + i];
        int temp1 = (ip[4 + i] * 35468) >> 16, temp2 = ip[12 + i] + ((ip[12 + i] * 20091) >> 16);
        int c1 = temp1 - temp2;
        temp1 = ip[4 + i] + ((ip[4 + i] * 20091) >> 16); temp2 = (ip[12 + i] * 35468) >> 16;
        int d1 = temp1 + temp2;
        t[i] = a1 + d1; t[12 + i] = a1 - d1; t[4 + i] = b1 + c1; t[8 + i] = b1 - c1;
    }
    for (int i = 0; i < 4; i++) {
        int a1 = t[i * 4] + t[i * 4 + 2], b1 = t[i * 4] - t[i * 4 + 2];
        int temp1 = (t[i * 4 + 1] * 35468) >> 16, temp2 = t[i * 4 + 3] + ((t[i * 4 + 3] * 20091) >> 16);
        int c1 = temp1 - temp2;
        temp1 = t[i * 4 + 1] + ((t[i * 4 + 1] * 20091) >> 16); temp2 = (t[i * 4 + 3] * 35468) >> 16;
        int d1 = temp1 + temp2;
        const uint8_t *pr = pred + i * ps; uint8_t *d = dst + i * ds;
        d[0] = clip255(pr[0] + ((a1 + d1 + 4) >> 3)); d[3] = clip255(pr[3] + ((a1 - d1 + 4) >> 3));
        d[1] = clip255(pr[1] + ((b1 + c1 + 4) >> 3)); d[2] = clip255(pr[2] + ((b1 - c1 + 4) >> 3));
    }
}

static inline int sse_blk(const uint8_t *a, int as, const uint8_t *b, int bs, int w, int h) {
    int s = 0;
    for (int j = 0; j < h; j++) for (int i = 0; i < w; i++) { int d = a[j * as + i] - b[j * bs + i]; s += d * d; }
    return s;
}

// ---------------------------------------------------------------------------------------------------------------------
// Encoder state

typedef struct {
    int16_t lv[25][16];       // levels in zigzag order: 0..15 Y, 16..19 U, 20..23 V, 24 Y2
    uint8_t ymode;            // 0 DC 1 V 2 H 3 TM 4 B_PRED
    uint8_t uvmode, seg, skip;
    uint8_t bm[16];
} MB;

typedef struct { int q[2]; int iq[2]; int bias[2]; } QP;      // [0] = DC, [1] = AC
typedef struct { QP y1, y2, uv; int qi; double lambda; int lf; } SegQ;

typedef struct {
    int mbw, mbh;
    const uint8_t *Y, *U, *V; int ys, cs;
    MB *mbs;
    uint8_t *probs;                    // 1056
    const uint8_t *defProbs, *updProbs;
    const int32_t *dcq, *acq;
    int nseg;
    SegQ sq[4];
    int dq_uvdc, dq_uvac;
    // cost tables
    uint16_t lc[4 * 8 * 3][68];
    uint16_t cne[4 * 8 * 3], ce0[4 * 8 * 3], cz[4 * 8 * 3];
    // tuning
    int maxModes4, keep16, keepC, skipI4;
    double lamI16, lamI4, rdoqGamma, rdoqLam;
} Enc;

static int level_cost_dyn(const uint8_t *p, int v) {
    int c = BC1[p[1]];
    if (v == 1) return c + BC0[p[2]];
    c += BC1[p[2]];
    if (v <= 4) {
        c += BC0[p[3]];
        if (v == 2) c += BC0[p[4]];
        else c += BC1[p[4]] + (v == 4 ? BC1[p[5]] : BC0[p[5]]);
        return c;
    }
    c += BC1[p[3]];
    int cat, off;
    if (v <= 10) {
        c += BC0[p[6]];
        if (v <= 6) { c += BC0[p[7]]; cat = 0; off = 5; } else { c += BC1[p[7]]; cat = 1; off = 7; }
    } else {
        c += BC1[p[6]];
        if (v <= 34) {
            c += BC0[p[8]];
            if (v <= 18) { c += BC0[p[9]]; cat = 2; off = 11; } else { c += BC1[p[9]]; cat = 3; off = 19; }
        } else {
            c += BC1[p[8]];
            if (v <= 66) { c += BC0[p[10]]; cat = 4; off = 35; } else { c += BC1[p[10]]; cat = 5; off = 67; }
        }
    }
    int n = CATN[cat];
    for (int k = 0; k < n; k++) c += (((v - off) >> (n - 1 - k)) & 1) ? BC1[CATP[cat][k]] : BC0[CATP[cat][k]];
    return c;
}

static void build_costs(Enc *E) {
    for (int i = 0; i < 4 * 8 * 3; i++) {
        const uint8_t *p = E->probs + i * 11;
        E->cne[i] = BC1[p[0]]; E->ce0[i] = BC0[p[0]]; E->cz[i] = BC0[p[1]];
        E->lc[i][0] = 0;
        for (int v = 1; v < 68; v++) E->lc[i][v] = (uint16_t)level_cost_dyn(p, v);
    }
}

/// Estimated rate (1/256 bit) of one block's tokens; *nz receives the context flag.
static inline int block_rate(const Enc *E, const int16_t *lv, int first, int type, int ctx, int *nz) {
    int eob = first;
    for (int i = 15; i >= first; i--) if (lv[i]) { eob = i + 1; break; }
    int rate = 0, c = ctx, prevzero = 0;
    for (int i = first; i < eob; i++) {
        int idx = (type * 8 + BANDS[i]) * 3 + c;
        if (!prevzero) rate += E->cne[idx];
        int a = abs(lv[i]);
        if (a == 0) { rate += E->cz[idx]; c = 0; prevzero = 1; }
        else {
            rate += (a < 68 ? E->lc[idx][a] : level_cost_dyn(E->probs + idx * 11, a)) + 256;
            c = a == 1 ? 1 : 2; prevzero = 0;
        }
    }
    if (eob < 16) rate += E->ce0[(type * 8 + BANDS[eob]) * 3 + c];
    *nz = eob > first;
    return rate;
}

static inline int quant1(int c, int iq, int bias) {
    int a = c < 0 ? -c : c;
    int l = (a * iq + bias) >> 17;
    if (l > 2047) l = 2047;
    return c < 0 ? -l : l;
}

static void setup_qp(QP *p, int dc, int ac, double biasDC, double biasAC) {
    p->q[0] = dc; p->q[1] = ac;
    for (int k = 0; k < 2; k++) p->iq[k] = (1 << 17) / p->q[k];
    p->bias[0] = (int)(biasDC * (1 << 17)); p->bias[1] = (int)(biasAC * (1 << 17));
}

static inline int clipq(int v) { return v < 0 ? 0 : (v > 127 ? 127 : v); }

static void setup_seg(Enc *E, SegQ *s, int qi, double lamK) {
    s->qi = qi;
    int y1dc = E->dcq[qi], y1ac = E->acq[qi];
    int y2dc = E->dcq[qi] * 2, y2ac = E->acq[qi] * 155 / 100; if (y2ac < 8) y2ac = 8;
    int uvdc = E->dcq[clipq(qi + E->dq_uvdc)]; if (uvdc > 132) uvdc = 132;
    int uvac = E->acq[clipq(qi + E->dq_uvac)];
    // rounding offsets (tuned for size at equal SSIM on Kodak + graphic frames)
    const double bY1D = 0.42, bY1A = 0.42, bY2D = 0.42, bY2A = 0.42, bUVD = 0.42, bUVA = 0.42;
    setup_qp(&s->y1, y1dc, y1ac, bY1D, bY1A);
    setup_qp(&s->y2, y2dc, y2ac, bY2D, bY2A);
    setup_qp(&s->uv, uvdc, uvac, bUVD, bUVA);
    s->lambda = lamK * (double)y1ac * (double)y1ac;
}

// ---------------------------------------------------------------------------------------------------------------------
// Prediction

#define BPS 32
// Work buffer layout (per plane): row 0 = above row (col 0 = top-left, cols 1.. = above, then above-right), rows 1.. = [left, pixels].

static void pred_block(uint8_t *dst, int ds, const uint8_t *W, int n, int mode, int haveTop, int haveLeft) {
    const uint8_t *top = W + 1;
    switch (mode) {
    case 0: {
        int dc = 128, sum = 0, shift = n == 16 ? 4 : 3;
        if (haveTop && haveLeft) { for (int i = 0; i < n; i++) sum += top[i] + W[(i + 1) * BPS]; dc = (sum + n) >> (shift + 1); }
        else if (haveTop) { for (int i = 0; i < n; i++) sum += top[i]; dc = (sum + n / 2) >> shift; }
        else if (haveLeft) { for (int i = 0; i < n; i++) sum += W[(i + 1) * BPS]; dc = (sum + n / 2) >> shift; }
        for (int j = 0; j < n; j++) memset(dst + j * ds, dc, (size_t)n);
        break;
    }
    case 1: for (int j = 0; j < n; j++) memcpy(dst + j * ds, top, (size_t)n); break;
    case 2: for (int j = 0; j < n; j++) memset(dst + j * ds, W[(j + 1) * BPS], (size_t)n); break;
    default: {
        int tl = W[0];
        for (int j = 0; j < n; j++) { int l = W[(j + 1) * BPS] - tl; for (int i = 0; i < n; i++) dst[j * ds + i] = clip255(l + top[i]); }
    }
    }
}

#define AVG3(x, y, z) (uint8_t)(((x) + 2 * (y) + (z) + 2) >> 2)
#define AVG2(x, y) (uint8_t)(((x) + (y) + 1) >> 1)

/// 4x4 sub-block predictor, RFC 6386 12.3. A[-1] = P, A[0..7] above/above-right; L[0..3] left.
static void pred4(uint8_t *B, const uint8_t *A, const uint8_t *L, int mode) {
    int P = A[-1];
    uint8_t E[9] = {L[3], L[2], L[1], L[0], (uint8_t)P, A[0], A[1], A[2], A[3]};
#define B_(r, c) B[(r) * 4 + (c)]
    switch (mode) {
    case B_DC: { int v = 4; for (int i = 0; i < 4; i++) v += A[i] + L[i]; v >>= 3; memset(B, v, 16); break; }
    case B_TM: for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++) B_(r, c) = clip255(L[r] + A[c] - P); break;
    case B_VE:
        for (int c = 0; c < 4; c++) { uint8_t v = AVG3(A[c - 1], A[c], A[c + 1]); B_(0, c) = B_(1, c) = B_(2, c) = B_(3, c) = v; }
        break;
    case B_HE: {
        uint8_t v0 = AVG3(P, L[0], L[1]), v1 = AVG3(L[0], L[1], L[2]), v2 = AVG3(L[1], L[2], L[3]), v3 = AVG3(L[2], L[3], L[3]);
        memset(B, v0, 4); memset(B + 4, v1, 4); memset(B + 8, v2, 4); memset(B + 12, v3, 4);
        break;
    }
    case B_LD:
        B_(0, 0) = AVG3(A[0], A[1], A[2]);
        B_(0, 1) = B_(1, 0) = AVG3(A[1], A[2], A[3]);
        B_(0, 2) = B_(1, 1) = B_(2, 0) = AVG3(A[2], A[3], A[4]);
        B_(0, 3) = B_(1, 2) = B_(2, 1) = B_(3, 0) = AVG3(A[3], A[4], A[5]);
        B_(1, 3) = B_(2, 2) = B_(3, 1) = AVG3(A[4], A[5], A[6]);
        B_(2, 3) = B_(3, 2) = AVG3(A[5], A[6], A[7]);
        B_(3, 3) = AVG3(A[6], A[7], A[7]);
        break;
    case B_RD:
        B_(3, 0) = AVG3(E[0], E[1], E[2]);
        B_(3, 1) = B_(2, 0) = AVG3(E[1], E[2], E[3]);
        B_(3, 2) = B_(2, 1) = B_(1, 0) = AVG3(E[2], E[3], E[4]);
        B_(3, 3) = B_(2, 2) = B_(1, 1) = B_(0, 0) = AVG3(E[3], E[4], E[5]);
        B_(2, 3) = B_(1, 2) = B_(0, 1) = AVG3(E[4], E[5], E[6]);
        B_(1, 3) = B_(0, 2) = AVG3(E[5], E[6], E[7]);
        B_(0, 3) = AVG3(E[6], E[7], E[8]);
        break;
    case B_VR:
        B_(3, 0) = AVG3(E[1], E[2], E[3]);
        B_(2, 0) = AVG3(E[2], E[3], E[4]);
        B_(3, 1) = B_(1, 0) = AVG3(E[3], E[4], E[5]);
        B_(2, 1) = B_(0, 0) = AVG2(E[4], E[5]);
        B_(3, 2) = B_(1, 1) = AVG3(E[4], E[5], E[6]);
        B_(2, 2) = B_(0, 1) = AVG2(E[5], E[6]);
        B_(3, 3) = B_(1, 2) = AVG3(E[5], E[6], E[7]);
        B_(2, 3) = B_(0, 2) = AVG2(E[6], E[7]);
        B_(1, 3) = AVG3(E[6], E[7], E[8]);
        B_(0, 3) = AVG2(E[7], E[8]);
        break;
    case B_VL:
        B_(0, 0) = AVG2(A[0], A[1]);
        B_(1, 0) = AVG3(A[0], A[1], A[2]);
        B_(2, 0) = B_(0, 1) = AVG2(A[1], A[2]);
        B_(1, 1) = B_(3, 0) = AVG3(A[1], A[2], A[3]);
        B_(2, 1) = B_(0, 2) = AVG2(A[2], A[3]);
        B_(3, 1) = B_(1, 2) = AVG3(A[2], A[3], A[4]);
        B_(2, 2) = B_(0, 3) = AVG2(A[3], A[4]);
        B_(3, 2) = B_(1, 3) = AVG3(A[3], A[4], A[5]);
        B_(2, 3) = AVG3(A[4], A[5], A[6]);
        B_(3, 3) = AVG3(A[5], A[6], A[7]);
        break;
    case B_HD:
        B_(3, 0) = AVG2(E[0], E[1]);
        B_(3, 1) = AVG3(E[0], E[1], E[2]);
        B_(2, 0) = B_(3, 2) = AVG2(E[1], E[2]);
        B_(2, 1) = B_(3, 3) = AVG3(E[1], E[2], E[3]);
        B_(2, 2) = B_(1, 0) = AVG2(E[2], E[3]);
        B_(2, 3) = B_(1, 1) = AVG3(E[2], E[3], E[4]);
        B_(1, 2) = B_(0, 0) = AVG2(E[3], E[4]);
        B_(1, 3) = B_(0, 1) = AVG3(E[3], E[4], E[5]);
        B_(0, 2) = AVG3(E[4], E[5], E[6]);
        B_(0, 3) = AVG3(E[5], E[6], E[7]);
        break;
    default: // B_HU
        B_(0, 0) = AVG2(L[0], L[1]);
        B_(0, 1) = AVG3(L[0], L[1], L[2]);
        B_(0, 2) = B_(1, 0) = AVG2(L[1], L[2]);
        B_(0, 3) = B_(1, 1) = AVG3(L[1], L[2], L[3]);
        B_(1, 2) = B_(2, 0) = AVG2(L[2], L[3]);
        B_(1, 3) = B_(2, 1) = AVG3(L[2], L[3], L[3]);
        B_(2, 2) = B_(2, 3) = B_(3, 0) = B_(3, 1) = B_(3, 2) = B_(3, 3) = L[3];
    }
#undef B_
}

// ---------------------------------------------------------------------------------------------------------------------
// Block coding helpers

/// DCT + quantise one 4x4 residual block. `first` = 1 skips the DC (carried by Y2). Fills lv (zigzag) and dq (natural,
/// dequantised). Returns nothing; the caller computes the rate.
static inline void quant_block(const int16_t *co, const QP *qp, int first, int16_t *lv, int16_t *dq) {
    for (int i = first; i < 16; i++) {
        int pos = ZZ[i], k = i > 0;
        int l = quant1(co[pos], qp->iq[k], qp->bias[k]);
        lv[i] = (int16_t)l;
        dq[pos] = (int16_t)(l * qp->q[k]);
    }
}

/// Quantised block -> tokens: optional trailing RD pruning (a trailing +-1 is dropped when the bits it costs outweigh the
/// distortion it removes; `co` = unquantised coefficients in natural order), then the exact rate. Updates lv / dq in place,
/// returns the rate (1/256 bit) and the context flag. One pass over the block builds the cumulative token costs.
static inline int code_block(const Enc *E, const QP *qp, double lam, const int16_t *co, int first, int type, int ctx,
                             int16_t *lv, int16_t *dq, int *nz) {
    int cum[17], cn[17];
    int eob = first;                                  // no coefficient: the EOB token sits at the first position
    for (int i = 15; i >= first; i--) if (lv[i]) { eob = i + 1; break; }
    int c = ctx, prevzero = 0, r = 0;
    cum[first] = 0; cn[first] = ctx;
    for (int i = first; i < eob; i++) {
        int idx = (type * 8 + BANDS[i]) * 3 + c;
        if (!prevzero) r += E->cne[idx];
        int a = abs(lv[i]);
        if (a == 0) { r += E->cz[idx]; c = 0; prevzero = 1; }
        else {
            r += (a < 68 ? E->lc[idx][a] : level_cost_dyn(E->probs + idx * 11, a)) + 256;
            c = a == 1 ? 1 : 2; prevzero = 0;
        }
        cum[i + 1] = r; cn[i + 1] = c;
    }
    if (E->rdoqGamma > 0) {
        while (eob > first && abs(lv[eob - 1]) == 1) {
            int p = eob - 1, e2 = p;
            while (e2 > first && lv[e2 - 1] == 0) e2--;       // new eob if the trailing one goes
            int rWith = cum[eob] + (eob < 16 ? E->ce0[(type * 8 + BANDS[eob]) * 3 + cn[eob]] : 0);
            int rWo = cum[e2] + (e2 < 16 ? E->ce0[(type * 8 + BANDS[e2]) * 3 + cn[e2]] : 0);
            int pos = ZZ[p], ac = abs(co[pos]), q = qp->q[p > 0];
            double dD = ((double)ac * ac - (double)(ac - q) * (ac - q)) * E->rdoqGamma;
            if (dD < lam * (rWith - rWo) * (1.0 / 256.0)) { lv[p] = 0; dq[pos] = 0; eob = e2; }
            else break;
        }
    }
    *nz = eob > first;
    return cum[eob] + (eob < 16 ? E->ce0[(type * 8 + BANDS[eob]) * 3 + cn[eob]] : 0);
}

typedef struct {
    int16_t lv[25][16];
    uint8_t rec[256];       // Y 16x16 (stride 16)
    uint8_t recC[2][64];    // U, V 8x8 (stride 8)
    int sse, rate;
    double j;
    uint8_t bm[16];
    uint8_t tnzY[4], lnzY[4];   // updated contexts after the candidate (for chosen one)
    uint8_t y2nz;
} Cand;

typedef struct {
    uint8_t srcY[256], srcU[64], srcV[64];
    uint8_t WY[17 * BPS], WU[9 * BPS], WV[9 * BPS];
    int mbx, mby;
    uint8_t tnz[9], lnz[9];    // contexts at MB start: 0..3 Y, 4..5 U, 6..7 V, 8 Y2
} MBCtx;

static void eval_i16(const Enc *E, const SegQ *sq, const MBCtx *C, int mode, Cand *out) {
    uint8_t pred[256];
    pred_block(pred, 16, C->WY, 16, mode, C->mby > 0, C->mbx > 0);
    int dcs[16];
    int16_t dq[16][16];
    memset(out->lv, 0, sizeof(out->lv));
    uint8_t tnz[4], lnz[4];
    memcpy(tnz, C->tnz, 4); memcpy(lnz, C->lnz, 4);
    int nz, rate = 0;
    double rlam = sq->lambda * E->rdoqLam;
    for (int b = 0; b < 16; b++) {
        int bx = (b & 3) * 4, by = (b >> 2) * 4;
        int16_t co[16];
        fdct4(C->srcY + by * 16 + bx, 16, pred + by * 16 + bx, 16, co);
        dcs[b] = co[0];
        quant_block(co, &sq->y1, 1, out->lv[b], dq[b]);
        dq[b][0] = 0;
        rate += code_block(E, &sq->y1, rlam, co, 1, 0, tnz[b & 3] + lnz[b >> 2], out->lv[b], dq[b], &nz);
        tnz[b & 3] = lnz[b >> 2] = (uint8_t)nz;
    }
    int w[16];
    fwht(dcs, w);
    int dqw[16];
    for (int i = 0; i < 16; i++) {
        int pos = ZZ[i], k = i > 0;
        int l = quant1(w[pos], sq->y2.iq[k], sq->y2.bias[k]);
        out->lv[24][i] = (int16_t)l;
        dqw[pos] = l * sq->y2.q[k];
    }
    int dcr[16];
    iwht(dqw, dcr);
    int sse = 0;
    for (int b = 0; b < 16; b++) {
        int bx = (b & 3) * 4, by = (b >> 2) * 4;
        dq[b][0] = (int16_t)dcr[b];
        idct_add(dq[b], pred + by * 16 + bx, 16, out->rec + by * 16 + bx, 16);
    }
    sse = sse_blk(C->srcY, 16, out->rec, 16, 16, 16);
    rate += block_rate(E, out->lv[24], 0, 1, C->tnz[8] + C->lnz[8], &nz);
    out->y2nz = (uint8_t)nz;
    memcpy(out->tnzY, tnz, 4); memcpy(out->lnzY, lnz, 4);
    static const int modeBits[4] = {0, 0, 0, 0};
    rate += BC1[145] + modeBits[mode];
    out->sse = sse; out->rate = rate;
    out->j = sse + sq->lambda * E->lamI16 * rate * (1.0 / 256.0);
}

static void eval_chroma(const Enc *E, const SegQ *sq, const MBCtx *C, int mode, Cand *out) {
    memset(&out->lv[16], 0, sizeof(int16_t) * 16 * 8);
    uint8_t tnz[4], lnz[4];
    memcpy(tnz, C->tnz + 4, 4); memcpy(lnz, C->lnz + 4, 4);
    int sse = 0, rate = 0, nz;
    for (int pl = 0; pl < 2; pl++) {
        uint8_t pred[64];
        const uint8_t *W = pl ? C->WV : C->WU, *src = pl ? C->srcV : C->srcU;
        pred_block(pred, 8, W, 8, mode, C->mby > 0, C->mbx > 0);
        for (int b = 0; b < 4; b++) {
            int bx = (b & 1) * 4, by = (b >> 1) * 4;
            int16_t co[16], dq[16];
            int16_t *lv = out->lv[16 + pl * 4 + b];
            fdct4(src + by * 8 + bx, 8, pred + by * 8 + bx, 8, co);
            quant_block(co, &sq->uv, 0, lv, dq);
            int cx = pl * 2 + (b & 1), cy = pl * 2 + (b >> 1);
            rate += code_block(E, &sq->uv, sq->lambda * E->rdoqLam, co, 0, 2, tnz[cx] + lnz[cy], lv, dq, &nz);
            idct_add(dq, pred + by * 8 + bx, 8, out->recC[pl] + by * 8 + bx, 8);
            tnz[cx] = lnz[cy] = (uint8_t)nz;
        }
        sse += sse_blk(src, 8, out->recC[pl], 8, 8, 8);
    }
    static const int cbits[4] = {0, 0, 0, 0};
    (void)cbits;
    rate += mode == 0 ? BC0[142] : (BC1[142] + (mode == 1 ? BC0[114] : BC1[114] + (mode == 2 ? BC0[183] : BC1[183])));
    out->sse = sse; out->rate = rate;
    out->j = sse + sq->lambda * rate * (1.0 / 256.0);
    memcpy(out->tnzY, tnz, 4); memcpy(out->lnzY, lnz, 4);
}

/// Sequential 4x4 search. Works in a scratch copy of WY so the caller's buffer is untouched. Returns J (incl. mode bits).
static double eval_i4(const Enc *E, const SegQ *sq, const MBCtx *C, const uint8_t *topModes, const uint8_t *leftModes,
                      double jLimit, Cand *out) {
    uint8_t W[17 * BPS];
    memcpy(W, C->WY, sizeof(W));
    memset(out->lv, 0, sizeof(int16_t) * 16 * 16);
    uint8_t tnz[4], lnz[4];
    memcpy(tnz, C->tnz, 4); memcpy(lnz, C->lnz, 4);
    uint8_t modes[16];
    double J = sq->lambda * E->lamI4 * (BC0[145]) / 256.0;
    int sse = 0, rate = BC0[145];
    int nmodes = E->maxModes4;
    for (int b = 0; b < 16; b++) {
        int bx = b & 3, by = b >> 2;
        const uint8_t *A = W + (by * 4) * BPS + 1 + bx * 4;
        uint8_t L[4];
        for (int i = 0; i < 4; i++) L[i] = W[(by * 4 + 1 + i) * BPS + bx * 4];
        int ctxA = by == 0 ? topModes[bx] : modes[b - 4];
        int ctxL = bx == 0 ? leftModes[by] : modes[b - 1];
        const uint8_t *src = C->srcY + by * 4 * 16 + bx * 4;
        // candidate ranking by prediction SSE when pruning
        uint8_t preds[10][16];
        int order[10], pscore[10];
        for (int m = 0; m < 10; m++) {
            pred4(preds[m], A, L, m);
            int s = sse_blk(src, 16, preds[m], 4, 4, 4);
            pscore[m] = s + (int)(sq->lambda * E->lamI4 * bmode_cost[ctxA][ctxL][m] / 256.0 * 0.5);
            order[m] = m;
        }
        if (nmodes < 10) {
            for (int i = 0; i < nmodes; i++) {
                int bi = i;
                for (int k = i + 1; k < 10; k++) if (pscore[order[k]] < pscore[order[bi]]) bi = k;
                int t = order[i]; order[i] = order[bi]; order[bi] = t;
            }
        }
        double bestJ = 1e300; int bestM = 0, bestSse = 0, bestRate = 0, bestNz = 0;
        int16_t bestLv[16]; uint8_t bestRec[16];
        for (int oi = 0; oi < nmodes; oi++) {
            int m = order[oi];
            int16_t co[16], dq[16], lv[16];
            fdct4(src, 16, preds[m], 4, co);
            quant_block(co, &sq->y1, 0, lv, dq);
            int nz;
            int r = code_block(E, &sq->y1, sq->lambda * E->rdoqLam, co, 0, 3, tnz[bx] + lnz[by], lv, dq, &nz) + bmode_cost[ctxA][ctxL][m];
            uint8_t rec[16];
            idct_add(dq, preds[m], 4, rec, 4);
            int s = sse_blk(src, 16, rec, 4, 4, 4);
            double j = s + sq->lambda * E->lamI4 * r * (1.0 / 256.0);
            if (j < bestJ) { bestJ = j; bestM = m; bestSse = s; bestRate = r; bestNz = nz; memcpy(bestLv, lv, sizeof(lv)); memcpy(bestRec, rec, 16); }
        }
        modes[b] = (uint8_t)bestM;
        memcpy(out->lv[b], bestLv, sizeof(bestLv));
        tnz[bx] = lnz[by] = (uint8_t)bestNz;
        sse += bestSse; rate += bestRate; J += bestJ;
        for (int j = 0; j < 4; j++) memcpy(W + (by * 4 + 1 + j) * BPS + 1 + bx * 4, bestRec + j * 4, 4);
        for (int j = 0; j < 4; j++) memcpy(out->rec + (by * 4 + j) * 16 + bx * 4, bestRec + j * 4, 4);
        if (J > jLimit) return 1e300;
    }
    memcpy(out->bm, modes, 16);
    memcpy(out->tnzY, tnz, 4); memcpy(out->lnzY, lnz, 4);
    out->sse = sse; out->rate = rate; out->j = J;
    return J;
}

// ---------------------------------------------------------------------------------------------------------------------
// Main encode

static inline int bmode_of_ymode(int ym) { return ym == 0 ? B_DC : (ym == 1 ? B_VE : (ym == 2 ? B_HE : B_TM)); }

typedef struct { BoolEnc *be; int *cnt; } TokOut;

static inline void tput(TokOut *t, const uint8_t *probs, int idx, int bit) {
    if (t->cnt) t->cnt[idx * 2 + bit]++;
    else be_put(t->be, probs[idx], bit);
}
static inline void tfixed(TokOut *t, int p, int bit) { if (!t->cnt) be_put(t->be, p, bit); }

static int emit_block(TokOut *t, const uint8_t *probs, const int16_t *lv, int first, int type, int ctx) {
    int eob = 0;
    for (int i = 15; i >= first; i--) if (lv[i]) { eob = i + 1; break; }
    int c = ctx, skipEOB = 0;
    for (int i = first; i < 16; i++) {
        int b = ((type * 8 + BANDS[i]) * 3 + c) * 11;
        if (!skipEOB) {
            tput(t, probs, b, i < eob);
            if (i >= eob) return eob > first;
        }
        int v = lv[i], a = abs(v);
        if (a == 0) { tput(t, probs, b + 1, 0); c = 0; skipEOB = 1; continue; }
        tput(t, probs, b + 1, 1);
        if (a == 1) { tput(t, probs, b + 2, 0); c = 1; }
        else {
            tput(t, probs, b + 2, 1);
            if (a <= 4) {
                tput(t, probs, b + 3, 0);
                if (a == 2) tput(t, probs, b + 4, 0); else { tput(t, probs, b + 4, 1); tput(t, probs, b + 5, a == 4); }
            } else {
                tput(t, probs, b + 3, 1);
                int cat, off;
                if (a <= 10) { tput(t, probs, b + 6, 0); if (a <= 6) { tput(t, probs, b + 7, 0); cat = 0; off = 5; } else { tput(t, probs, b + 7, 1); cat = 1; off = 7; } }
                else {
                    tput(t, probs, b + 6, 1);
                    if (a <= 34) { tput(t, probs, b + 8, 0); if (a <= 18) { tput(t, probs, b + 9, 0); cat = 2; off = 11; } else { tput(t, probs, b + 9, 1); cat = 3; off = 19; } }
                    else { tput(t, probs, b + 8, 1); if (a <= 66) { tput(t, probs, b + 10, 0); cat = 4; off = 35; } else { tput(t, probs, b + 10, 1); cat = 5; off = 67; } }
                }
                int n = CATN[cat];
                for (int k = 0; k < n; k++) tfixed(t, CATP[cat][k], ((a - off) >> (n - 1 - k)) & 1);
            }
            c = 2;
        }
        tfixed(t, 128, v < 0);
        skipEOB = 0;
    }
    return eob > first;
}

static void walk_tokens(const Enc *E, TokOut *t) {
    int mbw = E->mbw;
    uint8_t *tnz = (uint8_t *)calloc((size_t)mbw * 9, 1);
    for (int mby = 0; mby < E->mbh; mby++) {
        uint8_t lnz[9] = {0};
        for (int mbx = 0; mbx < mbw; mbx++) {
            const MB *mb = &E->mbs[mby * mbw + mbx];
            uint8_t *a = tnz + mbx * 9;
            int i16 = mb->ymode != 4;
            if (mb->skip) {
                for (int k = 0; k < 8; k++) a[k] = lnz[k] = 0;
                if (i16) a[8] = lnz[8] = 0;
                continue;
            }
            int firstY = 0, typeY = 3;
            if (i16) {
                int nz = emit_block(t, E->probs, mb->lv[24], 0, 1, a[8] + lnz[8]);
                a[8] = lnz[8] = (uint8_t)nz; firstY = 1; typeY = 0;
            }
            for (int b = 0; b < 16; b++) {
                int bx = b & 3, by = b >> 2;
                int nz = emit_block(t, E->probs, mb->lv[b], firstY, typeY, a[bx] + lnz[by]);
                a[bx] = lnz[by] = (uint8_t)nz;
            }
            for (int pl = 0; pl < 2; pl++) for (int b = 0; b < 4; b++) {
                int cx = 4 + pl * 2 + (b & 1), cy = 4 + pl * 2 + (b >> 1);
                int nz = emit_block(t, E->probs, mb->lv[16 + pl * 4 + b], 0, 2, a[cx] + lnz[cy]);
                a[cx] = lnz[cy] = (uint8_t)nz;
            }
        }
    }
    free(tnz);
}

// Edge handling: top-row buffers hold the unfiltered bottom row of the MB row above (with 4 spare pixels on the right).
int64_t sr_vp8_encode(const uint8_t *Y, const uint8_t *U, const uint8_t *V, int32_t ys, int32_t cs, int32_t mbw, int32_t mbh,
                      int32_t width, int32_t height, int32_t quality, const uint8_t *defProbs, const uint8_t *updProbs,
                      const int32_t *dcq, const int32_t *acq, uint8_t **outp) {
    if (!outp) return -1;
    *outp = NULL;
    if (!Y || !U || !V || !defProbs || !updProbs || !dcq || !acq ||
        width < 1 || height < 1 || width > 16383 || height > 16383 ||
        (uint64_t)width * (uint64_t)height > ((uint64_t)1 << 27) ||
        mbw < 1 || mbh < 1 || mbw > 1024 || mbh > 1024) {
        return -1;
    }
    Enc *E = (Enc *)calloc(1, sizeof(Enc));
    if (!E) return -1;
    E->mbw = mbw; E->mbh = mbh; E->Y = Y; E->U = U; E->V = V; E->ys = ys; E->cs = cs;
    E->defProbs = defProbs; E->updProbs = updProbs; E->dcq = dcq; E->acq = acq;
    E->mbs = (MB *)calloc((size_t)mbw * mbh, sizeof(MB));
    E->probs = (uint8_t *)malloc(1056);
    if (!E->mbs || !E->probs) { free(E->mbs); free(E->probs); free(E); return -1; }
    memcpy(E->probs, defProbs, 1056);
    build_costs(E);
    E->maxModes4 = (int)(4);
    E->keep16 = (int)(1);
    E->keepC = (int)(4);
    E->skipI4 = (int)(1);
    E->lamI16 = (1.0);
    E->lamI4 = (1.0);
    E->rdoqGamma = (0.4);
    E->rdoqLam = (1.0);
    E->dq_uvdc = (int)(0);
    E->dq_uvac = (int)(-10);
    double lamK = (0.015);
    int useI4 = (int)(1);

    // quantiser index from quality (file size ~ q^3, same law as libwebp's quality scale)
    double qf = (quality < 0 ? 0 : (quality > 100 ? 100 : quality)) / 100.0;
    double lin = qf < 0.75 ? qf * 2.0 / 3.0 : 2.0 * qf - 1.0;
    int qiBase = (int)lrint(127.0 * (1.0 - pow(lin, 1.0 / 3.0)));
    qiBase = clipq(qiBase);

    // ---- segment analysis: luma gradient activity per macroblock
    int nmb = mbw * mbh;
    float *act = (float *)malloc(sizeof(float) * (size_t)nmb);
    for (int my = 0; my < mbh; my++) for (int mx = 0; mx < mbw; mx++) {
        const uint8_t *p = Y + (size_t)my * 16 * ys + mx * 16;
        int s = 0;
        for (int j = 0; j < 16; j++) for (int i = 0; i < 15; i++) s += abs(p[j * ys + i] - p[j * ys + i + 1]);
        for (int j = 0; j < 15; j++) for (int i = 0; i < 16; i++) s += abs(p[j * ys + i] - p[(j + 1) * ys + i]);
        act[my * mbw + mx] = log2f(1.0f + (float)s / 8.0f);
    }
    double beta = (0.28);
    E->nseg = 1;
    int segOf_n[4] = {0, 0, 0, 0};
    uint8_t *segmap = (uint8_t *)calloc((size_t)nmb, 1);
    if (beta != 0.0 && nmb >= 4) {
        float *tmp = (float *)malloc(sizeof(float) * (size_t)nmb);
        memcpy(tmp, act, sizeof(float) * (size_t)nmb);
        // quantile boundaries via histogram on [0,16) in 256 bins
        int hist[256] = {0};
        double mean = 0;
        for (int i = 0; i < nmb; i++) { int b = (int)(act[i] * 16.0f); if (b > 255) b = 255; hist[b]++; mean += act[i]; }
        mean /= nmb;
        int cut[3], acc = 0, ci = 0;
        for (int b = 0; b < 256 && ci < 3; b++) { acc += hist[b]; while (ci < 3 && acc * 4 >= nmb * (ci + 1)) { cut[ci++] = b; } }
        while (ci < 3) cut[ci++] = 255;
        double sum[4] = {0}; int cnt[4] = {0};
        for (int i = 0; i < nmb; i++) {
            int b = (int)(act[i] * 16.0f); if (b > 255) b = 255;
            int s = b <= cut[0] ? 0 : (b <= cut[1] ? 1 : (b <= cut[2] ? 2 : 3));
            segmap[i] = (uint8_t)s; sum[s] += act[i]; cnt[s]++;
        }
        free(tmp);
        double baseStep = acq[qiBase];
        int qis[4], distinct = 0;
        for (int s = 0; s < 4; s++) {
            double c = cnt[s] ? sum[s] / cnt[s] : mean;
            double step = baseStep * pow(2.0, beta * (c - mean));
            int best = 0; double bd = 1e9;
            for (int q = 0; q < 128; q++) { double d = fabs(log((double)acq[q]) - log(step)); if (d < bd) { bd = d; best = q; } }
            qis[s] = best;
            if (s > 0 && qis[s] != qis[s - 1]) distinct = 1;
        }
        if (distinct) {
            E->nseg = 4;
            for (int s = 0; s < 4; s++) setup_seg(E, &E->sq[s], qis[s], lamK);
        } else memset(segmap, 0, (size_t)nmb);
    }
    if (E->nseg == 1) {
        setup_seg(E, &E->sq[0], qiBase, lamK);
        for (int s = 1; s < 4; s++) E->sq[s] = E->sq[0];
    }
    free(act);

    uint8_t probs[1056];
    uint8_t upd[1056];
    // ---- main loop
    int tl_pad = 32;
    uint8_t *topY = (uint8_t *)malloc((size_t)ys + 64), *topU = (uint8_t *)malloc((size_t)cs + 64), *topV = (uint8_t *)malloc((size_t)cs + 64);
    memset(topY, 127, (size_t)ys + 64); memset(topU, 127, (size_t)cs + 64); memset(topV, 127, (size_t)cs + 64);
    (void)tl_pad;
    uint8_t *topModes = (uint8_t *)calloc((size_t)mbw * 4, 1);   // B_DC = 0 outside the frame
    uint8_t *tnzAll = (uint8_t *)calloc((size_t)mbw * 9, 1);
    for (int mby = 0; mby < mbh; mby++) {
        uint8_t leftY[16], leftU[8], leftV[8];
        uint8_t leftModes[4] = {0, 0, 0, 0};
        uint8_t lnz[9] = {0};
        uint8_t tlY = mby == 0 ? 127 : 129, tlU = tlY, tlV = tlY;
        for (int mbx = 0; mbx < mbw; mbx++) {
            MB *mb = &E->mbs[mby * mbw + mbx];
            MBCtx C;
            C.mbx = mbx; C.mby = mby;
            const SegQ *sq = &E->sq[segmap[mby * mbw + mbx]];
            mb->seg = segmap[mby * mbw + mbx];
            segOf_n[mb->seg]++;
            for (int j = 0; j < 16; j++) memcpy(C.srcY + j * 16, Y + (size_t)(mby * 16 + j) * ys + mbx * 16, 16);
            for (int j = 0; j < 8; j++) {
                memcpy(C.srcU + j * 8, U + (size_t)(mby * 8 + j) * cs + mbx * 8, 8);
                memcpy(C.srcV + j * 8, V + (size_t)(mby * 8 + j) * cs + mbx * 8, 8);
            }
            // work buffers
            {
                uint8_t *W = C.WY;
                W[0] = mbx == 0 ? (mby == 0 ? 127 : 129) : (mby == 0 ? 127 : tlY);
                if (mby == 0) memset(W + 1, 127, 20);
                else {
                    memcpy(W + 1, topY + mbx * 16, 16);
                    if (mbx == mbw - 1) memset(W + 17, topY[mbx * 16 + 15], 4);
                    else memcpy(W + 17, topY + mbx * 16 + 16, 4);
                }
                for (int j = 0; j < 16; j++) W[(j + 1) * BPS] = mbx == 0 ? 129 : leftY[j];
                for (int r = 1; r < 4; r++) memcpy(W + (4 * r) * BPS + 17, W + 17, 4);
                uint8_t *WU = C.WU, *WV = C.WV;
                WU[0] = mbx == 0 ? (mby == 0 ? 127 : 129) : (mby == 0 ? 127 : tlU);
                WV[0] = mbx == 0 ? (mby == 0 ? 127 : 129) : (mby == 0 ? 127 : tlV);
                if (mby == 0) { memset(WU + 1, 127, 8); memset(WV + 1, 127, 8); }
                else { memcpy(WU + 1, topU + mbx * 8, 8); memcpy(WV + 1, topV + mbx * 8, 8); }
                for (int j = 0; j < 8; j++) { WU[(j + 1) * BPS] = mbx == 0 ? 129 : leftU[j]; WV[(j + 1) * BPS] = mbx == 0 ? 129 : leftV[j]; }
            }
            memcpy(C.tnz, tnzAll + mbx * 9, 9);
            memcpy(C.lnz, lnz, 9);
            // luma: I16
            Cand best16, cand;
            best16.j = 1e300;
            {
                int ord[4] = {0, 1, 2, 3};
                if (E->keep16 < 4) {
                    int sc[4];
                    uint8_t pr[256];
                    for (int m = 0; m < 4; m++) { pred_block(pr, 16, C.WY, 16, m, mby > 0, mbx > 0); sc[m] = sse_blk(C.srcY, 16, pr, 16, 16, 16); }
                    for (int i = 0; i < E->keep16; i++) {
                        int bi = i;
                        for (int k = i + 1; k < 4; k++) if (sc[ord[k]] < sc[ord[bi]]) bi = k;
                        int t = ord[i]; ord[i] = ord[bi]; ord[bi] = t;
                    }
                }
                for (int oi = 0; oi < E->keep16; oi++) {
                    int m = ord[oi];
                    eval_i16(E, sq, &C, m, &cand);
                    if (cand.j < best16.j) { best16 = cand; mb->ymode = (uint8_t)m; }
                }
            }
            Cand *useY = &best16;
            Cand c4;
            int isI4 = 0;
            int zero16 = 1;
            if (E->skipI4) { for (int b = 0; b < 25 && zero16; b++) for (int k = 0; k < 16; k++) if (best16.lv[b][k]) { zero16 = 0; break; } } else zero16 = 0;
            if (useI4 && !zero16) {
                uint8_t tm[4], lm[4];
                memcpy(tm, topModes + mbx * 4, 4); memcpy(lm, leftModes, 4);
                double j4 = eval_i4(E, sq, &C, tm, lm, best16.j, &c4);
                if (j4 < best16.j) { isI4 = 1; useY = &c4; mb->ymode = 4; memcpy(mb->bm, c4.bm, 16); }
            }
            // chroma
            Cand bestC;
            bestC.j = 1e300;
            {
                int ord[4] = {0, 1, 2, 3};
                if (E->keepC < 4) {
                    int sc[4];
                    uint8_t pr[64];
                    for (int m = 0; m < 4; m++) {
                        pred_block(pr, 8, C.WU, 8, m, mby > 0, mbx > 0); sc[m] = sse_blk(C.srcU, 8, pr, 8, 8, 8);
                        pred_block(pr, 8, C.WV, 8, m, mby > 0, mbx > 0); sc[m] += sse_blk(C.srcV, 8, pr, 8, 8, 8);
                    }
                    for (int i = 0; i < E->keepC; i++) {
                        int bi = i;
                        for (int k = i + 1; k < 4; k++) if (sc[ord[k]] < sc[ord[bi]]) bi = k;
                        int t = ord[i]; ord[i] = ord[bi]; ord[bi] = t;
                    }
                }
                for (int oi = 0; oi < E->keepC; oi++) {
                    eval_chroma(E, sq, &C, ord[oi], &cand);
                    if (cand.j < bestC.j) { bestC = cand; mb->uvmode = (uint8_t)ord[oi]; }
                }
            }
            // store levels
            if (isI4) { memset(mb->lv[24], 0, 32); memcpy(mb->lv, c4.lv, sizeof(int16_t) * 16 * 16); }
            else { memcpy(mb->lv, best16.lv, sizeof(int16_t) * 16 * 16); memcpy(mb->lv[24], best16.lv[24], 32); }
            memcpy(mb->lv[16], bestC.lv[16], sizeof(int16_t) * 16 * 8);
            // skip decision
            int any = 0;
            for (int b = 0; b < 25 && !any; b++) for (int k = 0; k < 16; k++) if (mb->lv[b][k]) { any = 1; break; }
            mb->skip = !any;
            if (!isI4) memset(mb->bm, bmode_of_ymode(mb->ymode), 16);
            // update contexts
            if (mb->skip) {
                for (int k = 0; k < 8; k++) { tnzAll[mbx * 9 + k] = 0; lnz[k] = 0; }
                if (!isI4) tnzAll[mbx * 9 + 8] = lnz[8] = 0;
            } else {
                memcpy(tnzAll + mbx * 9, useY->tnzY, 4); memcpy(lnz, useY->lnzY, 4);
                memcpy(tnzAll + mbx * 9 + 4, bestC.tnzY, 4); memcpy(lnz + 4, bestC.lnzY, 4);
                if (!isI4) tnzAll[mbx * 9 + 8] = lnz[8] = useY->y2nz;
            }
            // bmode contexts
            if (isI4) {
                for (int k = 0; k < 4; k++) { topModes[mbx * 4 + k] = mb->bm[12 + k]; leftModes[k] = mb->bm[k * 4 + 3]; }
            } else {
                int bmv = bmode_of_ymode(mb->ymode);
                for (int k = 0; k < 4; k++) { topModes[mbx * 4 + k] = (uint8_t)bmv; leftModes[k] = (uint8_t)bmv; }
            }
            // reconstruction -> top/left buffers
            tlY = topY[mbx * 16 + 15]; tlU = topU[mbx * 8 + 7]; tlV = topV[mbx * 8 + 7];
            memcpy(topY + mbx * 16, useY->rec + 15 * 16, 16);
            for (int j = 0; j < 16; j++) leftY[j] = useY->rec[j * 16 + 15];
            memcpy(topU + mbx * 8, bestC.recC[0] + 7 * 8, 8); memcpy(topV + mbx * 8, bestC.recC[1] + 7 * 8, 8);
            for (int j = 0; j < 8; j++) { leftU[j] = bestC.recC[0][j * 8 + 7]; leftV[j] = bestC.recC[1][j * 8 + 7]; }
        }
    }
    free(topY); free(topU); free(topV); free(topModes); free(tnzAll);

    // ---- token statistics -> probabilities
    int *cnt = (int *)calloc(1056 * 2, sizeof(int));
    TokOut st = {NULL, cnt};
    walk_tokens(E, &st);
    memcpy(probs, defProbs, 1056);
    memset(upd, 0, sizeof(upd));
    for (int i = 0; i < 1056; i++) {
        int n0 = cnt[i * 2], n1 = cnt[i * 2 + 1];
        if (n0 + n1 == 0) continue;
        int np = (int)lrint(256.0 * n0 / (n0 + n1));
        if (np < 1) np = 1; if (np > 255) np = 255;
        int old = defProbs[i], up = updProbs[i];
        double save = ((double)n0 * (BC0[old] - BC0[np]) + (double)n1 * (BC1[old] - BC1[np])) / 256.0;
        if (save > 8.0 + (BC1[up] - BC0[up]) / 256.0) { upd[i] = 1; probs[i] = (uint8_t)np; }
    }
    free(cnt);
    memcpy(E->probs, probs, 1056);

    // ---- loop-filter levels per segment (decoder applies them per macroblock)
    double lfK = (0.9);
    int lfMax = 0;
    for (int s = 0; s < 4; s++) {
        int qi = E->sq[s].qi;
        int lf = (int)lrint(lfK * (qi * 0.3 + (qi > 0 ? 2 : 0)));
        E->sq[s].lf = lf < 0 ? 0 : (lf > 63 ? 63 : lf);
        if (E->nseg == 1 && s > 0) E->sq[s].lf = E->sq[0].lf;
        if (E->sq[s].lf > lfMax) lfMax = E->sq[s].lf;
    }

    // ---- first partition
    BoolEnc fb;
    be_init(&fb, (size_t)nmb * 8 + 1024);
    be_lit(&fb, 0, 1); be_lit(&fb, 0, 1);               // colour space, clamping type
    int segP[3] = {255, 255, 255};
    if (E->nseg > 1) {
        int n01 = segOf_n[0] + segOf_n[1], n23 = segOf_n[2] + segOf_n[3];
        int tot = n01 + n23;
        #define PROB(a, b) ((a) + (b) == 0 ? 255 : (int)fmin(255.0, fmax(1.0, lrint(256.0 * (a) / ((a) + (b))))))
        segP[0] = PROB(n01, n23); segP[1] = PROB(segOf_n[0], segOf_n[1]); segP[2] = PROB(segOf_n[2], segOf_n[3]);
        (void)tot;
        be_lit(&fb, 1, 1);                              // segmentation enabled
        be_lit(&fb, 1, 1); be_lit(&fb, 1, 1);           // update map, update data
        be_lit(&fb, 1, 1);                              // absolute values
        for (int s = 0; s < 4; s++) { be_lit(&fb, 1, 1); be_lit(&fb, E->sq[s].qi, 7); be_lit(&fb, 0, 1); }
        for (int s = 0; s < 4; s++) { be_lit(&fb, 1, 1); be_lit(&fb, E->sq[s].lf, 6); be_lit(&fb, 0, 1); }
        for (int k = 0; k < 3; k++) { if (segP[k] != 255) { be_lit(&fb, 1, 1); be_lit(&fb, segP[k], 8); } else be_lit(&fb, 0, 1); }
    } else be_lit(&fb, 0, 1);
    be_lit(&fb, 0, 1);                                  // normal loop filter
    be_lit(&fb, lfMax, 6); be_lit(&fb, 0, 3);           // level, sharpness
    be_lit(&fb, 0, 1);                                  // no loop-filter deltas
    be_lit(&fb, 0, 2);                                  // one token partition
    be_lit(&fb, E->nseg > 1 ? E->sq[0].qi : E->sq[0].qi, 7);
    be_lit(&fb, 0, 1);                                  // y1 dc delta
    be_lit(&fb, 0, 1);                                  // y2 dc delta
    be_lit(&fb, 0, 1);                                  // y2 ac delta
    for (int k = 0; k < 2; k++) {
        int d = k == 0 ? E->dq_uvdc : E->dq_uvac;
        if (d == 0) be_lit(&fb, 0, 1);
        else { be_lit(&fb, 1, 1); be_lit(&fb, d < 0 ? -d : d, 4); be_lit(&fb, d < 0, 1); }
    }
    be_lit(&fb, 1, 1);                                  // refresh_entropy_probs
    for (int i = 0; i < 1056; i++) {
        be_put(&fb, updProbs[i], upd[i]);
        if (upd[i]) be_lit(&fb, probs[i], 8);
    }
    int nSkip = 0;
    for (int i = 0; i < nmb; i++) nSkip += E->mbs[i].skip;
    int useSkip = nSkip > 0;
    be_lit(&fb, useSkip, 1);
    int pSkip = (int)lrint(256.0 * (nmb - nSkip) / nmb);
    if (pSkip < 1) pSkip = 1; if (pSkip > 255) pSkip = 255;
    if (useSkip) be_lit(&fb, pSkip, 8);
    uint8_t *topBm = (uint8_t *)calloc((size_t)mbw * 4, 1);
    for (int mby = 0; mby < mbh; mby++) {
        uint8_t leftBm[4] = {0, 0, 0, 0};
        for (int mbx = 0; mbx < mbw; mbx++) {
            const MB *mb = &E->mbs[mby * mbw + mbx];
            if (E->nseg > 1) {
                int s = mb->seg;
                be_put(&fb, segP[0], s >= 2);
                be_put(&fb, segP[s >= 2 ? 2 : 1], s & 1);
            }
            if (useSkip) be_put(&fb, pSkip, mb->skip);
            if (mb->ymode == 4) {
                be_put(&fb, 145, 0);
                for (int b = 0; b < 16; b++) {
                    int bx = b & 3, by = b >> 2;
                    int A = by == 0 ? topBm[mbx * 4 + bx] : mb->bm[b - 4];
                    int L = bx == 0 ? leftBm[by] : mb->bm[b - 1];
                    int m = mb->bm[b];
                    for (int k = 0; k < bm_path_len[m]; k++) be_put(&fb, KF_BMODE_PROB[A][L][(int)bm_path_node[m][k]], bm_path_bit[m][k]);
                }
            } else {
                be_put(&fb, 145, 1);
                switch (mb->ymode) {
                case 0: be_put(&fb, 156, 0); be_put(&fb, 163, 0); break;
                case 1: be_put(&fb, 156, 0); be_put(&fb, 163, 1); break;
                case 2: be_put(&fb, 156, 1); be_put(&fb, 128, 0); break;
                default: be_put(&fb, 156, 1); be_put(&fb, 128, 1); break;
                }
            }
            switch (mb->uvmode) {
            case 0: be_put(&fb, 142, 0); break;
            case 1: be_put(&fb, 142, 1); be_put(&fb, 114, 0); break;
            case 2: be_put(&fb, 142, 1); be_put(&fb, 114, 1); be_put(&fb, 183, 0); break;
            default: be_put(&fb, 142, 1); be_put(&fb, 114, 1); be_put(&fb, 183, 1); break;
            }
            for (int k = 0; k < 4; k++) { topBm[mbx * 4 + k] = mb->bm[12 + k]; leftBm[k] = mb->bm[k * 4 + 3]; }
        }
    }
    free(topBm);
    be_finish(&fb);
    // ---- token partition
    BoolEnc tb;
    be_init(&tb, (size_t)nmb * 64 + 1024);
    TokOut wr = {&tb, NULL};
    walk_tokens(E, &wr);
    be_finish(&tb);
    free(segmap);
    free(E->mbs); free(E->probs); free(E);
    if (fb.oom || tb.oom) { free(fb.p); free(tb.p); return -1; }
    if (fb.n > 0x7FFFF) { free(fb.p); free(tb.p); return -3; }   // first partition size does not fit the 19-bit field
    size_t total = 10 + fb.n + tb.n;
    uint8_t *out = (uint8_t *)malloc(total);
    if (!out) { free(fb.p); free(tb.p); return -1; }
    uint32_t tag = ((uint32_t)fb.n << 5) | (1u << 4);
    out[0] = (uint8_t)tag; out[1] = (uint8_t)(tag >> 8); out[2] = (uint8_t)(tag >> 16);
    out[3] = 0x9D; out[4] = 0x01; out[5] = 0x2A;
    out[6] = (uint8_t)width; out[7] = (uint8_t)(width >> 8); out[8] = (uint8_t)height; out[9] = (uint8_t)(height >> 8);
    memcpy(out + 10, fb.p, fb.n); memcpy(out + 10 + fb.n, tb.p, tb.n);
    free(fb.p); free(tb.p);
    *outp = out;
    return (int64_t)total;
}

void sr_vp8_free(uint8_t *p) { free(p); }

// ---------------------------------------------------------------------------------------------------------------------
// RGB(A)/gray rows -> studio-range YUV 4:2:0 (BT.601). Rows r0/r1 are pixel rows of `ch` channels (BGR order, or gray);
// `w` real pixels, outputs are `pw` wide (right edge replicated). Luma goes to y0/y1, 2x2 averaged chroma to u/v.
void sr_vp8_yuv_rows(const uint8_t *r0, const uint8_t *r1, int32_t ch, int32_t w, int32_t pw, uint8_t *y0, uint8_t *y1,
                     uint8_t *u, uint8_t *v) {
    for (int rowi = 0; rowi < 2; rowi++) {
        const uint8_t *r = rowi ? r1 : r0;
        uint8_t *y = rowi ? y1 : y0;
        for (int x = 0; x < pw; x++) {
            int sx = x < w ? x : w - 1;
            int R, G, B;
            if (ch == 1) R = G = B = r[sx]; else { B = r[sx * ch]; G = r[sx * ch + 1]; R = r[sx * ch + 2]; }
            y[x] = clip255((16839 * R + 33059 * G + 6420 * B + (16 << 16) + 32768) >> 16);
        }
    }
    for (int x = 0; x < pw / 2; x++) {
        int sr = 0, sg = 0, sb = 0;
        for (int dy = 0; dy < 2; dy++) for (int dx = 0; dx < 2; dx++) {
            const uint8_t *r = dy ? r1 : r0;
            int sx = 2 * x + dx; if (sx > w - 1) sx = w - 1;
            if (ch == 1) { sr += r[sx]; sg += r[sx]; sb += r[sx]; }
            else { sb += r[sx * ch]; sg += r[sx * ch + 1]; sr += r[sx * ch + 2]; }
        }
        int R = (sr + 2) >> 2, G = (sg + 2) >> 2, B = (sb + 2) >> 2;
        u[x] = clip255((-9719 * R - 19081 * G + 28800 * B + (128 << 16) + 32768) >> 16);
        v[x] = clip255((28800 * R - 24116 * G - 4684 * B + (128 << 16) + 32768) >> 16);
    }
}
