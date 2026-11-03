-- Tow & Repo Hub game engine entry point (towRepoHub_core).
-- Step 1 skeleton: answers the phone app with the RLS version status and career state.

local rlsVersion = require("towRepoHub/lib/rlsVersion")

local M = {}

local LOG_TAG = "towRepoHub"

local versionStatus, versionString

local function readRlsVersion()
  local data = jsonReadFile and jsonReadFile(rlsVersion.FILE) or nil
  versionStatus, versionString = rlsVersion.check(data)
  if versionStatus == "ok" then
    log("I", LOG_TAG, "RLS " .. versionString .. " detected")
  elseif versionStatus == "unsupported" then
    log("W", LOG_TAG, "RLS " .. versionString .. " is not supported, expected " .. rlsVersion.SUPPORTED)
  else
    log("W", LOG_TAG, "RLS version file not found: " .. rlsVersion.FILE)
  end
end

local function careerActive()
  return (overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive()) and true or false
end

-- Called by the phone app through callLua('towRepoHub_core.getState').
local function getState()
  if not versionStatus then readRlsVersion() end
  return {
    rlsVersion = versionString,
    rlsVersionStatus = versionStatus,
    supportedVersion = rlsVersion.SUPPORTED,
    careerActive = careerActive(),
  }
end

local function onExtensionLoaded()
  readRlsVersion()
  log("I", LOG_TAG, "loaded")
end

M.getState = getState
M.onExtensionLoaded = onExtensionLoaded

return M
