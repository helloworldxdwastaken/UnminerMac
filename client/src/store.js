import { writable } from '@svelte-use/shared'

export const form = writable({
  symbol: '',
  address: '',
  referralCode: '',
  cpuUsage: 25,
})

export const preparing = writable(false)

export const isMining = writable(false)

export const hashrates = writable([0, 0])

// calculate step on `FormSettings.svelte`
export const cpuCores = writable(100)

// Performance-core count (from Go side, sysctl hw.perflevel0.physicalcpu).
// 0 = unknown (Intel Mac or sysctl unavailable).
export const pCores = writable(0)

export const miningLogs = writable([])

// 'unknown' | 'checking' | 'online' | 'offline'
export const connectionStatus = writable('unknown')

// Coin list: [name, symbol, referralCode, logoUrl][]. Initialized empty;
// populated by helper/coinLoader.js (live API → cache → static fallback).
export const coins = writable([])
