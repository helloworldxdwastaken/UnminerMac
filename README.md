# UnminerMac

**First native ARM64 + Metal VerusHash 2.2 miner for Apple Silicon (M1–M5+).** Also supports RandomX/XMR via unMineable. macOS 11+ including Tahoe 26.x.

Built by **[Verox Studio](https://veroxstudio.com)**.

---

## What's in this app

- **VerusHash 2.2 miner** — native ARM64 NEON + ARMv8 AES + CL hash via `vmull_p64`. Connects directly to LuckPool. No middleman, no registration. ~7.3 MH/s on M5 (4 P-cores). First public arm64-native VerusHash miner.
- **RandomX miner** — xmrig 6.26.0 (March 2026) via unMineable pool. Mines XMR + auto-converts to 35+ coins.
- **Metal GPU mining** — Phase 4 in development. Bit-sliced AES at 87.7 G rounds/sec on M5 GPU (33× CPU throughput).

---

## What makes this different

- No hidden referral codes, no phone-home telemetry, no silent extraction
- Every binary updated (xmrig 6.26.0 arm64, verusminer native)
- Auto P-core detection + CPU slider that persists across launches
- Live connection status indicator + DNS-blocking workarounds
- Glass-morphism UI with dark/light mode

---

## Install

Download the latest release from [Releases](https://github.com/helloworldxdwastaken/UnminerMac/releases) → drag to Applications → launch.

macOS Tahoe Gatekeeper: System Settings → Privacy & Security → "Open Anyway".

## Building from source

```bash
npm install --legacy-peer-deps
npm run build              # builds Svelte frontend → dist/
bash build.sh              # builds Go app + packages into out/UnminerMac.app
```

---

## VerusHash 2.2 — our research & first implementation

The full research is documented on the [research page](https://helloworldxdwastaken.github.io/UnminerMac/research.html).

**CPU pipeline (Phase 1–3, shipping):**
- Haraka256 NEON: 68 MH/s (1 P-core)
- Full VerusHash 2.2 mining with CL hash + key caching: 1.82 MH/s (1 P-core) / 7.3 MH/s (4 P-cores)
- ARMv8 `vmull_p64` polynomial multiply for CL hash (2.2× vs portable)
- Stratum v1 client → LuckPool direct mining

**Metal GPU pipeline (Phase 4, in development):**
- Bit-sliced AES kernel: 87.7 G rounds/sec on M5 GPU (33× single CPU core)
- Target: 8–15 MH/s VerusHash on M5 GPU
- Architecture: bit-sliced AES (pure ALU, no memory lookups) via Metal Shading Language

---

## Attribution & references

- **[2nthony/macmineable](https://github.com/2nthony/macmineable)** — original project that this was built from. Rewritten and extended significantly.
- **xmrig** — [GPL v3](https://github.com/xmrig/xmrig), RandomX miner bundled in `assets/miner/`
- **VerusCoin source** — [MIT](https://github.com/VerusCoin/VerusCoin), algorithm reference for haraka + verus_clhash
- **Haraka v2 paper** (ePrint 2016/098) — algorithm spec and test vectors
- **MacMetal Miner** — [MIT](https://github.com/MacMetalMiner/MacMetal-Miner), Metal kernel architecture reference (SHA-256d, not VerusHash)
- **Käsper-Schwabe bit-sliced AES** (ePrint 2009/129) — algorithm reference for GPU AES

---

## License

**Elastic License 2.0 (ELv2)** — see [LICENSE](./LICENSE).

Non-commercial use, research, education, and personal mining are free. Commercial or hosted use requires a paid license. Contact via [GitHub](https://github.com/helloworldxdwastaken/UnminerMac).

© 2026 [tokyo](https://github.com/helloworldxdwastaken). All rights reserved.
