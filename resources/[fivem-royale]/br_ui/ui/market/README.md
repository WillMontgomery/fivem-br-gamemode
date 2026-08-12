# Market artwork

Drop PNGs here named after the **item id** from `br_lib/config/market.lua`:

    chute_rainbow.png   chute_crimson.png   chute_hornet.png
    trail_ember.png     trail_patriot.png
    wtint_gold.png      wtint_platinum.png

Vite copies this directory verbatim into the build, so a file here is served at
`market/<id>.png` next to `index.html`, and `br_ui/ui/` picks it up on the next
`npm run build`.

Anything missing falls back to the two-letter monogram in the rarity colour —
the card's `onError` handles it — so the set can be filled a few at a time and a
typo in a filename degrades to the old behaviour rather than to a broken-image
icon.

Transparent backgrounds. Square-ish source images look best: the card uses
`object-fit: contain`, so a wide image letterboxes rather than stretches.

## Capturing canopies

`brchute cycle` in the F8 console lifts you to canopy height and steps through
every index with a re-deploy between each, which is the whole set in one pass.
Screenshot each one, crop square, save as the item id.

Worth doing rather than sourcing images from a reference site, for two reasons
beyond the obvious one about somebody else's screenshots. This gamemode
overrides the parachute model (`p_parachute1_mp_s`), so a canopy here may not
look identical to the same index photographed under a different model — and a
storefront whose pictures do not match what the player receives is worse than a
storefront with no pictures. The lighting and angle also end up consistent
across the set, which no collection of found images will be.

## Trails and finishes

Trails photograph best from below during a drop; the colour is in the smoke, not
the canopy, so frame the trail rather than the player. Weapon finishes want the
weapon wheel or a third-person shot with the weapon drawn — `brchute` does not
help here, but any match does.
