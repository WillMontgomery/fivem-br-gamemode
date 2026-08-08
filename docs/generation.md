# Generated systems

How loot layouts, flight routes and storm circles are produced, with the formulas.

[← Back to the main README](../README.md)

---

Everything below is generated per match from a seed, and all three follow the
same shape: **the server authors a record, both sides solve it, nothing is
streamed**. Written out because "why did it put a crate there" is a question
that comes up every playtest.

### Loot

**When.** The whole layout is built once, at `WARMUP`, by `BR.BuildLootLayout`
in `br_lib/shared/loot_gen.lua`. Not at `PLAYING` — players land during `BUS`,
so a layout generated at the state flip would pop items under whoever landed
first. The warmup island has its own separate, shared layout.

**The seed.** `GetGameTimer() + matchId × 15485863`. The prime keeps two
matches minted in the same server millisecond from replaying each other (the
storm uses 7919 and the bus 104729 for the same reason). **Layouts therefore
differ every match** — `brlootseed <n>` pins one when you need to debug the
same map twice. The seed never leaves the server: a client that could replay
it would know where every item is.

**How much, and where.** For each of the 101 POIs, by tier:

```
crates(tier)     = 20 | 20 | 24          (tier 1 | 2 | 3)
floor items(tier)=  5 |  8 | 14
```

Crates land uniformly **by area** in a disc of `radius × 0.95`, floor items in
`radius × 0.97` — just off the rim, where a first-pass radius is most likely to
have overshot into water or a cliff. (Crates used only the inner 75% of the
radius until 2026-08-06, which is 56% of the area and read as clustered in the
middle.) Then 420 roadside filler items along the
authored corridors in `BR.Config.Map.Roads`, offset **8–22 m** perpendicular
to the centreline, on one side or the other, never on it. Plus 3 crates per
player, spawned when they land, 55–130 m out — the inner radius is the design:
past what the eye takes in on touchdown, so it reads as a lucky drop zone
rather than as crates raining down around you.

A candidate point is rejected if it falls in authored water
(`BR.Config.Map.Water`) or a no-loot zone (`BR.Config.Map.NoLoot` — currently
the Cayo runway, so the Battle Bus never has to be cleared a path). POI
retries **shrink toward the centre**:

```
radius(attempt) = radius × spread × lerp(1.0, 0.15, (attempt-1)/11)
```

Re-rolling the same disc just draws the sea again for a coastal POI; walking
inward always terminates, because a POI centre is on land by definition.
There is a test asserting no water rectangle may contain one.

**What is inside.** Each roll picks a kind, then a rarity, then an item — and
**a crate rolls on a different table from the floor**:

```
crate kind ~ weighted(weapon 34, ammo 30, consumable 28, throwable 8)
floor kind ~ weighted(ammo 74, weapon 16, consumable 6, throwable 4)
```

Loose ground loot is deliberately almost all ammo, and **bandages and med kits
cannot spawn on the floor at all** (`chestOnly` on the consumable, with a
separate precomputed bucket table so a loose roll still burns the same number of
RNG draws). The crate has to be the thing worth crossing open ground for, and it
is not if a rifle on the floor is as likely as one in a box. Healing will
eventually also come from reboot vans. Shields are not restricted.

A crate holds **2–4 items, weighted 1:2:1**, so three is typical and it is never
empty. The rarity roll is shared:

```
rarity ~ weighted(RarityWeights[tier])      -- tier 3: 25/28/27/15/5
item   ~ uniform(bucket[rarity]), walking DOWN if that bucket is empty
```

The walk-down matters: there is no legendary consumable, and a nil item would
be an invisible prop. A crate's contents roll at `min(tier + 1, 3)` — one tier
hotter than the ground around it, which is what makes crossing open ground for
one worth the exposure. Its glow colour is the best thing inside.

**Determinism.** Every walk is over an **array**, never a hash — `pairs()`
order is undefined, so `AmmoOrder`, `WeaponsByRarity` and `ConsumablesByRarity`
all exist as ordered tables built by `ipairs`. Rejection loops burn a fixed
number of draws whether or not they reject.

