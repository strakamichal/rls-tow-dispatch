-- Pickup spot rules: which city parking spots can be used and how one is drawn.
-- Pure functions, no game API, so they run under plain LuaJIT in tests. See docs/spec.md,
-- section Pickup spots.

local M = {}

-- How far (m) a live or reloaded spot may lie from the position an offer stored for it.
M.SAME_SPOT_M = 3

-- Drops every spot whose key is shared with another spot. RLS reserves spots by key
-- ("file#name") and resolves a shared key to the first spot with it, so such a spot cannot be
-- reserved reliably. Example on West Coast: stall 8 of the row "Parking 1828" and a single spot
-- are both named "Parking 1828.8". Returns the kept spots and how many were dropped.
function M.uniqueByKey(spots, keyOf)
  local counts = {}
  for _, spot in ipairs(spots) do
    local key = keyOf(spot)
    counts[key] = (counts[key] or 0) + 1
  end
  local kept, dropped = {}, 0
  for _, spot in ipairs(spots) do
    if counts[keyOf(spot)] == 1 then kept[#kept + 1] = spot else dropped = dropped + 1 end
  end
  return kept, dropped
end

-- Groups spots by the sites entry they come from: a single spot, or a row ("multi spot") whose
-- extra stalls the game generates as procedural spots named "<row name>.<n>". A procedural spot
-- whose row is unknown forms its own group. Spot fields used: name, isMultiSpot, isProcedural.
function M.groupByEntry(spots)
  local rows, groups, order = {}, {}, {}
  for _, spot in ipairs(spots) do
    if spot.isMultiSpot and not spot.isProcedural and spot.name then rows[spot.name] = true end
  end
  local function add(key, spot)
    if not groups[key] then groups[key] = {}; order[#order + 1] = key end
    local list = groups[key]
    list[#list + 1] = spot
  end
  for index, spot in ipairs(spots) do
    local row = spot.isProcedural and type(spot.name) == "string" and spot.name:match("^(.*)%.%d+$")
    if row and rows[row] then
      add("row:" .. row, spot)
    elseif spot.isMultiSpot and not spot.isProcedural and spot.name then
      add("row:" .. spot.name, spot)
    else
      add("spot:" .. index, spot)
    end
  end
  local result = {}
  for _, key in ipairs(order) do result[#result + 1] = groups[key] end
  return result
end

-- Draws an entry first and then a stall in it, so a lot drawn as one long row is not picked more
-- often than a kerbside spot. rng(n) returns an integer in 1..n.
function M.pick(groups, rng)
  if #groups == 0 then return nil end
  local group = groups[rng(#groups)]
  return group[rng(#group)]
end

-- True when two positions ({x, y, z} arrays or vec3-like tables) name the same spot.
function M.samePlace(a, b)
  if not (a and b) then return false end
  local ax, ay, az = a.x or a[1], a.y or a[2], a.z or a[3]
  local bx, by, bz = b.x or b[1], b.y or b[2], b.z or b[3]
  if not (ax and ay and az and bx and by and bz) then return false end
  local dx, dy, dz = ax - bx, ay - by, az - bz
  return dx * dx + dy * dy + dz * dz <= M.SAME_SPOT_M * M.SAME_SPOT_M
end

return M
