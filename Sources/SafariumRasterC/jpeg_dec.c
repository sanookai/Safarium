// SafariumRasterC — Compact C11/NEON baseline JFIF JPEG decoder matching libjpeg-turbo
// ITU BT.601 YCbCr -> BGR and fancy 4:2:0 / 4:2:2 / 4:4:0 chroma upsampling.
// Streaming 1-MCU-row pipeline: writes directly into caller buffer with ~100 KiB scratch.

#include "sr_ops_perf.h"
#include <arm_neon.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t ZIGZAG[64] = {
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63
};

#define FAST_BITS 10
#define FAST_MASK ((1 << FAST_BITS) - 1)

typedef struct {
    uint16_t fast[1 << FAST_BITS]; // bit 15 = valid fast entry: bits[11:8] = len, bits[7:0] = symbol
    uint16_t maxcode[17];          // scaled 16-bit codes for slow decode (sentinel 0x10000 in 32-bit if needed)
    uint32_t maxcode32[17];
    int32_t  valoffset[17];
    uint8_t  huffval[256];
    int      valid;
} huff_tab_t;

typedef struct {
    int32_t id;
    int32_t hs, vs;
    int32_t qt_id;
    int32_t dc_id, ac_id;
    int32_t dc_pred;
} jpeg_comp_t;

typedef struct {
    const uint8_t *p;
    const uint8_t *end;
    uint32_t bitbuf; // MSB-aligned in top `bitcnt` bits (use 64-bit for 32-bit lookahead)
    uint64_t buf64;
    int      bitcnt;
    int      eof_or_marker; // encountered EOI/unexpected marker cleanly
} bitread_t;

static inline uint16_t rd_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static inline uint16_t rd_u16_end(const uint8_t *p, int le) {
    return le ? (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8)) : rd_be16(p);
}

