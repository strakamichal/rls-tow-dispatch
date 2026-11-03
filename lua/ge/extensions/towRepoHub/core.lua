-- Tow & Repo Hub game engine entry point (towRepoHub_core).
-- Keeps one offer board per map and answers the phone app. Repo offers only so far (spec step 3).
-- RLS calls go through guarded lookups: every RLS module used here is internal (docs/rls-integration.md).

local rlsVersion = require("towRepoHub/lib/rlsVersion")
local pricing = require("towRepoHub/lib/pricing")
local board = require("towRepoHub/lib/board")
local jobRules = require("towRepoHub/lib/job")
local tow = require("towRepoHub/lib/tow")

local M = {}

M.dependencies = { "util_configListGenerator" }

local LOG_TAG = "towRepoHub"

local SKILL_ATTRIBUTE = "careerSkills-recovery"
local SKILL_PATH_IDS = { "careerSkills-recovery", "recovery" }
local SKILL_MAX_LEVEL = 50
local REPO_FILTERS_FILE = "gameplay/overhaul/repo/repoVehicleFilters.json"

local MIN_PICKUP_FROM_PLAYER_M = 300
local MIN_LOADED_ROUTE_M = 500
local MAX_SPOT_TRIES = 25
local MAX_ROUTE_TRIES = 3
local TICK_S = 1

-- Job types the board offers.
local JOB_TYPES = { "tow", "repo" }

local versionStatus, versionString

local simMinutes = 0
local tickTimer = 0
local nextOfferId = 1
local boards = {}           -- [levelId] = board state (lib/board)
local repoPool              -- RLS repo vehicle pool factory instance
local mapCache = {}         -- per-level caches: city spots, eligible vehicles, candidates
local routeCache = {}
local routeLease
local routedOfferId

-- RLS access ---------------------------------------------------------------------------------------

local function tryRequire(name)
  local ok, module = pcall(require, name)
  if ok then return module end
  log("W", LOG_TAG, "cannot load " .. name .. ": " .. tostring(module))
  return nil
end

local function readRlsVersion()
  local data = jsonReadFile and jsonReadFile(rlsVersion.FILE) or nil
  versionStatus, versionString = rlsVersion.check(data)
  if versionStatus == "ok" then
    log("I", LOG_TAG, "RLS " .. versionString .. " detected")
  elseif versionStatus == "unsupported" then
    log("W", LOG_TAG, "RLS " .. versionString .. " is not supported, expected " .. rlsVersion.SUPPORTED)
  else
    log("W", LOG_TAG, "RLS version file not found: " .. rlsVersion.FILE)
  end
end

local function careerActive()
  return (overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive()) and true or false
end

local function levelId()
  return getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
end

local function getRepoPool()
  if repoPool then return repoPool end
  local factory = tryRequire("overhaul/jobs/repo/vehiclePool")
  if factory then repoPool = factory(REPO_FILTERS_FILE, SKILL_ATTRIBUTE, SKILL_MAX_LEVEL, SKILL_PATH_IDS) end
  return repoPool
end

local function skillLevel()
  local pool = getRepoPool()
  local ok, level = pcall(function() return pool and pool.getRepoSkillLevel() end)
  return ok and tonumber(level) or 0
end

local function economy(section)
  local adjuster = overhaul_career_economyAdjuster
  if not (adjuster and adjuster.getSectionMultiplier) then return 1 end
  return tonumber((adjuster.getSectionMultiplier(section))) or 1
end

local function playerPosition()
  local vehicle = be:getPlayerVehicle(0)
  return vehicle and vehicle:getPosition() or nil
end

-- Road route length in metres; falls back to the straight line (as RLS Off-Road Recovery does).
local function routeDistance(fromPos, toPos)
  local key = string.format("%.0f,%.0f,%.0f>%.0f,%.0f,%.0f", fromPos.x, fromPos.y, fromPos.z, toPos.x, toPos.y, toPos.z)
  if routeCache[key] then return routeCache[key] end
  local straight = fromPos:distance(toPos)
  local ok, result = pcall(function()
    local planner = require("/lua/ge/extensions/gameplay/route/route")()
    planner:setRouteParams(nil, 1e3)
    planner:setupPath(fromPos, toPos)
    local distance = planner.path and planner.path[1] and planner.path[1].distToTarget or planner.distance
    planner:clear()
    return tonumber(distance)
  end)
  local distance = ok and result and result > 0 and result or straight
  routeCache[key] = distance
  return distance
end

local function vecToArray(v) return { v.x, v.y, v.z } end
local function arrayToVec(a) return vec3(a[1], a[2], a[3]) end

local function spotKey(spot)
  return (spot.getPath and spot:getPath()) or spot.name
end

-- Per-map data ---------------------------------------------------------------------------------------

local function currentMapCache()
  local id = levelId()
  if mapCache.levelId ~= id then mapCache = { levelId = id } end
  return mapCache
end

