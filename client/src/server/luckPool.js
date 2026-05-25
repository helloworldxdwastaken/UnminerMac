// LuckPool VRSC (Verus) JSON API client.
//
// All endpoints discovered by reverse-engineering luckpool.net/verus/miner.html
// + assets/js/minerstats.js (jQuery $.getJSON calls). The base path is
// https://luckpool.net/verus/ — each per-miner endpoint takes the wallet
// address as a path segment.
//
// Endpoints used here:
//   GET /verus/earningstats/<addr>  →  { lastDay, lastTwo, lastSeven, lastTen, lastFifteen }
//                                     (VRSC mined in that many days)
//   GET /verus/miner/<addr>         →  live miner stats (hashrate, immature,
//                                     balance, paid, workers, etc.) — returns
//                                     {"error":"not found"} until first share
//   GET /verus/settings/<addr>      →  { minPayment, minerIP, stake }
//   GET /verus/earnings/<addr>      →  array of recent payments
//
// Everything is open / unauthenticated. Caller should debounce.

const POOL_BASE = 'https://luckpool.net/verus'

async function fetchJsonSafe(url) {
  try {
    const res = await fetch(url, { headers: { Accept: 'application/json' } })
    if (!res.ok) return null
    const text = await res.text()
    if (!text || !text.trim()) return null
    try {
      return JSON.parse(text)
    } catch {
      return null
    }
  } catch {
    return null
  }
}

// Returns null until the wallet has shares on the pool.
// Shape on success (from live observation):
//   {
//     lastDay: 0.0001234,   // VRSC in last 24h
//     lastTwo: 0.000252,
//     lastSeven: 0.000900,
//     lastTen: ...,
//     lastFifteen: ...
//   }
export async function fetchEarningStats(address) {
  if (!address) return null
  return fetchJsonSafe(`${POOL_BASE}/earningstats/${address}`)
}

// Returns the rich miner object once the wallet is recognised by the pool
// (after the first accepted share). Until then returns `{ error: 'not found' }`.
// Real shape includes:
//   { hashrate, immature, balance, paid, workers: [...], ... }
export async function fetchMiner(address) {
  if (!address) return null
  return fetchJsonSafe(`${POOL_BASE}/miner/${address}`)
}

// Recent payment history (array). Empty until first payout.
export async function fetchEarnings(address) {
  if (!address) return null
  return fetchJsonSafe(`${POOL_BASE}/earnings/${address}`)
}

// Account settings (min payout, IP, stake). Always available.
export async function fetchSettings(address) {
  if (!address) return null
  return fetchJsonSafe(`${POOL_BASE}/settings/${address}`)
}

// Pool-wide stats — includes `marketStats.price_usd` and network info.
// Shape (from live observation):
//   { poolStats: { hashrate, minerCount, ... },
//     networkStats: { height, ... },
//     marketStats: { price_usd, price_btc, percent_change_24h, ... } }
let _poolStatsCache = { at: 0, data: null }
export async function fetchPoolStats({ maxAgeMs = 60_000 } = {}) {
  const now = Date.now()
  if (_poolStatsCache.data && now - _poolStatsCache.at < maxAgeMs) {
    return _poolStatsCache.data
  }
  const data = await fetchJsonSafe(`${POOL_BASE}/stats`)
  if (data) _poolStatsCache = { at: now, data }
  return data
}

// Just the USD price (cached separately for hot-paths). Falls back to a
// recent observation if the pool stats endpoint is unreachable.
const VRSC_USD_FALLBACK = 0.93
export async function fetchVrscPriceUSD() {
  const stats = await fetchPoolStats()
  const p = stats?.marketStats?.price_usd
  return (typeof p === 'number' && p > 0) ? p : VRSC_USD_FALLBACK
}

// Single-shot combined fetch — pulls everything in parallel and returns a
// flat object the UI can spread into state. Missing endpoints are silently
// dropped (set to undefined) so the UI just won't render those fields.
export async function fetchLuckPoolLive(address) {
  if (!address) return null
  const [earningStats, miner, settings, priceUSD] = await Promise.all([
    fetchEarningStats(address),
    fetchMiner(address),
    fetchSettings(address),
    fetchVrscPriceUSD(),
  ])
  const minerOk = miner && !miner.error
  return {
    // Earnings (VRSC) — these are TOTAL VRSC mined to the address over the
    // window, not USD. Pool also auto-pays at the min threshold.
    vrscLast24h: earningStats?.lastDay ?? 0,
    vrscLast7d: earningStats?.lastSeven ?? 0,
    vrscLast15d: earningStats?.lastFifteen ?? 0,
    // Live status (after first share)
    miner: minerOk ? miner : null,
    minerKnown: !!minerOk,
    // Account config
    minPayment: settings?.minPayment ?? 0.0001,
    minerIP: settings?.minerIP ?? null,
    // Live VRSC price in USD, pulled from LuckPool /verus/stats every
    // ~60s. Drives the "$X.XX/day" estimates on the mining page so we
    // don't ship a stale hardcoded value.
    priceUSD: priceUSD,
    // Timestamp for cache busting in the UI
    fetchedAt: Date.now(),
  }
}
