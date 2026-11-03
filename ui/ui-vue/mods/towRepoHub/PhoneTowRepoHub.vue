<template>
  <div class="hub-root">
    <main class="hub-app">
      <header class="summary">
        <div>
          <span class="eyebrow">Tow &amp; Repo Hub</span>
          <h1>Job board</h1>
        </div>
        <div v-if="state && state.careerActive" class="summary-right">
          <span>Recovery level {{ state.skillLevel }}</span>
          <small>+{{ percent(state.skillBonus) }} pay</small>
        </div>
      </header>

      <section v-if="state && state.rlsVersionStatus !== 'ok'" class="notice warning">
        <strong>Unsupported RLS version</strong>
        <p v-if="state.rlsVersion">
          Installed RLS {{ state.rlsVersion }}; this add-on is built for RLS {{ state.supportedVersion }}.
          Jobs may not work correctly.
        </p>
        <p v-else>RLS Career Overhaul was not found. This add-on needs RLS {{ state.supportedVersion }}.</p>
      </section>

      <section v-if="state && state.disabledReason" class="notice">
        <strong>Jobs unavailable</strong>
        <p>{{ state.disabledReason }}</p>
      </section>

      <template v-else-if="state">
        <section v-if="message" class="notice">
          <p>{{ message }}</p>
        </section>

        <article v-if="job" class="card active-card">
          <span class="eyebrow">Active job · {{ phaseLabel(job) }}</span>
          <div class="card-top">
            <h3>{{ vehicleLabel(job) }}</h3>
            <strong class="quote">{{ money(job.quote) }}</strong>
          </div>
          <dl>
            <div><dt>Destination</dt><dd>{{ job.destinationName }}</dd></div>
            <div><dt>{{ job.custody ? 'To destination' : 'To vehicle' }}</dt><dd>{{ distance(job.distanceToNextM) }}</dd></div>
          </dl>
          <p v-if="job.otherMap" class="hint">This job is on another map.</p>
          <div class="actions">
            <button type="button" class="secondary" @click="routeJob">Route</button>
            <button type="button" class="danger" @click="confirmingCancel = true">Cancel</button>
          </div>
        </article>

        <section class="controls">
          <div class="control-row">
            <span class="label">Sort</span>
            <button v-for="option in sortOptions" :key="option.id" type="button" class="chip"
              :class="{ active: sortBy === option.id }" @click="sortBy = option.id">{{ option.label }}</button>
          </div>
          <div class="control-row">
            <span class="label">Type</span>
            <button v-for="option in typeOptions" :key="option.id" type="button" class="chip"
              :class="{ active: typeFilter === option.id }" @click="typeFilter = option.id">{{ option.label }}</button>
          </div>
          <div v-if="tierOptions.length > 1" class="control-row">
            <span class="label">Tier</span>
            <button type="button" class="chip" :class="{ active: tierFilter === 'all' }" @click="tierFilter = 'all'">All</button>
            <button v-for="tier in tierOptions" :key="tier.tag" type="button" class="chip"
              :class="{ active: tierFilter === tier.tag }" @click="tierFilter = tier.tag">{{ tier.label }}</button>
          </div>
          <div class="control-row">
            <span class="label">Within</span>
            <button v-for="option in distanceOptions" :key="option.km" type="button" class="chip"
              :class="{ active: maxDistanceKm === option.km }" @click="maxDistanceKm = option.km">{{ option.label }}</button>
          </div>
        </section>

        <div class="section-heading">
          <h2>Offers</h2>
          <span>{{ visibleOffers.length }}/{{ state.offers.length }} shown · {{ state.offers.length }}/{{ state.boardSize }}</span>
        </div>

        <article v-for="offer in visibleOffers" :key="offer.id" class="card">
          <div class="card-top">
            <div>
              <span class="eyebrow">
                <span class="job-type" :class="offer.jobType">{{ offer.jobType === 'tow' ? 'Tow' : 'Repo' }}</span>
                {{ offer.tierLabel }}
              </span>
              <h3>{{ vehicleLabel(offer) }}</h3>
            </div>
            <strong class="quote">{{ money(offer.quote) }}</strong>
          </div>
          <dl>
            <div><dt>To vehicle</dt><dd>{{ distance(offer.distanceToVehicleM) }}</dd></div>
            <div><dt>Route loaded</dt><dd>{{ distance(offer.loadedM) }}</dd></div>
            <div><dt>Destination</dt><dd>{{ offer.destinationName }}</dd></div>
            <div><dt>Weight</dt><dd>{{ weight(offer.weightKg) }}</dd></div>
            <div><dt>Expires</dt><dd>{{ duration(offer.expiresInS) }}</dd></div>
          </dl>
          <div class="actions">
            <button type="button" class="secondary" :class="{ routed: offer.routed }" @click="route(offer.id)">
              {{ offer.routed ? 'Routing ✓' : 'Route' }}
            </button>
            <button type="button" :disabled="!!job || busy" @click="accept(offer.id)">Accept</button>
          </div>
        </article>

        <div v-if="!state.offers.length" class="empty">
          <strong>{{ state.filling ? 'Looking for jobs…' : 'No offers on the board' }}</strong>
          <span v-if="state.nextOfferInS != null && !state.filling">Next offer in {{ duration(state.nextOfferInS) }}.</span>
        </div>
        <div v-else-if="!visibleOffers.length" class="empty">
          <strong>No offers match the filters</strong>
        </div>
        <p v-else-if="state.nextOfferInS != null" class="hint">Next offer in {{ duration(state.nextOfferInS) }}.</p>
      </template>

      <footer v-if="state" class="footer">RLS {{ state.rlsVersion || 'not found' }}</footer>
    </main>

    <div v-if="confirmingCancel && job" class="overlay">
      <section class="modal">
        <span class="eyebrow">Cancel job?</span>
        <h2>{{ vehicleLabel(job) }}</h2>
        <p v-if="job.cancelFine > 0">You already have the vehicle. Cancelling costs a fine of {{ money(job.cancelFine) }}.</p>
        <p v-else>You have not taken the vehicle yet, so cancelling is free.</p>
        <button type="button" class="danger" @click="cancelJob">Cancel job</button>
        <button type="button" class="secondary" @click="confirmingCancel = false">Keep job</button>
      </section>
    </div>

    <div v-if="completion" class="overlay">
      <section class="modal">
        <span class="eyebrow">Job complete</span>
        <h2>{{ vehicleLabel(completion) }}</h2>
        <ul class="breakdown">
          <li><span>Quote</span><span>{{ money(completion.quote) }}</span></li>
          <li v-if="completion.penalty > 0" class="penalty">
            <span>Damage penalty</span><span>−{{ money(completion.penalty) }}</span>
          </li>
          <li v-for="part in completion.parts" :key="part.name" class="part">
            <span>{{ part.name }} ({{ part.lostPercent }}%)</span><span>{{ money(part.value) }}</span>
          </li>
          <li class="total"><span>Paid</span><span>{{ money(completion.paid) }}</span></li>
          <li><span>Recovery XP</span><span>+{{ completion.xp }}</span></li>
        </ul>
        <button type="button" @click="clearCompletion">Done</button>
      </section>
    </div>
  </div>
