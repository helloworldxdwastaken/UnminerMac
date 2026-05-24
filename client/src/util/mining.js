export function getHashrate(log = '', algorithm = 'randomx') {
  const s = parseMiningStats(log, algorithm)
  return s.hashrate || 0
}

// Returns { hashrate (H/s), threads, vrscPerDay, usdPerDay } parsed from
// a single log line. Fields are 0/undefined when not present in the line.
export function parseMiningStats(log = '', algorithm = 'randomx') {
  log = log.trim()

  if (algorithm === 'verushash') {
    // New format:
    // [STATS] 5.77 MH/s | 4 threads | ~1.4658 VRSC/day | ~$0.879/day | total: 29250000 | uptime: 5s
    const hr = /\[STATS\]\s+([\d.]+)\s+(MH|KH|GH|H)\/s/.exec(log)
    if (!hr) return {}
    const value = Number(hr[1])
    const unit = hr[2]
    let hashrate = value
    if (unit === 'GH') hashrate = value * 1e9
    else if (unit === 'MH') hashrate = value * 1e6
    else if (unit === 'KH') hashrate = value * 1e3

    const t = /\|\s*(\d+)\s+threads/.exec(log)
    const v = /~([\d.]+)\s+VRSC\/day/.exec(log)
    const u = /~\$([\d.]+)\/day/.exec(log)

    return {
      hashrate,
      threads: t ? Number(t[1]) : undefined,
      vrscPerDay: v ? Number(v[1]) : undefined,
      usdPerDay: u ? Number(u[1]) : undefined,
    }
  }

  // RandomX (xmrig): [...]  miner  speed 10s/60s/15m 353.6 n/a n/a H/s max 359.0 H/s
  if (log && /miner/.test(log) && /speed.*max/.test(log)) {
    const m = /speed(.*)max/.exec(log)
    if (!m) return {}
    const [, speedPer10Second] = m[1].trim().split(' ')
    return { hashrate: Number(speedPer10Second) }
  }

  return {}
}