static inline uint32_t rd_u32_end(const uint8_t *p, int le) {
    if (le) return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

// Parse APP1 Exif IFD orientation tag (0x0112). Returns 1 if absent/invalid or orientation value 1..8.
static int32_t parse_exif_orientation(const uint8_t *app, size_t len) {
    if (len < 14 || memcmp(app, "Exif\0\0", 6) != 0) return 1;
    const uint8_t *t = app + 6;
    size_t tlen = len - 6;
    int le = 0;
    if (t[0] == 'I' && t[1] == 'I') le = 1;
    else if (t[0] == 'M' && t[1] == 'M') le = 0;
    else return 1;
    if (rd_u16_end(t + 2, le) != 42) return 1;
    uint32_t ifd0 = rd_u32_end(t + 4, le);
    if ((size_t)ifd0 + 2 > tlen) return 1;
    uint16_t cnt = rd_u16_end(t + ifd0, le);
    for (uint16_t i = 0; i < cnt; i++) {
        size_t off = (size_t)ifd0 + 2 + (size_t)i * 12;
        if (off + 12 > tlen) break;
        if (rd_u16_end(t + off, le) == 0x0112) {
            uint16_t val = rd_u16_end(t + off + 8, le);
            return (val >= 1 && val <= 8) ? (int32_t)val : 1;
        }
    }
    return 1;
}

static int build_huff(huff_tab_t *ht, const uint8_t bits[16], const uint8_t *vals, int num_vals) {
    memset(ht, 0, sizeof(*ht));
    if (num_vals > 256) return -1;
    memcpy(ht->huffval, vals, (size_t)num_vals);

    uint8_t huffsize[257];
    uint16_t huffcode[257];
    int p = 0;
    for (int l = 1; l <= 16; l++) {
        int c = bits[l - 1];
        if (p + c > 256) return -1;
        for (int i = 0; i < c; i++) huffsize[p++] = (uint8_t)l;
    }
    huffsize[p] = 0;
    if (p != num_vals) return -1;

    uint32_t code = 0;
    int si = huffsize[0], idx = 0;
    while (huffsize[idx]) {
        while ((int)huffsize[idx] == si) {
            if (code >= (1u << si)) return -1;
            huffcode[idx++] = (uint16_t)code++;
        }
        code <<= 1;
        si++;
    }

    p = 0;
    for (int l = 1; l <= 16; l++) {
        if (bits[l - 1]) {
            ht->valoffset[l] = p - (int32_t)huffcode[p];
            p += bits[l - 1];
            ht->maxcode32[l] = (uint32_t)huffcode[p - 1];
        } else {
            ht->valoffset[l] = 0;
            ht->maxcode32[l] = UINT32_MAX; // marks empty level
        }
    }

    // Populate FAST_BITS lookup table
    for (int i = 0; i < idx; i++) {
        int l = huffsize[i];
        if (l <= FAST_BITS) {
            int shift = FAST_BITS - l;
            uint32_t base = (uint32_t)huffcode[i] << shift;
            uint32_t span = 1u << shift;
            uint16_t entry = (uint16_t)(0x8000u | ((uint16_t)l << 8) | (uint16_t)vals[i]);
            for (uint32_t k = 0; k < span; k++) ht->fast[base + k] = entry;
        }
    }
    ht->valid = 1;
    return 0;
}

static inline void br_init(bitread_t *br, const uint8_t *p, const uint8_t *end) {
    br->p = p;
    br->end = end;
    br->buf64 = 0;
    br->bitcnt = 0;
    br->eof_or_marker = 0;
}

static inline void br_fill(bitread_t *br) {
    if (!br->eof_or_marker && br->bitcnt <= 32 && br->p + 4 <= br->end) {
        uint32_t d;
        memcpy(&d, br->p, 4);
        uint32_t v = ~d;
        if (((v - 0x01010101u) & ~v & 0x80808080u) == 0) {
            uint32_t be = __builtin_bswap32(d);
            br->buf64 |= (uint64_t)be << (32 - br->bitcnt);
            br->bitcnt += 32;
            br->p += 4;
            if (br->bitcnt > 56) return;
        }
    }
    while (br->bitcnt <= 56) {
        if (br->p >= br->end || br->eof_or_marker) {
            br->bitcnt += 8; // zero-pad cleanly at stream end without reading OOB
            continue;
        }
        uint8_t b = *br->p++;
        if (b == 0xFF) {
            if (br->p >= br->end) {
                br->eof_or_marker = 1;
                br->bitcnt += 8;
                continue;
            }
            uint8_t b2 = *br->p++;
            if (b2 == 0x00) {
                b = 0xFF; // byte-stuffed 0xFF
            } else {
                // Marker hit (RST/EOI/etc.): rewind before marker, zero-pad remaining bits
                br->p -= 2;
                br->eof_or_marker = 1;
                br->bitcnt += 8;
                continue;
            }
        }
        br->buf64 |= (uint64_t)b << (56 - br->bitcnt);
        br->bitcnt += 8;
    }
}

static inline void br_drop(bitread_t *br, int n) {
    br->buf64 <<= n;
    br->bitcnt -= n;
}

static inline int32_t br_get_bits_signed(bitread_t *br, int s) {
    if (s <= 0) return 0;
    if (br->bitcnt < s) br_fill(br);
    uint32_t v = (uint32_t)(br->buf64 >> (64 - s));
    br->buf64 <<= s;
    br->bitcnt -= s;
    uint32_t half = 1u << (s - 1);
    if (v < half) return (int32_t)v - (int32_t)((1u << s) - 1u);
    return (int32_t)v;
}

static inline int huff_decode(bitread_t *br, const huff_tab_t *ht) {
    if (br->bitcnt < FAST_BITS) br_fill(br);
    uint32_t peek = (uint32_t)(br->buf64 >> (64 - FAST_BITS));
    uint16_t ent = ht->fast[peek];
    if (ent & 0x8000u) {
        int len = (ent >> 8) & 0xF;
        br_drop(br, len);
        return ent & 0xFF;
    }
    uint32_t code = 0;
    for (int l = 1; l <= 16; l++) {
        if (br->bitcnt < 1) br_fill(br);
        code = (code << 1) | (uint32_t)(br->buf64 >> 63);
        br->buf64 <<= 1;
        br->bitcnt--;
        if (ht->maxcode32[l] != UINT32_MAX && code <= ht->maxcode32[l]) {
            int32_t idx = (int32_t)code + ht->valoffset[l];
            if ((uint32_t)idx < 256u) return ht->huffval[idx];
            return -1;
        }
    }
    return -1;
}

static inline uint8_t clamp_u8(int32_t v) {
    return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

// Decode one 8x8 block (if skip_idct != 0, only consumes entropy & updates dc_pred without dequant/IDCT).
static int decode_block(bitread_t *br, const huff_tab_t *dc_ht, const huff_tab_t *ac_ht,
                        const uint16_t *qt, int32_t *dc_pred, int16_t block[64], int skip_idct,
                        int32_t *nz_max_out) {
    int sym = huff_decode(br, dc_ht);
    if (sym < 0 || sym > 15) return -1;
    int32_t diff = br_get_bits_signed(br, sym);
    int32_t dc = *dc_pred + diff;
    *dc_pred = dc;

    int32_t nonzero_max = 0;
    if (!skip_idct) {
        memset(block, 0, sizeof(int16_t) * 64);
        block[0] = (int16_t)(dc * (int32_t)qt[0]);
    }
    int k = 1;
    while (k < 64) {
        int rs = huff_decode(br, ac_ht);
        if (rs < 0) return -1;
        if (rs == 0) break; // EOB
        int r = rs >> 4;
        int s = rs & 0xF;
        if (rs == 0xF0) {
            k += 16;
            continue;
        }
        k += r;
        if (k >= 64) return -1;
        int32_t ac = br_get_bits_signed(br, s);
        if (!skip_idct && s > 0) {
            int32_t pos = ZIGZAG[k];
            block[pos] = (int16_t)(ac * (int32_t)qt[k]);
            if (ac != 0) nonzero_max = k;
        }
        k++;
    }
    if (nz_max_out) *nz_max_out = nonzero_max;
    return 0;
}

// Exact libjpeg-turbo integer IDCT (`jidctint` CONST_BITS=13, PASS1_BITS=2)
#define FIX_0_298631336  ((int32_t)2446)
#define FIX_0_390180644  ((int32_t)3196)
#define FIX_0_541196100  ((int32_t)4433)
#define FIX_0_765366865  ((int32_t)6270)
#define FIX_0_899976223  ((int32_t)7373)
#define FIX_1_175875602  ((int32_t)9633)
#define FIX_1_501321110  ((int32_t)12299)
#define FIX_1_847759065  ((int32_t)15137)
#define FIX_1_961570560  ((int32_t)16069)
#define FIX_2_053119869  ((int32_t)16819)
#define FIX_2_562915447  ((int32_t)20995)
#define FIX_3_072711026  ((int32_t)25172)

static inline int32_t descale(int32_t x, int n) {
    return (x + (1 << (n - 1))) >> n;
}

static inline void idct_4col_s16(int16x4_t i0, int16x4_t i1, int16x4_t i2, int16x4_t i3,
                                 int16x4_t i4, int16x4_t i5, int16x4_t i6, int16x4_t i7,
                                 int32x4_t *o0, int32x4_t *o1, int32x4_t *o2, int32x4_t *o3,
                                 int32x4_t *o4, int32x4_t *o5, int32x4_t *o6, int32x4_t *o7) {
    int32x4_t z2 = vmovl_s16(i2), z3 = vmovl_s16(i6);
    int32x4_t z1 = vmulq_n_s32(vaddq_s32(z2, z3), FIX_0_541196100);
    int32x4_t tmp2 = vsubq_s32(z1, vmulq_n_s32(z3, FIX_1_847759065));
    int32x4_t tmp3 = vaddq_s32(z1, vmulq_n_s32(z2, FIX_0_765366865));

    int32x4_t w0 = vmovl_s16(i0), w4 = vmovl_s16(i4);
    int32x4_t tmp0 = vshlq_n_s32(vaddq_s32(w0, w4), 13);
    int32x4_t tmp1 = vshlq_n_s32(vsubq_s32(w0, w4), 13);

    int32x4_t t10 = vaddq_s32(tmp0, tmp3), t13 = vsubq_s32(tmp0, tmp3);
    int32x4_t t11 = vaddq_s32(tmp1, tmp2), t12 = vsubq_s32(tmp1, tmp2);

    int32x4_t x0 = vmovl_s16(i7), x1 = vmovl_s16(i5), x2 = vmovl_s16(i3), x3 = vmovl_s16(i1);
    int32x4_t nz1 = vaddq_s32(x0, x3), nz2 = vaddq_s32(x1, x2);
    int32x4_t nz3 = vaddq_s32(x0, x2), nz4 = vaddq_s32(x1, x3);
    int32x4_t nz5 = vmulq_n_s32(vaddq_s32(nz3, nz4), FIX_1_175875602);

    x0 = vmulq_n_s32(x0, FIX_0_298631336);
    x1 = vmulq_n_s32(x1, FIX_2_053119869);
    x2 = vmulq_n_s32(x2, FIX_3_072711026);
    x3 = vmulq_n_s32(x3, FIX_1_501321110);
    nz1 = vmulq_n_s32(nz1, -FIX_0_899976223);
    nz2 = vmulq_n_s32(nz2, -FIX_2_562915447);
    nz3 = vaddq_s32(vmulq_n_s32(nz3, -FIX_1_961570560), nz5);
    nz4 = vaddq_s32(vmulq_n_s32(nz4, -FIX_0_390180644), nz5);

    x0 = vaddq_s32(x0, vaddq_s32(nz1, nz3));
    x1 = vaddq_s32(x1, vaddq_s32(nz2, nz4));
    x2 = vaddq_s32(x2, vaddq_s32(nz2, nz3));
    x3 = vaddq_s32(x3, vaddq_s32(nz1, nz4));

    *o0 = vaddq_s32(t10, x3); *o7 = vsubq_s32(t10, x3);
    *o1 = vaddq_s32(t11, x2); *o6 = vsubq_s32(t11, x2);
    *o2 = vaddq_s32(t12, x1); *o5 = vsubq_s32(t12, x1);
    *o3 = vaddq_s32(t13, x0); *o4 = vsubq_s32(t13, x0);
}

static void idct_8x8_int(const int16_t coef[64], uint8_t *out, ptrdiff_t out_stride, int32_t nz_max) {
    if (nz_max == 0) {
        uint8_t dc = clamp_u8(descale((int32_t)coef[0], 3) + 128);
        uint8x8_t v = vdup_n_u8(dc);
        for (int y = 0; y < 8; y++) vst1_u8(out + (ptrdiff_t)y * out_stride, v);
        return;
    }

    int16x8_t r0 = vld1q_s16(coef + 0),  r1 = vld1q_s16(coef + 8);
    int16x8_t r2 = vld1q_s16(coef + 16), r3 = vld1q_s16(coef + 24);
    int16x8_t r4 = vld1q_s16(coef + 32), r5 = vld1q_s16(coef + 40);
    int16x8_t r6 = vld1q_s16(coef + 48), r7 = vld1q_s16(coef + 56);

    int32x4_t l0, l1, l2, l3, l4, l5, l6, l7;
    int32x4_t h0, h1, h2, h3, h4, h5, h6, h7;
    idct_4col_s16(vget_low_s16(r0), vget_low_s16(r1), vget_low_s16(r2), vget_low_s16(r3),
                  vget_low_s16(r4), vget_low_s16(r5), vget_low_s16(r6), vget_low_s16(r7),
                  &l0, &l1, &l2, &l3, &l4, &l5, &l6, &l7);
    idct_4col_s16(vget_high_s16(r0), vget_high_s16(r1), vget_high_s16(r2), vget_high_s16(r3),
                  vget_high_s16(r4), vget_high_s16(r5), vget_high_s16(r6), vget_high_s16(r7),
                  &h0, &h1, &h2, &h3, &h4, &h5, &h6, &h7);

    int16x8_t w0 = vcombine_s16(vrshrn_n_s32(l0, 11), vrshrn_n_s32(h0, 11));
    int16x8_t w1 = vcombine_s16(vrshrn_n_s32(l1, 11), vrshrn_n_s32(h1, 11));
    int16x8_t w2 = vcombine_s16(vrshrn_n_s32(l2, 11), vrshrn_n_s32(h2, 11));
    int16x8_t w3 = vcombine_s16(vrshrn_n_s32(l3, 11), vrshrn_n_s32(h3, 11));
    int16x8_t w4 = vcombine_s16(vrshrn_n_s32(l4, 11), vrshrn_n_s32(h4, 11));
    int16x8_t w5 = vcombine_s16(vrshrn_n_s32(l5, 11), vrshrn_n_s32(h5, 11));
    int16x8_t w6 = vcombine_s16(vrshrn_n_s32(l6, 11), vrshrn_n_s32(h6, 11));
    int16x8_t w7 = vcombine_s16(vrshrn_n_s32(l7, 11), vrshrn_n_s32(h7, 11));

    // Transpose 8x8 int16x8_t so Pass 2 transforms rows simultaneously
    int16x8x2_t a0 = vtrnq_s16(w0, w1), a1 = vtrnq_s16(w2, w3), a2 = vtrnq_s16(w4, w5), a3 = vtrnq_s16(w6, w7);
    int32x4x2_t b0 = vtrnq_s32(vreinterpretq_s32_s16(a0.val[0]), vreinterpretq_s32_s16(a1.val[0]));
    int32x4x2_t b1 = vtrnq_s32(vreinterpretq_s32_s16(a0.val[1]), vreinterpretq_s32_s16(a1.val[1]));
    int32x4x2_t b2 = vtrnq_s32(vreinterpretq_s32_s16(a2.val[0]), vreinterpretq_s32_s16(a3.val[0]));
    int32x4x2_t b3 = vtrnq_s32(vreinterpretq_s32_s16(a2.val[1]), vreinterpretq_s32_s16(a3.val[1]));

    int16x8_t c0 = vreinterpretq_s16_s64(vtrn1q_s64(vreinterpretq_s64_s32(b0.val[0]), vreinterpretq_s64_s32(b2.val[0])));
    int16x8_t c4 = vreinterpretq_s16_s64(vtrn2q_s64(vreinterpretq_s64_s32(b0.val[0]), vreinterpretq_s64_s32(b2.val[0])));
    int16x8_t c2 = vreinterpretq_s16_s64(vtrn1q_s64(vreinterpretq_s64_s32(b0.val[1]), vreinterpretq_s64_s32(b2.val[1])));
    int16x8_t c6 = vreinterpretq_s16_s64(vtrn2q_s64(vreinterpretq_s64_s32(b0.val[1]), vreinterpretq_s64_s32(b2.val[1])));
    int16x8_t c1 = vreinterpretq_s16_s64(vtrn1q_s64(vreinterpretq_s64_s32(b1.val[0]), vreinterpretq_s64_s32(b3.val[0])));
    int16x8_t c5 = vreinterpretq_s16_s64(vtrn2q_s64(vreinterpretq_s64_s32(b1.val[0]), vreinterpretq_s64_s32(b3.val[0])));
    int16x8_t c3 = vreinterpretq_s16_s64(vtrn1q_s64(vreinterpretq_s64_s32(b1.val[1]), vreinterpretq_s64_s32(b3.val[1])));
    int16x8_t c7 = vreinterpretq_s16_s64(vtrn2q_s64(vreinterpretq_s64_s32(b1.val[1]), vreinterpretq_s64_s32(b3.val[1])));

    idct_4col_s16(vget_low_s16(c0), vget_low_s16(c1), vget_low_s16(c2), vget_low_s16(c3),
                  vget_low_s16(c4), vget_low_s16(c5), vget_low_s16(c6), vget_low_s16(c7),
                  &l0, &l1, &l2, &l3, &l4, &l5, &l6, &l7);
    idct_4col_s16(vget_high_s16(c0), vget_high_s16(c1), vget_high_s16(c2), vget_high_s16(c3),
                  vget_high_s16(c4), vget_high_s16(c5), vget_high_s16(c6), vget_high_s16(c7),
                  &h0, &h1, &h2, &h3, &h4, &h5, &h6, &h7);

    // (val + (1<<17)) >> 18 + 128 saturated to u8, using rounding shift 16 then >>2 after +128?
    // Keep exact + (1<<17), arithmetic >> 18 to match scalar descale bit-for-bit!
    const int32x4_t rbias = vdupq_n_s32((1 << 17) + (128 << 18));
    #define PACK_COL(LO, HI, U8) do { \
        int16x4_t p0 = vqmovn_s32(vshrq_n_s32(vaddq_s32((LO), rbias), 18)); \
        int16x4_t p1 = vqmovn_s32(vshrq_n_s32(vaddq_s32((HI), rbias), 18)); \
        (U8) = vqmovun_s16(vcombine_s16(p0, p1)); \
    } while (0)
    uint8x8_t u0, u1, u2, u3, u4, u5, u6, u7;
    PACK_COL(l0, h0, u0); PACK_COL(l1, h1, u1); PACK_COL(l2, h2, u2); PACK_COL(l3, h3, u3);
    PACK_COL(l4, h4, u4); PACK_COL(l5, h5, u5); PACK_COL(l6, h6, u6); PACK_COL(l7, h7, u7);
    #undef PACK_COL

    // Transpose 8x8 uint8x8_t columns back to rows for sequential output stores
    uint8x8x2_t t0 = vtrn_u8(u0, u1), t1 = vtrn_u8(u2, u3), t2 = vtrn_u8(u4, u5), t3 = vtrn_u8(u6, u7);
    uint16x4x2_t d0 = vtrn_u16(vreinterpret_u16_u8(t0.val[0]), vreinterpret_u16_u8(t1.val[0]));
    uint16x4x2_t d1 = vtrn_u16(vreinterpret_u16_u8(t0.val[1]), vreinterpret_u16_u8(t1.val[1]));
    uint16x4x2_t d2 = vtrn_u16(vreinterpret_u16_u8(t2.val[0]), vreinterpret_u16_u8(t3.val[0]));
    uint16x4x2_t d3 = vtrn_u16(vreinterpret_u16_u8(t2.val[1]), vreinterpret_u16_u8(t3.val[1]));
    uint32x2x2_t e0 = vtrn_u32(vreinterpret_u32_u16(d0.val[0]), vreinterpret_u32_u16(d2.val[0]));
    uint32x2x2_t e1 = vtrn_u32(vreinterpret_u32_u16(d1.val[0]), vreinterpret_u32_u16(d3.val[0]));
    uint32x2x2_t e2 = vtrn_u32(vreinterpret_u32_u16(d0.val[1]), vreinterpret_u32_u16(d2.val[1]));
    uint32x2x2_t e3 = vtrn_u32(vreinterpret_u32_u16(d1.val[1]), vreinterpret_u32_u16(d3.val[1]));

    vst1_u8(out + (ptrdiff_t)0 * out_stride, vreinterpret_u8_u32(e0.val[0]));
    vst1_u8(out + (ptrdiff_t)1 * out_stride, vreinterpret_u8_u32(e1.val[0]));
    vst1_u8(out + (ptrdiff_t)2 * out_stride, vreinterpret_u8_u32(e2.val[0]));
    vst1_u8(out + (ptrdiff_t)3 * out_stride, vreinterpret_u8_u32(e3.val[0]));
    vst1_u8(out + (ptrdiff_t)4 * out_stride, vreinterpret_u8_u32(e0.val[1]));
    vst1_u8(out + (ptrdiff_t)5 * out_stride, vreinterpret_u8_u32(e1.val[1]));
    vst1_u8(out + (ptrdiff_t)6 * out_stride, vreinterpret_u8_u32(e2.val[1]));
    vst1_u8(out + (ptrdiff_t)7 * out_stride, vreinterpret_u8_u32(e3.val[1]));
}

// libjpeg-turbo exact fancy 1D upsample on weighted vertical pair (3*cur + nbr) -> 2*cw pixels
static void h2v2_upsample_row(const uint8_t *cur, const uint8_t *nbr, int32_t cw, uint8_t *out, int32_t w) {
    if (cw == 1) {
        uint8_t v = (uint8_t)((3 * cur[0] + nbr[0] + 2) >> 2);
        out[0] = v;
        if (w > 1) out[1] = v;
        return;
    }
    int32_t thiscolsum = 3 * (int32_t)cur[0] + (int32_t)nbr[0];
    int32_t nextcolsum = 3 * (int32_t)cur[1] + (int32_t)nbr[1];
    out[0] = (uint8_t)((thiscolsum * 4 + 8) >> 4);
    if (w > 1) out[1] = (uint8_t)((thiscolsum * 3 + nextcolsum + 7) >> 4);
    int32_t x = 1;
    if (cw >= 18) {
        const uint16x8_t v8 = vdupq_n_u16(8), v7 = vdupq_n_u16(7);
        const uint8x8_t v3 = vdup_n_u8(3);
        int32_t limit = cw - 9;
        if (2 * limit + 16 > w) limit = (w - 16) / 2;
        for (; x + 8 <= limit; x += 8) {
            uint8x8_t c_m = vld1_u8(cur + x - 1), n_m = vld1_u8(nbr + x - 1);
            uint8x8_t c_c = vld1_u8(cur + x),     n_c = vld1_u8(nbr + x);
            uint8x8_t c_p = vld1_u8(cur + x + 1), n_p = vld1_u8(nbr + x + 1);
            uint16x8_t lm = vaddw_u8(vmull_u8(c_m, v3), n_m);
            uint16x8_t lc = vaddw_u8(vmull_u8(c_c, v3), n_c);
            uint16x8_t lp = vaddw_u8(vmull_u8(c_p, v3), n_p);
            uint16x8_t c3 = vaddq_u16(vshlq_n_u16(lc, 1), lc);
            uint8x8_t ev = vshrn_n_u16(vaddq_u16(vaddq_u16(c3, lm), v8), 4);
            uint8x8_t od = vshrn_n_u16(vaddq_u16(vaddq_u16(c3, lp), v7), 4);
            uint8x8x2_t pair = {{ev, od}};
            vst2_u8(out + (ptrdiff_t)x * 2, pair);
        }
    }
    int32_t lastcolsum = 3 * (int32_t)cur[x - 1] + (int32_t)nbr[x - 1];
    thiscolsum = 3 * (int32_t)cur[x] + (int32_t)nbr[x];
    for (; x < cw - 1; x++) {
        nextcolsum = 3 * (int32_t)cur[x + 1] + (int32_t)nbr[x + 1];
        int32_t dx = x * 2;
        if (dx < w) out[dx] = (uint8_t)((thiscolsum * 3 + lastcolsum + 8) >> 4);
        if (dx + 1 < w) out[dx + 1] = (uint8_t)((thiscolsum * 3 + nextcolsum + 7) >> 4);
        lastcolsum = thiscolsum;
        thiscolsum = nextcolsum;
    }
    int32_t dx = (cw - 1) * 2;
    if (dx < w) out[dx] = (uint8_t)((thiscolsum * 3 + lastcolsum + 8) >> 4);
    if (dx + 1 < w) out[dx + 1] = (uint8_t)((thiscolsum * 4 + 7) >> 4);
}

static void h2v1_upsample_row(const uint8_t *cur, int32_t cw, uint8_t *out, int32_t w) {
    if (cw == 1) {
        out[0] = cur[0];
        if (w > 1) out[1] = cur[0];
        return;
    }
    int32_t c0 = cur[0], c1 = cur[1];
    out[0] = (uint8_t)c0;
    if (w > 1) out[1] = (uint8_t)((c0 * 3 + c1 + 2) >> 2);
    for (int32_t x = 1; x < cw - 1; x++) {
        int32_t cm = cur[x - 1], cc = cur[x], cp = cur[x + 1];
        int32_t dx = x * 2;
        if (dx < w) out[dx] = (uint8_t)((cc * 3 + cm + 1) >> 2);
        if (dx + 1 < w) out[dx + 1] = (uint8_t)((cc * 3 + cp + 2) >> 2);
    }
    int32_t dx = (cw - 1) * 2;
    if (dx < w) out[dx] = (uint8_t)((cur[cw - 1] * 3 + cur[cw - 2] + 1) >> 2);
    if (dx + 1 < w) out[dx + 1] = cur[cw - 1];
}

// libjpeg-turbo BT.601 YCbCr -> BGR (or RGB if rgb_out != 0) using NEON (SCALEBITS=16)
static void ycbcr_to_bgr_row(const uint8_t *yp, const uint8_t *cbp, const uint8_t *crp,
                             uint8_t *dst, int32_t w, int rgb_out) {
    int32_t x = 0;
    const int16x8_t c128 = vdupq_n_s16(128);
    const int32x4_t cCrR = vdupq_n_s32(91881);
    const int32x4_t cCbG = vdupq_n_s32(22554);
    const int32x4_t cCrG = vdupq_n_s32(46802);
    const int32x4_t cCbB = vdupq_n_s32(116130);
    const int16x8_t c0 = vdupq_n_s16(0);

    for (; x + 8 <= w; x += 8) {
        int16x8_t y16 = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(yp + x)));
        int16x8_t cb = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(cbp + x))), c128);
        int16x8_t cr = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(crp + x))), c128);

        int32x4_t cr_lo = vmovl_s16(vget_low_s16(cr)), cr_hi = vmovl_s16(vget_high_s16(cr));
        int32x4_t cb_lo = vmovl_s16(vget_low_s16(cb)), cb_hi = vmovl_s16(vget_high_s16(cb));

        int16x8_t r_off = vcombine_s16(vrshrn_n_s32(vmulq_s32(cr_lo, cCrR), 16),
                                       vrshrn_n_s32(vmulq_s32(cr_hi, cCrR), 16));
        int16x8_t b_off = vcombine_s16(vrshrn_n_s32(vmulq_s32(cb_lo, cCbB), 16),
                                       vrshrn_n_s32(vmulq_s32(cb_hi, cCbB), 16));
        int32x4_t g_lo = vaddq_s32(vmulq_s32(cb_lo, cCbG), vmulq_s32(cr_lo, cCrG));
        int32x4_t g_hi = vaddq_s32(vmulq_s32(cb_hi, cCbG), vmulq_s32(cr_hi, cCrG));
        int16x8_t g_off = vcombine_s16(vrshrn_n_s32(g_lo, 16), vrshrn_n_s32(g_hi, 16));

        uint8x8_t R = vqmovun_s16(vmaxq_s16(c0, vaddq_s16(y16, r_off)));
        uint8x8_t G = vqmovun_s16(vmaxq_s16(c0, vsubq_s16(y16, g_off)));
        uint8x8_t B = vqmovun_s16(vmaxq_s16(c0, vaddq_s16(y16, b_off)));

        uint8x8x3_t out = rgb_out ? (uint8x8x3_t){{R, G, B}} : (uint8x8x3_t){{B, G, R}};
        vst3_u8(dst + (ptrdiff_t)x * 3, out);
    }
    for (; x < w; x++) {
        int32_t yv = yp[x];
        int32_t cb = (int32_t)cbp[x] - 128;
        int32_t cr = (int32_t)crp[x] - 128;
        int32_t r = yv + ((91881 * cr + 32768) >> 16);
        int32_t g = yv - ((22554 * cb + 46802 * cr + 32768) >> 16);
        int32_t b = yv + ((116130 * cb + 32768) >> 16);
        if (rgb_out) {
            dst[x * 3 + 0] = clamp_u8(r); dst[x * 3 + 1] = clamp_u8(g); dst[x * 3 + 2] = clamp_u8(b);
        } else {
            dst[x * 3 + 0] = clamp_u8(b); dst[x * 3 + 1] = clamp_u8(g); dst[x * 3 + 2] = clamp_u8(r);
        }
    }
}

