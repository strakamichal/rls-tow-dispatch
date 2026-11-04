-- Tow Dispatch (formerly Tow & Repo Hub) game engine entry point (towRepoHub_core). Internal ids
-- keep the towRepoHub name so saves and installs stay compatible.
-- Keeps one offer board per map and answers the phone app. Repo offers only so far (spec step 3).
-- RLS calls go through guarded lookups: every RLS module used here is internal (docs/rls-integration.md).

local rlsVersion = require("towRepoHub/lib/rlsVersion")
local pricing = require("towRepoHub/lib/pricing")
local board = require("towRepoHub/lib/board")
local jobRules = require("towRepoHub/lib/job")
local tow = require("towRepoHub/lib/tow")
local repoTiers = require("towRepoHub/lib/repoTiers")
local persist = require("towRepoHub/lib/persist")

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

-- Job types the board offers. Repo jobs were dropped: an intact car is simply driven to the
-- dealership, which the original RLS repo app already covers. The job flow still handles
-- jobType "repo", so it can come back by generating repo offers again (see git history).
local JOB_TYPES = { "tow" }

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
local generationCo          -- coroutine that builds one offer over several frames
local generationCo_state    -- the board it builds for

-- Hands the frame back while an offer is being generated, so generation never stalls a frame.
-- Only yields inside our own coroutine; elsewhere (accept, debug tools) it does nothing.
-- Never call it inside pcall: LuaJIT here cannot yield across it (RLS repo.lua notes the same).
local function yieldStep()
  if generationCo and coroutine.running() == generationCo then coroutine.yield() end
end

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
  yieldStep()
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

-- RLS repo tier configs (every tier), loaded once; tow and repo offers use the same tier data.
local repoTierList, repoTierByTag
local function loadRepoTiers()
  if not repoTierList then
    repoTierList = repoTiers.normalize(jsonReadFile(REPO_FILTERS_FILE) or {})
    repoTierByTag = {}
    for _, tier in ipairs(repoTierList) do repoTierByTag[tier.unlockTag] = tier end
  end
  return repoTierList, repoTierByTag
end

local function tierUnlocked(tier, level)
  if level >= (tonumber(tier.skillUnlockLevel) or SKILL_MAX_LEVEL) then return true end
  local flag = tier.skillUnlockFlag or tier.unlockFlag
  local flags = overhaul_career_progression_unlockFlags
  return flag ~= nil and flags ~= nil and flags.getFlag(flag) == true
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

local POOL_YIELD_EVERY = 60

local function population(info)
  return tonumber(info.adjustedPopulation) or tonumber(info.Population) or 1
end

