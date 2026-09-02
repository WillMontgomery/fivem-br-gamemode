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
| **Dev gate** | One wrap around `RegisterCommand`, installed once in `br_lib/shared/devgate.lua`, putting **every console command in the project** behind `br_devMode` (or `sv_devMode`) since 2026-08-31. A wrap rather than a helper each command calls, because the failure mode of a helper is not the copies — it is the next command, written with no call, ungated, looking exactly like every gated one and saying nothing. Through the wrap a new command is gated **by construction**. **Three verbs are exempt** and keep working on the public box: `brkick` and `brspectate`, which `tools/dispatch.sh` types into the server console over tmux and which therefore *are* the admin console's Kick and Spectate buttons, and `brring`, which nothing types — it is exempt because `DEPLOY.md` sends an operator to it by hand on the live box after an IAM policy change, and it is the only thing there that can tell "the Ringmaster link is fine" from "it has been refusing us for an hour". `bridents` is **not** exempt and was checked rather than assumed: nothing invokes it and it prints licenses, Discord ids and Steam ids for every connected player at once. The gate **fails open** — if the file leaves a manifest, commands register ungated — because a gate that can take `brkick` off the public box by failing to load is worse than one that can leave `brshop` on it. **Keybinds are not diagnostics**: FiveM builds a keybind out of a command plus `RegisterKeyMapping`, so `+brinteract`, `brslot3` and `brmap` are console commands in exactly the sense `brshop` is *and* are E, 3 and M — through the wrap the public box would have had no keyboard at all. They and the player verb `/brleave` go through `BR.Dev.rawCommand`, the native captured before the wrap, and `verify.sh` pins that door to those two files. It checks the four things construction rests on — the exempt set, the raw-door allowlist, every command-registering resource loading `devgate.lua`, and loading it **first** — rather than a list of today's command names, which would stay green while the next one arrived ungated beside it. |

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
| **POI** | Point of interest: **120** places (`br_lib/config/map.lua`) with a tier that drives loot density — 77 tier 1, 29 tier 2, 14 tier 3. **72 are north of the city** (`y > 500`), and **23** of those are **backcountry** — sited from the empty ground *between* the road corridors rather than from a place name, because named places are all on roads and the authored set had inherited the road network's shape. The backcountry set was 25 until 2026-08-28, when the surveyed map boundary put `graybeard` and `calafia` outside it by 51 m and 45 m; nothing else in the set moved. `tools/check_pois.lua` gates the spacing and the distance to the nearest corridor, and prints all four counts on every run. They double as storm-anchor candidates. |
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
| **Cell** | The streaming grid, 256 m squares. Clients subscribe to the 3×3 block around them and are sent only those entries — a small fraction in flight instead of the whole layout (~3,370 entries: 2,196 crates + 754 floor items + 420 roadside filler). Props are a much smaller radius again (90 m), because entries are cheap and objects are not. |
| **Claim** | The pickup request. The server re-validates distance (with slack for its own 4 Hz position sampling), rate-limits, and arbitrates: the first claim wins and the loser is told. Nothing about a pickup is decided client-side. |
| **Container** | A crate (`prop_box_wood05a`) or a death box. Holds a rolled burst of items the client is never told about — the contents are the reason to open it — and opening one takes a held key, so it is a commitment in the open. |
| **Husk** | What an opened crate leaves behind: `prop_box_wood05b`, the same crate open and empty. Not loot — no glow, no prompt, and the server refuses to claim it. It exists so a room you have already swept reads as swept from the doorway. |
| **Look-at targeting** | `BR.Native.aim()` fires a synchronous shapetest from the *gameplay camera* (not the ped's facing — those differ by up to 180° and the player's expectation follows the camera) and resolves the hit entity through a handle→entry map. Crates keep collision so the ray has something to hit; loose floor items do not, and fall back to proximity. |
| **Repair round-trip** | `GetGroundZFor_3dCoord` and `GetWaterHeight` are client natives, so the server cannot tell it put a crate in the Pacific. A client that finds one sends back a corrected position; the server accepts it only within 30 m, once per entry, and only for a cell that player is subscribed to. |
| **Warmup loot** | One layout on the Cayo Perico pad, shared by every concurrent match — the pad is a communal routing bucket, so a per-match layout would put two players side by side seeing different crates. Looted crates respawn on a timer, and everything found there is wiped at wheels-up. |
| **Slots** | Five, matching the `slot1`–`slot5` keybinds, plus **slot 0: fists** — always present, never fillable, left of slot 1 on the bar and part of the scroll ring. Weapons, throwables and consumables occupy a slot; ammo lives in a separate capped pool. Picking anything up with no free slot swaps it into the active slot and drops what was there onto the ground; nothing is ever refused, because reaching for an item means wanting it more than what is in hand. |
| **Active slot** | The one thing the ped is holding. Every switch is `RemoveAllPedWeapons` + `GiveWeaponToPed`, so the weapon wheel cannot drift out of agreement with the inventory — and it is suspended while airborne, because that call would take the parachute with it. |
| **Ammo reports** | The one number only the client can observe. Reports are accepted **only when they lower** the stored value, so the worst a liar can do is disarm themselves. M6's shot counting did not retire this — it left a hole the size of every shot that raises no `weaponDamageEvent`, which is every explosive — so under `serverAmmo` the report survives as a floor on the total and nothing else. See below — the choice of *which* number cost five rounds, and the hole cost a sixth. |

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

##### What M6 changed, and the hole it left (2026-08-23)

With `Combat.serverAmmo` on the server counts rounds off validated shot events
and the client's report was switched off entirely. `BR.Damage.spendRound` is
reachable from exactly one place — the `weaponDamageEvent` handler — so **a
round burnt by a shot that raises no such event was charged to nobody**. An
explosive raises none at all, which is the whole airdrop shelf: the RPG, the
grenade launcher and the railgun. The server's number then sat above the ped's
for the rest of the match, and every re-grant — a slot switch, a pickup that
touched the shared pool, the post-landing chute sweep — wrote it back onto the
gun. Owner, from a playtest: *"once depleted, switching between slots gave me
more ammo."*

