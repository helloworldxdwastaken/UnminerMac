// verus_hash_v2.metal — full GPU port of CVerusHashV2 (Reset+Write+Finalize2b)
// mirroring canonical/verus_hash.h / verus_hash.cpp. The mining-loop kernel.
//
// Pipeline (mirrors CPU exactly):
//   Reset:        curBuf = 64 zero bytes
//   Write(data, len):
//     - 32 bytes at a time fill curBuf[32..64]
//     - haraka512(result, curBuf)  ← reads 64, writes 64 (un-keyed, static RC)
//     - swap curBuf ↔ result, continue
//     - partial last chunk stays in curBuf with curPos tracking
//   Finalize2b:
//     - FillExtra(curBuf): copies curBuf prefix into tail (no-known-zeros)
//     - GenNewCLKey(curBuf): chain haraka256 from curBuf[0..32] for 276 blocks
//     - intermediate = verusclhash_sv2_2(key, curBuf)
//     - FillExtra(&intermediate): fills tail with 8-byte intermediate (repeated)
//     - haraka512_keyed(hash, curBuf, key + (intermediate & 0x1FF) * 16)
//
// Primitives all validated byte-perfect against CPU in earlier commits:
//   haraka256 / haraka512 / haraka512_keyed / clmul64 / mulhrs /
//   precompReduction64 / verusclhash_sv2_2
//
// Kernel I/O:
//   buffer 0: input    — up to 512 bytes (canonical-cleared block buffer)
//   buffer 1: key_scratch — 24 KB per thread, holds the CL key + headroom
//   buffer 2: output   — 32 bytes per thread (final hash)
//   buffer 3: params   — [input_len_bytes]
//
// One thread = one hash. Mining will dispatch N threads with N nonces.

#include <metal_stdlib>
using namespace metal;

// ===================================================================
// Primitive 1: vec128 — our local 16-byte vector representation.
// uint64_t pair maps cleanly onto Intel __m128i: .lo = first 8 bytes
// (low-address), .hi = next 8 bytes. clmul ops naturally take 64-bit
// halves so this is the right granularity.
// ===================================================================
struct vec128 {
    uint64_t lo;
    uint64_t hi;
};

inline vec128 v128_zero() {
    vec128 r; r.lo = 0; r.hi = 0; return r;
}

// Load 16 bytes from device memory at byte offset.
inline vec128 v128_load(device const uchar *p) {
    vec128 r;
    r.lo = 0; r.hi = 0;
    // Unrolled byte loads (safe for any alignment, matches our other kernels)
    for (int i = 0; i < 8; i++) r.lo |= ((uint64_t)p[i])     << (8 * i);
    for (int i = 0; i < 8; i++) r.hi |= ((uint64_t)p[i + 8]) << (8 * i);
    return r;
}

// Same but from thread address space (for curBuf in the wrapper).
inline vec128 v128_load_thread(thread const uchar *p) {
    vec128 r;
    r.lo = 0; r.hi = 0;
    for (int i = 0; i < 8; i++) r.lo |= ((uint64_t)p[i])     << (8 * i);
    for (int i = 0; i < 8; i++) r.hi |= ((uint64_t)p[i + 8]) << (8 * i);
    return r;
}

inline void v128_store(device uchar *p, vec128 v) {
    for (int i = 0; i < 8; i++) p[i]     = (uchar)((v.lo >> (8 * i)) & 0xff);
    for (int i = 0; i < 8; i++) p[i + 8] = (uchar)((v.hi >> (8 * i)) & 0xff);
}

inline void v128_store_thread(thread uchar *p, vec128 v) {
    for (int i = 0; i < 8; i++) p[i]     = (uchar)((v.lo >> (8 * i)) & 0xff);
    for (int i = 0; i < 8; i++) p[i + 8] = (uchar)((v.hi >> (8 * i)) & 0xff);
}

inline vec128 v128_xor(vec128 a, vec128 b) {
    vec128 r; r.lo = a.lo ^ b.lo; r.hi = a.hi ^ b.hi; return r;
}

// Set a vec128 from a low uint32 (high 32 of low u64 = 0, high u64 = 0).
// Mirrors _mm_cvtsi32_si128_emu — which is ZERO-extending, not sign-
// extending: the parameter is uint32_t, and storing into a uint64 slot
// zero-extends. So if you pass a negative int32 you get its bit pattern
// reinterpreted as uint32 then zero-extended to uint64.
inline vec128 v128_from_u32(uint32_t x) {
    vec128 r;
    r.lo = (uint64_t)x;   // zero-extend
    r.hi = 0;
    return r;
}

// ===================================================================
// Primitive 2: clmul64 — windowed carryless multiply.
// Copied verbatim from clmul64.metal (already validated 1032/1032).
// ===================================================================
inline void clmul64_gpu(uint64_t a, uint64_t b,
                        thread uint64_t &r0, thread uint64_t &r1) {
    const uint s = 4;
    const uint64_t smask = (1ul << s) - 1ul;
    uint64_t u[16];
    u[0] = 0; u[1] = b;
    for (uint i = 2; i < (1u << s); i += 2) {
        u[i]     = u[i >> 1] << 1;
        u[i + 1] = u[i] ^ b;
    }
    r0 = u[a & smask];
    r1 = 0;
    for (uint i = s; i < 64; i += s) {
        uint64_t tmp = u[(a >> i) & smask];
        r0 ^= tmp << i;
        r1 ^= tmp >> (64u - i);
    }
    uint64_t m = 0xEEEEEEEEEEEEEEEEul;
    for (uint i = 1; i < s; i++) {
        uint64_t tmp = (a & m) >> i;
        m &= (m << 1);
        uint64_t ifmask = (uint64_t)0 - (uint64_t)((b >> (64u - i)) & 1ul);
        r1 ^= (tmp & ifmask);
    }
}

// clmul(a, b, 0x10) — multiply a.lo × b.hi
inline vec128 v128_clmul_lh(vec128 a, vec128 b) {
    vec128 r;
    clmul64_gpu(a.lo, b.hi, r.lo, r.hi);
    return r;
}

// ===================================================================
// Primitive 3: mulhrs_epi16 — 8-lane signed 16-bit fixed-point mul
// with rounding. Validated 517/517.
// ===================================================================
inline vec128 v128_mulhrs(vec128 a, vec128 b) {
    short ai[8], bi[8], ri[8];
    for (int i = 0; i < 4; i++) {
        ai[i]   = (short)((a.lo >> (16 * i)) & 0xffff);
        ai[i+4] = (short)((a.hi >> (16 * i)) & 0xffff);
        bi[i]   = (short)((b.lo >> (16 * i)) & 0xffff);
        bi[i+4] = (short)((b.hi >> (16 * i)) & 0xffff);
    }
    for (int i = 0; i < 8; i++) {
        int prod = (int)ai[i] * (int)bi[i];
        ri[i] = (short)((prod + 0x4000) >> 15);
    }
    vec128 r;
    r.lo = 0; r.hi = 0;
    for (int i = 0; i < 4; i++) {
        r.lo |= ((uint64_t)(uint16_t)ri[i])     << (16 * i);
        r.hi |= ((uint64_t)(uint16_t)ri[i + 4]) << (16 * i);
    }
    return r;
}