-- Tow candidates for every tier on this map, unlocked or not, built once per map (over several
-- frames when called from offer generation). pools[bucket] = { tow = { {info, tierKey, weight} } }.
local function tierPools()
  local cache = currentMapCache()
  if cache.pools then return cache.pools end
  local _, tierByTag = loadRepoTiers()
  cache.eligibleVehicles = cache.eligibleVehicles or require("util/configListGenerator").getEligibleVehicles(false, false) or {}
  local pools = {}
  for index, info in ipairs(cache.eligibleVehicles) do
    local tierKey = tow.tierKey(info)
    if tierKey and tierByTag[tierKey] then
      local bucket = board.tierBucket(tierKey)
      pools[bucket] = pools[bucket] or { tow = {} }
      local list = pools[bucket].tow
      list[#list + 1] = { info = info, tierKey = tierKey, weight = population(info) }
    end
    if index % POOL_YIELD_EVERY == 0 then yieldStep() end
  end

  cache.pools = pools
  local parts = {}
  for bucket, pool in pairs(pools) do parts[#parts + 1] = string.format("%s %d", bucket, #pool.tow) end
  table.sort(parts)
  log("I", LOG_TAG, string.format("tow candidates on %s: %s", tostring(cache.levelId), table.concat(parts, ", ")))
  return pools
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

-- Debug tools (lib/build.debugTools): short jobs for testing. Pickups within DEBUG_MAX_PICKUP_M of
-- the player, the nearest destination and lower minimums. Toggled from the phone app.
local DEBUG_TOOLS = require("towRepoHub/lib/build").debugTools == true
local debugShortJobs = false
local DEBUG_MAX_PICKUP_M = 1500
local DEBUG_MIN_PICKUP_FROM_PLAYER_M = 50
local DEBUG_MIN_LOADED_ROUTE_M = 100

-- Debug tools: vehicles offered by the test tow offer panel (debugAddTowOffer); any model of a
-- chosen tier is the other option.
local DEBUG_MODELS = {
  { key = "covet", label = "Covet" },
  { key = "midsize", label = "Pessima" },
  { key = "fullsize", label = "Grand Marshal" },
  { key = "etk800", label = "ETK 800" },
  { key = "pickup", label = "D-Series" },
  { key = "van", label = "H-Series" },
}

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
    economy = economy("repo"),
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
    unlockLevel = tonumber(tier.skillUnlockLevel),
    unlockFlag = tier.skillUnlockFlag,
    -- Runtime only: the RLS spot and facility objects used on accept.
    runtime = { spot = spot, dropSpot = dropSpot, dropSpots = destination.dropSpots },
  }
end

local function candidateWeight(candidate) return candidate.weight end

local function generateTowOffer(state, level, fromPos, candidates)
  if #candidates == 0 then return nil end
  local candidate = pickWeighted(candidates, candidateWeight)
  local _, tierByTag = loadRepoTiers()
  local info = deepcopy(candidate.info)
  if not tierByTag[candidate.tierKey] or not rollUsedCondition(info) then return nil end

  local heavy = tow.isHeavy(info)
  local destinations = towDestinations()
  local kind = tow.destinationKind(math.random, heavy, #destinations.home > 0)
  local list = destinations[kind]
  if #list == 0 then return nil end
  local destination = debugShortJobs and nearestEntry(list, fromPos) or list[math.random(#list)]

  local tier = tow.tierData(candidate.tierKey, tierByTag[candidate.tierKey])
  local offer = buildOffer(state, level, fromPos, "tow", info, candidate.tierKey, tier, destination)
  if not offer then return nil end
  offer.destinationKind = kind
  local condition = tow.pickCondition(math.random, tow.isElectric(info))
  offer.fault = condition.fault
  offer.engineIntegrity = condition.engineIntegrity
  offer.shabby = condition.shabby
  offer.faultLabel = tow.faultLabel(condition.fault)
  return offer
end

-- One offer: a tier picked by its board share (lib/board), then a tow vehicle in that tier.
local function generateOffer(state, level, fromPos)
  yieldStep()
  local pools = tierPools()
  local available = {}
  for bucket, pool in pairs(pools) do
    if #pool.tow > 0 then available[bucket] = true end
  end
  local bucket = board.pickTier(state.offers, math.random, available)
  if not bucket then return nil end
  return generateTowOffer(state, level, fromPos, pools[bucket].tow)
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
  local capacity = state.filling and state.target or nil
  -- Runs inside generationCo and yields between steps, so no pcall here (see yieldStep);
  -- coroutine.resume catches errors instead.
  local candidate, relaxed = board.pick(function() return generateOffer(state, level, fromPos) end,
    state.offers, JOB_TYPES, capacity)
  local elapsedMs = (os.clock() - started) * 1000
  if not candidate then
    log("W", LOG_TAG, string.format("no offer found for the board (%.0f ms)", elapsedMs))
    return false
  end
  candidate.id = nextOfferId
  nextOfferId = nextOfferId + 1
  candidate.createdAt = simMinutes
  candidate.expiresAt = simMinutes + board.ttl(math.random)
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
  if not generationCo and board.isDue(state, simMinutes) then
    generationCo = coroutine.create(function()
      board.scheduleNext(state, simMinutes, addOffer(state))
    end)
    generationCo_state = state
  end
end

-- Advances offer generation by one step; called every frame.
local function stepGeneration()
  if not generationCo then return end
  local ok, err = coroutine.resume(generationCo)
  if not ok then
    log("E", LOG_TAG, "offer generation failed: " .. tostring(err))
    if generationCo_state then board.scheduleNext(generationCo_state, simMinutes, false) end
  end
  if not ok or coroutine.status(generationCo) == "dead" then
    generationCo, generationCo_state = nil, nil
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
  local fine = pricing.custodyFine(job.quote)
  local ok, problem = payout({
    amount = -fine,
    label = string.format("Tow Dispatch fine: %s (%s)", reason, vehicleLabel(job)),
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

-- The Recovery skill level and how far it is to the next one, for the completion screen.
-- getBranchLevel returns level, progress, neededForNext, prevThreshold, nextThreshold.
local function skillProgress()
  local skills = overhaul_career_progression_skills
  local attributes = overhaul_career_economy_playerAttributes
  if not (skills and skills.getBranchLevel and attributes and attributes.getAttributeValue) then return nil end
  local ok, level, _, _, previous, nextAt = pcall(skills.getBranchLevel, SKILL_PATH_IDS[1])
  level, previous, nextAt = tonumber(level), tonumber(previous), tonumber(nextAt)
  if not ok or not level then return nil end
  local value = tonumber(attributes.getAttributeValue(SKILL_ATTRIBUTE)) or 0
  local result = { level = level }
  if previous and nextAt and nextAt > previous then
    result.fraction = math.max(0, math.min(1, (value - previous) / (nextAt - previous)))
    result.toNext = math.max(0, math.ceil(nextAt - value))
  end
  return result
end

local function scaledXp(xp)
  local rewardData = { [SKILL_ATTRIBUTE] = { amount = xp } }
  local difficulty = overhaul_career_economy_difficultyMode
  if difficulty and difficulty.scalePaymentRewardData then
    pcall(difficulty.scalePaymentRewardData, rewardData, { includeMoney = false })
  end
  return rewardData[SKILL_ATTRIBUTE] and tonumber(rewardData[SKILL_ATTRIBUTE].amount) or 0
end

local findCarrier

-- True when the vehicle is the player's own, with the test RLS employment uses for "your own
-- service vehicle": in the garage, not marked unowned, no loan type (depot rental, company,
-- delivery) and no owning organization. On foot (RLS walking) is not owned.
local function isOwnVehicle(vehicleId)
  local garage = overhaul_career_garage_inventory
  if not (vehicleId and garage and garage.getInventoryIdFromVehicleId and garage.getVehicles) then return false end
  local inventoryId = garage.getInventoryIdFromVehicleId(vehicleId)
  local info = inventoryId and garage.getVehicles()[inventoryId]
  return info ~= nil and info.owned ~= false and not info.loanType and not info.owningOrganization
end

local function isTrailer(vehicle)
  local ok, jbeam = pcall(function() return vehicle:getJBeamFilename() end)
  local model = ok and jbeam and core_vehicles and core_vehicles.getModel(jbeam)
  return model and model.model and model.model.Type == "Trailer" or false
end

-- Who owns the rig at delivery: the vehicle the target rests on (a trailer and what pulls it, or a
-- flatbed), else the vehicle the player sits in (wheel lift, rope). Returns rigOwned and
-- trailerOwned (nil without a trailer).
local function rigOwnership(job)
  local rigId, trailerId
  local carrier = findCarrier(job)
  if carrier and isTrailer(carrier) then
    trailerId = carrier:getID()
    local puller = core_trailerRespawn and core_trailerRespawn.getAttachedNonTrailer
      and core_trailerRespawn.getAttachedNonTrailer(trailerId)
    if puller and puller ~= trailerId then rigId = puller end
  elseif carrier then
    rigId = carrier:getID()
  end
  if not rigId then
    local playerId = be:getPlayerVehicleID(0)
    if playerId and playerId >= 0 and playerId ~= job.vehicleId then rigId = playerId end
  end
  local trailerOwned
  if trailerId then trailerOwned = isOwnVehicle(trailerId) end
  return isOwnVehicle(rigId), trailerOwned
end

local function completeJob(job, finalConditions)
  local damageValue = jobRules.damage(job.baseline, finalConditions, partValueLookup(job.vehicleId))
  local paid, penalty = pricing.settle(job.quote, damageValue)
  local notTowed, xpFactor = pricing.selfDrive(job.quote, job.drivenM, job.loadedM)
  -- A failed rig check only costs the bonus, never the payout. The bonus shrinks like the XP when
  -- part of the route was driven instead of towed.
  local okRig, rigOwned, trailerOwned = pcall(rigOwnership, job)
  if not okRig then log("W", LOG_TAG, "rig check failed: " .. tostring(rigOwned)); rigOwned, trailerOwned = false, nil end
  local ownRigShare = pricing.ownRigBonusShare(rigOwned, trailerOwned)
  local ownRig = pricing.ownRigBonus(job.quote * xpFactor, ownRigShare)
  paid = math.max(0, paid - notTowed) + ownRig
  local xp = scaledXp(pricing.xp({ tierBaseXp = job.tierBaseXp, loadedKm = job.loadedM / 1000, jobType = job.jobType }))
  xp = math.floor(xp * xpFactor + 0.5)
  local label = string.format("Tow Dispatch: delivered the %s to %s", vehicleLabel(job), job.destinationName)

  -- Listed in Wallet as work income from recovery, like Off-Road Recovery. No "repo" tag: that
  -- tag ties the payout to the RLS repo demand (activity heat).
  local spec = { amount = paid, label = label, tags = { "gameplay", "reward", "recovery", "towRepoHub" },
    fullReward = true }
  if xp > 0 then spec.xp = { [SKILL_ATTRIBUTE] = xp } end
  local levelBefore = skillLevel()
  local ok, problem = payout(spec, "activity:recovery")
  if not ok then
    log("W", LOG_TAG, "payout refused: " .. tostring(problem))
  elseif recordJob then
    pcall(recordJob, { name = vehicleLabel(job), money = paid })
  end

  lastCompletion = {
    vehicle = { brand = job.brand, name = job.name, year = job.year },
    destinationName = job.destinationName,
    quote = job.quote, penalty = penalty, notTowed = notTowed, drivenM = job.drivenM or 0, paid = paid, xp = xp,
    ownRig = ownRig, ownRigShare = ownRigShare, rentedTrailer = trailerOwned == false,
    skill = skillProgress(),
  }
  -- Level up, and the tow tiers that unlocked with it, for the completion screen.
  local levelAfter = skillLevel()
  if levelAfter > levelBefore then
    lastCompletion.levelUp = { from = levelBefore, to = levelAfter }
    lastCompletion.unlocked = {}
    for _, tier in ipairs((loadRepoTiers())) do
      local unlockAt = tonumber(tier.skillUnlockLevel)
      if board.TIER_SHARES[tier.unlockTag] and unlockAt and unlockAt > levelBefore and unlockAt <= levelAfter then
        lastCompletion.unlocked[#lastCompletion.unlocked + 1] = tow.tierLabel(tier.tierLabel)
      end
    end
    log("I", LOG_TAG, string.format("level up %d -> %d, unlocked %d tiers", levelBefore, levelAfter, #lastCompletion.unlocked))
  end
  log("I", LOG_TAG, string.format("job delivered: quote %d, damage %.0f, penalty %d, driven %.0f m, not towed %d, own rig bonus %d, paid %d, xp %d",
    job.quote, damageValue, penalty, job.drivenM or 0, notTowed, ownRig, paid, xp))
  ui_message(string.format("Delivered the %s.\nPaid $%d (quote $%d), %d Recovery XP.",
    vehicleLabel(job), paid, job.quote, xp), 10, LOG_TAG, "info")
  endJob(job)
  if overhaul_career_saveSystem and overhaul_career_saveSystem.saveCurrent then
    pcall(overhaul_career_saveSystem.saveCurrent)
  end
end

local function requestPartConditions(vehicle, callback)
  if not core_vehicleBridge then callback(nil); return end
  core_vehicleBridge.requestValue(vehicle, function(res) callback(res and res.result) end, "getPartConditions")
end

-- Overheating fault, when the player arrives: the engine has just overheated and stopped, so it is
-- hot but below the game's damage thresholds (block 140, oil 150, cylinder walls 160 °C).
local OVERHEAT_ARRIVAL_TEMPERATURE_C = 125
local VLUA_HOT_ENGINE = [[
for _, engine in ipairs(powertrain.getDevicesByCategory("engine") or {}) do
  local thermals = engine.thermals
  if thermals and thermals.engineBlockTemperature then
    thermals.engineBlockTemperature = %f
    thermals.cylinderWallTemperature = %f
    thermals.oilTemperature = %f
    if thermals.coolantTemperature then thermals.coolantTemperature = %f end
  end
end
log("I", "towRepoHub", "engine heated to %.0f C")
]]

local function heatEngine(vehicle)
  local t = OVERHEAT_ARRIVAL_TEMPERATURE_C
  vehicle:queueLuaCommand(string.format(VLUA_HOT_ENGINE, t, t, t, t, t))
end

local function prepareTargetForPickup(job, vehicle, resumed)
  -- Keep traffic AI off the target, as RLS repo does.
  if gameplay_traffic and gameplay_traffic.insertTraffic then
    pcall(function()
      gameplay_traffic.insertTraffic(job.vehicleId, true)
      local trafficVehicle = gameplay_traffic.getTrafficData()[job.vehicleId]
      if trafficVehicle then trafficVehicle:setRole("empty") end
    end)
  end
  vehicle:queueLuaCommand('input.event("parkingbrake", 1, "FILTER_DI", nil, nil, nil, nil)')
  if job.fault == "overheat" and not resumed then heatEngine(vehicle) end
end

-- Tow jobs pay for towing: metres the player drives the target themselves are counted, and beyond
-- the allowance they cut the pay (lib/pricing selfDrive). Riding on a bed or a rope does not count:
-- the player sits in the tow vehicle then. The player is told when they first get in and when the
-- allowance runs out.
local function trackSelfDrive(job, targetPos)
  local inTarget = be:getPlayerVehicleID(0) == job.vehicleId
  if inTarget and job.lastTargetPos then
    job.drivenM = (job.drivenM or 0) + jobRules.drivenStep(targetPos:distance(arrayToVec(job.lastTargetPos)))
  end
  job.lastTargetPos = vecToArray(targetPos)
  if not inTarget then return end

  local allowance = pricing.config.selfDriveAllowanceM
  if not job.selfDriveWarned then
    job.selfDriveWarned = true
    ui_message(string.format("Tow jobs pay for towing.\nYou are allowed to drive this car only %d m, to load it.",
      allowance), 8, LOG_TAG, "warning")
  end
  if (job.drivenM or 0) > allowance and not job.selfDriveOverWarned then
    job.selfDriveOverWarned = true
    ui_message("You have driven this car further than allowed.\nThe pay drops the further you drive it; tow it instead.",
      8, LOG_TAG, "warning")
    log("I", LOG_TAG, "self-drive allowance used up")
  end
end

local resolveOfferRuntime

-- Set while the level unloads and until the target is back, so its disappearance is not a loss.
local unloading = false
local restorePending = false

local function updateJob()
  local job = activeJob
  if not job or job.completing then return end
  if job.mapId ~= levelId() or unloading or restorePending then return end
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not vehicle then failJob(job, "lost"); return end

  local targetPos = vehicle:getPosition()
  -- Pose kept for saving: the spawn rotation convention RLS recovery uses (persistence.lua).
  job.targetPose = { pos = vecToArray(targetPos),
    rot = (function() local q = quat(0, 0, 1, 0) * quat(vehicle:getRefNodeRotation()); return { q.x, q.y, q.z, q.w } end)() }
  trackSelfDrive(job, targetPos)
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
-- Appearance of a shabby vehicle (paint and visual condition only).
local SHABBY_VISUAL = 0.55
-- Overheating fault: a broken radiator (full leak damage) with practically no coolant left, so
-- the engine overheats as soon as it runs. Passed as the radiator's integrity state
-- (combustionEngineThermals). Not exactly 0: the game divides by the coolant mass.
local OVERHEAT_RADIATOR_DAMAGE = 0.1
local OVERHEAT_COOLANT_KG = 0.05

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
    engine.thermals.setPartConditionRadiator(0, { radiatorDamage = %f, coolantMass = %f }, 1)
    applied = applied + 1
  end
end
log(applied > 0 and "I" or "W", "towRepoHub", "fault applied: overheating on " .. applied .. " engine(s)")
]]

-- Engine integrity drives misfires and idle stability (combustionEngine setPartCondition).
local VLUA_ENGINE = [[
local applied = 0
for _, engine in ipairs(powertrain.getDevicesByCategory("engine") or {}) do
  if engine.setPartCondition then
    engine:setPartCondition(nil, %f, %f, 1)
    applied = applied + 1
  end
end
log(applied > 0 and "I" or "W", "towRepoHub", "fault applied: failing engine, integrity %.2f on " .. applied .. " engine(s)")
]]

local function applyFault(job, vehicle)
  if job.fault == "fuel" then applyFuelFault(vehicle) end
  if job.fault == "flat" then vehicle:queueLuaCommand(VLUA_FLAT) end
  if job.fault == "overheat" then vehicle:queueLuaCommand(string.format(VLUA_OVERHEAT, OVERHEAT_RADIATOR_DAMAGE, OVERHEAT_COOLANT_KG)) end
  if job.fault == "engine" then
    local integrity = tonumber(job.engineIntegrity) or tow.engineIntegrity(0.5)
    vehicle:queueLuaCommand(string.format(VLUA_ENGINE, tonumber(job.mileage) or 0, integrity, integrity))
  end
end

local function spawnTarget(job, spot)
  local vehicle = core_vehicles.spawnNewVehicle(job.modelKey, {
    config = job.configKey, autoEnterVehicle = false,
    pos = spot.pos, rot = spot.rot or quat(0, 0, 0, 1), cling = true,
    electrics = { parkingbrake = 0 },
  })
  -- A fresh spawn has no part conditions; without them the baseline request returns nothing.
  -- A shabby vehicle gets a lower visual condition only.
  if vehicle and core_vehicleBridge then
    local visual = job.shabby and SHABBY_VISUAL or 1
    pcall(core_vehicleBridge.executeAction, vehicle, "ensurePartConditionsInit", tonumber(job.mileage) or 0, 1, visual)
    if job.shabby then log("I", LOG_TAG, "shabby look applied") end
  end
  if vehicle and job.jobType == "tow" then
    local ok, err = pcall(applyFault, job, vehicle)
    if not ok then log("W", LOG_TAG, "applying the fault failed: " .. tostring(err)) end
  end
  return vehicle
end

-- Called by the phone app. Returns {ok, reason}.
-- The board shows offers of every tier; those above the player's Recovery level are locked.
local function offerLocked(offer, level)
  return not tierUnlocked({ skillUnlockLevel = offer.unlockLevel, skillUnlockFlag = offer.unlockFlag }, level)
end

-- Offers loaded from a save have no RLS spot objects; finds them again by spot key and
-- destination id. Leaves offer.runtime nil when the spot or destination is gone.
resolveOfferRuntime = function(offer)
  local spot
  for _, candidate in ipairs(cityParkingSpots()) do
    if spotKey(candidate) == offer.spotKey then spot = candidate break end
  end
  local facility
  for _, dealership in ipairs(dealerships()) do
    if dealership.id == offer.destinationId then facility = dealership break end
  end
  if not facility then
    for _, garage in ipairs(overhaul_world_facilities.getFacilitiesByType("garage", levelId()) or {}) do
      if garage.id == offer.destinationId then facility = garage break end
    end
  end
  local dropSpots = facility and facilitySpots(facility) or {}
  if not spot or #dropSpots == 0 then return end
  local dropSpot = dropSpots[1]
  for _, candidate in ipairs(dropSpots) do
    if candidate.name == offer.dropSpotName then dropSpot = candidate break end
  end
  offer.runtime = { spot = spot, dropSpot = dropSpot, dropSpots = dropSpots }
end

local function acceptOffer(id)
  if activeJob then return { ok = false, reason = "Finish or cancel your active job first." } end
  if boardDisabledReason() then return { ok = false, reason = boardDisabledReason() } end
  local offer = findOffer(id)
  if offer and not offer.runtime then resolveOfferRuntime(offer) end
  if not offer or not offer.runtime then
    if offer then removeOffer(offer.id) end
    return { ok = false, reason = "This offer is no longer available." }
  end
  if offerLocked(offer, skillLevel()) then
    return { ok = false, reason = string.format("This job unlocks at Recovery level %d.", offer.unlockLevel or 0) }
  end

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
  ui_message(string.format("%s\nTow it to %s for $%d. You are allowed to drive it yourself only %d m.",
    story, job.destinationName, job.quote, pricing.config.selfDriveAllowanceM), 10, LOG_TAG, "info")
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

-- The map's display name, as RLS employment shows it.
local function mapLabel(mapId)
  local info = core_levels and core_levels.getLevelByName(mapId)
  local title = info and info.title
  if title and translateLanguage then title = translateLanguage(title, title, true) end
  return title or tostring(mapId)
end

local function activeJobView(job)
  local otherMap = job.mapId ~= levelId()
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  local nextStop = arrayToVec(job.custody and job.dropPos or job.pickupPos)
  local from = not otherMap and (job.custody and vehicle and vehicle:getPosition() or playerPosition())
  return {
    jobType = job.jobType,
    tierLabel = job.tierLabel,
    vehicle = { brand = job.brand, name = job.name, year = job.year },
    destinationName = job.destinationName,
    destinationKind = job.destinationKind,
    fault = job.fault,
    faultLabel = job.faultLabel,
    weightKg = job.weightKg,
    loadedM = job.loadedM,
    quote = job.quote,
    xp = scaledXp(pricing.xp({ tierBaseXp = job.tierBaseXp, loadedKm = job.loadedM / 1000, jobType = job.jobType })),
    drivenM = job.drivenM or 0,
    driveAllowanceM = pricing.config.selfDriveAllowanceM,
    notTowedSoFar = (pricing.selfDrive(job.quote, job.drivenM, job.loadedM)),
    custody = job.custody,
    phase = job.completing and "completing" or (job.custody and "delivery" or "pickup"),
    distanceToNextM = from and from:distance(nextStop) or nil,
    cancelFine = jobRules.endsWithFine(job) and pricing.custodyFine(job.quote) or 0,
    otherMap = otherMap,
    mapLabel = otherMap and mapLabel(job.mapId) or nil,
  }
end

-- Persistence --------------------------------------------------------------------------------------------
-- Saved with the RLS career (onOverhaulSaveCurrentProfile) and, around a Lua reload, in a session
-- file. The target vehicle is not an RLS inventory vehicle, so it is respawned from the saved pose,
-- part conditions and fuel; on a flatbed or trailer it is placed back on the carrier with the RLS
-- carriedFrame relation (docs/rls-integration.md 7.4).

local SAVE_DIR = "/career/towRepoHub"
local SAVE_FILE = SAVE_DIR .. "/state.json"
local SESSION_FILE = "/temp/towRepoHub/session.json"
local SNAPSHOT_S = 10
local CARRIER_SEARCH_M = 12
local RESTORE_WAIT_S = 20

local snapshotTimer = 0
local restoreWaited = 0
local carriedFrame

local function getCarriedFrame()
  carriedFrame = carriedFrame or tryRequire("overhaul/lib/vehicles/carriedFrame")
  return carriedFrame
end

local function inventory() return overhaul_career_garage_inventory end

-- Part conditions and fuel of the target, refreshed every SNAPSHOT_S while a job runs; saving reads
-- the latest copy because these values only come back asynchronously.
local function snapshotTarget(job)
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  if not (vehicle and core_vehicleBridge) then return end
  requestPartConditions(vehicle, function(conditions)
    if activeJob == job and type(conditions) == "table" then job.conditions = conditions end
  end)
  core_vehicleBridge.requestValue(vehicle, function(response)
    local tanks = response and (response.result or response)
    tanks = type(tanks) == "table" and (tanks[1] or tanks) or {}
    if activeJob ~= job then return end
    job.energy = {}
    for _, tank in ipairs(tanks) do
      if type(tank) == "table" and tank.name then
        job.energy[#job.energy + 1] = { name = tank.name, energy = tonumber(tank.currentEnergy) or 0 }
      end
    end
  end, "energyStorage")
end

-- The vehicle carrying the target, if any: the player's own or rented vehicles nearby, checked by
-- carriedFrame, which only finds a support when the target rests on a deck.
-- Returns the vehicle, its inventory id and the support.
findCarrier = function(job)
  local target = job.vehicleId and getObjectByID(job.vehicleId)
  local frames = getCarriedFrame()
  if not (target and frames and getAllVehicles) then return nil end
  local targetPos = target:getPosition()
  for _, candidate in ipairs(getAllVehicles() or {}) do
    local id = candidate:getID()
    local invId = id ~= job.vehicleId and inventory() and inventory().getInventoryIdFromVehicleId(id)
    if invId and candidate:getPosition():distance(targetPos) <= CARRIER_SEARCH_M then
      local support = frames.capture(target, candidate)
      if support then return candidate, invId, support end
    end
  end
  return nil
end

-- Records which vehicle carries the target, so a reload can put it back on the deck.
local function captureCarrier(job)
  job.carrier = nil
  local target = job.vehicleId and getObjectByID(job.vehicleId)
  local candidate, invId, support = findCarrier(job)
  if not candidate then return end
  local offset = candidate:getRefNodeMatrix():inverse() * target:getRefNodeMatrix()
  local pos, rot = offset:getPosition(), offset:toEuler()
  job.carrier = { inventoryId = invId, support = support,
    offset = { x = pos.x, y = pos.y, z = pos.z, rx = rot.x, ry = rot.y, rz = rot.z } }
  log("I", LOG_TAG, "target is carried by inventory vehicle " .. tostring(invId))
end

local function stateForSave()
  if activeJob and activeJob.vehicleId then captureCarrier(activeJob) end
  return persist.build({ boards = boards, activeJob = activeJob, simMinutes = simMinutes, nextOfferId = nextOfferId })
end

local function applySaved(data, source)
  local state, reason = persist.restore(data)
  if not state then
    if data ~= nil then log("W", LOG_TAG, "ignoring saved state from " .. source .. ": " .. tostring(reason)) end
    return
  end
  simMinutes, nextOfferId, boards = state.simMinutes, state.nextOfferId, state.boards
  activeJob = state.activeJob
  if activeJob then
    activeJob.vehicleId = nil
    restorePending = true
    restoreWaited = 0
  end
  local count = 0
  for _ in pairs(boards) do count = count + 1 end
  log("I", LOG_TAG, string.format("state loaded from %s: %d boards, %s", source, count,
    activeJob and ("active job on " .. tostring(activeJob.mapId)) or "no active job"))
end

local function loadFromCareerSave()
  local saveSystem = overhaul_career_saveSystem
  if not (saveSystem and saveSystem.getCurrentProfile) then return end
  local _, savePath = saveSystem.getCurrentProfile()
  if not savePath then return end
  applySaved(jsonReadFile(savePath .. SAVE_FILE), "career save")
end

-- Respawns the active job's target on this map: on its carrier when it was carried, else at its
-- saved pose; then its condition, fuel and fault. Waits up to RESTORE_WAIT_S for the carrier,
-- which RLS restores from the player's inventory on its own schedule.
local function tryRestoreTarget(dt)
  local job = activeJob
  if not restorePending or not job then restorePending = false return end
  if job.mapId ~= levelId() then return end
  if not be:getPlayerVehicle(0) then return end

  restoreWaited = restoreWaited + dt
  local carrier
  if job.carrier and inventory() then
    local carrierId = inventory().getVehicleIdFromInventoryId(job.carrier.inventoryId)
    carrier = carrierId and getObjectByID(carrierId)
    if not carrier and restoreWaited < RESTORE_WAIT_S then return end
  end

  local pose = job.targetPose or { pos = job.custody and job.dropPos or job.pickupPos, rot = { 0, 0, 0, 1 } }
  local spot = { pos = arrayToVec(pose.pos), rot = quat(pose.rot[1], pose.rot[2], pose.rot[3], pose.rot[4]) }
  local vehicle = spawnTarget(job, spot)
  restorePending = false
  if not vehicle then
    log("W", LOG_TAG, "could not respawn the job vehicle; ending the job without a fine")
    ui_message("The tow job vehicle could not be restored. The job ended without a fine.", 8, LOG_TAG, "warning")
    endJob(job)
    return
  end
  job.vehicleId = vehicle:getID()

  local frames = getCarriedFrame()
  local matrix = carrier and frames and frames.transform(carrier, job.carrier)
  if matrix then
    vehicle:setTransform(matrix)
    if vehicle.resetBrokenFlexMesh then vehicle:resetBrokenFlexMesh() end
    log("I", LOG_TAG, "job vehicle placed back on its carrier")
  end
  if core_vehicleBridge then
    if type(job.conditions or job.baseline) == "table" then
      pcall(core_vehicleBridge.executeAction, vehicle, "initPartConditions", job.conditions or job.baseline, 0, 1, 1)
    end
    for _, tank in ipairs(job.energy or {}) do
      pcall(core_vehicleBridge.executeAction, vehicle, "setEnergyStorageEnergy", tank.name, tank.energy)
    end
  end
  if job.baselineRequested then prepareTargetForPickup(job, vehicle, true) end

  local temporary = tryRequire("overhaul/lib/vehicles/temporary")
  if temporary then
    disposeTemporary = temporary.declare(LOG_TAG, function()
      if activeJob then removeTargetVehicle(activeJob) end
    end)
  end
  job.lastTargetPos = vecToArray(vehicle:getPosition())
  if job.custody then
    setRoute(arrayToVec(job.dropPos))
    showDeliveryMarker(arrayToVec(job.dropPos))
  else
    setRoute(arrayToVec(job.pickupPos))
  end
  ui_message(string.format("Tow job resumed: %s.", vehicleLabel(job)), 6, LOG_TAG, "info")
  log("I", LOG_TAG, "job vehicle restored")
end

-- Takes the target out of the world but keeps the job, for map travel and Lua reload. On a level
-- unload the level deletes the vehicle itself (deleteVehicle false).
local function parkJob(job, deleteVehicle)
  if not job then return end
  if job.vehicleId then captureCarrier(job) end
  clearDeliveryMarker()
  if routeLease then routeLease.clear() end
  if disposeTemporary then disposeTemporary(); disposeTemporary = nil end
  local vehicle = job.vehicleId and getObjectByID(job.vehicleId)
  job.vehicleId = nil
  if vehicle and deleteVehicle then vehicle:delete() end
  restorePending = true
  restoreWaited = 0
end

-- State to resume: the session file a Lua reload left for this profile, else the career save.
local SESSION_MAX_AGE_S = 600
local resumedFromSession = false

local function profileName()
  local saveSystem = overhaul_career_saveSystem
  return saveSystem and saveSystem.getCurrentProfile and saveSystem.getCurrentProfile() or nil
end

local function loadState()
  local session = jsonReadFile(SESSION_FILE)
  if session then
    FS:removeFile(SESSION_FILE)
    if session.profile == profileName() and math.abs(os.time() - (tonumber(session.savedAt) or 0)) <= SESSION_MAX_AGE_S then
      applySaved(session, "session")
      return true
    end
  end
  loadFromCareerSave()
end

-- Phone app API ----------------------------------------------------------------------------------------

-- distanceToVehicleM follows the player (refreshLiveDistance); outboundM and loadedM are the
-- routes the fixed quote was made from.
local function offerView(offer, level)
  return {
    locked = offerLocked(offer, level),
    unlockLevel = offer.unlockLevel,
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
    fault = offer.fault,
    faultLabel = offer.faultLabel,
    quote = offer.quote,
    xp = scaledXp(pricing.xp({ tierBaseXp = offer.tierBaseXp, loadedKm = offer.loadedM / 1000, jobType = offer.jobType })),
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
    skillBonus = pricing.skillBonus(level),
    skill = careerActive() and skillProgress() or nil,
    boardSize = board.config.size,
    offers = {},
    activeJob = activeJob and activeJobView(activeJob) or nil,
    lastCompletion = lastCompletion,
  }
  local current = not state.disabledReason and currentBoard() or nil
  if current then
    for _, offer in ipairs(current.offers) do state.offers[#state.offers + 1] = offerView(offer, level) end
    state.filling = current.filling
  end
  if DEBUG_TOOLS then
    local _, tierByTag = loadRepoTiers()
    local tiers = {}
    for _, tier in ipairs(tow.VALUE_TIERS) do
      tiers[#tiers + 1] = { key = tier.key, label = tow.tierLabel(tierByTag[tier.key] and tierByTag[tier.key].tierLabel or tier.key) }
    end
    tiers[#tiers + 1] = { key = tow.HEAVY_TIER,
      label = tow.tierLabel(tierByTag[tow.HEAVY_TIER] and tierByTag[tow.HEAVY_TIER].tierLabel or "Heavy") }
    state.debug = {
      shortJobs = debugShortJobs,
      models = DEBUG_MODELS,
      tiers = tiers,
      faults = tow.FAULTS,
      mapId = levelId(),
      offerCount = current and #current.offers or 0,
      target = current and current.target or nil,
      nextOfferInS = current and current.nextOfferAt and math.max(0, (current.nextOfferAt - simMinutes) * 60) or nil,
    }
  end
  -- The next tier the player unlocks, for the app header.
  local tiers = loadRepoTiers()
  for _, tier in ipairs(tiers) do
    local unlockAt = tonumber(tier.skillUnlockLevel)
    if unlockAt and not tierUnlocked(tier, level)
      and (not state.nextUnlock or unlockAt < state.nextUnlock.level) then
      state.nextUnlock = { level = unlockAt, label = tier.tierLabel }
    end
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
-- Debug tools only: players may not reroll the board (spec: Problem).
local function refreshOffers()
  if not DEBUG_TOOLS then return false end
  local state = currentBoard()
  if not state then return false end
  local fresh = board.newState(simMinutes)
  state.offers, state.filling, state.target, state.nextOfferAt = {}, true, fresh.target, fresh.nextOfferAt
  routedOfferId = nil
  log("I", LOG_TAG, "offers refreshed")
  return true
end

-- Debug tools: a test tow offer placed near the player, for a vehicle model, a tier or both (nil or
-- "" for any) and a fault.
-- Console: towRepoHub_core.debugAddTowOffer("covet", "engine", "junkerVeh")
local function debugAddTowOffer(modelKey, fault, wantedTier)
  if not DEBUG_TOOLS then return { ok = false, reason = "Debug tools are off." } end
  if not tow.isFault(fault) then return { ok = false, reason = "Unknown fault: " .. tostring(fault) } end
  if modelKey == "" then modelKey = nil end
  if wantedTier == "" then wantedTier = nil end
  local state, fromPos, pool = currentBoard(), playerPosition(), getRepoPool()
  if not (state and fromPos and pool) then return { ok = false, reason = "No board, player or RLS data." } end
  local cache = currentMapCache()
  cache.eligibleVehicles = cache.eligibleVehicles or require("util/configListGenerator").getEligibleVehicles(false, false) or {}
  local matches = {}
  for _, info in ipairs(cache.eligibleVehicles) do
    local key = tow.tierKey(info)
    if key and (not modelKey or info.model_key == modelKey) and (not wantedTier or key == wantedTier) then
      matches[#matches + 1] = info
    end
  end
  if #matches == 0 then
    return { ok = false, reason = string.format("No tow vehicle for %s in %s.", modelKey or "any model", wantedTier or "any tier") }
  end

  local info = deepcopy(matches[math.random(#matches)])
  rollUsedCondition(info)
  -- A used vehicle may be worth less than its tier; the chosen tier still applies.
  local tierKey = wantedTier or tow.tierKey(info)
  local _, tierByTag = loadRepoTiers()
  if not tierByTag[tierKey] then return { ok = false, reason = "No tier data for " .. tostring(tierKey) .. "." } end
  local tier = tow.tierData(tierKey, tierByTag[tierKey])
  local destinations = towDestinations()
  local kind = tow.destinationKind(math.random, tow.isHeavy(info), #destinations.home > 0)
  if #destinations[kind] == 0 then return { ok = false, reason = "No destination on this map." } end

  local previous = debugShortJobs
  debugShortJobs = true
  local ok, offer = pcall(buildOffer, state, skillLevel(), fromPos, "tow", info, tierKey, tier,
    nearestEntry(destinations[kind], fromPos))
  debugShortJobs = previous
  if not ok then return { ok = false, reason = tostring(offer) } end
  if not offer then return { ok = false, reason = "No free parking spot near you." } end

  offer.destinationKind = kind
  -- Test offers are never locked, so tiers above the player's level (Heavy) can be tried.
  offer.unlockLevel, offer.unlockFlag = 0, nil
  offer.fault = fault
  offer.engineIntegrity = fault == "engine" and tow.engineIntegrity(math.random()) or nil
  offer.shabby = false
  offer.faultLabel = tow.faultLabel(fault)
  offer.id = nextOfferId
  nextOfferId = nextOfferId + 1
  offer.createdAt = simMinutes
  offer.expiresAt = simMinutes + board.ttl(math.random)
  offer.liveDistanceM = offer.outboundM
  offer.liveFrom = vecToArray(fromPos)
  if #state.offers >= board.config.size then table.remove(state.offers) end
  table.insert(state.offers, 1, offer)
  log("I", LOG_TAG, string.format("debug offer %d: %s %s [%s, %s] -> %s", offer.id, tostring(offer.brand),
    tostring(offer.name), offer.tierLabel or tierKey, offer.faultLabel, offer.destinationName))
  return { ok = true, label = string.format("%s %s (%s)", tostring(offer.brand), tostring(offer.name),
    tostring(offer.tierLabel or tierKey)) }
end

-- Debug tools: moves the player to the road next to a position, facing it. The vehicle is
-- not reset, so a trailer and its load stay as they are.
local function debugTeleportNear(pos)
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then return false end
  local target = pos
  local ok, _, nodeA, nodeB = pcall(map.findClosestRoad, pos)
  local nodes = ok and nodeA and map.getMap().nodes or nil
  if nodes and nodes[nodeA] then
    local a, b = nodes[nodeA].pos, nodes[nodeB] and nodes[nodeB].pos
    target = (b and b:distance(pos) < a:distance(pos)) and b or a
  end
  local dir = pos - target
  dir.z = 0
  local rot = dir:length() > 0.5 and quatFromDir(dir:normalized(), vec3(0, 0, 1)) or nil
  spawn.safeTeleport(vehicle, target + vec3(0, 0, 0.5), rot, nil, nil, nil, nil, false)
  return true
end

-- Debug tools: teleports to an offer's vehicle, or with no id to the active job's next stop.
local function debugTeleport(id)
  if not DEBUG_TOOLS then return false end
  local pos
  if id then
    local offer = findOffer(id)
    pos = offer and arrayToVec(offer.pickupPos)
  elseif activeJob then
    pos = arrayToVec(activeJob.custody and activeJob.dropPos or activeJob.pickupPos)
  end
  if not pos then return false end
  local ok, err = pcall(debugTeleportNear, pos)
  if not ok then log("W", LOG_TAG, "debug teleport failed: " .. tostring(err)) end
  return ok and err
end

-- Debug tools: see debugShortJobs.
local function setDebugShortJobs(enabled)
  if not DEBUG_TOOLS then return false end
  debugShortJobs = enabled == true
  log("I", LOG_TAG, "debug short jobs " .. (debugShortJobs and "on" or "off"))
  refreshOffers()
  return debugShortJobs
end

-- Debug tools: saves the career now, to test persistence.
local function debugSaveCareer()
  if not DEBUG_TOOLS then return false end
  local saveSystem = overhaul_career_saveSystem
  if not (saveSystem and saveSystem.saveCurrent) then return false end
  local accepted = saveSystem.saveCurrent(nil, { manual = true, force = true })
  log("I", LOG_TAG, "debug career save " .. (accepted and "requested" or "refused"))
  return accepted ~= false
end

-- Hooks ----------------------------------------------------------------------------------------------

local function onExtensionLoaded()
  readRlsVersion()
  local logbookFeed = tryRequire("overhaul/lib/progression/logbookFeed")
  if logbookFeed then
    recordJob = logbookFeed.register(LOGBOOK_ID,
      { title = "Tow job completed", label = "Jobs", icon = "carCoins" }, "towRepoHub/core.lua")
  end
  -- After a Lua reload the session file holds the state from just before it; otherwise, with a
  -- career already running, the career save does.
  if careerActive() then resumedFromSession = loadState() end
  log("I", LOG_TAG, "loaded")
end

local function onExtensionUnloaded()
  if careerActive() then
    local ok, err = pcall(function()
      local data = stateForSave()
      data.profile, data.savedAt = profileName(), os.time()
      if activeJob then parkJob(activeJob, true) end
      jsonWriteFile(SESSION_FILE, data, false)
    end)
    if not ok then log("W", LOG_TAG, "could not keep the state over the reload: " .. tostring(err)) end
    if activeJob then removeTargetVehicle(activeJob) end
  elseif activeJob then
    endJob(activeJob)
  end
end

local function onOverhaulSaveCurrentProfile(savePath, _, writer)
  if not savePath or not careerActive() then return end
  local ok, err = pcall(function()
    writer = writer or (overhaul_career_saveSystem and overhaul_career_saveSystem.getSaveWriter and overhaul_career_saveSystem.getSaveWriter())
    local dir = savePath .. SAVE_DIR
    if writer and writer.exists and not writer.exists(dir) then writer.mkdir(dir) end
    local data = stateForSave()
    if overhaul_career_saveSystem and overhaul_career_saveSystem.jsonWriteFileSafe then
      overhaul_career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_FILE, data, true)
    else
      jsonWriteFile(savePath .. SAVE_FILE, data, true)
    end
  end)
  if not ok then log("W", LOG_TAG, "saving failed: " .. tostring(err)) end
end

-- Career start or load: read this save's hub state. Right after a Lua reload the session state is
-- newer than the save, so the first activation keeps it.
local function onOverhaulModulesActivated()
  if resumedFromSession then resumedFromSession = false return end
  activeJob, boards, lastCompletion = nil, {}, nil
  simMinutes, nextOfferId = 0, 1
  loadState()
end

local function onOverhaulBeforeSetProfile()
  if activeJob then removeTargetVehicle(activeJob) end
  activeJob, boards, lastCompletion, restorePending = nil, {}, nil, false
end

local function onWorldReadyState(state)
  if state == 2 then
    unloading = false
    if activeJob and not activeJob.vehicleId then restorePending = true; restoreWaited = 0 end
  end
end

local function onClientStartMission()
  unloading = false
end
local function onUpdate(dtReal, dtSim)
  if not careerActive() then return end
  simMinutes = simMinutes + math.max(tonumber(dtSim) or 0, 0) / 60
  local dt = tonumber(dtReal) or 0
  if restorePending and not unloading then
    local ok, err = pcall(tryRestoreTarget, dt)
    if not ok then
      log("E", LOG_TAG, "restoring the job vehicle failed: " .. tostring(err))
      restorePending = false
    end
  end
  snapshotTimer = snapshotTimer + dt
  if snapshotTimer >= SNAPSHOT_S then
    snapshotTimer = 0
    if activeJob and activeJob.vehicleId then pcall(snapshotTarget, activeJob) end
  end
  jobTimer = jobTimer + dt
  if jobTimer >= JOB_TICK_S then
    jobTimer = 0
    local ok, err = pcall(updateJob)
    if not ok then log("E", LOG_TAG, "job update failed: " .. tostring(err)) end
  end
  stepGeneration()
  tickTimer = tickTimer + dt
  if tickTimer < TICK_S then return end
  tickTimer = 0
  local ok, err = pcall(tickBoard)
  if not ok then log("E", LOG_TAG, "board update failed: " .. tostring(err)) end
end

local function onVehicleDestroyed(vehicleId)
  if unloading then return end
  if activeJob and activeJob.vehicleId == vehicleId and not activeJob.completing then
    activeJob.vehicleId = nil
    failJob(activeJob, "destroyed")
  end
end

-- Map travel and level unload: the job pauses and its vehicle comes back when the player returns to
-- that map (onWorldReadyState). Its pose and carrier are captured before the level goes.
local function onClientEndMission()
  unloading = true
  if activeJob and activeJob.vehicleId then
    pcall(parkJob, activeJob, false)
    log("I", LOG_TAG, "level unloaded with an active job; it resumes on " .. tostring(activeJob.mapId))
  end
  generationCo, generationCo_state = nil, nil
  mapCache = {}
  routeCache = {}
end

local function onOverhaulActive(active)
  if not active then
    if activeJob then endJob(activeJob) end
    lastCompletion = nil
    generationCo, generationCo_state = nil, nil
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
M.debugAddTowOffer = debugAddTowOffer
M.debugTeleport = debugTeleport
M.debugSaveCareer = debugSaveCareer
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onClientEndMission = onClientEndMission
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulBeforeSetProfile = onOverhaulBeforeSetProfile
M.onWorldReadyState = onWorldReadyState
M.onClientStartMission = onClientStartMission
M.onOverhaulActive = onOverhaulActive

return M
