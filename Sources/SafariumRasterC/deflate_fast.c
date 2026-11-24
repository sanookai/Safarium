// SafariumRasterC - fast raw-deflate compressor for TIFF strips (zlib level-1 class speed, denser than zlib -1 on residual data)
// plus the NEON kernels of the TIFF floating-point predictor (Adobe TIFF Technical Note 3).
//
// Deflate: RFC 1951. Greedy LZ77 with a single-probe 4-byte hash (miss acceleration, distance-dependent minimum length),
// per-block dynamic Huffman codes (literal/length and distance codes limited to 12 bits so that four literals fit one
// 64-bit store), stored blocks when coding would not pay. No third-party code. The caller wraps the stream (zlib header +
// adler32 for TIFF "Adobe Deflate").
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

#define HBITS 15
#define WINDOW 32768
#define MAXTOK 32768
#define BLOCK_IN (1 << 18)
// Tuning (f32 residual planes of Sompong frames / Kodak / noise): skip acceleration 1 + (misses >> 6); minimum match 4 / 5 / 6 / 8 bytes
// by distance (<= 16 / 512 / 8192 / farther). A stricter skip (>> 4) is ~1.5x faster but 50% larger on match-rich planes.
#define SKIPSHIFT 6
#define ML0 4
#define ML1 5
#define ML2 6
#define ML3 8
#define LITLEN_LIMIT 12
#define DIST_LIMIT 12

static inline uint32_t ld32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static inline uint64_t ld64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static inline void st64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static inline uint32_t hash4(uint32_t v) { return (v * 0x9E3779B1u) >> (32 - HBITS); }

