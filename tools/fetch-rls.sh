#!/usr/bin/env bash
# Fetches the RLS Career Overhaul source for reference into .cache/rls (not committed).
# Usage: tools/fetch-rls.sh [tag]   (default: the RLS version this add-on targets)
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-v2.8.0}"
DEST=.cache/rls

rm -rf "$DEST"
# Source only: skip large binary assets (textures, models, sounds).
git -c advice.detachedHead=false clone -q --depth 1 --filter=blob:limit=512k --no-checkout --branch "$TAG" https://github.com/RLS-Modding/rls_career_overhaul.git "$DEST"
git -C "$DEST" sparse-checkout set --no-cone '*.lua' '*.json' '*.js' '*.vue' '*.md'
git -c advice.detachedHead=false -C "$DEST" checkout -q
echo "RLS $TAG in $DEST"