// ===================================================================
// Primitive 4: AES round (T-table form, runtime keys). Used by cases
// 0x10, 0x14. Validated as `aesenc_tt_keyed` in haraka512_keyed_v2.metal.
// ===================================================================
constant uchar SBOX[256] = {
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

inline uchar gf2(uchar x) {
    return (uchar)((((int)x) << 1) ^ ((x & 0x80) ? 0x1b : 0));
}

inline uint t_row(uchar b, int row) {
    uchar s   = SBOX[b];
    uchar f2s = gf2(s);
    uchar f3s = f2s ^ s;
    uchar c0, c1, c2, c3;
    if (row == 0)      { c0=f2s; c1=s;   c2=s;   c3=f3s; }
    else if (row == 1) { c0=f3s; c1=f2s; c2=s;   c3=s;   }
    else if (row == 2) { c0=s;   c1=f3s; c2=f2s; c3=s;   }
    else               { c0=s;   c1=s;   c2=f3s; c3=f2s; }
    return (uint)c0 | ((uint)c1 << 8) | ((uint)c2 << 16) | ((uint)c3 << 24);
}

// AES round on a single 16-byte state using a runtime round key.
// Takes vec128 state, returns new vec128 state.
inline vec128 v128_aesenc(vec128 s, vec128 rk) {
    // Unpack state into 4 uint32 columns
    uint x0 = (uint)(s.lo        & 0xffffffff);
    uint x1 = (uint)((s.lo >> 32) & 0xffffffff);
    uint x2 = (uint)(s.hi        & 0xffffffff);
    uint x3 = (uint)((s.hi >> 32) & 0xffffffff);
    uint y0, y1, y2, y3;

    y0 = t_row((uchar)( x0        & 0xff), 0);
    y1 = t_row((uchar)( x1        & 0xff), 0);
    y2 = t_row((uchar)( x2        & 0xff), 0);
    y3 = t_row((uchar)( x3        & 0xff), 0);

    y0 ^= t_row((uchar)((x1 >>  8) & 0xff), 1);
    y1 ^= t_row((uchar)((x2 >>  8) & 0xff), 1);
    y2 ^= t_row((uchar)((x3 >>  8) & 0xff), 1);
    y3 ^= t_row((uchar)((x0 >>  8) & 0xff), 1);

    y0 ^= t_row((uchar)((x2 >> 16) & 0xff), 2);
    y1 ^= t_row((uchar)((x3 >> 16) & 0xff), 2);
    y2 ^= t_row((uchar)((x0 >> 16) & 0xff), 2);
    y3 ^= t_row((uchar)((x1 >> 16) & 0xff), 2);

    y0 ^= t_row((uchar)( x3 >> 24       ), 3);
    y1 ^= t_row((uchar)( x0 >> 24       ), 3);
    y2 ^= t_row((uchar)( x1 >> 24       ), 3);
    y3 ^= t_row((uchar)( x2 >> 24       ), 3);

    // Unpack rk into 4 uint32 and XOR
    uint rk0 = (uint)(rk.lo        & 0xffffffff);
    uint rk1 = (uint)((rk.lo >> 32) & 0xffffffff);
    uint rk2 = (uint)(rk.hi        & 0xffffffff);
    uint rk3 = (uint)((rk.hi >> 32) & 0xffffffff);

    vec128 result;
    result.lo = ((uint64_t)(y0 ^ rk0))        | (((uint64_t)(y1 ^ rk1)) << 32);
    result.hi = ((uint64_t)(y2 ^ rk2))        | (((uint64_t)(y3 ^ rk3)) << 32);
    return result;
}

// AES2_EMU(s0, s1, rci) — 4 aesenc rounds using runtime round keys at
// key[(prand_idx16 + rci + 0..3) * 16].
inline void aes2_emu(thread vec128 &s0, thread vec128 &s1,
                     device const uchar *key, uint rk_offset_bytes) {
    vec128 rk0 = v128_load(key + rk_offset_bytes + 0  * 16);
    vec128 rk1 = v128_load(key + rk_offset_bytes + 1  * 16);
    vec128 rk2 = v128_load(key + rk_offset_bytes + 2  * 16);
    vec128 rk3 = v128_load(key + rk_offset_bytes + 3  * 16);
    s0 = v128_aesenc(s0, rk0);
    s1 = v128_aesenc(s1, rk1);
    s0 = v128_aesenc(s0, rk2);
    s1 = v128_aesenc(s1, rk3);
}

// MIX2_EMU — interleave 32-bit lanes (same as haraka256 MIX2).
//   tmp = unpacklo(s0, s1) = (s0[0], s1[0], s0[1], s1[1])
//   s1  = unpackhi(s0, s1) = (s0[2], s1[2], s0[3], s1[3])
//   s0  = tmp
inline void mix2_emu(thread vec128 &s0, thread vec128 &s1) {
    // Unpack into 4 lanes each
    uint a0 = (uint)(s0.lo        & 0xffffffff);
    uint a1 = (uint)((s0.lo >> 32) & 0xffffffff);
    uint a2 = (uint)(s0.hi        & 0xffffffff);
    uint a3 = (uint)((s0.hi >> 32) & 0xffffffff);
    uint b0 = (uint)(s1.lo        & 0xffffffff);
    uint b1 = (uint)((s1.lo >> 32) & 0xffffffff);
    uint b2 = (uint)(s1.hi        & 0xffffffff);
    uint b3 = (uint)((s1.hi >> 32) & 0xffffffff);

    // new s0 = (a0, b0, a1, b1)
    s0.lo = (uint64_t)a0 | ((uint64_t)b0 << 32);
    s0.hi = (uint64_t)a1 | ((uint64_t)b1 << 32);
    // new s1 = (a2, b2, a3, b3)
    s1.lo = (uint64_t)a2 | ((uint64_t)b2 << 32);
    s1.hi = (uint64_t)a3 | ((uint64_t)b3 << 32);
}

// ===================================================================
// Primitive 5: precompReduction64 — close the verusclhash pipeline.
// Validated 518/518.
// ===================================================================
constant uchar PRECOMP_LUT16[16] = {
    0x00, 0x1b, 0x36, 0x2d, 0x6c, 0x77, 0x5a, 0x41,
    0xd8, 0xc3, 0xee, 0xf5, 0xb4, 0xaf, 0x82, 0x99
};

inline uint64_t precomp_reduction64_v128(vec128 A) {
    // Q2 = clmul(A.hi, 0x1B)
    uint64_t q2_lo, q2_hi;
    clmul64_gpu(A.hi, 0x1Bul, q2_lo, q2_hi);

    // Pack Q2 as bytes
    uchar q2[16];
    for (int i = 0; i < 8; i++) {
        q2[i]     = (uchar)((q2_lo >> (8 * i)) & 0xff);
        q2[i + 8] = (uchar)((q2_hi >> (8 * i)) & 0xff);
    }
    // srli_si128(Q2, 8): high 8 bytes become low, high zeroed
    uchar q2sh[16];
    for (int i = 0; i < 8; i++)  q2sh[i] = q2[i + 8];
    for (int i = 8; i < 16; i++) q2sh[i] = 0;
    // Q3 = LUT shuffle
    uchar q3[16];
    for (int i = 0; i < 16; i++) {
        q3[i] = (q2sh[i] & 0x80) ? 0 : PRECOMP_LUT16[q2sh[i] & 0x0f];
    }
    // Pack A as bytes
    uchar a_bytes[16];
    for (int i = 0; i < 8; i++) {
        a_bytes[i]     = (uchar)((A.lo >> (8 * i)) & 0xff);
        a_bytes[i + 8] = (uchar)((A.hi >> (8 * i)) & 0xff);
    }
    // final = Q3 ^ (Q2 ^ A) — return low 8 bytes as the hash
    uint64_t hash = 0;
    for (int i = 0; i < 8; i++) {
        uchar b = q3[i] ^ (q2[i] ^ a_bytes[i]);
        hash |= ((uint64_t)b) << (8 * i);
    }
    return hash;
}

// ===================================================================
// verusclhash_sv2_2 — full algorithm as an INLINE helper.
// Takes a 64-byte thread-local curBuf and a device-resident mutable
// per-thread key buffer; returns the 64-bit hash output.
// ===================================================================
static uint64_t verusclhash_sv2_2_inline(thread const uchar *curBuf,
                                         device uchar *key_buf,
                                         uint64_t keyMask_bytes) {
    // Load the 4-vector input from thread-local curBuf
    vec128 buf0 = v128_load_thread(curBuf + 0 * 16);
    vec128 buf1 = v128_load_thread(curBuf + 1 * 16);
    vec128 buf2 = v128_load_thread(curBuf + 2 * 16);
    vec128 buf3 = v128_load_thread(curBuf + 3 * 16);

    // pbuf_copy[4] — first 2 are XOR-mixed, last 2 are pass-through
    vec128 pbuf_copy[4];
    pbuf_copy[0] = v128_xor(buf0, buf2);
    pbuf_copy[1] = v128_xor(buf1, buf3);
    pbuf_copy[2] = buf2;
    pbuf_copy[3] = buf3;

    // keyMask is passed in BYTES; the CPU does `keyMask >>= 4` to convert
    // to __m128i indices. We keep it as bytes everywhere for clarity, with
    // explicit << 4 / >> 4 conversions when indexing.
    uint64_t keyMask_units = keyMask_bytes >> 4;   // in __m128i (16-byte) units

    // Initial acc: read from key[(keyMask + 2) * 16 bytes]
    // (CPU line 892: `acc = _mm_load_si128_emu(randomsource + (keyMask + 2))`
    // — but in CPU at this point keyMask is ALREADY in __m128i units because
    // line 887 did `keyMask >>= 4`. So the byte offset is (keyMask_units + 2) * 16.)
    vec128 acc = v128_load(key_buf + (keyMask_units + 2) * 16);

    for (int i = 0; i < 32; i++) {
        uint64_t selector = acc.lo;

        // prand, prandex: indices into key (in __m128i units)
        uint64_t prand_idx   = (selector >> 5)  & keyMask_units;
        uint64_t prandex_idx = (selector >> 32) & keyMask_units;
        uint prand_off_bytes   = (uint)(prand_idx   * 16);
        uint prandex_off_bytes = (uint)(prandex_idx * 16);

        // pbuf base index in pbuf_copy (0..3)
        uint pbuf_idx     = (uint)(selector & 3);
        // The "neighbor" index: pbuf+1 when sel even, pbuf-1 when sel odd.
        // Equivalent to (pbuf_idx XOR 1) — both directions stay in [0..3].
        uint pbuf_alt_idx = pbuf_idx ^ 1;

        vec128 pbuf     = pbuf_copy[pbuf_idx];
        vec128 pbuf_alt = pbuf_copy[pbuf_alt_idx];

        uint sw = (uint)(selector & 0x1c);

        if (sw == 0x00) {
            // CPU lines 912-935
            vec128 temp1 = v128_load(key_buf + prandex_off_bytes);
            vec128 temp2 = pbuf_alt;
            vec128 add1  = v128_xor(temp1, temp2);
            vec128 clprod1 = v128_clmul_lh(add1, add1);
            acc = v128_xor(clprod1, acc);

            vec128 tempa1 = v128_mulhrs(acc, temp1);
            vec128 tempa2 = v128_xor(tempa1, temp1);

            vec128 temp12 = v128_load(key_buf + prand_off_bytes);
            v128_store(key_buf + prand_off_bytes, tempa2);

            vec128 temp22 = pbuf;
            vec128 add12 = v128_xor(temp12, temp22);
            vec128 clprod12 = v128_clmul_lh(add12, add12);
            acc = v128_xor(clprod12, acc);

            vec128 tempb1 = v128_mulhrs(acc, temp12);
            vec128 tempb2 = v128_xor(tempb1, temp12);
            v128_store(key_buf + prandex_off_bytes, tempb2);
        }
        else if (sw == 0x04) {
            // CPU lines 936-959
            vec128 temp1 = v128_load(key_buf + prand_off_bytes);
            vec128 temp2 = pbuf;
            vec128 add1  = v128_xor(temp1, temp2);
            vec128 clprod1 = v128_clmul_lh(add1, add1);
            acc = v128_xor(clprod1, acc);
            vec128 clprod2 = v128_clmul_lh(temp2, temp2);
            acc = v128_xor(clprod2, acc);

            vec128 tempa1 = v128_mulhrs(acc, temp1);
            vec128 tempa2 = v128_xor(tempa1, temp1);

            vec128 temp12 = v128_load(key_buf + prandex_off_bytes);
            v128_store(key_buf + prandex_off_bytes, tempa2);

            vec128 temp22 = pbuf_alt;
            vec128 add12 = v128_xor(temp12, temp22);
            acc = v128_xor(add12, acc);

            vec128 tempb1 = v128_mulhrs(acc, temp12);
            vec128 tempb2 = v128_xor(tempb1, temp12);
            v128_store(key_buf + prand_off_bytes, tempb2);
        }
        else if (sw == 0x08) {
            // CPU lines 961-984
            vec128 temp1 = v128_load(key_buf + prandex_off_bytes);
            vec128 temp2 = pbuf;
            vec128 add1  = v128_xor(temp1, temp2);
            acc = v128_xor(add1, acc);

            vec128 tempa1 = v128_mulhrs(acc, temp1);
            vec128 tempa2 = v128_xor(tempa1, temp1);

            vec128 temp12 = v128_load(key_buf + prand_off_bytes);
            v128_store(key_buf + prand_off_bytes, tempa2);

            vec128 temp22 = pbuf_alt;
            vec128 add12 = v128_xor(temp12, temp22);
            vec128 clprod12 = v128_clmul_lh(add12, add12);
            acc = v128_xor(clprod12, acc);
            vec128 clprod22 = v128_clmul_lh(temp22, temp22);
            acc = v128_xor(clprod22, acc);

            vec128 tempb1 = v128_mulhrs(acc, temp12);
            vec128 tempb2 = v128_xor(tempb1, temp12);
            v128_store(key_buf + prandex_off_bytes, tempb2);
        }
        else if (sw == 0x0c) {
            // CPU lines 986-1028 — branchy: int64 % int32, then split on dividend & 1
            vec128 temp1 = v128_load(key_buf + prand_off_bytes);
            vec128 temp2 = pbuf_alt;
            vec128 add1  = v128_xor(temp1, temp2);

            int32_t divisor = (int32_t)(uint32_t)selector;
            acc = v128_xor(add1, acc);

            int64_t dividend = (int64_t)acc.lo;
            // MSL supports signed 64-bit % directly. Same semantics as C
            // (truncation toward zero for negative operands).
            int64_t mod = dividend % divisor;
            vec128 modulo = v128_from_u32((uint32_t)mod);
            acc = v128_xor(modulo, acc);

            vec128 tempa1 = v128_mulhrs(acc, temp1);
            vec128 tempa2 = v128_xor(tempa1, temp1);

            if (dividend & 1) {
                vec128 temp12 = v128_load(key_buf + prandex_off_bytes);
                v128_store(key_buf + prandex_off_bytes, tempa2);

                vec128 temp22 = pbuf;
                vec128 add12 = v128_xor(temp12, temp22);
                vec128 clprod12 = v128_clmul_lh(add12, add12);
                acc = v128_xor(clprod12, acc);
                vec128 clprod22 = v128_clmul_lh(temp22, temp22);
                acc = v128_xor(clprod22, acc);

                vec128 tempb1 = v128_mulhrs(acc, temp12);
                vec128 tempb2 = v128_xor(tempb1, temp12);
                v128_store(key_buf + prand_off_bytes, tempb2);
            } else {
                vec128 tempb3 = v128_load(key_buf + prandex_off_bytes);
                v128_store(key_buf + prandex_off_bytes, tempa2);
                v128_store(key_buf + prand_off_bytes,   tempb3);
                vec128 tempb4 = pbuf;
                acc = v128_xor(tempb4, acc);
            }
        }
        else if (sw == 0x10) {
            // CPU lines 1030-1058 — 6 AES rounds + 3 MIX2s + 1 mulhrs
            vec128 temp1 = pbuf_alt;
            vec128 temp2 = pbuf;

            // AES2(t1, t2, 0), MIX2; AES2(t1, t2, 4), MIX2; AES2(t1, t2, 8), MIX2
            // Round keys come from key_buf at prand_off, rci is in __m128i units
            aes2_emu(temp1, temp2, key_buf, prand_off_bytes + 0  * 16);
            mix2_emu(temp1, temp2);
            aes2_emu(temp1, temp2, key_buf, prand_off_bytes + 4  * 16);
            mix2_emu(temp1, temp2);
            aes2_emu(temp1, temp2, key_buf, prand_off_bytes + 8  * 16);
            mix2_emu(temp1, temp2);

            acc = v128_xor(temp1, acc);
            acc = v128_xor(temp2, acc);

            vec128 tempa1 = v128_load(key_buf + prand_off_bytes);
            vec128 tempa2 = v128_mulhrs(acc, tempa1);
            vec128 tempa3 = v128_xor(tempa1, tempa2);

            vec128 tempa4 = v128_load(key_buf + prandex_off_bytes);
            v128_store(key_buf + prandex_off_bytes, tempa3);
            v128_store(key_buf + prand_off_bytes,   tempa4);
        }
        else if (sw == 0x14) {
            // CPU lines 1060-1103 — do-while loop, AES vs clmul branch
            vec128 buftmp = pbuf_alt;
            uint64_t rounds = selector >> 61;   // 0..7
            uint rc_offset_bytes = prand_off_bytes;
            uint64_t aesround = 0;
            vec128 onekey = v128_zero();

            // do { ... } while (rounds--) executes (rounds + 1) times.
            // We translate as: for (int r = (int)rounds; r >= 0; r--) {...}
            for (int r = (int)rounds; r >= 0; r--) {
                bool branch_aes_to_clmul = (selector & (((uint64_t)0x10000000) << r)) != 0;
                vec128 src2 = ((r & 1) ? pbuf : buftmp);    // when branch taken
                vec128 src2_alt = ((r & 1) ? buftmp : pbuf);// when branch not taken

                if (branch_aes_to_clmul) {
                    onekey = v128_load(key_buf + rc_offset_bytes);
                    rc_offset_bytes += 16;
                    vec128 temp2 = src2;
                    vec128 add1 = v128_xor(onekey, temp2);
                    vec128 clprod1 = v128_clmul_lh(add1, add1);
                    acc = v128_xor(clprod1, acc);
                } else {
                    onekey = v128_load(key_buf + rc_offset_bytes);
                    rc_offset_bytes += 16;
                    vec128 temp2 = src2_alt;
                    uint roundidx = (uint)(aesround << 2);
                    aesround++;
                    // CPU code: AES2_EMU expands to aesenc(s, rc[rci+k]) where
                    // `rc` is the LOCAL pointer that has been advanced by
                    // every `rc++` so far this case. So the round-key offset
                    // is FROM THE CURRENT rc, not from the original prand.
                    aes2_emu(onekey, temp2, key_buf, rc_offset_bytes + roundidx * 16);
                    mix2_emu(onekey, temp2);
                    acc = v128_xor(onekey, acc);
                    acc = v128_xor(temp2,  acc);
                }
            }

            vec128 tempa1 = v128_load(key_buf + prand_off_bytes);
            vec128 tempa2 = v128_mulhrs(acc, tempa1);
            vec128 tempa3 = v128_xor(tempa1, tempa2);

            vec128 tempa4 = v128_load(key_buf + prandex_off_bytes);
            v128_store(key_buf + prandex_off_bytes, tempa3);
            v128_store(key_buf + prand_off_bytes,   tempa4);
        }
        else if (sw == 0x18) {
            // CPU lines 1105-1143 — do-while loop, modulo vs clmul branch
            vec128 buftmp = pbuf_alt;
            uint64_t rounds = selector >> 61;
            uint rc_offset_bytes = prand_off_bytes;
            vec128 onekey = v128_zero();

            for (int r = (int)rounds; r >= 0; r--) {
                bool branch_mod = (selector & (((uint64_t)0x10000000) << r)) != 0;
                vec128 src2 = ((r & 1) ? pbuf : buftmp);
                vec128 src2_alt = ((r & 1) ? buftmp : pbuf);

                if (branch_mod) {
                    onekey = v128_load(key_buf + rc_offset_bytes);
                    rc_offset_bytes += 16;
                    vec128 temp2 = src2;
                    onekey = v128_xor(onekey, temp2);
                    int32_t divisor = (int32_t)(uint32_t)selector;
                    int64_t dividend = (int64_t)onekey.lo;
                    int64_t mod = dividend % divisor;
                    vec128 modulo = v128_from_u32((uint32_t)mod);
                    acc = v128_xor(modulo, acc);
                } else {
                    onekey = v128_load(key_buf + rc_offset_bytes);
                    rc_offset_bytes += 16;
                    vec128 temp2 = src2_alt;
                    vec128 add1 = v128_xor(onekey, temp2);
                    onekey = v128_clmul_lh(add1, add1);
                    vec128 clprod2 = v128_mulhrs(acc, onekey);
                    acc = v128_xor(clprod2, acc);
                }
            }

            vec128 tempa3 = v128_load(key_buf + prandex_off_bytes);
            vec128 tempa4 = v128_xor(tempa3, acc);
            v128_store(key_buf + prandex_off_bytes, onekey);
            v128_store(key_buf + prand_off_bytes,   tempa4);
        }
        else /* sw == 0x1c */ {
            // CPU lines 1144-1165
            vec128 temp1 = pbuf;
            vec128 temp2 = v128_load(key_buf + prandex_off_bytes);
            vec128 add1  = v128_xor(temp1, temp2);
            vec128 clprod1 = v128_clmul_lh(add1, add1);
            acc = v128_xor(clprod1, acc);

            vec128 tempa1 = v128_mulhrs(acc, temp2);
            vec128 tempa2 = v128_xor(tempa1, temp2);

            vec128 tempa3 = v128_load(key_buf + prand_off_bytes);
            v128_store(key_buf + prand_off_bytes, tempa2);

            acc = v128_xor(tempa3, acc);
            vec128 temp4 = pbuf_alt;
            acc = v128_xor(temp4, acc);
            vec128 tempb1 = v128_mulhrs(acc, tempa3);
            vec128 tempb2 = v128_xor(tempb1, tempa3);
            v128_store(key_buf + prandex_off_bytes, tempb2);
        }
    }

    // Outer wrapper: XOR with lazyLengthHash(1024, 64) = clmul(64, 1024).
    // Precomputed: clmul64(64, 1024) where 64 is "low" and 1024 is "high"
    // of a __m128i vector.
    // We compute it inline (one clmul) to keep the kernel self-contained.
    uint64_t llh_lo, llh_hi;
    clmul64_gpu(64ul, 1024ul, llh_lo, llh_hi);
    vec128 llh; llh.lo = llh_lo; llh.hi = llh_hi;
    acc = v128_xor(acc, llh);

    // precompReduction64 → final 64-bit hash
    return precomp_reduction64_v128(acc);
}

// ===================================================================
// Un-keyed haraka primitives — for Write (haraka512) and GenNewCLKey
// (haraka256). RC[160] table mirrors haraka_portable.c's haraka_rc[40][16]
// packed as 4 uint32 LE per 16-byte round constant.
// ===================================================================
constant uint HRC[160] = {
    0x75817b9d, 0xb2c5fef0, 0xe620c00a, 0x0684704c,
    0x2f08f717, 0x640f6ba4, 0x88f3a06b, 0x8b66b4e1,
    0x9f029114, 0xcf029d60, 0x53f28498, 0x3402de2d,
    0xfd5b4f79, 0xbbf3bcaf, 0x2e7b4f08, 0x0ed6eae6,
    0xbe397044, 0x79eecd1c, 0x4872448b, 0xcbcfb0cb,
    0x2b8a057b, 0x8d5335ed, 0x6e9032b7, 0x7eeacdee,
    0xda4fef1b, 0xe2412761, 0x5e2e7cd0, 0x67c28f43,
    0x1fc70b3b, 0x675ffde2, 0xafcacc07, 0x2924d9b0,
    0xb9d465ee, 0xecdb8fca, 0xe6867fe9, 0xab4d63f1,
    0xad037e33, 0x5b2a404f, 0xd4b7cd64, 0x1c30bf84,
    0x8df69800, 0x69028b2e, 0x941723bf, 0xb2cc0bb9,
    0x5c9d2d8a, 0x4aaa9ec8, 0xde6f5572, 0xfa0478a6,
    0x29129fd4, 0x0efa4f2e, 0x6b772a12, 0xdfb49f2b,
    0xbb6a12ee, 0x32d611ae, 0xf449a236, 0x1ea10344,
    0x9ca8eca6, 0x5f9600c9, 0x4b050084, 0xaf044988,
    0x27e593ec, 0x78a2c7e3, 0x9d199c4f, 0x21025ed8,
    0x82d40173, 0xb9282ecd, 0xa759c9b7, 0xbf3aaaf8,
    0x10307d6b, 0x37f2efd9, 0x6186b017, 0x6260700d,
    0xf6fc9ac6, 0x81c29153, 0x21300443, 0x5aca45c2,
    0x36d1943a, 0x2caf92e8, 0x226b68bb, 0x9223973c,
    0xe51071b4, 0x6cbab958, 0x225886eb, 0xd3bf9238,
    0x24e1128d, 0x933dfddd, 0xaef0c677, 0xdb863ce5,
    0xcb2212b1, 0x83e48de3, 0xffeba09c, 0xbb606268,
    0xc72bf77d, 0x2db91a4e, 0xe2e4d19c, 0x734bd3dc,
    0x2cb3924e, 0x4b1415c4, 0x61301b43, 0x43bb47c3,
    0x16eb6899, 0x03b231dd, 0xe707eff6, 0xdba775a8,
    0x7eca472c, 0x8e5e2302, 0x3c755977, 0x6df3614b,
    0xb88617f9, 0x6d1be5b9, 0xd6de7d77, 0xcda75a17,
    0xa946ee5d, 0x9d6c069d, 0x6ba8e9aa, 0xec6b43f0,
    0x3bf327c1, 0xa2531159, 0xf957332b, 0xcb1e6950,
    0x600ed0d9, 0xe4ed0353, 0x00da619c, 0x2cee0c75,
    0x63a4a350, 0x80bbbabc, 0x96e90cab, 0xf0b1a5a1,
    0x938dca39, 0xab0dde30, 0x5e962988, 0xae3db102,
    0x2e75b442, 0x8814f3a8, 0xd554a40b, 0x17bb8f38,
    0x360a16f6, 0xaeb6b779, 0x5f427fd7, 0x34bb8a5b,
    0xffbaafde, 0x43ce5918, 0xcbe55438, 0x26f65241,
    0x839ec978, 0xa2ca9cf7, 0xb9f3026a, 0x4ce99a54,
    0x22901235, 0x40c06e28, 0x1bdff7be, 0xae51a51a,
    0x48a659cf, 0xc173bc0f, 0xba7ed22b, 0xa0c1613c,
    0xe9c59da1, 0x4ad6bdfd, 0x02288288, 0x756acc03,
};

// Build a vec128 round constant from HRC[i*4 .. i*4+4].
inline vec128 hrc_at(int i) {
    vec128 r;
    r.lo = (uint64_t)HRC[i*4 + 0] | ((uint64_t)HRC[i*4 + 1] << 32);
    r.hi = (uint64_t)HRC[i*4 + 2] | ((uint64_t)HRC[i*4 + 3] << 32);
    return r;
}

// MIX4 — interleave 32-bit lanes across 4 halves. Same as haraka512_v2.metal.
inline void mix4_v128(thread vec128 &s0, thread vec128 &s1,
                      thread vec128 &s2, thread vec128 &s3) {
    uint a0 = (uint)(s0.lo & 0xffffffff), a1 = (uint)(s0.lo >> 32);
    uint a2 = (uint)(s0.hi & 0xffffffff), a3 = (uint)(s0.hi >> 32);
    uint b0 = (uint)(s1.lo & 0xffffffff), b1 = (uint)(s1.lo >> 32);
    uint b2 = (uint)(s1.hi & 0xffffffff), b3 = (uint)(s1.hi >> 32);
    uint c0 = (uint)(s2.lo & 0xffffffff), c1 = (uint)(s2.lo >> 32);
    uint c2 = (uint)(s2.hi & 0xffffffff), c3 = (uint)(s2.hi >> 32);
    uint d0 = (uint)(s3.lo & 0xffffffff), d1 = (uint)(s3.lo >> 32);
    uint d2 = (uint)(s3.hi & 0xffffffff), d3 = (uint)(s3.hi >> 32);

    uint t0 = a0, t1 = b0, t2 = a1, t3 = b1;   // unpacklo(s0, s1)
    uint p0 = a2, p1 = b2, p2 = a3, p3 = b3;   // unpackhi(s0, s1)
    uint q0 = c0, q1 = d0, q2 = c1, q3 = d1;   // unpacklo(s2, s3)
    uint r0 = c2, r1 = d2, r2 = c3, r3 = d3;   // unpackhi(s2, s3)

    s3.lo = (uint64_t)p0 | ((uint64_t)r0 << 32);   // unpacklo(p, r) = (a2,c2,b2,d2)
    s3.hi = (uint64_t)p1 | ((uint64_t)r1 << 32);
    s0.lo = (uint64_t)p2 | ((uint64_t)r2 << 32);   // unpackhi(p, r)
    s0.hi = (uint64_t)p3 | ((uint64_t)r3 << 32);
    s2.lo = (uint64_t)q2 | ((uint64_t)t2 << 32);   // unpackhi(q, t)
    s2.hi = (uint64_t)q3 | ((uint64_t)t3 << 32);
    s1.lo = (uint64_t)q0 | ((uint64_t)t0 << 32);   // unpacklo(q, t)
    s1.hi = (uint64_t)q1 | ((uint64_t)t1 << 32);
}

// haraka256_port equivalent: 32 bytes → 32 bytes (perm + feed-forward).
// Uses RC indices 0..19 (4 per round × 5 rounds, 2 halves × 2 sub-rounds per).
inline void haraka256_apply(thread uchar *out, thread const uchar *in) {
    vec128 s0 = v128_load_thread(in);
    vec128 s1 = v128_load_thread(in + 16);
    vec128 i0 = s0, i1 = s1;

    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 2; j++) {
            s0 = v128_aesenc(s0, hrc_at(2*2*i + 2*j + 0));
            s1 = v128_aesenc(s1, hrc_at(2*2*i + 2*j + 1));
        }
        mix2_emu(s0, s1);
    }

    // Feed-forward
    s0 = v128_xor(s0, i0);
    s1 = v128_xor(s1, i1);
    v128_store_thread(out,      s0);
    v128_store_thread(out + 16, s1);
}

