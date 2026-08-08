# The arithmetic of a match

Every number a match is built from, where it comes from, and why it is that
number. This is the page to read before changing any of them.

[← Back to the main README](../README.md)

---

Nothing here is decided by a client. Every value below is computed on the
server, from a seed the server keeps, and published as a record that clients
*interpolate* rather than recompute. That distinction is load-bearing and it
comes up in every section.

---

## 1. Seeds, and why the same match never repeats

Three independent seeds per match, derived from the match id and the server
clock:

```
lootSeed  = mix(matchId, now)
stormSeed = mix(matchId, now, 7919)
busSeed   = mix(matchId, now, 104729)
```

The two constants are primes, and they exist for one reason: two matches
minted in the same server millisecond would otherwise share a seed and replay
each other's map, route and circles exactly. Mixing a different prime into each
subsystem also stops the storm and the bus from correlating within one match.

**The seed never leaves the server.** A client that could derive the loot
layout would know where every item on the map is; a client that could derive
the storm sequence would know every circle in advance. `brlootseed <n>` pins a
layout for debugging, server-side only.

---

## 2. The flight route

The bus flies an authored tour, not a straight line. Route selection is a
seeded pick over the tours in `br_lib/config/map.lua`, then a chord across the
map for the approach.

### The chord

```
theta   = rng() * 2π                        -- a random bearing
offset  = (rng() * 2 - 1) × radius × maxOffset
half    = √(radius² - offset²)              -- half-chord at that offset
start   = centre + perpendicular(offset) - direction × half
end     = centre + perpendicular(offset) + direction × half
```

The perpendicular offset is what stops every match flying through the middle of
the map. `maxOffset` defaults to 0.5, so the chord can sit anywhere from a
diameter to a shallow edge pass.

### Timing the route

Waypoints are solved into a timed path with a smoothing pass, so the plane
accelerates and decelerates rather than stepping between speeds:

```
-- forward pass, then backward pass, over every adjacent pair
cap      = √(v_next² + 2 × a_max × distance)
v_i      = min(v_i, cap)

-- then time each segment at its average speed
t += distance / ((v_prev + v_next) / 2)
```

The backward pass is the one that matters: without it a plane can be *told* to
be slow at a waypoint it is arriving at too fast to reach.

### Takeoff

| Quantity | Value | Why |
|---|---|---|
| Roll distance | ~382 m | Spawn to `rotatePoint`, surveyed in game |
| `rollSpeed` | 88 m/s | Wheels-up speed. Roll time is `2 × distance / rollSpeed` |
| `climbDist` | 1800 m | Past rotation, to reach cruise altitude |
| `climbSpeed` | 270 m/s | Through the climb and the first turn |
| `turnRadius` | 1000 m | Fillet: start turning this far from a waypoint |

### The doors

The jumpable window is the **union** of an authored window and every door-zone
crossing:

```
open  = min(authoredOpen,  first zone entry)
close = max(authoredClose, last zone exit)
open  = max(open, rotateAt)          -- never before wheels-up
```

Door zones (`BR.Config.Map.DoorZones`) cover LSIA and the ports. The union is
widening-only: a zone can never make the jumpable stretch shorter than the
authored one. The radii are deliberately tight — an early draft at 1200/1400 m
reached out over the ocean, and the departure path from Cayo clipped it,
opening the doors over open water seconds after takeoff.

---

## 3. The storm

### The anchor

The whole sequence homes on one point, chosen at warmup:

1. Pick a random **waypoint of this match's own flight tour**.
2. Pick a random **POI** between `band.min` and `band.max` of it (500–1500 m).
3. If nothing is in band, widen by `widenStep` up to `widenMax`, then take the
   nearest POI outright.

Route-coupled, so the opening circle almost always contains a stretch of the
path players actually dropped along. POI-anchored, so the centre is always a
nameable place on land.

### The opening circle

```
radius0 = max(configRadius0, distance from anchor to the furthest AABB corner)
```

It covers the **whole playable map** by construction. Nobody can land outside
circle one, so "I spawned already dying" is structurally impossible.

