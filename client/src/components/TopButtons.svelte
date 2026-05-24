<script>
  import IconGitHub from './icons/GitHub.svelte'
  import IconSettings from './icons/Settings.svelte'
  import { ipc } from '../ipc'
  import DrawerFormSettings from './DrawerFormSettings.svelte'
  import DarkModeSwitch from './DarkModeSwitch.svelte'
  import ConnectionStatus from './ConnectionStatus.svelte'

  let drawerFormSettingsComp

  let buttons = [
    {
      component: IconGitHub,
      onClick: () => {
        ipc.send('emitOpenURL', 'https://github.com/helloworldxdwastaken/UnMIneableMac')
      },
    },
    {
      component: DarkModeSwitch,
    },
    {
      component: IconSettings,
      onClick: () => {
        drawerFormSettingsComp.show()
      },
    },
  ]
</script>

<div class="flex items-center">
  <ConnectionStatus />
  {#each buttons as button, i (i)}
    <svelte:component
      this={button.component}
      class="w-4 ml-2 cursor-pointer"
      on:click={button.onClick}
    />
  {/each}
</div>

<DrawerFormSettings bind:this={drawerFormSettingsComp} />
