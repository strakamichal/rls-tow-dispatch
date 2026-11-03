# Tow Dispatch (formerly Tow & Repo Hub) — specification

Status: **implemented** (delivery steps 1–6), playable beta, not released yet.
Targets: BeamNG.drive 0.40, RLS Career Overhaul 2.8.0.

## Problem

RLS repo jobs are generated one at a time. To find a job worth doing, the player
generates an offer, checks the vehicle and map, cancels and repeats until the tier,
location and vehicle fit. The drop-off is not shown, so the player guesses it from
the vehicle type. Pay barely grows with distance, so a 6 km tow on a winding road
is not worth the time and short jobs always win. There is also no towing work in
the sense of "my car broke down, take it home or to a garage".

## Goals

- See several offers at once with everything needed to choose one.
- Quote the payout before accepting; short and long jobs pay about the same per minute.
- Add tow jobs (broken-down cars) next to repo jobs.
- Keep this work a step below Off-Road Recovery in pay and XP.
- Progress the existing RLS Recovery skill, not a new one.
- Leave the original RLS repo jobs untouched.

## Design

### Job types

**Decision (2026-11-03): the board offers tow jobs only.** A repo vehicle is intact, so the
player simply drives it to the dealership: there is nothing for a tow truck to do, and the
original RLS repo app already covers that work. The repo job flow stays in the code
(`jobType = "repo"`) but no repo offers are generated. The repo column below documents what
existed; tow jobs keep the ×1.1 factor.

| | Tow | Repo (not offered) |
|---|---|---|
| Story | The owner's car broke down; take it home or to a service | The owner missed payments; return the car to the lender |
| Vehicle | Any common traffic vehicle on the map | A vehicle sold by the destination dealership (as RLS repo) |
| Condition | Has a fault (see below), never deformed | Intact, just parked |
| Destination | An unowned garage (home) or a dealership (service) | A dealership or a repo-provider yard (as RLS repo) |
| Pay and XP | ×1.1 | ×1.0 |

### Board

- A per-map board of tow jobs **of every tier**, whatever the player's level. Its
  size varies: a new board starts with **10–14 jobs**, then a new job arrives every
  **1–3 in-game minutes** (twice as fast below 8), up to **14**.
