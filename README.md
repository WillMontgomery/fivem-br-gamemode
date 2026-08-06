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
| M0 | Resources, build pipeline, verification tooling, debug commands | **Done** |
| M1 | Authoritative roster, scope-safe broadcast, match state machine, clock sync | **Done** |
| M2 | Persistent parties, squad formation, autofill, lobby UI | **Done** |
| M3 | Battle Bus, skydive, glider, end-of-match choreography | **Done** |
| M4 | The storm — anchor, phases, damage, rendering | **Done** — in-game gate passed |
| M5 | Loot spawning, pickups, 5-slot inventory | **Code complete** — in-game gate pending |
| M6 | Combat, damage validation, kill attribution | Not started |
| M7 | Downed state and revives | Not started |
| M8 | Spectating, match summary, round flow | Not started |

**Working now:** the loop, end to end, minus validated gunplay. Players queue
from a lobby above Cayo Perico, form persistent parties, and warm up on the
island airstrip while the match's flight route is drawn on the map. Several
matches run at once in separate routing buckets, sharing the warmup pad and
watching each other's flights take off. The Battle Bus flies an authored tour
over Los Santos and everyone skydives out wherever they choose. On the ground
there is loot: weapons, ammo, shields, throwables and chests scattered across
~49 points of interest and along the highways between them, streamed to each
client cell by cell as they move. When the last player lands, the match goes
live and the storm starts — a shrinking circle homed on a point of interest
near the flight path, with a rendered wall, map circles, screen effects and
server-authoritative damage. Deaths (storm included) leave a lootable box,
placements are assigned, and a match ends with a victory/elimination sequence
back to the lobby.

**Not working yet:** damage is not validated server-side (M6), so shots are
whatever the engine says they are; no downed state, no spectating, no
persistent stats.

---

## Architecture

Four resources under `resources/[fivem-royale]/`:

| Resource | Runtime | Responsibility |
|---|---|---|
| `br_lib` | No | Shared config, enums, protocol constants, geometry, seeded RNG, storm solver. Consumed via `shared_scripts { '@br_lib/...' }`, which loads files into each consuming resource's own Lua state — zero runtime cost, no exports. |
| `br_core` | Yes | All gameplay, client and server. One Lua state, one loop registry. |
| `br_environment` | Yes | World state: IPL loading and the Cayo Perico lobby island (home of the pre-match lobby; released back to the streamer once a match is live). Will grow into the streamed-asset container. |
| `br_ui` | Yes | The NUI page and the only file that touches `SetNuiFocus`. |
| `br_stats` | Yes | oxmysql persistence, XP, leaderboards. Optional — degrades to "no stats" rather than taking the match down. |

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

## Terminology

The words the code, the logs, and the commit history use — and what each one
actually is.

### Authority and sync

| Term | Meaning |
|---|---|
| **Roster** | The server's per-player table (`br_core/server/roster.lua`) — the single source of truth for who is connected, their state, squad, health, kills, placement. Positions and licences live here too but are never broadcast. |
| **Mirror** | The client's read-only copy of the roster and match state (`br_core/client/state.lua`). It applies what the server said and derives nothing itself. |
| **Snapshot** | Everything a client needs to rebuild its mirror from nothing. Sent on join and whenever the UI restarts. |
| **Delta** | A batched, sequenced list of roster changes, flushed at 4 Hz. The optimisation layered on top of snapshots. |
| **Digest** | A 2 Hz heartbeat of the counts everyone needs (alive, squads, state, endsAt). Also the self-healing layer: a client whose state is wrong is wrong for at most half a second. |
| **Routing bucket** | FiveM's server-side world partition. Every LOBBY player sits alone in a personal bucket (the lobby is a menu with a view — nobody's ped may wander into it); everyone in a match shares bucket 0. |
| **Clock sync** | Client-estimated offset from server time via ping/pong. Countdowns and both moving systems (bus, storm) interpolate against `BR.Clock.now()`, never a streamed position. |
| **Scope gate** | The CI grep in `tools/verify.sh` banning scope-limited natives (`GetActivePlayers` etc.) from client gameplay code — under OneSync those only see nearby players, which is how alive-counts silently go wrong. |

