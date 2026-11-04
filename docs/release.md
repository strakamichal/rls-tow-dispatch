# Release checklist

How to ship a version of Tow Dispatch. Written for the first release, 1.0.0; later releases
follow the same steps.

## 0. Before the first release

Once, before 1.0.0; repeat the in-game checks for big changes.

- In game:
  - **New career:** level 1, starting money, no tow truck. Can a new player take a first
    Low Value job? If it needs a car trailer or a cheap truck, say so in the in-app help.
  - **Uninstall mid-job:** active job, save, disable the mod, load the career. RLS must load
    without errors and nothing of the job may be left behind (target vehicle, reservation).
  - **West Coast USA:** a few full jobs; it is the most played RLS map.
- Watch RLS releases on GitHub (Watch → Custom → Releases) and retest after each one;
  the add-on uses internal RLS calls that can change without notice.
- Let the RLS authors know about the add-on (Discord or GitHub) and which RLS internals it
  uses (see docs/rls-integration.md).
- `CHANGELOG.md` has the section for the version.

## 1. Prepare the code

Done for 1.0.0; for a later version only the version number and the CHANGELOG change.

1. Start from a clean `main` that is pushed (`git status`, `git log origin/main..`).
2. Version: `version` in `lua/ge/extensions/towRepoHub/lib/build.lua` (`"1.0.0"`, or
   `"1.0.0-beta.1"` for a pre-release). The phone footer shows it: `Tow Dispatch 1.0.0 – RLS 2.8.0`.
3. Debug tools off: `debugTools = false` in the same file (the default on `main`; turn it on only
   locally for testing). The phone then gets no `state.debug` and the debug functions refuse to run.
4. `CHANGELOG.md`: a section `## <version>`; replace "unreleased" with the date. The release
   workflow uses this section as the release notes (a pre-release falls back to its base version).
5. Run the tests: `tools/test.sh` (or `luajit tests/run.lua tests/*_test.lua` in PowerShell).
6. Render the phone screens: `tools/dev/preview.ps1` and check `list`, `active`, `delivery`,
   `complete`, `help` and `empty` in `.cache/preview/` (the preview data shows the debug panel;
   the game does not).

The zip is `tow_dispatch.zip`. Nothing inside the mod depends on the zip name: the extension
(`towRepoHub_core`), the phone app id (`towRepoHub`) and the save folder (`career/towRepoHub`)
stay, so existing saves keep their jobs. `tools/dev/deploy.ps1` removes copies under the old name
(`tow_repo_hub`) from the user folder, so the game never loads the mod twice.

## 2. Build and install it like a player

1. On Windows: `tools/dev/deploy.ps1 -Zip` builds `tow_dispatch.zip` with `tar.exe`, installs it in
   `mods/`, removes the unpacked copy and puts the same zip in `dist/`. (`tools/package.sh` needs
   `zip`, which Git Bash on Windows does not have; the release workflow uses it on Linux.)
2. Restart the game (not just Ctrl+L) and load an RLS career:
   - the mod manager lists `tow_dispatch` (only the file name until beamng.com adds metadata);
   - the log shows `towRepoHub: RLS 2.8.0 detected` and `loaded`, and no errors from the mod;
   - the phone shows **Tow Dispatch** with its icon; offers arrive; no debug panel; the footer
     shows the version;
   - one full job: accept, load, deliver, payout in Wallet under Recovery, XP;
   - save, reload the save: the board and an active job come back.

## 3. Publish on GitHub

`.github/workflows/release.yml` does the build when a version tag is pushed:

1. Commit the release changes (`Release 1.0.0`) and push; CI runs the tests.
2. Tag and push the tag:

   ```bash
   git tag -a v1.0.0 -m "Tow Dispatch 1.0.0"
   git push origin v1.0.0
   ```

3. The workflow runs the tests, checks that the tag matches `version` in `lib/build.lua`, packages
   the zip (refused while `debugTools` is on), checks its contents (forward slashes; only `lua`,
   `scripts`, `gameplay`, `ui` and `LICENSE`) and creates a **draft** release with the zip and the
   CHANGELOG section as notes. A tag with a suffix (`v1.0.0-beta.1`) becomes a pre-release.
4. Check the draft on GitHub (notes, zip) and press **Publish**. Nothing is public before that.
5. README: replace "Not released yet" with the install steps and a link to the release.

To try the build without a tag: Actions → release → Run workflow builds the zip as an artifact and
creates no release.

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
- Tested on The Gap (OwnTheBank) and West Coast USA; other RLS maps should work but are not tested yet.
- A job started on one map waits there while you travel; a car on a flatbed does not travel
  with you.
- One active job at a time.
