// clhash_portable.c — self-contained portable CL hash for VerusHash 2.2.
//
// Extracted from verus_clhash_portable.cpp, stripped of VerusCoin
// wallet dependencies. Provides verusclhash_sv2_2_port() and all
// supporting emulated SSE operations.
//
// Used by Phase 1c to benchmark the Full Finalize2b() mining pipeline.

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stddef.h>

// ---- emulated SSE types ----

typedef struct { uint64_t m[2]; } emu128_t;
typedef struct { uint8_t  m[16]; } emu128b_t;

// ---- clmul64: 64-bit carry-less multiplication (PCLMUL emulation) ----

static void clmul64(uint64_t a, uint64_t b, uint64_t *r) {
    uint8_t s = 4;
    uint64_t two_s = 1ULL << s;
    uint64_t smask = two_s - 1;
    uint64_t u[16];
    u[0] = 0;
    u[1] = b;
    int i;
    for (i = 2; i < (int)two_s; i += 2) {
        u[i] = u[i >> 1] << 1;
        u[i + 1] = u[i] ^ b;
    }
    r[0] = u[a & smask];
    r[1] = 0;
    for (i = s; i < 64; i += s) {
        uint64_t tmp = u[(a >> i) & smask];
        r[0] ^= tmp << i;
        r[1] ^= tmp >> (64 - i);
    }
    uint64_t m = 0xEEEEEEEEEEEEEEEEULL;
    for (i = 1; i < (int)s; i++) {
        uint64_t tmp = ((a & m) >> i);
        m &= m << 1;
        int64_t ifmask = -((b >> (64 - i)) & 1);
        r[1] ^= (tmp & (uint64_t)ifmask);
    }
}

// ---- emulated SSE wrappers ----

static inline emu128_t clmulepi64_emu(emu128_t a, emu128_t b, int imm) {
    uint64_t result[2];
    clmul64(a.m[imm & 1], b.m[(imm & 0x10) >> 4], result);
    emu128_t r;
    r.m[0] = result[0];
    r.m[1] = result[1];
    return r;
}

static inline emu128_t mulhrs_epi16_emu(emu128_t _a, emu128_t _b) {
    int16_t *a = (int16_t *)&_a, *b = (int16_t *)&_b;
    int16_t result[8];
    int i;
    for (i = 0; i < 8; i++)
        result[i] = (int16_t)((((int32_t)a[i] * (int32_t)b[i]) + 0x4000) >> 15);
    emu128_t r;
    memcpy(&r, result, 16);
    return r;
}

static inline emu128_t set_epi64x_emu(uint64_t hi, uint64_t lo) {
    emu128_t r; r.m[0] = lo; r.m[1] = hi; return r;
}
static inline emu128_t cvtsi64_si128_emu(uint64_t lo) {
    emu128_t r; r.m[0] = lo; r.m[1] = 0; return r;
}
static inline int64_t  cvtsi128_si64_emu(emu128_t a) { return (int64_t)a.m[0]; }
static inline int32_t  cvtsi128_si32_emu(emu128_t a) { return (int32_t)a.m[0]; }
static inline emu128_t cvtsi32_si128_emu(uint32_t lo) {
    emu128_t r; memset(&r, 0, 16); ((uint32_t *)&r)[0] = lo; return r;
}
static inline emu128_t setr_epi8_emu(uint8_t c0,uint8_t c1,uint8_t c2,uint8_t c3,
    uint8_t c4,uint8_t c5,uint8_t c6,uint8_t c7,uint8_t c8,uint8_t c9,
    uint8_t c10,uint8_t c11,uint8_t c12,uint8_t c13,uint8_t c14,uint8_t c15) {
    emu128b_t r;
    uint8_t vals[16] = {c0,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14,c15};
    memcpy(r.m, vals, 16);
    return *(emu128_t *)&r;
}
static inline emu128_t srli_si128_emu(emu128_t a, int imm8) {
    uint8_t shift = imm8 & 0xff;
    if (shift > 15) shift = 16;
    unsigned char *src = (unsigned char *)&a;
    emu128b_t r;
    int i;
    for (i = 0; i < (16 - shift); i++) r.m[i] = src[shift + i];
    for (; i < 16; i++) r.m[i] = 0;
    return *(emu128_t *)&r;
}
static inline emu128_t xor_si128_emu(emu128_t a, emu128_t b) {
    emu128_t r; r.m[0] = a.m[0] ^ b.m[0]; r.m[1] = a.m[1] ^ b.m[1]; return r;
}
static inline emu128_t load_si128_emu(const void *p) { return *(emu128_t *)p; }
static inline void     store_si128_emu(void *p, emu128_t val) { *(emu128_t *)p = val; }
static inline emu128_t shuffle_epi8_emu(emu128_t a, emu128_t b) {
    emu128b_t result;
    uint8_t *ab = (uint8_t *)&a, *bb = (uint8_t *)&b;
    int i;
    for (i = 0; i < 16; i++)
        result.m[i] = (bb[i] & 0x80) ? 0 : ab[bb[i] & 0xf];
    return *(emu128_t *)&result;
}
static inline emu128_t unpacklo_epi32_emu(emu128_t a, emu128_t b) {
    uint32_t *ta = (uint32_t *)&a, *tb = (uint32_t *)&b;
    emu128_t r; uint32_t *tr = (uint32_t *)&r;
    tr[0] = ta[0]; tr[1] = tb[0]; tr[2] = ta[1]; tr[3] = tb[1];
    return r;
}
static inline emu128_t unpackhi_epi32_emu(emu128_t a, emu128_t b) {
    uint32_t *ta = (uint32_t *)&a, *tb = (uint32_t *)&b;
    emu128_t r; uint32_t *tr = (uint32_t *)&r;
    tr[0] = ta[2]; tr[1] = tb[2]; tr[2] = ta[3]; tr[3] = tb[3];
    return r;
}

