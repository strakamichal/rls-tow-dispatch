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

  local NAN = 0 / 0

  return {
    { "repo skill bonus follows the RLS repo curve", function()
      t.eq(pricing.repoSkillBonus(1), 0, "level 1")
      t.near(pricing.repoSkillBonus(11), 5 / 6, 1e-9, "level 11")
      t.eq(pricing.repoSkillBonus(48), 4, "level 48")
      t.eq(pricing.repoSkillBonus(50), 4, "level 50 stays capped")
      t.eq(pricing.repoSkillBonus(-3), 0, "negative level")
    end },

    { "hub skill bonus is the RLS repo curve", function()
      for level = -3, 52 do
        t.eq(pricing.skillBonus(level), pricing.repoSkillBonus(level), "level " .. level)
      end
    end },

    { "quote at level 11, Low tier, 2 + 2 km", function()
      -- (400 + 55*2 + 135*2) * 1.0 * (1 + 5/6) = 1430
      t.eq(quote(2, 2, 11, 1.0), 1430, "repo")
      t.eq(quote(2, 2, 11, 1.0, "tow"), 1573, "tow is 1.1x")
    end },

    { "economy multiplier scales the quote", function()
      t.eq(quote(2, 2, 11, 1.0, "repo", 0.72), 1030, "1430 * 0.72")
    end },

    { "tow factor applies to higher tiers", function()
      -- Standard, level 11, 2 + 2 km: 780 * 1.15 * (1 + 5/6) * 1.1 = 1808.95
      t.eq(quote(2, 2, 11, 1.15, "tow"), 1809, "tow")
    end },

    { "long heavy jobs are not capped", function()
      local amount, breakdown = pricing.quote({
        outboundKm = 3, loadedKm = 30, level = 30, tierMultiplier = 1.8, jobType = "repo", economy = 1,
      })
      -- (400 + 55*3 + 135*30) * 1.8 * (1 + 4*15/24) = 29074.5
      t.eq(amount, 29075, "full formula")
      t.eq(breakdown.capped, nil, "no cap in the breakdown")
    end },

    { "quote grows with distance, tier and level", function()
      for level = 0, 49 do
        for i = 2, #TIERS do
          for j = 2, #DISTANCES do
            local here = quote(2, DISTANCES[j], level, TIERS[i], "tow")
            t.truthy(here >= quote(2, DISTANCES[j - 1], level, TIERS[i], "tow"), "distance")
            t.truthy(here >= quote(2, DISTANCES[j], level, TIERS[i - 1], "tow"), "tier")
            t.truthy(quote(2, DISTANCES[j], level + 1, TIERS[i], "tow") >= here, "level")
          end
        end
      end
    end },

    { "own rig bonus: 10 % for an own rig, 5 % for an own vehicle with a rented trailer", function()
      t.eq(pricing.ownRigBonusShare(true, nil), 0.10, "own flatbed, wheel lift or rope")
      t.eq(pricing.ownRigBonusShare(true, true), 0.10, "own vehicle and own trailer")
      t.eq(pricing.ownRigBonusShare(true, false), 0.05, "own vehicle, rented trailer")
      t.eq(pricing.ownRigBonusShare(false, true), 0, "rented vehicle, own trailer")
      t.eq(pricing.ownRigBonusShare(false, false), 0, "rented vehicle and trailer")
      t.eq(pricing.ownRigBonusShare(false, nil), 0, "rented flatbed")
      t.eq(pricing.ownRigBonusShare(nil, nil), 0, "no rig found")
    end },

    { "own rig bonus is the share of the quote", function()
      t.eq(pricing.ownRigBonus(4115, 0.10), 412, "10 %")
      t.eq(pricing.ownRigBonus(4115, 0.05), 206, "5 %")
      t.eq(pricing.ownRigBonus(4115, 0), 0, "none")
      t.eq(pricing.ownRigBonus(NAN, 0.10), 0, "NaN quote")
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
