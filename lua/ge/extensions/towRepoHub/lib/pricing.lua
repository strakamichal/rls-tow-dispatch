-- Quotes, XP, settlement and fines for hub jobs. Pure functions, no game API,
-- so they run under plain LuaJIT in tests. See docs/spec.md, sections Pricing and XP.

local M = {}

M.config = {
  callout = 400,
  outboundPerKm = 55,
  loadedPerKm = 135,
  jobTypeFactor = { tow = 1.1, repo = 1.0 },
  recoveryCapShare = 0.9,
  fineBase = 1000,
}

-- Off-Road Recovery reference values from RLS 2.8 jobs/recovery/rewards.lua.
local RECOVERY = {
  callout = 1500,
  outboundPerKm = 100,
  loadedPerKm = 250,
}

local MAX_SKILL_LEVEL = 50

local function round(x)
  return math.floor(x + 0.5)
end

local function clamp(x, lo, hi)
  return math.max(lo, math.min(hi, x))
end

-- NaN and infinities become the fallback; damage values come from divisions in game data.
local function finite(x, fallback)
  x = tonumber(x)
  if not x or x ~= x or x == math.huge or x == -math.huge then return fallback end
  return x
end

local function distanceKm(km)
  return math.max(0, finite(km, 0))
end

local function skillLevel(level)
  return clamp(math.floor(finite(level, 0)), 0, MAX_SKILL_LEVEL)
end

-- A missing tier multiplier means the caller failed to load tier data; fail loudly.
local function tierMultiplierOf(value)
  local multiplier = finite(value, nil)
  if not multiplier or multiplier <= 0 then error("invalid tier multiplier: " .. tostring(value)) end
  return multiplier
end

local function economyOf(value)
  return math.max(0, finite(value, 1))
end

local function jobTypeFactor(jobType)
  local factor = M.config.jobTypeFactor[jobType]
  if not factor then error("unknown job type: " .. tostring(jobType)) end
  return factor
end

-- Same curve as RLS repo (jobs/repo/vehiclePool.lua): +1/6 every two levels, +400 % at level 48.
function M.repoSkillBonus(level)
  local steps = clamp(math.floor(skillLevel(level) / 2), 0, 24)
  return 4 * steps / 24
end

-- Same curve as RLS Off-Road Recovery (jobs/recovery/vehiclePool.lua): quadratic, +200 % at level 49.
function M.recoverySkillBonus(level)
  local clamped = clamp(skillLevel(level), 1, MAX_SKILL_LEVEL)
  local steps = clamp(math.floor((clamped - 5) / 2), 0, 22)
  local progress = steps / 22
  return 2 * progress * progress
end

-- The best recovery difficulty fee a player of this level can reach.
function M.recoveryDifficultyFee(level)
  local clamped = skillLevel(level)
  if clamped >= 30 then return 3000 end
  if clamped >= 10 then return 1500 end
  return 0
end

-- Recovery quote before the economy multiplier, used as the cap reference.
function M.recoveryQuote(outboundKm, loadedKm, level)
  local base = RECOVERY.callout
    + RECOVERY.outboundPerKm * distanceKm(outboundKm)
    + RECOVERY.loadedPerKm * distanceKm(loadedKm)
    + M.recoveryDifficultyFee(level)
  return base * (1 + M.recoverySkillBonus(level))
end

-- args: outboundKm, loadedKm, level (Recovery skill, shared by RLS repo and recovery),
--       tierMultiplier, jobType ("tow" | "repo"), economy (RLS "repo" section),
--       recoveryEconomy (RLS "offroadRecovery" section, defaults to economy)
-- Returns the rounded quote and a breakdown for the UI.
function M.quote(args)
  local cfg = M.config
  local outboundKm = distanceKm(args.outboundKm)
  local loadedKm = distanceKm(args.loadedKm)
  local tierMultiplier = tierMultiplierOf(args.tierMultiplier)
  local economy = economyOf(args.economy)
  local recoveryEconomy = economyOf(args.recoveryEconomy or economy)
  local bonus = M.repoSkillBonus(args.level)
  local typeFactor = jobTypeFactor(args.jobType)

  local base = cfg.callout + cfg.outboundPerKm * outboundKm + cfg.loadedPerKm * loadedKm
  local raw = base * tierMultiplier * (1 + bonus) * typeFactor * economy
  -- Compared with what Off-Road Recovery actually pays now, so the hub stays below it
  -- even when the two RLS economy sections differ.
  local cap = cfg.recoveryCapShare * M.recoveryQuote(outboundKm, loadedKm, args.level) * recoveryEconomy
  local capped = raw > cap

  return round(math.min(raw, cap)), {
    callout = cfg.callout,
    outbound = cfg.outboundPerKm * outboundKm,
    loaded = cfg.loadedPerKm * loadedKm,
    tierMultiplier = tierMultiplier,
    skillBonus = bonus,
    jobTypeFactor = typeFactor,
    economy = economy,
    recoveryEconomy = recoveryEconomy,
    capped = capped,
  }
end

-- RLS repo XP for a delivered job (jobs/repo.lua): (5 + tier base XP + km / 2 rounded) × 2.
function M.rlsRepoXp(tierBaseXp, loadedKm)
  return (5 + math.max(0, finite(tierBaseXp, 0)) + round(distanceKm(loadedKm) / 2)) * 2
end

-- args: tierBaseXp, loadedKm, jobType, payout
-- A 2 km job gives what RLS repo gives; longer jobs scale so XP per minute stays even.
-- A delivery paid zero because of damage gives no XP.
function M.xp(args)
  if finite(args.payout, 0) <= 0 then return 0 end
  local loadedKm = distanceKm(args.loadedKm)
  local xp = M.rlsRepoXp(args.tierBaseXp, loadedKm) * (3 + loadedKm) / 5 * jobTypeFactor(args.jobType)
  return round(xp)
end

-- The damage penalty never takes a delivery below zero.
function M.settle(quote, damagePenalty)
  quote = math.max(0, finite(quote, 0))
  local penalty = clamp(finite(damagePenalty, 0), 0, quote)
  return quote - penalty, penalty
end

-- Fixed fine for abandoning or losing a vehicle in custody.
function M.custodyFine(tierMultiplier, economy)
  return round(M.config.fineBase * tierMultiplierOf(tierMultiplier) * economyOf(economy))
end

return M
