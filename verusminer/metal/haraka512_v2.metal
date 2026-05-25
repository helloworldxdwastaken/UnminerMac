// haraka512_v2.metal — clean port of haraka512_port + TRUNCSTORE from
// haraka_portable.c, using the SAME T-table aesenc that haraka256_v2.metal
// validated byte-perfect against the CPU reference.
//
// Differences from haraka256_v2:
//   - 4 halves of 16 bytes (4 uint32 each) instead of 2 → state is 64 bytes
//   - Each AES sub-round consumes 4 round constants (one per half)
//   - All 40 round constants are used (haraka256 only uses the first 20)
//   - Mixing is MIX4 from haraka.h, not MIX2
//   - Output is TRUNCATED to 32 bytes: takes the upper halves of s0,s1 and
//     the lower halves of s2,s3 (mirrors haraka_portable.c lines 386-389)
//
// AES round indexing (matches haraka_portable.c haraka512_perm):
//   for i in 0..5:        # outer rounds
//     for j in 0..2:      # 2 AES sub-rounds per outer round
//       half k in 0..4 gets rc[8*i + 4*j + k]
//   total: 5 * 2 * 4 = 40 round constants, all consumed
//
// Verified against canonical Haraka v2 test vector (haraka.c testvector512):
//   input  = 0x00,0x01,...,0x3f
//   output = be 7f 72 3b 4e 80 a9 98 13 b2 92 28 7f 30 6f 62
//            5a 6d 57 33 1c ae 5f 34 dd 92 77 b0 94 5b e2 aa

#include <metal_stdlib>
using namespace metal;

// SBOX — AES SubBytes
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

