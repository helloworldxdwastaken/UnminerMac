<script>
  import { connectionStatus } from '../store'
  import { recheckConnection } from '../helper/connectionStatus'

  $: cls = 'status-dot ' + $connectionStatus
  $: label =
    $connectionStatus === 'online' ? 'Connected' :
    $connectionStatus === 'offline' ? 'Blocked — click to retry' :
    $connectionStatus === 'checking' ? 'Checking…' : 'Unknown'
</script>

<button type="button" class="btn btn-ghost flex items-center gap-2" title={label} on:click={recheckConnection}>
  <span class={cls}></span>
  <span class="text-xs">{label}</span>
</button>
