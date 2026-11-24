// SafariumRasterC — own VP8L (WebP lossless) encoder core (Area C). Written from the public WebP Lossless Bitstream
// Specification: subtract-green, per-tile predictor (entropy-chosen modes), per-tile cross-colour transform, palette
// (colour indexing) with pixel bundling, LZ77 with 2-D distance codes and cost-based (dynamic programming) parsing that knows
// the colour cache, colour cache, meta prefix codes (entropy image) built by histogram clustering, canonical Huffman codes.
// No libwebp code is used; the search is our own.
//
// What is encoded is decided by real encoded sizes, not by entropy estimates: palette images try the plain and (for big
// palettes) the predictor variant, graphics / screenshots (long LZ77 copies) skip the predictor, borderline images encode both
// ways; images above TRIAL_FULL pixels compare the candidates on a sample of horizontal bands. Memory is bounded per pixel
// (hash chains and the DP cost row are rings of one window; one token array at a time) and every allocation is checked:
// sr_vp8l_encode returns a negative code (and *outp = NULL) instead of crashing.
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------------------------------------------------
// Bit writer

typedef struct { uint8_t *p; size_t n, cap; uint64_t acc; int nb; int oom; } BW;

static void bw_init(BW *b, size_t cap) {
    b->p = (uint8_t *)malloc(cap < 64 ? 64 : cap); b->cap = b->p ? (cap < 64 ? 64 : cap) : 0; b->n = 0; b->acc = 0; b->nb = 0; b->oom = b->p == NULL;
}
static inline void bw_byte(BW *b, uint8_t v) {
    if (b->n == b->cap) {
        if (b->oom) return;
        uint8_t *np = (uint8_t *)realloc(b->p, b->cap * 2);
        if (!np) { b->oom = 1; return; }
        b->p = np; b->cap *= 2;
    }
    b->p[b->n++] = v;
}
static inline void bw_put(BW *b, uint32_t v, int len) {
    if (len < 32) v &= (1u << len) - 1;
    b->acc |= (uint64_t)v << b->nb; b->nb += len;
    while (b->nb >= 8) { bw_byte(b, (uint8_t)b->acc); b->acc >>= 8; b->nb -= 8; }
}
static void bw_flush(BW *b) { if (b->nb > 0) { bw_byte(b, (uint8_t)b->acc); b->acc = 0; b->nb = 0; } }

// ---------------------------------------------------------------------------------------------------------------------
// Huffman codes

#define MAXSYM 2400

static int ll_cmp_pair(const void *a, const void *b) {
    const uint64_t *x = (const uint64_t *)a, *y = (const uint64_t *)b;
    return x[0] < y[0] ? -1 : (x[0] > y[0] ? 1 : (x[1] < y[1] ? -1 : (x[1] > y[1])));
}

static int ll_cmp64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : (x > y);
}

static void huff_lengths(const uint32_t *freq, int n, int maxlen, uint8_t *lens) {
    memset(lens, 0, (size_t)n);
    int sym[MAXSYM], m = 0;
    for (int i = 0; i < n; i++) if (freq[i]) sym[m++] = i;
    if (m == 0) return;
    if (m == 1) { lens[sym[0]] = 1; return; }
    uint64_t cmin = 1;
    for (;;) {
        // sort leaves by (freq, symbol) with a simple counting-free approach: indices sorted by qsort on packed key
        uint64_t keys[MAXSYM];
        for (int i = 0; i < m; i++) {
            uint64_t f = freq[sym[i]]; if (f < cmin) f = cmin;
            keys[i] = (f << 16) | (uint64_t)i;      // m < 65536
        }
        // insertion into sorted order via qsort
        qsort(keys, (size_t)m, sizeof(uint64_t), ll_cmp64);
        uint64_t w[2 * MAXSYM];
        int parent[2 * MAXSYM], leafSym[MAXSYM];
        for (int i = 0; i < m; i++) { w[i] = keys[i] >> 16; leafSym[i] = sym[keys[i] & 0xFFFF]; }
        int li = 0, ii = m, nn = m;     // leaves [0,m), internal nodes [m, nn)
        int ihead = m;
        while (nn < 2 * m - 1) {
            int pick[2];
            for (int k = 0; k < 2; k++) {
                if (li < m && (ihead >= nn || w[li] <= w[ihead])) pick[k] = li++;
                else pick[k] = ihead++;
            }
            w[nn] = w[pick[0]] + w[pick[1]];
            parent[pick[0]] = nn; parent[pick[1]] = nn;
            nn++;
        }
        (void)ii;
        int depth[2 * MAXSYM];
        depth[2 * m - 2] = 0;
        int maxd = 0;
        for (int k = 2 * m - 3; k >= 0; k--) { depth[k] = depth[parent[k]] + 1; if (depth[k] > maxd && k < m) maxd = depth[k]; }
        if (maxd <= maxlen) {
            for (int i = 0; i < m; i++) lens[leafSym[i]] = (uint8_t)depth[i];
            return;
        }
        cmin *= 2;
    }
}

/// Canonical codes (spec 3.7.2.1.x), bit-reversed for the LSB-first stream: out = reversed code | len << 16.
static void canon_codes(const uint8_t *lens, int n, uint32_t *out) {
    int count[16] = {0}, next[16];
    for (int i = 0; i < n; i++) count[lens[i]]++;
    count[0] = 0;
    int code = 0;
    for (int l = 1; l < 16; l++) { code = (code + count[l - 1]) << 1; next[l] = code; }
    for (int i = 0; i < n; i++) {
        int l = lens[i];
        if (!l) { out[i] = 0; continue; }
        uint32_t c = (uint32_t)next[l]++, r = 0;
        for (int k = 0; k < l; k++) { r = (r << 1) | (c & 1); c >>= 1; }
        out[i] = r | ((uint32_t)l << 16);
    }
}