### The phases

| # | Radius | Wait | Shrink (ceiling) | DPS |
|---|---|---|---|---|
| 1 | 2600 | 120 s | 240 s | 0.5 |
| 2 | 1600 | 120 s | 120 s | 1.25 |
| 3 | 950 | 90 s | 90 s | 1.7 |
| 4 | 520 | 75 s | 75 s | 2.2 |
| 5 | 260 | 60 s | 60 s | 2.9 |
| 6 | 110 | 45 s | 50 s | 4.0 |
| 7 | 40 | 40 s | 40 s | 5.0 |
| 8 | 0 | 30 s | 60 s | 6.7 |

DPS is in **display units per second** against a 100-point bar, so phase 1
takes 200 s of standing still to kill and phase 8 takes 15.

Phase 1 is deliberately the forgiving one: a far-end jumper has a legitimate
multi-minute run to the first circle, so being caught by it should cost health
rather than the match.

### How long a shrink actually takes

The authored `shrink` is a **ceiling**, not the duration. The real figure is
priced off the furthest player's run:

```
furthest  = max over in-match players of (distance to next centre − nextRadius)
shrinkSec = clamp(furthest / 9.0, 40, ceiling)
```

9 m/s is the assumed cross-map travel speed. Everyone already inside means the
sweep takes the 40-second floor and the game moves on; a genuine straggler buys
time up to the ceiling.

### Where the next circle goes

```
slack   = curRadius − nextRadius            -- the containment limit
offset  ~ pointInDisc(reach × edgeBias)     -- uniform BY AREA, not by radius
```

`pointInDisc` applies `√` to the radius draw. Without it, circles cluster
toward the centre and every match's zone path feels the same.

**Breakout.** With a probability that ramps by phase, the next circle may leave
the current one entirely:

```
chance(phase) = lerp(0%, 85%, (phase − 1) / (phases − 1))
reach         = curRadius + nextRadius + gapMax × curRadius      -- when it fires
              = slack                                            -- when it does not
```

`gapMax` is 0.5, so the two circles may separate by up to half the
predecessor's radius. This is safe only because the wall **sweeps**: damage
comes from where the wall is, and a phase that broke out gets its shrink
ceiling multiplied by `shrinkFactor` (2.5) so the run is one people can make.

Two earlier formulations were wrong in instructive ways — scaling the budget by
the *next* radius made the final phase (radius 0) unable to move at all, and
scaling by the *current* radius could never separate the early circles. Stating
the geometry we wanted removed both accidents.

### And never into the sea

A drawn centre that lands in authored water is walked back along its own
bearing toward the previous centre, which is dry by induction from the anchor.
Without this, 210 of 600 sampled draws off a coastal centre landed in open
water.

---

## 4. Loot

### How much, and where

For each of the 105 POIs, by tier:

```
crates(tier)      = 20 | 20 | 24
floor items(tier) =  5 |  8 | 14
```

Plus 420 roadside filler items along the authored corridors, offset 8–22 m
perpendicular to the centreline, on one side or the other, never on it.

Crates sample uniformly **by area** in `radius × 0.95`, floor items in
`radius × 0.97`. The crate figure used to be 0.75, which is only 56% of the
area — and that is what read as "clustered in the middle".

A rejected point retries by **shrinking toward the centre**:

```
radius(attempt) = radius × spread × lerp(1.0, 0.15, (attempt − 1) / 11)
```

Re-rolling the same disc just draws the sea again for a coastal POI. Walking
inward always terminates, because a POI centre is on land by definition.

### What is in it

Crates and the floor roll on **different tables**:

```
crate kind ~ weighted(weapon 34, ammo 30, consumable 28, throwable 8)
floor kind ~ weighted(ammo 74, weapon 16, consumable 6, throwable 4)
```

Bandages and med kits are `chestOnly` and cannot spawn loose at all. A crate
holds **2–4 items weighted 1:2:1**, so three is typical and it is never empty.
Crate weapon rolls have an 18% chance of producing melee instead of a firearm.

### Rarity

