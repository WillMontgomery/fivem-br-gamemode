# The terminals' contract

Season 2's computer terminals (#396): the Yubikey that unlocks them, the
terminals in the world, the rules a use is held to, how `br_core` opens the
computer, what it shows, and how a request to run a function gets to the
server and back.

[← Back to the main README](../README.md)

---

Four pieces, in three places. Each knows only its neighbors.

| Piece | Where | Its job |
|---|---|---|
| **The server door** | `br_core/server/terminal.lua` | Opens a session for a player on a terminal, lists the functions, takes a run only inside that session, decides it, answers. |
| **br_core's client** | `br_core/client/terminal.lua` | Opens and closes the computer when the server says, relays run requests up and answers down, tells the key layer when the computer holds the keyboard. |
| **The computer** | `resources/[computer]/cuchi_computer` | Vendored, cut-down [cuchi_computer](https://github.com/Cu-chi/cuchi_computer) (GPL-3.0). `client/shell.lua` holds NUI focus while the desktop is up and forwards what the page asks; `nui/br.js` drives the desktop. Decides nothing. |
| **The app** | `ui-src/terminal`, built into `cuchi_computer/nui/apps/terminal` | "Control Tower": React + Cloudscape, a web site in the desktop's one window (an iframe) dressed as a browser. Renders the state, the copy and the catalog, asks to run. Decides nothing. |

Around them, the Gameplay half:

| Piece | Where | Its job |
|---|---|---|
| **The key** | `br_core/server/yubikey.lua` | Who holds a Yubikey, on the profile row through br_ddb (`yubikey`, `yubikeySeen`); every way one changes hands. |
| **The world** | `br_core/client/yubikey.lua` | Each terminal's blip and plate (the laptops are the owner's ymap's, hidden where terminals are off); the press that asks to open one; the key's HUD glyph; Storm reveal on the maps. Decides nothing. |
| **The shared rules** | `br_lib/shared/terminal_solve.lua` | Online against the storm (`offlineWhy`), the squad's key, the sites list, the notice tokens, the extra roll -- one spelling for both sides. |
| **The effects** | `br_core/server/terminalfx.lua` | What the first built functions do: Scan and its bounty, Supply drop, Max ammo, and the pushes that keep Scan and the bounty on screen; and the helpers the files below share. |
| **One file per function** | `br_core/server/terminalfx/<id>.lua` | Wave A on (2026-10-06): Field medic, Disarm, Ghost, Contract -- see [Wave A](#wave-a-owner-2026-10-06); wave B's Storm control, Time & weather and Power outage -- see [wave B](#the-storm-the-sky-the-clock-and-the-lights-wave-b); wave C's EMP, Comms blackout and Reboot -- see [Wave C](#wave-c-owner-2026-10-06); and round 5's Gear Up, Vehicle drop and Airstrike -- see [Gear Up](#gear-up-round-5-owner-2026-10-06), [Vehicle drop](#vehicle-drop-round-5-owner-2026-10-06) and [Airstrike](#airstrike-round-5-owner-2026-10-06). Every row is built. |
| **The marks** | `br_core/client/terminalfx.lua`, `br_core/client/terminalfx/<id>.lua` | Scan's opponents and the bounty on this player's maps, an EMP held on the vehicle this player drives, a Vehicle drop's look for somewhere to land, its descent and its blip, and an Airstrike's circles, flare and rockets, from the server's pushes. Decides nothing. |
| **The persistent notices** | `br_core/server/terminalfx.lua` (and each function file's source), `br_core/client/terminalfx.lua`, `ui-src/src/hud/Impacts.tsx` | Round 4: what another player's terminal run is doing to each player, with its clock, at the foot of the HUD's notice stack -- see [the persistent notices](#persistent-notices-round-4). |

**The server decides everything.** The computer and the app only ask. A run is
taken only from a player with an open session on that terminal, which only the
server opens, and the server checks the terminal, the key and the squad again
before anything happens. A client never says it is at a terminal, never says it
holds a key, and never names a terminal it was not opened on.

## The state

What the computer opens with, and what the server sends again when it changes.

```lua
{
  terminalId = 'dev',            -- string, at most 64 characters
  functions  = {                 -- every registry row, in its order
    { id = 'storm_reveal', available = true },
    { id = 'scan', available = false, reason = 'squad_used' },
    { id = 'disarm', available = false, reason = 'fn_offline' },
  },
  keyHeld    = true,             -- this player holds a Yubikey
  squadUsed  = false,            -- their squad has used its one key this match
  squadMatch = true,             -- in a squad match (BR.Terminal.squadMatch)
  volts      = 1250,             -- their balance, as every Volts display shows it
  running    = { functionId = 'scan', runMs = 4200, leftMs = 1800 },  -- or nil
  player     = 'NightOwl',       -- the roster name: the app's signed-in user
  match      = {                 -- BR.Terminal.matchInfo; nil outside a match
    tag, mode, phase, elapsedMs,
    storm = { stage, stages, state, leftMs },
    players, squads,             -- still in the fight (BR.Server.isInMatch)
    squad = { { name, state = 'alive'|'downed'|'out', me } },  -- theirs only
    terminals = { online, total },
    bounties = { { name, leftMs } },
  },
  mates      = { { id = '12', name = 'Bravo' } },  -- round 5: BR.Terminal.mates
}
```

`mates` (round 5) is this player's standing teammates -- ALIVE, never the
player, in a squad match alone, in server id order -- each a server id as a
string and the roster's name: the choices of an option with `source =
'mates'` (Gear Up's teammate). Live with every push, so the dropdown follows
who is still up.

`reason` is a code, and a code is a key into the copy: `fn_offline` (the
effect is not built), `offline`, `squad_used`, `no_key`, `bad_option`, `unavailable` (a run of theirs or their
squad's in flight, a squad-only function outside a squad match), or any key a
function's own refusal adds (`no_storm`, `no_site`, `drop_busy`, `ammo_full`,
round 7's `no_guns`,
Storm control's `storm_aimed`;
wave A's `health_full`, `no_weapons`, `no_target`; wave C's
`reboot_none`). The app shows the line for the
code, or `unavailable` when there is none, and maps it to the card's
statuses: Available, Used (`squad_used`), Not available (`fn_offline`,
`offline`), and -- round 6 (owner, 2026-10-07: "Let's make all the terminals
have all the same tools available please"; on the tools' own rules, "Yes
please say the real reason") -- for everything else **the reason itself**, in
a few words: `status_<reason>` (`status_no_night` "Only at night",
`status_storm_aimed`, ...), or `status_not_now` "Not available now" for a
reason with no short line (`unavailable`). Home's Status filter groups all of
those as Not available now. Every terminal lists every tool; round 2's "Not
available at this terminal" is gone. The balance is never a listing's reason:
Run stays pressable whatever it is, and only a run is refused `no_volts`.

**`squadMatch`** is true in a match's bus or playing phase, in a mode whose
squads are bigger than one; the lobby, the warmup pad and a dev terminal
outside a match are not. Outside one the squad-only functions (`squadOnly`)
are not listed. **`running`** is the run this player has loading, so an app
opened again mid-load shows the same bar.

THE SAME STATE, ONCE A SECOND. While a computer is open the server pushes it
again every `infoPushMs` (TERMINAL_INFO), to that player alone; that is what
makes the match panel realtime. Nothing in the app runs a clock of its own.

## The copy

**Every player-facing line is in one block**, `copy` in
`br_lib/config/terminals.lua`. The desktop and the app render keys out of it and
nothing else: a key with no line renders as nothing, never as the key.
`br_core`'s client hands the whole block to the computer with each opening (the
client already has it, so it never crosses the network). Changing a line is an
edit there and a restart.

Three kinds of line, marked in the file: the owner's **verbatim** words
(`no_key`, `notice_access`, `notice_action`, `bounty_new`, `bounty_protect`,
round 2's `app_title`/`desktop_icon`/`window_title` "Control Tower",
`match_heading` "Match stats", `status_offline` "Not available", and round 3's plate,
`terminal_label` "Computer system" and `terminal_use` "press to open"), lines
**written** for the 2026-10-05 app at his request and listed in that round's
report for his review (the app's frame and pages, every function's lines, the
how-to, round 2's lines, marked "WRITTEN (2026-10-05, round 2)", and round 3's
one edit, `howto_terminal_body`'s "press interact"), and, since round 5, no
**placeholder** at all: `first_pickup` is the owner's own text (the
first-pickup card; since round 6 four lines, `first_pickup_title`,
`first_pickup_subtitle`, `first_pickup` and `first_pickup_dismiss`), and
`already_holding` and `key_label` are written. Round 6's new lines are marked
"WRITTEN (round 6, proposal for the owner)". A line
with a newline in it is
a list; `{name}`, `{value}`, `{count}`, `{stage}`/`{stages}`,
`{online}`/`{total}` and `{volts}`/`{cost}`/`{balance}` (a figure and the
currency word, "1,250 Volts") are filled by the app.

**"Squad" only in a squad match** (owner, round 2). A line that says squad has
a `<key>_solo` sibling that does not, and one picker per side chooses: the
Lua side's `BR.TerminalSolve.pick` (the server's toasts, notices and reasons)
and the app's `speaker` (model.ts), both from
`squadMatch`. An empty `_solo` line hides the row it labels (the match
panel's squad rows, the mode in a squad match's warmup). A squad-only
function's lines, and the Squad category's name, are only ever shown in a
squad match, so they have none. `tools/test_terminal.lua` fails a line that
says squad with neither, and a Lua reader that indexes the copy by a computed
key or names a line with a sibling directly; `check-terminal.mjs` fails an app
component that reads the copy without the speaker.

Every function has, keyed by its id: `_name`, `_summary` (its card), `_what`,
`_duration`, `_affects`, `_notified`, `_risks` (optional; `risk_notice` is
always listed first, but on a `quiet` row's page), `_done`, `_description`
(the lobby notice's `{description}`; none on a `quiet` row, which the lobby is
not told of), and per option `_opt_<option>` and `_opt_<option>_<choice>`
(with an optional `_desc`). `tools/test_terminal.lua` fails a row missing any,
and a quiet row that has a `_description`.

The table below is the lines outside the functions' own:

| Key | Who reads it |
|---|---|
| `shell_boot` | At the terminal: under the boot spinner, for the 7-10 s boot |
| `bsod_face`, `bsod_text`, `bsod_code` | At the terminal: the storm's close (round 4), the whole computer's blue screen for 1.5 s before it powers off -- a Windows 10 parody: its sad face, one sentence, and a stop code naming the storm |
| `desktop_icon` | At the terminal: under the app's desktop icon |
| `window_title` | At the terminal: the browser's one tab |
| `app_title` | At the terminal: the top bar's title, and nowhere else in the app |
| `address_host`, `path_*`, `aria_*` | At the terminal: the address bar, the browser's buttons |
| `running` | At the terminal: the bar under a run while the server carries it out; `{name}` |
| `balance_new` | At the terminal: after a paid run's done line -- in the app, or in the toast when the computer closed first; `{volts}` |
| `no_volts` | At the terminal: why a run the balance cannot cover was refused; `{cost}`, `{balance}` |
| `cost_line_volts`, `confirm_body_volts` | At the terminal: a priced function's cost and its confirmation; `{volts}` |
| `<key>_solo` | The same reader as `<key>`, outside a squad match |
| `search_*`, `mode_*`, `menu_*`, `nav_*` | At the terminal: the search, the light/dark switch, the user menu, the side navigation |
| `match_heading`, `field_*` and their values | At the terminal: the "Match stats" panel, collapsed when the app opens |
| `tools_heading`, `filter_*`, `card_*`, `pref_*`, `status_*`, `risk_*`, `category_*` | At the terminal: the cards (round 5: the heading "Tools", was `functions_heading` "Functions") |
| `card_cost`, `card_bounty`, `cost_free`, `cost_paid`, `bounty_none`, `bounty_runner`, `bounty_target`, `filter_any` | At the terminal (round 4): a card's Cost and Bounty sections (and their names in the preferences' Card content), and Home's filters -- each labeled with a `card_*` line, `filter_any` its no-filter choice, the cards' own words its others (`cost_paid` the Cost filter's choice for every priced function) |
| `squads_link`, `squads_popover` (VERBATIM) | At the terminal, in a squad match only (their `_solo` lines are empty): "Squads!" beside the title of a `squadWide` function's card and page, and the box it opens |
| `details_heading` .. `cost_line`, `risk_notice`, `run`, `confirm_*` | At the terminal: a function's page and its confirmation |
| `howto_*` | At the terminal: the how-to page |
| `privacy_*` | At the terminal: the Privacy page, the owner's approved policy (VERBATIM, "Perfect", 2026-10-06): its title and two paragraphs |
| `unavailable` | At the terminal: why not, for a code with no line |
| `fn_offline`, `bad_option`, `no_storm`, `no_site`, `drop_busy`, `ammo_full` | At the terminal: why not |
| `no_guns`, `status_no_guns` (WRITTEN, round 7) | At the terminal: why not, and the card's status (Max ammo, when nobody it fills carries a gun) |
| `storm_aimed` | At the terminal: why not (Storm control, once a spot is picked this match: one spot a match) -- round 4's review |
| `health_full`, `no_weapons`, `no_target` | At the terminal: why not (wave A's functions) |
| `no_night` | At the terminal: why not (Power outage, unless it is night because of a Time & weather run) -- round 4 |
| `reboot_none` | At the terminal: why not (Reboot: nobody in the squad eliminated and still in the match). Squad-only, so no `_solo` line |
| `gear_standing`, `gear_no_mate`, `gear_full`, `gear_full_mate`, `gear_full_squad`, `gear_no_room`, `gear_no_room_mate`, `gear_no_room_squad` | At the terminal: why not (Gear Up, round 5: nobody standing to get it, a teammate who no longer can, already carrying the most, no room). The `_squad` two have empty `_solo` lines: the squad is no choice outside a squad match |
| `gear_up_received` | A toast to each teammate who got Gear Up's item from somebody else's run, after the lobby's notice: `{playername}` the runner, `{description}` what they got ("3 Med Kits") |
| `gear_up_opt_item_<id>` | Gear Up's dropdown: each item's own `label` from the weapons and loot configs, written into the copy as `terminals.lua` loads -- no words of ours |
| `drop_no_mate`, `drop_target`, `drop_ground`, `drop_ground_mate` | At the terminal: why not (Vehicle drop, round 5: the teammate is not standing, the player it was for is not standing when it drops, no road or open ground within 40 m of the runner or of the teammate). Squad and solo alike |
| `vehicle_drop_received` | A toast to the teammate a Vehicle drop lands next to, from somebody else's run; `{playername}` the runner |
| `vehicle_drop_blip` | The runner's squad: the legend name of the dropped car's blip, until one of them gets in |
| `strike_spot` | At the terminal: why not (Airstrike, round 5: the spot picked is outside the play area) |
| `airstrike_blip`, `airstrike_fuzz_blip` | The legend names of an Airstrike's circle, on every player's map, and of the rough circles its runner sees while picking the spot |
| `cost_free_or` | A card's cost when it depends on the choices and the cheapest is free (round 5): `{volts}` the most it can cost -- over the choices this player is offered, so a solo player's Gear Up card reads `cost_free` (round 5's review) |
| `impact_*` (`impact_emp`, `impact_outage`, `impact_blackout`, `impact_bounty`, `impact_scan`, `impact_time`, `impact_weather`, `impact_storm`, `impact_airstrike`) and `impact_until_end` | On the HUD, to the player it is happening to: what another player's terminal run is doing to them, beside its clock -- or `impact_until_end` in its place for the rest of the match (round 4) |
| `no_key`, `squad_used` | At the terminal (why not; `no_key` is also the login screen), and `squad_used` the toast for a run refused for it. Never the world's plate: not `no_key` since round 6, not `squad_used` since round 7 -- the plate is one plate whatever the player's status |
| `offline` | At the terminal (why not: the dev tool's `brterminal offline`, or the moment before the storm's close), and a toast to a player whose press reached the server a step behind the storm. Never a plate since round 4: a terminal outside the storm has none |
| `bounty_new` | A toast to the lobby: Scan's or a Contract's bounty; `{playername}` |
| `bounty_protect` | A toast to the bounty's squad, not the bounty (Scan's or a Contract's: both ten minutes since round 4); `{playername}` |
| `scan_blip`, `bounty_blip` | The legend names of Scan's and the bounty's marks |
| `<id>_description` | The lobby: the `{description}` in `notice_action` |
| `first_pickup_title`, `first_pickup_subtitle`, `first_pickup`, `first_pickup_dismiss` | The player who gets their first Yubikey ever: the first-pickup card's words, verbatim -- its H1, its H3, its body and the words beside the Enter cap (round 6; round 5's one line split as he asked) -- not a toast |
| `status_<reason>`, `status_not_now` | At the terminal: a card's and a page's status when a rule of the match stops a tool -- the reason in a few words, or "Not available now" (round 6) |
| `rarity_<key>` | At the terminal: Gear Up's item list, each item's rarity on the right of its row -- BR.RarityInfo's own names, filled in as the file loads (round 6) |
| `already_holding` | A toast to a holder whose claim on a second key is refused ("You already have a Yubikey.") |
| `notice_access` | A toast to the lobby (the whole match) when someone gains access; `{playername}` |
| `notice_action` | A toast to the lobby when a function ran; `{playername}`, `{description}` |
| `key_label` | Anyone near a key on the ground: its plate ("Yubikey") |
| `terminal_label` | Anyone near a terminal: its plate's title, and its blip's legend name |
| `terminal_use` | Anyone at a live terminal, key or no key (round 6), the squad's use spent or not (round 7): the plate's hint, beside their interact key's cap |
| `storm_reveal_blip` | The squad that ran Storm reveal: the legend name of the final zone |

`{playername}` travels as `BR.Notice.who` (drawn bold, never formatted into the
sentence); `{description}` as plain text. `BR.TerminalSolve.line` fills both.

## The art

Every placeholder is in one block, `art` in `br_lib/config/terminals.lua`:
`keyProp` and `keyScale` (a key on the ground: the owner's `blitz_seckey`,
24 cm long, as authored) with `keyFallbackProp` and `keyFallbackScale` (the
stock `hei_prop_hst_usb_drive` at 4x, drawn by a client without his pack or
whose stream of it fails), `hudGlyph` (the equipped icon
and the squad panel's holder mark), `terminalProp` (the model the owner's ymap
stands at every site, which Season 1 hides) and `hideRadiusM`,
`blipSprite`/`blipColour` (the owner's 521 and 51) and `blipScale`, and
`reveal` (the final zone's `sprite`, `colour`, `scale`, `radiusM` and
`alpha`). Until round 6 the key was drawn as `prop_cs_usb_drive`, which is no
model at all, so nothing was drawn but its glow.

## The functions

**ONE REGISTRY, READ BY BOTH SIDES**: `BR.Config.Terminals.functions`, each row
`{ id, category, risk, implemented, options, cost?, squadOnly?, soloCategory?, bounty?, squadWide?, spot?, fuzz?, quiet?, costBy? }`,
with `categories` beside it.
The server rules every run against it; br_core's client hands it to the
computer with each opening (the **catalog**), and the app draws its cards,
filters and pages from it.

- `category`: `intel`, `storm`, `disruption`, `supply` or `squad`.
- `risk`: `low`, `medium` or `high` -- how much it exposes the player who runs
  it, drawn as the card's badge.
- `implemented`: false lists the function, card and page and all, as
  `fn_offline`, and refuses its run before anything is asked or spent.
- `cost`: Volts a run costs, 0 to 200 (owner, round 2: "no more than 200";
  `test_terminal.lua` fails a row outside it). Absent is free.
- `squadOnly`: not listed, and its run refused, outside a squad match.
- `soloCategory`: the category a squad-category function is listed under
  outside a squad match.
- `bounty` (round 4): who a run puts a bounty on, as its card and Home's
  Bounty filter say it -- `'runner'` (Scan: the player who runs it gets one),
  `'target'` (Contract: another player does), absent for none. The app's
  words only; each effect gives its own bounty.
- `squadWide` (round 4): the effect reaches the runner's whole squad (its
  `_affects` starts "Your squad", or its marks show on the squad's maps): Scan,
  Storm reveal, Max ammo, Reboot, Ghost, Field medic and Vehicle drop (its
  blip is on the squad's maps).
  In a squad match the app draws "Squads!" beside its title. Presentation
  only; `test_terminal.lua` holds the set to the rows' own lines.
- `spot` (round 4): `true` for a row run at a place picked on the big map
  (see [the map pick](#the-map-pick-round-4)); or, round 6, `{ when = {
  <option> = <choice>, ... } }` for a row run at one ONLY while the run's
  options carry those choices -- Power outage's `{ when = { area = 'spot' } }`
  (owner, 2026-10-07: 'Any use of "near this terminal" is like, not useful for
  this gamemode'). One rule both sides read, `BR.TerminalSolve.spotWanted`
  over the choices the run carries (`BR.Terminal.options`' answer); the app's
  `model.ts` `needsSpot` asks the same. Each `when` names an option of its row
  and one of its choices; any other shape is no spot (`spotRule`).
- `fuzz` (round 5, Airstrike): a row run at a spot whose map pick shows the
  player's opponents as rough circles near where they are -- never centered on
  anybody -- while the big map is up. The client says when the pick starts and
  ends (`TERMINAL_PICK`), and the server sends the circles (`TERMINAL_FUZZ`).
- `quiet` (round 4, owner 2026-10-06: "Field medic should not notify
  everyone"): the lobby is not told it ran -- no `notice_action`, no
  `_description` -- and its page leaves out `risk_notice` (the app's
  `risksOf`). Opening a terminal with a key still tells the lobby
  (`notice_access`), the owner's own rule.
- `options`: `{ { id, choices = { ... }, default } }`. `BR.Terminal.options`
  takes a run's choices only if every key is a declared option and every value
  one of its `choices` (strings, at most 8), fills the rest with defaults, and
  refuses anything else whole (`bad_option`, nothing spent). The shell and the
  desktop shape-check them on the way too. Round 5: an option with `source =
  'mates'` has no `choices` or `default` -- its choices are the state's
  `mates`, and the door takes the shape of one (a server id, digits, at most
  ten) and leaves whether it is still a standing teammate to the function --
  and `dropdown = true` draws an option as a dropdown rather than radio
  buttons. An option whose label, or a choice whose line, is empty for this
  player is not shown (Gear Up's "Who gets it" outside a squad match).
- `costBy` (round 5): a price by choice, `{ option, choices = { [choice] =
  Volts } }` -- Gear Up's `{ option = 'who', choices = { squad = 200 } }`. A
  run whose option has a listed choice costs that, any other the row's `cost`
  (`BR.Terminal.costOf(row, opts)`). Every figure 0..200 like `cost`. The page's
  cost line and the confirm box say the run's own price; the card says
  `cost_free_or` with the most it can cost, and the Cost filter finds it under
  Free and Paid. Round 5's review: the card and the filter work this out over
  the choices THIS player is offered (`model.ts` `offeredValues`: each choice
  with words for him, or, for an option the page hides from him, its default),
  so a solo player, never offered the whole squad, reads Free and finds Gear Up
  under Free alone; and every option's default is a choice a solo player has
  (`tools/test_terminal.lua`).

The server half of a built function is `BR.Terminal.FUNCTIONS[id]`
(`server/terminal.lua` for Storm reveal, `server/terminalfx.lua` for Scan,
Supply drop and Max ammo, and from wave A on a file of its own,
`server/terminalfx/<id>.lua`):

- `refuse(src, session, opts) -> reason|nil` (optional), asked after the shared
  reasons, which come in this order: `fn_offline`, `unavailable` (squad-only,
  outside a squad match), `offline`, `squad_used`, `no_key`, `unavailable` (a
  run in flight). `opts` is nil while the terminal is only being listed:
  answer for ANY choice, so a card says the reason only when no choice could
  run. It is asked again when the loading is over.
- `run(src, session, opts) -> { ok, code, after? }`, called when the loading
  is over. On `ok` the server tells the lobby `notice_action` (not for a
  `quiet` row), then calls
  `after` -- so Scan's bounty toasts follow the redemption. Anything else
  gives everything back (see the run, below).
- `prepare(src, session, opts)` (optional, round 5): called as the run is
  accepted, before the load, for an effect that has to ASK the world first --
  Vehicle drop's landing spot, which only a client can see. The load is the
  time the answer has to come back in; `run` decides on whatever came.
  `abandon(src, session, opts)` (optional) lets go of what `prepare` started
  when the run is refused or fails as the load ends. The dev command's `run`
  calls `prepare` too, and runs `runMinMs` later.

### The run: asked, accepted, loading, done (owner, 2026-10-05, round 2)

1. **Asked.** Every refusal above, then the options, then the **Volts**: a
   row's `cost` against `BR.Market.balanceOf` (the figure every other Volts
   display shows). Short is `no_volts`, answered with `cost` and `balance`;
   nothing is spent.
2. **Accepted.** In flight for the player and their squad. The Volts are spent
   first, through `BR.Market.charge` -- the revive key's conditional write, so
   two presses, two players or two terminals never spend twice; a write that
   fails or cannot be made refuses with nothing spent (`no_volts` when the row
   says the balance is short, else `unavailable`). The door is asked again
   (the round trip is long enough for a key to drop), then the key and the
   squad's use are spent. The server picks `runMinMs..runMaxMs` (3-5 s) and
   answers `running` with `runMs`.
3. **Done**, when that time is up: the match still playing, the function's
   own `refuse` asked again, `run`. Then, and only then, `notice_action`. An
   effect that can no longer happen -- the match ended, `drop_busy`, the
   player left the server -- gives back the Volts (`BR.Market.refund`, by
   account), the key (`BR.Yubikey.restore`, by account) and the squad's use,
   and answers the reason. A paid `done` carries the new `balance`.

**Closing, walking away, going down or dying while it loads does not stop a
paid run.** While the computer is open on the session that asked, the app
gets the answer; once it has closed, the done line (and the new balance) or
the reason arrives as a toast. A runner already out gets no bounty.

**A run's last word never goes nowhere** (review of round 2). The server knows
a computer has closed only when `TERMINAL_CLOSED` arrives, so every last word it
sends -- every answer but `running` -- carries `toast`, the very line it would
toast itself (through the solo picker). Whichever surface finds it cannot show
the answer toasts that line, once: `br_core`'s client for an answer that lands
after the computer went away (or on another terminal, or with no computer), and
the desktop, through the shell, for an answer it held for an app that was not
there to take it -- its window closed, still loading after its icon was
clicked, or minimized and never shown again -- when the computer closes
first.

| id | Name | Category | Risk | Cost | Effect |
|---|---|---|---|---|---|
| `scan` | Scan | intel | high | 200 | **live** |
| `storm_reveal` | Storm reveal | intel | low | | **live** |
| `storm_control` | Storm control | storm | medium | 150 | **live** (wave B) |
| `comms_blackout` | Comms blackout | disruption (squad-only) | medium | | **live** (wave C) |
| `time_weather` | Time & weather | disruption | low | | **live** (wave B) |
| `power_outage` | Power outage | disruption | low | | **live** (wave B) |
| `disarm` | Disarm | disruption | high | 200 | **live** (wave A) |
| `airstrike` | Airstrike | disruption | medium | 200 (proposed) | **live** (round 5) |
| `supply_drop` | Supply drop | supply | medium | | **live** |
| `max_ammo` | Max ammo | supply | low | | **live** |
| `reboot` | Reboot | squad (squad-only) | medium | 150 | **live** (wave C) |
| `ghost` | Ghost | squad (disruption alone) | low | | **live** (wave A) |
| `emp` | EMP | disruption | medium | | **live** (wave C) |
| `gear_up` | Gear Up | supply | low | 200 for the whole squad (`costBy`), else free | **live** (round 5) |
| `vehicle_drop` | Vehicle drop | supply | medium | 100 (proposed) | **live** (round 5) |
| `contract` | Contract | disruption | medium | | **live** (wave A) |
| `field_medic` | Field medic | supply | low | | **live** (wave A) |

The costs are the coordinator's proposal for the owner (round 2). Time &
weather changes the time or the weather, never both, for the rest of the match;
it offers no thunderstorm and no rain, and its chosen weather holds only inside the
circle -- outside, the storm's own weather wins (the owner's rule; how it is
built is [wave B's section](#the-storm-the-sky-the-clock-and-the-lights-wave-b)).

**Wave B's functions are a file each** (#396, 2026-10-06), as wave A's are:
the server half in `br_core/server/terminalfx/<id>.lua`, the client half (when
there is one) in `br_core/client/terminalfx/<id>.lua`, both listed in
`br_core/fxmanifest.lua` after `terminalfx.lua`; `tools/test_terminal.lua`
loads every `server/terminalfx/` file the manifest names.

The first nine are the owner's (2026-10-04), the next four were suggested on
the issue, and the last three are proposals for him to keep or cut. He cut two
more proposals on 2026-10-06: Lockdown ("The player gains nothing from using
that") and Storm delay ("We have to keep the pace of the match"). A new
function is a row, its copy lines, and -- to go live -- an entry in
`BR.Terminal.FUNCTIONS` and `implemented = true`. `tools/test_terminal.lua`
fails a row missing a line, and a built row with no server entry.

## The wire

| Event | Way | Payload | Rule |
|---|---|---|---|
| `BR.Net.TERMINAL_OPEN` | S→C | `{ state }` | Open the computer on this terminal. |
| `BR.Net.TERMINAL_RUN` | C→S | `{ terminalId, functionId, options?, at? }` | Dropped, unanswered, without an open session on that terminal, with a malformed id, or sooner than `runMinIntervalMs` after the last. Options the registry does not allow are answered `bad_option`, and so is a spot (`at = { x, y }`, two finite numbers within 20 km of the map's middle) missing from a run at one (`spot`; round 6, or its `spot.when` holding for the choices sent) or sent with one that takes none (`BR.Terminal.spot`). |
| `BR.Net.TERMINAL_INFO` | S→C | `{ terminalId, state }` | The open computer's state again, match panel included, every `infoPushMs` (1 s), to that player alone, only while open, never off Season 2. |
| `BR.Net.TERMINAL_SCAN` | S→C | `{ matchId, list = { { s, x, y, down? } } }` | Scan: every opponent's position, to the scanning squad alone (dead and spectating members included), every `fx.scanPingMs` for the rest of the match. A squad under Ghost is left out. |
| `BR.Net.TERMINAL_BOUNTY` | S→C | `{ matchId, list = { { s, x, y } } }` | Each live bounty's position (a Contract's too), to everyone in the match outside that bounty's squad, every `fx.bountyPingMs`, and once more, empty, when the last ends. A bounty on a squad under Ghost is left out. |
| `BR.Net.TERMINAL_IMPACTS` | S→C | `{ list = { { key, text, endsAt?, tail? } } }` | The persistent notices (round 4): this player's whole list, to them alone, when it changes -- a row came or went or its end moved -- on a 1 s pass (`fx.endCheckMs`) and at once after a run's effect. `text` is picked for them (squad or solo); `endsAt` is the server's clock, or `tail` (`impact_until_end`) stands in for it. `client/terminalfx.lua` hands it to br_ui as `BR.Nui.IMPACTS`. |
| `BR.Net.TERMINAL_EMP` | S→C | `{ matchId, leftMs?, liveMs? }` | EMP (round 4): how long this player's driving stalls from now (absent when every EMP in force spares their squad) and how long any EMP in the match lasts (absent with none). To the whole match when one goes off and when one ends (its time, the match's end, Season 1), and on `br:ready` while one lasts. `client/terminalfx/emp.lua` applies it to the vehicle its own player drives, and (round 7) lays the road speed zones that stop NPC traffic while `liveMs` lasts. |
| `BR.Net.TERMINAL_DROP_FIND` | S→C | `{ nonce, r, minM, everyMs, forMs }` / `{ nonce, stop }` | Vehicle drop (round 5): to the ONE player the car is for, as the run is accepted -- look for somewhere to land it within `r`, at least `minM` from yourself, and answer every `everyMs` until `stop` or `forMs`. |
| `BR.Net.TERMINAL_DROP_SPOT` | C→S | `{ nonce, x, y, z, h }` / `{ nonce, none }` | That client's best road or open ground. Taken only from the player asked, for the nonce asked, at most twenty a search, and only if `BR.TerminalSolve.dropCheck` passes against the server's own samples; the last good one stands, `none` changes nothing, and it is checked again when the car drops. |
| `BR.Net.TERMINAL_DROP` | S→C | `{ matchId, id, netId, x, y, z, h, tRelease, tLand, alt, blip? }` / `{ matchId, id, x, y }` / `{ matchId, id, off }` | A Vehicle drop: its descent to the whole match as it drops (`blip` for the squad it is for); the blip moved, and taken off, to that squad alone; again to a squadmate on `br:ready` while it lasts. |
| `BR.Net.TERMINAL_PICK` | C→S | `{ terminalId, functionId, on }` | Airstrike (round 5): a map pick started (`on`) or ended on this client. An end is always taken; a start only inside the session on that terminal, for a `fuzz` row, from a player the door would let run it and who can afford it, one per `runMinIntervalMs`. |
| `BR.Net.TERMINAL_FUZZ` | S→C | `{ list = { { s, x, y, r } } }` | The rough circles while that pick lasts, every `fx.fuzzPingMs`, and an empty list as it ends (the pick, the session, `fx.fuzzMaxMs`, Season 2). Never a teammate or a squad under Ghost; nothing while the runner's squad has Scan running. |
| `BR.Net.TERMINAL_STRIKE` | S→C | `{ matchId, id, x, y, r, startsAt, endsAt, rockets = { { x, y, at } } }` | An Airstrike, to the whole match as its warning starts and on `br:ready` while it lasts: the circle, and every rocket's point and time (server clock). The client draws it and nothing more. |
| `BR.Net.TERMINAL_STRIKE_VEH` | S→C | `{ netId, frac, wreck? }` | A rocket's blast on a vehicle, to the one client the server says owns it: `frac` of `fx.strikeVehicleDamage` off its engine and body, or wrecked. |
| `BR.Net.SQUAD_POS` (`server/party.lua`) | S→C | the squad beacon's rows | Comms blackout: while one another squad ran is in force, every row sent to a blacked-out squad leaves `x` and `y` off, and nothing else (`BR.Terminal.beaconDark`). |
| `BR.Net.REVIVEKEY_ARRIVE`, `BR.Net.REVIVEKEY_PLACE` | S→C | `{ x, y, z }` / `{ cancelled }` | Reboot: the revive key's own return (`BR.ReviveKey.bringBackAt`), over the runner or the teammate picked (round 6). |
| `BR.Net.TERMINAL_RESULT` | S→C | `{ terminalId, functionId, ok, code, state?, runMs?, cost?, balance?, toast? }` | To the runner alone. `code` is `running` when a run is accepted (with `runMs`), `done` when it is over (a paid one with the new `balance`), else a reason (`no_volts` with `cost` and `balance`). Every answer but `running` carries `toast`, the line the server would toast for it; a client whose computer cannot show the answer toasts that. Once the server knows the computer has closed, the last word is its own toast instead. |
| `BR.Net.TERMINAL_CLOSE` | S→C | `{ why }` | The session is over (death, storm, teardown). |
| `BR.Net.TERMINAL_CLOSED` | C→S | `{ terminalId, why }` | The computer went away on the client; ends only the session it names. |
| `BR.Net.TERMINAL_DEV` | S→C | `'<text>'` | A `brterminalsv` answer, printed on F8. |
| `BR.Net.TERMINAL_USE` | C→S | `{ terminalId }` | "I pressed interact here." Opens a session only for a living player within reach by the server's own sample, in a PLAYING match, at an online terminal; offline is refused aloud. One per `runMinIntervalMs`. |
| `BR.Net.TERMINAL_SITES` | S→C | `{ placed, removed, forced }` | The dev tools' changes, whole, to everyone, and on `br:ready`. |
| `BR.Net.TERMINAL_REVEAL` | S→C | `{ x, y, r, matchId }` | Storm reveal, to the squad that ran it alone; again on `br:ready` while that match lasts, and again when Storm control moves the end. |
| `BR.Net.TERMINAL_SKY` | S→C | `{ matchId, weather? }` | Time & weather: the chosen weather (an engine weather's name, never RAIN or THUNDER), to the whole match when a run sets the time or the weather and when the match ends (no `weather`), and on `br:ready` while one is set. Each client claims it only while its view is inside the circle. |
| `BR.Net.TERMINAL_POWER` | S→C | `{ matchId, list = { { kind, x?, y?, r?, line? } } }` | Power outage: every live outage area, to the whole match when one starts or ends (an empty list: the lights back), and on `br:ready` while one lasts. |
| `BR.Net.YUBIKEY_STATE` | S→C | `{ held, first? }` | This player's key, to them alone, on every change and on `br:ready`; `first` on the push that gave them their first key ever (the first-pickup card). Round 7 took out `squadUsed` and `squadMatch`: the plate is one plate, so nothing read them. Squadmates learn who holds a key from the squad beacon's `yubikey` bit. |

## br_core and the computer

`exports.cuchi_computer`:

| Export | Does |
|---|---|
| `Open(state, copy, catalog, desktop) -> ok, why` | Boots the desktop (the player opens the app from its icon), takes NUI focus (keyboard and cursor). Refuses with `page-not-ready` before the page has loaded, rather than take focus over nothing. Opening another terminal while one is open closes the first (`replaced`). `catalog` is `{ functions, categories, currency, pageLoad }`, the registry and the browser's page-load range (`{ minMs, maxMs }`); `desktop` is `{ bootMinMs, bootMaxMs, clock = { h, m } }`. |
| `Update(state)` | The new state, while open on that terminal: after a run, and once a second (TERMINAL_INFO). |
| `Result(result) -> shown` | `{ functionId, ok, code, runMs?, cost?, balance?, toast? }`, while open; `false` when nothing is up to show it, and `br_core` toasts `toast` instead. |
| `Clock(h, m)` | The game's hour and minute for the taskbar: `br_core` reads the clock (never writes it) while the computer is open and sends it on each new minute. |
| `Close(why) -> ok` | Takes it down and releases focus. **The storm's close** (`why` `'offline'`, round 4) plays out first: the page shows its blue screen and power-off (about 2.1 s) and the focus is released -- and `cuchi_computer:closed` raised -- when the page says the screen is dark (NUI callback `off`), at the latest 4 s on (`SHUTDOWN_MAX_MS`), or at once if an `Open` or a resource stopping needs the computer first. Meanwhile it is no longer open: nothing is updated, run or shown on it, so an answer landing then is toasted. Every other why releases at once. |
| `IsOpen() -> boolean` | |
| `Hide() -> ok` | Round 4's map pick: the page out of sight -- the app and its box kept in it -- and NUI focus released, so the game has the keyboard and the big map the mouse. Still open. `false` when not open or already hidden. |
| `Show(picked) -> ok` | Back from the map: focus taken again, and the page handed `picked = { functionId, at?, place? }`, shape-checked (a spot two finite numbers, a place cut to 120 characters). `false` when not hidden. |

Local events it raises for `br_core`'s client (never net events):

| Event | Args | When |
|---|---|---|
| `cuchi_computer:opened` | `terminalId` | Focus taken |
| `cuchi_computer:request` | `terminalId, { action = 'run', functionId, options, at }` | The page asked; the terminal is the one `br_core` opened; `options` and the spot `at` shape-checked (refused while hidden) |
| `cuchi_computer:pick` | `terminalId, { functionId }` | "Set location" (round 4): the page asks for a spot on the big map (NUI callback `pick { functionId }`; refused while hidden) |
| `cuchi_computer:closed` | `terminalId, why` | Focus released: `escape`, `exit` (the power button), `page`, `replaced`, `opener-stopped`, `stopped`, or `br_core`'s own why |
| `cuchi_computer:missed` | `toast, ok` | The page handed back a run's last word the app never showed (NUI callback `missed { toast }`); passed on only for a toast this shell relayed, once. `br_core` toasts it |

**Focus.** The computer is its own resource's page, so it holds its own NUI
focus: FiveM keeps one vote per resource. Every way out releases it, including
`br_core` stopping (the shell watches the resource that opened it) and the shell
itself stopping. `br_core`'s client tells the key layer on `opened` and
`closed` (`BR.Keys.setExternalScreen`), so no key action fires under the
computer, and Escape is the computer's while it is up and for three frames after.

**The storm's close** (round 4, owner 2026-10-06: "If they're using it while
the storm moves and they're now outside the storm, the computer should show a
BSOD quickly followed by a CRT-style visual power off"). The server's session
check closes a session whose terminal the storm took with the one online rule's
word, `offline` (a Lockdown's is `locked`; going down, walking away and the rest
keep their own). The shell sends the page `{ type: 'br:close', storm: true }`
for that why alone. `br.js` shuts the computer at once -- the app unloaded, a
held last word handed back -- but keeps its page up for the screen: `#br-off`,
over everything, holding a Windows 10 style blue screen in the copy block's
`bsod_*` words, for `BSOD_MS` (1.5 s); then `.br-crt` collapses the picture to
a bright line, a dot and nothing over `CRT_MS` (0.6 s, br.css's `br-crt-off`,
run once); then the screen is REMOVED from the page, the page hidden, and the
shell told `off`, which releases the focus vote -- the keyboard goes back to
the game. An opening that arrives first drops the screen at once. **It plays
over the game** (round 5, owner 2026-10-06: "I'd like it to be transparent so
the player can get back to worrying about the storm"): `#br-off` has no color
of its own and `body.br-shutdown` takes the page's color away and hides the
desktop, so only the blue picture is opaque, and as it collapses the game
shows around it. **And it is waited out**: Escape, the power button and the
app's Escape do nothing while it plays (below).
A run already loading still lands by the door's contract: its last word reaches
a computer that is no longer open and is toasted.

## The page and the app

Inside the computer, `nui/br.js` and the app talk by `postMessage`, each
listening only to the other's window, every message carrying `brTerminal: 1`:

| Way | Message |
|---|---|
| app → desktop | `{ type: 'ready' }`, `{ type: 'run', functionId, options?, at? }`, `{ type: 'pick', functionId }` ("Set location", round 4), `{ type: 'escape' }`, `{ type: 'loading', on: true, ms }` / `{ type: 'loading', on: false }` (a page load started or ended: the tab's symbol) |
| desktop → app | `{ type: 'state', state, copy?, catalog? }` (copy and catalog on ready; an update is the state alone), `{ type: 'result', result }`, `{ type: 'picked', picked }` (what the map pick found: `{ functionId, at, place }`, round 4) |

**The boot** lasts a uniform pick in `bootMinMs..bootMaxMs` (7-10 s), new every
boot, and ends on the desktop; a second open while it is up is a refresh. A
generation counter keeps a closed session's boot timer out of a later one.
**The app is loaded when the player opens it** from its desktop icon, and
unloaded by its window's close and when the computer closes. The desktop posts
to the app only once the app has said `ready`; a run's last word that arrives
before then (its window closed, or still loading) is held and handed over on
`ready`, and one the app took while its window was minimized counts as unseen
until the window is shown again. If the computer closes first, either goes back
to the shell as `missed { toast }` for a toast. `ui-src/scripts/test-terminal-desktop.mjs`
drives every one of those paths through the real `br.js`.
Escape, on the desktop or inside the app, closes the computer -- unless a
dialog or an open dropdown in the app takes it first (the app reads it in the
capture phase). **Not during the boot, the blue screen or the power-off**
(owner, 2026-10-06, round 5: "the ESC key must not close the UI - they have to
wait it out. The same should be true for the starting up screen"; this
reverses round 2's Escape during the boot): while any of them plays, Escape,
the taskbar's power button and the app's forwarded Escape do nothing, and the
computer keeps the keyboard until it ends -- the boot on the desktop, the
storm's close with `off`. `br_core`'s own closes still close it at any time,
and the shell's 4 s backstop still lets go of a storm's close that never says
`off`. **The window** resizes from any edge or
corner (900x560 at least, kept inside the desktop) and maximizes to the
desktop -- its button, or a double-click on the title bar -- and back to its
old size and place. **The taskbar's clock** is the game's hour and minute, and
the date is hidden.

### A web browser, not a terminal (owner, 2026-10-05)

**The frame is the desktop's.** `cuchi_computer/nui/br.css` restyles upstream's
window title bar into a tab strip: one tab with the app's icon (the Control
Tower drawing, `nui/assets/images/terminal.svg`) and `window_title`, and drawn
minimize/maximize/close controls. The window is 1440x880 (BR-PATCH 5), capped
at 98vw x 92vh until it is resized. **The browser looks the same in both of the
site's modes** (owner, round 2): the frame and the app's toolbar have fixed
colors, and the light/dark switch changes only the site.

**The toolbar is the app's** (`Browser.tsx`): back, forward and reload over the
app's own history, and a read-only address bar whose fictional URL follows the
page (`https://controltower.blitz/home`, `.../tools/supply-drop` -- round 5,
was `/functions/` -- `.../privacy`). It lives in the app
because the history and the address are the app's navigation; a copy in the
desktop would be a second state kept in step over postMessage. Reload asks the
desktop for everything again (`ready`) and remounts the page.

### Pages load (owner, 2026-10-06)

"please make an artificial page load time when navigating in the web browser
between pages, except if they use the forward/back buttons. The time should be
random between 1 and 3 seconds, and the tab icon should change to a loading
symbol to indicate it's loading."

- **A navigation loads** for a fresh uniform pick in `pageMinMs..pageMaxMs`
  (1-3 s, `br_lib/config/terminals.lua`, handed over in the catalog): the side
  navigation, a card or its title, a breadcrumb, the user menu's How to, the
  top bar's name, a search result, and the reload button. A link to the page
  already on screen is not a navigation.
- **The page on screen stays while it loads, address and all.** The address
  bar changes with the page when it shows -- a browser keeps the page you
  clicked on until the next one arrives -- and the history moves then too.
- **A new navigation replaces** the load under way, with its own pick.
- **Back and forward are instant**, and drop a load under way: its page never
  shows.
- **Not navigations, never a load:** typing in the cards' filter (the page's
  own entry is rewritten in place, as before), the cards' pagination and
  preferences (state inside the page, with no address of their own), Match
  stats, the light/dark switch, and Run with its 3-5 s bar.
- **The tab** (the desktop's, outside the app) shows a turning ring in place of
  the app's icon for exactly the length of the load: the app posts `loading`
  on and off, and `br.js` puts `.br-loading` on the tab. `br.css` animates the
  ring only under that class, so the animation is removed with it, not paused
  (#385: a running animation repaints the NUI every frame). `br.js` takes it
  off when the page shows, when the app's window or the computer closes, and
  by a backstop at the load's length plus a second (15 s at most). No
  Cloudscape Spinner.
- **The first page loads too** (round 4, owner 2026-10-06: "The initial page
  load should also take time, and be shown as a white page during that time
  while the tab shows the loading icon"). The app opened from its desktop icon
  is a fresh document: the tab wears its symbol from the click (the app's own
  bundle loading included, so its backstop is the 15 s cap), and the app shows
  the browser's toolbar -- with the address it is loading -- over a blank white
  page (`.terminal-blank`, white in both of the site's modes, like the
  toolbar). When the catalog arrives, the app picks a fresh length in
  `pageMinMs..pageMaxMs` and tells the tab; when it has passed, the first page
  shows and the tab is itself again. Nothing navigates meanwhile (back and
  forward have nowhere to go; reload waits). `model.ts` `startOpening`,
  `openingStarts`, `openingEnds`.

`model.ts` holds the rules (`navigate`, `arrive`, `step`, `rewrite`,
`loadMs`), tested in `test-terminal-model.mjs`; the tab's class on every way in
and out is `test-terminal-desktop.mjs`'s; `check-terminal.mjs` T10 holds the
wiring and the stylesheet.

**The site** (Cloudscape, like the cards and details examples): a fixed
TopNavigation with the app's name -- the one place in the app it is written --
a search across every tool (pick one to open it, or search the cards), the
player's Volts, the light/dark switch, and the gamertag as the signed-in user
(its menu: How to, Sign out); AppLayout with SideNavigation (Home, How to,
Privacy, each category with something in it; no header) and a BreadcrumbGroup
on every page but the login screen; Home, the tools page ("Match stats",
collapsed, over the cards, with the five filters, pagination and preferences;
"Home" in its address, its link and the trail's first crumb, owner 2026-10-06,
while its heading counts the Tools), a page per tool (its trail
Home, its category, its name; details with its cost, what it does -- which
names its options -- its risks, and Run in its risk badge's color, which opens
the **confirm box**, `RunBox.tsx`: round 6, owner 2026-10-07, "We need to move
all required options/inputs to be part of the "confirm" modal": the run's
price for the choices made in it, every option offered under them (radio
buttons, or a dropdown -- Gear Up's items rarest first, each with its rarity's
name on the right in the game's rarity color and a tint of it on the
highlighted row, through Select's `renderOption`; the standing teammates), the
spot for a run at one, and Run disabled until every choice is made), the how-to page, the Privacy page (the owner's approved
made-up policy, "sponsored by Lifeinvader", in one container), and the login
screen (the lock and `no_key`) when the computer opened without
a key. A run the server accepts shows a determinate bar filling over its
`runMs`, then the server's answer; a state saying nothing is loading takes the
bar down (an answer that went to a toast never leaves one behind). Shadows give
the surfaces depth in both modes -- the top and side navigation, the
containers, the cards and their heading block, the confirmation box and the
flashes -- and the app gives nothing on them one: no button (the pagination,
the preferences gear, Run), badge, progress bar or input, and no text anywhere
(owner, 2026-10-06: "If they don't have shadows on the text we shouldn't
either"; Cloudscape's own demos have none). Where Cloudscape shades a control
itself -- the knob of each toggle in the preferences is the one a player sees
-- `terminal.css` takes it off; a dropdown, which floats (the search's, the
user menu), keeps Cloudscape's own. `terminal.css`
draws the shadows in one rule over the surfaces and takes Cloudscape's off its
controls in one more, and `check-terminal.mjs` T11 holds both, reading every
shade in the built CSS. The mode is
applied on `<body>` only,
light by default, and remembered per gamertag in the page's localStorage
(`control-tower-mode:`). The header is fixed rather than sticky: focus moving
into a sticky box scrolled the page to its top. `ui-src/scripts/check-terminal.mjs`
holds #385's findings over it, and that every line goes through the speaker.

### Round 4 (owner, 2026-10-06)

- **The cards show their cost and their bounty** ("The cards should show cost
  in volts and bounty"): Cost is the function's Volts, or `cost_free`; Bounty
  is its row's `bounty` in words. The preferences' Card content lists both.
- **Home's filters** ("the "Functions" search should have filters available
  for category, risk, Volts cost (free/paid), bounty, and availability
  status"): five Selects, each labeled inside its own trigger and "Any" until
  set (round 5 took the text search beside them away -- the top bar's is the
  one). The category is the page's own (the side navigation's); the other four
  ride in the route. All of them and the top bar's search text, when a search
  brought the player here, narrow the cards together, pagination runs over what is left, and
  the heading counts what is left of what there is ("(4/18)") while anything
  but the category narrows them. A change rewrites the page's own history
  entry, as typing does -- no load, no new entry -- and the address carries
  them (`/home?category=intel&risk=high&cost=paid&bounty=runner&status=available&q=scan`).
  "Clear filter" on an empty page clears them all. `model.ts` "the filters".
- **Every mention of Volts in the Volts style** ("Any mention of volts must
  use our proper font for that and the gold color"; round 5: "back to the
  standard font for the browser instead of our volts font"): the Volts gold,
  `#d9ae35` (`--color-volts`), the same in both modes, in the page's own font
  -- the text around it, Open Sans at its weight. The rule sets the color and
  nothing else, and the app bundles no face (round 4's Anton and its license
  are gone from the build). `Volts.tsx` draws every Volts amount
  and every mention of the word: a card's cost, a page's cost line, the
  confirmation, a run's answer (the new balance; `no_volts`'s word, cost and
  balance) and the privacy policy's "your Volts balance" (the style only, not
  a word of it). The top bar's balance is a TopNavigation utility's string, so
  the bar is marked `terminal-topnav-volts` while the balance is its first
  utility and `terminal.css` dresses that one the same way.
  `check-terminal.mjs` T12 holds it: a Volts token filled as text, a copy
  line that says Volts read without the style (or read only where T12 cannot
  see, such as an option's label), a copy line its reader cannot read (one
  not written `key = '...',`), and a color that is not the Volts gold, a
  font of its own, or a face bundled for it all fail; and outside `model.ts` and `Volts.tsx` the currency's
  word and a Volts figure (`.cost`, `.volts`, `.balance`) may be read only
  where its closed list allows -- handed to `VoltsAmount`, `voltsLine(s)` or
  `voltsText`, passed down as `currency={currency}`, compared with 0 or null,
  or parsed by `bridge.ts` -- so `${f.cost} ${currency}`, `{f.cost}` or a
  formatted figure beside the word fails the build (the review of round 4
  found both of the first two passing it).
- **"Squads!"** (the owner's words, verbatim): on a `squadWide` function, in a
  squad match only, a blue dotted "Squads!" after the card's title and the
  function page's -- a Cloudscape popover's text trigger, as in the AWS
  console screenshot he sent -- whose box reads "This function will apply to
  your entire squad." Clicking it opens the box and nothing else (not the
  card). Outside a squad match it is not drawn, and its lines' empty `_solo`
  siblings say nothing even if it were. `check-terminal.mjs` T13 holds the
  gate (`model.ts` `showsSquads`).
- **The font weight** (the owner asked whether ours differs from Cloudscape's
  public demos): it does not -- both are Open Sans, 400 for the body and 700
  for headings and labels, at 14 px; the cards' titles are 20 px at the
  owner's own request (round 2).

### Round 5 (owner, 2026-10-06)

- **A new wallpaper**: "Please use this graphic as the new wallpaper for the
  computers." His daytime Vinewood screenshot, 2000x1125
  (`nui/assets/images/wallpaper.webp`; VENDOR.json has its size and sha256).
- **"Functions" is "Tools"** ('Rename the "Functions" to "Tools"'): every line
  the player reads says tool -- the cards' heading (`tools_heading`), the top
  bar's search and its empty row, the cards-per-page choice, the empty filter
  line, `fn_offline`, `unavailable`, the how-to -- and a tool's page is under
  `/tools/<id>` (`path_tools`). The owner's VERBATIM lines stay as he wrote
  them ("This function will apply to your entire squad."). The registry and
  the code still say function. `test_terminal.lua` fails any other copy line
  that says function.
- **No text search on Home** ("please remove the search bar within the
  Functions (soon to be "Tools") section - we have a search at the top anyway.
  Just the filters can remain."): the five filters stay; the top bar's search
  still opens a tool, or narrows the cards to what was typed.
  `check-terminal.mjs` T14 holds it.
- **Volts in the page's font, in the gold** (above, "Every mention of Volts").
- **The storm's close plays over the game, and is waited out** (["The
  storm's close"](#br_core-and-the-computer)), and so is the boot: Escape, the
  power button and the app's Escape do nothing until each ends.

### Round 7 (owner, 2026-10-07)

- **A status wraps between its words** ("can you wrap this text better?" --
  a card's Status read "No armed opponent" and then "s"): Cloudscape's
  StatusIndicator breaks at any letter (`word-break: break-all`), and
  terminal.css takes that off for every status the app shows -- the cards',
  a tool's page's, the match panel's -- with the lines beside the icon. A
  word is cut only when it is wider than its whole column (a long gamertag);
  no `status_` line's is, at the window's smallest and at its default size.
  `check-terminal.mjs` T15 holds it.
- **The cost in bold** ("Please bold the cost text inside the cards and
  details page."): a card's Cost, a tool's page's Cost line and, for the
  same reading, the Volts a run costs in the confirm box (the amount, not the
  sentence) -- in their own color, the Volts still gold. T16.

## The Yubikey

The owner's rules (#396, 2026-10-04), and where each lives:

- **Owned, one per player, no slot.** On the profile row, read by the connect
  read `server/market.lua` already makes, written through `br:ddb:yubikeySet`,
  whose condition is the cap of one. The session cache is what the game reads; a
  failed write is a console line, never a refusal.
- **A key on the ground is ordinary loot**, kind `yubikey`, drawn by
  `client/loot.lua` and claimed through `server/loot.lua`'s LOOT_CLAIM like a
  Volts pile. A holder's claim is refused (`already_holding`) and the key stays.
- **The first key ever** shows the **first-pickup card** once (`yubikeySeen`),
  round 5 (owner: "the tutorial-style card which tells them how to use it and
  requires manual dismissal using the return key"). `BR.Yubikey.give` pushes
  YUBIKEY_STATE with `first = true` -- a real pickup or `bryubikey give` -- and
  `client/yubikey.lua` sends br_ui `BR.Nui.YUBIKEY_CARD { show, title,
  subtitle, text, dismiss }` with the owner's words (`first_pickup_title`,
  `first_pickup_subtitle`, `first_pickup`, `first_pickup_dismiss`). br_ui draws
  them on the tutorial's card (`tutorial/YubikeyCard.tsx`: `tut-card`; round 6,
  owner 2026-10-07: his first sentence an `<h1>`, his second an `<h3>`, the
  body through `emphasize`, and the Enter key cap with "to dismiss" beside it;
  no count, no button) in the lower quarter of the screen as the walkthrough's
  `place: 'quarter'` cards are -- `cardPlacement.ts`'s `centred` at
  `BAND.quarter`, from its measured box -- over the match only -- not over the lobby, a
  paused HUD or the verdict, where it waits for the next match. **Only Enter
  takes it down**, read in Lua as a control (INPUT_FRONTEND_RDOWN 191,
  INPUT_FRONTEND_ACCEPT 201 and INPUT_FRONTEND_ENDSCREEN_ACCEPT 215, disabled
  for the frame and read disabled), counted only when the keyboard made the
  press (`isTrue(IsUsingKeyboard(0))` on that frame: all three are a gamepad's
  A as well, and A on foot is sprint, so a controller player running off would
  otherwise dismiss it unread -- the round 5 review; they press the keyboard's
  Enter), and only while no br_ui screen, in-game menu or computer holds the
  keyboard and GTA's pause menu is down; no timer, nothing else. It takes no
  focus and no other control, so the player moves and shoots as ever. A
  terminal's computer hides it while it is up; br_ui restarting gets it
  again. No toast says it.
- **On screen**: the owner's image of the key (round 5: br_ui's
  `items/yubikey.png`, his render of the blitz_seckey prop) by the inventory
  slots, 3rem square -- 25% over the 2.4rem plate it replaced -- with no
  plate behind it, while the HUD envelope's `yubikey` (the glyph) says one is
  held; the squad panel's mark (the glyph) beside every squadmate who holds
  one (several can).
- **Carried into the next match** unused: the row still says so. Only a use
  and a death take one (round 6, owner 2026-10-07: "the ownership of an unused
  Yubikey doesn't actually persist between matches as it should"):
  - a holder who **leaves mid-fight** -- walking out (Leave Match, `brleave`,
    the way a dev box's match is left) or disconnecting -- keeps it while
    `leaveDrops` is false, the default since round 6 (it was true, dropping
    it like a death, while the owner had not ruled);
  - **but not a holder who leaves DOWNED** (round 6's review): DBNO, the fight
    is already lost, so Leave Match, a disconnect, a crash or a console kick
    there drops the key where they lay, as the death it is heading for would,
    whatever `leaveDrops` says. Only a holder standing or in the air (the
    bus, freefall, the chute) keeps it. Both ways out ask before the state
    changes (`keepsOnLeaving` in `server/yubikey.lua`);
  - **nothing takes a key once its match is decided**: the winners are ALIVE
    through the verdict until the sweep sends them home, so a walk-out, a
    disconnect or a late death report there used to drop the key into loot
    CLEANUP was about to clear. From ENDED on, the holder keeps it, whatever
    `leaveDrops` says;
  - **a failed profile read keeps what the session knows**: br_ddb answers a
    read it could not make with the empty inventory, which reads as "no key",
    so a reconnect through one lost the key for the session. The market hands
    the read's `extra` over, and a failed read keeps the account's entry.
- **Dropped where its holder dies**, on the death box's edge
  (`server/combat.lua`), in a match still being fought (the bus or PLAYING),
  and where a holder leaves mid-fight downed, or at all while `leaveDrops` is
  true.
- **Sources**: an EXTRA item rolled as a container opens, on its own stream, so
  the box's own contents do not move -- `airdropChance` (0.5) per airdrop and
  `crateChance` per crate, any tier (round 5, owner 2026-10-06: "We should
  have the same chance of yubikeys in crates as something rare", "let's make
  the Yubikey rare then, not legendary"). Never on the warmup pad, never a
  death box. `crateChance` is the chance an average RARE item is in a crate:
  each item a crate rolls at rare (twelve on 2026-10-06), its share of crates
  holding one, weighted by the match's crates per tier, averaged -- 3.08%,
  so 0.031. `tools/test_yubikey.lua` measures it with the real loot generator
  on every run and fails a config more than a tenth away, so a loot change
  that moves the rare items says so. The roll happens as the crate opens,
  after its rarity was decided from its contents, so a crate with a key looks
  exactly like one without; the key's own glow shows only in the burst. About
  78 keys a match at the 2,512 crates a match lays out, if every crate is
  opened.
- **Rare on the ground**: blue, its label rare, like any rare item -- "the
  Yubikey ground glow should be blue for rare like anything else" (owner,
  2026-10-07). It was legendary, gold. `Y.stack` is the one place a key is
  made, so a dropped key, a burst one and a dev drop all read rare.

## Terminals in the world

**The laptops are the owner's** (2026-10-06): `prop_laptop_01a` placed by
his ymap, `stream/LaptopTerminals.ymap` in the Season 2 drop
(`br_stream_s2`). Nothing in this repository spawns one. `sites` in
`br_lib/config/terminals.lua` holds where they stand, in his order and at his
numbers except Paleto PD and Calafia Way, whose rows were moved the 1.7 m onto
their laptops as his ymap stands them (his numbers are in each row's comment)
-- Mount Gordo, the top of Chiliad, Fort Zancudo, Paleto PD, Calafia
Way, the vineyard, Rebel Radio, Panorama Drive, the towers by the Vinewood
sign, the Vinewood Bowl, the Hillcrest Ridge access road, the lot south of the
college, La Mesa PD (his "chumash? PD"), the factory by the heliport and the
Vespucci canals -- and every terminal check reads those rows, never a prop.
`tools/check_boundary.lua` holds them inside the surveyed play area. `brterminal
place` stays as a dev aid for a future site: a plate and a blip for the
session, no laptop, and the row to paste.

A terminal is **online only inside the storm's current zone**, by its real
shape; before there is a storm everything is inside it.

**ONE ONLINE RULE, BOTH SIDES**: `BR.TerminalSolve.offlineWhy(site, zone,
forced)` answers `'offline'` (outside the storm, unless forced online), else
nil. The server reads it through `BR.Terminal.offlineWhy` (and `T.online`, its
boolean) for every use, every run, every session check, the panel's count and
`brterminal list`; every client reads it in `client/yubikey.lua`.

- **Season 1 hides the laptops.** `br_stream_s2` is installed from Season 2
  on (`assets.lock`), so a box started at Season 1 has no laptops at all (and
  a live `brseason 2` there gives plates and blips with none: playtest on a
  box started at Season 2). A running server cannot swap a streamed asset, so
  after a live `brseason 1` on a box started at Season 2 the ymap's laptops
  still stream, and a client where `BR.Season.has('terminals')` is false
  hides `terminalProp`
  within `hideRadiusM` (2 m) of every config row with
  `CreateModelHideExcludingScriptObjects(x, y, z, radius, model, true)` -- map
  objects only, and surviving a map reload, so a laptop that streams in later
  arrives hidden -- and `RemoveModelHide(..., false)` brings each back at once
  when the season turns terminals on. On start, on every move of the client's
  season (`BR.Season.onChange`, with the SLOW pass catching a move it did not
  announce), and taken down when br_core stops; never per frame. The dev
  tool's changes do not touch the hides.
- **Its blip** shows only while this player holds a key, only for an online
  terminal, and only in a match -- from its warmup on (round 5, owner
  2026-10-06: "it's okay to show the computer system blips while in warmup as
  long as the player has possession of a Yubikey"; it was from the bus on).
  Before the storm exists (warmup and the bus) every terminal is online and
  has its blip; from PLAYING only those inside the storm do. **One blip per
  terminal, a fuel station's kind** (round 5: "change the computers
  SetBlipDisplay to the same type as fuel stations - reason being, the blips
  are currently pinned on the minimap and are always there"): the art block's
  sprite 521, color 51 and scale, the default display and
  `SetBlipAsShortRange(true)` exactly as `client/fuel.lua` makes a station's --
  on the big map always, on the minimap only nearby. It was a display-3 and
  display-5 pair, not short-range.
- **Its plate** (the shared prompt browser) is ONE PLATE: `terminal_label`
  ("Computer system") over `terminal_use` ("press to open") with the player's
  interact key, **whatever the player's status** -- a key or none (round 6,
  owner 2026-10-07: "if I approach a computer with no Yubikey, the DUI should
  show the same as if I do have one. The player will realize what's up when
  they go to open the app."), the squad's use spent or not, a run in flight
  (round 7, the same day: 'The DUI reading "you already used your terminal
  this match" should be the same DUI text as the rest, not unique to that
  status.'). A press opens the computer, whose app says what stands in the
  way (`no_key`, `squad_used`, ...);
- **At the laptop** (round 6: "please lower the DUIs to the elevation of the
  laptops"): every site's row is its laptop's origin, and the plate is drawn
  `art.plateLiftM` (0.15 m) over it, about the middle of an open laptop's
  screen -- it was 0.9 m. One number, for every site;
- **Outside the storm it has no plate at all, for anyone** (round 4, owner
  2026-10-06: "A terminal outside the storm should have no blip and no DUI -
  hence it's unusable"): nothing is sent to the prompt browser, nothing is
  drawn, the loot prompt keeps the floor, and there is nothing to press. A
  terminal the SLOW pass has not placed yet counts as outside. The server
  still refuses a use there, aloud (`offline`), for a client a step behind
  the storm.
- **A press of interact** sends TERMINAL_USE (it was an 800 ms hold until
  round 3), no sooner than `runMinIntervalMs` after the last; the server's
  door is unchanged and drops one sooner itself.

## The rules, server-side

1. **A use** opens a session only for a living player within reach, by the
   server's own sample, in a PLAYING match, at an online terminal.
2. **Access** is a key and a squad that has not spent its use. The lobby (the
   whole match) hears `notice_access` once per player per match.
3. **A run** is refused, in this order, `offline`,
   `squad_used`, `no_key`, a run in flight, the function's own reason, then
   `no_volts`.
4. **When it is accepted**: its Volts, then the key and the squad's ONE use
   this match (a solo player is a squad of one) are spent, and the squad is
   told its use is gone; the squad's other holders are refused `squad_used`
   and keep their keys. **When it is done**, 3-5 s later, the lobby hears
   `notice_action` -- or, if it could not happen, everything comes back.
5. **Every fact is read from the world on every ask.** A session closes when its
   player goes down, dies, leaves, walks away or the storm takes the
   terminal: on a 500 ms check, and again inside every run.

## The map pick (round 4)

Owner, 2026-10-06: "Storm control: we should let them actually pick exactly
where they want it. When they click confirm, we should open the big map for
them, wait for them to pick a location, then when they close the big map we run
it. This could be a multi-step flow on the popup box like where the confirm
button is greyed out until they select a "set location" button", and "The supply <!-- spelling-ok: the owner's own words -->
drop should also allow them to pick exactly where."

A registry row with **`spot = true`** (Storm control, Supply drop, and round
5's Airstrike) is run at a
place picked on the big map. Its run request carries it as **`at = { x, y }`**,
and `BR.Terminal.spot` takes only that shape -- two finite numbers within 20 km
of the map's middle -- for such a row, and none for any other: anything else is
`bad_option`, nothing spent. The function reads it as `opts.at` (no registry
option is called `at`) and decides what it means (Storm control: the storm
closes toward it, round 5; Supply drop: the airdrop spot nearest it). `brterminal run
<id> x=<n> y=<n>` is the same spot from the console.

**The confirm box asks for the spot** for such a run (the app's `RunBox`,
round 6: after the run's options, which live in the box too): **"Set
location"** (`confirm_location`, the owner's words, with Cloudscape's
`location-pin` icon since round 6) with Run disabled -- and, for a row whose
`spot` has a `when`, only while the choices made hold it. Pressed, it goes down as `pick` (app → `br.js` → the shell's
`pick` callback → `cuchi_computer:pick`), and `br_core`'s client
(`client/terminal.lua`):

1. **hides the computer** (`Hide`: the page out of sight with the app and the
   box still in it, NUI focus released) and lets the key layer go;
2. clears the player's own waypoint, if any, and notes the sprite-8 blips
   already on the map (squad pings wear the waypoint's sprite);
3. **opens the big map** -- br_ui's own, the map key's (`br:ui:mapToggle`, the
   pause menu's frontend map) -- and waits on the TICK pass the taskbar clock
   already runs: for br_ui's `BR.Native.frontendMap` to rise (5 s at most,
   br_ui's own raise deadline), then to fall, which it does when the
   frontend is down by any way out (Escape, the map key, right-click);
4. **reads the waypoint** set meanwhile (the first sprite-8 blip not noted
   before and not a squad ping `client/markers.lua` drew meanwhile,
   `BR.Markers.isOwn`), takes it off the map -- `client/markers.lua` stands
   down while `BR.Terminal.picking()`, so it is never a squad ping -- names the place
   with the game's own natives (`GetStreetNameAtCoord`, `GetNameOfZone` and
   `GetLabelText`: "Elgin Ave, Downtown"), and **shows the computer again**
   (`Show`) with `{ functionId, at, place }`.

The box then shows the place beside "Set location" (its map coordinates in
digits where the game has no name) and enables Run; pressing "Set location"
again picks again, and a map closed with no waypoint puts the box back to its
first step. The run carries the spot (`at`). The server hears only that a pick
started and ended (round 5: `TERMINAL_PICK`, `on` as the computer hides and not
as it is shown again), which means something only for a `fuzz` row -- Airstrike's
rough circles. A session the server ends meanwhile (the player downed, the
storm) closes the hidden computer like any other -- the storm's close too,
at once and with no blue screen, since nobody could see it under the map; the
map is the player's to close, and the waypoint is still taken off it then.
Back on screen, `br.js` gives the app's frame the keyboard again (so Escape
closes the box, not the computer), and the key layer is claimed only once
`Show` says the computer is up. No instruction is written
on the map: the frontend's own buttons say how to set a waypoint. Nothing runs
per frame: one nil test on the TICK pass while there is no pick.

## Storm reveal

`BR.Storm.finalCentre(m)` walks the phases the storm has not drawn yet, against a
copy of the match's storm stream, so asking never moves the real one;
`tools/test_storm.lua`'s `server.final` holds it exact at every phase. The answer
goes to the squad that ran it and nobody else (`TERMINAL_REVEAL`). It is drawn
as a radius blip and a sprite on both maps until the trip back to the lobby. With
nothing to reveal (no storm stream yet) the function is `unavailable` and spends
nothing. A dev `brphase` or `brstormfreeze` after a reveal ends the storm
somewhere else.

## The storm, the sky, the clock and the lights (wave B)

Three functions change the world everybody in the match stands in (#396,
2026-10-06); a fourth, Storm delay, was removed by the owner the same day
("We have to keep the pace of the match"). Each is built to its own page in `copy`, and where a line could
not be true it was changed (the report of wave B lists every one).

**Storm control** (`storm_control.lua`, 150 Volts, run at a spot -- round 4,
owner 2026-10-06: "we should let them actually pick exactly where they want
it"; round 5, the same day, on round 4's refusal of a spot outside the next
circle: "this limitation should not exist. the next phases should instead work
towards the location the player selected"). The run carries the spot set on
the big map (`at`, see [the map pick](#the-map-pick-round-4)), and **no spot is
refused**: every circle the storm draws from now on closes toward it, and the
last ends on it when the storm can get there and as near it as it can
otherwise. `BR.Storm.aim` plans the rest of the match once
(`BR.StormAimPlan`, `br_lib/shared/storm_solve.lua`) and keeps the plan as
`m.stormAim`; from the next circle `enterPhase` draws, `drawCentre` reads each
center off it. The plan holds the planner's own rules less its dice, for every
circle: every zone nested in the one before by its real shape (#344,
`NEST_CLEAR`), its exact bounding box inside the map bounds wherever the planner
would ask it, and its center on the map -- the end's and every circle's between
them alike (round 5's review found circles between centered in the Alamo Sea);
no aimed phase breaks out or hugs the edge, and the city share (#381) is circle
1's anchor's, drawn before any Storm control, so it never applies here.

- **The land, in convex pieces.** On the map (`BR.StormOffMap`) is inside the
  surveyed boundary and off every water rectangle -- not convex, so it is cut
  once into convex pieces (`BR.StormLand`): the boundary ear-clipped into
  triangles, flipped to the constrained Delaunay triangulation so no fan of
  slivers meets at one corner, merged back into convex pieces wherever two make
  one (Hertel-Mehlhorn), and every piece a water rectangle reaches into split
  into its parts beside it. That is 30 pieces, kept a millimeter clear of the
  water and of the coastline wherever a piece runs along it.
- **The spot, on land.** A spot over water or off the surveyed map is aimed as
  the nearest point to it on the map: the nearest point of the nearest piece,
  exactly -- the shore it was picked beside.
- **The end.** Each phase may place its zone at offsets from the center before
  that form a convex room (the zone before, cut to chords and eroded by the next
  zone's exact support). Along a route -- which convex set of land each phase's
  center stands in -- the centers each phase can reach are convex, the last
  phase's plus its room cut to the land, and so are the ends. A best-first
  search over the routes finds the one whose ends come nearest the spot: no
  route ends nearer it than the land inside its centers plus the rooms still to
  come, so once none left can beat the best end found, nothing the rules allow
  can. The storm ends on the spot when a chain of circles with every center on
  land can get there, and otherwise on the nearest point to it such a chain can
  reach. It is never outside the next circle on the map, which every later
  circle is inside.
- **Toward, phase by phase.** Each circle's center is the one nearest the spot
  among the centers on land its rules allow from the circle before **and** from
  which the storm can still end there over land (the backward reach on land, a
  union of convex sets), so the walk closes on the spot as fast as the rules
  permit. A circle moves away from the spot only where the bounds or the land
  leave no nearer center that still ends there.

The walk is tried to the exact end first. Where the end sits on the very edge
of what the storm can reach -- one chain reaches it, and that walk does not pass
the planner's tests -- the end is held two centimeters in (the reach drawn in by
two centimeters, or the nearest point pulled two centimeters toward the reach's
middle, whichever is nearer the spot), and twenty centimeters or two meters
where a walk needs more; a spot inside the reach is ended on exactly unless it
is within those two centimeters of its edge. Every center is checked against
the real `BR.StormShape.fit`, the bounds and the land before the plan is kept.
Storm reveal walks the same `drawCentre`, so it answers the end, and a squad
that ran it is sent the new end. **A circle on the map never moves** (round
6, owner 2026-10-07: "Running the storm location selection before the first
sweep moves the first sweep to that location. That shouldn't happen."): the
phase the storm is in, entered again from where its wall stands -- a thaw
(`brstormfreeze off`), `brphase` to the same phase -- keeps the circle every
player was looking at, the one on the map when the storm was aimed or the one
the aim's walk drew, and the walk carries on from it. (That re-entry planned
again from the wall, which put circle 1 straight onto the spot before the
first sweep.) A `brphase` jump to another phase plans again from the wall
toward the same spot. Nothing else moves: the record on the map and the
circle already drawn stay, and the change reaches every client, the map's morph (#350) and the
airdrop's re-site (#386) as any record does. **One spot a match** (round 4's
review): once the storm is aimed, every later Storm control in that match is
refused `storm_aimed` (`BR.Storm.aimed`) -- on its card, at the run and after
the load, so of two loading at once the second to land gives everything back --
and its page says so ("Only one spot can be picked each match"). Refused too:
`no_storm`, and `no_circle` once the final circle is on the map -- and nothing
about the spot itself: the only shape the door refuses is the one the big map
cannot produce (`bad_option`, see the map pick). A plan costs about 16 ms of the
server's Lua (28 ms at the 99th percentile and 40 ms at the most, over 4,000
plans by the coast and the Alamo Sea), once per Storm control; the search
opens at most 256 routes (the most any plan opened was 126) and the walk weighs
at most 64 sets of centers a phase (the most was 24), which bound it. Building
the land's pieces costs about 2 ms, once. `tools/test_storm.lua`'s `control.*`
blocks hold it: a brute-force search over the land on the end of 343 plans,
brute-force searches of every circle toward the spot, 84 spots walked through
the real phase job, the bounds from circles that overhang them, the land's
pieces against `BR.StormOffMap`, and round 5's review's cases by the Alamo Sea.

**Time & weather** (`time_weather.lua`, both sides; options `change`, then
`time` or `weather`). Round 4 (owner, 2026-10-06): "either time or weather to
be set. Not both. Weather should be any weather the game engine allows, except
rain and thunder since those are reserved for the storm only. The duration
should be the remainder of the match".

- **One or the other.** `change` is `time` or `weather`, and the registry
  offers the matching option only under it (`when = { change = ... }`):
  `BR.Terminal.options` drops the other and refuses a run that chose both
  (`bad_option`), and the app shows only the one offered (model.ts
  `shownOptions`, `runChoices`). A run changes that one and keeps the other as
  an earlier run left it; `m.terminalSky` holds `base`, `anchor` and `time` (a
  time run's) and `weather` (a weather run's) -- `time` is what Power outage
  asks.

- **The time** is the match clock's anchor (#394). The run gives the match a
  new anchor -- the chosen hour from `fx.skyTime` (day 12:00, dusk 19:30,
  night 00:00), running from now at the match's own rate -- which the digest,
  the state events, the snapshot and a spectator's pushes already carry; the
  one clock writer (`BR.Native.applyClock`) writes once when it arrives and
  once when the match's own anchor comes back at the end, so the clock returns
  to where the match's own time has run to. No client writes the clock for it.
  A weather needs no clock, so only a time run is refused (`unavailable`) in a
  match with none.
- **The weather** is a sky claim, `terminal`, ranked below `storm` and above
  `island` (`br_lib/shared/world.lua`'s `SKY_SOURCES`), claimed only while the
  client's view is inside the circle (`BR.Storm.viewInside`, kept by the
  storm's own tick; the shot for a spectator). Caught outside is THUNDER
  whatever was chosen; outside the circle and not caught (phase 1's free-loot
  hold) the storm's own sky stands. **A role yields to a weather claimed below
  it**: the storm's all-clear is the `base` role, held for the rest of a match
  once the storm has caught the player, and the chosen weather is drawn over
  it. Claiming a weather hands the rain knob back, as the console's does.
- **The weathers** are the engine's own, by name (`fx.skyWeather`): ten of the
  fifteen -- EXTRASUNNY, CLEAR, CLOUDS, SMOG, OVERCAST, FOGGY, XMAS, SNOWLIGHT,
  SNOW and BLIZZARD. Not RAIN or THUNDER (the owner's: the storm's), and not
  the three more that rain: CLEARING (the engine's weather 8, "Light rain" in
  alt:V's weather reference and in admin tools that set weather by index) and
  NEUTRAL (weather 9, "Smoggy light rain" in the same places), and HALLOWEEN
  (rain is what the Cfx.re "Permanent Halloween" thread asks how to stop). The
  server refuses RAIN and THUNDER whatever the table says, and a client claims
  neither. The festive months change nothing here: "clear" is CLEAR, and the
  ground follows the resolved weather as #399 shipped -- white under XMAS,
  SNOWLIGHT, SNOW and BLIZZARD, bare under the rest.
- **It lasts the rest of the match, or until another run changes it.**
  Another squad's run of the same kind replaces it (a time run the time, a
  weather run the weather), and every line that says how long it lasts says
  so -- the card, the page, the duration and the done line (round 4's
  review). It ends when the match stops PLAYING
  (the end screen included) or off Season 2, on a 1 s pass
  (`fx.worldCheckMs`): the match's own clock back (only if a time run moved
  it), the weather released on every client. A client lets go in the lobby
  too.

**Power outage** (`power_outage.lua`, both sides; options `area`,
`duration`): the engine's blackout (`SET_ARTIFICIAL_LIGHTS_STATE`) is one
switch per client for the whole map, so a client whose view is inside a live
outage area turns its own lights off -- vehicles left out of it
(`_SET_ARTIFICIAL_LIGHTS_STATE_AFFECTS_VEHICLES(false)`), so headlights work --
and one outside keeps its lights. **spot** is `fx.outageRadiusM` (1000 m, the
page's 1 km) around a spot picked on the map in the confirm box, the run's
`opts.at` (round 6: "Any use of 'near this terminal' is like, not useful for
this gamemode" -- it was **here**, around this terminal; a `spot` run with no
spot is `bad_option`); **city** is below the storm's city line
and **county** on or above it (`BR.StormCityLine`, the #381 line the anchor's
draw reads). `BR.TerminalSolve.outageArea` / `inOutage` are the one spelling
both sides use. Several can run at once. The lights are written on a change
only, and put back at the end, in the lobby, off Season 2 and when `br_core`
stops; `tools/verify.sh` allows the two natives (by name and by hash) in
`client/terminalfx/power_outage.lua` alone. vMenu's weather sync writes the
blackout every second while it is on, which is why `server.cfg.example` keeps
it off.

**Only on a terminal's night** (round 4, owner 2026-10-06: "The power outage
tool should only work if someone else has set it to night time first"). A
match runs from noon at the slow clock's rate -- about 17:00 by its end -- so
its own clock never makes a night. Power outage is refused, spending nothing
(`no_night`), unless the last Time & weather time run chose night and its
anchor is still the match's clock (`BR.Terminal.terminalNight`): a weather run
after it keeps the night, a later day or dusk run ends it, and so does the
match's end. Asked again when the load ends, like every refusal. An outage
already running is not ended by a later day. The page and the reason say it
works "while it's night because someone ran Time & weather", which stays true
once a later day run has ended the night (round 4's review).

## Dev

Every one is dev-mode only, Season 2 only (`brseason 2` on a dev box at Season
1), and runs on the server as `brterminalsv`:

| Command | Does |
|---|---|
| `brterminal [nokey] [used] [offline] [volts=<n>]` | The computer anywhere, on a dev terminal whose facts are those words -- the app alone. Its runs spend `volts` (or the real balance as it opened) in the session alone, never the row |
| `brterminal close` | Close it |
| `bryubikey [give or take]` | A key for yourself, or yours taken: the real profile write and messages, the first-pickup card included |
| `bryubikey unseen` | Round 5: your next key -- `bryubikey give` or a pickup -- shows the first-pickup card again. This session's flag only (`BR.Yubikey.devUnseen`); the profile row's `yubikeySeen` is untouched and the next grant writes it true again |
| `bryubikey drop` | Round 5: a Yubikey on the ground a meter and a half in front of you, in your match or on the warmup pad (`BR.Yubikey.devDrop`), to test the real ground pickup -- the claim, `already_holding` and the card. Within 10 m of you only |
| `brterminal place [id]` | A terminal where you look (or on the ground ahead), facing you, for this session -- a plate and a blip, no laptop (the owner's ymap holds those); prints the config row |
| `brterminal remove <id>` | Out of play for this session (a config row stays in the file) |
| `brterminal list` | Every terminal, and whether your match has it online |
| `brterminal online <id> [off]` | Force one online whatever the storm, or hand it back |
| `brterminal reset [player id]` | Your squad's use this match, unspent, and your Yubikey back -- restored by its account, as a refund is -- so the same player can use a terminal again in the same match (round 6). With a player id, theirs; an id that names nobody resets nobody and says so. A player who never spent a key is given one too. Dev mode only, as every verb here; the result on your F8 |
| `brterminal run <function> [option=choice ...]` | The function's effect for you: no key, no terminal, no notice, no loading, nothing spent -- no Volts either; the options through `BR.Terminal.options` (`brterminal run ghost duration=240`). "This terminal" is the dev terminal, which is nowhere. Round 6: a function run at a spot (`airstrike`, `storm_control`, `supply_drop`, `power_outage` at its default `area=spot`) typed with no `x=` `y=` lands 60 m in front of you -- `brterminal run airstrike` rehearses the real strike, its warning, rockets, blasts and damage, for nothing. Round 5: `run gear_up item=medkit`, `run gear_up item=assaultrifle who=mate mate=<server id>`, `run gear_up item=grenade who=squad` (no Volts from the dev command); `run vehicle_drop` or `run vehicle_drop to=mate mate=<server id>` -- it asks that player's client for a spot first and drops the car `runMinMs` (3 s) later; `run airstrike x=<n> y=<n>` (the warning, then the rockets, the damage the server's). Wave B: `run storm_control x=<n> y=<n>` (the spot, as for Supply drop), `run time_weather change=time time=night` or `change=weather weather=snow`, `run power_outage area=county duration=240` (round 6: `area=spot` takes `x=<n> y=<n>`). Wave C: `run emp` (round 4: no options; it spares the squad of whoever typed it), `run comms_blackout duration=180`, `run reboot`. |

From the server console, a verb about a player takes the id next:
`brterminalsv open <player id> [...]`, `brterminalsv key <player id> give`.

## Scan and the bounty

**Scan** (`server/terminalfx.lua`): every opponent of the squad still in the
match -- alive, downed or in the air -- is sent to every member of the squad
(dead and spectating ones too: "for the whole squad") every `fx.scanPingMs`
(2 s) for the rest of the match, as TERMINAL_SCAN, from the roster's own 4 Hz
samples. Nobody else is sent it. `client/terminalfx.lua` draws a mark per
opponent on both maps (`art.scan`, named `scan_blip`), moves it on every push,
and clears them in the lobby or when the pushes stop.

**The bounty**, the owner's spec (2026-10-04) verbatim, on the player who ran
Scan, after the lobby has read `notice_action`:

- `bounty_new` to everyone in the match; `bounty_protect` to their squad (not to
  the bounty).
- `fx.bountyMs`: ten minutes. Ended early by elimination, leaving, or the match
  ending. No reward for the kill: the owner has not ruled.
- Everyone outside the bounty's squad is sent where it is every
  `fx.bountyPingMs` (TERMINAL_BOUNTY) and draws blip 58 colour 3 (`art.bounty`,
  named `bounty_blip`); one empty push clears every map when the last ends.
- The squad reads the beacon's new `bounty` bit (`server/party.lua`):
  `client/squadmates.lua` re-dresses that mate's blip as 58 colour 69 (on
  change only), and the squad panel draws `art.bountyGlyph` beside the name.
- The match panel lists every live bounty with its time left.

## Supply drop and Max ammo

**Supply drop** (run at a spot -- round 4, owner 2026-10-06: "The supply
drop should also allow them to pick exactly where") hands the spot set on the
big map (`at`, see [the map pick](#the-map-pick-round-4)) to `BR.Airdrop.call`
(`server/airdrop.lua`), which sites one extra drop at the airdrop spot nearest
it by the airdrop's own rules (the landing window, `insideBy`, placeable
ground, no POI another drop is on) -- an airdrop lands only at a spot -- and
announces it like any drop; from then on it is an ordinary drop (the 200 m
gate, moves, abandonment, the loot path), holds the schedule like a manual
one, and draws its heading and payout from a stream of its own. Refused,
spending nothing: `no_storm`, `drop_busy` (another drop is waiting or falling
-- the #355 rule), `no_site` (no airdrop spot fits inside the next circle;
while it is only listed, asked of the next circle's center).

**Max ammo** fills, for everyone in the squad still in the fight, every pool a
carried gun draws on to its cap and loads an empty magazine
(`BR.Inv.fillAmmo`: addAmmo's clamp and loadEmpty's move, one INV_SET each).
Refused, spending nothing, when nobody has room: `no_guns` when nobody still in
the fight carries a gun at all (`BR.Inv.hasGuns`: a gun with a magazine, never
melee or a throwable; round 7, owner 2026-10-07: '"ammo already full" shows
when I've got no weapons in-hand, so that's a bit confusing'), else `ammo_full`.
`ammo_full` is worked out over the whole squad, so its card reads
`status_ammo_full` "Squad's ammo already full" in a squad match (WRITTEN,
round 7 review: a runner with no gun whose teammates' guns were full read
"Ammo already full" as their own) and `status_ammo_full_solo` "Ammo already
full" outside one; `tools/test_terminal.lua` gives every status worked out
over more than the viewer a solo sibling, or checks it reads true either way. The whole squad in a squad match, wherever they are (round 4, owner 2026-10-06: "should apply to the whole squad, when in squads" -- it always did; `test_terminalfx.lua` pins a squadmate across the map and one in the air).

## Wave A (owner, 2026-10-06)

"All 14 others" are being built in three waves; wave A is these four (a
fifth, Lockdown, was removed by the owner on 2026-10-06, and two more in round
5). Each is **a file of its own**, `server/terminalfx/<id>.lua`, registering
its `BR.Terminal.FUNCTIONS` entry -- and, for one that changes something on a
client, `client/terminalfx/<id>.lua` -- listed in
`br_core/fxmanifest.lua` after `terminalfx.lua`, whose shared helpers they
use: on the server `T.fxOf` (the match's effects record), `T.marked`,
`T.namedLine` (`T.anchorOf`, "this terminal", went in round 6 with the last
function centered on one); on the client `F.newMark`, `F.dropMark`, `F.clear`,
`F.apply`, `F.on` and `F.onSlow` (a check on `client/terminalfx.lua`'s one
SLOW pass, so no file adds a loop callback). `tools/test_terminal.lua` and
`tools/test_terminalfx.lua` load exactly the files the manifest lists.

**The rules they all keep.** The server decides and times everything: an
effect's state lives on `m.terminalFx`, so it is gone with its match; a timed
one is ended by a job on `fx.endCheckMs` (or its own push schedule), by the
match no longer being played, and off Season 2 (a season switch is staged
until no match is running, so that is a dev box's `brseason` alone).
Durations and radii are config: the `fx` block, or an option's own choices
(seconds and meters, read as numbers). A line that says squad has its `_solo`
sibling through the picker. Nothing runs per frame.

| Function | What it does | Refused, spending nothing |
|---|---|---|
| Field medic | Every squadmate **standing** (ALIVE: not downed, not in the air) short of either gets full health (the display bar's 100) and full armor (`BR.Config.Match.maxArmour`), through `BR.Inv.grantEffect`. Round 4 (owner, 2026-10-06): and every player standing outside the squad with `fx.medicDrainFromHp` (50) health or more loses `fx.medicDrainHp` (20), through `BR.Damage.drain`; and the lobby is not told (`quiet`). Instant. | `health_full`: nothing at all would change -- everyone standing in the squad is full and nobody else standing has 50 |
| Disarm | Every player still in the fight OUTSIDE the runner's squad (round 4, owner 2026-10-06: "should not apply to the user or their squad") loses ONE weapon: the highest rarity, then the most damage, then the lower slot (`BR.Terminal.disarmPick`; guns and melee, never throwables), through `BR.Inv.revoke`. Gone, not dropped. 200 Volts. | `no_weapons`: nobody outside the squad carries one |
| Ghost | `duration` 120 / 240 s: the squad is left out of other squads' Scan marks and (round 5) an Airstrike pick's rough circles, and a bounty on one of them leaves every other map. It hides nobody from sight. | -- |
| Contract | A bounty for `fx.bountyMs` (10 min, Scan's -- round 4, owner 2026-10-06: "The contract bounty should last 10 minutes") on the player outside the squad with the most eliminations, never one in the runner's squad; a tie to whoever reached the count first (`killsAt`, stamped as a kill is credited), then the lower id (`BR.Terminal.contractPick`). | `no_target`: nobody outside the squad has one |

Each refusal is asked again when the load ends, so an effect that can no
longer happen gives everything back (the door's rule). Every function runs
through `brterminal run <id> [option=choice]`.

**Ghost is one predicate.** `BR.Terminal.hidden(m, key, now)`: under Ghost, in
a match being played, on Season 2. Scan's push and the bounty's push ask it
before they put anybody on another squad's map (and, round 5, an Airstrike
pick's rough circles), and Ghost pushes both at once
when it starts. Nothing is sent about Ghost itself; the squad's own
view (its beacon, its own bounty mark, its own Scan) and the match panel's
bounty list are untouched.

**Contract is Scan's bounty, word for word** (round 4). `BR.Terminal.startBounty`
is the one bounty: the owner's ten minutes, his `bounty_new` to the lobby and
his `bounty_protect` to the target's squad -- "for the next 10 minutes" is true
of a Contract now, so wave A's `contract_protect` (its five-minute line) and
`contract_target` (a toast to the target) are gone. The target reads their own
name in `bounty_new`, and their HUD's persistent notice says the bounty and its
time left ([persistent notices](#persistent-notices-round-4)). Same blip 58 in
his colors, same pushes and endings; a bounty already running restarts its ten
and is never shortened.

**Disarm and the anticheat.** The INV_SET takes a round trip; until it lands
the ped still holds the weapon, so a hit from it is refused -- a gun NOT_HELD,
a launcher NOT_THROWN, each a case on the first hit -- and the client's strip
of it is counted by `server/strip.lua`. A launcher's round fired just before
the INV_SET lands is still in the air, and lands after the weapon is gone.
`BR.Inv.revoke` remembers the weapon on the inventory for `fx.disarmGraceMs`
(10 s: an RPG rocket lives 5 s, a grenade launcher's round lobbed straight up
about 6.1 s, the railgun is instant, plus a round trip -- the stock
weapons.meta numbers are in the config note; never on the wire, gone with a
reset), and `server/damage.lua` and `server/strip.lua` stand down for that
weapon from that player alone, whatever the hit is refused for: the hit is
still refused, nobody is filed.

**Field medic and the ledger.** `BR.Inv.grantEffect` is a med kit landing's
authorization (a window and a ceiling per stat, `authorize`) and its
INV_EFFECT, so `server/roster.lua`'s ledger follows the ped to full instead of
snapping it back; a heal or shield channel still running is ended first (its
item left unspent), or its next slice would pull the ceiling back down.
**The drain** (round 4) is `BR.Damage.drain` (`server/damage.lua`), the
storm's shape rather than a bullet's -- no dealer, no weapon, no armor, no
credit: the ledger takes the whole engine points first (`BR.Roster.update`),
a heal ceiling still standing comes down by the same, `noteHurt` records it,
and `lastDrainAt` is stamped -- folded by `server/roster.lua`'s `healthCtx`
beside `lastHitAt` and `lastStormAt`, so for the round trip while the ped still
reads high the sampler holds the ledger and the health audit excuses it --
then HIT_DAMAGE tells the ped to follow. Not `lastHitAt` (a shooter's assist
window) and not `lastStormAt` (a death soon after would read as the storm's).
It stops a point above empty whatever it is asked, so it can never knock
anybody; Field medic only asks it of players at 50 or more. A heal running in
an ambulance is not told (bullets are not either: #372 waits on the owner).

## Wave C (owner, 2026-10-06)

The last three of "all 14": EMP, Comms blackout and Reboot, built the wave A
way -- a file each under `server/terminalfx/` (and, for EMP,
`client/terminalfx/`), listed in `br_core/fxmanifest.lua`, each keeping its
state on `m.terminalFx` and its clock on the server, ending with its match and
off Season 2, each through `brterminal run <id> [option=choice]`.

| Function | What it does | Refused, spending nothing |
|---|---|---|
| EMP | Round 4 (owner, 2026-10-06: "kill all cars in the entire match, except the ones that the user or their squad get into ... for 3 minutes"): no options; `fx.empMs` (3 min). Every player outside the runner's squad stalls whatever vehicle they drive, wherever it is; the squad drives as ever. A fact about drivers, not a mark on cars: see below. | Outside a match. Never for finding no vehicle |
| Comms blackout | `duration` 60 / 120 / 180 s; squad-only. Every OTHER squad's beacon rows leave the server without `x`/`y`, so their teammates' dots leave both maps -- a downed mate's, one left where a mate fell, and a bounty mate's blip 58 color 69 included -- and come back when it ends. Names, states, the bleed clock, levels, the voice bit and the Yubikey, bounty and revive key marks still travel: the beacon is the client's membership model. | Outside a squad match (the door), outside a match |
| Reboot | 150 Volts; squad-only. Every member of the squad who is OUT, in this match, still connected and not already on the way back comes back at full health with an empty inventory, through the revive key's own return (`BR.ReviveKey.bringBackAt`): black, the focus on the point, the spectate camera down, then a fade later resurrected 150 m over it with the parachute. Round 6: the point is the runner (option `to` = `self`) or a standing teammate picked from a dropdown (`to` = `mate`, `mate` from the state's `mates`) -- Vehicle drop's two options, to the letter; it was this terminal | `reboot_none`: nobody to bring back (asked again at the end of the load). `unavailable`: nobody in the squad left in the fight. `reboot_target`: over the runner, who is not standing as it runs. `drop_no_mate`: the teammate picked is not standing |

**EMP, a fact about drivers** (round 4). Wave C stalled the vehicles inside a
radius by a state bag on each; the owner's round-4 rule is about who is
DRIVING, and it holds for a car parked a mile off, one that drives in later
and one that changes hands mid-EMP -- so nothing is picked or marked. The
server keeps one fact per EMP on `m.terminalFx.emps` (the squad it spares,
who ran it, its end) and pushes every player in the match `TERMINAL_EMP`:
how long THEIR driving stalls (`leftMs`, from `BR.Terminal.empFor`: the
latest end among the EMPs that do not spare their squad, so two EMPs from two
squads spare neither from the other, as the page says: "unless another squad's
EMP is going off too", round 4's review) and how long any EMP lasts (`liveMs`) --
when one goes off, when one ends, and on `br:ready`. Each client applies it
to the one vehicle its own player is in the driver's seat of -- the driver's
client, which is where the vehicle's network ownership goes, so the write
sticks: on the fact's change, on `CEventNetworkPlayerEnteredVehicle` (held
again 250 ms and 1 s later as ownership arrives), and on
`client/terminalfx.lua`'s one SLOW pass (a shuffle into the driver's seat, an
engine somebody started under it, getting out, the end). Engine off, no
auto-start, undriveable; a car moving when it lands coasts to a stop.
**Spared, in a car somebody else stalled:** getting in while any EMP lasts
frees it -- driveable, started -- so a car the squad gets into works whoever
drove it before. **Whoever wrote the hold undoes it** (wave C's review: the
flags are that machine's copy): when its player stops driving it, when the
stall ends (started again for a driver still in the seat), in the lobby, off
Season 2 and as br_core stops. Never an aircraft (nobody may fly here, and a
stalled one would fall) or a bicycle (no engine) or a train. It ends at
`fx.empMs` on the server's 1 s pass and on the client's own clock, with the
match, and off Season 2. Nothing per frame; with no EMP and nothing written
the SLOW hook calls no native. Nothing is created, deleted, moved or marked:
`server/vehicles.lua`'s creation rule, the fuel ledger and
`sv_entityLockdown` are untouched.

**NPC traffic stops too** (round 7, owner 2026-10-07: "The EMP doesn't work
for NPC vehicles. We should probably use speed zones for this and set it to
0."). While any EMP lasts (`liveMs` -- every player in the match is sent it,
the runner's squad included), every client lays road speed zones at 0
(`AddRoadNodeSpeedZone`, p5 false) over the play area, and lifts each one
(`RemoveRoadNodeSpeedZone`) when none lasts: the server's end push (its time,
the match ending), its own clock, the lobby, Season 2 switched off, br_core
stopping. No server state was added. The research, in
`client/terminalfx/emp.lua`'s header: speed is in m/s and 0 holds the cars
where they are (forum.cfx.re/t/162682, /t/4871954); Rockstar's own comment on
the native says only cars running a cruise task obey it, so no player's own car
slows; a zone is local to the machine that lays it (/t/846551), so each client
lays its own for the AI cars it drives. Nothing found documents a cap on the
radius or the number of zones, so it is a grid (`fx.empTraffic`: cells of at
most 2,500 m over the boundary's box plus 500 m, a 2,000 m zone each at
z 300 -- 20 zones), which covers every road whether the game measures a
sphere or a circle. Whether the game holds all 20 is only checkable in game.
`emp_what` says "NPC traffic stops too." and `emp_affects` ends ", and NPC
traffic" (both WRITTEN, round 7; the Affects line after the review, which
found it still naming only players' vehicles). `tools/test_terminal.lua`
reads the speed zones from the client and holds every Affects and What line
of the tool that lays them to NPC traffic.

**Comms blackout is one predicate.** `BR.Terminal.blackedOut(m, key, now)`: a
blackout run by another squad, in force, in a match being played, on Season
2. The squad beacon asks it (`BR.Terminal.beaconDark`, by squad id) every
push; `client/squadmates.lua` takes a row with no position as no dot (the
blip removed, not hidden: an alpha-0 blip keeps its last coordinates) and
makes it afresh when positions come back. It answers a different question
from Ghost, and neither changes the other: a squad under Ghost is blacked out
like any squad and stays off other squads' Scan and bounty marks. A
bounty on a blacked-out squad's member leaves their own maps with the other
dots and stays on every other map. The revive key's ground marker and plate
stay (they are in the world, within 120 m, and how the key is picked up);
overhead names hang off peds already in sight; map pings are where a mate
pointed. The squad panel never showed where a teammate is, so the page's
line saying it would stop was taken out.

**Reboot's records** are the revive key's return's: the placement retracted
on every client (written again at the next elimination or the match's end),
`diedAt` cleared, the killer keeping the kill, nobody credited a revive, and a
revive key for a rebooted player spent -- held or not, bought or not (the
page's risks say so). A hold filling at an ambulance for one is stopped, and
none can start or keep running while they are on the way back (the review of
wave C: one started in the black would have been cleared with the key at the
arrival, its reviver's ring left up); a key arrival already committed lands on
its own and is not doubled. Only a squad
with somebody still in the fight is rebooted, so `BR.Server.squadsAlive` and
the match's end check (`<= 1`) are exactly what the eliminations left; the
players-left count grows. The match ending in the black withdraws the
promise.

## Gear Up (round 5, owner 2026-10-06)

> "add a new one which allows the user to give something to themselves -
> anything of their choice - any inventory item or weapon which is not a heavy
> sniper or machine gun. This should be a selection from a dropdown list
> within the tool, and the item they choose can also be given to a teammate,
> or for a charge of 200 volts the whole team can get them. If they choose a
> consumable, they are given the maxCarry quantity of that item." He named it
> Gear Up.

`server/terminalfx/gear_up.lua`; the row and its list in
`br_lib/config/terminals.lua`.

**The list** is built as `terminals.lua` loads (after `config/weapons.lua`
and `config/loot.lua`, as br_core's manifest has it): the guns, the airdrop
shelf, melee, throwables, the consumables and the CPR kit, in the configs'
order, each line its own `label` -- 55 items on 2026-10-06. **Left out**
(`gearUp`): every gun whose `class` is `'mg'` (the MG, the Gusenberg
Sweeper, the Combat MG and its Mk II, and the minigun, filed and fed with
them), and the Heavy Sniper by id. `class` is new on every firearm in
`config/weapons.lua` (`pistol`, `smg`, `rifle`, `shotgun`, `sniper`, `mg`,
`launcher`), so a machine gun added later is left out too. **Never on it**,
by construction: ammo (a pool, not a slot), the Yubikey and the revive key
(owned, never carried), fists, and the shop's car tokens (`config/shop.lua`'s).
The other three scoped rifles, the RPG, grenade launcher and railgun, and the
CPR kit are on it.

**Who gets it** (`who`): `self` (free), `mate` (free; `mate`, a dropdown of
the state's `mates`) or `squad` (200 Volts, `costBy`) -- the last two in a
squad match alone, `bad_option` outside one, where the page hides the choice.
Only a player who is STANDING gets it.

**How much**: a weapon as a crate's (a full magazine, and the found-gun spare
through `BR.Inv.give`); a consumable at its `carryMax` (the config's name for
"maxCarry"), or for one with no carry ceiling -- the two shields -- a full
stack (`maxStack`); a throwable at its stack; each clamped to what the player
may still carry and has room for.

**Through the inventory's own door**: `BR.Inv.roomFor(src, stack)` (new, a
read: how many go in without displacing anything -- a free slot for a gun,
top-ups and free slots for a stack, never the hand mid-channel -- or 0 and
`carrymax`/`noroom`) and `BR.Inv.give`. A granted gun is the server's own slot
from the moment it exists, which is what the shot validator's held check and
the weapon strip's `ourWeapon` read, so neither flags it; nothing is handed to
a ped, and nothing a player carries is ever thrown on the floor to make room.

| Choice | Refused, spending nothing (the Volts included) |
|---|---|
| `self` | `gear_standing` (not standing), `gear_full` (carrying the most), `gear_no_room` |
| `mate` | `gear_no_mate` (not a standing teammate now, or none picked), `gear_full_mate`, `gear_no_room_mate` |
| `squad` | a member at the ceiling is skipped (they have it); any member with no room refuses the run (`gear_no_room_squad`), so 200 Volts never leave a teammate out; everyone at the ceiling `gear_full_squad`; nobody standing `gear_standing` |

The refusal is asked again as the load ends, so a teammate who went down or
filled their bag meanwhile gives everything back. The lobby hears
`notice_action` with `gear_up_description`, which names no item; each teammate
who got it from somebody else's run is told who and what
(`gear_up_received`). Instant: no persistent notice. The card is available in
any match -- whether an item fits is a question about choices not made yet.

## Vehicle drop (round 5, owner 2026-10-06)

> "Kuruma is good!", and "let's not have them pick a location for the vehicle
> drop, but instead have it drop within 40m of them, with a blip until they get
> into the vehicle, OR when in squads they can pick from a dropdown of alive
> teammates to drop it next to."

`server/terminalfx/vehicle_drop.lua` and `client/terminalfx/vehicle_drop.lua`;
the row (100 Volts, proposed), the copy and `fx.drop*` in
`br_lib/config/terminals.lua`.

**The car** is an armored Kuruma (`fx.dropModel`, `kuruma2`), never an armed
vehicle, built by `BR.Vehicles.spawnOwned` -- the one creation path, in
`server/vehicles.lua` beside the allowlist -- so the vehicle rules' own ruling
admits it, it goes into the match's routing bucket, and the fuel ledger takes
it the moment somebody in the match sits in it.

**Next to whom** (`to`): `self`, or `mate` (`mate`, a dropdown of the state's
`mates`) -- the second in a squad match alone, `bad_option` outside one, where
the page hides the choice. No map pick.

**Where**: within `fx.dropRadiusM` (40 m) of that player, on a road or flat open
ground under open sky -- never on a player, in the water or inside a building.
Only a client can see roads and roofs, so as the run is accepted (`prepare`)
the client of the player it is for is asked to look (`TERMINAL_DROP_FIND`): the
nearest road node at least `fx.dropMinM` (6 m) away and inside the reach, no
more than 10 m above or below them, then flat open ground on rings around them
(within 6 m of their height), each spot out of the water (sea level, and
`GetWaterHeight` for the lakes), flat (a ground normal of 0.94 or more), with 60
m of open sky over it (one synchronous ray: no roof, bridge or tree) and nobody
and nothing on it (`IsPositionOccupied`, 3.5 m). It answers every second while
the run loads. The server keeps the last answer that passes ITS OWN checks
(`BR.TerminalSolve.dropCheck`: within `dropRadiusM` + `dropSlackM` of its 4 Hz
sample of them, within `dropRiseM` of their height, `dropClearM` from every
player in the match, inside the play area), and checks it again when the load
is over. No spot is `drop_ground` (`drop_ground_mate`) and everything comes
back.

**The descent**: the real car is built AT ONCE where it lands, a meter over the
ground, frozen and locked -- so a car the engine will not build is a refund,
not a promise -- and every client within `fx.dropDrawM` (600 m) draws a local
copy of it coming down from `fx.dropAltM` (120 m) under the airdrop's own
cargo chute (`BR.Config.Airdrop`'s `chuteModel` and its deploy anim, at
`art.drop.chuteScale`), on the airdrop's own fall curve (`BR.AirdropCrateZ`,
the flare at the bottom included), over `fx.dropFallMs` (9 s), hiding the real
one (`SetEntityLocallyInvisible`) until the copy touches down. Then the server
unfreezes and unlocks it. A FRAME callback only while a copy comes down.

**The blip** (`art.drop`) is on the squad's maps, moved if the car is, until
somebody in that squad gets in (the seat walk, `BR.Vehicles.ridingIn`, after it
has landed), the car is wrecked (engine at -4000) or gone, the match stops being
played, or Season 2 ends; again to a squadmate on `br:ready`. Nothing deletes
the car at the match's end, as nothing deletes a car bought in warmup: its
bucket is never used again.

| Refused, spending nothing (the Volts included) | When |
|---|---|
| `drop_target` | the runner is not standing (asked again as the load ends) |
| `drop_no_mate` | the teammate is not a standing teammate now, or none was named |
| `drop_ground`, `drop_ground_mate` | no spot the server will take, or the client never answered |
| `unavailable` | no match, the vehicle rules refuse the model (on the card too), or the engine would not build it |

The lobby hears `notice_action` with `vehicle_drop_description`; the teammate
it lands next to is told who sent it (`vehicle_drop_received`). It does
nothing timed to anybody else, so it has no persistent notice.

## Airstrike (round 5, owner 2026-10-06)

> "yes please put Airstrike in the same build", on the design proposed on
> #396: not homing missiles; after a visible ~10 s warning (a flare and a
> circle on everyone's map), about 10 unguided airstrike rockets onto random
> points within ~40 m of the spot; the damage decided by the server and
> credited to the runner, every client only drawing the rockets and the
> explosions.

`server/terminalfx/airstrike.lua` and `client/terminalfx/airstrike.lua`; the
row (200 Volts, proposed; `spot`, `fuzz`), the copy, `art.strike`, `art.fuzz`,
`art.rocket` and `fx.strike*`/`fx.fuzz*` in `br_lib/config/terminals.lua`.

**The spot** is round 4's map pick; inside the play area
(`BR.Config.Map.InBounds`) or `strike_spot`, nothing spent.

**While it is picked** the runner sees every opponent as a rough circle
(`fx.fuzzRadiusM`, 100 m) whose center is `fx.fuzzMinM`..`fx.fuzzMaxM` (25..85
m) off them, spread evenly over that ring's area -- always around them, never
on them (`BR.TerminalSolve.fuzzOffset`). Each offset is fixed for the match,
per runner and opponent, so picking again tells nothing more; the circle moves
with them every `fx.fuzzPingMs` (2 s) while the pick lasts, `fx.fuzzMaxMs` (2
min) at most. Never a teammate, never a squad under Ghost
(`BR.Terminal.hidden`, the one question every mark on another squad's map
asks), and none at all while the runner's squad has Scan running -- the exact
dots are already there. The page says Ghost hides a squad from the circles
while it lasts, as Scan's and Contract's say it of their marks (round 5's
review: `tools/test_terminal.lua` finds every row whose marks ask Ghost from
the code and holds its squad and solo page to it). Only inside the session on that terminal, from a
player the door would let run it and who can afford it. The client clears
them the moment its pick ends (`BR.Terminal.picking`), and the server's empty
list follows.

**The warning**: from the run's end, `fx.strikeWarnMs` (10 s) to the first
rocket. `TERMINAL_STRIKE` to the whole match carries the circle (a red radius
blip on every map, `airstrike_blip`, until `fx.strikeLingerMs` after the last
rocket) and every rocket's point and time; every client within
`fx.strikeDrawM` (800 m) lights a red flare at the spot (`BR.Flare.fire`, the
airdrop's own, on a thread of its own so its stream never holds the rockets)
and streams the rocket's model and particles. The persistent notice
(`impact_airstrike`) is on every player in the fight within its reach, the
runner's squad included, never the runner, until the last rocket.

**The rockets**: `fx.strikeRockets` (10) on points spread evenly over the area
within `fx.strikeRadiusM` (40 m), one after another, each at a random moment in
its own tenth of `fx.strikeSpreadMs` (4 s) (`BR.TerminalSolve.strikePlan`).
Unguided: nothing about where anybody is goes into the plan. Each client in
range draws each as a LOCAL object (`art.rocket.models`), and where it lands
a fireball (`exp_grd_vehicle`) drawn
out to the damage's own reach -- `fx.strikeReachM / art.rocket.blastBaseM`
times its size, 3x (round 6: "the explosions from them should be 3x as big,
at least"; `blastBaseM`, the effect's own 5 m, is the estimate to tune) -- the
game's cheap explosion sound and a camera shake within 60 m. **Why the rockets
were never seen** (round 6: "missile props never actually spawn"): the model
was asked for once and never waited on, so a rocket whose model had not
arrived was skipped silently; and a weapon's drawable is culled past its own
few meters, the airdrop crate's lesson, so a rocket 150 m up was not drawn
until its last meters. Now the model is streamed and waited on before the
first rocket flies (`IsModelInCdimage` and `IsModelValid` first, then the
stand-ins; none at all is said once on the console), each rocket is drawn from
`art.rocket.lodDist` (1,500 m since round 7), and it flies slowly enough to be
seen.

**Homing missiles, to look at** (round 7, owner 2026-10-07: "Any chance we
could use homing missiles targeted at the random coords we already have?").
The server's points, schedule and damage are untouched. Each rocket is the
Homing Launcher's own model (`w_lr_homing_rocket`, then the RPG's rocket and a
vehicle missile as stand-ins) with the trail the Homing Launcher's ammo draws
(`proj_rpg_trail`, weaponhominglauncher.meta's TrailFx), looped on it from
launch to landing. It is launched `launchM` (320 m) off to the side and
`launchUpM` (160 m) over its point, cruises in at that height veering
`weaveM` (40 m) to one side, dives from `diveUpM` (90 m) and lands on the
first surface under its point (a roof, or the street) at exactly its
scheduled time, `flightMs` (3 s) after launch -- a cubic curve, its nose along
it every frame (`rocketPath`). The launch bearing comes from the strike's id,
fanned over `fanDeg` (50 degrees) by each rocket's place in the schedule, so
every client draws the same flight. The page's third line says the rockets
"home in on random points" (WRITTEN, round 7; it said "They aren't
guided."), and `tools/test_terminal.lua` holds every Airstrike line to it
while the client launches them off to the side. A real homing projectile
(`ShootSingleBulletBetweenCoords` with the Homing Launcher) was weighed and
refused: the native credits its `ownerPed` in the kill feed, and the
launcher's ammo is `DestroyOnImpact ProcessImpacts` -- it explodes as itself,
GTA's damage, networked, whatever the bullet's `damage` says. **Never
`AddExplosion` and never a projectile**: a scripted explosion is networked,
hurts whatever it touches on that machine and is judged by
`server/damage.lua`'s explosion checks; these hurt nothing, send nothing and
flag nobody. A FRAME callback only from a moment before the first rocket
launches to the last one landing; each rocket in the air is moved and turned
every frame (two natives a rocket, up to eight at once), so the strike's own
frames cost more than round 6's straight slant -- `match airstrike` in
`tools/perf_budget.lua` was rebaselined for that alone.

**The damage is the server's.** Each rocket deals `fx.strikeDamage` (150) to
every player standing or downed within `fx.strikeFullM` (5 m; 4 m until round
6) of where it lands, falling off in a straight line to nothing at
`fx.strikeReachM` (15 m; 14 m until round 6) -- exactly as far as the fireball
is drawn, so nobody outside it is hurt and nobody inside it is spared
(`BR.TerminalSolve.blastDamage`), measured on the ground -- the server cannot
see roofs, so a rocket hurts whoever is within reach on the map, indoors or up
a tower. Players in the air and players out are untouched. Every hit goes
through `BR.Damage.applyHit` -- the health ledger's own door: armor first, a
downed player's bleed clock, the heal ceilings lowered, the victim's ped told
to follow -- billed as the world's blast (`WEAPON_EXPLOSION`), so it kills
outright, as every blast does. **An opponent's hit is the runner's**: the
damage credited, a hitmarker, the kill theirs (if they are still on the
server). **Friendly fire: the runner's own squad is hit too** -- it is their
call where to aim -- **but a teammate's hit, and the runner's own, is nobody's**:
`applyHit` with no dealer (round 5) -- no credit, no hitmarker, no assist
window taken, no teamkill counted; its hurt window is the drain's own stamp
(`lastDrainAt`), so the sampler holds and the health audit excuses the round
trip, as for Field medic's drain. **Vehicles** within `fx.strikeReachM` of a
rocket lose up to `fx.strikeVehicleDamage` (1000) engine and body points the
same way, and within `fx.strikeWreckM` (5 m; 4 m until round 6) are wrecked -- written by the one
client the server says owns each (`TERMINAL_STRIKE_VEH`), since a vehicle's
health is its owner's to write, and a wreck goes up the way any wreck does.

The lobby hears `notice_action` with `airstrike_description`. The match ending,
or Season 2 ending, stops the rockets still to land. `brterminal run airstrike
x=<n> y=<n>` strikes there, charging nothing.

## Persistent notices (round 4)

The owner, 2026-10-06: "Anything that a player is being impacted by, which
happened as a result of another player's actions at a terminal, should show a
persistent notification with a timer explaining what the impact is and when it
will be over."

**The server builds each player's list.** Every function file that puts a
timed or ongoing effect on other players registers a source
(`BR.Terminal.impactSource(fn)`, `fn(m, now, add)`), which calls
`add(src, key, untilAt)` for every player its effect is on right now: `key` the
`impact_*` line, `untilAt` its end on the server's clock or nil for the rest of
the match. Two of a kind on one player are one row at the later end; a row for
the rest of the match outlasts any clock. Only a player still in the fight has
rows -- out, spectating, the lobby, a match not being played and Season 1 have
none. `BR.Terminal.impactsOf(m, now)` sorts them, the soonest end first, then
the rest of the match, then by key. A 1 s pass (`terminal.impacts`) and the
door after a run's effect send each player `TERMINAL_IMPACTS` only when their
list changed, the text picked for them; `br:ready` makes the next pass send a
restarted client's list whole.

| Effect | Who has the row | Until |
|---|---|---|
| EMP (`impact_emp`) | every player whose driving it stalls -- everyone outside the runner's squad | the last such EMP ends |
| Power outage (`impact_outage`) | every player standing in a live area by the server's own position sample, as they walk in and out -- not the runner | it ends |
| Comms blackout (`impact_blackout`) | every player with a teammate in a squad another squad blacked out | it ends |
| A bounty (`impact_bounty`) | the player who carries it: a Contract's target, and a Scan's runner (the coordinator's spec named both) -- not while their squad is under Ghost, when no map shows them | its ten minutes |
| Scan (`impact_scan`) | every opponent of a scanning squad, but a squad under Ghost while it lasts | the match ends |
| Time & weather (`impact_time`, `impact_weather`) | everyone in the fight but the runner of the time (while its clock is the match's) and of the weather, one row each | the match ends |
| Storm control (`impact_storm`) | everyone in the fight but whoever aimed the storm that stands | the match ends |
| Airstrike (`impact_airstrike`) | everyone in the fight within its reach (its 40 m and a blast's 14 m past it) by the server's own samples, as they walk in and out -- the runner's squad included, never the runner | its last rocket |

**None:** Disarm, Field medic's drain, Max ammo, Reboot, Supply drop, Gear Up
and Vehicle drop are instant or touch nobody else (nothing to count down); Ghost and Storm reveal put nothing on anybody
else. The runner never has a row for their own run, but for a Scan's bounty;
their squadmates do (it is another player's run).

**The HUD** (`ui-src/src/hud/Impacts.tsx`): the rows sit at the foot of the
notice stack, nearest the minimap, with the passing notices above them --
NoticeRow's plate, in the warning tone, the sentence through KeyText -- and
each counts down with the shared drift-corrected clock (`useCountdownText`,
`formatClock`: `2:59`, `0:07`) against the store's `clockOffset`: one timer to
the next second, written into the node, no re-render and nothing per frame. A
row for the rest of the match shows its tail there instead. `hud/impactRows.ts`
shape-checks the envelope (`scripts/test-impacts.mjs`). The page clears them as
the match leaves play, and br_core's client sends an empty list in the lobby,
off Season 2 and as br_core stops, and the list again when br_ui restarts.
