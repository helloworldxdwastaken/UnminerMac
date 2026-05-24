<script>
  import { ipc } from '../ipc'
  import ConnectionStatus from './ConnectionStatus.svelte'
</script>

<div class="flex items-center justify-between mb-4">
  <h2 style="font-size:18px;font-weight:600;color:var(--ink)">Settings</h2>
  <ConnectionStatus />
</div>
