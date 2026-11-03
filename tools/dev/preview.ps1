# Renders the phone app to PNG without the game: the real PhoneTowRepoHub.vue with sample data.
#
#   tools/dev/preview.ps1                    # every state from tools/dev/preview/states.js
#   tools/dev/preview.ps1 -State list,active # some states
#   tools/dev/preview.ps1 -Open              # also opens the list state in the default browser
#   tools/dev/preview.ps1 -Height 1200       # a taller screen to see more of a long list
#
# Writes .cache/preview/<state>.png (not committed). Needs Microsoft Edge and internet access for
# Vue, vue3-sfc-loader and Sass from CDNs. The CSS matches the game closely but not exactly: the
# game's UI scaling and phone shell differ a little, so check final tweaks in game.

param(
  [string[]]$State,
  [switch]$Open,
  [int]$Scale = 2,
  # The RLS phone screen in CSS px, measured in game at 2560 × 1440.
  [int]$Width = 350,
  [int]$Height = 626
)

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Out = Join-Path $Repo ".cache\preview"
New-Item -ItemType Directory -Force $Out | Out-Null

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge not found." }

$sfc = [IO.File]::ReadAllText((Join-Path $Repo "ui\ui-vue\mods\towRepoHub\PhoneTowRepoHub.vue"))
$states = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "preview\states.js"))
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "preview\preview.html"))
# JSON string literal; "</" escaped so the app's own </script> cannot end the inline script.
$sfcJson = ($sfc | ConvertTo-Json -Compress).Replace("</", "<\/")
$html = $template.Replace("/*STATES*/", $states).Replace("/*SFC*/", $sfcJson)
$page = Join-Path $Out "preview.html"
[IO.File]::WriteAllText($page, $html, (New-Object System.Text.UTF8Encoding $false))

if (-not $State) {
  $State = [regex]::Matches($states, '(?m)^\s{4}(\w+): Object\.assign') | ForEach-Object { $_.Groups[1].Value }
  $State += [regex]::Matches($states, "PREVIEW_STATES\.(\w+) = window") | ForEach-Object { $_.Groups[1].Value }
}

$url = "file:///" + ($page -replace '\\', '/')
foreach ($name in $State) {
  $png = Join-Path $Out "$name.png"
  if (Test-Path $png) { Remove-Item $png }
  # Start-Process: Edge logs diagnostics to stderr, which Windows PowerShell would treat as an error.
  $arguments = @("--headless=new", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
    "--force-device-scale-factor=$Scale", "--window-size=$Width,$Height", "--virtual-time-budget=15000",
    "--screenshot=`"$png`"", "`"$url`?state=$name&w=$Width&h=$Height`"")
  Start-Process -FilePath $edge -ArgumentList $arguments -Wait -WindowStyle Hidden
  if (Test-Path $png) { Write-Host "Rendered $png" } else { Write-Warning "No image for $name" }
}

if ($Open) { Start-Process "$url`?state=list" }
