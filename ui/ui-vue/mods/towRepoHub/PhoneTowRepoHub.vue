<template>
  <div class="hub-root">
    <main class="hub-app">
      <header class="topbar">
        <div class="brand">
          <span class="brand-mark"><svg viewBox="0 0 24 24"><path :d="icons.tow" /></svg></span>
          <div>
            <strong>Tow Dispatch</strong>
            <small>Roadside &amp; recovery</small>
          </div>
        </div>
        <div class="topbar-right">
          <div v-if="state && state.careerActive" class="level" title="Recovery skill level and pay bonus">
            <span>Lv {{ state.skillLevel }}</span>
            <small>+{{ percent(state.skillBonus) }}</small>
          </div>
          <button type="button" class="help-btn" title="How it works" @click="helpOpen = true">?</button>
        </div>
      </header>
      <div class="hazard" />
      <div v-if="state && state.nextUnlock && !state.disabledReason" class="next-unlock">
        <p>
          <svg viewBox="0 0 24 24"><path :d="icons.lock" /></svg>
          Next: <b>{{ shortTier(state.nextUnlock.label) }}</b> jobs at Recovery level {{ state.nextUnlock.level }}
          <span v-if="state.skill && state.skill.toNext != null" class="to-next">{{ state.skill.toNext.toLocaleString('en-US') }} XP to Lv {{ state.skill.level + 1 }}</span>
        </p>
        <div v-if="state.skill && state.skill.fraction != null" class="skill-bar thin" title="Progress to the next Recovery level">
          <div :style="{ width: `${Math.round(state.skill.fraction * 100)}%` }" />
        </div>
      </div>

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
        <section v-if="message" class="notice" @click="message = ''">
          <p>{{ message }}</p>
        </section>

        <article v-if="job" class="card active" :class="job.jobType">
          <div class="card-head">
            <div class="title">
              <span class="badge" :class="job.jobType">
                <svg viewBox="0 0 24 24"><path :d="job.jobType === 'tow' ? icons.tow : icons.key" /></svg>
                {{ shortTier(job.tierLabel) }}
              </span>
              <h3 class="vehicle wrap">{{ vehicleLabel(job) }}</h3>
            </div>
            <div class="reward">
              <strong class="quote">{{ money(job.quote) }}</strong>
              <small v-if="job.xp">+{{ job.xp }} XP</small>
            </div>
          </div>

          <div class="props">
            <span title="Vehicle weight"><svg viewBox="0 0 24 24"><path :d="icons.weight" /></svg>{{ weight(job.weightKg) }}</span>
            <span :title="destinationTitle(job)"><svg viewBox="0 0 24 24"><path :d="destinationIcon(job)" /></svg>{{ destinationKindLabel(job) }}</span>
            <span :class="{ warn: job.cancelFine > 0 }" title="Cost of cancelling now">
              Cancel: {{ job.cancelFine > 0 ? `${money(job.cancelFine)} fine` : 'free' }}
            </span>
          </div>

          <ol class="steps">
            <li :class="{ done: job.custody, current: !job.custody }">
              <svg viewBox="0 0 24 24"><path :d="icons.pin" /></svg>
              <span>Pick up the vehicle</span>
              <b v-if="!job.custody">{{ distance(job.distanceToNextM) }}</b>
            </li>
            <li :class="{ current: job.custody }" :title="destinationTitle(job)">
              <svg viewBox="0 0 24 24"><path :d="destinationIcon(job)" /></svg>
              <span>{{ job.custody ? 'Deliver to' : 'Then to' }} {{ job.destinationName }}</span>
              <b>{{ distance(job.custody ? job.distanceToNextM : job.loadedM) }}</b>
            </li>
          </ol>

          <!-- Always visible while a job runs, so the player knows towing is what pays. -->
          <div class="tow-meter" :class="{ over: job.drivenM > job.driveAllowanceM, used: job.drivenM > 0 }">
            <div class="tow-meter-text">
              <svg viewBox="0 0 24 24"><path :d="icons.car" /></svg>
              <span v-if="job.drivenM > job.driveAllowanceM">
                Driven yourself {{ distance(job.drivenM) }}: pay <b>−{{ money(job.notTowedSoFar) }}</b>. Tow it!
              </span>
              <span v-else-if="job.drivenM > 0">Driven yourself {{ distance(job.drivenM) }} of {{ distance(job.driveAllowanceM) }} free</span>
              <span v-else>Tow it: driving it yourself is free only for {{ distance(job.driveAllowanceM) }}</span>
            </div>
            <div class="tow-meter-bar">
              <div :style="{ width: `${Math.min(100, Math.round((job.drivenM || 0) / job.driveAllowanceM * 100))}%` }" />
            </div>
          </div>

          <div v-if="job.fault" class="fault-box">
            <svg viewBox="0 0 24 24"><path :d="faultIcon(job.fault)" fill-rule="evenodd" /></svg>
            <div>
              <strong>{{ job.faultLabel }}</strong>
              <p>{{ faultHelp[job.fault] }}</p>
            </div>
          </div>
          <p v-else-if="job.jobType === 'repo'" class="job-note">The owner missed payments. Take the car back to the dealership.</p>

          <p v-if="job.otherMap" class="hint">This job is on another map.</p>
          <div class="actions">
            <button v-if="debugOpen" type="button" class="icon-btn debug" title="Teleport (debug)" @click="teleport()">
              <svg viewBox="0 0 24 24"><path :d="icons.bolt" /></svg>
            </button>
            <button type="button" class="btn" @click="confirmingCancel = true">Cancel</button>
            <button type="button" class="btn primary grow" @click="routeJob">
              <svg viewBox="0 0 24 24"><path :d="icons.navigate" /></svg>Navigate
            </button>
          </div>
        </article>

        <button v-if="job" type="button" class="offers-toggle" @click="showOffers = !showOffers">
          <span>Offers on the board ({{ availableCount }})</span>
          <span>{{ showOffers ? 'Hide' : 'Show' }}</span>
        </button>

        <template v-if="!job || showOffers">
        <nav v-if="availableCount" class="filters">
          <button type="button" class="filter" title="Tap to change the order"
            @click="sortBy = sortBy === 'quote' ? 'distance' : 'quote'">
            <small>Sort</small>
            <span><svg viewBox="0 0 24 24"><path :d="icons.sort" /></svg>{{ sortBy === 'quote' ? 'Payout' : 'Nearest' }}</span>
          </button>
          <button type="button" class="filter" :class="{ active: maxDistanceKm }" title="Maximum distance to the vehicle"
            @click="cycleDistance">
            <small>Distance</small>
            <span><svg viewBox="0 0 24 24"><path :d="icons.pin" /></svg>{{ maxDistanceKm ? `≤ ${maxDistanceKm} km` : 'Any' }}</span>
          </button>
          <button type="button" class="filter" :class="{ active: tierFilter !== 'all' }" title="Tier" @click="cycleTier">
            <small>Tier</small>
            <span>{{ tierFilterLabel }}</span>
          </button>
        </nav>

        <article v-for="offer in visibleOffers" :key="offer.id" class="card" :class="offer.jobType">
          <div class="card-head">
            <div class="title">
              <span class="badge" :class="offer.jobType">
                <svg viewBox="0 0 24 24"><path :d="offer.jobType === 'tow' ? icons.tow : icons.key" /></svg>
                {{ shortTier(offer.tierLabel) }}
                <span class="expires" :class="{ soon: offer.expiresInS < 180 }" title="Offer expires in">
                  <svg viewBox="0 0 24 24"><path :d="icons.clock" /></svg>{{ duration(offer.expiresInS) }}
                </span>
              </span>
              <h3 class="vehicle" :title="vehicleLabel(offer)">{{ vehicleLabel(offer) }}</h3>
            </div>
            <div class="reward">
              <strong class="quote">{{ money(offer.quote) }}</strong>
              <small v-if="offer.xp">+{{ offer.xp }} XP</small>
            </div>
          </div>
          <span v-if="offer.faultLabel" class="fault">
            <svg viewBox="0 0 24 24"><path :d="faultIcon(offer.fault)" fill-rule="evenodd" /></svg>{{ offer.faultLabel }}
          </span>
          <div class="card-foot">
            <div class="card-info">
              <div class="stats">
                <span title="Distance to the vehicle"><svg viewBox="0 0 24 24"><path :d="icons.pin" /></svg>{{ distance(offer.distanceToVehicleM) }}</span>
                <span title="Route with the vehicle"><svg viewBox="0 0 24 24"><path :d="icons.route" /></svg>{{ distance(offer.loadedM) }}</span>
                <span title="Vehicle weight"><svg viewBox="0 0 24 24"><path :d="icons.weight" /></svg>{{ weight(offer.weightKg) }}</span>
              </div>
              <span class="destination" :title="destinationTitle(offer)">
                <svg viewBox="0 0 24 24"><path :d="destinationIcon(offer)" /></svg>
                <b>{{ destinationKindLabel(offer) }}</b><span class="dest-name">{{ offer.destinationName }}</span>
              </span>
            </div>
            <div class="actions">
              <button v-if="debugOpen" type="button" class="icon-btn debug" title="Teleport (debug)" @click="teleport(offer.id)">
                <svg viewBox="0 0 24 24"><path :d="icons.bolt" /></svg>
              </button>
              <button type="button" class="btn primary" :disabled="!!job || busy" @click="accept(offer.id)">Accept</button>
            </div>
          </div>
        </article>

        <div v-if="!availableCount" class="empty">
          <span class="empty-mark"><svg viewBox="0 0 24 24"><path :d="icons.tow" /></svg></span>
          <strong>{{ state.filling ? 'Looking for jobs…' : 'No jobs for you right now' }}</strong>
          <span>{{ state.filling ? 'Calls come in one by one; the first ones are on their way.' : 'New jobs come in over time. Check back later.' }}</span>
        </div>
        <div v-else-if="!visibleOffers.length" class="empty">
          <strong>No offers match the filters</strong>
        </div>

        <template v-if="lockedOffers.length">
          <button type="button" class="offers-toggle" @click="showLocked = !showLocked">
            <span>
              <svg viewBox="0 0 24 24"><path :d="icons.lock" /></svg>
              Higher-level jobs ({{ lockedOffers.length }})
            </span>
            <span>{{ showLocked ? 'Hide' : 'Show' }}</span>
          </button>
          <template v-if="showLocked">
            <article v-for="offer in lockedOffers" :key="offer.id" class="locked-row" :class="offer.jobType">
              <svg viewBox="0 0 24 24"><path :d="offer.jobType === 'tow' ? icons.tow : icons.key" /></svg>
              <div class="locked-main">
                <span class="locked-tier">{{ shortTier(offer.tierLabel) }}</span>
                <span class="locked-vehicle">{{ vehicleLabel(offer) }}</span>
              </div>
              <div class="locked-side">
                <strong>{{ money(offer.quote) }}</strong>
                <span class="lock-level"><svg viewBox="0 0 24 24"><path :d="icons.lock" /></svg>Lv {{ offer.unlockLevel }}</span>
              </div>
            </article>
          </template>
        </template>
        </template>
      </template>

      <!-- DEBUG, temporary: test tools -->
      <section v-if="state && !state.disabledReason && state.debugModels" class="debug-panel">
        <button type="button" class="pill debug" :class="{ active: debugOpen }" @click="debugOpen = !debugOpen">
          <svg viewBox="0 0 24 24"><path :d="icons.bolt" /></svg>Debug tools
        </button>
        <template v-if="debugOpen">
          <div class="debug-row">
            <button type="button" class="pill" :class="{ active: state.debugShortJobs }" @click="toggleShortJobs">Short jobs</button>
            <button type="button" class="pill" @click="refreshOffers">
              <svg viewBox="0 0 24 24"><path :d="icons.refresh" /></svg>New board
            </button>
          </div>
          <div class="debug-row">
            <button v-for="model in state.debugModels" :key="model.key" type="button" class="pill"
              :class="{ active: debugModel === model.key }" @click="debugModel = model.key">{{ model.label }}</button>
          </div>
          <div class="debug-row">
            <button v-for="fault in state.debugFaults" :key="fault" type="button" class="pill"
              :class="{ active: debugFault === fault }" @click="debugFault = fault">{{ faultNames[fault] || fault }}</button>
          </div>
          <div v-if="debugFault === 'engine'" class="debug-row">
            <button v-for="option in severityOptions" :key="option.value" type="button" class="pill"
              :class="{ active: debugSeverity === option.value }" @click="debugSeverity = option.value">{{ option.label }}</button>
          </div>
          <button type="button" class="btn primary" :disabled="!debugModel || busy" @click="addDebugOffer">Add test tow offer</button>
        </template>
      </section>

      <footer v-if="state" class="footer">RLS {{ state.rlsVersion || 'not found' }}</footer>
    </main>

    <div v-if="helpOpen" class="overlay" @click.self="helpOpen = false">
      <section class="modal help">
        <div class="hazard" />
        <span class="eyebrow">How it works</span>
        <ol>
          <li><b>Pick a job.</b> A broken-down car needs to go to the owner's home or to a service. The fault and the payout are shown up front; the payout is fixed when you accept.</li>
          <li><b>Tow it.</b> Load it on a flatbed or trailer, lift it or pull it on a rope. You may drive it yourself for the first 200 m to get it loaded; beyond that the pay drops, down to a quarter and no XP if you drive it all the way.</li>
          <li><b>Deliver it.</b> Stop within the green marker at the destination. You are paid the quote and get Recovery XP.</li>
          <li><b>Mind the damage.</b> Damage you cause on the way is taken from the payout, at most half of it.</li>
          <li><b>Cancelling</b> is free until you move the vehicle; after that it costs a fine.</li>
        </ol>
        <p>One job at a time. Offers expire, and new ones come in over time. Higher Recovery levels unlock better-paying tiers.</p>
        <button type="button" class="btn primary" @click="helpOpen = false">Got it</button>
      </section>
    </div>

    <div v-if="confirmingCancel && job" class="overlay">
      <section class="modal">
        <span class="eyebrow">Cancel job?</span>
        <h2>{{ vehicleLabel(job) }}</h2>
        <p v-if="job.cancelFine > 0">You already have the vehicle. Cancelling costs a fine of {{ money(job.cancelFine) }}.</p>
        <p v-else>You have not taken the vehicle yet, so cancelling is free.</p>
        <button type="button" class="btn" @click="confirmingCancel = false">Keep job</button>
        <button type="button" class="btn danger" @click="cancelJob">Cancel job</button>
      </section>
    </div>

    <div v-if="completion" class="overlay">
      <section class="modal">
        <div class="hazard" />
        <span class="eyebrow">Job complete</span>
        <h2>{{ vehicleLabel(completion) }}</h2>

        <div class="payday">
          <strong>{{ money(completion.paid) }}</strong>
          <span v-if="completion.xp > 0">+{{ completion.xp }} Recovery XP</span>
          <span v-else class="no-xp">No Recovery XP: not towed</span>
        </div>

        <p v-if="!completion.penalty && !completion.notTowed" class="clean">
          <svg viewBox="0 0 24 24"><path :d="icons.check" /></svg>Towed without damage, full pay
        </p>
        <ul v-else class="breakdown">
          <li><span>Quote</span><span>{{ money(completion.quote) }}</span></li>
          <li v-if="completion.notTowed" class="penalty">
            <span>Not towed ({{ distance(completion.drivenM) }} driven)</span><span>−{{ money(completion.notTowed) }}</span>
          </li>
          <li v-if="completion.penalty" class="penalty"><span>Damage penalty</span><span>−{{ money(completion.penalty) }}</span></li>
          <li class="total"><span>Paid</span><span>{{ money(completion.paid) }}</span></li>
        </ul>

        <div v-if="completion.levelUp" class="level-up">
          <strong>Level up!</strong>
          <span>Recovery Lv {{ completion.levelUp.from }} → {{ completion.levelUp.to }}</span>
          <p v-for="label in completion.unlocked || []" :key="label" class="unlocked">
            <svg viewBox="0 0 24 24"><path :d="icons.unlock" /></svg>{{ shortTier(label) }} jobs unlocked
          </p>
        </div>

        <div v-if="completion.skill" class="skill">
          <div class="skill-head">
            <span>Recovery Lv {{ completion.skill.level }}</span>
            <span v-if="completion.skill.toNext != null">{{ completion.skill.toNext.toLocaleString('en-US') }} XP to Lv {{ completion.skill.level + 1 }}</span>
          </div>
          <div v-if="completion.skill.fraction != null" class="skill-bar">
            <div :style="{ width: `${Math.round(completion.skill.fraction * 100)}%` }" />
          </div>
        </div>

        <button type="button" class="btn primary" @click="clearCompletion">Done</button>
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

