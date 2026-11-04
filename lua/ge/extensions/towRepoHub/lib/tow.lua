-- Tow job rules: vehicle eligibility, value tiers, faults and destination kinds.
-- Pure functions, no game API, so they run under plain LuaJIT in tests.
-- See docs/spec.md, sections Tiers, Tow faults and Destinations.

local M = {}

M.config = {
  heavyWeightKg = 3500,
  -- Heavier vehicles do not fit a tow truck or a car trailer.
  maxWeightKg = 9000,
  minPlausibleValue = 500,
  maxPlausibleValue = 10000000,
  -- Chance of a tired look (paint and appearance only) on top of the fault.
  shabbyChance = 0.4,
  -- Engine integrity for "Failing engine", from an occasional cough (mild) to stalling all the time
  -- (severe). The game turns lower integrity into misfires and an unstable idle.
  engineIntegrityMild = 0.5,
  engineIntegritySevere = 0.3,
  homeChance = 0.5,
}

-- Value bands mapped to the RLS repo tiers in repoVehicleFilters.json, so tow uses the same
-- unlock levels, pay multipliers and base XP. Keys are the tiers' unlockTag values, which is how
-- the RLS repo pool looks them up (getRepoTagData).
M.VALUE_TIERS = {
  { key = "junkerVeh", below = 25000 },
  { key = "smallVeh", below = 50000 },
  { key = "fleetVeh", below = 100000 },
  { key = "highEndVeh", below = 200000 },
  { key = "exoticVeh", below = math.huge },
}
M.HEAVY_TIER = "heavyVeh"

-- Tow pay and XP per tier. RLS gives Low Value and Budget the same pay multiplier and Budget less
-- base XP, so unlocking Budget would bring nothing; tow uses its own ladder instead. A 6 km tow pays
-- about 1.1-1.3x RLS repo of the same tier per minute, and the top tiers step up faster so Exotic
-- and Heavy pay close to RLS Job Broker deliveries of the same class (tools/balance.lua). Unlock levels
-- still come from RLS.
M.TIER_PAY = { junkerVeh = 1.3, smallVeh = 1.5, fleetVeh = 1.7, highEndVeh = 2.0, exoticVeh = 2.4, heavyVeh = 2.85 }
M.TIER_BASE_XP = { junkerVeh = 300, smallVeh = 350, fleetVeh = 500, highEndVeh = 900, exoticVeh = 1400, heavyVeh = 1800 }

-- The RLS tier data with the tow pay multiplier, base XP and label applied.
function M.tierData(tierKey, rlsTier)
  local tier = {}
  for k, v in pairs(rlsTier or {}) do tier[k] = v end
  tier.payMultiplier = M.TIER_PAY[tierKey] or tier.payMultiplier or 1
  tier.baseXp = M.TIER_BASE_XP[tierKey] or tier.baseXp or 0
  tier.tierLabel = M.tierLabel(tier.tierLabel)
  return tier
end

-- One fault per job, so the player can tell what is wrong with the vehicle.
M.FAULTS = { "fuel", "flat", "overheat", "engine" }
M.FAULT_LABELS = {
  fuel = "Nearly empty tank",
  flat = "Flat tyre",
  overheat = "Overheating",
  engine = "Failing engine",
}

-- Buses do not fit a tow truck or a trailer, so tow takes cars and trucks only.
local VEHICLE_TYPES = { Car = true, Truck = true }
-- Off-road machines and semi tractors, which no tow truck or car trailer carries.
local BLOCKED_MODELS = { atv = true, wl40 = true, frameless_dump = true, us_semi = true, citybus = true }
local MISSION_CONFIG_TYPES = { roleplay = true, police = true }
-- Trucks the RLS heavy repo tier lists by model, whatever their configuration weighs.
local HEAVY_MODELS = { md_series = true, midtruck = true }

local function numberOrMin(info, key)
  local value = tonumber(info[key])
  if value then return value end
  local aggregate = type(info.aggregates) == "table" and info.aggregates[key]
  return type(aggregate) == "table" and tonumber(aggregate.min) or nil
end

