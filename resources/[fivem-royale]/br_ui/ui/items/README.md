# Item artwork

Drop PNGs here named after the **item id** from `br_lib`:

    carbinerifle.png   heavysniper.png   pumpshotgun.png
    railgun.png        minigun.png       rpg.png

Vite copies this directory verbatim into the build, so a file here is served
at `items/<id>.png` next to `index.html` — no import, no bundler config, and
`br_ui/ui/` picks it up on the next `npm run build`.

**Every weapon must have one.** `tools/check_weapons.lua` fails the build if a
weapon that can occupy a slot has no PNG here *and* no PNG in the built bundle
— firearms, the airdrop shelf, melee, throwables and fists, 56 of them. That is
the mechanical half of the owner's rule below; the other half is that
`src/hud/ItemIcon.tsx` no longer contains a single weapon-shaped drawn icon, so
a missing file cannot be papered over by drawing something.

A file that is present but fails to decode falls back to the `missing`
placeholder — an empty frame with a slash — which deliberately looks like
nothing in the game. It is not a fallback you should ever see; it says "this
picture failed", not "you are holding a rifle".

Transparent backgrounds. Square-ish source images look best — the renderer
uses `object-fit: contain`, so a wide image letterboxes rather than stretches.

The weapon ids are the `id` fields in `br_lib/config/weapons.lua`; the
consumables are in `br_lib/config/loot.lua`. **Four consumables are drawn on
purpose** (`shield`, `minishield`, `bandage`, `medkit`) — a shield and a cross
are symbols rather than objects, and there is no photograph of them to take.
A PNG dropped here under one of those ids would still be picked up, and
`repairkit.png` is exactly that: a consumable with real artwork, which is why
it is the one PNG in this directory that is not a weapon render. Ammo has no
artwork by design (there is nothing to draw) and never requests a file at all.

**Do not add consumable ids to `CONSUMABLE_ICON` in `src/hud/ItemIcon.tsx` to
"fix" a missing picture.** That map is consulted only *after* a file has failed
to load, so an entry there would permanently mask a broken PNG behind a drawn
symbol — a confident picture of the wrong thing, which is the failure the whole
weapon-icon gate exists to prevent.

## Where the weapon art came from

All 56 are **GTA V's own weapon renders**, taken from
<https://github.com/R3DIANCE/GTA-V-Weapons-images> — a convenience mirror of
the images, organised by weapon class under the GTA display name.

    upstream   https://github.com/R3DIANCE/GTA-V-Weapons-images
    branch     master
    commit     b4229820099a77ca4d38f1846532c2f451afbefc
    retrieved  2026-08-06 (39 weapons + Fist), 2026-08-07 (melee),
               2026-08-22 (rpg, grenadelauncher, railgun, minigun)

Sourcing is **verbatim and rename-only**: a file is copied out of that repo
unmodified and renamed from its GTA display name to our item id. Nothing is
cropped, recompressed or recoloured, which is why the set is not uniform — 35
are RGBA and 21 are indexed-colour with a `tRNS` chunk; 25 sit on the full
760×290 canvas and the other 31 are trimmed, from 172 px to 760 px wide and
58 px to 290 px tall. **That is how upstream holds them**, not something done
here. All 56 are transparent-backed, which is the only property that actually
matters in a slot. Do not "normalise" them: the renderer letterboxes with
`object-fit: contain`, so the inconsistency costs nothing and re-encoding would
break the blob-id check below.

That claim is checkable, and was checked on 2026-08-22: **every one of the 56
weapon files here has the same git blob id as the upstream file it came from.**
Blob ids, not a `diff` of two worktrees — `.gitattributes` marks `*.png
binary`, so the bytes are the bytes. Note the directory holds 57 PNGs, not 56:
`repairkit.png` is not from upstream and will not match anything there. See the
section below.

    git ls-tree HEAD ui-src/public/items/
    curl -s "https://api.github.com/repos/R3DIANCE/GTA-V-Weapons-images/git/trees/master?recursive=1"
    # then match our blob shas against the upstream tree's

Most ids map to our own `label` in `weapons.lua`; a handful use the GTA display
name instead (Heavy Revolver MK II, Carbine Rifle MK II, Marksman Rifle MK II,
Molotov Cocktail, Tear Gas, Knuckledusters, Fist). **Watch the near-misses** —
`Heavy Weapons/` also holds a *Compact* Grenade Launcher, a Homing Launcher and
a Widowmaker, none of which is the weapon we issue.

## The licence, which does not exist

**That repository has no licence.** There is no `LICENSE` file in its tree and
the GitHub API reports `"license": null` — verified 2026-08-22, not assumed.
So this art is **not** licensed to us, and nothing here should be read as
claiming it is.

It is used anyway, on the owner's explicit decision. Owner, 2026-08-22:

> "And yes for the weapon pngs they're GTA's own weapon renders, the repo is a
> convenience mirror. We can use them."

The reasoning, in his words, is that the images are **Rockstar's own weapon
renders** — the repo did not create them and is not the party with anything to
grant, so its silence on licensing says nothing about the art. This gamemode is
a GTA V mod that runs only for people who own the game, and it already depends
on Rockstar's assets everywhere else.

This is a **judgement call by the owner, recorded so it is not re-litigated and
not quietly mistaken for a licence.** Two things follow:

* Do not add a `LICENSE` file or a `license` field for this art. There is
  nothing to put in one, and inventing a field is worse than the honest gap.
  `tools/verify.sh`'s `vendored third-party` gate — which *does* demand a
  LICENSE plus `upstream`/`version`/`commit` — scans `resources/**/VENDOR.json`
  and does not reach this directory. That is why the provenance lives here, in
  prose, next to the files: a `VENDOR.json` here would look enforced and would
  not be. See `resources/[voice]/pma-voice/VENDOR.json` for the shape this is
  imitating.
* If the position ever changes, the fix is not a licence — it is replacing the
  art. Every file is a plain PNG keyed by item id, so the set can be swapped
  wholesale without touching a line of code.

## `repairkit.png` — the one file that came from somewhere else

**Supplied by the owner on #228** (2026-09-03), attached to the issue, and
committed as sent: 476×476 RGBA, 201 KiB, transparent-backed and square, which
is the shape this file asks for above. It is not recompressed or resized —
re-encoding the owner's own artwork to save a couple of hundred kilobytes on a
local-disk `nui://` fetch buys nothing.

**Where he got it, and on what terms, is not recorded here, because nobody has
told us.** That is a gap in this document rather than a claim about the art: it
is deliberately *not* described as GTA's own, as public domain, or as licensed,
and the blob-id check above cannot say anything about it. **The owner should
fill this paragraph in** — one sentence naming the source is enough, and it is
the same judgement call, recorded the same way, as the weapon renders above.
