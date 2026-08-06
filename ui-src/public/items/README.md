# Item artwork

Drop PNGs here named after the **item id** from `br_lib`:

    carbinerifle.png   heavysniper.png   pumpshotgun.png
    medkit.png         bandage.png       shield.png   minishield.png
    grenade.png        molotov.png       sticky.png   smoke.png

Vite copies this directory verbatim into the build, so a file here is served
at `items/<id>.png` next to `index.html` — no import, no bundler config, and
`br_ui/ui/` picks it up on the next `npm run build`.

Anything missing falls back to the drawn icon in `src/hud/ItemIcon.tsx`, so
the set can be filled in a few at a time and a typo in a filename degrades to
the old behaviour rather than to an empty square.

Transparent backgrounds. Square-ish source images look best — the renderer
uses `object-fit: contain`, so a wide image letterboxes rather than stretches.

The weapon ids are the `id` fields in `br_lib/config/weapons.lua`; the
consumables are in `br_lib/config/loot.lua`. Ammo has no artwork by design
(there is nothing to draw), and always uses the drawn icon.
