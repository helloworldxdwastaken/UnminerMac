<script>
  import { tryOnMount, tryOnDestroy } from '@svelte-use/core'
  import { form, isMining, preparing, miningLogs, hashrates } from '../store'
  import { getBalance } from '../server/unMineable'
  import { fetchLuckPoolLive } from '../server/luckPool'
  import IconRefresh from '../components/icons/Refresh.svelte'
  import IconFileList from '../components/icons/FileList.svelte'
  import IconSettings from '../components/icons/Settings.svelte'
  import { ipc } from '../ipc'
  import * as router from 'svelte-spa-router'
  import HashratesChart from '../components/HashratesChart.svelte'
  import Drawer from '../components/Drawer.svelte'
  import DrawerFormSettings from '../components/DrawerFormSettings.svelte'
  import ConnectionStatus from '../components/ConnectionStatus.svelte'
  import { log } from '../util/log'
  import { parseMiningStats } from '../util/mining'

  let dialogLogsData = []
  let logDrawerEl
  let settingsDrawerEl
  let balance = {}
  let refreshingBalance = false
  let copiedAddress = false
  let liveStats = {}
  let poolLive = null            // LuckPool API snapshot
  let poolPollTimer = null
  let poolFetching = false

  $: currentHashrate = $hashrates[$hashrates.length - 1]
  $: isVerus = $form.algorithm === 'verushash'

  miningLogs.subscribe((logs) => {
    dialogLogsData = logs
    const lastLog = logs[logs.length - 1]
    const stats = parseMiningStats(lastLog, $form.algorithm)
    if (stats.hashrate) {
      hashrates.update((val) => {
        val.push(stats.hashrate)
        if (val.length > 6) val.shift()
        return val
      })
    }
    if (stats.vrscPerDay !== undefined || stats.sessionVrsc !== undefined) {
      liveStats = { ...liveStats, ...stats }
    }
  })

  function handleGetBalance() {
    refreshingBalance = true
    getBalance($form.symbol, $form.address)
      .then((d) => (balance = d))
      .finally(() => (refreshingBalance = false))
  }

  async function handleBack() {
    if ($isMining) {
      ipc.listen('onMiningStopped', () => router.pop())
      ipc.send('emitStopMining')
    } else {
      router.pop()
    }
  }

  function handleStart() {
    ipc.listen('onMiningStarted', () => ($isMining = true))
    ipc.send('emitStartMining', JSON.stringify($form))
  }

  function handleStop() {
    ipc.listen('onMiningStopped', () => {
      $isMining = false
      if (currentHashrate) $hashrates = [...$hashrates, 0]
    })
    ipc.send('emitStopMining')
  }

  function copyAddress() {
    try {
      navigator.clipboard.writeText($form.address)
      copiedAddress = true
      setTimeout(() => (copiedAddress = false), 1500)
    } catch (e) {}
  }

  function openExplorer() {
    const url = isVerus
      ? `https://luckpool.net/verus/miner.html?${$form.address}`
      : `https://unmineable.com/coins/${$form.symbol}/address/${$form.address}`
    ipc.send('emitOpenURL', url)
  }

  async function refreshPoolLive() {
    if (poolFetching || !$form.address) return
    poolFetching = true
    try {
      const snap = await fetchLuckPoolLive($form.address)
      if (snap) poolLive = snap
    } finally {
      poolFetching = false
    }
  }

  tryOnMount(() => {
    if (isVerus) {
      // First fetch immediately, then poll every 30s while page is mounted.
      refreshPoolLive()
      poolPollTimer = setInterval(refreshPoolLive, 30000)
    } else {
      handleGetBalance()
    }
  })
  tryOnDestroy(() => {
    $miningLogs.length = 0
    if (poolPollTimer) clearInterval(poolPollTimer)
  })

  // Formatted MH/s string for the headline
  $: hashrateDisplay = (() => {
    if ($isMining && !currentHashrate) return { value: 'Starting…', unit: '' }
    if (isVerus) return { value: ((currentHashrate || 0) / 1e6).toFixed(2), unit: 'MH/s' }
    return { value: String(currentHashrate || 0), unit: 'H/s' }
  })()