// Material Design icon paths (Apache 2.0), plus a simple weight icon.
const icons = {
  // Tow truck with boom and hook; the same silhouette as the app icon (icon.svg).
  tow: 'M2 12h10.6L4.6 5.4l1-1 7.4 7.4V8h4.5l3.5 4.5V17h-1.6a2.4 2.4 0 0 0-4.8 0H9.4a2.4 2.4 0 0 0-4.8 0H2zM4.4 5h1v3.2h-1zM3 7.4h1v1.8H3zm0 1h3.4v.8H3zM7 15.6a1.9 1.9 0 1 0 0 3.8 1.9 1.9 0 1 0 0-3.8zm10.4 0a1.9 1.9 0 1 0 0 3.8 1.9 1.9 0 1 0 0-3.8z',
  key: 'M12.65 10C11.83 7.67 9.61 6 7 6c-3.31 0-6 2.69-6 6s2.69 6 6 6c2.61 0 4.83-1.67 5.65-4H17v4h4v-4h2v-4H12.65zM7 14c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2z',
  pin: 'M12 2C8.13 2 5 5.13 5 9c0 5.25 7 13 7 13s7-7.75 7-13c0-3.87-3.13-7-7-7zm0 9.5c-1.38 0-2.5-1.12-2.5-2.5s1.12-2.5 2.5-2.5 2.5 1.12 2.5 2.5-1.12 2.5-2.5 2.5z',
  route: 'M19 15.18V7c0-2.21-1.79-4-4-4s-4 1.79-4 4v10c0 1.1-.9 2-2 2s-2-.9-2-2V8.82C8.16 8.4 9 7.3 9 6c0-1.66-1.34-3-3-3S3 4.34 3 6c0 1.3.84 2.4 2 2.82V17c0 2.21 1.79 4 4 4s4-1.79 4-4V7c0-1.1.9-2 2-2s2 .9 2 2v8.18c-1.16.41-2 1.51-2 2.82 0 1.66 1.34 3 3 3s3-1.34 3-3c0-1.3-.84-2.4-2-2.82z',
  flag: 'M14.4 6L14 4H5v17h2v-7h5.6l.4 2h7V6z',
  clock: 'M11.99 2C6.47 2 2 6.48 2 12s4.47 10 9.99 10C17.52 22 22 17.52 22 12S17.52 2 11.99 2zM12 20c-4.42 0-8-3.58-8-8s3.58-8 8-8 8 3.58 8 8-3.58 8-8 8zm.5-13H11v6l5.25 3.15.75-1.23-4.5-2.67z',
  warning: 'M1 21h22L12 2 1 21zm12-3h-2v-2h2v2zm0-4h-2v-4h2v4z',
  home: 'M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z',
  store: 'M20 4H4v2h16V4zm1 10v-2l-1-5H4l-1 5v2h1v6h10v-6h4v6h2v-6h1zm-9 4H6v-4h6v4z',
  navigate: 'M12 2L4.5 20.29l.71.71L12 18l6.79 3 .71-.71z',
  refresh: 'M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z',
  sort: 'M3 18h6v-2H3v2zM3 6v2h18V6H3zm0 7h12v-2H3v2z',
  bolt: 'M7 2v11h3v9l7-12h-4l4-8z',
  check: 'M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z',
  car: 'M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.66 0-1.21.42-1.42 1.01L3 12v8c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-1h12v1c0 .55.45 1 1 1h1c.55 0 1-.45 1-1v-8l-2.08-5.99zM6.5 16c-.83 0-1.5-.67-1.5-1.5S5.67 13 6.5 13s1.5.67 1.5 1.5S7.33 16 6.5 16zm11 0c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zM5 11l1.5-4.5h11L19 11H5z',
  // Fault icons: fuel pump, tyre (drawn as a ring, see .fault-icon), thermometer, engine block.
  fuel: 'M19.77 7.23l.01-.01-3.72-3.72L15 4.56l2.11 2.11c-.94.36-1.61 1.26-1.61 2.33 0 1.38 1.12 2.5 2.5 2.5.36 0 .69-.08 1-.21v7.21c0 .55-.45 1-1 1s-1-.45-1-1V14c0-1.1-.9-2-2-2h-1V5c0-1.1-.9-2-2-2H6c-1.1 0-2 .9-2 2v16h10v-7.5h1.5v5c0 1.38 1.12 2.5 2.5 2.5s2.5-1.12 2.5-2.5V9c0-.69-.28-1.32-.73-1.77zM12 10H6V5h6v5zm6 0c-.55 0-1-.45-1-1s.45-1 1-1 1 .45 1 1-.45 1-1 1z',
  tyre: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 4a6 6 0 1 1 0 12 6 6 0 0 1 0-12zm0 3.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5z',
  thermometer: 'M15 13V5c0-1.66-1.34-3-3-3S9 3.34 9 5v8c-1.21.91-2 2.37-2 4 0 2.76 2.24 5 5 5s5-2.24 5-5c0-1.63-.79-3.09-2-4zm-4-8c0-.55.45-1 1-1s1 .45 1 1h-1v1h1v2h-1v1h1v2h-2V5z',
  engine: 'M7 4v2h3v2H7l-2 2v3H3v-3H1v8h2v-3h2v3h3l2 2h8v-4h2v3h3V9h-3v3h-2V8h-6V6h3V4H7z',
  unlock: 'M12 17c1.1 0 2-.9 2-2s-.9-2-2-2-2 .9-2 2 .9 2 2 2zm6-9h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6h1.9c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm0 12H6V10h12v10z',
  lock: 'M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zm-6 9c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1 1.71 0 3.1 1.39 3.1 3.1v2z',
  weight: 'M12 3a3 3 0 0 0-2.83 4H6.5L3 21h18L17.5 7h-2.67A3 3 0 0 0 12 3zm0 2a1 1 0 1 1 0 2 1 1 0 0 1 0-2z',
}