### Match flow

| Term | Meaning |
|---|---|
| **Match states** | `WAITING → WARMUP → BUS → PLAYING → ENDED → CLEANUP`, owned entirely by the server (`match.lua`). Clients are told; they never infer. |
| **Player states** | `lobby, warmup, bus, freefall, glide, alive, dbno, dead, spectating, left` — a player's own position in the match, independent of the match state. Landing is what makes you `alive`; the state machine going PLAYING does not. |
| **Party** | A persistent group that survives across matches (invites, leader, pending list). What you queue with. |
| **Squad** | The per-match team formed from parties (plus autofill) the moment a match starts. Dies with the match; the party does not. |
| **Participants** | The queue snapshot taken when a match starts. Only players who readied up enter warmup — idling in the lobby never conscripts you. |

### The Battle Bus

| Term | Meaning |
|---|---|
| **Virtual bus** | There is no shared plane. The server publishes one timestamped route; every client spawns its own local, non-networked Titan and flies it along that route against the synced clock. 48 players see identical planes with zero sync traffic. |
| **Tour / legs** | The flight is authored, not random: one option drawn from each of four leg lists (coast → city → mid-map → northern exit), 192 possible flights, all over land by construction. |
| **Waypoints** | The authored points of the drawn tour — what players see on the map during warmup, and what the storm anchor is picked from. |
| **Doors** | The jump window. Opens on arrival at the leg-1 waypoint (the coastline players saw on the map) and closes after a 5-second overrun past the last waypoint, when stragglers are force-ejected. |

### The storm

| Term | Meaning |
|---|---|
| **POI** | Point of interest: ~49 named places (`br_lib/config/map.lua`) with a tier that drives loot density. They double as storm-anchor candidates. |
| **Anchor** | The place a match's whole storm sequence homes on. Picked at warmup: one random waypoint of this match's tour, then one random POI 500–1500 units off it — route-coupled, always on land, never a pattern. |
| **Record** | The one table the server publishes per phase: current circle, target circle, timestamps, dps. Whole-record broadcasts only, never incremental mutation. |
| **Solver** | `BR.StormAt(record, now)` — a pure function both sides run to get the circle at any instant. A shrinking storm costs zero per-frame network traffic. |
| **Phase** | One hold-then-shrink cycle from the authored table (radius, wait, shrink, dps, warn). Phase 1's 120 s wait is the free-loot hold; the first circle is visible from the moment the match goes live. |
| **Wall** | The rendered edge: ~40 tall cylinder markers on the arc nearest the player, drawn only when the edge is within 250 m. Cosmetic — disabling it changes nothing about damage. |
| **Ledger** | The authority trick. The server cannot write a ped's health, so clients are *told* to apply storm damage — but the server also tracks what the storm should have done and eliminates from its own arithmetic. A client that ignores every damage instruction dies at exactly the honest moment. |

### Loot and inventory