static const uint16_t kLenBase[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
static const uint8_t kLenExtra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
static const uint16_t kDistBase[30] = {1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                       4097, 6145, 8193, 12289, 16385, 24577};
static const uint8_t kDistExtra[30] = {0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
static const uint8_t kClOrder[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

static uint8_t g_lenCode[259];
static uint8_t g_distCode[512];
static pthread_once_t g_tablesOnce = PTHREAD_ONCE_INIT;

static void init_tables_once(void) {
    for (int c = 0; c < 29; c++) {
        int hi = c == 28 ? 258 : kLenBase[c + 1] - 1;
        for (int l = kLenBase[c]; l <= hi; l++) g_lenCode[l] = (uint8_t)c;
    }
    g_lenCode[258] = 28;
    for (int c = 0; c < 30; c++) {
        int lo = kDistBase[c] - 1, hi = c == 29 ? 32767 : kDistBase[c + 1] - 2;
        for (int d = lo; d <= hi; d += d < 256 ? 1 : 128) {
            if (d < 256) g_distCode[d] = (uint8_t)c; else g_distCode[256 + (d >> 7)] = (uint8_t)c;
        }
    }
}

static void init_tables(void) { pthread_once(&g_tablesOnce, init_tables_once); }

static inline int dist_code(int d1) { return d1 < 256 ? g_distCode[d1] : g_distCode[256 + (d1 >> 7)]; }   // d1 = distance - 1

// ------------------------------------------------------------------------------------------------ Huffman

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

/// Length-limited code lengths for freq[0..n) (0 stays 0). Two-queue Huffman + Kraft repair (miniz style).
static void huff_lengths(const uint32_t *freq, int n, int maxLen, uint8_t *lens) {
    uint64_t keys[320];
    int m = 0;
    for (int i = 0; i < n; i++) lens[i] = 0;
    for (int i = 0; i < n; i++) if (freq[i]) keys[m++] = ((uint64_t)freq[i] << 9) | (uint64_t)i;
    if (m == 0) return;
    if (m == 1) { lens[keys[0] & 511] = 1; return; }
    qsort(keys, (size_t)m, sizeof(uint64_t), cmp_u64);
    uint64_t weight[640];
    int parent[640], depth[640];
    for (int i = 0; i < m; i++) weight[i] = keys[i] >> 9;
    int leaf = 0, node = m, ih = m;
    for (int k = 0; k < m - 1; k++) {
        int pick[2];
        for (int j = 0; j < 2; j++) {
            if (leaf < m && (ih >= node || weight[leaf] <= weight[ih])) pick[j] = leaf++; else pick[j] = ih++;
        }
        weight[node] = weight[pick[0]] + weight[pick[1]];
        parent[pick[0]] = node; parent[pick[1]] = node;
        node++;
    }
    depth[node - 1] = 0;
    for (int i = node - 2; i >= 0; i--) depth[i] = depth[parent[i]] + 1;
    int num[17] = {0};
    for (int i = 0; i < m; i++) num[depth[i] < maxLen ? depth[i] : maxLen]++;
    long total = 0;
    for (int l = 1; l <= maxLen; l++) total += (long)num[l] << (maxLen - l);
    while (total > (1L << maxLen)) {
        num[maxLen]--;
        for (int l = maxLen - 1; l > 0; l--) if (num[l] > 0) { num[l]--; num[l + 1] += 2; break; }
        total--;
    }
    int k = 0;
    for (int l = maxLen; l >= 1; l--) for (int c = 0; c < num[l]; c++) lens[keys[k++] & 511] = (uint8_t)l;
}

/// Canonical codes, bit-reversed for LSB-first output: code | len << 16.
static void canon_codes(const uint8_t *lens, int n, uint32_t *out) {
    int cnt[17] = {0}, next[17];
    for (int i = 0; i < n; i++) cnt[lens[i]]++;
    cnt[0] = 0;
    int code = 0;
    for (int b = 1; b <= 16; b++) { code = (code + cnt[b - 1]) << 1; next[b] = code; }
    for (int i = 0; i < n; i++) {
        int l = lens[i];
        if (!l) { out[i] = 0; continue; }
        int c = next[l]++, r = 0;
        for (int b = 0; b < l; b++) if ((c >> b) & 1) r |= 1 << (l - 1 - b);
        out[i] = (uint32_t)r | (uint32_t)l << 16;
    }
}

// ------------------------------------------------------------------------------------------------ bit writer

typedef struct { uint8_t *p; uint64_t acc; int nb; } BW;

static inline void bw_put(BW *w, uint32_t code, int len) {   // len <= 32, nb < 8 on entry and on exit
    w->acc |= (uint64_t)code << w->nb;
    w->nb += len;
    st64(w->p, w->acc);
    w->p += w->nb >> 3;
    w->acc >>= (w->nb & ~7);
    w->nb &= 7;
}

static void bw_align(BW *w) {
    if (w->nb) { *w->p++ = (uint8_t)w->acc; w->acc = 0; w->nb = 0; }
}

// ------------------------------------------------------------------------------------------------ match finder

typedef struct {
    uint32_t tab[1 << HBITS];
    uint32_t run[MAXTOK + 2];   // literal bytes before the match
    uint32_t md[MAXTOK + 2];    // (length - 3) << 16 | (distance - 1)
} Ctx;

static inline int match_len(const uint8_t *a, const uint8_t *b, int maxlen) {   // a ahead of b, a[0..maxlen) readable
    int n = 0;
    if (maxlen >= 8) {   // most matches are short: settle them with one 8-byte compare
        uint64_t x = ld64(a) ^ ld64(b);
        if (x) return __builtin_ctzll(x) >> 3;
        n = 8;
    }
#if defined(__ARM_NEON)
    while (n + 16 <= maxlen) {
        uint8x16_t x = veorq_u8(vld1q_u8(a + n), vld1q_u8(b + n));
        if (vmaxvq_u8(x) == 0) { n += 16; continue; }
        uint64_t lo = vgetq_lane_u64(vreinterpretq_u64_u8(x), 0);
        if (lo) return n + (__builtin_ctzll(lo) >> 3);
        return n + 8 + (__builtin_ctzll(vgetq_lane_u64(vreinterpretq_u64_u8(x), 1)) >> 3);
    }
#endif
    while (n + 8 <= maxlen) {
        uint64_t x = ld64(a + n) ^ ld64(b + n);
        if (x) return n + (__builtin_ctzll(x) >> 3);
        n += 8;
    }
    while (n < maxlen && a[n] == b[n]) n++;
    return n;
}

/// Minimum match length by distance: a short far match costs more bits than the Huffman-coded literals it replaces.
static inline int min_len(int dist) { return dist <= 16 ? ML0 : (dist <= 512 ? ML1 : (dist <= 8192 ? ML2 : ML3)); }

/// Tokenise from *ip until `stop` (or MAXTOK tokens). Returns the number of tokens; *ip is where parsing stopped,
/// *anchor the end of the last match (literals after it belong to the block tail).
static int parse(Ctx *c, const uint8_t *in, int64_t start, int64_t stop, int64_t mlimit, int64_t end, int64_t *ipOut, int64_t *anchorOut) {
    int64_t ip = start, anchor = start;
    int nt = 0;
    uint32_t *tab = c->tab;
    while (ip < mlimit && ip < stop && nt < MAXTOK) {
        uint32_t v = ld32(in + ip), h = hash4(v);
        int64_t cand = tab[h];
        tab[h] = (uint32_t)ip;
        int64_t dist = ip - cand;
        if (dist > 0 && dist <= WINDOW && ld32(in + cand) == v) {
            int maxlen = end - ip < 258 ? (int)(end - ip) : 258;
            int len = 4 + match_len(in + ip + 4, in + cand + 4, maxlen - 4);
            if (len >= min_len((int)dist)) {
                c->run[nt] = (uint32_t)(ip - anchor);
                c->md[nt] = (uint32_t)(len - 3) << 16 | (uint32_t)(dist - 1);
                nt++;
                int64_t e = ip + len;
                if (ip + 1 < mlimit) tab[hash4(ld32(in + ip + 1))] = (uint32_t)(ip + 1);
                if (e - 2 < mlimit && e - 2 > ip + 1) tab[hash4(ld32(in + e - 2))] = (uint32_t)(e - 2);
                ip = anchor = e;
                continue;
            }
        }
        ip += 1 + ((ip - anchor) >> SKIPSHIFT);
    }
    *ipOut = ip;
    *anchorOut = anchor;
    return nt;
}

// ------------------------------------------------------------------------------------------------ block output

static void write_stored(BW *w, const uint8_t *src, int64_t n, int final) {
    int64_t left = n;
    do {
        int64_t k = left < 65535 ? left : 65535;
        int last = final && k == left;
        bw_put(w, (uint32_t)(last ? 1 : 0), 3);   // BFINAL + BTYPE 00
        bw_align(w);
        w->p[0] = (uint8_t)(k & 0xFF); w->p[1] = (uint8_t)(k >> 8);
        w->p[2] = (uint8_t)(~k & 0xFF); w->p[3] = (uint8_t)((~k >> 8) & 0xFF);
        w->p += 4;
        memcpy(w->p, src + (n - left), (size_t)k);
        w->p += k;
        left -= k;
    } while (left > 0);
}

static void write_block(Ctx *c, BW *w, const uint8_t *in, int64_t bstart, int64_t bend, int nt, int final) {
    int64_t rawBytes = bend - bstart;
    uint32_t litFreq[288] = {0}, distFreq[32] = {0};
    uint32_t hist[4][256];
    memset(hist, 0, sizeof hist);
    int64_t cur = bstart;
    for (int k = 0; k < nt; k++) {
        const uint8_t *p = in + cur;
        uint32_t r = c->run[k], j = 0;
        for (; j + 4 <= r; j += 4) { hist[0][p[j]]++; hist[1][p[j + 1]]++; hist[2][p[j + 2]]++; hist[3][p[j + 3]]++; }
        for (; j < r; j++) hist[0][p[j]]++;
        int len = (int)(c->md[k] >> 16) + 3, d1 = (int)(c->md[k] & 0xFFFF);
        litFreq[257 + g_lenCode[len]]++;
        distFreq[dist_code(d1)]++;
        cur += r + len;
    }
    {
        const uint8_t *p = in + cur;
        int64_t r = bend - cur, j = 0;
        for (; j + 4 <= r; j += 4) { hist[0][p[j]]++; hist[1][p[j + 1]]++; hist[2][p[j + 2]]++; hist[3][p[j + 3]]++; }
        for (; j < r; j++) hist[0][p[j]]++;
    }
    for (int s = 0; s < 256; s++) litFreq[s] = hist[0][s] + hist[1][s] + hist[2][s] + hist[3][s];
    litFreq[256] = 1;
    int anyDist = 0;
    for (int s = 0; s < 30; s++) if (distFreq[s]) anyDist = 1;
    if (!anyDist) distFreq[0] = 1;

    uint8_t litLens[288], distLens[32], clLens[19];
    uint32_t litCodes[288], distCodes[32], clCodes[19];
    huff_lengths(litFreq, 286, LITLEN_LIMIT, litLens);
    huff_lengths(distFreq, 30, DIST_LIMIT, distLens);
    int hlit = 286;
    while (hlit > 257 && litLens[hlit - 1] == 0) hlit--;
    int hdist = 30;
    while (hdist > 1 && distLens[hdist - 1] == 0) hdist--;
    uint8_t seq[320], extra[320];
    int ns = 0;
    {
        uint8_t all[320];
        int na = 0;
        for (int i = 0; i < hlit; i++) all[na++] = litLens[i];
        for (int i = 0; i < hdist; i++) all[na++] = distLens[i];
        int r = 0;
        while (r < na) {
            uint8_t v = all[r];
            int run = 1;
            while (r + run < na && all[r + run] == v) run++;
            if (v == 0 && run >= 3) {
                int n = run < 138 ? run : 138;
                if (n >= 11) { seq[ns] = 18; extra[ns++] = (uint8_t)(n - 11); } else { seq[ns] = 17; extra[ns++] = (uint8_t)(n - 3); }
                r += n;
            } else if (v != 0 && run >= 4) {
                seq[ns] = v; extra[ns++] = 0;
                int left = run - 1 < 6 ? run - 1 : 6;
                seq[ns] = 16; extra[ns++] = (uint8_t)(left - 3);
                r += 1 + left;
            } else {
                seq[ns] = v; extra[ns++] = 0;
                r++;
            }
        }
    }
    uint32_t clFreq[19] = {0};
    for (int i = 0; i < ns; i++) clFreq[seq[i]]++;
    huff_lengths(clFreq, 19, 7, clLens);
    int hclen = 19;
    while (hclen > 4 && clLens[kClOrder[hclen - 1]] == 0) hclen--;

    int64_t bits = 3 + 5 + 5 + 4 + 3 * hclen;
    for (int i = 0; i < ns; i++) bits += clLens[seq[i]] + (seq[i] == 16 ? 2 : (seq[i] == 17 ? 3 : (seq[i] == 18 ? 7 : 0)));
    for (int s = 0; s < 286; s++) if (litFreq[s]) bits += (int64_t)(litLens[s] + (s >= 257 ? kLenExtra[s - 257] : 0)) * litFreq[s];
    for (int s = 0; s < 30; s++) if (distFreq[s]) bits += (int64_t)(distLens[s] + kDistExtra[s]) * distFreq[s];
    int64_t storedBits = (rawBytes + 5 * ((rawBytes + 65534) / 65535)) * 8 + 8;
    if (rawBytes > 0 && bits > storedBits) { write_stored(w, in + bstart, rawBytes, final); return; }

    canon_codes(litLens, 286, litCodes);
    canon_codes(distLens, 30, distCodes);
    canon_codes(clLens, 19, clCodes);
    bw_put(w, (uint32_t)(final ? 1 : 0), 1);
    bw_put(w, 2, 2);
    bw_put(w, (uint32_t)(hlit - 257), 5);
    bw_put(w, (uint32_t)(hdist - 1), 5);
    bw_put(w, (uint32_t)(hclen - 4), 4);
    for (int k = 0; k < hclen; k++) bw_put(w, clLens[kClOrder[k]], 3);
    for (int k = 0; k < ns; k++) {
        uint32_t cc = clCodes[seq[k]];
        bw_put(w, cc & 0xFFFF, (int)(cc >> 16));
        if (seq[k] == 16) bw_put(w, extra[k], 2); else if (seq[k] == 17) bw_put(w, extra[k], 3); else if (seq[k] == 18) bw_put(w, extra[k], 7);
    }
    // tokens
    cur = bstart;
    for (int k = 0; k <= nt; k++) {
        const uint8_t *p = in + cur;
        int64_t r = k < nt ? c->run[k] : bend - cur, j = 0;
        for (; j + 4 <= r; j += 4) {
            uint32_t a = litCodes[p[j]], b = litCodes[p[j + 1]], d = litCodes[p[j + 2]], e = litCodes[p[j + 3]];
            int la = (int)(a >> 16), lb = (int)(b >> 16), ld = (int)(d >> 16), le = (int)(e >> 16);
            uint64_t v = (uint64_t)(a & 0xFFFF) | (uint64_t)(b & 0xFFFF) << la;
            int n = la + lb;
            v |= (uint64_t)(d & 0xFFFF) << n; n += ld;
            v |= (uint64_t)(e & 0xFFFF) << n; n += le;
            w->acc |= v << w->nb;
            w->nb += n;
            st64(w->p, w->acc);
            w->p += w->nb >> 3;
            w->acc >>= (w->nb & ~7);
            w->nb &= 7;
        }
        for (; j < r; j++) { uint32_t a = litCodes[p[j]]; bw_put(w, a & 0xFFFF, (int)(a >> 16)); }
        if (k == nt) break;
        cur += r;
        int len = (int)(c->md[k] >> 16) + 3, d1 = (int)(c->md[k] & 0xFFFF);
        int lc = g_lenCode[len], dc = dist_code(d1);
        uint32_t lcode = litCodes[257 + lc], dcode = distCodes[dc];
        int ll = (int)(lcode >> 16), dl = (int)(dcode >> 16);
        uint64_t v = (uint64_t)(lcode & 0xFFFF);
        int n = ll;
        v |= (uint64_t)(len - kLenBase[lc]) << n; n += kLenExtra[lc];
        v |= (uint64_t)(dcode & 0xFFFF) << n; n += dl;
        v |= (uint64_t)(d1 + 1 - kDistBase[dc]) << n; n += kDistExtra[dc];
        w->acc |= v << w->nb;   // <= 12 + 5 + 12 + 13 + 7 = 49 bits
        w->nb += n;
        st64(w->p, w->acc);
        w->p += w->nb >> 3;
        w->acc >>= (w->nb & ~7);
        w->nb &= 7;
        cur += len;
    }
    uint32_t eob = litCodes[256];
    bw_put(w, eob & 0xFFFF, (int)(eob >> 16));
}

/// Bytes a block of `raw` input can occupy at worst: it is stored when coding would not pay, so 5 bytes (1 header incl. bit
/// padding + LEN/NLEN) per 65535-byte sub-block, plus slack for the 8-byte over-stores of the bit writer.
static inline int64_t block_worst(int64_t raw) { return raw + 5 * ((raw + 65534) / 65535) + 16; }

/// Largest output `sr_deflate_fast` / the streaming feeds can produce for n input bytes (the caller's `cap` must be at least
/// this). Worst case = every block stored. Each stored sub-block costs 5 bytes and holds <= 65535, so the overhead is
/// 5 * (ceil sub-blocks): <= n/65535 sub-blocks plus one extra rounding-up sub-block per block (a BLOCK_IN block is 4 full
/// sub-blocks + a 4-byte one, i.e. 5 sub-blocks, which a plain n/65535 term undercounts). A block holds at least
/// MAXTOK * 4 = 2^17 input bytes unless it is the last of the call, so there are <= n/2^17 + 1 blocks. +64 covers the final
/// empty/aligning bytes and the 16-byte store slack.
int64_t sr_deflate_bound(int64_t n) { return n + 5 * (n / 65535 + n / (1 << 17) + 3) + 64; }

// A resumable stream: blocks are emitted as input arrives, the match finder keeps its 32 KiB window, the bit writer its
// partial byte. The caller owns the input window (see sr_dstream_rebase).
typedef struct { Ctx *c; uint64_t acc; int nb; } DStream;

void *sr_dstream_new(void) {
    init_tables();
    DStream *s = (DStream *)calloc(1, sizeof(DStream));
    if (!s) return NULL;
    s->c = (Ctx *)calloc(1, sizeof(Ctx));
    if (!s->c) { free(s); return NULL; }
    return s;
}

void sr_dstream_free(void *st) {
    DStream *s = (DStream *)st;
    if (s) { free(s->c); free(s); }
}

/// The caller moved the window: bytes [shift, ..) of the old buffer now start at index 0. Hash entries are re-based
/// (entries that fell out of the window point at index 0, where the match check still compares real bytes).
void sr_dstream_rebase(void *st, int64_t shift) {
    DStream *s = (DStream *)st;
    if (!s || shift <= 0) return;
    uint32_t *tab = s->c->tab;
    for (int i = 0; i < (1 << HBITS); i++) tab[i] = tab[i] >= (uint64_t)shift ? tab[i] - (uint32_t)shift : 0;
}

/// Compress in[start..len) (in[0..start) is already-coded history, at most WINDOW bytes of it are used) into `out`. A non-final
/// feed leaves the last few bytes unconsumed (*consumed counts bytes from `start`) and keeps a partial output byte inside the
/// stream; the final feed ends the stream on a byte boundary. Returns the bytes written to `out`, or -1 on bad arguments or
/// when `cap` would be overrun (checked before every block).
int64_t sr_dstream_feed(void *st, const uint8_t *in, int64_t start, int64_t len, int32_t final, uint8_t *out, int64_t cap, int64_t *consumed) {
    DStream *s = (DStream *)st;
    if (!s || !out || cap < 64 || start < 0 || len < start || len >= ((int64_t)1 << 31) - 1024 || (len > 0 && !in)) return -1;
    BW w = {out, s->acc, s->nb};
    int64_t pos = start;
    if (len == start && final) {
        write_stored(&w, in, 0, 1);
    } else {
        const int64_t mlimit = len - 8;
        for (;;) {
            int64_t ip, anchor;
            int64_t stop = pos + BLOCK_IN < len ? pos + BLOCK_IN : len;
            int nt = parse(s->c, in, pos, stop, mlimit, len, &ip, &anchor);
            int atEnd = ip >= mlimit;
            int isFinal = final && atEnd;
            int64_t bend = isFinal ? len : (ip > anchor ? ip : anchor);
            if (bend > len) bend = len;
            if (bend == pos) break;   // nothing to code yet (non-final tail)
            if (cap - (w.p - out) < block_worst(bend - pos)) return -1;
            write_block(s->c, &w, in, pos, bend, nt, isFinal);
            pos = bend;
            if (isFinal || atEnd) break;
        }
    }
    if (final) bw_align(&w);
    s->acc = w.acc; s->nb = w.nb;
    if (consumed) *consumed = pos - start;
    return w.p - out;
}

/// Compress in[0..n) into one raw deflate stream (final block marked). Returns the byte count, or -1 on bad
/// arguments / out of memory / `cap` < sr_deflate_bound(n).
int64_t sr_deflate_fast(const uint8_t *in, int64_t n, uint8_t *out, int64_t cap) {
    if (!out || (n > 0 && !in) || n < 0 || n >= ((int64_t)1 << 31) - 1024 || cap < sr_deflate_bound(n)) return -1;
    void *st = sr_dstream_new();
    if (!st) return -1;
    int64_t got = sr_dstream_feed(st, in, 0, n, 1, out, cap, NULL);
    sr_dstream_free(st);
    return got;
}

// ------------------------------------------------------------------------------------------------ TIFF float predictor

/// One row of the TIFF floating-point predictor (Tech Note 3): `w * ch` little-endian float samples become four byte planes
/// (most significant bytes first) and are then differenced with stride `ch` over the whole row, exactly like libtiff.
/// `swapRB` swaps samples 0 and 2 of every pixel (BGR(A) memory order -> RGB(A) file order). `tmp` needs 4 * w * ch + 16 bytes
/// (plus 4 * w * ch when swapRB). `dst` receives the 4 * w * ch result bytes.
void sr_tiff_f32_predict_row(const uint8_t *src, int32_t w, int32_t ch, int32_t swapRB, uint8_t *tmp, uint8_t *dst) {
    const int64_t n = (int64_t)w * ch;
    const uint8_t *s = src;
    uint8_t *planes = tmp;
    if (swapRB && ch >= 3) {
        uint8_t *sw = tmp + 4 * n + 16;
        for (int64_t x = 0; x < w; x++) {
            uint32_t px[4];
            memcpy(px, src + (size_t)x * ch * 4, (size_t)ch * 4);
            uint32_t t = px[0]; px[0] = px[2]; px[2] = t;
            memcpy(sw + (size_t)x * ch * 4, px, (size_t)ch * 4);
        }
        s = sw;
    }
    int64_t j = 0;
#if defined(__ARM_NEON)
    for (; j + 16 <= n; j += 16) {
        uint8x16x4_t v = vld4q_u8(s + 4 * j);   // v.val[k] = byte k of 16 consecutive floats
        vst1q_u8(planes + j, v.val[3]);
        vst1q_u8(planes + n + j, v.val[2]);
        vst1q_u8(planes + 2 * n + j, v.val[1]);
        vst1q_u8(planes + 3 * n + j, v.val[0]);
    }
#endif
    for (; j < n; j++) {
        planes[j] = s[4 * j + 3]; planes[n + j] = s[4 * j + 2]; planes[2 * n + j] = s[4 * j + 1]; planes[3 * n + j] = s[4 * j];
    }
    const int64_t rb = 4 * n;
    int64_t i = 0;
    for (; i < ch && i < rb; i++) dst[i] = planes[i];
    i = ch;
#if defined(__ARM_NEON)
    for (; i + 16 <= rb; i += 16) vst1q_u8(dst + i, vsubq_u8(vld1q_u8(planes + i), vld1q_u8(planes + i - ch)));
#endif
    for (; i < rb; i++) dst[i] = (uint8_t)(planes[i] - planes[i - ch]);
}
