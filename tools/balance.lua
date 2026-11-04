-- Compares tow pay per minute with RLS repo, Job Broker vehicle and trailer deliveries and
-- Off-Road Recovery. RLS formulas are copied from RLS 2.8 (jobs/repo.lua calculateReward,
-- lib/logistics/logisticsBalance.lua, career/logistics/vehicleTasks/rewards.lua,
-- jobs/recovery/rewards.lua, gameplay/overhaul/delivery/rlsvehicles.deliveryVehicles.json);
-- update them when RLS pay changes. Drive and load times are a model, not measurements.
-- Run from the repo root: luajit tools/balance.lua [loaded km]

package.path = "lua/ge/extensions/?.lua;" .. package.path
local pricing = require("towRepoHub/lib/pricing")
local tow = require("towRepoHub/lib/tow")

local OUTBOUND_KM = 2
local LOADED_KM = tonumber(arg[1]) or 6
local LEVELS = { 10, 25, 48 }

-- Speeds in km/h and fixed steps in minutes.
local CAR_KMH, TRUCK_KMH, TOWING_KMH = 60, 55, 45
local LOAD_MIN, STOP_MIN, SPAWN_MIN, PARK_MIN = 3, 0.5, 0.5, 0.5
local OFFROAD_KMH, OFFROAD_LOADED_KMH, EXTRACT_MIN = 40, 35, 8
local COUPLE_MIN, UNCOUPLE_MIN = 1, 1

-- RLS tier: unlock level, repo pay multiplier, a typical vehicle value, Job Broker 4-mile pay.
local CLASSES = {
  { key = "junkerVeh", label = "Low Value", level = 1, repo = 1.0, value = 12000, broker = 500 },
  { key = "smallVeh", label = "Budget", level = 5, repo = 1.0, value = 35000, broker = 750 },
  { key = "fleetVeh", label = "Standard", level = 10, repo = 1.15, value = 70000, broker = 1250 },
  { key = "highEndVeh", label = "Luxury", level = 15, repo = 1.35, value = 140000, broker = 2000 },
  { key = "exoticVeh", label = "Exotic", level = 20, repo = 1.6, value = 300000, broker = 3250 },
  { key = "heavyVeh", label = "Heavy", level = 25, repo = 1.8, value = 150000, broker = 4000 },
}

-- Job Broker trailer groups: 4-mile pay, a typical loaded filter's baseReward and rewardPerKm,
-- and the speed with the trailer. Hauled with the player's own vehicle, so there is no trip back.
-- Logistics unlock levels from TRAILER_XP_LEVEL_BY_GROUP in lib/logistics/calculators.lua.
local TRAILERS = {
  { label = "Small (TSFB, box)", level = 1, pay = 750, base = 275, perKm = 250, kmh = 55 },
  { label = "Medium (cargo, tilt)", level = 4, pay = 1500, base = 1100, perKm = 315, kmh = 50 },
  { label = "Heavy hitch", level = 6, pay = 3000, base = 1500, perKm = 450, kmh = 50 },
  { label = "Dry van", level = 10, pay = 4000, base = 2300, perKm = 800, kmh = 45 },
  { label = "Flatbed semi", level = 13, pay = 4250, base = 2700, perKm = 1000, kmh = 45 },
  { label = "Tanker", level = 19, pay = 4700, base = 3300, perKm = 1200, kmh = 45 },
  { label = "Container", level = 22, pay = 4850, base = 3600, perKm = 1250, kmh = 45 },
  { label = "Log trailer", level = 25, pay = 5000, base = 4300, perKm = 1400, kmh = 45 },
}
local BROKER_REFERENCE_KM = 4 * 1.609344
local BROKER_BASE_PAY_MULTIPLIER = 1.5

local function minutes(km, kmh) return km / kmh * 60 end

local function towJob(class, level)
  local quote = pricing.quote({
    outboundKm = OUTBOUND_KM, loadedKm = LOADED_KM, level = level,
    tierMultiplier = tow.TIER_PAY[class.key], jobType = "tow", economy = 1,
  })
  return quote, minutes(OUTBOUND_KM, TRUCK_KMH) + LOAD_MIN + minutes(LOADED_KM, TOWING_KMH) + STOP_MIN
end

