<script>
  import { tryOnMount } from '@svelte-use/core'
  import * as router from 'svelte-spa-router'
  import 'vercel-toast/dist/vercel-toast.css'
  import { createToast } from 'vercel-toast'

  import { ipc } from '../ipc'
  import {
    getReferralCode,
    validateAddress,
    NetworkError,
    fetchCoinDetail,
  } from '../server/unMineable'
  import { recheckConnection } from '../helper/connectionStatus'
  import { form, preparing, isMining, coins } from '../store'
  import { parseFormData, setFormData } from '../util/form'
  import { getStorage, setStorage } from '../util/storage'
  import TopButtons from '../components/TopButtons.svelte'
  import { log } from '../util/log'

  // Rough RandomX yield baseline at current pool/network conditions.
  // ~3 kH/s on M5 → ~0.00018 XMR/day BEFORE fee. We surface this as XMR/day
  // per kH/s so the math stays in one place if conditions shift.
  const ROUGH_XMR_PER_KH_DAY = 0.00006
  // Assumed user effective hashrate when computing days-to-payout.
  // The mining page tracks real hashrate; we don't pipe it here yet.
  const ASSUMED_HASHRATE_KH = 3
  // Spot prices in XMR — only used for a rough day-to-payout hint.
  // (User's actual conversion happens at unMineable's internal rate.)
  const COIN_TO_XMR = {
    XMR: 1,
    BTC: 280, // 1 BTC ≈ 280 XMR (rough)
    ETH: 14, // 1 ETH ≈ 14 XMR
    DOGE: 0.0007,
    SHIB: 0.0000001,
    LTC: 0.5,
    BNB: 3,
    SOL: 0.7,
  }

  let formEl
  let inputAddressEl
  let inputReferralCodeEl
  let selectedSymbol = ''
  let selectedDetail = null
  let loadingDetail = false

  $: selectedCoin = $coins.find((c) => c[1] === selectedSymbol)

  $: daysToPayout = (() => {
    if (!selectedDetail || !selectedDetail.payment_threshold) return null
    const threshold = Number(selectedDetail.payment_threshold)
    if (!threshold || Number.isNaN(threshold)) return null
    const dailyXmr = ASSUMED_HASHRATE_KH * ROUGH_XMR_PER_KH_DAY * 0.99 // -1% fee
    const xmrPerCoin = COIN_TO_XMR[selectedSymbol]
    if (!xmrPerCoin) return null
    const dailyCoin = dailyXmr / xmrPerCoin
    if (dailyCoin <= 0) return null
    return Math.ceil(threshold / dailyCoin)
  })()

  async function loadDetail(symbol) {
    if (!symbol) {
      selectedDetail = null
      return
    }
    loadingDetail = true
    selectedDetail = await fetchCoinDetail(symbol)
    loadingDetail = false
  }

  $: loadDetail(selectedSymbol)

  function onStart(event) {
    event.preventDefault()
    log('page select-coin:', 'start')

    $preparing = true
    log('page select-coin:', 'validating address')

    const data = parseFormData(new FormData(formEl))
    validateAddress(data.symbol, data.address)
      .then((isExist) => {
        if (isExist) {
          $form = { ...$form, ...data }
          setStorage('form', $form)
          setStorage($form.symbol, $form.address)

          ipc.listen('onMiningStarted', () => {
            $preparing = false
            $isMining = true
            router.push('/mining')
          })
          ipc.send('emitStartMining', JSON.stringify($form))
        } else {
          createToast(
            `Your address doesn't exist on unMineable, please register it first.`,
            {
              type: 'error',
              action: {
                text: 'Register',
                callback: (toast) => {
                  ipc.send(
                    'emitOpenURL',
                    `https://unmineable.com/coins/${$form.symbol}/address`,
                  )
                  toast.destory()
                },
              },
              cancel: 'Cancel',
            },
          )
        }
      })
      .catch((error) => {
        $preparing = false
        if (error instanceof NetworkError) {
          recheckConnection()
          createToast(error.message, {
            type: 'error',
            action: {
              text: 'Retry',
              callback: (toast) => {
                toast.destory()
                onStart(event)
              },
            },
            cancel: 'Cancel',
          })
        } else {
          createToast(
            error && error.message ? error.message : 'Unknown error',
            { type: 'error', cancel: 'Cancel' },
          )
        }
      })
      .finally(() => {
        $preparing = false
      })
  }

  function onSelectCoinChange(event) {
    selectedSymbol = event.target.value
    inputAddressEl.value = getStorage(selectedSymbol) || ''
    inputReferralCodeEl.value = getReferralCode($coins, selectedSymbol) || ''
  }

  tryOnMount(() => {
    const stored = getStorage('form')
    if (stored) {
      formEl.elements.symbol.value = stored.symbol || ''
      formEl.elements.address.value = stored.address || ''
      formEl.elements.referralCode.value = stored.referralCode || ''
      selectedSymbol = stored.symbol || ''
    }
  })
