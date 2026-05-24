<script>
  import { connectionStatus } from '../store'
  import { recheckConnection } from '../helper/connectionStatus'

  $: color =
    $connectionStatus === 'online'
      ? 'bg-green-500'
      : $connectionStatus === 'offline'
      ? 'bg-red-500'
      : $connectionStatus === 'checking'
      ? 'bg-yellow-400 animate-pulse'
      : 'bg-gray-400'

  $: label =
    $connectionStatus === 'online'
      ? 'Connected to unMineable'
      : $connectionStatus === 'offline'
      ? 'Cannot reach unMineable — check VPN/network'
      : $connectionStatus === 'checking'
      ? 'Checking connection…'
      : 'Connection status unknown'
</script>

<button
  type="button"
  class="flex items-center text-xs text-gray-400 hover:text-gray-200 cursor-pointer ml-2"
  title={label}
  on:click={recheckConnection}
>
  <span class="w-2.5 h-2.5 rounded-full {color}"></span>
</button>