-- Collects the lower-case strings of a metadata field: a string, a list or an aggregate set.
local function metadataText(info, keys)
  local parts = {}
  local function add(value)
    if type(value) == "string" then
      parts[#parts + 1] = value:lower()
    elseif type(value) == "table" then
      for k, v in pairs(value) do
        if type(k) == "string" and v == true then parts[#parts + 1] = k:lower() end
        if type(v) == "string" then parts[#parts + 1] = v:lower() end
      end
    end
  end
  for _, key in ipairs(keys) do
    add(info[key])
    if type(info.aggregates) == "table" then add(info.aggregates[key]) end
  end
  return table.concat(parts, " ")
end

-- The vehicle type, from the field or the aggregate set, as RLS filters read it.
function M.vehicleType(info)
  if type(info.Type) == "string" then return info.Type end
  local types = type(info.aggregates) == "table" and info.aggregates.Type
  if type(types) == "table" then
    for _, name in ipairs({ "Car", "Truck", "Bus" }) do
      if types[name] then return name end
    end
    for name, present in pairs(types) do
      if present == true then return name end
    end
  end
  return nil
end

function M.value(info)
  return numberOrMin(info, "Value")
end

function M.weightKg(info)
  return numberOrMin(info, "Weight")
end

function M.isElectric(info)
  local text = metadataText(info, { "Fuel Type", "FuelType", "fuelType", "Powertrain", "Propulsion" })
  return text:find("electric", 1, true) ~= nil or text:find("hybrid", 1, true) ~= nil
end

-- Heavy means really heavy: over heavyWeightKg or a medium-duty truck model. The game types
-- pickups and SUVs as "Truck" too, so the type alone does not make a vehicle heavy.
function M.isHeavy(info)
  local weight = M.weightKg(info)
  return (weight ~= nil and weight > M.config.heavyWeightKg) or HEAVY_MODELS[info.model_key] == true
end

-- A configuration without an engine, such as a rolling chassis: it cannot be a broken-down car.
function M.hasNoEngine(info)
  local name = metadataText(info, { "Name", "Configuration" })
  if name:find("rolling chassis", 1, true) or name:find("(n/a)", 1, true) then return true end
  local power = numberOrMin(info, "Power")
  return power ~= nil and power <= 0
end

-- A common road vehicle with an engine, a plausible catalogue value and a weight a tow truck carries.
function M.isEligible(info)
  if type(info) ~= "table" or not VEHICLE_TYPES[M.vehicleType(info)] then return false end
  if BLOCKED_MODELS[info.model_key] then return false end
  if M.hasNoEngine(info) then return false end
  local weight = M.weightKg(info)
  if weight ~= nil and weight > M.config.maxWeightKg then return false end
  local configTypes = metadataText(info, { "Config Type", "configType" })
  for word in configTypes:gmatch("%S+") do
    if MISSION_CONFIG_TYPES[word] then return false end
  end
  -- RLS Joe's Junk career configs are not traffic vehicles (RLS repo gives them their own tier).
  if configTypes:find("joesjunk", 1, true) then return false end
  local value = M.value(info)
  return value ~= nil and value >= M.config.minPlausibleValue and value <= M.config.maxPlausibleValue
end

-- The RLS repo tier key for a tow vehicle, by value only; heavy vehicles get the heavy tier.
function M.tierKey(info)
  if not M.isEligible(info) then return nil end
  if M.isHeavy(info) then return M.HEAVY_TIER end
  local value = M.value(info)
  for _, tier in ipairs(M.VALUE_TIERS) do
    if value < tier.below then return tier.key end
  end
end

-- "Low Value Repo" -> "Low Value Tow".
function M.tierLabel(repoLabel)
  local label = tostring(repoLabel or "")
  local replaced, count = label:gsub("%s*[Rr]epo$", " Tow")
  if count == 0 then replaced = label .. " Tow" end
  return (replaced:gsub("^%s+", ""))
end

function M.isFault(fault)
  return M.FAULT_LABELS[fault] ~= nil
end

-- Engine integrity for a "Failing engine" severity in [0, 1] (0 mild, 1 severe), two decimals.
function M.engineIntegrity(severity)
  local s = math.max(0, math.min(1, tonumber(severity) or 0))
  local cfg = M.config
  local value = cfg.engineIntegrityMild + (cfg.engineIntegritySevere - cfg.engineIntegrityMild) * s
  return math.floor(value * 100 + 0.5) / 100
end

-- The vehicle's condition for a tow job: one fault, the engine integrity (only for "engine") and
-- an optional tired look. Electric vehicles only get flat tyres. random() returns a number in [0, 1).
function M.pickCondition(random, electric)
  local fault = electric and "flat" or M.FAULTS[math.floor(random() * #M.FAULTS) + 1]
  return {
    fault = fault,
    engineIntegrity = fault == "engine" and M.engineIntegrity(random()) or nil,
    shabby = random() < M.config.shabbyChance,
  }
end

function M.faultLabel(fault)
  return M.FAULT_LABELS[fault] or tostring(fault)
end

-- "home" (an unowned garage) or "service" (a dealership). Heavy vehicles never go to garages.
function M.destinationKind(random, heavy, hasGarages)
  if heavy or not hasGarages then return "service" end
  return random() < M.config.homeChance and "home" or "service"
end

return M
