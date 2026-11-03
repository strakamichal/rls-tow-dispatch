# Tow & Repo Hub — specification

Status: **draft, not approved**.

## Problem

RLS repo jobs are generated one at a time. To find a job worth doing, the player
generates an offer, checks the vehicle and map, cancels and repeats until the tier,
location and vehicle fit. The drop-off is not shown, so the player guesses it from
the vehicle type. Pay barely grows with distance: a 6 km tow on a winding road pays
too little for the time, so short jobs always win.

## Goals

- See several offers at once with everything needed to choose one.
- Quote the payout before accepting, based on the actual road route.
- Keep repo work a step below Off-Road Recovery in pay, because recovery also needs
  the vehicle extracted from terrain.
- Spawn targets only where they can be loaded comfortably.
- Progress the existing RLS Recovery skill, not a new one.

## Acceptance criteria

1. The RLS phone shows a new **Tow & Repo Hub** app. Installing the add-on does not
   break RLS or any other RLS phone app.
2. The app lists 5–8 offers. Each shows: distance from the player to the vehicle,
   tier, vehicle, drop-off location, road route length (pickup → drop-off) and the
   quoted payout.
3. Offers can be sorted by payout, payout per km and distance to the vehicle, and
   filtered by tier and maximum distance to the vehicle.
4. Only tiers unlocked by the player's Recovery skill level are offered, using the
   same unlock levels as RLS repo.
5. Target vehicles spawn only on parking spots or roadside spots that a flatbed or
   wheel-lift truck can reach and load.
6. Quote = callout + rate per km to the vehicle + higher rate per km with the vehicle
   loaded, multiplied by tier, Recovery skill bonus and the RLS economy multiplier.
   For the same distances, skill level and economy, a quote is always lower than the
   Off-Road Recovery quote. Covered by automated tests.
7. Delivering the vehicle pays the quote minus a penalty for damage added during the
   job, and awards Recovery skill XP.
8. An accepted job can be cancelled. Completed or cancelled offers are replaced by new ones.
9. Offers and an active job survive save and reload.

## Out of scope

- Changing or removing the original RLS repo jobs (they stay as they are).
- Theft mechanics.
- Multiplayer.
- Maps that RLS repo does not support.

## Pricing model (draft)

Reference, RLS 2.8 Off-Road Recovery (`jobs/recovery/rewards.lua`):

```
1500 callout + 100/km outbound + 250/km loaded + difficulty fee (0 / 1500 / 3000)
× (1 + skill bonus, up to +200 %) × economy multiplier
```

Hub quote, starting point to tune:

```
callout + outboundRate/km + loadedRate/km
× tier multiplier × (1 + skill bonus) × economy multiplier
```

The invariant from criterion 6 (hub < recovery for equal inputs) constrains the
constants, including the highest tier multiplier. Exact values are settled in step 2.

## Delivery steps

Each step is playable and verified before the next starts.

1. **Skeleton.** Mod packaging and an empty phone app loaded by RLS. → AC 1
2. **Pricing.** Quote calculation with automated tests outside the game. → AC 6
3. **Board.** Offer generation, spawn spots, list with sorting and filters. → AC 2–5
4. **Job.** Pickup, delivery, payout, damage penalty, XP, cancel. → AC 7–8
5. **Persistence and release.** Save/reload, README, packaging for beamng.com. → AC 9

## Open questions

- Drop-off: reuse the RLS repo drop-off logic, or let each offer pick its own location?
- Skill bonus curve: the Recovery curve (+200 % max) or the repo curve (+400 % max)?
- Should offers expire after some in-game time?
