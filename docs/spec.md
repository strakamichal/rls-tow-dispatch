# Tow & Repo Hub — specification

Status: **draft, awaiting approval**.
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

| | Tow | Repo |
|---|---|---|
| Story | The owner's car broke down; take it home or to a service | The owner missed payments; return the car to the lender |
| Vehicle | Any common traffic vehicle on the map | A vehicle sold by the destination dealership (as RLS repo) |
| Condition | Has a fault (see below), never deformed | Intact, just parked |
| Destination | An unowned garage (home) or a dealership (service) | A dealership or a repo-provider yard (as RLS repo) |
| Pay and XP | ×1.1 | ×1.0 |

### Board

- Shows **6 offers**, mixed Tow and Repo, on a per-map board.
- A new offer arrives about every **3 in-game minutes** until the board is full.
- An offer expires after about **20 in-game minutes**. An accepted job never expires.
- **One active job** at a time.
- The target vehicle is spawned **only when an offer is accepted**; offers are data.
- Diversity rules when filling the board: at least 2 of each job type, at most 2 offers
  of the same tier, no vehicle model twice, no destination twice. If no offer fits after
  a number of attempts, the rules are relaxed so the board never stays empty.

Each offer shows: job type, tier, vehicle, weight, fault (Tow), distance from the
player to the vehicle by road, route length with the vehicle loaded, destination
name, quoted payout and time to expiry. Offers can be sorted by payout, payout per km
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

- Repo: vehicle selection exactly as RLS repo.
- Tow: classified by vehicle value only (no brand or config-type restriction), using the
  RLS value bands: Low Value < 25 000, Budget 25–50 k, Standard 50–100 k,
  Luxury 100–200 k, Exotic > 200 k. **Heavy** = weight > 3.5 t or type Truck/Bus.
  Overlapping bands resolve to the higher tier. Vehicles with implausible values
  (for example from other mods) are skipped.

### Tow faults

The vehicle can still drive a few metres onto a flatbed, so a winch is never required.

| Fault | Effect |
|---|---|
| Nearly empty tank | Fuel for a few hundred metres |
| Flat tyre | One deflated tyre (RLS tyre state) |
| Overheating | Engine overheats after a short drive |
| Worn | Aged parts and worse appearance; combined with another fault |

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
- Repo skill bonus as RLS repo: `4 × floor(level / 2) / 24`, capped at +400 %.
- Job type factor: Tow 1.1, Repo 1.0.
- Economy multiplier: the RLS `repo` economy section.
- No speed or time component; the quote is fixed when the offer is created.
- Skill level is the RLS Recovery skill (`careerSkills-recovery`), which RLS repo and
  Off-Road Recovery share.
- **Cap:** the quote never exceeds 90 % of what Off-Road Recovery pays for the same
  distances and skill level, using the recovery economy section (`offroadRecovery`),
  including the recovery difficulty fee available at that level (0 below level 10, 1 500 from 10, 3 000 from 30). Recovery reference
  (RLS 2.8 `jobs/recovery/rewards.lua`):
  `(1500 + 100/km outbound + 250/km loaded + fee) × (1 + 2p²)`, `p = floor((level − 5) / 2) / 22`.

### Damage penalty

- The baseline part condition is captured when the player first gets within ~30 m of
  the vehicle, not at spawn, so traffic damage before arrival is not charged.
- Penalty = value of part integrity lost during the job, as RLS Off-Road Recovery
  computes it. Losses below ~2 % per part are ignored.
- The penalty is capped at the quote: a delivery never pays below zero.

### XP

```
xp = RLS repo xp for the tier × (3 + km loaded) / 5 × job type factor
```

RLS repo xp is `(5 + tier baseXp + round(km / 2)) × 2`. A 2 km job gives what RLS
repo gives today; longer jobs give proportionally more, the same per minute.
**Open:** the spec also asked that XP never exceed 90 % of comparable Off-Road Recovery
XP. Recovery XP is `(5 + site baseXp + round(km / 2)) × 4` and barely grows with distance,
so with equal base XP a hub job passes 90 % of it from about 6 km loaded. The two goals
conflict; to decide once the recovery site base XP on The Gap is known. Damage does not reduce XP, but a delivery paid zero because of
damage gives no XP.

### Completion

The job completes when the vehicle is within ~5 m of the destination spot and stopped,
loaded on the truck or not (as RLS does). The player sees a breakdown: quote, damage
penalty with the most damaged parts, payout and XP. Payouts are tagged so RLS Wallet
lists them under repo/recovery with an extra hub tag, and the job is written to the
RLS logbook.

### Cancellation and failure

- **Custody** starts when the vehicle has moved more than ~10 m from its spot.
- Cancelling before custody is free. The offer leaves the board and is replaced.
- Cancelling after custody, or losing or destroying the vehicle after custody, costs a
  fixed fine of **1 000 × tier multiplier × economy multiplier** and gives no XP.
- A vehicle lost before custody (traffic, despawn, failed spawn) ends the job with no
  consequence and a message.
- Map travel is not possible during an active job; the app explains why.

### Persistence

- Saved in the career save slot together with RLS: per-map boards with expiry times,
  the active job (phase, quote, baseline, custody) and recently used spots.
- The active target is held as a temporary vehicle in the RLS inventory that takes no
  garage space (as RLS Off-Road Recovery does), so RLS restores it after loading,
  including on a flatbed. If restoring fails, the job ends with no fine and a message.

### RLS integration

- The original RLS Repo app and jobs stay as they are.
- No blocking between hub and RLS jobs; navigation simply follows the last route set.
- The app warns when the installed RLS version is not 2.8.x.
- To check in game: the RLS Carjacking & Theft mod must not treat hub targets as stealable.

## Acceptance criteria

1. The RLS phone shows a **Tow & Repo Hub** app; installing the add-on breaks neither RLS
   nor other phone apps. The app warns on an RLS version other than 2.8.x.
2. The board holds 6 offers with all fields listed under *Board*, refills about every
   3 in-game minutes, expires offers after about 20 minutes and keeps one active job.
3. Sorting and filters work as listed under *Board*; the Route button sets navigation.
4. The board follows the diversity rules and relaxes them when nothing fits.
5. Offered tiers respect the player's Recovery level; Tow vehicles are classified as
   listed under *Tiers*.
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
