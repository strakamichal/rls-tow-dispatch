return function(t)
  local rlsVersion = require("towRepoHub/lib/rlsVersion")

  return {
    { "2.8.x is supported", function()
      t.eq(rlsVersion.check({ version_string = "2.8.0" }), "ok", "2.8.0")
      t.eq(rlsVersion.check({ version_string = "2.8.12" }), "ok", "2.8.12")
      local _, version = rlsVersion.check({ version_string = "2.8.0" })
      t.eq(version, "2.8.0", "version is returned")
    end },

    { "other versions are unsupported", function()
      t.eq(rlsVersion.check({ version_string = "2.9.0" }), "unsupported", "2.9.0")
      t.eq(rlsVersion.check({ version_string = "2.7.4" }), "unsupported", "2.7.4")
      t.eq(rlsVersion.check({ version_string = "12.8.0" }), "unsupported", "12.8.0")
      t.eq(rlsVersion.check({ version_string = "2.80" }), "unsupported", "2.80")
    end },

    { "a missing or malformed file reports missing", function()
      t.eq(rlsVersion.check(nil), "missing", "nil")
      t.eq(rlsVersion.check({}), "missing", "no field")
      t.eq(rlsVersion.check({ version_string = "" }), "missing", "empty")
      t.eq(rlsVersion.check({ version_string = 28 }), "missing", "number")
    end },
  }
end
