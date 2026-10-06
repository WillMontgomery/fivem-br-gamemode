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
| **The shared rules** | `br_lib/shared/terminal_solve.lua` | Online against a Lockdown and the storm (`offlineWhy`), the squad's key, the sites list, the notice tokens, the extra roll -- one spelling for both sides. |
| **The effects** | `br_core/server/terminalfx.lua` | What the first built functions do: Scan and its bounty, Supply drop, Max ammo, and the pushes that keep Scan and the bounty on screen; and the helpers the files below share. |
| **One file per function** | `br_core/server/terminalfx/<id>.lua` | Wave A on (2026-10-06): Field medic, Disarm, Key finder, Pulse, Ghost, Contract, Lockdown -- see [Wave A](#wave-a-owner-2026-10-06); wave B's Storm delay, Storm control, Time & weather and Power outage -- see [wave B](#the-storm-the-sky-the-clock-and-the-lights-wave-b); and wave C's EMP, Comms blackout and Reboot -- see [Wave C](#wave-c-owner-2026-10-06). Every row is built. |
| **The marks** | `br_core/client/terminalfx.lua`, `br_core/client/terminalfx/<id>.lua` | Scan's opponents, the bounty, Key finder's keys and Pulse's finds on this player's maps, a Lockdown's fact for the world's online rule, and an EMP's stalled vehicles held on the client that owns them, from the server's pushes and state bags. Decides nothing. |

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
}
```

`reason` is a code, and a code is a key into the copy: `fn_offline` (the
effect is not built), `offline`, `locked` (a Lockdown has this terminal),
`squad_used`, `no_key`, `bad_option`, `unavailable` (a run of theirs or their
squad's in flight, a squad-only function outside a squad match), or any key a
function's own refusal adds (`no_storm`, `no_site`, `drop_busy`, `ammo_full`;
wave A's `health_full`, `no_weapons`, `no_keys`, `no_keys_ground`,
`no_keys_held`, `no_target`, `lockdown_none`; wave C's `reboot_none`). The app shows the line for the
code, or `unavailable` when there is none, and maps it to the card's four
statuses: Available, Used (`squad_used`), Not available (`fn_offline`,
`offline`), Not available at this terminal (everything else, `locked`
included). The balance is
never a listing's reason: Run stays pressable whatever it is, and only a run
is refused `no_volts`.

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
`match_heading` "Match stats", `status_offline` "Not available" and
`status_not_here` "Not available at this terminal", and round 3's plate,
`terminal_label` "Computer system" and `terminal_use` "press to open"), lines
**written** for the 2026-10-05 app at his request and listed in that round's
report for his review (the app's frame and pages, every function's lines, the
how-to, round 2's lines, marked "WRITTEN (2026-10-05, round 2)", and round 3's
one edit, `howto_terminal_body`'s "press interact"), and the remaining
**placeholders** outside the app (`first_pickup`, `already_holding`,
`key_label`). A line with a newline in it is
a list; `{name}`, `{value}`, `{count}`, `{stage}`/`{stages}`,
`{online}`/`{total}` and `{volts}`/`{cost}`/`{balance}` (a figure and the
currency word, "1,250 Volts") are filled by the app.

**"Squad" only in a squad match** (owner, round 2). A line that says squad has
a `<key>_solo` sibling that does not, and one picker per side chooses: the
Lua side's `BR.TerminalSolve.pick` (the server's toasts, notices and reasons,
and the world's plate) and the app's `speaker` (model.ts), both from
`squadMatch`. An empty `_solo` line hides the row it labels (the match
panel's squad rows, the mode in a squad match's warmup). A squad-only
function's lines, and the Squad category's name, are only ever shown in a
squad match, so they have none. `tools/test_terminal.lua` fails a line that
says squad with neither, and a Lua reader that indexes the copy by a computed
key or names a line with a sibling directly; `check-terminal.mjs` fails an app
component that reads the copy without the speaker.

Every function has, keyed by its id: `_name`, `_summary` (its card), `_what`,
`_duration`, `_affects`, `_notified`, `_risks` (optional; `risk_notice` is
always listed first), `_done`, `_description` (the lobby notice's
`{description}`), and per option `_opt_<option>` and `_opt_<option>_<choice>`
(with an optional `_desc`). `tools/test_terminal.lua` fails a row missing any.

The table below is the lines outside the functions' own:

| Key | Who reads it |
|---|---|
| `shell_boot` | At the terminal: under the boot spinner, for the 7-10 s boot |
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
| `functions_heading`, `filter_*`, `card_*`, `pref_*`, `status_*`, `risk_*`, `category_*` | At the terminal: the cards |
| `details_heading` .. `cost_line`, `risk_notice`, `run`, `confirm_*` | At the terminal: a function's page and its confirmation |
| `howto_*` | At the terminal: the how-to page |
| `privacy_*` | At the terminal: the Privacy page, the owner's approved policy (VERBATIM, "Perfect", 2026-10-06): its title and two paragraphs |
| `unavailable` | At the terminal: why not, for a code with no line |
| `fn_offline`, `bad_option`, `no_storm`, `no_site`, `drop_busy`, `ammo_full` | At the terminal: why not |
| `health_full`, `no_weapons`, `no_keys`, `no_keys_ground`, `no_keys_held`, `no_target`, `lockdown_none` | At the terminal: why not (wave A's functions) |
| `reboot_none` | At the terminal: why not (Reboot: nobody in the squad eliminated and still in the match). Squad-only, so no `_solo` line |
| `locked` | A terminal a Lockdown has taken: its world plate (nothing to press), a toast to a player who presses there anyway, the app's reason, and the refusal of a second Lockdown whose own terminal the first one took while it loaded |
| `key_finder_warned` | A toast to each key holder Key finder marked, after the lobby's notice |
| `pulse_detected` | A toast to each player a Pulse found, after the lobby's notice |
| `contract_protect` | A toast to a Contract target's squadmates (never the target): the owner's `bounty_protect` says ten minutes, Scan's; `{playername}` |
| `contract_target` | A toast to a Contract's target |
| `key_finder_blip`, `pulse_blip` | The legend names of Key finder's and Pulse's marks |
| `no_key`, `squad_used` | At the terminal (why not; `no_key` is also the login screen), and in the world (the terminal's plate) |
| `offline` | At the terminal (why not: the dev tool's `brterminal offline`, or the moment before the storm's close), and a toast to a player whose press reached the server a step behind the storm. Never a plate since round 4: a terminal outside the storm has none |
| `bounty_new` | A toast to the lobby: Scan's bounty; `{playername}` |
| `bounty_protect` | A toast to the bounty's squad, not the bounty; `{playername}` |
| `scan_blip`, `bounty_blip` | The legend names of Scan's and the bounty's marks |
| `<id>_description` | The lobby: the `{description}` in `notice_action` |
| `first_pickup` | A toast to a player picking up their first Yubikey ever |
| `already_holding` | A toast to a holder whose claim on a second key is refused |
| `notice_access` | A toast to the lobby (the whole match) when someone gains access; `{playername}` |
| `notice_action` | A toast to the lobby when a function ran; `{playername}`, `{description}` |
| `key_label` | Anyone near a key on the ground: its plate |
| `terminal_label` | Anyone near a terminal: its plate's title, and its blip's legend name |
| `terminal_use` | A holder at a live terminal: the plate's hint, beside their interact key's cap |
| `storm_reveal_blip` | The squad that ran Storm reveal: the legend name of the final zone |

`{playername}` travels as `BR.Notice.who` (drawn bold, never formatted into the
sentence); `{description}` as plain text. `BR.TerminalSolve.line` fills both.

## The art

Every placeholder is in one block, `art` in `br_lib/config/terminals.lua`:
`keyProp` and `keyScale` (a key on the ground), `hudGlyph` (the equipped icon
and the squad panel's holder mark), `terminalProp` (the model the owner's ymap
stands at every site, which Season 1 hides) and `hideRadiusM`,
`blipSprite`/`blipColour` (the owner's 521 and 51) and `blipScale`, and
`reveal` (the final zone's `sprite`, `colour`, `scale`, `radiusM` and
`alpha`). The owner's `blitz_seckey` prop and HUD icon replace the first two.
Wave A adds two placeholders the owner has not picked: `keyFinder` (Key
finder's marks: sprite 1, the plain dot, color 5, yellow) and `pulse`
(Pulse's: sprite 1, color 17, orange).

## The functions

**ONE REGISTRY, READ BY BOTH SIDES**: `BR.Config.Terminals.functions`, each row
`{ id, category, risk, implemented, options, cost?, squadOnly?, soloCategory? }`,
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
- `options`: `{ { id, choices = { ... }, default } }`. `BR.Terminal.options`
  takes a run's choices only if every key is a declared option and every value
  one of its `choices` (strings, at most 8), fills the rest with defaults, and
  refuses anything else whole (`bad_option`, nothing spent). The shell and the
  desktop shape-check them on the way too.

The server half of a built function is `BR.Terminal.FUNCTIONS[id]`
(`server/terminal.lua` for Storm reveal, `server/terminalfx.lua` for Scan,
Supply drop and Max ammo, and from wave A on a file of its own,
`server/terminalfx/<id>.lua`):

- `refuse(src, session, opts) -> reason|nil` (optional), asked after the shared
  reasons, which come in this order: `fn_offline`, `unavailable` (squad-only,
  outside a squad match), `offline`, `squad_used`, `no_key`, `unavailable` (a
  run in flight). `opts` is nil while the terminal is only being listed:
  answer for ANY choice, so a card says "Not available at this terminal" only
  when no choice could run. It is asked again when the loading is over.
- `run(src, session, opts) -> { ok, code, after? }`, called when the loading
  is over. On `ok` the server tells the lobby `notice_action`, then calls
  `after` -- so Scan's bounty toasts follow the redemption. Anything else
  gives everything back (see the run, below).

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
| `supply_drop` | Supply drop | supply | medium | | **live** |
| `max_ammo` | Max ammo | supply | low | | **live** |
| `reboot` | Reboot | squad (squad-only) | medium | 150 | **live** (wave C) |
| `ghost` | Ghost | squad (disruption alone) | low | | **live** (wave A) |
| `emp` | EMP | disruption | medium | | **live** (wave C) |
| `key_finder` | Key finder | intel | low | | **live** (wave A) |
| `storm_delay` | Storm delay | storm | low | | **live** (wave B) |
| `pulse` | Pulse | intel | medium | | **live** (wave A) |
| `lockdown` | Lockdown | disruption | medium | | **live** (wave A) |
| `contract` | Contract | disruption | medium | | **live** (wave A) |
| `field_medic` | Field medic | supply | low | | **live** (wave A) |

The costs are the coordinator's proposal for the owner (round 2). Time &
weather offers no thunderstorm, and its chosen weather holds only inside the
circle -- outside, the storm's own weather wins (the owner's rule; how it is
built is [wave B's section](#the-storm-the-sky-the-clock-and-the-lights-wave-b)).

**Wave B's functions are a file each** (#396, 2026-10-06), as wave A's are:
the server half in `br_core/server/terminalfx/<id>.lua`, the client half (when
there is one) in `br_core/client/terminalfx/<id>.lua`, both listed in
`br_core/fxmanifest.lua` after `terminalfx.lua`; `tools/test_terminal.lua`
loads every `server/terminalfx/` file the manifest names.

The first nine are the owner's (2026-10-04), the next four were suggested on
the issue, and the last five are proposals for him to keep or cut. A new
function is a row, its copy lines, and -- to go live -- an entry in
`BR.Terminal.FUNCTIONS` and `implemented = true`. `tools/test_terminal.lua`
fails a row missing a line, and a built row with no server entry.

## The wire

| Event | Way | Payload | Rule |
|---|---|---|---|
| `BR.Net.TERMINAL_OPEN` | S→C | `{ state }` | Open the computer on this terminal. |
| `BR.Net.TERMINAL_RUN` | C→S | `{ terminalId, functionId, options? }` | Dropped, unanswered, without an open session on that terminal, with a malformed id, or sooner than `runMinIntervalMs` after the last. Options the registry does not allow are answered `bad_option`. |
| `BR.Net.TERMINAL_INFO` | S→C | `{ terminalId, state }` | The open computer's state again, match panel included, every `infoPushMs` (1 s), to that player alone, only while open, never off Season 2. |
| `BR.Net.TERMINAL_SCAN` | S→C | `{ matchId, list = { { s, x, y, down? } } }` | Scan: every opponent's position, to the scanning squad alone (dead and spectating members included), every `fx.scanPingMs` for the rest of the match. A squad under Ghost is left out. |
| `BR.Net.TERMINAL_BOUNTY` | S→C | `{ matchId, list = { { s, x, y } } }` | Each live bounty's position (a Contract's too), to everyone in the match outside that bounty's squad, every `fx.bountyPingMs`, and once more, empty, when the last ends. A bounty on a squad under Ghost is left out. |
| `BR.Net.TERMINAL_KEYS` | S→C | `{ matchId, list = { { x, y } }, leftMs }` | Key finder: where each Yubikey was when it ran, to the squad that ran it alone; once more, empty, when its `fx.keyFinderMs` is up or the match ends; again on `br:ready` while it lasts. |
| `BR.Net.TERMINAL_PULSE` | S→C | `{ matchId, list = { { s, x, y } } }` | Pulse: where each player it found is now, to the squad that ran it alone, every `fx.pulsePingMs` for `fx.pulseMs`, and once more, empty, when it is over. |
| `BR.Net.TERMINAL_LOCKDOWN` | S→C | `{ matchId, on, keep?, leftMs? }` | Lockdown: every terminal but `keep` is offline in this match, to everyone in it, when it starts and when it ends (`on` false), and on `br:ready` while it lasts. The `lock` of the one online rule. |
| `fx.empBag` (`brEmp`), an entity state bag | S→C | the milliseconds an EMP has left, on each vehicle it stalled | EMP: set by the server alone (`server/terminalfx/emp.lua`) as it goes off, replicated to every client the vehicle is relevant to (and to one it becomes relevant to later), cleared when it ends, when its match ends or is torn down, and off Season 2. `client/terminalfx/emp.lua` reads it. |
| `BR.Net.SQUAD_POS` (`server/party.lua`) | S→C | the squad beacon's rows | Comms blackout: while one another squad ran is in force, every row sent to a blacked-out squad leaves `x` and `y` off, and nothing else (`BR.Terminal.beaconDark`). |
| `BR.Net.REVIVEKEY_ARRIVE`, `BR.Net.REVIVEKEY_PLACE` | S→C | `{ x, y, z }` / `{ cancelled }` | Reboot: the revive key's own return (`BR.ReviveKey.bringBackAt`), over this terminal. |
| `BR.Net.TERMINAL_RESULT` | S→C | `{ terminalId, functionId, ok, code, state?, runMs?, cost?, balance?, toast? }` | To the runner alone. `code` is `running` when a run is accepted (with `runMs`), `done` when it is over (a paid one with the new `balance`), else a reason (`no_volts` with `cost` and `balance`). Every answer but `running` carries `toast`, the line the server would toast for it; a client whose computer cannot show the answer toasts that. Once the server knows the computer has closed, the last word is its own toast instead. |
| `BR.Net.TERMINAL_CLOSE` | S→C | `{ why }` | The session is over (death, storm, teardown). |
| `BR.Net.TERMINAL_CLOSED` | C→S | `{ terminalId, why }` | The computer went away on the client; ends only the session it names. |
| `BR.Net.TERMINAL_DEV` | S→C | `'<text>'` | A `brterminalsv` answer, printed on F8. |
| `BR.Net.TERMINAL_USE` | C→S | `{ terminalId }` | "I pressed interact here." Opens a session only for a living player within reach by the server's own sample, in a PLAYING match, at an online terminal; offline is refused aloud. One per `runMinIntervalMs`. |
| `BR.Net.TERMINAL_SITES` | S→C | `{ placed, removed, forced }` | The dev tools' changes, whole, to everyone, and on `br:ready`. |
| `BR.Net.TERMINAL_REVEAL` | S→C | `{ x, y, r, matchId }` | Storm reveal, to the squad that ran it alone; again on `br:ready` while that match lasts, and again when Storm control moves the end. |
| `BR.Net.TERMINAL_SKY` | S→C | `{ matchId, weather? }` | Time & weather: the chosen weather (a weather name or the `base` role), to the whole match when it starts and when it ends (no `weather`), and on `br:ready` while it lasts. Each client claims it only while its view is inside the circle. |
| `BR.Net.TERMINAL_POWER` | S→C | `{ matchId, list = { { kind, x?, y?, r?, line? } } }` | Power outage: every live outage area, to the whole match when one starts or ends (an empty list: the lights back), and on `br:ready` while one lasts. |
| `BR.Net.YUBIKEY_STATE` | S→C | `{ held, squadUsed, squadMatch }` | This player's key and their squad's use, to them alone, on every change and on `br:ready`; `squadMatch` picks the plate's `squad_used` line. Squadmates learn who holds a key from the squad beacon's `yubikey` bit. |

## br_core and the computer

`exports.cuchi_computer`:

| Export | Does |
|---|---|
| `Open(state, copy, catalog, desktop) -> ok, why` | Boots the desktop (the player opens the app from its icon), takes NUI focus (keyboard and cursor). Refuses with `page-not-ready` before the page has loaded, rather than take focus over nothing. Opening another terminal while one is open closes the first (`replaced`). `catalog` is `{ functions, categories, currency, pageLoad }`, the registry and the browser's page-load range (`{ minMs, maxMs }`); `desktop` is `{ bootMinMs, bootMaxMs, clock = { h, m } }`. |
| `Update(state)` | The new state, while open on that terminal: after a run, and once a second (TERMINAL_INFO). |
| `Result(result) -> shown` | `{ functionId, ok, code, runMs?, cost?, balance?, toast? }`, while open; `false` when nothing is up to show it, and `br_core` toasts `toast` instead. |
| `Clock(h, m)` | The game's hour and minute for the taskbar: `br_core` reads the clock (never writes it) while the computer is open and sends it on each new minute. |
| `Close(why) -> ok` | Takes it down and releases focus. |
| `IsOpen() -> boolean` | |

Local events it raises for `br_core`'s client (never net events):

| Event | Args | When |
|---|---|---|
| `cuchi_computer:opened` | `terminalId` | Focus taken |
| `cuchi_computer:request` | `terminalId, { action = 'run', functionId, options }` | The page asked; the terminal is the one `br_core` opened; `options` shape-checked |
| `cuchi_computer:closed` | `terminalId, why` | Focus released: `escape`, `exit` (the power button), `page`, `replaced`, `opener-stopped`, `stopped`, or `br_core`'s own why |
| `cuchi_computer:missed` | `toast, ok` | The page handed back a run's last word the app never showed (NUI callback `missed { toast }`); passed on only for a toast this shell relayed, once. `br_core` toasts it |

**Focus.** The computer is its own resource's page, so it holds its own NUI
focus: FiveM keeps one vote per resource. Every way out releases it, including
`br_core` stopping (the shell watches the resource that opened it) and the shell
itself stopping. `br_core`'s client tells the key layer on `opened` and
`closed` (`BR.Keys.setExternalScreen`), so no key action fires under the
computer, and Escape is the computer's while it is up and for three frames after.

## The page and the app

Inside the computer, `nui/br.js` and the app talk by `postMessage`, each
listening only to the other's window, every message carrying `brTerminal: 1`:

| Way | Message |
|---|---|
| app → desktop | `{ type: 'ready' }`, `{ type: 'run', functionId, options? }`, `{ type: 'escape' }`, `{ type: 'loading', on: true, ms }` / `{ type: 'loading', on: false }` (a page load started or ended: the tab's symbol) |
| desktop → app | `{ type: 'state', state, copy?, catalog? }` (copy and catalog on ready; an update is the state alone), `{ type: 'result', result }` |

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
Escape, on the desktop (the boot included) or inside the app, closes the
computer -- unless a dialog or an open dropdown in the app takes it first (the
app reads it in the capture phase). **The window** resizes from any edge or
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
page (`https://controltower.blitz/home`, `.../functions/supply-drop`,
`.../privacy`). It lives in the app
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
  off when the page shows, when the app's window or the computer closes, when
  a fresh app is ready, and by a backstop at the load's length plus a second
  (15 s at most). No Cloudscape Spinner.

