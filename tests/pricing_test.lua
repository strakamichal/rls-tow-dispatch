return function(t)
  local pricing = require("towRepoHub/lib/pricing")

  local TIERS = { 0.75, 1.0, 1.15, 1.35, 1.6, 1.8 }
  local DISTANCES = { 0, 0.5, 1, 2, 3, 5, 8, 12, 20, 40 }

  local function quote(outboundKm, loadedKm, level, tier, jobType, economy)
    return (pricing.quote({
      outboundKm = outboundKm, loadedKm = loadedKm, level = level,
      tierMultiplier = tier, jobType = jobType or "repo", economy = economy or 1,
    }))
  end

  return {
    { "repo skill bonus follows the RLS repo curve", function()
      t.eq(pricing.repoSkillBonus(1), 0, "level 1")
      t.near(pricing.repoSkillBonus(11), 5 / 6, 1e-9, "level 11")
      t.eq(pricing.repoSkillBonus(48), 4, "level 48")
      t.eq(pricing.repoSkillBonus(50), 4, "level 50 stays capped")
      t.eq(pricing.repoSkillBonus(-3), 0, "negative level")
    end },

    { "recovery skill bonus follows the RLS recovery curve", function()
      t.eq(pricing.recoverySkillBonus(5), 0, "level 5")
      t.near(pricing.recoverySkillBonus(11), 2 * (3 / 22) ^ 2, 1e-9, "level 11")
      t.eq(pricing.recoverySkillBonus(49), 2, "level 49")
    end },

    { "recovery difficulty fee by level", function()
      t.eq(pricing.recoveryDifficultyFee(9), 0, "below 10")
      t.eq(pricing.recoveryDifficultyFee(10), 1500, "from 10")
      t.eq(pricing.recoveryDifficultyFee(30), 3000, "from 30")
    end },

    { "quote at level 11, Low tier, 2 + 2 km", function()
      -- (400 + 55*2 + 135*2) * 1.0 * (1 + 5/6) = 1430
      t.eq(quote(2, 2, 11, 1.0), 1430, "repo")
      t.eq(quote(2, 2, 11, 1.0, "tow"), 1573, "tow is 1.1x")
    end },

    { "economy multiplier scales the quote", function()
      t.eq(quote(2, 2, 11, 1.0, "repo", 0.72), 1030, "1430 * 0.72")
    end },

    { "cap applies to long heavy jobs", function()
      local amount, breakdown = pricing.quote({
        outboundKm = 3, loadedKm = 8, level = 11, tierMultiplier = 1.8, jobType = "repo", economy = 1,
      })
      -- 0.9 * (1500 + 300 + 2000 + 1500) * (1 + 2 * (3/22)^2) = 4947
      t.eq(amount, 4947, "capped amount")
      t.truthy(breakdown.capped, "breakdown marks the cap")
    end },

    { "quote never exceeds 90 % of the equivalent recovery quote", function()
      for level = 0, 50 do
        for _, tier in ipairs(TIERS) do
          for _, outboundKm in ipairs(DISTANCES) do
            for _, loadedKm in ipairs(DISTANCES) do
              for _, jobType in ipairs({ "repo", "tow" }) do
                for _, economy in ipairs({ 0.5, 0.72, 1, 1.4 }) do
                  local limit = 0.9 * pricing.recoveryQuote(outboundKm, loadedKm, level) * economy
                  local amount = quote(outboundKm, loadedKm, level, tier, jobType, economy)
                  if amount > limit + 0.5 then
                    error(string.format("level %d tier %.2f %s out %.1f loaded %.1f econ %.2f: %d > %.1f",
                      level, tier, jobType, outboundKm, loadedKm, economy, amount, limit))
                  end
                end
              end
            end
          end
        end
      end
    end },

    { "negative or missing distances count as zero", function()
      t.eq(quote(-5, nil, 11, 1.0), quote(0, 0, 11, 1.0), "clamped")
    end },

    { "unknown job type is rejected", function()
      t.raises(function() quote(1, 1, 11, 1.0, "taxi") end)
    end },

    { "xp matches RLS repo for a 2 km job and scales with distance", function()
      -- RLS repo: (5 + 500 + round(2/2)) * 2 = 1012
      t.eq(pricing.xp({ tierBaseXp = 500, loadedKm = 2, jobType = "repo", payout = 100 }), 1012, "2 km")
      -- (5 + 500 + 4) * 2 = 1018; * (3 + 8) / 5 = 2239.6
      t.eq(pricing.xp({ tierBaseXp = 500, loadedKm = 8, jobType = "repo", payout = 100 }), 2240, "8 km")
      t.eq(pricing.xp({ tierBaseXp = 500, loadedKm = 2, jobType = "tow", payout = 100 }), 1113, "tow is 1.1x")
    end },

    { "no xp when damage took the whole payout", function()
      t.eq(pricing.xp({ tierBaseXp = 500, loadedKm = 5, jobType = "repo", payout = 0 }), 0, "zero payout")
    end },

    { "settlement caps the damage penalty at the quote", function()
      t.eq(pricing.settle(1000, 300), 700, "partial penalty")
      local payout, penalty = pricing.settle(1000, 5000)
      t.eq(payout, 0, "never below zero")
      t.eq(penalty, 1000, "penalty capped")
      t.eq(pricing.settle(1000, -50), 1000, "negative penalty ignored")
    end },

    { "custody fine scales with tier and economy only", function()
      t.eq(pricing.custodyFine(1.0, 1), 1000, "Low")
      t.eq(pricing.custodyFine(1.8, 1), 1800, "Heavy")
      t.eq(pricing.custodyFine(1.15, 0.72), 828, "Standard in a weak economy")
    end },
  }
end
