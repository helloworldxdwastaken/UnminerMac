// verusclhash_sv2_2.metal — full integrated GPU port of
// __verusclmulwithoutreduction64alignedrepeat_sv2_2_port (CPU lines 881..1169
// of canonical/verus_clhash_portable.cpp) + the outer verusclhash_sv2_2_port
// wrapper (XOR with lazyLengthHash + precompReduction64).
//
// Every cryptographic primitive used here is already validated byte-perfect
// against the CPU reference in earlier validators:
//   - clmul64_gpu          (validate_clmul, 1032 vectors)
//   - mulhrs_8x            (validate_primitives, 517 vectors)
//   - precomp_reduction64  (validate_primitives, 518 vectors)
//   - aesenc_tt_keyed      (validate_haraka512_keyed, 9 vectors)
//   - mix2 (= MIX2 from haraka256/512) trivial
//
// What this file adds is GLUE — the 32-iteration selector loop with 8 switch
// cases over (selector & 0x1c). No new crypto, just orchestration.
//
// Kernel I/O:
//   buffer 0: input  — 64 bytes (4 × 16-byte vectors)
//   buffer 1: key    — at least (keyMask + 34) * 16 bytes, MUTATED in place
//                      (the algorithm read-mutates the key during the hash;
//                      next call must start from a fresh copy)
//   buffer 2: output — 1 × uint64_t (the verusclhash result)
//   buffer 3: params — [keyMask_lo, keyMask_hi] (uint32 pair = uint64 keyMask
//                      in bytes, as the CPU receives it; we >>= 4 internally)
//
// Single-thread kernel for now — one dispatch == one verusclhash call. Mining
// integration will dispatch N threads each with its own key copy.

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

inline void v128_store(device uchar *p, vec128 v) {
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
// THE MAIN EVENT: __verusclmulwithoutreduction64alignedrepeat_sv2_2
// CPU source lines 881..1169.
// ===================================================================
kernel void verusclhash_sv2_2_kernel(
    device const uchar  *input_buf [[buffer(0)]],   // 64 bytes
    device uchar        *key_buf   [[buffer(1)]],   // mutable key (per-thread copy)
    device uint64_t     *output    [[buffer(2)]],   // result u64 per thread
    device const uint64_t *params  [[buffer(3)]],   // [keyMask_bytes]
    uint gid [[thread_position_in_grid]])
{
    // Load the 4-vector input
    vec128 buf0 = v128_load(input_buf + 0 * 16);
    vec128 buf1 = v128_load(input_buf + 1 * 16);
    vec128 buf2 = v128_load(input_buf + 2 * 16);
    vec128 buf3 = v128_load(input_buf + 3 * 16);

    // pbuf_copy[4] — first 2 are XOR-mixed, last 2 are pass-through
    vec128 pbuf_copy[4];
    pbuf_copy[0] = v128_xor(buf0, buf2);
    pbuf_copy[1] = v128_xor(buf1, buf3);
    pbuf_copy[2] = buf2;
    pbuf_copy[3] = buf3;

    // keyMask is passed in BYTES; the CPU does `keyMask >>= 4` to convert
    // to __m128i indices. We keep it as bytes everywhere for clarity, with
    // explicit << 4 / >> 4 conversions when indexing.
    uint64_t keyMask_bytes = params[0];
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
    uint64_t hash = precomp_reduction64_v128(acc);
    output[gid] = hash;
}
