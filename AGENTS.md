# Tow & Repo Hub — project guide

Everything in this repo is written in English: code, comments, docs, commits, issues.

## What this is

A BeamNG.drive mod that adds a repo job board to RLS Career Overhaul.
Specification: [docs/spec.md](docs/spec.md).

## Target versions

- BeamNG.drive 0.40.x (Windows)
- RLS Career Overhaul 2.8.0 — source: https://github.com/RLS-Modding/rls_career_overhaul

## Layout

The repo root is the mod root; the packaged zip mirrors it.

- `lua/ge/extensions/towRepoHub/` — game engine Lua (offers, pricing, job flow)
- `gameplay/overhaul/phone/apps/tow-repo-hub.json` — RLS phone app definition
- `ui/ui-vue/mods/tow_repo_hub/` — phone app UI (Vue)
- `tests/` — Lua tests for pure logic, run outside the game
- `tools/` — packaging and dev scripts
- `docs/` — specification and notes

## Integrating with RLS

- Use RLS public modules and hooks; do not copy RLS source files.
- RLS discovers phone apps from `gameplay/overhaul/phone/apps/*.json`; see
  `lua/ge/extensions/overhaul/lib/phone/appCatalog.lua` in RLS for the schema.
- Reference implementations: `jobs/recovery/offers.lua`, `jobs/recovery/rewards.lua`
  and `jobs/repo.lua` in RLS.

## Build and run

- Tests: `tools/test.sh` (needs LuaJIT: `brew install luajit` / `scoop install luajit`)
- Package: `tools/package.sh` → `dist/tow_repo_hub.zip`
- Install: copy the zip into the BeamNG user folder `mods/` (keep it zipped),
  enable it in Mods → Manager, restart the game.
- Logs: `beamng.log` in the BeamNG user folder.

## Verification

Pure logic (pricing, filtering) is covered by Lua tests that run without the game.
Everything else is verified in game on BeamNG 0.40 with RLS 2.8; every acceptance
criterion needs evidence (log excerpt, screenshot or test output).
