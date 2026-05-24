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
  import TopButtons from '../components/TopButtons.svelte'
  import { log } from '../util/log'
  import { getHashrate, parseMiningStats } from '../util/mining'
  import Link from '../components/Link.svelte'

  let dialogLogsData = []
  let liveStats = {} // { vrscPerDay, usdPerDay, threads }

  miningLogs.subscribe((logs) => {
    dialogLogsData = logs

    const log = logs[logs.length - 1]
    const stats = parseMiningStats(log, $form.algorithm)
    if (stats.hashrate) {
      hashrates.update((val) => {
        val.push(stats.hashrate)
        if (val.length > 6) val.shift()
        return val
      })
    }
    if (stats.vrscPerDay !== undefined) liveStats = stats
  })

  let logDrawerEl

  let balance = {}
  $: currentHashrate = $hashrates[$hashrates.length - 1]
  let refreshingBalance = false

  function handleGetBalance() {
    log('page mining:', 'refreshing balance.')

    refreshingBalance = true
    getBalance($form.symbol, $form.address)
      .then((data) => (balance = data))
      .finally(() => {
        refreshingBalance = false
      })
  }

  async function handleBackToSelectCoin() {
    log('page mining:', 'back to select coin')

    if ($isMining) {
      ipc.listen('onMiningStopped', () => {
        router.pop()
      })
      ipc.send('emitStopMining')
    } else {
      router.pop()
    }
  }

  function handleStart() {
    log('page mining:', 'start')

    ipc.listen('onMiningStarted', () => {
      $isMining = true
    })
    ipc.send('emitStartMining', JSON.stringify($form))
  }

  function handleStop() {
    log('page mining:', 'stop')

    ipc.listen('onMiningStopped', () => {
      $isMining = false
      if (currentHashrate) {
        $hashrates = [...$hashrates, 0]
      }
    })
    ipc.send('emitStopMining')
  }

  tryOnMount(() => {
    if ($form.algorithm !== 'verushash') {
      handleGetBalance()
    }
  })
  tryOnDestroy(() => {
    $miningLogs.length = 0
  })
</script>