static const int CLORDER[19] = {17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

/// Write one prefix code for `freq` over an alphabet of `alpha` symbols; codes receives reversed code | len << 16.
/// Returns the number of bits written for the code description.
static void write_code(BW *bw, const uint32_t *freqIn, int alpha, uint32_t *codes) {
    uint32_t freq[MAXSYM];
    memcpy(freq, freqIn, sizeof(uint32_t) * (size_t)alpha);
    int used[MAXSYM], nu = 0;
    for (int i = 0; i < alpha; i++) if (freq[i]) used[nu++] = i;
    if (nu == 0) { freq[0] = 1; used[0] = 0; nu = 1; }
    if (nu == 1 && used[0] >= 256) { freq[0] = 1; nu = 0; for (int i = 0; i < alpha; i++) if (freq[i]) used[nu++] = i; }
    memset(codes, 0, sizeof(uint32_t) * (size_t)alpha);
    if (nu == 1) {
        int s = used[0];
        bw_put(bw, 1, 1); bw_put(bw, 0, 1);
        if (s <= 1) { bw_put(bw, 0, 1); bw_put(bw, (uint32_t)s, 1); } else { bw_put(bw, 1, 1); bw_put(bw, (uint32_t)s, 8); }
        return;     // zero bits per occurrence
    }
    uint8_t lens[MAXSYM];
    huff_lengths(freq, alpha, 15, lens);
    canon_codes(lens, alpha, codes);
    if (nu == 2 && used[1] < 256) {
        bw_put(bw, 1, 1); bw_put(bw, 1, 1);
        if (used[0] <= 1) { bw_put(bw, 0, 1); bw_put(bw, (uint32_t)used[0], 1); } else { bw_put(bw, 1, 1); bw_put(bw, (uint32_t)used[0], 8); }
        bw_put(bw, (uint32_t)used[1], 8);
        return;
    }
    // run-length coded code lengths
    uint8_t seq[MAXSYM + 8], extra[MAXSYM + 8];
    int ns = 0, r = 0;
    while (r < alpha) {
        int v = lens[r], run = 1;
        while (r + run < alpha && lens[r + run] == v) run++;
        if (v == 0 && run >= 3) {
            int n = run < 138 ? run : 138;
            if (n >= 11) { seq[ns] = 18; extra[ns++] = (uint8_t)(n - 11); } else { seq[ns] = 17; extra[ns++] = (uint8_t)(n - 3); }
            r += n;
        } else if (v != 0 && run >= 4) {
            seq[ns] = (uint8_t)v; extra[ns++] = 0;
            int left = run - 1 < 6 ? run - 1 : 6;
            seq[ns] = 16; extra[ns++] = (uint8_t)(left - 3);
            r += 1 + left;
        } else { seq[ns] = (uint8_t)v; extra[ns++] = 0; r++; }
    }
    uint32_t cf[19] = {0};
    for (int i = 0; i < ns; i++) cf[seq[i]]++;
    int ncf = 0;
    for (int i = 0; i < 19; i++) if (cf[i]) ncf++;
    if (ncf < 2) cf[cf[0] == 0 ? 0 : 1]++;
    uint8_t cl[19]; uint32_t cc[19];
    huff_lengths(cf, 19, 7, cl);
    canon_codes(cl, 19, cc);
    int ncl = 19;
    while (ncl > 4 && cl[CLORDER[ncl - 1]] == 0) ncl--;
    bw_put(bw, 0, 1);
    bw_put(bw, (uint32_t)(ncl - 4), 4);
    for (int k = 0; k < ncl; k++) bw_put(bw, cl[CLORDER[k]], 3);
    bw_put(bw, 0, 1);
    for (int k = 0; k < ns; k++) {
        uint32_t c = cc[seq[k]];
        bw_put(bw, c & 0xFFFF, (int)(c >> 16));
        if (seq[k] == 16) bw_put(bw, extra[k], 2); else if (seq[k] == 17) bw_put(bw, extra[k], 3); else if (seq[k] == 18) bw_put(bw, extra[k], 7);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Prefix coding of lengths / distances, distance map

static inline void prefix_code(int v, int *sym, int *nbits, int *val) {
    int d = v - 1;
    if (d < 4) { *sym = d; *nbits = 0; *val = 0; return; }
    int hi = 31 - __builtin_clz((unsigned)d);
    int second = (d >> (hi - 1)) & 1;
    int eb = hi - 1;
    *sym = 2 * hi + second; *nbits = eb; *val = d & ((1 << eb) - 1);
}

static const int8_t PLANE[120][2] = {{0,1},{1,0},{1,1},{-1,1},{0,2},{2,0},{1,2},{-1,2},{2,1},{-2,1},{2,2},{-2,2},{0,3},{3,0},{1,3},{-1,3},{3,1},{-3,1},{2,3},{-2,3},{3,2},{-3,2},{0,4},{4,0},{1,4},{-1,4},{4,1},{-4,1},{3,3},{-3,3},{2,4},{-2,4},{4,2},{-4,2},{0,5},{3,4},{-3,4},{4,3},{-4,3},{5,0},{1,5},{-1,5},{5,1},{-5,1},{2,5},{-2,5},{5,2},{-5,2},{4,4},{-4,4},{3,5},{-3,5},{5,3},{-5,3},{0,6},{6,0},{1,6},{-1,6},{6,1},{-6,1},{2,6},{-2,6},{6,2},{-6,2},{4,5},{-4,5},{5,4},{-5,4},{3,6},{-3,6},{6,3},{-6,3},{0,7},{7,0},{1,7},{-1,7},{5,5},{-5,5},{7,1},{-7,1},{4,6},{-4,6},{6,4},{-6,4},{2,7},{-2,7},{7,2},{-7,2},{3,7},{-3,7},{7,3},{-7,3},{5,6},{-5,6},{6,5},{-6,5},{8,0},{4,7},{-4,7},{7,4},{-7,4},{8,1},{8,2},{6,6},{-6,6},{8,3},{5,7},{-5,7},{7,5},{-7,5},{8,4},{6,7},{-6,7},{7,6},{-7,6},{8,5},{7,7},{-7,7},{8,6},{8,7}};

typedef struct { int dist[256]; int code[256]; int cdist[16]; int ncdist; } DistMap;   // open-addressed table dist -> code

static void distmap_init(DistMap *dm, int w) {
    for (int i = 0; i < 256; i++) { dm->dist[i] = 0; dm->code[i] = 0; }
    for (int k = 0; k < 120; k++) {
        int d = PLANE[k][0] + PLANE[k][1] * w;
        if (d < 1) d = 1;
        unsigned h = ((unsigned)d * 2654435761u) >> 24;
        for (;;) {
            if (dm->dist[h] == d) break;                      // keep the smallest code (inserted first)
            if (dm->dist[h] == 0) { dm->dist[h] = d; dm->code[h] = k + 1; break; }
            h = (h + 1) & 255;
        }
    }
    dm->ncdist = 0;
    for (int k = 0; k < 16; k++) { int d = PLANE[k][0] + PLANE[k][1] * w; if (d < 1) d = 1; dm->cdist[dm->ncdist++] = d; }
}
static inline int dist_code(const DistMap *dm, int d) {
    unsigned h = ((unsigned)d * 2654435761u) >> 24;
    for (;;) {
        if (dm->dist[h] == d) return dm->code[h];
        if (dm->dist[h] == 0) return d + 120;
        h = (h + 1) & 255;
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Tokens, LZ77

typedef struct { uint32_t a; uint16_t len; uint16_t kind; } Tok;     // kind 0 literal (a = ARGB), 1 cache (a = index), 2 copy (a = dist code)

typedef struct { Tok *t; size_t n, cap; } Toks;
#define WINDOW ((1 << 20) - 120)

// ---------------------------------------------------------------------------------------------------------------------
// Histograms and cost model

static float NLOGN[65536];
__attribute__((constructor)) static void ll_init(void) {
    NLOGN[0] = 0;
    for (int i = 1; i < 65536; i++) NLOGN[i] = (float)(i * log2((double)i));
}
static inline double nlogn(uint32_t n) { return n < 65536 ? (double)NLOGN[n] : (double)n * log2((double)n); }

#define HDR_BASE 12.0      // estimated bits of a prefix-code description: base + per used symbol (tuned on Kodak + graphics)
#define HDR_PER 4.0
static double array_cost(const uint32_t *a, int n) {
    uint64_t N = 0; double s = 0; int used = 0;
    for (int i = 0; i < n; i++) if (a[i]) { N += a[i]; s += nlogn(a[i]); used++; }
    if (used <= 1) return used ? 8.0 : 0.0;
    double hdr = used == 2 ? 20.0 : HDR_BASE + HDR_PER * used;
    return (double)N * log2((double)N) - s + hdr;
}

typedef struct { int gAlpha; uint32_t *g, *r, *b, *a, *d; } HistoView;
static inline int histo_total(int gAlpha) { return gAlpha + 256 * 3 + 40; }
static inline HistoView hv(uint32_t *base, int gAlpha) {
    HistoView v = {gAlpha, base, base + gAlpha, base + gAlpha + 256, base + gAlpha + 512, base + gAlpha + 768};
    return v;
}
static double histo_cost(uint32_t *base, int gAlpha) {
    HistoView v = hv(base, gAlpha);
    return array_cost(v.g, gAlpha) + array_cost(v.r, 256) + array_cost(v.b, 256) + array_cost(v.a, 256) + array_cost(v.d, 40);
}
static inline void histo_add_tok(HistoView v, const Tok *t) {
    if (t->kind == 0) { v.a[t->a >> 24]++; v.r[(t->a >> 16) & 255]++; v.g[(t->a >> 8) & 255]++; v.b[t->a & 255]++; }
    else if (t->kind == 1) v.g[280 + t->a]++;
    else { int s, nb, val; prefix_code(t->len, &s, &nb, &val); v.g[256 + s]++; prefix_code((int)t->a, &s, &nb, &val); v.d[s]++; }
}

/// Apply a colour cache of `bits` to a literal-token stream in place (hits become kind 1). Returns 0 on out of memory.
static int apply_cache(const uint32_t *px, Toks *T, int bits) {
    uint32_t *cache = (uint32_t *)calloc((size_t)1 << bits, sizeof(uint32_t));
    if (!cache) return 0;
    size_t pos = 0;
    for (size_t k = 0; k < T->n; k++) {
        Tok *t = &T->t[k];
        if (t->kind == 0) {
            uint32_t key = (px[pos] * 0x1E35A7BDu) >> (32 - bits);
            if (cache[key] == px[pos]) { t->kind = 1; t->a = key; } else cache[key] = px[pos];
            pos++;
        } else {
            for (size_t j = pos; j < pos + t->len; j++) cache[(px[j] * 0x1E35A7BDu) >> (32 - bits)] = px[j];
            pos += t->len;
        }
    }
    free(cache);
    return 1;
}

/// Estimated bits of the token stream as one histogram group, for cache size `bits` (0 = none), without modifying tokens.
/// Returns a negative value on out of memory.
static double cache_cost(const uint32_t *px, const Toks *T, int bits) {
    int gAlpha = 280 + (bits ? 1 << bits : 0);
    uint32_t *hb = (uint32_t *)calloc((size_t)histo_total(gAlpha), sizeof(uint32_t));
    uint32_t *cache = bits ? (uint32_t *)calloc((size_t)1 << bits, sizeof(uint32_t)) : NULL;
    if (!hb || (bits && !cache)) { free(hb); free(cache); return -1; }
    HistoView v = hv(hb, gAlpha);
    size_t pos = 0;
    for (size_t k = 0; k < T->n; k++) {
        const Tok *t = &T->t[k];
        if (t->kind == 0) {
            if (bits) {
                uint32_t key = (px[pos] * 0x1E35A7BDu) >> (32 - bits);
                if (cache[key] == px[pos]) v.g[280 + key]++; else { cache[key] = px[pos]; Tok l = *t; l.a = px[pos]; histo_add_tok(v, &l); }
            } else { Tok l = *t; l.a = px[pos]; histo_add_tok(v, &l); }
            pos++;
        } else {
            histo_add_tok(v, t);
            if (bits) for (size_t j = pos; j < pos + t->len; j++) cache[(px[j] * 0x1E35A7BDu) >> (32 - bits)] = px[j];
            pos += t->len;
        }
    }
    double c = histo_cost(hb, gAlpha);
    free(hb); free(cache);
    return c;
}

// ---------------------------------------------------------------------------------------------------------------------
// Match finder: 2-pixel hash chains (short / near matches) and 4-pixel hash chains (long matches without walking the long
// chains of repeated 2-pixel keys). The chains are rings of one window, so memory does not grow with the image.

#define RINGW (1 << 20)
typedef struct {
    const uint32_t *px; size_t n; int w;
    DistMap dm;
    int hbits, use4;
    int32_t *head, *head4, *prev, *prev4;
    size_t rmask;
} MF;

static void mf_free(MF *m) { free(m->head); free(m->head4); free(m->prev); free(m->prev4); m->head = m->head4 = m->prev = m->prev4 = NULL; }

static int mf_init(MF *m, const uint32_t *px, int w, int h, int use4) {
    memset(m, 0, sizeof *m);
    m->px = px; m->w = w; m->n = (size_t)w * h; m->use4 = use4;
    distmap_init(&m->dm, w);
    m->hbits = m->n < (1 << 16) ? 14 : 17;
    size_t ring = 1024;
    while (ring < m->n && ring < RINGW) ring <<= 1;
    m->rmask = ring - 1;
    m->head = (int32_t *)malloc(sizeof(int32_t) << m->hbits);
    m->prev = (int32_t *)malloc(sizeof(int32_t) * ring);
    if (use4) { m->head4 = (int32_t *)malloc(sizeof(int32_t) << m->hbits); m->prev4 = (int32_t *)malloc(sizeof(int32_t) * ring); }
    if (!m->head || !m->prev || (use4 && (!m->head4 || !m->prev4))) { mf_free(m); return 0; }
    memset(m->head, 0xFF, sizeof(int32_t) << m->hbits);
    if (use4) memset(m->head4, 0xFF, sizeof(int32_t) << m->hbits);
    return 1;
}

static inline uint32_t mf_h2(const MF *m, size_t i) { return (uint32_t)((((uint64_t)m->px[i] << 32) | m->px[i + 1]) * 0x9E3779B97F4A7C15ull >> (64 - m->hbits)); }
static inline uint32_t mf_h4(const MF *m, size_t i) {
    uint64_t a = ((uint64_t)m->px[i] << 32) | m->px[i + 1], b = ((uint64_t)m->px[i + 2] << 32) | m->px[i + 3];
    return (uint32_t)((a * 0x9E3779B97F4A7C15ull ^ (b + 0x632BE59BD9B4E019ull) * 0xC2B2AE3D27D4EB4Full) >> (64 - m->hbits));
}
static inline void mf_insert(MF *m, size_t i) {
    if (i + 1 < m->n) { uint32_t hh = mf_h2(m, i); m->prev[i & m->rmask] = m->head[hh]; m->head[hh] = (int32_t)i; }
    if (m->use4 && i + 3 < m->n) { uint32_t hh = mf_h4(m, i); m->prev4[i & m->rmask] = m->head4[hh]; m->head4[hh] = (int32_t)i; }
}

static inline size_t match_len_px(const uint32_t *px, size_t a, size_t b, size_t maxL) {   // a < b: compares px[a..] with px[b..]
    size_t l = 0;
    while (l < maxL && px[a + l] == px[b + l]) l++;
    return l;
}

/// Longest match for position i on the two chains. Returns the length (0 = none) and its distance.
static inline int mf_chain(const MF *m, size_t i, size_t maxL, int depth2, int depth4, int minLen, size_t *dist) {
    const uint32_t *px = m->px;
    uint32_t p = px[i];
    int bl = 0; size_t bd = 0;
    if (m->use4 && i + 3 < m->n && depth4 > 0) {
        int32_t cand = m->head4[mf_h4(m, i)]; int chain = depth4;
        while (cand >= 0 && chain > 0 && i - (size_t)cand <= WINDOW) {
            if (px[cand] == p && px[cand + 3] == px[i + 3] && (bl >= (int)maxL || px[cand + bl] == px[i + bl])) {
                size_t l = match_len_px(px, (size_t)cand, i, maxL);
                if ((int)l > bl) { bl = (int)l; bd = i - (size_t)cand; if (l >= 1024) break; }
            }
            cand = m->prev4[(size_t)cand & m->rmask]; chain--;
        }
    }
    if (depth2 > 0 && i + 1 < m->n) {
        int32_t cand = m->head[mf_h2(m, i)]; int chain = depth2;
        while (cand >= 0 && chain > 0 && i - (size_t)cand <= WINDOW) {
            if (px[cand] == p && (bl >= (int)maxL || px[cand + bl] == px[i + bl])) {
                size_t l = match_len_px(px, (size_t)cand, i, maxL);
                if ((int)l > bl) { bl = (int)l; bd = i - (size_t)cand; if (l >= 1024) break; }
            }
            cand = m->prev[(size_t)cand & m->rmask]; chain--;
        }
    }
    if (bl < minLen) return 0;
    *dist = bd;
    return bl;
}

// ---------------------------------------------------------------------------------------------------------------------
// Tokens

static int toks_push(Toks *T, uint32_t a, uint16_t len, uint16_t kind) {
    if (T->n == T->cap) {
        size_t nc = T->cap ? T->cap + T->cap / 2 : 4096;
        Tok *nt = (Tok *)realloc(T->t, nc * sizeof(Tok));
        if (!nt) return 0;
        T->t = nt; T->cap = nc;
    }
    T->t[T->n].a = a; T->t[T->n].len = len; T->t[T->n].kind = kind; T->n++;
    return 1;
}

/// Fast greedy parse (used for the first pass: statistics for the cost model, the cache size and the transform choice).
/// Literals have kind 0 (a = ARGB), copies kind 2 (a = distance code).
static int lz77_greedy(const uint32_t *px, int w, int h, int depth, Toks *T) {
    size_t n = (size_t)w * h;
    MF m;
    if (!mf_init(&m, px, w, h, 1)) return 0;
    T->n = 0;
    size_t i = 0;
    while (i < n) {
        uint32_t p = px[i];
        int bl = 0; size_t bd = 0;
        if (i + 1 < n) {
            size_t maxL = n - i; if (maxL > 4096) maxL = 4096;
            for (int k = 0; k < m.dm.ncdist; k++) {
                size_t d = (size_t)m.dm.cdist[k];
                if (d > i) continue;
                size_t c = i - d;
                if (px[c] != p) continue;
                if (bl > 0 && (size_t)bl < maxL && px[c + (size_t)bl] != px[i + (size_t)bl]) continue;
                size_t l = match_len_px(px, c, i, maxL);
                if ((int)l > bl) { bl = (int)l; bd = d; }
            }
            if (bl < 32) {
                size_t cd; int cl = mf_chain(&m, i, maxL, depth, depth, 3, &cd);
                if (cl > bl + 1) { bl = cl; bd = cd; }
            }
        }
        if (bl >= 3) {
            if (!toks_push(T, (uint32_t)dist_code(&m.dm, (int)bd), (uint16_t)bl, 2)) { mf_free(&m); return 0; }
            for (size_t j = i; j < i + (size_t)bl; j++) mf_insert(&m, j);
            i += (size_t)bl;
        } else {
            if (!toks_push(T, p, 0, 0)) { mf_free(&m); return 0; }
            mf_insert(&m, i);
            i++;
        }
    }
    mf_free(&m);
    return 1;
}

// ---------------------------------------------------------------------------------------------------------------------
// Cost-based LZ77 (optimal parse by dynamic programming over a bit-cost model)

#define CC_MAX 1024
typedef struct { float cg[256 + 24], cr[256], cb[256], ca[256], cd[40], cc[CC_MAX]; } CostModel;

static void model_costs(float *c, const uint32_t *h, int n, double extra) {
    double tot = extra + 1;
    for (int i = 0; i < n; i++) tot += h[i];
    for (int i = 0; i < n; i++) c[i] = (float)log2(tot / (h[i] + 0.5));
}

/// Cost model from the statistics of a token stream: literal channels, length prefixes, distance prefixes and (when
/// cacheBits > 0) colour-cache hits, simulated along the stream. Green, length prefixes and cache indices share one alphabet.
static int model_build(CostModel *M, const uint32_t *px, const Toks *T, int cacheBits) {
    uint32_t hr[256] = {0}, hb[256] = {0}, ha[256] = {0}, hd[40] = {0};
    uint32_t hg[256 + 24 + CC_MAX] = {0};
    uint32_t *cache = cacheBits ? (uint32_t *)calloc((size_t)1 << cacheBits, sizeof(uint32_t)) : NULL;
    if (cacheBits && !cache) return 0;
    size_t pos = 0;
    for (size_t k = 0; k < T->n; k++) {
        const Tok *t = &T->t[k];
        if (t->kind == 0 || t->kind == 1) {
            uint32_t p = px[pos];
            int hit = 0;
            if (cacheBits) {
                uint32_t key = (p * 0x1E35A7BDu) >> (32 - cacheBits);
                if (cache[key] == p) { hg[280 + key]++; hit = 1; } else cache[key] = p;
            }
            if (!hit) { ha[p >> 24]++; hr[(p >> 16) & 255]++; hg[(p >> 8) & 255]++; hb[p & 255]++; }
            pos++;
        } else {
            int s, nb, v; prefix_code(t->len, &s, &nb, &v); hg[256 + s]++; prefix_code((int)t->a, &s, &nb, &v); hd[s]++;
            if (cacheBits) for (size_t j = pos; j < pos + t->len; j++) cache[(px[j] * 0x1E35A7BDu) >> (32 - cacheBits)] = px[j];
            pos += t->len;
        }
    }
    free(cache);
    int na = 280 + (cacheBits ? 1 << cacheBits : 0);
    {
        double tot = 1;
        for (int i = 0; i < na; i++) tot += hg[i];
        for (int i = 0; i < 280; i++) M->cg[i] = (float)log2(tot / (hg[i] + 0.5));
        for (int i = 0; i < (cacheBits ? 1 << cacheBits : 0); i++) M->cc[i] = (float)log2(tot / (hg[280 + i] + 0.5));
    }
    model_costs(M->cr, hr, 256, 0); model_costs(M->cb, hb, 256, 0); model_costs(M->ca, ha, 256, 0); model_costs(M->cd, hd, 40, 0);
    return 1;
}


static void model_build_flat(CostModel *M, const uint32_t *px, size_t n) {
    uint32_t hr[256] = {0}, hg[256 + 24] = {0}, hb[256] = {0}, ha[256] = {0}, hd[40] = {0};
    for (size_t j = 0; j < n; j++) { uint32_t p = px[j]; ha[p >> 24]++; hr[(p >> 16) & 255]++; hg[(p >> 8) & 255]++; hb[p & 255]++; }
    for (int i = 0; i < 24; i++) hg[256 + i] = (uint32_t)(n / 400 + 1);
    for (int i = 0; i < 40; i++) hd[i] = (uint32_t)(n / 800 + 1);
    model_costs(M->cg, hg, 256 + 24, 0); model_costs(M->cr, hr, 256, 0); model_costs(M->cb, hb, 256, 0);
    model_costs(M->ca, ha, 256, 0); model_costs(M->cd, hd, 40, 0);
    for (int i = 0; i < CC_MAX; i++) M->cc[i] = 1e3f;
}


/// First-pass model: literal channel statistics are a blend of all pixels and of the pixels a greedy parse leaves as literals
/// (all-pixel statistics alone overrate literals, greedy-literal statistics alone are too skewed); copy costs from the greedy parse.
static int model_build_hybrid(CostModel *M, const uint32_t *px, int w, int h, double alpha) {
    size_t n = (size_t)w * h;
    Toks G = {0, 0, 0};
    if (!lz77_greedy(px, w, h, 2, &G)) { free(G.t); return 0; }
    uint32_t hr[256] = {0}, hg[256] = {0}, hb[256] = {0}, ha[256] = {0};
    uint32_t gr[256] = {0}, gg[256] = {0}, gb[256] = {0}, ga[256] = {0};
    uint32_t hd[40] = {0}, nl[24] = {0};
    for (size_t j = 0; j < n; j++) { uint32_t p = px[j]; ha[p >> 24]++; hr[(p >> 16) & 255]++; hg[(p >> 8) & 255]++; hb[p & 255]++; }
    size_t nlit = 0, pos = 0;
    for (size_t k = 0; k < G.n; k++) {
        const Tok *t = &G.t[k];
        if (t->kind == 0) { uint32_t p = px[pos]; ga[p >> 24]++; gr[(p >> 16) & 255]++; gg[(p >> 8) & 255]++; gb[p & 255]++; nlit++; pos++; }
        else { int s, nb, v; prefix_code(t->len, &s, &nb, &v); nl[s]++; prefix_code((int)t->a, &s, &nb, &v); hd[s]++; pos += t->len; }
    }
    free(G.t);
    uint32_t bg[256 + 24], br[256], bb[256], ba[256];
    double sa = alpha * 1e6 / (double)n, sg = nlit ? (1.0 - alpha) * 1e6 / (double)nlit : 0;
    for (int i = 0; i < 256; i++) {
        bg[i] = (uint32_t)(hg[i] * sa + gg[i] * sg); br[i] = (uint32_t)(hr[i] * sa + gr[i] * sg);
        bb[i] = (uint32_t)(hb[i] * sa + gb[i] * sg); ba[i] = (uint32_t)(ha[i] * sa + ga[i] * sg);
    }
    // scale the length-prefix counts to the same footing as the literal histogram (1e6 pixels' worth)
    double ratio = 1e6 / (double)n;
    for (int i = 0; i < 24; i++) bg[256 + i] = (uint32_t)(nl[i] * ratio) + 1;
    for (int i = 0; i < 40; i++) hd[i] = (uint32_t)(hd[i] * ratio) + 1;
    model_costs(M->cg, bg, 256 + 24, 0); model_costs(M->cr, br, 256, 0); model_costs(M->cb, bb, 256, 0);
    model_costs(M->ca, ba, 256, 0); model_costs(M->cd, hd, 40, 0);
    for (int i = 0; i < CC_MAX; i++) M->cc[i] = 1e3f;
    return 1;
}

#ifndef DP_DEPTH2
#define DP_DEPTH2 2
#endif
#ifndef DP_DEPTH4
#define DP_DEPTH4 0
#endif
#ifndef GREEDY_HI
#define GREEDY_HI 8
#endif
#ifndef GREEDY_LO
#define GREEDY_LO 4
#endif
#ifndef DP_ROUNDS
#define DP_ROUNDS 2
#endif
#ifndef MUL_HI
#define MUL_HI 1
#endif
#ifndef LMAXALL
#define LMAXALL 20
#endif
#define DPRING 8192

/// Optimal parse for the cost model M. `cacheBits` > 0 makes literal costs cache-aware: a pixel that the colour cache would
/// hold at that position (the cache content depends only on the position, never on the parse) costs its cache index.
static int lz77_dp(const uint32_t *px, int w, int h, int depthMul, int nneigh, const CostModel *M, int cacheBits, Toks *T) {
    size_t n = (size_t)w * h;
    MF mf;
    int depth2 = DP_DEPTH2 * depthMul, depth4 = DP_DEPTH4 * depthMul;
    if (!mf_init(&mf, px, w, h, depth4 > 0)) return 0;
    const DistMap *dm = &mf.dm;
    double *dp = (double *)malloc(sizeof(double) * DPRING);
    uint16_t *fl = (uint16_t *)calloc(n + 1, sizeof(uint16_t));
    uint32_t *fd = (uint32_t *)malloc(sizeof(uint32_t) * (n + 1));
    uint32_t *cache = cacheBits ? (uint32_t *)calloc((size_t)1 << cacheBits, sizeof(uint32_t)) : NULL;
    if (!dp || !fl || !fd || (cacheBits && !cache)) { free(dp); free(fl); free(fd); free(cache); mf_free(&mf); return 0; }
    for (int i = 0; i < DPRING; i++) dp[i] = 1e300;
    dp[0] = 0;
    size_t resetTo = 0;   // ring slots of positions <= resetTo are valid
    float lenCost[4097];
    for (int l = 1; l <= 4096; l++) { int s, nb, v; prefix_code(l, &s, &nb, &v); lenCost[l] = M->cg[256 + s] + (float)nb; }
    #define DPX(i) dp[(i) & (DPRING - 1)]
    #define LITCOST(q) (M->cg[((q) >> 8) & 255] + M->cr[((q) >> 16) & 255] + M->cb[(q) & 255] + M->ca[(q) >> 24])
    int prevLen = 0; size_t prevDist = 0;
    for (size_t i = 0; i < n; i++) {
        while (resetTo < i + 4096 && resetTo < n) { resetTo++; DPX(resetTo) = 1e300; }
        double base = DPX(i);
        uint32_t p = px[i];
        float lit = LITCOST(p);
        uint32_t ckey = 0;
        if (cacheBits) {
            ckey = (p * 0x1E35A7BDu) >> (32 - cacheBits);
            if (cache[ckey] == p && M->cc[ckey] < lit) lit = M->cc[ckey];
        }
        if (base + lit < DPX(i + 1)) { DPX(i + 1) = base + lit; fl[i + 1] = 0; }
        int bestLen = 0;
        if (i + 1 < n) {
            size_t maxL = n - i; if (maxL > 4096) maxL = 4096;
            int cl[3] = {0, 0, 0}; size_t cd[3] = {0, 0, 0}; int nc = 0;
            // cheap 2-D neighbours; the previous position's best match continues for free
            int nl = 0; size_t nd = 0;
            int cont = prevLen > 3 ? prevLen - 1 : 0;
            if (cont) { nl = cont; nd = prevDist; }
            for (int k = 0; k < nneigh && cont < 24; k++) {
                size_t d = (size_t)dm->cdist[k];
                if (d > i) continue;
                size_t c = i - d;
                if (px[c] != p) continue;
                if (nl > 0 && (size_t)nl < maxL && px[c + (size_t)nl] != px[i + (size_t)nl]) continue;   // cannot beat the current best
                size_t l = match_len_px(px, c, i, maxL);
                if ((int)l > nl) { nl = (int)l; nd = d; }
            }
            if (nl >= 3) { cl[nc] = nl; cd[nc] = nd; nc++; }
            size_t bd = 0;
            int bl = cont >= 24 ? 0 : mf_chain(&mf, i, maxL, depth2, depth4, 3, &bd);
            if (bl >= 3 && !(nc && bl == nl && bd == nd) && !(nc && bl <= nl)) { cl[nc] = bl; cd[nc] = bd; nc++; }
            for (int c = 0; c < nc; c++) {
                int L = cl[c]; int code = dist_code(dm, (int)cd[c]);
                int ds, dnb, dv; prefix_code(code, &ds, &dnb, &dv);
                float cc = (float)base + M->cd[ds] + (float)dnb;
                if (L > bestLen) { bestLen = L; prevDist = cd[c]; }
                // every length up to 40, then a sparse ladder (cost is flat inside a prefix-code bucket), always the full length
                static const int ladder[] = {48, 56, 64, 80, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096};
                int lmax40 = L < LMAXALL ? L : LMAXALL;
                for (int l = 3; l <= lmax40; l++) {
                    double v = cc + lenCost[l];
                    if (v < DPX(i + l)) { DPX(i + l) = v; fl[i + l] = (uint16_t)l; fd[i + l] = (uint32_t)code; }
                }
                for (int q = 0; q < 16 && ladder[q] < L; q++) {
                    int l = ladder[q]; double v = cc + lenCost[l];
                    if (v < DPX(i + l)) { DPX(i + l) = v; fl[i + l] = (uint16_t)l; fd[i + l] = (uint32_t)code; }
                }
                if (L > LMAXALL) {
                    double v = cc + lenCost[L];
                    if (v < DPX(i + L)) { DPX(i + L) = v; fl[i + L] = (uint16_t)L; fd[i + L] = (uint32_t)code; }
                }
            }
        }
        mf_insert(&mf, i);
        if (cacheBits) cache[ckey] = p;
        prevLen = bestLen;
        if (bestLen >= 128) {
            prevLen = 0;
            // long match: skip copy search inside it (literal transitions only), still index the pixels
            for (size_t j = i + 1; j < i + (size_t)bestLen && j < n; j++) {
                while (resetTo < j + 1 && resetTo < n) { resetTo++; DPX(resetTo) = 1e300; }
                mf_insert(&mf, j);
                uint32_t q = px[j];
                float lj = LITCOST(q);
                if (cacheBits) {
                    uint32_t k2 = (q * 0x1E35A7BDu) >> (32 - cacheBits);
                    if (cache[k2] == q && M->cc[k2] < lj) lj = M->cc[k2];
                    cache[k2] = q;
                }
                if (DPX(j) + lj < DPX(j + 1)) { DPX(j + 1) = DPX(j) + lj; fl[j + 1] = 0; }
            }
            i += (size_t)bestLen - 1;
        }
    }
    #undef DPX
    #undef LITCOST
    // backtrack
    size_t cnt = 0;
    for (size_t i = n; i > 0;) { i -= fl[i] ? fl[i] : 1; cnt++; }
    Tok *tk = (Tok *)malloc(cnt * sizeof(Tok));
    if (!tk) { free(dp); free(fl); free(fd); free(cache); mf_free(&mf); return 0; }
    size_t o = cnt;
    for (size_t i = n; i > 0;) {
        if (fl[i]) { o--; tk[o].a = fd[i]; tk[o].len = fl[i]; tk[o].kind = 2; i -= fl[i]; }
        else { o--; tk[o].a = px[i - 1]; tk[o].len = 0; tk[o].kind = 0; i--; }
    }
    free(T->t); T->t = tk; T->n = cnt; T->cap = cnt;
    free(dp); free(fl); free(fd); free(cache); mf_free(&mf);
    return 1;
}

// ---------------------------------------------------------------------------------------------------------------------
// Image entropy coding (with optional meta prefix codes)

static void emit_tokens(BW *bw, const Toks *T, const uint32_t *px, int w, int h, int hbits, const uint16_t *tileGroup, int tilesW,
                        uint32_t **codesG, uint32_t **codesR, uint32_t **codesB, uint32_t **codesA, uint32_t **codesD) {
    (void)h;
    int px_x = 0, px_y = 0;
    for (size_t k = 0; k < T->n; k++) {
        const Tok *t = &T->t[k];
        int grp = 0;
        if (tileGroup) grp = tileGroup[(px_y >> hbits) * tilesW + (px_x >> hbits)];
        const uint32_t *cg = codesG[grp];
        if (t->kind == 0) {
            uint32_t p = t->a;
            uint32_t c;
            c = cg[(p >> 8) & 255]; if (c >> 16) bw_put(bw, c & 0xFFFF, (int)(c >> 16));
            c = codesR[grp][(p >> 16) & 255]; if (c >> 16) bw_put(bw, c & 0xFFFF, (int)(c >> 16));
            c = codesB[grp][p & 255]; if (c >> 16) bw_put(bw, c & 0xFFFF, (int)(c >> 16));
            c = codesA[grp][p >> 24]; if (c >> 16) bw_put(bw, c & 0xFFFF, (int)(c >> 16));
            px_x++; if (px_x == w) { px_x = 0; px_y++; }
        } else if (t->kind == 1) {
            uint32_t c = cg[280 + t->a]; if (c >> 16) bw_put(bw, c & 0xFFFF, (int)(c >> 16));
            px_x++; if (px_x == w) { px_x = 0; px_y++; }
        } else {
            int s, nb, val;
            prefix_code(t->len, &s, &nb, &val);
            uint32_t c = cg[256 + s]; if (c >> 16) bw_put(bw, c & 0xFFFF, (int)(c >> 16));
            if (nb) bw_put(bw, (uint32_t)val, nb);
            prefix_code((int)t->a, &s, &nb, &val);
            c = codesD[grp][s]; if (c >> 16) bw_put(bw, c & 0xFFFF, (int)(c >> 16));
            if (nb) bw_put(bw, (uint32_t)val, nb);
            { long q = (long)px_x + t->len; px_y += (int)(q / w); px_x = (int)(q % w); }
        }
    }
    (void)px;
}


static int encode_argb(BW *bw, const uint32_t *px, int w, int h, int isMain, int depth, int quality, int passes);

#ifndef STAGEB_MAX
#define STAGEB_MAX 64
#endif
#ifndef TRIALS_PER_TILE
#define TRIALS_PER_TILE 20
#endif
#ifndef MAXFAILS
#define MAXFAILS 200
#endif
#define RNG_NEXT(st) ((st) ^= (st) << 13, (st) ^= (st) >> 17, (st) ^= (st) << 5, (st))

/// Cluster tile histograms; returns number of groups and fills tileGroup (per tile). `hist` = ntiles x histo_total.
static int cluster_histos(uint32_t *hist, int ntiles, int gAlpha, uint16_t *tileGroup, uint32_t **outHist, double maxMergeBits) {
    int tot = histo_total(gAlpha);
    int *owner = (int *)malloc(sizeof(int) * (size_t)ntiles);
    double *cost = (double *)malloc(sizeof(double) * (size_t)ntiles);
    int *alive = (int *)malloc(sizeof(int) * (size_t)ntiles);
    uint32_t *tmp = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)tot);
    uint64_t *pk = NULL; int *seq = NULL, *nx = NULL, *pv = NULL; double *dl = NULL;
    double *delta = NULL; int *idx = NULL; char *dead = NULL; int *remap = NULL; uint32_t *out = NULL;
    int nalive = 0;
    if (!owner || !cost || !alive || !tmp) goto fail;
    for (int i = 0; i < ntiles; i++) {
        owner[i] = i;
        cost[i] = histo_cost(hist + (size_t)i * tot, gAlpha);
        alive[nalive++] = i;
    }
    (void)maxMergeBits;
    // stages 1-3: agglomerate along three similarity orderings (dominant symbols, mean green, mean red/blue)
    for (int pass = 0; pass < 3; pass++) {
        if (nalive < 2) break;
        int K = nalive;
        pk = (uint64_t *)malloc(sizeof(uint64_t) * 2 * (size_t)K);
        if (!pk) goto fail;
        for (int q = 0; q < K; q++) {
            int c = alive[q];
            HistoView v = hv(hist + (size_t)c * tot, gAlpha);
            uint64_t key;
            if (pass == 0) {
                int dg = 0, dr = 0, db = 0, dl = 0;
                for (int k = 1; k < 256; k++) { if (v.g[k] > v.g[dg]) dg = k; if (v.r[k] > v.r[dr]) dr = k; if (v.b[k] > v.b[db]) db = k; }
                for (int k = 1; k < 24; k++) if (v.g[256 + k] > v.g[256 + dl]) dl = k;
                key = ((uint64_t)dg << 40) | ((uint64_t)dr << 32) | ((uint64_t)db << 24) | ((uint64_t)dl << 16);
            } else {
                double sg = 0, ng = 1e-9, sr = 0, nr = 1e-9, sb = 0, nb = 1e-9, nl = 0;
                for (int k = 0; k < 256; k++) { sg += (double)k * v.g[k]; ng += v.g[k]; sr += (double)k * v.r[k]; nr += v.r[k]; sb += (double)k * v.b[k]; nb += v.b[k]; }
                for (int k = 256; k < 280; k++) nl += v.g[k];
                uint64_t mg = (uint64_t)(sg / ng * 64), mr = (uint64_t)(sr / nr * 64), mb = (uint64_t)(sb / nb * 64);
                uint64_t frac = (uint64_t)(255.0 * nl / (ng + nl));
                key = pass == 1 ? ((mg & 0xFFFF) << 40) | ((frac & 0xFF) << 32) | ((mr & 0xFFFF) << 16) | (mb & 0xFFFF)
                                : ((frac & 0xFF) << 48) | ((mr & 0xFFFF) << 32) | ((mb & 0xFFFF) << 16) | (mg & 0xFFFF);
            }
            pk[2 * q] = key; pk[2 * q + 1] = (uint64_t)c;
        }
        qsort(pk, (size_t)K, 2 * sizeof(uint64_t), ll_cmp_pair);
        seq = (int *)malloc(sizeof(int) * (size_t)K); nx = (int *)malloc(sizeof(int) * (size_t)K); pv = (int *)malloc(sizeof(int) * (size_t)K);
        dl = (double *)malloc(sizeof(double) * (size_t)K);      // delta of merging position q with nx[q]
        if (!seq || !nx || !pv || !dl) goto fail;
        for (int q = 0; q < K; q++) { seq[q] = (int)pk[2 * q + 1]; nx[q] = q + 1 < K ? q + 1 : -1; pv[q] = q - 1; }
        free(pk); pk = NULL;
        #define PAIR_DELTA(q1, q2, outv) do {                                                         \
            uint32_t *h1 = hist + (size_t)seq[q1] * tot, *h2 = hist + (size_t)seq[q2] * tot;        \
            for (int k_ = 0; k_ < tot; k_++) tmp[k_] = h1[k_] + h2[k_];                              \
            (outv) = histo_cost(tmp, gAlpha) - cost[seq[q1]] - cost[seq[q2]];                         \
        } while (0)
        for (int q = 0; q < K; q++) { if (nx[q] >= 0) PAIR_DELTA(q, nx[q], dl[q]); else dl[q] = 1e30; }
        int live = K;
        for (;;) {
            double best = 0; int bq = -1;
            for (int q = 0; q < K; q = nx[q] >= 0 ? nx[q] : K) { /* walk live list from head 0 */
                if (dl[q] < best) { best = dl[q]; bq = q; }
                if (nx[q] < 0) break;
            }
            if (bq < 0) break;
            int a2 = bq, b2 = nx[bq];
            uint32_t *ha = hist + (size_t)seq[a2] * tot, *hb = hist + (size_t)seq[b2] * tot;
            for (int k = 0; k < tot; k++) ha[k] += hb[k];
            cost[seq[a2]] = histo_cost(ha, gAlpha);
            for (int i = 0; i < ntiles; i++) if (owner[i] == seq[b2]) owner[i] = seq[a2];
            nx[a2] = nx[b2];
            if (nx[b2] >= 0) pv[nx[b2]] = a2;
            live--;
            if (nx[a2] >= 0) PAIR_DELTA(a2, nx[a2], dl[a2]); else dl[a2] = 1e30;
            if (pv[a2] >= 0) PAIR_DELTA(pv[a2], a2, dl[pv[a2]]);
        }
        nalive = 0;
        for (int q = 0; q >= 0; q = nx[q]) { alive[nalive++] = seq[q]; if (nx[q] < 0) break; }
        free(seq); free(nx); free(pv); free(dl); seq = nx = pv = NULL; dl = NULL;
        (void)live;
    }
    // stage A: stochastic pair merging
    {
        uint32_t rng = 0x12345678u;
        int fails = 0, maxFails = MAXFAILS + nalive;
        long trials = 0, maxTrials = TRIALS_PER_TILE * (long)ntiles + 4000;
        while (nalive > 1 && fails < maxFails && trials < maxTrials) {
            trials++;
            int ia = (int)(RNG_NEXT(rng) % (uint32_t)nalive), ib = (int)(RNG_NEXT(rng) % (uint32_t)(nalive - 1));
            if (ib >= ia) ib++;
            int a = alive[ia], b = alive[ib];
            uint32_t *ha = hist + (size_t)a * tot, *hb = hist + (size_t)b * tot;
            for (int k = 0; k < tot; k++) tmp[k] = ha[k] + hb[k];
            double c = histo_cost(tmp, gAlpha);
            if (c < cost[a] + cost[b]) {
                memcpy(ha, tmp, sizeof(uint32_t) * (size_t)tot);
                cost[a] = c;
                for (int i = 0; i < ntiles; i++) if (owner[i] == b) owner[i] = a;
                alive[ib] = alive[nalive - 1]; nalive--;
                fails = 0;
            } else fails++;
        }
    }
    // stage B: exact greedy on what is left (bounded)
    if (nalive > 1 && nalive <= STAGEB_MAX) {
        int K = nalive;
        delta = (double *)malloc(sizeof(double) * (size_t)K * K);
        idx = (int *)malloc(sizeof(int) * (size_t)K);
        dead = (char *)calloc((size_t)K, 1);
        if (!delta || !idx || !dead) goto fail;
        for (int i = 0; i < K; i++) idx[i] = alive[i];
        int live = K;
        for (int i = 0; i < K; i++) for (int j = i + 1; j < K; j++) {
            uint32_t *ha = hist + (size_t)idx[i] * tot, *hb = hist + (size_t)idx[j] * tot;
            for (int k = 0; k < tot; k++) tmp[k] = ha[k] + hb[k];
            delta[i * K + j] = histo_cost(tmp, gAlpha) - cost[idx[i]] - cost[idx[j]];
        }
        while (live > 1) {
            double best = 0; int bi = -1, bj = -1;
            for (int i = 0; i < K; i++) if (!dead[i]) for (int j = i + 1; j < K; j++) if (!dead[j] && delta[i * K + j] < best) { best = delta[i * K + j]; bi = i; bj = j; }
            if (bi < 0) break;
            uint32_t *ha = hist + (size_t)idx[bi] * tot, *hb = hist + (size_t)idx[bj] * tot;
            for (int k = 0; k < tot; k++) ha[k] += hb[k];
            cost[idx[bi]] = histo_cost(ha, gAlpha);
            for (int i = 0; i < ntiles; i++) if (owner[i] == idx[bj]) owner[i] = idx[bi];
            dead[bj] = 1; live--;
            for (int j = 0; j < K; j++) if (!dead[j] && j != bi) {
                int lo = j < bi ? j : bi, hi = j < bi ? bi : j;
                uint32_t *hx = hist + (size_t)idx[lo] * tot, *hy = hist + (size_t)idx[hi] * tot;
                for (int k = 0; k < tot; k++) tmp[k] = hx[k] + hy[k];
                delta[lo * K + hi] = histo_cost(tmp, gAlpha) - cost[idx[lo]] - cost[idx[hi]];
            }
        }
        nalive = 0;
        for (int i = 0; i < K; i++) if (!dead[i]) alive[nalive++] = idx[i];
        free(delta); free(idx); free(dead); delta = NULL; idx = NULL; dead = NULL;
    }
    // renumber
    remap = (int *)malloc(sizeof(int) * (size_t)ntiles);
    if (!remap) goto fail;
    for (int i = 0; i < ntiles; i++) remap[i] = -1;
    for (int g = 0; g < nalive; g++) remap[alive[g]] = g;
    for (int i = 0; i < ntiles; i++) tileGroup[i] = (uint16_t)remap[owner[i]];
    out = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)tot * (size_t)nalive);
    if (!out) goto fail;
    for (int g = 0; g < nalive; g++) memcpy(out + (size_t)g * tot, hist + (size_t)alive[g] * tot, sizeof(uint32_t) * (size_t)tot);
    *outHist = out;
    free(owner); free(cost); free(alive); free(tmp); free(remap);
    return nalive;
fail:
    free(owner); free(cost); free(alive); free(tmp); free(pk); free(seq); free(nx); free(pv); free(dl);
    free(delta); free(idx); free(dead); free(remap); free(out);
    return 0;
}

