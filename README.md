# Tow Dispatch

An add-on for [RLS Career Overhaul](https://github.com/RLS-Modding/rls_career_overhaul) in
BeamNG.drive that adds towing work: broken-down cars that need to go home or to a service,
on a job board with the payout quoted up front, so you pick the job you want instead of
generating, cancelling and trying again.

> **Status:** playable beta, not released yet. Tested on The Gap with RLS 2.8.0. Saving an
> active job across a game reload is not done yet (see [Known limitations](#known-limitations)).

## Features

- **Tow Dispatch phone app** in the RLS phone, styled like a tow company's dispatch app.
- **A living job board** per map: 10–14 jobs of every tier, from cheap runabouts to exotics
  and heavy vehicles. New jobs come in over time and each expires on its own clock. The
  board cannot be rerolled.
- **Progression you can see:** jobs above your Recovery level are listed as locked, with
  their payout and the level that unlocks them. The higher your level, the more of the
  board you can take.
- **Tow jobs:** a broken-down car goes to the owner's home (an unowned garage) or to a
  dealership for service. Every tow vehicle has one fault:
  - **Nearly empty tank** – runs a few hundred metres,
  - **Flat tyre** – still rolls, drives badly,
  - **Overheating** – empty radiator, the engine overheats as soon as it runs,
  - **Failing engine** – misfires and stalls.

  You can load it on a truck or trailer, or drive it yourself if it still runs.
- **Quote up front:** every offer shows the payout, the fault, the distance to the vehicle,
  the route with the vehicle, its weight, the destination and when the offer expires. Sort
  by payout or distance and filter by tier and distance.
- **Fair pay:** short and long jobs pay about the same per minute, a step below Off-Road
  Recovery.
- **Recovery skill:** jobs give XP to the RLS Recovery skill (shared with repo and Off-Road
  Recovery), and higher levels unlock better-paying tiers at the same levels as RLS repo.
- **Damage and fines:** damage you cause during the job is taken from the payout, at most
  half of it. Cancelling is free until you move the vehicle; after that it costs a fine.
- **Integrated with RLS:** payouts appear in Wallet as recovery work income, jobs in the logbook,
  parking spots are reserved through RLS so hub and RLS jobs never share one, and the
  original RLS repo app keeps working as before (repo work stays there). Works alongside
  RLS Carjacking & Theft, which leaves job vehicles alone.

## Requirements

- BeamNG.drive 0.40
- RLS Career Overhaul 2.8.x (the app warns on other versions)

## Installation

Not released yet. Once it is: put `tow_repo_hub.zip` into your BeamNG `mods` folder next to
RLS and keep it zipped. Start or load an RLS career and open **Tow Dispatch** on the phone.

## How to play

1. Open the app and pick an offer. Tap **?** in the app for a short guide.
2. **Accept** it and drive to the vehicle; the app's **Navigate** button sets the route.
3. Load the vehicle, or drive it if it runs. Once it leaves its spot, it is yours.
4. Take it to the green marker at the destination and stop. You are paid the quote minus any
   damage penalty and get Recovery XP.

One job at a time.

## Known limitations

- **No saving yet:** the board and an active job are lost when you reload the game, reload
  Lua or travel to another map (an active job then ends without a fine).
- Tested on The Gap only so far; other RLS maps should work but are not verified.
- Heavy vehicles (Recovery level 25+) are not tested yet.
- The app has developer tools at the bottom (**Debug tools**) that will be removed or hidden
  for the release.

## Development

The repository root is the mod root. See [AGENTS.md](AGENTS.md) for the layout and workflow,
[docs/spec.md](docs/spec.md) for the specification and
[docs/rls-integration.md](docs/rls-integration.md) for how the add-on uses RLS.

- Tests (LuaJIT): `tools/test.sh`
- Deploy to the game for testing (Windows): `tools/dev/deploy.ps1`
- Package: `tools/package.sh` → `dist/tow_repo_hub.zip`

## License

[MIT](LICENSE). RLS Career Overhaul is a separate project with its own licenses; this add-on
uses its public interfaces and does not ship RLS code.
