import { apiv4coin } from './unMineableCoins'

export const apiServer = 'https://api.unmineable.com'

const referralCode = ''

const presetCoins = [
  fastCoin('Ethereum', 'ETH', referralCode),
  fastCoin('Dogecoin', 'DOGE', referralCode),
  fastCoin('SHIBA', 'SHIB', referralCode),
]

export const unMineableCoins = presetCoins
  .concat(
    apiv4coin.data
      .filter((unCoin) => {
        return presetCoins.findIndex((coin) => coin[1] === unCoin.symbol) < 0
      })
      .map((supplyCoin) => {
        return fastCoin(supplyCoin.name, supplyCoin.symbol, referralCode)
      }),
  )
  .sort()

export function getReferralCode(coins, symbol) {
  return coins.find((coin) => coin[1] === symbol)[2]
}

export class NetworkError extends Error {
  constructor(message) {
    super(message)
    this.name = 'NetworkError'
  }
}

export async function fetchCoinDetail(symbol) {
  if (!symbol) return null
  try {
    const res = await fetch(`${apiServer}/v4/coin/${encodeURIComponent(symbol)}`)
    if (!res.ok) return null
    const json = await res.json()
    if (!json || !json.success || !json.data) return null
    return json.data
  } catch (e) {
    return null
  }
}

export async function validateAddress(symbol, address) {
  let res
  try {
    res = await fetch(`${apiServer}/v4/address/${address}?coin=${symbol}`)
  } catch (e) {
    throw new NetworkError(
      `Could not reach unMineable (${e.message}). Turn on Cloudflare WARP / 1.1.1.1 or encrypted DNS, then try again.`,
    )
  }
  const text = await res.text()
  if (!text.trim().startsWith('{')) {
    throw new NetworkError(
      'unMineable returned a non-JSON response (likely a DNS/filter block page). Turn on your VPN and try again.',
    )
  }
  let json
  try {
    json = JSON.parse(text)
  } catch (e) {
    throw new NetworkError('unMineable returned invalid JSON. Check your network.')
  }
  return !!json.success
}

export function getBalance(symbol, address) {
  if (!symbol || !address) {
    return Promise.reject()
  }

  return fetch(
    `${apiServer}/v3/stats/${address}?tz=8&coin=${symbol}`,
  )
    .then((res) => res.json())
    .then((res) => {
      return {
        pendingBalance: res.data.pending_balance,
        total24h: res.data.total_24h,
        totalPaid: res.data.total_paid,
      }
    })
}

function fastCoin(name, symbol, referralCode) {
  return [
    name,
    symbol,
    referralCode,
    `https://www.unmineable.com/img/logos/${symbol}.png`,
  ]
}
