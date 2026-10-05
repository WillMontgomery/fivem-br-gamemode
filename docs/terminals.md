# The terminals' contract

Season 2's computer terminals (#396): how `br_core` opens the computer, what it
shows, and how a request to run a function gets to the server and back.

[← Back to the main README](../README.md)

---

Four pieces, in three places. Each knows only its neighbors.

| Piece | Where | Its job |
|---|---|---|
| **The server door** | `br_core/server/terminal.lua` | Opens a session for a player on a terminal, lists the functions, takes a run only inside that session, decides it, answers. |
| **br_core's client** | `br_core/client/terminal.lua` | Opens and closes the computer when the server says, relays run requests up and answers down, tells the key layer when the computer holds the keyboard. |
| **The computer** | `resources/[computer]/cuchi_computer` | Vendored, cut-down [cuchi_computer](https://github.com/Cu-chi/cuchi_computer) (GPL-3.0). `client/shell.lua` holds NUI focus while the desktop is up and forwards what the page asks; `nui/br.js` drives the desktop. Decides nothing. |
| **The app** | `ui-src/terminal`, built into `cuchi_computer/nui/apps/terminal` | React + Cloudscape, in the desktop's one window (an iframe). Renders the state, asks to run. Decides nothing. |

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
| `first_pickup`, `already_holding` | The Gameplay half: the Yubikey's first pickup, and a second refused |
| `notice_access`, `notice_action` | The Gameplay half: to the lobby, on access and on the action |

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

## Dev

`brterminal [nokey] [used] [offline]` opens the computer anywhere, on a dev
terminal whose facts are those words (a key and nothing against it by default).
`brterminal close` closes it. Both run on the server as `brterminalsv`. Dev mode
only, and Season 2 only (`brseason 2` on a dev box at Season 1).

## What the Gameplay half replaces

The dev session's facts are typed. A real terminal answers them from the world,
in `br_core/server/terminal.lua`: `BR.Terminal.facts` (the key on the profile,
the squad's use this match, the terminal against the safe zone),
`BR.Terminal.consume` (spend them), the Storm reveal's `run`, and a session
opened by walking up to a terminal instead of by the dev command. Everything
else in this document stays.