// RC — same 160-entry table as haraka256_v2 (40 round constants × 4 uint32 LE).
// haraka256 uses RC[0..80]; haraka512 uses ALL 160.
constant uint RC[160] = {
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

// GF(2^8) doubling — cast to int to dodge MSL uchar promotion truncation
inline uchar gf2(uchar x) {
    return (uchar)((((int)x) << 1) ^ ((x & 0x80) ? 0x1b : 0));
}

// T_row(b, row): produces the column that SubBytes+MixColumns yields when
// SubBytes(b) is placed at `row` of an otherwise-zero AES column.
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

// AES round (T-table form). Identical to the haraka256_v2 implementation.
inline void aesenc_tt(thread uint *s, constant uint *rk) {
    uint x0 = s[0], x1 = s[1], x2 = s[2], x3 = s[3];
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

    s[0] = y0 ^ rk[0];
    s[1] = y1 ^ rk[1];
    s[2] = y2 ^ rk[2];
    s[3] = y3 ^ rk[3];
}

inline void ld64(const device uchar *src, thread uint *w) {
    for (int i = 0; i < 16; i++) {
        uint o = i * 4;
        w[i] = (uint)src[o]
             | ((uint)src[o+1] <<  8)
             | ((uint)src[o+2] << 16)
             | ((uint)src[o+3] << 24);
    }
}

// Store 8 bytes (1 u64 = 2 uint32 LE) at dst
inline void st64_pair(device uchar *dst, uint lo, uint hi) {
    dst[0] =  lo        & 0xff;
    dst[1] = (lo >>  8) & 0xff;
    dst[2] = (lo >> 16) & 0xff;
    dst[3] = (lo >> 24) & 0xff;
    dst[4] =  hi        & 0xff;
    dst[5] = (hi >>  8) & 0xff;
    dst[6] = (hi >> 16) & 0xff;
    dst[7] = (hi >> 24) & 0xff;
}

// MIX4 — direct transcription of haraka.h MIX4 using uint columns instead
// of __m128i. Each half is a uint[4] where index 0 is the low-address u32.
//
// _mm_unpacklo_epi32(a, b) = { a[0], b[0], a[1], b[1] }
// _mm_unpackhi_epi32(a, b) = { a[2], b[2], a[3], b[3] }
inline void mix4(thread uint *s0, thread uint *s1,
                 thread uint *s2, thread uint *s3) {
    uint a0=s0[0], a1=s0[1], a2=s0[2], a3=s0[3];
    uint b0=s1[0], b1=s1[1], b2=s1[2], b3=s1[3];
    uint c0=s2[0], c1=s2[1], c2=s2[2], c3=s2[3];
    uint d0=s3[0], d1=s3[1], d2=s3[2], d3=s3[3];

    // After steps 1..4:
    //   tmp = (a0, b0, a1, b1)         ← unpacklo(s0_orig, s1_orig)
    //   s0' = (a2, b2, a3, b3)         ← unpackhi(s0_orig, s1_orig)
    //   s1' = (c0, d0, c1, d1)         ← unpacklo(s2_orig, s3_orig)
    //   s2' = (c2, d2, c3, d3)         ← unpackhi(s2_orig, s3_orig)
    uint t0 = a0, t1 = b0, t2 = a1, t3 = b1;   // tmp
    uint p0 = a2, p1 = b2, p2 = a3, p3 = b3;   // s0'
    uint q0 = c0, q1 = d0, q2 = c1, q3 = d1;   // s1'
    uint r0 = c2, r1 = d2, r2 = c3, r3 = d3;   // s2'

    // Step 5: s3 = unpacklo(s0', s2') = (p0, r0, p1, r1) = (a2, c2, b2, d2)
    s3[0] = p0; s3[1] = r0; s3[2] = p1; s3[3] = r1;
    // Step 6: s0 = unpackhi(s0', s2') = (p2, r2, p3, r3) = (a3, c3, b3, d3)
    s0[0] = p2; s0[1] = r2; s0[2] = p3; s0[3] = r3;
    // Step 7: s2 = unpackhi(s1', tmp) = (q2, t2, q3, t3) = (c1, a1, d1, b1)
    s2[0] = q2; s2[1] = t2; s2[2] = q3; s2[3] = t3;
    // Step 8: s1 = unpacklo(s1', tmp) = (q0, t0, q1, t1) = (c0, a0, d0, b0)
    s1[0] = q0; s1[1] = t0; s1[2] = q1; s1[3] = t1;
}

// Haraka512: perm + feed-forward XOR + TRUNCSTORE.
//   - 64-byte input  per thread at inputs + gid*64
//   - 32-byte output per thread at outputs + gid*32
kernel void haraka512_kernel(
    device const uchar *inputs  [[buffer(0)]],
    device uchar       *outputs [[buffer(1)]],
    device atomic_uint *count   [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    uint w[16];
    ld64(inputs + gid * 64, w);

    // 4 halves: s0=w[0..4], s1=w[4..8], s2=w[8..12], s3=w[12..16]
    uint s0[4] = { w[ 0], w[ 1], w[ 2], w[ 3] };
    uint s1[4] = { w[ 4], w[ 5], w[ 6], w[ 7] };
    uint s2[4] = { w[ 8], w[ 9], w[10], w[11] };
    uint s3[4] = { w[12], w[13], w[14], w[15] };

    for (uint i = 0; i < 5; i++) {
        // Each outer round uses 8 round constants (4 halves × 2 sub-rounds),
        // each RC is 4 uint32, so 8 RCs = 32 uint32 entries.
        uint base = i * 32;
        // Sub-round j=0 — RCs 8i+0..8i+3
        aesenc_tt(s0, RC + base +  0);
        aesenc_tt(s1, RC + base +  4);
        aesenc_tt(s2, RC + base +  8);
        aesenc_tt(s3, RC + base + 12);
        // Sub-round j=1 — RCs 8i+4..8i+7
        aesenc_tt(s0, RC + base + 16);
        aesenc_tt(s1, RC + base + 20);
        aesenc_tt(s2, RC + base + 24);
        aesenc_tt(s3, RC + base + 28);

        mix4(s0, s1, s2, s3);
    }

    // Feed-forward XOR with the original 64-byte input
    s0[0] ^= w[ 0]; s0[1] ^= w[ 1]; s0[2] ^= w[ 2]; s0[3] ^= w[ 3];
    s1[0] ^= w[ 4]; s1[1] ^= w[ 5]; s1[2] ^= w[ 6]; s1[3] ^= w[ 7];
    s2[0] ^= w[ 8]; s2[1] ^= w[ 9]; s2[2] ^= w[10]; s2[3] ^= w[11];
    s3[0] ^= w[12]; s3[1] ^= w[13]; s3[2] ^= w[14]; s3[3] ^= w[15];

    // TRUNCSTORE — pull 4 × 8 bytes from specific halves into a 32-byte out
    //   out[ 0.. 8] = s0[8..16]   (upper u64 of s0 = uint32 lanes 2,3)
    //   out[ 8..16] = s1[8..16]   (upper u64 of s1)
    //   out[16..24] = s2[0.. 8]   (lower u64 of s2 = uint32 lanes 0,1)
    //   out[24..32] = s3[0.. 8]   (lower u64 of s3)
    device uchar *out = outputs + gid * 32;
    st64_pair(out +  0, s0[2], s0[3]);
    st64_pair(out +  8, s1[2], s1[3]);
    st64_pair(out + 16, s2[0], s2[1]);
    st64_pair(out + 24, s3[0], s3[1]);

    atomic_fetch_add_explicit(count, 1, memory_order_relaxed);
}
