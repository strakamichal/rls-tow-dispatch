-- Offer board rules: timing, expiry, diversity and recently used spots. Pure functions, no game API,
-- so they run under plain LuaJIT in tests. See docs/spec.md, section Board.
--
-- An offer here is a plain table; the rules read only these fields:
--   jobType ("tow" | "repo"), tierTag, modelKey, destinationId, spotKey, expiresAt (sim minutes)

local M = {}

-- The board size varies: a new board fills to a random count, then offers arrive at random
-- intervals up to `size` and each expires after its own random time. Times are sim minutes.
M.config = {
  size = 14,
  minSize = 8,
  initialMin = 10,
  initialMax = 14,
  intervalMinMin = 1,
  intervalMaxMin = 3,
  ttlMinMin = 12,
  ttlMaxMin = 30,
  retryMin = 0.5,
  minPerType = 2,
  recentSpots = 10,
  attemptsPerLevel = 6,
}

-- The board holds jobs of every tier, unlocked or not, in about these shares. Keys are tier
-- buckets: RLS repo tier unlockTags, with Joe's Junk counted as Low Value.
M.TIER_SHARES = {
  junkerVeh = 0.30,
  smallVeh = 0.25,
  fleetVeh = 0.20,
  highEndVeh = 0.12,
  exoticVeh = 0.06,
  heavyVeh = 0.07,
}
local TIER_BUCKETS = { joesJunkVeh = "junkerVeh" }

local function between(random, low, high)
  return low + (high - low) * random()
end

function M.tierBucket(tierTag)
  return TIER_BUCKETS[tierTag] or tierTag
end

-- Picks the tier bucket for the next offer: weighted by its share, less likely the more the
-- board already has of it. available (optional) limits the choice to buckets with candidates.
-- random() returns a number in [0, 1).
function M.pickTier(offers, random, available)
  local counts = {}
  for _, offer in ipairs(offers) do
    local bucket = M.tierBucket(offer.tierTag)
    counts[bucket] = (counts[bucket] or 0) + 1
  end
  local buckets, weights, total = {}, {}, 0
  for bucket, share in pairs(M.TIER_SHARES) do
    if not available or available[bucket] then
      local expected = share * M.config.size
      local weight = share * math.max(0.1, (expected + 1 - (counts[bucket] or 0)) / (expected + 1))
      buckets[#buckets + 1] = bucket
      weights[bucket] = weight
    end
  end
  table.sort(buckets)
  for _, bucket in ipairs(buckets) do total = total + weights[bucket] end
  if total <= 0 then return nil end
  local roll = random() * total
  for _, bucket in ipairs(buckets) do
    roll = roll - weights[bucket]
    if roll <= 0 then return bucket end
  end
  return buckets[#buckets]
end

-- Diversity rules in the order they are relaxed when no candidate fits.
-- Few maps have more than a handful of dealerships, so destinations go first.
M.RELAX_ORDER = { "destination", "model", "jobTypeMix" }

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
-- capacity is the board size the type mix plans for (default config.size): a board filling to a
-- smaller starting count still gets both types.
function M.violations(candidate, offers, jobTypes, capacity)
  local cfg = M.config
  local broken = {}

  for _, offer in ipairs(offers) do
    if candidate.modelKey ~= nil and offer.modelKey == candidate.modelKey then broken.model = true end
    if candidate.destinationId ~= nil and offer.destinationId == candidate.destinationId then broken.destination = true end
  end

  -- Adding the candidate must leave enough free slots for the other types to reach their minimum.
  local types = countBy(offers, "jobType")
  local freeAfter = math.max(capacity or cfg.size, #offers + 1) - (#offers + 1)
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
function M.fits(candidate, offers, jobTypes, relaxed, capacity)
  local broken = M.violations(candidate, offers, jobTypes, capacity)
  for index, rule in ipairs(M.RELAX_ORDER) do
    if index > (relaxed or 0) and broken[rule] then return false end
  end
  return true
end

-- Calls generate(offers) until a candidate fits, relaxing one rule after every attemptsPerLevel
-- attempts. generate may return nil when it finds nothing. Returns the candidate and how many
-- rules were relaxed, or nil when every attempt failed.
function M.pick(generate, offers, jobTypes, capacity)
  for relaxed = 0, #M.RELAX_ORDER do
    for _ = 1, M.config.attemptsPerLevel do
      local candidate = generate(offers)
      if candidate and M.fits(candidate, offers, jobTypes, relaxed, capacity) then return candidate, relaxed end
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

-- How long a new offer stays on the board. random() returns a number in [0, 1).
function M.ttl(random)
  return between(random, M.config.ttlMinMin, M.config.ttlMaxMin)
end

-- A new offer is due when the board has a free slot and its timer has run out. While a board
-- is first filling, offers are added without waiting until it reaches its starting count.
function M.isDue(state, now)
  if #state.offers >= M.config.size then return false end
  if state.filling then return #state.offers < (state.target or M.config.size) end
  return now >= (state.nextOfferAt or 0)
end

-- Advances the timer after an attempt to add an offer. A thin board refills twice as fast.
function M.scheduleNext(state, now, added, random)
  local cfg = M.config
  if state.filling and #state.offers >= (state.target or cfg.size) then state.filling = false end
  if added then
    local interval = between(random or math.random, cfg.intervalMinMin, cfg.intervalMaxMin)
    if #state.offers < cfg.minSize then interval = interval / 2 end
    state.nextOfferAt = now + interval
  else
    state.filling = false
    state.nextOfferAt = now + cfg.retryMin
  end
end

function M.newState(now, random)
  local cfg = M.config
  local target = cfg.initialMin + math.floor((random or math.random)() * (cfg.initialMax - cfg.initialMin + 1))
  return { offers = {}, nextOfferAt = now or 0, filling = true, target = target, recentSpots = {} }
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
