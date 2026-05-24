<script>
  import { tryOnMount } from '@svelte-use/core'
  import * as router from 'svelte-spa-router'
  import 'vercel-toast/dist/vercel-toast.css'
  import { createToast } from 'vercel-toast'
  import { ipc } from '../ipc'
  import { getReferralCode, validateAddress, NetworkError, fetchCoinDetail } from '../server/unMineable'
  import { recheckConnection } from '../helper/connectionStatus'
  import { form, preparing, isMining, coins } from '../store'
  import { parseFormData } from '../util/form'
  import { getStorage, setStorage } from '../util/storage'
  import ConnectionStatus from '../components/ConnectionStatus.svelte'
  import { log } from '../util/log'

  const ROUGH_XMR_PER_KH_DAY = 0.00006
  const ASSUMED_HASHRATE_KH = 3
  const COIN_TO_XMR = { XMR:1, BTC:280, ETH:14, DOGE:0.0007, SHIB:0.0000001, LTC:0.5, BNB:3, SOL:0.7 }

  let formEl, inputAddressEl, inputReferralCodeEl
  let selectedAlgorithm = 'randomx'
  let selectedSymbol = ''
  let selectedDetail = null, loadingDetail = false

  $: selectedCoin = $coins.find((c) => c[1] === selectedSymbol)
  $: daysToPayout = (() => {
    if (!selectedDetail?.payment_threshold) return null
    const th = Number(selectedDetail.payment_threshold)
    if (!th || Number.isNaN(th)) return null
    const d = ASSUMED_HASHRATE_KH * ROUGH_XMR_PER_KH_DAY * 0.99
    const x = COIN_TO_XMR[selectedSymbol]; if (!x) return null
    const dc = d / x; if (dc <= 0) return null
    return Math.ceil(th / dc)
  })()

  async function loadDetail(s) { if(!s){selectedDetail=null;return} loadingDetail=true; selectedDetail=await fetchCoinDetail(s); loadingDetail=false }
  $: loadDetail(selectedSymbol)

  function onStart(e) {
    e.preventDefault()
    $preparing = true
    const data = parseFormData(new FormData(formEl))

    if (data.algorithm === 'verushash') {
      $form = { ...$form, ...data }
      setStorage('form', $form)
      ipc.listen('onMiningStarted', () => { $preparing=false; $isMining=true; router.push('/mining') })
      ipc.send('emitStartMining', JSON.stringify($form))
      return
    }

    log('validating address')
    validateAddress(data.symbol, data.address)
      .then(isExist => {
        if (isExist) {
          $form = { ...$form, ...data }
          setStorage('form', $form); setStorage($form.symbol, $form.address)
          ipc.listen('onMiningStarted', () => { $preparing=false; $isMining=true; router.push('/mining') })
          ipc.send('emitStartMining', JSON.stringify($form))
        } else {
          createToast(`Address not registered on unMineable.`, { type:'error', action:{ text:'Register', callback: t => { ipc.send('emitOpenURL',`https://unmineable.com/coins/${$form.symbol}/address`); t.destory() }}, cancel:'Cancel' })
        }
      })
      .catch(err => {
        $preparing=false
        if (err instanceof NetworkError) {
          recheckConnection()
          createToast(err.message, { type:'error', action:{ text:'Retry', callback: t => { t.destory(); onStart(e) }}, cancel:'Cancel' })
        } else {
          createToast(err?.message || 'Unknown error', { type:'error', cancel:'Cancel' })
        }
      })
      .finally(() => { $preparing = false })
  }

  function onCoinChange(e) {
    selectedSymbol = e.target.value
    inputAddressEl.value = getStorage(selectedSymbol) || ''
    inputReferralCodeEl.value = getReferralCode($coins, selectedSymbol) || ''
  }

  tryOnMount(() => {
    const s = getStorage('form')
    if (s) {
      formEl.elements.symbol.value = s.symbol || ''
      formEl.elements.address.value = s.address || ''
      formEl.elements.referralCode.value = s.referralCode || ''
      selectedSymbol = s.symbol || ''
      selectedAlgorithm = s.algorithm || 'randomx'
      if (s.algorithm && formEl.elements.algorithm) formEl.elements.algorithm.value = s.algorithm
    }
  })
</script>