local function cityParkingSpots()
  local cache = currentMapCache()
  if cache.citySpots then return cache.citySpots end
  local spots = {}
  local levelData = tryRequire("overhaul/lib/world/levelData")
  local found, parkingSpots = false, nil
  if levelData then found, parkingSpots = levelData.loadCityParkingSpots() end
  if not (found and parkingSpots) and overhaul_integration_services_parking then
    parkingSpots = overhaul_integration_services_parking.getParkingSpots()
  end
  for _, spot in pairs(parkingSpots and parkingSpots.objects or {}) do
    if spot.pos and not spot.missing then spots[#spots + 1] = spot end
  end
  cache.citySpots = spots
  log("I", LOG_TAG, string.format("%d parking spots on %s", #spots, tostring(cache.levelId)))
  return spots
end

local function dealerships()
  local list = {}
  local facilities = overhaul_world_facilities and overhaul_world_facilities.getFacilities(levelId())
  for _, facility in ipairs(facilities and facilities.dealerships or {}) do list[#list + 1] = facility end
  local generator = overhaul_career_logistics_generator
  for _, facility in ipairs(generator and generator.getFacilities and generator.getFacilities() or {}) do
    if facility.repoProvider then list[#list + 1] = facility end
  end
  return list
end

-- Repo candidates per dealership, rebuilt when the skill level changes (it unlocks tiers).
local function repoCandidatesByDealership(level)
  local cache = currentMapCache()
  if cache.repoCandidates and cache.repoLevel == level then return cache.repoCandidates end
  local pool = getRepoPool()
  if not pool then return {} end
  cache.eligibleVehicles = cache.eligibleVehicles or require("util/configListGenerator").getEligibleVehicles(false, false) or {}
  local byDealership = {}
  for _, dealership in ipairs(dealerships()) do
    local spots = overhaul_world_facilities.getParkingSpotsForFacility(dealership) or {}
    local dropSpots = {}
    for _, spot in ipairs(spots) do
      if spot.pos then dropSpots[#dropSpots + 1] = spot end
    end
    local candidates = pool.getEligibleRepoVehiclesForDealership(dealership, cache.eligibleVehicles) or {}
    if #candidates > 0 and #dropSpots > 0 then
      byDealership[#byDealership + 1] = { dealership = dealership, candidates = candidates, dropSpots = dropSpots }
    end
  end
  cache.repoCandidates, cache.repoLevel = byDealership, level
  log("I", LOG_TAG, string.format("%d dealerships with repo candidates at level %d", #byDealership, level))
  return byDealership
end

local function tierUnlocked(tier, level)
  if level >= (tonumber(tier.skillUnlockLevel) or SKILL_MAX_LEVEL) then return true end
  local flag = tier.skillUnlockFlag or tier.unlockFlag
  local flags = overhaul_career_progression_unlockFlags
  return flag ~= nil and flags ~= nil and flags.getFlag(flag) == true
end

-- Tow candidates: common road vehicles in an unlocked value tier, rebuilt when the level changes.
local function towCandidates(level)
  local cache = currentMapCache()
  if cache.towCandidates and cache.towLevel == level then return cache.towCandidates end
  local pool = getRepoPool()
  if not pool then return {} end
  cache.eligibleVehicles = cache.eligibleVehicles or require("util/configListGenerator").getEligibleVehicles(false, false) or {}
  local candidates = {}
  local skipped = { noTier = 0, noTierData = 0, locked = 0 }
  for _, info in ipairs(cache.eligibleVehicles) do
    local key = tow.tierKey(info)
    local tier = key and pool.getRepoTagData(key)
    if not key then
      skipped.noTier = skipped.noTier + 1
    elseif not tier then
      skipped.noTierData = skipped.noTierData + 1
    elseif not tierUnlocked(tier, level) then
      skipped.locked = skipped.locked + 1
    else
      candidates[#candidates + 1] = { info = info, tierKey = key, tier = tier }
    end
  end
  cache.towCandidates, cache.towLevel = candidates, level
  log("I", LOG_TAG, string.format("%d tow candidates at level %d of %d vehicles (no tier %d, no tier data %d, locked %d)",
    #candidates, level, #cache.eligibleVehicles, skipped.noTier, skipped.noTierData, skipped.locked))
  if #candidates == 0 and cache.eligibleVehicles[1] then
    local sample = cache.eligibleVehicles[1]
    log("I", LOG_TAG, string.format("sample vehicle: model %s, Type %s, aggregates.Type %s, Value %s",
      tostring(sample.model_key), tostring(sample.Type), dumps(sample.aggregates and sample.aggregates.Type),
      tostring(sample.Value)))
  end
  return candidates
end

local function facilitySpots(facility)
  local spots = {}
  for _, spot in ipairs(overhaul_world_facilities.getParkingSpotsForFacility(facility) or {}) do
    if spot.pos then spots[#spots + 1] = spot end
  end
  return spots
end

-- Tow destinations: dealerships as a service and unowned, purchasable garages as the owner's home.
-- Read per offer, so garages the player buys or rents drop out at once.
local function towDestinations()
  local result = { service = {}, home = {} }
  for _, dealership in ipairs(dealerships()) do
    local spots = facilitySpots(dealership)
    if #spots > 0 then result.service[#result.service + 1] = { facility = dealership, dropSpots = spots } end
  end
  local garages = overhaul_world_facilities.getFacilitiesByType("garage", levelId()) or {}
  local manager = overhaul_career_garage_garageManager
  for _, garage in ipairs(garages) do
    local excluded = garage.isRecoveryYard
      or not manager
      or manager.isNotPurchasableGarage(garage.id, garage)
      or manager.isAccessibleGarage(garage.id)
    if not excluded then
      local spots = facilitySpots(garage)
      if #spots > 0 then result.home[#result.home + 1] = { facility = garage, dropSpots = spots } end
    end
  end
  return result
end

-- Picks a list entry with probability proportional to weight(entry).
local function pickWeighted(list, weight)
  local total = 0
  for _, entry in ipairs(list) do total = total + math.max(0, weight(entry)) end
  if total <= 0 then return list[math.random(#list)] end
  local roll = math.random() * total
  for _, entry in ipairs(list) do
    roll = roll - math.max(0, weight(entry))
    if roll <= 0 then return entry end
  end
  return list[#list]
end

local function vehicleWeightKg(info)
  return tow.weightKg(info)
end

local function spotIsFree(spot)
  local reservation = tryRequire("overhaul/lib/parking/reservation")
  local service = reservation and reservation.service
  if not service then return true end
  local live = service.resolveLiveSpot(spot)
  if not live then return true end
  return not service.isSpotHardBlocked(live)
end

-- Offer generation -----------------------------------------------------------------------------------

-- DEBUG, temporary: short jobs for testing. Pickups within DEBUG_MAX_PICKUP_M of the player, the
-- nearest destination and lower minimums. Toggled from the phone app.
local debugShortJobs = false
local DEBUG_MAX_PICKUP_M = 1500
local DEBUG_MIN_PICKUP_FROM_PLAYER_M = 50
local DEBUG_MIN_LOADED_ROUTE_M = 100

local function pickPickupSpot(state, fromPos, destPos)
  local spots = cityParkingSpots()
  local minFromPlayer = debugShortJobs and DEBUG_MIN_PICKUP_FROM_PLAYER_M or MIN_PICKUP_FROM_PLAYER_M
  local minLoaded = debugShortJobs and DEBUG_MIN_LOADED_ROUTE_M or MIN_LOADED_ROUTE_M
  if debugShortJobs then
    local near = {}
    for _, spot in ipairs(spots) do
      if spot.pos:distance(fromPos) <= DEBUG_MAX_PICKUP_M then near[#near + 1] = spot end
    end
    spots = near
  end
  local routeTries = 0
  for _ = 1, MAX_SPOT_TRIES do
    if #spots == 0 then return nil end
    local spot = spots[math.random(#spots)]
    local key = spotKey(spot)
    if not board.isSpotTaken(state, key) and spot.pos:distance(fromPos) >= minFromPlayer then
      routeTries = routeTries + 1
      local loaded = routeDistance(spot.pos, destPos)
      if loaded >= minLoaded and spotIsFree(spot) then return spot, loaded end
      if routeTries >= MAX_ROUTE_TRIES then return nil end
    end
  end
  return nil
end

local function nearestEntry(entries, fromPos)
  local best, bestDistance
  for _, entry in ipairs(entries) do
    local distance = entry.dropSpots[1].pos:distance(fromPos)
    if not bestDistance or distance < bestDistance then best, bestDistance = entry, distance end
  end
  return best
end

-- Sets year and mileage on the vehicle info the RLS way; false when RLS rejects it.
local function rollUsedCondition(info)
  local usedCondition = tryRequire("overhaul/lib/market/usedVehicleCondition")
  return not usedCondition
    or usedCondition.generateUsedVehicleCondition({ id = "private", salesChannel = "local" }, info) ~= nil
end

-- Completes an offer for a chosen vehicle, tier and destination: pickup spot, routes and quote.
local function buildOffer(state, level, fromPos, jobType, info, tierKey, tier, destination)
  local dropSpot = destination.dropSpots[math.random(#destination.dropSpots)]
  local spot, loadedM = pickPickupSpot(state, fromPos, dropSpot.pos)
  if not spot then return nil end
  local outboundM = routeDistance(fromPos, spot.pos)

  local quote = pricing.quote({
    outboundKm = outboundM / 1000, loadedKm = loadedM / 1000, level = level,
    tierMultiplier = tier.payMultiplier, jobType = jobType,
    economy = economy("repo"), recoveryEconomy = economy("offroadRecovery"),
  })

  return {
    jobType = jobType,
    tierTag = tierKey,
    tierLabel = tier.tierLabel,
    tierMultiplier = tier.payMultiplier,
    tierBaseXp = tier.baseXp,
    modelKey = info.model_key,
    configKey = info.key,
    brand = info.Brand,
    name = info.Name,
    year = info.year,
    mileage = info.Mileage,
    weightKg = vehicleWeightKg(info),
    vehicleType = info.Type,
    spotKey = spotKey(spot),
    pickupPos = vecToArray(spot.pos),
    destinationId = destination.facility.id,
    destinationName = destination.facility.name or tostring(destination.facility.id),
    dropSpotName = dropSpot.name,
    dropPos = vecToArray(dropSpot.pos),
    outboundM = outboundM,
    loadedM = loadedM,
    quote = quote,
    -- Runtime only: the RLS spot and facility objects used on accept.
    runtime = { spot = spot, dropSpot = dropSpot, dropSpots = destination.dropSpots },
  }
end

local function generateRepoOffer(state, level, fromPos)
  local byDealership = repoCandidatesByDealership(level)
  if #byDealership == 0 then return nil end
  local entry = debugShortJobs and nearestEntry(byDealership, fromPos) or byDealership[math.random(#byDealership)]
  local pool = getRepoPool()

  local info = pool.pickWeightedRepoVehicleInfo(entry.candidates)
  local tier = info and pool.getRepoTagData(info.repoTag)
  if not tier or not rollUsedCondition(info) then return nil end

  return buildOffer(state, level, fromPos, "repo", info, info.repoTag, tier,
    { facility = entry.dealership, dropSpots = entry.dropSpots })
end

local function generateTowOffer(state, level, fromPos)
  local candidates = towCandidates(level)
  if #candidates == 0 then return nil end
  local candidate = pickWeighted(candidates, function(c)
    return tonumber(c.info.adjustedPopulation) or tonumber(c.info.Population) or 1
  end)
  local info = deepcopy(candidate.info)
  if not rollUsedCondition(info) then return nil end

  local heavy = tow.isHeavy(info)
  local destinations = towDestinations()
  local kind = tow.destinationKind(math.random, heavy, #destinations.home > 0)
  local list = destinations[kind]
  if #list == 0 then return nil end
  local destination = debugShortJobs and nearestEntry(list, fromPos) or list[math.random(#list)]

  local tier = deepcopy(candidate.tier)
  tier.tierLabel = tow.tierLabel(tier.tierLabel)
  local offer = buildOffer(state, level, fromPos, "tow", info, candidate.tierKey, tier, destination)
  if not offer then return nil end
  offer.destinationKind = kind
  offer.faults = tow.pickFaults(math.random, tow.isElectric(info))
  offer.faultLabel = tow.faultLabel(offer.faults)
  return offer
end

-- Prefers a job type still short of the board minimum, otherwise picks one at random.
local function generateOffer(state, level, fromPos)
  local counts = {}
  for _, offer in ipairs(state.offers) do counts[offer.jobType] = (counts[offer.jobType] or 0) + 1 end
  local short = {}
  for _, jobType in ipairs(JOB_TYPES) do
    if (counts[jobType] or 0) < board.config.minPerType then short[#short + 1] = jobType end
  end
  local pool = #short > 0 and short or JOB_TYPES
  local first = pool[math.random(#pool)]
  local generators = { tow = generateTowOffer, repo = generateRepoOffer }
  local offer = generators[first](state, level, fromPos)
  if offer then return offer end
  -- The other type keeps the board filling when one type has nothing to offer.
  for _, jobType in ipairs(JOB_TYPES) do
    if jobType ~= first then
      offer = generators[jobType](state, level, fromPos)
      if offer then return offer end
    end
  end
end

local function currentBoard()
  local id = levelId()
  if not id then return nil end
  boards[id] = boards[id] or board.newState(simMinutes)
  return boards[id]
end

local function boardDisabledReason()
  if not careerActive() then return "Start or load an RLS career to see jobs." end
  if economy("repo") <= 0 then return "Repo work is disabled in this career." end
  if not getRepoPool() then return "RLS repo data could not be loaded." end
  return nil
end

local function addOffer(state)
  local fromPos = playerPosition()
  if not fromPos then return false end
  local level = skillLevel()
  local started = os.clock()
  local ok, candidate, relaxed = pcall(board.pick, function() return generateOffer(state, level, fromPos) end,
    state.offers, JOB_TYPES)
  local elapsedMs = (os.clock() - started) * 1000
  if not ok then
    log("E", LOG_TAG, "offer generation failed: " .. tostring(candidate))
    return false
  end
  if not candidate then
    log("W", LOG_TAG, string.format("no offer found for the board (%.0f ms)", elapsedMs))
    return false
  end
  candidate.id = nextOfferId
  nextOfferId = nextOfferId + 1
  candidate.createdAt = simMinutes
  candidate.expiresAt = simMinutes + board.config.ttlMin
  candidate.liveDistanceM = candidate.outboundM
  candidate.liveFrom = vecToArray(fromPos)
  state.offers[#state.offers + 1] = candidate
  log("I", LOG_TAG, string.format("offer %d: %s %s %s%s -> %s, %.1f + %.1f km, %d (relaxed %d, %.0f ms)",
    candidate.id, candidate.tierLabel or "?", tostring(candidate.brand), tostring(candidate.name),
    candidate.faultLabel and (" [" .. candidate.faultLabel .. "]") or "",
    candidate.destinationName, candidate.outboundM / 1000, candidate.loadedM / 1000, candidate.quote,
    relaxed or 0, elapsedMs))
  return true
end

-- Re-measures the road distance from the player to one offer's vehicle per tick, so the board
-- follows the player without routing six offers at once. The quote stays fixed.
local LIVE_DISTANCE_MOVE_M = 50
local liveDistanceIndex = 0

local function refreshLiveDistance(state)
  local count = #state.offers
  if count == 0 then return end
  local fromPos = playerPosition()
  if not fromPos then return end
  liveDistanceIndex = liveDistanceIndex % count + 1
  local offer = state.offers[liveDistanceIndex]
  if offer.liveFrom and fromPos:distance(arrayToVec(offer.liveFrom)) < LIVE_DISTANCE_MOVE_M then return end
  offer.liveDistanceM = routeDistance(fromPos, arrayToVec(offer.pickupPos))
  offer.liveFrom = vecToArray(fromPos)
end

local function tickBoard()
  if boardDisabledReason() then return end
  local state = currentBoard()
  if not state then return end
  local open = board.expire(state.offers, simMinutes)
  state.offers = open
  refreshLiveDistance(state)
  if board.isDue(state, simMinutes) then
    board.scheduleNext(state, simMinutes, addOffer(state))
  end
end

local function findOffer(id)
  local state = currentBoard()
  for _, offer in ipairs(state and state.offers or {}) do
    if offer.id == tonumber(id) then return offer end
  end
end

local function removeOffer(id)
  local state = currentBoard()
  for index, offer in ipairs(state and state.offers or {}) do
    if offer.id == id then return table.remove(state.offers, index) end
  end
end

local function getRouteLease()
  if not routeLease then
    local lease = tryRequire("overhaul/lib/activity/routeLease")
    routeLease = lease and lease.new(LOG_TAG)
  end
  return routeLease
end

local function setRoute(pos)
  local lease = getRouteLease()
  return lease ~= nil and lease.set(pos, { clearPathOnReachingTarget = true })
end

-- Active job -------------------------------------------------------------------------------------------
-- One job at a time. The target spawns on accept; custody starts when it leaves its spot; it is
-- delivered when stopped within 5 m of the dealership spot. See lib/job.lua for the rules.

local JOB_TICK_S = 0.5
local LOGBOOK_ID = "towRepoHub.jobCompleted"

local activeJob
local lastCompletion
local jobTimer = 0
local recordJob
local disposeTemporary
local deliveryMarker

-- The green checkpoint RLS repo shows at the delivery spot.
local function showDeliveryMarker(pos)
  if deliveryMarker then return end
  local ok, marker = pcall(function()
    local m = createObject("TSStatic")
    m.shapeName = "art/shapes/interface/checkpoint_marker.dae"
    m.scale = vec3(4, 4, 4)
    m.useInstanceRenderData = true
    m.instanceColor = ColorF(0, 0.8, 0.2, 0.7):asLinear4F()
    m:setPosition(pos)
    m:registerObject("towRepoHub_delivery_marker")
    return m
  end)
  if ok then deliveryMarker = marker else log("W", LOG_TAG, "delivery marker failed: " .. tostring(marker)) end
end

local function clearDeliveryMarker()
  if not deliveryMarker then return end
  pcall(function() deliveryMarker:unregisterObject() end)
  pcall(function() deliveryMarker:delete() end)
  deliveryMarker = nil
end

local function vehicleLabel(job)
  local label = ((job.brand or "") .. " " .. (job.name or "")):gsub("^%s+", ""):gsub("%s+$", "")
  return label
end

local function reservationService()
  local reservation = tryRequire("overhaul/lib/parking/reservation")
  return reservation and reservation.service
end

local function releaseReservations(job)
  local service = reservationService()
  if not service then return end
  for _, key in ipairs({ "pickupLive", "dropLive" }) do
    if job[key] then pcall(service.releaseSpot, job[key], job.token) end
    job[key] = nil
  end
end

local function removeTargetVehicle(job)
  local vehicleId = job.vehicleId
  -- Cleared first: deleting fires onVehicleDestroyed, which must not treat this as a lost target.
  job.vehicleId = nil
  local vehicle = vehicleId and getObjectByID(vehicleId)
  if vehicle then
    if gameplay_traffic and gameplay_traffic.removeTraffic then pcall(gameplay_traffic.removeTraffic, vehicleId) end
    -- If the player drove the target to the destination, they get out on foot there; the
    -- vehicle they accepted the job from is the fallback.
    if be:getPlayerVehicleID(0) == vehicleId and gameplay_walk and gameplay_walk.setWalkingMode then
      pcall(gameplay_walk.setWalkingMode, true, nil, nil, true)
    end
    if be:getPlayerVehicleID(0) == vehicleId then
      local carrier = job.carrierId and getObjectByID(job.carrierId)
      if carrier then be:enterVehicle(0, carrier) end
    end
    if core_vehicleBridge then pcall(core_vehicleBridge.executeAction, vehicle, "setFreeze", true) end
    vehicle:delete()
  end
end

-- Ends the active job: removes the target, releases spots and clears our route.
local function endJob(job)
  if activeJob == job then activeJob = nil end
  releaseReservations(job)
  removeTargetVehicle(job)
  clearDeliveryMarker()
  if routeLease then routeLease.clear() end
  if disposeTemporary then disposeTemporary(); disposeTemporary = nil end
end

local function payout(spec, category)
  local payment = overhaul_career_economy_payment
  if not (payment and payment.payout) then return false, "RLS payment module missing" end
  local metadata = tryRequire("overhaul/lib/finance/metadata")
  if metadata then spec = metadata.tagPayout(spec, category, { vehicleRole = "player" }) end
  return payment.payout(spec)
end

local function chargeFine(job, reason)
  local fine = pricing.custodyFine(job.tierMultiplier, economy("repo"))
  local ok, problem = payout({
    amount = -fine,
    label = string.format("Tow & Repo Hub fine: %s (%s)", reason, vehicleLabel(job)),
    tags = { "towRepoHub", "fine" },
    allowNetDebit = true,
  }, "fine")
  if not ok then log("W", LOG_TAG, "fine refused: " .. tostring(problem)) end
  return fine
end

-- Ends the job when the target is gone; a fine applies only after custody.
local function failJob(job, reason)
  local message
  if jobRules.endsWithFine(job) then
    local fine = chargeFine(job, reason)
    message = string.format("The %s was %s. Fine: $%d.", vehicleLabel(job), reason, fine)
  else
    message = string.format("The %s was %s before you took it. The job ended without a fine.", vehicleLabel(job), reason)
  end
  log("I", LOG_TAG, "job failed: " .. message)
  ui_message(message, 8, LOG_TAG, "warning")
  endJob(job)
end

local function partValueLookup(vehicleId)
  local data = core_vehicle_manager and core_vehicle_manager.getVehicleData(vehicleId)
  local vdata = data and data.vdata
  local activeParts = vdata and vdata.activeParts or {}
  local partsData = vdata and vdata.activePartsData or {}
  return function(partPath)
    local partName = activeParts[partPath]
    local info = partName and partsData[partName] and partsData[partName].information
    return info and tonumber(info.value) or nil
  end
end

local function scaledXp(xp)
  local rewardData = { [SKILL_ATTRIBUTE] = { amount = xp } }
  local difficulty = overhaul_career_economy_difficultyMode
  if difficulty and difficulty.scalePaymentRewardData then
    pcall(difficulty.scalePaymentRewardData, rewardData, { includeMoney = false })
  end
  return rewardData[SKILL_ATTRIBUTE] and tonumber(rewardData[SKILL_ATTRIBUTE].amount) or 0
end

local function completeJob(job, finalConditions)
  local damageValue = jobRules.damage(job.baseline, finalConditions, partValueLookup(job.vehicleId))
  local paid, penalty = pricing.settle(job.quote, damageValue)
  local xp = scaledXp(pricing.xp({ tierBaseXp = job.tierBaseXp, loadedKm = job.loadedM / 1000, jobType = job.jobType }))
  local label = string.format("Tow & Repo Hub: delivered the %s to %s", vehicleLabel(job), job.destinationName)

  local spec = { amount = paid, label = label, tags = { "gameplay", "reward", "repo", "recovery", "towRepoHub" },
    fullReward = true }
  if xp > 0 then spec.xp = { [SKILL_ATTRIBUTE] = xp } end
  local ok, problem = payout(spec, "activity:repo")
  if not ok then
    log("W", LOG_TAG, "payout refused: " .. tostring(problem))
  elseif recordJob then
    pcall(recordJob, { name = vehicleLabel(job), money = paid })
  end

  lastCompletion = {
    vehicle = { brand = job.brand, name = job.name, year = job.year },
    destinationName = job.destinationName,
    quote = job.quote, penalty = penalty, paid = paid, xp = xp,
  }
  log("I", LOG_TAG, string.format("job delivered: quote %d, damage %.0f, penalty %d, paid %d, xp %d",
    job.quote, damageValue, penalty, paid, xp))
  ui_message(string.format("Delivered the %s.\nPaid $%d (quote $%d, damage −$%d), %d Recovery XP.",
    vehicleLabel(job), paid, job.quote, penalty, xp), 10, LOG_TAG, "info")
  endJob(job)
  if overhaul_career_saveSystem and overhaul_career_saveSystem.saveCurrent then
    pcall(overhaul_career_saveSystem.saveCurrent)
  end
end

local function requestPartConditions(vehicle, callback)
  if not core_vehicleBridge then callback(nil); return end
  core_vehicleBridge.requestValue(vehicle, function(res) callback(res and res.result) end, "getPartConditions")
end

local function prepareTargetForPickup(job, vehicle)
  -- Keep traffic AI off the target, as RLS repo does.
  if gameplay_traffic and gameplay_traffic.insertTraffic then
    pcall(function()
      gameplay_traffic.insertTraffic(job.vehicleId, true)
      local trafficVehicle = gameplay_traffic.getTrafficData()[job.vehicleId]
      if trafficVehicle then trafficVehicle:setRole("empty") end
    end)
  end
  vehicle:queueLuaCommand('input.event("parkingbrake", 1, "FILTER_DI", nil, nil, nil, nil)')
end

local function updateJob()
  local job = activeJob
  if not job or job.completing then return end
  if job.mapId ~= levelId() then return end
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then failJob(job, "lost"); return end

  local targetPos = vehicle:getPosition()
  local playerPos = playerPosition()
  if playerPos and jobRules.needsBaseline(job, playerPos:distance(targetPos)) then
    job.baselineRequested = true
    prepareTargetForPickup(job, vehicle)
    log("I", LOG_TAG, string.format("baseline requested at %.0f m", playerPos:distance(targetPos)))
    requestPartConditions(vehicle, function(conditions)
      if activeJob ~= job then return end
      if type(conditions) ~= "table" then log("W", LOG_TAG, "baseline: vehicle returned no part conditions") end
      job.baseline = type(conditions) == "table" and conditions or {}
      local count = 0
      for _ in pairs(job.baseline) do count = count + 1 end
      log("I", LOG_TAG, string.format("baseline captured: %d parts", count))
    end)
  end

  if jobRules.reachesCustody(job, targetPos:distance(arrayToVec(job.pickupPos))) then
    job.custody = true
    local service = reservationService()
    if service and job.pickupLive then pcall(service.releaseSpot, job.pickupLive, job.token) end
    job.pickupLive = nil
    setRoute(arrayToVec(job.dropPos))
    showDeliveryMarker(arrayToVec(job.dropPos))
    ui_message(string.format("You have the %s.\nDeliver it to %s.", vehicleLabel(job), job.destinationName),
      8, LOG_TAG, "info")
    log("I", LOG_TAG, "custody started")
  end

  local speed = vehicle:getVelocity():length()
  if jobRules.isDelivered(job, targetPos:distance(arrayToVec(job.dropPos)), speed) then
    job.completing = true
    requestPartConditions(vehicle, function(conditions)
      if activeJob ~= job then return end
      local ok, err = pcall(completeJob, job, conditions or {})
      if not ok then
        log("E", LOG_TAG, "completion failed: " .. tostring(err))
        endJob(job)
      end
    end)
  end
end

-- Picks a reservable spot, preferring `first`; falls back to the static spot like RLS repo.
local function reserveSpot(token, first, others)
  local service = reservationService()
  if not service then return first, nil end
  local candidates = { first }
  for _, spot in ipairs(service.shuffleSpots(others or {})) do
    if spot ~= first then candidates[#candidates + 1] = spot end
  end
  local live = service.findReservableSpot(candidates, token)
  return live or first, live
end

-- Tow faults (spec: Tow faults). Applied right after spawn, before the baseline is taken at 30 m,
-- so the fault itself is never charged as damage. Vehicle Lua logs what it did under "towRepoHub".
local FAULT_FUEL_LITRES = 0.08
local JOULES_PER_LITRE = { gasoline = 31.125e6, diesel = 36.112e6, kerosine = 34.4e6 }
local WORN_EXTRA_MILEAGE_M = 150000000
local WORN_VISUAL = 0.55
-- Radiator integrity for the overheating fault. The game's radiator condition maps it to a leak
-- and a coolant level: 0.15 leaves about a quarter of the coolant, so the engine overheats soon.
local OVERHEAT_RADIATOR_INTEGRITY = 0.15

local function hasFault(job, fault)
  for _, f in ipairs(job.faults or {}) do
    if f == fault then return true end
  end
  return false
end

local function applyFuelFault(vehicle)
  core_vehicleBridge.requestValue(vehicle, function(response)
    -- Same unwrapping as RLS recovery (targetVehicle.lua setOneLiter).
    local tanks = response and (response.result or response)
    tanks = type(tanks) == "table" and (tanks[1] or tanks) or {}
    for _, tank in ipairs(tanks) do
      local perLitre = type(tank) == "table" and JOULES_PER_LITRE[tank.energyType]
      if perLitre and tank.name then
        local energy = math.min(perLitre * FAULT_FUEL_LITRES, tonumber(tank.maxEnergy) or math.huge)
        core_vehicleBridge.executeAction(vehicle, "setEnergyStorageEnergy", tank.name, energy)
      end
    end
    log("I", LOG_TAG, "fault applied: fuel")
  end, "energyStorage")
end

local VLUA_FLAT = [[
beamstate.deflateRandomTire()
log("I", "towRepoHub", "fault applied: flat tyre")
]]

local VLUA_OVERHEAT = [[
local applied = 0
for _, engine in ipairs(powertrain.getDevicesByCategory("engine") or {}) do
  if engine.thermals and engine.thermals.setPartConditionRadiator then
    engine.thermals.setPartConditionRadiator(0, %f, 1)
    applied = applied + 1
  end
end
log(applied > 0 and "I" or "W", "towRepoHub", "fault applied: overheating on " .. applied .. " engine(s)")
]]

local function applyFaults(job, vehicle)
  if hasFault(job, "fuel") then applyFuelFault(vehicle) end
  if hasFault(job, "flat") then vehicle:queueLuaCommand(VLUA_FLAT) end
  if hasFault(job, "overheat") then vehicle:queueLuaCommand(string.format(VLUA_OVERHEAT, OVERHEAT_RADIATOR_INTEGRITY)) end
end

local function spawnTarget(job, spot)
  local vehicle = core_vehicles.spawnNewVehicle(job.modelKey, {
    config = job.configKey, autoEnterVehicle = false,
    pos = spot.pos, rot = spot.rot or quat(0, 0, 0, 1), cling = true,
    electrics = { parkingbrake = 0 },
  })
  -- A fresh spawn has no part conditions; without them the baseline request returns nothing.
  -- Worn tow vehicles get extra mileage and a tired look.
  if vehicle and core_vehicleBridge then
    local mileage = tonumber(job.mileage) or 0
    if hasFault(job, "worn") then
      pcall(core_vehicleBridge.executeAction, vehicle, "ensurePartConditionsInit",
        mileage + WORN_EXTRA_MILEAGE_M, 1, WORN_VISUAL)
      log("I", LOG_TAG, "fault applied: worn")
    else
      pcall(core_vehicleBridge.executeAction, vehicle, "ensurePartConditionsInit", mileage, 1, 1)
    end
  end
  if vehicle and job.jobType == "tow" then
    local ok, err = pcall(applyFaults, job, vehicle)
    if not ok then log("W", LOG_TAG, "applying faults failed: " .. tostring(err)) end
  end
  return vehicle
end

-- Called by the phone app. Returns {ok, reason}.
local function acceptOffer(id)
  if activeJob then return { ok = false, reason = "Finish or cancel your active job first." } end
  if boardDisabledReason() then return { ok = false, reason = boardDisabledReason() } end
  local offer = findOffer(id)
  if not offer or not offer.runtime then return { ok = false, reason = "This offer is no longer available." } end

  local service = reservationService()
  local token = service and service.makeReservationToken(LOG_TAG) or LOG_TAG
  local pickupLive = service and service.findReservableSpot({ offer.runtime.spot }, token)
  if service and not pickupLive then
    removeOffer(offer.id)
    return { ok = false, reason = "The vehicle's parking spot is taken. The offer was removed." }
  end
  local dropSpot, dropLive = reserveSpot(token, offer.runtime.dropSpot, offer.runtime.dropSpots)

  local vehicle = spawnTarget(offer, pickupLive or offer.runtime.spot)
  if not vehicle then
    if service then
      pcall(service.releaseSpot, pickupLive, token)
      if dropLive then pcall(service.releaseSpot, dropLive, token) end
    end
    removeOffer(offer.id)
    return { ok = false, reason = "The vehicle could not be spawned. The offer was removed." }
  end

  removeOffer(offer.id)
  local state = currentBoard()
  if state then board.rememberSpot(state.recentSpots, offer.spotKey) end

  local job = {}
  for key, value in pairs(offer) do
    if key ~= "runtime" then job[key] = value end
  end
  job.mapId = levelId()
  job.vehicleId = vehicle:getID()
  job.carrierId = be:getPlayerVehicleID(0)
  job.token = token
  job.pickupLive = pickupLive
  job.dropLive = dropLive
  job.dropPos = vecToArray(dropSpot.pos)
  job.custody = false
  activeJob = job
  lastCompletion = nil

  local temporary = tryRequire("overhaul/lib/vehicles/temporary")
  if temporary then
    disposeTemporary = temporary.declare(LOG_TAG, function()
      if activeJob then removeTargetVehicle(activeJob) end
    end)
  end

  setRoute(arrayToVec(job.pickupPos))
  local story = job.jobType == "tow"
    and string.format("Tow job accepted: %s (%s).", vehicleLabel(job), job.faultLabel or "broken down")
    or string.format("Repo job accepted: %s.", vehicleLabel(job))
  ui_message(string.format("%s\nPick it up and deliver it to %s for $%d.", story, job.destinationName, job.quote),
    8, LOG_TAG, "info")
  log("I", LOG_TAG, string.format("job accepted: offer %d, vehicle %d", offer.id, job.vehicleId))
  return { ok = true }
end

-- Called by the phone app. Before custody cancelling is free; after it, a fine applies.
local function cancelJob()
  local job = activeJob
  if not job then return { ok = false } end
  local fine = 0
  if jobRules.endsWithFine(job) then fine = chargeFine(job, "cancelled") end
  ui_message(fine > 0 and string.format("Job cancelled. Fine: $%d.", fine) or "Job cancelled.", 6, LOG_TAG, "info")
  log("I", LOG_TAG, "job cancelled, fine " .. fine)
  endJob(job)
  return { ok = true, fine = fine }
end

-- Sets navigation to the active job's next stop.
local function routeActiveJob()
  local job = activeJob
  if not job then return false end
  return setRoute(arrayToVec(job.custody and job.dropPos or job.pickupPos))
end

local function clearCompletion()
  lastCompletion = nil
  return true
end

local function activeJobView(job)
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  local nextStop = arrayToVec(job.custody and job.dropPos or job.pickupPos)
  local from = job.custody and vehicle and vehicle:getPosition() or playerPosition()
  return {
    jobType = job.jobType,
    tierLabel = job.tierLabel,
    vehicle = { brand = job.brand, name = job.name, year = job.year },
    destinationName = job.destinationName,
    destinationKind = job.destinationKind,
    faultLabel = job.faultLabel,
    quote = job.quote,
    custody = job.custody,
    phase = job.completing and "completing" or (job.custody and "delivery" or "pickup"),
    distanceToNextM = from and from:distance(nextStop) or nil,
    cancelFine = jobRules.endsWithFine(job) and pricing.custodyFine(job.tierMultiplier, economy("repo")) or 0,
    otherMap = job.mapId ~= levelId(),
  }
end

-- Phone app API ----------------------------------------------------------------------------------------

-- distanceToVehicleM follows the player (refreshLiveDistance); outboundM and loadedM are the
-- routes the fixed quote was made from.
local function offerView(offer)
  return {
    id = offer.id,
    jobType = offer.jobType,
    tierTag = offer.tierTag,
    tierLabel = offer.tierLabel,
    vehicle = { brand = offer.brand, name = offer.name, year = offer.year },
    weightKg = offer.weightKg,
    distanceToVehicleM = offer.liveDistanceM or offer.outboundM,
    outboundM = offer.outboundM,
    loadedM = offer.loadedM,
    destinationName = offer.destinationName,
    destinationKind = offer.destinationKind,
    faultLabel = offer.faultLabel,
    quote = offer.quote,
    expiresInS = math.max(0, (offer.expiresAt - simMinutes) * 60),
    routed = offer.id == routedOfferId and routeLease ~= nil and routeLease.isCurrent(),
  }
end

-- Called by the phone app through callLua('towRepoHub_core.getState').
local function getState()
  if not versionStatus then readRlsVersion() end
  local level = careerActive() and skillLevel() or 0
  local state = {
    rlsVersion = versionString,
    rlsVersionStatus = versionStatus,
    supportedVersion = rlsVersion.SUPPORTED,
    careerActive = careerActive(),
    disabledReason = boardDisabledReason(),
    skillLevel = level,
    skillBonus = pricing.repoSkillBonus(level),
    boardSize = board.config.size,
    offers = {},
    activeJob = activeJob and activeJobView(activeJob) or nil,
    lastCompletion = lastCompletion,
    debugShortJobs = debugShortJobs,
  }
  local current = not state.disabledReason and currentBoard() or nil
  if current then
    for _, offer in ipairs(current.offers) do state.offers[#state.offers + 1] = offerView(offer) end
    state.filling = current.filling
    state.nextOfferInS = #current.offers < board.config.size and math.max(0, (current.nextOfferAt - simMinutes) * 60) or nil
  end
  return state
end

-- Sets navigation to the offer's vehicle.
local function routeToOffer(id)
  local offer = findOffer(id)
  if not offer then return false end
  if not setRoute(arrayToVec(offer.pickupPos)) then return false end
  routedOfferId = offer.id
  ui_message(string.format("Route set to the %s %s (%.1f km).", tostring(offer.brand), tostring(offer.name),
    offer.outboundM / 1000), 5, LOG_TAG, "info")
  return true
end

-- Debug: empties the current map's board so it fills again. Console: towRepoHub_core.resetBoard()
local function resetBoard()
  local id = levelId()
  if id then boards[id] = nil end
  routeCache = {}
  mapCache = {}
  log("I", LOG_TAG, "board reset")
end

-- Replaces every offer on the current board; recently used spots stay excluded.
local function refreshOffers()
  local state = currentBoard()
  if not state then return false end
  state.offers = {}
  state.filling = true
  routedOfferId = nil
  log("I", LOG_TAG, "offers refreshed")
  return true
end

-- DEBUG, temporary: see debugShortJobs.
local function setDebugShortJobs(enabled)
  debugShortJobs = enabled == true
  log("I", LOG_TAG, "debug short jobs " .. (debugShortJobs and "on" or "off"))
  refreshOffers()
  return debugShortJobs
end

-- Hooks ----------------------------------------------------------------------------------------------

local function onExtensionLoaded()
  readRlsVersion()
  local logbookFeed = tryRequire("overhaul/lib/progression/logbookFeed")
  if logbookFeed then
    recordJob = logbookFeed.register(LOGBOOK_ID,
      { title = "Tow & Repo Hub job completed", label = "Jobs", icon = "carCoins" }, "towRepoHub/core.lua")
  end
  log("I", LOG_TAG, "loaded")
end

local function onExtensionUnloaded()
  if activeJob then endJob(activeJob) end
end

local function onUpdate(dtReal, dtSim)
  if not careerActive() then return end
  simMinutes = simMinutes + math.max(tonumber(dtSim) or 0, 0) / 60
  local dt = tonumber(dtReal) or 0
  jobTimer = jobTimer + dt
  if jobTimer >= JOB_TICK_S then
    jobTimer = 0
    local ok, err = pcall(updateJob)
    if not ok then log("E", LOG_TAG, "job update failed: " .. tostring(err)) end
  end
  tickTimer = tickTimer + dt
  if tickTimer < TICK_S then return end
  tickTimer = 0
  tickBoard()
end

local function onVehicleDestroyed(vehicleId)
  if activeJob and activeJob.vehicleId == vehicleId and not activeJob.completing then
    activeJob.vehicleId = nil
    failJob(activeJob, "destroyed")
  end
end

-- Map travel and level unload remove the target. Until persistence (spec step 6) the job ends
-- here without a fine.
local function onClientEndMission()
  if activeJob then
    log("I", LOG_TAG, "level unloaded with an active job; ending it without a fine")
    activeJob.vehicleId = nil
    endJob(activeJob)
  end
  mapCache = {}
  routeCache = {}
end

local function onOverhaulActive(active)
  if not active then
    if activeJob then endJob(activeJob) end
    lastCompletion = nil
    boards = {}
    mapCache = {}
    routeCache = {}
  end
end

M.getState = getState
M.routeToOffer = routeToOffer
M.acceptOffer = acceptOffer
M.cancelJob = cancelJob
M.routeActiveJob = routeActiveJob
M.clearCompletion = clearCompletion
M.resetBoard = resetBoard
M.refreshOffers = refreshOffers
M.setDebugShortJobs = setDebugShortJobs
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onClientEndMission = onClientEndMission
M.onOverhaulActive = onOverhaulActive

return M
