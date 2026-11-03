#!/usr/bin/env bash
# Runs the pure-logic Lua tests with LuaJIT (the Lua flavour BeamNG uses).
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v luajit >/dev/null; then
  echo "luajit not found (macOS: brew install luajit, Windows: scoop install luajit)" >&2
  exit 1
fi

luajit tests/run.lua tests/*_test.lua