| Term | Meaning |
|---|---|
| **Layout** | A match's whole loot map, generated once at warmup by `BR.BuildLootLayout(seed)` — a pure function in `br_lib/shared/loot_gen.lua` with no FiveM dependencies, so its determinism is proven outside the game. Same seed, same map, entry for entry. |
| **Entry** | One thing on the ground: an id, a stack (item, kind, rarity, count) and a position. Weapons, ammo, consumables, throwables, chests and death boxes are all entries. |
| **Cell** | The streaming grid, 256 m squares. Clients subscribe to the 3×3 block around them and are sent only those entries — roughly 50–150 in flight instead of ~1900. Props are a much smaller radius again (90 m), because entries are cheap and objects are not. |
| **Claim** | The pickup request. The server re-validates distance (with slack for its own 2 Hz position sampling), rate-limits, and arbitrates: the first claim wins and the loser is told. Nothing about a pickup is decided client-side. |
| **Container** | A crate (`prop_box_wood05a`) or a death box. Holds a rolled burst of items the client is never told about — the contents are the reason to open it — and opening one takes a held key, so it is a commitment in the open. |
| **Husk** | What an opened crate leaves behind: `prop_box_wood05b`, the same crate open and empty. Not loot — no glow, no prompt, and the server refuses to claim it. It exists so a room you have already swept reads as swept from the doorway. |
| **Look-at targeting** | `BR.Native.aim()` fires a synchronous shapetest from the *gameplay camera* (not the ped's facing — those differ by up to 180° and the player's expectation follows the camera) and resolves the hit entity through a handle→entry map. Crates keep collision so the ray has something to hit; loose floor items do not, and fall back to proximity. |
| **Repair round-trip** | `GetGroundZFor_3dCoord` and `GetWaterHeight` are client natives, so the server cannot tell it put a crate in the Pacific. A client that finds one sends back a corrected position; the server accepts it only within 30 m, once per entry, and only for a cell that player is subscribed to. |
| **Warmup loot** | One layout on the Cayo Perico pad, shared by every concurrent match — the pad is a communal routing bucket, so a per-match layout would put two players side by side seeing different crates. Looted crates respawn on a timer, and everything found there is wiped at wheels-up. |
| **Slots** | Five, matching the `slot1`–`slot5` keybinds. Weapons, throwables and consumables occupy a slot; ammo lives in a separate capped pool. A weapon picked up with no free slot swaps into the active slot and drops what was there; a consumable is refused instead — a misclick must not throw away your rifle. |
| **Active slot** | The one thing the ped is holding. Every switch is `RemoveAllPedWeapons` + `GiveWeaponToPed`, so the weapon wheel cannot drift out of agreement with the inventory — and it is suspended while airborne, because that call would take the parachute with it. |
| **Ammo reports** | The one number only the client can observe before M6 validates shots. Reports are accepted **only when they lower** the stored value, so the worst a liar can do is disarm themselves. |

### Health units

| Term | Meaning |
|---|---|
| **Display units** | 0–100, what players see and what every config number uses (storm dps, consumables, revive HP). Shield is armour, natively 0–100. |
| **Engine units** | 100–200 living range; **engine 100 is dead** (the GTA convention — a live death at exactly half bar under an earlier 0–200 mapping settled it; `GetEntityHealth` reads 0 only post-mortem). Conversion happens only in `BR.ToEngineHp` / `BR.ToDisplayHp` / `BR.ToEngineHpDelta` — never inline. |

### Interface

| Term | Meaning |
|---|---|
| **NUI** | FiveM's in-game browser layer (CEF, Chrome 103) where the React interface renders. |
| **Envelope** | The single message shape crossing the Lua→UI bridge: `{ k = kind, d = payload, s = sequence }`, numerics normalised once at the boundary. |
| **Focus stack** | `br_ui`'s ownership of `SetNuiFocus` — the only file allowed to touch it. Screens push and pop; a thrown React error can never strand a player without controls. |
| **Loop registry** | The client performance contract: exactly three loops (per-frame, 10 Hz, 1 Hz); every subsystem registers a measured callback instead of spawning threads. The server mirror of this is the **scheduler** (`BR.Sched`, interval-based jobs). |

---

## Running it

See **[DEPLOY.md](DEPLOY.md)** for the full walkthrough. In short:

```bash
git clone https://github.com/WillMontgomery/fivem-br-gamemode.git
cp server.cfg.example server.cfg     # then fill in sv_licenseKey
```

Copy `resources/[fivem-royale]/` into your server's resources directory, or use
[`tools/deploy.sh`](tools/deploy.sh) to pull and sync automatically.

**OneSync is required** (`set onesync on`). Without it the server cannot see
player entities at all — no positions, no storm damage, no validation — and the
failure is completely silent. The server warns loudly at boot if it is off.

A database is **optional**. Without one, `br_stats` disables itself and matches
run normally; you just get no persistent stats.

---

## Development

```bash
./tools/verify.sh          # syntax + tests + scope gate + manifest coverage
cd ui-src && npm run dev   # the UI in a browser, no game required
cd ui-src && npm run build # typecheck, build, and CSS compatibility check
```

`verify.sh` runs four gates: Lua 5.4 syntax on every file, ~770 unit tests over
the pure logic (geometry, storm solver and anchor picker, seeded RNG, loot
layout generation, loop registry, roster, match flow, bus routes, storm engine,
loot streaming and claims, the inventory model, parties, XP curve), the scope
gate, and a check that every `.lua` is declared in its `fxmanifest` — because a
file that is never loaded produces no error.

