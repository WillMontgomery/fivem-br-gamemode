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

## Where the canopy images came from

All fourteen (`chute_*.png`) are from **Vespura's parachute reference**,
<https://vespura.com/fivem/parachutes/> — Tom Grobbe's, and the best catalogue
of GTA's canopy designs anywhere. Credit belongs there.

They are the right source rather than a compromise. I had argued for shooting
our own on the grounds that this gamemode overrides the parachute model, so a
canopy photographed elsewhere might not match what a player receives — **that
was wrong.** The override sets `p_parachute1_mp_s`, which IS the standard
multiplayer canopy; it exists to move off the singleplayer model, not onto an
unusual one. Any FiveM reference is shot against the same asset we use.

They also served as an independent check on the index table: Hornet came back
black-and-yellow at index 7 and Patriot red-white-blue at 4, exactly as
`br_lib/config/market.lua` claims.

**The 8–13 images prove the designs exist, not that they render for us.** Those
six are documented as needing a model override, and whether ours satisfies that
is still open — see the canopy audit issue. If one comes back wrong in game,
the image is fine and the config is what changes.

## Capturing the rest

`brchute cycle` in the F8 console lifts you to canopy height and steps through
every index with a re-deploy between each — the whole set in one pass, if the
canopies ever need reshooting against our own lighting.

Trails photograph best from below during a drop; the colour is in the smoke, not
the canopy, so frame the trail rather than the player. Weapon finishes want the
weapon wheel or a third-person shot with the weapon drawn — `brchute` does not
help there, but any match does.

