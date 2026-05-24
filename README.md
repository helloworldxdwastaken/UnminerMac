# UnMineableMac

A heavily modified fork of [2nthony/macmineable](https://github.com/2nthony/macmineable) (abandoned 2022). Maintained by [tokyo](https://github.com/helloworldxdwastaken). Targets Apple Silicon (M1–M5+) on macOS 11 and later, including macOS Tahoe 26.x.

> **This is not the same app as upstream.** The original app silently routed mining commissions to the original author via hidden referral codes and phoned home for ads. This fork strips all of that out, updates every binary and dependency, rewrites the parts that were broken in 2026, and adds the features upstream never had.

---

## Why this fork exists

Upstream macMineable was abandoned in 2022 and stopped working entirely. On top of that, an audit of the source revealed several silent extraction mechanisms the user couldn't see in the UI:

### Removed from upstream (silent extractions)

- **3 hardcoded referral codes** (`xngb-nrye`, `8jjv-jipu`, `c310-m2st`) auto-appended to every xmrig `--user=…#refcode` argument. Every user mining through the original app was sending a kickback to the original author whether they knew it or not.
- **30-minute phone-home update check** polling `api.github.com/repos/2nthony/macmineable/releases` — passive telemetry on user behaviour.
- **PromotionBanner component** that fetched ad config from the author's GitHub at runtime and rendered banner ads in the app.
- **Hidden mailto button** wired to the original author's personal email.
- **"BuyMeACoffee" donation link** on the mining page pointing to the author's Notion page.
- **GitHub button** in the top bar that opened the author's repo.

Every one of these is gone. Verified with a grep against the bundled JS — zero matches for any of the strings above.

### Rebuilt to actually work in 2026

The original app couldn't connect to the unMineable pool on M1+ machines, which is why the author abandoned it. The cause was a 2021-era bundled `xmrig` binary plus a Shoelace beta.60 UI that breaks in modern browsers. Both rewritten:

- **xmrig 6.26.0** (March 2026, native arm64, ad-hoc codesigned) — replaces the stale 2021 binary. The bundled `xmrig` and `xmrig-m1` paths now point at the latest official xmrig release.
- **Native HTML form / select / range** replacing broken Shoelace `sl-form` / `sl-select` / `sl-range` — the Shoelace beta.60 popover attribute clashes with Svelte 3 on macOS Tahoe's WebKit and the entire form silently stops working.
- **Dynamic coin list** fetched live from `api.unmineable.com/v4/coin` with 24h `localStorage` cache and graceful fallback to the bundled static list when offline. Picks up coins added after 2022.
- **Coin logos** shown next to the selected coin (pulled from `unmineable.com/img/logos/SYMBOL.png`).
- **Payout info card** — minimum payout amount, chain network, and rough days-to-payout per coin based on a ~3 kH/s baseline. Helps you pick a coin you'll actually receive a payout from in a reasonable timeframe instead of one where the threshold is years away.
- **Connection status indicator** (colored dot in the top bar) that pings the API every 30 s. Green = online, red = blocked, yellow = checking. Click to recheck.
- **Offline banner** on the home page when the API is unreachable, with explicit Cloudflare WARP / encrypted-DNS instructions.
- **Better error messages** when Start fails — distinguishes "network unreachable / DNS blocked" from "address not registered on unMineable" from generic errors, with a Retry button on network failures.
- **Liquid-glass UI** — gray base with cool blue aurora glows, frosted-glass cards (`backdrop-filter: blur + saturate`), blue gradient buttons, soft layered shadows.
- **Auto P-core detection** — first launch detects Apple Silicon performance-core count (`sysctl hw.perflevel0.physicalcpu`) and defaults the CPU usage slider to that exact value (4/10 = 40% on M5). Using only P-cores is the single biggest RandomX hashrate win on Apple Silicon.
- **CPU usage slider that actually saves** and persists across launches via `localStorage`. Settings panel shows live thread count and a "Using P-cores only ✓" hint when set correctly.
- **Save & Restart** flow that cleanly emits stop → start with the new settings when you change CPU usage mid-mining.
- **`launch.json` autoPort** so dev preview doesn't fight over a fixed port.

### Updated dependencies

- xmrig: 2021 build → **6.26.0** (March 2026)
- `@sveltejs/vite-plugin-svelte`: bumped + pinned to last vite-2-compatible version
- `@shoelace-style/shoelace`: pinned to beta.60 (only version where `sl-form` exists) — though most of its usage was replaced with native HTML
- Switched from broken pnpm install (peer-dep conflict on modern Node) to npm

---

## Install / run

Download the latest `.app` from [Releases](https://github.com/helloworldxdwastaken/UnMIneableMac/releases) → quit any running macMineable → double-click to launch.

If macOS Tahoe Gatekeeper blocks it: System Settings → Privacy & Security → "Open Anyway".

---

## Building from source

Prereqs: Go ≥ 1.17, Node ≥ 18, npm.

```bash
npm install --legacy-peer-deps
npm run build              # builds the Svelte frontend → dist/
bash build.sh              # builds the Go app + packages into out/macMineable.app
codesign --force --deep --sign - out/macMineable.app
xattr -dr com.apple.quarantine out/macMineable.app
```

Resulting `out/macMineable.app` is ~18 MB and runs natively on Apple Silicon.

---

## Hashrate notes for Apple Silicon

xmrig 6.26 is the only viable RandomX miner for Apple Silicon — no faster alternative exists. RandomX was specifically engineered to defeat the Neural Engine, GPU, and AMX accelerators that make M-series chips fast at AI workloads (256MB random scratchpad per thread + random memory access + AES-heavy + integer-only). The hashrate ceiling on M5 with proper tuning is roughly **4–6 kH/s**.

**Tuning tips:**

- Keep the CPU slider at the P-core default (set automatically on first run). Adding E-cores hurts sustained hashrate because of L2 cache contention.
- macOS doesn't support huge pages the way Linux does (Apple's kernel doesn't expose `vm.nr_hugepages`). This caps Apple Silicon ~30% below the same CPU on Linux.
- Laptops will thermally throttle within ~60 s of sustained 100% CPU. Mac mini / Studio handle sustained mining better.

---

## Network notes

The unMineable domains (`api.unmineable.com`, `rx.unmineable.com`) are commonly blocked at DNS level by Fortinet/Fortiguard filters on corporate/ISP/school networks. If the connection dot is red, install **Cloudflare WARP** (https://1.1.1.1) or any encrypted-DNS profile — only port-53 plain DNS is hijacked; the actual IPs and pool ports are reachable through DoH/DoT.

---

## License

GPL v3 — inherited from upstream. Original work © [2nthony](https://github.com/2nthony). Modifications © [tokyo](https://github.com/helloworldxdwastaken).
