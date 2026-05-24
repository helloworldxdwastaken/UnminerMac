# verusminer — research notes

Findings from prior-art and source-code review before writing any miner code. Captured here so future maintainers (and re-entry sessions) don't have to redo the survey.

## TL;DR — what we found that changes the plan

Original estimate: 6–10 weeks total. **Revised estimate: 2–4 weeks** because most of phase 1's hard work is already done upstream:

| Phase | Original estimate | Revised | Reason |
|---|---|---|---|
| 1 — CPU NEON Haraka + VerusHash | ~1 week | **2–4 days** | VerusCoin source ships with `sse2neon.h` shim — Haraka + verus_clhash compile on ARM64 unmodified |
| 2 — Stratum client | ~1 week | ~1 week | Still custom work; can crib from cpuminer-opt's stratum.c |
| 3 — UnminerMac integration | ~3-5 days | ~2–3 days | Phase 0 already shipped the dispatch wiring |
| 4 — Metal compute shader | 2–4 weeks | **2–4 weeks** | Unchanged. Bit-sliced AES in MSL is the real research. Can study MacMetal Miner's SHA-256 kernel as architecture template. |
| 5 — Testing + tuning + release | 1–2 weeks | 1–2 weeks | Unchanged |

## Reference repositories cloned + audited

