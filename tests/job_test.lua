return function(t)
  local job = require("towRepoHub/lib/job")

  local function cond(integrityValue) return { integrityValue = integrityValue } end

  return {
    { "the baseline is requested once, within 30 m", function()
      t.truthy(not job.needsBaseline({}, 31), "too far")
      t.truthy(job.needsBaseline({}, 30), "at 30 m")
      t.truthy(not job.needsBaseline({ baselineRequested = true }, 5), "already requested")
      t.truthy(not job.needsBaseline({}, nil), "no position")
    end },

    { "custody starts after the vehicle moves more than 10 m", function()
      t.truthy(not job.reachesCustody({}, 10), "10 m")
      t.truthy(job.reachesCustody({}, 10.5), "10.5 m")
      t.truthy(not job.reachesCustody({ custody = true }, 50), "already in custody")
    end },

    { "delivery needs custody, 5 m and a stop", function()
      t.truthy(job.isDelivered({ custody = true }, 4.9, 0.5), "delivered")
      t.truthy(not job.isDelivered({ custody = false }, 1, 0), "never moved")
      t.truthy(not job.isDelivered({ custody = true }, 5.1, 0), "too far")
      t.truthy(not job.isDelivered({ custody = true }, 2, 1.5), "still moving")
    end },

    { "a fine applies only after custody", function()
      t.truthy(not job.endsWithFine({}), "before custody")
      t.truthy(job.endsWithFine({ custody = true }), "in custody")
    end },

    { "damage values the integrity lost per part", function()
      local values = { hood = 1000, door = 400 }
      local total, parts = job.damage(
        { hood = cond(1), door = cond(0.9), bumper = cond(1) },
        { hood = cond(0.5), door = cond(0.9), bumper = cond(0.99) },
        function(path) return values[path] end)
      t.near(total, 500, 1e-9, "hood half lost, door unchanged, bumper below 2 %")
      t.eq(#parts, 1, "one damaged part")
      t.eq(parts[1].path, "hood", "hood listed")
    end },

    { "a part missing at the end is fully lost, unknown values use the default", function()
      local total = job.damage({ wheel = cond(0.8) }, {}, function() return nil end)
      t.near(total, 0.8 * job.config.defaultPartValue, 1e-9, "missing wheel")
    end },

    { "damage lists at most three parts, most valuable first", function()
      local baseline, final = {}, {}
      for i = 1, 5 do
        baseline["p" .. i] = cond(1)
        final["p" .. i] = cond(0)
      end
      local _, parts = job.damage(baseline, final, function(path) return tonumber(path:sub(2)) * 100 end)
      t.eq(#parts, 3, "capped")
      t.eq(parts[1].path, "p5", "most valuable first")
      t.eq(parts[3].path, "p3", "third")
    end },

    { "repairs and bad data never add damage", function()
      local total = job.damage({ a = cond(0.5), b = { integrityValue = 0 / 0 } }, { a = cond(1), b = cond(1) })
      t.eq(total, 0, "no damage")
      t.eq((job.damage(nil, nil)), 0, "no baseline")
    end },
  }
end
