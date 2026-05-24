import { coins } from '../store'
import { apiServer } from '../server/unMineable'
import { unMineableCoins as staticFallback } from '../server/unMineable'

const CACHE_KEY = 'unmineable-coins-cache-v1'
const CACHE_MAX_AGE_MS = 24 * 60 * 60 * 1000

function logoFor(symbol, fromApi) {
  if (fromApi) return fromApi
  return `https://www.unmineable.com/img/logos/${symbol}.png`
}

function tupleFromApi(item) {
  return [item.name, item.symbol, '', logoFor(item.symbol, item.logo)]
}

function readCache() {
  try {
    const raw = localStorage.getItem(CACHE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw)
    if (!parsed || !Array.isArray(parsed.list)) return null
    return parsed
  } catch (e) {
    return null
  }
}

function writeCache(list) {
  try {
    localStorage.setItem(
      CACHE_KEY,
      JSON.stringify({ list, savedAt: Date.now() }),
    )
  } catch (e) {}
}

function applyList(list) {
  const sorted = [...list].sort((a, b) =>
    String(a[0]).toLowerCase().localeCompare(String(b[0]).toLowerCase()),
  )
  coins.set(sorted)
}

export async function loadCoins() {
  // 1. Seed immediately from cache if present, else static fallback.
  const cached = readCache()
  if (cached) {
    applyList(cached.list)
  } else {
    applyList(staticFallback)
  }

  // 2. If cache is fresh, skip the network refresh.
  if (cached && Date.now() - cached.savedAt < CACHE_MAX_AGE_MS) return

  // 3. Try a live refresh; on any failure, keep the seeded list.
  try {
    const res = await fetch(`${apiServer}/v4/coin`, { cache: 'no-store' })
    if (!res.ok) return
    const json = await res.json()
    if (!json || !json.success || !Array.isArray(json.data)) return
    const list = json.data.map(tupleFromApi)
    applyList(list)
    writeCache(list)
  } catch (e) {
    // Network/DNS failure — fallback already applied above.
  }
}