<form bind:this={formEl} on:submit={onStart}>
  <div class="flex items-center justify-between mb-4">
    <h2 style="font-size:18px;font-weight:600;letter-spacing:-0.01em;color:var(--ink)">New Mining Session</h2>
    <ConnectionStatus />
  </div>

  <div class="card">
    <div class="card-header"><span class="card-title">Algorithm</span></div>
    <select name="algorithm" bind:value={selectedAlgorithm} class="select">
      <option value="randomx">RandomX — XMR via unMineable</option>
      <option value="verushash">VerusHash 2.2 — VRSC via LuckPool</option>
    </select>
    <p class="text-xs text-dim mt-2">
      {selectedAlgorithm === 'verushash' ? 'Mine VRSC directly on LuckPool. No registration needed.' : 'Mine XMR, auto-convert to 35+ coins via unMineable.'}
    </p>
  </div>

  {#if selectedAlgorithm === 'verushash'}
    <div class="card mt-3">
      <div class="card-header"><span class="card-title">Pool Info</span></div>
      <div class="info-grid" style="margin-bottom:0">
        <div class="info-chip"><div class="chip-label">Coin</div><div class="chip-value">VerusCoin (VRSC)</div></div>
        <div class="info-chip"><div class="chip-label">Pool</div><div class="chip-value">LuckPool · 1% fee</div></div>
        <div class="info-chip"><div class="chip-label">Price</div><div class="chip-value text-gold">~$0.61</div></div>
        <div class="info-chip"><div class="chip-label">Payout</div><div class="chip-value">Auto at threshold</div></div>
      </div>
    </div>
  {:else}
    <div class="card mt-3">
      <div class="card-header"><span class="card-title">Coin</span></div>
      <div class="coin-selector mb-3">
        {#if selectedCoin}
          <img src={selectedCoin[3]} alt={selectedCoin[1]} on:error={e => e.target.style.visibility='hidden'}/>
        {:else}
          <div style="width:32px;height:32px;border-radius:50%;background:rgba(255,255,255,.06);flex-shrink:0"></div>
        {/if}
        <select name="symbol" required bind:value={selectedSymbol} on:change={onCoinChange} class="select flex-1">
          <option value="" disabled>Select a coin…</option>
          {#each $coins as c (c[1])}
            <option value={c[1]}>{c[0]} ({c[1]})</option>
          {/each}
        </select>
      </div>
      {#if selectedSymbol && selectedDetail}
        <div class="info-grid" style="margin-bottom:0">
          <div class="info-chip"><div class="chip-label">Min Payout</div><div class="chip-value mono">{selectedDetail.payment_threshold} {selectedSymbol}</div></div>
          <div class="info-chip"><div class="chip-label">Network</div><div class="chip-value">{selectedDetail.network || '—'}</div></div>
          {#if daysToPayout != null}
            <div class="info-chip"><div class="chip-label">Est. Days</div><div class="chip-value">{daysToPayout > 9999 ? '9999+' : daysToPayout} @ 3 kH/s</div></div>
          {/if}
        </div>
      {:else if loadingDetail}
        <p class="text-xs text-dim">Loading…</p>
      {/if}
    </div>
  {/if}

  <div class="card mt-3">
    <div class="card-header"><span class="card-title">Wallet Address</span></div>
    <input name="address" type="text" required bind:this={inputAddressEl} class="input" placeholder={selectedAlgorithm === 'verushash' ? 'R-address, i-address, or zs1-address' : 'Your coin wallet address'}/>
    <p class="text-xs text-dim mt-2">
      {selectedAlgorithm === 'verushash' ? 'Payouts go directly to your Verus wallet.' : 'The address on your chosen coin\'s network for payouts.'}
    </p>
  </div>

  {#if selectedAlgorithm === 'randomx'}
    <div class="card mt-3">
      <div class="card-header"><span class="card-title">Referral Code</span></div>
      <input name="referralCode" type="text" bind:this={inputReferralCodeEl} class="input" placeholder="Optional"/>
      <p class="text-xs text-dim mt-2">Leave empty unless you have your own unMineable referral code.</p>
    </div>
  {/if}

  <button type="submit" class="btn btn-primary btn-full btn-lg mt-4" disabled={$preparing}>
    {$preparing ? 'Starting…' : 'Start Mining'}
  </button>
</form>
