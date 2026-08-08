# Terminology

The words the code, the logs and the commit history use — and what each one actually is.

[← Back to the main README](../README.md)

---

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
| **Squad target** | `min(units, max(minSquads, ceil(players / maxSquadSize)))`. A **unit** is something that cannot be split — a party, or a lone player. The `minSquads` floor is why two unpartied players become two squads of one rather than one squad of two: a match with a single team standing has already met the win condition and would never start. The `units` ceiling is why four friends who queue as one party still, correctly, block for want of an opponent. Formation and the start gate both call it, or the queue deadlocks. |
| **Rebalance** | Late joiners are slotted into the emptiest squad, which is usually the whole job. When that leaves the shape wrong — the squad count no longer matches the target, or the teams differ by more than one — squads are re-formed from scratch (parties kept whole) and everyone who moved is told why. Eight players plus a ninth goes 4/4 → 3/3/3. |

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
| **POI** | Point of interest: 101 places (`br_lib/config/map.lua`) with a tier that drives loot density. 65 are north of the city, and 25 of those are **backcountry** — sited from the empty ground *between* the road corridors rather than from a place name, because named places are all on roads and the authored set had inherited the road network's shape. `tools/check_pois.lua` gates the spacing and the distance to the nearest corridor. They double as storm-anchor candidates. |
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
| **Slots** | Five, matching the `slot1`–`slot5` keybinds, plus **slot 0: fists** — always present, never fillable, left of slot 1 on the bar and part of the scroll ring. Weapons, throwables and consumables occupy a slot; ammo lives in a separate capped pool. Picking anything up with no free slot swaps it into the active slot and drops what was there onto the ground; nothing is ever refused, because reaching for an item means wanting it more than what is in hand. |
| **Active slot** | The one thing the ped is holding. Every switch is `RemoveAllPedWeapons` + `GiveWeaponToPed`, so the weapon wheel cannot drift out of agreement with the inventory — and it is suspended while airborne, because that call would take the parachute with it. |
| **Ammo reports** | The one number only the client can observe before M6 validates shots. Reports are accepted **only when they lower** the stored value, so the worst a liar can do is disarm themselves. See below — the choice of *which* number cost five rounds. |

#### The ammo model, and the four models before it

The client reports **`GetAmmoInPedWeapon` — the total, magazine included** — and
the server treats it as decrease-only. That is the whole rule:

```
FIRING   lowers the total.                    reserve = total - clip
RELOAD   does not change the total at all.    (the split moves, nothing is spent)
PICKUP   raises it, and the SERVER did that.  a client reporting a rise is refused
```

Everything else falls out of it. The reserve is never reported: it is what is
left once the magazine comes out of the total, so an empty pool cannot conjure
a magazine because there is nothing for the arithmetic to take it from.

This looks obvious and was not. The models before it each tried to infer *what
the player did* from a number, and each broke on a different engine quirk:
computing the reserve as `GetAmmoInPedWeapon - clip` made it grow as the
magazine shrank, which fed straight back into the ped as unlimited ammo;
reporting the magazine alone and reading a rise as a reload worked until
`/brprobe raw` showed the magazine **pinned at 5 while the total climbed by one
per shot**, with every one of our own writes suspended.

The answer came from reading [ox_inventory](https://github.com/overextended/ox_inventory),
which guards its ammo read with `if currentAmmo < weaponAmmo` — it refuses
increases rather than explaining them. Two consequences here:

- **The client clamps the ped.** If the engine ever holds more than the server
  granted, `SetPedAmmo` writes it back down. That kills the runaway at the ped
  as well as in the counter, whatever is causing it. Never upward — writing
  ammo up is what produced the unlimited-ammo round.
- **`GiveWeaponToPed` is called with ammo 0**, then `SetPedAmmo` sets the
  holding. That native *adds* rounds to a weapon the ped already has, so
  passing the real count re-granted a full holding on every re-apply.

Infinite ammo and infinite-ammo-clip are asserted **off every tick**, not once
per weapon grant: the raw probe showed the flag surviving a grant-time clear.
Two natives a tick is cheaper than finding out what re-sets it.

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

