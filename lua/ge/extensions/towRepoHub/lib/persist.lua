-- What the hub saves: boards per map, the active job, the hub's clock and the next offer id.
-- Pure functions, no game API, so they run under plain LuaJIT in tests. See docs/spec.md,
-- section Persistence. Runtime-only fields (RLS spot objects, live vehicle ids, reservations)
-- are dropped here and rebuilt after loading.

local M = {}

M.VERSION = 1

-- Offer fields that only make sense in the running game.
local OFFER_RUNTIME = { runtime = true }
-- Job fields that only make sense in the running game: the target's vehicle id, the carrier's
-- vehicle id, live parking spots and the completion in progress.
local JOB_RUNTIME = { vehicleId = true, carrierId = true, pickupLive = true, dropLive = true, completing = true,
  runtime = true, token = true }

-- A deep copy that keeps only JSON-safe values: numbers (finite), strings, booleans and tables.
local function plain(value)
  local kind = type(value)
  if kind == "number" then
    if value ~= value or value == math.huge or value == -math.huge then return nil end
    return value
  end
  if kind == "string" or kind == "boolean" then return value end
  if kind ~= "table" then return nil end
  local result = {}
  for k, v in pairs(value) do
    local key = (type(k) == "string" or type(k) == "number") and k or nil
    if key ~= nil then result[key] = plain(v) end
  end
  return result
end

local function without(source, dropped)
  local result = {}
  for k, v in pairs(source or {}) do
    if not dropped[k] then result[k] = v end
  end
  return plain(result)
end

function M.offer(offer)
  return without(offer, OFFER_RUNTIME)
end

function M.job(job)
  if not job then return nil end
  return without(job, JOB_RUNTIME)
end

function M.board(board)
  local result = without(board, { offers = true })
  result.offers = {}
  for _, offer in ipairs(board.offers or {}) do result.offers[#result.offers + 1] = M.offer(offer) end
  return result
end

-- state: { boards = { [levelId] = board }, activeJob, simMinutes, nextOfferId }
function M.build(state)
  local boards = {}
  for levelId, board in pairs(state.boards or {}) do boards[levelId] = M.board(board) end
  return {
    version = M.VERSION,
    simMinutes = plain(state.simMinutes) or 0,
    nextOfferId = plain(state.nextOfferId) or 1,
    boards = boards,
    activeJob = M.job(state.activeJob),
  }
end

-- Checks saved data and returns the state to resume, or nil and a reason. Offers lose their
-- runtime spot objects; the caller resolves them again before accepting.
function M.restore(data)
  if type(data) ~= "table" then return nil, "no data" end
  if data.version ~= M.VERSION then return nil, "unsupported version " .. tostring(data.version) end
  local boards = {}
  for levelId, board in pairs(type(data.boards) == "table" and data.boards or {}) do
    if type(board) == "table" then
      board.offers = type(board.offers) == "table" and board.offers or {}
      board.recentSpots = type(board.recentSpots) == "table" and board.recentSpots or {}
      boards[levelId] = board
    end
  end
  local job = type(data.activeJob) == "table" and data.activeJob or nil
  if job and not (job.modelKey and job.mapId and job.dropPos and job.pickupPos) then job = nil end
  return {
    simMinutes = tonumber(data.simMinutes) or 0,
    nextOfferId = math.max(1, math.floor(tonumber(data.nextOfferId) or 1)),
    boards = boards,
    activeJob = job,
  }
end

return M