static int encode_argb(BW *bw, const uint32_t *px, int w, int h, int isMain, int depth, int quality, int passes) {
    size_t n = (size_t)w * h;
    Toks T = {0, 0, 0};
    int cacheBits = 0;
    {
        int depthMul = depth >= 40 ? MUL_HI : 1;
        int nneigh = passes == 1 ? 8 : 16;      // palette images (one parse): fewer 2-D neighbour probes
        CostModel *M = (CostModel *)malloc(sizeof(CostModel));
        if (!M) return 0;
        // pass 1: optimal parse under the statistics of all pixels
        if (passes == 1 && n >= 64) { if (!model_build_hybrid(M, px, w, h, 0.3)) { free(M); return 0; } } else model_build_flat(M, px, n);
        if (!lz77_dp(px, w, h, depthMul, nneigh, M, 0, &T)) { free(M); free(T.t); return 0; }
        if (isMain && n >= 1024 && passes >= 2) {      // (palette index images: the colour cache cannot pay)
            double best = cache_cost(px, &T, 0);
            static const int tries[] = {10, 7};
            if (best < 0) { free(M); free(T.t); return 0; }
            for (int k = 0; k < 2; k++) {
                double c = cache_cost(px, &T, tries[k]);
                if (c < 0) { free(M); free(T.t); return 0; }
                if (c < best) { best = c; cacheBits = tries[k]; }
            }
        }
        if (n >= 64 && passes >= 2) {
            // pass 2: the statistics of pass 1 (and the colour cache, which the parse now knows about); keep the cheaper parse.
            double c1 = cache_cost(px, &T, cacheBits);
            if (c1 < 0 || !model_build(M, px, &T, cacheBits)) { free(M); free(T.t); return 0; }
            free(T.t); T.t = NULL; T.n = T.cap = 0;        // one token array at a time
            Toks T2 = {0, 0, 0};
            int ok2 = lz77_dp(px, w, h, depthMul, nneigh, M, cacheBits, &T2);
            double c2 = ok2 ? cache_cost(px, &T2, cacheBits) : -1;
            // (within 0.5% counts as equal: redoing pass 1 would cost a whole extra parse for nothing)
            if (ok2 && c2 >= 0 && c2 <= c1 * 1.005) T = T2;
            else {
                free(T2.t);
                model_build_flat(M, px, n);
                if (!lz77_dp(px, w, h, depthMul, nneigh, M, 0, &T)) { free(M); free(T.t); return 0; }
            }
        }
        free(M);
    }
    if (cacheBits) { if (!apply_cache(px, &T, cacheBits)) { free(T.t); return 0; } bw_put(bw, 1, 1); bw_put(bw, (uint32_t)cacheBits, 4); } else bw_put(bw, 0, 1);
    int gAlpha = 280 + (cacheBits ? 1 << cacheBits : 0);
    int tot = histo_total(gAlpha);
    int hbits = 0, tilesW = 0, tilesH = 0, ngroups = 1;
    uint16_t *tileGroup = NULL;
    uint32_t *ghist = NULL;
    uint32_t **cG = NULL;
    int ok = 0, nCodes = 0;
    if (isMain) {
        int useMeta = n >= 4096 && quality >= 25;
        if (useMeta) {
            hbits = quality >= 90 ? 3 : (quality >= 50 ? 4 : 5);
            for (;;) {
                tilesW = (w + (1 << hbits) - 1) >> hbits; tilesH = (h + (1 << hbits) - 1) >> hbits;
                if ((long)tilesW * tilesH <= 2600) break;
                hbits++;
            }
            // few tokens (flat / palette images): fewer, larger tiles so each tile has enough statistics to cluster
            while (hbits < 9 && (long)tilesW * tilesH > 4 && (long)tilesW * tilesH * 24 > (long)T.n) {
                hbits++;
                tilesW = (w + (1 << hbits) - 1) >> hbits; tilesH = (h + (1 << hbits) - 1) >> hbits;
            }
            if (hbits > 9) hbits = 9;
            tilesW = (w + (1 << hbits) - 1) >> hbits; tilesH = (h + (1 << hbits) - 1) >> hbits;
            int ntiles = tilesW * tilesH;
            uint32_t *th = (uint32_t *)calloc((size_t)tot * (size_t)ntiles, sizeof(uint32_t));
            tileGroup = (uint16_t *)malloc(sizeof(uint16_t) * (size_t)ntiles);
            if (!th || !tileGroup) { free(th); goto done; }
            size_t pos = 0;
            for (size_t k = 0; k < T.n; k++) {
                int x = (int)(pos % (size_t)w), y = (int)(pos / (size_t)w);
                int tile = (y >> hbits) * tilesW + (x >> hbits);
                histo_add_tok(hv(th + (size_t)tile * tot, gAlpha), &T.t[k]);
                pos += T.t[k].kind == 2 ? T.t[k].len : 1;
            }
            ngroups = cluster_histos(th, ntiles, gAlpha, tileGroup, &ghist, 0);
            free(th);
            if (ngroups == 0) goto done;
            if (ngroups > 1) {
                // is the meta image worth its cost? compare with a single group
                double clustered = 0;
                uint32_t *one = (uint32_t *)calloc((size_t)tot, sizeof(uint32_t));
                if (!one) goto done;
                for (int g = 0; g < ngroups; g++) {
                    const uint32_t *gh = ghist + (size_t)g * tot;
                    clustered += histo_cost((uint32_t *)gh, gAlpha);
                    for (int k = 0; k < tot; k++) one[k] += gh[k];
                }
                clustered += (double)ntiles * (log2((double)ngroups) + 1.5) + 40.0;
                double single = histo_cost(one, gAlpha);
                free(one);
                if (single <= clustered) ngroups = 1;
            }
        }
        if (ngroups > 1) {
            bw_put(bw, 1, 1); bw_put(bw, (uint32_t)(hbits - 2), 3);
            uint32_t *eimg = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)tilesW * (size_t)tilesH);
            if (!eimg) goto done;
            for (int i = 0; i < tilesW * tilesH; i++) eimg[i] = 0xFF000000u | (uint32_t)tileGroup[i] << 8;
            int okm = encode_argb(bw, eimg, tilesW, tilesH, 0, 16, quality, 2);
            free(eimg);
            if (!okm) goto done;
        } else bw_put(bw, 0, 1);
    }
    if (ngroups == 1) {
        free(ghist); ghist = (uint32_t *)calloc((size_t)tot, sizeof(uint32_t));
        if (!ghist) goto done;
        HistoView v = hv(ghist, gAlpha);
        for (size_t k = 0; k < T.n; k++) histo_add_tok(v, &T.t[k]);
        free(tileGroup); tileGroup = NULL;
    }
    cG = (uint32_t **)calloc(5 * (size_t)ngroups, sizeof(uint32_t *));
    if (!cG) goto done;
    {
        uint32_t **cR = cG + ngroups, **cB = cR + ngroups, **cA = cB + ngroups, **cD = cA + ngroups;
        for (int g = 0; g < ngroups; g++) {
            HistoView v = hv(ghist + (size_t)g * tot, gAlpha);
            cG[g] = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)(gAlpha + 256 * 3 + 40));
            if (!cG[g]) { nCodes = g; goto done; }
            cR[g] = cG[g] + gAlpha; cB[g] = cR[g] + 256; cA[g] = cB[g] + 256; cD[g] = cA[g] + 256;
            write_code(bw, v.g, gAlpha, cG[g]);
            write_code(bw, v.r, 256, cR[g]);
            write_code(bw, v.b, 256, cB[g]);
            write_code(bw, v.a, 256, cA[g]);
            write_code(bw, v.d, 40, cD[g]);
        }
        nCodes = ngroups;
        emit_tokens(bw, &T, px, w, h, hbits, tileGroup, tilesW, cG, cR, cB, cA, cD);
    }
    ok = !bw->oom;