// haraka512_port equivalent: 64 bytes → 32 bytes (perm + feed-forward + TRUNCSTORE).
// Used by CVerusHashV2::Write to chain 32-byte digests.
inline void haraka512_apply(thread uchar *out, thread const uchar *in) {
    vec128 s0 = v128_load_thread(in);
    vec128 s1 = v128_load_thread(in + 16);
    vec128 s2 = v128_load_thread(in + 32);
    vec128 s3 = v128_load_thread(in + 48);
    vec128 i0 = s0, i1 = s1, i2 = s2, i3 = s3;

    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 2; j++) {
            s0 = v128_aesenc(s0, hrc_at(4*2*i + 4*j + 0));
            s1 = v128_aesenc(s1, hrc_at(4*2*i + 4*j + 1));
            s2 = v128_aesenc(s2, hrc_at(4*2*i + 4*j + 2));
            s3 = v128_aesenc(s3, hrc_at(4*2*i + 4*j + 3));
        }
        mix4_v128(s0, s1, s2, s3);
    }

    // Feed-forward
    s0 = v128_xor(s0, i0);
    s1 = v128_xor(s1, i1);
    s2 = v128_xor(s2, i2);
    s3 = v128_xor(s3, i3);

    // TRUNCSTORE: out[0..8]=s0.hi, [8..16]=s1.hi, [16..24]=s2.lo, [24..32]=s3.lo
    for (int i = 0; i < 8; i++) out[i]      = (uchar)((s0.hi >> (8*i)) & 0xff);
    for (int i = 0; i < 8; i++) out[i + 8]  = (uchar)((s1.hi >> (8*i)) & 0xff);
    for (int i = 0; i < 8; i++) out[i + 16] = (uchar)((s2.lo >> (8*i)) & 0xff);
    for (int i = 0; i < 8; i++) out[i + 24] = (uchar)((s3.lo >> (8*i)) & 0xff);
}

