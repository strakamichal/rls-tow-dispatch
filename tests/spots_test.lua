return function(t)
  local spots = require("towRepoHub/lib/spots")

  local function key(spot) return "city.sites.json#" .. spot.name end

  -- A row "Lot" of n stalls as the game generates it: the entry itself, then procedural stalls
  -- named "Lot.3", "Lot.4", ... (BeamNG numbers them from 3).
  local function row(name, n)
    local list = { { name = name, isMultiSpot = true } }
    for i = 2, n do list[#list + 1] = { name = string.format("%s.%d", name, i + 1), isProcedural = true } end
    return list
  end

  local function concat(...)
    local result = {}
    for _, list in ipairs({ ... }) do
      for _, item in ipairs(list) do result[#result + 1] = item end
    end
    return result
  end

  return {
    { "spots sharing a key are dropped, both of them", function()
      local list = concat(row("Parking 1828", 8), { { name = "Parking 1828.8" } }, { { name = "Kerb" } })
      -- The row's stall 7 is "Parking 1828.8" too (numbered from 3).
      local kept, dropped = spots.uniqueByKey(list, key)
      t.eq(dropped, 2, "two spots named Parking 1828.8")
      t.eq(#kept, #list - 2, "the rest is kept")
      for _, spot in ipairs(kept) do t.truthy(spot.name ~= "Parking 1828.8", "no shared name left") end
    end },

    { "stalls are grouped by their sites entry", function()
      local groups = spots.groupByEntry(concat(row("Lot", 12), { { name = "Kerb A" }, { name = "Kerb B" } }, row("Small", 3)))
      t.eq(#groups, 4, "one row, two single spots, one more row")
      t.eq(#groups[1], 12, "the row keeps all its stalls")
      t.eq(#groups[2], 1, "a single spot")
      t.eq(#groups[4], 3, "the small row")
    end },

    { "a single spot named like a row stall is its own entry", function()
      local groups = spots.groupByEntry(concat(row("Parking 1828", 3), { { name = "Parking 1828.9" } }))
      t.eq(#groups, 2, "row and single spot")
      t.eq(#groups[2], 1, "the single spot stands alone")
    end },

    { "a procedural stall of an unknown row stands alone", function()
      local groups = spots.groupByEntry({ { name = "Gone.3", isProcedural = true } })
      t.eq(#groups, 1, "one entry")
    end },

    { "a 100-stall lot and a kerbside spot are drawn about equally often", function()
      local groups = spots.groupByEntry(concat(row("Mall", 100), { { name = "Kerb" } }))
      math.randomseed(12345)
      local rng = math.random
      local kerb = 0
      for _ = 1, 4000 do
        if spots.pick(groups, rng).name == "Kerb" then kerb = kerb + 1 end
      end
      t.near(kerb / 4000, 0.5, 0.05, "kerb share")
    end },

    { "nothing to pick from", function()
      t.eq(spots.pick({}, math.random), nil, "no groups")
    end },

    { "same place within 3 m", function()
      t.truthy(spots.samePlace({ 0, 0, 0 }, { 2, 2, 0 }), "2.8 m")
      t.truthy(not spots.samePlace({ 0, 0, 0 }, { 3, 3, 0 }), "4.2 m")
      t.truthy(spots.samePlace({ x = 10, y = 0, z = 0 }, { 10, 0, 1 }), "vec3 against an array")
      t.truthy(not spots.samePlace(nil, { 0, 0, 0 }), "missing position")
    end },
  }
end
