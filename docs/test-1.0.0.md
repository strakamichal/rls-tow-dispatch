# In-game test checklist — 1.0.0

What is left to test in game before the first release. Every item needs evidence: a log line
(`tools/dev/log.ps1`), a screenshot or a note. Tick it off with the evidence next to it.

Setup: `tools/dev/deploy.ps1` (unpacked, debug tools on) for sections A–H; section I uses the
release zip. Restart the game before each section that loads a career.

## Already verified (before the own rig bonus, on The Gap only)

- Mod loads with RLS 2.8.0, no errors from the mod in the log.
- Board: all tiers, all four faults offered, diversity rules relax.
- Accept → load → deliver with payout and XP (3×), level-up with a tier unlock.
- Cancel free and with a fine (661); failure when the car is destroyed, no fine.
- Save and reload with an active job (`job vehicle restored`), several times.
- Faults applied on accept: flat tyre, failing engine.

## Bugs found (fixed in code 2026-11-04, in game: see "After the fixes")

- [x] **Duplicate spot keys** (West Coast `city.sites.json`, ~31 keys such as `Parking 1828.8`):
      the RLS reservation resolves the key to another spot, the vehicle spawns there (~350 m off
      the offer's spot) and custody starts at once (offer 32, fine 765 on cancel). Skip ambiguous
      spots, store the spot position, check the reserved spot against it on accept.
- [x] **Custody vs. arrival:** measure the 10 m move from where the vehicle actually spawned; add
      an "on site" phase when the player gets within ~30 m (no fine).
- [x] **Active job distance** is straight-line (200 m shown, 1.1 km by road); show the road
      distance like the board and navigation.
- [x] **Own rig bonus read only at delivery:** unloading the car and driving the last metres
      loses the whole bonus. Track the rig while towing instead: in `trackSelfDrive`, on ticks
      where the player is not in the target and it moved a valid step (0.5–50 m), check the rig
      (every ~4th such tick) and keep the lowest bonus share seen in the job (saved with it).
      At delivery use that share, shrunk by the driven part as now; never towed → 0. Switching
      to an own truck at the end cannot raise it. Pure function in `lib/pricing.lua` with tests;
      update the spec's *Own rig bonus*.
- [x] **Pickups favour big parking lots:** spots are drawn uniformly from all stalls, so on
      West Coast 53 % come from rows of 12+ stalls and only 10 % from single kerbside spots.
      Draw one `city.sites.json` entry (single spot or row) first, then a free stall in it:
      singles go to 53 %, a 21-row lot from 12.7 % to 5 %. Group stalls by their source entry,
      not by name (`Parking 1828` row stall 8 and a single spot share the name `Parking 1828.8`);
      check whether BeamNG keeps a link to the entry, else group in load order. Pure function in
      a lib with tests; update the spec's *Pickup spots*.
- [x] **Double the own rig bonus** (decision 2026-11-04, variant A): own rig 20 %, own truck with
      a rented trailer 10 %; the tier ladder stays, so an own rig pays ~9 % more than the balance
      reference (towing is more work than hauling a trailer; an own rig is costly and at risk).
      `lib/pricing.lua` config, tests, rerun `tools/balance.lua` and update the spec (*Pricing*,
      *Own rig bonus*, balance reference), CHANGELOG, README and the in-app help if it names
      percentages.

## A. Own rig bonus (new)

Each delivery logs `own rig bonus N` in the `job delivered` line.

- [x] Rented pickup and rented trailer from the Job Broker depot: no bonus, no bonus row on the
      completion screen. — 2026-11-04, West Coast, Wigeon: `own rig bonus 0, paid 1118`
- [x] Own truck, rented trailer: row "Own truck bonus (+5 %)". — 2026-11-04, West Coast:
      `quote 1128, own rig bonus 56, paid 1184` (56 = 5 % of 1128)
- [x] Own flatbed, or own truck and own trailer: row "Own rig bonus (+10 %)". — 2026-11-04,
      own pickup + own tiltdeck (added to the inventory from the console, inventoryId 2),
      Wigeon LX Sprint: Quote $1,099, "Own rig bonus (+10%)" +$110, Paid $1,209, level 6 → 7.
      The car was on the trailer at delivery (confirmed by the player), so the own-trailer
      branch is proven.
- [x] Own pickup with a rope or wheel lift (no trailer): row "Own rig bonus (+10 %)". —
      2026-11-04, own pickup + RLS Project Yankem winch rope (offer 42, Pessima). Screenshot:
      Quote $880, "Own rig bonus (+10%)" +$88, Paid $968, +470 XP, level 4 → 5 with
      "Budget jobs unlocked"
- [ ] Customer car driven more than 200 m: the bonus percentage shrinks (e.g. +7 %) in the same
      ratio as the XP. — not shown yet: the 348 m job ended with the player in the customer car,
      so there was no bonus to shrink. Needs: drive > 200 m, then load it and deliver it towed.
- [x] Unload before the destination and drive the customer car the last metres: the bonus is
      lost, the payout is not. — 2026-11-04, Covet 13S (flat tyre): `quote 1212, damage 1175,
      penalty 606, driven 348 m, not towed 121, own rig bonus 0, paid 485, xp 451`. Penalty hit
      the 50 % cap; check what caused 1175 of damage (driving on the flat tyre?).
- [ ] Unload before the destination, leave the car in the zone, sit in the own truck to deliver:
      note whether the bonus is paid (expected: yes) and whether that is acceptable.

## B. New payouts

Skipped (decision 2026-11-04): the payouts felt right in play; the comparison with RLS repo
rests on `tools/balance.lua`.

- [ ] At your level, a ~6 km tow vs. an RLS repo job of similar length: the tow pays about
      1.1–1.3× more per minute.
- [ ] A very short tow vs. a short repo job: repo pays more.
- [ ] One Exotic and one Heavy offer: the price looks reasonable next to a Job Broker delivery.

## C. New career

- [ ] New career at level 1 with starting money: rent a pickup and a car trailer at the Job
      Broker depot and finish a first Low Value job, as the in-app help says. — 2026-11-04,
      West Coast, level 1 → 2: `quote 1118, damage 0, paid 1118, xp 482`. Confirmed again by the
      player with another new career: few jobs available at the start (only Low Value unlocked
      at level 1), as intended.

## D. Uninstall mid-job

- [x] Accept a job, load the car, save, disable the mod, load the career: RLS loads without
      errors; no target vehicle, no parking reservation and no job UI are left behind. —
      2026-11-04, game restarted with the mod off, `autosave4` with job 74 (Sunburst on the own
      trailer): the car is gone, no `GELua.towRepoHub` line, no errors from RLS beyond three
      unrelated startup ones (`openPhone` binding, unload mode, achievement metric).
      Disabling the mod **without a restart** does not stop it: the extension keeps running,
      makes offers, saves and restores the job, with no phone app. Accepted, not handled or
      tested (decision 2026-11-04): changing mods needs a game restart.
- Manual saves lack RLS's `partRenames040.json` marker, so RLS asks to migrate them to 0.40;
  autosaves are fine. RLS issue, not ours; worth reporting to the RLS authors.
- [x] Enable the mod again and load the same save: note what happens to the job. — 2026-11-04,
      restart, `autosave4`: `state loaded … active job on rls_west_coast`, `job vehicle placed
      back on its carrier`, `job vehicle restored`; no warnings or errors from the mod. The
      restored job then completed on the own trailer: `quote 1811, damage 0, driven 20 m,
      own rig bonus 181, paid 1992, xp 678`, level 7 → 8.

## E. Old save after the update

Skipped (decision 2026-11-04): saves of earlier test builds are not supported; 1.0.0 is the first
release.

- [ ] Load `testtowcarrier` (active job on The Gap from 2026-11-03): the board and the active job
      come back, the vehicle is restored and can be delivered.

## F. West Coast USA

- [x] Board fills with 10–14 jobs, no errors. — 14 offers at start, no errors from the mod
- [x] Delivery to a home. — Commercial Garage (debug offer 41), level 2 → 4
- [x] Delivery to a dealership/service. — Bruckell Factory Store
- [x] One job with an own rig, one with a rented rig. — rented: no bonus; own truck: +5 %

## G. Remaining faults

- [x] Overheating: the car still drives a few metres onto the flatbed; no real radiator damage
      beyond the fault. — drove 25 m (`engine heated to 125 C` at 26 m), `damage 0`
- [x] Nearly empty tank: the car still drives a few metres onto the flatbed. — tested earlier by
      the player; that log has rotated away (no `fault applied: fuel` in the kept logs)

## H. Wallet and logbook

- [x] Payout appears in Wallet as recovery income. — confirmed by the player, 2026-11-04
- [x] Finished job appears in the logbook. — 2026-11-04 screenshot: "Jobs · Tow job completed"
      +$1,184.00 (Autobello Piccolina 110 A (M)) and +$1,118.00, next to the Recovery level-ups.
      The detail shows the vehicle only, not the destination.

## I. Release build (last)

After the code changes in `docs/release.md` section 1 (version, `debugTools = false`,
`tow_dispatch.zip`). Remove `mods/unpacked/tow_repo_hub` first.

- [ ] `tools/dev/deploy.ps1 -Zip`; zip has forward slashes and only `lua`, `scripts`,
      `gameplay`, `ui`, `LICENSE`.
- [ ] Mod manager lists `tow_dispatch`; log shows `RLS 2.8.0 detected` and `loaded`.
- [ ] Phone: Tow Dispatch with icon, footer with the version, no debug panel or teleports.
- [ ] One full job with payout in Wallet and XP.
- [ ] Save and reload with an active job.

## Screenshots for beamng.com

16:9, daylight: the board on the phone, a car on a flatbed, the active job card, the completion
screen with the own rig bonus row.

- [ ] Board
- [ ] Car on a flatbed
- [ ] Active job
- [ ] Completion with bonus

## After the fixes (2026-11-04)

Fixed in code with tests (`spots_test.lua`, `job_test.lua`, `pricing_test.lua`: 79 passed).
In game 2026-11-04 on West Coast, one job (offer 89, nearly empty tank, own pickup and own
tiltdeck), no warnings or errors from the mod:

- [x] Active job distance matches navigation (road), before and after pickup. — player
- [x] Within ~30 m the first step reads "Load the vehicle", no distance, navigation stops
      (log: `on site at 30 m`).
- [x] Custody starts only when the car moves ~10 m: accepted at 1195 s, `custody started` at
      1374 s.
- [x] Bonus 20 % own rig: `rig bonus share while towing: 0.20`, `quote 1311, own rig bonus
      262, paid 1573` (262 = 20 % of 1311). The 10 % case (rented trailer) is covered by
      `pricing_test.lua` only.
- [ ] Unload short of the spot and drive the last metres: bonus kept (shrunk only past 200 m).
      Not tested in game; covered by `pricing_test.lua` (`rigShareAtDelivery`).
- [x] Log on map load: `2046 parking spots in 402 entries on rls_west_coast (100 with a shared
      name skipped)`.
