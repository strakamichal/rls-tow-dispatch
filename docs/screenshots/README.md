# Screenshots

In-game screenshots taken on 2026-11-04 with BeamNG 0.40 and RLS 2.8 (JPEG, quality 92, 16:9).
The full-resolution PNG originals stay local in `.cache/screenshots/` (not committed). They are
not part of the mod zip.

## For beamng.com and the README

Suggested set, in this order (the first becomes the thumbnail):

| # | File | Map | What it shows |
|---|------|-----|---------------|
| 1 | `beamng-delivery-gap.jpg` | The Gap | A car on the rollback; the phone shows the delivery step, the self-drive meter and the cancel fine |
| 2 | `beamng-board-gap2.jpg` | The Gap | The rollback at a gas station; the phone shows the job board |
| 3 | `beamng-trailer.jpg` | West Coast | An overheating van steaming on a car trailer behind a pickup (game screenshot, Ctrl+P) |
| 4 | `beamng-completion.jpg` | West Coast | The completion screen with "Own rig bonus (+20%)" |

Alternatives:

- `beamng-board-gap.jpg`, `beamng-board-gap3.jpg`: the board with the rollback, other angles.
- `beamng-active-gap.jpg`: the active job before pickup (The Gap).
- `beamng-board.jpg`, `beamng-active.jpg`: the board and the active job on West Coast with a
  pickup and trailer.
- `beamng-trailer-top.jpg`: the van on the trailer from above.

The rollback in the The Gap shots is RLS's "Fink Industries Rollback" spawned from the console as
a temporary vehicle, so those jobs show no own rig bonus.

## Test evidence (`testing/`)

Screens kept as evidence for [docs/test-1.0.0.md](../test-1.0.0.md):

- `completion-own-rig-bonus.jpg`: own pickup on a rope, bonus +10 % (before the bonus was doubled).
- `completion-own-trailer.jpg`: own pickup and own trailer, bonus +10 % (before doubling).
- `completion-not-towed-damage.jpg`: driven 348 m and a damage penalty at the 50 % cap.
- `completion-restored-job.jpg`: a job restored after disabling and re-enabling the mod.
- `logbook.jpg`: finished tow jobs in the RLS logbook.

## Notes for better shots

- Use the game's own screenshot (Ctrl+P, or Alt+P for a larger one) rather than a desktop capture.
- Alt+U hides the whole UI; Ctrl+Alt+P opens photo mode.
- The bar at the bottom ("UI ▲Shortcuts ▲Covers …") is BeamNG's Interface Explorer; turn it off
  from its launcher or with `be:executeJS("bngVue.debug(false)")` in the GE console.
- Release screenshots need the phone without the debug panel (`debugTools = false`).
