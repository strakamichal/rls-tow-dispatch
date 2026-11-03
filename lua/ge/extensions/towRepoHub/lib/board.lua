-- Offer board rules: timing, expiry, diversity and recently used spots. Pure functions, no game API,
-- so they run under plain LuaJIT in tests. See docs/spec.md, section Board.
--
-- An offer here is a plain table; the rules read only these fields:
--   jobType ("tow" | "repo"), tierTag, modelKey, destinationId, spotKey, expiresAt (sim minutes)

local M = {}

M.config = {
  size = 6,
  intervalMin = 3,
  ttlMin = 20,
  retryMin = 0.5,
  minPerType = 2,
  maxPerTier = 2,
  recentSpots = 10,
  attemptsPerLevel = 6,
}

-- Diversity rules in the order they are relaxed when no candidate fits.
-- Few maps have more than a handful of dealerships, so destinations go first.
M.RELAX_ORDER = { "destination", "tier", "model", "jobTypeMix" }

local function countBy(offers, field)
  local counts = {}
  for _, offer in ipairs(offers) do
    local key = offer[field]
    if key ~= nil then counts[key] = (counts[key] or 0) + 1 end
  end
  return counts
end

-- Returns a set of the rules the candidate breaks against the current offers.
-- jobTypes lists the job types the board offers; the type mix only applies between those.
function M.violations(candidate, offers, jobTypes)
  local cfg = M.config
  local broken = {}

  local tiers = countBy(offers, "tierTag")
  if candidate.tierTag ~= nil and (tiers[candidate.tierTag] or 0) >= cfg.maxPerTier then broken.tier = true end

  for _, offer in ipairs(offers) do
    if candidate.modelKey ~= nil and offer.modelKey == candidate.modelKey then broken.model = true end
    if candidate.destinationId ~= nil and offer.destinationId == candidate.destinationId then broken.destination = true end
  end

  -- Adding the candidate must leave enough free slots for the other types to reach their minimum.
  local types = countBy(offers, "jobType")
  local freeAfter = cfg.size - (#offers + 1)
  local missing = 0
  for _, jobType in ipairs(jobTypes or {}) do
    if jobType ~= candidate.jobType then
      missing = missing + math.max(0, cfg.minPerType - (types[jobType] or 0))
    end
  end
  if missing > freeAfter then broken.jobTypeMix = true end

  return broken
end

-- True when the candidate breaks none of the rules still enforced after relaxing the first
-- `relaxed` entries of RELAX_ORDER.
function M.fits(candidate, offers, jobTypes, relaxed)
  local broken = M.violations(candidate, offers, jobTypes)
  for index, rule in ipairs(M.RELAX_ORDER) do
    if index > (relaxed or 0) and broken[rule] then return false end
  end
  return true
end

-- Calls generate(offers) until a candidate fits, relaxing one rule after every attemptsPerLevel
-- attempts. generate may return nil when it finds nothing. Returns the candidate and how many
-- rules were relaxed, or nil when every attempt failed.
function M.pick(generate, offers, jobTypes)
  for relaxed = 0, #M.RELAX_ORDER do
    for _ = 1, M.config.attemptsPerLevel do
      local candidate = generate(offers)
      if candidate and M.fits(candidate, offers, jobTypes, relaxed) then return candidate, relaxed end
    end
  end
  return nil
end

-- Splits offers into those still open and those expired at `now`.
function M.expire(offers, now)
  local open, expired = {}, {}
  for _, offer in ipairs(offers) do
    if (offer.expiresAt or math.huge) <= now then
      expired[#expired + 1] = offer
    else
      open[#open + 1] = offer
    end
  end
  return open, expired
end

-- A new offer is due when the board has a free slot and its timer has run out. While a board
-- is first filling, offers are added without waiting.
function M.isDue(state, now)
  if #state.offers >= M.config.size then return false end
  return state.filling or now >= (state.nextOfferAt or 0)
end

-- Advances the timer after an attempt to add an offer.
function M.scheduleNext(state, now, added)
  if #state.offers >= M.config.size then state.filling = false end
  if added then
    state.nextOfferAt = now + M.config.intervalMin
  else
    state.filling = false
    state.nextOfferAt = now + M.config.retryMin
  end
end

function M.newState(now)
  return { offers = {}, nextOfferAt = now or 0, filling = true, recentSpots = {} }
end

-- Recently used pickup spots, newest last, at most config.recentSpots entries.
function M.rememberSpot(recent, key)
  if key == nil then return end
  for index = #recent, 1, -1 do
    if recent[index] == key then table.remove(recent, index) end
  end
  recent[#recent + 1] = key
  while #recent > M.config.recentSpots do table.remove(recent, 1) end
end

-- True when the spot was used recently or is the pickup of an open offer.
function M.isSpotTaken(state, key)
  if key == nil then return false end
  for _, recentKey in ipairs(state.recentSpots) do
    if recentKey == key then return true end
  end
  for _, offer in ipairs(state.offers) do
    if offer.spotKey == key then return true end
  end
  return false
end

return M
