return function(t)
  local repoTiers = require("towRepoHub/lib/repoTiers")

  -- A cut-down repoVehicleFilters.json with the RLS 2.8 shape.
  local RAW = {
    junkerVehFilter = { type = "vehicle", unlockTag = "junkerVeh", tierLabel = "Low Value Repo", skillUnlockLevel = 1,
      payMultiplier = 1.0, baseXp = 300, priority = 10,
      filter = { whiteList = { Value = { min = 1000, max = 25000 }, Type = { "Car" } },
        blackList = { model_key = { "atv" } } }, subFilters = {} },
    smallVehFilter = { type = "vehicle", unlockTag = "smallVeh", tierLabel = "Budget Repo", skillUnlockLevel = 5,
      priority = 20, filter = { whiteList = { Value = { min = 25000, max = 50000 }, Type = { "Car" } } } },
    fleetVehFilter = { type = "vehicle", unlockTag = "fleetVeh", tierLabel = "Standard Repo", skillUnlockLevel = 10,
      priority = 30, filter = { whiteList = { Value = { min = 40000, max = 100000 }, Type = { "Car" } } } },
    notAVehicle = { type = "part" },
  }

  local function car(value, extra)
    local info = { model_key = "covet", Type = "Car", Value = value, aggregates = {} }
    for k, v in pairs(extra or {}) do info[k] = v end
    return info
  end

  return {
    { "normalize keeps vehicle tiers, highest priority first, with defaults", function()
      local tiers = repoTiers.normalize(RAW)
      t.eq(#tiers, 3, "vehicle tiers only")
      t.eq(tiers[1].unlockTag, "fleetVeh", "highest priority first")
      t.eq(tiers[3].unlockTag, "junkerVeh", "lowest last")
      t.eq(tiers[2].payMultiplier, 1, "default pay multiplier")
      t.eq(tiers[2].baseXp, 0, "default base XP")
    end },

    { "the highest-priority matching tier wins, ignoring unlocks", function()
      local tiers = repoTiers.normalize(RAW)
      t.eq(repoTiers.tierFor(car(10000), tiers).unlockTag, "junkerVeh", "cheap")
      t.eq(repoTiers.tierFor(car(30000), tiers).unlockTag, "smallVeh", "budget")
      t.eq(repoTiers.tierFor(car(45000), tiers).unlockTag, "fleetVeh", "overlap resolves to the higher tier")
      t.eq(repoTiers.tierFor(car(500000), tiers), nil, "no tier")
      t.eq(repoTiers.tierFor(car(10000, { model_key = "atv" }), tiers), nil, "blacklisted")
    end },

    { "list rules read the field or the aggregate set", function()
      t.truthy(repoTiers.passesList({ aggregates = { Type = { Car = true } } }, { Type = { "Car" } }), "aggregate")
      t.truthy(not repoTiers.passesList({ aggregates = {} }, { Type = { "Car" } }), "missing field fails")
      t.truthy(repoTiers.passesList({ aggregates = { Value = { min = 3000 } } }, { Value = { min = 1000 } }), "aggregate min")
      t.truthy(not repoTiers.passesList({}, { Value = { min = 1000 } }), "missing value fails")
      t.truthy(repoTiers.passesList({}, { Mileage = { max = 1 } }), "mileage is ignored")
    end },

    { "years ranges must overlap", function()
      local info = { Years = { min = 1990, max = 1995 } }
      t.truthy(repoTiers.passesList(info, { Years = { min = 1994 } }), "overlap")
      t.truthy(not repoTiers.passesList(info, { Years = { min = 2000 } }), "too old")
      t.truthy(not repoTiers.passesList({}, { Years = { min = 1990 } }), "no years")
    end },

    { "sub-filters narrow a tier", function()
      local tier = { filter = { whiteList = { Type = { "Car" } } },
        subFilters = { { whiteList = { Brand = { "Ibishu" } } } } }
      t.truthy(repoTiers.matchesTier({ Type = "Car", Brand = "Ibishu" }, tier), "matching sub-filter")
      t.truthy(not repoTiers.matchesTier({ Type = "Car", Brand = "ETK" }, tier), "no sub-filter matches")
    end },

    { "dealership filters come from sub-filters or the organisation level", function()
      local dealership = { filter = { whiteList = { Type = { "Car" } } },
        subFilters = { { whiteList = { Brand = { "Ibishu" } }, probability = 0.3 }, { whiteList = { Brand = { "ETK" } } } } }
      local filters = repoTiers.dealershipFilters(dealership)
      t.eq(#filters, 2, "one per sub-filter")
      t.eq(filters[1].probability, 0.3, "probability kept")
      t.eq(filters[2].probability, 1, "default probability")
      t.truthy(repoTiers.passes({ Type = "Car", Brand = "ETK" }, filters[2]), "merged filter")

      local org = { reputation = { level = 0 }, reputationLevels = { {}, { filter = { whiteList = { Brand = { "Gavril" } } } } } }
      local orgFilters = repoTiers.dealershipFilters({ filter = { whiteList = { Brand = { "ETK" } } } }, org)
      t.truthy(repoTiers.passes({ Brand = "Gavril" }, orgFilters[1]), "organisation level filter")
      t.eq(#repoTiers.dealershipFilters(nil), 1, "no dealership: one empty filter")
    end },
  }
end
