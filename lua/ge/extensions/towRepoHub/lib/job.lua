-- Active job rules: baseline capture, custody, delivery, damage penalty and cancellation.
-- Pure functions, no game API, so they run under plain LuaJIT in tests.
-- See docs/spec.md, sections Damage penalty, Completion and Cancellation and failure.

local M = {}

M.config = {
  baselineRadiusM = 30,
  custodyMoveM = 10,
  deliveryRadiusM = 5,
  stoppedSpeedMps = 1,
  minPartLoss = 0.02,
  defaultPartValue = 700,
  topParts = 3,
}

-- The baseline part condition is taken when the player first gets close, so traffic damage
-- before arrival is not charged.
function M.needsBaseline(job, playerToTargetM)
  return not job.baselineRequested and tonumber(playerToTargetM) ~= nil
    and playerToTargetM <= M.config.baselineRadiusM
end

-- Custody starts once the vehicle has left its spot.
function M.reachesCustody(job, movedFromSpotM)
  return not job.custody and tonumber(movedFromSpotM) ~= nil and movedFromSpotM > M.config.custodyMoveM
end

-- Delivered when the vehicle is in custody, at the destination spot and stopped, loaded or not.
function M.isDelivered(job, targetToDropM, targetSpeedMps)
  return job.custody == true
    and tonumber(targetToDropM) ~= nil and targetToDropM <= M.config.deliveryRadiusM
    and tonumber(targetSpeedMps) ~= nil and targetSpeedMps <= M.config.stoppedSpeedMps
end

-- Metres to add to the self-driven distance for one check, given how far the vehicle moved since
-- the last one while the player sat in it. Jitter (settling on a bed) and jumps (teleport, reset)
-- do not count.
M.config.driveMinStepM = 0.5
M.config.driveMaxStepM = 50

function M.drivenStep(movedM)
  local moved = tonumber(movedM)
  if not moved or moved ~= moved then return 0 end
  if moved < M.config.driveMinStepM or moved > M.config.driveMaxStepM then return 0 end
  return moved
end

-- Cancelling, losing or destroying the vehicle costs a fine only after custody started.
function M.endsWithFine(job)
  return job.custody == true
end

local function integrity(condition)
  local value = type(condition) == "table" and tonumber(condition.integrityValue) or nil
  if not value or value ~= value then return 1 end
  return math.max(0, math.min(1, value))
end

-- Value of the part integrity lost since the baseline. A part missing at the end counts as fully
-- lost; losses below config.minPartLoss are ignored. partValueOf(partPath) returns the part value
-- or nil for the default. Returns the total and the most damaged parts {path, lost, value}.
function M.damage(baseline, final, partValueOf)
  local cfg = M.config
  local total, parts = 0, {}
  for partPath, start in pairs(baseline or {}) do
    local finish = final and final[partPath]
    local lost = integrity(start) - (finish and integrity(finish) or 0)
    if lost >= cfg.minPartLoss then
      local partValue = tonumber(partValueOf and partValueOf(partPath)) or cfg.defaultPartValue
      local value = partValue * lost
      total = total + value
      parts[#parts + 1] = { path = partPath, lost = lost, value = value }
    end
  end
  table.sort(parts, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.path < b.path
  end)
  while #parts > cfg.topParts do table.remove(parts) end
  return total, parts
end

return M
