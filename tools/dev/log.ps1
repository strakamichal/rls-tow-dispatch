# Follows beamng.log, showing hub messages, Lua errors and warnings.
#
#   tools/dev/log.ps1              # live, filtered
#   tools/dev/log.ps1 -All         # live, everything
#   tools/dev/log.ps1 -Tail 300    # how many existing lines to show first

param(
  [switch]$All,
  [int]$Tail = 100,
  [string]$UserFolder
)

$ErrorActionPreference = "Stop"

if (-not $UserFolder) {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA "BeamNG\BeamNG.drive\current"),
    (Join-Path $env:LOCALAPPDATA "BeamNG.drive\current")
  )
  $UserFolder = $candidates | Where-Object { Test-Path (Join-Path $_ "beamng.log") } | Select-Object -First 1
  if (-not $UserFolder) { throw "beamng.log not found. Pass -UserFolder." }
}

$log = Join-Path $UserFolder "beamng.log"
$pattern = "towRepoHub|tow_repo_hub|\|E\||\|W\||error|traceback"

if ($All) {
  Get-Content $log -Tail $Tail -Wait
} else {
  Get-Content $log -Tail $Tail -Wait | Select-String -Pattern $pattern
}