// ---- AES/S-box emulation for the MIX2 path (verus_clhash case 0x10/0x14) ----

static const uint8_t sbox[256] = {
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16
};

// AES round constants for the Haraka portable path (40 × 16 bytes)
static const unsigned char haraka_rc_port[40][16] = {
    {0x9d,0x7b,0x81,0x75,0xf0,0xfe,0xc5,0xb2,0x0a,0xc0,0x20,0xe6,0x4c,0x70,0x84,0x06},
    {0x17,0xf7,0x08,0x2f,0xa4,0x6b,0x0f,0x64,0x6b,0xa0,0xf3,0x88,0xe1,0xb4,0x66,0x8b},
    {0x14,0x91,0x02,0x9f,0x60,0x9d,0x02,0xcf,0x98,0x84,0xf2,0x53,0x2d,0xde,0x02,0x34},
    {0x79,0x4f,0x5b,0xfd,0xaf,0xbc,0xf3,0xbb,0x08,0x4f,0x7b,0x2e,0xe6,0xea,0xd6,0x0e},
    {0x44,0x70,0x39,0xbe,0x1c,0xcd,0xee,0x79,0x8b,0x44,0x72,0x48,0xcb,0xb0,0xcf,0xcb},
    {0x7b,0x05,0x8a,0x2b,0xed,0x35,0x53,0x8d,0xb7,0x32,0x90,0x6e,0xee,0xcd,0xea,0x7e},
    {0x1b,0xef,0x4f,0xda,0x61,0x27,0x41,0xe2,0xd0,0x7c,0x2e,0x5e,0x43,0x8f,0xc2,0x67},
    {0x3b,0x0b,0xc7,0x1f,0xe2,0xfd,0x5f,0x67,0x07,0xcc,0xca,0xaf,0xb0,0xd9,0x24,0x29},
    {0xee,0x65,0xd4,0xb9,0xca,0x8f,0xdb,0xec,0xe9,0x7f,0x86,0xe6,0xf1,0x63,0x4d,0xab},
    {0x33,0x7e,0x03,0xad,0x4f,0x40,0x2a,0x5b,0x64,0xcd,0xb7,0xd4,0x84,0xbf,0x30,0x1c},
    {0x00,0x98,0xf6,0x8d,0x2e,0x8b,0x02,0x69,0xbf,0x23,0x17,0x94,0xb9,0x0b,0xcc,0xb2},
    {0x8a,0x2d,0x9d,0x5c,0xc8,0x9e,0xaa,0x4a,0x72,0x55,0x6f,0xde,0xa6,0x78,0x04,0xfa},
    {0xd4,0x9f,0x12,0x29,0x2e,0x4f,0xfa,0x0e,0x12,0x2a,0x77,0x6b,0x2b,0x9f,0xb4,0xdf},
    {0xee,0x12,0x6a,0xbb,0xae,0x11,0xd6,0x32,0x36,0xa2,0x49,0xf4,0x44,0x03,0xa1,0x1e},
    {0xa6,0xec,0xa8,0x9c,0xc9,0x00,0x96,0x5f,0x84,0x00,0x05,0x4b,0x88,0x49,0x04,0xaf},
    {0xec,0x93,0xe5,0x27,0xe3,0xc7,0xa2,0x78,0x4f,0x9c,0x19,0x9d,0xd8,0x5e,0x02,0x21},
    {0x73,0x01,0xd4,0x82,0xcd,0x2e,0x28,0xb9,0xb7,0xc9,0x59,0xa7,0xf8,0xaa,0x3a,0xbf},
    {0x6b,0x7d,0x30,0x10,0xd9,0xef,0xf2,0x37,0x17,0xb0,0x86,0x61,0x0d,0x70,0x60,0x62},
    {0xc6,0x9a,0xfc,0xf6,0x53,0x91,0xc2,0x81,0x43,0x04,0x30,0x21,0xc2,0x45,0xca,0x5a},
    {0x3a,0x94,0xd1,0x36,0xe8,0x92,0xaf,0x2c,0xbb,0x68,0x6b,0x22,0x3c,0x97,0x23,0x92},
    {0xb4,0x71,0x10,0xe5,0x58,0xb9,0xba,0x6c,0xeb,0x86,0x58,0x22,0x38,0x92,0xbf,0xd3},
    {0x8d,0x12,0xe1,0x24,0xdd,0xfd,0x3d,0x93,0x77,0xc6,0xf0,0xae,0xe5,0x3c,0x86,0xdb},
    {0xb1,0x12,0x22,0xcb,0xe3,0x8d,0xe4,0x83,0x9c,0xa0,0xeb,0xff,0x68,0x62,0x60,0xbb},
    {0x7d,0xf7,0x2b,0xc7,0x4e,0x1a,0xb9,0x2d,0x9c,0xd1,0xe4,0xe2,0xdc,0xd3,0x4b,0x73},
    {0x4e,0x92,0xb3,0x2c,0xc4,0x15,0x14,0x4b,0x43,0x1b,0x30,0x61,0xc3,0x47,0xbb,0x43},
    {0x99,0x68,0xeb,0x16,0xdd,0x31,0xb2,0x03,0xf6,0xef,0x07,0xe7,0xa8,0x75,0xa7,0xdb},
    {0x2c,0x47,0xca,0x7e,0x02,0x23,0x5e,0x8e,0x77,0x59,0x75,0x3c,0x4b,0x61,0xf3,0x6d},
    {0xf9,0x17,0x86,0xb8,0xb9,0xe5,0x1b,0x6d,0x77,0x7d,0xde,0xd6,0x17,0x5a,0xa7,0xcd},
    {0x5d,0xee,0x46,0xa9,0x9d,0x06,0x6c,0x9d,0xaa,0xe9,0xa8,0x6b,0xf0,0x43,0x6b,0xec},
    {0xc1,0x27,0xf3,0x3b,0x59,0x11,0x53,0xa2,0x2b,0x33,0x57,0xf9,0x50,0x69,0x1e,0xcb},
    {0xd9,0xd0,0x0e,0x60,0x53,0x03,0xed,0xe4,0x9c,0x61,0xda,0x00,0x75,0x0c,0xee,0x2c},
    {0x50,0xa3,0xa4,0x63,0xbc,0xba,0xbb,0x80,0xab,0x0c,0xe9,0x96,0xa1,0xa5,0xb1,0xf0},
    {0x39,0xca,0x8d,0x93,0x30,0xde,0x0d,0xab,0x88,0x29,0x96,0x5e,0x02,0xb1,0x3d,0xae},
    {0x42,0xb4,0x75,0x2e,0xa8,0xf3,0x14,0x88,0x0b,0xa4,0x54,0xd5,0x38,0x8f,0xbb,0x17},
    {0xf6,0x16,0x0a,0x36,0x79,0xb7,0xb6,0xae,0xd7,0x7f,0x42,0x5f,0x5b,0x8a,0xbb,0x34},
    {0xde,0xaf,0xba,0xff,0x18,0x59,0xce,0x43,0x38,0x54,0xe5,0xcb,0x41,0x52,0xf6,0x26},
    {0x78,0xc9,0x9e,0x83,0xf7,0x9c,0xca,0xa2,0x6a,0x02,0xf3,0xb9,0x54,0x9a,0xe9,0x4c},
    {0x35,0x12,0x90,0x22,0x28,0x6e,0xc0,0x40,0xbe,0xf7,0xdf,0x1b,0x1a,0xa5,0x51,0xae},
    {0xcf,0x59,0xa6,0x48,0x0f,0xbc,0x73,0xc1,0x2b,0xd2,0x7e,0xba,0x3c,0x61,0xc1,0xa0},
    {0xa1,0x9d,0xc5,0xe9,0xfd,0xbd,0xd6,0x4a,0x88,0x82,0x28,0x02,0x03,0xcc,0x6a,0x75}
};

