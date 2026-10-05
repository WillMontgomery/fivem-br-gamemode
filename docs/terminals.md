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
| **The app** | `ui-src/terminal`, built into `cuchi_computer/nui/apps/terminal` | React + Cloudscape, a web site in the desktop's one window (an iframe) dressed as a browser. Renders the state, the copy and the catalog, asks to run. Decides nothing. |

Around them, the Gameplay half:

| Piece | Where | Its job |
|---|---|---|
| **The key** | `br_core/server/yubikey.lua` | Who holds a Yubikey, on the profile row through br_ddb (`yubikey`, `yubikeySeen`); every way one changes hands. |
| **The world** | `br_core/client/yubikey.lua` | Each terminal's local prop, blip and plate; the hold that asks to open one; the key's HUD glyph; Storm reveal on the maps. Decides nothing. |
| **The shared rules** | `br_lib/shared/terminal_solve.lua` | Online against the storm, the squad's key, the sites list, the notice tokens, the extra roll -- one spelling for both sides. |
| **The effects** | `br_core/server/terminalfx.lua` | What the built functions do: Scan and its bounty, Supply drop, Max ammo, and the pushes that keep Scan and the bounty on screen. |
| **The marks** | `br_core/client/terminalfx.lua` | Scan's opponents and the bounty on this player's maps, from the server's pushes. Decides nothing. |

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
effect is not built), `offline`, `squad_used`, `no_key`, `bad_option`, or any
key a function's own refusal adds (`no_storm`, `no_site`, `drop_busy`,
`ammo_full`). The app shows the line for the code, or `unavailable` when
there is none, and maps it to the card's four statuses: available, used
(`squad_used`), offline (`fn_offline`, `offline`), not here (everything else).

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
(`no_key`, `notice_access`, `notice_action`, `bounty_new`, `bounty_protect`),
lines **written** for the 2026-10-05 app at his request and listed in that
round's report for his review (the app's frame and pages, every function's
lines, the how-to), and the remaining **placeholders** outside the app
(`first_pickup`, `already_holding`, `key_label`, `terminal_label`,
`terminal_use`). A line with a newline in it is a list; `{name}`, `{value}`,
`{count}`, `{stage}`/`{stages}` and `{online}`/`{total}` are filled by the app.

Every function has, keyed by its id: `_name`, `_summary` (its card), `_what`,
`_duration`, `_affects`, `_notified`, `_risks` (optional; `risk_notice` is
always listed first), `_done`, `_description` (the lobby notice's
`{description}`), and per option `_opt_<option>` and `_opt_<option>_<choice>`
(with an optional `_desc`). `tools/test_terminal.lua` fails a row missing any.

The table below is the lines outside the functions' own:

