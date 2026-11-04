-- Compares tow pay per minute with RLS repo, Job Broker vehicle delivery and Off-Road Recovery.
-- RLS formulas are copied from RLS 2.8 (jobs/repo.lua calculateReward, lib/logistics/
-- logisticsBalance.lua, career/logistics/vehicleTasks/rewards.lua, jobs/recovery/rewards.lua);
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

-- RLS tier: unlock level, repo pay multiplier, a typical vehicle value, Job Broker 4-mile pay.
local CLASSES = {
  { key = "junkerVeh", label = "Low Value", level = 1, repo = 1.0, value = 12000, broker = 500 },
  { key = "smallVeh", label = "Budget", level = 5, repo = 1.0, value = 35000, broker = 750 },
  { key = "fleetVeh", label = "Standard", level = 10, repo = 1.15, value = 70000, broker = 1250 },
  { key = "highEndVeh", label = "Luxury", level = 15, repo = 1.35, value = 140000, broker = 2000 },
  { key = "exoticVeh", label = "Exotic", level = 20, repo = 1.6, value = 300000, broker = 3250 },
  { key = "heavyVeh", label = "Heavy", level = 25, repo = 1.8, value = 150000, broker = 4000 },
}

local function minutes(km, kmh) return km / kmh * 60 end

local function towJob(class, level)
  local quote = pricing.quote({
    outboundKm = OUTBOUND_KM, loadedKm = LOADED_KM, level = level,
    tierMultiplier = tow.TIER_PAY[class.key], jobType = "tow", economy = 1,
  })
  return quote, minutes(OUTBOUND_KM, TRUCK_KMH) + LOAD_MIN + minutes(LOADED_KM, TOWING_KMH) + STOP_MIN
end

local function repoJob(class, level)
  local metres, speed = LOADED_KM * 1000, CAR_KMH / 3.6
  local foundation = math.floor(((5 * math.sqrt(class.value) + 2 * metres) * (speed / 10)) / 4) / 15
  local pay = (foundation + 500) * class.repo * (1 + pricing.repoSkillBonus(level))
  return pay, minutes(OUTBOUND_KM, CAR_KMH) + SPAWN_MIN + minutes(LOADED_KM, CAR_KMH) + PARK_MIN
end

-- Best case: no damage, no detour and on time; Logistics at the same level as Recovery.
local function brokerJob(class, level, walkBack)
  local base = class.broker * 1.5 * LOADED_KM / (4 * 1.609344)
  local levelBonus = math.max(0, math.min(20, level - 30)) * 0.05
  local pay = (base * 1.05 + 2 * (base * 0.15 + 10)) * (1 + levelBonus)
  local time = minutes(OUTBOUND_KM, CAR_KMH) + SPAWN_MIN + minutes(LOADED_KM, CAR_KMH) + PARK_MIN
  if walkBack then time = time + minutes(LOADED_KM, CAR_KMH) end
  return pay, time
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
end
