# Blitz Royale

A battle royale gamemode for FiveM. Drop from a flying bus onto Los Santos, loot,
and outlast a shrinking storm until one squad is left.

> **Work in progress.** The match loop is complete and plays end to end, but this
> has not been released and is not yet running on a public server. See
> [Status](#status) for exactly what works today.

The gamemode is **Blitz Royale**; the repository and much of the source still say
"FiveM Royale". That is a rename in progress, not two projects. It landed on the
player-visible surfaces first (the loading screen and the player manual) because
those need no build step; the in-game NUI strings live in a committed bundle
guarded by the drift gate, so they change together with a `ui-src` rebuild.

Built with Lua on both client and server, and a React NUI for the interface.
Everything uses stock GTA V assets — no custom models, maps, or streamed files.

---

## Status

| Milestone | What it covers | State |
|---|---|---|
| M0 | Resources, build pipeline, verification tooling, debug commands | **DONE** |
| M1 | Authoritative roster, scope-safe broadcast, match state machine, clock sync | **DONE** |
| M2 | Persistent parties, squad formation, autofill, lobby UI | **DONE** |
| M3 | Battle Bus, skydive, glider, end-of-match choreography | **DONE** |
| M4 | The storm — anchor, phases, damage, rendering | **DONE** |
| M5 | Loot spawning, pickups, 5-slot inventory | **DONE** |
| M6 | Combat, damage validation, kill attribution | **DONE** |
| M6b | UI overhaul — lobby, HUD, inventory, end screen | **DONE** |
| M7 | DBNO, revives, spectating, match summary, stats | **DONE** |
| M7b | Persistence off the game host — DynamoDB / AWS serverless | **DONE** |
| M8 | Vehicles, aerial supply drops, fuel, rescue | **SCOPING** |
| M9 | Moderation console, in-game reports, admin ACEs, incident logging | **WIP** |

**Working now:** the loop, end to end. Players queue from a lobby above Cayo
Perico, form persistent parties, and warm up on the island airstrip while the
match's flight route is drawn on the map. Several matches run at once in separate
routing buckets, sharing the warmup pad and watching each other's flights take
off. The Battle Bus flies an authored tour over Los Santos and everyone skydives
out wherever they choose. On the ground there is loot: weapons, ammo, shields,
throwables and chests scattered across 107 points of interest and along the
highways between them, streamed to each client cell by cell as they move. When
the last player lands, the match goes live and the storm starts — a shrinking
circle homed on a point of interest near the flight path, with a rendered wall,
map circles, screen effects and server-authoritative damage. Squad members who
run out of health go down rather than dying outright: they crawl, a bleed clock
runs, and a squadmate can pick them up on a held key — more than once in a match,
though each knock is shorter than the last. Once eliminated they spectate the
rest of the match. Deaths (storm included) leave a lootable box, placements are
assigned, and a match ends with a victory/elimination sequence, a summary screen,
and XP and Volts written to DynamoDB.

**Damage is server-authoritative.** The server refuses impossible shots and
computes the damage itself from our own weapon table, including per-body-part
multipliers, and an evidence and incident layer sits on top of it — the server
keeps a rolling buffer of what it saw and files a case when the numbers do not
add up. See [Cheat resistance](docs/security.md).

**Progression is live.** Matches pay XP and Volts, Volts buy cosmetics from a
market, and the whole economy is config rather than code. See
[XP and Volts](docs/progression.md).

**Proximity voice** runs over Mumble/pma-voice, scoped so that squadmates hear
each other and nearby strangers are audible at range.

**In flight (M9):** moderation. The game-side half is built — an in-game player
list with reports, admin ACEs, incident filing, a maintenance and drain gate, and
branch switching from the console. The console itself is a separate repository
(`fivem-ringmaster`); neither side is deployed yet. The two talk over one
versioned contract, pinned by fixtures both repos test against, so each can be
built and verified with the other absent.

**Accurate reports are paid for.** When a case a player filed is resolved by an
admin and an action follows, that player and every corroborator are credited 250
Volts — hours or days later, across any number of restarts, because the debt is
queued in DynamoDB rather than in memory, and exactly once, because the credit
and its receipt are the same conditional write. See
[XP and Volts](docs/progression.md).

**Not working yet:** vehicles are ambient traffic only — no supply drops, fuel or
rescue (M8).

---

## Architecture

Eight resources under `resources/[fivem-royale]/`, started in this order by
[`server.cfg.example`](server.cfg.example):

| Resource | Runtime | Responsibility |
|---|---|---|
| `br_lib` | No | Shared config, enums, protocol constants, geometry, seeded RNG, storm solver. Consumed via `shared_scripts { '@br_lib/...' }`, which loads files into each consuming resource's own Lua state — zero runtime cost, no exports. |
| `br_core` | Yes | All gameplay, client and server. One Lua state, one loop registry. |
| `br_environment` | Yes | World state: IPL loading and the Cayo Perico lobby island (home of the pre-match lobby; released back to the streamer once a match is live). Will grow into the streamed-asset container. |
| `br_ui` | Yes | The NUI page and the only file that touches `SetNuiFocus`. |
| `br_loadscreen` | Yes | The loading screen. Shuts down manually rather than on a timer: `br_core` holds it open until the world is genuinely ready and choreographs the handoff onto the lobby's identical backdrop. |
| `br_ddb` | Yes | The only path to DynamoDB — ban checks at connect, grants, profiles, stats, and filing incidents. Runs on Node 22 rather than FXServer's bundled Node, which the AWS SDK bundle requires. |
| `br_stats` | Yes | Match results, XP and Volts, persisted to DynamoDB through `br_ddb`. Degrades to "no stats" rather than taking the match down. |
| `br_ringmaster` | Yes | The game-side half of the moderation console: pushes state out and executes admin verbs. Server-only by design — nothing here ever puts a pixel on a player's screen. |

Two of those declare only `br_lib`, and the omissions are deliberate.
`br_ringmaster` refuses `dependency 'br_core'`: declaring it would make
moderation refuse to start when the gamemode is down, and the `restart br_core`
that every deploy ends with would take the moderation channel with it.
`br_stats` refuses `dependency 'br_ddb'` for the same shape of reason — a server
with no database should play perfectly well, and `persist.lua` checks the
resource state and says so once per match instead. Both degrade to "no live
state" rather than to "not running".

The UI build project lives in `ui-src/`, **outside** `resources/`, because
FXServer auto-builds any resource containing a `package.json` using bundled Node
16 — and this toolchain needs Node 20+. Build output is committed, so the server
never builds anything.

### Three decisions worth knowing

**The server owns everything.** Under OneSync a client only sees players within
scope, so two players 3 km apart do not exist to each other. Any client-side
attempt to count who is alive is correct while everyone is bunched at the drop
and wrong for the rest of the match. All roster state lives on the server and
reaches clients through explicit broadcasts. `tools/verify.sh` fails the build if
a scope-limited native appears in client code without an explicit `-- scope-ok:`
marker.

**Three client loops, not thirty.** Every client subsystem registers a callback
into one of three loops (per-frame, 10 Hz, 1 Hz) rather than spawning its own
thread. Because gameplay is one resource, `resmon` can't attribute cost per
subsystem — so the registry measures each callback itself.

**Loot is client-rendered and server-owned.** ~3,370 items as networked entities
would not survive contact with a real server. The server generates the layout
from a seeded RNG and holds it as plain data; clients are streamed the entries
near them, render local non-networked props (`CreateObjectNoOffset` with
`isNetwork = false`), and ask the server to claim one. The seed itself never
leaves the server — a client that could derive the layout would know where
every item on the map is.

---


## Deeper reading

The detail lives alongside the code rather than in one wall of text here.
Each of these stands on its own:

| Document | What is in it |
|---|---|
| **[Terminology](docs/terminology.md)** | The words the code, the logs and the commit history use — roster, mirror, digest, scope gate, cell, husk, ledger — and what each one actually is. Read this first if you are reading the source. |
| **[Generated systems](docs/generation.md)** | How loot layouts, flight routes and storm circles are produced, **with the formulas**. Seeds, budgets, rejection sampling, and why every walk is over an array rather than a hash. |
| **[The arithmetic of a match](docs/match-math.md)** | Every number a match is built from and why it is that number — seeds, the flight chord, storm phases and pacing, breakout geometry, loot budgets and rarity, and the full damage formula. |
| **[Cheat resistance](docs/security.md)** | Why the client is never the authority on anything that decides a match. The three layers, a table of concrete attacks and why each fails, and an explicit statement of what this is *not*. |
| **[XP and Volts](docs/progression.md)** | The two currencies, what pays them, and the level curve. Both are computed at the end of a match and applied in a single atomic write. Tuning, not architecture — every number is a config edit. |
| **[Running and developing](docs/running.md)** | Server setup, the UI build, `tools/verify.sh`, and the in-game diagnostic commands. |
| **[Deploying](DEPLOY.md)** | Standing the server up on Ubuntu against standard FXServer Linux artifacts. |
| **[Testing](docs/testing.md)** | The suites and gates, when to run them, the rules that keep them honest, and the real bugs each one has caught. |
| **[Platform constraints](docs/platform.md)** | FiveM and CEF behaviours discovered the hard way — the ones that cost days — and what each one taught. |

The moderation half has its own contracts, because two repositories have to agree
on them without either being able to call the other:

| Document | What is in it |
|---|---|
| **[The ban contract](docs/ban-contract.md)** | The row schema, and why the console and the game server deliberately hold two separate implementations of the same check rather than sharing one. |
| **[The ingest envelope](docs/ingest-envelope.md)** | The only contract between the two repos — what the game sends, what the console promises back, and the fixtures both sides test against. |
| **[Branch switching](docs/branch-switch.md)** | Deploying a branch other than `main` to the live host from the console, with nobody on the box. |

---

## Licence

Not yet chosen. Until one is added, no permissions are granted beyond viewing.