-- RLS repo counts the route to the car and the loaded route as distance, but the clock only
-- from when the car first moves, so its "speed" term is total distance over loaded time.
local function repoJob(class, level)
  local metres = (OUTBOUND_KM + LOADED_KM) * 1000
  local loadedSeconds = minutes(LOADED_KM, CAR_KMH) * 60
  local speedTerm = metres / (loadedSeconds * 10)
  local foundation = math.floor(((5 * math.sqrt(class.value) + 2 * metres) * speedTerm) / 4) / 15
  local pay = (foundation + 500) * class.repo * (1 + pricing.repoSkillBonus(level))
  return pay, minutes(OUTBOUND_KM, CAR_KMH) + SPAWN_MIN + minutes(LOADED_KM, CAR_KMH) + PARK_MIN
end

-- No damage and no detour; the on-time bonus only when the job beats RLS's expected time
-- (offer distance at 12 m/s plus 30 s), timed from accepting it. Logistics at the same level
-- as Recovery.
local function withBrokerBonuses(base, level, jobMinutes)
  local levelBonus = math.max(0, math.min(20, level - 30)) * 0.05
  local bonusCount = 1
  if jobMinutes * 60 < LOADED_KM * 1000 / 12 + 30 then bonusCount = 2 end
  return (base * 1.05 + bonusCount * (base * 0.15 + 10)) * (1 + levelBonus)
end

-- Vehicle filters have no baseReward, so their pay is linear in distance.
local function brokerJob(class, level, walkBack)
  local base = class.broker * BROKER_BASE_PAY_MULTIPLIER * LOADED_KM / BROKER_REFERENCE_KM
  local time = minutes(OUTBOUND_KM, CAR_KMH) + SPAWN_MIN + minutes(LOADED_KM, CAR_KMH) + PARK_MIN
  local pay = withBrokerBonuses(base, level, time)
  if walkBack then time = time + minutes(LOADED_KM, CAR_KMH) end
  return pay, time
end

-- Trailer filters have a baseReward, so short deliveries keep much of the 4-mile pay.
-- With a loaner from the depot the organisation takes about half; not modelled.
local function trailerJob(trailer, level)
  local share = (trailer.base + trailer.perKm * LOADED_KM) / (trailer.base + trailer.perKm * BROKER_REFERENCE_KM)
  local time = minutes(OUTBOUND_KM, TRUCK_KMH) + COUPLE_MIN + minutes(LOADED_KM, trailer.kmh) + UNCOUPLE_MIN
  return withBrokerBonuses(trailer.pay * BROKER_BASE_PAY_MULTIPLIER * share, level, time), time
end

local function offroadJob(level)
  local fee = level >= 30 and 3000 or (level >= 10 and 1500 or 0)
  local p = math.max(0, math.min(22, math.floor((math.max(1, level) - 5) / 2))) / 22
  local pay = (1500 + 100 * OUTBOUND_KM + 250 * LOADED_KM + fee) * (1 + 2 * p * p)
  return pay, minutes(OUTBOUND_KM, OFFROAD_KMH) + EXTRACT_MIN + minutes(LOADED_KM, OFFROAD_LOADED_KMH)
end

local function perMinute(pay, time) return pay / time end

print(string.format("Pay per minute (pay per job); %g km to the car, %g km loaded", OUTBOUND_KM, LOADED_KM))
for _, level in ipairs(LEVELS) do
  print(string.format("\nRecovery and Logistics level %d; Off-Road Recovery %.0f/min",
    level, perMinute(offroadJob(level))))
  print(string.format("%-10s %15s %15s %15s %15s %8s %8s", "Tier", "Tow", "Repo", "Broker+back", "Broker",
    "Tow/Repo", "Tow/Brk"))
  for _, class in ipairs(CLASSES) do
    if class.level <= level then
      local tp, tt = towJob(class, level)
      local rp, rt = repoJob(class, level)
      local bp, bt = brokerJob(class, level, true)
      local jp, jt = brokerJob(class, level, false)
      print(string.format("%-10s %6.0f (%6.0f) %6.0f (%6.0f) %6.0f (%6.0f) %6.0f (%6.0f) %8.2f %8.2f",
        class.label, tp / tt, tp, rp / rt, rp, bp / bt, bp, jp / jt, jp,
        perMinute(tp, tt) / perMinute(rp, rt), perMinute(tp, tt) / perMinute(jp, jt)))
    end
  end
  local trailerRows = {}
  for _, trailer in ipairs(TRAILERS) do
    if trailer.level <= level then
      local pay, time = trailerJob(trailer, level)
      trailerRows[#trailerRows + 1] = string.format("%s %.0f (%.0f)", trailer.label, pay / time, pay)
    end
  end
  print("Broker trailers, own vehicle: " .. table.concat(trailerRows, ", "))
end