- Tiers appear in about these shares: Low Value 30 %, Budget 25 %, Standard 20 %,
  Luxury 12 %, Exotic 6 %, Heavy 7 % (RLS Joe's Junk repo counts as Low Value). A tier the
  board already has many of is picked less often.
- Jobs above the player's Recovery level are **locked**: the app lists them apart, with the
  payout and the level that unlocks them, but they cannot be accepted. The header shows the
  next tier to unlock. So the higher the level, the more of the board the player can take.
- Each job expires after its own random **12–30 in-game minutes**, so jobs leave the
  board at different times. An accepted job never expires.
- The board cannot be rerolled: new jobs only come with time.
- **One active job** at a time.
- The target vehicle is spawned **only when an offer is accepted**; offers are data.
- Diversity rules when filling the board: no vehicle model twice, no destination twice
  (and, while both job types were offered, at least 2 of each).
- Offer generation runs over several frames (a coroutine that yields after each route
  query), and the vehicle candidates of every tier are built once per map, so the board
  never stalls a frame. If no offer fits after
  a number of attempts, the rules are relaxed so the board never stays empty.

Each offer shows: job type, tier, vehicle, weight, fault (Tow), distance from the
player to the vehicle by road, route length with the vehicle loaded, destination
name, quoted payout and time to expiry. Offers can be sorted by payout
and distance to the vehicle, and filtered by job type, tier and maximum distance to
the vehicle. A **Route** button sets navigation to the active job's next stop.

### Pickup spots

- All parking spots from the map's `city` sites file, like RLS repo. Awkward spots are
  part of the fun; no loadability filter. On The Gap, roadside spots are parking spots.
- At least 300 m (straight line) from the player when spawned.
- The last ~10 used spots are not offered again.
- Spots are reserved through the RLS parking reservation service, so RLS jobs and the
  hub never share a spot.
- To check in game: whether maps carry more usable parking spots in other sites files.

### Destinations

- Repo: chosen the RLS repo way (dealership, then a vehicle it sells), including
  repo-provider yards.
- Tow: an unowned, purchasable garage (the owner's home) or a dealership (service).
  Garages the player owns or rents are excluded, as are non-purchasable ones.
  Heavy vehicles never go to garages.
- Minimum route length pickup → destination: **500 m by road**. No maximum.

### Tiers

The tier definitions are read at runtime from RLS `gameplay/overhaul/repo/repoVehicleFilters.json`
(unlock level, pay multiplier, base XP), so RLS changes carry over.

- Repo: vehicle selection as RLS repo (dealership filters, the highest-priority matching
  tier), but for every tier: RLS only hands out unlocked tiers, so the hub classifies
  vehicles itself with the same rules (`lib/repoTiers.lua`).
- Tow: classified by vehicle value only (no brand or config-type restriction), using the
  RLS value bands: Low Value < 25 000, Budget 25–50 k, Standard 50–100 k,
  Luxury 100–200 k, Exotic > 200 k. **Heavy** = weight > 3.5 t or a medium-duty truck
  model (MD-Series); the game types pickups and SUVs as Truck, so the type alone does not
  count. Overlapping bands resolve to the higher tier. Vehicles with implausible values
  (for example from other mods) are skipped, and so is anything a tow truck or car trailer
  cannot carry or that cannot be a broken-down car: buses, semi tractors, vehicles over 9 t
  and configurations without an engine (rolling chassis).

### Tow faults

The vehicle can still drive a few metres onto a flatbed, so a winch is never required.
Each tow job has exactly one fault, so the player can tell what is wrong.

| Fault | Effect |
|---|---|
| Nearly empty tank | About 0.08 l of fuel, enough for a few hundred metres; nothing else |
| Flat tyre | One deflated tyre; nothing else |
| Overheating | Broken radiator with no coolant left; the engine is hot (125 °C) when the player arrives and overheats as soon as it runs |
| Failing engine | Engine integrity 0.5–0.3, chosen at random: misfires and an unstable idle that make it stall |

Electric vehicles only get a flat tyre. About 40 % of tow vehicles also look shabby (worse
paint and visual condition), which has no effect on driving.

There is no rule against driving the vehicle to the destination: refuelling and driving
is allowed, and driving an overheating car ruins the engine, which the damage penalty
charges. Crashed (deformed) vehicles are out of scope for now.

### Pricing

```
quote = (callout + outboundRate × km to vehicle + loadedRate × km loaded)
        × tier multiplier × (1 + repo skill bonus) × job type factor × economy multiplier
```

- Starting constants: callout **400**, outbound **55/km**, loaded **135/km**; tuned in game.
  Distances are road route lengths.
- Skill bonus: the RLS repo steps scaled down, `2 × floor(level / 2) / 24`, capped at +200 %
  (RLS repo goes to +400 %, which ran most jobs into the recovery cap at higher levels).
- Tier multiplier for tow: the hub's own ladder, so every tier pays more than the one below
  (RLS gives Low Value and Budget the same): Low Value 1.0, Budget 1.15, Standard 1.3,
  Luxury 1.5, Exotic 1.75, Heavy 2.0. Unlock levels still come from RLS.
- Job type factor: Tow 1.1, Repo 1.0.
- Economy multiplier: the RLS `repo` economy section.
- No speed or time component; the quote is fixed when the offer is created.
- Skill level is the RLS Recovery skill (`careerSkills-recovery`), which RLS repo and
  Off-Road Recovery share.
- **Cap:** the quote never exceeds 90 % of what Off-Road Recovery pays for the same
  distances and skill level, using the recovery economy section (`offroadRecovery`),
  including the recovery difficulty fee available at that level (0 below level 10, 1 500 from 10, 3 000 from 30;
  RLS takes the fee per recovery spot, the cap uses the best fee reachable at that level). Recovery reference
  (RLS 2.8 `jobs/recovery/rewards.lua`):
  `(1500 + 100/km outbound + 250/km loaded + fee) × (1 + 2p²)`, `p = floor((level − 5) / 2) / 22`.

### Towing, not driving

A tow job pays for towing. Every half second, while the player sits in the target vehicle,
the distance it moved is added up (steps under 0.5 m or over 50 m are ignored: settling on a
bed, teleports, resets). Riding on a flatbed or trailer, a wheel lift or a rope does not count,
because the player sits in the tow vehicle then.

- The first **200 m** are free, to get the vehicle loaded.
- Beyond that the pay drops in proportion to the share of the loaded route driven beyond the
  allowance, down to **25 % of the quote and no XP** when the whole route was driven.
- The player is told on accept, when they first get in the target, and when the free distance
  runs out; the active job shows a live meter, and the completion breakdown a "Not towed" line.

### Damage penalty

- The baseline part condition is captured when the player first gets within ~30 m of
  the vehicle, not at spawn, so traffic damage before arrival is not charged.
- Penalty = value of part integrity lost during the job, as RLS Off-Road Recovery
  computes it. Losses below ~2 % per part are ignored.
- The penalty is capped at 50 % of the quote, as in RLS Off-Road Recovery: a delivery
  always pays at least half the quote.

### XP

```
xp = RLS repo xp for the tier × (9.5 + km loaded) / 14 × job type factor
```

RLS repo xp is `(5 + tier baseXp + round(km / 2)) × 2`, with tow base XP per tier
Low Value 300, Budget 350, Standard 500, Luxury 900, Exotic 1 400, Heavy 1 800. The distance
factor grows about half as fast as the pay (0.5 km ≈ 0.71, 7 km ≈ 1.18), so a long job gives
more XP but not a whole level. (The first draft used `(3 + km) / 5`, "the same XP per
minute"; at level 14 one long job then gave a full level.)
**Open:** the spec also asked that XP never exceed 90 % of comparable Off-Road Recovery
XP. Recovery XP is `(5 + site baseXp + round(km / 2)) × 4` and barely grows with distance,
so with equal base XP a hub job passes 90 % of it from about 6 km loaded. The two goals
conflict; to decide once the recovery site base XP on The Gap is known. Damage never reduces XP.

### Completion

The job completes when the vehicle is within ~5 m of the destination spot and stopped,
loaded on the truck or not (as RLS does). The player sees a breakdown: quote, damage
penalty, payout and XP. Payouts are tagged so RLS Wallet
lists them as work income from recovery (`activity:recovery`, like Off-Road Recovery) with an
extra hub tag, and the job is written to the
RLS logbook.

### Cancellation and failure

- **Custody** starts when the vehicle has moved more than ~10 m from its spot.
- Cancelling before custody is free. The offer leaves the board and is replaced.
- Cancelling after custody, or losing or destroying the vehicle after custody, costs a
  fine of **50 % of the quote, at least $200**, and gives no XP. The quote already carries
  the tier, distances and economy, and half the quote equals the largest damage penalty, so
  cancelling never beats delivering a damaged vehicle. (A fixed 1 000 × tier × economy fine
  was dropped: it could exceed the whole payout of a short job.)
- A vehicle lost before custody (traffic, despawn, failed spawn) ends the job with no
  consequence and a message.
- RLS offers no hook to block map travel for third-party jobs, so an active job pauses
  when the player travels and resumes on return (as Off-Road Recovery does).

### Persistence

- Saved in the career save slot together with RLS (`career/towRepoHub/state.json`):
  per-map boards with expiry times, recently used spots, the hub clock and the active
  job (phase, quote, baseline, custody, driven distance, fault).
- The target is not an RLS inventory vehicle; the hub respawns it itself (as RLS
  Off-Road Recovery does) from its last pose, part conditions and fuel. When it rested
  on one of the player's vehicles (flatbed, trailer), the save also holds that carrier's
  inventory id and the RLS `carriedFrame` relation, and the target is placed back on
  the carrier once RLS has restored it (waiting up to 20 s). If restoring fails, the job
  ends with no fine and a message.
- A Lua reload (Ctrl+L) keeps the state in a session file for the same profile.
- Map travel pauses the job; the target comes back when the player returns to its map.

### RLS integration

- The original RLS Repo app and jobs stay as they are.
- No blocking between hub and RLS jobs; navigation simply follows the last route set.
- The app warns when the installed RLS version is not 2.8.x.
- The RLS Carjacking & Theft mod does not treat hub targets as stealable: it only takes
  AI traffic spawned by the traffic system, and hub targets are inserted with AI off
  (checked in its `isJackableTrafficVehicle`, v0.40, and in game).

## Acceptance criteria

1. The RLS phone shows a **Tow Dispatch** app; installing the add-on breaks neither RLS
   nor other phone apps. The app warns on an RLS version other than 2.8.x.
2. The board starts with 10–14 jobs of all tiers in about the listed shares, showing all
   fields listed under *Board*, grows with time up to 14, expires each job after 12–30
   in-game minutes and keeps one active job.
3. Sorting and filters work as listed under *Board*; the Route button sets navigation.
4. The board follows the diversity rules and relaxes them when nothing fits.
5. Only jobs of tiers the player has unlocked can be accepted; locked jobs are listed apart
   with their unlock level. Tow vehicles are classified as listed under *Tiers*.
6. Pickups use parking spots ≥ 300 m from the player, skip the last ~10 used spots and
   never collide with RLS reservations; the vehicle spawns only on accept.
7. Destinations follow *Destinations*, including the 500 m minimum road route.
8. Tow vehicles have one of the listed faults, can drive onto a flatbed and are not deformed.
9. Quotes follow *Pricing*, including the recovery cap; covered by automated tests.
10. Completion pays the quote minus the damage penalty and awards XP as specified,
    shows the breakdown, and appears in Wallet and the logbook.
11. Cancellation, custody fines and failure cases behave as specified.
12. Boards and the active job survive save and reload, including a vehicle on a flatbed.

## Out of scope (later)

- The player's own Recovery Yard as a destination, with a storage fee.
- Crashed, deformed tow vehicles.
- Time limits for loading (a car parked where it must not be).
- Changing or removing the original RLS repo jobs.
- Multiplayer; maps RLS repo does not support.

## Delivery steps

Each step is playable and verified in game before the next starts.

1. **Skeleton.** Packaging, empty app in the RLS phone, version warning. → AC 1
2. **Pricing and XP.** Pure logic with automated tests outside the game. → AC 9, XP part of AC 10
3. **Board.** Offer generation for Repo, pickup spots, destinations, tiers, list with
   sorting, filters and diversity. → AC 2–7 for Repo
4. **Repo job.** Spawn, custody, delivery, payout, damage, XP, cancel, fines. → AC 10–11 for Repo
5. **Tow.** Traffic vehicle pool, value tiers, faults, garage destinations. → AC 5, 7, 8 and 10–11 for Tow
6. **Persistence and release.** Save/reload, README, packaging for beamng.com. → AC 12

## Risks

- The RLS inventory and payout calls used here are internal, not a documented API;
  an RLS update can break them. Each step adds a smoke test against the installed RLS.
- Whether overheating can be set up without real radiator damage is unverified;
  if not, it is replaced by another drivable fault.
- Phone app UI routes point at `.vue` components; that BeamNG 0.40 loads them from an
  add-on mod is verified in step 1.