static void aesenc_emu(unsigned char *s, const unsigned char *rk) {
    uint32_t x0 = ((uint32_t*)s)[0];
    uint32_t x1 = ((uint32_t*)s)[1];
    uint32_t x2 = ((uint32_t*)s)[2];
    uint32_t x3 = ((uint32_t*)s)[3];
    uint32_t y0, y1, y2, y3;

    #define XT(x) (((x) << 1) ^ ((((x) >> 7) & 1) * 0x1b))

    // SubBytes + ShiftRows
    y0 = ((uint32_t)sbox[x0 & 0xff])
       | ((uint32_t)sbox[(x1 >> 8) & 0xff] << 8)
       | ((uint32_t)sbox[(x2 >> 16) & 0xff] << 16)
       | ((uint32_t)sbox[x3 >> 24] << 24);
    y1 = ((uint32_t)sbox[x1 & 0xff])
       | ((uint32_t)sbox[(x2 >> 8) & 0xff] << 8)
       | ((uint32_t)sbox[(x3 >> 16) & 0xff] << 16)
       | ((uint32_t)sbox[x0 >> 24] << 24);
    y2 = ((uint32_t)sbox[x2 & 0xff])
       | ((uint32_t)sbox[(x3 >> 8) & 0xff] << 8)
       | ((uint32_t)sbox[(x0 >> 16) & 0xff] << 16)
       | ((uint32_t)sbox[x1 >> 24] << 24);
    y3 = ((uint32_t)sbox[x3 & 0xff])
       | ((uint32_t)sbox[(x0 >> 8) & 0xff] << 8)
       | ((uint32_t)sbox[(x1 >> 16) & 0xff] << 16)
       | ((uint32_t)sbox[x2 >> 24] << 24);

    // MixColumns
    ((uint32_t*)s)[0] = y0
        ^ XT(y0 ^ y1) ^ y1 ^ y2 ^ y3
        ^ XT(y3 ^ y0)  // cancels
        ^ ((uint32_t*)rk)[0];
    ((uint32_t*)s)[1] = y1
        ^ XT(y1 ^ y2) ^ y2 ^ y3 ^ y0
        ^ XT(y0 ^ y1)
        ^ ((uint32_t*)rk)[1];
    ((uint32_t*)s)[2] = y2
        ^ XT(y2 ^ y3) ^ y3 ^ y0 ^ y1
        ^ XT(y1 ^ y2)
        ^ ((uint32_t*)rk)[2];
    ((uint32_t*)s)[3] = y3
        ^ XT(y3 ^ y0) ^ y0 ^ y1 ^ y2
        ^ XT(y2 ^ y3)
        ^ ((uint32_t*)rk)[3];

    #undef XT
}