const state = ref(null)
const message = ref('')
const busy = ref(false)
const confirmingCancel = ref(false)
const sortBy = ref('quote')
const tierFilter = ref('all')
const maxDistanceKm = ref(0)

const showOffers = ref(false)
const helpOpen = ref(false)
const faultHelp = {
  fuel: 'Almost out of fuel. It runs for a few hundred metres, enough to get it on the truck.',
  flat: 'One tyre is flat. It still rolls onto the truck, but drives badly.',
  overheat: 'The radiator is empty. The engine overheats as soon as it runs; driving it far ruins the engine.',
  engine: 'The engine misfires and stalls. Expect it to die on you.',
}
const DISTANCE_STEPS = [0, 1, 2, 5]

const offers = computed(() => Array.isArray(state.value?.offers) ? state.value.offers : [])
const job = computed(() => state.value?.activeJob || null)
const completion = computed(() => state.value?.lastCompletion || null)
const destinationIcon = item => item.destinationKind === 'home' ? icons.home : (item.destinationKind === 'service' ? icons.store : icons.flag)
const destinationTitle = item => ({ home: 'Owner\'s home', service: 'Service' })[item.destinationKind] || 'Dealership'
const faultIcon = fault => ({ fuel: icons.fuel, flat: icons.tyre, overheat: icons.thermometer, engine: icons.engine })[fault] || icons.warning
const destinationKindLabel = item => ({ home: 'Home', service: 'Service' })[item.destinationKind] || 'Dealership'
const shortTier = label => String(label || '').replace(/\s*(Tow|Repo)$/i, '')

