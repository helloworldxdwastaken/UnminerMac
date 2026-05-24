<script>
  import '@shoelace-style/shoelace/dist/components/button/button'
  import Link from '../components/Link.svelte'
  import RouterLink from '../components/RouterLink.svelte'
  import DarkModeSwitch from '../components/DarkModeSwitch.svelte'
  import { connectionStatus } from '../store'
  import { recheckConnection } from '../helper/connectionStatus'
</script>

<hgroup>
  <h1 class="text-sky-500">macMineable</h1>
  <h6 class="text-xs text-green-500">
    3rd-party unMineable for macOS. Made by
    <Link
      url="https://github.com/helloworldxdwastaken"
      class="underline hover:text-indigo-500">tokyo</Link
    >.
  </h6>
</hgroup>

<p class="text-sm">
  The fastest and easiest way to start mining your favorite non-mineable (& some
  mineable) coins!
</p>

{#if $connectionStatus === 'offline'}
  <div
    class="glass my-3 p-3 border border-red-400/40 bg-red-500/15 text-xs text-red-400"
  >
    <strong>Can't reach unMineable servers.</strong>
    Turn on your VPN (Cloudflare WARP / 1.1.1.1) or encrypted DNS, then
    <button
      type="button"
      class="underline hover:text-red-200"
      on:click={recheckConnection}>retry</button
    >.
  </div>
{/if}

<RouterLink to="/select-coin">
  <button class="glass-btn w-full px-4 py-3 font-medium tracking-wide">Continue</button>
</RouterLink>

<p class="text-xs text-gray-700 dark:text-gray-200">
  <span class="font-semibold">IMPORTANT:</span>
  Mining, if not made correctly, could lead to permanent damage of your hardware
  components as it uses a lot of computation power and energy, that's why
  <!-- svelte-ignore a11y-invalid-attribute -->
  <a href="#" class="underline"
    >we have introduced a default low hashing setting
  </a>
  which will also slightly lower your rewards. You can set the high hashing option
  in advanced settings to increase you rewards at your own risk.
</p>

<span class="hidden">
  <DarkModeSwitch />
</span>