</script>

<div>
  <div class="flex items-center justify-between mb-3">
    <button class="btn btn-ghost" on:click={handleBack}>← Back</button>
    <ConnectionStatus />
  </div>

  <!-- Mining info card -->
  <div class="card mb-2">
    <div class="card-header">
      <span class="card-title">{isVerus ? 'VerusHash 2.2 · LuckPool' : ($form.symbol || 'Mining')}</span>
      <div class="flex items-center gap-2">
        <button
          class="btn btn-ghost"
          title="Settings"
          on:click={() => settingsDrawerEl && settingsDrawerEl.show()}
        >
          <IconSettings style="width:16px;height:16px" />
        </button>
        <button
          class="btn btn-ghost"
          title="Miner logs"
          on:click={() => logDrawerEl && logDrawerEl.show()}
        >
          <IconFileList style="width:16px;height:16px" />
        </button>
      </div>
    </div>

    <!-- Address row — tap to copy, button to open explorer/dashboard -->
    <div class="flex items-center gap-2 mb-3">
      <button
        class="btn btn-ghost mono truncate"
        title={copiedAddress ? 'Copied!' : 'Tap to copy address'}
        style="flex:1;justify-content:flex-start;text-align:left;padding:6px 10px;font-size:12px"
        on:click={copyAddress}
      >
        <span class="truncate" style="display:inline-block;max-width:100%">
          {copiedAddress ? '✓ Copied!' : $form.address}
        </span>
      </button>
      <button
        class="btn btn-ghost"
        title={isVerus ? 'Open LuckPool dashboard' : 'Open unMineable stats'}
        style="font-size:12px;padding:6px 10px"
        on:click={openExplorer}
      >
        {isVerus ? 'Pool ↗' : 'Stats ↗'}
      </button>
    </div>

    <!-- Earnings + payout chips -->
    {#if isVerus}
      {#if !poolLive || !poolLive.minerKnown}
        <!-- Pre-acceptance banner: shown while pool hasn't seen this address
             yet (first share takes a few minutes to land). Disappears once
             /verus/miner/<addr> returns a real miner object. -->
        <div
          class="card-accent"
          style="border:1px solid rgba(245,194,66,.4);background:rgba(245,194,66,.08);
                 border-radius:10px;padding:10px 12px;margin-bottom:12px;font-size:12px;line-height:1.45">
          <strong style="color:var(--gold)">⏳ Waiting for first accepted share…</strong>
          <span class="text-dim">
            Miner is hashing at the reported speed. LuckPool will register
            this address after the first share is accepted (a few minutes at
            this hashrate). Until then, numbers below are projections.
            Verify live on
            <button
              type="button"
              class="btn btn-ghost"
              style="padding:0;display:inline;color:var(--accent);font-size:inherit"
              on:click={openExplorer}>Pool dashboard ↗</button>.
          </span>
        </div>
      {/if}
    {/if}

    <div class="info-grid">
      {#if isVerus}
        <!-- LIVE pool earnings, when available -->
        {#if poolLive && (poolLive.vrscLast24h > 0 || poolLive.minerKnown)}
          <div class="info-chip">
            <div class="chip-label">Mined · last 24h <span style="color:var(--green)">● live</span></div>
            <div class="chip-value mono">
              {poolLive.vrscLast24h.toFixed(6)} VRSC
            </div>
          </div>
          <div class="info-chip">
            <div class="chip-label">Mined · last 7d</div>
            <div class="chip-value mono">
              {poolLive.vrscLast7d.toFixed(6)} VRSC
            </div>
          </div>
          {#if poolLive.miner?.balance !== undefined}
            <div class="info-chip" style="grid-column:1/-1">
              <div class="chip-label">Pending balance (auto-paid at {poolLive.minPayment} VRSC)</div>
              <div class="chip-value mono">{Number(poolLive.miner.balance).toFixed(8)} VRSC</div>
            </div>
          {/if}
          {#if poolLive.miner?.paid !== undefined}
            <div class="info-chip" style="grid-column:1/-1">
              <div class="chip-label">Total paid out</div>
              <div class="chip-value mono">{Number(poolLive.miner.paid).toFixed(8)} VRSC</div>
            </div>
          {/if}
        {/if}

        <!-- Projection from CPU hashrate (always shown — gives expectation) -->
        {#if liveStats.vrscPerDay !== undefined}
          <div class="info-chip">
            <div class="chip-label">Projected / day · from {liveStats.threads || '?'} threads</div>
            <div class="chip-value mono">
              {liveStats.vrscPerDay.toFixed(4)} VRSC
              <span style="color:var(--green);font-weight:400">
                ≈ ${liveStats.usdPerDay?.toFixed(3) || '0.000'}
              </span>
            </div>
          </div>
        {/if}
        {#if liveStats.sessionVrsc !== undefined && !poolLive?.minerKnown}
          <div class="info-chip">
            <div class="chip-label">Session hashed (projected)</div>
            <div class="chip-value mono">
              {liveStats.sessionVrsc.toFixed(6)} VRSC
            </div>
          </div>
        {/if}
        <div class="info-chip" style="grid-column:1/-1">
          <div class="chip-label">Payout</div>
          <div class="chip-value">
            Auto · every 20h · min {poolLive?.minPayment || 0.0001} VRSC
          </div>
        </div>
      {:else if balance.pendingBalance !== undefined}
        <div class="info-chip">
          <div class="chip-label" style="display:flex;align-items:center;gap:6px">
            Pending
            <IconRefresh
              class={refreshingBalance ? 'animate-spin' : ''}
              style="width:10px;height:10px;cursor:pointer"
              on:click={handleGetBalance}
            />
          </div>
          <div class="chip-value mono">{balance.pendingBalance} {$form.symbol}</div>
        </div>
        <div class="info-chip">
          <div class="chip-label">24h Reward</div>
          <div class="chip-value mono">{balance.total24h || 0}</div>
        </div>
        <div class="info-chip" style="grid-column:1/-1">
          <div class="chip-label">Total Paid</div>
          <div class="chip-value mono">{balance.totalPaid || 0} {$form.symbol}</div>
        </div>
      {/if}
    </div>
  </div>

  <!-- Hashrate card -->
  <div class="card mb-2">
    <div class="flex items-baseline justify-between mb-2">
      <div class="stat-label">Hashrate</div>
      {#if liveStats.threads}
        <div class="text-xs text-dim">{liveStats.threads} threads active</div>
      {/if}
    </div>
    <div class="stat-value">
      {hashrateDisplay.value}
      {#if hashrateDisplay.unit}
        <span style="font-size:18px;font-weight:500;color:var(--ink-dim)">{hashrateDisplay.unit}</span>
      {/if}
    </div>
    <HashratesChart />

    <div class="divider"></div>

    {#if !$isMining}
      <button class="btn btn-primary btn-full btn-lg" disabled={$preparing} on:click={handleStart}>
        {$preparing ? 'Starting…' : 'Start Mining'}
      </button>
    {:else}
      <button class="btn btn-danger btn-full btn-lg" disabled={$preparing} on:click={handleStop}>
        Stop Mining
      </button>
    {/if}
  </div>
</div>

<!-- Settings drawer (CPU slider + persist) -->
<DrawerFormSettings bind:this={settingsDrawerEl} />

<!-- Logs drawer -->
<Drawer fullscreen bind:this={logDrawerEl} title="Miner logs">
  <pre
    style="height:100%;padding:14px;overflow:auto;font-family:'SF Mono',Menlo,monospace;font-size:12px;color:var(--ink-dim);background:var(--bg-root);border-radius:10px;white-space:pre-wrap;word-break:break-all">{dialogLogsData.join('\n') || 'Waiting for miner output…'}</pre>
</Drawer>
