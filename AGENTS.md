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

- `lua/ge/extensions/towRepoHub/` — game engine Lua (offers, pricing, job flow);
  `core.lua` is the `towRepoHub_core` extension
- `scripts/towRepoHub/modScript.lua` — loads `towRepoHub_core` when the mod is active
- `gameplay/overhaul/phone/apps/towRepoHub.json` — RLS phone app definition (the `id` must equal
  the file name); it uses a top-level `component`, so RLS hosts it at `/overhaul/phone-app/towRepoHub`
  and passes `callLua` as a prop
- `ui/ui-vue/mods/towRepoHub/` — phone app UI (Vue)
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

- Tests: `tools/test.sh` (needs LuaJIT: `brew install luajit` / `scoop install luajit`).
  CI runs them on every push (`.github/workflows/tests.yml`).
- RLS source for reference: `tools/fetch-rls.sh` → `.cache/rls` (source files only,
  not committed). Search there instead of the GitHub API. Integration notes:
  [docs/rls-integration.md](docs/rls-integration.md).
- Package: `tools/package.sh` → `dist/tow_repo_hub.zip`. Releases ship without the phone app's
  debug tools: set `debugTools = false` in `lua/ge/extensions/towRepoHub/lib/build.lua` first;
  the script refuses to package while it is on (`--debug` packages a test build anyway).

On the Windows gaming PC (PowerShell; scripts not yet verified on a real install):

- Deploy unpacked for fast iteration: `tools/dev/deploy.ps1` → `mods/unpacked/tow_repo_hub`.
  Reload Lua in game with Ctrl+L; UI changes need Ctrl+F5 or a restart.
- Deploy as players install it: `tools/dev/deploy.ps1 -Zip`.
- Follow the log: `tools/dev/log.ps1` (filtered to hub messages, errors and warnings).
- Preview the phone app without the game: `tools/dev/preview.ps1` (Windows, Edge) or
  `tools/dev/preview.sh` (macOS/Linux, Chrome or Chromium) renders the real
  `PhoneTowRepoHub.vue` with sample data from `tools/dev/preview/states.js` to
  `.cache/preview/<state>.png` (headless Edge, Vue and Sass from CDNs). The default 350 × 626 px
  screen matches the RLS phone at 2560 × 1440. Use it for every layout change before deploying;
  add a state to `states.js` for new screens, and keep the sample payload in step with
  `towRepoHub_core.getState`.
- Both scripts look for the BeamNG user folder under `%LOCALAPPDATA%`; pass `-UserFolder`
  if it lives elsewhere (launcher: Manage User Folder → Open in Explorer).

## Verification

Pure logic (pricing, filtering) is covered by Lua tests that run without the game.
Everything else is verified in game on BeamNG 0.40 with RLS 2.8; every acceptance
criterion needs evidence (log excerpt, screenshot or test output).