// haraka512_port_keyed equivalent: 64 bytes → 32 bytes, round keys from device
// buffer at byte offset key_off. 40 round keys × 16 bytes = 640 bytes consumed.
inline void haraka512_keyed_apply(thread uchar *out, thread const uchar *in,
                                  device const uchar *key, uint key_off) {
    vec128 s0 = v128_load_thread(in);
    vec128 s1 = v128_load_thread(in + 16);
    vec128 s2 = v128_load_thread(in + 32);
    vec128 s3 = v128_load_thread(in + 48);
    vec128 i0 = s0, i1 = s1, i2 = s2, i3 = s3;

    for (int i = 0; i < 5; i++) {
        for (int j = 0; j < 2; j++) {
            uint base = key_off + (uint)(4*2*i + 4*j) * 16;
            s0 = v128_aesenc(s0, v128_load(key + base +  0));
            s1 = v128_aesenc(s1, v128_load(key + base + 16));
            s2 = v128_aesenc(s2, v128_load(key + base + 32));
            s3 = v128_aesenc(s3, v128_load(key + base + 48));
        }
        mix4_v128(s0, s1, s2, s3);
    }

    s0 = v128_xor(s0, i0);
    s1 = v128_xor(s1, i1);
    s2 = v128_xor(s2, i2);
    s3 = v128_xor(s3, i3);

    for (int i = 0; i < 8; i++) out[i]      = (uchar)((s0.hi >> (8*i)) & 0xff);
    for (int i = 0; i < 8; i++) out[i + 8]  = (uchar)((s1.hi >> (8*i)) & 0xff);
    for (int i = 0; i < 8; i++) out[i + 16] = (uchar)((s2.lo >> (8*i)) & 0xff);
    for (int i = 0; i < 8; i++) out[i + 24] = (uchar)((s3.lo >> (8*i)) & 0xff);
}

