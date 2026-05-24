<script>
  import './assets/index.css'
  import './assets/vars.css'
  import '@shoelace-style/shoelace/dist/themes/light.css'
  import '@shoelace-style/shoelace/dist/themes/dark.css'

  import { routes, Router } from './router'
  import { ipc } from './ipc'
  import { log } from './util/log'
  import { cpuCores, pCores, form } from './store'
  import { wsMiningLog } from './helper/wsMiningLog'
  import { common } from './helper/common'
  import { startConnectionWatch } from './helper/connectionStatus'
  import { loadCoins } from './helper/coinLoader'

  ipc.listen('onPageReady', (data) => {
    log('onPageReady', data)
    $cpuCores = data.cpuCores
    $pCores = data.pCores || 0

    // First-run default: snap CPU usage to P-core percent (best for RandomX).
    // Skip if user already saved a form (respect their choice).
    if ($pCores > 0 && $cpuCores > 0 && !localStorage.getItem('form')) {
      const pCorePercent = Math.round(($pCores / $cpuCores) * 100)
      $form = { ...$form, cpuUsage: pCorePercent }
    }
  })
  ipc.send('emitPageReady')

  wsMiningLog()
  common()
  startConnectionWatch()
  loadCoins()
</script>

<main class="flex flex-col justify-between h-screen p-3">
  <div class="glass p-6 flex-1 overflow-y-auto">
    <Router {routes} />
  </div>
</main>
