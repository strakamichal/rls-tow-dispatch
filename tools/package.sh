#!/usr/bin/env bash
# Packages the mod folders into dist/tow_repo_hub.zip for the BeamNG mods folder.
set -euo pipefail

cd "$(dirname "$0")/.."

MOD_DIRS=(lua scripts gameplay ui)
OUT=dist/tow_repo_hub.zip

present=()
for dir in "${MOD_DIRS[@]}"; do
  [[ -d "$dir" ]] && present+=("$dir")
done

if [[ ${#present[@]} -eq 0 ]]; then
  echo "Nothing to package yet: none of ${MOD_DIRS[*]} exist." >&2
  exit 1
fi

mkdir -p dist
rm -f "$OUT"
zip -qr "$OUT" "${present[@]}" LICENSE -x '*.DS_Store'
echo "Packaged $OUT"
