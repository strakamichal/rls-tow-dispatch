-- Minimal test runner for pure logic. Usage: luajit tests/run.lua tests/<name>_test.lua ...
-- Modules resolve like in game: require("towRepoHub/lib/pricing").

package.path = "lua/ge/extensions/?.lua;" .. package.path

local t = {}

function t.eq(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", message or "eq", tostring(expected), tostring(actual)), 2)
  end
end

function t.near(actual, expected, tolerance, message)
  if math.abs(actual - expected) > tolerance then
    error(string.format("%s: expected %s ± %s, got %s", message or "near",
      tostring(expected), tostring(tolerance), tostring(actual)), 2)
  end
end

function t.truthy(value, message)
  if not value then error(message or "expected truthy value", 2) end
end

function t.raises(fn, message)
  if pcall(fn) then error(message or "expected an error", 2) end
end

local passed, failed = 0, 0
for _, file in ipairs(arg) do
  local cases = dofile(file)(t)
  for _, case in ipairs(cases) do
    local ok, err = pcall(case[2])
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      print(string.format("FAIL %s :: %s\n     %s", file, case[1], err))
    end
  end
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
