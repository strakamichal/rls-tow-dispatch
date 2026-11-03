// Sample getState() replies for the layout preview (tools/dev/preview.ps1). They mirror what
// towRepoHub_core.getState returns; keep them in step when the payload changes.
(function () {
  const base = {
    rlsVersion: '2.8.0',
    rlsVersionStatus: 'ok',
    supportedVersion: '2.8.x',
    careerActive: true,
    skillLevel: 14,
    skillBonus: 1.1667,
    skill: { level: 14, fraction: 0.62, toNext: 1190 },
    boardSize: 14,
    nextUnlock: { level: 15, label: 'Luxury Repo' },
    debugShortJobs: false,
    debugModels: [
      { key: 'covet', label: 'Ibishu Covet' },
      { key: 'pickup', label: 'Gavril D-Series' },
    ],
    debugFaults: ['fuel', 'flat', 'overheat', 'engine'],
  }

  let nextId = 1
  const offer = (tierTag, tierLabel, year, brand, name, fault, faultLabel, quote, xp, toVehicleM, loadedM, weightKg,
    destinationName, destinationKind, expiresInS, extra) => Object.assign({
    id: nextId++, jobType: 'tow', tierTag, tierLabel, vehicle: { year, brand, name }, fault, faultLabel, quote, xp,
    distanceToVehicleM: toVehicleM, outboundM: toVehicleM, loadedM, weightKg, destinationName, destinationKind,
    expiresInS, locked: false, unlockLevel: 1,
  }, extra || {})

  const openOffers = [
    offer('smallVeh', 'Budget Tow', 1971, 'Gavril', 'Barstow 353 V8 RoadSport (M)', 'flat', 'Flat tyre', 5055, 1044,
      7200, 6200, 1700, 'Quarry Garage', 'home', 1260),
    offer('fleetVeh', 'Standard Tow', 2013, 'ETK', '800-Series 854x 250 (A)', 'flat', 'Flat tyre', 4774, 1924,
      5700, 5600, 1700, 'Blue Jay', 'home', 1320),
    offer('junkerVeh', 'Low Value Tow', 1986, 'Ibishu', 'Covet 15LE (M)', 'overheat', 'Overheating', 4190, 1058,
      4700, 4800, 1100, 'This Pink House', 'home', 1680),
    offer('smallVeh', 'Budget Tow', 1992, 'Ibishu', 'BX-Series Diana GTz Turbo (M)', 'engine', 'Failing engine', 4184,
      1074, 3100, 6900, 1300, 'Acceler It Auto Sales', 'service', 150),
    offer('junkerVeh', 'Low Value Tow', 1987, 'Ibishu', 'Pigeon Van (M)', 'fuel', 'Nearly empty tank', 1012, 410,
      697, 640, 521, 'River Lot', 'home', 900),
  ]
  const lockedOffers = [
    offer('highEndVeh', 'Luxury Tow', 2020, 'Bruckell', 'LeGran Sport Luxe (A)', 'engine', 'Failing engine', 6120, 2410,
      2300, 4100, 1900, 'Acceler It Auto Sales', 'service', 1500, { locked: true, unlockLevel: 15 }),
    offer('exoticVeh', 'Exotic Tow', 2019, 'Civetta', 'Scintilla GTs (DCT)', 'overheat', 'Overheating', 9850, 3900,
      4100, 3300, 1400, 'Barrow Gate', 'home', 1100, { locked: true, unlockLevel: 20 }),
    offer('heavyVeh', 'Heavy Tow', 2005, 'Gavril', 'H-Series H35 XT Passenger (A)', 'flat', 'Flat tyre', 4121, 1800,
      3500, 3800, 3600, 'Acceler It Auto Sales', 'service', 1700, { locked: true, unlockLevel: 25 }),
  ]

  const activeJob = {
    jobType: 'tow', tierLabel: 'Budget Tow', vehicle: { year: 2021, brand: 'Cherrier', name: 'FCV Tograc 150dQ (DCT)' },
    destinationName: 'Sparrows Rest', destinationKind: 'home', fault: 'overheat', faultLabel: 'Overheating',
    weightKg: 1700, loadedM: 599, quote: 1718, xp: 404, custody: false, phase: 'pickup', distanceToNextM: 434,
    cancelFine: 0, otherMap: false, drivenM: 0, driveAllowanceM: 200, notTowedSoFar: 0,
  }

  window.PREVIEW_STATES = {
    // The board as a level 14 player sees it.
    list: Object.assign({}, base, { offers: openOffers.concat(lockedOffers), filling: false }),
    // An accepted job before pickup; the offers are folded away.
    active: Object.assign({}, base, { offers: openOffers, activeJob }),
    // After pickup: the second step is current and cancelling costs a fine.
    delivery: Object.assign({}, base, {
      offers: openOffers,
      activeJob: Object.assign({}, activeJob, { custody: true, phase: 'delivery', distanceToNextM: 1830, cancelFine: 859 }),
    }),
    // Driving the car within the free distance, e.g. onto a trailer.
    driving: Object.assign({}, base, {
      offers: openOffers,
      activeJob: Object.assign({}, activeJob, { custody: true, phase: 'delivery', distanceToNextM: 1830, cancelFine: 859,
        drivenM: 120 }),
    }),
    // Driving it to the destination instead of towing.
    overdriven: Object.assign({}, base, {
      offers: openOffers,
      activeJob: Object.assign({}, activeJob, { custody: true, phase: 'delivery', distanceToNextM: 640, cancelFine: 859,
        drivenM: 1260, notTowedSoFar: 682 }),
    }),
    // Driven most of the way: pay cut and XP reduced.
    nottowed: Object.assign({}, base, {
      offers: openOffers,
      lastCompletion: {
        vehicle: { year: 2021, brand: 'Cherrier', name: 'FCV Tograc 150dQ (DCT)' }, destinationName: 'Sparrows Rest',
        quote: 1718, penalty: 0, notTowed: 1289, drivenM: 1830, paid: 429, xp: 0,
        skill: { level: 14, fraction: 0.62, toNext: 1190 },
      },
    }),
    // A clean delivery that also levels up and unlocks a tier.
    complete: Object.assign({}, base, {
      offers: openOffers,
      lastCompletion: {
        vehicle: { year: 1992, brand: 'Gavril', name: 'Grand Marshal V8 (A)' }, destinationName: 'El Place',
        quote: 1664, penalty: 0, paid: 1664, xp: 449, skill: { level: 15, fraction: 0.08, toNext: 2210 },
        levelUp: { from: 14, to: 15 }, unlocked: ['Luxury Tow'],
      },
    }),
    // A delivery with a damage penalty.
    damaged: Object.assign({}, base, {
      offers: openOffers,
      lastCompletion: {
        vehicle: { year: 1986, brand: 'Ibishu', name: 'Covet 15LE (M)' }, destinationName: 'This Pink House',
        quote: 4190, penalty: 980, paid: 3210, xp: 1058, skill: { level: 14, fraction: 0.62, toNext: 1190 },
      },
    }),
    // A new board still filling, before any offer arrived.
    empty: Object.assign({}, base, { offers: [], filling: true }),
  }

  // UI actions to run after the first render, per state: CSS selectors to click in order.
  window.PREVIEW_CLICKS = {
    help: ['.help-btn'],
    locked: ['.offers-toggle'],
    cancel: ['.card.active .btn:not(.primary)'],
  }
  window.PREVIEW_STATES.help = window.PREVIEW_STATES.list
  window.PREVIEW_STATES.locked = window.PREVIEW_STATES.list
  window.PREVIEW_STATES.cancel = window.PREVIEW_STATES.delivery
})()
