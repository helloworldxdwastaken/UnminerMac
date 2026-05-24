<script>
  import './assets/index.css'
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

<div class="app-shell">
  <div class="app-content">
    <Router {routes} />
  </div>
</div>