</script>

<div class="flex justify-end">
  <TopButtons />
</div>

<form bind:this={formEl} on:submit={onStart}>
  <label class="block my-4">
    <span class="block text-sm mb-1">
      Select a coin or token
      <span class="text-xs text-gray-500">({$coins.length} available)</span>
    </span>
    <div class="flex items-center gap-2">
      {#if selectedCoin}
        <img
          src={selectedCoin[3]}
          alt={selectedCoin[1]}
          class="w-8 h-8 rounded-full bg-white p-1 shrink-0"
          on:error={(e) => (e.target.style.visibility = 'hidden')}
        />
      {:else}
        <div class="w-8 h-8 rounded-full bg-gray-700 shrink-0"></div>
      {/if}
      <select
        name="symbol"
        required
        bind:value={selectedSymbol}
        on:change={onSelectCoinChange}
        class="glass-input glass-select flex-1 px-3 py-2 text-black dark:text-white"
      >
        <option value="" disabled>— pick one —</option>
        {#each $coins as coin (coin[1])}
          <option value={coin[1]}>{coin[0]} ({coin[1]})</option>
        {/each}
      </select>
    </div>
  </label>

  {#if selectedSymbol}
    <div class="glass-card my-3 p-3 text-xs">
      {#if loadingDetail}
        <span class="text-gray-400">Loading payout info…</span>
      {:else if selectedDetail}
        <div class="flex justify-between mb-1">
          <span class="text-gray-400">Min payout</span>
          <span class="font-mono"
            >{selectedDetail.payment_threshold} {selectedSymbol}</span
          >
        </div>
        <div class="flex justify-between mb-1">
          <span class="text-gray-400">Network</span>
          <span>{selectedDetail.network || '—'}</span>
        </div>
        {#if daysToPayout != null}
          <div class="flex justify-between mb-1">
            <span class="text-gray-400">Est. days to payout</span>
            <span
              >{daysToPayout > 9999 ? '9999+' : daysToPayout} days @ ~{ASSUMED_HASHRATE_KH} kH/s</span
            >
          </div>
        {/if}
        {#if !COIN_TO_XMR[selectedSymbol]}
          <p class="text-gray-500 mt-2">
            No spot-price estimate for this coin. Lower threshold = faster
            first payout.
          </p>
        {/if}
        {#if selectedDetail.high_risk}
          <p class="text-amber-400 mt-2">
            ⚠ unMineable flags this coin as high-risk.
          </p>
        {/if}
      {:else}
        <span class="text-gray-400">Payout info unavailable.</span>
      {/if}
    </div>
  {/if}

  <label class="block my-4">
    <span class="block text-sm mb-1">Enter your address</span>
    <input
      name="address"
      type="text"
      required
      bind:this={inputAddressEl}
      class="glass-input w-full px-3 py-2 text-black dark:text-white"
    />
  </label>

  <label class="block my-4">
    <span class="block text-sm mb-1">Referral Code (Optional)</span>
    <input
      name="referralCode"
      type="text"
      bind:this={inputReferralCodeEl}
      class="glass-input w-full px-3 py-2 text-black dark:text-white"
    />
    <p class="mt-2 text-xs text-gray-400">
      Leave empty unless you have your own unMineable referral code.
    </p>
  </label>

  <button
    type="submit"
    class="glass-btn w-full mt-4 px-4 py-3 font-medium tracking-wide"
    disabled={$preparing}
  >
    {$preparing ? 'Starting…' : 'Start'}
  </button>
</form>
