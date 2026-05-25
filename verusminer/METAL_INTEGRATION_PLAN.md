# Metal verusclhash integration — pickup plan

State of the world as of v0.19.0: every cryptographic primitive
verusclhash_sv2_2 needs is on the GPU and proven byte-perfect against
the CPU reference. What's left is the integration: wire those primitives
into the 32-iteration selector loop body so the GPU produces the same
64-bit hash as `verusclhash_sv2_2_port` for the same (key, input) pair.

This doc exists so the next session can pick up cold.

## Primitives status (all done, all validated)

| Primitive | Metal file | Validator | Vectors |
|-----------|-----------|-----------|---------|
| haraka256 | `metal/haraka256_v2.metal` | `validate_haraka256` | 4 (incl. paper) |
| haraka512 | `metal/haraka512_v2.metal` | `validate_haraka512` | 4 (incl. paper) |
| haraka512_keyed | `metal/haraka512_keyed_v2.metal` | `validate_haraka512_keyed` | 9 |
| clmul64 | `metal/clmul64.metal` | `validate_clmul` | 1032 |
| mulhrs_epi16 | `metal/verusclhash_primitives.metal` | `validate_primitives` | 517 |
| precompReduction64 | `metal/verusclhash_primitives.metal` | `validate_primitives` | 518 |

The only thing missing is the **glue** — the `__verusclmulwithoutreduction64alignedrepeat_sv2_2_port` translation.

## Reference: what we're translating

**File:** `cpu/canonical/verus_clhash_portable.cpp`
**Function:** `__verusclmulwithoutreduction64alignedrepeat_sv2_2_port` (lines 881–1169)
**Wrapper:** `verusclhash_sv2_2_port` (lines 1192–1199)

The wrapper is trivial:
```cpp
acc = __verusclmulwithoutreduction64alignedrepeat_sv2_2_port(rs64, string, keyMask, pMoveScratch);
acc ^= lazyLengthHash_port(1024, 64);      // = clmul64(64, 1024) packed as __m128i
return precompReduction64_port(acc);       // already have this in primitives
```

So the kernel needs:
1. The 32-iter loop (the hard part)
2. XOR with `lazyLengthHash_port(1024, 64)` — single clmul we precompute on the host
3. `precompReduction64` — already validated

## The 32-iter loop — outer structure

```cpp
acc = key[keyMask + 2];        // initial accumulator
for (i in 0..32) {
    selector = (uint64_t)acc.lo;
    prand_idx   = (selector >> 5)  & keyMask;   // both index into key[]
    prandex_idx = (selector >> 32) & keyMask;
    pbuf_offset = selector & 3;                  // pbuf_copy[0..3] starting offset
    switch (selector & 0x1c) {
        case 0x00: ... 8 cases ...
        case 0x04: ...
        case 0x08: ...
        case 0x0c: ...
        case 0x10: ...
        case 0x14: ...
        case 0x18: ...
        case 0x1c: ...
    }
    // pMoveScratch is only used to LATER restore the key — on GPU we
    // can either (a) make a per-thread copy of the key up front, or
    // (b) skip restoration entirely (each hash is self-contained).
}
return acc;
```

## Per-case translation notes

For each case, write the Metal version of the C body using the primitives
that are already validated. **Reference the CPU source line numbers when
debugging mismatches** — they tell you exactly which operation is wrong.

### case 0x00 (CPU line 912–935) — START HERE
- 2× clmul + 2× mulhrs + 2× R/W
- No inner loop, no branch — simplest case to validate end-to-end first
- After this works, build out the validator harness then add the others

### case 0x04 (CPU line 936–960)
- 3× clmul + 2× mulhrs + 2× R/W
- Same shape as 0, just one more clmul

### case 0x08 (CPU line 961–984)
- 2× clmul + 2× mulhrs + 2× R/W
- Same shape as 0

### case 0x0c (CPU line 986–1028)
- **Branchy!** `if (dividend & 1)` splits into two sub-paths
- Uses **int64 % int32** modulo — `selector` cast to int32 is the divisor
- MSL supports `%` on int64 natively, but watch for sign behavior

