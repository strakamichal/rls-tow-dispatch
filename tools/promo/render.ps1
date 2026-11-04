# Renders the promo graphics from tools/promo/promo.html to .cache/promo/out/<name>.png
# (1920 × 1080, headless Edge). Images come from .cache/promo/; see tools/promo/README.md.
#
#   tools/promo/render.ps1                       # all graphics
#   tools/promo/render.ps1 -Name delivery,board  # some

param([string[]]$Name = @("board", "delivery", "completion"))

$ErrorActionPreference = "Stop"
$Repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Out = Join-Path $Repo ".cache\promo\out"
New-Item -ItemType Directory -Force $Out | Out-Null

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw "Microsoft Edge not found." }

$url = "file:///" + ((Join-Path $PSScriptRoot "promo.html") -replace '\\', '/')
foreach ($n in $Name) {
  $png = Join-Path $Out "$n.png"
  if (Test-Path $png) { Remove-Item $png }
  # Start-Process: Edge logs to stderr, which Windows PowerShell would treat as an error.
  Start-Process -FilePath $edge -Wait -WindowStyle Hidden -ArgumentList @("--headless=new", "--disable-gpu",
    "--hide-scrollbars", "--allow-file-access-from-files", "--force-device-scale-factor=1",
    "--window-size=1920,1080", "--virtual-time-budget=8000", "--screenshot=`"$png`"", "`"$url`?g=$n`"")
  if (Test-Path $png) { Write-Host "Rendered $png" } else { Write-Warning "No output for $n" }
}