Two things changed and the rule above is unchanged by both:

- **The report is a floor, not a retirement.** Under `serverAmmo` the client may
  say the total has FALLEN and may say nothing else — it cannot raise it, cannot
  choose the split, and cannot buy a reload the pool has not paid for. It is the
  only observer of rounds the server never saw leave.
- **The client tracks its own shortfall.** Per slot, `what the server says` minus
  `what the engine says`, measured only where the ammo natives are trusted, and
  subtracted from every write onto the ped. That is what makes a dry weapon come
  back dry inside the round trip rather than one INV_SET later.

##### The fourth door: a gun that came back with a round (2026-08-23)

Three doors were closed above — the slot switch, an unrelated pickup, the
post-landing sweep — and all three were **re-grants**, the server's stale number
written onto the ped. The fourth is not a re-grant at all. Owner, same day:
*"when I drop it and pick it back up it has 1 round in it now."*

`BR.Inv.give` ends by granting a clip's worth of reserve to any weapon that
arrives, so that a found gun is usable. It asked nothing about where the gun came
from, so **a weapon a player dropped was minted a fresh magazine's worth on the
way back in** — out of an empty pool, repeatable, and compounding: the same trip
run three times on a railgun measured 3, 6, 9 in the heavy pool. What the owner
saw was one round because the conjured three had already been laundered — the
client pushes them onto the ped, the engine reads back lower, and the floor above
spends the difference and reloads. Not railgun-specific either: a dry pistol
makes the same trip and comes back with twelve. The railgun is only where it
shows, because its pool is the only one normally at zero.

The grant was right and its audience was wrong. Every stack that leaves an
inventory — a drop, a death, a displaced swap — is now stamped `carried` on the
way out, it travels with the world entry, and the grant is for **found** loot
only. A weapon that has been in an inventory comes back with what it left with.

`/brammo` prints all of it — the server's magazine, the pool, the engine's
holding and the shortfall, for all five slots at once. `/brprobe ammo` is the
stopwatch for the active weapon; this is the photograph that includes the slots
you are not holding, which is the only shape that can answer a question about
switching.

It also prints **`held`** — pool plus every magazine drawing on it — and how that
number moved since the last `/brammo`. The split is what the five rows show and
the invariant is about the sum, which is why the fourth door survived a readout
built to find the first three: every column was honest and none of them said
*you have more ammunition than you did*.

##### The manual reload (2026-08-23)

*"we need a manual reload button, which should default to R."* R was already the
`use` key, chosen by an argument about a reload that did not exist yet — *"the
two never want the key at the same moment"*. That is now load-bearing rather than
aspirational: it stays **one binding**, and which of the two things a press means
is decided by what is in the player's hands. A magazine with room in it over a
live pool is a reload; every other state is a `use`. Two rows both defaulting to
R would have rested on whether `RegisterKeyMapping` delivers both commands for
one key, which nothing here can test.

`INV_RELOAD` carries **nothing** — no slot, no count, no ammo type. The server
reloads the slot *it* believes is active out of the pool *it* holds, through
`BR.Inv.reload`, which is now the single copy of the rule that `spendRound` and
the `INV_AMMO` floor also run. That function *moves* rounds, so `clip + pool` is
identical on both sides of it: pressing the key a hundred times at a pool of zero
produces exactly what pressing it once does. There is no rate limit and none is
needed. It never asks the engine to reload — the magazine arrives with the
`INV_SET` that follows, on the path a server-paid reload has always taken.

Infinite ammo and infinite-ammo-clip are asserted **off every tick**, not once
per weapon grant: the raw probe showed the flag surviving a grant-time clear.
Two natives a tick is cheaper than finding out what re-sets it.

##### The fifth door goes the other way: ammunition that vanished (2026-08-23)

Four doors were closed and every one of them **made** rounds. The fifth takes
them. Owner, same day: *"I also picked up the railgun again this time, which came
with ammo, and was immediately drained of all railgun ammo..... didn't even do
anything."* He hadn't. Two faults were behind it and neither needs a shot fired
at the gun that empties.

**A report is a measurement of a moment, and it now says which one.** `INV_AMMO`
means *"you said N, the engine holds M, so N − M are gone"* — but until this
change the far end applied that subtraction to whatever it held when the message
**arrived**, and one round trip sits between the two. The client speaks every
150 ms and a `LOOT_CLAIM` is answered in rather less, so a report about the
weapon in hand and the pickup that credits the pool cross in flight routinely:
the rounds the pickup had just granted paid for the previous weapon's shots, in
one write. Making the handler a floor is what gave a stale report the power to
spend anything — before 951c6ea it returned outright.

So the report carries **`was`**: what this server last told that slot it holds,
echoed back. It is a **compare-and-swap token, never a quantity** — compared,
never arithmetic — and a mismatch is refused whole rather than guessed at. A
client lying about it achieves a refusal, which is the one outcome that cannot
cost anybody a round. And **refusing cannot lose ammunition**: the push that
invalidated a report re-baselines the client, which measures again and re-sends,
so rounds an explosive really burnt are still charged one cycle later — against
the holding they were actually taken out of. A throwable's `was` is its stack,
for the same window and the same reason.

**And the shortfall was being charged twice.** It is *measured* against the
server's own magazine, `rec.svClip`, and says why in its own note: the report
loop writes the engine's magazine into `slot.clip` every tick so the counter
follows the gun, which leaves the mirror laundered. Both **consumers** read the
laundered mirror and then subtracted the deficit from it, so every round already
reflected in the magazine came off a second time. One re-grant halves a gun and
three empty it, with the player stood still — on a railgun two rounds down:
`4 → 2 → 0`, the deficit reading 2, then 4, then 6 as the engine it is measured
against falls. The grant driven by an `INV_SET` was never wrong, because `adopt`
replaces the slot tables with the server's payload a few lines earlier and the
two numbers are briefly the same one; that is what made it invisible. The doors
that are not driven by an `INV_SET` are `BR.Inv.reapply` — the post-landing chute
sweep's third escalation — and the strip check clearing `applied`, both from tick
loops.

