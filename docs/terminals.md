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
| **The app** | `ui-src/terminal`, built into `cuchi_computer/nui/apps/terminal` | React + Cloudscape, in the desktop's one window (an iframe). Renders the state, asks to run. Decides nothing. |

Around them, the Gameplay half:

| Piece | Where | Its job |
|---|---|---|
| **The key** | `br_core/server/yubikey.lua` | Who holds a Yubikey, on the profile row through br_ddb (`yubikey`, `yubikeySeen`); every way one changes hands. |
| **The world** | `br_core/client/yubikey.lua` | Each terminal's local prop, blip and plate; the hold that asks to open one; the key's HUD glyph; Storm reveal on the maps. Decides nothing. |
| **The shared rules** | `br_lib/shared/terminal_solve.lua` | Online against the storm, the squad's key, the sites list, the notice tokens, the extra roll -- one spelling for both sides. |

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
  functions  = {                 -- in BR.Config.Terminals.functions order
    { id = 'storm_reveal', available = true },
    { id = 'scan', available = false, reason = 'squad_used' },
  },
  keyHeld    = true,             -- this player holds a Yubikey
  squadUsed  = false,            -- their squad has used its one key this match
}
```

`reason` is a code, and a code is a key into the copy: `no_key`, `squad_used`,
`offline`, or any key a function's own refusal adds. The app shows the line for
the code, or `unavailable` when there is none.

## The copy

**Every player-facing line is in one block**, `copy` in
`br_lib/config/terminals.lua`, and every value is a placeholder until the owner
writes it. The desktop and the app render keys out of it and nothing else: a key
with no line renders as nothing, never as the key. `br_core`'s client hands the
whole block to the computer with each opening (the client already has it, so it
never crosses the network). Changing a line is an edit there and a restart.

| Key | Who reads it |
|---|---|
| `shell_boot` | At the terminal: under the boot spinner |
| `desktop_icon` | At the terminal: under the app's desktop icon |
| `window_title` | At the terminal: the app's window title bar |
| `app_heading` | At the terminal: over the function list |
| `<id>_name` | At the terminal: the function's name in the list |
| `available` | At the terminal: the status of a function that can run |
| `unavailable` | At the terminal: why not, for a code with no line |
| `run` | At the terminal: the button |
| `<id>_done` | At the terminal: after the server ran it |
| `no_key`, `squad_used`, `offline` | At the terminal (why not), and in the world (the Gameplay half's prompts) |
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

`BR.Config.Terminals.functions` lists the ids, in order. The server half is
`BR.Terminal.FUNCTIONS[id]` in `br_core/server/terminal.lua`:

- `refuse(src, session) -> reason|nil` (optional), asked after the shared
  reasons, which come in this order: `offline`, `squad_used`, `no_key`.
- `run(src, session) -> { ok, code }`. On `ok`, the server spends the key and
  the squad's use (`BR.Terminal.consume`).

A new function is a row in the config, an entry in that table, and its
`<id>_name` and `<id>_done` lines. `tools/test_terminal.lua` fails a listed id
missing any of the three.

## The wire

| Event | Way | Payload | Rule |
|---|---|---|---|
| `BR.Net.TERMINAL_OPEN` | S→C | `{ state }` | Open the computer on this terminal. |
| `BR.Net.TERMINAL_RUN` | C→S | `{ terminalId, functionId }` | Dropped, unanswered, without an open session on that terminal, with a malformed id, or sooner than `runMinIntervalMs` after the last. |
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
| `Open(state, copy) -> ok, why` | Shows the desktop and the app, takes NUI focus (keyboard and cursor). Refuses with `page-not-ready` before the page has loaded, rather than take focus over nothing. Opening another terminal while one is open closes the first (`replaced`). |
| `Update(state)` | The new state, while open on that terminal. |
| `Result(result)` | `{ functionId, ok, code }`, while open. |
| `Close(why) -> ok` | Takes it down and releases focus. |
| `IsOpen() -> boolean` | |

Local events it raises for `br_core`'s client (never net events):

| Event | Args | When |
|---|---|---|
| `cuchi_computer:opened` | `terminalId` | Focus taken |
| `cuchi_computer:request` | `terminalId, { action = 'run', functionId }` | The page asked; the terminal is the one `br_core` opened |
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
| app → desktop | `{ type: 'ready' }`, `{ type: 'run', functionId }`, `{ type: 'escape' }` |
| desktop → app | `{ type: 'state', state, copy }`, `{ type: 'result', result }` |

The app is loaded when the computer opens and unloaded when it closes. Escape,
on the desktop or inside the app, closes the computer.

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
| `brterminal run <function>` | The function's effect for you: no key, no terminal, no notice, nothing spent |

From the server console, a verb about a player takes the id next:
`brterminalsv open <player id> [...]`, `brterminalsv key <player id> give`.
