#!/usr/bin/env bash
# Renders the phone app to PNG without the game: the real PhoneTowRepoHub.vue with sample data.
# macOS/Linux counterpart of tools/dev/preview.ps1; both fill the same template.
#
#   tools/dev/preview.sh                      # every state from tools/dev/preview/states.js
#   tools/dev/preview.sh list active          # some states
#   HEIGHT=1200 tools/dev/preview.sh list     # a taller screen to see more of a long list
#   OPEN=1 tools/dev/preview.sh               # also opens the list state in the browser
#
# Writes .cache/preview/<state>.png (not committed). Needs Chrome or Chromium and internet access
# for Vue, vue3-sfc-loader and Sass from CDNs. Check final tweaks in game: the game's UI scaling
# and phone shell differ a little.
set -euo pipefail

cd "$(dirname "$0")/../.."

SCALE="${SCALE:-2}"
# The RLS phone screen in CSS px, measured in game at 2560 × 1440.
WIDTH="${WIDTH:-350}"
HEIGHT="${HEIGHT:-626}"
OUT=.cache/preview
mkdir -p "$OUT"

browser=""
for candidate in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" \
  "$(command -v google-chrome || true)" "$(command -v chromium || true)" "$(command -v chromium-browser || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then browser="$candidate"; break; fi
done
[[ -n "$browser" ]] || { echo "Chrome or Chromium not found." >&2; exit 1; }

page="$PWD/$OUT/preview.html"
# Same filling as preview.ps1: the SFC as a JSON string literal with "</" escaped, so the app's
# own </script> cannot end the inline script.
python3 - "$page" <<'EOF'
import json, sys
sfc = open("ui/ui-vue/mods/towRepoHub/PhoneTowRepoHub.vue", encoding="utf-8").read()
states = open("tools/dev/preview/states.js", encoding="utf-8").read()
template = open("tools/dev/preview/preview.html", encoding="utf-8").read()
sfc_json = json.dumps(sfc, ensure_ascii=False).replace("</", "<\\/")
html = template.replace("/*STATES*/", states).replace("/*SFC*/", sfc_json)
open(sys.argv[1], "w", encoding="utf-8").write(html)
EOF

if [[ $# -gt 0 ]]; then
  names=("$@")
else
  # Same discovery as preview.ps1: top-level states and the ones added later in states.js.
  names=()
  while IFS= read -r name; do names+=("$name"); done < <(
    grep -E '^ {4}[A-Za-z0-9_]+: Object\.assign' tools/dev/preview/states.js | sed -E 's/^ {4}([A-Za-z0-9_]+):.*/\1/'
    grep -oE 'PREVIEW_STATES\.[A-Za-z0-9_]+ = window' tools/dev/preview/states.js | sed -E 's/PREVIEW_STATES\.([A-Za-z0-9_]+) = window/\1/'
  )
fi

url="file://$page"
for name in "${names[@]}"; do
  png="$PWD/$OUT/$name.png"
  rm -f "$png"
  "$browser" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor="$SCALE" --window-size="$WIDTH,$HEIGHT" --virtual-time-budget=15000 \
    --screenshot="$png" "$url?state=$name&w=$WIDTH&h=$HEIGHT" >/dev/null 2>&1 || true
  if [[ -f "$png" ]]; then echo "Rendered $OUT/$name.png"; else echo "No image for $name" >&2; fi
done

if [[ "${OPEN:-}" == "1" ]]; then open "$url?state=list" 2>/dev/null || xdg-open "$url?state=list"; fi