```
rarity ~ weighted(RarityWeights[tier])
item   ~ uniform(bucket[rarity]), walking DOWN if that bucket is empty
```

| Tier | Common | Uncommon | Rare | Epic | Legendary |
|---|---|---|---|---|---|
| 1 | 55 | 28 | 13 | 3 | 1 |
| 2 | 40 | 30 | 20 | 8 | 2 |
| 3 | 25 | 28 | 27 | 15 | 5 |

Crate contents roll at `min(tier + 1, 3)` — one tier hotter than the ground
around them, which is what makes crossing open ground for one worth the
exposure.

---

## 5. Damage

Every figure here is recomputed **server-side** from our own tables. The
client's reported damage is evidence of intent, never an input.

```
damage = weaponDamage
       × rarityMultiplier
       × rangeFalloff
       × bodyPartMultiplier
```

### Range falloff

Linear over the back half of the weapon's range, floored at 55%:

```
if distance > maxRange / 2:
    falloff = lerp(1.0, 0.55, (distance − maxRange/2) / (maxRange/2))
```

### Body parts

| Part | Multiplier |
|---|---|
| Head | 2.3 |
| Neck | 1.8 |
| Chest / upper torso | 1.0 |
| Lower torso / pelvis | 0.95 |
| Hips | 0.80 |
| Shoulders | 0.75 |
| Upper arms / legs | 0.65 |
| Elbows | 0.55 |
| Wrists / feet | 0.50 |

2.3 is arithmetic, not taste. Health is 100, so "two headshots to kill" means a
headshot must land in (50, 100]:

```
Mini SMG   23 × 2.3 = 53      Carbine        32 × 2.3 = 74
Pistol     26 × 2.3 = 60      Military Rifle 42 × 2.3 = 97
```

The weapons that break the rule are the ones that should: revolvers, shotguns
and snipers, all of which hit for 60+ to the chest before any multiplier.

**Headshots also fall off with range**, so a cross-map SMG headshot is not a
delete:

```
headMult(d) = lerp(2.3, 1.25, clamp((d − 30) / (120 − 30), 0, 1))
```

Snipers are unaffected in the way that matters — they one-shot centre mass
through raw damage at any range.

### Health units

Two scales, and mixing them is the likeliest source of a subtle balance bug:

- **Engine** 100–200, where **100 means dead**. What `GetEntityHealth` speaks.
- **Display** 0–100, what players see and what every config number uses.

Convert only at the boundary, with `BR.ToEngineHp` / `BR.ToDisplayHp`.

---

## 6. Everything else, in one table

| Quantity | Value | Notes |
|---|---|---|
| Max players | 48 | The free OneSync ceiling |
| Squad size | 4 | `minSquads` 2, so a match needs somebody to fight |
| Warmup | 45 s | 15 s once the lobby is full |
| Sprint | 7.8 s | Drain 12.82/s, regen 25/s after a 900 ms pause |
| Position sampling | 2 Hz | Which is why every range check carries slack |
| Roster delta flush | 4 Hz | |
| Digest | 2 Hz | The self-healing heartbeat |
| Client loops | 60 / 10 / 1 Hz | frame, tick, slow |
| Loot cell | 256 m | 3×3 subscription = 768 m |
| Loot props | 90 m | Subscription is cheap; objects are not |
| Assist window | 10 s | Storm damage still credits whoever shot you |

---

## Where these live

| Numbers | File |
|---|---|
| Players, timings, health, ambient, combat, body parts | `br_lib/config/match.lua` |
| Storm phases, anchor band, breakout, pacing | `br_lib/config/storm.lua` |
| Weapons, rarity, ammo caps, melee | `br_lib/config/weapons.lua` |
| Loot budgets, crates, consumables, drag, labels | `br_lib/config/loot.lua` |
| POIs, roads, water, door zones, bus routes | `br_lib/config/map.lua` |

The solvers that consume them are pure and tested outside the game:
`br_lib/shared/storm_solve.lua`, `loot_gen.lua`, `combat_solve.lua`, `geo.lua`.