done:
    if (cG) for (int g = 0; g < nCodes; g++) free(cG[g]);
    free(cG); free(ghist); free(tileGroup); free(T.t);
    return ok;
}

// ---------------------------------------------------------------------------------------------------------------------
// Transforms

static inline uint32_t avg2(uint32_t a, uint32_t b) { return (((a ^ b) & 0xFEFEFEFEu) >> 1) + (a & b); }
static inline int chan(uint32_t p, int s) { return (int)((p >> s) & 255); }
static inline uint32_t clampc(int v) { return (uint32_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); }

static inline uint32_t predict(int mode, uint32_t L, uint32_t T, uint32_t TR, uint32_t TL) {
    switch (mode) {
    case 1: return L;
    case 2: return T;
    case 3: return TR;
    case 4: return TL;
    case 5: return avg2(avg2(L, TR), T);
    case 6: return avg2(L, TL);
    case 7: return avg2(L, T);
    case 8: return avg2(TL, T);
    case 9: return avg2(T, TR);
    case 10: return avg2(avg2(L, TL), avg2(T, TR));
    case 11: {
        int pl = 0, pt = 0;
        for (int s = 0; s < 32; s += 8) {
            int est = chan(L, s) + chan(T, s) - chan(TL, s);
            pl += abs(est - chan(L, s)); pt += abs(est - chan(T, s));
        }
        return pl < pt ? L : T;
    }
    case 12: {
        uint32_t o = 0;
        for (int s = 0; s < 32; s += 8) o |= clampc(chan(L, s) + chan(T, s) - chan(TL, s)) << s;
        return o;
    }
    case 13: {
        uint32_t a = avg2(L, T), o = 0;
        for (int s = 0; s < 32; s += 8) { int x = chan(a, s), y = chan(TL, s); o |= clampc(x + (x - y) / 2) << s; }
        return o;
    }
    default: return 0xFF000000u;
    }
}