<section class="flex flex-col justify-between h-full">
  <div>
    <div class="flex justify-between items-center">
      <div
        class="text-blue-400 text-sm flex cursor-pointer"
        on:click={handleBackToSelectCoin}
      >
        ← Back to set coin & address
      </div>
      <div>
        <TopButtons />
      </div>
    </div>

    <div>
      <div class="mt-6">
        <h5 class="mb-1">Address</h5>
        <div class="flex items-center justify-between">
          <sl-tooltip placement="top" content={$form.address}>
            <p class="text-gray-500 text-xs m-0 break-all overflow-ellipsis whitespace-nowrap overflow-hidden mr-8">
              {$form.address}
            </p>
          </sl-tooltip>

          {#if $form.algorithm === 'verushash'}
            <button type="button" class="glass-btn-ghost px-3 py-1 text-xs"
              on:click={() => ipc.send('emitOpenURL', `https://explorer.verus.io/address/${$form.address}`)}>
              Explorer
            </button>
          {:else}
            <button type="button" class="glass-btn-ghost px-3 py-1 text-xs"
              on:click={() => ipc.send('emitOpenURL', `https://unmineable.com/coins/${$form.symbol}/address/${$form.address}`)}>
              Stats
            </button>
          {/if}
        </div>
      </div>

      <div class="mt-6">
        {#if $form.algorithm === 'verushash'}
          <div class="flex items-center justify-between">
            <h5>Mining</h5>
            <button
              type="button"
              class="glass-btn-ghost px-3 py-1 text-xs"
              on:click={() =>
                ipc.send(
                  'emitOpenURL',
                  `https://luckpool.net/verus/?address=${$form.address}`,
                )}
              >Pool dashboard ↗</button
            >
          </div>
          <div class="glass-card my-2 p-3 text-xs">
            <div class="flex justify-between mb-1">
              <span class="text-gray-400">Pool</span>
              <span>LuckPool</span>
            </div>
            <div class="flex justify-between mb-1">
              <span class="text-gray-400">Coin</span>
              <span>VRSC (VerusCoin)</span>
            </div>
            <div class="flex justify-between mb-1">
              <span class="text-gray-400">Algorithm</span>
              <span>VerusHash 2.2</span>
            </div>
            <p class="text-[10px] text-gray-500 mt-2 leading-snug">
              <strong class="text-gray-400">Accumulated VRSC is held at LuckPool</strong>
              against your address — it survives app restarts, reboots, etc.
              LuckPool pays out automatically once you cross the threshold
              (typically 0.1 VRSC). Check the dashboard for lifetime totals.
            </p>
          </div>
        {:else}
          <div class="flex items-center">
            <h5>Balance</h5>
            <IconRefresh class={`w-3 ml-2 cursor-pointer ${refreshingBalance ? 'animate-spin' : ''}`}
              on:click={handleGetBalance} />
          </div>
          <div class="flex items-end my-2">
            <p class="text-4xl m-0 mr-2 font-semibold">{balance.pendingBalance || 0}</p>
            <span>{$form.symbol || ''}</span>
          </div>
          <div class="flex flex-col">
            <p class="m-0 text-sm">
              <span class="text-gray-500">Last 24h Reward:</span>
              <span class="font-semibold">{balance.total24h || 0}</span>
            </p>
            <p class="m-0 text-sm">
              <span class="text-gray-500">Total Paid:</span>
              <span class="font-semibold">{balance.totalPaid || 0}</span>
            </p>
          </div>
        {/if}
      </div>
    </div>
  </div>

  <HashratesChart />

  <div>
    <div class="mb-4">
      <div class="text-gray-500">Hashrate</div>
      <div class="text-4xl flex items-center">
        {#if $isMining && !currentHashrate}
          <span class="text-gray-600">Running...</span>
        {:else if $form.algorithm === 'verushash'}
          <span>{(currentHashrate / 1e6).toFixed(2)} MH/s</span>
        {:else}
          <span>{currentHashrate || 0} H/s</span>
        {/if}
      </div>
      {#if $form.algorithm === 'verushash' && liveStats.vrscPerDay !== undefined}
        <div class="mt-2 flex items-baseline gap-3 text-sm flex-wrap">
          <span class="text-gray-500">~</span>
          <span class="font-mono text-sky-400 font-semibold"
            >{liveStats.vrscPerDay.toFixed(4)} VRSC/day</span
          >
          <span class="font-mono text-emerald-400 font-semibold"
            >${liveStats.usdPerDay.toFixed(3)}/day</span
          >
          {#if liveStats.threads}
            <span class="text-gray-500 text-xs">· {liveStats.threads} threads</span>
          {/if}
        </div>
        {#if liveStats.sessionVrsc !== undefined}
          <div class="mt-3 glass-card p-2.5 text-xs">
            <div class="flex items-center justify-between mb-1">
              <span class="text-gray-400">This session</span>
              {#if liveStats.uptimeSec !== undefined}
                <span class="text-gray-500 text-[10px]"
                  >uptime {Math.floor(liveStats.uptimeSec / 60)}m {liveStats.uptimeSec % 60}s</span
                >
              {/if}
            </div>
            <div class="flex items-baseline gap-3">
              <span class="font-mono text-sky-400 font-semibold"
                >{liveStats.sessionVrsc.toFixed(6)} VRSC</span
              >
              <span class="font-mono text-emerald-400">≈ ${liveStats.sessionUsd.toFixed(4)}</span>
            </div>
            <p class="text-[10px] text-gray-500 mt-1.5 leading-snug">
              Estimated from local hashes — see pool dashboard for confirmed
              accepted shares + lifetime VRSC across all sessions.
            </p>
          </div>
        {/if}
        <p class="text-[10px] text-gray-500 mt-2 leading-snug">
          <strong class="text-gray-400">Payments are automatic.</strong>
          LuckPool sends VRSC to your wallet when accumulated mining crosses
          the minimum threshold (default 0.1 VRSC, configurable as low as
          0.0001 VRSC via the pool dashboard). No manual claim button — it
          just lands in your wallet.
        </p>
      {/if}
    </div>
    <div class="flex justify-between items-end">
      <div class="flex flex-col"></div>
      <div class="flex items-center">
        <sl-tooltip content="Log" placement="top">
          <IconFileList
            class="w-6 mr-4 cursor-pointer"
            on:click={logDrawerEl.show}
          />
        </sl-tooltip>
        {#if !$isMining}
          <button
            type="button"
            class="glass-btn px-5 py-2 text-sm font-medium"
            disabled={$preparing}
            on:click={handleStart}>Start</button
          >
        {:else}
          <button
            type="button"
            class="glass-btn-danger px-5 py-2 text-sm font-medium"
            disabled={$preparing}
            on:click={handleStop}>Stop</button
          >
        {/if}
      </div>
    </div>
  </div>
</section>

<!-- dialog: logs -->
<Drawer fullscreen bind:this={logDrawerEl} title="Logs">
  <pre
    class="h-full p-4 overflow-auto select-text bg-gray-50 dark:bg-gray-900 text-xs rounded-md">
    {dialogLogsData.join('\n') || 'Pending logs...'}
  </pre>
</Drawer>
