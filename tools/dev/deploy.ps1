# Installs the add-on into the BeamNG user folder for testing.
#
#   tools/dev/deploy.ps1            # unpacked copy in mods/unpacked/tow_repo_hub (fast iteration)
#   tools/dev/deploy.ps1 -Zip       # packaged zip in mods/, as players install it
#   tools/dev/deploy.ps1 -UserFolder "D:\BeamNG\userfolder"
#
# After an unpacked deploy, Lua changes reload in game with Ctrl+L; UI changes need Ctrl+F5
# or a game restart. Unverified on a real install yet — fix paths here when they differ.

param(
  [switch]$Zip,
  [string]$UserFolder
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$ModName = "tow_repo_hub"
$ModDirs = @("lua", "scripts", "gameplay", "ui")

function Find-UserFolder {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA "BeamNG\BeamNG.drive\current"),
    (Join-Path $env:LOCALAPPDATA "BeamNG.drive\current")
  )
  # Older layouts keep one folder per game version, e.g. BeamNG.drive\0.40
  foreach ($root in @((Join-Path $env:LOCALAPPDATA "BeamNG\BeamNG.drive"), (Join-Path $env:LOCALAPPDATA "BeamNG.drive"))) {
    if (Test-Path $root) {
      $latest = Get-ChildItem $root -Directory | Where-Object { $_.Name -match '^\d+\.\d+' } |
        Sort-Object { [version]($_.Name -replace '[^\d.]', '') } -Descending | Select-Object -First 1
      if ($latest) { $candidates += $latest.FullName }
    }
  }
  foreach ($candidate in $candidates) {
    if (Test-Path (Join-Path $candidate "mods")) { return $candidate }
  }
  throw "BeamNG user folder not found. Pass -UserFolder (launcher: Manage User Folder -> Open in Explorer)."
}

if (-not $UserFolder) { $UserFolder = Find-UserFolder }
$Mods = Join-Path $UserFolder "mods"
$present = $ModDirs | Where-Object { Test-Path (Join-Path $Repo $_) }
if (-not $present) { throw "Nothing to deploy yet: none of $($ModDirs -join ', ') exist." }

$zipPath = Join-Path $Mods "$ModName.zip"
$unpackedPath = Join-Path $Mods "unpacked\$ModName"

if ($Zip) {
  if (Test-Path $unpackedPath) { Remove-Item $unpackedPath -Recurse -Force }
  # tar.exe (bsdtar, Windows 10+) writes forward-slash entries; Compress-Archive in
  # Windows PowerShell 5.1 writes backslashes, which BeamNG does not read correctly.
  Push-Location $Repo
  try {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    tar.exe -a -c -f $zipPath @present LICENSE
    if ($LASTEXITCODE -ne 0) { throw "tar.exe failed" }
  } finally { Pop-Location }
  Write-Host "Deployed $zipPath"
} else {
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
  foreach ($dir in $present) {
    robocopy (Join-Path $Repo $dir) (Join-Path $unpackedPath $dir) /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $dir" }
  }
  Write-Host "Deployed $unpackedPath"
}