`model.ts` holds the rules (`navigate`, `arrive`, `step`, `rewrite`,
`loadMs`), tested in `test-terminal-model.mjs`; the tab's class on every way in
and out is `test-terminal-desktop.mjs`'s; `check-terminal.mjs` T10 holds the
wiring and the stylesheet.

**The site** (Cloudscape, like the cards and details examples): a fixed
TopNavigation with the app's name -- the one place in the app it is written --
a search across every function (pick one to open it, or search the cards), the
player's Volts, the light/dark switch, and the gamertag as the signed-in user
(its menu: How to, Sign out); AppLayout with SideNavigation (Home, How to,
Privacy, each category with something in it; no header) and a BreadcrumbGroup
on every page but the login screen; Home, the functions page ("Match stats",
collapsed, over the cards, with a text filter, pagination and preferences;
"Home" in its address, its link and the trail's first crumb, owner 2026-10-06,
while its heading still counts the Functions), a page per function (its trail
Home, its category, its name; details with its cost, what it does, its options
as RadioGroups, its risks, Run in its risk badge's color behind a
confirmation), the how-to page, the Privacy page (the owner's approved
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

## The Yubikey

The owner's rules (#396, 2026-10-04), and where each lives:

- **Owned, one per player, no slot.** On the profile row, read by the connect
  read `server/market.lua` already makes, written through `br:ddb:yubikeySet`,
  whose condition is the cap of one. The session cache is what the game reads; a
  failed write is a console line, never a refusal.
- **A key on the ground is ordinary loot**, kind `yubikey`, drawn by
  `client/loot.lua` and claimed through `server/loot.lua`'s LOOT_CLAIM like a
  Volts pile. A holder's claim is refused (`already_holding`) and the key stays.
- **The first key ever** shows `first_pickup` once (`yubikeySeen`).
- **On screen**: the HUD envelope's `yubikey` (the glyph) while held; the squad
  panel's mark beside every squadmate who holds one (several can).
- **Carried into the next match** unused: the row still says so.
- **Dropped where its holder dies**, on the death box's edge
  (`server/combat.lua`), and where a holder **leaves mid-fight** -- walking out
  or disconnecting -- while `leaveDrops` is true. That is UNDECIDED; true is the
  default, as proposed on the issue.
- **Sources**: an EXTRA item rolled as a container opens, on its own stream, so
  the box's own contents do not move -- `airdropChance` (0.5) per airdrop and
  `legendaryCrateChance` (0.05) per legendary crate. Never on the warmup pad.

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
shape; before there is a storm everything is inside it -- **and only while no
Lockdown has it** (wave A).

**ONE ONLINE RULE, BOTH SIDES**: `BR.TerminalSolve.offlineWhy(site, zone,
forced, lock)` answers `'locked'` (a Lockdown is in force in this match and
this is not the terminal it kept -- nothing beats it, not even the dev tool's
forcing), else `'offline'` (outside the storm, unless forced online), else nil.
The server reads it through `BR.Terminal.offlineWhy` (and `T.online`, its
boolean) for every use, every run, every session check, the panel's count and
`brterminal list`; every client reads it in `client/yubikey.lua`, with the
Lockdown `client/terminalfx/lockdown.lua` was told about. The terminal a
Lockdown keeps is still the storm's.

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
  terminal, and only in a match (from the bus on) -- so during a Lockdown a
  key holder's map shows only the terminal it kept.
- **Its plate** (the shared prompt browser) reads `terminal_label` ("Computer
  system") over one of four hints:
  - `terminal_use` ("press to open") with the player's interact key: a press
    opens the computer;
  - `no_key`: the key cap too, and a press opens it, every function `no_key`;
  - `squad_used`: the same;
  - `locked` (a Lockdown has it): no key cap, nothing to press.
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
3. **A run** is refused, in this order, `offline` (or `locked`),
   `squad_used`, `no_key`, a run in flight, the function's own reason, then
   `no_volts`.
4. **When it is accepted**: its Volts, then the key and the squad's ONE use
   this match (a solo player is a squad of one) are spent, and the squad is
   told its use is gone; the squad's other holders are refused `squad_used`
   and keep their keys. **When it is done**, 3-5 s later, the lobby hears
   `notice_action` -- or, if it could not happen, everything comes back.
5. **Every fact is read from the world on every ask.** A session closes when its
   player goes down, dies, leaves, walks away or the storm (or a Lockdown)
   takes the terminal: on a 500 ms check, and again inside every run.

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

Four functions change the world everybody in the match stands in (#396,
2026-10-06). Each is built to its own page in `copy`, and where a line could
not be true it was changed (the report of wave B lists every one).

**Storm delay** (`server/terminalfx/storm_delay.lua`, option `delay` 60 or
120 s): the hold is the storm record's own `tWait`. While the storm holds,
`BR.Storm.delay` rebuilds the record with the same tStart, circles, seed and
outline and `delay` more hold, and publishes it, so every client's countdown,
the sweep after it, the airdrop's landing circles and the match panel follow
it. While the wall closes the delay waits in `m.stormDelayNextMs` and
`enterPhase` adds it to the next hold. Real seconds, never scaled by
`brstormscale`; the next circle never moves; the 75% cut (#352) cuts to 1:30
plus the delay. Refused `no_storm`, and `no_hold` once the final circle is
closing or closed (`BR.Storm.holdLeft`).

**Storm control** (`storm_control.lua`, 150 Volts, option `zone`): where the
match ends is where its storm stream takes it, so a possible final circle is
the storm's own planner -- `drawCentre`, the function and arguments
`enterPhase` uses -- run forward on another stream (`BR.Storm.futures`):
`fx.stormControlFutures` (8) of them, the storm's own plan first. Every one
obeys the planner's rules: the play area and its water, the nesting and the
breakout's gap, the edge hug, each zone's shape (#344, from the seed, which
nothing here changes). `BR.TerminalSolve.threeEnds` names three different
ones, all measured from this terminal so each label is true of the circle it
picks: **near** (nearest it, "Closest to this terminal"), **far** (of the
others, the farthest from it, "Farthest from this terminal") and **center**
(of the rest, the one whose distance is nearest halfway between those two,
"Middle distance from this terminal"); at the dev terminal "this terminal"
is the player. A middle choice measured from anywhere else would be "of the
rest", and its label false whenever near or far had taken the end it named.
`tools/test_terminalworld.lua` holds each zone label to its claim over
thousands of draws, and a label it has no claim for fails. `BR.Storm.steer`
hands the match the chosen stream, and nothing else moves: the record on the
map and the circle already drawn stay, and the change starts with the next
circle `enterPhase` draws -- which reaches every client, the map's morph
(#350) and the airdrop's re-site (#386) as any record does. A squad that ran
Storm reveal is sent the new end. Refused `no_storm`, and `no_circle` once the
final circle is on the map. `tools/test_storm.lua`'s `control.valid` steers
24 matches to each of the three at every phase and checks every later circle
against the planner's own geometry.

**Time & weather** (`time_weather.lua`, both sides; options `time`,
`weather`, `duration`):

- **The time** is the match clock's anchor (#394). The run gives the match a
  new anchor -- the chosen hour from `fx.skyTime` (day 12:00, dusk 19:30,
  night 00:00), running from now at the match's own rate -- which the digest,
  the state events, the snapshot and a spectator's pushes already carry; the
  one clock writer (`BR.Native.applyClock`) writes once when it arrives and
  once when the match's own anchor comes back at the end, so the clock returns
  to where the match's own time has run to. No client writes the clock for it.
- **The weather** is a sky claim, `terminal`, ranked below `storm` and above
  `island` (`br_lib/shared/world.lua`'s `SKY_SOURCES`), claimed only while the
  client's view is inside the circle (`BR.Storm.viewInside`, kept by the
  storm's own tick; the shot for a spectator). Caught outside is THUNDER
  whatever was chosen; outside the circle and not caught (phase 1's free-loot
  hold) the storm's own sky stands. **A role yields to a weather claimed below
  it**: the storm's all-clear is the `base` role, held for the rest of a match
  once the storm has caught the player, and the chosen RAIN is drawn over it.
  Claiming a weather hands the rain knob back, as the console's does.
- **Clear** is the `base` role: EXTRASUNNY, and **XMAS with snow on the
  ground in December and January** (#399), as a storm exit is. The ground
  follows the resolved weather as #399 shipped -- bare under RAIN or FOGGY.
- **It ends** when its time is up, when the match stops PLAYING (the end
  screen included) or off Season 2, on a 1 s pass (`fx.worldCheckMs`): the
  match's own clock back, the weather released on every client. A client lets
  go in the lobby too. A second run replaces the first.

**Power outage** (`power_outage.lua`, both sides; options `area`,
`duration`): the engine's blackout (`SET_ARTIFICIAL_LIGHTS_STATE`) is one
switch per client for the whole map, so a client whose view is inside a live
outage area turns its own lights off -- vehicles left out of it
(`_SET_ARTIFICIAL_LIGHTS_STATE_AFFECTS_VEHICLES(false)`), so headlights work --
and one outside keeps its lights. **here** is `fx.outageRadiusM` (1000 m, the
page's 1 km) around this terminal; **city** is below the storm's city line
and **county** on or above it (`BR.StormCityLine`, the #381 line the anchor's
draw reads). `BR.TerminalSolve.outageArea` / `inOutage` are the one spelling
both sides use. Several can run at once. The lights are written on a change
only, and put back at the end, in the lobby, off Season 2 and when `br_core`
stops; `tools/verify.sh` allows the two natives (by name and by hash) in
`client/terminalfx/power_outage.lua` alone. vMenu's weather sync writes the
blackout every second while it is on, which is why `server.cfg.example` keeps
it off.

**Daytime, mostly.** A match runs from noon at the slow clock's rate -- about
17:00 by its end -- so an outage barely shows unless Time & weather has made
it dusk or night.

## Dev

Every one is dev-mode only, Season 2 only (`brseason 2` on a dev box at Season
1), and runs on the server as `brterminalsv`:

| Command | Does |
|---|---|
| `brterminal [nokey] [used] [offline] [volts=<n>]` | The computer anywhere, on a dev terminal whose facts are those words -- the app alone. Its runs spend `volts` (or the real balance as it opened) in the session alone, never the row |
| `brterminal close` | Close it |
| `bryubikey [give or take]` | A key for yourself, or yours taken: the real profile write and messages |
| `brterminal place [id]` | A terminal where you look (or on the ground ahead), facing you, for this session -- a plate and a blip, no laptop (the owner's ymap holds those); prints the config row |
| `brterminal remove <id>` | Out of play for this session (a config row stays in the file) |
| `brterminal list` | Every terminal, and whether your match has it online (`LOCKED (Lockdown)` when a Lockdown has it) |
| `brterminal online <id> [off]` | Force one online whatever the storm, or hand it back |
| `brterminal reset` | Your squad's use this match, unspent |
| `brterminal run <function> [option=choice ...]` | The function's effect for you: no key, no terminal, no notice, no loading, nothing spent -- no Volts either; the options through `BR.Terminal.options` (`brterminal run pulse radius=500`, `brterminal run lockdown duration=300`). "This terminal" is the dev terminal, which is nowhere: Pulse, EMP and Reboot are centered on you, and Lockdown keeps the terminal nearest you. Wave B: `run storm_delay delay=120`, `run storm_control zone=far`, `run time_weather time=night weather=rain duration=300`, `run power_outage area=here duration=240`. Wave C: `run emp radius=600 duration=60`, `run comms_blackout duration=180`, `run reboot`. |

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

**Supply drop** (option `site`: `terminal` or `circle`) hands this terminal's
point, or the next circle's centre, to `BR.Airdrop.call`
(`server/airdrop.lua`), which sites one extra drop at the nearest airdrop spot
by the airdrop's own rules (the landing window, `insideBy`, placeable ground,
no POI another drop is on) and announces it like any drop; from then on it is
an ordinary drop (the 200 m gate, moves, abandonment, the loot path), holds the
schedule like a manual one, and draws its heading and payout from a stream of
its own. Refused, spending nothing: `no_storm`, `drop_busy` (another drop is
waiting or falling -- the #355 rule), `no_site`.

**Max ammo** fills, for everyone in the squad still in the fight, every pool a
carried gun draws on to its cap and loads an empty magazine
(`BR.Inv.fillAmmo`: addAmmo's clamp and loadEmpty's move, one INV_SET each).
Refused `ammo_full`, spending nothing, when nobody has room.

## Wave A (owner, 2026-10-06)

"All 14 others" are being built in three waves; wave A is these seven. Each is
**a file of its own**, `server/terminalfx/<id>.lua`, registering its
`BR.Terminal.FUNCTIONS` entry -- and, for the three that draw or read
something on a client, `client/terminalfx/<id>.lua` -- listed in
`br_core/fxmanifest.lua` after `terminalfx.lua`, whose shared helpers they
use: on the server `T.fxOf` (the match's effects record), `T.marked`,
`T.namedLine`, `T.anchorOf` ("this terminal": the session's, or the player at
the dev terminal); on the client `F.newMark`, `F.dropMark`, `F.clear`,
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
| Field medic | Every squadmate **standing** (ALIVE: not downed, not in the air) short of either gets full health (the display bar's 100) and full armor (`BR.Config.Match.maxArmour`), through `BR.Inv.grantEffect`. Instant. | `health_full`: everyone standing is full |
| Disarm | Every player still in the fight, the runner's squad too, loses ONE weapon: the highest rarity, then the most damage, then the lower slot (`BR.Terminal.disarmPick`; guns and melee, never throwables), through `BR.Inv.revoke`. Gone, not dropped. 200 Volts. | `no_weapons`: nobody carries one |
| Key finder | `target`: every loose Yubikey in the match's loot, or every player OUTSIDE the squad holding one (in the fight). One static position each, on the squad's maps (`TERMINAL_KEYS`) for `fx.keyFinderMs` (2 min). Each holder it marks is warned (`key_finder_warned`). | `no_keys` (the card: none either way), `no_keys_ground`, `no_keys_held` |
| Pulse | `radius` 250 / 500 m around this terminal: every player outside the squad in the fight inside it, found once and followed wherever they go (`TERMINAL_PULSE`, every `fx.pulsePingMs`) for `fx.pulseMs` (30 s). Each one found is told (`pulse_detected`). | Never for finding nobody -- a refusal is free, so it would be free intel |
| Ghost | `duration` 120 / 240 s: the squad is left out of other squads' Scan and Pulse marks, and a bounty on one of them leaves every other map. It hides nobody from sight. | -- |
| Contract | A bounty for `fx.contractMs` (5 min) on the player outside the squad with the most eliminations; a tie to whoever reached the count first (`killsAt`, stamped as a kill is credited), then the lower id (`BR.Terminal.contractPick`). | `no_target`: nobody outside the squad has one |
| Lockdown | `duration` 180 / 300 s: every terminal but this one offline -- open computers there close, nobody can open them, a key holder's map shows only this one (`TERMINAL_LOCKDOWN`, the one online rule's `lock`). | `lockdown_none`: no other terminal is online. `locked`: another squad's Lockdown has taken this terminal -- two loading in the same 3-5 s, the second to land is given everything back instead of locking the terminal the first kept |

Each refusal is asked again when the load ends, so an effect that can no
longer happen gives everything back (the door's rule). Every function runs
through `brterminal run <id> [option=choice]`.

**Ghost is one predicate.** `BR.Terminal.hidden(m, key, now)`: under Ghost, in
a match being played, on Season 2. Scan's push, the bounty's push and Pulse ask
it before they put anybody on another squad's map, and Ghost pushes all three
at once when it starts. Nothing is sent about Ghost itself; the squad's own
view (its beacon, its own bounty mark, its own Scan) and the match panel's
bounty list are untouched.

**Contract is Scan's bounty in its own words.** `BR.Terminal.startBounty` takes
a Contract's clock and lines: the owner's `bounty_new` to the lobby verbatim
(it names no length), but never his `bounty_protect` -- "for the next 10
minutes" is Scan's ten -- so the target's squad reads `contract_protect` and
the target `contract_target`. Same blip 58 in his colors, same pushes and
endings; a bounty already running keeps whichever clock is longer.

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

## Wave C (owner, 2026-10-06)

The last three of "all 14": EMP, Comms blackout and Reboot, built the wave A
way -- a file each under `server/terminalfx/` (and, for EMP,
`client/terminalfx/`), listed in `br_core/fxmanifest.lua`, each keeping its
state on `m.terminalFx` and its clock on the server, ending with its match and
off Season 2, each through `brterminal run <id> [option=choice]`.

| Function | What it does | Refused, spending nothing |
|---|---|---|
| EMP | `radius` 300 / 600 m around this terminal, `duration` 30 / 60 s. As it goes off the server picks every vehicle in the match's routing bucket inside the radius (on the ground) that a player may use here (`BR.Terminal.empPick`), and marks each with the `fx.empBag` state bag. The client that owns a marked vehicle holds it stalled -- engine off, no auto-start, undriveable -- and lets it go when the bag clears: started again with a driver in the seat, else free to start. A vehicle that drives in later was never picked. | Outside a match, or on a build with no server vehicle natives. Never for finding no vehicle (Pulse's rule: a refusal is free intel) |
| Comms blackout | `duration` 60 / 120 / 180 s; squad-only. Every OTHER squad's beacon rows leave the server without `x`/`y`, so their teammates' dots leave both maps -- a downed mate's, one left where a mate fell, and a bounty mate's blip 58 color 69 included -- and come back when it ends. Names, states, the bleed clock, levels, the voice bit and the Yubikey, bounty and revive key marks still travel: the beacon is the client's membership model. | Outside a squad match (the door), outside a match |
| Reboot | 150 Volts; squad-only. Every member of the squad who is OUT, in this match, still connected and not already on the way back comes back over this terminal at full health with an empty inventory, through the revive key's own return (`BR.ReviveKey.bringBackAt`): black, the focus on the terminal, the spectate camera down, then a fade later resurrected 150 m over it with the parachute. | `reboot_none`: nobody to bring back (asked again at the end of the load). `unavailable`: nobody in the squad left in the fight |

**EMP, who stalls it.** A vehicle's engine is its network owner's to run, so
every client keeps the marked vehicles it hears of (the bag's change handler,
which also fires as a vehicle comes into scope) and the one that owns each
holds it: on the bag's change, on `CEventNetworkPlayerEnteredVehicle` (read off
the entity itself, held again 250 ms and 1 s later as ownership reaches the
new driver), and on `client/terminalfx.lua`'s one SLOW pass for ownership that
moved or an engine somebody started (a refuel's ignition, a revive hold's
siren). Behind the server's clear: a vehicle this client owns whose bag is
gone, the lobby, Season 1, the resource stopping, and 5 s past the time the
bag gave. **Whoever stalled a vehicle undoes it, owner or not** (the wave C
review): a stall writes the undriveable and no-auto-start flags to that
client's own copy, and nothing promises the owner's sync writes them back, so
every client keeps the vehicles it wrote to and every way an EMP ends undoes
them -- the owner releases in full, any other client clears both flags on its
copy and leaves the engine to the owner -- and getting into a vehicle with no
bag that this client marked or stalled undoes it again as ownership arrives.
Nothing per frame; with nothing marked and nothing left to undo the SLOW hook
calls no native. **Not picked:** anything `BR.Config.VehicleRefusalFor`
refuses -- **aircraft** above all: nobody may fly one here (#215 ejects them,
#211 files a case), the bus and the airdrop's plane are local and never
networked, and a stalled helicopter in the air falls on whoever is under it,
which the page does not say -- and the tanks; a trailer or a train (no
engine), and the CPR ride while it carries a downed player. An armed
model-table vehicle is NOT refused since #322 (its weapons are switched off),
so it is picked and stalls like any car. A bicycle is marked and never held:
it has no engine. Nothing is created, deleted or moved (`server/vehicles.lua`'s
creation rule, the fuel ledger and `sv_entityLockdown` are untouched); the
only write is the server's own state bag, cleared with its end, its match,
Season 1 and br_core stopping.

**Comms blackout is one predicate.** `BR.Terminal.blackedOut(m, key, now)`: a
blackout run by another squad, in force, in a match being played, on Season
2. The squad beacon asks it (`BR.Terminal.beaconDark`, by squad id) every
push; `client/squadmates.lua` takes a row with no position as no dot (the
blip removed, not hidden: an alpha-0 blip keeps its last coordinates) and
makes it afresh when positions come back. It answers a different question
from Ghost, and neither changes the other: a squad under Ghost is blacked out
like any squad and stays off other squads' Scan, Pulse and bounty marks. A
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
