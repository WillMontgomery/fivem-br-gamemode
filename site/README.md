# site/ — the player manual

The public how-to for players. Deliberately two hand-written files and no build
step for the content: a manual that needs a toolchain to edit is a manual that
stops being edited.

```
site/
  index.html   the whole manual
  style.css    the whole stylesheet
  shots/       screenshots (see below)
  .nojekyll    belt and braces against Pages treating this as a Jekyll site
```

## How it gets published

`.github/workflows/pages.yml` uploads this folder as the entire site on every
push to `main` that touches `site/**`. Nothing is compiled — the workflow
uploads these files exactly as they sit here.

The one-time repo setting is **Settings → Pages → Source: GitHub Actions**.
The legacy "deploy from a branch" mode can only serve the repository root or
`/docs`, never `/site`, which is the whole reason the workflow exists.

It is live at <https://blitz-royale.com/>. The domain is configured in the
repo's Pages settings rather than in a `CNAME` file here, because that is where
it lives when the build type is a workflow.

**`main` is the only branch that publishes.** Work merged to `dev` does not
change the live site until `dev` reaches `main`, so "I fixed it" and "it is
fixed for players" are two different days.

**Everything in this folder is public**, including this file — it is uploaded
with the rest and served as a static file. Write nothing here you would not put
on the front page.

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
`loot`, `fight`, `storm`. All five are still placeholders.

Write a real `alt`. Some of the people reading this play with a screen reader.

## Keeping it honest

**Every number in the manual is duplicated from the game's config**, which
means it can go stale. A manual that disagrees with the game is worse than no
manual. What is currently baked in, and where it comes from:

| In the manual | Comes from |
|---|---|
| Rarity damage steps (+6/12/20/28%) | `br_lib/shared/enums.lua` → `BR.RarityInfo` |
| Consumable amounts, caps and times | `br_lib/config/loot.lua` → `BR.Config.Consumables` |
| Storm phases and damage per second | `br_lib/config/storm.lua` → `phases` |
| Default keybinds | `br_core/client/keybinds.lua` |
| Five ammo pools | `br_lib/shared/enums.lua` → `BR.AmmoType` |
| 48 players, squads of 4 | `br_lib/config/match.lua` |
| XP per event, and the level curve | `br_lib/shared/xp.lua` → `BR.Xp.Config` |
| Volts per event, and the worked totals | `br_lib/config/market.lua` → `BR.Config.Market.payout` |
| What crossing a level pays | `br_lib/config/market.lua` → `BR.Config.levelBonus` |
| Bleed timer and its escalation, revive hold, revive health | `br_lib/config/match.lua` → the `dbno*` values |
| "About four rifle rounds to finish a knock" | `br_lib/config/match.lua` → `dbnoBleedPerDamage`, whose own note states the design as a round count |
| Voice range, and the three voice modes | `br_lib/config/match.lua` → `Config.Match.voice`; the modes themselves are `BR.VoiceRouting` in `br_lib/shared/enums.lua`, two booleans per mode that are never both true |
| Which mode is offered in solos, and that the two preferences are separate | `ui-src/src/screens/Settings.tsx` → `SOLO_MODES` / `SQUAD_MODES`; `BR.ToSoloVoiceMode` in `br_lib/shared/enums.lua` enforces the same rule in Lua |
| Every key in the Controls section, including push-to-talk | `br_core/client/keybinds.lua` — the `tap()` / `hold()` rows, **and `BR.Keys.on` for the same action**. A row with no subscriber is a key that does nothing |
| Report rules — five at a time, three submissions a match, one per player per match | `br_lib/config/match.lua` → `BR.Config.Report` |
| What an accurate report pays | `br_stats/server/awards.lua` → `AWARD_VOLTS`. **Not** in `market.lua`: it is a bounty on a moderation outcome, not part of the earn-per-hour curve |
| That a trail slot has no visible default, and canopies and finishes do | `br_lib/config/market.lua` → the `hidden` flag on `trail_none`, filtered in `br_ui/client/market.lua` |

**This table is the only thing standing between the manual and quiet drift, so
it has to grow whenever the manual does.** It has already failed twice exactly
that way. The XP and Volts tables were added to the manual without being added
here, the payout was retuned four days later, and nothing connected the two — the
live site went on quoting the old numbers to players. Then the downed timers *did*
get a row here, and the manual still went stale anyway: it was written against a
45-second bleed and an eight-second revive hold, both of which had already
changed. **A row is a pointer, not a check.** Until the generator below exists,
adding a number without a row is one failure mode and trusting a row you have not
re-read is the other.

**Third failure, 2026-08-21, and it is the one that proves the sentence above.**
Every Volts figure in the manual — the whole payout table, "a clean win is 135",
"a middling match is worth around 70", and the report bounty in both of the
places it appears — was double the live number, because the halving on 2026-08-20
moved five integers in `market.lua` and one in `awards.lua` and touched nothing
here. Both of those already had rows in this table. The rows were correct, nobody
re-read them, and the site kept promising players twice what the game pays.

**The same audit found four keys the manual named that do nothing**, which is a
failure this table could not have caught in the shape it had, because a keybind is
not a number: `Z` for a squad marker (removed — the marker rides the map-waypoint
gesture now), `M` for the map (the map is on the pause menu), and the two spectate
arrows. All four still have `RegisterKeyMapping` rows, so they look live in the
config and in the rebinder; what they do not have is a `BR.Keys.on` subscriber.
That is why the keybind row above names both halves. **A bound key with no
listener is indistinguishable, to a player, from a broken feature** — and printing
one in the manual is worse, because it tells them to expect it.

**It should be generated, not typed** — a script in `tools/` emitting these
tables into `index.html`, gated so the build fails when the committed output
drifts from the config. Until that exists, the table above is the manual
version of it.

## Previewing locally

Serve this folder over HTTP. Any static server will do, from inside `site/`:

```
python -m http.server 3100
npx --yes http-server -p 3100     # if you would rather use node
```

Then open <http://localhost:3100/>.

Opening `index.html` as a `file://` URL does **not** work — the stylesheet
silently fails to apply and the page renders unstyled, which looks like a CSS
bug and is not one.

## House style

Written for a player, not a maintainer. Second person, short sentences, and
every section answers "what do I actually do".

Nothing internal ever goes in `index.html`: no issue numbers, no milestone
names, no file paths, no resource names. A player has no way to resolve any of
it, and this page is the front door. Anything that reads like implementation
belongs in `docs/` instead.