**Dedup.** Ids are assigned `1..n` in generation order and are the claim key.
A claim removes the entry from the table before anything else happens, so a
second claim in the same tick finds nothing — that *is* the arbitration. A
test asserts uniqueness.

**Line of sight.** Not considered for the main layout, and cannot be:
generation runs at warmup, before anyone has chosen a drop, so there is
nothing to be in sight of. It only applies to the landing crates, which is
what their 55 m inner radius is for.

**Streaming.** Clients report their 256 m cell at 1 Hz; the server answers with
the entries in the 3×3 block around it and retires what left scope. Props
materialise within 180 m, capped at 160 objects. A client that ground-probes an
entry into the sea or under the map sends back a corrected position
(`LOOT_FIX`), which the server accepts within 30 m, once per entry.

### Flight routes

The tour is **authored, not random**. `BR.Config.Bus.legs` holds four leg
lists — coast, city, mid-map, northern exit — and a flight draws one option
from each:

```
route = spawn → leg1[i] → leg2[j] → leg3[k] → leg4[l] → overrun
        4 × 4 × 4 × 3 = 192 possible flights
```

Drawing from ordered lists rather than sampling the map means every flight
crosses land, passes POIs, and cannot degenerate into a corner-to-corner
diagonal over the ocean. The rng is `GetGameTimer() + matchId × 104729`, so
concurrent matches fly different tours.

Timing is computed from the geometry, not scripted: the ground roll is uniform
acceleration sampled at equal **time** steps (`pos ∝ k²`, `v ∝ k`, 32 samples
— equal *distance* steps were the takeoff lurch), then a climb over
`climbDist` 1800 m using smootherstep for the z curve, then cruise at
600 units/s. `route.rotateAt` is the wheels-up timestamp, and both the island
handoff and the smoke cutoff clock from it.

The **doors** open on arrival at the leg-1 waypoint and close after a
5-second overrun past the last, when stragglers are force-ejected. Clients
each fly their own local, non-networked Titan along the published route
against the synced clock — 48 players see identical planes with zero sync
traffic.

### Storm circles

**The anchor** is picked at warmup: a random waypoint of *this match's tour*,
then a random POI 500–1500 units off it. Route-coupled, always on land, and
never the same twice — see `BR.PickStormAnchor` in `storm_solve.lua`.

**The opening circle** is centred on the anchor with a radius that guarantees
nobody can land outside it:

```
radius0 = max(configured r0, distance from anchor to each of the 4 map corners)
          + openMargin (200)
```

**Each phase** publishes one record — `{cx0, cy0, r0, cx1, cy1, r1, tStart,
tWait, tShrink, dps}` — and both sides solve it with `BR.StormAt(record, now)`.
Nothing about the circle is streamed; a shrinking storm costs zero per-frame
network traffic.

The next circle is chosen by `NextStormCentre`, which picks a point such that
the new circle sits **inside** the old one, with an edge bias that grows over
the match (`edgeBiasMax` 1.0) so late circles hug the rim rather than always
converging on the middle. Containment beats the bias: the solver's `minDist`
is `slack − 250`, so a circle that cannot both hug the edge and stay inside
gives up the edge.

**Timing.** The first hold is priced for the furthest player's run to the
first circle's *edge*:

```
hold = clamp(furthest_distance_to_edge / metersPerSec, minSeconds, maxSeconds)
       then capped at startCapSeconds (180)
```

so the wall always moves within three minutes whatever the drop spread, and a
player already inside the target pays nothing. Every later shrink is priced
the same way — `clamp(furthest-to-target-edge / 9, 40s, authored)` — which is
what stops a fast circle being unsurvivable from the far side.

**Damage** is `dps = 100 / killtime`, from a table that ramps 1 → 10 across the
phases, applied 1 Hz from server-sampled positions and bypassing armour. Phase
1's hold is free (`dps = 0`) — nothing hurts until circle 1 starts closing.

---

