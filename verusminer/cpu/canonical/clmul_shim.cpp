// clmul_shim.cpp — extern "C" wrappers around the C++-name-mangled
// helpers in verus_clhash_portable.cpp, so Swift can call them via
// @_silgen_name without dealing with Itanium mangling.

#include <stdint.h>
#include <cstring>

// Pull in the same header chain verus_clhash_portable.cpp uses, so
// __m128i is the same opaque type the wrapped helpers expect.
#include "verus_hash.h"

extern void clmul64(uint64_t a, uint64_t b, uint64_t *r);
extern __m128i _mm_mulhrs_epi16_emu(__m128i a, __m128i b);

// Full verusclhash entry point (lives in verus_clhash_portable.cpp).
extern "C" uint64_t verusclhash_sv2_2_port(void *random, const unsigned char buf[64],
                                            uint64_t keyMask, __m128i **pMoveScratch);

// NOTE: most of the _mm_*_emu helpers in verus_clhash_portable.cpp are
// declared `inline` and have NO exported symbol — so we can't `extern`
// them and link. Instead, re-implement the small ones inline here using
// raw byte ops on the __m128i layout (which is layout-compatible with
// uint8_t[16] on both x86-64 and arm64).

extern "C" {

// clmul64: writes r[0] = low 64 bits of (a ⊗ b), r[1] = high 64 bits,
// where ⊗ is GF(2)[x] carryless multiplication.
void clmul64_wrap(uint64_t a, uint64_t b, uint64_t *r) {
    clmul64(a, b, r);
}

// mulhrs_epi16: 8-lane signed 16-bit fixed-point multiply with rounding.
// in_a, in_b, out are all 16-byte buffers (8 × int16_t LE).
void mulhrs_epi16_wrap(const uint8_t *in_a, const uint8_t *in_b, uint8_t *out) {
    __m128i a, b, r;
    std::memcpy(&a, in_a, 16);
    std::memcpy(&b, in_b, 16);
    r = _mm_mulhrs_epi16_emu(a, b);
    std::memcpy(out, &r, 16);
}

// precompReduction64: takes a 16-byte vector, returns 16 bytes where
// the low 8 are the reduced 64-bit hash (high 8 = garbage per the
// CPU reference). Re-implementation of precompReduction64_si128_port —
// the helpers it depends on are inline (no link symbol), so we inline
// the byte-level equivalents directly here. Bit-exact same algorithm.
void precomp_reduction64_wrap(const uint8_t *in_A, uint8_t *out) {
    // 1. C = 0x1B as low 64 of a 16-byte vec (high = 0)
    uint8_t C[16];
    std::memset(C, 0, 16);
    C[0] = 0x1B;

    // 2. Q2 = clmul(A.hi, C.lo) — uses imm=0x01 = pick a's HIGH u64, b's LOW u64
    uint64_t aHi = 0, cLo = 0;
    for (int i = 0; i < 8; i++) aHi |= ((uint64_t)in_A[i + 8]) << (8 * i);
    for (int i = 0; i < 8; i++) cLo |= ((uint64_t)C[i])        << (8 * i);
    uint64_t q2_r[2];
    clmul64(aHi, cLo, q2_r);
    uint8_t Q2[16];
    for (int i = 0; i < 8; i++) {
        Q2[i]     = (uint8_t)((q2_r[0] >> (8 * i)) & 0xff);
        Q2[i + 8] = (uint8_t)((q2_r[1] >> (8 * i)) & 0xff);
    }

    // 3. shifted = srli_si128(Q2, 8) — right-shift by 8 BYTES
    //    low 8 ← Q2[8..16], high 8 ← 0
    uint8_t Q2sh[16];
    for (int i = 0; i < 8; i++)  Q2sh[i]     = Q2[i + 8];
    for (int i = 8; i < 16; i++) Q2sh[i]     = 0;

    // 4. LUT lookup: for each byte of Q2sh, if MSB set output 0,
    //    else output LUT[byte & 0x0f]
    static const uint8_t LUT[16] = {
        0x00, 0x1b, 0x36, 0x2d, 0x6c, 0x77, 0x5a, 0x41,
        0xd8, 0xc3, 0xee, 0xf5, 0xb4, 0xaf, 0x82, 0x99
    };
    uint8_t Q3[16];
    for (int i = 0; i < 16; i++) {
        Q3[i] = (Q2sh[i] & 0x80) ? 0 : LUT[Q2sh[i] & 0x0f];
    }

    // 5. final = (Q2 XOR A) XOR Q3
    for (int i = 0; i < 16; i++) {
        out[i] = (Q2[i] ^ in_A[i]) ^ Q3[i];
    }
}


// Friendly wrapper around verusclhash_sv2_2_port that handles the
// pMoveScratch bookkeeping. Caller passes:
//   - key      — VERUSKEYSIZE=8832 byte buffer (mutated in place!)
//   - input    — 64 byte buffer
//   - keyMask  — usually 8192 (= VERUSKEYSIZE - 40*16 - 1 rounded down,
//                actually 0x2000 = 8192 for default Verus 2.2 config)
// Returns the 64-bit verusclhash output.
uint64_t verusclhash_sv2_2_wrap(uint8_t *key, const uint8_t *input, uint64_t keyMask) {
    // pMoveScratch records mutated key slots so caller can restore them.
    // We allocate enough for 32 iters × 2 ptrs = 64 entries.
    // pMoveScratch points to a writable array of __m128i*; the function
    // advances its local copy as it logs mutated slots. We discard.
    __m128i *scratch[80];
    __m128i **scratchPtr = scratch;
    return verusclhash_sv2_2_port(key, input, keyMask, scratchPtr);
}

} // extern "C"