// ---- MIX2_EMU (Haraka mixing layer) ----

#define MIX2_EMU(s0, s1) do { \
    emu128_t tmp_ = unpacklo_epi32_emu(s0, s1); \
    s1 = unpackhi_epi32_emu(s0, s1); \
    s0 = tmp_; \
} while(0)

// AES2_EMU: 4 AES rounds with the Haraka portable round constants
#define AES2_EMU(s0, s1, rci) do { \
    aesenc_emu((unsigned char *)&s0, haraka_rc_port[rci]); \
    aesenc_emu((unsigned char *)&s1, haraka_rc_port[rci + 1]); \
    aesenc_emu((unsigned char *)&s0, haraka_rc_port[rci + 2]); \
    aesenc_emu((unsigned char *)&s1, haraka_rc_port[rci + 3]); \
} while(0)

// ---- CL hash core: lazyLengthHash + precompReduction ----

static emu128_t lazyLengthHash_port(uint64_t keylength, uint64_t length) {
    emu128_t lv = set_epi64x_emu(keylength, length);
    return clmulepi64_emu(lv, lv, 0x10);
}

static emu128_t precompReduction64_si128_port(emu128_t A) {
    emu128_t C = cvtsi64_si128_emu((1U<<4)+(1U<<3)+(1U<<1)+(1U<<0));
    emu128_t Q2 = clmulepi64_emu(A, C, 0x01);
    emu128_t Q3 = shuffle_epi8_emu(
        setr_epi8_emu(0,27,54,45,108,119,90,65,
                      (char)216,(char)195,(char)238,(char)245,(char)180,(char)175,(char)130,(char)153),
        srli_si128_emu(Q2, 8));
    emu128_t Q4 = xor_si128_emu(Q2, A);
    return xor_si128_emu(Q3, Q4);
}