Every regression test must be **proven load-bearing**: revert the fix, confirm
the test fails, restore it. A test that passes either way is rewritten. Anything
that has to reach clients is asserted **on the wire** (the captured
`TriggerClientEvent` stream), not on the server's own tables — a bug that
passed every server-side assertion and still shipped is what set that rule.

Install the pre-commit hook with `./tools/install-hooks.sh`.

### In-game diagnostics

| Command | Where | What |
|---|---|---|
| `brnativecheck` | client | Verify every native assumption against the running build |
| `brblack` | client | Every state that can cause a black screen, at once |
| `brfocus` | client | The NUI focus stack — why you do or don't have a cursor |
| `brbus`, `brdrop` | client | Bus ride and skydive state, live |
| `brloot` | client | What this client can see: entries, live props, nearest item |
| `brpromptcheck` | client | Which prompt glyph actually renders for a custom keybind |
| `/brleave` | client | Leave the current match (counts as an elimination) |
| `brperf` | both | Per-subsystem frame and tick cost |
| `brwhy <id>` | server | Why a given player is in the state they're in |
| `brscatter` | server | Spread everyone 3 km apart to test OneSync scoping |
| `brforce <state>`, `brskip`, `brkill <id>` | server | Drive the match by hand |
| `brloot [matchId]` | server | World loot: counts by kind and rarity, cells, who is subscribed |
| `brinv <id>`, `brgive <id> <item> [n]` | server | Read or fill a player's inventory |
| `brphase <n>` | server | Jump the storm to phase n, seamlessly from the live circle |
| `brstormscale <0.05–1>` | server | Compress storm pacing for testing (0.1 ≈ a 2-minute cycle) |
| `brstate`, `brroster`, `brstorm`, `brqueue`, `brparty` | server | State dumps |

---

## Platform constraints discovered along the way

These are load-bearing and cost real time to find. Recorded here so the next
person doesn't repeat them.

**FiveM's CEF is Chrome 103.** It cannot parse `oklch()`, `oklab()`,
`color-mix()`, `:has()`, or CSS nesting. Tailwind 4 and HeroUI 3 emit those
throughout their colour systems, which is why this project pins **HeroUI 2 +
Tailwind 3**. An unparseable colour is not a fallback — the declaration is
dropped and the element renders invisible. `ui-src/scripts/check-css.mjs` fails
the build if any reach the bundle.

**`color-scheme: dark` paints the canvas opaque.** Separately from any
background-color. A component library's dark theme will black out the entire
game while `html`, `body` and `#root` all correctly report transparent. The fix
is `html { color-scheme: normal !important }` — the same line
[ox_lib](https://github.com/overextended/ox_lib) opens its stylesheet with.

**Entity culling is 424 units** and the natives to widen it are deprecated with
known unfixable issues. Players beyond that are not rendered and cannot be shot,
so weapon ranges and late-game circle sizes are designed around it.

**`GET_PLAYER_PED` takes a string.** Passing the numeric server id returns 0 for
every player, silently.

**Server-side entity access requires OneSync.** Without it every position read
returns nothing and nothing errors.

**A parachute is a weapon, and its AMMO is what "has a parachute" means.**
Opening the canopy does not consume it — the ped keeps `GADGET_PARACHUTE` with
its count intact, which the engine reads as a chute still available. That is
one bug (a reserve chute, and the vanilla deploy prompt returning on landing)
wearing three different faces across four sessions. The count is zeroed the
instant the canopy appears, removal at touchdown is retried across real frames
rather than assumed, and a standing 10 Hz sweep disarms any grounded live
player still holding one.

**Native names keep an underscore before digit-leading segments.**
`GetGroundZFor_3dCoord`, not `GetGroundZFor3dCoord` — the latter is `nil`, and
a nil native is not an error, it is a silent no-op. `luac -p` cannot see it and
unit tests stub it. Every native a new subsystem leans on gets a probe in
`brnativecheck` **before** the in-game test.

---

## Licence

Not yet chosen. Until one is added, no permissions are granted beyond viewing.
