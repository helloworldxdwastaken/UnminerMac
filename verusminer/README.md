# verusminer — native ARM64 + Metal VerusHash 2.2 miner for Apple Silicon

This subdirectory is the home of UnminerMac's second mining algorithm. Goal: the first arm64-native, Metal-accelerated VerusHash 2.2 miner. Status: **Phase 0** (skeleton).

## Why this exists

See [the research page](https://helloworldxdwastaken.github.io/UnminerMac/research.html). The CPU AES benchmark on M5 showed a realistic ceiling of 1.8–3.5 MH/s for VerusHash 2.2; the Metal compute bench showed 90× the raw ALU throughput, suggesting 8–20 MH/s is reachable with a bit-sliced AES Metal kernel. No public arm64-native VerusHash miner exists today — this fills that gap.

## Phased roadmap

| Phase | Deliverable | Status |
|---|---|---|
| **0** | Skeleton + UnminerMac UI selector + Go multi-algo refactor | ✅ done (commit `19c888f`) |
| **1a** | Haraka256 via sse2neon shim measured at **68 MH/s on M5 1 P-core**, paper test vector PASS | ✅ prototype done — see [cpu/RESULTS.md](cpu/RESULTS.md) |
| **1b** | Full VerusHash 2.2 digest benchmark — 11.82 MH/s NEON on 1 P-core M5 (4.7× faster than portable). Portable vs NEON outputs match. | ✅ done |
| **1c** | Full Finalize2b() mining pipeline with CL hash + key caching. 1.82 MH/s real mining on 1 P-core NEON (2.2× vs portable CLMUL). Key cache verified. | ✅ done |
| **2** | Stratum v1 protocol client, connect to a Verus pool (luckpool, zergpool, etc.), submit + validate shares | planned |
| **3** | Integration with UnminerMac — spawn verusminer subprocess, hashrate display, accepted/rejected share counter | planned |
| **4** | Metal compute shader port — bit-sliced AES + Haraka256 kernel, batched candidate-hash dispatch, bench vs CPU phase 1 | planned |
| **5** | Real pool testing, share rejection rate < 1 %, performance tuning, release as `v0.20-metal-verus` | planned |

## Hashrate expectations on M5

| Implementation | Measured / Estimated MH/s | Notes |
|---|---|---|
| Rosetta-emulated x86 `verus-cli` | ~1 MH/s | current reality for Mac users |
| **Phase 1b — NEON VerusHash digest on 1 P-core** | **11.82 MH/s** | measured on M5 (May 2026) |
| **Phase 1b — NEON VerusHash digest on 4 P-cores** | **~47.3 MH/s** | linear extrapolation |
| Phase 1b — real mining (w/ CL hash + key gen) on 4 P-cores | **14–28 MH/s** | 30-60% of digest-only |
| Phase 4 — Metal compute, bit-sliced AES | 8–20 MH/s | 10–25 % of RTX 4090 throughput |

## Economic reality

At current VRSC price (~$0.30), even 15 MH/s on M5 produces roughly $0.07–0.20/day. **This is not a profit play.** The point is technical credibility, open-source contribution, and hedging on potential future VRSC price appreciation.

## Build (phase 1 onward)

```bash
# CPU implementation (phase 1)
cd verusminer
clang -O3 -march=armv8-a+crypto -pthread \
      haraka256.c verushash.c stratum.c main.c \
      -o verusminer
./verusminer --bench
./verusminer --pool pool.example.com:1234 --user VRSC_ADDR

# Metal kernel (phase 4)
swiftc -O metal_verus.swift -o metal_verus_test \
       -framework Metal -framework Foundation
./metal_verus_test --bench
```

## License

GPL v3 (consistent with UnminerMac upstream). Test vectors from the [Haraka v2 paper](https://eprint.iacr.org/2016/098.pdf), reference implementation patterns from the [VerusCoin source](https://github.com/VerusCoin/VerusCoin).