| Repo | License | What we got from it |
|---|---|---|
| [VerusCoin/VerusCoin](https://github.com/VerusCoin/VerusCoin) | MIT | **Gold standard**: `src/crypto/verus_hash.{cpp,h}`, `haraka.{c,h}`, `haraka_portable.{c,h}`, `verus_clhash.{cpp,h}` — official VerusHash 2.x implementation with `sse2neon.h` shim built in for ARM64. Should compile on M5 directly. |
| [MacMetalMiner/MacMetal-Miner](https://github.com/MacMetalMiner/MacMetal-Miner) | MIT | **Phase 4 template**: a working Swift+Metal miner doing SHA-256d on Apple Silicon at 1.2 GH/s (M1) → 7 GH/s (M4 Pro). Kernel pattern in `SHA256.metal` is reusable verbatim for VerusHash dispatch. |
| [DeckerSU/verushash-example](https://github.com/DeckerSU/verushash-example) | (no license file) | Standalone C example. x86-only (uses `-mavx2 -maes`). Useful for understanding the high-level driver — building the 1488-byte header, validating hashes — but not directly portable. |
| [hellcatz/verusProxy](https://github.com/hellcatz/verusProxy) | GPL-ish | Stratum proxy between Verus daemon and pools. Useful **phase 2 reference** for stratum framing/jobs/share format. |
| [JayDDee/cpuminer-opt](https://github.com/JayDDee/cpuminer-opt) | GPL v2 | Has full ARM64/NEON support (since v23.5) — but does NOT support VerusHash 2.x. Their `algo/lyra2/` and similar can serve as a NEON optimization template. |
| [monkins1010/AMDVerusCoin](https://github.com/monkins1010/AMDVerusCoin) | (legacy) | OpenCL VerusHash for AMD GPUs. Version of VerusHash unclear from README. Kernels might be portable to Metal but architecture differs. |

## Key architectural finding: MacMetal Miner's kernel pattern

Their `SHA256.metal` kernel and Swift dispatcher are directly applicable. The structure of `sha256_mine`:

```metal
kernel void sha256_mine(
    device uchar* headerBase    [[buffer(0)]],
    device uint* nonceStart     [[buffer(1)]],
    device atomic_uint* hashCount [[buffer(2)]],
    device atomic_uint* resultCount [[buffer(3)]],
    device MiningResult* results [[buffer(4)]],
    device uint* target          [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    uchar header[80];
    /* copy headerBase[0..76] into header */
    uint nonce = nonceStart[0] + gid;
    /* splice nonce into header[76..80] */

    uint hash[8];
    sha256_80(header, hash);              // ← the algorithm-specific step
    sha256_32(hash, hash);                // SHA-256d second pass

    atomic_fetch_add_explicit(hashCount, 1, ...);

    if (hash_below_target(hash, target)) {
        uint idx = atomic_fetch_add_explicit(resultCount, 1, ...);
        results[idx].nonce = nonce;
        memcpy(results[idx].hash, hash, 32);
    }
}
```

**For VerusHash:** swap `sha256_80(...)` for `verushash_v2(...)`. Everything else (header layout, nonce iteration, target comparison, atomic counters, result collection) carries over.

Their Swift dispatcher uses `dispatchThreadgroups` with a configurable batch size, reads back the result buffer after each batch, submits found shares via Stratum. Same model fits VerusHash.

## VerusCoin source layout (what we'll copy into `verusminer/cpu/`)

```
VerusCoin/src/crypto/
├── verus_hash.cpp        ← CVerusHashV2::Hash() — main entry
├── verus_hash.h          ← class declarations
├── haraka.c              ← Haraka with SSE intrinsics (via sse2neon on ARM)
├── haraka.h              ← Haraka declarations, includes sse2neon.h when on ARM
├── haraka_portable.c     ← Portable C fallback (no SIMD)
├── haraka_portable.h
├── verus_clhash.cpp      ← Carryless hash (PCLMUL on x86, emulated on ARM)
├── verus_clhash.h
├── verus_clhash_portable.cpp ← Portable CLHash fallback
└── (sse2neon.h)          ← SSE-to-NEON shim, bundled in VerusCoin compat/
```

**Critical detail**: VerusCoin's `haraka.h` does:
```c
#if defined(__arm__) || defined(__aarch64__)
#include "crypto/sse2neon.h"
#else
#include "immintrin.h"
#endif
```

So the same source compiles for x86 (real SSE/AES-NI) and ARM64 (NEON via sse2neon translation). **Apple Silicon's ARMv8 hardware AES extensions are accessible through this path.**

## Phase 1 build recipe (drafted)

```bash
cd verusminer/cpu

# Copy the 8 files from VerusCoin source
cp ../../tmp/research-clones/VerusCoin/src/crypto/{verus_hash,haraka,haraka_portable,verus_clhash,verus_clhash_portable}.{c,cpp,h} . 2>/dev/null
cp ../../tmp/research-clones/VerusCoin/src/compat/sse2neon.h .

# Build with native ARMv8 crypto extensions
clang++ -O3 -march=armv8-a+crypto+sha2+aes \
        -DHAVE_SSE2NEON=1 \
        verus_hash.cpp haraka.c haraka_portable.c \
        verus_clhash.cpp verus_clhash_portable.cpp \
        main.cpp \
        -o verusminer

./verusminer --bench         # measure raw MH/s on M5
./verusminer --validate      # check against known test vectors
```

## Known test vectors

We need test vectors to validate any implementation. Sources to check:

1. The VerusCoin test suite (`src/test/`) has unit tests for Haraka and VerusHash.
2. The Haraka v2 paper has reference input → output pairs.
3. DeckerSU's `main.c` contains hardcoded test cases.

**Action item**: extract test vectors before writing code. Implementing crypto without test vectors is how you ship wrong-but-fast hashes that get every share rejected.

## Verus pool options (phase 2 target)

| Pool | URL | Fee | Hashrate | Notes |
|---|---|---|---|---|
| **LuckPool** (US) | `na.luckpool.net:3958` (SSL stratum) | 1% | 136 GH (largest) | Most-tested by upstream tools |
| **LuckPool** (EU) | `eu.luckpool.net:3956` | 1% | — | EU latency |
| **Zergpool** | `verushash.mine.zergpool.com:5440` | 0.5% | — | Multi-coin auto-exchange |
| **MiningPoolStats** stats | https://miningpoolstats.stream/veruscoin | — | — | Live network hashrate dashboard |

For phase 2 development, **LuckPool is the obvious choice**: largest, single-coin, well-documented stratum. The `hellcatz/verusProxy` tool is built specifically to bridge Verus daemons to LuckPool — its source documents the exact wire protocol.

## Metal phase 4 — what we'd actually write

Apple GPU has no hardware AES (confirmed in our [Metal AES bench](https://helloworldxdwastaken.github.io/UnminerMac/research.html)). So the Metal kernel needs **bit-sliced AES** — AES implemented in pure boolean operations across 8 parallel state lanes per thread, no S-box lookups. References:

- **Käsper-Schwabe 2009 bit-sliced AES** ([paper](https://eprint.iacr.org/2009/129)) — the canonical algorithm-level reference
- **VECTI/dolphin-emu's bit-sliced AES** — a real-world adaptation that runs on GPU compute APIs
- **Apple's "Optimizing Performance with the Metal Profiler"** doc — for tuning the actual kernel once it works

The expected complexity for phase 4 is **3000-5000 lines of MSL** plus a Swift dispatcher modeled on MacMetal Miner. Realistic timeline: 2-4 weeks with focused work.

## Economic update

Re-checked Verus pool stats: **136 GH/s total network hashrate** (per miningpoolstats.stream). At our phase-1 expected M5 hashrate of ~3 MH/s:

- Your share = 3M / 136G = 0.0000220
- Network reward = ~24 VRSC / 60s block × 1440 blocks/day = 34,560 VRSC/day
- Your daily VRSC = 34,560 × 0.0000220 = **0.76 VRSC/day**
- At $0.30/VRSC = **$0.23/day** on CPU phase 1

That's **2-4× better than RandomX on M5 today** ($0.05-0.10/day). The economics genuinely do work, contrary to my earlier pessimism — Verus has a much smaller network than I was assuming.

At Metal phase 4 (15 MH/s estimate): ~$1.15/day. Mac mining starts to feel real.

## What I'll start coding now

Phase 1 prototype: copy the 8 source files from VerusCoin into `verusminer/cpu/`, write a 50-line `main.cpp` that calls `verus_hash_v2()` and benchmarks throughput, compile and run on M5. Reports back the actual MH/s number — replaces the previous "1.8-3.5 MH/s estimate" with measured data.

Sources:
- [VerusCoin source](https://github.com/VerusCoin/VerusCoin/tree/master/src/crypto) — algorithm reference
- [MacMetal Miner](https://github.com/MacMetalMiner/MacMetal-Miner) — Apple Silicon Metal architecture template
- [hellcatz/verusProxy](https://github.com/hellcatz/verusProxy) — stratum protocol reference
- [LuckPool Verus](https://luckpool.net/verus/) — phase 2 target pool
- [Käsper-Schwabe bit-sliced AES paper](https://eprint.iacr.org/2009/129) — phase 4 algorithm reference
- [Haraka v2 spec](https://eprint.iacr.org/2016/098.pdf) — algorithm spec for validation
- [DLTcollab/sse2neon](https://github.com/DLTcollab/sse2neon) — SSE intrinsics → ARM NEON shim