| Key | Who reads it |
|---|---|
| `shell_boot` | At the terminal: under the boot spinner |
| `desktop_icon` | At the terminal: under the app's desktop icon |
| `window_title` | At the terminal: the browser's one tab |
| `app_title`, `address_host`, `path_*`, `aria_*` | At the terminal: the top bar, the side navigation, the first breadcrumb, the address bar, the browser's buttons |
| `search_*`, `mode_*`, `menu_*`, `nav_*` | At the terminal: the search, the light/dark switch, the user menu, the side navigation |
| `match_heading`, `field_*` and their values | At the terminal: the match panel |
| `functions_heading`, `filter_*`, `card_*`, `pref_*`, `status_*`, `risk_*`, `category_*` | At the terminal: the cards |
| `details_heading` .. `cost_line`, `risk_notice`, `run`, `confirm_*` | At the terminal: a function's page and its confirmation |
| `howto_*` | At the terminal: the how-to page |
| `unavailable` | At the terminal: why not, for a code with no line |
| `fn_offline`, `bad_option`, `no_storm`, `no_site`, `drop_busy`, `ammo_full` | At the terminal: why not |
| `no_key`, `squad_used`, `offline` | At the terminal (why not; `no_key` is also the login screen), and in the world (the Gameplay half's prompts) |
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
| `terminal_use` | A holder at a live terminal: the plate's hint, with the key cap and the ring |
| `storm_reveal_blip` | The squad that ran Storm reveal: the legend name of the final zone |

`{playername}` travels as `BR.Notice.who` (drawn bold, never formatted into the
sentence); `{description}` as plain text. `BR.TerminalSolve.line` fills both.

## The art

Every placeholder is in one block, `art` in `br_lib/config/terminals.lua`:
`keyProp` and `keyScale` (a key on the ground), `hudGlyph` (the equipped icon
and the squad panel's holder mark), `terminalProp`, `blipSprite`/`blipColour`
(the owner's 521 and 51) and `blipScale`, and `reveal` (the final zone's
sprite, colour, scale, radius and alpha). The owner's `blitz_seckey` prop and
HUD icon replace the first two.

## The functions

**ONE REGISTRY, READ BY BOTH SIDES**: `BR.Config.Terminals.functions`, each row
`{ id, category, risk, implemented, options }`, with `categories` beside it.
The server rules every run against it; br_core's client hands it to the
computer with each opening (the **catalog**), and the app draws its cards,
filters and pages from it.

- `category`: `intel`, `storm`, `disruption`, `supply` or `squad`.
- `risk`: `low`, `medium` or `high` -- how much it exposes the player who runs
  it, drawn as the card's badge.
- `implemented`: false lists the function, card and page and all, as
  `fn_offline`, and refuses its run before anything is asked or spent.
- `options`: `{ { id, choices = { ... }, default } }`. `BR.Terminal.options`
  takes a run's choices only if every key is a declared option and every value
  one of its `choices` (strings, at most 8), fills the rest with defaults, and
  refuses anything else whole (`bad_option`, nothing spent). The shell and the
  desktop shape-check them on the way too.

The server half of a built function is `BR.Terminal.FUNCTIONS[id]`
(`server/terminal.lua` for Storm reveal, `server/terminalfx.lua` for the rest):

- `refuse(src, session, opts) -> reason|nil` (optional), asked after the shared
  reasons, which come in this order: `fn_offline`, `offline`, `squad_used`,
  `no_key`. `opts` is nil while the terminal is only being listed: answer for
  ANY choice, so a card says "not here" only when no choice could run.
- `run(src, session, opts) -> { ok, code, after? }`. On `ok`, the server spends
  the key and the squad's use (`BR.Terminal.consume`), tells the lobby
  `notice_action`, then calls `after` -- so Scan's bounty toasts follow the
  redemption.

| id | Name | Category | Risk | Effect |
|---|---|---|---|---|
| `scan` | Scan | intel | high | **live** |
| `storm_reveal` | Storm reveal | intel | low | **live** |
| `storm_control` | Storm control | storm | medium | offline |
| `comms_blackout` | Comms blackout | disruption | medium | offline |
| `time_weather` | Time & weather | disruption | low | offline |
| `power_outage` | Power outage | disruption | low | offline |
| `disarm` | Disarm | disruption | high | offline |
| `supply_drop` | Supply drop | supply | medium | **live** |
| `max_ammo` | Max ammo | supply | low | **live** |
| `reboot` | Reboot | squad | medium | offline |
| `ghost` | Ghost | squad | low | offline |
| `emp` | EMP | disruption | medium | offline |
| `key_finder` | Key finder | intel | low | offline |
| `storm_delay` | Storm delay | storm | low | offline |
| `pulse` | Pulse | intel | medium | offline |
| `lockdown` | Lockdown | disruption | medium | offline |
| `contract` | Contract | disruption | medium | offline |
| `field_medic` | Field medic | supply | low | offline |

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
| `BR.Net.TERMINAL_SCAN` | S→C | `{ matchId, list = { { s, x, y, down? } } }` | Scan: every opponent's position, to the scanning squad alone (dead and spectating members included), every `fx.scanPingMs` for the rest of the match. |
| `BR.Net.TERMINAL_BOUNTY` | S→C | `{ matchId, list = { { s, x, y } } }` | Each live bounty's position, to everyone in the match outside that bounty's squad, every `fx.bountyPingMs`, and once more, empty, when the last ends. |
| `BR.Net.TERMINAL_RESULT` | S→C | `{ terminalId, functionId, ok, code, state? }` | To the runner alone. `code` is `done` on success, else a reason. |
| `BR.Net.TERMINAL_CLOSE` | S→C | `{ why }` | The session is over (death, storm, teardown). |
| `BR.Net.TERMINAL_CLOSED` | C→S | `{ terminalId, why }` | The computer went away on the client; ends only the session it names. |
| `BR.Net.TERMINAL_DEV` | S→C | `'<text>'` | A `brterminalsv` answer, printed on F8. |
| `BR.Net.TERMINAL_USE` | C→S | `{ terminalId }` | "I held interact here." Opens a session only for a living player within reach by the server's own sample, in a PLAYING match, at an online terminal; offline is refused aloud. One per `runMinIntervalMs`. |
| `BR.Net.TERMINAL_SITES` | S→C | `{ placed, removed, forced }` | The dev tools' changes, whole, to everyone, and on `br:ready`. |
| `BR.Net.TERMINAL_REVEAL` | S→C | `{ x, y, r, matchId }` | Storm reveal, to the squad that ran it alone; again on `br:ready` while that match lasts. |
| `BR.Net.YUBIKEY_STATE` | S→C | `{ held, squadUsed }` | This player's key and their squad's use, to them alone, on every change and on `br:ready`. Squadmates learn who holds a key from the squad beacon's `yubikey` bit. |

## br_core and the computer

`exports.cuchi_computer`:

| Export | Does |
|---|---|
| `Open(state, copy, catalog) -> ok, why` | Shows the desktop and the app, takes NUI focus (keyboard and cursor). Refuses with `page-not-ready` before the page has loaded, rather than take focus over nothing. Opening another terminal while one is open closes the first (`replaced`). `catalog` is `{ functions, categories }`, the registry. |
| `Update(state)` | The new state, while open on that terminal: after a run, and once a second (TERMINAL_INFO). |
| `Result(result)` | `{ functionId, ok, code }`, while open. |
| `Close(why) -> ok` | Takes it down and releases focus. |
| `IsOpen() -> boolean` | |

Local events it raises for `br_core`'s client (never net events):

| Event | Args | When |
|---|---|---|
| `cuchi_computer:opened` | `terminalId` | Focus taken |
| `cuchi_computer:request` | `terminalId, { action = 'run', functionId, options }` | The page asked; the terminal is the one `br_core` opened; `options` shape-checked |
| `cuchi_computer:closed` | `terminalId, why` | Focus released: `escape`, `exit` (the power button), `page`, `replaced`, `opener-stopped`, `stopped`, or `br_core`'s own why |

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
| app → desktop | `{ type: 'ready' }`, `{ type: 'run', functionId, options? }`, `{ type: 'escape' }`, `{ type: 'mode', mode }` |
| desktop → app | `{ type: 'state', state, copy?, catalog? }` (copy and catalog on open and on ready; an update is the state alone), `{ type: 'result', result }` |

The app is loaded when the computer opens and unloaded when it closes. Escape,
on the desktop or inside the app, closes the computer -- unless a dialog or an
open dropdown in the app takes it first (the app reads it in the capture phase).

### A web browser, not a terminal (owner, 2026-10-05)

**The frame is the desktop's.** `cuchi_computer/nui/br.css` restyles upstream's
window title bar -- no markup changed -- into a tab strip: one tab with the
app's icon and `window_title`, and drawn minimize/close controls. The window is
1440x880 (BR-PATCH 5), capped at 98vw x 92vh. The tab follows the app's
light/dark mode (`mode` -> `br-light` on the window).

**The toolbar is the app's** (`Browser.tsx`): back, forward and reload over the
app's own history, and a read-only address bar whose fictional URL follows the
page (`https://terminal.blitz/functions/supply-drop`). It lives in the app
because the history and the address are the app's navigation; a copy in the
desktop would be a second state kept in step over postMessage. Reload asks the
desktop for everything again (`ready`) and remounts the page.

**The site** (Cloudscape, like the cards and details examples): TopNavigation
with the app's name, a search across every function (pick one to open it, or
search the cards), the light/dark switch, and the gamertag as the signed-in
user (its menu: How to, Sign out); AppLayout with SideNavigation (Functions,
How to, each category) and a BreadcrumbGroup on every page; the functions page
(the match panel over the cards, with a text filter, pagination and
preferences), a page per function (details, what it does, its options as
RadioGroups, its risks, Run behind a confirmation), the how-to page, and the
login screen when the computer opened without a key. The mode is applied on
`<body>` only and remembered per gamertag in the page's localStorage.
`ui-src/scripts/check-terminal.mjs` holds #385's findings over it.

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

`sites` in `br_lib/config/terminals.lua` is empty until the owner places them
(`brterminal place` prints each row). A terminal is **online only inside the
storm's current zone**, by its real shape; before there is a storm everything is
inside it.

- **Its prop** is local to each client, within 150 m.
- **Its blip** shows only while this player holds a key, only for an online
  terminal, and only in a match (from the bus on).
- **Its plate** (the shared prompt browser) reads `terminal_label` over one
  of four hints:
  - `terminal_use`: the hold opens the computer;
  - `no_key`: it opens too, every function `no_key`;
  - `squad_used`;
  - `offline`: nothing to hold.
- **Holding interact** for `holdMs` sends TERMINAL_USE.

## The rules, server-side

1. **A use** opens a session only for a living player within reach, by the
   server's own sample, in a PLAYING match, at an online terminal.
2. **Access** is a key and a squad that has not spent its use. The lobby (the
   whole match) hears `notice_access` once per player per match.
3. **A run** is refused, in this order, `offline`, `squad_used`, `no_key`, then
   the function's own reason.
4. **When it runs**: the key is spent, the squad's ONE use this match is spent
   (a solo player is a squad of one), the lobby hears `notice_action`, and the
   squad is told its use is gone. The squad's other holders are refused
   `squad_used` and keep their keys.
5. **Every fact is read from the world on every ask.** A session closes when its
   player goes down, dies, leaves, walks away or the storm takes the terminal:
   on a 500 ms check, and again inside every run.

## Storm reveal

`BR.Storm.finalCentre(m)` walks the phases the storm has not drawn yet, against a
copy of the match's storm stream, so asking never moves the real one;
`tools/test_storm.lua`'s `server.final` holds it exact at every phase. The answer
goes to the squad that ran it and nobody else (`TERMINAL_REVEAL`). It is drawn
as a radius blip and a sprite on both maps until the trip back to the lobby. With
nothing to reveal (no storm stream yet) the function is `unavailable` and spends
nothing. A dev `brphase` or `brstormfreeze` after a reveal ends the storm
somewhere else.

## Dev

Every one is dev-mode only, Season 2 only (`brseason 2` on a dev box at Season
1), and runs on the server as `brterminalsv`:

| Command | Does |
|---|---|
| `brterminal [nokey] [used] [offline]` | The computer anywhere, on a dev terminal whose facts are those words -- the app alone |
| `brterminal close` | Close it |
| `bryubikey [give or take]` | A key for yourself, or yours taken: the real profile write and messages |
| `brterminal place [id]` | A terminal where you look (or on the ground ahead), facing you; prints the config row |
| `brterminal remove <id>` | Out of play for this session (a config row stays in the file) |
| `brterminal list` | Every terminal, and whether your match has it online |
| `brterminal online <id> [off]` | Force one online whatever the storm, or hand it back |
| `brterminal reset` | Your squad's use this match, unspent |
| `brterminal run <function> [option=choice ...]` | The function's effect for you: no key, no terminal, no notice, nothing spent; the options through `BR.Terminal.options` |

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