static uint64_t precompReduction64_port(emu128_t A) {
    return (uint64_t)cvtsi128_si64_emu(precompReduction64_si128_port(A));
}

// ---- CL hash main loop (SV2_2 variant, current VerusHash 2.2) ----

static emu128_t verusclmul_sv2_2_port(
    emu128_t *randomsource, const emu128_t buf[4],
    uint64_t keyMask, emu128_t **pMoveScratch)
{
    const emu128_t pbuf_copy[4] = {
        xor_si128_emu(buf[0], buf[2]),
        xor_si128_emu(buf[1], buf[3]),
        buf[2], buf[3]
    };
    const emu128_t *pbuf;

    keyMask >>= 4;

    emu128_t acc = load_si128_emu(randomsource + (keyMask + 2));

    for (int64_t i = 0; i < 32; i++) {
        const uint64_t selector = (uint64_t)cvtsi128_si64_emu(acc);
        emu128_t *prand = randomsource + ((selector >> 5) & keyMask);
        emu128_t *prandex = randomsource + ((selector >> 32) & keyMask);

        *pMoveScratch++ = prand;
        *pMoveScratch++ = prandex;

        pbuf = pbuf_copy + (selector & 3);

        switch (selector & 0x1c) {
            case 0: {
                emu128_t temp1 = load_si128_emu(prandex);
                emu128_t temp2 = load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                emu128_t add1 = xor_si128_emu(temp1, temp2);
                emu128_t clprod1 = clmulepi64_emu(add1, add1, 0x10);
                acc = xor_si128_emu(clprod1, acc);

                emu128_t tempa1 = mulhrs_epi16_emu(acc, temp1);
                emu128_t tempa2 = xor_si128_emu(tempa1, temp1);

                emu128_t temp12 = load_si128_emu(prand);
                store_si128_emu(prand, tempa2);

                emu128_t temp22 = load_si128_emu(pbuf);
                emu128_t add12 = xor_si128_emu(temp12, temp22);
                emu128_t clprod12 = clmulepi64_emu(add12, add12, 0x10);
                acc = xor_si128_emu(clprod12, acc);

                emu128_t tempb1 = mulhrs_epi16_emu(acc, temp12);
                emu128_t tempb2 = xor_si128_emu(tempb1, temp12);
                store_si128_emu(prandex, tempb2);
                break;
            }
            case 4: {
                emu128_t temp1 = load_si128_emu(prand);
                emu128_t temp2 = load_si128_emu(pbuf);
                emu128_t add1 = xor_si128_emu(temp1, temp2);
                emu128_t clprod1 = clmulepi64_emu(add1, add1, 0x10);
                acc = xor_si128_emu(clprod1, acc);
                emu128_t clprod2 = clmulepi64_emu(temp2, temp2, 0x10);
                acc = xor_si128_emu(clprod2, acc);

                emu128_t tempa1 = mulhrs_epi16_emu(acc, temp1);
                emu128_t tempa2 = xor_si128_emu(tempa1, temp1);

                emu128_t temp12 = load_si128_emu(prandex);
                store_si128_emu(prandex, tempa2);

                emu128_t temp22 = load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                emu128_t add12 = xor_si128_emu(temp12, temp22);
                acc = xor_si128_emu(add12, acc);

                emu128_t tempb1 = mulhrs_epi16_emu(acc, temp12);
                emu128_t tempb2 = xor_si128_emu(tempb1, temp12);
                store_si128_emu(prand, tempb2);
                break;
            }
            case 8: {
                emu128_t temp1 = load_si128_emu(prandex);
                emu128_t temp2 = load_si128_emu(pbuf);
                emu128_t add1 = xor_si128_emu(temp1, temp2);
                acc = xor_si128_emu(add1, acc);

                emu128_t tempa1 = mulhrs_epi16_emu(acc, temp1);
                emu128_t tempa2 = xor_si128_emu(tempa1, temp1);

                emu128_t temp12 = load_si128_emu(prand);
                store_si128_emu(prand, tempa2);

                emu128_t temp22 = load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                emu128_t add12 = xor_si128_emu(temp12, temp22);
                emu128_t clprod12 = clmulepi64_emu(add12, add12, 0x10);
                acc = xor_si128_emu(clprod12, acc);
                emu128_t clprod22 = clmulepi64_emu(temp22, temp22, 0x10);
                acc = xor_si128_emu(clprod22, acc);

                emu128_t tempb1 = mulhrs_epi16_emu(acc, temp12);
                emu128_t tempb2 = xor_si128_emu(tempb1, temp12);
                store_si128_emu(prandex, tempb2);
                break;
            }
            case 0xc: {
                emu128_t temp1 = load_si128_emu(prand);
                emu128_t temp2 = load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                emu128_t add1 = xor_si128_emu(temp1, temp2);

                int32_t divisor = (int32_t)(uint32_t)selector;
                acc = xor_si128_emu(add1, acc);

                int64_t dividend = cvtsi128_si64_emu(acc);
                emu128_t modulo = cvtsi32_si128_emu((uint32_t)(dividend % divisor));
                acc = xor_si128_emu(modulo, acc);

                emu128_t tempa1 = mulhrs_epi16_emu(acc, temp1);
                emu128_t tempa2 = xor_si128_emu(tempa1, temp1);

                if (dividend & 1) {
                    emu128_t temp12 = load_si128_emu(prandex);
                    store_si128_emu(prandex, tempa2);

                    emu128_t temp22 = load_si128_emu(pbuf);
                    emu128_t add12 = xor_si128_emu(temp12, temp22);
                    emu128_t clprod12 = clmulepi64_emu(add12, add12, 0x10);
                    acc = xor_si128_emu(clprod12, acc);
                    emu128_t clprod22 = clmulepi64_emu(temp22, temp22, 0x10);
                    acc = xor_si128_emu(clprod22, acc);

                    emu128_t tempb1 = mulhrs_epi16_emu(acc, temp12);
                    emu128_t tempb2 = xor_si128_emu(tempb1, temp12);
                    store_si128_emu(prand, tempb2);
                } else {
                    emu128_t tempb3 = load_si128_emu(prandex);
                    store_si128_emu(prandex, tempa2);
                    store_si128_emu(prand, tempb3);
                    emu128_t tempb4 = load_si128_emu(pbuf);
                    acc = xor_si128_emu(tempb4, acc);
                }
                break;
            }
            case 0x10: {
                const emu128_t *rc = prand;
                emu128_t tmp;

                emu128_t temp1 = load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                emu128_t temp2 = load_si128_emu(pbuf);

                AES2_EMU(temp1, temp2, 0);
                MIX2_EMU(temp1, temp2);

                AES2_EMU(temp1, temp2, 4);
                MIX2_EMU(temp1, temp2);

                AES2_EMU(temp1, temp2, 8);
                MIX2_EMU(temp1, temp2);

                acc = xor_si128_emu(temp1, acc);
                acc = xor_si128_emu(temp2, acc);

                emu128_t tempa1 = load_si128_emu(prand);
                emu128_t tempa2 = mulhrs_epi16_emu(acc, tempa1);
                emu128_t tempa3 = xor_si128_emu(tempa1, tempa2);

                emu128_t tempa4 = load_si128_emu(prandex);
                store_si128_emu(prandex, tempa3);
                store_si128_emu(prand, tempa4);
                break;
            }
            case 0x14: {
                const emu128_t *buftmp = pbuf - (((selector & 1) << 1) - 1);
                emu128_t tmp;

                uint64_t rounds = selector >> 61;
                emu128_t *rc = prand;
                uint64_t aesround = 0;
                emu128_t onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = load_si128_emu(rc++);
                        emu128_t temp2 = load_si128_emu(rounds & 1 ? pbuf : buftmp);
                        emu128_t add1 = xor_si128_emu(onekey, temp2);
                        emu128_t clprod1 = clmulepi64_emu(add1, add1, 0x10);
                        acc = xor_si128_emu(clprod1, acc);
                    } else {
                        onekey = load_si128_emu(rc++);
                        emu128_t temp2 = load_si128_emu(rounds & 1 ? buftmp : pbuf);
                        uint64_t roundidx = aesround++ << 2;
                        AES2_EMU(onekey, temp2, (int)roundidx);

                        MIX2_EMU(onekey, temp2);

                        acc = xor_si128_emu(onekey, acc);
                        acc = xor_si128_emu(temp2, acc);
                    }
                } while (rounds--);

                emu128_t tempa1 = load_si128_emu(prand);
                emu128_t tempa2 = mulhrs_epi16_emu(acc, tempa1);
                emu128_t tempa3 = xor_si128_emu(tempa1, tempa2);

                emu128_t tempa4 = load_si128_emu(prandex);
                store_si128_emu(prandex, tempa3);
                store_si128_emu(prand, tempa4);
                break;
            }
            case 0x18: {
                const emu128_t *buftmp = pbuf - (((selector & 1) << 1) - 1);
                emu128_t tmp;

                uint64_t rounds = selector >> 61;
                emu128_t *rc = prand;
                emu128_t onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = load_si128_emu(rc++);
                        emu128_t temp2 = load_si128_emu(rounds & 1 ? pbuf : buftmp);
                        onekey = xor_si128_emu(onekey, temp2);
                        int32_t divisor = (int32_t)(uint32_t)selector;
                        int64_t dividend = cvtsi128_si64_emu(onekey);
                        emu128_t modulo = cvtsi32_si128_emu((uint32_t)(dividend % divisor));
                        acc = xor_si128_emu(modulo, acc);
                    } else {
                        onekey = load_si128_emu(rc++);
                        emu128_t temp2 = load_si128_emu(rounds & 1 ? buftmp : pbuf);
                        emu128_t add1 = xor_si128_emu(onekey, temp2);
                        onekey = clmulepi64_emu(add1, add1, 0x10);
                        emu128_t clprod2 = mulhrs_epi16_emu(acc, onekey);
                        acc = xor_si128_emu(clprod2, acc);
                    }
                } while (rounds--);

                emu128_t tempa3 = load_si128_emu(prandex);
                emu128_t tempa4 = xor_si128_emu(tempa3, acc);
                store_si128_emu(prandex, onekey);
                store_si128_emu(prand, tempa4);
                break;
            }
            case 0x1c: {
                emu128_t temp1 = load_si128_emu(pbuf);
                emu128_t temp2 = load_si128_emu(prandex);
                emu128_t add1 = xor_si128_emu(temp1, temp2);
                emu128_t clprod1 = clmulepi64_emu(add1, add1, 0x10);
                acc = xor_si128_emu(clprod1, acc);

                emu128_t tempa1 = mulhrs_epi16_emu(acc, temp2);
                emu128_t tempa2 = xor_si128_emu(tempa1, temp2);

                emu128_t tempa3 = load_si128_emu(prand);
                store_si128_emu(prand, tempa2);

                acc = xor_si128_emu(tempa3, acc);
                emu128_t temp4 = load_si128_emu(pbuf - (((selector & 1) << 1) - 1));
                acc = xor_si128_emu(temp4, acc);
                emu128_t tempb1 = mulhrs_epi16_emu(acc, tempa3);
                emu128_t tempb2 = xor_si128_emu(tempb1, tempa3);
                store_si128_emu(prandex, tempb2);
                break;
            }
        }
    }
    return acc;
}

// ---- Public API: verusclhash_sv2_2_port ----

uint64_t verusclhash_sv2_2_port(
    void *random, const unsigned char buf[64],
    uint64_t keyMask, void **pMoveScratch_out)
{
    emu128_t *rs64 = (emu128_t *)random;
    const emu128_t *string = (const emu128_t *)buf;

    emu128_t acc = verusclmul_sv2_2_port(rs64, string, keyMask, (emu128_t **)pMoveScratch_out);
    acc = xor_si128_emu(acc, lazyLengthHash_port(1024, 64));
    return precompReduction64_port(acc);
}
