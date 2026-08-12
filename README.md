# FiveM Royale

A battle royale gamemode for FiveM. Drop from a flying bus onto Los Santos, loot,
and outlast a shrinking storm until one squad is left.

> **Work in progress — pre-alpha.** This is not playable yet and not ready to run
> on a public server. The foundations are in and verified; most of the game is
> not. See [Status](#status) for exactly what works today.

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
| M6 | Combat, damage validation, kill attribution | **WIP** |
| M6b | UI overhaul — lobby, HUD, inventory, end screen | **WIP** |
| M7 | DBNO, revives, spectating, match summary, stats | **PLANNED** |
| M7b | Persistence off the game host — DynamoDB / AWS serverless | **PLANNED** |
| M8 | Vehicles, aerial supply drops, fuel, rescue | **SCOPING** |
| M9 | Moderation web UI, Discord webhook, in-game reports, admin ACEs, logging | **SCOPING** |

**Working now:** the loop, end to end, minus validated gunplay. Players queue
from a lobby above Cayo Perico, form persistent parties, and warm up on the
island airstrip while the match's flight route is drawn on the map. Several
matches run at once in separate routing buckets, sharing the warmup pad and
watching each other's flights take off. The Battle Bus flies an authored tour
over Los Santos and everyone skydives out wherever they choose. On the ground
there is loot: weapons, ammo, shields, throwables and chests scattered across
105 points of interest and along the highways between them, streamed to each
client cell by cell as they move. When the last player lands, the match goes
live and the storm starts — a shrinking circle homed on a point of interest
near the flight path, with a rendered wall, map circles, screen effects and
server-authoritative damage. Deaths (storm included) leave a lootable box,
placements are assigned, and a match ends with a victory/elimination sequence
back to the lobby.

**In flight (M6):** damage is now validated and applied server-side -- the
server refuses impossible shots and computes the damage itself from our own
weapon table, including per-body-part multipliers. See
[Cheat resistance](docs/security.md).

**Not working yet:** no downed state or revives, no spectating, no persistent
stats. Vehicles are ambient traffic only.

---

## Architecture

Four resources under `resources/[fivem-royale]/`:

| Resource | Runtime | Responsibility |
|---|---|---|
| `br_lib` | No | Shared config, enums, protocol constants, geometry, seeded RNG, storm solver. Consumed via `shared_scripts { '@br_lib/...' }`, which loads files into each consuming resource's own Lua state — zero runtime cost, no exports. |
| `br_core` | Yes | All gameplay, client and server. One Lua state, one loop registry. |
| `br_environment` | Yes | World state: IPL loading and the Cayo Perico lobby island (home of the pre-match lobby; released back to the streamer once a match is live). Will grow into the streamed-asset container. |
| `br_ui` | Yes | The NUI page and the only file that touches `SetNuiFocus`. |
| `br_stats` | Yes | Match results and XP, persisted to DynamoDB through `br_ddb`. Degrades to "no stats" rather than taking the match down. |

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

**Loot is client-rendered and server-owned.** ~1900 items as networked entities
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
| **[Running and developing](docs/running.md)** | Server setup, the UI build, `tools/verify.sh`, and the in-game diagnostic commands. |
| **[Testing](docs/testing.md)** | The suites and gates, when to run them, the rules that keep them honest, and the real bugs each one has caught. |
| **[Platform constraints](docs/platform.md)** | FiveM and CEF behaviours discovered the hard way — the ones that cost days — and what each one taught. |

`PLAN.md` (untracked, local) carries the working milestone log.

---

## Licence

Not yet chosen. Until one is added, no permissions are granted beyond viewing.
