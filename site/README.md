# site/ — the player manual

The public how-to for players, published by GitHub Pages straight out of this
folder. Deliberately two hand-written files and no build step: a manual that
needs a toolchain to edit is a manual that stops being edited.

```
site/
  index.html   the whole manual
  style.css    the whole stylesheet
  shots/       screenshots (see below)
```

## Turning it on (one time)

Repo **Settings → Pages → Build and deployment**:

- Source: **Deploy from a branch**
- Branch: **main**, folder: **/site**

It lands at `https://willmontgomery.github.io/fivem-br-gamemode/`.

A custom domain is a `CNAME` file here plus a DNS record, if it is ever wanted.

## Adding screenshots

Every image slot is a `<figure class="shot">` with a dashed placeholder in it.
Drop the file in `shots/` and swap the placeholder for an `img`:

```html
<!-- before -->
<figure class="shot" data-shot="lobby">
  <div class="placeholder">Screenshot: the lobby</div>
</figure>

<!-- after -->
<figure class="shot" data-shot="lobby">
  <img src="shots/lobby.jpg" alt="The lobby, with the character on the right">
</figure>
```

The stylesheet already handles `img` inside `.shot` — full width, rounded,
bordered. Nothing else to change. There are five slots: `lobby`, `drop`,
`loot`, `fight`, `storm`.

Write a real `alt`. Some of the people reading this play with a screen reader.

## Keeping it honest

**Every number in here is duplicated from `br_lib/config/`**, which means it can
go stale. A manual that disagrees with the game is worse than no manual. The
values currently baked in:

| In the manual | Comes from |
|---|---|
| Rarity damage steps (+6/12/20/28%) | `br_lib/shared/enums.lua` → `BR.RarityInfo` |
| Consumable amounts, caps and times | `br_lib/config/loot.lua` → `BR.Config.Consumables` |
| Storm phases and damage per second | `br_lib/config/storm.lua` → `phases` |
| Default keybinds | `br_core/client/keybinds.lua` |
| Five ammo pools | `br_lib/shared/enums.lua` → `BR.AmmoType` |
| 48 players, squads of 4 | `br_lib/config/match.lua` |

**This should be generated, not typed** — a script in `tools/` emitting the
tables into `index.html`, gated so the build fails when the committed output
drifts from the config. That is tracked as part of the M9 site work and is the
main thing standing between this being scrappy and being trustworthy.

## Previewing locally

`.claude/launch.json` has a `br_site` entry that serves this folder on
port 3100. Opening `index.html` as a `file://` URL does **not** work — the
stylesheet silently fails to apply and the page renders unstyled, which looks
like a CSS bug and is not one.

## House style

Written for a player, not a maintainer. Second person, short sentences, and
every section answers "what do I actually do". Anything that reads like
implementation belongs in `docs/` instead.