static inline uint32_t sub_px(uint32_t a, uint32_t b) {
    uint32_t ag = ((((a >> 8) & 0x00FF00FFu) | 0x01000100u) - ((b >> 8) & 0x00FF00FFu)) & 0x00FF00FFu;
    uint32_t rb = (((a & 0x00FF00FFu) | 0x01000100u) - (b & 0x00FF00FFu)) & 0x00FF00FFu;
    return (ag << 8) | rb;
}

static inline uint32_t neighbour_pred(int mode, const uint32_t *s, int w, int x, int y) {
    uint32_t L = s[y * w + x - 1], T = s[(y - 1) * w + x], TL = s[(y - 1) * w + x - 1];
    uint32_t TR = x + 1 < w ? s[(y - 1) * w + x + 1] : s[y * w];
    return predict(mode, L, T, TR, TL);
}

/// Residuals of one tile for predictor mode M (constant after inlining).
static inline __attribute__((always_inline)) void tile_residuals(int M, const uint32_t *s, int w, int x0, int x1, int y0, int y1, uint32_t *out) {
    int k = 0;
    for (int y = y0; y < y1; y++) {
        const uint32_t *row = s + (size_t)y * w, *up = row - w;
        for (int x = x0; x < x1; x++) {
            uint32_t L = row[x - 1], T = up[x], TL = up[x - 1];
            uint32_t TR = x + 1 < w ? up[x + 1] : row[0];
            out[k++] = sub_px(row[x], predict(M, L, T, TR, TL));
        }
    }
}

