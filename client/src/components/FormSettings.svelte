<script>
  import { tryOnMount } from '@svelte-use/core'
  import { form, cpuCores } from '../store'
  import { useDispatch } from '../use/dispatch'

  const { dispatch } = useDispatch()

  // Step = one core's worth (so 4 P-cores on a 10-core M5 = 40%)
  $: step = Math.max(1, Math.round(100 / $cpuCores))
  $: threadsAtCurrent = Math.max(1, Math.round((tweakForm.cpuUsage / 100) * $cpuCores))
  $: pCoreHint =
    $cpuCores >= 8 && tweakForm.cpuUsage <= 50
      ? 'Using P-cores only ✓ (best for RandomX)'
      : tweakForm.cpuUsage > 50
      ? 'E-cores included — may reduce sustained hashrate'
      : ''

  let tweakForm = {
    cpuUsage: $form.cpuUsage,
  }

  let formEl

  export function getFormData() {
    return new FormData(formEl)
  }

  export function setFormData(data) {
    if (!data) return
    if (typeof data.cpuUsage === 'number' || typeof data.cpuUsage === 'string') {
      tweakForm.cpuUsage = Number(data.cpuUsage)
    }
  }

  function onSlide(event) {
    tweakForm.cpuUsage = Number(event.target.value)
    dispatch('change', { ...$form, cpuUsage: tweakForm.cpuUsage })
  }
</script>

<form bind:this={formEl} class="p-2">
  <label class="block">
    <div class="flex items-baseline justify-between mb-2">
      <span class="font-medium">CPU Usage</span>
      <span class="font-mono text-sky-400 text-lg"
        >{tweakForm.cpuUsage}%</span
      >
    </div>
    <input
      type="range"
      name="cpuUsage"
      min={step}
      max="100"
      {step}
      value={tweakForm.cpuUsage}
      on:input={onSlide}
      class="w-full accent-sky-500"
    />
    <div class="flex justify-between text-xs text-gray-400 mt-1">
      <span>{step}%</span>
      <span>~{threadsAtCurrent} of {$cpuCores} threads</span>
      <span>100%</span>
    </div>
    {#if pCoreHint}
      <p class="text-xs mt-3 text-gray-400">{pCoreHint}</p>
    {/if}
  </label>
</form>
