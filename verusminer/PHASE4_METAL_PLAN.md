# Phase 4 — Metal-accelerated VerusHash 2.2 miner for Apple Silicon

Detailed plan for the GPU phase of `verusminer`. Everything below is what we'd be building **on top of the CPU NEON miner we already shipped** (phases 1-3). Nothing here invalidates the existing CPU path — Metal would be an opt-in `--gpu` mode.

## Goal & success metric

**Goal:** First public arm64-native Metal compute shader implementation of VerusHash 2.2 for Apple Silicon (M1-M5+).

**Success metric:** ≥ 8 MH/s on M5 GPU, validated bit-for-bit against the CPU NEON implementation, with a real-world share rejection rate below 1% over a 24h mining session on LuckPool.

**Stretch goal:** ≥ 15 MH/s on M5 GPU (within 50% of our theoretical ceiling of ~50 MH/s).

## Why this is hard

Apple GPU has **no hardware AES instructions** exposed to Metal Shading Language. CPU NEON gets to use the `vaeseq_u8` / `vaesmcq_u8` intrinsics that map to ARMv8's AESE/AESMC instructions (1 cycle each). On the GPU we have to implement AES in software, two options:

1. **Bit-sliced AES** — pure boolean operations across 8 lanes per thread. No table lookups. Best parallelism but ~3000 ops per round.
2. **Table-based AES** — S-box + T-tables (~1 KB). Fewer ops per round but memory-bound and lookup table fights for cache between threads.

Whichever we pick, we need to write substantial MSL code. There's no copy-paste reference like there was for the CPU path (where VerusCoin's `sse2neon.h` made everything compile unmodified).

The other complication: VerusHash 2.2 isn't pure AES — it has a **CL hash** step (carry-less polynomial multiplication, `vmull_p64` on CPU) that has no GPU equivalent. We have to software-emulate the polynomial multiply, which is slow if naively implemented.

## Things to investigate BEFORE writing kernel code

Open questions that determine the architecture. Answer them with microbenchmarks, not assumptions.

| # | Question | How to answer | Time |
|---|---|---|---|
| 1 | **Bit-sliced vs table-based AES on M5 GPU** — which has higher rounds/sec at saturation? | Write two minimal MSL kernels (50 lines each), bench both at 1M threads, pick the winner | 1-2 days |
| 2 | **What's the optimal batch size** (nonces per dispatch)? Too small = launch overhead dominates, too big = memory pressure + late share submissions | Sweep batch sizes from 1K to 10M, plot effective MH/s | 1 day |
| 3 | **CL hash polynomial multiply** — can we vectorize it efficiently in MSL or is it inherently sequential? | Prototype the inner loop, measure | 2 days |
| 4 | **Key cache placement** — 8832-byte key in threadgroup memory (32KB max on M5) vs device memory (slower)? | Bench both placements with the same kernel | 1 day |
| 5 | **Kernel monolithic vs split** — one giant VerusHash kernel vs multiple smaller kernels (Haraka, CL hash, finalize)? | Build both, compare wall-clock for a full hash | 2-3 days |
| 6 | **Validation strategy** — how do we prove our GPU kernel produces bit-identical hashes to the CPU NEON impl? | Write a test harness: same input, both backends, byte-compare output across 10000 random nonces | 1 day |
| 7 | **MSL feature set on M5** — which Metal shading language version, what intrinsics are available, can we use `simd_ballot` / subgroup ops? | `metal --version` + read M5 GPU family docs | 30 min |

**Total investigation budget: ~1 week** before writing the production kernel.

## Reference materials we'd lean on

