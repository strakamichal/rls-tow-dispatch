return function(t)
  local pricing = require("towRepoHub/lib/pricing")

  local TIERS = { 0.75, 1.0, 1.15, 1.35, 1.6, 1.8 }
  local DISTANCES = { 0, 0.5, 1, 2, 3, 5, 8, 12, 20, 40 }

  local function quote(outboundKm, loadedKm, level, tier, jobType, economy, recoveryEconomy)
    return (pricing.quote({
      outboundKm = outboundKm, loadedKm = loadedKm, level = level,
      tierMultiplier = tier, jobType = jobType or "repo", economy = economy or 1,
      recoveryEconomy = recoveryEconomy,
    }))
  end

  local NAN = 0 / 0

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

    { "recovery quote matches hand-computed RLS values at fee boundaries", function()
      -- Level 9: no fee, p = 2/22.  (1500 + 200 + 500) * (1 + 2 * (2/22)^2)
      t.near(pricing.recoveryQuote(2, 2, 9), 2200 * (1 + 2 * (2 / 22) ^ 2), 1e-9, "level 9")
      -- Level 10: fee 1500, p = 2/22.
      t.near(pricing.recoveryQuote(2, 2, 10), 3700 * (1 + 2 * (2 / 22) ^ 2), 1e-9, "level 10")
      -- Level 30: fee 3000, p = 12/22.
      t.near(pricing.recoveryQuote(2, 2, 30), 5200 * (1 + 2 * (12 / 22) ^ 2), 1e-9, "level 30")
    end },

    { "hub skill bonus is the repo steps scaled to +200 %", function()
      t.eq(pricing.skillBonus(1), 0, "level 1")
      t.near(pricing.skillBonus(11), 2 * 5 / 24, 1e-9, "level 11")
      t.eq(pricing.skillBonus(48), 2, "level 48")
      t.eq(pricing.skillBonus(50), 2, "capped")
    end },

    { "quote at level 11, Low tier, 2 + 2 km", function()
      -- (400 + 55*2 + 135*2) * 1.0 * (1 + 5/12) = 1105
      t.eq(quote(2, 2, 11, 1.0), 1105, "repo")
      t.eq(quote(2, 2, 11, 1.0, "tow"), 1216, "tow is 1.1x")
    end },

    { "economy multiplier scales the quote", function()
      t.eq(quote(2, 2, 11, 1.0, "repo", 0.72), 796, "1105 * 0.72")
    end },

    { "cap applies to very long heavy jobs", function()
      local amount, breakdown = pricing.quote({
        outboundKm = 3, loadedKm = 30, level = 30, tierMultiplier = 1.8, jobType = "repo", economy = 1,
      })
      t.eq(amount, math.floor(0.9 * pricing.recoveryQuote(3, 30, 30) + 0.5), "capped amount")
      t.truthy(breakdown.capped, "breakdown marks the cap")
    end },

    { "tow factor applies below the cap and is cut by it above", function()
      -- Standard, level 11, 2 + 2 km: 780 * 1.15 * (1 + 5/12) * 1.1 = 1397.9
      t.eq(quote(2, 2, 11, 1.15, "tow"), 1398, "below cap")
      t.eq(quote(3, 30, 30, 1.8, "tow"), quote(3, 30, 30, 1.8, "repo"), "same cap for both types")
    end },

    { "cap follows the recovery economy when the RLS sections differ", function()
      -- Long heavy job with a strong repo economy and a weak recovery economy.
      local strongRepo = quote(2, 20, 25, 1.8, "repo", 1.5, 0.7)
      local limit = 0.9 * pricing.recoveryQuote(2, 20, 25) * 0.7
      t.truthy(strongRepo <= limit + 0.5, "hub stays below what recovery pays now")
    end },

    { "quote never exceeds 90 % of the equivalent recovery quote", function()
      for level = 0, 50 do
        for _, tier in ipairs(TIERS) do
          for _, outboundKm in ipairs(DISTANCES) do
            for _, loadedKm in ipairs(DISTANCES) do
              for _, jobType in ipairs({ "repo", "tow" }) do
                for _, economy in ipairs({ 0.5, 0.72, 1, 1.4 }) do
                  for _, recoveryEconomy in ipairs({ 0.5, 1, 1.4 }) do
                    local limit = 0.9 * pricing.recoveryQuote(outboundKm, loadedKm, level) * recoveryEconomy
                    local amount = quote(outboundKm, loadedKm, level, tier, jobType, economy, recoveryEconomy)
                    if amount > limit + 0.5 then
                      error(string.format("level %d tier %.2f %s out %.1f loaded %.1f econ %.2f/%.2f: %d > %.1f",
                        level, tier, jobType, outboundKm, loadedKm, economy, recoveryEconomy, amount, limit))
                    end
                  end
                end
              end
            end
          end
        end
      end
    end },

    { "invalid numbers do not leak into money", function()
      t.eq(quote(NAN, 2, 11, 1.0), quote(0, 2, 11, 1.0), "NaN distance counts as zero")
      t.eq(quote(2, 2, NAN, 1.0), quote(2, 2, 0, 1.0), "NaN level counts as zero")
      t.eq(quote(2, 2, 11, 1.0, "repo", -1), 0, "negative economy pays nothing")
      t.eq(quote(2, 2, 11, 1.0, "repo", NAN), quote(2, 2, 11, 1.0, "repo", 1), "NaN economy falls back to neutral")
      t.raises(function() quote(2, 2, 11, nil) end, "missing tier multiplier is an error")
      t.raises(function() quote(2, 2, 11, NAN) end, "NaN tier multiplier is an error")
      t.raises(function() quote(2, 2, 11, 0) end, "zero tier multiplier is an error")
    end },

    { "negative or missing distances count as zero", function()
      t.eq(quote(-5, nil, 11, 1.0), quote(0, 0, 11, 1.0), "clamped")
    end },

    { "unknown job type is rejected", function()
      t.raises(function() quote(1, 1, 11, 1.0, "taxi") end)
    end },

    { "xp is RLS repo xp scaled gently by distance", function()
      -- RLS repo: (5 + 500 + round(2/2)) * 2 = 1012; * (9.5 + 2) / 14 = 831.3
      t.eq(pricing.xp({ tierBaseXp = 500, loadedKm = 2, jobType = "repo" }), 831, "2 km")
      -- (5 + 500 + 4) * 2 = 1018; * (9.5 + 8) / 14 = 1272.5
      t.eq(pricing.xp({ tierBaseXp = 500, loadedKm = 8, jobType = "repo" }), 1273, "8 km")
      t.eq(pricing.xp({ tierBaseXp = 500, loadedKm = 2, jobType = "tow" }), 914, "tow is 1.1x")
      local short = pricing.xp({ tierBaseXp = 500, loadedKm = 0.5, jobType = "repo" })
      local long = pricing.xp({ tierBaseXp = 500, loadedKm = 7, jobType = "repo" })
      t.truthy(long / short < 1.8, "a 7 km job gives well under twice the XP of a short one")
    end },

    { "settlement caps the damage penalty at half the quote", function()
      t.eq(pricing.settle(1000, 300), 700, "partial penalty")
      local payout, penalty = pricing.settle(1000, 5000)
      t.eq(payout, 500, "half the quote stays")
      t.eq(penalty, 500, "penalty capped")
      t.eq(select(2, pricing.settle(495, 5000)), 248, "rounded")
      t.eq(pricing.settle(1000, -50), 1000, "negative penalty ignored")
      t.eq(pricing.settle(1000, NAN), 1000, "NaN penalty ignored")
      t.eq(pricing.settle(-500, 100), 0, "negative quote pays nothing")
    end },

    { "driving within the allowance costs nothing", function()
      t.eq(pricing.selfDriveShare(0, 5000), 0, "towed")
      t.eq(pricing.selfDriveShare(200, 5000), 0, "at the allowance")
      local deduction, xpFactor = pricing.selfDrive(2000, 150, 5000)
      t.eq(deduction, 0, "no deduction")
      t.eq(xpFactor, 1, "full XP")
    end },

    { "driving beyond the allowance cuts pay down to a quarter and XP to zero", function()
      t.near(pricing.selfDriveShare(2600, 5000), 0.5, 1e-9, "half the route beyond the allowance")
      local deduction, xpFactor = pricing.selfDrive(2000, 2600, 5000)
      t.eq(deduction, 750, "three quarters of the quote times half")
      t.near(xpFactor, 0.5, 1e-9, "half XP")
      deduction, xpFactor = pricing.selfDrive(2000, 9000, 5000)
      t.eq(deduction, 1500, "whole route: a quarter of the quote stays")
      t.eq(xpFactor, 0, "no XP")
      t.eq(pricing.selfDriveShare(400, 100), 1, "route shorter than the allowance")
      t.eq(pricing.selfDriveShare(NAN, 5000), 0, "bad distance")
    end },

    { "custody fine is half the quote, at least the minimum", function()
      t.eq(pricing.custodyFine(1460), 730, "half the quote")
      t.eq(pricing.custodyFine(1461), 731, "rounded")
      t.eq(pricing.custodyFine(300), pricing.config.fineMin, "minimum")
      t.eq(pricing.custodyFine(NAN), pricing.config.fineMin, "bad quote")
      local quote = 2400
      t.eq(pricing.custodyFine(quote), select(2, pricing.settle(quote, 1e9)), "same as the largest damage penalty")
    end },
  }
end