</template>

<script setup>
import { computed, onActivated, onDeactivated, onMounted, onUnmounted, ref } from 'vue'

// PhoneAppHost passes the RLS callModLua helper as callLua.
const props = defineProps({
  app: { type: Object, default: null },
  callLua: { type: Function, default: null },
})

const POLL_MS = 1000

const state = ref(null)
const message = ref('')
const busy = ref(false)
const confirmingCancel = ref(false)
const sortBy = ref('quote')
const typeFilter = ref('all')
const tierFilter = ref('all')
const maxDistanceKm = ref(0)

const sortOptions = [
  { id: 'quote', label: 'Payout' },
  { id: 'distance', label: 'Nearest' },
]
const typeOptions = [
  { id: 'all', label: 'All' },
  { id: 'repo', label: 'Repo' },
  { id: 'tow', label: 'Tow' },
]
const distanceOptions = [
  { km: 0, label: 'Any' },
  { km: 1, label: '1 km' },
  { km: 2, label: '2 km' },
  { km: 5, label: '5 km' },
]

const offers = computed(() => Array.isArray(state.value?.offers) ? state.value.offers : [])
const job = computed(() => state.value?.activeJob || null)
const completion = computed(() => state.value?.lastCompletion || null)
const phaseLabel = j => ({ pickup: 'Pick up the vehicle', delivery: 'Deliver', completing: 'Completing' })[j.phase] || ''