/// Choose per-tile predictor modes and compute residuals. modes: tw*th bytes. res: w*h.
/// A tile's cost for a mode is the increase of the image-wide residual entropy (the tile's histogram added to the histograms
/// of the tiles already chosen), so noisy tiles pick "no prediction" and structured ones pick a real predictor.
static int predictor_transform(const uint32_t *s, uint32_t *res, int w, int h, int tb, uint8_t *modes, int quality) {
    int tile = 1 << tb, tw = (w + tile - 1) >> tb, th = (h + tile - 1) >> tb;
    static const int allModes[13] = {11, 12, 13, 2, 1, 7, 5, 10, 4, 3, 6, 8, 9};
    int nm = quality >= 90 ? 13 : (quality >= 50 ? 10 : 6);
    uint32_t *acc = (uint32_t *)calloc(4 * 256, sizeof(uint32_t)), *tmp = (uint32_t *)calloc(4 * 256, sizeof(uint32_t));
    uint64_t accN[4] = {0, 0, 0, 0};
    uint16_t *touched = (uint16_t *)malloc(sizeof(uint16_t) * 4 * (size_t)tile * tile);
    uint32_t *tileRes = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)tile * tile);
    uint32_t *bestRes = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)tile * tile);
    if (!acc || !tmp || !touched || !tileRes || !bestRes) { free(acc); free(tmp); free(touched); free(tileRes); free(bestRes); return 0; }
    for (int ty = 0; ty < th; ty++) for (int tx = 0; tx < tw; tx++) {
        int y0 = ty * tile < 1 ? 1 : ty * tile, y1 = (ty + 1) * tile < h ? (ty + 1) * tile : h;
        int x0 = tx * tile < 1 ? 1 : tx * tile, x1 = (tx + 1) * tile < w ? (tx + 1) * tile : w;
        int npx = (y1 - y0 > 0 && x1 - x0 > 0) ? (y1 - y0) * (x1 - x0) : 0;
        if (npx == 0) { modes[ty * tw + tx] = 1; continue; }
        double best = 1e300; int bm = 1;
        for (int mi = -1; mi < nm; mi++) {          // mode 0 (no prediction) first: best on noise
            int m = mi < 0 ? 0 : allModes[mi];
            switch (m) {   // one specialised loop per mode: the predictor expression is a compile-time constant in each
#define TILE_MODE(M) case M: tile_residuals(M, s, w, x0, x1, y0, y1, tileRes); break;
            TILE_MODE(0) TILE_MODE(1) TILE_MODE(2) TILE_MODE(3) TILE_MODE(4) TILE_MODE(5) TILE_MODE(6) TILE_MODE(7)
            TILE_MODE(8) TILE_MODE(9) TILE_MODE(10) TILE_MODE(11) TILE_MODE(12) TILE_MODE(13)
#undef TILE_MODE
            default: break;
            }
            int nt = 0;
            for (int q = 0; q < npx; q++) {
                uint32_t r = tileRes[q];
                int v[4] = {(int)(r >> 24), (int)((r >> 16) & 255), (int)((r >> 8) & 255), (int)(r & 255)};
                for (int c = 0; c < 4; c++) { if (tmp[c * 256 + v[c]]++ == 0) touched[nt++] = (uint16_t)(c * 256 + v[c]); }
            }
            double cost = 0;
            for (int c = 0; c < 4; c++) cost += nlogn((uint32_t)(accN[c] + npx)) - nlogn((uint32_t)accN[c]);
            for (int q = 0; q < nt; q++) {
                int idx = touched[q];
                cost -= nlogn(acc[idx] + tmp[idx]) - nlogn(acc[idx]);
            }
            // (cost above = bits of the tile under the enlarged global histogram, up to the constant tile term)
            for (int q = 0; q < nt; q++) tmp[touched[q]] = 0;
            if (cost < best) { best = cost; bm = m; memcpy(bestRes, tileRes, sizeof(uint32_t) * (size_t)npx); }
        }
        modes[ty * tw + tx] = (uint8_t)bm;
        for (int q = 0; q < npx; q++) {
            uint32_t r = bestRes[q];
            acc[r >> 24]++; acc[256 + ((r >> 16) & 255)]++; acc[512 + ((r >> 8) & 255)]++; acc[768 + (r & 255)]++;
        }
        for (int c = 0; c < 4; c++) accN[c] += (uint64_t)npx;
    }
    free(acc); free(tmp); free(touched); free(tileRes); free(bestRes);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        uint32_t pred;
        if (y == 0) pred = x == 0 ? 0xFF000000u : s[x - 1];
        else if (x == 0) pred = s[(y - 1) * w];
        else pred = neighbour_pred(modes[(y >> tb) * tw + (x >> tb)], s, w, x, y);
        res[y * w + x] = sub_px(s[y * w + x], pred);
    }
    return 1;
}

