import { connectionStatus } from '../store'
import { apiServer } from '../server/unMineable'

const CHECK_INTERVAL_MS = 30_000
const TIMEOUT_MS = 6_000

async function pingOnce() {
  connectionStatus.set('checking')
  const ctrl = new AbortController()
  const t = setTimeout(() => ctrl.abort(), TIMEOUT_MS)
  try {
    const res = await fetch(`${apiServer}/v4/coin`, {
      signal: ctrl.signal,
      cache: 'no-store',
    })
    if (!res.ok) throw new Error(`HTTP ${res.status}`)
    const body = await res.text()
    if (!body.trim().startsWith('{')) throw new Error('non-JSON response')
    connectionStatus.set('online')
  } catch (e) {
    connectionStatus.set('offline')
  } finally {
    clearTimeout(t)
  }
}

let intervalId
export function startConnectionWatch() {
  pingOnce()
  intervalId = setInterval(pingOnce, CHECK_INTERVAL_MS)
}

export function recheckConnection() {
  return pingOnce()
}
