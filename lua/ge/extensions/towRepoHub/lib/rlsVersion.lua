-- RLS version check. Pure functions, no game API, so they run under plain LuaJIT in tests.
-- RLS has no version getter; it reads /gameplay/overhaul/version.json ad hoc (docs/rls-integration.md 1.5).

local M = {}

M.FILE = "/gameplay/overhaul/version.json"
M.SUPPORTED = "2.8.x"

local SUPPORTED_PATTERN = "^2%.8%."

-- Returns the version string from the decoded version.json table, or nil.
function M.versionString(data)
  if type(data) ~= "table" or type(data.version_string) ~= "string" or data.version_string == "" then
    return nil
  end
  return data.version_string
end

-- Returns status, version: status is "ok", "unsupported" or "missing".
function M.check(data)
  local version = M.versionString(data)
  if not version then return "missing", nil end
  if version:match(SUPPORTED_PATTERN) then return "ok", version end
  return "unsupported", version
end

return M
