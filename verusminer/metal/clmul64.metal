// clmul64.metal — direct port of clmul64() from
// canonical/verus_clhash_portable.cpp (the 4-bit-window carryless
// multiply that emulates AES-NI's _mm_clmulepi64_si128 / NEON's
// vmull_p64 on hardware without those instructions).
//
// Algorithm (window size s=4):
//   1. Precompute u[0..15]: u[k] = b · k under GF(2) — k acting as a
//      4-bit poly. Even k uses left-shift of u[k/2]; odd k = u[k-1] ^ b.
//   2. Multiply: for each 4-bit window of a, look up u[window] and XOR
//      it (shifted by window position) into the 128-bit result.
//   3. Repair: cleanup loop for high-bit carries — only matters when
//      a has bits in positions where (64-i) of b is 1. Pure XOR math.
//
// This is the genuinely-novel building block for verusclhash on the GPU
// since Metal has no carryless-multiply intrinsic. Once this is byte-
// perfect vs CPU, the rest of verusclhash is straight translation.
//
// Kernel I/O:
//   Input  buffer: N × 16 bytes = [a_lo, a_hi, b_lo, b_hi] little-endian
//                                 actually [a:uint64, b:uint64]
//   Output buffer: N × 16 bytes = [r0:uint64, r1:uint64]
//
// One thread = one (a, b) → (r0, r1) pair. The validator dispatches a
// batch of pairs and byte-diffs the outputs.

#include <metal_stdlib>
using namespace metal;

// Carryless 64×64 → 128-bit multiply. Output: lo→r0, hi→r1.
//
// Implementation note: MSL uint64_t left-shifts by 64 or more are UB,
// just like in C. The CPU code uses `tmp >> (64 - i)` where i starts
// at s=4, so 64-i ∈ [60, 56, 52, ..., 4] — never 0 and never 64.
// Same constraint here.
inline void clmul64_gpu(uint64_t a, uint64_t b,
                        thread uint64_t &r0, thread uint64_t &r1) {
    const uint s = 4;
    const uint two_s = 1u << s;        // 16
    const uint64_t smask = two_s - 1;   // 0x0f

    // Precomputation: u[k] = k * b under GF(2). u[k] is a 64-bit poly.
    uint64_t u[16];
    u[0] = 0;
    u[1] = b;
    for (uint i = 2; i < two_s; i += 2) {
        u[i]     = u[i >> 1] << 1;   // even: shift left (×x in GF)
        u[i + 1] = u[i] ^ b;          // odd:  add b
    }

    // Multiply. Each 4-bit window of a selects a u[k] to XOR into r
    // (shifted by window position).
    r0 = u[a & smask];     // first window only affects r0
    r1 = 0;
    for (uint i = s; i < 64; i += s) {
        uint64_t tmp = u[(a >> i) & smask];
        r0 ^= tmp << i;
        r1 ^= tmp >> (64u - i);   // 64-i ∈ [60..4], well-defined
    }

    // Repair pass: handles the high carries that the window mul missed.
    // For each bit i in [1, s-1], if bit (64-i) of b is 1, then bits of
    // a where (bitpos mod s) == i flow into the high word's bit (bitpos - i).
    uint64_t m = 0xEEEEEEEEEEEEEEEEUL;   // s=4 → 16 nibbles of 0b1110
    for (uint i = 1; i < s; i++) {
        uint64_t tmp = (a & m) >> i;
        m &= (m << 1);                    // narrow mask each iter
        // if (b >> (64-i)) & 1, contribute tmp into r1
        uint64_t ifmask = (uint64_t)(0) - (uint64_t)((b >> (64u - i)) & 1ul);
        r1 ^= (tmp & ifmask);
    }
}

// Kernel: each thread reads (a, b) at gid*16 bytes, writes (r0, r1) at
// gid*16 bytes of the output buffer.
kernel void clmul64_kernel(
    device const uint64_t *inputs  [[buffer(0)]],   // [a0, b0, a1, b1, ...]
    device uint64_t       *outputs [[buffer(1)]],   // [r0_0, r1_0, r0_1, r1_1, ...]
    uint gid [[thread_position_in_grid]])
{
    uint64_t a = inputs[gid * 2 + 0];
    uint64_t b = inputs[gid * 2 + 1];
    uint64_t r0, r1;
    clmul64_gpu(a, b, r0, r1);
    outputs[gid * 2 + 0] = r0;
    outputs[gid * 2 + 1] = r1;
}
