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
| M8 | Vehicles, aerial supply drops, fuel, rescue | **DONE** |
| M9 | Moderation: incidents, in-game reports, artifacts, admin ACEs, the in-game console | **DONE** |
| M10 | Finishing touches: feature requests gathered after M8, and a security audit of both repos | **WIP** |

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
add up. **One** high-severity refusal opens a case, or **two** normal ones; the
count is per match and does not lapse. A second source feeds the same pipeline: a
weapon the gamemode never issued is taken out of the ped's hand *and recorded*,
and nobody is exempt from that, admins included. See
[Cheat resistance](docs/security.md).

**Progression is live.** Matches pay XP and Volts, Volts buy cosmetics from a
market, and the whole economy is config rather than code. See
[XP and Volts](docs/progression.md).

**Proximity voice** runs on pma-voice, vendored whole under `resources/[voice]/`.
The three modes are **exclusive, not layered**: `nearby` is proximity and only
proximity, out to 25 m; `squad` is the radio and only the radio, at any distance;
`off` is neither. Push-to-talk is one of our own keybinds, rebindable on our own
settings screen like every other key.

> **This paragraph used to read "scoped so that squadmates hear each other and
> nearby strangers are audible at range".** That was the layered reading, and it
> is corrected rather than quietly edited because it is the sentence somebody
> would quote to conclude that picking `squad` keeps proximity. It does not: #157
> made the modes exclusive on the owner's instruction — "Nearby should only be
> nearby, different from squads and not additional to it" — so a squad player no
> longer hears the stranger they are fighting, and a `nearby` player gets no
> special case for a squadmate across the island.

**Moderation (M9):** the game's half of it runs end to end.
The anticheat and the in-game player list both file real rows in DynamoDB rather
than logging and forgetting, and a case carries three things beyond the finding
itself:

* **Artifacts** — screenshots of the subject's own screen, taken through
  `screenshot-basic` and uploaded straight to S3 under the game box's own
  instance role, where they expire after 180 days. Three timed frames at 0, +5s
  and +10s from the filing, then one more per corroboration arriving after that
  window, to a cap of nine. **They are the game's 3D render only** — NUI and the
  HUD are composited afterwards and never appear in a frame. An empty or partial
  set is the normal outcome and is not evidence of anything: the capture happens
  on the subject's machine, which can disconnect, crash or alt-tab.
* **A match timeline** — the match around the case. Start, every kill the subject
  landed with the weapon that did it *and whether it is a weapon this gamemode
  issues*, every weapon strip, end. The issued/not-issued call is resolved here,
  on the server, because a second copy of that table in another repository is a
  copy that drifts.
* **An admin console nobody leaves the game for** — Ringmaster opens in the pause
  menu, already signed in, over a one-use handoff token, so an admin never types
  a password into the game. The origin is the `br_adminConsoleUrl` convar, and
  unset is the default: no tab, no HTTP call, no mention anywhere but one line in
  the boot banner.

The rest of the game-side half is as it was: admin ACEs, a maintenance and drain
gate, and branch switching from the console. The console itself is a separate
repository (`fivem-ringmaster`). The two talk over one versioned contract, pinned
by fixtures both repos test against, so each can be built and verified with the
other absent — and the handoff above is the only place the game asks the console
for anything and waits, licensed by the fact that failure there costs an iframe
and nothing else.

**Accurate reports are paid for.** When a case a player filed is resolved by an
admin and an action follows, that player and every corroborator are credited 100
Volts — hours or days later, across any number of restarts, because the debt is
queued in DynamoDB rather than in memory, and exactly once, because the credit
and its receipt are the same conditional write. See
[XP and Volts](docs/progression.md).

> **The bounty has been three numbers and 100 is the only one anybody chose for
> it.** It shipped at the 250 the owner first asked for, then halved to 125 on
> 2026-08-20 along with every match-payout number, under an instruction — "cut
> all Volts earnings by 50%" — that was given about a playtest and so about the
> match payout. That made it collateral rather than a decision, which is what
> #256 raised. The owner set 100 outright on 2026-09-02, so it is now a fixed
> bounty on a moderation outcome and not a fraction of anything the market pays.

**In flight (M10):** finishing touches — the feature requests gathered after M8,
and a security audit of both repos now that they are public. Landed so far: the
warmup vehicle showroom, squad revive keys with a network of station ambulances,
and a Discord card gated on real guild membership. Queued: a guided first run for
new players, a repair kit, and in-game bug reports.

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
| `br_ddb` | Yes | The only path to AWS — ban checks at connect, grants, profiles, stats and filing incidents in DynamoDB, and putting artifact frames in S3. Runs on Node 22 rather than FXServer's bundled Node, which the AWS SDK bundle requires. |
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

**One more resource is started, and it is not ours.**
`resources/[voice]/pma-voice` is
[pma-voice](https://github.com/AvarianKnight/pma-voice) v7.0.2-rc3 (MIT,
© Dillon Skaggs), vendored whole rather than installed: every byte outside a
declared `BR-PATCH` block is identical to the upstream tag, `VENDOR.json` records
the provenance, and `tools/verify.sh` gates that the licence is present, that
every patch marker in the tree is declared and every declared patch is in the
tree, and that `tools/deploy.sh` actually syncs it. It owns the voice engine.
`br_core/client/voice.lua` expresses our rules through it and calls exactly one
Mumble native — a read, driving the talking indicator. Every setter is gone.

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
| **[Vehicle data overrides](docs/vehicle-data.md)** | Which weapons a vehicle seat accepts, the playtest that proved a resource cannot change it, and the template for folding an add-on vehicle's own `vehiclelayouts.meta` in. |

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