static inline int cdelta(int t, int c) { return ((int8_t)t * (int8_t)c) >> 5; }

/// Per-tile cross-colour multipliers chosen on the predictor residuals; applies the transform in place. params: tw*th ARGB pixels.
#define SY 2
static void cross_color_transform(uint32_t *px, int w, int h, int tb, uint32_t *params) {
    int tile = 1 << tb, tw = (w + tile - 1) >> tb, th = (h + tile - 1) >> tb;
    for (int ty = 0; ty < th; ty++) for (int tx = 0; tx < tw; tx++) {
        int y0 = ty * tile, y1 = y0 + tile < h ? y0 + tile : h, x0 = tx * tile, x1 = x0 + tile < w ? x0 + tile : w;
        // histogram entropy of the tile channel after applying delta
        int bestG2R = 0, bestG2B = 0, bestR2B = 0;
        double bestC;
        uint32_t hist[256];
        #define ENTROPY_OF(EXPR, OUT) do {                                                          \
            memset(hist, 0, sizeof(hist));                                                          \
            for (int y = y0; y < y1; y += SY) for (int x = x0; x < x1; x += SY) {                   \
                uint32_t p = px[y * w + x]; int g = (int8_t)((p >> 8) & 255), r = (int8_t)((p >> 16) & 255); (void)g; (void)r; \
                int b_ = (int)(p & 255); (void)b_; int r_ = (int)((p >> 16) & 255); (void)r_;       \
                hist[(EXPR) & 255]++;                                                               \
            }                                                                                       \
            uint32_t N = 0; for (int i = 0; i < 256; i++) N += hist[i]; double s_ = 0;                          \
            for (int i = 0; i < 256; i++) if (hist[i]) s_ += nlogn(hist[i]);                        \
            (OUT) = nlogn(N) - s_;                                                                  \
        } while (0)
        // green -> red
        {
            double c0;
            ENTROPY_OF(r_ - 0, c0);
            bestC = c0;
            for (int t = -32; t <= 31; t += 8) {
                if (t == 0) continue;
                double c;
                ENTROPY_OF(r_ - cdelta(t, g), c);
                if (c < bestC - 2.0) { bestC = c; bestG2R = t; }
            }
            if (bestG2R) for (int t = bestG2R - 3; t <= bestG2R + 3; t++) {
                if (t == bestG2R || t < -128 || t > 127) continue;
                double c;
                ENTROPY_OF(r_ - cdelta(t, g), c);
                if (c < bestC) { bestC = c; bestG2R = t; }
            }
        }
        // green -> blue, then red -> blue
        {
            ENTROPY_OF(b_ - 0, bestC);
            for (int t = -32; t <= 31; t += 8) {
                if (t == 0) continue;
                double c;
                ENTROPY_OF(b_ - cdelta(t, g), c);
                if (c < bestC - 2.0) { bestC = c; bestG2B = t; }
            }
            if (bestG2B) for (int t = bestG2B - 3; t <= bestG2B + 3; t++) {
                if (t == bestG2B || t < -128 || t > 127) continue;
                double c;
                ENTROPY_OF(b_ - cdelta(t, g), c);
                if (c < bestC) { bestC = c; bestG2B = t; }
            }
            for (int t = -32; t <= 31; t += 8) {
                if (t == 0) continue;
                double c;
                ENTROPY_OF(b_ - cdelta(bestG2B, g) - cdelta(t, r), c);
                if (c < bestC - 2.0) { bestC = c; bestR2B = t; }
            }
            if (bestR2B) for (int t = bestR2B - 3; t <= bestR2B + 3; t++) {
                if (t == bestR2B || t < -128 || t > 127) continue;
                double c;
                ENTROPY_OF(b_ - cdelta(bestG2B, g) - cdelta(t, r), c);
                if (c < bestC) { bestC = c; bestR2B = t; }
            }
        }
        params[ty * tw + tx] = 0xFF000000u | (uint32_t)(bestR2B & 255) << 16 | (uint32_t)(bestG2B & 255) << 8 | (uint32_t)(bestG2R & 255);
        for (int y = y0; y < y1; y++) for (int x = x0; x < x1; x++) {
            uint32_t p = px[y * w + x];
            int g = (int8_t)((p >> 8) & 255), r = (int8_t)((p >> 16) & 255);
            int nr = (int)((p >> 16) & 255) - cdelta(bestG2R, g);
            int nb = (int)(p & 255) - cdelta(bestG2B, g) - cdelta(bestR2B, r);
            px[y * w + x] = (p & 0xFF00FF00u) | (uint32_t)(nr & 255) << 16 | (uint32_t)(nb & 255);
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Orchestration

static void write_header(BW *bw, int w, int h, int hasAlpha) {
    bw_put(bw, 0x2F, 8);
    bw_put(bw, (uint32_t)(w - 1), 14); bw_put(bw, (uint32_t)(h - 1), 14);
    bw_put(bw, hasAlpha ? 1 : 0, 1); bw_put(bw, 0, 3);
}

/// Zero-order entropy estimate (bits) of the four channels of `px` over sampled rows.
static double channel_entropy(const uint32_t *px, int w, int h, int sg, int pred) {
    uint32_t hist[4][256];
    memset(hist, 0, sizeof(hist));
    size_t cnt = 0;
    for (int y = pred ? 2 : 0; y < h; y += 2) {
        for (int x = pred ? 1 : 0; x < w; x++) {
            uint32_t p = px[(size_t)y * w + x];
            if (sg) { uint32_t g = (p >> 8) & 255; p = (p & 0xFF00FF00u) | (((p >> 16) - g) & 255) << 16 | ((p - g) & 255); }
            if (pred) {
                uint32_t L = px[(size_t)y * w + x - 1], T = px[(size_t)(y - 1) * w + x], TL = px[(size_t)(y - 1) * w + x - 1];
                if (sg) {
                    uint32_t gl = (L >> 8) & 255, gt = (T >> 8) & 255, gtl = (TL >> 8) & 255;
                    L = (L & 0xFF00FF00u) | (((L >> 16) - gl) & 255) << 16 | ((L - gl) & 255);
                    T = (T & 0xFF00FF00u) | (((T >> 16) - gt) & 255) << 16 | ((T - gt) & 255);
                    TL = (TL & 0xFF00FF00u) | (((TL >> 16) - gtl) & 255) << 16 | ((TL - gtl) & 255);
                }
                p = sub_px(p, predict(12, L, T, T, TL));
            }
            hist[0][p >> 24]++; hist[1][(p >> 16) & 255]++; hist[2][(p >> 8) & 255]++; hist[3][p & 255]++;
            cnt++;
        }
    }
    double bits = 0;
    for (int c = 0; c < 4; c++) {
        double s = 0; uint32_t N = 0;
        for (int i = 0; i < 256; i++) if (hist[c][i]) { s += nlogn(hist[c][i]); N += hist[c][i]; }
        bits += nlogn(N) - s;
    }
    (void)cnt;
    return bits;
}


/// Transform choice by the zero-order entropy of the four configurations (fast; wrong for text and graphics, see sr_vp8l_encode).
static void general_pick(const uint32_t *argb, int w, int h, int *useSG, int *usePred) {
    double eNone = channel_entropy(argb, w, h, 0, 0), eSg = channel_entropy(argb, w, h, 1, 0);
    *useSG = 0; *usePred = 0;
    if (w >= 2 && h >= 3) {
        double ePr = channel_entropy(argb, w, h, 0, 1), ePs = channel_entropy(argb, w, h, 1, 1);
        double best = eNone;
        if (eSg < best) { best = eSg; *useSG = 1; *usePred = 0; }
        if (ePr < best) { best = ePr; *useSG = 0; *usePred = 1; }
        if (ePs < best) { best = ePs; *useSG = 1; *usePred = 1; }
    } else if (eSg < eNone) *useSG = 1;
}

/// General path: optional subtract green, optional per-tile predictor with cross colour. `cfg` < 0 picks the transforms by the
/// zero-order entropy of the four configurations; otherwise bit 0 = subtract green, bit 1 = predictor + cross colour.
static int encode_general(BW *bw, const uint32_t *argb, int w, int h, int hasAlpha, int quality, int cfg) {
    size_t n = (size_t)w * h;
    int useSG = 0, usePred = 0;
    if (cfg >= 0) { useSG = cfg & 1; usePred = (cfg >> 1) & 1; if (w < 2 || h < 3) usePred = 0; }
    else {
        general_pick(argb, w, h, &useSG, &usePred);
    }
    // the working image: the input itself unless subtract green has to rewrite it (no extra copy for the other cases)
    const uint32_t *s = argb;
    uint32_t *sg = NULL;
    if (useSG) {
        sg = (uint32_t *)malloc(sizeof(uint32_t) * n);
        if (!sg) return 0;
        for (size_t i = 0; i < n; i++) {
            uint32_t p = argb[i], g = (p >> 8) & 255;
            sg[i] = (p & 0xFF00FF00u) | (((p >> 16) - g) & 255) << 16 | ((p - g) & 255);
        }
        s = sg;
    }
    write_header(bw, w, h, hasAlpha);
    if (useSG) { bw_put(bw, 1, 1); bw_put(bw, 2, 2); }          // subtract green
    const uint32_t *res = s;
    uint32_t *resOwn = NULL;
    int ok = 1;
    if (usePred) {
        resOwn = (uint32_t *)malloc(sizeof(uint32_t) * n);
        if (!resOwn) { free(sg); return 0; }
        int pb = 3;
        while ((long)((w + (1 << pb) - 1) >> pb) * ((h + (1 << pb) - 1) >> pb) > 16384L) pb++;
        int tw = (w + (1 << pb) - 1) >> pb, th = (h + (1 << pb) - 1) >> pb;
        uint8_t *modes = (uint8_t *)malloc((size_t)tw * th);
        uint32_t *mimg = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)tw * th);
        if (!modes || !mimg) { free(modes); free(mimg); free(resOwn); free(sg); return 0; }
        if (!predictor_transform(s, resOwn, w, h, pb, modes, quality)) { free(modes); free(mimg); free(resOwn); free(sg); return 0; }
        free(sg); sg = NULL; s = NULL;
        for (int i = 0; i < tw * th; i++) mimg[i] = 0xFF000000u | (uint32_t)modes[i] << 8;
        bw_put(bw, 1, 1); bw_put(bw, 0, 2); bw_put(bw, (uint32_t)(pb - 2), 3);
        ok = encode_argb(bw, mimg, tw, th, 0, 16, quality, 2);
        free(mimg); free(modes);
        if (!ok) { free(resOwn); return 0; }
        // cross colour on the residuals
        int cb = 5;
        while ((long)((w + (1 << cb) - 1) >> cb) * ((h + (1 << cb) - 1) >> cb) > 4096L) cb++;
        int cw = (w + (1 << cb) - 1) >> cb, ch = (h + (1 << cb) - 1) >> cb;
        uint32_t *cimg = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)cw * ch);
        if (!cimg) { free(resOwn); return 0; }
        cross_color_transform(resOwn, w, h, cb, cimg);
        bw_put(bw, 1, 1); bw_put(bw, 1, 2); bw_put(bw, (uint32_t)(cb - 2), 3);
        ok = encode_argb(bw, cimg, cw, ch, 0, 16, quality, 2);
        free(cimg);
        if (!ok) { free(resOwn); return 0; }
        res = resOwn;
    }
    bw_put(bw, 0, 1);                                  // no more transforms
    int depth = quality >= 90 ? 96 : (quality >= 50 ? 40 : 10);
    ok = encode_argb(bw, res, w, h, 1, depth, quality, 2);
    free(resOwn); free(sg);
    return ok;
}

