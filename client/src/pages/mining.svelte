<script>
  import '@shoelace-style/shoelace/dist/components/button/button'
  import '@shoelace-style/shoelace/dist/components/tooltip/tooltip'
  import { tryOnMount, tryOnDestroy } from '@svelte-use/core'
  import { form, isMining, preparing, miningLogs, hashrates } from '../store'
  import { getBalance } from '../server/unMineable'
  import IconRefresh from '../components/icons/Refresh.svelte'
  import { ipc } from '../ipc'
  import * as router from 'svelte-spa-router'
  import IconFileList from '../components/icons/FileList.svelte'
  import HashratesChart from '../components/HashratesChart.svelte'
  import Drawer from '../components/Drawer.svelte'
  import ConnectionStatus from '../components/ConnectionStatus.svelte'
  import { log } from '../util/log'
  import { getHashrate } from '../util/mining'

  let dialogLogsData = []
  let logDrawerEl
  let balance = {}
  let refreshingBalance = false

  $: currentHashrate = $hashrates[$hashrates.length - 1]
  $: isVerus = $form.algorithm === 'verushash'

  miningLogs.subscribe(logs => {
    dialogLogsData = logs
    hashrates.update(val => {
      const hs = getHashrate(logs[logs.length - 1], $form.algorithm)
      if (hs) val.push(hs)
      if (val.length > 6) val.shift()
      return val
    })
  })

  function handleGetBalance() {
    refreshingBalance = true
    getBalance($form.symbol, $form.address).then(d => balance = d).finally(() => refreshingBalance = false)
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
    ipc.listen('onMiningStarted', () => { $isMining = true })
    ipc.send('emitStartMining', JSON.stringify($form))
  }

  function handleStop() {
    ipc.listen('onMiningStopped', () => { $isMining = false; if (currentHashrate) $hashrates = [...$hashrates, 0] })
    ipc.send('emitStopMining')
  }

  tryOnMount(() => { if (!isVerus) handleGetBalance() })
  tryOnDestroy(() => { $miningLogs.length = 0 })
</script>

<div>
  <div class="flex items-center justify-between mb-4">
    <button class="btn btn-ghost" on:click={handleBack}>← Back</button>
    <ConnectionStatus />
  </div>

  <div class="card mb-3">
    <div class="card-header">
      <span class="card-title">{isVerus ? 'VerusHash 2.2' : $form.symbol || 'Mining'}</span>
      <button class="btn btn-ghost" on:click={logDrawerEl.show}>
        <IconFileList style="width:16px;height:16px"/>
      </button>
    </div>

    <div class="info-grid">
      <div class="info-chip">
        <div class="chip-label">Address</div>
        <div class="chip-value mono truncate" style="max-width:200px">{$form.address}</div>
      </div>
      {#if isVerus}
        <div class="info-chip"><div class="chip-label">Pool</div><div class="chip-value">LuckPool</div></div>
        <div class="info-chip"><div class="chip-label">Coin</div><div class="chip-value">VRSC</div></div>
        <div class="info-chip"><div class="chip-label">Payout</div><div class="chip-value">Auto</div></div>
      {:else if balance.pendingBalance !== undefined}
        <div class="info-chip"><div class="chip-label">Balance</div><div class="chip-value">{balance.pendingBalance} {$form.symbol}</div></div>
        <div class="info-chip"><div class="chip-label">24h Reward</div><div class="chip-value">{balance.total24h || 0}</div></div>
        <div class="info-chip"><div class="chip-label">Total Paid</div><div class="chip-value">{balance.totalPaid || 0}</div></div>
      {/if}
    </div>
  </div>

  <HashratesChart />

  <div class="card mt-3">
    <div class="stat-label">Hashrate</div>
    <div class="stat-value">
      {#if $isMining && !currentHashrate}
        <span style="color:var(--ink-dim)">Starting…</span>
      {:else if isVerus}
        {(currentHashrate / 1e6).toFixed(2)} <span style="font-size:18px;font-weight:500;color:var(--ink-dim)">MH/s</span>
      {:else}
        {currentHashrate || 0} <span style="font-size:18px;font-weight:500;color:var(--ink-dim)">H/s</span>
      {/if}
    </div>

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

<Drawer fullscreen bind:this={logDrawerEl} title="Logs">
  <pre style="height:100%;padding:16px;overflow:auto;font-family:var(--font-family-mono);font-size:12px;color:var(--ink-dim);background:var(--bg-root);border-radius:10px">
    {dialogLogsData.join('\n') || 'Waiting for miner output…'}
  </pre>
</Drawer>
