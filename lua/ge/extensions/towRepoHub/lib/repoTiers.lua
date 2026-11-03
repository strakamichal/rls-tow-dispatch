-- Repo tiers for every tier, unlocked or not. RLS only hands out repo vehicles for unlocked
-- tiers, but the board also shows locked offers, so the hub classifies vehicles itself with the
-- same rules as RLS 2.8 jobs/repo/vehiclePool.lua (see docs/rls-integration.md 4.1, 4.2).
-- Pure functions, no game API, so they run under plain LuaJIT in tests.

local M = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for k, v in pairs(value) do result[k] = copy(v) end
  return result
end

-- Merges `extra` into `base` (a copy), recursing into tables; lists are replaced.
local function merged(base, extra)
  local result = copy(base or {})
  for k, v in pairs(extra or {}) do
    if type(v) == "table" and type(result[k]) == "table" and v[1] == nil then
      result[k] = merged(result[k], v)
    else
      result[k] = copy(v)
    end
  end
  return result
end

-- Tier configs from repoVehicleFilters.json: vehicle tiers only, with RLS defaults, highest
-- priority first. Each keeps its JSON key as `id` and its lookup key as `unlockTag`.
function M.normalize(raw)
  local tiers = {}
  for id, entry in pairs(raw or {}) do
    if type(entry) == "table" and entry.type == "vehicle" then
      local tier = copy(entry)
      tier.id = id
      tier.unlockTag = tier.unlockTag or id
      tier.priority = tonumber(tier.priority) or 0
      tier.skillUnlockLevel = tonumber(tier.skillUnlockLevel) or 50
      tier.payMultiplier = tonumber(tier.payMultiplier) or 1
      tier.baseXp = tonumber(tier.baseXp) or 0
      tier.tierLabel = tier.tierLabel or tier.filterName or tier.unlockTag
      tiers[#tiers + 1] = tier
    end
  end
  table.sort(tiers, function(a, b)
    if a.priority ~= b.priority then return a.priority > b.priority end
    return tostring(a.id) < tostring(b.id)
  end)
  return tiers
end

local function aggregate(info, key)
  return type(info.aggregates) == "table" and info.aggregates[key] or nil
end

local function numberField(info, key)
  local direct = tonumber(info[key])
  if direct then return direct end
  local agg = aggregate(info, key)
  return type(agg) == "table" and tonumber(agg.min) or nil
end

local function yearsRange(info)
  for _, years in ipairs({ info.Years, aggregate(info, "Years") }) do
    if type(years) == "table" then
      local low, high = tonumber(years.min), tonumber(years.max)
      if low and high and low <= high then return low, high end
    end
  end
end

-- Every entry of a whiteList or blackList must match. A missing field never matches.
function M.passesList(info, filters)
  if type(info) ~= "table" or type(filters) ~= "table" then return false end
  for name, rule in pairs(filters) do
    if name == "Years" then
      local low, high = yearsRange(info)
      if not low then return false end
      if rule.min ~= nil and (not tonumber(rule.min) or high < tonumber(rule.min)) then return false end
      if rule.max ~= nil and (not tonumber(rule.max) or low > tonumber(rule.max)) then return false end
    elseif name ~= "Mileage" then
      if type(rule) ~= "table" then return false end
      if rule.min ~= nil or rule.max ~= nil then
        local value = numberField(info, name)
        if not value then return false end
        if rule.min ~= nil and (not tonumber(rule.min) or value < tonumber(rule.min)) then return false end
        if rule.max ~= nil and (not tonumber(rule.max) or value > tonumber(rule.max)) then return false end
      else
        local agg = aggregate(info, name)
        local found = false
        for _, option in ipairs(rule) do
          if info[name] == option or (type(agg) == "table" and agg[option]) then
            found = true
            break
          end
        end
        if not found then return false end
      end
    end
  end
  return true
end

function M.passes(info, filter)
  if type(filter) ~= "table" then return false end
  if filter.whiteList and not M.passesList(info, filter.whiteList) then return false end
  if filter.blackList and M.passesList(info, filter.blackList) then return false end
  return true
end

-- A tier matches when its base filter passes, and with sub-filters when any base + sub passes.
function M.matchesTier(info, tier)
  local base = tier.filter or {}
  if not M.passes(info, base) then return false end
  local subs = tier.subFilters
  if type(subs) ~= "table" or next(subs) == nil then return true end
  for _, sub in ipairs(subs) do
    if type(sub) == "table" and M.passes(info, merged(base, sub)) then return true end
  end
  return false
end

-- The highest-priority tier the vehicle matches, ignoring unlocks; nil when none.
function M.tierFor(info, tiers)
  for _, tier in ipairs(tiers) do
    if M.matchesTier(info, tier) then return tier end
  end
end

-- The dealership's vehicle filters, each with a `probability`. An organisation's reputation
-- level overrides the dealership filter as in RLS (levels[reputation + 2]).
function M.dealershipFilters(dealership, organization)
  local filter = dealership and dealership.filter or {}
  local subs = dealership and dealership.subFilters or {}
  if organization and type(organization.reputationLevels) == "table" then
    local level = organization.reputation and tonumber(organization.reputation.level) or 0
    local data = organization.reputationLevels[level + 2]
    if data and data.filter then filter = data.filter end
    if data and data.subFilters then subs = data.subFilters end
  end
  local result = {}
  if type(subs) == "table" and next(subs) ~= nil then
    for _, sub in ipairs(subs) do
      local variant = merged(filter, sub)
      variant.probability = type(sub.probability) == "number" and sub.probability or 1
      result[#result + 1] = variant
    end
  else
    local variant = copy(filter)
    variant.probability = 1
    result[1] = variant
  end
  return result
end

return M