/// Palette path (<= 256 colours): colour indexing with pixel bundling.
static int encode_palette(BW *bw, const uint32_t *argb, int w, int h, int hasAlpha, int quality, const uint32_t *pal, int np, int usePred) {
    // index lookup via sorted palette + binary search
    int wb = np > 16 ? 0 : (np > 4 ? 1 : (np > 2 ? 2 : 3));
    int bitsPer = 8 >> wb, pw = (w + (1 << wb) - 1) >> wb;
    uint32_t *packed = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)pw * h);
    if (!packed) return 0;
    for (size_t i = 0; i < (size_t)pw * h; i++) packed[i] = 0xFF000000u;
    uint32_t sorted[256]; int sidx[256];
    {
        int order[256];
        for (int i = 0; i < np; i++) order[i] = i;
        for (int i = 1; i < np; i++) { int k = order[i], j = i - 1; while (j >= 0 && pal[order[j]] > pal[k]) { order[j + 1] = order[j]; j--; } order[j + 1] = k; }
        for (int i = 0; i < np; i++) { sorted[i] = pal[order[i]]; sidx[i] = order[i]; }
    }
    uint32_t last = 0; int lastIdx = 0, have = 0;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        uint32_t c = argb[(size_t)y * w + x];
        int idx;
        if (have && c == last) idx = lastIdx;
        else {
            int lo = 0, hi = np - 1;
            while (lo < hi) { int mid = (lo + hi) >> 1; if (sorted[mid] < c) lo = mid + 1; else hi = mid; }
            idx = sidx[lo]; last = c; lastIdx = idx; have = 1;
        }
        packed[(size_t)y * pw + (x >> wb)] |= (uint32_t)idx << (8 + (x & ((1 << wb) - 1)) * bitsPer);
    }
    write_header(bw, w, h, hasAlpha);
    bw_put(bw, 1, 1); bw_put(bw, 3, 2);
    bw_put(bw, (uint32_t)(np - 1), 8);
    uint32_t delta[256];
    delta[0] = pal[0];
    for (int i = 1; i < np; i++) delta[i] = sub_px(pal[i], pal[i - 1]);
    int ok = encode_argb(bw, delta, np, 1, 0, 8, quality, 2);
    if (!ok) { free(packed); return 0; }
    uint32_t *main = packed;
    if (usePred) {
        int pb = 3;
        while ((long)((pw + (1 << pb) - 1) >> pb) * ((h + (1 << pb) - 1) >> pb) > 4096) pb++;
        int tw = (pw + (1 << pb) - 1) >> pb, th = (h + (1 << pb) - 1) >> pb;
        uint8_t *modes = (uint8_t *)malloc((size_t)tw * th);
        uint32_t *res = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)pw * h);
        uint32_t *mimg = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)tw * th);
        if (!modes || !res || !mimg || !predictor_transform(packed, res, pw, h, pb, modes, quality)) { free(modes); free(res); free(mimg); free(packed); return 0; }
        for (int i = 0; i < tw * th; i++) mimg[i] = 0xFF000000u | (uint32_t)modes[i] << 8;
        bw_put(bw, 1, 1); bw_put(bw, 0, 2); bw_put(bw, (uint32_t)(pb - 2), 3);
        ok = encode_argb(bw, mimg, tw, th, 0, 16, quality, 2);
        free(mimg); free(modes);
        if (!ok) { free(res); free(packed); return 0; }
        free(packed);
        main = res; packed = res;
    }
    bw_put(bw, 0, 1);
    ok = encode_argb(bw, main, pw, h, 1, quality >= 50 ? 64 : 16, quality, pw * h > 32768 ? 1 : 2);   // one parse for real-sized palette images: they must be fast
    free(packed);
    return ok;
}

static int distinct_colors(const uint32_t *argb, size_t n, uint32_t *pal) {
    uint32_t tab[1024]; uint8_t used[1024];
    memset(used, 0, sizeof(used));
    int np = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t c = argb[i];
        unsigned hsh = (c * 2654435761u) >> 22;
        for (;;) {
            if (!used[hsh]) { if (np == 256) return 257; used[hsh] = 1; tab[hsh] = c; pal[np++] = c; break; }
            if (tab[hsh] == c) break;
            hsh = (hsh + 1) & 1023;
        }
    }
    return np;
}

// ---------------------------------------------------------------------------------------------------------------------
// Choosing what to encode: real encoded sizes (of the whole image when it is small, of a sample of horizontal bands otherwise)

#define TRIAL_FULL 32768          // up to this many pixels every candidate is encoded in full and the smallest output is kept
#define TRIAL_SAMPLE 65536       // larger images: candidates are compared on about this many pixels

/// Bands of 16 rows spread over the image, copied into one contiguous image (NULL = use the whole image / out of memory).
static uint32_t *make_sample(const uint32_t *argb, int w, int h, size_t maxPx, int *sh) {
    const int B = 16;
    long bands = (long)(maxPx / ((size_t)w * B));
    if (bands < 1) bands = 1;
    if ((long)h <= bands * B * 2) return NULL;
    uint32_t *sp = (uint32_t *)malloc(sizeof(uint32_t) * (size_t)w * (size_t)(bands * B));
    if (!sp) return NULL;
    for (long b = 0; b < bands; b++) {
        long y0 = bands > 1 ? (long)(((long long)(h - B) * b) / (bands - 1)) : (h - B) / 2;
        memcpy(sp + (size_t)b * B * w, argb + (size_t)y0 * w, sizeof(uint32_t) * (size_t)w * B);
    }
    *sh = (int)(bands * B);
    return sp;
}

/// Fraction of the pixels that a greedy parse covers with copies of at least 8 pixels (graphics and text: high; photos: ~0).
static double copy_coverage(const uint32_t *px, int w, int h) {
    Toks T = {0, 0, 0};
    if (!lz77_greedy(px, w, h, 4, &T)) { free(T.t); return 0; }
    size_t cov = 0;
    for (size_t k = 0; k < T.n; k++) if (T.t[k].kind == 2 && T.t[k].len >= 8) cov += T.t[k].len;
    free(T.t);
    return (double)cov / ((double)w * h);
}

typedef struct { int kind; int arg; } Cand;     // kind 0 palette (arg = predictor flag), 1 general (arg = cfg)

static int run_cand(BW *bw, const uint32_t *argb, int w, int h, int hasAlpha, int quality, const uint32_t *pal, int np, Cand c) {
    return c.kind == 0 ? encode_palette(bw, argb, w, h, hasAlpha, quality, pal, np, c.arg) : encode_general(bw, argb, w, h, hasAlpha, quality, c.arg);
}

/// Encoded size of a candidate on an image, or (size_t)-1 on failure.
static size_t cand_size(const uint32_t *argb, int w, int h, int hasAlpha, int quality, const uint32_t *pal, int np, Cand c, BW *keep) {
    BW bw;
    bw_init(&bw, (size_t)w * h / 2 + 4096);
    if (bw.oom || !run_cand(&bw, argb, w, h, hasAlpha, quality, pal, np, c) || bw.oom) { free(bw.p); return (size_t)-1; }
    bw_flush(&bw);
    if (bw.oom) { free(bw.p); return (size_t)-1; }
    size_t sz = bw.n;
    if (keep) *keep = bw; else free(bw.p);
    return sz;
}

int64_t sr_vp8l_encode(const uint32_t *argb, int32_t w, int32_t h, int32_t hasAlpha, int32_t quality, uint8_t **outp) {
    if (!outp) return -1;
    *outp = NULL;
    if (!argb || w < 1 || h < 1 || w > 16383 || h > 16383) return -1;     // strict 14-bit WebP limit (max 16383x16383)
    size_t n = (size_t)w * (size_t)h;
    if (n > ((size_t)1 << 27)) return -2;      // > 134 Mpx: the working set (several words per pixel) would exceed a sane budget
    uint32_t pal[257];
    int np = distinct_colors(argb, n, pal);
    if (np <= 256) for (int i = 1; i < np; i++) { uint32_t k = pal[i]; int j = i - 1; while (j >= 0 && pal[j] > k) { pal[j + 1] = pal[j]; j--; } pal[j + 1] = k; }
    Cand cands[3]; int nc = 0;
    if (np <= 256) {
        cands[nc].kind = 0; cands[nc++].arg = 0;
        if (np > 64) { cands[nc].kind = 0; cands[nc++].arg = 1; }                       // index bundling off: a predictor can pay (smooth ramps)
        if (np > 128 && n <= 262144) { cands[nc].kind = 1; cands[nc++].arg = -1; }       // big palettes of small images
    } else {
        int sg = 0, pr = 0;
        general_pick(argb, w, h, &sg, &pr);
        int hcfg = sg | pr << 1;
        int dsg = channel_entropy(argb, w, h, 1, 0) < channel_entropy(argb, w, h, 0, 0);
        int sh = 0;
        uint32_t *sp = n > TRIAL_FULL ? make_sample(argb, w, h, TRIAL_SAMPLE, &sh) : NULL;
        double cov = copy_coverage(sp ? sp : argb, w, sp ? sh : h);
        free(sp);
        // text / screenshots: long copies make "no predictor" far better than the entropy estimate says; photos: ~0 coverage
        if (cov >= 0.6) { cands[nc].kind = 1; cands[nc++].arg = dsg; }
        else if (cov >= 0.25 && hcfg >= 2) { cands[nc].kind = 1; cands[nc++].arg = hcfg; cands[nc].kind = 1; cands[nc++].arg = dsg; }
        else { cands[nc].kind = 1; cands[nc++].arg = hcfg; }
    }
    int pick = 0;
    BW best; int haveBest = 0;
    if (nc > 1) {
        size_t sizes[3];
        if (n <= TRIAL_FULL) {
            // small image: encode every candidate in full, keep the smallest output
            for (int i = 0; i < nc; i++) {
                BW bw;
                sizes[i] = cand_size(argb, w, h, hasAlpha, quality, pal, np, cands[i], &bw);
                if (sizes[i] == (size_t)-1) continue;
                if (!haveBest || sizes[i] < best.n) { if (haveBest) free(best.p); best = bw; haveBest = 1; } else free(bw.p);
            }
            if (!haveBest) return -1;
            *outp = best.p;
            return (int64_t)best.n;
        }
        int sh = 0;
        uint32_t *sp = make_sample(argb, w, h, TRIAL_SAMPLE, &sh);
        const uint32_t *tp = sp ? sp : argb;
        int th = sp ? sh : h;
        size_t bestSz = (size_t)-1;
        for (int i = 0; i < nc; i++) {
            sizes[i] = cand_size(tp, w, th, hasAlpha, quality, pal, np, cands[i], NULL);
            if (sizes[i] != (size_t)-1 && (bestSz == (size_t)-1 || sizes[i] < bestSz)) { bestSz = sizes[i]; pick = i; }
        }
        free(sp);
    }
    size_t sz = cand_size(argb, w, h, hasAlpha, quality, pal, np, cands[pick], &best);
    if (sz == (size_t)-1) return -1;
    *outp = best.p;
    return (int64_t)best.n;
}
