# The dev menu

A menu in the gun shop's UI, on a dev-mode server only, over the console
commands a playtest leans on (#422). F10 or `/brdev` opens it. This page is
the contract: who may use it, what each row runs, and what it writes.

[← Back to the main README](../README.md)

---

Owner, 2026-10-24: *"What I need now is a dev-only menu using the same UI as
our gun store. It should control things like time, weather, match state, give
volts, give Yubikeys, Storm pause, warmup pause, spawn airdrops"*

| Piece | Where | Its job |
|---|---|---|
| **The words and the lists** | `br_lib/config/devmenu.lua` (`BR.Config.DevMenu`) | The labels, the key, the Volts amounts and the match states. Read by both sides. |
| **The client** | `br_core/client/devmenu.lua` | The menu, built once through `BR.Menu` (`client/menu.lua`), the key, and one `brdevsv` line per press. Decides nothing. |
| **The server** | `br_core/server/devmenu.lua` (`BR.DevMenu`) | The door, `brdevsv`: the gate, the checks, the rate, and the console verb each row runs. |

## Who

**Anyone on a dev-mode server**, and nobody anywhere else. Every press is the
server command `brdevsv`, run from the client with `ExecuteCommand` (the
`brprop` route), so two gates stand in front of every request:

- `br_lib/shared/devgate.lua`'s wrap: `sv_devMode` or `br_devMode`, read when
  the request arrives;
- `BR.DevMenu.allowed()`: `BR.Server.devMode == true`, what br_core started as.
  Dev mode switched on live, without restarting br_core, is not dev mode here.

On a server without dev mode the request is refused with one line on the
server console and has no other effect. `/brdev` prints the dev-mode line on
F8 and opens nothing, and **F10 is not mapped at all**: a key mapping cannot be
taken back, so the client maps it the first time it reads dev mode on, and the
public box's binding list never shows it. F10 is a default the player can move
in FiveM's key bindings.

## The rows

Each row runs the console command's own body, factored out so the command and
the menu call one piece of code.

| Row | Value | Runs | Acts on |
|---|---|---|---|
| Time | `00:00`-`23:00`, Reset | `brtime` (`BR.WorldSky.setTime`) | the session's clock override, everyone |
| Weather | the fifteen weathers, Reset | `brweather` (`BR.WorldSky.setWeather`) | the session's sky override, everyone |
| Match state | `waiting` `warmup` `bus` `playing` `ended` `cleanup` `skip` | `brforce` (`BR.Match.force`), `brskip` (`BR.Match.skip`) | **the asker's match** |
| Player | the connected players, yourself first | -- | who the next two give to |
| Give volts | 100, 500, 1,000, 5,000, 10,000 Volts | `brvolts` (`BR.Debug.grantVolts`) | that player's stored profile |
| Give Yubikeys | -- | `brterminalsv key give` (`BR.Terminal.devKey`) | that player's stored profile; one at most, Season 2 |
| Storm pause | on / off | `brstormfreeze` (`BR.Storm.setFrozen`) | every live storm, and the next to start |
| Warmup pause | on / off | `brwarmupfreeze` (`BR.Match.setWarmupFrozen`) | every open warmup, and the next to open |
| Spawn airdrops | -- | `brairdrop now` (`BR.Airdrop.dropNow`) | **the asker's match**; PLAYING only |

**The asker's match, never the newest.** Matches run side by side in their own
routing buckets, and the console commands aim at `BR.Server.latestMatch()`.
Match state and Spawn airdrops take `BR.Server.matchOf(asker)`. From the
lobby, a forced state forms a match from the queue, as `brforce` does with no
match; `waiting` and `skip` say there is no match. Time, weather and the two
pauses are one setting for the whole session in their commands, with no match
to aim at, so the menu does what the command does.

A refusal is the command's own sentence (`airdrops only run during PLAYING
(match … is warmup)`, `1: already holds one`, `no match running`), sent to the
player who pressed as a warning toast and printed on their F8. A success is a
line on F8 only. After every answer the server sends the rows back, so a pause
box the library flipped is put right if the request did not take.

## What the server checks

Every word, against the lists the rows are built from: an hour 0-23 or
`reset`; a weather of `BR.World.WEATHERS` or `reset`; a state of
`BR.Config.DevMenu.states`; an amount of `BR.Config.DevMenu.volts`; a target
that is a connected player who has not left; `on` or `off`. Anything else is a
request no row could have sent, and it is dropped with the usage line on F8. A
request inside `minIntervalMs` (250 ms) of the last one taken from that player
is dropped too, and the rows are sent back so a pause box shows the truth. The server console cannot use `brdevsv`; its commands are the
console verbs themselves.

## The profile store

Give volts and Give Yubikeys write stored profiles through br_ddb. **On a
dev-mode server those are the `dev-` tables**: br_ddb forces every table it
names to `dev-br-*` and `dev-ringmaster-*` whenever `sv_devMode` or
`br_devMode` is on, and ignores the prefix convars while it does
(`js-src/br_ddb/src/prefix.js`; [DEPLOY.md](../DEPLOY.md), "A dev box uses
`dev-` tables"). Those are the convars both gates above read, so the menu
writes `dev-br-players` and never `br-players`. Both rows are on.

The one way round it is outside the menu: br_ddb resolves its prefix once, at
its own start. Dev mode turned on live and only br_core restarted would leave
br_ddb on the production tables with the menu's second gate open. `brvolts`
on the console has the same exposure. Restart the whole server, not one
resource, to change a box's dev mode.

## Tests

`tools/test_devmenu.lua`: the server door behind the real `devgate.lua` (off,
started-off, `== true`, console, strangers), every argument, every row's
dispatch with the asker's match, refusals as toasts, the pushed rows and the
rate; the client over the real `client/menu.lua` (the labels in order, no
descriptions, F10 mapped once and only on dev mode, every row's line, the
answer applied in place, names stripped of GTA's text codes); and every line
the rows can type, taken by the server. The verbs' bodies are covered where
their commands are: `test_roster` (force and skip on a given match),
`test_airdrop` (`dropNow` on a given match), `test_stats`
(`grantVolts`'s answers), `test_yubikey` (`devKey`), `test_shared`,
`test_storm`.
