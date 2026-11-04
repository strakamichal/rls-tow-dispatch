#!/usr/bin/env bash
# Packages the mod folders into dist/tow_dispatch.zip for the BeamNG mods folder.
set -euo pipefail

cd "$(dirname "$0")/.."

MOD_DIRS=(lua scripts gameplay ui)
OUT=dist/tow_dispatch.zip
BUILD_FILE=lua/ge/extensions/towRepoHub/lib/build.lua

# A release must not ship the debug tools; --debug packages a test build anyway.
if [[ "${1:-}" != "--debug" ]] && grep -Eq '^\s*debugTools\s*=\s*true' "$BUILD_FILE"; then
  echo "Debug tools are on in $BUILD_FILE. Set debugTools = false for a release, or pass --debug." >&2
  exit 1
fi

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