// ===================================================================
// THE WRAPPER: CVerusHashV2 Reset + Write + Finalize2b.
// One GPU thread = one hash of arbitrary-length input.
// ===================================================================
// Per-thread scratch budget:
//   curBuf, result        = 64 + 64 = 128 bytes (thread-private)
//   key scratch (device)  = at least 8832 + 8192 = 17024 bytes — we allocate
//                           24576 per thread for safe headroom.
constant uint KEY_SCRATCH_PER_THREAD = 24576;
constant uint VERUS_KEYSIZE          = 8832;
constant uint VERUS_REFRESHSIZE      = 8192;   // = (keymask 8191) + 1
constant uint VERUS_KEYMASK_BYTES    = 8191;

// ===================================================================
// MINING KERNEL — the one mining actually dispatches.
// Each thread mutates the 8-byte nonce slot in its own scratch copy,
// computes the full VerusHash 2.2, and checks against the target.
// Winners are atomically logged into found_nonces/found_hashes.
//
// Buffer layout:
//   buffer 0 input_template  — shared, the scratch buffer pre-nonce-mutation
//                              (PBaaS-cleared, blake2b embedded). Read-only.
//   buffer 1 key_scratch     — N × KEY_SCRATCH_PER_THREAD bytes (device,
//                              read-write per thread)
//   buffer 2 target          — 32 bytes (shared, read-only). Pool target in
//                              MSB-first order (same as set_target).
//   buffer 3 params          — [input_len, body_tail_off, base_nonce_lo,
//                               base_nonce_hi, max_found]
//   buffer 4 found_count     — atomic uint, # winners found in this batch
//   buffer 5 found_nonces    — N × uint64_t (only first found_count are valid)
//   buffer 6 found_hashes    — N × 32 bytes (full hashes for verification)
//
// Compare semantics: hash_below_target_pool from main.cpp — hash is LE
// (MSB at hash[31]), target is BE (MSB at target[0]). Iterate from MSB
// of each, return true on first byte where hash < target.
constant uint MINE_MAX_FOUND = 64;   // hard cap on winners per batch
constant uint MINE_KEY_SCRATCH_PER_THREAD = 24576;