| Source | License | What we'd take from it |
|---|---|---|
| [MacMetal Miner](https://github.com/MacMetalMiner/MacMetal-Miner) | MIT | Swift Metal dispatcher pattern (~500 lines). Their `SHA256.metal` kernel is the architectural template — we keep the dispatch + buffer + atomic-counter + result-buffer pattern, swap the algorithm body. Already have it cloned for reference. |
| [VerusCoin source](https://github.com/VerusCoin/VerusCoin/tree/master/src/crypto) | MIT | Reference CPU implementation we validate our GPU output against. Already in `verusminer/cpu/`. |
| [Käsper-Schwabe bit-sliced AES paper](https://eprint.iacr.org/2009/129) | academic | Canonical bit-sliced AES algorithm. We adapt the algorithm to MSL. |
| [Haraka v2 paper](https://eprint.iacr.org/2016/098.pdf) | academic | Algorithm spec for round constants + test vectors |
| [Apple Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf) | Apple docs | What intrinsics, threadgroup memory limits, atomic ops, etc. are available |
| Our own [research/metal_aes_bench.swift](research/metal_aes_bench.swift) + [research/aes_bench.c](research/aes_bench.c) | (this repo) | Established that M5 GPU has 1.5 T ops/sec budget — proves the ceiling exists |

## Phased build plan

Time estimates are **focused work weeks**, not calendar weeks. Buffer 30% for the inevitable surprises in GPU programming.

### Phase 4.0 — Investigation & prototyping (1 week)
- Answer the 7 open questions above
- "Hello compute" MSL kernel that runs on M5 — validates the Swift+Metal build pipeline end-to-end
- Single-AES-round benchmark in both bit-sliced and table-based forms; pick winner
- Decision gate: if GPU AES throughput is < 5× CPU AES throughput, abort Phase 4 and accept the 7 MH/s CPU ceiling

### Phase 4.1 — Haraka256 in MSL (1 week)
- Implement Haraka256 v2 using the chosen AES strategy
- Test vector: `0x00..0x1f` input must produce `8027ccb87949774b...` (Haraka v2 paper)
- Validate output matches our CPU NEON `haraka256()` bit-for-bit
- Benchmark standalone Haraka256 throughput on GPU
- **Deliverable**: `verusminer/metal/haraka256.metal` + parity test
- Decision gate: if Haraka256 throughput < 500 MH/s on GPU, reconsider feasibility

### Phase 4.2 — Haraka512 + Haraka512_keyed in MSL (3-5 days)
- Port the 512-bit variants used by VerusHash 2.2 final step
- Same validation pattern as 4.1
- **Deliverable**: `verusminer/metal/haraka512.metal` with both variants

### Phase 4.3 — CL hash + key generation in MSL (1 week)
- CL hash inner loop — carry-less polynomial multiply in MSL (no hw support, write it as bit-shift + XOR)
- Key generation pipeline (`generate_cl_key_full` — chain of 276 haraka256 calls over 8832 bytes)
- Key cache strategy (regenerate when block template seed changes, store in device memory)
- **Deliverable**: `verusminer/metal/clhash.metal` + key pipeline
- Decision gate: if CL hash is taking >70% of full hash time and can't be optimized further, the GPU advantage shrinks substantially

### Phase 4.4 — Full VerusHash 2.2 kernel (1 week)
- Wire haraka + clhash + finalize into a single `verushash_v2_mine` kernel
- Each thread = one nonce candidate
- Atomic share counter + result buffer (cribbed from MacMetal Miner pattern)
- Validate full hash output matches CPU implementation across 10000 random inputs
- **Deliverable**: end-to-end Metal kernel + benchmark showing MH/s

### Phase 4.5 — Integration (3-5 days)
- Swift dispatcher (`verusminer/metal/main.swift`) — sets up Metal device, compiles kernel at runtime, dispatches batches, reads back results
- Connect to the existing `stratum.cpp` (no rewrite — verusminer GPU + CPU share the stratum client)
- New `--gpu` flag for the verusminer binary
- Result collection: when GPU finds a share, hand off to stratum for submission
- **Deliverable**: `./verusminer mine --gpu <wallet>` works end-to-end

### Phase 4.6 — Real pool testing (3-5 days)
- Run on LuckPool for 24 hours
- Track: shares submitted, shares accepted, shares rejected, reject reasons
- Tune batch size based on real-world job churn rate
- Target: < 1% rejection rate
- **Deliverable**: log file showing 24h of mining with acceptable rejection rate

### Phase 4.7 — UnminerMac integration + v0.19 release (2-3 days)
- Add "VerusHash 2.2 — Metal (M5 GPU)" option to algorithm dropdown
- Go side: spawn `verusminer mine --gpu <addr>` when selected
- Mining page shows GPU hashrate (in MH/s, not kH/s)
- Update website /research page with measured Metal numbers
- Tag `v0.19.0-verus-metal`, build dmg, push release
- **Deliverable**: shippable v0.19 with GPU mining option

### Total: 5-7 weeks of focused work + 30% buffer = ~7-10 calendar weeks

## What gets shipped where

```
verusminer/
├── cpu/                       ← already done (phases 1-3, ships in v0.18)
│   ├── main.cpp               (--bench / --quick / mine modes)
│   ├── haraka*.{c,h}
│   ├── verus_clhash*.{cpp,h}
│   ├── stratum.{cpp,h}
│   └── Makefile
│
└── metal/                     ← new in phase 4
    ├── main.swift             (Metal device setup, dispatcher, stratum bridge)
    ├── haraka256.metal        (4.1)
    ├── haraka512.metal        (4.2)
    ├── clhash.metal           (4.3)
    ├── verushash_kernel.metal (4.4 — the orchestrator kernel)
    ├── parity_test.swift      (4.6 — CPU vs GPU output validation harness)
    └── build.sh
```

The Go side already dispatches `algorithm: "verushash"` to `assets/miner/verusminer mine <addr>`. For phase 4 we just append `--gpu` when the UI option says "Metal" — single line change in `lib/ipc_events.go`.

## Risk register

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| GPU AES too slow to justify (Phase 4.0 abort) | Medium | High | Test in week 1, accept and ship CPU-only v0.18 if so |
| CL hash dominates and GPU loses overall | Medium | High | Phase 4.3 decision gate — if CL hash > 70% of cycle, abort |
| Validation parity bugs eat the whole budget | High | Medium | Strict bit-comparison harness from day one; never ship unverified hashes |
| Thermal throttling on MacBook makes GPU mining unsustainable | Medium | Medium | Document thermal behavior + recommend Mac mini/Studio for sustained mining |
| LuckPool rejects shares for protocol mismatch | Low | High | Phase 4.6 dedicated to real-pool testing before release |
| VRSC price drops further, makes all this moot | Always | Low | We're building infrastructure regardless; can mine other VerusHash-family coins |

## Decision gates — when to abort

Phase 4 is a real research project with multiple ways to fail. **Pre-commit to aborting** at these points if numbers don't justify continuing:

1. **End of Phase 4.0**: If single-AES throughput on GPU is < 5× CPU equivalent, the Metal speedup will be < 2× total and not worth the weeks. **Abort, ship CPU-only.**
2. **End of Phase 4.1**: If Haraka256 alone is < 500 MH/s on GPU (CPU NEON does 887 MH/s on 4 cores), the GPU isn't winning the algorithm. **Reconsider.**
3. **End of Phase 4.4**: If full kernel throughput is < 5 MH/s VerusHash, we're below CPU. **Don't ship — debug or abort.**
4. **End of Phase 4.6**: If share rejection rate is > 5% after tuning, our kernel has a correctness bug. **Don't release until fixed.**

## What we need from you (the human in the loop)

The build itself doesn't need much from you, but two things require human decisions:

1. **Pre-commit to the time investment.** 5-7 weeks of focused work is real. If you don't have that, do Phase 4.0 only (1 week, gives you a definitive answer on whether the rest is worth doing).
2. **Approve the abort gates above.** If we hit one, we need permission to stop without "but maybe if we try harder" pressure. The gates exist because shipping a slow or buggy Metal miner is worse than not shipping one at all.

## What we'd NOT do

To keep scope honest, these are out of scope for Phase 4:

- Multi-algorithm GPU support (KAWPOW, Octopus, etc.) — different kernel each
- Anything for AMD or Intel Macs — arm64 Apple Silicon only
- Auto profitability switching — separate feature
- Bigger UI overhaul — current UnminerMac UI is fine
- Web version — desktop only

## Concrete next action

If you want to commit to Phase 4: start with **Phase 4.0 — the 1-week investigation**. It costs a week to find out if the project is viable. After that we have data to decide whether to continue or stop.

If you'd rather defer Phase 4 entirely: **ship v0.18 now** with the CPU NEON VerusHash miner we already built. It's real, it works, it's a notable open-source first. Phase 4 can be a v0.19 follow-up months later when you have bandwidth.

The CPU implementation does ~7 MH/s on M5 → ~$0.20/day at current VRSC price. Phase 4 would push that to ~$0.60-1.50/day. Whether the 5-7 week investment is worth a $0.40-1.30/day improvement is your call.
