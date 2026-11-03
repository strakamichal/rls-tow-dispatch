return function(t)
  local tow = require("towRepoHub/lib/tow")

  local function car(extra)
    local info = { Type = "Car", model_key = "covet", Value = 18000, Weight = 1100, ["Fuel Type"] = "Gasoline" }
    for k, v in pairs(extra or {}) do info[k] = v end
    return info
  end

  local function sequence(values)
    local i = 0
    return function()
      i = i + 1
      return values[i] or 0
    end
  end

  return {
    { "value bands map to RLS repo tiers", function()
      t.eq(tow.tierKey(car({ Value = 24999 })), "junkerVeh", "below 25k")
      t.eq(tow.tierKey(car({ Value = 25000 })), "smallVeh", "25k")
      t.eq(tow.tierKey(car({ Value = 75000 })), "fleetVeh", "75k")
      t.eq(tow.tierKey(car({ Value = 150000 })), "highEndVeh", "150k")
      t.eq(tow.tierKey(car({ Value = 900000 })), "exoticVeh", "900k")
    end },

    { "heavy vehicles get the heavy tier", function()
      t.eq(tow.tierKey(car({ Weight = 3600 })), "heavyVeh", "over 3.5 t")
      t.eq(tow.tierKey(car({ Type = "Truck", Weight = 2000 })), "heavyVeh", "truck")
      t.eq(tow.tierKey(car({ Type = "Bus" })), "heavyVeh", "bus")
      t.eq(tow.tierKey(car({ Weight = 3500 })), "junkerVeh", "exactly 3.5 t is not heavy")
    end },

    { "aggregates stand in for missing fields", function()
      local info = car()
      info.Value, info.Weight = nil, nil
      info.aggregates = { Value = { min = 60000, max = 70000 }, Weight = { min = 4000, max = 4100 } }
      t.eq(tow.value(info), 60000, "value")
      t.eq(tow.tierKey(info), "heavyVeh", "heavy from aggregate weight")
    end },

    { "the vehicle type may come from the aggregate set", function()
      local info = car()
      info.Type = nil
      info.aggregates = { Type = { Car = true } }
      t.eq(tow.tierKey(info), "junkerVeh", "car from aggregates")
      info.aggregates.Type = { Truck = true }
      t.eq(tow.tierKey(info), "heavyVeh", "truck from aggregates")
      info.aggregates.Type = { Trailer = true }
      t.eq(tow.tierKey(info), nil, "trailer from aggregates")
    end },

    { "only plausible common road vehicles are eligible", function()
      t.truthy(tow.isEligible(car()), "a car")
      t.truthy(not tow.isEligible(car({ Type = "Trailer" })), "trailer")
      t.truthy(not tow.isEligible(car({ model_key = "wl40" })), "blocked model")
      t.truthy(not tow.isEligible(car({ ["Config Type"] = "Police" })), "police")
      t.truthy(not tow.isEligible(car({ Value = 100 })), "too cheap")
      t.truthy(not tow.isEligible(car({ Value = 50000000 })), "implausible")
      local noValue = car()
      noValue.Value = nil
      t.truthy(not tow.isEligible(noValue), "no value")
      t.eq(tow.tierKey(car({ Type = "Trailer" })), nil, "no tier")
    end },

    { "electric and hybrid vehicles are detected", function()
      t.truthy(tow.isElectric(car({ ["Fuel Type"] = "Electric" })), "electric")
      local hybrid = car({ aggregates = { Powertrain = { Hybrid = true } } })
      hybrid["Fuel Type"] = nil
      t.truthy(tow.isElectric(hybrid), "hybrid aggregate")
      t.truthy(not tow.isElectric(car()), "gasoline")
    end },

    { "tier labels say Tow", function()
      t.eq(tow.tierLabel("Low Value Repo"), "Low Value Tow", "repo suffix")
      t.eq(tow.tierLabel("Heavy"), "Heavy Tow", "no suffix")
    end },

    { "faults: one primary, sometimes worn; electric only flat", function()
      local faults = tow.pickFaults(sequence({ 0.0, 0.9 }), false)
      t.eq(faults[1], "fuel", "first fault")
      t.eq(#faults, 1, "no wear")
      faults = tow.pickFaults(sequence({ 0.99, 0.1 }), false)
      t.eq(faults[1], "overheat", "last fault")
      t.eq(faults[2], "worn", "worn added")
      t.eq(tow.pickFaults(sequence({ 0.9 }), true)[1], "flat", "electric")
      t.eq(tow.faultLabel({ "flat", "worn" }), "Flat tyre, Worn", "label")
    end },

    { "heavy vehicles never go home", function()
      t.eq(tow.destinationKind(function() return 0 end, true, true), "service", "heavy")
      t.eq(tow.destinationKind(function() return 0 end, false, false), "service", "no garages")
      t.eq(tow.destinationKind(function() return 0 end, false, true), "home", "home")
      t.eq(tow.destinationKind(function() return 0.9 end, false, true), "service", "service")
    end },
  }
end
