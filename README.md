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
| M2 | Persistent parties, squad formation, autofill, lobby UI | **In progress** |
| M3 | Battle Bus, skydive, glider | Not started |
| M4 | The storm — phases, damage, rendering | Not started |
| M5 | Loot spawning, pickups, 5-slot inventory | Not started |
| M6 | Combat, damage validation, kill attribution | Not started |
| M7 | Downed state and revives | Not started |
| M8 | Spectating, match summary, round flow | Not started |

**Working now:** players connect and spawn, queue for a match, form persistent
parties, chat globally or to their squad, and a match runs WAITING → WARMUP →
BUS → PLAYING → ENDED → CLEANUP with a real win condition. Deaths are detected
and placements assigned.

**Not working yet:** there is no bus, no drop, no storm, no loot, and no weapons.
A "match" currently consists of standing at the airport until someone dies.

---

## Architecture

Four resources under `resources/[fivem-royale]/`:

| Resource | Runtime | Responsibility |
|---|---|---|
| `br_lib` | No | Shared config, enums, protocol constants, geometry, seeded RNG, storm solver. Consumed via `shared_scripts { '@br_lib/...' }`, which loads files into each consuming resource's own Lua state — zero runtime cost, no exports. |
| `br_core` | Yes | All gameplay, client and server. One Lua state, one loop registry. |
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

**Loot will be client-rendered and server-owned.** ~1200 items as networked
entities would not survive contact with a real server. The server holds the
layout as plain data generated from a seeded RNG; clients render local,
non-networked props and ask the server to claim them.

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

`verify.sh` runs four gates: Lua 5.4 syntax on every file, 350 unit tests over
the pure logic (geometry, storm solver, seeded RNG, loop registry, roster,
parties, XP curve), the scope gate, and a check that every `.lua` is declared in
its `fxmanifest` — because a file that is never loaded produces no error.

Install the pre-commit hook with `./tools/install-hooks.sh`.

### In-game diagnostics

| Command | Where | What |
|---|---|---|
| `brnativecheck` | client | Verify every native assumption against the running build |
| `brblack` | client | Every state that can cause a black screen, at once |
| `brfocus` | client | The NUI focus stack — why you do or don't have a cursor |
| `brperf` | both | Per-subsystem frame and tick cost |
| `brwhy <id>` | server | Why a given player is in the state they're in |
| `brscatter` | server | Spread everyone 3 km apart to test OneSync scoping |
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

---

## Licence

Not yet chosen. Until one is added, no permissions are granted beyond viewing.
