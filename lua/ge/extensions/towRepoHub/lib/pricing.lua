-- Quotes, XP, settlement and fines for hub jobs. Pure functions, no game API,
-- so they run under plain LuaJIT in tests. See docs/spec.md, sections Pricing and XP.

local M = {}

M.config = {
  callout = 400,
  outboundPerKm = 55,
  loadedPerKm = 135,
  jobTypeFactor = { tow = 1.1, repo = 1.0 },
  maxPenaltyShare = 0.5,
  fineShare = 0.5,
  fineMin = 200,
  -- Driving the vehicle yourself: free up to selfDriveAllowanceM (to get it onto the truck);
  -- beyond that the pay drops in proportion, down to selfDriveMinPayShare and no XP when the
  -- whole loaded route was driven.
  selfDriveAllowanceM = 200,
  selfDriveMinPayShare = 0.25,
  -- XP distance factor: (xpDistanceBase + km loaded) / xpDistanceDivisor. Grows about half as fast
  -- as "XP per minute"; 0.5 km gives ~0.71, 7 km ~1.18.
  xpDistanceBase = 9.5,
  xpDistanceDivisor = 14,
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

-- The hub's pay bonus is the RLS repo curve: tow shares the Recovery skill with repo, so the
-- gap between the two stays the same at every level.
M.skillBonus = M.repoSkillBonus

-- args: outboundKm, loadedKm, level (Recovery skill, shared by RLS repo and recovery),
--       tierMultiplier, jobType ("tow" | "repo"), economy (RLS "repo" section)
-- Returns the rounded quote and a breakdown for the UI.
function M.quote(args)
  local cfg = M.config
  local outboundKm = distanceKm(args.outboundKm)
  local loadedKm = distanceKm(args.loadedKm)
  local tierMultiplier = tierMultiplierOf(args.tierMultiplier)
  local economy = economyOf(args.economy)
  local bonus = M.skillBonus(args.level)
  local typeFactor = jobTypeFactor(args.jobType)

  local base = cfg.callout + cfg.outboundPerKm * outboundKm + cfg.loadedPerKm * loadedKm
  local amount = base * tierMultiplier * (1 + bonus) * typeFactor * economy

  return round(amount), {
    callout = cfg.callout,
    outbound = cfg.outboundPerKm * outboundKm,
    loaded = cfg.loadedPerKm * loadedKm,
    tierMultiplier = tierMultiplier,
    skillBonus = bonus,
    jobTypeFactor = typeFactor,
    economy = economy,
  }
end

-- RLS repo XP for a delivered job (jobs/repo.lua): (5 + tier base XP + km / 2 rounded) × 2.
function M.rlsRepoXp(tierBaseXp, loadedKm)
  return (5 + math.max(0, finite(tierBaseXp, 0)) + round(distanceKm(loadedKm) / 2)) * 2
end

-- args: tierBaseXp, loadedKm, jobType
-- RLS repo XP for the tier, scaled by a distance factor that grows about half as fast as the pay,
-- so long jobs give more XP without a level per job. Damage never reduces XP.
function M.xp(args)
  local cfg = M.config
  local loadedKm = distanceKm(args.loadedKm)
  local distanceFactor = (cfg.xpDistanceBase + loadedKm) / cfg.xpDistanceDivisor
  local xp = M.rlsRepoXp(args.tierBaseXp, loadedKm) * distanceFactor * jobTypeFactor(args.jobType)
  return round(xp)
end

-- The damage penalty takes at most maxPenaltyShare of the quote, as RLS Off-Road Recovery does.
function M.settle(quote, damagePenalty)
  quote = math.max(0, finite(quote, 0))
  local penalty = round(clamp(finite(damagePenalty, 0), 0, quote * M.config.maxPenaltyShare))
  return quote - penalty, penalty
end

-- Fixed fine for abandoning or losing a vehicle in custody.
-- How much of the job was driven instead of towed, 0..1: metres driven beyond the allowance over
-- the loaded route beyond the allowance.
function M.selfDriveShare(drivenM, loadedM)
  local allowance = M.config.selfDriveAllowanceM
  local over = math.max(0, finite(drivenM, 0) - allowance)
  if over <= 0 then return 0 end
  local route = math.max(1, finite(loadedM, 0) - allowance)
  return clamp(over / route, 0, 1)
end

-- Pay taken for driving instead of towing, and the factor for XP. Returns deduction, xpFactor.
function M.selfDrive(quote, drivenM, loadedM)
  local share = M.selfDriveShare(drivenM, loadedM)
  quote = math.max(0, finite(quote, 0))
  local deduction = round(quote * (1 - M.config.selfDriveMinPayShare) * share)
  return deduction, 1 - share
end

-- The fine is half the job's quote (the same as the largest damage penalty, so cancelling never
-- beats delivering a damaged vehicle), at least fineMin. The quote already carries the tier,
-- the distances and the economy.
function M.custodyFine(quote)
  local cfg = M.config
  return math.max(cfg.fineMin, round(math.max(0, finite(quote, 0)) * cfg.fineShare))
end

return M