### case 0x10 (CPU line 1030–1058)
- Uses **AES2_EMU + MIX2_EMU** macros from the canonical source
  - AES2_EMU(s0, s1, rci) = 4 aesenc rounds with round keys from `prand`
  - MIX2_EMU(s0, s1) = interleave low/high 32-bit lanes (same as haraka256's MIX2)
- Round keys come from the key buffer at `prand` offset, NOT the haraka_rc table
- This is exactly what `haraka512_keyed`'s `aesenc_tt_keyed` does — reuse it

### case 0x14 (CPU line 1060–1103)
- **Inner do-while loop**: `rounds = selector >> 61` → loops 1 to 8 times (rounds in 1..8 then 0)
- Branchy: `if (selector & (0x10000000 << rounds))` toggles between clmul path and AES path
- AES path uses AES2_EMU with `roundidx` derived from a counter

### case 0x18 (CPU line 1105–1143)
- Same do-while shape as 0x14 but with modulo + clmul instead of AES
- Cleanest mix of all the primitives

### case 0x1c (CPU line 1144–1165)
- 1× clmul + 2× mulhrs + 2× R/W
- Straightforward — good second case to validate after 0

## Recommended implementation order

1. **Write the skeleton.** A Metal kernel that takes `(input[64], key[~8800])` and produces a 64-bit hash. Implement ONLY case 0 (`selector & 0x1c == 0`) — for all other case values, write `// TODO` and break.
2. **Write the validator.** Swift harness that:
   - Generates a deterministic random key via `haraka_S` (matches CPU `verusclhasher` construction)
   - Picks (input, initial-acc) combinations that **force the selector & 0x1c to land on case 0** for all 32 iters (you may need to skip the loop and just test ONE iter of case 0 first)
   - Runs CPU `verusclhash_sv2_2_port` with the same key + input
   - Diffs the GPU output 64-bit hash vs CPU
3. **Validate case 0**, commit.
4. **Add case 0x04, validate, commit.** Same pattern: test inputs that force that case.
5. **Add cases 0x08, 0x1c** (the other "simple" ones).
6. **Add case 0x10** (uses haraka512_keyed primitives).
7. **Add cases 0x0c, 0x14, 0x18** (the branchy ones with modulo / inner loops).
8. **Mining-loop integration**: batched dispatch with N threads = N nonces, CPU prep loop, share submission gated on CPU-vs-GPU agreement for the first M hashes per job.

## Key data shape

The key buffer is a `__m128i[]` array allocated by `verusclhasher::operator()`
(see `cpu/canonical/verus_clhash.h` line 165 and following). For Verus 2.2:

- `VERUSKEYSIZE = 1024*8 + 40*16 = 8832 bytes` = 552 × __m128i = 2208 × uint32
- `keyMask` (after `>>= 4`) tells you the indexable range
- Last `keyMask + 2` slot holds the **initial acc** (special, never xored before being read)

For GPU, pass the key as a `device const uint *` (so the validator can
read/write it). Each GPU thread should get its own copy in private memory
or its own slice of a per-thread region of a shared device buffer.

## Validator harness — bootstrap pattern

```swift
// 1. Seed the same key on CPU and GPU
let seed: [UInt8] = ...   // some deterministic seed
var key = [UInt8](repeating: 0, count: 8832)
haraka_S(&key, 8832, seed, seed.count)   // CPU computes the key

// 2. Pick an input
let input: [UInt8] = ... // 64 bytes

// 3. CPU reference
var scratchPtrs = [UnsafeMutablePointer<__m128i>?](repeating: nil, count: 64)
let cpuHash = verusclhash_sv2_2_port(&key, input, 8192, &scratchPtrs)

// 4. GPU
let gpuHash = runGPUverusclhash(key: key, input: input)

// 5. Diff
assert(cpuHash == gpuHash)
```

The `pMoveScratch` parameter is a write-only restoration log. The GPU
doesn't need to populate it (we just don't restore the key — each call
is functionally pure since key starts the same).

## Files to create

- `metal/verusclhash_sv2_2.metal` — the integrated kernel
- `metal/validate_verusclhash.swift` — CPU↔GPU diff harness
- `cpu/canonical/verusclhash_shim.cpp` — extend the existing clmul_shim
  with `verusclhash_sv2_2_wrap()` so Swift can call the C++ function
  without dealing with __m128i\*\* in Swift signature

## Estimated time

- Skeleton + case 0 + validator: 2-3 hours
- Cases 0x04, 0x08, 0x1c, 0x10: 1-2 hours each
- Cases 0x0c, 0x14, 0x18: 2-3 hours each (branchy, modulo, inner loops)
- Mining-loop integration: 1-2 days

Total: ~1 week of focused work to get from "all primitives validated" to
"GPU mining shares accepted".

## Performance expectations

CPU mining today: 3.94 MH/s on 7 threads (~560 KH/s/thread)
M5 GPU theoretical: ~10 P-cores × ~16 ALUs × ~1.5 GHz ÷ (instructions per hash)

For VerusHash 2.2, each hash is roughly:
- 4 haraka512 calls (per Verus2.2 mining pipeline) = ~6000 ops
- 16 verusclhash calls × (1× haraka512 + 32× loop body) = ~250000 ops

So ~256k ops/hash × 1M hashes = 2.56e11 ops. At M5's ~1 TFLOPS GPU compute,
that's ~256ms per million hashes = ~3.9 MH/s.

That matches the CPU baseline almost exactly — so the GPU win is in
**parallelism**, not per-hash speed. Need to batch dispatch many hashes
to win. Realistic GPU target: 12-20 MH/s (3-5× CPU) once batched.

This is consistent with VerusHash's design intent: it's specifically
balanced to be hard to accelerate on GPUs vs CPUs. The win is "free"
hashpower on top of CPU, not a 100× speedup.