const showLocked = ref(false)
const openOffers = computed(() => offers.value.filter(offer => !offer.locked))
const availableCount = computed(() => openOffers.value.length)
const lockedOffers = computed(() =>
  offers.value.filter(offer => offer.locked).sort((a, b) => (a.unlockLevel || 0) - (b.unlockLevel || 0) || b.quote - a.quote))

// Tiers present among the offers the player can take, by tier tag.
const tierOptions = computed(() => {
  const seen = new Map()
  for (const offer of openOffers.value) {
    if (offer.tierTag && !seen.has(offer.tierTag)) seen.set(offer.tierTag, shortTier(offer.tierLabel) || offer.tierTag)
  }
  return [...seen.entries()].map(([tag, label]) => ({ tag, label }))
})
const tierFilterLabel = computed(() =>
  tierFilter.value === 'all' ? 'All' : (tierOptions.value.find(t => t.tag === tierFilter.value)?.label || 'All'))

function cycleTier() {
  const tags = ['all', ...tierOptions.value.map(t => t.tag)]
  tierFilter.value = tags[(tags.indexOf(tierFilter.value) + 1) % tags.length]
}

function cycleDistance() {
  maxDistanceKm.value = DISTANCE_STEPS[(DISTANCE_STEPS.indexOf(maxDistanceKm.value) + 1) % DISTANCE_STEPS.length]
}

