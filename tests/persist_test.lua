return function(t)
  local persist = require("towRepoHub/lib/persist")

  local spotObject = { name = "Parking 12", getPath = function() return "x" end }

  local function sample()
    return {
      simMinutes = 42.5,
      nextOfferId = 17,
      boards = {
        gap = {
          offers = {
            { id = 3, jobType = "tow", quote = 1500, pickupPos = { 1, 2, 3 }, expiresAt = 60,
              runtime = { spot = spotObject } },
          },
          nextOfferAt = 44, filling = false, target = 12, recentSpots = { "a", "b" },
        },
      },
      activeJob = {
        id = 9, jobType = "tow", modelKey = "covet", mapId = "gap", quote = 2000, custody = true,
        pickupPos = { 1, 2, 3 }, dropPos = { 4, 5, 6 }, drivenM = 120.5,
        vehicleId = 12345, carrierId = 6789, pickupLive = spotObject, dropLive = spotObject, token = "t",
        completing = true, baseline = { ["/body"] = { integrityValue = 1 } },
        targetPose = { pos = { 1, 1, 1 }, rot = { 0, 0, 0, 1 } },
      },
    }
  end

  return {
    { "build drops runtime fields and keeps the rest", function()
      local data = persist.build(sample())
      t.eq(data.version, persist.VERSION, "version")
      t.eq(data.simMinutes, 42.5, "clock")
      t.eq(data.nextOfferId, 17, "next id")
      local offer = data.boards.gap.offers[1]
      t.eq(offer.quote, 1500, "offer kept")
      t.eq(offer.runtime, nil, "spot objects dropped")
      t.eq(data.boards.gap.recentSpots[2], "b", "recent spots kept")
      local job = data.activeJob
      t.eq(job.vehicleId, nil, "vehicle id dropped")
      t.eq(job.carrierId, nil, "carrier id dropped")
      t.eq(job.pickupLive, nil, "live spot dropped")
      t.eq(job.completing, nil, "completion flag dropped")
      t.eq(job.drivenM, 120.5, "driven distance kept")
      t.eq(job.baseline["/body"].integrityValue, 1, "baseline kept")
      t.eq(job.targetPose.rot[4], 1, "pose kept")
    end },

    { "build output is plain data", function()
      local data = persist.build(sample())
      local function check(value, path)
        local kind = type(value)
        t.truthy(kind == "table" or kind == "number" or kind == "string" or kind == "boolean", path .. " is " .. kind)
        if kind == "number" then t.truthy(value == value and value ~= math.huge, path .. " is finite") end
        if kind == "table" then for k, v in pairs(value) do check(v, path .. "." .. tostring(k)) end end
      end
      check(data, "data")
      local withNan = sample()
      withNan.activeJob.drivenM = 0 / 0
      t.eq(persist.build(withNan).activeJob.drivenM, nil, "NaN dropped")
    end },

    { "build does not change the live state", function()
      local state = sample()
      persist.build(state)
      t.eq(state.activeJob.vehicleId, 12345, "live vehicle id")
      t.truthy(state.boards.gap.offers[1].runtime, "live runtime")
    end },

    { "restore round-trips and validates", function()
      local restored = persist.restore(persist.build(sample()))
      t.eq(restored.simMinutes, 42.5, "clock")
      t.eq(restored.nextOfferId, 17, "next id")
      t.eq(restored.boards.gap.offers[1].id, 3, "offer")
      t.eq(restored.activeJob.custody, true, "job")
      t.eq((persist.restore({ version = 99 })), nil, "other version")
      t.eq((persist.restore(nil)), nil, "nothing saved")
      local broken = persist.build(sample())
      broken.activeJob.dropPos = nil
      t.eq(persist.restore(broken).activeJob, nil, "an incomplete job is dropped")
      local bare = persist.restore({ version = persist.VERSION, boards = { gap = {} } })
      t.eq(#bare.boards.gap.offers, 0, "missing lists become empty")
      t.eq(bare.nextOfferId, 1, "default next id")
    end },
  }
end
