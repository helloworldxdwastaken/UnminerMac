<script>
  import Link from '../components/Link.svelte'
  import RouterLink from '../components/RouterLink.svelte'
  import { connectionStatus } from '../store'
  import { recheckConnection } from '../helper/connectionStatus'
</script>

<div style="padding-top:40px;text-align:center">
  <h1 style="font-size:32px;font-weight:700;letter-spacing:-0.02em;color:var(--ink)">
    Unminer<span style="color:var(--accent)">Mac</span>
  </h1>
  <p class="text-dim mt-2" style="font-size:15px">
    Mine XMR & VRSC on Apple Silicon
  </p>
</div>

{#if $connectionStatus === 'offline'}
  <div class="card mt-4" style="border-left:3px solid var(--red);background:rgba(248,81,73,.08)">
    <p class="text-sm" style="color:var(--red);margin:0">
      <strong>Can't reach servers.</strong> Turn on VPN (Cloudflare WARP / 1.1.1.1) or encrypted DNS, then
      <button type="button" style="background:none;border:none;color:var(--red);text-decoration:underline;cursor:pointer;font:inherit;padding:0" on:click={recheckConnection}>retry</button>.
    </p>
  </div>
{/if}

<div class="info-grid mt-4">
  <div class="info-chip">
    <div class="chip-label">Algorithms</div>
    <div class="chip-value">RandomX + VerusHash 2.2</div>
  </div>
  <div class="info-chip">
    <div class="chip-label">Platform</div>
    <div class="chip-value">Apple Silicon M1–M5</div>
  </div>
  <div class="info-chip">
    <div class="chip-label">VerusHash</div>
    <div class="chip-value text-gold">7.3 MH/s on M5</div>
  </div>
  <div class="info-chip">
    <div class="chip-label">Metal GPU</div>
    <div class="chip-value">In development</div>
  </div>
</div>

<RouterLink to="/select-coin">
  <button class="btn btn-primary btn-full btn-lg mt-4">Start Mining</button>
</RouterLink>

<p class="text-xs text-dim mt-3" style="text-align:center">
  Mining uses significant CPU and energy. Default settings are conservative.
</p>

<div class="divider"></div>

<p style="text-align:center;font-size:10px;color:var(--ink-muted)">
  Built by <Link url="https://veroxstudio.com" style="color:var(--accent);text-decoration:none">veroxstudio.com</Link>
</p>