const tierOptions = computed(() => {
  const seen = new Map()
  for (const offer of offers.value) {
    if (offer.tierTag && !seen.has(offer.tierTag)) seen.set(offer.tierTag, { tag: offer.tierTag, label: offer.tierLabel || offer.tierTag })
  }
  return [...seen.values()]
})

const visibleOffers = computed(() => {
  const list = offers.value.filter(offer =>
    (typeFilter.value === 'all' || offer.jobType === typeFilter.value) &&
    (tierFilter.value === 'all' || offer.tierTag === tierFilter.value) &&
    (!maxDistanceKm.value || (Number(offer.distanceToVehicleM) || 0) <= maxDistanceKm.value * 1000))
  const key = {
    quote: offer => -(Number(offer.quote) || 0),
    distance: offer => Number(offer.distanceToVehicleM) || 0,
  }[sortBy.value]
  return list.sort((a, b) => key(a) - key(b))
})

const vehicleLabel = offer => [offer.vehicle?.year, offer.vehicle?.brand, offer.vehicle?.name].filter(Boolean).join(' ') || 'Vehicle'
const percent = value => `${Math.round((Number(value) || 0) * 100)}%`
const money = value => `$${Math.round(Number(value) || 0).toLocaleString('en-US')}`
const distance = value => {
  const m = Number(value) || 0
  return m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(1)} km`
}
const weight = kg => {
  const value = Number(kg)
  if (!value) return '—'
  return value < 1000 ? `${Math.round(value)} kg` : `${(value / 1000).toFixed(1)} t`
}
const duration = seconds => `${Math.max(0, Math.ceil((Number(seconds) || 0) / 60))} min`

async function refresh() {
  if (!props.callLua) return
  const result = await props.callLua('towRepoHub_core.getState')
  state.value = result && typeof result === 'object' ? result : { rlsVersionStatus: 'missing', careerActive: false, offers: [] }
}

async function route(id) {
  if (!props.callLua) return
  await props.callLua('towRepoHub_core.routeToOffer', id)
  refresh()
}

async function accept(id) {
  if (!props.callLua || busy.value) return
  busy.value = true
  try {
    const result = await props.callLua('towRepoHub_core.acceptOffer', id)
    if (result == null) message.value = 'No answer from the game. The add-on may be out of date; reload Lua (Ctrl+L).'
    else message.value = result.ok ? '' : (result.reason || 'The job could not be accepted.')
  } finally {
    busy.value = false
    refresh()
  }
}

async function cancelJob() {
  confirmingCancel.value = false
  if (props.callLua) await props.callLua('towRepoHub_core.cancelJob')
  refresh()
}

async function routeJob() {
  if (props.callLua) await props.callLua('towRepoHub_core.routeActiveJob')
}

async function clearCompletion() {
  if (props.callLua) await props.callLua('towRepoHub_core.clearCompletion')
  refresh()
}

let timer = null
function start() {
  if (timer) return
  refresh()
  timer = setInterval(refresh, POLL_MS)
}
function stop() {
  if (timer) clearInterval(timer)
  timer = null
}

onMounted(start)
onActivated(start)
onDeactivated(stop)
onUnmounted(stop)
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
.summary {
  display: flex;
  justify-content: space-between;
  align-items: flex-end;
  padding: 4px 4px 12px;
  h1 { margin: 2px 0 0; font-size: 1.4em; }
}
.summary-right {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  font-size: .85em;
  small { opacity: .7; }
}
.eyebrow { font-size: .75em; text-transform: uppercase; letter-spacing: .08em; opacity: .75; }
.notice {
  margin: 0 0 10px;
  padding: 10px 12px;
  border-radius: 8px;
  background: rgba(255, 255, 255, .08);
  p { margin: 4px 0 0; font-size: .9em; opacity: .85; }
}
.notice.warning { background: rgba(214, 140, 30, .25); border: 1px solid rgba(214, 140, 30, .6); }
.controls {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin-bottom: 10px;
}
.control-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px;
  .label { width: 46px; font-size: .75em; opacity: .65; }
}
.chip {
  padding: 3px 9px;
  border: 1px solid rgba(255, 255, 255, .18);
  border-radius: 999px;
  background: transparent;
  color: inherit;
  font: inherit;
  font-size: .8em;
  cursor: pointer;
  &.active { background: #3d7cc0; border-color: #3d7cc0; }
}
.section-heading {
  display: flex;
  justify-content: space-between;
  align-items: baseline;
  margin: 4px 4px 6px;
  h2 { margin: 0; font-size: 1em; }
  span { font-size: .75em; opacity: .65; }
}
.card {
  margin-bottom: 8px;
  padding: 10px 12px;
  border-radius: 10px;
  background: rgba(255, 255, 255, .07);
  border: 1px solid rgba(255, 255, 255, .08);
}
.card-top {
  display: flex;
  justify-content: space-between;
  gap: 8px;
  h3 { margin: 2px 0 0; font-size: 1em; }
}
.job-type {
  display: inline-block;
  margin-right: 4px;
  padding: 0 5px;
  border-radius: 4px;
  background: #6b4fa0;
  &.tow { background: #b0601e; }
}
.quote { font-size: 1.1em; color: #8fd18b; white-space: nowrap; }
dl {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 4px 10px;
  margin: 8px 0;
  div { display: flex; justify-content: space-between; gap: 6px; font-size: .8em; }
  dt { opacity: .6; }
  dd { margin: 0; text-align: right; }
}
.actions { display: flex; justify-content: flex-end; gap: 6px; }
.actions button {
  padding: 5px 12px;
  border: 0;
  border-radius: 6px;
  background: #3d7cc0;
  color: #fff;
  font: inherit;
  font-size: .85em;
  cursor: pointer;
  &.secondary { background: rgba(255, 255, 255, .14); }
  &.routed { background: #2f7d4a; }
  &.danger { background: #a83a3a; }
  &:disabled { opacity: .4; cursor: default; }
}
.active-card { border-color: rgba(143, 209, 139, .5); background: rgba(47, 125, 74, .18); }
.overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  background: rgba(0, 0, 0, .6);
  z-index: 5;
}
.modal {
  display: flex;
  flex-direction: column;
  gap: 8px;
  width: 100%;
  padding: 16px;
  border-radius: 12px;
  background: #1a222d;
  color: #eef3f8;
  h2 { margin: 0; font-size: 1.1em; }
  p { margin: 0; font-size: .9em; opacity: .85; }
  button {
    padding: 8px;
    border: 0;
    border-radius: 6px;
    background: #3d7cc0;
    color: #fff;
    font: inherit;
    cursor: pointer;
    &.danger { background: #a83a3a; }
    &.secondary { background: rgba(255, 255, 255, .14); }
  }
}
.breakdown {
  margin: 0;
  padding: 0;
  list-style: none;
  font-size: .9em;
  li { display: flex; justify-content: space-between; padding: 3px 0; }
  .penalty { color: #e08a8a; }
  .part { padding-left: 10px; font-size: .85em; opacity: .7; }
  .total { border-top: 1px solid rgba(255, 255, 255, .2); margin-top: 4px; padding-top: 6px; font-weight: 600; color: #8fd18b; }
}
.empty {
  display: flex;
  flex-direction: column;
  gap: 4px;
  padding: 24px 12px;
  text-align: center;
  opacity: .8;
}
.hint { margin: 4px; font-size: .75em; text-align: center; opacity: .6; }
.footer { margin-top: 16px; font-size: .75em; text-align: center; opacity: .5; }
</style>
