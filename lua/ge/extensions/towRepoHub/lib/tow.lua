-- Tow job rules: vehicle eligibility, value tiers, faults and destination kinds.
-- Pure functions, no game API, so they run under plain LuaJIT in tests.
-- See docs/spec.md, sections Tiers, Tow faults and Destinations.

local M = {}

M.config = {
  heavyWeightKg = 3500,
  minPlausibleValue = 500,
  maxPlausibleValue = 10000000,
  wornChance = 0.3,
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

M.FAULTS = { "fuel", "flat", "overheat" }
M.FAULT_LABELS = {
  fuel = "Nearly empty tank",
  flat = "Flat tyre",
  overheat = "Overheating",
  worn = "Worn",
}

local VEHICLE_TYPES = { Car = true, Truck = true, Bus = true }
local BLOCKED_MODELS = { atv = true, wl40 = true, frameless_dump = true }
local MISSION_CONFIG_TYPES = { roleplay = true, police = true }

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

function M.isHeavy(info)
  local weight = M.weightKg(info)
  local vehicleType = M.vehicleType(info)
  return (weight ~= nil and weight > M.config.heavyWeightKg) or vehicleType == "Truck" or vehicleType == "Bus"
end

-- A common road vehicle with a plausible catalogue value.
function M.isEligible(info)
  if type(info) ~= "table" or not VEHICLE_TYPES[M.vehicleType(info)] then return false end
  if BLOCKED_MODELS[info.model_key] then return false end
  local configTypes = metadataText(info, { "Config Type", "configType" })
  for word in configTypes:gmatch("%S+") do
    if MISSION_CONFIG_TYPES[word] then return false end
  end
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

-- One drivable fault, sometimes combined with wear. Electric vehicles only get flat tyres.
-- random() returns a number in [0, 1).
function M.pickFaults(random, electric)
  local primary
  if electric then
    primary = "flat"
  else
    primary = M.FAULTS[math.floor(random() * #M.FAULTS) + 1]
  end
  local faults = { primary }
  if random() < M.config.wornChance then faults[#faults + 1] = "worn" end
  return faults
end

function M.faultLabel(faults)
  local labels = {}
  for _, fault in ipairs(faults or {}) do labels[#labels + 1] = M.FAULT_LABELS[fault] or fault end
  return table.concat(labels, ", ")
end

-- "home" (an unowned garage) or "service" (a dealership). Heavy vehicles never go to garages.
function M.destinationKind(random, heavy, hasGarages)
  if heavy or not hasGarages then return "service" end
  return random() < M.config.homeChance and "home" or "service"
end

return M
