<script>
  import { tryOnMount } from '@svelte-use/core'
  import { listen } from 'svelte/internal'
  import '@shoelace-style/shoelace/dist/components/drawer/drawer'
  import { useDispatch } from '../use/dispatch'

  const { dispatch } = useDispatch()
  export let title = 'Drawer'
  export let fullscreen = false
  $: style = fullscreen ? '--size: 100vw;' : ''

  let drawerEl, closeEl

  export function show() { drawerEl.show() }
  export function hide() { drawerEl.hide() }

  tryOnMount(() => {
    listen(closeEl, 'click', () => drawerEl.hide())
    listen(drawerEl, 'sl-show', () => dispatch('show'))
    listen(drawerEl, 'sl-after-hide', () => dispatch('after-hide'))
  })
</script>

<sl-drawer bind:this={drawerEl} {style} no-header>
  <header style="margin-bottom:24px">
    <h2 style="font-size:20px;font-weight:600;color:var(--ink)">{title}</h2>
  </header>
  <div style="flex:1;overflow:auto;padding-bottom:16px">
    <slot />
  </div>
  <div slot="footer" class="flex items-center justify-end gap-3">
    <button type="button" bind:this={closeEl} class="btn btn-secondary">Close</button>
    <slot name="footer" />
  </div>
</sl-drawer>