int32_t sr_jpeg_decode_baseline(const uint8_t *data, size_t len,
                                int32_t *out_w, int32_t *out_h, int32_t *out_cn,
                                uint8_t *dst, ptrdiff_t dst_stride, int32_t want_cn) {
    if (!data || len < 4) return -1;
    if (data[0] != 0xFF || data[1] != 0xD8) return 1; // not JPEG

    uint16_t qt[4][64];
    int qt_ok[4] = {0, 0, 0, 0};
    huff_tab_t dc_ht[4], ac_ht[4];
    memset(dc_ht, 0, sizeof(dc_ht));
    memset(ac_ht, 0, sizeof(ac_ht));

    int32_t w = 0, h = 0, nf = 0;
    jpeg_comp_t comp[3];
    memset(comp, 0, sizeof(comp));
    int has_sof = 0, dri = 0, exif_orient = 1;
    int adobe_seen = 0, adobe_transform = -1;
    size_t pos = 2;
    size_t sos_data_off = 0;
    int sos_found = 0;

    while (pos < len) {
        while (pos < len && data[pos] != 0xFF) pos++;
        while (pos < len && data[pos] == 0xFF) pos++;
        if (pos >= len) break;
        uint8_t marker = data[pos++];
        if (marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7)) continue;
        if (marker == 0xD9) break; // EOI

        if (pos + 2 > len) return -1;
        uint16_t seg_len = rd_be16(data + pos);
        if (seg_len < 2 || pos + seg_len > len) return -1;
        const uint8_t *seg = data + pos + 2;
        size_t slen = (size_t)seg_len - 2;
        pos += seg_len;

        if (marker == 0xC0) { // SOF0 (Baseline DCT)
            if (has_sof || slen < 6) return 1;
            if (seg[0] != 8) return 1;
            h = rd_be16(seg + 1);
            w = rd_be16(seg + 3);
            nf = seg[5];
            if (w <= 0 || h <= 0) return -1;
            if ((uint64_t)w * (uint64_t)h > (1ULL << 30)) return -2;
            if ((nf != 1 && nf != 3) || slen != (size_t)(6 + 3 * nf)) return 1;
            for (int i = 0; i < nf; i++) {
                comp[i].id = seg[6 + 3 * i];
                comp[i].hs = seg[6 + 3 * i + 1] >> 4;
                comp[i].vs = seg[6 + 3 * i + 1] & 0xF;
                comp[i].qt_id = seg[6 + 3 * i + 2];
                if (comp[i].hs < 1 || comp[i].hs > 2 || comp[i].vs < 1 || comp[i].vs > 2 || comp[i].qt_id > 3) return 1;
            }
            if (nf == 3) {
                if (comp[1].hs != 1 || comp[1].vs != 1 || comp[2].hs != 1 || comp[2].vs != 1) return 1;
                if (comp[0].id == 'R' && comp[1].id == 'G' && comp[2].id == 'B') return 1;
            }
            has_sof = 1;
        } else if ((marker >= 0xC1 && marker <= 0xC3) || (marker >= 0xC5 && marker <= 0xCF && marker != 0xC4 && marker != 0xCC)) {
            return 1; // progressive / extended / lossless / arithmetic -> ImageIO fallback
        } else if (marker == 0xC4) { // DHT
            size_t off = 0;
            while (off < slen) {
                if (off + 17 > slen) return -1;
                int tc = seg[off] >> 4, th = seg[off] & 0xF;
                if (tc > 1 || th > 3) return 1;
                const uint8_t *bits = seg + off + 1;
                int cnt = 0;
                for (int i = 0; i < 16; i++) cnt += bits[i];
                off += 17;
                if (off + (size_t)cnt > slen) return -1;
                huff_tab_t *ht = (tc == 0) ? &dc_ht[th] : &ac_ht[th];
                if (build_huff(ht, bits, seg + off, cnt) != 0) return -1;
                off += (size_t)cnt;
            }
        } else if (marker == 0xDB) { // DQT
            size_t off = 0;
            while (off < slen) {
                int pq = seg[off] >> 4, tq = seg[off] & 0xF;
                if (pq != 0 || tq > 3) return 1; // 16-bit DQT -> ImageIO
                off++;
                if (off + 64 > slen) return -1;
                for (int k = 0; k < 64; k++) qt[tq][k] = seg[off + k];
                qt_ok[tq] = 1;
                off += 64;
            }
        } else if (marker == 0xDD) { // DRI
            if (slen < 2) return -1;
            dri = rd_be16(seg);
        } else if (marker == 0xE1) { // APP1 Exif
            int32_t o = parse_exif_orientation(seg, slen);
            if (o != 1) exif_orient = o;
        } else if (marker == 0xEE) { // APP14 Adobe
            if (slen >= 12 && memcmp(seg, "Adobe", 5) == 0) {
                adobe_seen = 1;
                adobe_transform = seg[11];
            }
        } else if (marker == 0xDA) { // SOS
            if (!has_sof || slen < (size_t)(4 + 2 * nf)) return 1;
            int ns = seg[0];
            if (ns != nf || slen != (size_t)(4 + 2 * ns)) return 1; // multi-scan -> ImageIO
            for (int i = 0; i < ns; i++) {
                int cid = seg[1 + 2 * i];
                int td = seg[2 + 2 * i] >> 4, ta = seg[2 + 2 * i] & 0xF;
                if (td > 3 || ta > 3 || cid != comp[i].id) return 1;
                comp[i].dc_id = td; comp[i].ac_id = ta;
            }
            if (seg[1 + 2 * ns] != 0 || seg[2 + 2 * ns] != 63 || seg[3 + 2 * ns] != 0) return 1;
            sos_data_off = pos;
            sos_found = 1;
            break;
        }
    }

    if (!has_sof || !sos_found) return 1;
    if (adobe_seen && nf == 3 && adobe_transform != 1) return 1; // Adobe raw RGB -> ImageIO
    if (exif_orient != 1) return 1; // Let IOCodec handle EXIF orientation (or fallback when orientation != 1)
    for (int i = 0; i < nf; i++) {
        if (!qt_ok[comp[i].qt_id] || !dc_ht[comp[i].dc_id].valid || !ac_ht[comp[i].ac_id].valid) return 1;
    }

    if (out_w) *out_w = w;
    if (out_h) *out_h = h;
    if (out_cn) *out_cn = nf;
    if (!dst) return 0; // Header probe only!

    // Decode baseline scan into dst (want_cn: 1 = gray, 3 = BGR, -3 = RGB)
    const int want_gray = (want_cn == 1);
    const int rgb_out = (want_cn == -3);
    const int32_t hs = comp[0].hs, vs = comp[0].vs;
    const int32_t mcu_w = hs * 8, mcu_h = vs * 8;
    const int32_t n_mcux = (w + mcu_w - 1) / mcu_w;
    const int32_t n_mcuy = (h + mcu_h - 1) / mcu_h;
    const int32_t y_stride = n_mcux * mcu_w;
    const int32_t cw = n_mcux * 8;

    // 1-MCU-row delay strip buffers (~100 KiB for 1080p)
    uint8_t *y_cur = (uint8_t *)malloc((size_t)y_stride * (size_t)mcu_h);
    uint8_t *y_next = (uint8_t *)malloc((size_t)y_stride * (size_t)mcu_h);
    uint8_t *cb_cur = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)cw * 8) : NULL;
    uint8_t *cb_next = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)cw * 8) : NULL;
    uint8_t *cr_cur = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)cw * 8) : NULL;
    uint8_t *cr_next = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)cw * 8) : NULL;
    uint8_t *cb_prev_row = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)cw) : NULL;
    uint8_t *cr_prev_row = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)cw) : NULL;
    uint8_t *cb_up = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)w + 16) : NULL;
    uint8_t *cr_up = (nf == 3 && !want_gray) ? (uint8_t *)malloc((size_t)w + 16) : NULL;

    if (!y_cur || !y_next || (nf == 3 && !want_gray && (!cb_cur || !cb_next || !cr_cur || !cr_next || !cb_prev_row || !cr_prev_row || !cb_up || !cr_up))) {
        free(y_cur); free(y_next); free(cb_cur); free(cb_next); free(cr_cur); free(cr_next);
        free(cb_prev_row); free(cr_prev_row); free(cb_up); free(cr_up);
        return -1;
    }

    bitread_t br;
    br_init(&br, data + sos_data_off, data + len);
    int32_t mcu_idx = 0;
    int status = 0;

    // Decode MCU row `my` into `(yb, cbb, crb)`
    #define DECODE_MCU_ROW(my, yb, cbb, crb) do { \
        for (int32_t mx = 0; mx < n_mcux && status == 0; mx++) { \
            if (dri > 0 && mcu_idx > 0 && (mcu_idx % dri) == 0) { \
                /* Byte-align & consume RST0..RST7 */ \
                int rem = br.bitcnt & 7; \
                if (rem) br_drop(&br, rem); \
                /* Look for RST marker in stream */ \
                while (br.p < br.end && br.p[0] != 0xFF) br.p++; \
                if (br.p + 1 < br.end && br.p[0] == 0xFF && br.p[1] >= 0xD0 && br.p[1] <= 0xD7) { \
                    br.p += 2; br.buf64 = 0; br.bitcnt = 0; br.eof_or_marker = 0; \
                } \
                comp[0].dc_pred = comp[1].dc_pred = comp[2].dc_pred = 0; \
            } \
            for (int32_t bv = 0; bv < vs && status == 0; bv++) { \
                for (int32_t bh = 0; bh < hs && status == 0; bh++) { \
                    int16_t blk[64]; \
                    int32_t nz = 0; \
                    if (decode_block(&br, &dc_ht[comp[0].dc_id], &ac_ht[comp[0].ac_id], \
                                     qt[comp[0].qt_id], &comp[0].dc_pred, blk, 0, &nz) != 0) { status = 1; break; } \
                    idct_8x8_int(blk, (yb) + (ptrdiff_t)(bv * 8) * y_stride + (mx * hs + bh) * 8, y_stride, nz); \
                } \
            } \
            if (nf == 3 && status == 0) { \
                int16_t blk[64]; \
                int skip = want_gray; \
                int32_t nz1 = 0, nz2 = 0; \
                if (decode_block(&br, &dc_ht[comp[1].dc_id], &ac_ht[comp[1].ac_id], \
                                 qt[comp[1].qt_id], &comp[1].dc_pred, blk, skip, &nz1) != 0) { status = 1; break; } \
                if (!skip) idct_8x8_int(blk, (cbb) + (ptrdiff_t)mx * 8, cw, nz1); \
                if (decode_block(&br, &dc_ht[comp[2].dc_id], &ac_ht[comp[2].ac_id], \
                                 qt[comp[2].qt_id], &comp[2].dc_pred, blk, skip, &nz2) != 0) { status = 1; break; } \
                if (!skip) idct_8x8_int(blk, (crb) + (ptrdiff_t)mx * 8, cw, nz2); \
            } \
            mcu_idx++; \
        } \
    } while (0)

    if (nf == 1 || want_gray) {
        for (int32_t my = 0; my < n_mcuy && status == 0; my++) {
            DECODE_MCU_ROW(my, y_cur, cb_cur, cr_cur);
            if (status != 0) break;
            int32_t y0 = my * mcu_h;
            int32_t y1 = y0 + mcu_h < h ? y0 + mcu_h : h;
            for (int32_t r = y0; r < y1; r++) {
                const uint8_t *ys = y_cur + (ptrdiff_t)(r - y0) * y_stride;
                if (want_gray) {
                    memcpy(dst + (ptrdiff_t)r * dst_stride, ys, (size_t)w);
                } else {
                    // nf == 1 grayscale JPEG decoded as 3-channel BGR/RGB
                    uint8_t *d = dst + (ptrdiff_t)r * dst_stride;
                    int32_t x = 0;
                    for (; x + 16 <= w; x += 16) {
                        uint8x16_t v = vld1q_u8(ys + x);
                        uint8x16x3_t q = {{v, v, v}};
                        vst3q_u8(d + (ptrdiff_t)x * 3, q);
                    }
                    for (; x < w; x++) { uint8_t v = ys[x]; d[x*3] = d[x*3+1] = d[x*3+2] = v; }
                }
            }
        }
    } else {
        // Color 3-channel YCbCr -> BGR(RGB) with 1-MCU-row delay for smooth vertical chroma upsampling
        DECODE_MCU_ROW(0, y_cur, cb_cur, cr_cur);
        if (status == 0) {
            memcpy(cb_prev_row, cb_cur, (size_t)cw);
            memcpy(cr_prev_row, cr_cur, (size_t)cw);
            const int32_t chroma_h = (h + vs - 1) / vs;
            const int32_t chroma_w = (w + hs - 1) / hs;
            for (int32_t my = 0; my < n_mcuy && status == 0; my++) {
                int has_next = (my + 1 < n_mcuy);
                if (has_next) {
                    DECODE_MCU_ROW(my + 1, y_next, cb_next, cr_next);
                    if (status != 0) break;
                }
                int32_t y0 = my * mcu_h;
                int32_t y1 = y0 + mcu_h < h ? y0 + mcu_h : h;
                for (int32_t r = y0; r < y1; r++) {
                    const uint8_t *yp = y_cur + (ptrdiff_t)(r - y0) * y_stride;
                    uint8_t *dr = dst + (ptrdiff_t)r * dst_stride;
                    if (hs == 1 && vs == 1) {
                        ycbcr_to_bgr_row(yp, cb_cur + (ptrdiff_t)(r - y0) * cw, cr_cur + (ptrdiff_t)(r - y0) * cw,
                                         dr, w, rgb_out);
                    } else if (hs == 2 && vs == 1) {
                        h2v1_upsample_row(cb_cur + (ptrdiff_t)(r - y0) * cw, chroma_w, cb_up, w);
                        h2v1_upsample_row(cr_cur + (ptrdiff_t)(r - y0) * cw, chroma_w, cr_up, w);
                        ycbcr_to_bgr_row(yp, cb_up, cr_up, dr, w, rgb_out);
                    } else if (hs == 1 && vs == 2) {
                        int32_t cy = r >> 1;
                        int32_t cy_in = cy & 7;
                        const uint8_t *cc = cb_cur + (ptrdiff_t)cy_in * cw;
                        const uint8_t *rc = cr_cur + (ptrdiff_t)cy_in * cw;
                        const uint8_t *cnbr, *rnbr;
                        if ((r & 1) == 0) {
                            cnbr = cy_in > 0 ? cb_cur + (ptrdiff_t)(cy_in - 1) * cw : cb_prev_row;
                            rnbr = cy_in > 0 ? cr_cur + (ptrdiff_t)(cy_in - 1) * cw : cr_prev_row;
                        } else if (cy + 1 >= chroma_h) {
                            cnbr = cc; rnbr = rc;
                        } else if (cy_in < 7) {
                            cnbr = cb_cur + (ptrdiff_t)(cy_in + 1) * cw;
                            rnbr = cr_cur + (ptrdiff_t)(cy_in + 1) * cw;
                        } else {
                            cnbr = has_next ? cb_next : cc;
                            rnbr = has_next ? cr_next : rc;
                        }
                        for (int32_t x = 0; x < w; x++) {
                            cb_up[x] = (uint8_t)((3 * cc[x] + cnbr[x] + ((r & 1) ? 2 : 1)) >> 2);
                            cr_up[x] = (uint8_t)((3 * rc[x] + rnbr[x] + ((r & 1) ? 2 : 1)) >> 2);
                        }
                        ycbcr_to_bgr_row(yp, cb_up, cr_up, dr, w, rgb_out);
                    } else { // hs == 2 && vs == 2 (4:2:0 fancy upsampling)
                        int32_t cy = r >> 1;
                        int32_t cy_in = cy & 7;
                        const uint8_t *cc = cb_cur + (ptrdiff_t)cy_in * cw;
                        const uint8_t *rc = cr_cur + (ptrdiff_t)cy_in * cw;
                        const uint8_t *cnbr, *rnbr;
                        if ((r & 1) == 0) {
                            cnbr = cy_in > 0 ? cb_cur + (ptrdiff_t)(cy_in - 1) * cw : cb_prev_row;
                            rnbr = cy_in > 0 ? cr_cur + (ptrdiff_t)(cy_in - 1) * cw : cr_prev_row;
                        } else if (cy + 1 >= chroma_h) {
                            cnbr = cc; rnbr = rc;
                        } else if (cy_in < 7) {
                            cnbr = cb_cur + (ptrdiff_t)(cy_in + 1) * cw;
                            rnbr = cr_cur + (ptrdiff_t)(cy_in + 1) * cw;
                        } else {
                            cnbr = has_next ? cb_next : cc;
                            rnbr = has_next ? cr_next : rc;
                        }
                        h2v2_upsample_row(cc, cnbr, chroma_w, cb_up, w);
                        h2v2_upsample_row(rc, rnbr, chroma_w, cr_up, w);
                        ycbcr_to_bgr_row(yp, cb_up, cr_up, dr, w, rgb_out);
                    }
                }
                if (has_next) {
                    memcpy(cb_prev_row, cb_cur + 7 * (ptrdiff_t)cw, (size_t)cw);
                    memcpy(cr_prev_row, cr_cur + 7 * (ptrdiff_t)cw, (size_t)cw);
                    uint8_t *yt = y_cur; y_cur = y_next; y_next = yt;
                    uint8_t *ct = cb_cur; cb_cur = cb_next; cb_next = ct;
                    uint8_t *rt = cr_cur; cr_cur = cr_next; cr_next = rt;
                }
            }
        }
    }
    #undef DECODE_MCU_ROW

    free(y_cur); free(y_next); free(cb_cur); free(cb_next); free(cr_cur); free(cr_next);
    free(cb_prev_row); free(cr_prev_row); free(cb_up); free(cr_up);
    return status;
}
