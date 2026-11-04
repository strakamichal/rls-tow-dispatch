# Promo graphics

Three 1920 × 1080 graphics for beamng.com and the README: a photo-mode shot, the in-game phone in
its in-game corner (same size and margins as RLS shows it at 2560 × 1440), and a headline.

| `?g=` | Headline | Phone | Background |
|-------|----------|-------|------------|
| `board` | Take the call. | the job board | photo 52, sunset road |
| `delivery` | Tow it, don't drive it. | the delivery step | photo 32, sunset hairpin |
| `completion` | Your own rig pays more. | completion with the +20 % bonus | photo 27, rollback with beacons |

Photo numbers refer to the photo-mode shots of 2026-11-04, kept locally in
`.cache/screenshots/repo-docs/photomode/` (not committed). The finished graphics and the README
gallery are in `docs/images/`.

## Render

```powershell
tools/promo/render.ps1                  # all, to .cache/promo/out/<name>.png
tools/promo/render.ps1 -Name delivery   # one
```

Needs Microsoft Edge and internet access (Overpass from Google Fonts).

## Images

`promo.html` reads its images from `.cache/promo/` (not committed):

- `bg-board.png`, `bg-delivery.png`, `bg-completion.png`: the original 2560 × 1440 game
  screenshots (`screenshots/` in the BeamNG user folder), not the JPEG copies.
- `phone-board.png`, `phone-delivery.png`, `phone-completion.png`: the phone cropped from an
  in-game desktop capture at 2560 × 1440, rectangle x 2024, y 552, 508 × 882.

Texts and file names are in the `GRAPHICS` table at the end of `promo.html`.