inline bool hash_below_target_gpu(thread const uchar *hash, device const uchar *target) {
    for (int i = 0; i < 32; i++) {
        uchar h = hash[31 - i];   // hash MSB-first (hash is LE-stored)
        uchar t = target[i];      // target MSB-first
        if (h < t) return true;
        if (h > t) return false;
    }
    return false;
}

// Read byte idx from the shared input_template, substituting nonce bytes
// at body_tail_off..body_tail_off+8. Avoids per-thread scratch copy.
inline uchar mine_byte_at(uint idx,
                          device const uchar *input_template,
                          uint body_tail_off,
                          uint64_t nonce) {
    if (idx >= body_tail_off && idx < body_tail_off + 8) {
        return (uchar)((nonce >> ((idx - body_tail_off) * 8)) & 0xff);
    }
    return input_template[idx];
}

kernel void verus_mine_kernel(
    device const uchar    *input_template [[buffer(0)]],
    device uchar          *key_scratch    [[buffer(1)]],
    device const uchar    *target         [[buffer(2)]],
    device const uint64_t *params         [[buffer(3)]],
    device atomic_uint    *found_count    [[buffer(4)]],
    device uint64_t       *found_nonces   [[buffer(5)]],
    device uchar          *found_hashes   [[buffer(6)]],
    uint gid [[thread_position_in_grid]])
{
    uint     input_len     = (uint)params[0];
    uint     body_tail_off = (uint)params[1];
    uint64_t base_nonce    = params[2];

    // Per-thread nonce: base_nonce + gid
    uint64_t nonce = base_nonce + (uint64_t)gid;

    // Per-thread key buffer slice in device memory
    device uchar *key = key_scratch + gid * MINE_KEY_SCRATCH_PER_THREAD;

    // === Full VerusHash 2.2 (mirrors verus_hash_v2_kernel) ===
    thread uchar curBuf[64];
    thread uchar result[64];
    for (int i = 0; i < 64; i++) curBuf[i] = 0;
    int curPos = 0;

    // Write loop — reads directly from shared input_template, substituting
    // the nonce bytes at body_tail_off on the fly (no per-thread copy).
    uint pos = 0;
    while (pos < input_len) {
        int room = 32 - curPos;
        int remaining = (int)(input_len - pos);
        if (remaining >= room) {
            for (int i = 0; i < room; i++) {
                curBuf[32 + curPos + i] = mine_byte_at(pos + i, input_template,
                                                       body_tail_off, nonce);
            }
            haraka512_apply(result, curBuf);
            for (int i = 0; i < 32; i++) curBuf[i] = result[i];
            pos += room;
            curPos = 0;
        } else {
            for (int i = 0; i < remaining; i++) {
                curBuf[32 + curPos + i] = mine_byte_at(pos + i, input_template,
                                                       body_tail_off, nonce);
            }
            curPos += remaining;
            pos = input_len;
        }
    }

    // FillExtra(curBuf)
    {
        int left = 32 - curPos;
        int fpos = curPos;
        while (left > 0) {
            int len = (left > 16) ? 16 : left;
            for (int i = 0; i < len; i++) {
                curBuf[32 + fpos + i] = curBuf[i];
            }
            fpos += len; left -= len;
        }
    }

    // GenNewCLKey — chain haraka256 from curBuf[0..32], 276 blocks
    {
        thread uchar src[32];
        for (int i = 0; i < 32; i++) src[i] = curBuf[i];
        uint pkey_off = 0;
        for (int b = 0; b < 276; b++) {
            thread uchar tmp[32];
            haraka256_apply(tmp, src);
            for (int i = 0; i < 32; i++) {
                key[pkey_off + i] = tmp[i];
                src[i] = tmp[i];
            }
            pkey_off += 32;
        }
        for (uint i = 0; i < VERUS_REFRESHSIZE; i++) {
            key[VERUS_KEYSIZE + i] = key[i];
        }
    }

    // verusclhash
    uint64_t intermediate = verusclhash_sv2_2_inline(curBuf, key, VERUS_KEYMASK_BYTES);

    // FillExtra(&intermediate)
    {
        int left = 32 - curPos;
        int fpos = curPos;
        while (left > 0) {
            int len = (left > 8) ? 8 : left;
            for (int i = 0; i < len; i++) {
                curBuf[32 + fpos + i] = (uchar)((intermediate >> (8*i)) & 0xff);
            }
            fpos += len; left -= len;
        }
    }

    // Final haraka512_keyed → hash[32]
    thread uchar hash[32];
    {
        uint offset_units = (uint)(intermediate & 511);
        haraka512_keyed_apply(hash, curBuf, key, offset_units * 16);
    }

    // === Target check ===
    if (hash_below_target_gpu(hash, target)) {
        // Atomically claim a winner slot
        uint slot = atomic_fetch_add_explicit(found_count, 1, memory_order_relaxed);
        if (slot < MINE_MAX_FOUND) {
            found_nonces[slot] = nonce;
            for (int i = 0; i < 32; i++) found_hashes[slot * 32 + i] = hash[i];
        }
    }
}

