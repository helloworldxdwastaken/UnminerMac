<script>
  import _isEqual from 'lodash.isequal'
  import Drawer from './Drawer.svelte'
  import FormSettings from './FormSettings.svelte'
  import { parseFormData } from '../util/form'
  import { form, isMining } from '../store'
  import { ipc } from '../ipc'
  import { setStorage } from '../util/storage'

  let drawerComp
  let formSettingsComp

  let saving = false
  let isChanged = false

  export function show() {
    drawerComp.show()
  }

  function handleSave() {
    const formData = formSettingsComp.getFormData()
    const data = parseFormData(formData, (v) => {
      v.cpuUsage = Number(v.cpuUsage)
      return v
    })

    $form = { ...$form, ...data }
    setStorage('form', $form)

    if ($isMining) {
      saving = true
      ipc.listen('onMiningStopped', () => {
        ipc.listen('onMiningStarted', () => {
          saving = false
          isChanged = false
          drawerComp.hide()
        })
        ipc.send('emitStartMining', JSON.stringify($form))
      })
      ipc.send('emitStopMining')
    } else {
      isChanged = false
      drawerComp.hide()
    }
  }

  function resetFormData() {
    formSettingsComp.setFormData($form)
    isChanged = false
  }

  function onFormChange(event) {
    const data = event.detail
    isChanged = !_isEqual($form, data)
  }
</script>

<Drawer
  bind:this={drawerComp}
  fullscreen
  title="Settings"
  on:show={resetFormData}
  on:after-hide={resetFormData}
>
  <FormSettings bind:this={formSettingsComp} on:change={onFormChange} />

  <button
    slot="footer"
    type="button"
    class="btn btn-primary"
    on:click={handleSave}
    disabled={saving || !isChanged}
  >
    {#if saving}
      Restarting…
    {:else}
      Save{$isMining ? ' & Restart' : ''}
    {/if}
  </button>
</Drawer>