const visibleOffers = computed(() => {
  const list = openOffers.value.filter(offer =>
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
  const m = Math.round(Number(value) || 0)
  return m < 1000 ? `${m} m` : `${(m / 1000).toFixed(1)} km`
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

async function refreshOffers() {
  if (props.callLua) await props.callLua('towRepoHub_core.refreshOffers')
  refresh()
}

// DEBUG, temporary
const debugOpen = ref(false)
const debugModel = ref('')
const debugFault = ref('engine')
const debugSeverity = ref(0.5)
const faultNames = { fuel: 'Empty tank', flat: 'Flat tyre', overheat: 'Overheating', engine: 'Failing engine' }
const severityOptions = [
  { value: 0, label: 'Mild' },
  { value: 0.5, label: 'Medium' },
  { value: 1, label: 'Severe' },
]

async function teleport(id) {
  if (!props.callLua) return
  const ok = id == null
    ? await props.callLua('towRepoHub_core.debugTeleport')
    : await props.callLua('towRepoHub_core.debugTeleport', id)
  if (!ok) message.value = 'Teleport failed.'
}

async function addDebugOffer() {
  if (!props.callLua || busy.value) return
  busy.value = true
  try {
    const result = await props.callLua('towRepoHub_core.debugAddTowOffer', debugModel.value, debugFault.value, debugSeverity.value)
    message.value = result?.ok ? 'Test offer added at the top of the board.' : (result?.reason || 'No answer from the game.')
  } finally {
    busy.value = false
    refresh()
  }
}

async function toggleShortJobs() {
  if (props.callLua) await props.callLua('towRepoHub_core.setDebugShortJobs', !state.value?.debugShortJobs)
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
// Tow truck look: asphalt dark, safety amber, hazard stripes.
$asphalt: #15171a;
$panel: #1f2226;
$panel-hi: #2a2e33;
$line: rgba(255, 255, 255, .08);
$text: #eceff2;
$muted: #8d949c;
$amber: #ffb81c;
$amber-dark: #d99100;
$tow: #ffb81c;
$repo: #6ab0ff;
$money: #8fdc6a;
$danger: #e5533d;
$debug: #c06a24;

// The font is set on the root so the overlays (help, completion) do not depend on the phone shell.
.hub-root { position: relative; height: 100%; font-family: Overpass, sans-serif; }
.hub-app {
  height: 100%;
  overflow-y: auto;
  box-sizing: border-box;
  padding: 48px 10px 16px;
  color: $text;
  background:
    radial-gradient(ellipse at top, rgba(255, 184, 28, .08), transparent 55%),
    $asphalt;
  font-family: Overpass, sans-serif;
  font-size: 14px;
}
svg { width: 1em; height: 1em; fill: currentColor; flex: none; }

.topbar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 2px 2px 8px;
}
.brand {
  display: flex;
  align-items: center;
  gap: 8px;
  strong { display: block; font-size: 1.1em; letter-spacing: .04em; text-transform: uppercase; white-space: nowrap; }
  small { display: block; color: $amber; font-size: .66em; letter-spacing: .14em; text-transform: uppercase; }
}
.brand-mark {
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  border-radius: 8px;
  background: $amber;
  color: $asphalt;
  font-size: 20px;
}
// A pill the same height and outline as the round help button next to it.
.level {
  display: flex;
  align-items: center;
  gap: 6px;
  height: 30px;
  box-sizing: border-box;
  padding: 0 12px;
  border: 1px solid rgba(255, 184, 28, .4);
  border-radius: 15px;
  span { font-weight: 700; color: $amber; }
  small { font-size: .75em; color: $muted; }
}
.reward {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  line-height: 1.1;
  small { font-size: .72em; color: $amber; font-weight: 600; }
}
.hazard {
  height: 5px;
  margin: 0 -10px 10px;
  background: repeating-linear-gradient(-45deg, $amber 0 9px, $asphalt 9px 18px);
  opacity: .9;
}

.notice {
  margin: 0 0 8px;
  padding: 8px 10px;
  border-radius: 8px;
  background: $panel;
  border-left: 3px solid $muted;
  p { margin: 3px 0 0; font-size: .9em; color: $muted; }
}
.notice.warning { border-left-color: $amber; }

.topbar-right { display: flex; align-items: center; gap: 6px; }
.help-btn {
  width: 30px;
  height: 30px;
  border: 1px solid rgba(255, 184, 28, .4);
  border-radius: 50%;
  background: transparent;
  color: $amber;
  font: inherit;
  font-weight: 700;
  cursor: pointer;
}

// One control bar with three sections: a small caption over the current value.
.filters {
  display: flex;
  margin: 2px 0 8px;
  border: 1px solid $line;
  border-radius: 10px;
  background: $panel;
  overflow: hidden;
}
.filter {
  flex: 1 1 0;
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 1px;
  padding: 5px 10px 6px;
  border: 0;
  background: transparent;
  color: $text;
  font: inherit;
  text-align: left;
  cursor: pointer;
  & + & { border-left: 1px solid $line; }
  small { font-size: .62em; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; color: $muted; }
  span {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    max-width: 100%;
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
    font-size: .85em;
    font-weight: 600;
  }
  svg { font-size: 13px; color: $muted; }
  &:hover { background: $panel-hi; }
  &.active span, &.active svg { color: $amber; }
}
.pill {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  height: 28px;
  padding: 0 8px;
  border: 1px solid $line;
  border-radius: 8px;
  background: $panel;
  color: $text;
  font: inherit;
  font-size: .8em;
  cursor: pointer;
  svg { font-size: 14px; color: $muted; }
  &.active { border-color: $amber; color: $amber; svg { color: $amber; } }
  &.tier { min-width: 0; overflow: hidden; text-overflow: ellipsis; justify-content: center; }
  &.debug.active { border-color: $debug; color: $debug; svg { color: $debug; } }
}
.icon-btn {
  display: grid;
  place-items: center;
  width: 32px;
  height: 30px;
  border: 1px solid $line;
  border-radius: 8px;
  background: $panel-hi;
  color: $text;
  cursor: pointer;
  svg { font-size: 17px; }
  &.small { width: 28px; height: 28px; margin-left: auto; background: $panel; }
  &.routed { background: rgba(143, 220, 106, .18); border-color: $money; color: $money; }
  &.debug { background: rgba(192, 106, 36, .25); border-color: $debug; color: #ffb27a; }
}
.btn {
  height: 30px;
  padding: 0 14px;
  border: 0;
  border-radius: 8px;
  background: $panel-hi;
  color: $text;
  font: inherit;
  font-weight: 700;
  font-size: .85em;
  letter-spacing: .04em;
  text-transform: uppercase;
  cursor: pointer;
  &.primary { background: $amber; color: $asphalt; }
  &.primary:hover:not(:disabled) { background: #ffc645; }
  &.danger { background: $danger; color: #fff; }
  &.grow { flex: 1; display: inline-flex; align-items: center; justify-content: center; gap: 6px; svg { font-size: 16px; } }
  &:disabled { opacity: .35; cursor: default; }
}

.vehicle.wrap { white-space: normal; font-size: 1.05em; }
.card.active .card-head { margin-bottom: 8px; }
.steps {
  margin: 0 0 8px;
  padding: 0;
  list-style: none;
  li {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 4px 0;
    color: $muted;
    font-size: .88em;
    span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    svg { font-size: 16px; }
    b { color: $muted; font-weight: 600; }
    // The current step stands out by colour and weight only, without a panel.
    &.current { color: $text; font-weight: 600; svg { color: $amber; } b { color: $text; } }
    &.done { text-decoration: line-through; opacity: .6; }
  }
}
.fault-box {
  display: flex;
  gap: 8px;
  margin-bottom: 8px;
  padding: 7px 9px;
  border-radius: 8px;
  background: rgba(229, 83, 61, .12);
  border: 1px solid rgba(229, 83, 61, .35);
  > svg { font-size: 18px; color: #ff8a73; margin-top: 1px; }
  strong { color: #ff8a73; font-size: .9em; }
  p { margin: 2px 0 0; font-size: .8em; color: $muted; }
}
.job-note { margin: 0 0 8px; font-size: .82em; color: $muted; }
// Transport properties of the active job, one row of small chips under the vehicle name.
.props {
  display: flex;
  flex-wrap: wrap;
  gap: 5px;
  margin: 0 0 10px;
  span {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    padding: 2px 8px;
    border-radius: 6px;
    background: $panel-hi;
    font-size: .76em;
    color: $text;
  }
  svg { font-size: 13px; color: $muted; }
  .warn { color: #ff8a73; background: rgba(229, 83, 61, .12); }
}
.next-unlock {
  margin: -4px 2px 9px;
  p {
    display: flex;
    align-items: center;
    gap: 4px;
    margin: 0 0 4px;
    font-size: .75em;
    color: $muted;
  }
  b { color: $text; }
  svg { font-size: 12px; color: $amber; }
  .to-next { margin-left: auto; white-space: nowrap; }
}
.skill-bar.thin { height: 3px; }
// Self-drive meter on the active job: one line and a thin bar, no panel; red text beyond the
// free distance.
.tow-meter {
  margin: 0 0 10px;
  .tow-meter-text {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 4px;
    font-size: .76em;
    color: $muted;
    svg { font-size: 14px; color: $muted; flex: none; }
    b { color: #ff8a73; }
  }
  .tow-meter-bar {
    height: 2px;
    border-radius: 1px;
    background: $panel-hi;
    overflow: hidden;
    div { height: 100%; background: $amber; }
  }
  &.used .tow-meter-text { color: $text; }
  &.over {
    .tow-meter-text { color: #ff8a73; svg { color: #ff8a73; } }
    .tow-meter-bar div { background: $danger; }
  }
}
.locked-row {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 5px;
  padding: 6px 10px;
  border-radius: 8px;
  background: rgba(255, 255, 255, .03);
  border: 1px solid $line;
  opacity: .75;
  > svg { font-size: 16px; color: $muted; }
  &.tow > svg { color: rgba(255, 184, 28, .6); }
  &.repo > svg { color: rgba(106, 176, 255, .6); }
}
.locked-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
}
.locked-tier { font-size: .68em; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: $muted; }
.locked-vehicle { font-size: .82em; }
.locked-side {
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  strong { font-size: .9em; color: rgba(143, 220, 106, .7); }
}
.lock-level {
  display: inline-flex;
  align-items: center;
  gap: 3px;
  font-size: .7em;
  color: $amber;
  svg { font-size: 11px; }
}
.offers-toggle {
  display: flex;
  justify-content: space-between;
  width: 100%;
  margin: 2px 0 8px;
  padding: 8px 10px;
  border: 1px dashed $line;
  border-radius: 8px;
  background: transparent;
  color: $muted;
  font: inherit;
  font-size: .85em;
  cursor: pointer;
  span:last-child { color: $amber; }
}

.card {
  position: relative;
  margin-bottom: 7px;
  // Equal inner margins; the left one also clears the 3 px type stripe.
  padding: 9px 12px 9px 15px;
  border-radius: 10px;
  background: $panel;
  border: 1px solid $line;
  overflow: hidden;
  &::before {
    content: '';
    position: absolute;
    left: 0;
    top: 0;
    bottom: 0;
    width: 3px;
    background: $muted;
  }
  &.tow::before { background: $tow; }
  &.repo::before { background: $repo; }
}
.card.active {
  border-color: rgba(255, 184, 28, .55);
  background: linear-gradient(180deg, rgba(255, 184, 28, .1), $panel 60%);
}
// Two independent columns: tier over the vehicle name on the left, payout over XP on the right,
// so neither column pushes the other down.
.card-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 10px;
  margin-bottom: 4px;
  .title { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 1px; }
  // The tier and the payout get the same first-line height, so the tier does not sit lower.
  .badge, .quote { display: flex; align-items: center; height: 20px; line-height: 20px; }
  .expires {
    display: inline-flex;
    align-items: center;
    gap: 3px;
    margin-left: 6px;
    padding-left: 7px;
    border-left: 1px solid $line;
    font-weight: 600;
    letter-spacing: 0;
    text-transform: none;
    color: $muted;
    // Beats the tier colour that .badge.tow svg gives every icon in the badge.
    &.expires svg { font-size: 12px; color: $muted; }
    &.soon, &.soon.expires svg { color: #ff8a73; }
  }
  .vehicle { margin: 0; }
  .reward { flex: none; }
}
.badge {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: .72em;
  font-weight: 700;
  letter-spacing: .08em;
  text-transform: uppercase;
  color: $muted;
  svg { font-size: 15px; }
  &.tow svg { color: $tow; }
  &.repo svg { color: $repo; }
}
.quote { font-size: 1.15em; color: $money; letter-spacing: .01em; }
.vehicle {
  margin: 0 0 5px;
  font-size: .98em;
  font-weight: 600;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.fault {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-bottom: 4px;
  padding: 0 7px;
  line-height: 1.6;
  border-radius: 6px;
  background: rgba(229, 83, 61, .15);
  color: #ff8a73;
  font-size: .75em;
  font-weight: 600;
  svg { font-size: 13px; }
}
.stats {
  display: flex;
  flex-wrap: wrap;
  gap: 2px 9px;
  font-size: .82em;
  span { display: inline-flex; align-items: center; gap: 4px; }
  svg { font-size: 14px; color: $muted; }
  .soon { color: #ff8a73; svg { color: #ff8a73; } }
}
.destination {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
  color: $muted;
  font-size: .82em;
  svg { font-size: 14px; flex: none; }
  b { color: $text; font-weight: 600; flex: none; }
  .dest-name { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
}
// Stats over destination on the left, Accept on the right as tall as both lines, so the two sides
// end on the same line and neither leaves a gap.
.card-foot {
  display: flex;
  align-items: stretch;
  gap: 8px;
  .card-info { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
  .actions { align-items: stretch; }
  .btn { height: auto; padding: 0 14px; font-size: .8em; }
  .icon-btn { height: auto; }
}
.actions { display: flex; align-items: center; gap: 5px; flex: none; }
.card.active .actions { justify-content: flex-end; margin-top: 6px; }

.empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  padding: 32px 24px;
  text-align: center;
  color: $muted;
  font-size: .9em;
  strong { color: $text; font-size: 1.1em; }
}
.empty-mark {
  display: grid;
  place-items: center;
  width: 56px;
  height: 56px;
  margin-bottom: 8px;
  border-radius: 50%;
  background: rgba(255, 184, 28, .1);
  border: 1px dashed rgba(255, 184, 28, .45);
  color: $amber;
  font-size: 28px;
}
.hint { margin: 4px; font-size: .75em; text-align: center; color: $muted; }
.footer { margin-top: 12px; font-size: .7em; text-align: center; color: $muted; opacity: .6; }

.debug-panel {
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  gap: 6px;
  margin-top: 12px;
  padding-top: 10px;
  border-top: 1px dashed $line;
}
.debug-row { display: flex; flex-wrap: wrap; gap: 4px; }

.overlay {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 16px;
  background: rgba(0, 0, 0, .65);
  z-index: 5;
}
.modal {
  display: flex;
  flex-direction: column;
  gap: 8px;
  width: 100%;
  padding: 0 16px 16px;
  border-radius: 12px;
  background: $panel;
  border: 1px solid rgba(255, 184, 28, .35);
  color: $text;
  overflow: hidden;
  .hazard { margin: 0 -16px 4px; }
  .eyebrow { margin-top: 12px; color: $amber; font-size: .72em; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; }
  .hazard + .eyebrow { margin-top: 0; }
  h2 { margin: 0; font-size: 1.05em; }
  p { margin: 0; font-size: .9em; color: $muted; }
  .btn { height: 34px; }
}
.payday {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 10px 0 4px;
  strong { font-size: 2em; color: $money; line-height: 1.1; }
  span { font-size: .85em; font-weight: 600; color: $amber; }
  .no-xp { color: $muted; font-weight: 400; }
}
.clean {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  padding: 6px;
  border-radius: 8px;
  background: rgba(143, 220, 106, .1);
  color: $money !important;
  font-size: .82em !important;
  svg { font-size: 15px; }
}
.level-up {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 2px;
  padding: 8px;
  border-radius: 8px;
  background: linear-gradient(180deg, rgba(255, 184, 28, .22), rgba(255, 184, 28, .06));
  border: 1px solid rgba(255, 184, 28, .5);
  strong { font-size: 1.1em; letter-spacing: .1em; text-transform: uppercase; color: $amber; }
  > span { font-size: .85em; color: $text; }
  .unlocked {
    display: flex;
    align-items: center;
    gap: 5px;
    margin: 4px 0 0;
    padding: 3px 9px;
    border-radius: 6px;
    background: rgba(143, 220, 106, .14);
    color: $money;
    font-size: .8em;
    font-weight: 600;
    svg { font-size: 14px; }
  }
}
.skill {
  padding: 8px 0 2px;
  border-top: 1px solid $line;
}
.skill-head {
  display: flex;
  justify-content: space-between;
  margin-bottom: 5px;
  font-size: .78em;
  color: $muted;
  span:first-child { color: $text; font-weight: 600; }
}
.skill-bar {
  height: 7px;
  border-radius: 4px;
  background: $panel-hi;
  overflow: hidden;
  div { height: 100%; border-radius: 4px; background: linear-gradient(90deg, $amber-dark, $amber); }
}
.modal.help {
  ol { margin: 0; padding-left: 18px; font-size: .85em; line-height: 1.4; }
  li { margin-bottom: 5px; color: $muted; }
  b { color: $text; }
}
.breakdown {
  margin: 0;
  padding: 0;
  list-style: none;
  font-size: .9em;
  li { display: flex; justify-content: space-between; padding: 3px 0; }
  .penalty { color: #ff8a73; }
  .total { border-top: 1px solid $line; margin-top: 4px; padding-top: 6px; font-weight: 700; color: $money; }
}
</style>
