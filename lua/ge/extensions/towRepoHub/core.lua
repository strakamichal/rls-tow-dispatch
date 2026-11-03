-- Tow & Repo Hub game engine entry point (towRepoHub_core).
-- Keeps one offer board per map and answers the phone app. Repo offers only so far (spec step 3).
-- RLS calls go through guarded lookups: every RLS module used here is internal (docs/rls-integration.md).

local rlsVersion = require("towRepoHub/lib/rlsVersion")
local pricing = require("towRepoHub/lib/pricing")
local board = require("towRepoHub/lib/board")

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

-- Job types the board offers; tow joins in spec step 5.
local JOB_TYPES = { "repo" }

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

local function vehicleWeightKg(info)
  local weight = tonumber(info.Weight)
  if not weight and type(info.aggregates) == "table" and type(info.aggregates.Weight) == "table" then
    weight = tonumber(info.aggregates.Weight.min)
  end
  return weight
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

local function pickPickupSpot(state, fromPos, destPos)
  local spots = cityParkingSpots()
  local routeTries = 0
  for _ = 1, MAX_SPOT_TRIES do
    if #spots == 0 then return nil end
    local spot = spots[math.random(#spots)]
    local key = spotKey(spot)
    if not board.isSpotTaken(state, key) and spot.pos:distance(fromPos) >= MIN_PICKUP_FROM_PLAYER_M then
      routeTries = routeTries + 1
      local loaded = routeDistance(spot.pos, destPos)
      if loaded >= MIN_LOADED_ROUTE_M and spotIsFree(spot) then return spot, loaded end
      if routeTries >= MAX_ROUTE_TRIES then return nil end
    end
  end
  return nil
end

local function generateRepoOffer(state, level, fromPos)
  local byDealership = repoCandidatesByDealership(level)
  if #byDealership == 0 then return nil end
  local entry = byDealership[math.random(#byDealership)]
  local pool = getRepoPool()

  local info = pool.pickWeightedRepoVehicleInfo(entry.candidates)
  local tier = info and pool.getRepoTagData(info.repoTag)
  if not tier then return nil end

  local usedCondition = tryRequire("overhaul/lib/market/usedVehicleCondition")
  if usedCondition and not usedCondition.generateUsedVehicleCondition({ id = "private", salesChannel = "local" }, info) then
    return nil
  end

  local dropSpot = entry.dropSpots[math.random(#entry.dropSpots)]
  local spot, loadedM = pickPickupSpot(state, fromPos, dropSpot.pos)
  if not spot then return nil end
  local outboundM = routeDistance(fromPos, spot.pos)

  local quote = pricing.quote({
    outboundKm = outboundM / 1000, loadedKm = loadedM / 1000, level = level,
    tierMultiplier = tier.payMultiplier, jobType = "repo",
    economy = economy("repo"), recoveryEconomy = economy("offroadRecovery"),
  })

  return {
    jobType = "repo",
    tierTag = info.repoTag,
    tierLabel = tier.tierLabel or info.repoTierLabel,
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
    destinationId = entry.dealership.id,
    destinationName = entry.dealership.name or tostring(entry.dealership.id),
    dropSpotName = dropSpot.name,
    dropPos = vecToArray(dropSpot.pos),
    outboundM = outboundM,
    loadedM = loadedM,
    quote = quote,
  }
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
  local ok, candidate, relaxed = pcall(board.pick, function() return generateRepoOffer(state, level, fromPos) end,
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
  state.offers[#state.offers + 1] = candidate
  log("I", LOG_TAG, string.format("offer %d: %s %s %s -> %s, %.1f + %.1f km, %d (relaxed %d, %.0f ms)",
    candidate.id, candidate.tierLabel or "?", tostring(candidate.brand), tostring(candidate.name),
    candidate.destinationName, candidate.outboundM / 1000, candidate.loadedM / 1000, candidate.quote,
    relaxed or 0, elapsedMs))
  return true
end

local function tickBoard()
  if boardDisabledReason() then return end
  local state = currentBoard()
  if not state then return end
  local open = board.expire(state.offers, simMinutes)
  state.offers = open
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

-- Phone app API ----------------------------------------------------------------------------------------

-- Distances are the road routes the quote was made from; they stay fixed like the quote.
local function offerView(offer)
  return {
    id = offer.id,
    jobType = offer.jobType,
    tierTag = offer.tierTag,
    tierLabel = offer.tierLabel,
    vehicle = { brand = offer.brand, name = offer.name, year = offer.year },
    weightKg = offer.weightKg,
    distanceToVehicleM = offer.outboundM,
    outboundM = offer.outboundM,
    loadedM = offer.loadedM,
    destinationName = offer.destinationName,
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
  if not routeLease then
    local lease = tryRequire("overhaul/lib/activity/routeLease")
    routeLease = lease and lease.new(LOG_TAG)
  end
  if not routeLease then return false end
  routeLease.set(arrayToVec(offer.pickupPos), { clearPathOnReachingTarget = true })
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

-- Hooks ----------------------------------------------------------------------------------------------

local function onExtensionLoaded()
  readRlsVersion()
  log("I", LOG_TAG, "loaded")
end

local function onUpdate(dtReal, dtSim)
  if not careerActive() then return end
  simMinutes = simMinutes + math.max(tonumber(dtSim) or 0, 0) / 60
  tickTimer = tickTimer + (tonumber(dtReal) or 0)
  if tickTimer < TICK_S then return end
  tickTimer = 0
  tickBoard()
end

local function onClientEndMission()
  mapCache = {}
  routeCache = {}
end

local function onOverhaulActive(active)
  if not active then
    boards = {}
    mapCache = {}
    routeCache = {}
  end
end

M.getState = getState
M.routeToOffer = routeToOffer
M.resetBoard = resetBoard
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onClientEndMission = onClientEndMission
M.onOverhaulActive = onOverhaulActive

return M
