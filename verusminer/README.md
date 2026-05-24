# verusminer — native ARM64 + Metal VerusHash 2.2 miner for Apple Silicon

This subdirectory is the home of UnminerMac's second mining algorithm. Goal: the first arm64-native, Metal-accelerated VerusHash 2.2 miner. Status: **Phase 0** (skeleton).

## Why this exists

See [the research page](https://helloworldxdwastaken.github.io/UnminerMac/research.html). The CPU AES benchmark on M5 showed a realistic ceiling of 1.8–3.5 MH/s for VerusHash 2.2; the Metal compute bench showed 90× the raw ALU throughput, suggesting 8–20 MH/s is reachable with a bit-sliced AES Metal kernel. No public arm64-native VerusHash miner exists today — this fills that gap.

## Phased roadmap

| Phase | Deliverable | Status |
|---|---|---|
| **0** | Skeleton + UnminerMac UI selector + Go multi-algo refactor | ⏳ in progress |
| **1** | Haraka256 v2 + VerusHash 2.2 in C with ARM NEON intrinsics, validated against published test vectors, standalone `verusminer --bench` CLI | planned |
| **2** | Stratum v1 protocol client, connect to a Verus pool (luckpool, zergpool, etc.), submit + validate shares | planned |
| **3** | Integration with UnminerMac — spawn verusminer subprocess, hashrate display, accepted/rejected share counter | planned |
| **4** | Metal compute shader port — bit-sliced AES + Haraka256 kernel, batched candidate-hash dispatch, bench vs CPU phase 1 | planned |
| **5** | Real pool testing, share rejection rate < 1 %, performance tuning, release as `v0.20-metal-verus` | planned |

## Hashrate expectations on M5

| Implementation | Expected MH/s | Notes |
|---|---|---|
| Rosetta-emulated x86 `verus-cli` | ~1 MH/s | current reality for Mac users |
| Phase 1 (CPU, NEON intrinsics) | 1.8–3.5 MH/s | 2–4× the Rosetta'd reference |
| Phase 4 (Metal compute, bit-sliced AES) | 8–20 MH/s | 10–25 % of RTX 4090 throughput |

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