// DEBUG: test haraka256_apply directly on input. If this doesn't match the
// canonical Haraka v2 test vector (8027ccb87949774b…) for counting-up input,
// haraka256_apply is broken.
kernel void haraka256_probe_kernel(
    device const uchar  *input_buf [[buffer(0)]],   // 32 bytes
    device uchar        *output    [[buffer(1)]],   // 32 bytes
    uint gid [[thread_position_in_grid]])
{
    thread uchar in[32], out[32];
    for (int i = 0; i < 32; i++) in[i] = input_buf[i];
    haraka256_apply(out, in);
    for (int i = 0; i < 32; i++) output[gid * 32 + i] = out[i];
}

// DEBUG: probe kernel that mirrors the OLD validate_verusclhash setup but
// loads input into a thread buffer FIRST, then calls verusclhash_sv2_2_inline.
// If this matches the OLD kernel byte-for-byte, the inline + thread-curBuf
// path is correct. If it doesn't, the bug is there.
kernel void verusclhash_inline_probe_kernel(
    device const uchar  *input_buf [[buffer(0)]],
    device uchar        *key_buf   [[buffer(1)]],
    device uint64_t     *output    [[buffer(2)]],
    device const uint64_t *params  [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    thread uchar buf[64];
    for (int i = 0; i < 64; i++) buf[i] = input_buf[i];
    output[gid] = verusclhash_sv2_2_inline(buf, key_buf, params[0]);
}

kernel void verus_hash_v2_kernel(
    device const uchar  *input_buf [[buffer(0)]],
    device uchar        *key_buf   [[buffer(1)]],
    device uchar        *output    [[buffer(2)]],
    device const uint64_t *params  [[buffer(3)]],   // [input_len, trace_enable]
    device uchar        *trace     [[buffer(4)]],   // 256 bytes if trace_enable
    uint gid [[thread_position_in_grid]])
{
    uint input_len = (uint)params[0];
    uint trace_enable = (uint)params[1];
    device uchar *key = key_buf + gid * KEY_SCRATCH_PER_THREAD;
    device uchar *out = output + gid * 32;

    // === Reset ===
    thread uchar curBuf[64];
    thread uchar result[64];
    for (int i = 0; i < 64; i++) curBuf[i] = 0;
    int curPos = 0;

    // === Write(data, len) ===
    uint pos = 0;
    while (pos < input_len) {
        int room = 32 - curPos;
        int remaining = (int)(input_len - pos);
        if (remaining >= room) {
            // Fill the 32-byte slot, hash, swap curBuf ↔ result
            for (int i = 0; i < room; i++) {
                curBuf[32 + curPos + i] = input_buf[pos + i];
            }
            haraka512_apply(result, curBuf);
            // Copy result[0..32] into curBuf[0..32] (rest will be overwritten
            // either by next data chunk or by FillExtra in Finalize2b).
            for (int i = 0; i < 32; i++) curBuf[i] = result[i];
            pos += room;
            curPos = 0;
        } else {
            // Partial chunk — append and exit
            for (int i = 0; i < remaining; i++) {
                curBuf[32 + curPos + i] = input_buf[pos + i];
            }
            curPos += remaining;
            pos = input_len;
        }
    }

    // TRACE checkpoint 1: curBuf after Write (64 bytes at trace[0..64])
    if (trace_enable) {
        for (int i = 0; i < 64; i++) trace[i] = curBuf[i];
        // also stash curPos at trace[252]
        trace[252] = (uchar)curPos;
    }

    // === Finalize2b ===
    // Step 1: FillExtra(curBuf) — copy curBuf[0..16] tiled into curBuf[32+curPos..64]
    {
        int left = 32 - curPos;
        int fpos = curPos;
        while (left > 0) {
            int len = (left > 16) ? 16 : left;
            for (int i = 0; i < len; i++) {
                curBuf[32 + fpos + i] = curBuf[i];
            }
            fpos += len; left -= len;
        }
    }

    // Step 2: GenNewCLKey(curBuf) — chain haraka256 from curBuf[0..32].
    // VERUS_KEYSIZE / 32 = 276 blocks; no extra bytes (8832 % 32 == 0).
    {
        thread uchar src[32];
        for (int i = 0; i < 32; i++) src[i] = curBuf[i];
        uint pkey_off = 0;
        for (int b = 0; b < 276; b++) {
            thread uchar tmp[32];
            haraka256_apply(tmp, src);
            for (int i = 0; i < 32; i++) {
                key[pkey_off + i] = tmp[i];
                src[i] = tmp[i];
            }
            pkey_off += 32;
        }
        // Duplicate first `refreshsize` bytes of key at key+VERUS_KEYSIZE for
        // the algorithm's refresh mechanism (the verusclhash loop reads here
        // for prand_off > VERUS_KEYSIZE - 32 cases).
        for (uint i = 0; i < VERUS_REFRESHSIZE; i++) {
            key[VERUS_KEYSIZE + i] = key[i];
        }
    }

    // TRACE checkpoint 2: first 32 bytes of generated key (haraka256 chain output[0])
    //                     + last 32 bytes of key (end of chain, ~276 blocks deep)
    if (trace_enable) {
        for (int i = 0; i < 32; i++) trace[64 + i] = key[i];
        for (int i = 0; i < 32; i++) trace[96 + i] = key[8832 - 32 + i];
    }

    // TRACE: dump curBuf RIGHT BEFORE verusclhash (post-FillExtra(curBuf))
    // at trace[168..232]. This is the input to verusclhash.
    if (trace_enable) {
        for (int i = 0; i < 64; i++) trace[168 + i] = curBuf[i];
    }

    // Step 3: intermediate = verusclhash_sv2_2(key, curBuf)
    uint64_t intermediate = verusclhash_sv2_2_inline(curBuf, key, VERUS_KEYMASK_BYTES);

    // TRACE checkpoint 3: intermediate at trace[160..168]
    if (trace_enable) {
        for (int i = 0; i < 8; i++) trace[160 + i] = (uchar)((intermediate >> (8*i)) & 0xff);
    }

    // Step 4: FillExtra(&intermediate) — fill tail with 8-byte intermediate, tiled
    {
        int left = 32 - curPos;
        int fpos = curPos;
        while (left > 0) {
            int len = (left > 8) ? 8 : left;
            for (int i = 0; i < len; i++) {
                curBuf[32 + fpos + i] = (uchar)((intermediate >> (8*i)) & 0xff);
            }
            fpos += len; left -= len;
        }
    }

    // (Previously dumped curBuf-pre-haraka512_keyed at trace[168..232], but
    // we repurposed that slot for curBuf-pre-verusclhash. Skip.)

    // Step 5: haraka512_keyed(out, curBuf, key + (intermediate & 0x1FF) * 16)
    {
        uint offset_units = (uint)(intermediate & 511);   // keyMask (8191) >> 4 = 511
        thread uchar hash[32];
        haraka512_keyed_apply(hash, curBuf, key, offset_units * 16);
        for (int i = 0; i < 32; i++) out[i] = hash[i];
    }
}

