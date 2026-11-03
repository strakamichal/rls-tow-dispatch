<template>
  <div class="hub-root">
    <main class="hub-app">
      <header class="summary">
        <span class="eyebrow">Tow &amp; Repo Hub</span>
        <h1>Job board</h1>
      </header>

      <section v-if="state && state.rlsVersionStatus !== 'ok'" class="notice warning">
        <strong>Unsupported RLS version</strong>
        <p v-if="state.rlsVersion">
          Installed RLS {{ state.rlsVersion }}; this add-on is built for RLS {{ state.supportedVersion }}.
          Jobs may not work correctly.
        </p>
        <p v-else>RLS Career Overhaul was not found. This add-on needs RLS {{ state.supportedVersion }}.</p>
      </section>

      <section v-if="state && !state.careerActive" class="notice">
        <strong>Career not active</strong>
        <p>Start or load an RLS career to see jobs.</p>
      </section>

      <section class="empty">
        <strong>No offers yet</strong>
        <span>The job board is coming in a later version.</span>
      </section>

      <footer v-if="state" class="footer">RLS {{ state.rlsVersion || 'not found' }}</footer>
    </main>
  </div>
</template>

<script setup>
import { onActivated, onMounted, ref } from 'vue'

// PhoneAppHost passes the RLS callModLua helper as callLua.
const props = defineProps({
  app: { type: Object, default: null },
  callLua: { type: Function, default: null },
})

const state = ref(null)

async function refresh() {
  if (!props.callLua) return
  const result = await props.callLua('towRepoHub_core.getState')
  state.value = result && typeof result === 'object' ? result : { rlsVersionStatus: 'missing', careerActive: false }
}

onMounted(refresh)
onActivated(refresh)
</script>

<style scoped lang="scss">
.hub-root { position: relative; height: 100%; }
.hub-app {
  height: 100%;
  overflow-y: auto;
  box-sizing: border-box;
  padding: 48px 10px 20px;
  color: #eef3f8;
  background: linear-gradient(180deg, #1f3d5c 0, #121821 34%, #0a0c10 100%);
  font-family: Overpass, sans-serif;
}
.summary { padding: 4px 4px 12px; }
.summary h1 { margin: 2px 0 0; font-size: 1.4em; }
.eyebrow { font-size: .75em; text-transform: uppercase; letter-spacing: .08em; opacity: .7; }
.notice {
  margin: 0 0 10px;
  padding: 10px 12px;
  border-radius: 8px;
  background: rgba(255, 255, 255, .08);
  p { margin: 4px 0 0; font-size: .9em; opacity: .85; }
}
.notice.warning { background: rgba(214, 140, 30, .25); border: 1px solid rgba(214, 140, 30, .6); }
.empty {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 24px 12px;
  text-align: center;
  opacity: .8;
}
.footer { margin-top: 16px; font-size: .75em; text-align: center; opacity: .5; }
</style>
