return function(t)
  local board = require("towRepoHub/lib/board")

  local BOTH = { "tow", "repo" }

  local function offer(jobType, tierTag, modelKey, destinationId, extra)
    local o = { jobType = jobType, tierTag = tierTag, modelKey = modelKey, destinationId = destinationId }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
  end

  return {
    { "a fresh candidate on an empty board breaks nothing", function()
      local broken = board.violations(offer("repo", "small", "covet", "d1"), {}, BOTH)
      t.truthy(next(broken) == nil, "no violations")
    end },

    { "tier shares add up and Joe's Junk counts as Low Value", function()
      local total = 0
      for _, share in pairs(board.TIER_SHARES) do total = total + share end
      t.near(total, 1, 1e-9, "shares sum to 1")
      t.eq(board.tierBucket("joesJunkVeh"), "junkerVeh", "Joe's Junk bucket")
      t.eq(board.tierBucket("fleetVeh"), "fleetVeh", "other tiers are their own bucket")
    end },

    { "pickTier follows the shares and avoids crowded tiers", function()
      local seen = {}
      local steps = 400
      for i = 1, steps do
        local bucket = board.pickTier({}, function() return (i - 0.5) / steps end)
        seen[bucket] = (seen[bucket] or 0) + 1
      end
      for bucket, share in pairs(board.TIER_SHARES) do
        t.near(seen[bucket] / steps, share, 0.02, "share of " .. bucket)
      end

      local crowded = {}
      for i = 1, 6 do crowded[i] = offer("repo", "junkerVeh", "m" .. i, "d" .. i) end
      local lowValue = 0
      for i = 1, steps do
        if board.pickTier(crowded, function() return (i - 0.5) / steps end) == "junkerVeh" then lowValue = lowValue + 1 end
      end
      t.truthy(lowValue / steps < board.TIER_SHARES.junkerVeh / 2, "a crowded tier is picked less")

      t.eq(board.pickTier({}, function() return 0.5 end, { heavyVeh = true }), "heavyVeh", "only available buckets")
      t.eq(board.pickTier({}, function() return 0.5 end, {}), nil, "nothing available")
    end },

    { "no model and no destination twice", function()
      local offers = { offer("repo", "small", "covet", "d1") }
      local broken = board.violations(offer("tow", "fleet", "covet", "d1"), offers, BOTH)
      t.truthy(broken.model, "same model")
      t.truthy(broken.destination, "same destination")
    end },

    { "the type mix keeps room for two of each type", function()
      local offers = {
        offer("repo", "a", "m1", "d1"), offer("repo", "b", "m2", "d2"),
        offer("repo", "c", "m3", "d3"), offer("repo", "d", "m4", "d4"),
      }
      -- On a board planned for 6, a fifth repo would leave one slot for the two tow offers missing.
      t.truthy(board.violations(offer("repo", "e", "m5", "d5"), offers, BOTH, 6).jobTypeMix, "fifth repo")
      t.truthy(not board.violations(offer("tow", "e", "m5", "d5"), offers, BOTH, 6).jobTypeMix, "tow fits")
      t.truthy(not board.violations(offer("repo", "e", "m5", "d5"), offers, BOTH, 10).jobTypeMix, "room on a bigger board")
    end },

    { "the type mix does not apply with a single job type", function()
      local offers = {}
      for i = 1, 5 do offers[i] = offer("repo", "t" .. i, "m" .. i, "d" .. i) end
      t.truthy(not board.violations(offer("repo", "t6", "m6", "d6"), offers, { "repo" }).jobTypeMix, "repo only")
    end },

    { "relaxing drops rules in RELAX_ORDER", function()
      local offers = { offer("repo", "small", "covet", "d1") }
      local sameDestination = offer("repo", "fleet", "pessima", "d1")
      t.truthy(not board.fits(sameDestination, offers, { "repo" }, 0), "strict")
      t.truthy(board.fits(sameDestination, offers, { "repo" }, 1), "destination relaxed")
      local sameModel = offer("repo", "fleet", "covet", "d2")
      t.truthy(not board.fits(sameModel, offers, { "repo" }, 1), "model still enforced")
      t.truthy(board.fits(sameModel, offers, { "repo" }, 2), "model relaxed")
    end },

    { "pick relaxes until something fits and never loops forever", function()
      local offers = { offer("repo", "small", "covet", "d1") }
      local calls = 0
      local candidate, relaxed = board.pick(function()
        calls = calls + 1
        return offer("repo", "fleet", "pessima", "d1")
      end, offers, { "repo" })
      t.truthy(candidate, "found")
      t.eq(relaxed, 1, "destination relaxed")
      t.eq(calls, board.config.attemptsPerLevel + 1, "attempts")

      calls = 0
      t.eq(board.pick(function() calls = calls + 1 end, offers, { "repo" }), nil, "nothing generated")
      t.eq(calls, board.config.attemptsPerLevel * (#board.RELAX_ORDER + 1), "bounded attempts")
    end },

    { "expire splits open and expired offers", function()
      local offers = { offer("repo", "a", "m1", "d1", { expiresAt = 10 }), offer("repo", "b", "m2", "d2", { expiresAt = 30 }) }
      local open, expired = board.expire(offers, 10)
      t.eq(#open, 1, "open")
      t.eq(#expired, 1, "expired")
      t.eq(open[1].modelKey, "m2", "later one stays")
    end },

    { "a new board fills to a random starting count without waiting", function()
      local cfg = board.config
      t.eq(board.newState(0, function() return 0 end).target, cfg.initialMin, "lowest start")
      t.eq(board.newState(0, function() return 0.999 end).target, cfg.initialMax, "highest start")
      local state = board.newState(0, function() return 0 end)
      for i = 1, cfg.initialMin do
        t.truthy(board.isDue(state, 0), "filling " .. i)
        state.offers[i] = offer("repo", "t" .. i, "m" .. i, "d" .. i)
        board.scheduleNext(state, 0, true, function() return 0 end)
      end
      t.truthy(not state.filling, "filling ends at the starting count")
      t.truthy(not board.isDue(state, cfg.intervalMinMin - 0.1), "waits for the interval")
      t.truthy(board.isDue(state, cfg.intervalMinMin), "due after the interval")
    end },

    { "offers keep arriving up to the maximum, faster on a thin board", function()
      local cfg = board.config
      local state = board.newState(0)
      state.filling = false
      for i = 1, cfg.size do state.offers[i] = offer("repo", "t" .. i, "m" .. i, "d" .. i) end
      t.truthy(not board.isDue(state, 1000), "full board")
      state.offers = { offer("repo", "a", "m", "d") }
      board.scheduleNext(state, 0, true, function() return 0.999 end)
      t.truthy(state.nextOfferAt < cfg.intervalMaxMin, "thin board refills faster")
      state.offers = {}
      for i = 1, cfg.minSize do state.offers[i] = offer("repo", "t" .. i, "m" .. i, "d" .. i) end
      board.scheduleNext(state, 0, true, function() return 0.999 end)
      t.near(state.nextOfferAt, cfg.intervalMaxMin, 0.01, "normal interval")
    end },

    { "each offer gets its own lifetime", function()
      t.eq(board.ttl(function() return 0 end), board.config.ttlMinMin, "shortest")
      t.near(board.ttl(function() return 0.999 end), board.config.ttlMaxMin, 0.1, "longest")
    end },

    { "a failed attempt stops filling and retries soon", function()
      local state = board.newState(5)
      board.scheduleNext(state, 5, false)
      t.truthy(not state.filling, "filling stopped")
      t.truthy(not board.isDue(state, 5), "not immediately")
      t.truthy(board.isDue(state, 5 + board.config.retryMin), "retry")
    end },

    { "recent spots keep the last ten and block reuse", function()
      local state = board.newState(0)
      for i = 1, 12 do board.rememberSpot(state.recentSpots, "s" .. i) end
      t.eq(#state.recentSpots, board.config.recentSpots, "capped")
      t.truthy(not board.isSpotTaken(state, "s1"), "oldest forgotten")
      t.truthy(board.isSpotTaken(state, "s12"), "newest kept")
      board.rememberSpot(state.recentSpots, "s5")
      t.eq(state.recentSpots[#state.recentSpots], "s5", "reuse moves to the end")
      t.eq(#state.recentSpots, board.config.recentSpots, "no duplicate")
    end },

    { "a spot used by an open offer is taken", function()
      local state = board.newState(0)
      state.offers[1] = offer("repo", "a", "m", "d", { spotKey = "p1" })
      t.truthy(board.isSpotTaken(state, "p1"), "offer spot")
      t.truthy(not board.isSpotTaken(state, "p2"), "free spot")
    end },
  }
end
