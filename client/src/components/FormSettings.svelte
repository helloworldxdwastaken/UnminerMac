<script>
  import { tryOnMount } from '@svelte-use/core'
  import { form, cpuCores } from '../store'
  import { useDispatch } from '../use/dispatch'

  const { dispatch } = useDispatch()
  $: step = Math.max(1, Math.round(100 / $cpuCores))
  $: threadsAtCurrent = Math.max(1, Math.round((tweakForm.cpuUsage / 100) * $cpuCores))
  $: pCoreHint = $cpuCores >= 8 && tweakForm.cpuUsage <= 50
    ? 'P-cores only ✓ (best for RandomX)'
    : tweakForm.cpuUsage > 50 ? 'E-cores included — may reduce hashrate' : ''

  let tweakForm = { cpuUsage: $form.cpuUsage }
  let formEl

  export function getFormData() { return new FormData(formEl) }
  export function setFormData(data) {
    if (!data) return
    if (typeof data.cpuUsage === 'number' || typeof data.cpuUsage === 'string')
      tweakForm.cpuUsage = Number(data.cpuUsage)
  }

  function onSlide(e) {
    tweakForm.cpuUsage = Number(e.target.value)
    dispatch('change', { ...$form, cpuUsage: tweakForm.cpuUsage })
  }
</script>

<form bind:this={formEl}>
  <div class="form-group">
    <div class="flex items-center justify-between mb-2">
      <span class="label" style="margin-bottom:0">CPU Usage</span>
      <span class="mono text-accent" style="font-size:20px;font-weight:600">{tweakForm.cpuUsage}%</span>
    </div>
    <input type="range" name="cpuUsage" min={step} max="100" {step} value={tweakForm.cpuUsage}
      on:input={onSlide}
      style="width:100%;accent-color:var(--accent)"/>
    <div class="flex justify-between text-xs text-dim mt-1">
      <span>{step}%</span>
      <span>~{threadsAtCurrent} / {$cpuCores} threads</span>
      <span>100%</span>
    </div>
    {#if pCoreHint}
      <p class="text-xs mt-2 text-dim">{pCoreHint}</p>
    {/if}
  </div>
</form>
