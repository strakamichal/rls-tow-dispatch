# Release checklist

How to ship a version of Tow Dispatch. Written for the first release, 1.0.0; later releases
follow the same steps.

## 1. Prepare the code

1. Start from a clean `main` that is pushed (`git status`, `git log origin/main..`).
2. Version: add `version = "1.0.0"` to `lua/ge/extensions/towRepoHub/lib/build.lua`, send it
   in `getState` and show it in the phone footer next to the RLS version
   (`Tow Dispatch 1.0.0 · RLS 2.8.0`). Update `tools/dev/preview/states.js`.
3. Switch the debug tools off: `debugTools = false` in `lib/build.lua`. The phone then gets no
   `state.debug`: no debug panel, no teleport buttons, and the debug functions refuse to run.
4. Name the zip after the mod: `tow_dispatch.zip` instead of `tow_repo_hub.zip`.
   - `tools/package.sh`: `OUT=dist/tow_dispatch.zip`.
   - `tools/dev/deploy.ps1`: `$ModName = "tow_dispatch"`. Before the first deploy under the new
     name, remove `mods/unpacked/tow_repo_hub` and `mods/tow_repo_hub.zip` from the user folder,
     or the game loads the mod twice.
   - `README.md` and `AGENTS.md`: the new file name.
   - Nothing inside the mod depends on the zip name: the extension (`towRepoHub_core`), the phone
     app id (`towRepoHub`) and the save folder (`career/towRepoHub`) stay, so existing saves keep
     their jobs.
5. Run the tests: `tools/test.sh` (or `luajit tests/run.lua tests/*_test.lua` in PowerShell).
6. Render the phone screens: `tools/dev/preview.ps1` (or `tools/dev/preview.sh` on macOS) and check `list`, `active`, `delivery`,
   `complete`, `help` and `empty` in `.cache/preview/`: no debug panel, footer with the version.

## 2. Build and install it like a player

1. Package. `tools/package.sh` needs `zip`, which Git Bash on Windows does not have; on Windows
   use `tools/dev/deploy.ps1 -Zip`, which builds the zip with `tar.exe`, installs it in `mods/`
   and removes the unpacked copy. Copy that zip to `dist/` for the release.
2. Check the zip: entries use forward slashes, it contains `lua`, `scripts`, `gameplay`, `ui`
   and `LICENSE`, and nothing else (no `tests`, `tools`, `docs`, `.cache`).
3. Restart the game (not just Ctrl+L) and load an RLS career:
   - the mod manager lists `tow_dispatch` (only the file name until beamng.com adds metadata);
   - the log shows `towRepoHub: RLS 2.8.0 detected` and `loaded`, and no errors from the mod;
   - the phone shows **Tow Dispatch** with its icon; offers arrive; no debug panel;
   - one full job: accept, load, deliver, payout in Wallet under Recovery, XP;
   - save, reload the save: the board and an active job come back.

## 3. Publish on GitHub

1. Commit the release changes (`Release 1.0.0`) and push.
2. Tag and release with the zip attached:

   ```bash
   git tag -a v1.0.0 -m "Tow Dispatch 1.0.0"
   git push origin v1.0.0
   gh release create v1.0.0 dist/tow_dispatch.zip --title "Tow Dispatch 1.0.0" --notes-file <notes>
   ```

3. Release notes: what the mod does, requirements, installation, known limits (below).
4. README: replace "Not released yet" with the install steps and a link to the release.

## 4. Publish on beamng.com

The upload is done by the author in the browser (it needs their beamng.com account). Prepare:

- **Title:** Tow Dispatch for RLS Career Overhaul
- **Category:** the one RLS add-ons use (check RLS's own page); tag BeamNG 0.40.
- **Short description** (one line): Run a tow business in your RLS career: take breakdown
  calls on the phone and tow the cars home or to a service.
- **Description:** a new way to earn money in the RLS career as a tow company; requires RLS
  Career Overhaul 2.8.x and BeamNG 0.40; how to play (open Tow Dispatch on the phone, accept a
  call, load the car on your truck, deliver it home or to a service; driving it there yourself
  cuts the pay); tiers unlocked with the Recovery skill; the four faults; saving; known limits;
  link to GitHub for issues. The README's first two sections are a good base.
- **Images:** 1–4 in-game screenshots at 16:9 in daylight: the board on the phone, a car on a
  flatbed, the active job card, the delivery payout. The first one becomes the thumbnail, and
  the repository uses it for the mod manager card too.
- **File:** `tow_dispatch.zip`, the same as on GitHub.

After approval the repository adds `mod_info` with title, author, version and image; until then
the in-game mod manager shows the file name, type "unknown" and no author. This is expected.

## Known limits to state in the notes

- Built for RLS Career Overhaul 2.8.x on BeamNG 0.40; other RLS versions show a warning.
- Tested on The Gap (OwnTheBank); other RLS maps should work but are not tested yet.
- A job started on one map waits there while you travel; a car on a flatbed does not travel
  with you.
- One active job at a time.