`/brammo` now prints **what this client has told the server and what became of
it**: the last eight reports with `was`, what was sent, and what the server
turned out to hold at the next `INV_SET`. Every column of the table above was
correct at the instant it was printed, which is exactly why none of them could
describe a disagreement between two instants.

### Downed, and getting back up

Squads only, and only while a squadmate is still on their feet. The numbers are
in [match-math.md](match-math.md); the rules are here.

| Term | Meaning |
|---|---|
| **Knock / DBNO** | Running out of health puts you on the floor instead of killing you (`br_core/server/combat.lua`). `BR.Combat.canBeDowned` wants three things at once: state ALIVE, a mode whose `dbno` flag is set, and a squadmate who is ALIVE, FREEFALL or GLIDE — a mate mid-canopy can land and pick you up, a mate already down cannot. Solo has no DBNO because nothing could revive you; the switch for it is `BR.Mode.SOLO.dbno` plus a second answer to "who picks them up", which is why the two conditions are separate. |
| **Bleed clock** | The downed player's health, denominated in seconds. There is no second health bar: shooting a downed body takes **time** off the clock (`dbnoBleedPerDamage`), and the tuning target for that number is a *round count* — about four rifle rounds to finish a fresh knock — not the seconds it converts to. |
| **Escalation** | Each knock in the same match is shorter: `base + step × (n − 1)`, floored. Per match, wiped at CLEANUP. A squad cannot farm revives out of one long fight. The three numbers are one **shape** rather than three independent values — when the base moved, the step, the floor and the per-damage cost all moved with it in proportion, or the same table would have described a different rule. |
| **Crawl** | A downed player can move, and that is the whole reason the state reads differently from death across a street: an enemy has to be able to tell "finish them" from "they are already gone", and a body that moves is the only signal that carries that far. No build here has a downed *locomotion* clipset, so `client/dbno.lua` drives the ped by hand at a real m/s and °/s rather than scaling a walk that is not happening. |
| **Revive** | A held interact key at close range, reusing the crate hold rather than a second implementation of it. **Multiple revives per match are normal** — a hold arms from the key's *level* in the frame band, so a held key is a held key however the last hold ended. It used to arm only on the key-down edge and be cleared on five different paths, which is exactly why "the second one never works" was the symptom. |
| **The clock stops while somebody is on you** | A genuinely progressing hold pushes the deadline along with the tick. It is the only thing that moves the deadline forward; damage moves it back and letting go simply stops it. A revive begun with three seconds left that still ended in a death read as the game ignoring what you did. |
| **Cover pose** | `SET_ENTITY_LOCALLY_INVISIBLE` for one frame (capped at 250 ms) around a resurrection. `TaskPlayAnim` *queues* a task and the engine evaluates the tree after the tick, so a resurrected ped renders one standing idle frame however tightly the calls are ordered — re-ordering could never fix it, so the frame is covered instead. Locally invisible rather than `SetEntityVisible` because `applyGameRules` asserts visibility every frame and would stomp a property write within a frame; the local flag also lasts exactly one frame, so there is no un-hide to forget on a failure path. |
| **Squad cues** | `squad.down`, `squad.out` and `squad.revived`, filtered on the **server** where the squad is actually known, and sent to every mate except the subject, who has their own sounds. `down` fires on the knock; `out` fires only from `eliminate`'s was-downed branch, so a straight elimination that was never a knock plays neither. The `squadcue` envelope had no subscriber in `ui-src` for a while and all three were dropped by the router with no error anywhere — the shape of "my change didn't do anything". `App.tsx` handles it now, outside the store, because it is fire-and-forget with no state any component reads. |
| **Revive key** | The second way back, added in #219 and reaching all the way to OUT rather than stopping at DBNO. When the bleed clock runs out and a player goes to spectate, their inventory spills on the ground and a **key is minted where it spilled**. It is **an entitlement held by the squad, not an inventory item** — no slot, no carrier, nothing to loot off a body — and the record lives on the *eliminated* player's roster entry, keyed by the person it brings back rather than the person who fetched it, which is what makes "one player can pick up the key while another processes the revive" fall out for free. Collection takes a **press** within `collectM` 2.5 m, and the press is there because it once did not: "I somehow picked up the dead player's key by walking up to them without seeing a DUI or pressing anything" (owner, 2026-08-30). **Two clocks, not one**: `expiryMs` (3 minutes) retires the *world pickup* and nothing else, and the entitlement it stood for stays purchasable for the rest of the match — which is what makes revives unlimited if a squad can pay. |
| **Buying keys** | 25 Volts at any ambulance, from the **saved** balance, and **one purchase buys every key the squad has outstanding** — the set is re-read *after* the DynamoDB charge lands rather than captured before it, so a mate eliminated during the round trip is covered by the price that was already paid. Multiple purchases per match are allowed. The squad is marked as buying for the whole flight, so a second press cannot buy one set twice. |
| **Spending a key** | A **6-second hold at an ambulance** (`reviveHoldMs`), not at the body — the owner moved the prompt to the van, and once a mate has bled out the van is the only place it appears. Its owner comes back on **full health** (`reviveHp` 100, against `dbnoReviveHp`'s 30 for a revive at the body) and **arrives as a drop from 150 m over that specific van** (`dropM`) rather than standing up beside it. The ambulance plate is the one prompt in this game that **names nobody**: "Revive your squad" over "PRESS AND HOLD", both the owner's own words of 2026-09-01, after the downed mate's name was taken off it. |
| **Station ambulance** | One of **23 persistent ambulances**, standing at the points surveyed with `/brcoords` on 2026-08-23 and spawned **when the bus doors open** rather than on demand. The points live in `BR.Config.Map.AmbulanceSpawns` and are read through `BR.Config.Rescue.Points()` at call time — three features read that one table, which is what stops a station ambulance and the rescue that spawns beside it disagreeing about where a station is. The model is the rescue's model for the same reason: a station van must count as an ambulance to `br_core/server/ambheal.lua` and to the revive key, and both ask `BR.Rescue.isAmbulance`. With no points the feature is **inert rather than broken** — nothing created, nothing blipped, one console line saying the table was empty. |
| **Ambulance blips** | Shown to the whole squad, and **all of them**, because the squad is choosing where to drive and a map showing one option is not a choice. The trigger is `BR.PlayerState.OUT` **alone**, which was a correction: it was "down or out" until 2026-08-31, and the owner's word was "we should not see blips until they've bled out" — a DBNO mate is revived at the body, no key exists yet, so a map of ambulances during the bleed-out points at something nobody can act on. **There is no knob for this**, deliberately. Ambient ambulances players have found along the way ride the same gate: `server/rescue.lua` remembers any ambulance a player was seen driving (the only hook that can see client-created population) and `server/ambulances.lua` publishes those finds beside the 23. |

`brdbno` (client and server both have one) and `brcrawl` read this state back;
`brdown`, `brrevive` and `brbleed` drive it by hand from the server console;
`brkey` reads and drives the revive key, and `brplate` tunes the plates.

### Health units

| Term | Meaning |
|---|---|
| **Display units** | 0–100, what players see and what every config number uses (storm dps, consumables, revive HP). Shield is armour, natively 0–100. |
| **Engine units** | 100–200 living range; **engine 100 is dead** (the GTA convention — a live death at exactly half bar under an earlier 0–200 mapping settled it; `GetEntityHealth` reads 0 only post-mortem). Conversion happens only in `BR.ToEngineHp` / `BR.ToDisplayHp` / `BR.ToEngineHpDelta` — never inline. |

### Interface

| Term | Meaning |
|---|---|
| **NUI** | FiveM's in-game browser layer (CEF, Chrome 103) where the React interface renders. |
| **Envelope (UI)** | The single message shape crossing the Lua→UI bridge: `{ k = kind, d = payload, s = sequence }`, numerics normalised once at the boundary. **Not** the ingest envelope below — two different shapes share the word. |
| **Notice parts** | How a toast that names a player crosses to the page. Owner, 2026-08-31: "Any time we mention a player by name in a toast their name should be bold" — which a string cannot carry, so since then a notice may travel **pre-split**: `parts`, an ordered list of `{ t = 'prose we wrote' }` and `{ b = "the player's own name" }`, built by `BR.Notice.line(fmt, ...)` with `BR.Notice.who(name)` marking which holes are people. **The split happens on the format string, which is always a literal in our own source; the substituted values are never scanned, tokenised or escaped.** That is the security property rather than a rendering detail: a name is the one part of a toast a player writes, so markdown (`**%s** is down!`) and a `{b:…}` token are both injections with a sign-up form in front of them — a player called `**` or `Bob}` reformats the sentence. There is no grammar for a name to break out of because the name is never inside one. `who()` has to be explicit because not every `%s` is a person: in `'%s\'s invite expired -- %s.'` the first hole goes bold and the second, our own word for why, does not. `text` travels alongside as the same sentence flattened — what the store dedups on and what any string-only consumer gets — and a notice naming nobody sends `text` alone, which is almost all of them. `verify.sh`'s *notice names* gate checks every sender for a name formatted into a sentence. |
| **Focus stack** | `br_ui`'s ownership of `SetNuiFocus` — the only file allowed to touch it. Screens push and pop; a thrown React error can never strand a player without controls. |
| **Loop registry** | The client performance contract: exactly three loops (per-frame, 10 Hz, 1 Hz); every subsystem registers a measured callback instead of spawning threads. The server mirror of this is the **scheduler** (`BR.Sched`, interval-based jobs). |

### Progression and cosmetics

See **[progression.md](progression.md)** for the tuning and the reasoning.

| Term | Meaning |
|---|---|
| **XP** | Drives levels only, and has no purchasing power. The curve is `base = 800`, `exponent = 1.55`, `maxLevel = 100`, in `br_lib/shared/xp.lua` — one implementation shared by `br_stats` (which stores the level) and `br_core` (which sends the lobby a level and bar). The client never derives a level; it renders what the server sends, because a client that computed its own would eventually disagree and the player believes the number in front of them. |
| **Volts** | The currency, named in exactly one place (`BR.Config.Market.currency`). Levels say how long you have played; Volts say what you have done recently. **Earned, never bought** — no purchase path, no top-up, no admin grant. Two verbs can increase a balance and both are earned: `br_ddb`'s `statsApply` at match end, and `awardPay` when an incident you reported resolves with an action taken. It was one until `e4f211d`; see [progression.md](progression.md). |
| **Market** | The cosmetics storefront (`br_lib/config/market.lua`). Payout and prices live in the same file on purpose: they only mean anything relative to each other, so changing one forces you to look at the other. |
| **Item kind** | Which slot a cosmetic occupies and which tab it appears under: `character`, `chute`, `trail`, `weapon`, `banner`, `verdict`. One equipped item per kind, stored as flat `equip_<kind>` attributes on the profile row rather than a nested map. |
| **Season** | A group of market items. `MarketIndex` flattens every item across every season into one id-keyed table, built once at load rather than searched per lookup. |
| **Showroom** | The warmup vehicle shop (#224), and the **second** thing Volts buy. Thirteen cars standing at coordinates and headings the owner surveyed on 2026-08-29, on the warmup pad, priced **250–1500 Volts** per row. Both match state and player state must be `WARMUP`, the limit is **one car per player per match** (`limit = 1`), and **purchases are never refunded** — that is meant literally and includes the known engine fault where a server-created vehicle simply disappears (citizenfx/fivem#2623, still open), so there is no refund path and no retry path, only a console line at every step of a delivery so a car that never arrived can be told from a car that arrived and vanished. |
| **The catalogue is the safety mechanism** | Not a phrase about config hygiene. A showroom car is bought with the **saved** Volts balance — earned across every match ever played — and it lands *in* a match, which is the first thing to come near the rule that nothing you buy changes how a fight goes. The owner funded it on one condition, 2026-08-29: **"A bought car must be transport, not an advantage."** Nothing in the code enforces that and nothing can: `config/vehicles.lua` refuses what *flies* or carries built-in weapons, and every catalogue row is put through `BR.Config.IsAllowedVehicle` at load (a refused model is dropped with a console line rather than left wearing a price it cannot deliver on) — but armour, ramming mass, bulletproof glass and a roll cage are bought advantages no ban list names. The check bounds what is **legal**; the person choosing models is the one enforcing what is **fair**, and a row that lets a hundred-match player beat a one-match player breaks the condition quietly with nothing to report it. |
| **The car as an item** | A purchase becomes an **ordinary inventory item**: it takes one of the five slots, it can be dropped, and it is dropped at the player's feet if the bag is full when the match starts. Using it is refused unless the player is **on foot**. **Nothing outlives the round** — leaving the match forfeits an undelivered car (owner, 2026-08-30, #238: "if you buy a car, then leave the match, you forfeit your purchase. It should not be persistent or carry over to another round ever"), which **overruled** the earlier trade in `ecdda80` of declining a second sale and keeping the first owed. `BR.Match.leaveMatch` is the only call site that can forfeit, deliberately, so that "forfeit on leaving" can never drift into "forfeit while still in the match". |
| **Rolled paint** | Since 2026-08-31, twelve of the thirteen cars no longer wear the colour authored on their row: the server rolls **one colour per row per match** from its own seed (`BR.ShopSolve.paint`) and applies the same number to the display car in the showroom and to the car that comes out of the item, so what a player buys is what they saw. The draw is a **curated 32-entry palette** rather than the full 0–159 index space, because that space is a parts bin and not a spread of colours — a uniform draw over it paints roughly one car in six grey, and chrome and gold read as a cheat rather than a paint job. **The ambulance is excluded** and keeps its authored colour (`randomColour = false`): it has a livery, so colour would not show. The palette is the one place a paint index is written down, and emptying it turns the roll off and returns every car to its row. |

### Voice

| Term | Meaning |
|---|---|
| **pma-voice** | The third-party resource that owns voice (MIT, © Dillon Skaggs), pinned at **v7.0.2-rc3** (`dc099d3`) and **vendored into this repository** at `resources/[voice]/pma-voice` — outside `resources/[fivem-royale]/`, so our namespace stays ours, with a second `--delete`-scoped rsync in `tools/deploy.sh` carrying it to the same path on the box the hand-installed clone used. `br_core/client/voice.lua` expresses our rules through its extension points and calls exactly one Mumble native itself — `MumbleIsPlayerTalking`, a read. Every setter is gone, and `test_client.lua` asserts they stay gone. |
| **BR-PATCH** | The marker on every local change to vendored third-party source, and the unit the patch log is kept in. Four exist, all in pma-voice: **1** replaces an unconditional `print(volumes[moduleType])` with `logger.verbose` (it put "0.6" in every player's F8 console whenever anybody talked); **2** makes `playMicClicks()` return immediately, killing the press/release chirp at source while leaving the radio **submix** — the effect the owner asked to keep — untouched; **3a** and **3b** delete the `RegisterKeyMapping` calls for `cycleproximity` (F11) and `+radiotalk` (Left Alt), which registered keys outside our own key layer. **The `+radiotalk` and `-radiotalk` commands are deliberately untouched** — `brptt` drives them by `ExecuteCommand` and they are the only thing that ever puts a squadmate in the Mumble voice target. Every marker is declared in `resources/[voice]/pma-voice/VENDOR.json` next to the upstream tag and commit; `tools/verify.sh`'s **vendored third-party** gate fails the build if the markers and the log disagree in either direction, if the `LICENSE` goes missing, or if `deploy.sh` stops syncing the resource. |
| **Proximity** | Enforced by the **speaker**, not the listener. Every player has their own Mumble channel; pma-voice rebuilds each player's voice target four times a second from the channels of players near *them*, so out-of-range audio never leaves the machine that made it. There is no receive-side gate, which is why a mistake here costs one player's microphone rather than one player's ears. Range comes from `Config.Match.voice.range.nearby` via `overrideProximityRange`. |
| **Voice modes** | `nearby`, `squad`, `off`, and **two saved preferences rather than one** — `voiceModeSolo` and `voiceModeSquad`, set as two rows of side-by-side buttons under **Settings → Voice**. Which one is in force is derived from the match kind on every read (`BR.VoiceModeFor`, `br_lib/shared/enums.lua`); nothing stores the resolved mode, because a stored one goes stale the moment the match kind changes and a stale voice mode is a silent match. The modes are **mutually exclusive rather than layered** (`BR.VoiceRouting`: two booleans per mode, never both true). `nearby` is proximity with falloff and **no** radio — a squadmate across the island is as inaudible as any stranger. `squad` is the server-assigned pma-voice **radio channel and nothing else**: no falloff, no proximity, and every non-squadmate muted. `off` transmits to nobody and hears nobody. **Both slots default to `nearby`** (`BR.VoiceModeDefault`), read by `br_ui/client/settings.lua`, `br_core/client/voice.lua` and `ui-src/src/settings/apply.ts`, which `tools/verify.sh` compares as text. **`squad` is not offered, and cannot be stored, in the solos row** — a solo match has no squad radio, so honouring it would be silence; `BR.ToSoloVoiceMode` coerces it to the default whatever route it arrives by, including the migration from the single setting this pair replaced. **Squad mode with no squad is total silence**, which is correct and identical to a fault; that one is still said on the HUD (`ui-src/src/hud/VoiceNotice.tsx`), on the settings screen and in `/brvoice`, from one source: `BR.Voice.statusFor`. The **working** radio state deliberately says nothing on the HUD — a permanent "voice is fine" banner is furniture, and the owner asked for it gone. **Neither does `off`**, since 2026-08-20: it used to draw "Voice is off" across the bottom of the screen, and the owner's word on it was "just simply say nothing at all. It's off because they turned it off - the default was Nearby." A line naming a setting the player picked is furniture that lasts as long as the preference does. Its **detail** survives, because that one is read on the settings screen. |
| **Push to talk** | `brptt`, **"Royale: Push to talk", default N**, a row in the gamemode's own key layer (`br_core/client/keybinds.lua`), rebindable on the settings screen like every other action. It drives **both** transmit paths: `+radiotalk` in `pma-voice` when the mode is `squad` — the only thing that ever puts a squadmate in the Mumble voice target — and GTA's **`INPUT_PUSH_TO_TALK` (control 249)**, forced every frame the key is held, when the mode is `nearby`. It does nothing on `off` or while riding the bus (`BR.Voice.gagged`, re-asked per frame), and the **release is never gated**, so a mode change mid-hold cannot leave pma-voice transmitting. It was pma-voice's own `+radiotalk` on **Left Alt** — `voice_defaultRadio`'s default, inherited by never setting it — which no screen of ours could list, name or move; setting that convar would have moved *pma-voice's* binding rather than giving us one. N because 249's own default keyboard binding is N. The key is named to the player **once per session** (`BR.Voice.noticeFor`, delivered at the first WARMUP where the mode is not `off`) and read from `BR.Keys.labelFor`, so a rebound key is named as the key it now is, and an **unbound** one says so rather than naming a key nothing is listening to. The session latch is a plain client-side boolean: it clears on reconnect, and also on a `br_core` restart, which is close enough to a reconnect to not be worth persisting. It is spent on **delivery, not on the opportunity** — a session spent on `off` has been told nothing, so switching voice on later still earns the sentence. A **preference change does not re-arm it**: the settings screen is already rendering the same information (`voiceDetail`, from `BR.Voice.statusFor`) at the moment the player makes the change. |
| **The bus rule** | `nearby` does not transmit while you are in the bus seat; `squad` on the bus is untouched, and listening is never affected. It lives **inside** the proximity check pma-voice calls four times a second, re-deriving "am I on the bus" from the roster on every call — there is no transition handler, no cached boolean and no event that can be missed. Two earlier attempts both failed on the clock rather than the rule, and left the gag on for a whole match. |

### Moderation and the console

See **[ingest-envelope.md](ingest-envelope.md)**, **[ban-contract.md](ban-contract.md)** and **[branch-switch.md](branch-switch.md)**.

| Term | Meaning |
|---|---|
| **Ringmaster** | The admin console — a separate repo (`fivem-ringmaster`) on a separate machine. `br_ringmaster` is the game-side resource that talks to it. The two are deliberately decoupled: each half can be built and verified with the other absent. |
| **Envelope (ingest)** | The outbound HTTP contract from `br_ringmaster` to Ringmaster's ingest endpoint — the only contract between the two repos, versioned and pinned by fixtures in `tools/fixtures/` that **both** sides test against. Outbound only: FXServer never listens, and commands arrive over SSH instead. Distinct from the **Envelope (UI)** above. |
| **Incident** | A case filed for human review, in `ringmaster-incidents`. Two states and no others: **`pending_review`** and **`resolved`**. There is no re-open — a resolved case stays resolved — and a verdict cannot be changed after the fact. A case opened by the *anticheat* can only come from a reason in `BR.ShotSuspicious`; `BR.Damage.noteRefusal` returns early for anything else, and `verify.sh`'s *incident surface* gate pins that table, because the distance between "the game declined a shot" and "a human has to review a case" is the whole point. **Three producers, two record kinds**: refused shots and weapon strips both file `kind = 'anticheat'` with no reporter, and reports file `kind = 'report'`. The strip path deliberately reuses the anticheat shape rather than inventing a third — the console has two record types and must not grow one for a finding that triages exactly like the first. It carries no `refusal` block, because a strip has neither a `count` of refused shots nor a `windowMs` and inventing them would dress up the finding; its evidence is the match timeline. |
| **Verdict** | What an admin decided: `action` of `ban`, `kick` or `none`, plus `expiresAt` **if and only if** the action is a ban (`null` there means permanent). Written once, with the state, in one conditional update that refuses to run twice — so there is no window in which a resolved row is still waiting for its verdict. A resolved row carrying **no verdict at all** is a real state and is not `none`: it is a row that predates the field, or one the system auto-resolved, and reading it as "no action was taken" would be a claim about a decision nobody made. Read `action` first, always. |
| **A ban from an incident is a normal ban** | Issuing one out of a case is a **standard audit action** — the console records it in `ringmaster-audit` exactly as it records a ban issued from anywhere else. There is no separate incident-ban pathway. The row it writes to `ringmaster-bans` is the one described in [ban-contract.md](ban-contract.md), with no extra field, so the game server's connect check neither knows nor needs to know that a case was behind it. |
| **Report** | A player naming another from the in-game player list. `BR.Config.Report` bounds it three ways at once: **5 targets** in one submission (`maxTargets`), **3 submissions** per player per match (`maxPerMatch`), and **one report per target per match**. Those are separate limits — three submissions of five distinct targets is fifteen reports and is fine; two submissions naming the same person is one report and the second is refused whole. A submission naming somebody already reported is refused **entirely** rather than partly filed, and does not cost an allowance; hitting the rate limit *does* count, because hammering it is itself a signal. There is no free-text field: the dropdown reason is the whole report. |
| **Report reward** | 125 Volts to the reporter and every corroborator when their case resolves with an action taken. The debt is queued durably on the game's own table because the verdict arrives days and several deploys later; the credit and the receipt are one conditional write, so it cannot be paid twice. See [progression.md](progression.md). |
| **Killer nudge** | "Suspect cheating? Press **TAB** to report &lt;name&gt;", offered to a player who has just been killed by somebody with a case open. `BR.Net.REPORT_KILLED` **carries no payload at all** — the server resolves the asker's killer from its own damage records. That absence is the guard: the obvious shape ("is player 14 under suspicion?") is a probe a modified client would walk the roster with, and there is no field to enumerate with here. It requires state DEAD, not DBNO — being knocked is not being killed — and answers nothing when no case exists. The subject is told nothing, ever. **"A case open" means any match, not this one** (#177): the map behind it, `BR.Incident.openFor`, is keyed by license and is not freed at match teardown, so a case still in `pending_review` from a previous round prompts — an older case is the *better* corroboration target, having survived long enough to still be under review. It is honest only for the current server process: nothing on the box can enumerate cases by subject (there is no Query or Scan in br_ddb), so a restart forgets, and no resolution feed reaches the game, so a case an admin has since closed keeps prompting until then. |
| **Corroborate key** | The action behind the nudge. `BR.Net.REPORT_CORROBORATE`, also **payload-free**, resolved by the same function that decided to show the prompt — so the key works exactly when the prompt was offered, and does nothing when it was not. **That claim was false in TIME until 2026-08-20**, which is what broke corroboration on the verdict screen: the resolver *re-derived* the offender at press time from the victim's roster state and the assist window, and both expire while the sentence is still on screen — the server sweeps every participant to `LOBBY` as soon as their screen reports black under the verdict slam, and `attributedKiller` refuses anything older than `assistWindowMs`, which the client's own 10s key claim outlasts by construction. The prompt is now **recorded when it is offered** (`nudged` carries the offender and their name, not just a tick) and a press is honoured against that record when the live derivation has run out. Nothing new is trusted — the press still carries no fields — and the record is per `(match, reporter, offender)`, so an offer is never lent to another player. Its lifetime must outlive the client's, never the reverse, so it has no clock of its own beyond the match. One press appends to the case that already exists; it never opens one and never opens the player list. **One action per offender per match**: it is refused if this player has already reported that offender from the panel *or* already corroborated. The slot it always spends is `usage.corroborated`, per `(reporter, offender, match)`. **It spends `usage.named` — the set the panel refuses on — only when the case it answered is one *this* match opened**, and that condition is the whole of #177's match-boundary fix. It used to be written unconditionally, which is what the owner walked into on the first playtest: a case filed in match N and answered from the prompt in match N+1 spent match N+1's panel allowance, so the reporter was told "you have already reported X in this match" about a match in which they had reported nobody, and that round's own cheating opened no case. Filing policy is per match on purpose, and a prompt that reaches across matches must not repeal it by the back door. It does not spend one of the three panel submissions either way — one keypress is not one of the three trips to the panel. **TAB is the inventory key** — `BR.Keys.claim` in `br_core/client/keybinds.lua` borrows one press for as long as the sentence is on screen, so the two never both fire. That is a transient claim on one key and **not** the panel arbitration #179 asks for. |
| **Tilde and TAB are different verbs** | The reporting notice says *tilde*, the killer nudge says *TAB*, and reconciling them would delete an action. Tilde is the player-list latch (`brplayers`) and opens the panel so a **new** report can be filed against anybody in the match; TAB on the nudge **corroborates the existing case** against the player who just killed you, in one press, with no panel. Both keys were specified by the owner (#180 and #177 respectively), and neither is resolved from the binding table any more — see the note on `BR.Net.REPORT_HINT` in `br_ui/client/players.lua` for why that deliberately overrides #168. |
| **Weapon strip** | A weapon the gamemode never issued, taken out of the ped's hand **and recorded**. The strip itself is old and is a gameplay fix rather than an anticheat one — the engine applies damage locally before the server sees it, so a foreign weapon lets a client kill somebody on their own screen. What is new is that it reports. The **second** countable strip in a match opens one incident; the first is buffered and announced to nobody, because one weapon in one hand for one tick is the shape our own two inventory mirrors disagreeing has. Every strip after the second corroborates, **one per strip** — not `damage.lua`'s doubling. What bounds the channel is `MIN_INTERVAL_MS`, one countable strip per 900 ms per player. **Nobody is exempt, including admins**; an exemption shipped for one commit and the owner removed it the same day. Two guards stop it accusing innocent players: the client declines to report a hash that is in any of its own slots, and the server declines again against **its own** inventory, which is the copy a compromised client does not control. `brstrips` prints how often that second guard fired. It catches the vMenu tier only — the report comes from our own resource on the offender's machine, so a cheat that stops `br_core` stops this with it. |
| **Artifact** | A screenshot of the **subject's own screen**, taken through the third-party `screenshot-basic` and uploaded straight to S3 under the game box's own instance role. Three timed frames at offsets **0, +5s, +10s** from the filing, plus one per corroboration arriving after that first ten seconds, to a **cap of nine** (`timedMax` 3 + `corroborationMax` 6, `br_lib/shared/artifact_plan.lua`). At the cap the capture stops and nothing already taken is discarded. **It is the game's 3D render only** — NUI and the HUD are composited afterwards and never appear in a frame. **An empty or partial set is the normal outcome and is not evidence of anything**: the subject can disconnect, crash, alt-tab or be running without `screenshot-basic`, and every frame fails independently. Stamped with the server's clock, never the subject's. The subject is told nothing at any point. `brartifacts` is the only window onto it from the box. Unlike pma-voice, `screenshot-basic` is **installed, not vendored** — it ships TypeScript with no built output, so vendoring would mean committing a build we produced ourselves and destroying the provenance the vendoring gate exists to assert. |
| **Match timeline** | The match context a case carries: `match_start`, every `kill` the subject landed, every `weapon_strip`, `match_end`. A kill entry names the weapon **and whether it is one this gamemode issues** — resolved here, on the server, because the console has no weapon list and must not grow one; a second copy of that table in another repository is a copy that drifts, and the failure it produces is an innocent player shown in red. **Absolute times, not offsets**: every `at` is a game-clock reading converted to wall-clock on the way out, and the console renders "3m before the report" by subtracting `openedAt` itself. Storing offsets would bake the zero point into the data. `matchTimeline` is the **game's** attribute and `events` is the **console's** — two writers, two attributes, one view, merged on `at` for display. Capped at 250 kills and 60 strips, with `matchTimelineComplete` going false rather than a short list looking complete. |
| **Admin console (in-game)** | Ringmaster opened in an iframe from the pause menu, **already signed in**, so an admin never types a password into the game. `br_core/server/admin.lua` decides who may ask (the `BR.Grants.CONSOLE` scope); `br_ringmaster/server/handoff.lua` carries the question to the console and gets back a signed-in URL or a reason, knowing nothing about grants or about which player asked. The origin comes from **`br_adminConsoleUrl`**, and unset is the default and the default is off — no tab, no HTTP call, no mention anywhere but one line in the boot banner. The mint is keyed on the **admin**, so a retry replaces its predecessor and at most one live token exists per admin. **This is the one place the game asks the console for something and waits**, licensed by the fact that failure costs only the iframe: no connect gate, no match, no player, no tick. `bradmin` exists because the tab is binary and its preconditions are not — it names which of six reasons applies to each player. |
| **Appeal line** | The sentence appended to a kick or ban message saying where to come and argue about it, from **`br_discordUrl`**. Unset means **no line at all** — not an empty URL, not a bare "contact an admin". Parsed as kind `link` rather than kind `url`, and the distinction is the reason `link` exists: `br_adminConsoleUrl` is *compared* against a browser's `event.origin` so it must be bare and a trailing slash is fatal, while a Discord invite is nothing without its path. **It is no longer the only surface that value reaches** — see the Discord card below. |
| **Discord card** | The invite in the pause menu's Help page, from the same `br_discordUrl`. Added 2026-08-30, and it is where an **overridable key legitimately reaches a client**: `br_core/server/community.lua` reads the resolved value on `br:ready`, on the server, and sends it under the wire name **`invite`**. The rename is the whole licence — `verify.sh`'s *tunable overrides* gate greps every `br_*/client/*.lua` for the bare key `discordUrl` and fails on it in code or in a comment, so the client half never says the name and there is still one reader per Lua state. `{}` is a real answer and silence is not: clearing the convar and restarting `br_core` sends the empty table, and a page still up takes the card down on it. **Who sees it changed on 2026-08-31.** It used to vanish for the rest of a session once copied — the owner's own instruction, reasoning "it's not worth us writing something to listen for that" — and that is exactly what got answered, so the flag is gone rather than joined: the card now shows to **everybody** and is withheld only from a player Discord itself confirms is already in the guild. |
| **Guild lookup** | How that confirmation is obtained, and it does **not** go through Ringmaster even though Ringmaster already calls the same endpoint with the same kind of token — the game must never depend on the console, only the reverse. `br_core/server/guild.lua` makes one `GET /guilds/{guild}/members/{user}` per connection, primed at `playerJoining` so it has the resource download to settle in, against Discord's API pinned to **v10** (an unversioned path resolves to the long-deprecated v6). It needs `br_discord_bot_token` — **a secret**, read straight off the convar and deliberately never a `br_lib/config/` key, because everything in that directory is printed at boot, read back by `brconfig` and rendered by the console's `configreport`, so a credential there would be a credential in three logs — and `br_discord_guild_id`, digits only because both ids are interpolated into the request path. Both or neither; with neither the feature is inert and the card shows to all. **A 404 means two things** — "not a member" (10007) and "this bot cannot see that guild" (10004) — and reading the second as the first would take the card away from every player at once, so **only a confirmed yes hides anything**: no token, no `discord:` identifier, a timeout, a 429, a player who dropped mid-lookup all show the card. On the wire the answer is `member`, present **only** for a true, because absent-for-no and absent-for-we-could-not-tell must collapse: the page's question is "may I stop inviting this person", and a `false` would be a second thing to test and a second way to get the polarity wrong. |
| **Doorbell** | The design rule for incidents: **the DynamoDB write is the source of truth, the event is only a doorbell.** The tidier-looking design (send it over the event channel, let the console write it) is wrong, because that channel discards a batch after four attempts silently — so the console could not tell "thirty-two refusals were dropped" from "no refusals happened", and the evidence buffer behind a lost incident is discarded at match end. The game writes the row and the event carries only an id; a lost doorbell costs a delay, not the case. |
| **Outbox** | The batching event channel to Ringmaster. Gives a batch four attempts and then discards it — which is acceptable for telemetry and is exactly why incidents do not ride it. |
| **Drain gate / maintenance window** | The controlled path to taking the server down or switching what it runs: the console schedules a window, the server stops starting new matches and holds the door at the connect gate (`BR.Ring.draining()`), and the switch lands once it is empty. The game **polls** the maintenance row rather than being told — a pushed flag lives in memory, so a server that restarted mid-window would come back accepting players with nothing anywhere to notice. Re-reading every twenty seconds means the truth is re-derived continuously and heals itself after a restart on either side. |
| **Branch pin** | The file `switchref` writes and a deploy consumes, naming which ref to deploy. The sha is consumed by the first successful deploy, so a switch is a *one-time* act rather than a standing instruction — later routine deploys legitimately track the branch tip. |
| **Dispatch invariant** | `tools/dispatch.sh` must be byte-identical on every ref that can ever be deployed, so a branch can never rewrite the console's own SSH channel. Enforced in two places and gated from outside by `verify.sh`. |

---

